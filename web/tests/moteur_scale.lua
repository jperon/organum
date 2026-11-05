package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"

local chemin = (os.getenv("SCALE_SRC") or "moteur/aeolus/scale.cpp")
local f = assert(io.open(chemin, "rb"), "scale.cpp illisible : " .. chemin)
local contenu = f:read("*a")
f:close()

local attendus = {
  {"Pythagorean", "Pythagorean"},
  {"MeanQuart",   "Meantone"},
  {"Werckm3",     "Werckmeister"},
  {"Kirnberg3",   "Kirnberger"},
  {"WellTemp",    "Well tempered"},
  {"EqualTemp",   "Equal tempered"},
  {"Ahrend",      "Ahrend"},
  {"Vallotti",    "Vallotti"},
  {"Kellner",     "Kellner"},
  {"Lehman",      "Lehman"},
  {"Pure",        "Just intonation / C"},
}

-- On isole la table « names » de getNameForType pour ne pas ramasser les
-- autres accolades du fichier.
local bloc = contenu:match("names%s*{(.-)}%s*;")
aide.verifie(bloc ~= nil, "scale.cpp : table des noms trouvée")
if bloc then
  local paires = {}
  for cle, nom in bloc:gmatch('{%s*([%w_]+)%s*,%s*"([^"]*)"%s*}') do
    paires[#paires + 1] = {cle, nom}
  end
  aide.egal(#paires, 11, "scale.cpp : onze noms")
  for i, attendu in ipairs(attendus) do
    local paire = paires[i]
    aide.egal(paire and paire[1], attendu[1], "scale.cpp : enum du nom " .. (i - 1))
    aide.egal(paire and paire[2], attendu[2], "scale.cpp : libellé " .. (i - 1))
  end
end

aide.termine()
