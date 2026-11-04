// ----------------------------------------------------------------------------
//
//  Copyright (C) 2021 Arthur Benilov <arthur.benilov@gmail.com>
//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ----------------------------------------------------------------------------

#include "aeolus/voice.h"
#include "aeolus/engine.h"

#include <cmath>
#include <cstring>

using namespace juce;

AEOLUS_NAMESPACE_BEGIN

Voice::Voice(Engine& engine)
    : _engine(engine)
    , _state{}
    , _stopIndex{-1}
    , _buffer{0}
    , _delayLine{SAMPLE_RATE}
    , _delay{0}
    , _chiff{}
    , _panPosition{0.0f}
    , _spatialSource{}
{
}

void Voice::trigger(const Pipewave::State& state)
{
    jassert(_state.isIdle());
    _state = state;

    // Clé de redondance (Q1c) : précalculée une seule fois ici, hors du
    // chemin de choix. Le modèle Addsynth identifie exactement le TUYAU
    // (ressource) : deux divisions qui tirent le même tuyau partagent le
    // même modèle ; un même libellé de jeu sur un autre tuyau (Open
    // Diapason 8 III) a un modèle différent et n'est donc pas un doublon.
    // La fréquence inclut la transposition fd/fn : deux rangs de mixture
    // de même tuyau et même note n'ont pas la même hauteur, donc pas la
    // même clé.
    _modeleRedondance = nullptr;
    _cleRedondance = 0;
    _freqCent = 0;
    if (_state.pipewave != nullptr) {
        const auto& modele = _state.pipewave->getModel();
        const float f = _state.pipewave->getPipeFrequency();

        // Tolérance : quantification au cent (1/100 de demi-ton), très en
        // dessous du seuil audible de hauteur (~5 cents). Deux tuyaux
        // réellement identiques donnent exactement le même entier.
        if (f > 0.0f)
            _freqCent = (int32_t) std::lround(1200.0 * std::log2((double)f / 440.0));

        _modeleRedondance = &modele;

        const juce::String nom = modele.getStopName();
        const char* p = nom.toRawUTF8();
        uint32_t h = 2166136261u; // FNV-1a 32 bits
        while (*p != 0) {
            h ^= (uint32_t)(uint8_t)*p++;
            h *= 16777619u;
        }
        h ^= (uint32_t)_freqCent;
        h *= 16777619u;
        _cleRedondance = h;
    }

    _volee = false;
    _neuve = true;

    // Réglages de qualité : recopiés ici (R1), lus une seule fois pour toute
    // la durée de vie de la voix. Les voix déjà sonnantes gardent l'ancien
    // réglage jusqu'à leur recyclage.
    _qualiteSpatialisation = jlimit(0, 2, _engine.getQualite(Engine::QUALITE_SPATIALISATION));
    _qualiteBruitAttaque = _engine.getQualite(Engine::QUALITE_BRUIT_ATTAQUE) != 0;
    _qualiteInstabilite = _engine.getQualite(Engine::QUALITE_INSTABILITE) != 0;

    // Instabilité de hauteur : verrouillée pour ce tuyau (rankwave.cpp).
    _state.instabilite = _qualiteInstabilite;

    // Chiff
    const auto freq = _state.pipewave->getPipeFrequency();
    const auto dt = 1.0f / freq;

    // Delay pipe harmonic signal so that chiff noise builds up first
    _delay = (int) jmin((float)_delayLine.size(), 0.5f * dt * SAMPLE_RATE_F);

    _chiff.setAttack(5.0f * dt);
    _chiff.setDecay(100.0f * dt);
    _chiff.setSustain(0.01f);
    _chiff.setRelease(100.0f * dt);

    // Frequency-dependant chiff attenuation
    float att = 1.0f - expf(-freq / 3000.0f);
    _chiff.setGain(jmin(1.0f, 0.02f * _state.chiffGain * att));
    _chiff.setFrequency(freq);
    if (_qualiteBruitAttaque)
        _chiff.trigger();

    // Spatialisation
    int note = _state.pipewave->getNote();
    float k = note % 2 != 0 ? 1.0f : -1.0f;

    // Wider spread for low-pitched pipes
    const auto& model = _state.pipewave->getModel();
    const float width = 0.15f * model.getFd() / model.getFn();

    float x = width * k * (float)abs(note - 65);

    // Assuming notes range [36..96]
    float n = k * float(abs(note - 65)); // ~[-30..30]
    _panPosition = jlimit(0.0f, 1.0f, (n + 30.0f) / 60.0f);

    _spatialSource.setSampleRate(SAMPLE_RATE_F);
    _spatialSource.setSourcePosition(x, 5.0f);
    _spatialSource.recalculate();

    // Gains du chemin simplifié : les mêmes atténuations que celles
    // appliquées par SpatialSource, sans ligne à retard ni biquad par voix.
    _gainL = _spatialSource.leftAttenuation();
    _gainR = _spatialSource.rightAttenuation();

    // R2 : la ligne à retard spatiale n'est utilisée qu'en niveau 2 ; son
    // temps de vidage ne doit donc pas être compté aux niveaux 0 et 1.
    _postReleaseCounter = (_qualiteSpatialisation == 2
                               ? _spatialSource.getPostFxSamplesCount()
                               : 0)
                        + 2 * _delay + (int)TREMULANT_DELAY_LENGTH;
}

