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


AEOLUS_NAMESPACE_BEGIN

namespace dsp {

/**
 * @brief BiQuad configurable IIR
 */
struct BiquadFilter
{
    enum Type
    {
        LowPass,
        HighPass,
        BandPass,
        Notch,
        AllPass,
        PeakingEq,
        LowShelf,
        HighShelf
    };

    struct Spec
    {
        Type type;
        float sampleRate;
        float freq;
        float q;
        float dbGain;

        float a[3];
        float b[4];
    };

    struct State
    {
        float x[2];
        float y[2];
    };

    static void updateSpec(Spec& spec);
    static void resetState(const Spec& spec, State& state);

    static inline float tick(const Spec& spec, State& state, float in)
    {
        const float x = in;
        const float y = spec.b[0] * x + spec.b[1] * state.x[0] + spec.b[2] * state.x[1]
                        - spec.a[1] * state.y[0] - spec.a[2] * state.y[1];

        state.x[1] = state.x[0];
        state.x[0] = x;
        state.y[1] = state.y[0];
        state.y[0] = y;

        return y;
    }

    static void process(const Spec& spec, State& state, const float* in, float* out, size_t size);
};

} // namespace dsp

AEOLUS_NAMESPACE_END
