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

aide.termine()
