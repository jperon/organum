-- Règles pures du mode dégradé audio : l'axe audio n'est dégradé que si
-- aucun backend audio n'existe réellement pour la plate-forme, ou si
-- ORGANUM_SANS_BACKEND=1 le force pour les tests. La décision ne se fonde
-- plus sur le seul nom de plate-forme : macOS a désormais le backend socket
-- (assistant CoreAudio), et c'est organum.audio_supportee() qui fait foi.
-- `supportee` vaut nil quand le module natif ne publie pas encore la
-- fonction : on retombe alors sur l'ancienne règle par nom de plate-forme.
-- L'axe MIDI est décidé séparément (midi_actif.moon).

helper = require "assistant"

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

-- État de l'axe audio à l'exécution, pour l'interface web et la fenêtre
-- native. Quatre situations distinctes, qui n'ont pas le même sens :
--   * aucun backend audio sur cette plate-forme (le son n'est pas prévu) ;
--   * axe audio désactivé (ORGANUM_SANS_BACKEND, ou backend absent alors que
--     la plate-forme en a normalement un) ;
--   * assistant socket absent, ou pas encore connecté (non alarmant) ;
--   * assistant présent mais sans périphérique de sortie (ACK statut 2) ;
--   * organum et assistant de versions de protocole/anneau incompatibles :
--     refus explicite, jamais un silence présenté comme normal.
-- `audio_erreur` est examinée avant `audio_assistant` : un assistant qui
-- répond « aucune sortie audio » ou une version incompatible n'est pas un
-- assistant absent. Renvoie nil, nil quand l'audio fonctionne : aucun
-- message ne doit s'afficher.
etat_audio = (info) ->
  info = info or {}
  supportee = info.supportee
  socket = info.socket == true
  disponible = info.disponible == true
  assistant = tonumber info.assistant
  erreur = tostring info.erreur or ""
  if not socket and supportee != true
    "sans_backend", "Audio non pris en charge sur cette plate-forme."
  elseif info.sans_backend == true
    -- Uniquement le forçage explicite (ORGANUM_SANS_BACKEND=1) ou l'axe coupé
    -- au démarrage. Surtout PAS `not socket` : `socket` ne dit que « backend
    -- socket macOS retenu ». Un backend ALSA ou WinMM opérationnel a
    -- audio_socket = false ; le présenter comme désactivé affichait un
    -- bandeau « Audio désactivé » sur tout Linux fonctionnel.
    "desactive", "Audio désactivé sur cette plate-forme."
  elseif erreur\find "aucune sortie audio", 1, true
    "sans_sortie", "Aucune sortie audio : vérifiez Réglages Système → Son → Sortie."
  elseif (erreur\find "version du protocole audio incompatible", 1, true) or
         (erreur\find "version de l'anneau audio incompatible", 1, true)
    -- Le message brut nomme déjà les deux versions et demande de recompiler.
    "incompatible", erreur
  elseif disponible and info.demarre == false
    -- Production pas encore commencée (ouverture, ou recréation du moteur
    -- pendant un changement de taux) : le silence est explicite, jamais une
    -- famine comptée comme un xrun.
    message = if info.application == true
      "Son suspendu pendant l'application des réglages audio…"
    else
      "Son suspendu : la sortie audio se prépare…"
    "suspendu", message
  elseif disponible
    nil, nil
  else
    -- Assistant absent de l'archive, ou impossible à installer ou à lancer :
    -- le message nomme la cause et le journal, sans accuser l'utilisateur.
    code = helper.message info.assistant_etat, info.assistant_log
    if code
      info.assistant_etat, code
    elseif assistant == 0
      "assistant_absent", "Assistant audio absent : organum ne l'a pas lancé (voir plateforme/macos/LANCEMENT.md)."
    else
      "indisponible", "Audio momentanément indisponible."

{ :sans_backend, :detecter, :etat_audio }
