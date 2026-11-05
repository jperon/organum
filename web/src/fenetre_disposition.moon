-- Disposition de l'interface native, sans dépendance à Nuklear ni au
-- moteur : uniquement des calculs de tailles et de police. Extrait de
-- fenetre.moon pour être éprouvé sans affichage (tests unitaires).
--
--   d = require "fenetre_disposition"
--   d.disposer e, l, h, rapport, rapport_deux, cible

-- Marges de Nuklear (style par défaut) : intervalle entre lignes, marge de
-- la fenêtre, marge et bordure des groupes.
ESPACE, MARGE, MARGE_GROUPE = 4, 4, 6
-- Rapport hauteur de ligne / taille de police, et bornes de la police.
LIGNE_POLICE, POLICE_MIN, POLICE_MAX = 1.25, 10, 64
-- Identique à MAX_ASSOCIATIONS de cosmo/lorganum.c (#define, 16) : au-delà,
-- le moteur refuse la liste. init.moon n'expose pas cette valeur dans l'état
-- partagé ; garder les deux constantes synchronisées.
MAX_ASSOCIATIONS = 16

-- Un curseur ne renvoie une commande que si l'utilisateur l'a bougé : la
-- valeur rendue par Nuklear (flottant 32 bits) diffère sinon à peine de l'état.
bouge = (avant, apres) -> math.abs(apres - avant) > 1e-4

-- Découpe un nom de jeu à un espace, en deux lignes les plus équilibrées
-- possibles : renvoie {a, b, large} où large est la largeur de la ligne la
-- plus longue, ou nil si le nom n'a pas d'espace où se couper.
decoupe = (ui, texte) ->
  meilleure = nil
  for i = 2, #texte - 1
    if texte\sub(i, i) == " "
      a = texte\sub 1, i - 1
      b = texte\sub i + 1
      large = math.max ui\largeur_texte(a), ui\largeur_texte(b)
      if not meilleure or large < meilleure.large
        meilleure = {:a, :b, :large}
  meilleure

-- Disposition qui tient dans l × h : nombre de sous-colonnes de jeux par
-- clavier (1 à 3), lignes de combinaisons, police, hauteurs de l'en-tête et
-- des boutons de jeu.
-- rapport : largeur du plus long nom de jeu / taille de police.
-- rapport_deux : largeur de la plus longue moitié du meilleur découpage en
-- deux lignes / taille de police.
--
-- On maximise d'abord la police jusqu'à `cible`, puis, à police égale, la
-- hauteur des boutons de jeu (donc plutôt plus de sous-colonnes). Les
-- rangées de réglages, combinaisons, nom et gain prennent une hauteur
-- confortable (environ 2,2 × police, 36 px si la place le permet) ; toute la
-- hauteur restante est répartie à parts égales entre les jeux et les
-- accouplements. Si aucune disposition ne tient, repli sur la plus grande
-- police possible.
disposer = (e, l, h, rapport, rapport_deux, cible) ->
  ndiv = math.max 1, #e.divisions
  maxjeux, liens = 0, false
  for d in *e.divisions
    maxjeux = math.max maxjeux, #d.jeux
    liens or= #d.liens > 0
  meilleure, repli = nil, nil
  for sous = 1, 3
    rangs = math.ceil maxjeux / sous
    for lignes_combi = 1, 2
      -- Rangées : réglages puis combinaisons en haut ; dans chaque colonne,
      -- le nom, le gain, les jeux et les accouplements.
      haut = 1 + lignes_combi
      col_jeu = math.max 1, rangs + (liens and 1 or 0)
      col = 2 + col_jeu
      fixe = 2 * MARGE + ESPACE * (haut + 1) + 2 * MARGE_GROUPE + ESPACE * col
      largeur_case = (l - 2 * MARGE) / ndiv / sous - 2 * MARGE_GROUPE / sous - ESPACE
      -- Un nom sur deux lignes peut utiliser presque toute la case ; sur une
      -- ligne, ui:choix garde la marge de Selectable (2 px de chaque côté).
      dispo_deux = math.max 0, largeur_case - 2
      dispo_un = math.max 0, largeur_case - 4
      combi = (l - 2 * MARGE) / math.ceil(e.netapes / lignes_combi) - ESPACE
      par_largeur = math.floor math.min POLICE_MAX, dispo_deux / math.max(rapport_deux, 0.001), combi / 1.5
      if par_largeur >= POLICE_MIN
        debut = math.min cible, par_largeur
        for police = debut, POLICE_MIN, -1
          une_ligne = police * rapport <= dispo_un
          besoin = if une_ligne then police + 4 else 2 * police + 6
          min_jeu = if h >= 600 then math.max 44, besoin else besoin
          entete, jeu = nil, nil
          -- 36 px d'abord ; si la fenêtre ne le permet pas, 2,2 × police,
          -- puis seulement 2 × police pour ne pas écraser les jeux.
          for essai in *{math.max(36, math.ceil(2.2 * police)), math.ceil(2.2 * police), math.max(police + 4, 2 * police)}
            hauteur = (h - fixe - (haut + 2) * essai) / col_jeu
            if hauteur >= min_jeu
              entete, jeu = essai, hauteur
              break
          if entete
            score = math.min police, cible
            if not meilleure or score > meilleure.score or (score == meilleure.score and jeu > meilleure.jeu)
              meilleure = {police: police, entete: entete, jeu: jeu, case: largeur_case, :sous, :lignes_combi, :rangs, :score}
            break
      -- Repli pour une fenêtre trop petite : la plus grande police possible,
      -- quitte à rogner les rangées d'en-tête.
      if not repli or par_largeur > repli.police
        police_repli = math.max POLICE_MIN, par_largeur
        entete_repli = math.max police_repli + 4, math.ceil(2.2 * police_repli)
        jeu_repli = math.max 1, (h - fixe - (haut + 2) * entete_repli) / col_jeu
        repli = {police: police_repli, entete: entete_repli, jeu: jeu_repli, case: largeur_case, :sous, :lignes_combi, :rangs}
  meilleure or repli

-- Disposition du panneau MIDI : en-tête sur deux lignes (navigation, puis
-- compteurs), une ligne par clavier, contrôle, expression, actions, puis une
-- ligne par association. assoc_max indique combien d'associations afficher ;
-- compte dit si la ligne « … n non affichée(s) » a une place ; trop_petit
-- signale que même les lignes de base ne tiennent pas (on n'affiche alors
-- qu'une ligne d'avertissement).
disposer_midi = (e, cfg, l, h) ->
  ndiv = math.max 1, #e.divisions
  nassoc = #cfg.associations
  base = ndiv + 5
  rows = base + nassoc
  fixe = 2 * MARGE + ESPACE * (rows + 1)
  ligne = math.floor (h - fixe) / rows
  par_hauteur = ligne / LIGNE_POLICE
  -- 17 colonnes : nom du clavier, puis les canaux 1 à 16.
  case = (l - 2 * MARGE) / 17 - ESPACE
  par_largeur = case / 1.2
  -- Lignes d'association et d'actions : 5 colonnes de boutons. Sans cette
  -- borne, « Apprendre », « Cible Gain » ou « Tout effacer » déborderaient
  -- de leur case quand la fenêtre est agrandie.
  case_action = (l - 2 * MARGE) / 5 - ESPACE
  par_bouton = case_action / 5.5
  police = math.floor math.min(par_hauteur, par_largeur, par_bouton, POLICE_MAX)
  assoc_max, compte, trop_petit = nassoc, false, false
  if police < POLICE_MIN
    police = POLICE_MIN
    ligne = math.ceil(police * LIGNE_POLICE)
    dispo = h - 2 * MARGE - ESPACE
    -- Hauteur d'une ligne : ligne pixels plus ESPACE, la première marge
    -- (ESPACE) étant déjà retirée de dispo.
    rows_fit = math.floor dispo / (ligne + ESPACE)
    if rows_fit < base
      -- Même les lignes de base débordent : une seule ligne, avec Retour.
      trop_petit = true
      assoc_max = 0
    else
      place = rows_fit - base
      if nassoc > 0 and place < nassoc and place >= 1
        -- Réserver une ligne au compte des associations masquées.
        assoc_max = place - 1
        compte = true
      else
        assoc_max = math.min nassoc, place
  else
    ligne = math.max 1, ligne
  {police: police, :ligne, :assoc_max, :compte, :trop_petit}

-- Disposition de l'écran Connexions : en-tête, titres de colonnes, une ligne
-- par port, puis un pied (message d'erreur ou compteur de ports masqués).
-- Même logique que disposer_midi : tout doit tenir sans défilement.
disposer_connexions = (nports, l, h) ->
  base = 3
  rows = base + nports
  fixe = 2 * MARGE + ESPACE * (rows + 1)
  ligne = math.floor (h - fixe) / rows
  par_hauteur = ligne / LIGNE_POLICE
  -- Trois colonnes : libellé du port, état, action. Le libellé (« 24:0 —
  -- Clavier USB ») est long ; l'en-tête a quatre colonnes plus étroites et
  -- porte « Connexions MIDI ». Borner la police sur les deux largeurs, sinon
  -- le titre et le libellé déborderaient, surtout dans le harnais agrandi.
  case = (l - 2 * MARGE) / 3 - ESPACE
  case_entete = (l - 2 * MARGE) / 4 - ESPACE
  par_largeur = math.min case / 10, case_entete / 8
  police = math.floor math.min(par_hauteur, par_largeur, POLICE_MAX)
  visibles, compte, trop_petit = nports, false, false
  if police < POLICE_MIN
    police = POLICE_MIN
    ligne = math.ceil(police * LIGNE_POLICE)
    dispo = h - 2 * MARGE - ESPACE
    rows_fit = math.floor dispo / (ligne + ESPACE)
    if rows_fit < base
      trop_petit = true
      visibles = 0
    else
      place = rows_fit - base
      if nports > place
        -- Réserver une ligne au compte des ports masqués.
        visibles = place > 0 and place - 1 or 0
        compte = true
      else
        visibles = nports
  else
    ligne = math.max 1, ligne
  {police: police, :ligne, :visibles, :compte, :trop_petit, colonne: case}

-- Disposition du panneau Qualité : une ligne d'en-tête, une par réglage,
-- puis les lignes facultatives (tête de réverbération, calibration) et le
-- message d'état. rows vient de l'appelant ; colonnes est le nombre de cases
-- de la ligne « Niveau » (6 avec Auto, 5 sinon). Comme les autres panneaux,
-- tout doit tenir sans défilement : la police est bornée par la hauteur et
-- par la largeur, et si même la police plancher ne suffit pas, trop_petit
-- le signale (une seule ligne d'avertissement est alors dessinée).
disposer_qualite = (rows, l, h, colonnes) ->
  fixe = 2 * MARGE + ESPACE * (rows + 1)
  ligne = math.floor (h - fixe) / rows
  par_hauteur = ligne / LIGNE_POLICE
  case = (l - 2 * MARGE) / colonnes - ESPACE
  -- 8,7 : les libellés de tempérament les plus longs (« Werckmeister III »,
  -- 16 caractères) doivent tenir dans une case, pas seulement les nombres.
  par_largeur = case / 8.7
  police = math.floor math.min(par_hauteur, par_largeur, POLICE_MAX)
  trop_petit = false
  if police < POLICE_MIN
    police = POLICE_MIN
    ligne = math.ceil(police * LIGNE_POLICE)
    dispo = h - 2 * MARGE - ESPACE
    rows_fit = math.floor dispo / (ligne + ESPACE)
    trop_petit = rows_fit < rows
  else
    ligne = math.max 1, ligne
  {police: police, :ligne, :trop_petit}

-- Ligne d'information de la calibration automatique (facultative) : niveau
-- choisi, temps estimé pour ce niveau, échéance du bloc, nombre de voix de
-- référence. Les champs absents sont simplement omis.
texte_calibration = (c) ->
  parties = {}
  if type(c.niveau) == "number"
    table.insert parties, "Calibration : niveau #{c.niveau}"
  else
    table.insert parties, "Calibration automatique"
  est = c.estimation_ms
  if type(est) == "table" and type(c.niveau) == "number" and type(est[c.niveau + 1]) == "number"
    table.insert parties, ("estimation %.1f ms")\format est[c.niveau + 1]
  elseif type(est) == "number"
    table.insert parties, ("estimation %.1f ms")\format est
  if type(c.echeance_ms) == "number"
    table.insert parties, ("échéance %.1f ms")\format c.echeance_ms
  if type(c.voix_ref) == "number"
    table.insert parties, "#{c.voix_ref} voix"
  if type(c.tete_reverb) == "boolean"
    table.insert parties, c.tete_reverb and "tête zéro latence" or "sans tête"
  table.concat parties, " · "

{
  :ESPACE, :MARGE, :MARGE_GROUPE
  :LIGNE_POLICE, :POLICE_MIN, :POLICE_MAX
  :bouge, :decoupe
  :disposer, :disposer_midi, :disposer_connexions, :disposer_qualite
  :texte_calibration
}
