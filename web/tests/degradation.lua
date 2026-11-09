package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local d = require "degradation"

-- La règle se fonde sur le backend audio réel, plus sur le nom de la
-- plate-forme : macOS a désormais un backend socket.
aide.egal(d.sans_backend("linux", true), false, "linux avec backend audio actif")
aide.egal(d.sans_backend("windows", true), false, "windows avec backend audio actif")
aide.egal(d.sans_backend("macos", true), false, "macos avec backend socket")
aide.egal(d.sans_backend("macos", false), true, "macos sans backend audio")
aide.egal(d.sans_backend("autre", false), true, "plate-forme inconnue sans backend")

-- Repli quand le module natif ne publie pas audio_supportee (supportee nil).
aide.egal(d.sans_backend("linux"), false, "repli : linux a un backend")
aide.egal(d.sans_backend("windows"), false, "repli : windows a un backend")
aide.egal(d.sans_backend("macos"), true, "repli : macos était sans backend")
aide.egal(d.sans_backend("autre"), true, "repli : plate-forme inconnue")

local force, raison = d.detecter("linux", "1", true)
aide.egal(force, true, "ORGANUM_SANS_BACKEND=1 force le mode sur linux")
aide.egal(raison, "forcé par ORGANUM_SANS_BACKEND", "raison du forçage")

local normal = d.detecter("linux", nil, true)
aide.egal(normal, false, "linux avec backend reste normal")
normal = d.detecter("linux", "0", true)
aide.egal(normal, false, "ORGANUM_SANS_BACKEND=0 est ignoré")
normal = d.detecter("linux", "oui", true)
aide.egal(normal, false, "valeur non 1 ignorée")

local degrade, motif = d.detecter("macos", nil, false)
aide.egal(degrade, true, "macos sans backend audio est dégradé")
aide.egal(motif, "aucun backend audio pour « macos »", "raison du mode dégradé")

local actif = d.detecter("macos", nil, true)
aide.egal(actif, false, "macos avec backend socket n'est plus dégradé")

-- etat_audio : quatre situations distinctes, plus le forçage du mode dégradé.
local code, texte = d.etat_audio {supportee = false, socket = false,
  disponible = false, assistant = -1, erreur = ""}
aide.egal(code, "sans_backend", "etat_audio : aucun backend sur la plate-forme")
aide.egal(texte, "Audio non pris en charge sur cette plate-forme.",
  "etat_audio : message de plate-forme non prise en charge")

code, texte = d.etat_audio {supportee = true, sans_backend = true,
  socket = true, disponible = false, assistant = 0,
  erreur = "assistant audio absent (socket /tmp/a) : connexion refusée"}
aide.egal(code, "desactive", "etat_audio : ORGANUM_SANS_BACKEND désactive l'axe")
aide.egal(texte, "Audio désactivé sur cette plate-forme.",
  "etat_audio : message de désactivation")

code, texte = d.etat_audio {supportee = true, socket = true,
  disponible = false, assistant = 0,
  erreur = "périphérique par défaut : assistant audio absent (socket /tmp/a) : connexion refusée"}
aide.egal(code, "assistant_absent", "etat_audio : assistant audio absent")
aide.egal(texte,
  "Assistant audio absent : lancez organum-audio (voir plateforme/macos/LANCEMENT.md).",
  "etat_audio : message d'assistant absent")

-- L'ACK statut 2 donne aussi audio_assistant = 0 : le message d'erreur doit
-- primer, sinon une machine sans sortie serait présentée comme sans assistant.
code, texte = d.etat_audio {supportee = true, socket = true,
  disponible = false, assistant = 0,
  erreur = "périphérique par défaut : aucune sortie audio disponible"}
aide.egal(code, "sans_sortie", "etat_audio : aucune sortie audio")
aide.egal(texte,
  "Aucune sortie audio : vérifiez Réglages Système → Son → Sortie.",
  "etat_audio : message de sortie absente")

-- Un couple hétérogène organum/assistant ne doit jamais être présenté comme
-- un simple assistant absent : le message explicite (deux versions) reste
-- visible dans l'interface.
code, texte = d.etat_audio {supportee = true, socket = true,
  disponible = false, assistant = 0,
  erreur = "périphérique par défaut : version du protocole audio incompatible entre organum (2) et l'assistant (1) : recompilez les deux"}
aide.egal(code, "incompatible", "etat_audio : version de protocole incompatible")
aide.egal(texte,
  "périphérique par défaut : version du protocole audio incompatible entre organum (2) et l'assistant (1) : recompilez les deux",
  "etat_audio : message de version incompatible conservé")

code, texte = d.etat_audio {supportee = true, socket = true,
  disponible = false, assistant = 0,
  erreur = "périphérique par défaut : version de l'anneau audio incompatible entre organum (2) et l'assistant (1) : recompilez les deux"}
aide.egal(code, "incompatible", "etat_audio : version d'anneau incompatible")
aide.egal(texte,
  "périphérique par défaut : version de l'anneau audio incompatible entre organum (2) et l'assistant (1) : recompilez les deux",
  "etat_audio : message d'anneau incompatible conservé")

code, texte = d.etat_audio {supportee = true, socket = true,
  disponible = true, assistant = 1, erreur = ""}
aide.egal(code, nil, "etat_audio : audio opérationnel, aucun message")
aide.egal(texte, nil, "etat_audio : texte nil quand l'audio fonctionne")

-- Le producteur n'a pas encore écrit (ouverture, ou recréation du moteur
-- pendant un changement de taux) : le silence doit être annoncé, pas compté
-- comme une famine invisible.
code, texte = d.etat_audio {supportee = true, socket = true,
  disponible = true, assistant = 1, erreur = "", demarre = false,
  application = false}
aide.egal(code, "suspendu", "etat_audio : production pas encore démarrée")
aide.egal(texte, "Son suspendu : la sortie audio se prépare…",
  "etat_audio : message de suspension à l'ouverture")
code, texte = d.etat_audio {supportee = true, socket = true,
  disponible = true, assistant = 1, erreur = "", demarre = false,
  application = true}
aide.egal(code, "suspendu", "etat_audio : production suspendue pendant une reconfiguration")
aide.egal(texte, "Son suspendu pendant l'application des réglages audio…",
  "etat_audio : message de suspension pendant l'application")
code, texte = d.etat_audio {supportee = true, socket = true,
  disponible = true, assistant = 1, erreur = "", demarre = true}
aide.egal(code, nil, "etat_audio : production démarrée, aucun message")

code, texte = d.etat_audio {supportee = true, socket = true,
  disponible = false, assistant = -1, erreur = ""}
aide.egal(code, "indisponible", "etat_audio : état transitoire sans erreur")
aide.egal(texte, "Audio momentanément indisponible.",
  "etat_audio : message transitoire")

code = d.etat_audio(nil)
aide.egal(code, "sans_backend", "etat_audio : nil traité comme plate-forme sans backend")

aide.termine()
