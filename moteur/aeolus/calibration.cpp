// Micro-banc autonome de calibration de la qualité (étape Q3a).
//
// Aucune instance d'aeolus::Engine n'est créée : on mesure les classes dsp
// réelles (SpatialSource, BiquadFilter, Convolver) sur des données factices
// pseudo-aléatoires, puis on applique le modèle de coût de la spécification.
//
// Hypothèses documentées (voir aussi rapport-Q3a.md) :
//  - Le coût « reste » (lecture de la table d'onde, bruit d'attaque, mélange,
//    gestion de voix...) est supposé proportionnel au coût de la spatialisation
//    complète : reste = K_RESTE * cout_spat2. K_RESTE = 1,7 est mesuré sur le
//    banc de charge de la machine de développement (8,6 ms niveau 2 dont
//    3,2 ms de spatialisation complète, 5,4 ms de reste pour ~600 voix).
//  - Voix de référence : 250. Un accord de 6 notes sur deux claviers fait
//    252 voix, plein jeu typique visé par la spécification ; le modèle ne
//    sait pas combien de voix seront réellement jouées.
//  - On exige que le temps estimé reste ≤ 60 % de l'échéance : marge pour les
//    pics (release, vol de voix, ordonnanceur) et pour l'imprécision du modèle.
//
// Ce que le modèle ne sait PAS : le nombre réel de voix, la charge des autres
// processus, les accès mémoire froids, le coût du Worker de convolution sur
// l'autre cœur, ni les variations de fréquence du processeur. La calibration
// est faite une fois au démarrage, sans dégradation en cours de jeu.

#include "calibration.h"

#include "aeolus/globals.h"
#include "aeolus/dsp/convolver.h"
#include "aeolus/dsp/filter.h"
#include "aeolus/dsp/spatial.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <vector>

AEOLUS_USING_NAMESPACE

namespace {

using Horloge = std::chrono::steady_clock;

double maintenant_ms()
{
    return std::chrono::duration<double, std::milli>(
               Horloge::now().time_since_epoch())
        .count();
}

// Générateur pseudo-aléatoire xorshift (pas juce::Random).
struct Alea
{
    uint32_t etat;
    explicit Alea(uint32_t graine) : etat(graine ? graine : 0x12345678u) {}

    uint32_t suivant()
    {
        uint32_t x = etat;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        etat = x;
        return x;
    }

