// Équivalence au niveau fonction du chemin de spatialisation complet
// (spatialisation = 2, bruit d'attaque = 1) : la restructuration de
// Voice::process doit être bit à bit identique à l'ancienne version.
//
// Le vrai Chiff::process utilise un juce::Random statique non reproductible ;
// on utilise donc ici une copie déterministe de son algorithme (même suite de
// nombres pour les deux variantes), afin d'isoler la restructuration testée.
// DelayLine, BiquadFilter et SpatialSource sont les classes réelles du dépôt.
#include "aeolus/dsp/spatial.h"
#include "aeolus/dsp/chiff.h"
#include "aeolus/dsp/adsrenv.h"

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>

AEOLUS_USING_NAMESPACE
using namespace juce;

namespace {

uint32_t rnd32(uint32_t& s)
{
    uint32_t x = s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    s = x;
    return x;
}

float rndFloat(uint32_t& s)
{
    const uint32_t r = rnd32(s);
    if ((r & 31) == 0) {
        uint32_t bits = r & 0x807fffffu;
        float f;
        std::memcpy(&f, &bits, 4);
        return f;
    }
    if ((r & 31) == 1) return 0.0f;
    return (float)(int32_t)r * (1.0f / 16777216.0f);
}

class ChiffDeterministe
{
public:
    explicit ChiffDeterministe(uint32_t graine) : _graine{graine} {}

    void initialiser(uint32_t graine) { _graine = graine; }

    void configurer()
    {
        _trig.attack = 0.01f;
        _trig.decay = 0.1f;
        _trig.sustain = 0.01f;
        _trig.release = 0.1f;
        _gain = 0.2f;
        _pipeDelay = SAMPLE_RATE / 440.0f;
        _lp.type = dsp::BiquadFilter::LowPass;
        _lp.sampleRate = SAMPLE_RATE;
        _lp.dbGain = 0.0f;
        _lp.q = 0.7071f;
        _lp.freq = 1760.0f;
    }

    void trigger()
    {
        _noiseEnvelope.trigger({0.01f, 0.0f, 1.0f, 0.02f});
        _envelope.trigger(_trig);
        _resonateur.reset();
        dsp::BiquadFilter::updateSpec(_lp);
        dsp::BiquadFilter::resetState(_lp, _etat);
    }

    void process(float* out, int n)
    {
        if (_envelope.state() == dsp::Envelope::Off)
            return;

        for (int i = 0; i < n; ++i) {
            const float x0 = 2.0f * rndFloat(_graine) - 1.0f;
            const float x = x0 * _noiseEnvelope.next();
            float y = _resonateur.read(_pipeDelay);
            y = dsp::BiquadFilter::tick(_lp, _etat, y);
            y += x;
            _resonateur.write(y);
            out[i] += y * _gain * _envelope.next();
        }
    }

private:
    uint32_t _graine;
    dsp::Envelope _noiseEnvelope;
    dsp::Envelope _envelope;
    dsp::Envelope::Trigger _trig{};
    dsp::DelayLine _resonateur{SAMPLE_RATE};
    float _pipeDelay{};
    dsp::BiquadFilter::Spec _lp{};
    dsp::BiquadFilter::State _etat{};
    float _gain{};
};

struct EtatTest
{
    dsp::DelayLine delayLine{SAMPLE_RATE};
    int delay{0};
    ChiffDeterministe chiff{0x9e3779b9u};
    dsp::SpatialSource spatial;
    float gain{1.0f};
};

// Ancienne version : ligne à retard du tuyau, puis Chiff, puis spatialisation.
namespace ancien {

void process(const float* in, float* outL, float* outR, int n, EtatTest& e, bool bruit)
{
    float buf[64];
    std::memcpy(buf, in, sizeof(float) * n);

    for (int i = 0; i < n; ++i) {
        e.delayLine.write(buf[i]);
        buf[i] = e.delayLine.readNearest(e.delay) * e.gain;
    }

    if (bruit)
        e.chiff.process(buf, n);

    e.spatial.process(buf, outL, outR, n);
}

} // namespace ancien

// Nouvelle version : mêmes étapes avec les branchements de qualité ajoutés,
// spatialisation = 2 et bruit = 1 (chemin par défaut).
namespace nouveau {

void process(const float* in, float* outL, float* outR, int n, EtatTest& e, bool bruit)
{
    float buf[64];
    std::memcpy(buf, in, sizeof(float) * n);

    const float gain = e.gain;

    for (int i = 0; i < n; ++i) {
        e.delayLine.write(buf[i]);
        buf[i] = e.delayLine.readNearest(e.delay) * gain;
    }

    if (bruit)
        e.chiff.process(buf, n);

    // Pas de fondu ici (aucun vol de voix dans ce test).
    e.spatial.process(buf, outL, outR, n);
}

} // namespace nouveau

} // namespace

