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

#include "aeolus/dsp/delay.h"

AEOLUS_NAMESPACE_BEGIN

namespace dsp {

DelayLine::DelayLine(size_t size)
    : _buffer(size, 0.0f)
    , _writeIndex(0)
{
}

void DelayLine::resize (size_t size)
{
    _buffer.resize(size);
    reset();
}

void DelayLine::reset()
{
    _writeIndex = 0;
    ::memset(_buffer.data(), 0, sizeof (float) * _buffer.size());
}

} // namespace dsp

AEOLUS_NAMESPACE_END
