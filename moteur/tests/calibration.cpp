// Tests du micro-banc de calibration automatique (étape Q3a), API C seule.
//
// Depuis le déplacement de la décision vers web/src/calibration.moon, ce banc
// ne vérifie plus le niveau choisi : il éprouve les MESURES C++ (durée,
// échéance, coûts positifs, voix de référence, indicateur de voix forcée).
// La décision (niveau, tête, estimations) est couverte par
// web/tests/calibration_test.lua, qui rejoue plusieurs jeux de mesures.

#include "aeolus_c.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

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
    std::printf("echeance=%.4f ms voix_ref=%d voix_forcee=%d\n",
                c.echeance_ms, c.voix_ref, c.voix_forcee);
    std::printf("cout_spat2=%.4f us/voix/64  cout_spat1=%.4f us/voix/64\n",
                c.cout_spat2_us, c.cout_spat1_us);
    std::printf("cout_reverb tete=%.4f ms/bloc  sans_tete=%.4f ms/bloc\n",
                c.cout_reverb_tete_ms, c.cout_reverb_sans_tete_ms);
    std::printf("duree_calibration=%.2f ms\n", c.duree_calibration_ms);
}

static void mesurer_et_verifier(int taux, int periode)
{
    aeolus_calibrage c;
    std::memset(&c, 0, sizeof(c));
    const int code = aeolus_calibrer(taux, periode, &c);

    afficher(taux, periode, c);

    char msg[256];
    std::snprintf(msg, sizeof(msg), "periode %d : code 0", periode);
    verifier(code == 0, msg);

    std::snprintf(msg, sizeof(msg), "periode %d : duree %.2f ms < 1500 ms",
                  periode, c.duree_calibration_ms);
    verifier(c.duree_calibration_ms < 1500.0, msg);

    std::snprintf(msg, sizeof(msg),
                  "periode %d : echeance %.4f ms = periode/taux",
                  periode, c.echeance_ms);
    verifier(std::fabs(c.echeance_ms - periode * 1000.0 / taux) < 1e-9, msg);

    std::snprintf(msg, sizeof(msg), "periode %d : voix_ref positive", periode);
    verifier(c.voix_ref > 0, msg);

    std::snprintf(msg, sizeof(msg), "periode %d : cout_spat2 > 0", periode);
    verifier(c.cout_spat2_us > 0.0, msg);

    std::snprintf(msg, sizeof(msg), "periode %d : cout_spat1 > 0", periode);
    verifier(c.cout_spat1_us > 0.0, msg);

    std::snprintf(msg, sizeof(msg), "periode %d : cout_reverb tete > 0", periode);
    verifier(c.cout_reverb_tete_ms > 0.0, msg);

    std::snprintf(msg, sizeof(msg), "periode %d : cout_reverb sans tete > 0", periode);
    verifier(c.cout_reverb_sans_tete_ms > 0.0, msg);
}

int main()
{
    const int taux = 48000;

    mesurer_et_verifier(taux, 512);
    mesurer_et_verifier(taux, 1024);

    // L'indicateur de voix forcée suit ORGANUM_CALIBRATION_VOIX (utilisé par
    // le banc de validation chargé) ; il est transmis tel quel à la décision.
    std::printf("\n=== indicateur ORGANUM_CALIBRATION_VOIX ===\n");
    unsetenv("ORGANUM_CALIBRATION_VOIX");
    {
        aeolus_calibrage c;
        std::memset(&c, 0, sizeof(c));
        aeolus_calibrer(taux, 1024, &c);
        verifier(c.voix_forcee == 0, "sans variable : voix_forcee = 0");
    }
    setenv("ORGANUM_CALIBRATION_VOIX", "250", 1);
    {
        aeolus_calibrage c;
        std::memset(&c, 0, sizeof(c));
        aeolus_calibrer(taux, 1024, &c);
        verifier(c.voix_forcee == 1, "variable définie : voix_forcee = 1");
        verifier(c.voix_ref == 250, "variable définie : voix_ref = 250");
    }
    unsetenv("ORGANUM_CALIBRATION_VOIX");

    // Le facteur multiplie exactement les coûts mesurés ; on vérifie surtout
    // que le champ reste transmis et que les mesures restent positives.
    std::printf("\n=== effet de ORGANUM_CALIBRATION_FACTEUR ===\n");
    const double facteurs[] = {1.0, 5.0, 25.0, 100.0};
    for (double f : facteurs) {
        char valeur[64];
        std::snprintf(valeur, sizeof(valeur), "%.17g", f);
        setenv("ORGANUM_CALIBRATION_FACTEUR", valeur, 1);

        aeolus_calibrage c;
        std::memset(&c, 0, sizeof(c));
        aeolus_calibrer(taux, 1024, &c);

        std::printf("facteur=%g -> spat2 %.4f us, reverb tete %.4f ms, duree %.2f ms\n",
                    f, c.cout_spat2_us, c.cout_reverb_tete_ms,
                    c.duree_calibration_ms);
        char msg[256];
        std::snprintf(msg, sizeof(msg), "facteur %g : couts positifs", f);
        verifier(c.cout_spat2_us > 0.0 && c.cout_reverb_tete_ms > 0.0, msg);
    }
    unsetenv("ORGANUM_CALIBRATION_FACTEUR");

    std::printf("\n%s (%d echec(s))\n", echecs == 0 ? "SUCCES" : "ECHEC", echecs);
    return echecs == 0 ? 0 : 1;
}