void Voice::release()
{
    // This voice is pending to be reclaimed.
    if (_state.env == Pipewave::Over)
        return;

    _state.release();

    _chiff.release();
}

void Voice::reset()
{
    _state.reset();
    _stopIndex = -1;

    memset(_buffer, 0, sizeof(float) * SUB_FRAME_LENGTH);

    _delayLine.reset();
    _chiff.reset();
    _spatialSource.reset();

    _fadeGain = 0.0f;
    _fadeStep = 0.0f;
    _volee = false;
    _neuve = false;
    _proprietaire = nullptr;

    _cleRedondance = 0;
    _freqCent = 0;
    _modeleRedondance = nullptr;
}

void Voice::demanderVidageRapide()
{
    if (_state.env == Pipewave::Idle || _state.env == Pipewave::Over)
        return;

    // Déjà en cours de vidage rapide.
    if (_fadeGain > 0.0f)
        return;

    // Release normal (sans clic) puis fondu court de la sortie, ~5 ms : la
    // voix est libérée au pool dès que le fondu atteint zéro.
    release();
    _volee = true;
    _fadeGain = 1.0f;
    _fadeStep = 1.0f / (0.005f * SAMPLE_RATE_F);
}

void Voice::process(float* outL, float* outR)
{
    _neuve = false;
    memset(_buffer, 0, sizeof(float) * SUB_FRAME_LENGTH);

    const auto gain = _state.gain;

    if (_state.env == Pipewave::Over) {
        _postReleaseCounter -= std::min((int)_postReleaseCounter, SUB_FRAME_LENGTH);

        for (int i = 0; i < SUB_FRAME_LENGTH; ++i) {
            _delayLine.write(0.0f);
            _buffer[i] = _delayLine.readNearest(_delay) * gain;
        }

    } else {
        auto* pipe = _state.pipewave;
        pipe->play(_state, _buffer);

        for (int i = 0; i < SUB_FRAME_LENGTH; ++i) {
            _delayLine.write(_buffer[i]);
            _buffer[i] = _delayLine.readNearest(_delay) * gain;
        }
    }

    if (_qualiteBruitAttaque)
        _chiff.process(_buffer, SUB_FRAME_LENGTH);

    // Vol de voix : fondu court de la sortie entière, puis libération.
    if (_fadeGain > 0.0f) {
        int i = 0;
        for (; i < SUB_FRAME_LENGTH && _fadeGain > 0.0f; ++i) {
            _buffer[i] *= _fadeGain;
            _fadeGain -= _fadeStep;
        }
        if (_fadeGain <= 0.0f) {
            for (; i < SUB_FRAME_LENGTH; ++i)
                _buffer[i] = 0.0f;
            _fadeGain = 0.0f;
            _state.env = Pipewave::Over;
            _postReleaseCounter = 0;
        }
    }

    // Spatial modelling is only applied on stereo voice output
    if (outL != outR) {
        switch (_qualiteSpatialisation) {
        case 2:
            // Chemin d'origine : ligne à retard + deux biquads par voix.
            _spatialSource.process(_buffer, outL, outR, SUB_FRAME_LENGTH);
            break;

        case 1:
            // Chemin simplifié : gains gauche/droite seulement. Le filtre
            // passe-bas commun est appliqué par la division. On ADDITIONNE
            // dans le tampon de niveau 1 de la division, effacé une seule
            // fois avant la boucle des voix : une affectation écraserait la
            // contribution des voix précédentes.
            for (int i = 0; i < SUB_FRAME_LENGTH; ++i) {
                const float x = _buffer[i];
                outL[i] += x * _gainL;
                outR[i] += x * _gainR;
            }
            break;

        default:
            // Spatialisation coupée : somme mono centrée à gain unité.
            for (int i = 0; i < SUB_FRAME_LENGTH; ++i) {
                outL[i] = _buffer[i];
                outR[i] = _buffer[i];
            }
            break;
        }
    } else {
        memcpy(outL, _buffer, sizeof(float) * SUB_FRAME_LENGTH);
    }
}

