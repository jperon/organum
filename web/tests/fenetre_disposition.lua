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

-- Géométrie des rangées : largeurs et positions, formes fermées.
aide.egal(d.largeur_case(100, 2), 48, "géométrie : largeur de case (2 colonnes)")
aide.egal(d.largeur_case(100, 1), 100, "géométrie : une seule colonne")
aide.egal(d.case_x(10, 100, 2, 0), 10, "géométrie : bord gauche de la première case")
aide.egal(d.case_x(10, 100, 2, 1), 62, "géométrie : bord gauche de la seconde case")
aide.egal(d.case_centre(10, 100, 2, 1), 86, "géométrie : centre de la seconde case")
aide.egal(d.rangee_y(0, 36), d.MARGE + d.ESPACE + 18, "géométrie : centre de la première rangée")
aide.egal(d.rangee_y(2, 36), d.MARGE + d.ESPACE + 2 * 40 + 18, "géométrie : centre de la troisième rangée")
aide.egal(d.groupe_contenu(100), 100 + d.CADRE_GROUPE / 2 + d.ESPACE,
  "géométrie : premier widget d'un groupe")
local colonne = d.colonne_ratio(10, 100, {3, 1}, 2)
aide.egal(colonne.largeur, (100 - d.ESPACE) / 4, "géométrie : largeur d'une case à poids")
aide.egal(colonne.x, 10 + 3 * (100 - d.ESPACE) / 4 + d.ESPACE, "géométrie : bord d'une case à poids")
aide.egal(colonne.centre, colonne.x + colonne.largeur / 2, "géométrie : centre d'une case à poids")

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

local tailles = {{320, 200}, {480, 320}, {640, 480}, {800, 480}, {1024, 640},
                 {1280, 720}, {1920, 1080}, {2560, 1440}, {3840, 2160}}
local configs = {
  {1, 0, false}, {1, 1, false}, {1, 12, false}, {4, 15, true},
  {4, 12, false}, {3, 8, true},
}

-- Le bandeau des curseurs généraux réserve une colonne par réglage (44 px de
-- zone sensible, 52 px au plus) : la largeur des jeux doit en tenir compte, et
-- le total rester dans la fenêtre. un/deux/trois couvrent « Volume » seule,
-- puis « Volume » et « Pédale », puis un troisième curseur (« Piano »).
for _, nb_generaux in ipairs({1, 2, 3}) do
  for _, cfg in ipairs(configs) do
    local nbdiv, njeux, liens = cfg[1], cfg[2], cfg[3]
    local e = etat(nbdiv, njeux, liens)
    for _, size in ipairs(tailles) do
      local l, h = size[1], size[2]
      local nom = string.format("%dx%d, %d div, %d jeux, %d curseurs", l, h, nbdiv, njeux, nb_generaux)
      local cible = math.min(d.POLICE_MAX, math.max(13, math.floor(l / 64)))
      local p = d.disposer(e, l, h, 30, 15, cible, nb_generaux)
      aide.egal(p.nb_generaux, nb_generaux, "disposer : nombre de curseurs généraux " .. nom)
      local colonne = math.min(d.CURSEUR_MAX, math.max(d.CURSEUR_LARGEUR, l / 16))
      aide.egal(p.colonne_curseur, colonne, "disposer : largeur d'une colonne de curseur " .. nom)
      aide.egal(p.bande, nb_generaux * colonne + (nb_generaux - 1) * d.ESPACE + d.CADRE_GROUPE,
        "disposer : largeur du bandeau " .. nom)
      aide.verifie(p.l_jeux >= 1, "disposer : largeur des claviers positive " .. nom, p.l_jeux)
      aide.verifie(p.bande + d.ESPACE + p.l_jeux + 2 * d.MARGE <= l + 1e-6,
        "disposer : bandeau et claviers dans la fenêtre " .. nom,
        (p.bande + d.ESPACE + p.l_jeux + 2 * d.MARGE) .. " > " .. l)
      aide.egal(p.largeur_colonne, p.l_jeux / nbdiv - d.CADRE_GROUPE,
        "disposer : largeur du contenu d'un clavier " .. nom)
      aide.egal(p.largeur_jeux, math.max(1, p.largeur_colonne - d.ESPACE - p.curseur_largeur),
        "disposer : largeur de la grille de jeux " .. nom)
      local colonne_gain = math.max(d.CURSEUR_LARGEUR, l / 16)
      aide.egal(p.colonne_gain, colonne_gain, "disposer : largeur d'une colonne de gain " .. nom)
      aide.verifie(p.curseur_largeur > 0 and p.curseur_largeur <= colonne_gain,
        "disposer : largeur du curseur de gain " .. nom, p.curseur_largeur)
      if p.largeur_colonne >= colonne_gain + d.ESPACE + 24 then
        aide.egal(p.curseur_largeur, colonne_gain,
          "disposer : curseur de gain assez large quand la place le permet " .. nom)
      end
      aide.verifie(p.colonne_curseur >= d.CURSEUR_LARGEUR,
        "disposer : colonne de curseur au moins sensible " .. nom, p.colonne_curseur)
      aide.verifie(p.colonne_curseur <= d.CURSEUR_MAX,
        "disposer : colonne de curseur bornée " .. nom, p.colonne_curseur)
      aide.verifie(p.case * p.sous + d.ESPACE * (p.sous - 1) <= p.largeur_jeux + 1e-6,
        "disposer : jeux dans leur grille " .. nom,
        (p.case * p.sous + d.ESPACE * (p.sous - 1)) .. " > " .. p.largeur_jeux)
      aide.verifie(p.etiquette_curseur >= d.BOUTON_HAUTEUR / 2 or p.etiquette_curseur > 0,
        "disposer : hauteur d'étiquette positive " .. nom)
      aide.verifie(p.bande_curseur >= d.BOUTON_HAUTEUR,
        "disposer : curseur du bandeau au moins de la hauteur du bouton " .. nom, p.bande_curseur)
      aide.verifie(p.bouton_reset >= d.BOUTON_HAUTEUR,
        "disposer : bouton de remise à zéro au moins la hauteur du bouton " .. nom, p.bouton_reset)
      local contenu_bande = p.reste - d.CADRE_GROUPE - d.ESPACE
      aide.verifie(2 * p.etiquette_curseur + p.bande_curseur + p.bouton_reset +
        3 * d.ESPACE <= contenu_bande + 1e-6,
        "disposer : bandeau (curseurs et bouton) dans sa case " .. nom,
        (2 * p.etiquette_curseur + p.bande_curseur + p.bouton_reset + 3 * d.ESPACE) ..
          " > " .. contenu_bande)
    end
  end
