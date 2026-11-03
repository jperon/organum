// Équivalence des variantes SIMD de aeolus/simd.cpp.
//
// 1. La variante no_simd réécrite est comparée BIT À BIT à une copie textuelle
//    de l'ancienne implémentation (namespace ancien), sur > 1 000 000 de
//    valeurs pseudo-aléatoires déterministes (xorshift, jamais juce::Random).
// 2. Chaque variante SIMD (sse, sse::fma, avx, avx::fma) est comparée à
//    no_simd ; l'écart relatif maximal est mesuré et doit rester <= 1e-5.
// 3. Lancé avec ORGANUM_SIMD=0, le test vérifie que le dispatch a bien
//    conservé les pointeurs no_simd et que fft_step() passe par celui-ci.
//
// Compilation : sh mkcharge.sh <moteur> <sortie> tests/equiv_simd.cpp

#include <JuceHeader.h>
#include "aeolus/simd.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <cmath>
#include <cstdint>
#include <algorithm>

// ---------------------------------------------------------------------------
// Déclarations des fonctions internes de simd.cpp (liaison externe).
// ---------------------------------------------------------------------------

namespace aeolus {

namespace no_simd {
    void  add(float*, const float*, size_t);
    void  mul_const_add(float*, const float*, const float, size_t);
    void  add_mul_const(float*, const float*, const float, size_t);
    void  mul_const(float*, const float, size_t);
    float mul_reduce(const float*, const float*, size_t);
    void  complex_mul(float*, const float*, const float*, size_t);
    void  complex_mul_conj(float*, const float*, const float*, size_t);
    void  fft_step(float*, const float*, size_t);
}

namespace sse {
    void  add(float*, const float*, size_t);
    void  mul_const_add(float*, const float*, const float, size_t);
    void  add_mul_const(float*, const float*, const float, size_t);
    void  mul_const(float*, const float, size_t);
    float mul_reduce(const float*, const float*, size_t);
    float mul_reduce_unaligned(const float*, const float*, size_t);
    void  complex_mul(float*, const float*, const float*, size_t);
    void  complex_mul_conj(float*, const float*, const float*, size_t);
    void  fft_step(float*, const float*, size_t);
    namespace fma {
        void  mul_const_add(float*, const float*, const float, size_t);
        float mul_reduce(const float*, const float*, size_t);
        float mul_reduce_unaligned(const float*, const float*, size_t);
        void  complex_mul(float*, const float*, const float*, size_t);
        void  complex_mul_conj(float*, const float*, const float*, size_t);
        void  fft_step(float*, const float*, size_t);
    }
}

namespace avx {
    void  add(float*, const float*, size_t);
    void  mul_const_add(float*, const float*, const float, size_t);
    void  add_mul_const(float*, const float*, const float, size_t);
    void  mul_const(float*, const float, size_t);
    float mul_reduce(const float*, const float*, size_t);
    float mul_reduce_unaligned(const float*, const float*, size_t);
    void  complex_mul(float*, const float*, const float*, size_t);
    void  complex_mul_conj(float*, const float*, const float*, size_t);
    void  fft_step(float*, const float*, size_t);
    namespace fma {
        void  mul_const_add(float*, const float*, const float, size_t);
        float mul_reduce(const float*, const float*, size_t);
        float mul_reduce_unaligned(const float*, const float*, size_t);
        void  complex_mul(float*, const float*, const float*, size_t);
        void  complex_mul_conj(float*, const float*, const float*, size_t);
        void  fft_step(float*, const float*, size_t);
    }
}

} // namespace aeolus

// ---------------------------------------------------------------------------
// Copie textuelle des anciennes fonctions no_simd (wt/H/moteur/aeolus/simd.cpp
// lignes 105-168) : sert de témoin bit à bit.
// ---------------------------------------------------------------------------

namespace ancien {

    void add(float* out, const float* in, size_t size)
    {
        for (size_t i = 0; i < size; ++i)
            out[i] += in[i];
    }

