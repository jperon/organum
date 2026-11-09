package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local a = require "assistant"

-- Décision : l'assistant n'est extrait et lancé que sous macOS, et seulement
-- si un axe socket en a besoin. Sous Linux, rien ne change, même avec les
-- variables de simulation ORGANUM_MIDI_SOCKET / ORGANUM_AUDIO_SOCKET.
aide.egal(a.besoin("linux", nil, true, false), false,
  "besoin : Linux ne lance jamais l'assistant")
aide.egal(a.besoin("linux", false, true, true), false,
  "besoin : Linux avec sockets simulées ne lance rien")
aide.egal(a.besoin("windows", nil, true, true), false,
  "besoin : Windows ne lance rien")
aide.egal(a.besoin("macos", false, true, true), true,
  "besoin : macOS avec audio et MIDI socket")
aide.egal(a.besoin("macos", false, false, false), true,
  "besoin : macOS avec audio seul utilise encore le helper")
aide.egal(a.besoin("macos", true, false, false), false,
  "besoin : macOS sans audio ni MIDI n'a pas besoin du helper")
aide.egal(a.besoin("macos", true, true, true), true,
  "besoin : macOS avec MIDI socket malgré l'audio coupé")

-- Dossier d'extraction : TMPDIR d'abord (le même que les sockets), puis le
-- cache de l'utilisateur, puis /tmp.
aide.egal(a.dossier("/var/folders/x/T", "/Users/jacques"),
  "/var/folders/x/T/.organum", "dossier : TMPDIR prioritaire")
aide.egal(a.dossier("", "/Users/jacques"),
  "/Users/jacques/Library/Caches/.organum", "dossier : repli cache utilisateur")
aide.egal(a.dossier(nil, nil), "/tmp/.organum", "dossier : repli /tmp")
aide.egal(a.chemin("/tmp", nil), "/tmp/.organum/organum-helper",
  "chemin : extrait stable par utilisateur")
aide.egal(a.chemin_log("/tmp", nil), "/tmp/.organum/organum-helper.log",
  "chemin : journal voisin de l'extrait")

-- Chemins de socket : même règle que trame_chemin_socket_nom.
aide.egal(a.chemin_socket(nil, "/var/folders/x/T", 501, "organum-midi"),
  "/var/folders/x/T/organum-midi-501.sock", "socket : TMPDIR et uid")
aide.egal(a.chemin_socket(nil, nil, 501, "organum-audio"),
  "/tmp/organum-audio-501.sock", "socket : repli /tmp")
aide.egal(a.chemin_socket("/tmp/special.sock", "/var/folders/x/T", 501,
  "organum-midi"), "/tmp/special.sock", "socket : variable prioritaire")
aide.egal(a.chemin_socket(nil, "/var/folders/x/T/", 501, "organum-midi"),
  "/var/folders/x/T/organum-midi-501.sock", "socket : barre finale évitée")
aide.egal(a.chemin_socket(nil, "/", 501, "organum-midi"),
  "/organum-midi-501.sock", "socket : racine sans double barre")

-- Messages : nil quand tout va bien, texte d'action sinon, jamais un reproche.
aide.egal(a.message(nil, "/tmp/x.log"), nil, "message : état nil, silence")
aide.egal(a.message("actif", "/tmp/x.log"), nil,
  "message : assistant actif, silence")
local absent = a.message("non_embarque", "/tmp/x.log")
aide.verifie(absent and absent:find("reconstruisez", 1, true) ~= nil,
  "message : archive sans assistant dit quoi faire", absent)
local extraction = a.message("extraction_impossible", "/tmp/x.log")
aide.verifie(extraction and extraction:find("/tmp/x.log", 1, true) ~= nil,
  "message : extraction impossible nomme le journal", extraction)
local lancement = a.message("lancement_impossible", "/tmp/y.log")
aide.verifie(lancement and lancement:find("/tmp/y.log", 1, true) ~= nil,
  "message : lancement impossible nomme le journal", lancement)
local inutilisable = a.message("inutilisable", "/tmp/z.log")
aide.verifie(inutilisable and inutilisable:find("/tmp/z.log", 1, true) ~= nil
  and inutilisable:find("signature", 1, true) ~= nil,
  "message : binaire inutilisable explique la signature", inutilisable)

-- Intégrité de l'extrait : contenu identique à l'archive, puis --aide doit
-- rendre 0. Un extrait tronqué est une extraction impossible ; un extrait
-- complet mais refusé par le système (signature absente sous arm64) est
-- inutilisable.
local source = "\127ELF faux binaire"
aide.egal(a.verifier_extrait(source, source, 0), nil,
  "extrait : contenu identique et --aide à 0, aucun état")
aide.egal(a.verifier_extrait(source, source, 1), "inutilisable",
  "extrait : --aide en échec, inutilisable")
aide.egal(a.verifier_extrait(source, source, nil), "inutilisable",
  "extrait : --aide sans code, inutilisable")
aide.egal(a.verifier_extrait(source, source:sub(1, 8), 0),
  "extraction_impossible", "extrait : tronqué, extraction impossible")
aide.egal(a.verifier_extrait(source, "", 0), "extraction_impossible",
  "extrait : vide, extraction impossible")
aide.egal(a.verifier_extrait(source, nil, 0), "extraction_impossible",
  "extrait : absent, extraction impossible")
aide.egal(a.verifier_extrait(source, source .. "x", 0),
  "extraction_impossible", "extrait : plus long que l'archive, refusé")

aide.termine()
