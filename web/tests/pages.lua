package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"

-- html.moon : balises, attributs, contenu, échappement laissé à l'appelant.
local h = require "html"
aide.egal(h.div({"Hello", class = "container"}), '<div class="container">Hello</div>',
  "html : attribut et contenu")
aide.egal(h.br({}), "<br/>", "html : balise vide auto-fermante")
aide.egal(h.div({}), "<div/>", "html : élément vide auto-fermant")
local entree = h.input({type = "range", value = "50"})
aide.verifie(entree:find('<input ', 1, true) == 1 and entree:find('/>', 1, true) ~= nil,
  "html : balise input auto-fermante")
aide.verifie(entree:find('type="range"', 1, true) ~= nil and
  entree:find('value="50"', 1, true) ~= nil, "html : attributs sans contenu")
aide.egal(h.span(h.b("gras"), " texte"),
  "<span><b>gras</b>\n texte</span>", "html : imbrication et fonction")
aide.egal(h.p(42), "<p>42</p>", "html : contenu numérique")
aide.egal(h.option({"x", selected = true}), '<option selected>x</option>',
  "html : attribut booléen")
aide.egal(h.div({h.span("b"), "c", class = "a"}),
  '<div class="a"><span>b</span>\nc</div>', "html : plusieurs contenus")

-- Pages complètes.
local page = require "page"
local page_midi = require "page_midi"
local page_audio = require "page_audio"

local divisions = {
  {name = "Pedal", gain = 0.25, links = {}, stops = {
    {name = "Bourdon\n16", on = true},
    {name = "<script>", on = false},
    {name = "Sans état"},
  }},
  {name = "Manual I", gain = 0.5, links = {{division = 0, on = true}},
   stops = {{name = "Montre 8", on = true}}},
  {name = "Manual II", gain = nil, links = {}, stops = {}},
}
local html_page = page(divisions, 32)

aide.verifie(html_page:sub(1, 15) == "<!DOCTYPE html>", "page : doctype")
aide.verifie(html_page:find('<html lang="fr">', 1, true) ~= nil, "page : langue française")
for _, id in ipairs({"volume", "volume-pedale", "value", "value-pedale",
                     "status", "mute", "combo-prev", "combo-num", "combo-next",
                     "panic", "lien-qualite"}) do
  aide.verifie(html_page:find('id="' .. id .. '"', 1, true) ~= nil,
    "page : identifiant " .. id)
end
aide.verifie(html_page:find('href="/midi"', 1, true) ~= nil, "page : lien MIDI")
aide.verifie(html_page:find('href="/audio"', 1, true) ~= nil, "page : lien Audio")
aide.verifie(html_page:find("Code source (AGPL-3.0)", 1, true) ~= nil,
  "page : lien code source AGPL")
aide.verifie(html_page:find("https://github.com/jperon/organum", 1, true) ~= nil,
  "page : URL du code source")
aide.verifie(html_page:find("Bourdon<br>16", 1, true) ~= nil,
  "page : nom de jeu sur deux lignes rendu en <br>")
aide.verifie(html_page:find("&lt;script&gt;", 1, true) ~= nil,
  "page : nom de jeu échappé")
aide.verifie(html_page:find("<script>", 1, true) ~= nil,
  "page : script client présent")
aide.verifie(html_page:find('data-state="on"', 1, true) ~= nil,
  "page : jeu actif marqué on")
aide.verifie(html_page:find('data-state="off"', 1, true) ~= nil,
  "page : jeu inactif marqué off")
aide.verifie(html_page:find('data-state="unknown"', 1, true) ~= nil,
  "page : jeu sans état marqué unknown")
aide.verifie(html_page:find('value="25"', 1, true) ~= nil,
  "page : gain 0,25 rendu en 25")
aide.verifie(html_page:find('value="50"', 1, true) ~= nil,
  "page : gain absent rendu en 50")
aide.verifie(html_page:find("P+I", 1, true) ~= nil,
  "page : accouplement abrégé P+I")
aide.verifie(html_page:find('data-step="0"', 1, true) ~= nil,
  "page : première combinaison")
aide.verifie(html_page:find('data-step="31"', 1, true) ~= nil,
  "page : dernière combinaison")
aide.verifie(html_page:find('data-step="32"', 1, true) == nil,
  "page : pas de combinaison 32 avec 32 étapes")
