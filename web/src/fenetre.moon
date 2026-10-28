-- Interface native (Nuklear, module C « nk ») : le pendant de la page web,
-- dessinée dans une fenêtre Wayland ou X11. Lancée par init.moon dans un
-- processus fils ; lit l'état publié par le moteur et lui envoie les mêmes
-- commandes que l'interface web.
--
--   lancer = require "fenetre"
--   lancer organum, nk, {titre:, largeur:, hauteur:, continuer: -> bool,
--     volume: {lire: -> v, regler: (v) ->}}
--
-- volume (facultatif) : volume du système, 0 à 100, comme le curseur de la
-- page web ; à défaut, le curseur règle le volume interne du moteur.
--
-- Disposition en console : un clavier par colonne. Tout est calculé pour
-- tenir dans la fenêtre, sans défilement : hauteur des lignes et taille de
-- police suivent la taille de la fenêtre (agrandie ou maximisée, l'interface
-- grossit au lieu de seulement s'étirer).

-- Abréviation d'un clavier pour les accouplements (P+I, I+II…), comme la page web.
abrege = (nom) ->
  nom\match("^[Mm]anual%s+(%S+)$") or (nom\match("^[Pp]ed") and "P") or nom

nom_jeu = (jeu) -> (jeu.nom\gsub "\n", " ")

-- Marges de Nuklear (style par défaut) : intervalle entre lignes, marge de
-- la fenêtre, marge et bordure des groupes.
ESPACE, MARGE, MARGE_GROUPE = 4, 4, 6
-- Rapport hauteur de ligne / taille de police, et bornes de la police.
LIGNE_POLICE, POLICE_MIN, POLICE_MAX = 1.5, 10, 64

-- Un curseur ne renvoie une commande que si l'utilisateur l'a bougé : la
-- valeur rendue par Nuklear (flottant 32 bits) diffère sinon à peine de l'état.
bouge = (avant, apres) -> math.abs(apres - avant) > 1e-4

-- Disposition qui tient dans l × h : nombre de sous-colonnes de jeux par
-- clavier (1 à 3), lignes de combinaisons, hauteur de ligne, police.
-- rapport : largeur du plus long nom de jeu / taille de police.
disposer = (e, l, h, rapport) ->
  ndiv = math.max 1, #e.divisions
  maxjeux, liens = 0, false
  for d in *e.divisions
    maxjeux = math.max maxjeux, #d.jeux
    liens or= #d.liens > 0
  meilleure = nil
  for sous = 1, 3
    for lignes_combi = 1, 2
      -- Lignes : réglages, combinaisons, puis dans chaque colonne le nom, le
      -- gain, les jeux et les accouplements.
      haut = 1 + lignes_combi
      col = 2 + math.ceil(maxjeux / sous) + (liens and 1 or 0)
      fixe = 2 * MARGE + ESPACE * (haut + 1) + 2 * MARGE_GROUPE + ESPACE * col
      ligne = math.floor (h - fixe) / (haut + col)
      par_hauteur = ligne / LIGNE_POLICE
      -- Largeur : un nom de jeu par case, et « 32 » par combinaison.
      case = (l - 2 * MARGE) / ndiv / sous - 2 * MARGE_GROUPE / sous - ESPACE
      par_largeur = case / (rapport + 1)
      combi = (l - 2 * MARGE) / math.ceil(e.netapes / lignes_combi) - ESPACE
      par_combi = combi / 1.6
      taille = math.floor math.min(par_hauteur, par_largeur, par_combi, POLICE_MAX)
      if not meilleure or taille > meilleure.police
        meilleure = {police: math.max(taille, POLICE_MIN), :ligne, :sous, :lignes_combi, rangs: math.ceil(maxjeux / sous)}
  meilleure

(organum, nk, options = {}) ->
  -- Police : Alegreya Sans (OFL), réduite au latin, embarquée dans le zip.
  -- ORGANUM_POLICE : autre fichier .ttf, pour essayer une police.
  ttf = Slurp and (os.getenv("ORGANUM_POLICE") and Slurp(os.getenv "ORGANUM_POLICE") or
    Slurp "/zip/.polices/AlegreyaSans-Latin1.ttf")
  ui, err = nk.ouvrir options.titre or "organum", options.largeur or 1024,
    options.hauteur or 640, 20, ttf
  return nil, err unless ui
  continuer = options.continuer or -> true
  police, seq = 20, nil

  -- Volume du système : lu par un outil externe, donc relu toutes les
  -- 20 itérations (environ une seconde) ; pendant un glissement, envoyé au
  -- plus une itération sur trois, puis à sa valeur finale.
  systeme = options.volume
  vol_sys, a_envoyer, tour, envoye_au = nil, nil, 0, -10
  lire_sys = ->
    v = systeme.lire!
    v and v / 100

  while continuer!
    ouverte, sale = ui\evenements 50
    break unless ouverte
    tour += 1
    if systeme
      if a_envoyer and tour - envoye_au >= 3
        systeme.regler math.floor a_envoyer * 100 + 0.5
        a_envoyer, envoye_au = nil, tour
      elseif not a_envoyer and tour - envoye_au > 20 and tour % 20 == 0
        v = lire_sys!
        sale = true if v and v != vol_sys
        vol_sys = v or vol_sys
      vol_sys or= lire_sys!
    e = organum.etat!
    continue unless sale or e.seq != seq
    seq = e.seq

    l, h = ui\taille!
    -- Rapport largeur/taille du plus long nom de jeu, à la police courante.
    plus_long = 0
    for d in *e.divisions
      for j in *d.jeux
        plus_long = math.max plus_long, ui\largeur_texte nom_jeu j
    p = disposer e, l, h, plus_long / police
    if p.police != police
      ui\police p.police
      police = p.police
    ligne = p.ligne

    if ui\debut "", 0, 0, l, h
      -- Réglages généraux
      ui\ligne ligne, 6
      ui\texte "Volume", "droite"
      if systeme and vol_sys
        v = ui\curseur vol_sys, 0, 1, 0.01
        vol_sys, a_envoyer = v, v if bouge vol_sys, v
      else
        v = ui\curseur e.volume, 0, 1, 0.01
        organum.volume v if bouge e.volume, v
      ui\texte "Réverb.", "droite"
      r = ui\curseur e.reverb, 0, 1, 0.01
      organum.reverb r if bouge e.reverb, r
      ui\texte ""
      organum.panique! if ui\bouton "Panique"

      -- Combinaisons : l'étape courante est enfoncée.
      ui\ligne ligne, math.ceil(e.netapes / p.lignes_combi)
      for n = 1, e.netapes
        actif = e.etape == n - 1
        organum.midi 0xCF, n - 1 if ui\choix(tostring(n), actif) and not actif

      -- Claviers, un par colonne, sur toute la hauteur restante.
      reste = h - 2 * MARGE - (1 + p.lignes_combi) * (ligne + ESPACE) - ESPACE
      ui\ligne reste, #e.divisions
      for d, div in ipairs e.divisions
        if ui\groupe_debut "clavier #{d}"
          ui\ligne ligne, 1
          ui\texte div.nom, "centre"
          ui\ligne ligne, 2
          g = ui\curseur div.gain, 0, 1, 0.01
          organum.gain d, g if bouge div.gain, g
          if ui\bouton "Annuler"
            organum.jeu d, j, false for j = 1, #div.jeux
          ui\ligne ligne, p.sous
          for j, jeu in ipairs div.jeux
            organum.jeu d, j, not jeu.actif if ui\choix(nom_jeu(jeu), jeu.actif) != jeu.actif
          -- Lignes vides : les accouplements s'alignent en bas des colonnes.
          vides = p.rangs * p.sous - #div.jeux
          ui\texte "" for _ = 1, vides
          if #div.liens > 0
            ui\ligne ligne, #div.liens
            for i, lien in ipairs div.liens
              cible = e.divisions[lien.division]
              etiquette = "#{abrege div.nom}+#{abrege cible and cible.nom or '?'}"
              organum.lien d, i, not lien.actif if ui\choix(etiquette, lien.actif) != lien.actif
          ui\groupe_fin!
    ui\fin!
    ui\dessiner 30, 30, 30
  true
