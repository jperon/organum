-- Interface native (Nuklear, module C « nk ») : le pendant de la page web,
-- dessinée dans une fenêtre Wayland ou X11. Lancée par init.moon dans un
-- processus fils ; lit l'état publié par le moteur et lui envoie les mêmes
-- commandes que l'interface web.
--
--   lancer = require "fenetre"
--   lancer organum, nk, {titre:, largeur:, hauteur:, continuer: -> bool,
--     volume: {lire: -> v, regler: (v) ->},
--     midi: {etat: -> cfg, appliquer: (cfg) ->, enregistrer: (cfg) ->}}
--
-- volume (facultatif) : volume du système, 0 à 100, comme le curseur de la
-- page web ; à défaut, le curseur règle le volume interne du moteur.
--
-- authentification et reseaux (facultatifs) : même contrat que la page web
-- pour la lecture seule (etat) ; la fenêtre est locale, donc jamais filtrée
-- par le fichier de réseaux.
--
-- midi (facultatif) : active le panneau MIDI (bouton « MIDI » dans la barre
-- de réglages). etat renvoie la configuration au format d'etat_midi
-- (divisions[].canaux, controle, expression, associations), appliquer
-- l'envoie au moteur et enregistrer l'écrit dans midi.json ; sans
-- cette option, le bouton et le panneau sont absents. Le panneau remplace
-- la console et tient dans la fenêtre, sans défilement : si la place manque
-- à la police plancher, seule une partie des associations est affichée (le
-- nombre de celles qui restent cachées est indiqué). Chaque bouton de canal
-- s'allume sur l'activité MIDI récente (ui\etat : vert pour l'activité, bleu
-- pour la sélection). « Connexions » ouvre la liste des ports du séquenceur
-- (organum.midi_ports) et permet de connecter/déconnecter une source.
--
-- Disposition en console : un clavier par colonne. Tout est calculé pour
-- tenir dans la fenêtre, sans défilement : hauteur des lignes et taille de
-- police suivent la taille de la fenêtre (agrandie ou maximisée, l'interface
-- grossit au lieu de seulement s'étirer).

-- Présentation partagée avec la page web (modele.moon) : abréviations,
-- noms de jeux, canaux et libellés d'associations ont une seule source.
modele = require "modele"

-- Disposition pure (tailles, police, découpe des noms) : module séparé,
-- testable sans Nuklear ni moteur.
{ :ESPACE, :MARGE, :MARGE_GROUPE
  :LIGNE_POLICE, :POLICE_MIN, :POLICE_MAX
  :bouge, :decoupe
  :disposer, :disposer_midi, :disposer_connexions, :disposer_qualite
  :texte_calibration } = require "fenetre_disposition"

-- Identique à MAX_ASSOCIATIONS de cosmo/lorganum.c (#define, 16) : au-delà,
-- le moteur refuse la liste. init.moon n'expose pas cette valeur dans l'état
-- partagé ; garder les deux constantes synchronisées.
MAX_ASSOCIATIONS = 16


(organum, nk, options = {}) ->
  -- Police : Libertinus Serif (OFL), réduite au latin, embarquée dans le zip.
  -- ORGANUM_POLICE : autre fichier .ttf, pour essayer une police.
  ttf = Slurp and (os.getenv("ORGANUM_POLICE") and Slurp(os.getenv "ORGANUM_POLICE") or
    Slurp "/zip/.polices/LibertinusSerif-Latin1.ttf")
  ui, err = nk.ouvrir options.titre or "organum", options.largeur or 1024,
    options.hauteur or 640, 20, ttf
  return nil, err unless ui
  continuer = options.continuer or -> true
  police, seq = 20, nil
  midi = options.midi
  mode = "console"  -- "console", "midi", "connexions" ou "qualite" ; ces panneaux remplacent la console
  mc = nil           -- configuration MIDI locale, même forme qu'etat_midi
  -- Qualité : options.qualite (facultatif) fournit l'état complet (niveau,
  -- auto, tête de réverbération, calibration) et l'enregistrement persistant ;
  -- sans lui, la fenêtre reste utilisable sur les quatre champs à chaud que
  -- publie le moteur. message_qualite affiche un échec ou un redémarrage.
  qualite_opt = options.qualite
  message_qualite = nil
  -- Authentification facultative : même contrat que la page web pour la
  -- lecture seule. La fenêtre ne saisit plus de texte : la configuration se
  -- fait depuis la page web.
  auth_opt = options.authentification
  auth_courant = nil
  -- Contrôle d'accès par sous-réseau source : lecture seule, la fenêtre est
  -- locale et ne modifie pas la liste.
  reseaux_opt = options.reseaux
  reseaux_courant = nil
  -- Tempérament : la cible en cours est publiée par le serveur
  -- (qualite.temperament_cible), donc identique à celle des autres
  -- interfaces. temperament_cible ne garde qu'un retour immédiat au clic,
  -- le temps de la lecture suivante ; il distingue la cible en cours
  -- (libellé suivi de « … ») du tempérament réellement en service.
  temperament_cible = nil
  cible_apprentissage = "volume"
  -- Apprentissage : {i: n} refait l'association n, {nouveau: true} attend un
  -- contrôle pour en créer une. dernier_vu est le dernier contrôle publié au
  -- moment où l'on arme, afin d'attendre le suivant (comme la page web).
  apprentissage, dernier_vu, message_midi = nil, nil, nil
  seq_midi, attente_midi, tour_envoi = nil, false, 0
  -- Activité MIDI : canaux_actifs est hors seq (éphémère, 250 ms). On garde le
  -- dernier masque dessiné pour réveiller la boucle quand il change, sans
  -- relire la configuration ni réinitialiser la saisie.
  seq_actifs = nil
  -- Écran Connexions : liste relue à l'entrée, après une action, par le bouton
  -- « Rafraîchir » et périodiquement (voir rafraichir_ports).
  ports, message_ports, tour_ports = {}, nil, -100
  tour_qualite = -100
  tour = 0

  cibles = {"volume", "reverb", "gain"}
  cible_suivante = (c) ->
    for i, v in ipairs cibles
      return cibles[i % #cibles + 1] if v == c
    "volume"
  dedans = (liste, c) ->
    for v in *liste
      return true if v == c
    false
  -- Tronque un libellé à la largeur d'une colonne, avec des points de
  -- suspension : Nuklear ne coupe pas le texte au bord du widget, il
  -- déborderait sur la colonne suivante.
  tronquer = (texte, largeur) ->
    return texte if ui\largeur_texte(texte) <= largeur
    n = utf8.len(texte) or #texte
    for i = n - 1, 0, -1
      fin = utf8.offset texte, i + 1
      essai = if fin then texte\sub(1, fin - 1) .. "…" else "…"
      return essai if ui\largeur_texte(essai) <= largeur
    "…"
  basculer = (liste, c) ->
    for i, v in ipairs liste
      if v == c
        table.remove liste, i
        return
    table.insert liste, c
  copie_controle = (d) ->
    d and {canal: d.canal, cc: d.cc, valeur: d.valeur}
  meme_controle = (a, b) ->
    return true if not a and not b
    return false unless a and b
    a.canal == b.canal and a.cc == b.cc and a.valeur == b.valeur
  canaux_egaux = (a, b) ->
    a or= {}
    b or= {}
    return false if #a != #b
    for i = 1, #a
      return false if a[i] != b[i]
    true
  associations_egales = (a, b) ->
    a or= {}
    b or= {}
    return false if #a != #b
    for i = 1, #a
      x, y = a[i], b[i]
      return false unless type(x) == "table" and type(y) == "table"
      return false unless x.cc == y.cc
      return false unless (x.canal or 0) == (y.canal or 0)
      return false unless (x.cible or "aucune") == (y.cible or "aucune")
      return false unless (x.division or 1) == (y.division or 1)
    true
  memes_reglages = (a, b) ->
    return false unless type(a) == "table" and type(b) == "table"
    ad, bd = a.divisions or {}, b.divisions or {}
    return false if #ad != #bd
    for i = 1, #ad
      return false unless canaux_egaux ad[i].canaux, bd[i].canaux
    return false unless canaux_egaux a.controle, b.controle
    return false unless canaux_egaux a.expression, b.expression
    associations_egales a.associations, b.associations
  normaliser_midi = (cfg, e) ->
    cfg or= {}
    cfg.divisions = {} unless type(cfg.divisions) == "table"
    for d = 1, #e.divisions
      cd = cfg.divisions[d]
      unless type(cd) == "table"
        cd = {nom: e.divisions[d].nom, canaux: {}}
        cfg.divisions[d] = cd
      cd.nom = e.divisions[d].nom unless cd.nom
      cd.canaux = {} unless type(cd.canaux) == "table"
    for k in *{"controle", "expression", "associations"}
      cfg[k] = {} unless type(cfg[k]) == "table"
    cfg
  -- Configuration vide de secours quand midi.etat échoue : le panneau reste
  -- utilisable au lieu de faire tomber la fenêtre.
  etat_midi_vide = ->
    cfg = {divisions: {}, controle: {}, expression: {}, associations: {}}
    for k in *{"divisions", "controle", "expression", "associations"}
      cfg[k] = modele.liste_json cfg[k]
    cfg
  -- Avant enregistrement, toutes les listes doivent rester des tableaux JSON,
  -- même vides : sans la marque [0] = false de modele.liste_json, redbean
  -- encode {} et midi.json ne recharge plus une liste.
  preparer_json = (cfg) ->
    cfg.divisions = modele.liste_json cfg.divisions
    for d in *cfg.divisions
      d.canaux = modele.liste_json d.canaux if type(d) == "table"
    for k in *{"controle", "expression", "associations"}
      cfg[k] = modele.liste_json cfg[k]
    cfg
  -- Lecture protégée de midi.etat : renvoie la configuration normalisée et,
  -- en cas d'échec, le message à afficher.
  lire_etat_midi = (e) ->
    ok, brut = pcall midi.etat
    if ok
      return normaliser_midi(brut, e), nil
    etat_midi_vide!, "État MIDI illisible"
  -- Armer l'apprentissage : on note le contrôle déjà reçu, le prochain
  -- changement de dernier_controle (publié par le fil audio, qui incrémente
  -- seq) déclenche la capture.
  armer = (quoi, dernier) ->
    apprentissage = quoi
    dernier_vu = copie_controle dernier
    message_midi = nil
  -- Chaque changement part au moteur puis dans midi.json (callbacks
  -- d'init.moon) ; on force un redessin sans attendre le fil audio.
  envoyer_midi = (cfg) ->
    cfg = preparer_json cfg
    ok, err = pcall ->
      applique, raison = midi.appliquer cfg
      error raison unless applique
      midi.enregistrer cfg
    Log kLogWarn, "fenêtre : MIDI : #{err}" if not ok and Log
    if ok
      attente_midi = true
      tour_envoi = tour
    seq = nil
  -- Libellés d'état de l'écran Connexions (modele.etat_port renvoie la clé).
  ETATS_PORTS =
    organum: "Organum"
    connecte: "Connecté"
    destination: "Destination"
    disponible: "Disponible"

  -- Ports du séquenceur. midi_ports() énumère les ports ALSA : on ne l'appelle
  -- pas à chaque image. La liste est relue à l'entrée de l'écran, après chaque
  -- connexion, au clic sur « Rafraîchir » et toutes les ~2 s (40 × 50 ms), ce
  -- qui suffit à voir apparaître un port sans coût perceptible. En cas
  -- d'échec la liste est vide et un message court reste affiché.
  rafraichir_ports = ->
    ok, liste = pcall organum.midi_ports
    if ok and type(liste) == "table"
      ports = liste
      message_ports = nil
    else
      ports = {}
      message_ports = "Ports MIDI indisponibles"
      Log kLogWarn, "fenêtre : ports MIDI : #{liste}" if Log

  -- Abonne ou désabonne une source, puis relit la liste. Les erreurs du
  -- moteur (port disparu, 0:1 refusé…) deviennent un message, pas une
  -- exception : la fenêtre reste utilisable.
  agir_port = (p) ->
    action = p.connecte and organum.midi_deconnecter or organum.midi_connecter
    ok, err = pcall action, p.client, p.port
    rafraichir_ports!
    unless ok
      detail = tostring(err)\match(": ([^:]+)$") or tostring(err)
      message_ports = "Échec : #{detail}"
    seq = nil

  afficher_canaux = (titre, liste, ligne, actifs) ->
    ui\ligne ligne, 17
    ui\texte titre
    for c = 1, 16
      selection = dedans liste, c
      allume = ((actifs or 0) >> (c - 1)) & 1 == 1
      -- ui\etat distingue la sélection (bleu) de l'activité (vert) ; seule
      -- une interaction utilisateur modifie la sélection.
      nouvelle = ui\etat tostring(c), selection, allume
      if nouvelle != selection
        basculer liste, c
        envoyer_midi mc

  -- Volume du système : lu par un outil externe, donc relu toutes les
  -- 20 itérations (environ une seconde) ; pendant un glissement, envoyé au
  -- plus une itération sur trois, puis à sa valeur finale.
  systeme = options.volume
  vol_sys, a_envoyer, envoye_au = nil, nil, -10
  lire_sys = ->
    v = systeme.lire!
    v and v / 100

  -- État de qualité pour le panneau. Avec options.qualite, on interroge son
  -- état complet ; sinon on se rabat sur les quatre champs à chaud du moteur
  -- et le niveau se déduit des présélections (modele.niveau_correspondant).
  etat_qualite = (e) ->
    base = e.qualite or {}
    if qualite_opt and qualite_opt.etat
      ok, q = pcall qualite_opt.etat
      if ok and type(q) == "table"
        q.reverb = e.reverb if type(e.reverb) == "number"
        return q
    {
      temperament: e.temperament or 5
      temperament_erreur: base.temperament_erreur or ""
      temperament_cible: base.temperament_cible or -1
      bruit_attaque: base.bruit_attaque == true
      instabilite: base.instabilite == true
      spatialisation: base.spatialisation or 0
      polyphonie_max: base.polyphonie_max or 0
      tete_reverb: base.tete_reverb
      tete_reverb_prochain: base.tete_reverb
      tete_reverb_impose: base.tete_reverb_impose == true
      periode: e.periode
      periode_prochain: e.periode
      periode_impose: false
      taux: e.taux
      taux_prochain: e.taux
      taux_impose: false
      peripherique: ""
      peripherique_prochain: ""
      peripherique_impose: false
      limiteur: true
      limiteur_prochain: true
      limiteur_impose: false
      audio_repli: ""
      application: base.application == true
      application_audio: base.application_audio == true
      charge: base.charge or 0
      charge_pointe: base.charge_pointe or 0
      charge_evaluee: base.charge_evaluee == true
      charge_niveau: base.charge_niveau or 0
      xruns_recents: base.xruns_recents or 0
      xruns: e.xruns or 0
      reverb: e.reverb
      niveau: modele.niveau_correspondant base
      calibration: base.calibration
    }

  -- Applique un ou plusieurs réglages. Avec options.qualite, c'est lui qui
  -- enregistre et applique à chaud ; sinon on écrit directement les champs
  -- à chaud du moteur et une présélection est décomposée en ses quatre
  -- champs.
  regler_qualite = (payload) ->
    message_qualite = nil
    -- Le tempérament passe par son propre calcul différé, pas par les
    -- réglages de qualité : même chemin que POST /api/orgue {"temperament"}.
    if payload.temperament != nil
      ok, err = pcall organum.temperament, payload.temperament
      if ok
        temperament_cible = payload.temperament
      else
        message_qualite = "Échec de l'enregistrement des réglages"
        Log kLogWarn, "fenêtre : tempérament : #{err}" if Log
      seq = nil
      return
    if qualite_opt and qualite_opt.regler
      ok, res = pcall qualite_opt.regler, payload
      if not ok then
        message_qualite = "Échec de l'enregistrement des réglages"
        Log kLogWarn, "fenêtre : qualité : #{res}" if Log
      seq = nil
      return
    if payload.niveau != nil
      pr = modele.PRESELECTIONS[payload.niveau + 1]
      if pr
        organum.qualite "spatialisation", pr.spatialisation
        organum.qualite "bruit_attaque", pr.bruit_attaque
        organum.qualite "instabilite", pr.instabilite
        organum.qualite "polyphonie_max", pr.polyphonie_max
    else
      for k, v in pairs payload
        switch k
          when "bruit_attaque", "instabilite"
            organum.qualite k, v == true
          when "spatialisation", "polyphonie_max"
            organum.qualite k, math.floor v
    seq = nil

  -- État de l'authentification : avec options.authentification, c'est le
  -- module qui répond ; sinon le panneau l'indique indisponible.
  etat_auth = ->
    if auth_opt and auth_opt.etat
      ok, a = pcall auth_opt.etat
      if ok and type(a) == "table"
        return a
    {active: false, utilisateur: "organiste", source: "aucune", erreur: nil}

  etat_reseaux = ->
    if reseaux_opt and reseaux_opt.etat
      ok, r = pcall reseaux_opt.etat
      if ok and type(r) == "table"
        return r
    {active: false, texte: "", source: nil, erreur: nil}

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
    -- Les ports MIDI peuvent apparaître ou disparaître sans incrémenter seq :
    -- en Connexions, relire la liste toutes les ~2 s (40 × 50 ms) suffit et
    -- évite un appel à midi_ports() par image.
    if mode == "connexions" and tour - tour_ports >= 40
      rafraichir_ports!
      tour_ports = tour
      sale = true
    -- Panneau Qualité ouvert : les pourcentages sont publiés sans changer
    -- seq ; on redessine au plus une fois toutes les 2 s. Fermé : rien.
    if mode == "qualite" and tour - tour_qualite >= 40
      tour_qualite = tour
      auth_courant = etat_auth!
      reseaux_courant = etat_reseaux!
      sale = true
    -- canaux_actifs est éphémère et hors seq : c'est la seule comparaison qui
    -- réveille le rendu pour éteindre un canal après 250 ms d'inactivité.
    actifs = e.canaux_actifs or 0
    continue unless sale or e.seq != seq or actifs != seq_actifs
    seq = e.seq
    seq_actifs = actifs

    if mode == "midi" and midi and mc
      -- Relecture de l'état frais quand il a changé (page web, autre client),
      -- sauf pendant un apprentissage — pour ne pas écraser la saisie en
      -- cours — et tant que notre propre envoi n'est pas encore publié par le
      -- fil audio : une relecture retardataire annulerait le clic local.
      -- Au-delà de ~2 s (40 × 50 ms), on accepte l'état frais.
      if not apprentissage and e.seq != seq_midi
        frais, erreur_midi = lire_etat_midi e
        if erreur_midi
          message_midi = erreur_midi
        elseif message_midi == "État MIDI illisible"
          message_midi = nil
        en_attente = not erreur_midi and attente_midi and not memes_reglages(frais, mc) and tour - tour_envoi <= 40
        unless en_attente
          -- Soit notre envoi est publié, soit le délai d'attente est dépassé.
          mc = frais
          seq_midi = e.seq
          attente_midi = false

      -- Capture du prochain contrôle. On compare à dernier_vu (contrôle déjà
      -- reçu à l'armement) ; tout changement de dernier_controle incrémente
      -- seq dans cosmo/lorganum.c, donc la boucle se réveille bien.
      if apprentissage and not meme_controle(e.dernier_controle, dernier_vu)
        der = e.dernier_controle
        dernier_vu = copie_controle der
        if der
          quoi = apprentissage
          if quoi.nouveau and #mc.associations >= MAX_ASSOCIATIONS
            message_midi = "Limite : #{MAX_ASSOCIATIONS} associations"
            apprentissage = nil
          else
            doublon = false
            for j, x in ipairs mc.associations
              if quoi.i != j and x.cc == der.cc and (x.canal == der.canal or not x.canal)
                doublon = true
                break
            if doublon
              message_midi = "CC#{der.cc} déjà associé (c#{der.canal})"
            elseif quoi.nouveau
              a = {canal: der.canal, cc: der.cc, cible: cible_apprentissage}
              a.division = 1 if a.cible == "gain"
              table.insert mc.associations, a
              apprentissage, message_midi = nil, nil
              envoyer_midi mc
            else
              a = mc.associations[quoi.i]
              if a
                a.canal, a.cc = der.canal, der.cc
                a.division or= 1 if a.cible == "gain"
                apprentissage, message_midi = nil, nil
                envoyer_midi mc
      l, h = ui\taille!
      p = disposer_midi e, mc, l, h
      if p.police != police
        ui\police p.police
        police = p.police
      ligne = p.ligne
      if p.trop_petit
        -- Même les lignes de base ne tiennent pas : une ligne suffit, sans
        -- débordement, et le compte des associations n'est pas affiché.
        if ui\debut "", 0, 0, l, h
          ui\ligne ligne, 2
          if ui\bouton "Retour"
            mode = "console"
            apprentissage, message_midi = nil, nil
            seq = nil
          ui\texte "Fenêtre trop petite pour le panneau MIDI"
          ui\fin!
          ui\dessiner 30, 30, 30
        continue
      if ui\debut "", 0, 0, l, h
        -- En-tête sur deux lignes : la première porte les boutons assez
        -- larges pour ne pas tronquer « Connexions », la seconde les
        -- compteurs et le dernier contrôle reçu.
        ui\ligne ligne, 4
        if ui\bouton "Retour"
          mode = "console"
          apprentissage, message_midi = nil, nil
          seq = nil
        if ui\bouton "Connexions"
          mode = "connexions"
          rafraichir_ports!
          tour_ports = tour
          seq = nil
        ui\texte "MIDI #{e.midi or '?'}"
        ui\texte ""
        ui\ligne ligne, 2
        ui\texte "#{#mc.associations} assoc."
        if der = e.dernier_controle
          ui\texte "c#{der.canal} CC#{der.cc}=#{der.valeur}", "droite"
        else
          ui\texte "aucun CC", "droite"

        -- Canaux 1-16 de chaque clavier, puis contrôle et expression. Les
        -- boutons s'allument sur l'activité MIDI (canaux_actifs) sans changer
        -- la sélection : ui\etat sépare les deux notions.
        mc.divisions or= {}
        for d = 1, #e.divisions
          cd = mc.divisions[d]
          unless cd
            cd = {nom: e.divisions[d].nom, canaux: {}}
            mc.divisions[d] = cd
          cd.canaux = {} unless type(cd.canaux) == "table"
          -- Noms abrégés (P, I, II…) : la colonne du nom est étroite.
          afficher_canaux modele.abrege(e.divisions[d].nom), cd.canaux, ligne, actifs
        mc.controle = {} unless type(mc.controle) == "table"
        mc.expression = {} unless type(mc.expression) == "table"
        mc.associations = {} unless type(mc.associations) == "table"
        afficher_canaux "Ctrl", mc.controle, ligne, actifs
        afficher_canaux "Expr", mc.expression, ligne, actifs

        -- Associations CC : cible et division se changent par clic ; chaque
        -- ligne peut réapprendre son CC/canal (attente du prochain contrôle).
        visibles = math.min #mc.associations, p.assoc_max
        suppression = nil
        for i = 1, visibles
          a = mc.associations[i]
          ui\ligne ligne, 5
          canal = a.canal and "c#{modele.canal_texte a.canal}" or modele.canal_texte(nil)
          ui\texte "#{canal} CC#{a.cc}"
          if ui\bouton "Cible #{modele.cible_midi_court[a.cible] or modele.cible_midi[a.cible] or a.cible}"
            a.cible = cible_suivante a.cible
            if a.cible == "gain"
              a.division or= 1
            else
              a.division = nil
            envoyer_midi mc
          if a.cible == "gain"
            if ui\bouton "Clav. #{a.division or 1}"
              a.division = ((a.division or 1) % #e.divisions) + 1
              envoyer_midi mc
          else
            ui\texte ""
          if apprentissage and apprentissage.i == i
            if ui\bouton "Annuler"
              apprentissage, message_midi = nil, nil
          else
            if ui\bouton "Apprendre"
              armer {i: i}, e.dernier_controle
          if ui\bouton "Retirer"
            suppression = i
        if suppression
          table.remove mc.associations, suppression
          apprentissage, message_midi = nil, nil
          envoyer_midi mc
        cachees = #mc.associations - visibles
        if p.compte and cachees > 0
          ui\ligne ligne, 1
          ui\texte "… #{cachees} association(s) non affichée(s) : agrandir la fenêtre"

        -- Apprentissage du prochain contrôle. « Ajouter » arme la création
        -- d'une association (elle n'est créée qu'à l'arrivée d'un contrôle,
        -- jamais un CC 7 figé) ; « Apprendre » sur une ligne la réapprend.
        -- Les deux partagent l'état d'attente, le refus des doublons et le
        -- bouton d'annulation ; il n'y a donc pas deux chemins concurrents.
        ui\ligne ligne, 4
        if apprentissage and apprentissage.nouveau
          if ui\bouton "Annuler"
            apprentissage, message_midi = nil, nil
        else
          if ui\bouton "Ajouter"
            if #mc.associations >= MAX_ASSOCIATIONS
              message_midi = "Limite : #{MAX_ASSOCIATIONS} associations"
            else
              armer {nouveau: true}, e.dernier_controle
        if ui\bouton "Cible #{modele.cible_midi_court[cible_apprentissage] or modele.cible_midi[cible_apprentissage] or cible_apprentissage}"
          cible_apprentissage = cible_suivante cible_apprentissage
        if message_midi
          ui\texte message_midi
        elseif apprentissage
          ui\texte "En attente…"
        else
          ui\texte ""
        if ui\bouton "Tout effacer"
          if #mc.associations > 0
            mc.associations = {}
            apprentissage, message_midi = nil, nil
            envoyer_midi mc
        ui\fin!
        ui\dessiner 30, 30, 30
      continue

    if mode == "connexions" and midi
      l, h = ui\taille!
      p = disposer_connexions #ports, l, h
      if p.police != police
        ui\police p.police
        police = p.police
      ligne = p.ligne
      if p.trop_petit
        -- Même l'en-tête ne tient pas : une seule ligne, avec Retour.
        if ui\debut "", 0, 0, l, h
          ui\ligne ligne, 2
          if ui\bouton "Retour"
            mode = "midi"
            seq = nil
          ui\texte "Fenêtre trop petite pour les connexions"
          ui\fin!
          ui\dessiner 30, 30, 30
        continue
      if ui\debut "", 0, 0, l, h
        -- En-tête : retour, rafraîchissement manuel, titre, nombre de ports.
        ui\ligne ligne, 4
        if ui\bouton "Retour"
          mode = "midi"
          seq = nil
        if ui\bouton "Rafraîchir"
          rafraichir_ports!
          tour_ports = tour
          seq = nil
        ui\texte "Connexions MIDI", "droite"
        ui\texte "#{#ports} port(s)", "droite"
        ui\ligne ligne, 3
        ui\texte "Port"
        ui\texte "État"
        ui\texte "Action", "droite"

        -- Une action seulement pour les sources réelles : ni Organum, ni les
        -- destinations, ni 0:1 (port d'annonces du système, non déconnectable).
        action = nil
        for i = 1, math.min #ports, p.visibles
          port = ports[i]
          etat = modele.etat_port port
          ui\ligne ligne, 3
          ui\texte tronquer(modele.libelle_port(port), p.colonne - 3 * ESPACE)
          ui\texte tronquer((ETATS_PORTS[etat] or etat), p.colonne - 3 * ESPACE)
          peut = port.source and not port.organum and not (port.client == 0 and port.port == 1)
          if peut
            if ui\bouton (port.connecte and "Déconnecter" or "Connecter")
              action = port
          else
            ui\texte "—", "droite"
        -- Hors de la boucle : la liste peut être remplacée par le
        -- rafraîchissement sans perturber l'itération en cours.
        if action
          agir_port action
        cachees = #ports - math.min #ports, p.visibles
        ui\ligne ligne, 1
        if message_ports
          ui\texte message_ports
        elseif p.compte and cachees > 0
          ui\texte "… #{cachees} port(s) non affiché(s) : agrandir la fenêtre"
        else
          ui\texte ""
        ui\fin!
        ui\dessiner 30, 30, 30
      continue

    if mode == "qualite"
      l, h = ui\taille!
      q = etat_qualite e
      -- Cible affichée : celle que publie le serveur, partagée par toutes
      -- les interfaces. Le retour local du clic ne sert que si aucune cible
      -- n'est encore publiée et qu'une demande est en cours.
      cible_temperament = nil
      if type(q.temperament_cible) == "number" and q.temperament_cible >= 0
        cible_temperament = q.temperament_cible
        temperament_cible = nil
      elseif temperament_cible != nil
        if q.application == true
          cible_temperament = temperament_cible
        else
          -- Plus aucune demande en cours : le retour local est périmé.
          temperament_cible = nil
      a_tete = type(q.tete_reverb) == "boolean" and type(q.tete_reverb_prochain) == "boolean"
      a_reverb = type(q.reverb) == "number"
      calib = type(q.calibration) == "table" and q.calibration or nil
      -- Rangées : en-tête, niveau, deux cases, spatialisation, polyphonie,
      -- période, taux, limiteur, tempérament (2 rangées), périphérique,
      -- périphérique, authentification (1 rangée), réseaux (1 rangée), puis
      -- (tête), (calibration) et message. Le nombre de cases de la ligne « Niveau »
      -- vaut 6 quand le mode Auto existe (bouton en plus), 5 sinon.
      rows = 10 + (a_reverb and 1 or 0) + (a_tete and 1 or 0) + (calib and 1 or 0) + 1 + 1 + 1 + 1
      colonnes = (type(q.auto) == "boolean") and 6 or 5
      p = disposer_qualite rows, l, h, colonnes
      if p.police != police
        ui\police p.police
        police = p.police
      ligne = p.ligne
      if p.trop_petit
        -- Même la police plancher ne laisse pas passer toutes les rangées :
        -- une seule ligne d'avertissement, sans débordement.
        if ui\debut "", 0, 0, l, h
          ui\ligne ligne, 2
          if ui\bouton "Retour"
            mode = "console"
            seq = nil
          ui\texte "Fenêtre trop petite pour les réglages audio"
          ui\fin!
          ui\dessiner 30, 30, 30
        continue
      if ui\debut "", 0, 0, l, h
        ui\ligne ligne, 3
        if ui\bouton "Retour"
          mode = "console"
          seq = nil
        ui\texte "Audio", "droite"
        ui\texte (if q.auto == true then "Auto" elseif q.niveau == -1 then "Personnalisé" else "Niveau #{q.niveau}"), "droite"

        -- Niveau : Auto (si disponible) ou une présélection 0 à 3.
        ui\ligne ligne, colonnes
        ui\texte "Niveau", "droite"
        if type(q.auto) == "boolean"
          auto_actif = q.auto == true
          if ui\choix("Auto", auto_actif) != auto_actif
            regler_qualite {auto: true}
        for n = 0, 3
          actif = q.auto != true and q.niveau == n
          if ui\choix(tostring(n), actif) != actif
            regler_qualite {niveau: n}

        -- Bruit d'attaque et instabilité (champs à chaud). Boutons-bascule
        -- plutôt que cases : l'état actif est lisible (accent bleu), alors que
        -- le rendu rawfb des cases est peu contrasté.
        ui\ligne ligne, 2
        actif_bruit = q.bruit_attaque == true
        nouveau = ui\choix "Bruit d'attaque", actif_bruit
        regler_qualite {bruit_attaque: nouveau} if nouveau != actif_bruit
        actif_instabilite = q.instabilite == true
        nouveau = ui\choix "Instabilité", actif_instabilite
        regler_qualite {instabilite: nouveau} if nouveau != actif_instabilite

        -- Spatialisation : coupée, simplifiée, complète.
        ui\ligne ligne, 4
        ui\texte "Spatialisation", "droite"
        for v, nom in ipairs {"Coupée", "Simplifiée", "Complète"}
          actif = q.spatialisation == v - 1
          if ui\choix(nom, actif) != actif
            regler_qualite {spatialisation: v - 1}

        -- Réverbération : réglage du moteur, aussi pilotable par une
        -- association MIDI de cible « reverb » ; relu à chaque image.
        if a_reverb
          ui\ligne ligne, 2
          ui\texte "Réverb.", "droite"
          r = ui\curseur (q.reverb or 0), 0, 1, 0.01
          organum.reverb r if bouge (q.reverb or 0), r

        -- Polyphonie maximale : 0 = illimitée, jusqu'à 512. Colonnes de
        -- largeurs inégales : le libellé complet et un curseur assez long
        -- pour rester manœuvrable même à 720 px de large.
        ui\ligne_ratio ligne, {1.9, 0.25, 2.0, 0.85}
        ui\texte "Polyphonie max.", "droite"
        ui\texte ""
        poly = ui\curseur (q.polyphonie_max or 0), 0, 512, 1
        if bouge (q.polyphonie_max or 0), poly
          regler_qualite {polyphonie_max: math.floor poly + 0.5}
        ui\texte (if (q.polyphonie_max or 0) == 0 then "Illimitée" else "#{q.polyphonie_max} voix"), "droite"

        -- Période : sept valeurs, plus le libellé (8 cases).
        ui\ligne ligne, 8
        etiquette_periode = "Période"
        if q.periode_impose == true
          etiquette_periode = "Période (imposée)"
        elseif q.periode_prochain != q.periode
          etiquette_periode = "Période (en cours)"
        ui\texte tronquer(etiquette_periode, (l - 2 * MARGE) / 8 - ESPACE)
        for valeur in *{128, 256, 512, 768, 1024, 1536, 2048}
          actif = q.periode_prochain == valeur
          change = ui\choix(tostring(valeur), actif) != actif
          if change and q.periode_impose != true
            regler_qualite {periode: valeur}

        -- Taux d'échantillonnage (4 cases).
        ui\ligne ligne, 4
        etiquette_taux = "Taux"
        if q.taux_impose == true
          etiquette_taux = "Taux (imposé)"
        elseif q.taux_prochain != q.taux
          etiquette_taux = "Taux (en cours)"
        ui\texte tronquer(etiquette_taux, (l - 2 * MARGE) / 4 - ESPACE)
        for valeur in *{44100, 48000}
          actif = q.taux_prochain == valeur
          change = ui\choix(tostring(valeur), actif) != actif
          if change and q.taux_impose != true
            regler_qualite {taux: valeur}

        -- Limiteur sur sa propre rangée : libellé explicite et bascule.
        ui\ligne ligne, 2
        if q.limiteur_impose == true
          texte_limiteur = if q.limiteur == true
            "Limiteur (imposé : actif)" else "Limiteur (imposé : coupé)"
          ui\texte tronquer(texte_limiteur, (l - 2 * MARGE) / 2 - ESPACE)
          ui\texte ""
        else
          libelle_limiteur = "Limiteur — évite la saturation sur les gros accords"
          ui\texte tronquer(libelle_limiteur, (l - 2 * MARGE) / 2 - ESPACE), "droite"
          actif_limiteur = q.limiteur_prochain == true
          nouveau = ui\choix "Actif", actif_limiteur
          regler_qualite {limiteur: nouveau} if nouveau != actif_limiteur

        -- Tempérament : 11 valeurs sur deux rangées (libellé + 5 boutons,
        -- puis 6 boutons). Le calcul se fait hors du fil audio ; la cible en
        -- cours porte « … » dans son libellé, la valeur en service reste le
        -- bouton accentué.
        etiquette_temperament = "Tempérament"
        if cible_temperament != nil
          etiquette_temperament = "Application de #{modele.TEMPERAMENTS[cible_temperament + 1]}…"
        ui\ligne ligne, 6
        ui\texte tronquer(etiquette_temperament, (l - 2 * MARGE) / 6 - ESPACE), "droite"
        for i = 1, 5
          actif = q.temperament == i - 1
          en_cours = cible_temperament == i - 1
          libelle = modele.TEMPERAMENTS[i]
          libelle = libelle .. " …" if en_cours
          if en_cours
            -- Cible en cours : état vert éphémère, jamais la sélection
            -- accentuée qui désigne le tempérament réellement en service.
            ui\etat libelle, false, true
          else
            choix = ui\choix libelle, actif
            if choix != actif and choix and q.temperament != i - 1 and cible_temperament != i - 1
              regler_qualite {temperament: i - 1}
        ui\ligne ligne, 6
        for i = 6, 11
          actif = q.temperament == i - 1
          en_cours = cible_temperament == i - 1
          libelle = modele.TEMPERAMENTS[i]
          libelle = libelle .. " …" if en_cours
          if en_cours
            ui\etat libelle, false, true
          else
            choix = ui\choix libelle, actif
            if choix != actif and choix and q.temperament != i - 1 and cible_temperament != i - 1
              regler_qualite {temperament: i - 1}

        -- Périphérique : lecture seule (le module nk n'expose pas de champ
        -- de saisie de texte) ; la page web permet de le modifier.
        ui\ligne ligne, 1
        valeur_periph = if type(q.peripherique_prochain) == "string" and q.peripherique_prochain != ""
          q.peripherique_prochain else "défaut"
        texte_periph = "Périphérique : #{valeur_periph}"
        if q.peripherique_impose == true
          texte_periph = texte_periph .. " (imposé par ORGANUM_PERIPHERIQUE)"
        elseif q.peripherique_prochain != q.peripherique
          actuel = if type(q.peripherique) == "string" and q.peripherique != ""
            q.peripherique else "défaut"
          texte_periph = texte_periph .. " (en cours : #{actuel})"
        ui\texte tronquer(texte_periph, l - 2 * MARGE - ESPACE)

        -- Authentification et réseaux : une ligne d'état en lecture seule
        -- chacun. La configuration se fait depuis la page web ; la fenêtre ne
        -- saisit plus de texte.
        a_auth = auth_courant or etat_auth!
        texte_auth = if type(a_auth.erreur) == "string" and a_auth.erreur != ""
          "Authentification : configuration invalide (#{a_auth.erreur})"
        else if a_auth.active == true
          "Authentification : activée pour « #{a_auth.utilisateur} »"
        else
          "Authentification : désactivée"
        ui\ligne ligne, 1
        ui\texte tronquer(texte_auth, l - 2 * MARGE - ESPACE)

        a_reseaux = reseaux_courant or etat_reseaux!
        texte_reseaux = if type(a_reseaux.erreur) == "string" and a_reseaux.erreur != ""
          "Réseaux autorisés : configuration invalide (#{a_reseaux.erreur})"
        else if a_reseaux.active == true
          "Réseaux autorisés : #{a_reseaux.texte} · source : #{a_reseaux.source or "locale"}"
        else
          "Réseaux autorisés : tous · source : #{a_reseaux.source or "locale"}"
        ui\ligne ligne, 1
        ui\texte tronquer(texte_reseaux, l - 2 * MARGE - ESPACE)

        if a_tete
          ui\ligne ligne, 1
          if q.tete_reverb_impose == true
            -- ORGANUM_REVERB_TETE force la valeur : l'afficher, sans
            -- proposer un réglage que la variable ignorerait.
            texte_tete = if q.tete_reverb == true
              "Tête de réverbération zéro latence : imposée par ORGANUM_REVERB_TETE"
            else
              "Tête de réverbération coupée : imposée par ORGANUM_REVERB_TETE"
            ui\texte tronquer(texte_tete, l - 2 * MARGE - ESPACE)
          else
            actif_tete = q.tete_reverb_prochain == true
            etiquette_tete = "Tête de réverbération zéro latence"
            if q.tete_reverb_prochain != q.tete_reverb
              etiquette_tete = etiquette_tete .. if q.tete_reverb == true then " — en cours : active" else " — en cours : coupée"
            nouveau = ui\choix etiquette_tete, actif_tete
            regler_qualite {tete_reverb: nouveau} if nouveau != actif_tete

        if calib
          ui\ligne ligne, 1
          ui\texte tronquer texte_calibration(calib), l - 2 * MARGE - ESPACE

        ui\ligne ligne, 1
        -- Puce d'adaptation : le niveau est calculé en C ; modele fournit le
        -- libellé et la classe. Nuklear n'expose pas de bouton coloré
        -- arbitraire : le libellé « ! » double toujours la couleur.
        niveau_charge = modele.charge_niveau q.charge_niveau
        info_charge = modele.CHARGE_NIVEAUX[niveau_charge + 1]
        texte_puce = info_charge.libelle
        pointe = q.charge_pointe or 0
        if q.charge_evaluee == true or pointe > 0
          texte_puce = texte_puce .. " — pointe #{pointe} %"
        texte_puce = texte_puce .. " · Xruns récents : #{q.xruns_recents or 0} · total : #{q.xruns or 0}"
        ui\texte tronquer(texte_puce, l - 2 * MARGE - ESPACE)

        ui\ligne ligne, 1
        -- Pendant l'application (état explicite publié par le fil audio), le
        -- message le plus important est « Application… » ; une fois terminée,
        -- un échec éventuel reprend la ligne.
        message_affiche = nil
        if q.application_audio == true
          message_affiche = "Application…"
        message_affiche or= message_qualite
        if not message_affiche and type(q.temperament_erreur) == "string" and q.temperament_erreur != ""
          message_affiche = "Tempérament : #{q.temperament_erreur}"
        if not message_affiche and type(q.audio_erreur) == "string" and q.audio_erreur != ""
          message_affiche = "Reconfiguration audio : #{q.audio_erreur}"
        if not message_affiche and type(q.audio_repli) == "string" and q.audio_repli != ""
          message_affiche = "Repli audio : #{q.audio_repli}"
        ui\texte tronquer(message_affiche or "", l - 2 * MARGE - ESPACE)
        ui\fin!
        ui\dessiner 30, 30, 30
      continue

    l, h = ui\taille!
    -- Rapports largeur/police du plus long nom de jeu, sur une ligne et sur
    -- la plus longue moitié du meilleur découpage en deux lignes. Ils sont
    -- indépendants de la police : les mesurer à la police courante suffit.
    plus_long, plus_long_deux = 0, 0
    for d in *e.divisions
      for j in *d.jeux
        nom = modele.nom_jeu j
        large = ui\largeur_texte nom
        plus_long = math.max plus_long, large
        coupe = decoupe ui, nom
        plus_long_deux = math.max plus_long_deux, (coupe and coupe.large or large)
    -- Police visée : elle croît avec la largeur de la fenêtre, avec un
    -- plancher de 13 px pour les toutes petites fenêtres.
    cible = math.min POLICE_MAX, math.max 13, math.floor l / 64
    p = disposer e, l, h, plus_long / police, plus_long_deux / police, cible
    if p.police != police
      ui\police p.police
      police = p.police

    if ui\debut "", 0, 0, l, h
      -- Réglages généraux (le bouton Qualité s'ajoute toujours, MIDI si fourni).
      -- Avec un volume système, deux curseurs : le système et la pédale (volume
      -- du moteur, distinct) ; sans lui, le curseur unique règle déjà le moteur.
      deux = systeme and vol_sys
      ui\ligne p.entete, (midi and 6 or 5) + (deux and 2 or 0)
      if deux
        ui\texte "Volume #{math.floor(vol_sys * 100 + 0.5)} %", "droite"
        v = ui\curseur vol_sys, 0, 1, 0.01
        vol_sys, a_envoyer = v, v if bouge vol_sys, v
        ui\texte "Pédale #{math.floor(e.volume * 100 + 0.5)} %", "droite"
        vp = ui\curseur e.volume, 0, 1, 0.01
        organum.volume vp if bouge e.volume, vp
      else
        ui\texte "Volume", "droite"
        v = ui\curseur e.volume, 0, 1, 0.01
        organum.volume v if bouge e.volume, v
      ui\texte ""
      organum.panique! if ui\bouton "Panique"
      -- Accès au panneau Qualité : vert seulement pour « Confortable » ;
      -- orange et rouge colorent le bouton, la marque textuelle restant.
      niveau_charge = modele.charge_niveau e.qualite.charge_niveau
      marque_charge = if niveau_charge >= 3 then " !!" elseif niveau_charge >= 2 then " !" else ""
      clique_qualite = if niveau_charge == 1
        ui\etat("Audio", false, true) != false
      else
        ui\bouton "Audio#{marque_charge}", niveau_charge
      if clique_qualite
        mode = "qualite"
        message_qualite = nil
        auth_courant = etat_auth!
        seq = nil
      if midi and ui\bouton "MIDI"
        mode = "midi"
        appel_ok = true
        mc, erreur_midi = lire_etat_midi e
        if erreur_midi
          message_midi = erreur_midi
          appel_ok = false
        seq_midi = e.seq
        apprentissage, attente_midi = nil, false
        message_midi = nil if appel_ok
        seq = nil

      -- Combinaisons : l'étape courante est enfoncée.
      ui\ligne p.entete, math.ceil(e.netapes / p.lignes_combi)
      for n = 1, e.netapes
        actif = e.etape == n - 1
        organum.midi 0xCF, n - 1 if ui\choix(tostring(n), actif) and not actif

      -- Claviers, un par colonne, sur toute la hauteur restante.
      reste = h - 2 * MARGE - (1 + p.lignes_combi) * (p.entete + ESPACE) - ESPACE
      -- Transposition dans la colonne du Manuel III (sans accouplement). La
      -- rangée des accouplements n'existe que si au moins un clavier en a :
      -- elle fournit alors la place libre en bas de sa colonne.
      colonne_transposition = modele.colonne_transposition e.divisions
      a_des_liens = false
      for dd in *e.divisions
        a_des_liens = true if #dd.liens > 0
      ui\ligne reste, #e.divisions
      for d, div in ipairs e.divisions
        if ui\groupe_debut "clavier #{d}"
          ui\ligne p.entete, 1
          ui\texte div.nom, "centre"
          ui\ligne p.entete, 2
          g = ui\curseur div.gain, 0, 1, 0.01
          organum.gain d, g if bouge div.gain, g
          if ui\bouton "Annuler"
            organum.jeu d, j, false for j = 1, #div.jeux
          ui\ligne p.jeu, p.sous
          for j, jeu in ipairs div.jeux
            nom = modele.nom_jeu jeu
            nouveau = if ui\largeur_texte(nom) <= p.case - 4
              ui\choix nom, jeu.actif
            else
              coupe = decoupe ui, nom
              if coupe and coupe.large <= p.case - 2
                ui\choix_deux coupe.a, coupe.b, jeu.actif
              else
                ui\choix nom, jeu.actif
            organum.jeu d, j, not jeu.actif if nouveau != jeu.actif
          -- Lignes vides : les accouplements s'alignent en bas des colonnes.
          vides = p.rangs * p.sous - #div.jeux
          ui\texte "" for _ = 1, vides
          if #div.liens > 0
            ui\ligne p.jeu, #div.liens
            for i, lien in ipairs div.liens
              cible = e.divisions[lien.division]
              etiquette = "#{modele.abrege div.nom}+#{modele.abrege cible and cible.nom or '?'}"
              organum.lien d, i, not lien.actif if ui\choix(etiquette, lien.actif) != lien.actif
          elseif d == colonne_transposition and a_des_liens
            -- Une seule rangée disponible : −, valeur signée, +. La valeur
            -- non nulle accentue les trois cellules (couleur de sélection).
            v = math.tointeger(e.transposition) or 0
            accent = v != 0
            ui\ligne_ratio p.jeu, {2, 1, 1.2, 1}
            largeur_colonne = (l - 2 * MARGE) / #e.divisions - 2 * MARGE_GROUPE - ESPACE
            ui\texte tronquer("Transposition", largeur_colonne * 2 / 5.2 - ESPACE)
            -- Le jeu de police embarqué ne couvre que le latin : le signe
            -- moins U+2212 y manque, on garde l'hyphen ASCII côté natif.
            clique_moins = ui\etat("-", accent, false) != accent
            if clique_moins and v > -12
              organum.transposition v - 1
              v -= 1
              accent = v != 0
            texte_valeur = modele.texte_transposition(v)\gsub "\u{2212}", "-"
            clique_valeur = ui\etat texte_valeur, accent, false
            if clique_valeur != accent and v != 0
              organum.transposition 0
              v = 0
              accent = false
            clique_plus = ui\etat("+", accent, false) != accent
            if clique_plus and v < 12
              organum.transposition v + 1
          ui\groupe_fin!
    ui\fin!
    ui\dessiner 30, 30, 30
  true
