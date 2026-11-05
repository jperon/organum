package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local d = require "fenetre_disposition"

-- bouge : seuil strict de 1e-4.
aide.egal(d.bouge(0, 0), false, "bouge : valeurs égales")
aide.egal(d.bouge(0, 0.0001), false, "bouge : exactement au seuil")
aide.egal(d.bouge(0, 0.00011), true, "bouge : juste au-dessus")
aide.egal(d.bouge(1, 0.99989), true, "bouge : négatif au-delà")
aide.egal(d.bouge(1, 0.99991), false, "bouge : négatif sous le seuil")
aide.egal(d.bouge(0.5, 0.50005), false, "bouge : bruit de flottant ignoré")

-- decoupe : coupe au space qui équilibre le mieux, largeur maximale.
local ui = {}
function ui:largeur_texte(s) return #s end
local coupe = d.decoupe(ui, "Double Open Diapason")
aide.verifie(coupe ~= nil, "decoupe : nom avec espaces")
if coupe then
  aide.egal(coupe.a .. " " .. coupe.b, "Double Open Diapason", "decoupe : texte reconstitué")
  local meilleure = math.huge
  for i = 2, #"Double Open Diapason" - 1 do
    if ("Double Open Diapason"):sub(i, i) == " " then
      local a = ("Double Open Diapason"):sub(1, i - 1)
      local b = ("Double Open Diapason"):sub(i + 1)
      meilleure = math.min(meilleure, math.max(#a, #b))
    end
  end
  aide.egal(coupe.large, meilleure, "decoupe : largeur minimale")
end
aide.egal(d.decoupe(ui, "SansEspace"), nil, "decoupe : sans espace")
coupe = d.decoupe(ui, "A B")
aide.egal(coupe and coupe.a, "A", "decoupe : deux mots courts")
coupe = d.decoupe(ui, "A B C")
aide.egal(coupe and coupe.a, "A", "decoupe : première coupe équilibrée")
aide.egal(coupe and coupe.b, "B C", "decoupe : reste conservé")
coupe = d.decoupe(ui, "A  B")
aide.egal(coupe and coupe.a, "A", "decoupe : espaces consécutifs")
aide.egal(coupe and coupe.b, " B", "decoupe : second espace conservé dans la suite")
aide.egal(d.decoupe(ui, " AB"), nil, "decoupe : espace en tête ignoré")

-- texte_calibration
aide.egal(d.texte_calibration({}), "Calibration automatique", "calibration : sans champs")
aide.egal(d.texte_calibration({niveau = 2, estimation_ms = {4.2, 5.1, 6.3, 8.9},
  echeance_ms = 10.6666, voix_ref = 250, tete_reverb = true}),
  "Calibration : niveau 2 · estimation 6.3 ms · échéance 10.7 ms · 250 voix · tête zéro latence",
  "calibration : champs complets")
aide.egal(d.texte_calibration({niveau = 0, estimation_ms = 12.34, tete_reverb = false}),
  "Calibration : niveau 0 · estimation 12.3 ms · sans tête",
  "calibration : estimation numérique et sans tête")
aide.egal(d.texte_calibration({niveau = 3, estimation_ms = {1, 2, 3}}),
  "Calibration : niveau 3", "calibration : estimation du niveau absente")
aide.egal(d.texte_calibration({niveau = 1, estimation_ms = "4"}),
  "Calibration : niveau 1", "calibration : estimation de type faux ignorée")
aide.egal(d.texte_calibration({echeance_ms = 10, voix_ref = 0}),
  "Calibration automatique · échéance 10.0 ms · 0 voix",
  "calibration : sans niveau mais avec échéance")

local function etat(nbdiv, njeux, liens, netapes)
  local e = {netapes = netapes or 32, divisions = {}}
  for i = 1, nbdiv do
    local div = {nom = "Manual " .. i, jeux = {}, liens = {}}
    for j = 1, njeux do
      div.jeux[j] = {nom = "Double Open Diapason " .. j, actif = j % 3 == 0}
    end
    if liens then
      for j = 1, i - 1 do div.liens[j] = {division = j, actif = j == 1} end
    end
    e.divisions[i] = div
  end
  return e
end

local tailles = {{320, 200}, {480, 320}, {640, 480}, {1024, 640},
                 {1280, 720}, {1920, 1080}, {2560, 1440}, {3840, 2160}}
local configs = {
  {1, 0, false}, {1, 1, false}, {1, 12, false}, {4, 15, true},
  {4, 12, false}, {3, 8, true},
}

for _, cfg in ipairs(configs) do
  local nbdiv, njeux, liens = cfg[1], cfg[2], cfg[3]
  local e = etat(nbdiv, njeux, liens)
  for _, size in ipairs(tailles) do
    local l, h = size[1], size[2]
    local cible = math.min(d.POLICE_MAX, math.max(13, math.floor(l / 64)))
    local p = d.disposer(e, l, h, 30, 15, cible)
    local nom = string.format("%dx%d, %d div, %d jeux", l, h, nbdiv, njeux)
    aide.verifie(p ~= nil, "disposer : résultat " .. nom)
    if p then
      aide.entre(p.police, d.POLICE_MIN, d.POLICE_MAX, "disposer : police " .. nom)
      aide.verifie(p.sous >= 1 and p.sous <= 3, "disposer : sous-colonnes " .. nom)
      aide.verifie(p.lignes_combi >= 1 and p.lignes_combi <= 2, "disposer : lignes combi " .. nom)
      aide.egal(p.rangs, math.ceil(njeux / p.sous), "disposer : rangées " .. nom)
      local haut = 1 + p.lignes_combi
      local col_jeu = math.max(1, p.rangs + ((liens and nbdiv > 1) and 1 or 0))
      local fixe = 2 * d.MARGE + d.ESPACE * (haut + 1) +
        2 * d.MARGE_GROUPE + d.ESPACE * (2 + col_jeu)
      local utilise = fixe + (haut + 2) * p.entete + col_jeu * p.jeu
      local largeur = nbdiv * p.sous *
        (p.case + 2 * d.MARGE_GROUPE / p.sous + d.ESPACE) + 2 * d.MARGE
      aide.verifie(p.case > 0, "disposer : case positive " .. nom, p.case)
      aide.verifie(largeur <= l + 1e-6, "disposer : largeur dans la fenêtre " .. nom,
        largeur .. " > " .. l)
      if p.score then
        aide.verifie(utilise <= h + 1e-6, "disposer : hauteur dans la fenêtre " .. nom,
          utilise .. " > " .. h)
        aide.verifie(p.police <= cible, "disposer : police sous la cible " .. nom)
        -- Cible de AGENTS.md : 36 px d'abord, sinon 2,2 × police, sinon
        -- seulement 2 × police pour ne pas écraser les jeux.
        local essais = {
          math.max(36, math.ceil(2.2 * p.police)),
          math.ceil(2.2 * p.police),
          math.max(p.police + 4, 2 * p.police),
        }
        local trouve = false
        for _, e in ipairs(essais) do
          if p.entete == e then trouve = true end
        end
        aide.verifie(trouve, "disposer : hauteur d'en-tête dans les cibles " .. nom, p.entete)
      else
        -- Repli documenté : l'en-tête peut être rogné, mais la police reste
        -- au moins au plancher et une ligne de jeu subsiste.
        aide.verifie(p.police >= d.POLICE_MIN, "disposer : repli au-dessus du plancher " .. nom)
        aide.verifie(p.jeu >= 1, "disposer : repli garde une ligne de jeu " .. nom)
      end
    end
  end
end

-- MIDI : 17 colonnes, lignes d'association et d'actions.
local e4 = etat(4, 15, true)
for _, size in ipairs(tailles) do
  local l, h = size[1], size[2]
  local nom = string.format("MIDI %dx%d", l, h)
  for _, nassoc in ipairs({0, 1, 4, 16, 40}) do
    local cfg = {associations = {}}
    for i = 1, nassoc do cfg.associations[i] = {cc = i} end
    local p = d.disposer_midi(e4, cfg, l, h)
    aide.entre(p.police, d.POLICE_MIN, d.POLICE_MAX, "disposer_midi : police " .. nom)
    aide.verifie(p.ligne >= 1, "disposer_midi : ligne positive " .. nom)
    aide.verifie(p.assoc_max >= 0 and p.assoc_max <= nassoc, "disposer_midi : assoc_max " .. nom)
    local case = (l - 2 * d.MARGE) / 17 - d.ESPACE
    aide.verifie(p.police <= math.floor(case / 1.2) or p.police == d.POLICE_MIN,
      "disposer_midi : police bornée par la largeur " .. nom)
    local base = math.max(1, #e4.divisions) + 5
    local rows = base + p.assoc_max + (p.compte and 1 or 0)
    if not p.trop_petit then
      local fixe = 2 * d.MARGE + d.ESPACE * (rows + 1)
      aide.verifie(fixe + rows * p.ligne <= h + 1e-6,
        "disposer_midi : hauteur dans la fenêtre " .. nom,
        (fixe + rows * p.ligne) .. " > " .. h)
    else
      aide.egal(p.assoc_max, 0, "disposer_midi : trop petit sans association " .. nom)
      aide.egal(p.police, d.POLICE_MIN, "disposer_midi : trop petit à la police plancher " .. nom)
    end
    if p.compte then
      aide.verifie(p.assoc_max < nassoc, "disposer_midi : compte seulement si masqué " .. nom)
    end
  end
end

-- Connexions : trois colonnes et un pied.
for _, size in ipairs(tailles) do
  local l, h = size[1], size[2]
  for _, nports in ipairs({0, 1, 5, 20, 100}) do
    local nom = string.format("connexions %dx%d, %d ports", l, h, nports)
    local p = d.disposer_connexions(nports, l, h)
    aide.entre(p.police, d.POLICE_MIN, d.POLICE_MAX, "disposer_connexions : police " .. nom)
    aide.verifie(p.ligne >= 1, "disposer_connexions : ligne positive " .. nom)
    aide.verifie(p.visibles >= 0 and p.visibles <= nports, "disposer_connexions : visibles " .. nom)
    aide.verifie(3 * (p.colonne + d.ESPACE) + 2 * d.MARGE <= l + 1e-6,
      "disposer_connexions : largeur dans la fenêtre " .. nom)
    local rows = 3 + p.visibles + (p.compte and 1 or 0)
    if not p.trop_petit then
      local fixe = 2 * d.MARGE + d.ESPACE * (rows + 1)
      aide.verifie(fixe + rows * p.ligne <= h + 1e-6,
        "disposer_connexions : hauteur dans la fenêtre " .. nom,
        (fixe + rows * p.ligne) .. " > " .. h)
    else
      aide.egal(p.visibles, 0, "disposer_connexions : trop petit sans port " .. nom)
    end
  end
end

-- Qualité : rows fournies par l'appelant, colonnes 5 ou 6.
for _, size in ipairs(tailles) do
  local l, h = size[1], size[2]
  for _, cas in ipairs({{9, 5}, {12, 6}, {14, 6}, {20, 6}}) do
    local rows, colonnes = cas[1], cas[2]
    local nom = string.format("qualité %dx%d, rows %d, cols %d", l, h, rows, colonnes)
    local p = d.disposer_qualite(rows, l, h, colonnes)
    aide.entre(p.police, d.POLICE_MIN, d.POLICE_MAX, "disposer_qualite : police " .. nom)
    aide.verifie(p.ligne >= 1, "disposer_qualite : ligne positive " .. nom)
    local case = (l - 2 * d.MARGE) / colonnes - d.ESPACE
    aide.verifie(p.police <= math.floor(case / 8.7) or p.police == d.POLICE_MIN,
      "disposer_qualite : police bornée par la largeur " .. nom)
    if not p.trop_petit then
      local fixe = 2 * d.MARGE + d.ESPACE * (rows + 1)
      aide.verifie(fixe + rows * p.ligne <= h + 1e-6,
        "disposer_qualite : hauteur dans la fenêtre " .. nom,
        (fixe + rows * p.ligne) .. " > " .. h)
    end
  end
end

aide.termine()
