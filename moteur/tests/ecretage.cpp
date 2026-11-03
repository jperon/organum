// Mesure de l'écrêtage de la sortie du moteur sur un accord dense.
//
// Le programme rend le même accord deux fois, avec puis sans limiteur, et
// imprime pour chaque canal le pic absolu et le nombre d'échantillons dont
// la valeur absolue atteint 1.0. C'est la preuve hors ligne que le limiteur
// évite la saturation dure du pilote audio. Cible : `make -C moteur ecretage`.
#include <JuceHeader.h>
#include "aeolus_c.h"
#include "aeolus/dsp/limiter.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace
{
    constexpr int SR = 44100;
    constexpr int DUREE = SR * 3 / 2;  // 1,5 s
    constexpr int BLOC = 512;

    struct Mesure
    {
        double picG{ 0.0 }, picD{ 0.0 };
        long eclipsesG{ 0 }, eclipsesD{ 0 };
        double rms{ 0.0 };
        double ms{ 0.0 };
    };

    Mesure mesurer(const std::vector<float>& g, const std::vector<float>& d,
                   double ms)
    {
        Mesure m;
        double somme = 0.0;
        for (size_t i = 0; i < g.size(); ++i) {
            const double ag = std::abs((double)g[i]);
            const double ad = std::abs((double)d[i]);
            if (ag > m.picG) m.picG = ag;
            if (ad > m.picD) m.picD = ad;
            if (ag >= 1.0) ++m.eclipsesG;
            if (ad >= 1.0) ++m.eclipsesD;
            somme += ag * ag + ad * ad;
        }
        m.rms = std::sqrt(somme / (2.0 * (double)g.size()));
        m.ms = ms;
        return m;
    }

    void bench_limiteur()
    {
        constexpr int N = SR * 20;
        std::vector<float> in(N), out(N);
        for (int i = 0; i < N; ++i)
            in[i] = 0.5f * std::sin(2.0 * 3.14159265358979 * 440.0 * i / SR)
                    + 0.3f * std::sin(2.0 * 3.14159265358979 * 660.0 * i / SR);

        aeolus::dsp::Limiter::Spec spec;
        spec.threshold = 0.8f;
        spec.attack = 1.0f;
        spec.release = 1.0f / SR;
        spec.sustain = SR / 2;
        aeolus::dsp::Limiter::State state;
        aeolus::dsp::Limiter::resetState(spec, state);

        constexpr int tours = 50;
        for (int i = 0; i < 3; ++i)
            aeolus::dsp::Limiter::process(spec, state, in.data(), out.data(), N);
        const auto debut = std::chrono::steady_clock::now();
        for (int i = 0; i < tours; ++i)
            aeolus::dsp::Limiter::process(spec, state, in.data(), out.data(), N);
        const auto fin = std::chrono::steady_clock::now();
        const double ns = std::chrono::duration<double, std::nano>(fin - debut).count()
                          / (double)(tours * N);
        std::printf("Limiteur : %.2f ns/échantillon, soit %.3f %% d'un cœur à 48 kHz\n",
                    ns, ns * 48000.0 / 1e7);
    }

    Mesure jouer(int limiteur, bool accord)
    {
        void* moteur = aeolus_creer(SR);
        if (!moteur) {
            std::fprintf(stderr, "aeolus_creer a échoué\n");
            std::exit(1);
        }
        aeolus_limiteur(moteur, limiteur);

        if (accord) {
            // Plein jeu sur les quatre claviers : plusieurs rangs par division,
            // pour que la somme dépasse largement l'unité.
            const int rangs[] = { 6, 6, 6, 5 };
            for (int div = 0; div < aeolus_nb_divisions(moteur); ++div) {
                const int n = aeolus_nb_jeux(moteur, div);
                const int souhaite = div < 4 ? rangs[div] : 4;
                for (int j = 0; j < n && j < souhaite; ++j)
                    aeolus_jeu(moteur, div, j, 1);
            }

            // Accord de huit notes, réparti sur deux octaves.
            const int notes[] = { 36, 48, 52, 55, 60, 64, 67, 72 };
            for (int note : notes) {
                unsigned char on[] = { 0x90, (unsigned char)note, 100 };
                aeolus_midi(moteur, on, 3);
            }
        } else {
            // Note seule, un seul jeu : doit rester identique avec limiteur.
            if (aeolus_nb_divisions(moteur) > 0 && aeolus_nb_jeux(moteur, 0) > 0)
                aeolus_jeu(moteur, 0, 0, 1);
            unsigned char on[] = { 0x90, 60, 100 };
            aeolus_midi(moteur, on, 3);
        }

        std::vector<float> g(DUREE, 0.0f), d(DUREE, 0.0f);
        const auto debut = std::chrono::steady_clock::now();
        for (int i = 0; i < DUREE; i += BLOC) {
            const int n = std::min(BLOC, DUREE - i);
            aeolus_rendre(moteur, g.data() + i, d.data() + i, n);
        }
        const auto fin = std::chrono::steady_clock::now();
        const double ms = std::chrono::duration<double, std::milli>(fin - debut).count();

        aeolus_detruire(moteur);
        return mesurer(g, d, ms);
    }
}

int main()
{
    const Mesure sans = jouer(0, true);
    const Mesure avec = jouer(1, true);
    const Mesure noteSans = jouer(0, false);
    const Mesure noteAvec = jouer(1, false);

    std::printf("Sans limiteur : pic G %.6f, pic D %.6f ; écrêtés G %ld, D %ld ; "
                "RMS %.6f ; rendu %.1f ms\n",
                sans.picG, sans.picD, sans.eclipsesG, sans.eclipsesD,
                sans.rms, sans.ms);
    std::printf("Avec limiteur : pic G %.6f, pic D %.6f ; écrêtés G %ld, D %ld ; "
                "RMS %.6f ; rendu %.1f ms\n",
                avec.picG, avec.picD, avec.eclipsesG, avec.eclipsesD,
                avec.rms, avec.ms);
    std::printf("Note seule (sans/avec) : pic G %.6f/%.6f, pic D %.6f/%.6f\n",
                noteSans.picG, noteAvec.picG, noteSans.picD, noteAvec.picD);
    bench_limiteur();

    int echec = 0;
    if (sans.eclipsesG == 0 && sans.eclipsesD == 0) {
        std::fprintf(stderr,
                     "accord non écrêté sans limiteur : test non concluant\n");
        echec = 1;
    }
    if (avec.eclipsesG != 0 || avec.eclipsesD != 0
        || avec.picG > 0.85 || avec.picD > 0.85) {
        std::fprintf(stderr,
                     "limiteur insuffisant : pic > 0.85 ou échantillon écrêté\n");
        echec = 1;
    }
    // Une note seule reste sous le seuil : le limiteur n'a rien à faire.
    // Les deux rendus ne sont pas comparés à l'échantillon près, car le
    // chiff des jeux introduit un bruit aléatoire d'une instance à l'autre.
    if (noteSans.picG >= 0.8 || noteSans.picD >= 0.8
        || noteAvec.picG >= 0.8 || noteAvec.picD >= 0.8) {
        std::fprintf(stderr, "note seule au-dessus du seuil : cas non concluant\n");
        echec = 1;
    }

    return echec;
}
