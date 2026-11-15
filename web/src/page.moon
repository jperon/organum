-- Page HTML générée via html.moon.
-- Le module renvoie une fonction (divisions, steps) -> html : les divisions et
-- leurs jeux viennent de l'état publié par Aeolus ({name, stops: {{name, on}}}),
-- ou de la table de repli d'orgue.moon quand le plugin est injoignable.
h = require "html"
style = require "style"
client = require "client"
modele = require "modele"
clavier = require "clavier"

escape = (s) ->
  s = tostring s
  s = s\gsub "&", "&amp;"
  s = s\gsub "<", "&lt;"
  s = s\gsub ">", "&gt;"
  s = s\gsub '"', "&quot;"
  s

display = (s) ->
  t = escape s
  t = t\gsub "\n", "<br>"
  t

-- État d'un jeu : « on » / « off » si connu (état d'Aeolus), sinon « unknown ».
etat_jeu = (jeu) ->
  return "unknown" if jeu.on == nil
  jeu.on and "on" or "off"

-- Abréviation d'un clavier pour les accouplements : voir modele.abrege.

-- Commande de transposition : −, valeur signée, +. La valeur 0 s'affiche
-- « 0 » ; une valeur non nulle met le bloc en évidence (classes CSS) et les
-- bornes désactivent le bouton correspondant.
transposition_html = (valeur) ->
  v = tonumber(valeur) or 0
  v = math.max -12, math.min 12, math.floor v
  texte = modele.texte_transposition v
  classes = if v != 0 then "transposition active" else "transposition"
  attrs_moins = {type: "button", class: "btn small transposition-moins", ["aria-label"]: "Transposition −1 demi-ton", "−"}
  attrs_plus = {type: "button", class: "btn small transposition-plus", ["aria-label"]: "Transposition +1 demi-ton", "+"}
  attrs_moins.disabled = true if v <= -12
  attrs_plus.disabled = true if v >= 12
  -- Un clic sur la valeur remet la transposition à 0 : le bouton garde la
  -- classe transposition-valeur (les tests lisent son textContent) et
  -- aria-live, avec un libellé qui annonce la remise à 0.
  libelle_valeur = "Transposition #{texte} : remettre à 0"
  attrs_valeur =
    type: "button"
    class: "btn small transposition-valeur"
    ["aria-live"]: "polite"
    ["aria-label"]: libelle_valeur
    title: libelle_valeur
  h.div class: classes, id: "transposition", ["data-transposition"]: tostring(v),
    h.span class: "transposition-libelle", "Transposition",
    h.button attrs_moins,
    h.button attrs_valeur, texte,
    h.button attrs_plus

-- Bouton « Piano » d'un clavier : même style et même comportement qu'un
-- accouplement (bascule, état enfoncé = actif), placé en dernier sur la
-- rangée basse. Il n'apparaît que si le piano échantillonné est disponible.
piano_html = (d, actif) ->
  etat = if actif then "on" else "off"
  h.button class: "piano-bouton", ["data-division"]: d, ["data-state"]: etat, ["aria-pressed"]: (actif and "true" or "false"), type: "button", title: "Faire jouer ce clavier sur le piano échantillonné", "Piano"

