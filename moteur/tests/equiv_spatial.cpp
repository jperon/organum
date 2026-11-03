// Equivalence bit a bit SpatialSource::process (nouveau, par blocs) contre
// une copie integrale de l'implementation d'origine (tick() appele par
// echantillon), elle-meme dotee des anciennes DelayLine et BiquadFilter.
#include "aeolus/dsp/spatial.h"

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <vector>
#include <algorithm>

AEOLUS_USING_NAMESPACE
using namespace juce;

namespace ancien {

class DelayLine
{
public:
    DelayLine(size_t size = 1024) : _buffer(size, 0.0f), _writeIndex(0) {}
    void resize(size_t size) { _buffer.resize(size); reset(); }
    void reset() { _writeIndex = 0; ::memset(_buffer.data(), 0, sizeof(float) * _buffer.size()); }
    void write(float x)
    {
        if (_writeIndex == 0) _writeIndex = _buffer.size() - 1;
        else --_writeIndex;
        _buffer[_writeIndex] = x;
    }
    float readNearest(int delay) const
    {
        const int index{ int ((delay + _writeIndex) % _buffer.size()) };
        return _buffer[index];
    }
    size_t size() const { return _buffer.size(); }
private:
    std::vector<float> _buffer;
    size_t _writeIndex;
};

struct BiquadFilter
{
    enum Type { LowPass };
    struct Spec { Type type; float sampleRate, freq, q, dbGain; float a[3]; float b[4]; };
    struct State { float x[2]; float y[2]; };

    static void resetState(const Spec&, State& state) { ::memset(&state, 0, sizeof(state)); }
    static void updateSpec(Spec& spec)
    {
        float A = sqrtf(powf(10.0f, spec.dbGain / 20.0f));
        float w0 = 2.0f * juce::MathConstants<float>::pi * spec.freq / spec.sampleRate;
        float cos_w0 = cos(w0);
        float sin_w0 = sin(w0);
        float alpha = sin_w0 / (2.0f * spec.q);
        spec.b[0] = (1.0f - cos_w0) / 2.0f;
        spec.b[1] = 1.0f - cos_w0;
        spec.b[2] = (1.0f - cos_w0) / 2.0f;
        spec.a[0] = 1.0f + alpha;
        spec.a[1] = -2.0f * cos_w0;
        spec.a[2] = 1.0f - alpha;
        spec.a[1] /= spec.a[0];
        spec.a[2] /= spec.a[0];
        spec.b[0] /= spec.a[0];
        spec.b[1] /= spec.a[0];
        spec.b[2] /= spec.a[0];
        (void)A;
    }
    static float tick(const Spec& spec, State& state, float in)
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
};

class SpatialSource
{
public:
    struct Position
    {
        float x, y;
        void rotate(float a)
        {
            const float c = cosf(a);
            const float s = sinf(a);
            const float x2 = c * x - s * y;
            const float y2 = s * x + s * y;
            x = x2; y = y2;
        }
        float distanceTo(const Position& other) const noexcept
        {
            return sqrt((other.x - x) * (other.x - x) + (other.y - y) * (other.y - y));
        }
        float angleTo(const Position& other) const noexcept
        {
            return atan2f(other.y, other.x) - atan2f(y, x);
        }
    };

    SpatialSource()
        : _sampleRate{SAMPLE_RATE_F}, _sourcePosition{0.0f, 0.0f},
          _listenerPosition{0.0f, 0.0f}, _listenerOrientation{0.0f},
          _listenerLeftRightDistance{0.3f}, _delayLine{}, _leftDelay{},
          _rightDelay{}, _filterSpec{}, _filterState{}
    { recalculate(); }

