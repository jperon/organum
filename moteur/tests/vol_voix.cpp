// Test du vol de voix du plafond de polyphonie (étape Q1).
// Vérifie que la voix volée est bien la plus ANCIENNE encore tenue, même
// après des relâchements qui réordonnent le registre interne du pool.
#include <JuceHeader.h>
#include "aeolus_c.h"

#include <cstdio>
#include <vector>

static void note_on(void* m, int note)
{
    unsigned char msg[3] = { 0x90, (unsigned char)note, 100 };
    aeolus_midi(m, msg, 3);
}

static void note_off(void* m, int note)
{
    unsigned char msg[3] = { 0x80, (unsigned char)note, 0 };
    aeolus_midi(m, msg, 3);
}

static void rendre(void* m, int blocs)
{
    const int n = 1024;
    std::vector<float> l(n, 0.0f), r(n, 0.0f);
    for (int b = 0; b < blocs; ++b)
        aeolus_rendre(m, l.data(), r.data(), n);
}

int main()
{
    const int sr = 48000;
    const int N = 4;

    void* m = aeolus_creer(sr);
    if (!m) {
        std::fprintf(stderr, "aeolus_creer échoué\n");
        return 1;
    }

    // Un seul jeu à une seule rankwave par note (division 0, "Claribel 8"
    // = I_melodia, vérifié : une note = une voix). Les autres sont coupés.
    const int nd = aeolus_nb_divisions(m);
    for (int d = 0; d < nd; ++d) {
        const int nj = aeolus_nb_jeux(m, d);
        for (int j = 0; j < nj; ++j)
            aeolus_jeu(m, d, j, 0);
    }
    aeolus_jeu(m, 0, 2, 1);

    aeolus_qualite(m, 2, 0); // spatialisation coupée : release plus court
    aeolus_qualite(m, 0, 0); // pas de chiff
    aeolus_qualite(m, 3, N);

    const int A = 60, B = 62, C = 64, D = 65, E = 67, F = 69;

    note_on(m, A);
    note_on(m, B);
    note_on(m, C);
    note_on(m, D);
    std::printf("après A,B,C,D : prises=%d tenues=%d\n",
                aeolus_nb_voix(m), aeolus_nb_voix_actives(m));

    // Relâche la plus ancienne (A) et laisse le pool la recycler : le
    // registre réordonne alors ses entrées (ancien code : swap avec la
    // dernière, D passe en tête).
    note_off(m, A);
    int blocs = 0;
    while (aeolus_nb_voix(m) > 3 && blocs < 300) {
        rendre(m, 1);
        ++blocs;
    }
    std::printf("A recyclée après %d blocs : prises=%d tenues=%d\n",
                blocs, aeolus_nb_voix(m), aeolus_nb_voix_actives(m));

    // E remplit le plafond sans voler (3 tenues < N).
    note_on(m, E);

    // F dépasse le plafond : la plus ancienne tenue (B) doit être volée.
    note_on(m, F);

    const int b = aeolus_note_active(m, B);
    const int d = aeolus_note_active(m, D);
    const int c = aeolus_note_active(m, C);
    const int e = aeolus_note_active(m, E);
    const int f = aeolus_note_active(m, F);

    std::printf("après E puis F : B=%d C=%d D=%d E=%d F=%d (tenues=%d)\n",
                b, c, d, e, f, aeolus_nb_voix_actives(m));

    int echecs = 0;
    if (b != 0) {
        std::printf("ECHEC : B (la plus ancienne tenue) n'a pas été volée\n");
        ++echecs;
    }
    if (d != 1) {
        std::printf("ECHEC : D (plus récente) a été volée à tort\n");
        ++echecs;
    }
    if (c != 1 || e != 1 || f != 1) {
        std::printf("ECHEC : une note récente ne sonne plus\n");
        ++echecs;
    }
    if (aeolus_nb_voix_actives(m) > N) {
        std::printf("ECHEC : voix tenues > plafond\n");
        ++echecs;
    }

    aeolus_detruire(m);

    if (echecs == 0) {
        std::printf("vol_voix : tous les contrôles passent\n");
        return 0;
    }

    std::printf("vol_voix : %d échec(s)\n", echecs);
    return 1;
}
