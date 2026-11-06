-- Décision de la calibration automatique de la qualité (étape Q3a).
--
-- Module pur : il ne mesure rien et n'appelle ni le moteur ni le module
-- « organum ». Les mesures sont prises en C++ (moteur/aeolus/calibration.cpp)
-- puis passées ici ; ce fichier applique le modèle de coût de la
-- spécification et choisit le niveau 0..3 et la tête de réverbération.
--
-- Le modèle est inchangé : les constantes et les tables reprennent celles de
-- l'ancienne décision C++.

K_RESTE = 1.7
FRACTION_ECHEANCE = 0.6

-- Table de la spécification §3.
NIVEAU_SPATIAL = {0, 1, 1, 2}
NIVEAU_POLYPHONIE = {64, 128, 192, 0}  -- 0 = illimité
NIVEAU_TETE = {0, 0, 1, 1}

-- Renvoie {niveau, tete_reverb, estimation_ms}, ou nil et un message.
-- mesures : taux, periode, echeance_ms, cout_spat2_us, cout_spat1_us,
--           cout_reverb_tete_ms, cout_reverb_sans_tete_ms, voix_ref,
--           voix_forcee (facultatif).
choisir = (mesures) ->
  return nil, "mesures absentes" unless type(mesures) == "table"
  obligatoires = {
    "periode", "echeance_ms", "cout_spat2_us", "cout_spat1_us"
    "cout_reverb_tete_ms", "cout_reverb_sans_tete_ms", "voix_ref"
  }
  for nom in *obligatoires
    return nil, "mesure absente : #{nom}" unless type(mesures[nom]) == "number"
  return nil, "période invalide" unless mesures.periode > 0

  reste_us = K_RESTE * mesures.cout_spat2_us
  ratio_periode = mesures.periode / 64
  estimation_ms = {}
  meilleur = 0

  for niveau = 0, 3
    plafond = NIVEAU_POLYPHONIE[niveau + 1]
    voix = mesures.voix_ref
    if not mesures.voix_forcee and plafond > 0 and voix > plafond
      voix = plafond

    cout_spatial_us = 0
    if NIVEAU_SPATIAL[niveau + 1] == 2
      cout_spatial_us = mesures.cout_spat2_us
    elseif NIVEAU_SPATIAL[niveau + 1] == 1
      cout_spatial_us = mesures.cout_spat1_us

    cout_voix_ms = voix * (cout_spatial_us + reste_us) * ratio_periode / 1000
    cout_reverb_ms = 0
    if NIVEAU_TETE[niveau + 1] == 1
      cout_reverb_ms = mesures.cout_reverb_tete_ms
    else
      cout_reverb_ms = mesures.cout_reverb_sans_tete_ms

    estimation_ms[niveau + 1] = cout_voix_ms + cout_reverb_ms
    if estimation_ms[niveau + 1] <= FRACTION_ECHEANCE * mesures.echeance_ms
      meilleur = niveau

  {
    niveau: meilleur
    tete_reverb: NIVEAU_TETE[meilleur + 1] == 1
    estimation_ms: estimation_ms
  }

{
  :K_RESTE, :FRACTION_ECHEANCE
  :NIVEAU_SPATIAL, :NIVEAU_POLYPHONIE, :NIVEAU_TETE
  :choisir
}