division_html = (di, div, divisions, transposition = 0, colonne_transposition = nil, piano_disponible = false) ->
  d = tostring di
  liens = for i, l in ipairs div.links or {}
    cible = divisions[l.division + 1]
    continue unless cible
    h.button class: "link", ["data-division"]: d, ["data-index"]: tostring(i - 1), ["data-state"]: (l.on and "on" or "off"), type: "button", title: "Accoupler #{escape cible.name} à #{escape div.name}", "#{modele.abrege div.name}+#{modele.abrege cible.name}"
  btns = for i, jeu in ipairs div.stops
    h.button class: "stop", ["data-division"]: d, ["data-index"]: tostring(i - 1), ["data-state"]: etat_jeu(jeu), type: "button", display jeu.name
  gain = math.floor((tonumber(div.gain) or 0.5) * 100 + 0.5)
  -- Rangée basse du clavier : transposition (Manuel III, qui n'a pas
  -- d'accouplement), accouplements, puis le bouton Piano en dernier. Un
  -- clavier sans accouplement garde donc la transposition et reçoit le piano
  -- sur la même rangée.
  bas = {}
  if di + 1 == colonne_transposition and #liens == 0
    table.insert bas, transposition_html transposition
  for b in *liens
    table.insert bas, b
  if piano_disponible
    table.insert bas, piano_html d, div.piano == true
  -- Curseur de gain vertical, à droite des jeux et de leur hauteur ; il a
  -- quitté la rangée d'en-tête, qui garde le nom et « Annuler ». La valeur en
  -- % est sous le curseur, le libellé au-dessus.
  tete_html = h.div class: "division-tete",
    h.h2(class: "division-nom", display div.name),
    h.button(class: "btn small cancel-division", ["data-division"]: d, type: "button", "Tout annuler")
  gain_html = h.div class: "gain-colonne",
    h.span(class: "gain-libelle", "Gain"),
    h.input(type: "range", class: "gain", ["data-division"]: d, min: "0", max: "100", step: "1", value: tostring(gain), ["aria-label"]: "Volume #{escape div.name}", style: "--fill: #{gain}%"),
    h.span(class: "gain-valeur", ["aria-hidden"]: "true", "#{gain}\u{00A0}%")
  corps_html = h.div class: "division-corps",
    h.div(class: "stops-grid", table.unpack btns),
    gain_html
  bas_html = if #bas > 0 then h.div(class: "links", table.unpack bas) else ""
  h.section class: "division", tete_html, corps_html, bas_html

-- Panneau repliable « Clavier », replié par défaut : <details> natif, sans
-- JavaScript pour le repli. Une option par division réellement publiée par
-- /api/orgue ; sa valeur est le premier canal MIDI que la division écoute.
-- Un jeu de deux octaves (do 4 à si 5) est rendu en touches blanches et
-- noires ; le script client gère l'appui, le glissando et le relâchement.
clavier_html = (divisions) ->
  options = {}
  for i, div in ipairs(divisions or {})
    nom = escape div.name
    canal = clavier.canal_division div
    attrs = {["data-division"]: tostring(i - 1)}
    if canal
      attrs.value = tostring canal
      options[#options + 1] = h.option attrs, nom
    else
      attrs.value = ""
      attrs.disabled = true
      options[#options + 1] = h.option attrs, "#{nom} (aucun canal)"

  octaves = for groupe in *clavier.octaves(60, 2)
    touches = {}
    for t in *groupe.blanches
      touches[#touches + 1] = h.button type: "button", class: "touche touche-blanche", ["data-note"]: tostring(t.note), ["aria-label"]: escape(t.libelle), ["aria-pressed"]: "false", t.nom
    for t in *groupe.noires
      touches[#touches + 1] = h.button type: "button", class: "touche touche-noire noire-position-#{t.position}", ["data-note"]: tostring(t.note), ["aria-label"]: escape(t.libelle), ["aria-pressed"]: "false", ""
    h.div class: "octave", table.unpack(touches)

  avertissement_attrs = {class: "note clavier-avertissement", id: "clavier-avertissement"}
  avertissement_attrs.hidden = true unless clavier.aucun_jeu_actif divisions
  avertissement = h.p avertissement_attrs, "Aucun jeu n'est allumé : allumez au moins un jeu pour entendre le clavier."

  barre = h.div class: "clavier-barre",
    h.label class: "clavier-etiquette", ["for"]: "clavier-canal", "Jouer sur",
    h.select id: "clavier-canal", ["aria-label"]: "Clavier MIDI de destination", table.unpack options,
    h.span class: "note clavier-aide", "Souris ou doigt ; relâchez pour arrêter la note."
  corps = h.div class: "clavier-corps",
    barre,
    avertissement,
    h.div class: "clavier-octaves", role: "group", ["aria-label"]: "Clavier, deux octaves", table.unpack octaves
  h.details class: "clavier-panneau", id: "clavier-panneau",
    h.summary class: "clavier-summary", "Clavier",
    corps

(divisions, steps = 32, transposition = 0, infos = {}) ->
  colonne_transposition = modele.colonne_transposition divisions
  -- Bandeau d'état : chaque axe (audio, MIDI) a son propre message, calculé
  -- par une règle pure et publié par le serveur. Un axe qui fonctionne se
  -- tait ; l'absence de l'assistant audio ou MIDI n'est pas une faute.
  messages = {}
  if infos
    if infos.audio_message and infos.audio_message != ""
      table.insert messages, infos.audio_message
    if infos.midi_message and infos.midi_message != ""
      table.insert messages, infos.midi_message
  bandeau_degrade = if #messages > 0
    h.p class: "note degrade", id: "mode-degrade", table.concat messages, " "
  else
    ""
  -- Console : bandeau vertical des curseurs généraux à gauche, claviers et
  -- barre de réglages à droite. Le bandeau est une liste : « Volume »
  -- (système), « Pédale » (volume du moteur) et, si le piano échantillonné est
  -- chargé, « Piano » — la disposition suit sans refonte.
  curseur_gen = (c) ->
    h.div class: c.classe,
      h.label(class: "volume-etiquette", ["for"]: c.ident, c.etiquette),
      h.input(type: "range", id: c.ident, min: "0", max: "100", step: "1", value: tostring(c.valeur), ["aria-valuetext"]: "#{c.valeur}\u{00A0}%", style: "--fill: #{c.valeur}%"),
      h.span(class: "value", id: c.valeur_id, ["aria-hidden"]: "true", "#{c.valeur}\u{00A0}%")
  -- Pourcentage entier 0..100 d'une valeur publiée en 0..1 ; 50 par défaut
  -- tant que le serveur n'a rien publié.
  pourcent = (v) ->
    n = tonumber v
    return 50 unless n
    math.max 0, math.min 100, math.floor n * 100 + 0.5
  curseurs_generaux = {
    {ident: "volume", etiquette: "Volume", classe: "curseur-general", valeur_id: "value", valeur: 50}
    {ident: "volume-pedale", etiquette: "Pédale", classe: "curseur-general pedale-general", valeur_id: "value-pedale", valeur: pourcent infos and infos.volume}
  }
  if infos and infos.piano_disponible
    table.insert curseurs_generaux, {
      ident: "piano-volume", etiquette: "Piano", classe: "curseur-general piano-general"
      valeur_id: "value-piano", valeur: pourcent infos.piano_volume
    }
  etat_html = h.span class: "status #{modele.ETATS.rouge.classe}", id: "status", role: "status", ["aria-live"]: "polite", ["aria-atomic"]: "true", title: escape(modele.ETATS.rouge.title), ["data-libelle-vert"]: escape(modele.ETATS.vert.libelle), ["data-libelle-orange"]: escape(modele.ETATS.orange.libelle), ["data-libelle-rouge"]: escape(modele.ETATS.rouge.libelle), ["data-title-vert"]: escape(modele.ETATS.vert.title), ["data-title-orange"]: escape(modele.ETATS.orange.title), ["data-title-rouge"]: escape(modele.ETATS.rouge.title),
    h.span class: "sr-only", escape(modele.ETATS.rouge.libelle)
  combo_html = h.div class: "combo", ["aria-label"]: "Combinaison",
    h.button(type: "button", class: "btn small", id: "combo-prev", ["aria-label"]: "Combinaison précédente", "◀"),
    h.input(type: "number", id: "combo-num", min: "1", max: tostring(steps), value: "1", ["aria-label"]: "Numéro de combinaison"),
    h.button(type: "button", class: "btn small", id: "combo-next", ["aria-label"]: "Combinaison suivante", "▶")
  combos_html = h.div class: "combo-btns", ["aria-label"]: "Combinaisons",
    table.unpack [h.button(type: "button", class: "combo-btn", ["data-step"]: tostring(n - 1), tostring n) for n = 1, steps]
  lien_qualite = h.a class: "btn small lien-qualite charge-gris", href: "/audio", id: "lien-qualite", ["aria-label"]: "Audio — #{escape modele.CHARGE_NIVEAUX[1].libelle}", ["data-charge-classe-0"]: modele.CHARGE_NIVEAUX[1].classe, ["data-charge-classe-1"]: modele.CHARGE_NIVEAUX[2].classe, ["data-charge-classe-2"]: modele.CHARGE_NIVEAUX[3].classe, ["data-charge-classe-3"]: modele.CHARGE_NIVEAUX[4].classe, ["data-charge-libelle-0"]: escape(modele.CHARGE_NIVEAUX[1].libelle), ["data-charge-libelle-1"]: escape(modele.CHARGE_NIVEAUX[2].libelle), ["data-charge-libelle-2"]: escape(modele.CHARGE_NIVEAUX[3].libelle), ["data-charge-libelle-3"]: escape(modele.CHARGE_NIVEAUX[4].libelle), "Audio"
  barre_html = h.div class: "barre", etat_html, h.noscript(h.span(class: "etat-fallback", "Hors ligne")),
    h.button(type: "button", class: "btn mute", id: "mute", ["aria-pressed"]: "false", ["aria-label"]: "Couper le son", "Muet"),
    combo_html,
    combos_html,
    h.button(type: "button", class: "btn panic", id: "panic", "Panique"),
    h.a(class: "btn small", href: "/midi", "MIDI"),
    lien_qualite
  bandeau_html = h.div class: "bandeau", role: "group", ["aria-label"]: "Réglages généraux",
    table.unpack [curseur_gen c for c in *curseurs_generaux]
  piano_disponible = infos and infos.piano_disponible == true
  divisions_html = h.div class: "divisions",
    table.unpack [division_html(di - 1, div, divisions, transposition, colonne_transposition, piano_disponible) for di, div in ipairs divisions]
  principal_html = h.div class: "console-principal", barre_html, bandeau_degrade,
    h.p(class: "note", "L'affichage reflète l'état mémorisé par le serveur ; il peut différer si les jeux sont tirés ailleurs."),
    divisions_html,
    h.p(class: "note", h.a(href: "https://github.com/jperon/organum", "Code source (AGPL-3.0)"))
  console_html = h.div class: "console", bandeau_html, principal_html
  page = h.html lang: "fr",
    h.head {},
      h.meta charset: "utf-8",
      h.meta name: "viewport", content: "width=device-width, initial-scale=1",
      h.title "Orgue",
      h.style style,
    h.body {},
      h.main {},
        h.section(class: "tab-panel", id: "panel-orgue", console_html),
        clavier_html(divisions),
      h.script client

  "<!DOCTYPE html>\n" .. page