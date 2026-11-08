package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local d = require "degradation"

aide.egal(d.sans_backend("linux"), false, "linux a un backend")
aide.egal(d.sans_backend("windows"), false, "windows a un backend")
aide.egal(d.sans_backend("macos"), true, "macos est sans backend")
aide.egal(d.sans_backend("autre"), true, "plate-forme inconnue sans backend")

local force, raison = d.detecter("linux", "1")
aide.egal(force, true, "ORGANUM_SANS_BACKEND=1 force le mode sur linux")
aide.egal(raison, "forcé par ORGANUM_SANS_BACKEND", "raison du forçage")

local normal = d.detecter("linux", nil)
aide.egal(normal, false, "linux sans variable reste normal")
normal = d.detecter("linux", "0")
aide.egal(normal, false, "ORGANUM_SANS_BACKEND=0 est ignoré")
normal = d.detecter("linux", "oui")
aide.egal(normal, false, "valeur non 1 ignorée")

force = d.detecter("macos", nil)
aide.egal(force, true, "macos dégradé sans variable")

aide.termine()
