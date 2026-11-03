// Test de l'API C des réglages de qualité (étape Q1, côté moteur).
// Vérifie les défauts, la lecture/écriture de chaque champ, le plafond de
// polyphonie avec vol de voix, et le comportement à saturation du pool.
#include <JuceHeader.h>
#include "aeolus_c.h"

#include <cmath>
#include <cstdio>
#include <vector>

static int echecs = 0;

static void verifier(bool condition, const char* message)
{
    if (!condition) {
        std::printf("ECHEC : %s\n", message);
        ++echecs;
    }
}

static void activer_tous_les_jeux(void* moteur)
{
    const int nd = aeolus_nb_divisions(moteur);
    for (int d = 0; d < nd; ++d) {
        const int nj = aeolus_nb_jeux(moteur, d);
        for (int j = 0; j < nj; ++j)
            aeolus_jeu(moteur, d, j, 1);
    }
}

static void note_on(void* moteur, int note, int canal = 1)
{
    unsigned char msg[3] = { (unsigned char)(0x90 | (canal - 1)),
                             (unsigned char)note, 100 };
    aeolus_midi(moteur, msg, 3);
}

static void n_activer_qu_un_jeu(void* moteur)
{
    // Un seul jeu (division 0, stop 0) : une note tenue ne consomme alors
    // qu'un nombre minimal de voix, ce qui permet de tester le plafond sans
    // saturer le pool physique.
    const int nd = aeolus_nb_divisions(moteur);
    for (int d = 0; d < nd; ++d) {
        const int nj = aeolus_nb_jeux(moteur, d);
        for (int j = 0; j < nj; ++j)
            aeolus_jeu(moteur, d, j, 0);
    }
    if (nd > 0 && aeolus_nb_jeux(moteur, 0) > 0)
        aeolus_jeu(moteur, 0, 0, 1);
}

static bool rendu_non_nul_et_fini(void* moteur)
{
    const int n = 256;
    std::vector<float> l(n, 0.0f), r(n, 0.0f);
    bool nonNul = false;

    for (int b = 0; b < 8; ++b) {
        aeolus_rendre(moteur, l.data(), r.data(), n);
        for (int i = 0; i < n; ++i) {
            if (!std::isfinite(l[i]) || !std::isfinite(r[i]))
                return false;
            if (l[i] != 0.0f || r[i] != 0.0f)
                nonNul = true;
        }
    }

    return nonNul;
}