    void mul_const_add(float* out, const float* in, const float k, size_t size)
    {
        for (size_t i = 0; i < size; ++i)
            out[i] += in[i] * k;
    }

    void add_mul_const(float* out, const float* in, const float k, size_t size)
    {
        for (size_t i = 0; i < size; ++i)
            out[i] = k * (out[i] + in[i]);
    }

    void mul_const(float* out, const float k, size_t size)
    {
        for (size_t i = 0; i < size; ++i)
            out[i] *= k;
    }

    float mul_reduce(const float* x, const float* y, size_t size)
    {
        float sum = 0.0f;
        for (size_t i = 0; i < size; ++i)
            sum += x[i] * y[i];
        return sum;
    }

    void complex_mul(float* res, const float* a, const float* b, size_t size)
    {
        for (size_t i = 0; i < size; i += 2) {
            res[i] = a[i] * b[i] - a[i + 1] * b[i + 1];
            res[i + 1] = a[i] * b[i + 1] + a[i + 1] * b[i];
        }
    }

    void complex_mul_conj(float* res, const float* a, const float* b, size_t size)
    {
        for (size_t i = 0; i < size; i += 2) {
            const float x = a[i] * b[i] - a[i + 1] * b[i + 1];
            const float y = -a[i] * b[i + 1] - a[i + 1] * b[i];
            res[i] = x;
            res[i + 1] = y;
        }
    }

    void fft_step(float* data, const float* w, size_t n)
    {
        for (unsigned i = 0; i < n; i += 2) {
            const float tempr = data[i + n] * w[i] - data[i + n + 1] * w[i + 1];
            const float tempi = data[i + n] * w[i + 1] + data[i + n + 1] * w[i];
            data[i + n] = data[i] - tempr;
            data[i + n + 1] = data[i + 1] - tempi;
            data[i] += tempr;
            data[i + 1] += tempi;
        }
    }

} // namespace ancien

// ---------------------------------------------------------------------------
// Générateur déterministe (xorshift64*) et tableaux alignés.
// ---------------------------------------------------------------------------

static uint64_t g_state = 0x9e3779b97f4a7c15ULL;

static uint64_t xs64()
{
    uint64_t x = g_state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    g_state = x;
    return x * 0x2545f4914f6cdd1dULL;
}

static float xs_float()
{
    uint64_t r = xs64();
    // Valeurs dans [-1, 1), avec zéros et subnormaux injectés régulièrement.
    if ((r & 0x1f) == 0)
        return 0.0f;
    if ((r & 0x3f) == 1)
        return std::ldexp((r & 1) ? 1.0f : -1.0f, -140);
    const int32_t mant = (int32_t)((r >> 8) & 0xffffff);
    const float m = (float)mant / 8388608.0f;   // [-1, 1)
    return m;
}

static void fill(float* p, size_t n)
{
    for (size_t i = 0; i < n; ++i)
        p[i] = xs_float();
}

static const size_t MAXN = 8192;

alignas(64) static float bufA[MAXN];
alignas(64) static float bufB[MAXN];
alignas(64) static float bufC[MAXN];
alignas(64) static float out1[MAXN];
alignas(64) static float out2[MAXN];
alignas(64) static float old1[MAXN];
alignas(64) static float old2[MAXN];

// ---------------------------------------------------------------------------
// Mesure d'erreur.
// ---------------------------------------------------------------------------

struct EquivResult
{
    double max_rel;
    uint64_t compared;
};

static double max_abs(const float* p, size_t n)
{
    double m = 0.0;
    for (size_t i = 0; i < n; ++i)
        m = std::max(m, (double)std::fabs(p[i]));
    return m;
}

// Erreur relative par élément, avec un plancher proportionnel à l'amplitude
// du signal pour ne pas diviser par un bruit numérique négligeable.
static double elementwise_max_rel(const float* ref, const float* got, size_t n)
{
    const double amp = std::max(max_abs(ref, n), 1e-30);
    const double floor = 1e-6 * amp;
    double worst = 0.0;
    for (size_t i = 0; i < n; ++i) {
        const double d = std::fabs((double)got[i] - (double)ref[i]);
        const double den = std::max((double)std::fabs(ref[i]), floor);
        worst = std::max(worst, d / den);
    }
    return worst;
}