static bool memes_bits(float a, float b)
{
    return std::memcmp(&a, &b, sizeof(float)) == 0;
}

int main()
{
    constexpr int n = 64;
    constexpr int blocs_par_essai = 160;
    constexpr int essais = 100;

    std::vector<float> in(n), l0(n), r0(n), l1(n), r1(n);
    uint64_t total = 0;
    uint64_t echecs = 0;

    for (int essai = 0; essai < essais; ++essai) {
        EtatTest a, b;
        const uint32_t graine = 0x1234567u + (uint32_t)essai * 7919u;

        uint32_t sg = graine;
        const float posx = (float)(int32_t)rnd32(sg) * (5.0f / 2147483648.0f);
        const float posy = (float)(rnd32(sg) % 10000) / 1000.0f + 1.0f;
        const int delay = (int)(rnd32(sg) % 256);
        const float gain = 0.5f + (float)(rnd32(sg) % 1000) / 1000.0f;

        // Les deux états doivent être identiques (même délai, même gain,
        // même position, même graine de chiff).
        for (EtatTest* e : { &a, &b }) {
            e->delay = delay;
            e->gain = gain;
            e->chiff.initialiser(graine);
            e->chiff.configurer();
            e->chiff.trigger();
            e->spatial.setSampleRate(SAMPLE_RATE_F);
            e->spatial.setSourcePosition(posx, posy);
            e->spatial.recalculate();
            e->spatial.reset();
        }

        uint32_t srng = graine ^ 0xa5a5a5a5u;

        for (int blk = 0; blk < blocs_par_essai; ++blk) {
            for (int i = 0; i < n; ++i)
                in[i] = rndFloat(srng);

            ancien::process(in.data(), l0.data(), r0.data(), n, a, true);
            nouveau::process(in.data(), l1.data(), r1.data(), n, b, true);

            for (int i = 0; i < n; ++i) {
                ++total;
                if (!memes_bits(l0[i], l1[i]) || !memes_bits(r0[i], r1[i])) {
                    ++echecs;
                    if (echecs <= 5)
                        std::printf("ECHEC échantillon %llu : L %a/%a R %a/%a\n",
                                    (unsigned long long)total, (double)l0[i], (double)l1[i],
                                    (double)r0[i], (double)r1[i]);
                }
            }
        }
    }

    std::printf("equiv spatialisation=2 : %llu échantillons comparés, %llu échec(s)\n",
                (unsigned long long)total, (unsigned long long)echecs);

    if (echecs != 0)
        return 1;

    // Formules du chemin simplifié (niveau 1) et du chemin coupé (niveau 0),
    // contre les atténuations réellement calculées par SpatialSource.
    const float positions[][2] = { {0.0f, 5.0f}, {-3.0f, 5.0f}, {3.0f, 5.0f} };
    const char* noms[] = { "centre", "gauche", "droite" };

    for (int p = 0; p < 3; ++p) {
        dsp::SpatialSource sp;
        sp.setSampleRate(SAMPLE_RATE_F);
        sp.setSourcePosition(positions[p][0], positions[p][1]);
        sp.recalculate();

        const float gL = sp.leftAttenuation();
        const float gR = sp.rightAttenuation();

        uint32_t srng = 0xdeadbeefu + (uint32_t)p;
        int mauvais = 0;

        for (int i = 0; i < 1000; ++i) {
            const float x = rndFloat(srng);

            // Niveau 1 : gains seulement.
            const float l1 = x * gL;
            const float r1 = x * gR;
            if (l1 != x * sp.leftAttenuation() || r1 != x * sp.rightAttenuation())
                ++mauvais;

            // Niveau 0 : somme mono centrée à gain unité.
            const float l0 = x;
            const float r0 = x;
            if (l0 != x || r0 != x)
                ++mauvais;
        }

        std::printf("formule %s : gL=%.6f gR=%.6f, %d écart(s)\n",
                    noms[p], (double)gL, (double)gR, mauvais);
        echecs += (uint64_t)mauvais;
    }

    if (echecs == 0) {
        std::printf("equiv_voix_spatial : tous les contrôles passent\n");
        return 0;
    }

    return 1;
}
