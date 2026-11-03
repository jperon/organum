#include <JuceHeader.h>
#include "aeolus_c.h"

#include <vector>
#include <cmath>
#include <cstdio>
#include <algorithm>
#include <ctime>

static double ms(struct timespec t0, struct timespec t1)
{
    return (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
}

static void mesurer(void* moteur, const char* label, int n, double deadline)
{
    std::vector<float> L(n, 0.0f), R(n, 0.0f);

    // warmup
    for (int i = 0; i < 50; ++i)
        aeolus_rendre(moteur, L.data(), R.data(), n);

    std::vector<double> times(1000);
    for (int i = 0; i < 1000; ++i) {
        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        aeolus_rendre(moteur, L.data(), R.data(), n);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        times[i] = ms(t0, t1);
    }

    std::sort(times.begin(), times.end());
    double sum = 0;
    for (double t : times) sum += t;
    double mean = sum / 1000.0;
    double median = (times[499] + times[500]) / 2.0;

    std::printf("%s : moy=%.3f ms med=%.3f ms  (%.1f%% ech.)\n",
                label, mean, median, mean / deadline * 100.0);
}

int main()
{
    const int sr = 48000;
    const int n = 1024;
    const double deadline = 1024.0 / 48000.0 * 1000.0;
    const int notes[] = {36,43,48,52,55,60,64,67,72,76};

    const int tetes[] = {1, 0};
    const char* labels[] = {"tete ON ", "tete OFF"};

    for (int s = 0; s < 2; ++s) {
        void* moteur = aeolus_creer(sr);
        if (!moteur) { std::fprintf(stderr, "aeolus_creer failed\n"); return 1; }

        aeolus_reverb_tete(moteur, tetes[s]);

        int nd = aeolus_nb_divisions(moteur);
        for (int d = 0; d < nd; ++d) {
            int nj = aeolus_nb_jeux(moteur, d);
            for (int j = 0; j < nj; ++j) aeolus_jeu(moteur, d, j, 1);
        }

        for (int c = 0; c < 3; ++c) {
            for (int ni = 0; ni < 10; ++ni) {
                unsigned char on[3] = { (unsigned char)(0x90 | c), (unsigned char)notes[ni], 100 };
                aeolus_midi(moteur, on, 3);
            }
        }

        aeolus_reverb(moteur, 0.25f);

        mesurer(moteur, labels[s], n, deadline);

        aeolus_detruire(moteur);
    }
    return 0;
}