static double scalar_max_rel(double ref, double got)
{
    const double den = std::max(std::fabs(ref), 1e-30);
    return std::fabs(got - ref) / den;
}

static bool g_fail = false;

static void report(const char* what, const EquivResult& r, double limit = 1e-5)
{
    const bool ok = r.max_rel <= limit;
    std::printf("%-42s  n=%10llu  ecart_rel_max=%.3e  %s\n",
                what, (unsigned long long)r.compared, r.max_rel,
                ok ? "OK" : "ECHEC");
    if (!ok)
        g_fail = true;
}

// ---------------------------------------------------------------------------
// Comparaisons de familles de fonctions.
// ---------------------------------------------------------------------------

typedef void (*BinFn)(float*, const float*, size_t);
typedef void (*ConstFn)(float*, const float*, const float, size_t);
typedef void (*MulConstFn)(float*, const float, size_t);
typedef void (*ComplexFn)(float*, const float*, const float*, size_t);
typedef float (*ReduceFn)(const float*, const float*, size_t);

static const size_t sizes4[] = { 0, 4, 8, 12, 16, 20, 40, 72, 440, 1104, 4096 };
static const size_t sizes8[] = { 0, 8, 16, 24, 32, 40, 72, 440, 1104, 4096 };

template <typename Fn>
static size_t iterations_for(size_t n)
{
    if (n == 0) return 1;
    return (size_t)(1000000 / n) + 1;
}

static EquivResult check_binary(const char* name, BinFn ref, BinFn simd,
                           const size_t* sizes, size_t nsizes)
{
    EquivResult r{0.0, 0};
    for (size_t si = 0; si < nsizes; ++si) {
        const size_t n = sizes[si];
        const size_t iters = iterations_for<void>(n);
        for (size_t it = 0; it < iters; ++it) {
            fill(bufA, n);
            fill(bufB, n);
            std::memcpy(out1, bufA, n * sizeof(float));
            std::memcpy(out2, bufA, n * sizeof(float));
            ref(out1, bufB, n);
            simd(out2, bufB, n);
            r.max_rel = std::max(r.max_rel, elementwise_max_rel(out1, out2, n));
            r.compared += n;
        }
    }
    (void)name;
    return r;
}

static EquivResult check_const(const char* name, ConstFn ref, ConstFn simd,
                          const size_t* sizes, size_t nsizes)
{
    EquivResult r{0.0, 0};
    for (size_t si = 0; si < nsizes; ++si) {
        const size_t n = sizes[si];
        const size_t iters = iterations_for<void>(n);
        for (size_t it = 0; it < iters; ++it) {
            const float k = xs_float() * 3.0f + 0.25f;
            fill(bufA, n);
            fill(bufB, n);
            std::memcpy(out1, bufA, n * sizeof(float));
            std::memcpy(out2, bufA, n * sizeof(float));
            ref(out1, bufB, k, n);
            simd(out2, bufB, k, n);
            r.max_rel = std::max(r.max_rel, elementwise_max_rel(out1, out2, n));
            r.compared += n;
        }
    }
    (void)name;
    return r;
}

static EquivResult check_mul_const(const char* name, MulConstFn ref, MulConstFn simd,
                              const size_t* sizes, size_t nsizes)
{
    EquivResult r{0.0, 0};
    for (size_t si = 0; si < nsizes; ++si) {
        const size_t n = sizes[si];
        const size_t iters = iterations_for<void>(n);
        for (size_t it = 0; it < iters; ++it) {
            const float k = xs_float() * 3.0f + 0.25f;
            fill(bufA, n);
            std::memcpy(out1, bufA, n * sizeof(float));
            std::memcpy(out2, bufA, n * sizeof(float));
            ref(out1, k, n);
            simd(out2, k, n);
            r.max_rel = std::max(r.max_rel, elementwise_max_rel(out1, out2, n));
            r.compared += n;
        }
    }
    (void)name;
    return r;
}

