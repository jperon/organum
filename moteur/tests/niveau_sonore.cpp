// Test du niveau sonore par mode de spatialisation (étape Q1).
// Scénario de charge.cpp : tous les jeux, accord de 30 notes tenues,
// réverbération 0, blocs de 1024 à 48 kHz, limiteur actif par défaut.
//
// Il détecte le défaut où les contributions des voix de niveau 1 s'écrasaient
// au lieu de s'additionner : le niveau 1 devenait quasi silencieux.
#include <JuceHeader.h>
#include "aeolus_c.h"

#include <cmath>
#include <cstdio>
#include <vector>

static double rms_niveau(int spatial)
{
    const int sr = 48000;
    const int n = 1024;
    const int notes[] = {36, 43, 48, 52, 55, 60, 64, 67, 72, 76};

    void* m = aeolus_creer(sr);
    if (!m) {
        std::fprintf(stderr, "aeolus_creer échoué\n");
        return -1.0;
    }

    const int nd = aeolus_nb_divisions(m);
    for (int d = 0; d < nd; ++d) {
        const int nj = aeolus_nb_jeux(m, d);
        for (int j = 0; j < nj; ++j)
            aeolus_jeu(m, d, j, 1);
    }

    // Réglage AVANT déclenchement (lu au trigger, R1).
    aeolus_qualite(m, 2, spatial);
    aeolus_reverb(m, 0.0f);

    for (int ch = 0; ch < 3; ++ch) {
        for (int ni = 0; ni < 10; ++ni) {
            unsigned char on[3] = { (unsigned char)(0x90 | ch),
                                    (unsigned char)notes[ni], 100 };
            aeolus_midi(m, on, 3);
        }
    }

    std::vector<float> L(n, 0.0f), R(n, 0.0f);

    // Chauffe (tables, enveloppes, réverbération).
    for (int i = 0; i < 50; ++i)
        aeolus_rendre(m, L.data(), R.data(), n);

    double somme = 0.0;
    long total = 0;
    for (int b = 0; b < 100; ++b) {
        aeolus_rendre(m, L.data(), R.data(), n);
        for (int i = 0; i < n; ++i) {
            somme += (double)L[i] * L[i] + (double)R[i] * R[i];
            total += 2;
        }
    }

    aeolus_detruire(m);
    return std::sqrt(somme / (double)total);
}

int main()
{
    const double r2 = rms_niveau(2);
    const double r1 = rms_niveau(1);
    const double r0 = rms_niveau(0);

    std::printf("RMS spatialisation 2 = %.6f\n", r2);
    std::printf("RMS spatialisation 1 = %.6f  (rapport au niveau 2 : %.3f)\n",
                r1, r2 > 0.0 ? r1 / r2 : 0.0);
    std::printf("RMS spatialisation 0 = %.6f  (rapport au niveau 2 : %.3f)\n",
                r0, r2 > 0.0 ? r0 / r2 : 0.0);

    // Tolérance large [0,5 ; 2,0] (environ ±6 dB) : les niveaux 1 et 0
    // changent les gains/le filtrage spatial (atténuations angulaires
    // 0,3..1,0, passe-bas de distance au-dessus de ~12 kHz), mais la
    // puissance globale d'un même accord doit rester du même ordre. Un
    // écrasement des contributions (une seule voix audible par division)
    // tombe très en dessous de 0,5.
    int echecs = 0;
    if (!(r2 > 0.0)) {
        std::printf("ECHEC : niveau 2 muet\n");
        ++echecs;
    }
    if (!(r1 / r2 >= 0.5 && r1 / r2 <= 2.0)) {
        std::printf("ECHEC : rapport RMS niveau 1 / niveau 2 hors [0,5 ; 2,0]\n");
        ++echecs;
    }
    if (!(r0 / r2 >= 0.5 && r0 / r2 <= 2.0)) {
        std::printf("ECHEC : rapport RMS niveau 0 / niveau 2 hors [0,5 ; 2,0]\n");
        ++echecs;
    }

    if (echecs == 0) {
        std::printf("niveau_sonore : tous les contrôles passent\n");
        return 0;
    }

    std::printf("niveau_sonore : %d échec(s)\n", echecs);
    return 1;
}
