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

aide.termine()
