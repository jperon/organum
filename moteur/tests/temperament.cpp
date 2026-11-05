// Test du tempérament : API C, tuyaux réellement sélectionnés après retune,
// durée du recalcul et absence de blocage du rendu (le calcul se fait hors
// du fil audio, sur le jeu de tuyaux parallèle).
#include <JuceHeader.h>
#include "aeolus_c.h"
#include "aeolus/engine.h"
#include "aeolus/rankwave.h"
#include "aeolus/scale.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

using namespace juce;
AEOLUS_USING_NAMESPACE;

static int echecs = 0;

static void verifier(bool condition, const char* message)
{
    if (!condition) {
        std::printf("ECHEC : %s\n", message);
        ++echecs;
    }
}

static Rankwave* rangwave_pour_note(int note)
{
    auto* g = EngineGlobal::getInstance();
    for (int i = 0; i < g->getStopsCount(); ++i) {
        auto* rw = g->getStop(i);
        if (rw && rw->isForNote(note))
            return rw;
    }
    return nullptr;
}

static float frequence_tuyau(int note)
{
    auto* rw = rangwave_pour_note(note);
    if (!rw) return -1.0f;
    auto etat = rw->trigger(note);
    if (etat.pipewave == nullptr) return -1.0f;
    return etat.pipewave->getFreqency();
}

static double maintenant_s()
{
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

int main()
{
    const int sr = 48000;

    verifier(aeolus_nb_temperaments() == 11, "onze tempéraments");
    for (int i = 0; i < aeolus_nb_temperaments(); ++i) {
        const char* nom = aeolus_nom_temperament(i);
        verifier(nom != nullptr && nom[0] != '\0', "nom de tempérament non vide");
        std::free((void*)nom);
    }
    verifier(aeolus_nom_temperament(-1) == nullptr, "tempérament -1 refusé");
    verifier(aeolus_nom_temperament(11) == nullptr, "tempérament 11 refusé");

    void* moteur = aeolus_creer(sr);
    if (!moteur) {
        std::printf("ECHEC : aeolus_creer\n");
        return 1;
    }
    verifier(aeolus_temperament(moteur, 11) == -1, "application 11 refusée");
    verifier(aeolus_temperament(moteur, -1) == -1, "application -1 refusée");

    // Note 60 (do) : le rapport do/la diffère entre égal et mésotonique.
    verifier(aeolus_temperament(moteur, (int)Scale::EqualTemp) == 0,
             "application égal");
    const float f_egal = frequence_tuyau(60);
    verifier(f_egal > 0.0f, "tuyau du do trouvé (égal)");

    verifier(aeolus_temperament(moteur, (int)Scale::MeanQuart) == 0,
             "application mésotonique");
    const float f_mesoton = frequence_tuyau(60);
    verifier(f_mesoton > 0.0f, "tuyau du do trouvé (mésotonique)");
    verifier(std::fabs(f_mesoton - f_egal) > 1e-3f,
             "la fréquence du tuyau en service change");

    Scale egal(Scale::EqualTemp), mesoton(Scale::MeanQuart);
    const float rapport_attendu =
        mesoton.getFrequencyForMidoNote(60, 440.0f) /
        egal.getFrequencyForMidoNote(60, 440.0f);
    const float rapport_obtenu = f_mesoton / f_egal;
    verifier(std::fabs(rapport_obtenu - rapport_attendu) < 1e-5f,
             "le rapport correspond à la table de scale.cpp");

    // Durée du recalcul, rendu concurrent : le fil de rendu ne doit pas être
    // bloqué par l'application (les tuyaux parallèles permettent la bascule).
    unsigned char on[3] = { 0x90, 60, 100 };
    aeolus_midi(moteur, on, 3);
    std::atomic<bool> fin{false};
    std::atomic<long long> pire_rendu_ns{0};
    std::atomic<long long> rendus{0};
    std::vector<float> l(512, 0.0f), r(512, 0.0f);
    std::thread rendu([&]() {
        while (!fin.load(std::memory_order_relaxed)) {
            auto t0 = std::chrono::steady_clock::now();
            aeolus_rendre(moteur, l.data(), r.data(), (int)l.size());
            auto t1 = std::chrono::steady_clock::now();
            const long long d = std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count();
            long long ancien = pire_rendu_ns.load(std::memory_order_relaxed);
            while (d > ancien &&
                   !pire_rendu_ns.compare_exchange_weak(ancien, d,
                       std::memory_order_relaxed))
                ;
            rendus.fetch_add(1, std::memory_order_relaxed);
        }
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    const long long pire_avant = pire_rendu_ns.load();
    const auto avant = rendus.load();

    double duree_max = 0.0, duree_totale = 0.0;
    for (int i = 0; i < aeolus_nb_temperaments(); ++i) {
        const double t0 = maintenant_s();
        const int ok = aeolus_temperament(moteur, i);
        const double d = maintenant_s() - t0;
        duree_max = std::max(duree_max, d);
        duree_totale += d;
        verifier(ok == 0, "application d'un tempérament valide");
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    const long long pire_apres = pire_rendu_ns.load();
    const auto apres = rendus.load();
    fin.store(true);
    rendu.join();

    std::printf("durée recalcul : max %.3f ms, moyenne %.3f ms (11 tempéraments)\n",
                duree_max * 1000.0, duree_totale / aeolus_nb_temperaments() * 1000.0);
    std::printf("rendu concurrent : %lld tampons avant, %lld pendant/après ; "
                "pire tampon avant %.3f ms, global %.3f ms\n",
                (long long)(apres - avant), (long long)apres,
                pire_avant / 1e6, pire_apres / 1e6);
    std::printf("fréquence do (égal) = %.6f Hz, (mésotonique) = %.6f Hz, "
                "rapport = %.9f (attendu %.9f)\n",
                f_egal, f_mesoton, rapport_obtenu, rapport_attendu);
    verifier(apres > avant, "le rendu a continué pendant le recalcul");

    aeolus_detruire(moteur);

    if (echecs == 0) {
        std::printf("tempérament : tous les contrôles OK\n");
        return 0;
    }
    std::printf("tempérament : %d échec(s)\n", echecs);
    return 1;
}
