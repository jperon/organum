// Polyphonie par accouplement : un clavier sans jeu (Manual I) accouplé à
// Manual III doit laisser sonner autant de notes que de touches tenues.
//
// Reproduit le cas mesuré sur l'orgue : Manual I sans jeu, lien I -> III,
// notes jouées sur le canal 2. Une seule note sonnait ; cinq notes tenues ne
// produisaient qu'une voix. Le test compte les voix tenues par note et par
// division après plusieurs blocs de rendu.
#include <JuceHeader.h>
#include "aeolus_c.h"
#include "aeolus/engine.h"
#include "aeolus/division.h"
#include "aeolus/voice.h"

#include <cstdio>
#include <cstring>
#include <vector>

AEOLUS_USING_NAMESPACE

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

static void note_off(void* m, int canal, int note)
{
    unsigned char msg[3] = { (unsigned char)(0x80 | (canal - 1)), (unsigned char)note, 0 };
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

static void rendre(void* m, int blocs, int n = 1024)
{
    std::vector<float> l(n, 0.0f), r(n, 0.0f);
    for (int i = 0; i < blocs; ++i)
        aeolus_rendre(m, l.data(), r.data(), n);
}

static int echecs = 0;

static void verifier(bool condition, const char* message)
{
    if (!condition) {
        std::printf("ECHEC : %s\n", message);
        ++echecs;
    }
}

// Active exactement la registration mesurée sur l'orgue.
static void registration_orgue(void* m, aeolus::Engine* e,
                               int dI, int dII, int dIII, int dP)
{
    couper_tous_les_jeux(m);

    struct { int d; const char* noms[4]; } jeux[] = {
        { dIII, { "Open Diapason\n8", "Principal\n4", "Fifteenth\n2", nullptr } },
        { dII,  { "Open Diapason\n8", "Chimney Flute\n8", "Principal\n4", nullptr } },
        { dP,   { "Open Diapason\n16", "Bourdon\n16", nullptr, nullptr } },
    };

    for (auto& j : jeux) {
        for (int i = 0; i < 4 && j.noms[i]; ++i) {
            const int idx = trouver_jeu(e, j.d, j.noms[i]);
            if (idx >= 0)
                aeolus_jeu(m, j.d, idx, 1);
        }
    }
}

// Masques exacts de /api/midi sur l'orgue.
static void masques_orgue(void* m, int dI, int dII, int dIII, int dP)
{
    aeolus_fixer_canaux_division(m, dIII, 0xFFF8); // 4..16
    aeolus_fixer_canaux_division(m, dII,  0xFFF9); // 1,4..16
    aeolus_fixer_canaux_division(m, dI,   0xFFFA); // 2,4,6..16
    aeolus_fixer_canaux_division(m, dP,   0xFFFC); // 3..16
    aeolus_fixer_canaux_controle(m, 0xFFFF & ~(1 << 3)); // 1,2,3,5..16
}

static void liens_off(void* m, int nd)
{
    for (int d = 0; d < nd; ++d)
        for (int l = 0; l < aeolus_nb_liens(m, d); ++l)
            aeolus_lien(m, d, l, 0);
}

static void activer_lien(void* m, int d, const char* vers)
{
    auto* e = moteur(m);
    for (int l = 0; l < aeolus_nb_liens(m, d); ++l) {
        auto& lien = e->getDivisionByIndex(d)->getLinkByIndex(l);
        if (lien.division->getName() == juce::String(vers))
            aeolus_lien(m, d, l, 1);
    }
}

// Joue n notes sur un canal, rend, puis compte les voix tenues de chaque note.
static int scenario(const char* nom, int canal, bool jeu_sur_I, bool lien_I_II, bool lien_I_III, bool lien_II_III)
{
    const int sr = 48000;
    void* m = aeolus_creer(sr);
    if (m == nullptr) {
        std::printf("ECHEC : aeolus_creer\n");
        return 1;
    }

    auto* e = moteur(m);
    const int dI = trouver_division(e, "Manual I");
    const int dII = trouver_division(e, "Manual II");
    const int dIII = trouver_division(e, "Manual III");
    const int dP = trouver_division(e, "Pedal");

    if (dI < 0 || dII < 0 || dIII < 0 || dP < 0) {
        std::printf("ECHEC : divisions introuvables\n");
        aeolus_detruire(m);
        return 1;
    }

    registration_orgue(m, e, dI, dII, dIII, dP);
    masques_orgue(m, dI, dII, dIII, dP);

    const int nd = aeolus_nb_divisions(m);
    liens_off(m, nd);
    if (lien_I_II)
        activer_lien(m, dI, "Manual II");
    if (lien_I_III)
        activer_lien(m, dI, "Manual III");
    if (lien_II_III)
        activer_lien(m, dII, "Manual III");

    if (jeu_sur_I) {
        const int idx = trouver_jeu(e, dI, "Open Diapason\n8");
        if (idx >= 0)
            aeolus_jeu(m, dI, idx, 1);
    }

    aeolus_qualite(m, 0, 0); // pas de bruit d'attaque
    aeolus_qualite(m, 1, 0); // pas d'instabilité
    aeolus_qualite(m, 2, 1); // spatialisation 1
    aeolus_qualite(m, 3, 0); // polyphonie illimitée

    // Note A, puis B, puis l'accord, sur le canal de Manual I (canal 2).
    const int notes[] = { 60, 64, 67, 72, 76 };

    std::printf("\n== %s (jeu sur I=%d, lien I->II=%d, lien I->III=%d, lien II->III=%d)\n",
                nom, jeu_sur_I, lien_I_II, lien_I_III, lien_II_III);

    int precedent = 0;
    for (int i = 0; i < 5; ++i) {
        note_on(m, canal, notes[i]);
        rendre(m, 4);

        const int tenuesIII = tenues(e, dIII, notes[i]);
        const int tenuesII = tenues(e, dII, notes[i]);
        const int tenuesI = tenues(e, dI, notes[i]);

        std::printf("  après note %d : I=%d II=%d III=%d\n",
                    notes[i], tenuesI, tenuesII, tenuesIII);

        if (i == 0) {
            verifier(tenuesIII > 0 || tenuesII > 0 || tenuesI > 0,
                     "la première note tenue sonne");
            precedent = tenuesI + tenuesII + tenuesIII;
            verifier(precedent > 0, "au moins une voix après la première note");
            if (lien_I_III || lien_II_III)
                verifier(tenuesIII > 0, "Manual III sonne par l'accouplement");
            if (lien_I_II)
                verifier(tenuesII > 0, "Manual II sonne par l'accouplement");
            if (jeu_sur_I)
                verifier(tenuesI > 0, "Manual I sonne par son propre jeu");
        } else {
            verifier(tenuesIII > 0 || tenuesII > 0 || tenuesI > 0,
                     "chaque note tenue garde au moins une voix");
        }
    }

    // Après cinq notes tenues, chaque note doit encore voiser.
    for (int i = 0; i < 5; ++i) {
        const int total = tenues(e, dI, notes[i]) + tenues(e, dII, notes[i])
                        + tenues(e, dIII, notes[i]);
        if (total == 0) {
            std::printf("  note %d perdue après l'accord\n", notes[i]);
            ++echecs;
        }
    }

    // Relâchement : toutes les voix doivent finir par s'éteindre.
    for (int i = 0; i < 5; ++i)
        note_off(m, canal, notes[i]);
    rendre(m, 400);

    int restantes = 0;
    for (int d = 0; d < nd; ++d) {
        for (auto* v = e->getDivisionByIndex(d)->getActiveVoices().first();
             v != nullptr; v = v->next()) {
            if (v->isActive())
                ++restantes;
        }
    }
    std::printf("  voix tenues après relâchement : %d\n", restantes);
    verifier(restantes == 0, "toutes les voix se relâchent");

    aeolus_detruire(m);
    return 0;
}

int main()
{
    scenario("canal 1 Manual II (témoin polyphone)", 1, false, false, false, false);
    scenario("canal 4 tous claviers (témoin)", 4, false, false, false, false);
    scenario("canal 2 Manual I -> III", 2, false, false, true, false);
    scenario("canal 2 Manual I -> II et III", 2, false, true, true, false);
    scenario("canal 2 Manual I -> II -> III (chaîne)", 2, false, true, false, true);
    scenario("canal 2 Manual I -> III avec jeu sur I", 2, true, false, true, false);

    if (echecs == 0) {
        std::printf("\npolyphonie : tous les contrôles OK\n");
        return 0;
    }
    std::printf("\npolyphonie : %d échec(s)\n", echecs);
    return 1;
}
