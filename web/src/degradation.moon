-- Règles pures du mode dégradé : une plate-forme sans backend audio ni MIDI
-- (macOS aujourd'hui) garde l'interface web mais ne produit aucun son.
-- ORGANUM_SANS_BACKEND=1 force ce mode pour les tests ; toute autre valeur
-- est ignorée, donc sans effet sur Linux normal.

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
