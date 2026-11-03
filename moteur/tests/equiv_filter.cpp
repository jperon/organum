// Equivalence bit a bit BiquadFilter::tick (inline) contre l'original.
#include "aeolus/dsp/filter.h"

#include <cstdio>
#include <cstring>
#include <cstdint>

AEOLUS_USING_NAMESPACE

namespace ancien {

struct BiquadFilter
{
    struct Spec { int type; float sampleRate, freq, q, dbGain; float a[3]; float b[4]; };
    struct State { float x[2]; float y[2]; };

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

} // namespace ancien

static uint64_t rngState = 0x9e3779b97f4a7c15ULL;
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
    if ((r & 15) == 0) {
        uint32_t bits = r & 0x807fffffu;
        float f;
        std::memcpy(&f, &bits, 4);
        return f;
    }
    if ((r & 15) == 1)
        return 0.0f;
    // valeurs finies dans [-8, 8], dont petits flottants
    return (float)(int32_t)r * (1.0f / 268435456.0f);
}

int main()
{
    uint64_t echecs = 0, essais = 0;

    for (int trial = 0; trial < 1000; ++trial) {
        dsp::BiquadFilter::Spec sn;
        ancien::BiquadFilter::Spec so;
        dsp::BiquadFilter::State stn;
        ancien::BiquadFilter::State sto;

        std::memset(&sn, 0, sizeof(sn));
        std::memset(&stn, 0, sizeof(stn));
        for (int k = 0; k < 3; ++k) sn.a[k] = rndFloat();
        for (int k = 0; k < 4; ++k) sn.b[k] = rndFloat();
        for (int k = 0; k < 2; ++k) { sn.a[k] = rndFloat(); }
        stn.x[0] = rndFloat(); stn.x[1] = rndFloat();
        stn.y[0] = rndFloat(); stn.y[1] = rndFloat();

        std::memcpy(&so, &sn, sizeof(sn));
        sto.x[0] = stn.x[0]; sto.x[1] = stn.x[1];
        sto.y[0] = stn.y[0]; sto.y[1] = stn.y[1];

        for (int i = 0; i < 1000; ++i) {
            const float x = rndFloat();
            const float a = ancien::BiquadFilter::tick(so, sto, x);
            const float b = dsp::BiquadFilter::tick(sn, stn, x);
            ++essais;
            if (std::memcmp(&a, &b, sizeof(float)) != 0
                || std::memcmp(&stn.x, &sto.x, sizeof(stn.x)) != 0
                || std::memcmp(&stn.y, &sto.y, sizeof(stn.y)) != 0) {
                std::printf("ECHEC essai %llu : %a vs %a\n",
                            (unsigned long long)essais, (double)a, (double)b);
                ++echecs;
                if (echecs > 5) return 1;
            }
        }
    }

    std::printf("%llu essais, %llu echecs\n",
                (unsigned long long)essais, (unsigned long long)echecs);
    return echecs == 0 ? 0 : 1;
}
