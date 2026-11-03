// Banc de charge par niveau de qualité (étape Q1).
// Même scénario que tests/charge.cpp : tous les jeux, 30 notes tenues,
// blocs de 1024 à 48 kHz, réverbération 0. Une ligne par configuration.
#include <JuceHeader.h>
#include "aeolus_c.h"

#include <vector>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <ctime>

static double ms(struct timespec t0, struct timespec t1)
{
    return (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
}

struct Config
{
    const char* nom;
    int spatial;
    int bruit;
    int instabilite;
    int polyphonie;
};

static void mesurer(const Config& c, double& moyenne, double& mediane, double& p99)
{
    const int sr = 48000;
    const int n = 1024;
    const int notes[] = {36, 43, 48, 52, 55, 60, 64, 67, 72, 76};

    void* m = aeolus_creer(sr);
    if (!m) {
        std::fprintf(stderr, "aeolus_creer échoué\n");
        std::exit(1);
    }

    const int nd = aeolus_nb_divisions(m);
    for (int d = 0; d < nd; ++d) {
        const int nj = aeolus_nb_jeux(m, d);
        for (int j = 0; j < nj; ++j)
            aeolus_jeu(m, d, j, 1);
    }

    // Réglages AVANT le déclenchement : ils sont lus au trigger (R1).
    aeolus_qualite(m, 2, c.spatial);
    aeolus_qualite(m, 0, c.bruit);
    aeolus_qualite(m, 1, c.instabilite);
    aeolus_qualite(m, 3, c.polyphonie);

    for (int ch = 0; ch < 3; ++ch) {
        for (int ni = 0; ni < 10; ++ni) {
            unsigned char on[3] = { (unsigned char)(0x90 | ch),
                                    (unsigned char)notes[ni], 100 };
            aeolus_midi(m, on, 3);
        }
    }

    aeolus_reverb(m, 0.0f);

    std::vector<float> L(n, 0.0f), R(n, 0.0f);

    for (int i = 0; i < 50; ++i)
        aeolus_rendre(m, L.data(), R.data(), n);

    std::vector<double> temps(1000);
    for (int i = 0; i < 1000; ++i) {
        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        aeolus_rendre(m, L.data(), R.data(), n);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        temps[i] = ms(t0, t1);
    }

    std::sort(temps.begin(), temps.end());
    double somme = 0.0;
    for (double t : temps)
        somme += t;

    moyenne = somme / (double)temps.size();
    mediane = (temps[499] + temps[500]) / 2.0;
    p99 = temps[989];

    aeolus_detruire(m);
}

int main(int argc, char** argv)
{
    const Config configs[] = {
        { "spatialisation 2 (defaut)", 2, 1, 1, 0 },
        { "spatialisation 1",          1, 1, 1, 0 },
        { "spatialisation 0",          0, 1, 1, 0 },
        { "bruit_attaque 0",           2, 0, 1, 0 },
        { "instabilite 0",             2, 1, 0, 0 },
        { "polyphonie_max 64",         2, 1, 1, 64 },
    };

    const double deadline = 1024.0 / 48000.0 * 1000.0;
    const int nConfigs = (int)(sizeof(configs) / sizeof(configs[0]));

    // Argument optionnel : indice de la seule configuration à mesurer (pour
    // alterner les exécutions des configurations extrêmes).
    int debut = 0;
    int fin = nConfigs;
    if (argc > 1) {
        int idx = std::atoi(argv[1]);
        if (idx < 0 || idx >= nConfigs) {
            std::fprintf(stderr, "indice de configuration invalide\n");
            return 2;
        }
        debut = idx;
        fin = idx + 1;
    }

    for (int i = debut; i < fin; ++i) {
        const auto& c = configs[i];
        double moy, med, p99;
        mesurer(c, moy, med, p99);
        std::printf("%-28s moy=%.3f ms med=%.3f ms p99=%.3f ms (%.1f%% échéance)\n",
                    c.nom, moy, med, p99, moy / deadline * 100.0);
        std::fflush(stdout);
    }

    return 0;
}