    // Valeur dans [-1, 1).
    float flottant()
    {
        return (float)((double)suivant() / 2147483648.0 - 1.0);
    }
};

// Exécute `fn` plusieurs fois et renvoie la DURÉE MINIMALE observée, en ms.
// Robuste au bruit de la machine (un pic d'ordonnancement n'abaisse jamais le
// minimum). Borné à la fois en nombre de répétitions et en temps.
double minimum_ms(const std::function<void()>& fn,
                  double budget_ms,
                  int repetitions_min = 3,
                  int repetitions_max = 200)
{
    double meilleur = 1.0e300;
    const double debut = maintenant_ms();
    int repetitions = 0;

    do {
        const double t0 = maintenant_ms();
        fn();
        const double t1 = maintenant_ms();
        const double d = t1 - t0;
        if (d < meilleur)
            meilleur = d;
        ++repetitions;
    } while ((repetitions < repetitions_min
              || maintenant_ms() - debut < budget_ms)
             && repetitions < repetitions_max);

    return meilleur;
}

// Coût d'une voix pour SpatialSource::process sur une sous-trame de 64
// échantillons : microsecondes par voix et par sous-trame.
double mesurer_spatial2_us(int taux, double budget_ms)
{
    dsp::SpatialSource source;
    source.setSampleRate((float)taux);
    source.setListenerPosition(0.0f, 0.0f);
    source.setSourcePosition(1.5f, 0.7f);
    source.recalculate();

    constexpr int N = 64;
    float in[N], gauche[N], droite[N];
    Alea alea(0x9e3779b9u);
    for (int i = 0; i < N; ++i) {
        in[i] = alea.flottant();
        gauche[i] = droite[i] = 0.0f;
    }

    constexpr int appels = 256;
    auto lot = [&]() {
        for (int k = 0; k < appels; ++k)
            source.process(in, gauche, droite, N);
    };

    const double ms = minimum_ms(lot, budget_ms);
    return ms * 1000.0 / (double)appels;
}

// Coût du chemin simplifié par voix et sous-trame de 64 échantillons :
// deux multiplications par échantillon (gains gauche/droite) + la part de
// l'unique biquad par division (mesuré par BiquadFilter::process sur un bloc
// de la taille de la période, puis réparti sur voix_ref voix).
double mesurer_spat1_us(int taux, int periode, int voix_ref, double budget_ms)
{
    constexpr int N = 64;
    float in[N], outL[N], outR[N];
    Alea alea(0x85ebca6bu);
    for (int i = 0; i < N; ++i)
        in[i] = alea.flottant();

    volatile float somme = 0.0f;
    const float gainL = 0.71f;
    const float gainR = 0.53f;

    // Lot : `voix_lot` voix × 64 échantillons, deux multiplications chacune.
    constexpr int voix_lot = 512;
    auto lot = [&]() {
        float accum = 0.0f;
        for (int v = 0; v < voix_lot; ++v) {
            for (int i = 0; i < N; ++i) {
                outL[i] = in[i] * gainL;
                outR[i] = in[i] * gainR;
                accum += outL[i] + outR[i];
            }
        }
        somme = accum;
    };

    const double deux_mult_us =
        minimum_ms(lot, budget_ms) * 1000.0 / (double)voix_lot;

    // Biquad commun, un par division, exécuté sur un bloc de `periode`.
    std::vector<float> bloc_in((size_t)periode), bloc_out((size_t)periode);
    for (int i = 0; i < periode; ++i)
        bloc_in[(size_t)i] = alea.flottant();

    dsp::BiquadFilter::Spec spec{};
    spec.type = dsp::BiquadFilter::LowPass;
    spec.sampleRate = (float)taux;
    spec.freq = 18000.0f;
    spec.q = 0.707f;
    spec.dbGain = 0.0f;
    dsp::BiquadFilter::updateSpec(spec);

    dsp::BiquadFilter::State etat{};
    dsp::BiquadFilter::resetState(spec, etat);

    auto lot_biquad = [&]() {
        dsp::BiquadFilter::process(spec, etat, bloc_in.data(), bloc_out.data(),
                                   (size_t)periode);
        somme = bloc_out[(size_t)periode - 1];
    };

    const double biquad_bloc_ms = minimum_ms(lot_biquad, budget_ms);
    const double part_par_voix_us =
        biquad_bloc_ms * 1000.0 / (double)std::max(1, voix_ref)
        * (64.0 / (double)periode);

    return deux_mult_us + part_par_voix_us;
}

// Réponse impulsionnelle synthétique stéréo de ~2,5 s : bruit xorshift
// décroissant exponentiellement (pas de ressource externe).
juce::AudioBuffer<float> fabriquer_reponse(int taux)
{
    const int n = (int)(2.5 * (double)taux);
    juce::AudioBuffer<float> ir(2, n);
    Alea alea(0xdeadbeefu);
    for (int c = 0; c < 2; ++c) {
        float* p = ir.getWritePointer(c);
        for (int i = 0; i < n; ++i) {
            const float enveloppe = std::exp(-6.0f * (float)i / (float)n);
            p[i] = alea.flottant() * enveloppe;
        }
    }
    return ir;
}

// Coût par bloc de `periode` trames de la partie qui s'exécute dans le thread
// appelant, tête zéro latence active (`zero_delay` vrai) ou non. Le Worker de
// convolution, lui, tourne dans son propre thread.
double mesurer_reverb_ms(const juce::AudioBuffer<float>& ir,
                         int taux,
                         int periode,
                         bool zero_delay,
                         double budget_ms)
{
    const int longueur =
        ((ir.getNumSamples() - 1) / (int)dsp::Convolver::BlockSize + 2)
        * (int)dsp::Convolver::BlockSize;

    dsp::Convolver convolveur;
    convolveur.setLength(longueur);
    convolveur.prepareToPlay((float)taux, (size_t)periode);
    convolveur.setZeroDelay(zero_delay);
    convolveur.setIR(ir);
    convolveur.setDryWet(0.0f, 1.0f, true);

    std::vector<float> inL((size_t)periode), inR((size_t)periode);
    std::vector<float> outL((size_t)periode), outR((size_t)periode);
    Alea alea(zero_delay ? 0x27d4eb2fu : 0x165667b1u);
    for (int i = 0; i < periode; ++i) {
        inL[(size_t)i] = alea.flottant();
        inR[(size_t)i] = alea.flottant();
    }

    // Pré-échauffement (mise en route de l'état de convolution).
    for (int i = 0; i < 16; ++i)
        convolveur.process(inL.data(), inR.data(), outL.data(), outR.data(),
                           (size_t)periode);

    constexpr int blocs = 8;
    auto lot = [&]() {
        for (int k = 0; k < blocs; ++k)
            convolveur.process(inL.data(), inR.data(), outL.data(),
                               outR.data(), (size_t)periode);
    };

    const double ms = minimum_ms(lot, budget_ms);
    return ms / (double)blocs;
}

double lire_env_reel(const char* nom, double defaut)
{
    const char* v = std::getenv(nom);
    if (!v || !*v)
        return defaut;
    char* fin = nullptr;
    const double x = std::strtod(v, &fin);
    if (fin == v || !std::isfinite(x) || x <= 0.0)
        return defaut;
    return x;
}

int lire_env_entier(const char* nom, int defaut)
{
    const char* v = std::getenv(nom);
    if (!v || !*v)
        return defaut;
    char* fin = nullptr;
    const long x = std::strtol(v, &fin, 10);
    if (fin == v || x <= 0 || x > 100000)
        return defaut;
    return (int)x;
}

// Constantes du modèle, documentées en tête de fichier.
constexpr double K_RESTE = 1.7;
constexpr int VOIX_REF = 250;
constexpr double FRACTION_ECHEANCE = 0.6;

// Table de la spécification §3.
constexpr int NIVEAU_SPATIAL[4] = {0, 1, 1, 2};
constexpr int NIVEAU_POLYPHONIE[4] = {64, 128, 192, 0}; // 0 = illimité
constexpr int NIVEAU_TETE[4] = {0, 0, 1, 1};

} // namespace

