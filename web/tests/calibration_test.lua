package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local cal = require "calibration"

-- Constantes reprises de l'ancienne décision C++ (non modifiées).
aide.egal(cal.K_RESTE, 1.7, "constante K_RESTE")
aide.egal(cal.FRACTION_ECHEANCE, 0.6, "constante FRACTION_ECHEANCE")
aide.egal(cal.NIVEAU_SPATIAL[1], 0, "table spatialisation niveau 0")
aide.egal(cal.NIVEAU_SPATIAL[4], 2, "table spatialisation niveau 3")
aide.egal(cal.NIVEAU_POLYPHONIE[1], 64, "table polyphonie niveau 0")
aide.egal(cal.NIVEAU_POLYPHONIE[4], 0, "table polyphonie niveau 3 (illimité)")
aide.egal(cal.NIVEAU_TETE[1], 0, "table tête niveau 0")
aide.egal(cal.NIVEAU_TETE[3], 1, "table tête niveau 2")

-- Jeux de mesures et sorties attendues, calculées par la référence C++
-- (copie fidèle de l'ancienne boucle de moteur/aeolus/calibration.cpp,
-- compilée à part) : niveau, tête, estimations des niveaux 0..3.
local jeux = {
  {
    nom = "rapide", taux = 48000, periode = 512,
    spat2 = 0.05, spat1 = 0.02, revt = 0.5, revs = 0.4,
    voix = 250, forcee = false,
    niveau = 3, tete = 1,
    est = {0.443520000000, 0.507520000000, 0.661280000000, 0.770000000000},
  },
  {
    nom = "moyen", taux = 48000, periode = 512,
    spat2 = 0.8, spat1 = 0.3, revt = 2.0, revs = 1.5,
    voix = 250, forcee = false,
    niveau = 3, tete = 1,
    est = {2.196320000000, 3.199840000000, 4.549760000000, 6.320000000000},
  },
  {
    nom = "lent", taux = 48000, periode = 512,
    spat2 = 8.0, spat1 = 3.0, revt = 20.0, revs = 15.0,
    voix = 250, forcee = false,
    niveau = 0, tete = 0,
    est = {21.963200000000, 31.998400000000, 45.497600000000, 63.200000000000},
  },
  {
    nom = "periode128", taux = 48000, periode = 128,
    spat2 = 0.3, spat1 = 0.1, revt = 1.0, revs = 0.8,
    voix = 250, forcee = false,
    niveau = 3, tete = 1,
    est = {0.865280000000, 0.956160000000, 1.234240000000, 1.405000000000},
  },
  {
    nom = "forcee600", taux = 48000, periode = 512,
    spat2 = 0.8, spat1 = 0.3, revt = 2.0, revs = 1.5,
    voix = 600, forcee = true,
    niveau = 0, tete = 0,
    est = {8.028000000000, 9.468000000000, 9.968000000000, 12.368000000000},
  },
  {
    nom = "plafond128", taux = 48000, periode = 1024,
    spat2 = 0.8, spat1 = 0.3, revt = 2.0, revs = 1.5,
    voix = 250, forcee = false,
    niveau = 3, tete = 1,
    est = {2.892640000000, 4.899680000000, 7.099520000000, 10.640000000000},
  },
  {
    nom = "limite", taux = 48000, periode = 512,
    spat2 = 0.10, spat1 = 0.0, revt = 0.0, revs = 0.0,
    voix = 250, forcee = false,
    niveau = 3, tete = 1,
    est = {0.087040000000, 0.174080000000, 0.261120000000, 0.540000000000},
  },
  {
    nom = "niveau1", taux = 48000, periode = 512,
    spat2 = 3.0, spat1 = 0.0, revt = 0.0, revs = 0.0,
    voix = 250, forcee = false,
    niveau = 1, tete = 0,
    est = {2.611200000000, 5.222400000000, 7.833600000000, 16.200000000000},
  },
  {
    nom = "niveau2", taux = 48000, periode = 512,
    spat2 = 1.5, spat1 = 0.0, revt = 0.0, revs = 0.0,
    voix = 250, forcee = false,
    niveau = 2, tete = 1,
    est = {1.305600000000, 2.611200000000, 3.916800000000, 8.100000000000},
  },
}

for _, j in ipairs(jeux) do
  local mesures = {
    taux = j.taux,
    periode = j.periode,
    echeance_ms = j.periode / j.taux * 1000,
    cout_spat2_us = j.spat2,
    cout_spat1_us = j.spat1,
    cout_reverb_tete_ms = j.revt,
    cout_reverb_sans_tete_ms = j.revs,
    voix_ref = j.voix,
    voix_forcee = j.forcee,
  }
  local d = cal.choisir(mesures)
  aide.verifie(type(d) == "table", j.nom .. " : décision rendue")
  if type(d) == "table" then
    aide.egal(d.niveau, j.niveau, j.nom .. " : niveau")
    aide.egal(d.tete_reverb, j.tete == 1, j.nom .. " : tête")
    for i = 1, 4 do
      aide.presque(d.estimation_ms[i], j.est[i], 1.0e-9,
        j.nom .. " : estimation niveau " .. (i - 1))
    end
  end
end

-- Cas d'erreur : aucune décision inventée sur des mesures incomplètes.
local d, err = cal.choisir(nil)
aide.egal(d, nil, "mesures absentes : nil")
aide.verifie(type(err) == "string", "mesures absentes : message")
d, err = cal.choisir({periode = 512})
aide.egal(d, nil, "mesure incomplète : nil")
d, err = cal.choisir({periode = 0, echeance_ms = 0, cout_spat2_us = 0,
  cout_spat1_us = 0, cout_reverb_tete_ms = 0, cout_reverb_sans_tete_ms = 0,
  voix_ref = 250})
aide.egal(d, nil, "période nulle : nil")

-- voix_forcee absent : traité comme faux (plafond appliqué), comme en C++.
local mesures = {
  periode = 512, echeance_ms = 512 / 48000 * 1000,
  cout_spat2_us = 0.8, cout_spat1_us = 0.3,
  cout_reverb_tete_ms = 2.0, cout_reverb_sans_tete_ms = 1.5,
  voix_ref = 600,
}
local sans = cal.choisir(mesures)
mesures.voix_forcee = true
local avec = cal.choisir(mesures)
aide.verifie(sans.estimation_ms[1] < avec.estimation_ms[1],
  "voix_forcee absent applique le plafond")

aide.termine()