int main()
{
    const int sr = 48000;

    // (i) Valeurs par défaut.
    {
        void* m = aeolus_creer(sr);
        verifier(m != nullptr, "aeolus_creer");
        verifier(aeolus_lire_qualite(m, 0) == 1, "défaut bruit_attaque = 1");
        verifier(aeolus_lire_qualite(m, 1) == 1, "défaut instabilite = 1");
        verifier(aeolus_lire_qualite(m, 2) == 2, "défaut spatialisation = 2");
        verifier(aeolus_lire_qualite(m, 3) == 0, "défaut polyphonie_max = 0");
        verifier(aeolus_lire_qualite(m, 99) == -1, "champ inconnu -> -1");

        // (ii) Chaque champ se règle et se relit.
        aeolus_qualite(m, 0, 0);
        verifier(aeolus_lire_qualite(m, 0) == 0, "bruit_attaque réglé à 0");
        aeolus_qualite(m, 1, 0);
        verifier(aeolus_lire_qualite(m, 1) == 0, "instabilite réglé à 0");
        aeolus_qualite(m, 2, 1);
        verifier(aeolus_lire_qualite(m, 2) == 1, "spatialisation réglée à 1");
        aeolus_qualite(m, 2, 0);
        verifier(aeolus_lire_qualite(m, 2) == 0, "spatialisation réglée à 0");
        aeolus_qualite(m, 2, 2);
        verifier(aeolus_lire_qualite(m, 2) == 2, "spatialisation réglée à 2");
        aeolus_qualite(m, 3, 64);
        verifier(aeolus_lire_qualite(m, 3) == 64, "polyphonie_max réglé à 64");

        // Valeurs hors bornes : bornées.
        aeolus_qualite(m, 0, -5);
        verifier(aeolus_lire_qualite(m, 0) == 0, "bruit_attaque -5 borné à 0");
        aeolus_qualite(m, 0, 7);
        verifier(aeolus_lire_qualite(m, 0) == 1, "bruit_attaque 7 borné à 1");
        aeolus_qualite(m, 1, -1);
        verifier(aeolus_lire_qualite(m, 1) == 0, "instabilite -1 bornée à 0");
        aeolus_qualite(m, 2, 9);
        verifier(aeolus_lire_qualite(m, 2) == 2, "spatialisation 9 bornée à 2");
        aeolus_qualite(m, 3, 9999);
        verifier(aeolus_lire_qualite(m, 3) == 512, "polyphonie_max 9999 bornée à 512");
        aeolus_qualite(m, 3, -3);
        verifier(aeolus_lire_qualite(m, 3) == 0, "polyphonie_max -3 bornée à 0");

        aeolus_detruire(m);
    }

    // (iii) Plafond de polyphonie N : plus de notes que N, la dernière sonne,
    // le nombre de voix tenues ne dépasse jamais N.
    {
        const int N = 8;
        void* m = aeolus_creer(sr);
        verifier(m != nullptr, "aeolus_creer plafond");
        n_activer_qu_un_jeu(m);
        aeolus_qualite(m, 3, N);

        const int notes[] = {48, 52, 55, 59, 60, 62, 64, 67, 69, 72, 74, 76, 79, 81};
        int maxVues = 0;

        for (int note : notes) {
            note_on(m, note);
            const int actives = aeolus_nb_voix_actives(m);
            if (actives > maxVues)
                maxVues = actives;
            verifier(actives <= N, "voix tenues <= plafond");
            verifier(aeolus_nb_voix(m) <= 512, "voix prises <= 512");
        }

        const int derniere = notes[(int)(sizeof(notes) / sizeof(notes[0])) - 1];
        verifier(aeolus_note_active(m, derniere) == 1, "la dernière note déclenchée sonne");
        verifier(rendu_non_nul_et_fini(m), "sortie non nulle et finie sous plafond");

        std::printf("plafond %d : max voix tenues vues = %d, prises = %d\n",
                    N, maxVues, aeolus_nb_voix(m));

        aeolus_detruire(m);
    }

    // (iv) Saturation du pool physique (512) sans plafond : comportement
    // documenté = réutilisation d'autorité de la plus ancienne voix, aucune
    // perte silencieuse, nombre de voix prises borné par 512.
    {
        void* m = aeolus_creer(sr);
        verifier(m != nullptr, "aeolus_creer saturation");
        activer_tous_les_jeux(m);
        aeolus_qualite(m, 3, 0);

        int derniere = 0;
        int maxPrises = 0;
        for (int note = 36; note <= 96; ++note) {
            note_on(m, note);
            derniere = note;
            const int prises = aeolus_nb_voix(m);
            if (prises > maxPrises)
                maxPrises = prises;
            verifier(prises <= 512, "voix prises <= 512 à saturation");
        }

        note_on(m, derniere);
        verifier(aeolus_note_active(m, derniere) == 1, "dernière note non perdue à saturation");
        verifier(rendu_non_nul_et_fini(m), "sortie non nulle et finie à saturation");

        std::printf("saturation : max voix prises = %d (pool plein = %s), dernière note active = %d\n",
                    maxPrises, maxPrises == 512 ? "oui" : "non",
                    aeolus_note_active(m, derniere));

        aeolus_detruire(m);
    }

    if (echecs == 0) {
        std::printf("qualite : tous les contrôles passent\n");
        return 0;
    }

    std::printf("qualite : %d échec(s)\n", echecs);
    return 1;
}
