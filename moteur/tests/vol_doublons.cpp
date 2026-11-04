// Test du sacrifice prioritaire des doublons (étape Q1c).
//
// Scénario :
//   - seuls « Open Diapason 8 » de Manual I (canal 1) et Manual II (canal 2)
//     — même tuyau I_principal_8, donc vrais doublons — ainsi qu'un jeu
//     unique de Manual III (canal 3) sont activés ;
//   - on joue d'abord trois notes UNIQUES sur Manual III ;
//   - puis le MÊME accord de trois notes sur Manual I et Manual II
//     (six voix, donc trois paires de doublons) ;
//   - plafond N = 9, puis trois nouvelles notes uniques forcent trois vols.
// Attendu (nouveau choix) : les trois voix volées sont une copie de chaque
// doublon ; les six notes uniques et une copie de chaque note d'accord
// sonnent encore. Ancien choix (plus ancienne) : les trois premières notes
// uniques sont volées, le test échoue.
#include <JuceHeader.h>
#include "aeolus_c.h"
#include "aeolus/engine.h"
#include "aeolus/division.h"
#include "aeolus/voice.h"

#include <cstdio>
#include <cstring>
#include <ctime>
#include <vector>

AEOLUS_USING_NAMESPACE

// Même disposition que la structure Handle interne de api/aeolus_c.cpp
// (premier membre : Engine*). L'API C ne permet pas d'observer les voix ;
// les en-têtes C++ du moteur le permettent.
struct HandleVue
{
    aeolus::Engine* engine;
    void* listener;
};

static aeolus::Engine* moteur(void* m)
{
    return reinterpret_cast<HandleVue*>(m)->engine;
}

static void note_on(void* m, int canal, int note)
{
    unsigned char msg[3] = { (unsigned char)(0x90 | (canal - 1)), (unsigned char)note, 100 };
    aeolus_midi(m, msg, 3);
}

static int trouver_division(aeolus::Engine* e, const char* nom)
{
    for (int i = 0; i < e->getDivisionCount(); ++i) {
        if (e->getDivisionByIndex(i)->getName() == juce::String(nom))
            return i;
    }
    return -1;
}

static int trouver_jeu(aeolus::Engine* e, int d, const char* nom)
{
    auto* div = e->getDivisionByIndex(d);
    for (int j = 0; j < div->getStopsCount(); ++j) {
        if (div->getStopByIndex(j).getName() == juce::String(nom))
            return j;
    }
    return -1;
}

// Nombre de voix TENUES (Attack) de cette division pour cette note.
static int tenues(aeolus::Engine* e, int d, int note)
{
    int n = 0;
    auto& voix = e->getDivisionByIndex(d)->getActiveVoices();

    for (auto* v = voix.first(); v != nullptr; v = v->next()) {
        if (v->isActive() && v->getNote() == note)
            ++n;
    }

    return n;
}

static void couper_tous_les_jeux(void* m)
{
    const int nd = aeolus_nb_divisions(m);

    for (int d = 0; d < nd; ++d) {
        const int nj = aeolus_nb_jeux(m, d);
        for (int j = 0; j < nj; ++j)
            aeolus_jeu(m, d, j, 0);
    }
}