static EquivResult check_complex(const char* name, ComplexFn ref, ComplexFn simd,
                            const size_t* sizes, size_t nsizes)
{
    EquivResult r{0.0, 0};
    for (size_t si = 0; si < nsizes; ++si) {
        const size_t n = sizes[si];
        const size_t iters = iterations_for<void>(n);
        for (size_t it = 0; it < iters; ++it) {
            fill(bufA, n);
            fill(bufB, n);
            ref(out1, bufA, bufB, n);
            simd(out2, bufA, bufB, n);
            r.max_rel = std::max(r.max_rel, elementwise_max_rel(out1, out2, n));
            r.compared += n;
        }
    }
    (void)name;
    return r;
}

static EquivResult check_fft(const char* name, BinFn ref, BinFn simd,
                        const size_t* sizes, size_t nsizes)
{
    EquivResult r{0.0, 0};
    for (size_t si = 0; si < nsizes; ++si) {
        const size_t n = sizes[si];
        const size_t total = (n == 0) ? 1 : 2 * n;
        const size_t iters = iterations_for<void>(total);
        for (size_t it = 0; it < iters; ++it) {
            fill(bufA, total);
            fill(bufB, n);
            std::memcpy(out1, bufA, total * sizeof(float));
            std::memcpy(out2, bufA, total * sizeof(float));
            ref(out1, bufB, n);
            simd(out2, bufB, n);
            r.max_rel = std::max(r.max_rel, elementwise_max_rel(out1, out2, total));
            r.compared += total;
        }
    }
    (void)name;
    return r;
}

static EquivResult check_reduce(const char* name, ReduceFn ref, ReduceFn simd,
                           const size_t* sizes, size_t nsizes)
{
    EquivResult r{0.0, 0};
    for (size_t si = 0; si < nsizes; ++si) {
        const size_t n = sizes[si];
        const size_t iters = iterations_for<void>(n);
        for (size_t it = 0; it < iters; ++it) {
            fill(bufA, n);
            fill(bufB, n);
            const double a = ref(bufA, bufB, n);
            const double b = simd(bufA, bufB, n);
            r.max_rel = std::max(r.max_rel, scalar_max_rel(a, b));
            r.compared += n;
        }
    }
    (void)name;
    return r;
}

// Réduction non alignée de référence (même boucle que no_simd::mul_reduce).
static float ref_reduce_unaligned(const float* x, const float* y, size_t size)
{
    float sum = 0.0f;
    for (size_t i = 0; i < size; ++i)
        sum += x[i] * y[i];
    return sum;
}

// Pour les variantes non alignées, les tailles varient librement : on décale
// volontairement les pointeurs pour tester des adresses non alignées.
static EquivResult check_reduce_unaligned(const char* name, ReduceFn simd,
                                     const size_t* sizes, size_t nsizes)
{
    EquivResult r{0.0, 0};
    for (size_t si = 0; si < nsizes; ++si) {
        const size_t n = sizes[si];
        const size_t iters = iterations_for<void>(n);
        for (size_t it = 0; it < iters; ++it) {
            fill(bufA + 1, n);
            fill(bufB + 3, n);
            const double a = ref_reduce_unaligned(bufA + 1, bufB + 3, n);
            const double b = simd(bufA + 1, bufB + 3, n);
            r.max_rel = std::max(r.max_rel, scalar_max_rel(a, b));
            r.compared += n;
        }
    }
    (void)name;
    return r;
}

// ---------------------------------------------------------------------------
// 1. no_simd réécrite == ancienne implémentation, bit à bit.
// ---------------------------------------------------------------------------

static uint64_t g_bitwise = 0;

static void check_same_bits(const char* name, const float* a, const float* b, size_t n)
{
    if (std::memcmp(a, b, n * sizeof(float)) != 0) {
        for (size_t i = 0; i < n; ++i) {
            if (std::memcmp(&a[i], &b[i], sizeof(float)) != 0) {
                std::printf("BITWISE DIFF %s index %zu : %.9g vs %.9g\n",
                            name, i, (double)a[i], (double)b[i]);
                break;
            }
        }
        g_fail = true;
    }
    g_bitwise += n;
}

