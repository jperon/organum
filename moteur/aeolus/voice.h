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

#pragma once

#include "aeolus/globals.h"
#include "aeolus/list.h"
#include "aeolus/rankwave.h"

#include "aeolus/dsp/delay.h"
#include "aeolus/dsp/chiff.h"
#include "aeolus/dsp/spatial.h"

#include <vector>
#include <atomic>
#include <cstdint>

/// Marqueur de compilation : le sacrifice prioritaire des doublons (Q1c) est
/// présent. Sert aux tests qui doivent aussi compiler contre l'état d'origine.
#define ORGANUM_VOIX_DOUBLONS 1

AEOLUS_NAMESPACE_BEGIN

class Engine;
class Division;

/**
 * @brief Single voice associated with a single pipe.
 */
class Voice : public ListItem<Voice>
{
public:
    Voice() = delete;
    Voice(Engine& engine);

    void trigger(const Pipewave::State& state);
    void release();
    void reset();
    void process(float* outL, float* outR);
    bool isOver() const noexcept;
    bool isActive() const noexcept;
    bool isForNote(int note) const noexcept;
    int getNote() const;

    void setStopIndex(int idx) noexcept { _stopIndex = idx; }
    int stopIndex() const noexcept { return _stopIndex; }

    void resetAndReturnToPool();

    float getPanPosition() const noexcept { return _panPosition; }

    /// Mode de spatialisation verrouillé au déclenchement (0/1/2).
    int spatialisation() const noexcept { return _qualiteSpatialisation; }

    /// Release court (~5 ms) utilisé par le vol de voix du plafond de
    /// polyphonie : fondu sur la sortie puis libération au pool.
    void demanderVidageRapide();

    /// Vrai si la voix a été libérée par un vol de voix du plafond et n'a
    /// pas encore été recyclée. La touche qu'elle occupait reste considérée
    /// comme déjà voisée jusqu'au prochain recyclage : sans cela, un second
    /// événement du même bloc (autre division, autre canal) re-déclenche la
    /// note volée, qui vole à son tour une autre voix (cascade mesurée en
    /// Q1c : 504 voix prises au lieu de 252).
    bool estVolee() const noexcept { return _volee; }

    /// Vrai entre le déclenchement et le premier traitement audio. Une voix
    /// encore neuve n'a jamais produit d'échantillon : on peut la réutiliser
    /// pour une nouvelle note sans fondu (aucun clic), au lieu de la laisser
    /// se vider pendant qu'une autre voix est déclenchée puis traitée pour
    /// rien. Voir VoicePool::trigger.
    bool estNeuve() const noexcept { return _neuve; }

    /// Index dans le registre du pool (retrait O(1)).
    int registreSlot() const noexcept { return _poolSlot; }
    void setRegistreSlot(int slot) noexcept { _poolSlot = slot; }

    /// Numéro d'ordre d'activation (voir VoicePool::choisirVictime).
    uint64_t ordre() const noexcept { return _ordre; }
    void setOrdre(uint64_t o) noexcept { _ordre = o; }

    /// Empreinte de redondance (Q1c) : FNV-1a du nom du TUYAU (identité du
    /// fichier/ressource de tuyau, pas le libellé du jeu) combiné à la
    /// fréquence du tuyau quantifiée au cent. Calculée au déclenchement.
    /// Deux jeux de même libellé mais de tuyaux différents (Open Diapason 8
    /// III vs I/II : 9,27 dB d'écart mesuré) ne sont donc PAS des doublons.
    uint32_t cleRedondance() const noexcept { return _cleRedondance; }
    int32_t freqCent() const noexcept { return _freqCent; }

    /// Modèle Addsynth du tuyau. Le modèle est unique par ressource de tuyau
    /// dans EngineGlobal (addsynth.cpp, _nameToSynthMap) : comparer ce
    /// pointeur vérifie l'identité EXACTE du tuyau, indépendamment de la clé
    /// de hachage. I et II partagent `I_principal_8` ; III utilise
    /// `III_principal_8`, donc un pointeur différent.
    const Addsynth* modeleRedondance() const noexcept { return _modeleRedondance; }

private:
    Engine& _engine;
    Pipewave::State _state; ///< Pipe state associated with this voice.

    /// Index of the stop associated with this voice.
    /// This is used to tell which stops are voiced.
    int _stopIndex;

    float _buffer[SUB_FRAME_LENGTH];

    /// Delay after chiff.
    dsp::DelayLine _delayLine;
    int _delay{};

    /// Attack chiff.
    dsp::Chiff _chiff;