static int test_fonctionnel()
{
    const int sr = 48000;
    const int N = 9;
    const int uniques1[] = { 48, 50, 52 };
    const int accord[] = { 60, 64, 67 };
    const int uniques2[] = { 53, 55, 57 };

    void* m = aeolus_creer(sr);
    if (m == nullptr) {
        std::printf("ECHEC : aeolus_creer\n");
        return 1;
    }

    auto* e = moteur(m);

    const int dI = trouver_division(e, "Manual I");
    const int dII = trouver_division(e, "Manual II");
    const int dIII = trouver_division(e, "Manual III");

    if (dI < 0 || dII < 0 || dIII < 0) {
        std::printf("ECHEC : divisions Manual I/II/III introuvables\n");
        aeolus_detruire(m);
        return 1;
    }

    const int jOD_I = trouver_jeu(e, dI, "Open Diapason\n8");
    const int jOD_II = trouver_jeu(e, dII, "Open Diapason\n8");
    const int jUnique = trouver_jeu(e, dIII, "Oboe\n8");

    if (jOD_I < 0 || jOD_II < 0 || jUnique < 0) {
        std::printf("ECHEC : jeux attendus introuvables (OD I=%d, OD II=%d, Oboe III=%d)\n",
                    jOD_I, jOD_II, jUnique);
        aeolus_detruire(m);
        return 1;
    }

    couper_tous_les_jeux(m);
    aeolus_jeu(m, dI, jOD_I, 1);
    aeolus_jeu(m, dII, jOD_II, 1);
    aeolus_jeu(m, dIII, jUnique, 1);

    // Aucun accouplement : les trois divisions jouent strictement leur canal.
    const int nd = aeolus_nb_divisions(m);
    for (int d = 0; d < nd; ++d) {
        aeolus_fixer_canaux_division(m, d, 0);
        for (int l = 0; l < aeolus_nb_liens(m, d); ++l)
            aeolus_lien(m, d, l, 0);
    }
    aeolus_fixer_canaux_division(m, dI, 1 << 0);
    aeolus_fixer_canaux_division(m, dII, 1 << 1);
    aeolus_fixer_canaux_division(m, dIII, 1 << 2);

    aeolus_qualite(m, 0, 0); // pas de bruit d'attaque
    aeolus_qualite(m, 1, 0); // pas d'instabilité
    aeolus_qualite(m, 2, 0); // spatialisation coupée
    aeolus_qualite(m, 3, N);

    // 1. Trois notes uniques, les plus anciennes.
    for (int n : uniques1)
        note_on(m, 3, n);

    // 2. Le même accord sur Manual I puis Manual II : six voix, trois paires.
    for (int n : accord) {
        note_on(m, 1, n);
        note_on(m, 2, n);
    }

    const int tenues_avant = aeolus_nb_voix_actives(m);
    std::printf("avant les vols : prises=%d tenues=%d (plafond %d)\n",
                aeolus_nb_voix(m), tenues_avant, N);

    // 3. Trois nouvelles notes uniques : une voix volée par note.
    for (int n : uniques2)
        note_on(m, 3, n);

    int echecs = 0;

    const int tenues_apres = aeolus_nb_voix_actives(m);
    std::printf("après les vols : prises=%d tenues=%d\n",
                aeolus_nb_voix(m), tenues_apres);

    if (tenues_avant != 9) {
        std::printf("ECHEC : %d voix tenues avant les vols, 9 attendues\n", tenues_avant);
        ++echecs;
    }
    if (tenues_apres > N) {
        std::printf("ECHEC : %d voix tenues > plafond %d\n", tenues_apres, N);
        ++echecs;
    }

    // Toutes les notes uniques doivent sonner (c'est ce que l'ancien choix
    // « plus ancienne » casse : il vole les trois premières).
    for (int n : uniques1) {
        if (tenues(e, dIII, n) != 1) {
            std::printf("ECHEC : note unique %d de Manual III volée (%d tenue(s))\n",
                        n, tenues(e, dIII, n));
            ++echecs;
        }
    }
    for (int n : uniques2) {
        if (tenues(e, dIII, n) != 1) {
            std::printf("ECHEC : nouvelle note unique %d absente (%d tenue(s))\n",
                        n, tenues(e, dIII, n));
            ++echecs;
        }
    }

    // Chaque note de l'accord garde exactement une copie (l'autre a été
    // volée), et c'est celle de Manual II : les vols ont bien visé les
    // doublons les plus anciens (Manual I).
    for (int n : accord) {
        const int i = tenues(e, dI, n);
        const int ii = tenues(e, dII, n);

        if (i + ii != 1) {
            std::printf("ECHEC : accord note %d : %d copie(s) restante(s) sur I+II (1 attendue)\n",
                        n, i + ii);
            ++echecs;
        }
        if (ii != 1) {
            std::printf("ECHEC : accord note %d : Manual II ne garde pas sa copie (I=%d, II=%d)\n",
                        n, i, ii);
            ++echecs;
        }
    }

    std::printf("tenues Manual I : OD I:");
    for (int n : accord)
        std::printf(" %d=%d", n, tenues(e, dI, n));
    std::printf(" | Manual II :");
    for (int n : accord)
        std::printf(" %d=%d", n, tenues(e, dII, n));
    std::printf("\n");

    aeolus_detruire(m);

    if (echecs == 0) {
        std::printf("vol_doublons : tous les contrôles passent\n");
        return 0;
    }

    std::printf("vol_doublons : %d échec(s)\n", echecs);
    return 1;
}

#ifdef ORGANUM_VOIX_DOUBLONS
static double microsecondes(struct timespec t0, struct timespec t1)
{
    return (t1.tv_sec - t0.tv_sec) * 1e6 + (t1.tv_nsec - t0.tv_nsec) / 1e3;
}

// Coût d'un choix de victime avec 512 voix tenues dans le registre.
static void mesurer_cout()
{
    const int sr = 48000;
    void* m = aeolus_creer(sr);

    if (m == nullptr) {
        std::printf("mesure : aeolus_creer échoué\n");
        return;
    }

    auto* e = moteur(m);
    const int nd = aeolus_nb_divisions(m);

    // Tous les jeux de toutes les divisions : quelques notes suffisent à
    // saturer physiquement le pool (512 voix).
    for (int d = 0; d < nd; ++d) {
        const int nj = aeolus_nb_jeux(m, d);
        for (int j = 0; j < nj; ++j)
            aeolus_jeu(m, d, j, 1);
    }

    for (int n = 36; n <= 96 && aeolus_nb_voix_actives(m) < 512; ++n)
        note_on(m, 1, n);

    // Plafond au maximum : le choix de victime reste sur le même chemin.
    aeolus_qualite(m, 3, 512);

    auto* pool = &e->getVoicePool();
    const int actives = aeolus_nb_voix_actives(m);

    // Chauffe (réutilisation de la table, aucun effet d'allocation).
    volatile unsigned long long somme = 0;
    for (int i = 0; i < 200; ++i) {
        auto* v = pool->choisirVictimePourMesure();
        if (v != nullptr)
            somme += v->ordre() & 1;
    }

    const int iterations = 2000;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < iterations; ++i) {
        auto* v = pool->choisirVictimePourMesure();
        if (v != nullptr)
            somme += v->ordre() & 1;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    const double total = microsecondes(t0, t1);
    std::printf("coût du choix de victime : %.2f µs/choix (%d voix tenues, %d itérations, somme=%llu)\n",
                total / iterations, actives, iterations, (unsigned long long)somme);

    aeolus_detruire(m);
}
#else
static void mesurer_cout()
{
    std::printf("coût du choix : non mesuré (état d'origine)\n");
}
#endif

int main()
{
    const int echecs = test_fonctionnel();
    mesurer_cout();
    return echecs;
}