static const size_t bit_sizes[] = { 4, 8, 12, 16, 40, 440, 1104, 4096 };

static void test_no_simd_identite()
{
    for (size_t si = 0; si < sizeof(bit_sizes)/sizeof(bit_sizes[0]); ++si) {
        const size_t n = bit_sizes[si];
        const size_t iters = iterations_for<void>(n);
        for (size_t it = 0; it < iters; ++it) {
            const float k = xs_float() * 3.0f + 0.25f;
            size_t total = 2 * n;
            fill(bufA, total);
            fill(bufB, n);

            std::memcpy(old1, bufA, total * sizeof(float));
            std::memcpy(old2, bufA, total * sizeof(float));
            ancien::add(old1, bufB, n);      aeolus::no_simd::add(old2, bufB, n);
            check_same_bits("add", old1, old2, n);

            std::memcpy(old1, bufA, total * sizeof(float));
            std::memcpy(old2, bufA, total * sizeof(float));
            ancien::mul_const_add(old1, bufB, k, n); aeolus::no_simd::mul_const_add(old2, bufB, k, n);
            check_same_bits("mul_const_add", old1, old2, n);

            std::memcpy(old1, bufA, total * sizeof(float));
            std::memcpy(old2, bufA, total * sizeof(float));
            ancien::add_mul_const(old1, bufB, k, n); aeolus::no_simd::add_mul_const(old2, bufB, k, n);
            check_same_bits("add_mul_const", old1, old2, n);

            std::memcpy(old1, bufA, total * sizeof(float));
            std::memcpy(old2, bufA, total * sizeof(float));
            ancien::mul_const(old1, k, n); aeolus::no_simd::mul_const(old2, k, n);
            check_same_bits("mul_const", old1, old2, n);

            const float ra = ancien::mul_reduce(bufA, bufB, n);
            const float rb = aeolus::no_simd::mul_reduce(bufA, bufB, n);
            check_same_bits("mul_reduce", &ra, &rb, 1);

            ancien::complex_mul(out1, bufA, bufB, n); aeolus::no_simd::complex_mul(out2, bufA, bufB, n);
            check_same_bits("complex_mul", out1, out2, n);

            ancien::complex_mul_conj(out1, bufA, bufB, n); aeolus::no_simd::complex_mul_conj(out2, bufA, bufB, n);
            check_same_bits("complex_mul_conj", out1, out2, n);

            std::memcpy(out1, bufA, total * sizeof(float));
            std::memcpy(out2, bufA, total * sizeof(float));
            ancien::fft_step(out1, bufB, n); aeolus::no_simd::fft_step(out2, bufB, n);
            check_same_bits("fft_step", out1, out2, total);
        }
    }
    std::printf("no_simd == ancien (bit a bit) : %llu valeurs comparees\n",
                (unsigned long long)g_bitwise);
    if (g_bitwise < 1000000) {
        std::printf("ECHEC : moins de 1 000 000 de valeurs comparees\n");
        g_fail = true;
    }
}

// ---------------------------------------------------------------------------
// Programme principal.
// ---------------------------------------------------------------------------

