package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local m = require "midi_actif"

aide.egal(m.actif(true, nil, false), true, "linux normal : MIDI actif")
aide.egal(m.actif(true, "0", false), true, "ORGANUM_SANS_BACKEND=0 ignoré")
aide.egal(m.actif(true, "oui", false), true, "valeur non 1 ignorée")
aide.egal(m.actif(true, "1", false), false,
  "ORGANUM_SANS_BACKEND=1 coupe le MIDI sans socket")
aide.egal(m.actif(true, "1", true), true,
  "socket imposée : MIDI actif malgré le forçage audio")
aide.egal(m.actif(false, nil, false), false, "aucun backend MIDI : inactif")
aide.egal(m.actif(false, nil, true), false,
  "socket imposée sans backend : inactif")

-- socket_actif : même règle que l'aiguillage de plateforme/midi.c.
aide.egal(m.socket_actif("linux", false), false,
  "socket_actif : Linux sans forçage, ALSA")
aide.egal(m.socket_actif("linux", true), true,
  "socket_actif : Linux avec ORGANUM_MIDI_SOCKET, socket")
aide.egal(m.socket_actif("macos", false), true,
  "socket_actif : macOS, socket d'office")
aide.egal(m.socket_actif("macos", true), true,
  "socket_actif : macOS avec forçage, socket")
aide.egal(m.socket_actif("windows", true), false,
  "socket_actif : Windows garde WinMM malgré la variable")
aide.egal(m.socket_actif("windows", false), false,
  "socket_actif : Windows, WinMM")
aide.egal(m.socket_actif("autre", false), false,
  "socket_actif : plate-forme sans backend")
aide.egal(m.socket_actif("linux", nil), false,
  "socket_actif : forçage inconnu")

-- message : état de l'axe MIDI pour le bandeau de la page d'orgue.
aide.egal(m.message(true, true, true), nil,
  "message : assistant socket connecté, rien à dire")
aide.egal(m.message(true, false, false), nil,
  "message : ALSA/WinMM sans assistant, rien à dire")
aide.egal(m.message(false, false, false),
  "MIDI désactivé sur cette plate-forme.",
  "message : MIDI coupé")
aide.egal(m.message(true, false, true),
  "Assistant MIDI absent : lancez organum-midi (voir plateforme/macos/LANCEMENT.md).",
  "message : assistant socket absent")
aide.egal(m.message(nil, false, true),
  "MIDI désactivé sur cette plate-forme.",
  "message : état indisponible annoncé")

aide.termine()
