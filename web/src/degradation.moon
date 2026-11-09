-- Règles pures du mode dégradé audio : l'axe audio n'est dégradé que si
-- aucun backend audio n'existe réellement pour la plate-forme, ou si
-- ORGANUM_SANS_BACKEND=1 le force pour les tests. La décision ne se fonde
-- plus sur le seul nom de plate-forme : macOS a désormais le backend socket
-- (assistant CoreAudio), et c'est organum.audio_supportee() qui fait foi.
-- `supportee` vaut nil quand le module natif ne publie pas encore la
-- fonction : on retombe alors sur l'ancienne règle par nom de plate-forme.
-- L'axe MIDI est décidé séparément (midi_actif.moon).

sans_backend = (plateforme, supportee) ->
  if supportee == nil
    plateforme != "linux" and plateforme != "windows"
  else
    supportee != true

detecter = (plateforme, force, supportee) ->
  if force == "1"
    true, "forcé par ORGANUM_SANS_BACKEND"
  elseif sans_backend plateforme, supportee
    true, "aucun backend audio pour « #{plateforme} »"
  else
    false, nil

{ :sans_backend, :detecter }
