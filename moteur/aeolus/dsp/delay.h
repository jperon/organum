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

#include <vector>

AEOLUS_NAMESPACE_BEGIN

namespace dsp {

// Reduction modulo _buffer.size() de i de type size_t. L'implementation
// d'origine calculait (i % size) ; le resultat est identique pour tout i,
// mais on evite la division dans le cas courant i < 2 * size.
static inline size_t wrapDelayIndex(size_t i, size_t size) noexcept
{
    if (i < size)
        return i;
    const size_t j = i - size;
    if (j < size)
        return j;
    return i % size;
}

/**
* @brief Delay line with samples linear interpolation.
*/
class DelayLine
{
public:

    DelayLine(size_t size = 1024);
    void resize(size_t size);
    void reset();
    void write(float x)
    {
        if (_writeIndex == 0)
            _writeIndex = _buffer.size() - 1;
        else
            --_writeIndex;

        _buffer[_writeIndex] = x;
    }

    float read(float delay) const
    {
        int index = (int)std::floor(delay);
        float frac = delay - (float)index;

        index = (int) wrapDelayIndex((size_t) index + _writeIndex, _buffer.size());
        const auto a = _buffer[index];
        const auto b = index < _buffer.size() - 1 ? _buffer[index + 1] : _buffer[0];

        return math::lerp(a, b, frac);
    }

    float readNearest(int delay) const
    {
        const int index{ int (wrapDelayIndex((size_t) delay + _writeIndex, _buffer.size())) };
        return _buffer[index];
    }

    size_t size() const { return _buffer.size(); }

    // Acces direct pour le traitement par blocs de SpatialSource.
    float* bufferData() noexcept { return _buffer.data(); }
    const float* bufferData() const noexcept { return _buffer.data(); }
    size_t writeIndex() const noexcept { return _writeIndex; }
    void setWriteIndex(size_t i) noexcept { _writeIndex = i; }

private:
    std::vector<float> _buffer;
    size_t _writeIndex;
};


} // namespace dsp

AEOLUS_NAMESPACE_END
