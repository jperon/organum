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

    /// Index dans le registre du pool (retrait O(1)).
    int registreSlot() const noexcept { return _poolSlot; }
    void setRegistreSlot(int slot) noexcept { _poolSlot = slot; }

    /// Numéro d'ordre d'activation (voir VoicePool::choisirVictime).
    uint64_t ordre() const noexcept { return _ordre; }
    void setOrdre(uint64_t o) noexcept { _ordre = o; }

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

    /// Index dans le registre des voix prises du pool (-1 = non enregistrée).
    int _poolSlot{-1};

    /// Numéro d'ordre croissant attribué à l'enregistrement dans le pool.
    /// Sert au vol de voix : la plus ancienne = plus petit numéro, sans
    /// dépendre de l'ordre physique du vecteur (modifié par les retraits).
    uint64_t _ordre{0};

    /// Division propriétaire (pour détacher la voix lors d'une réutilisation
    /// forcée quand le pool physique est saturé).
    Division* _proprietaire{nullptr};

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

private:

    void enregistrer(Voice* voice);
    void desenregistrer(Voice* voice);
    Voice* choisirVictime() noexcept;

    Engine& _engine;

    std::vector<Voice> _voices;     ///< All the voices.
    List<Voice> _idleVoices;        ///< Voices available to be triggered.
    std::vector<Voice*> _registre;  ///< Voix prises (ordre physique quelconque).
    uint64_t _prochainOrdre{1};     ///< Compteur d'ordre d'activation.
    std::atomic<int> _voiceCount;   ///< Number of taken voices.

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(VoicePool)
};

AEOLUS_NAMESPACE_END