end

-- Largeur du bandeau bornée en pixels : 44 px de zone sensible au moins,
-- 52 px au plus, quelle que soit la fenêtre ; à 800 px la borne vaut déjà
-- 50 px (un seizième), à 1024 et 1920 la colonne est plafonnée. La place
-- gagnée revient aux claviers, et la colonne de gain garde sa propre largeur.
for _, cas in ipairs({{800, 480, 50}, {1024, 640, 52}, {1920, 1080, 52}}) do
  local l, h, attendu = cas[1], cas[2], cas[3]
  local p = d.disposer(etat(4, 15, true), l, h, 9.36, 4.74, 13, 3)
  local nom = string.format("%dx%d", l, h)
  aide.egal(p.colonne_curseur, attendu, "disposer : colonne du bandeau bornée " .. nom)
  aide.verifie(p.colonne_curseur >= d.CURSEUR_LARGEUR and p.colonne_curseur <= d.CURSEUR_MAX,
    "disposer : colonne du bandeau entre 44 et 52 px " .. nom, p.colonne_curseur)
  aide.egal(p.bande, 3 * attendu + 2 * d.ESPACE + d.CADRE_GROUPE,
    "disposer : largeur du bandeau à trois curseurs " .. nom)
  aide.verifie(p.bande <= 3 * d.CURSEUR_MAX + 2 * d.ESPACE + d.CADRE_GROUPE,
    "disposer : bandeau au plus 174 px " .. nom, p.bande)
  aide.verifie(p.bouton_reset >= 44,
    "disposer : bouton de remise à zéro de 44 px " .. nom, p.bouton_reset)
  aide.verifie(p.curseur_largeur >= d.BOUTON_LARGEUR,
    "disposer : poignée de gain logée dans sa colonne " .. nom, p.curseur_largeur)
end

