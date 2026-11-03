// Equivalence bit a bit DelayLine::read/readNearest (nouveau) contre la copie
// de l'implementation d'origine (namespace ancien).
#include "aeolus/dsp/delay.h"

#include <cstdio>
#include <cstring>
#include <cmath>
#include <cstdint>
#include <vector>
#include <cstdlib>

AEOLUS_USING_NAMESPACE

namespace ancien {

class DelayLine
{
public:
    DelayLine(size_t size = 1024) : _buffer(size, 0.0f), _writeIndex(0) {}
    void reset()
    {
        _writeIndex = 0;
        ::memset(_buffer.data(), 0, sizeof(float) * _buffer.size());
    }
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
        index = (index + _writeIndex) % (int) _buffer.size();
        const auto a = _buffer[index];
        const auto b = index < _buffer.size() - 1 ? _buffer[index + 1] : _buffer[0];
        return aeolus::math::lerp(a, b, frac);
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

} // namespace ancien

static uint64_t rngState = 0x123456789abcdefULL;
static uint32_t rnd32()
{
    uint64_t x = rngState;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    rngState = x;
    return (uint32_t)(x >> 32);
}
static float rndFloat()
{
    // melange valeurs normales, petites, denormales, zero et exactes
    uint32_t r = rnd32();
    if ((r & 7) == 0) {
        uint32_t bits = r & 0x807fffffu; // signe + mantisse, exposant 0 => denormaux
        float f;
        std::memcpy(&f, &bits, 4);
        return f;
    }
    if ((r & 7) == 1)
        return 0.0f;
    return (float)(int32_t)r * (1.0f / 16777216.0f) + (r & 1 ? 0.5f : -0.5f);
}

static int compare(const char* what, size_t sz, int delay, float a, float b)
{
    if (std::memcmp(&a, &b, sizeof(float)) != 0) {
        std::printf("ECHEC %s size=%zu delay=%d ancien=%a nouveau=%a\n", what, sz, delay, (double)a, (double)b);
        return 1;
    }
    return 0;
}

int main()
{
    const size_t sizes[] = {1, 2, 3, 441, 1023, 1024, 1103, 4096, 8191};
    uint64_t echecs = 0, essais = 0;
    uint64_t checksum = 0;

    for (size_t sz : sizes) {
        dsp::DelayLine nouveau(sz);
        ancien::DelayLine vieux(sz);
        nouveau.reset();
        vieux.reset();

        for (int step = 0; step < 60000; ++step) {
            const float x = rndFloat();
            nouveau.write(x);
            vieux.write(x);

            // delais varies : 0, size-1, size, >= size, negatifs, aleatoires
            int delays[8];
            delays[0] = 0;
            delays[1] = (int)sz - 1;
            delays[2] = (int)sz;
            delays[3] = (int)sz + 1;
            delays[4] = (int)(rnd32() % (uint32_t)(2 * sz + 7));
            delays[5] = -(int)(rnd32() % (uint32_t)(2 * sz + 7));
            delays[6] = (int)(rnd32() % (uint32_t)sz);
            delays[7] = (int)(rnd32() & 0x7fffffff);

            for (int k = 0; k < 8; ++k) {
                const int d = delays[k];
                const float a = vieux.readNearest(d);
                const float b = nouveau.readNearest(d);
                ++essais;
                echecs += compare("readNearest", sz, d, a, b);
                float fb;
                std::memcpy(&fb, &a, 4);
                checksum += (uint64_t)(uint32_t)(b != 0.0f);
            }

            // read(float) : delai fractionnaire positif/negatif et entier
            for (int k = 0; k < 8; ++k) {
                float fd;
                if (k == 0) fd = 0.0f;
                else if (k == 1) fd = (float)(sz - 1);
                else if (k == 2) fd = (float)sz;
                else if (k == 3) fd = (float)sz + 0.5f;
                else if (k == 4) fd = -(float)(rnd32() % 1000);
                else fd = (float)(rnd32() % (uint32_t)(2 * sz + 7)) + (rnd32() & 255) / 256.0f;
                const float a = vieux.read(fd);
                const float b = nouveau.read(fd);
                ++essais;
                echecs += compare("read", sz, (int)fd, a, b);
            }
        }
    }

    std::printf("%llu essais, %llu echecs (checksum %llu)\n",
                (unsigned long long)essais, (unsigned long long)echecs,
                (unsigned long long)checksum);
    return echecs == 0 ? 0 : 1;
}