bool Voice::isOver() const noexcept
{
    return (_state.env == Pipewave::Over) && _postReleaseCounter == 0;
}

bool Voice::isActive() const noexcept
{
    return _state.env == Pipewave::Attack;
}

bool Voice::isForNote(int note) const noexcept
{
    if (_state.pipewave != nullptr)
        return _state.pipewave->getNote() == note;

    return false;
}

int Voice::getNote() const
{
    if (_state.pipewave != nullptr)
        return _state.pipewave->getNote();

    return -1;
}

void Voice::resetAndReturnToPool()
{
    _engine.getVoicePool().resetAndReturnToPool(this);
}

//==============================================================================

VoicePool::VoicePool(Engine& engine, int maxVoices)
    : _engine{engine}
    , _voices(maxVoices, engine)
    , _idleVoices{}
    , _registre{}
    , _voiceCount{0}
    , _tableRedondance(TailleTableRedondance)
{
    _registre.reserve(maxVoices);

    for (auto& voice : _voices)
        _idleVoices.append(&voice);
}

int VoicePool::getNumberOfHeldVoices() const noexcept
{
    int n = 0;

    for (const auto* voice : _registre) {
        if (voice->isActive())
            ++n;
    }

    return n;
}

bool VoicePool::hasHeldVoiceForNote(int note) const noexcept
{
    for (const auto* voice : _registre) {
        if (voice->isActive() && voice->isForNote(note))
            return true;
    }

    return false;
}

void VoicePool::enregistrer(Voice* voice)
{
    // Une voix ne doit être enregistrée qu'une seule fois : un doublon
    // fausserait le compte des voix tenues et le plafond.
    for (const auto* v : _registre) {
        if (v == voice)
            return;
    }

    voice->setRegistreSlot((int)_registre.size());
    voice->setOrdre(_prochainOrdre++);
    _registre.push_back(voice);
}

void VoicePool::desenregistrer(Voice* voice)
{
    // Recherche linéaire (registre borné à 512) : plus robuste qu'un index
    // stocké, qui peut devenir obsolète si une voix est réutilisée d'autorité.
    for (size_t i = 0; i < _registre.size(); ++i) {
        if (_registre[i] != voice)
            continue;

        Voice* last = _registre.back();
        _registre[i] = last;
        last->setRegistreSlot((int)i);
        _registre.pop_back();
        voice->setRegistreSlot(-1);
        return;
    }
}

