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
  {name = "Pedal", gain = 0.25, links = {}, canaux = {1}, stops = {
    {name = "Bourdon\n16", on = true},
    {name = "<script>", on = false},
    {name = "Sans état"},
  }},
  {name = "Manual I", gain = 0.5, links = {{division = 0, on = true}},
   canaux = {2}, stops = {{name = "Montre 8", on = true}}},
  {name = "Manual II", gain = nil, links = {}, canaux = {3}, stops = {}},
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

-- Clavier jouable : panneau <details> replié par défaut, deux octaves,
-- touches noires et sélecteur de division fondé sur les canaux publiés.
aide.verifie(html_page:find('id="clavier-panneau"', 1, true) ~= nil,
  "page : panneau Clavier présent")
local debut_details = html_page:find("<details", 1, true)
local fin_details = html_page:find(">", debut_details or 1, true)
local balise_details = debut_details and html_page:sub(debut_details, fin_details) or ""
aide.verifie(balise_details:find("open", 1, true) == nil,
  "page : panneau Clavier replié par défaut")
aide.verifie(html_page:find("<summary", 1, true) ~= nil and
  html_page:find(">Clavier</summary>", 1, true) ~= nil,
  "page : résumé Clavier natif")
local debut_clavier = html_page:find('class="clavier-octaves"', 1, true) or 1
local corps_clavier = html_page:sub(debut_clavier)
local _, blanches = corps_clavier:gsub("touche%-blanche", "")
local _, noires = corps_clavier:gsub("touche%-noire", "")
aide.egal(blanches, 14, "page : 14 touches blanches (deux octaves)")
aide.egal(noires, 10, "page : 10 touches noires (deux octaves)")
aide.verifie(html_page:find('id="clavier-canal"', 1, true) ~= nil,
  "page : sélecteur de clavier")
