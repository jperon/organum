package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local c = require "clavier"

-- Noms et octaves : do 4 = note MIDI 60 (diapason scientifique).
aide.egal(c.nom(60), "do", "clavier : note 60 = do")
aide.egal(c.nom(61), "do dièse", "clavier : note 61 = do dièse")
aide.egal(c.nom(71), "si", "clavier : note 71 = si")
aide.egal(c.court(63), "Ré♯", "clavier : libellé court de ré dièse")
aide.egal(c.octave(60), 4, "clavier : octave de do 4")
aide.egal(c.octave(59), 3, "clavier : octave de si 3")
aide.egal(c.octave(84), 6, "clavier : octave de do 6")
aide.egal(c.libelle(61), "do dièse 4", "clavier : libellé complet avec octave")

-- Touches noires : une par demi-ton 1, 3, 6, 8 et 10 de l'octave.
aide.egal(c.est_noire(60), false, "clavier : do est blanche")
aide.egal(c.est_noire(61), true, "clavier : do dièse est noire")
for _, note in ipairs({61, 63, 66, 68, 70}) do
  aide.egal(c.est_noire(note), true, "clavier : " .. note .. " est noire")
end
for _, note in ipairs({60, 62, 64, 65, 67, 69, 71}) do
  aide.egal(c.est_noire(note), false, "clavier : " .. note .. " est blanche")
end
aide.egal(c.est_noire(128), false, "clavier : note hors bornes n'est pas noire")
aide.egal(c.est_noire("61"), false, "clavier : chaîne refusée")

-- Position d'une noire : nombre de blanches avant elle dans l'octave.
aide.egal(c.position_noire(61), 1, "clavier : do dièse après 1 blanche")
aide.egal(c.position_noire(63), 2, "clavier : ré dièse après 2 blanches")
aide.egal(c.position_noire(66), 4, "clavier : fa dièse après 4 blanches")
aide.egal(c.position_noire(68), 5, "clavier : sol dièse après 5 blanches")
aide.egal(c.position_noire(70), 6, "clavier : la dièse après 6 blanches")

-- Deux octaves : 14 blanches et 10 noires, de do 4 à si 5.
local octaves = c.octaves(60, 2)
aide.egal(#octaves, 2, "clavier : deux octaves")
aide.egal(#octaves[1].blanches, 7, "clavier : 7 blanches par octave")
aide.egal(#octaves[1].noires, 5, "clavier : 5 noires par octave")
aide.egal(octaves[1].blanches[1].note, 60, "clavier : première note do 4")
aide.egal(octaves[2].blanches[7].note, 83, "clavier : dernière note si 5")
aide.egal(octaves[2].blanches[1].note, 72, "clavier : deuxième octave commence à do 5")
local positions = {}
for _, t in ipairs(octaves[1].noires) do positions[#positions + 1] = t.position end
aide.egal(table.concat(positions, ","), "1,2,4,5,6",
  "clavier : positions des noires dans l'octave")
aide.egal(octaves[1].noires[1].nom, "Do♯", "clavier : nom court de la première noire")
aide.egal(octaves[1].blanches[1].libelle, "do 4", "clavier : libellé de la première blanche")

-- Les bornes MIDI sont respectées : aucune touche au-delà de 127.
local haut = c.octaves(120, 2)
local dernier = haut[#haut].blanches[#haut[#haut].blanches]
aide.egal(dernier.note, 127, "clavier : aucune note au-delà de 127")

-- Choix du canal publié par /api/orgue : première valeur du masque, nil si
-- le clavier n'écoute aucun canal.
aide.egal(c.canal_division({canaux = {3, 4}}), 3, "clavier : premier canal de la division")
aide.egal(c.canal_division({canaux = {16}}), 16, "clavier : canal 16 accepté")
aide.egal(c.canal_division({canaux = {}}), nil, "clavier : aucun canal -> nil")
aide.egal(c.canal_division({canaux = {17}}), nil, "clavier : canal hors bornes -> nil")
aide.egal(c.canal_division(nil), nil, "clavier : division absente -> nil")

-- Message discret quand aucun jeu n'est allumé.
aide.egal(c.aucun_jeu_actif({}), true, "clavier : aucune division -> aucun jeu")
aide.egal(c.aucun_jeu_actif({{stops = {{on = false}, {on = false}}}}), true,
  "clavier : tous les jeux éteints")
aide.egal(c.aucun_jeu_actif({{stops = {{on = false}, {on = true}}}}), false,
  "clavier : un jeu allumé")
aide.egal(c.aucun_jeu_actif({{stops = {{}}}, {stops = {{on = false}}}}), true,
  "clavier : jeux sans état comptés comme éteints")

aide.termine()