Voice* VoicePool::choisirVictime() noexcept
{
    constexpr size_t capacite = (size_t)TailleTableRedondance;
    constexpr size_t masque = capacite - 1;

    // Table fixe réinitialisée sans allocation (memset sur 2048 entrées).
    std::memset(_tableRedondance.data(), 0,
                _tableRedondance.size() * sizeof(EntreeRedondance));

    auto trouver = [this, masque](const Voice* voice) -> EntreeRedondance* {
        const uint32_t cle = voice->cleRedondance();
        const int32_t cent = voice->freqCent();
        const Addsynth* modele = voice->modeleRedondance();

        size_t i = (size_t)cle & masque;
        for (size_t essai = 0; essai < capacite; ++essai) {
            auto& e = _tableRedondance[i];

            if (!e.occupe)
                return nullptr;

            // Égalité réelle, pas seulement la clé de hachage : une
            // collision entre deux tuyaux différents ne les fusionne jamais.
            if (e.cle == cle && e.modele == modele && e.freqCent == cent)
                return &e;

            i = (i + 1) & masque;
        }

        return nullptr;
    };

    // Première passe : compter les groupes (tuyau exact, hauteur au cent) et
    // retenir s'ils mélangent au moins deux divisions.
    for (auto* voice : _registre) {
        if (!voice->isActive())
            continue;

        const Addsynth* modele = voice->modeleRedondance();
        if (modele == nullptr)
            continue;

        const uint32_t cle = voice->cleRedondance();
        const int32_t cent = voice->freqCent();

        size_t i = (size_t)cle & masque;
        for (size_t essai = 0; essai < capacite; ++essai) {
            auto& e = _tableRedondance[i];

            if (!e.occupe) {
                e.occupe = true;
                e.cle = cle;
                e.modele = modele;
                e.freqCent = cent;
                e.division = voice->proprietaire();
                e.compte = 1;
                e.melange = false;
                break;
            }

            if (e.cle == cle && e.modele == modele && e.freqCent == cent) {
                if (e.compte < UINT16_MAX)
                    ++e.compte;
                if (e.division != voice->proprietaire())
                    e.melange = true;
                break;
            }

            i = (i + 1) & masque;
        }
    }

    // Deuxième passe : la plus ancienne voix ACTIVE dont le groupe est
    // redondant. Un groupe redondant couvre au moins deux divisions : en
    // retirer une voix laisse donc toujours au moins un exemplaire.
    Voice* victime = nullptr;

    for (auto* voice : _registre) {
        if (!voice->isActive() || voice->modeleRedondance() == nullptr)
            continue;

        const auto* e = trouver(voice);
        if (e == nullptr || !e->melange)
            continue;

        if (victime == nullptr || voice->ordre() < victime->ordre())
            victime = voice;
    }

    if (victime != nullptr)
        return victime;

    // À défaut, comportement d'origine : la plus ancienne voix active, puis
    // la plus ancienne du registre (déjà en release, moins coûteuse à couper).
    for (auto* voice : _registre) {
        if (!voice->isActive())
            continue;

        if (victime == nullptr || voice->ordre() < victime->ordre())
            victime = voice;
    }

    if (victime != nullptr)
        return victime;

    for (auto* voice : _registre) {
        if (victime == nullptr || voice->ordre() < victime->ordre())
            victime = voice;
    }

    return victime;
}

Voice* VoicePool::trigger(const Pipewave::State& state)
{
    auto* voice = _idleVoices.first();
    const int maxVoices = _engine.getQualite(Engine::QUALITE_POLYPHONIE_MAX);

    // Pool physiquement saturé : réutiliser d'autorité une voix pour ne
    // jamais perdre la nouvelle note (au prix d'une coupure nette dans ce cas
    // extrême). C'est la correction de la perte silencieuse d'origine. Si le
    // plafond est atteint, on réutilise une voix tenue (le compte reste
    // borné) ; sinon la plus ancienne du registre.
    if (voice == nullptr) {
        Voice* victim = nullptr;

        if (maxVoices > 0 && getNumberOfHeldVoices() >= maxVoices)
            victim = choisirVictime();
        else
            victim = _registre.empty() ? nullptr : _registre.front();

        if (victim == nullptr)
            return nullptr;

        // Détacher la victime de toutes les divisions (son propriétaire
        // enregistré peut être obsolète après une réutilisation forcée).
        for (int i = 0; i < _engine.getDivisionCount(); ++i)
            _engine.getDivisionByIndex(i)->detacherVoix(victim);

        desenregistrer(victim);
        victim->reset();
        victim->trigger(state);
        enregistrer(victim);

        return victim;
    }

    // Plafond de polyphonie (R3) : voler une voix. Si la victime n'a pas
    // encore été traitée (déclenchée plus tôt dans le même bloc audio), elle
    // n'a produit aucun son : on la réutilise directement pour la nouvelle
    // note, sans fondu ni nouvelle voix. Cela évite de déclencher puis de
    // faire se vider 156 voix pour rien quand un accord de 252 rangs tombe
    // sous un plafond de 96 (pics de démarrage mesurés en Q1c). Sinon, la
    // victime reçoit un release court sans clic ; la nouvelle note n'est
    // jamais perdue.
    if (maxVoices > 0 && getNumberOfHeldVoices() >= maxVoices) {
        if (auto* victim = choisirVictime()) {
            if (victim->estNeuve()) {
                for (int i = 0; i < _engine.getDivisionCount(); ++i)
                    _engine.getDivisionByIndex(i)->detacherVoix(victim);

                desenregistrer(victim);
                victim->reset();
                victim->trigger(state);
                enregistrer(victim);

                return victim;
            }

            victim->demanderVidageRapide();
        }
    }

    _idleVoices.remove(voice);
    voice->trigger(state);
    enregistrer(voice);
    ++_voiceCount;

    return voice;
}

void VoicePool::resetAndReturnToPool(Voice* voice)
{
    jassert(voice != nullptr);

    desenregistrer(voice);
    voice->reset();
    _idleVoices.append(voice);
    --_voiceCount;
}

AEOLUS_NAMESPACE_END