    ///  Voice virtual pan position [0..1] used for multibus output
    float _panPosition;

    /// Stereo spatial modeller.
    dsp::SpatialSource _spatialSource;

    /// Counter to account for the delayed sound before recycling the voice.
    size_t _postReleaseCounter;

    // Réglages de qualité recopiés au déclenchement (R1) : une voix en
    // cours garde sa topologie jusqu'à son recyclage.
    int _qualiteSpatialisation{2};
    bool _qualiteBruitAttaque{true};
    bool _qualiteInstabilite{true};

    /// Gains gauche/droite du chemin simplifié (copiés au déclenchement).
    float _gainL{1.0f};
    float _gainR{1.0f};

    /// Fondu court du vol de voix (1 = pas de fondu).
    float _fadeGain{0.0f};
    float _fadeStep{0.0f};

    /// Voix libérée par un vol du plafond, en attente de recyclage.
    bool _volee{false};

    /// Déclenchée mais pas encore passée dans process().
    bool _neuve{false};

    /// Index dans le registre des voix prises du pool (-1 = non enregistrée).
    int _poolSlot{-1};

    /// Numéro d'ordre croissant attribué à l'enregistrement dans le pool.
    /// Sert au vol de voix : la plus ancienne = plus petit numéro, sans
    /// dépendre de l'ordre physique du vecteur (modifié par les retraits).
    uint64_t _ordre{0};

    /// Division propriétaire (pour détacher la voix lors d'une réutilisation
    /// forcée quand le pool physique est saturé).
    Division* _proprietaire{nullptr};

    /// Clé de redondance précalculée au déclenchement (Q1c).
    uint32_t _cleRedondance{0};
    /// Fréquence du tuyau quantifiée au cent (1200·log2(f/440), arrondi).
    int32_t _freqCent{0};
    /// Modèle du tuyau : identité exacte du tuyau entre divisions.
    const Addsynth* _modeleRedondance{nullptr};

public:
    Division* proprietaire() const noexcept { return _proprietaire; }
    void setProprietaire(Division* d) noexcept { _proprietaire = d; }
};

//==============================================================================

/**
 * @brief A collection of all the voices.
 */
class VoicePool final
{
public:
    constexpr static int DefaultMaxVoices = 512;

    VoicePool(Engine& engine, int maxVoices = DefaultMaxVoices);

    Voice* trigger(const Pipewave::State& state);
    void resetAndReturnToPool(Voice* voice);

    int getNumberOfActiveVoices() const noexcept { return _voiceCount; }

    /// Nombre de voix tenues (enveloppe Attack) : c'est la grandeur bornée
    /// par le plafond de polyphonie (les voix en release ne comptent pas).
    int getNumberOfHeldVoices() const noexcept;

    /// Vrai si au moins une voix tenue joue cette note (diagnostic).
    bool hasHeldVoiceForNote(int note) const noexcept;

    /// Choix de victime exposé pour la mesure de coût des tests (Q1c).
    /// Aucune allocation : réutilise la table fixe du pool.
    Voice* choisirVictimePourMesure() noexcept { return choisirVictime(); }

private:

    /// Entrée de la table à adressage ouvert du choix de victime (Q1c).
    /// `modele` et `freqCent` servent à distinguer deux clés de hachage
    /// identiques : une collision ne doit jamais fusionner deux jeux.
    struct EntreeRedondance
    {
        uint32_t cle;
        int32_t freqCent;
        const Addsynth* modele;     ///< Représentant du groupe (tuyau exact).
        const Division* division;
        uint16_t compte;
        bool occupe;
        bool melange;   ///< Au moins deux divisions distinctes dans le groupe.
    };

    /// Taille fixe, puissance de deux, > 2 × DefaultMaxVoices : le sondage
    /// linéaire s'arrête toujours avant de boucler, sans allocation.
    constexpr static int TailleTableRedondance = 2048;

    void enregistrer(Voice* voice);
    void desenregistrer(Voice* voice);
    Voice* choisirVictime() noexcept;

    Engine& _engine;

    std::vector<Voice> _voices;     ///< All the voices.
    List<Voice> _idleVoices;        ///< Voices available to be triggered.
    std::vector<Voice*> _registre;  ///< Voix prises (ordre physique quelconque).
    uint64_t _prochainOrdre{1};     ///< Compteur d'ordre d'activation.
    std::atomic<int> _voiceCount;   ///< Number of taken voices.

    /// Table fixe du choix de victime (Q1c), allouée une seule fois.
    std::vector<EntreeRedondance> _tableRedondance;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(VoicePool)
};

AEOLUS_NAMESPACE_END
