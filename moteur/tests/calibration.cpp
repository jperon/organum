// Tests du cœur de la calibration automatique (étape Q3a), API C seule.
//
// Vérifie : durée < 1,5 s, niveau dans 0..3, estimations croissantes avec le
// niveau, et niveaux non croissants quand ORGANUM_CALIBRATION_FACTEUR augmente.
// Affiche tous les champs pour les périodes 512 et 1024 à 48 kHz.

#include "aeolus_c.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static int echecs = 0;

static void verifier(bool condition, const char* message)
{
    if (!condition) {
        std::printf("ECHEC : %s\n", message);
        ++echecs;
    } else {
        std::printf("ok    : %s\n", message);
    }
}

static void afficher(int taux, int periode, const aeolus_calibrage& c)
{
    std::printf("\n=== taux=%d Hz, periode=%d trames ===\n", taux, periode);
    std::printf("niveau=%d tete_reverb=%d echeance=%.4f ms voix_ref=%d\n",
                c.niveau, c.tete_reverb, c.echeance_ms, c.voix_ref);
    std::printf("cout_spat2=%.4f us/voix/64  cout_spat1=%.4f us/voix/64\n",
                c.cout_spat2_us, c.cout_spat1_us);
    std::printf("cout_reverb tete=%.4f ms/bloc  sans_tete=%.4f ms/bloc\n",
                c.cout_reverb_tete_ms, c.cout_reverb_sans_tete_ms);
    for (int i = 0; i < 4; ++i)
        std::printf("estimation_ms[%d]=%.4f\n", i, c.estimation_ms[i]);
    std::printf("duree_calibration=%.2f ms\n", c.duree_calibration_ms);
}

static void verifier_croissance(const aeolus_calibrage& c, int periode)
{
    // Tolérance relative de 5 % : les estimations sont calculées dans le même
    // passage à partir de deux mesures de réverbération indépendantes (tête
    // et sans tête), qui peuvent être bruitées ; 5 % couvre ce bruit sans
    // masquer une vraie inversion de tendance.
    const double tol = 0.05;
    char msg[256];
    for (int i = 0; i < 3; ++i) {
        const bool ok = c.estimation_ms[i]
                        <= c.estimation_ms[i + 1] * (1.0 + tol) + 1e-9;
        std::snprintf(msg, sizeof(msg),
                      "periode %d : estimation[%d]=%.4f <= estimation[%d]=%.4f (tol 5%%)",
                      periode, i, c.estimation_ms[i], i + 1,
                      c.estimation_ms[i + 1]);
        verifier(ok, msg);
    }
}

static int calibrer_et_verifier(int taux, int periode)
{
    aeolus_calibrage c;
    std::memset(&c, 0, sizeof(c));
    const int niveau = aeolus_calibrer(taux, periode, &c);

    afficher(taux, periode, c);

    char msg[256];
    std::snprintf(msg, sizeof(msg), "periode %d : duree %.2f ms < 1500 ms",
                  periode, c.duree_calibration_ms);
    verifier(c.duree_calibration_ms < 1500.0, msg);

    std::snprintf(msg, sizeof(msg), "periode %d : niveau %d dans 0..3",
                  periode, niveau);
    verifier(niveau >= 0 && niveau <= 3 && c.niveau == niveau, msg);

    std::snprintf(msg, sizeof(msg),
                  "periode %d : echeance %.4f ms = periode/taux",
                  periode, c.echeance_ms);
    verifier(std::fabs(c.echeance_ms - periode * 1000.0 / taux) < 1e-9, msg);

    verifier_croissance(c, periode);
    return niveau;
}

int main()
{
    const int taux = 48000;

    // Deux périodes représentatives.
    calibrer_et_verifier(taux, 512);
    calibrer_et_verifier(taux, 1024);

    // Facteur croissant ⇒ niveau non croissant (machine simulée plus lente).
    const double facteurs[] = {1.0, 5.0, 25.0, 100.0};
    int precedent = 3;
    std::printf("\n=== effet de ORGANUM_CALIBRATION_FACTEUR ===\n");
    for (double f : facteurs) {
        char valeur[64];
        std::snprintf(valeur, sizeof(valeur), "%.17g", f);
        setenv("ORGANUM_CALIBRATION_FACTEUR", valeur, 1);

        aeolus_calibrage c;
        std::memset(&c, 0, sizeof(c));
        const int niveau = aeolus_calibrer(taux, 1024, &c);

        std::printf("facteur=%g -> niveau=%d (estimations %.3f / %.3f / %.3f / %.3f ms, duree %.2f ms)\n",
                    f, niveau, c.estimation_ms[0], c.estimation_ms[1],
                    c.estimation_ms[2], c.estimation_ms[3],
                    c.duree_calibration_ms);

        char msg[256];
        std::snprintf(msg, sizeof(msg),
                      "facteur %g : niveau %d <= niveau precedent %d",
                      f, niveau, precedent);
        verifier(niveau <= precedent, msg);
        precedent = niveau;
    }

    // Le facteur 100 doit donner le niveau 0.
    {
        aeolus_calibrage c;
        std::memset(&c, 0, sizeof(c));
        const int niveau = aeolus_calibrer(taux, 1024, &c);
        verifier(niveau == 0, "facteur 100 : niveau 0");
    }

    // Facteur 1 : au moins le niveau 0 (sanity).
    setenv("ORGANUM_CALIBRATION_FACTEUR", "1", 1);
    {
        aeolus_calibrage c;
        std::memset(&c, 0, sizeof(c));
        const int niveau = aeolus_calibrer(taux, 1024, &c);
        verifier(niveau >= 0 && niveau <= 3, "facteur 1 : niveau valide");
    }

    std::printf("\n%s (%d echec(s))\n", echecs == 0 ? "SUCCES" : "ECHEC", echecs);
    return echecs == 0 ? 0 : 1;
}
