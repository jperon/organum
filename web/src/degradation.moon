-- Règles pures du mode dégradé audio : une plate-forme sans backend audio
-- (macOS aujourd'hui) garde l'interface web mais ne produit aucun son.
-- L'axe MIDI est décidé séparément (midi_actif.moon) : macOS a désormais un
-- backend MIDI par socket, et `sans_backend` ne désigne donc ici que l'axe
-- audio. ORGANUM_SANS_BACKEND=1 force ce mode pour les tests ; toute autre
-- valeur est ignorée, donc sans effet sur Linux normal.

sans_backend = (plateforme) ->
  plateforme != "linux" and plateforme != "windows"

detecter = (plateforme, force) ->
  if force == "1"
    true, "forcé par ORGANUM_SANS_BACKEND"
  elseif sans_backend plateforme
    true, "aucun backend audio/MIDI pour « #{plateforme} »"
  else
    false, nil

{ :sans_backend, :detecter }