extern "C" int aeolus_calibrer(int taux, int periode, aeolus_calibrage* sortie)
{
    if (!sortie)
        return 0;

    const double debut_calibration = maintenant_ms();

    if (taux <= 0 || periode <= 0) {
        // Paramètres invalides : on renvoie prudemment le niveau le plus bas.
        std::memset(sortie, 0, sizeof(*sortie));
        sortie->niveau = 0;
        sortie->tete_reverb = 0;
        sortie->echeance_ms = 0.0;
        sortie->voix_ref = VOIX_REF;
        return 0;
    }

    // Chaque mesure dispose d'un budget court ; le total reste très en deçà
    // de la garantie dure de 1500 ms (objectif ≤ 400 ms sur l'Atom).
    constexpr double BUDGET_SPATIAL_MS = 80.0;
    constexpr double BUDGET_BIQUAD_MS = 40.0;
    constexpr double BUDGET_REVERB_MS = 120.0;

    int voix_ref = lire_env_entier("ORGANUM_CALIBRATION_VOIX", VOIX_REF);
    // En mode de validation (ORGANUM_CALIBRATION_VOIX défini), on n'applique
    // pas le plafond de polyphonie, afin de pouvoir comparer l'estimation à un
    // banc chargé à n voix.
    const bool voix_forcee = (std::getenv("ORGANUM_CALIBRATION_VOIX") != nullptr);

    double cout_spat2_us =
        mesurer_spatial2_us(taux, BUDGET_SPATIAL_MS);
    double cout_spat1_us =
        mesurer_spat1_us(taux, periode, voix_ref, BUDGET_BIQUAD_MS);

    const juce::AudioBuffer<float> ir = fabriquer_reponse(taux);
    double cout_reverb_tete_ms =
        mesurer_reverb_ms(ir, taux, periode, true, BUDGET_REVERB_MS);
    double cout_reverb_sans_tete_ms =
        mesurer_reverb_ms(ir, taux, periode, false, BUDGET_REVERB_MS);

    // ORGANUM_CALIBRATION_FACTEUR multiplie TOUS les coûts mesurés, sans autre
    // effet : sert aux tests à simuler une machine plus lente.
    const double facteur =
        lire_env_reel("ORGANUM_CALIBRATION_FACTEUR", 1.0);
    cout_spat2_us *= facteur;
    cout_spat1_us *= facteur;
    cout_reverb_tete_ms *= facteur;
    cout_reverb_sans_tete_ms *= facteur;

    const double echeance_ms = (double)periode / (double)taux * 1000.0;
    const double reste_us = K_RESTE * cout_spat2_us;
    const double ratio_periode = (double)periode / 64.0;

    double estimation_ms[4];
    int meilleur = 0;

    for (int niveau = 0; niveau < 4; ++niveau) {
        const int plafond = NIVEAU_POLYPHONIE[niveau];
        int voix = voix_ref;
        if (!voix_forcee && plafond > 0 && voix > plafond)
            voix = plafond;

        double cout_spatial_us = 0.0;
        if (NIVEAU_SPATIAL[niveau] == 2)
            cout_spatial_us = cout_spat2_us;
        else if (NIVEAU_SPATIAL[niveau] == 1)
            cout_spatial_us = cout_spat1_us;

        const double cout_voix_ms =
            (double)voix * (cout_spatial_us + reste_us) * ratio_periode / 1000.0;
        const double cout_reverb_ms = NIVEAU_TETE[niveau]
                                          ? cout_reverb_tete_ms
                                          : cout_reverb_sans_tete_ms;

        estimation_ms[niveau] = cout_voix_ms + cout_reverb_ms;

        if (estimation_ms[niveau] <= FRACTION_ECHEANCE * echeance_ms)
            meilleur = niveau;
    }

    sortie->niveau = meilleur;
    sortie->tete_reverb = NIVEAU_TETE[meilleur];
    sortie->echeance_ms = echeance_ms;
    sortie->cout_spat2_us = cout_spat2_us;
    sortie->cout_spat1_us = cout_spat1_us;
    sortie->cout_reverb_tete_ms = cout_reverb_tete_ms;
    sortie->cout_reverb_sans_tete_ms = cout_reverb_sans_tete_ms;
    for (int i = 0; i < 4; ++i)
        sortie->estimation_ms[i] = estimation_ms[i];
    sortie->voix_ref = voix_ref;
    sortie->duree_calibration_ms = maintenant_ms() - debut_calibration;

    return meilleur;
}