aide.verifie(html_page:find('data-charge-classe-3="charge-rouge"', 1, true) ~= nil,
  "page : classes de charge exposées")

-- Noms contenant des caractères HTML : échappement complet.
local piege = page({{name = 'A&<>"', gain = 0.5, links = {},
  stops = {{name = '&<>"', on = true}}}}, 1)
aide.verifie(piege:find('A&amp;&lt;&gt;&quot;', 1, true) ~= nil,
  "page : nom de division échappé")
aide.verifie(piege:find('&amp;&lt;&gt;&quot;', 1, true) ~= nil,
  "page : nom de jeu échappé")

-- page_midi
local midi = page_midi()
aide.verifie(midi:sub(1, 15) == "<!DOCTYPE html>", "page MIDI : doctype")
for _, id in ipairs({"grille", "associations", "liste-ports", "adresse-midi",
                     "message-connexions", "rafraichir-ports", "ajouter",
                     "dernier", "titre-connexions"}) do
  aide.verifie(midi:find('id="' .. id .. '"', 1, true) ~= nil,
    "page MIDI : identifiant " .. id)
end
aide.verifie(midi:find('data-cible-volume="Volume"', 1, true) ~= nil,
  "page MIDI : libellé volume")
aide.verifie(midi:find('data-cible-reverb="Réverbération"', 1, true) ~= nil,
  "page MIDI : libellé réverbération")
aide.verifie(midi:find('data-canal-tous="Tous"', 1, true) ~= nil,
  "page MIDI : libellé canal tous")
aide.verifie(midi:find("suivrePorts", 1, true) ~= nil,
  "page MIDI : suivi des ports dans le script")
aide.verifie(midi:find("← Orgue", 1, true) ~= nil, "page MIDI : retour à l'orgue")

-- page_audio
local audio = page_audio()
aide.verifie(audio:sub(1, 15) == "<!DOCTYPE html>", "page audio : doctype")
for _, id in ipairs({"reverb", "qualite-polyphonie", "qualite-polyphonie-valeur",
                     "qualite-periode", "qualite-taux", "qualite-temperament",
                     "qualite-peripherique", "qualite-tete", "qualite-calibration",
                     "qualite-message", "qualite-niveau"}) do
  aide.verifie(audio:find('id="' .. id .. '"', 1, true) ~= nil,
    "page audio : identifiant " .. id)
end
local temperaments = {
  "Pythagoricien", "Mésotonique", "Werckmeister III", "Kirnberger III",
  "Bien tempéré", "Égal", "Ahrend", "Vallotti", "Kellner", "Lehman", "Juste (do)",
}
local position = 0
for i, nom in ipairs(temperaments) do
  local p = audio:find(">" .. nom .. "<", position + 1, true)
  aide.verifie(p ~= nil and p > position,
    "page audio : tempérament " .. (i - 1) .. " dans l'ordre")
  position = p or position
end
for _, valeur in ipairs({"128", "256", "512", "1024", "2048"}) do
  aide.verifie(audio:find(">" .. valeur .. "<", 1, true) ~= nil,
    "page audio : période " .. valeur)
end
for _, valeur in ipairs({"44100", "48000"}) do
  aide.verifie(audio:find(">" .. valeur .. "<", 1, true) ~= nil,
    "page audio : taux " .. valeur)
end
aide.verifie(audio:find("setProperty('--fill'", 1, true) ~= nil,
  "page audio : script pose --fill")
aide.verifie(audio:find("qualite-calibration", 1, true) ~= nil,
  "page audio : calibration")
aide.verifie(audio:find("Réverbération zéro latence", 1, true) ~= nil,
  "page audio : tête de réverbération")

-- client.moon : code JavaScript rendu tel quel, avec ses repères.
local client = require "client"
aide.verifie(type(client) == "string" and #client > 1000, "client : chaîne JavaScript")
aide.verifie(client:find("setProperty('--fill'", 1, true) ~= nil,
  "client : volume pose --fill")
aide.verifie(client:find("pedalSlider", 1, true) ~= nil, "client : curseur pédale")
aide.verifie(client:find("lienQualite", 1, true) ~= nil, "client : lien qualité")
aide.verifie(client:find("startOrgueLoop", 1, true) ~= nil, "client : boucle orgue")

aide.termine()
