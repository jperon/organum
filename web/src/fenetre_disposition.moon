-- Disposition de l'interface native, sans dépendance à Nuklear ni au
-- moteur : uniquement des calculs de tailles et de police. Extrait de
-- fenetre.moon pour être éprouvé sans affichage (tests unitaires).
--
--   d = require "fenetre_disposition"
--   d.disposer e, l, h, rapport, rapport_deux, cible

-- Marges de Nuklear (style par défaut) : intervalle entre lignes, marge de
-- la fenêtre, marge et bordure des groupes.
ESPACE, MARGE, MARGE_GROUPE = 4, 4, 6
-- Cadre exact d'un groupe à bordure (NK_WINDOW_BORDER) : 1 px de bordure et
-- 4 px de marge interne de chaque côté. MARGE_GROUPE reste la valeur
-- historique des calculs de largeur (arrondie au-dessus) ; CADRE_GROUPE est
-- la valeur exacte, utilisée pour la géométrie.
CADRE_GROUPE = 10
-- Curseur vertical : zone sensible de 44 px de large sur toute la hauteur,
-- bouton de 40 × 24 px (voir ui:curseur_vertical dans cosmo/lnuklear.c).
CURSEUR_LARGEUR, BOUTON_LARGEUR, BOUTON_HAUTEUR = 44, 40, 24
-- Largeur maximale d'une colonne du bandeau des curseurs généraux : bornée en
-- pixels, du même ordre que la colonne de gain des claviers, au lieu d'une
-- fraction de la fenêtre (un seizième faisait 64 px par colonne à 1024 px,
-- soit 20 % de la largeur pour trois réglages).
CURSEUR_MAX = 52
-- Bouton de remise à zéro des volumes, sous les curseurs du bandeau : cible
-- tactile de 44 px de haut, pleine largeur du bandeau.
BOUTON_RESET = 44
-- Rapport hauteur de ligne / taille de police, et bornes de la police.
LIGNE_POLICE, POLICE_MIN, POLICE_MAX = 1.25, 10, 64
-- Identique à MAX_ASSOCIATIONS de cosmo/lorganum.c (#define, 16) : au-delà,
-- le moteur refuse la liste. init.moon n'expose pas cette valeur dans l'état
-- partagé ; garder les deux constantes synchronisées.
MAX_ASSOCIATIONS = 16

-- Un curseur ne renvoie une commande que si l'utilisateur l'a bougé : la
-- valeur rendue par Nuklear (flottant 32 bits) diffère sinon à peine de l'état.
bouge = (avant, apres) -> math.abs(apres - avant) > 1e-4

-- Géométrie des rangées de Nuklear, partagée par fenetre.moon et les tests de
-- bout en bout (coordonnées cliquables). Tout est en pixels.

-- Largeur d'une case d'une rangée dynamique de n colonnes.
largeur_case = (largeur, n) -> (largeur - ESPACE * (n - 1)) / n

-- Bord gauche puis centre de la case c (0 à n-1) d'une telle rangée.
case_x = (x0, largeur, n, c) -> x0 + c * (largeur_case(largeur, n) + ESPACE)
case_centre = (x0, largeur, n, c) -> case_x(x0, largeur, n, c) + largeur_case(largeur, n) / 2

-- Ordonnée du centre de la rangée k : chaque rangée avance de sa hauteur
-- plus ESPACE, la première commençant à MARGE + ESPACE.
rangee_y = (k, hauteur) -> MARGE + ESPACE + k * (hauteur + ESPACE) + hauteur / 2

-- Ordonnée du premier widget à l'intérieur d'un groupe : bordure et marge
-- interne (CADRE_GROUPE / 2) puis espacement de la première rangée (ESPACE).
groupe_contenu = (y) -> y + CADRE_GROUPE / 2 + ESPACE

-- Case i (1 à #poids) d'une rangée à colonnes proportionnelles
-- (ui:ligne_ratio) : renvoie {x, largeur, centre}.
colonne_ratio = (x0, largeur, poids, i) ->
  total = 0
  for poids_i in *poids
    total += poids_i
  utile = largeur - ESPACE * (#poids - 1)
  x = x0
  for j = 1, i - 1
    x += utile * poids[j] / total + ESPACE
  l = utile * poids[i] / total
  {x: x, largeur: l, centre: x + l / 2}


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
-- des boutons de jeu, et largeur du bandeau des curseurs généraux.
-- rapport : largeur du plus long nom de jeu / taille de police.
-- rapport_deux : largeur de la plus longue moitié du meilleur découpage en
-- deux lignes / taille de police.
-- nb_generaux : nombre de curseurs généraux (Volume, Pédale, Piano…) placés
-- côte à côte dans le bandeau vertical de gauche ; 0 pour s'en passer.
--
-- On maximise d'abord la police jusqu'à `cible`, puis, à police égale, la
-- hauteur des boutons de jeu (donc plutôt plus de sous-colonnes). Les
-- rangées de réglages et de combinaisons prennent une hauteur confortable
-- (environ 2,2 × police, 36 px si la place le permet) ; toute la hauteur
-- restante revient aux claviers. Dans chaque clavier : une rangée pour le nom
-- et « Annuler », le bloc de jeux avec, à droite, le curseur de gain vertical
-- de la même hauteur, puis la rangée des accouplements. Si aucune disposition
-- ne tient, repli sur la plus grande police possible.
disposer = (e, l, h, rapport, rapport_deux, cible, nb_generaux = 0) ->
  ndiv = math.max 1, #e.divisions
  maxjeux, liens = 0, false
  for d in *e.divisions
    maxjeux = math.max maxjeux, #d.jeux
    liens or= #d.liens > 0
  -- Bandeau des curseurs généraux : une colonne par curseur, côte à côte,
  -- plus le cadre du groupe. La colonne garde la zone sensible de 44 px mais
  -- ne dépasse pas 52 px : c'est une largeur en pixels, pas une proportion de
  -- la fenêtre. La police de l'interface grandissant avec la fenêtre,
  -- fenetre.moon écrit l'étiquette et la valeur à une petite police
  -- (ui:police_petite) pour qu'elles tiennent dans la colonne.
  colonne_curseur = math.min CURSEUR_MAX, math.max(CURSEUR_LARGEUR, l / 16)
  -- Colonne de gain des claviers : même zone sensible, mais elle suit la
  -- largeur de la fenêtre comme avant (le libellé « Gain » et la valeur y
  -- tiennent à toute police) ; elle ne dépend pas de la borne du bandeau.
  colonne_gain = math.max CURSEUR_LARGEUR, l / 16
  bande = if nb_generaux > 0
    nb_generaux * colonne_curseur + (nb_generaux - 1) * ESPACE + CADRE_GROUPE
  else
    0
  -- Largeur laissée aux claviers, une case par division. Plancher à 1 px :
  -- une fenêtre minuscule ne doit pas produire un poids nul (refusé par
  -- ui:ligne_ratio) ; le bandeau cède alors la place.
  dispo = l - 2 * MARGE - (if nb_generaux > 0 then ESPACE else 0)
  l_jeux = math.max 1, dispo - bande
  bande = dispo - l_jeux
  -- Largeur du contenu d'un groupe de clavier, et largeur de la grille de
  -- jeux une fois réservée la colonne du curseur de gain. La colonne garde
  -- sa largeur sensible (44 px) tant que la case du clavier le permet ; dans
  -- une fenêtre minuscule elle se réduit plutôt que d'écraser les jeux.
  largeur_colonne = l_jeux / ndiv - CADRE_GROUPE
  curseur_largeur = math.min colonne_gain, math.max(8, largeur_colonne - 2 * MARGE_GROUPE)
  largeur_jeux = math.max 1, largeur_colonne - ESPACE - curseur_largeur
  meilleure, repli = nil, nil
  for sous = 1, 3
    rangs = math.ceil maxjeux / sous
    for lignes_combi = 1, 2
      -- Rangées : réglages puis combinaisons en haut ; dans chaque colonne,
      -- le nom et « Annuler », les jeux et leur curseur de gain, puis les
      -- accouplements.
      haut = 1 + lignes_combi
      col_jeu = math.max 1, rangs + (liens and 1 or 0)
      -- Hauteur occupée hors jeux : marges de la fenêtre et du groupe,
      -- rangées du haut, en-tête du clavier, espacements (celui de la
      -- première rangée du groupe et celui de la dernière rangée de jeux).
      -- Chaque essai de hauteur d'en-tête en déduit la hauteur de jeu
      -- disponible.
      fixe = 2 * MARGE + CADRE_GROUPE + 2 * ESPACE + (haut + 1) * ESPACE
      case_jeu = largeur_jeux / sous - ESPACE * (sous - 1) / sous
      -- Un nom sur deux lignes peut utiliser presque toute la case ; sur une
      -- ligne, ui:choix garde la marge de Selectable (2 px de chaque côté).
      dispo_deux = math.max 0, case_jeu - 2
      dispo_un = math.max 0, case_jeu - 4
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
            hauteur = (h - fixe - (haut + 1) * essai) / col_jeu - ESPACE
            if hauteur >= min_jeu
              entete, jeu = essai, hauteur
              break
          if entete
            score = math.min police, cible
            if not meilleure or score > meilleure.score or (score == meilleure.score and jeu > meilleure.jeu)
              meilleure = {police: police, entete: entete, jeu: jeu, case: case_jeu, :sous, :lignes_combi, :rangs, :score}
            break
      -- Repli pour une fenêtre trop petite : la plus grande police possible,
      -- quitte à rogner les rangées d'en-tête. La police est d'abord bornée
      -- par la hauteur de rangée (deux lignes de texte doivent tenir, sinon un
      -- clavier de quinze jeux dans une fenêtre basse superposerait les noms),
      -- puis, entre deux replis, on préfère des rangées lisibles, la plus
      -- large case de jeu et enfin la plus haute : à 800 × 480 avec quatre
      -- claviers, deux sous-colonnes rognent à peine les noms les plus longs,
      -- une seule les rend illisibles.
      police_repli = math.max POLICE_MIN, math.min(par_largeur, POLICE_MAX)
      entete_repli, jeu_repli = nil, nil
      for _ = 1, 4
        entete_essai = math.max police_repli + 4, math.ceil(2.2 * police_repli)
        jeu_essai = math.max 1, (h - fixe - (haut + 1) * entete_essai) / col_jeu - ESPACE
        police_essai = math.max POLICE_MIN, math.floor (jeu_essai - 6) / 2
        entete_repli, jeu_repli = entete_essai, jeu_essai
        break if police_essai >= police_repli
        police_repli = police_essai
      candidat = {
        police: police_repli
        entete: entete_repli
        jeu: jeu_repli
        case: case_jeu
        :sous, :lignes_combi, :rangs
        lisible: jeu_repli >= 2 * police_repli + 6
      }
      if not repli or (candidat.lisible and not repli.lisible) or
          (candidat.lisible == repli.lisible and
           (candidat.case > repli.case + 1e-6 or
            (math.abs(candidat.case - repli.case) <= 1e-6 and candidat.jeu > repli.jeu)))
        repli = candidat
  p = meilleure or repli
  p.bande, p.l_jeux, p.nb_generaux = bande, l_jeux, nb_generaux
  p.largeur_colonne, p.largeur_jeux = largeur_colonne, largeur_jeux
  p.curseur_largeur, p.colonne_curseur = curseur_largeur, colonne_curseur
  p.colonne_gain = colonne_gain
  p.haut = 1 + p.lignes_combi
  -- Hauteur de la rangée principale (bandeau et claviers) : tout ce qui
  -- reste après les rangées du haut et l'espacement de fin de rangée.
  p.reste = h - 2 * MARGE - p.haut * (p.entete + ESPACE) - ESPACE
  -- Hauteur d'une ligne d'étiquette ou de valeur d'un curseur vertical, et
  -- hauteur du curseur du bandeau (celui des claviers occupe tout le bloc).
  -- Sous la valeur viennent la remise à zéro des volumes, puis la
  -- transposition globale (étiquette et rangée −/valeur/+).
  etiquette = math.min p.entete, math.max(p.police + 2, 14)
  p.etiquette_curseur = etiquette
  contenu = p.reste - CADRE_GROUPE
  -- La transposition n'est dessinée que si la place reste confortable :
  -- trois rangées de cible (curseur, ↺, transposition) d'au moins 24 px et
  -- trois étiquettes doivent tenir. Dans une fenêtre très basse elle est omise
  -- (bouton 0) plutôt que de déborder du groupe.
  p.transposition_visible = contenu >= 3 * etiquette + 5 * ESPACE + 3 * BOUTON_HAUTEUR
  p.bouton_transposition = 0
  if p.transposition_visible
    p.bouton_transposition = math.max BOUTON_HAUTEUR,
      math.min BOUTON_RESET, contenu - 5 * ESPACE - 3 * etiquette - 2 * BOUTON_HAUTEUR
  lignes = if p.transposition_visible then 6 else 4
  etiquettes = if p.transposition_visible then 3 else 2
  -- Le bouton de remise à zéro vise 44 px ; dans une fenêtre si basse que
  -- même le curseur minimal ne tiendrait pas, il se réduit (le plancher est
  -- la hauteur du bouton de curseur), plutôt que de déborder du groupe.
  p.bouton_reset = math.max BOUTON_HAUTEUR,
    math.min BOUTON_RESET,
      contenu - (lignes - 1) * ESPACE - etiquettes * etiquette -
        p.bouton_transposition - BOUTON_HAUTEUR
  p.bande_curseur = math.max BOUTON_HAUTEUR,
    contenu - (lignes - 1) * ESPACE - etiquettes * etiquette -
      p.bouton_reset - p.bouton_transposition
  p

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
  :CADRE_GROUPE, :CURSEUR_LARGEUR, :CURSEUR_MAX, :BOUTON_LARGEUR, :BOUTON_HAUTEUR
  :BOUTON_RESET
  :LIGNE_POLICE, :POLICE_MIN, :POLICE_MAX
  :bouge, :decoupe
  :largeur_case, :case_x, :case_centre, :rangee_y, :groupe_contenu, :colonne_ratio
  :disposer, :disposer_midi, :disposer_connexions, :disposer_qualite
  :texte_calibration
}