local options_clavier = {}
for tag in html_page:gmatch("<option[^>]*>") do options_clavier[#options_clavier + 1] = tag end
local function a_option(valeur, division)
  for _, tag in ipairs(options_clavier) do
    if tag:find('value="' .. valeur .. '"', 1, true) and
       tag:find('data-division="' .. division .. '"', 1, true) then
      return true
    end
  end
  return false
end
aide.verifie(a_option("1", "0"), "page : première division sur son canal")
aide.verifie(a_option("2", "1"), "page : deuxième division sur son canal")
local page_sans_jeu = page({{name = "Manual I", gain = 0.5, links = {},
  canaux = {1}, stops = {{name = "Montre 8", on = false}}}}, 1)
local pos_avert = page_sans_jeu:find('id="clavier-avertissement"', 1, true)
local debut_avert = page_sans_jeu:sub(1, pos_avert or 1):find("<p[^>]*$")
local fin_avert = page_sans_jeu:find(">", pos_avert or 1, true)
local balise_avert = page_sans_jeu:sub(debut_avert or 1, fin_avert or 1)
aide.verifie(balise_avert:find("hidden", 1, true) == nil,
  "page : avertissement visible sans jeu allumé")
aide.verifie(page_sans_jeu:find("Aucun jeu n'est allumé", 1, true) ~= nil,
  "page : texte d'avertissement sans jeu allumé")
local pos_avert_on = html_page:find('id="clavier-avertissement"', 1, true)
local debut_avert_on = html_page:sub(1, pos_avert_on or 1):find("<p[^>]*$")
local fin_avert_on = html_page:find(">", pos_avert_on or 1, true)
local balise_avert_on = html_page:sub(debut_avert_on or 1, fin_avert_on or 1)
aide.verifie(balise_avert_on:find("hidden", 1, true) ~= nil,
  "page : avertissement masqué quand un jeu est allumé")

-- Noms contenant des caractères HTML : échappement complet.
local piege = page({{name = 'A&<>"', gain = 0.5, links = {},
  stops = {{name = '&<>"', on = true}}}}, 1)
aide.verifie(piege:find('A&amp;&lt;&gt;&quot;', 1, true) ~= nil,
  "page : nom de division échappé")
aide.verifie(piege:find('&amp;&lt;&gt;&quot;', 1, true) ~= nil,
  "page : nom de jeu échappé")

-- Bandeau d'état : chaque axe a son message, et un axe qui fonctionne se
-- tait. L'ancien texte « Audio et MIDI indisponibles » ne doit plus revenir.
local page_audio_seule = page(divisions, 32, 0, {
  audio_message = "Assistant audio absent : lancez organum-audio (voir plateforme/macos/LANCEMENT.md).",
  midi_message = "",
})
aide.verifie(page_audio_seule:find('id="mode-degrade"', 1, true) ~= nil,
  "page : bandeau présent pour l'axe audio seul")
aide.verifie(page_audio_seule:find("Assistant audio absent", 1, true) ~= nil,
  "page : message d'assistant audio absent")
aide.verifie(page_audio_seule:find("Audio et MIDI indisponibles", 1, true) == nil,
  "page : plus de message global audio et MIDI")
local page_midi_seul = page(divisions, 32, 0, {
  audio_message = "",
  midi_message = "Assistant MIDI absent : lancez organum-midi (voir plateforme/macos/LANCEMENT.md).",
})
aide.verifie(page_midi_seul:find("Assistant MIDI absent", 1, true) ~= nil,
  "page : message d'assistant MIDI séparé")
aide.verifie(page_midi_seul:find("Assistant audio absent", 1, true) == nil,
  "page : pas de message audio quand l'audio fonctionne")
local page_saine = page(divisions, 32, 0, {audio_message = "", midi_message = ""})
aide.verifie(page_saine:find('id="mode-degrade"', 1, true) == nil,
  "page : aucun bandeau quand les deux axes fonctionnent")

-- page_midi
local midi = page_midi(true)
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
aide.verifie(midi:find('data-message-assistant-absent="Assistant MIDI absent', 1, true) ~= nil,
  "page MIDI : message d'assistant absent disponible")
aide.verifie(midi:find('etatPorts.socket === true', 1, true) ~= nil,
  "page MIDI : message d'assistant absent conditionné au backend socket")
aide.verifie(midi:find("← Orgue", 1, true) ~= nil, "page MIDI : retour à l'orgue")
local midi_alsa = page_midi(false)
aide.verifie(midi_alsa:sub(1, 15) == "<!DOCTYPE html>", "page MIDI : doctype hors socket")
aide.verifie(midi_alsa:find("organum-midi", 1, true) == nil,
  "page MIDI : aucun organum-midi à lancer hors backend socket")
aide.verifie(midi_alsa:find('id="liste-ports"', 1, true) ~= nil,
  "page MIDI : liste des ports présente hors backend socket")

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
for _, valeur in ipairs({"128", "256", "512", "768", "1024", "1536", "2048"}) do
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
aide.verifie(audio:find("q.audio_message", 1, true) ~= nil,
  "page audio : message d'état calculé côté serveur")
aide.verifie(audio:find("Audio et MIDI indisponibles", 1, true) == nil,
  "page audio : plus de message global audio et MIDI")
local audio_absent = page_audio("Assistant audio absent : lancez organum-audio (voir plateforme/macos/LANCEMENT.md).")
aide.verifie(audio_absent:find("Assistant audio absent", 1, true) ~= nil,
  "page audio : message d'état rendu côté serveur")
-- L'ordre des attributs vient de pairs() : ne pas supposer « id » puis
-- « hidden ». On isole la balise <p> qui porte l'identifiant.
local function balise_plateforme(page)
  local pos = page:find('id="qualite-plateforme"', 1, true)
  if not pos then return "" end
  local debut = page:sub(1, pos):find("<p[^>]*$")
  local fin = page:find(">", pos, true)
  if not debut or not fin then return "" end
  return page:sub(debut, fin)
end
aide.verifie(balise_plateforme(audio_absent):find("hidden", 1, true) == nil,
  "page audio : ligne plate-forme visible quand un message existe")
local audio_ok = page_audio("")
aide.verifie(balise_plateforme(audio_ok):find("hidden", 1, true) ~= nil,
  "page audio : ligne plate-forme masquée quand l'audio fonctionne")

-- client.moon : code JavaScript rendu tel quel, avec ses repères.
local client = require "client"
aide.verifie(type(client) == "string" and #client > 1000, "client : chaîne JavaScript")
aide.verifie(client:find("setProperty('--fill'", 1, true) ~= nil,
  "client : volume pose --fill")
aide.verifie(client:find("pedalSlider", 1, true) ~= nil, "client : curseur pédale")
aide.verifie(client:find("lienQualite", 1, true) ~= nil, "client : lien qualité")
aide.verifie(client:find("startOrgueLoop", 1, true) ~= nil, "client : boucle orgue")

aide.termine()