    void reset()
    {
        _delayLine.reset();
        BiquadFilter::resetState(_filterSpec[0], _filterState[0]);
        BiquadFilter::resetState(_filterSpec[1], _filterState[1]);
    }
    void tick(float x, float& l, float& r)
    {
        _delayLine.write(x);
        l = BiquadFilter::tick(_filterSpec[0], _filterState[0], _delayLine.readNearest(_leftDelay) * _leftAttenuation);
        r = BiquadFilter::tick(_filterSpec[1], _filterState[1], _delayLine.readNearest(_rightDelay) * _rightAttenuation);
    }
    void process(float* in, float* outL, float* outR, int numFrames)
    {
        for (int i = 0; i < numFrames; ++i) tick(in[i], outL[i], outR[i]);
    }
    void setSampleRate(float sr) { _sampleRate = sr; }
    void setSourcePosition(float x, float y) noexcept { _sourcePosition = {x, y}; }
    void setListenerPosition(float x, float y) noexcept { _listenerPosition = {x, y}; }
    size_t getPostFxSamplesCount() const { return _delayLine.size(); }
    void recalculate()
    {
        constexpr float speedOfSound = 330.0f;
        Position left{-0.5f * _listenerLeftRightDistance, 0.0f};
        Position right{0.5f * _listenerLeftRightDistance, 0.0f};
        left.rotate(_listenerOrientation);
        right.rotate(_listenerOrientation);
        Position sourceRelativeToListener{_sourcePosition.x - _listenerPosition.x, _sourcePosition.y - _listenerPosition.y};
        float leftAngle = left.angleTo(sourceRelativeToListener);
        float rightAngle = right.angleTo(sourceRelativeToListener);
        left.x += _listenerPosition.x; left.y += _listenerPosition.y;
        right.x += _listenerPosition.x; right.y += _listenerPosition.y;
        const float leftDistance = _sourcePosition.distanceTo(left);
        const float rightDistance = _sourcePosition.distanceTo(right);
        const float maxDistance = std::max(leftDistance, rightDistance);
        const float maxT = maxDistance / speedOfSound;
        size_t delayLengthInSamples = (size_t)(_sampleRate * maxT + 0.5f);
        _delayLine.resize(delayLengthInSamples);
        _leftDelay = (int) roundf(leftDistance * _sampleRate / speedOfSound);
        _rightDelay = (int) roundf(rightDistance * _sampleRate / speedOfSound);
        constexpr float att = 0.7f;
        _leftAttenuation = 0.5f * att * (cosf(leftAngle) + 1.0f) + 1.0f - att;
        _rightAttenuation = 0.5f * att * (cosf(rightAngle) + 1.0f) + 1.0f - att;
        _filterSpec[0].type = BiquadFilter::LowPass;
        _filterSpec[0].dbGain = 0.0f;
        _filterSpec[0].q = 0.7071f;
        _filterSpec[0].sampleRate = SAMPLE_RATE;
        _filterSpec[1] = _filterSpec[0];
        _filterSpec[0].freq = 22.0e3f * expf(-0.09f * leftDistance);
        _filterSpec[1].freq = 22.0e3f * expf(-0.09f * rightDistance);
        BiquadFilter::updateSpec(_filterSpec[0]);
        BiquadFilter::updateSpec(_filterSpec[1]);
    }
private:
    float _sampleRate;
    Position _sourcePosition, _listenerPosition;
    float _listenerOrientation, _listenerLeftRightDistance;
    DelayLine _delayLine;
    int _leftDelay, _rightDelay;
    float _leftAttenuation, _rightAttenuation;
    BiquadFilter::Spec _filterSpec[2];
    BiquadFilter::State _filterState[2];
};

} // namespace ancien

static uint64_t rngState = 0xd1b54a32d192ed03ULL;
static uint32_t rnd32()
{
    uint64_t x = rngState;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    rngState = x;
    return (uint32_t)(x >> 32);
}
static float rndFloat()
{
    uint32_t r = rnd32();
    if ((r & 31) == 0) {
        uint32_t bits = r & 0x807fffffu;
        float f;
        std::memcpy(&f, &bits, 4);
        return f;
    }
    if ((r & 31) == 1) return 0.0f;
    return (float)(int32_t)r * (1.0f / 16777216.0f);
}

int main()
{
    const int n = 64;
    std::vector<float> in(n), l0(n), r0(n), l1(n), r1(n);
    uint64_t essais = 0, echecs = 0;

    for (int trial = 0; trial < 200; ++trial) {
        dsp::SpatialSource nouveau;
        ancien::SpatialSource vieux;

        const float sx = (float)(int32_t)rnd32() * (20.0f / 2147483648.0f);
        const float sy = (float)(rnd32() % 20000) / 1000.0f + 0.5f;
        nouveau.setSampleRate(SAMPLE_RATE_F);
        vieux.setSampleRate(SAMPLE_RATE_F);
        nouveau.setSourcePosition(sx, sy);
        vieux.setSourcePosition(sx, sy);
        nouveau.recalculate();
        vieux.recalculate();
        nouveau.reset();
        vieux.reset();

        if (nouveau.getPostFxSamplesCount() != vieux.getPostFxSamplesCount()) {
            std::printf("ECHEC taille delay %zu vs %zu\n",
                        nouveau.getPostFxSamplesCount(), vieux.getPostFxSamplesCount());
            return 1;
        }

        for (int blk = 0; blk < 100; ++blk) {
            for (int i = 0; i < n; ++i) in[i] = rndFloat();
            vieux.process(in.data(), l0.data(), r0.data(), n);
            nouveau.process(in.data(), l1.data(), r1.data(), n);
            for (int i = 0; i < n; ++i) {
                ++essais;
                if (std::memcmp(&l0[i], &l1[i], sizeof(float)) != 0
                    || std::memcmp(&r0[i], &r1[i], sizeof(float)) != 0) {
                    std::printf("ECHEC essai %llu : L %a/%a R %a/%a\n",
                                (unsigned long long)essais, (double)l0[i], (double)l1[i],
                                (double)r0[i], (double)r1[i]);
                    ++echecs;
                    if (echecs > 5) return 1;
                }
            }
        }
    }

    std::printf("%llu echantillons stereo, %llu echecs\n",
                (unsigned long long)essais, (unsigned long long)echecs);
    return echecs == 0 ? 0 : 1;
}