int main()
{
    const char* tcpu = std::getenv("ORGANUM_TEST_CPU");
    bool has_sse2 = true, has_sse3 = true, has_avx = true, has_fma = true;
    if (tcpu) {
        std::string v = tcpu;
        has_sse2 = (v=="sse2"||v=="sse3"||v=="avx"||v=="avx2fma");
        has_sse3 = (v=="sse3"||v=="avx"||v=="avx2fma");
        has_avx  = (v=="avx"||v=="avx2fma");
        has_fma  = (v=="avx2fma");
    } else {
        auto c = aeolus::CPUTraits::get();
        has_sse2 = c.sse2;
        has_sse3 = c.sse3;
        has_avx  = c.avx;
        has_fma  = c.fma;
    }
    std::printf("== identite no_simd vs ancienne implementation ==\n");
    test_no_simd_identite();

    std::printf("\n== variantes SSE2 / SSE3 vs no_simd ==\n");
    report("sse::add",                    check_binary("add", &aeolus::no_simd::add, &aeolus::sse::add, sizes4, 11));
    report("sse::mul_const_add",          check_const("mul_const_add", &aeolus::no_simd::mul_const_add, &aeolus::sse::mul_const_add, sizes4, 11));
    report("sse::add_mul_const",          check_const("add_mul_const", &aeolus::no_simd::add_mul_const, &aeolus::sse::add_mul_const, sizes4, 11));
    report("sse::mul_const",              check_mul_const("mul_const", &aeolus::no_simd::mul_const, &aeolus::sse::mul_const, sizes4, 11));
    report("sse::complex_mul",            check_complex("complex_mul", &aeolus::no_simd::complex_mul, &aeolus::sse::complex_mul, sizes4, 11));
    report("sse::complex_mul_conj",       check_complex("complex_mul_conj", &aeolus::no_simd::complex_mul_conj, &aeolus::sse::complex_mul_conj, sizes4, 11));
    report("sse::fft_step",               check_fft("fft_step", &aeolus::no_simd::fft_step, &aeolus::sse::fft_step, sizes4, 11));
    if (has_sse3) {
        report("sse::mul_reduce",             check_reduce("mul_reduce", &aeolus::no_simd::mul_reduce, &aeolus::sse::mul_reduce, sizes4, 11));
        report("sse::mul_reduce_unaligned",   check_reduce_unaligned("mul_reduce_unaligned", &aeolus::sse::mul_reduce_unaligned, sizes4, 11));
    } else {
        std::printf("SAUTÉ : sse::mul_reduce (CPU sans sse3)\n");
        std::printf("SAUTÉ : sse::mul_reduce_unaligned (CPU sans sse3)\n");
    }

    std::printf("\n== variantes SSE+FMA vs no_simd ==\n");
    if (has_avx && has_fma) {
        report("sse::fma::mul_const_add",     check_const("mul_const_add", &aeolus::no_simd::mul_const_add, &aeolus::sse::fma::mul_const_add, sizes4, 11));
        report("sse::fma::complex_mul",       check_complex("complex_mul", &aeolus::no_simd::complex_mul, &aeolus::sse::fma::complex_mul, sizes4, 11));
        report("sse::fma::complex_mul_conj",  check_complex("complex_mul_conj", &aeolus::no_simd::complex_mul_conj, &aeolus::sse::fma::complex_mul_conj, sizes4, 11));
        report("sse::fma::fft_step",          check_fft("fft_step", &aeolus::no_simd::fft_step, &aeolus::sse::fma::fft_step, sizes4, 11));
        report("sse::fma::mul_reduce",        check_reduce("mul_reduce", &aeolus::no_simd::mul_reduce, &aeolus::sse::fma::mul_reduce, sizes4, 11));
        report("sse::fma::mul_reduce_unal",   check_reduce_unaligned("mul_reduce_unaligned", &aeolus::sse::fma::mul_reduce_unaligned, sizes4, 11));
    } else {
        const char* niv = has_avx ? "fma" : "avx";
        std::printf("SAUTÉ : sse::fma::mul_const_add (CPU sans %s)\n", niv);
        std::printf("SAUTÉ : sse::fma::complex_mul (CPU sans %s)\n", niv);
        std::printf("SAUTÉ : sse::fma::complex_mul_conj (CPU sans %s)\n", niv);
        std::printf("SAUTÉ : sse::fma::fft_step (CPU sans %s)\n", niv);
        std::printf("SAUTÉ : sse::fma::mul_reduce (CPU sans %s)\n", niv);
        std::printf("SAUTÉ : sse::fma::mul_reduce_unal (CPU sans %s)\n", niv);
    }

    std::printf("\n== variantes AVX vs no_simd ==\n");
    if (has_avx) {
        report("avx::add",                    check_binary("add", &aeolus::no_simd::add, &aeolus::avx::add, sizes8, 10));
        report("avx::mul_const_add",          check_const("mul_const_add", &aeolus::no_simd::mul_const_add, &aeolus::avx::mul_const_add, sizes8, 10));
        report("avx::add_mul_const",          check_const("add_mul_const", &aeolus::no_simd::add_mul_const, &aeolus::avx::add_mul_const, sizes8, 10));
        report("avx::mul_const",              check_mul_const("mul_const", &aeolus::no_simd::mul_const, &aeolus::avx::mul_const, sizes8, 10));
        report("avx::complex_mul",            check_complex("complex_mul", &aeolus::no_simd::complex_mul, &aeolus::avx::complex_mul, sizes8, 10));
        report("avx::complex_mul_conj",       check_complex("complex_mul_conj", &aeolus::no_simd::complex_mul_conj, &aeolus::avx::complex_mul_conj, sizes8, 10));
        report("avx::fft_step",               check_fft("fft_step", &aeolus::no_simd::fft_step, &aeolus::avx::fft_step, sizes8, 10));
        report("avx::mul_reduce",             check_reduce("mul_reduce", &aeolus::no_simd::mul_reduce, &aeolus::avx::mul_reduce, sizes8, 10));
        report("avx::mul_reduce_unaligned",   check_reduce_unaligned("mul_reduce_unaligned", &aeolus::avx::mul_reduce_unaligned, sizes8, 10));
    } else {
        std::printf("SAUTÉ : avx::add (CPU sans avx)\n");
        std::printf("SAUTÉ : avx::mul_const_add (CPU sans avx)\n");
        std::printf("SAUTÉ : avx::add_mul_const (CPU sans avx)\n");
        std::printf("SAUTÉ : avx::mul_const (CPU sans avx)\n");
        std::printf("SAUTÉ : avx::complex_mul (CPU sans avx)\n");
        std::printf("SAUTÉ : avx::complex_mul_conj (CPU sans avx)\n");
        std::printf("SAUTÉ : avx::fft_step (CPU sans avx)\n");
        std::printf("SAUTÉ : avx::mul_reduce (CPU sans avx)\n");
        std::printf("SAUTÉ : avx::mul_reduce_unaligned (CPU sans avx)\n");
    }
    std::printf("\n== variantes AVX+FMA vs no_simd ==\n");
    if (has_avx && has_fma) {
        report("avx::fma::mul_const_add",     check_const("mul_const_add", &aeolus::no_simd::mul_const_add, &aeolus::avx::fma::mul_const_add, sizes8, 10));
        report("avx::fma::complex_mul",       check_complex("complex_mul", &aeolus::no_simd::complex_mul, &aeolus::avx::fma::complex_mul, sizes8, 10));
        report("avx::fma::complex_mul_conj",  check_complex("complex_mul_conj", &aeolus::no_simd::complex_mul_conj, &aeolus::avx::fma::complex_mul_conj, sizes8, 10));
        report("avx::fma::fft_step",          check_fft("fft_step", &aeolus::no_simd::fft_step, &aeolus::avx::fma::fft_step, sizes8, 10));
        report("avx::fma::mul_reduce",        check_reduce("mul_reduce", &aeolus::no_simd::mul_reduce, &aeolus::avx::fma::mul_reduce, sizes8, 10));
        report("avx::fma::mul_reduce_unal",   check_reduce_unaligned("mul_reduce_unaligned", &aeolus::avx::fma::mul_reduce_unaligned, sizes8, 10));
    } else {
        std::printf("SAUTÉ : avx::fma::mul_const_add (CPU sans %s)\n", has_avx ? "fma" : "avx");
        std::printf("SAUTÉ : avx::fma::complex_mul (CPU sans %s)\n", has_avx ? "fma" : "avx");
        std::printf("SAUTÉ : avx::fma::complex_mul_conj (CPU sans %s)\n", has_avx ? "fma" : "avx");
        std::printf("SAUTÉ : avx::fma::fft_step (CPU sans %s)\n", has_avx ? "fma" : "avx");
        std::printf("SAUTÉ : avx::fma::mul_reduce (CPU sans %s)\n", has_avx ? "fma" : "avx");
        std::printf("SAUTÉ : avx::fma::mul_reduce_unal (CPU sans %s)\n", has_avx ? "fma" : "avx");
    }
    // -----------------------------------------------------------------------
    // 3. Repli : ORGANUM_SIMD=0 doit laisser tous les pointeurs sur no_simd.
    // -----------------------------------------------------------------------
    const char* env = std::getenv("ORGANUM_SIMD");
    const bool force_off = env != nullptr && env[0] == '0' && env[1] == '\0';

    std::printf("\n== dispatch (ORGANUM_SIMD=%s) ==\n", env ? env : "(non defini)");
    if (force_off) {
        const bool all_no_simd =
            aeolus::simd::add                  == &aeolus::no_simd::add &&
            aeolus::simd::mul_const_add        == &aeolus::no_simd::mul_const_add &&
            aeolus::simd::add_mul_const        == &aeolus::no_simd::add_mul_const &&
            aeolus::simd::mul_const            == &aeolus::no_simd::mul_const &&
            aeolus::simd::mul_reduce           == &aeolus::no_simd::mul_reduce &&
            aeolus::simd::mul_reduce_unaligned == &aeolus::no_simd::mul_reduce &&
            aeolus::simd::complex_mul          == &aeolus::no_simd::complex_mul &&
            aeolus::simd::complex_mul_conj     == &aeolus::no_simd::complex_mul_conj &&
            aeolus::simd::fft_step             == &aeolus::no_simd::fft_step;
        std::printf("pointeurs tous no_simd : %s\n", all_no_simd ? "OUI" : "NON");
        if (!all_no_simd)
            g_fail = true;

        const size_t n = 1024;
        const size_t total = 2 * n;
        fill(bufA, total);
        fill(bufB, n);
        std::memcpy(out1, bufA, total * sizeof(float));
        std::memcpy(out2, bufA, total * sizeof(float));
        aeolus::no_simd::fft_step(out1, bufB, n);
        aeolus::simd::fft_step(out2, bufB, n);
        const bool same = std::memcmp(out1, out2, total * sizeof(float)) == 0;
        std::printf("fft_step dispatch == no_simd (bit a bit) : %s\n", same ? "OUI" : "NON");
        if (!same)
            g_fail = true;
    } else {
        std::printf("impl. active fft_step : %s\n",
                    aeolus::simd::fft_step == &aeolus::avx::fma::fft_step ? "avx::fma" :
                    aeolus::simd::fft_step == &aeolus::avx::fft_step      ? "avx" :
                    aeolus::simd::fft_step == &aeolus::sse::fma::fft_step ? "sse::fma" :
                    aeolus::simd::fft_step == &aeolus::sse::fft_step      ? "sse" :
                    aeolus::simd::fft_step == &aeolus::no_simd::fft_step  ? "no_simd" : "inconnue");
        std::printf("impl. active mul_reduce_unaligned : %s\n",
                    aeolus::simd::mul_reduce_unaligned == &aeolus::avx::fma::mul_reduce_unaligned ? "avx::fma" :
                    aeolus::simd::mul_reduce_unaligned == &aeolus::avx::mul_reduce_unaligned     ? "avx" :
                    aeolus::simd::mul_reduce_unaligned == &aeolus::sse::fma::mul_reduce_unaligned ? "sse::fma" :
                    aeolus::simd::mul_reduce_unaligned == &aeolus::sse::mul_reduce_unaligned     ? "sse" :
                    aeolus::simd::mul_reduce_unaligned == &aeolus::no_simd::mul_reduce           ? "no_simd" : "inconnue");
    }

    std::printf("\n%s\n", g_fail ? "RESULTAT : ECHEC" : "RESULTAT : OK");
    return g_fail ? 1 : 0;
}