for _, cfg in ipairs(configs) do
  local nbdiv, njeux, liens = cfg[1], cfg[2], cfg[3]
  local e = etat(nbdiv, njeux, liens)
  for _, size in ipairs(tailles) do
    local l, h = size[1], size[2]
    local cible = math.min(d.POLICE_MAX, math.max(13, math.floor(l / 64)))
    local p = d.disposer(e, l, h, 30, 15, cible, 2)
    local nom = string.format("%dx%d, %d div, %d jeux", l, h, nbdiv, njeux)
    aide.verifie(p ~= nil, "disposer : résultat " .. nom)
    if p then
      aide.entre(p.police, d.POLICE_MIN, d.POLICE_MAX, "disposer : police " .. nom)
      aide.verifie(p.sous >= 1 and p.sous <= 3, "disposer : sous-colonnes " .. nom)
      aide.verifie(p.lignes_combi >= 1 and p.lignes_combi <= 2, "disposer : lignes combi " .. nom)
      aide.egal(p.rangs, math.ceil(njeux / p.sous), "disposer : rangées " .. nom)
      -- Rangées d'un clavier : en-tête (nom et Annuler), bloc de jeux, puis
      -- accouplements éventuels. Chaque rangée avance de sa hauteur + ESPACE,
      -- sauf la dernière du bloc (d'où le - ESPACE).
      local haut = 1 + p.lignes_combi
      local col_jeu = math.max(1, p.rangs + ((liens and nbdiv > 1) and 1 or 0))
      local utilise = 2 * d.MARGE + d.CADRE_GROUPE + 2 * d.ESPACE +
        (haut + 1) * (p.entete + d.ESPACE) + col_jeu * (p.jeu + d.ESPACE) - d.ESPACE
      aide.verifie(p.reste > 0, "disposer : rangée principale positive " .. nom, p.reste)
      aide.egal(p.reste, h - 2 * d.MARGE - haut * (p.entete + d.ESPACE) - d.ESPACE,
        "disposer : hauteur de la rangée principale " .. nom)
      if p.score or p.jeu > 1 then
        aide.verifie(utilise <= h + 1e-6, "disposer : hauteur dans la fenêtre " .. nom,
          utilise .. " > " .. h)
      end
      aide.verifie(p.case > 0, "disposer : case positive " .. nom, p.case)
      if p.score then
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

-- Les fonctions de géométrie restent utilisables après un calcul de
-- disposition (aucun nom local ne doit masquer un export du module).
aide.egal(d.case_centre(0, 100, 2, 1), 76, "géométrie : case_centre après disposer")
aide.egal(d.colonne_ratio(0, 100, {1, 1}, 2).centre, 76,
  "géométrie : colonne_ratio après disposer")

-- Bandeau étroit (même règle que la page web sous 600 px) : dès que la place
-- manque, la colonne garde les 44 px de la zone sensible et rien de plus.
local etroit = d.disposer(etat(4, 12, false), 480, 800, 30, 15, 13, 2)
aide.egal(etroit.colonne_curseur, d.CURSEUR_LARGEUR,
  "disposer : colonne du bandeau à 44 px en étroit")
aide.egal(etroit.bande, 2 * d.CURSEUR_LARGEUR + d.ESPACE + d.CADRE_GROUPE,
  "disposer : bandeau serré en étroit")

-- Fenêtre native la plus petite avec les trois curseurs généraux (Volume,
-- Pédale, Piano), quatre claviers et quinze jeux : la place manque pour une
-- disposition confortable, mais le repli doit garder deux sous-colonnes et
-- des rangées assez hautes pour deux lignes de texte ; sinon les noms se
-- superposent (mesuré sur l'orgue par défaut : r1 ≈ 9,36, r2 ≈ 4,74).
local petit = d.disposer(etat(4, 15, true), 800, 480, 9.36, 4.74, 13, 3)
aide.egal(petit.sous, 2, "disposer : 800x480, trois curseurs et quatre claviers, deux sous-colonnes")
aide.verifie(petit.jeu >= 2 * petit.police + 6,
  "disposer : 800x480, trois curseurs, rangées lisibles", petit.jeu)
aide.verifie(petit.bouton_reset >= 44,
  "disposer : 800x480, bouton de remise à zéro de 44 px", petit.bouton_reset)

-- Sans curseur général, la console retrouve toute la largeur.
local sans = d.disposer(etat(4, 12, false), 1024, 640, 30, 15, 16, 0)
aide.egal(sans.bande, 0, "disposer : aucun bandeau sans curseur général")
aide.egal(sans.l_jeux, 1024 - 2 * d.MARGE, "disposer : claviers sur toute la largeur sans bandeau")

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
