// Tables et énumération des tempéraments (aeolus/scale.cpp), sans moteur ni
// JUCE lié : getNameForType n'est pas appelé (il faudrait juce_core).
#include "aeolus/scale.h"

#include <cmath>
#include <cstdio>

// JUCE exige un symbole sentinelle quand les unités ne sont pas toutes
// compilées dans le même mode (ici, pas de juce_core lié).
namespace juce {
this_will_fail_to_link_if_some_of_your_compile_units_are_built_in_release_mode::
  this_will_fail_to_link_if_some_of_your_compile_units_are_built_in_release_mode() noexcept {}
}

static int echecs;

static void verifier(bool condition, const char* message) {
  if (!condition) {
    std::printf("ÉCHEC : %s\n", message);
    ++echecs;
  }
}

int main() {
  using aeolus::Scale;
  verifier((int)Scale::First == 0, "First = 0");
  verifier((int)Scale::Pythagorean == 0, "Pythagorean = 0");
  verifier((int)Scale::MeanQuart == 1, "MeanQuart = 1");
  verifier((int)Scale::Werckm3 == 2, "Werckm3 = 2");
  verifier((int)Scale::Kirnberg3 == 3, "Kirnberg3 = 3");
  verifier((int)Scale::WellTemp == 4, "WellTemp = 4");
  verifier((int)Scale::EqualTemp == 5, "EqualTemp = 5");
  verifier((int)Scale::Ahrend == 6, "Ahrend = 6");
  verifier((int)Scale::Vallotti == 7, "Vallotti = 7");
  verifier((int)Scale::Kellner == 8, "Kellner = 8");
  verifier((int)Scale::Lehman == 9, "Lehman = 9");
  verifier((int)Scale::Pure == 10, "Pure = 10");
  verifier((int)Scale::Total == 11, "Total = 11");

  // La table de chaque tempérament : 12 rapports croissants, do = 1, et une
  // octave exacte entre le do et le do suivant (les tables sont normalisées
  // sur 12 demi-tons, le do à l'index 0).
  for (int i = 0; i < (int)Scale::Total; ++i) {
    Scale s((Scale::Type)i);
    const Scale::Table& t = s.getTable();
    verifier(t[0] == 1.0f, "table : do = 1");
    for (int n = 1; n < 12; ++n) {
      verifier(std::isfinite(t[n]) && t[n] > 0.0f, "table : rapport fini et positif");
      verifier(t[n] > t[n - 1], "table : rapports croissants");
    }
  }

  // Valeurs de référence lues dans scale.cpp : un décalage de colonne ou un
  // libellé interverti se voit.
  const float reference[11][12] = {
    {1.0f, 1.06787109f, 1.125f, 1.18518519f, 1.265625f, 1.33333333f,
     1.42382812f, 1.5f, 1.60180664f, 1.6875f, 1.77777778f, 1.8984375f},
    {1.0f, 1.0449067f, 1.1180340f, 1.1962790f, 1.25f, 1.3374806f,
     1.3975425f, 1.4953488f, 1.5625f, 1.6718508f, 1.7888544f, 1.8691860f},
    {1.0f, 1.05349794f, 1.11740331f, 1.18518519f, 1.25282725f, 1.33333333f,
     1.40466392f, 1.49492696f, 1.58024691f, 1.67043633f, 1.77777778f, 1.87924088f},
    {1.0f, 1.05349794f, 1.11848107f, 1.18518519f, 1.25000021f, 1.33333333f,
     1.40625f, 1.49542183f, 1.58024691f, 1.67176840f, 1.77777778f, 1.875f},
    {1.0f, 1.05468828f, 1.12246205f, 1.18652432f, 1.25282725f, 1.33483985f,
     1.40606829f, 1.49830708f, 1.58203242f, 1.67705161f, 1.77978647f, 1.87711994f},
    {1.0f, 1.05946309f, 1.12246205f, 1.18920712f, 1.25992105f, 1.33483985f,
     1.41421356f, 1.49830708f, 1.58740105f, 1.68179283f, 1.78179744f, 1.88774863f},
    {1.0f, 1.05064661f, 1.11891853f, 1.18518519f, 1.25197868f, 1.33695184f,
     1.40086215f, 1.49594019f, 1.57596992f, 1.67383521f, 1.78260246f, 1.87288523f},
    {1.0f, 1.05647631f, 1.12035146f, 1.18808855f, 1.25518740f, 1.33609659f,
     1.40890022f, 1.49689777f, 1.58441623f, 1.67705160f, 1.78179744f, 1.87888722f},
    {1.0f, 1.05349794f, 1.11891853f, 1.18518519f, 1.25197868f, 1.33333333f,
     1.40466392f, 1.49594019f, 1.58024691f, 1.67383521f, 1.77777778f, 1.87796802f},
    {1.0f, 1.05826737f, 1.11992982f, 1.18786496f, 1.25424281f, 1.33634808f,
     1.41102316f, 1.49661606f, 1.58560949f, 1.67610496f, 1.77978647f, 1.88136421f},
    {1.0f, 1.04166667f, 1.125f, 1.1892f, 1.25f, 1.33333333f,
     1.40625f, 1.5f, 1.5874f, 1.66666667f, 1.77777778f, 1.875f},
  };
  for (int i = 0; i < 11; ++i) {
    Scale s((Scale::Type)i);
    const Scale::Table& t = s.getTable();
    for (int n = 0; n < 12; ++n)
      verifier(std::fabs(t[n] - reference[i][n]) < 1e-6f,
               "table : valeur de référence");
  }

  // La fréquence du la (note 69) ne dépend pas du tempérament, et l'octave
  // double exactement. Les autres notes diffèrent d'un tempérament à l'autre.
  for (int i = 0; i < (int)Scale::Total; ++i) {
    Scale s((Scale::Type)i);
    verifier(std::fabs(s.getFrequencyForMidoNote(69, 440.0f) - 440.0f) < 1e-3f,
             "fréquence : la = 440 Hz");
    verifier(std::fabs(s.getFrequencyForMidoNote(81, 440.0f) - 880.0f) < 1e-3f,
             "fréquence : octave doublée");
  }
  Scale pyth((Scale::Pythagorean)), egal((Scale::EqualTemp));
  verifier(std::fabs(pyth.getFrequencyForMidoNote(64, 440.0f) -
                     egal.getFrequencyForMidoNote(64, 440.0f)) > 1e-3f,
           "fréquence : mi diffère entre Pythagoricien et égal");

  if (echecs == 0) {
    std::printf("-- scale_tables : OK\n");
    return 0;
  }
  std::printf("-- scale_tables : %d échec(s)\n", echecs);
  return 1;
}
