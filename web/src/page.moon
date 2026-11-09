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

division_html = (di, div, divisions, transposition = 0, colonne_transposition = nil) ->
  d = tostring di
  liens = for i, l in ipairs div.links or {}
    cible = divisions[l.division + 1]
    continue unless cible
    h.button class: "link", ["data-division"]: d, ["data-index"]: tostring(i - 1), ["data-state"]: (l.on and "on" or "off"), type: "button", title: "Accoupler #{escape cible.name} à #{escape div.name}", "#{modele.abrege div.name}+#{modele.abrege cible.name}"
  btns = for i, jeu in ipairs div.stops
    h.button class: "stop", ["data-division"]: d, ["data-index"]: tostring(i - 1), ["data-state"]: etat_jeu(jeu), type: "button", display jeu.name
  gain = math.floor((tonumber(div.gain) or 0.5) * 100 + 0.5)
  commande_transposition = ""
  if di + 1 == colonne_transposition and #liens == 0
    commande_transposition = transposition_html transposition
  h.section class: "division",
    h.div class: "division-tete",
      h.h2 class: "division-nom", display div.name,
      h.input type: "range", class: "gain", ["data-division"]: d, min: "0", max: "100", step: "1", value: tostring(gain), ["aria-label"]: "Volume #{escape div.name}",
    h.div class: "stops-grid", table.unpack btns,
    #liens > 0 and h.div(class: "links", table.unpack liens) or "",
    commande_transposition,
    h.button class: "btn small cancel-division", ["data-division"]: d, type: "button", "Tout annuler"

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
  page = h.html lang: "fr",
    h.head {},
      h.meta charset: "utf-8",
      h.meta name: "viewport", content: "width=device-width, initial-scale=1",
      h.title "Orgue",
      h.style style,
    h.body {},
      h.main {},
        h.section class: "tab-panel", id: "panel-orgue",
          h.div class: "barre",
            h.div class: "volume-general",
              h.label class: "volume-etiquette", ["for"]: "volume", "Volume",
              h.input type: "range", id: "volume", min: "0", max: "100", step: "1", value: "50", ["aria-valuetext"]: "50\u{00A0}%",
              h.span class: "value", id: "value", ["aria-hidden"]: "true", "50\u{00A0}%",
              h.span class: "status #{modele.ETATS.rouge.classe}", id: "status", role: "status", ["aria-live"]: "polite", ["aria-atomic"]: "true", title: escape(modele.ETATS.rouge.title), ["data-libelle-vert"]: escape(modele.ETATS.vert.libelle), ["data-libelle-orange"]: escape(modele.ETATS.orange.libelle), ["data-libelle-rouge"]: escape(modele.ETATS.rouge.libelle), ["data-title-vert"]: escape(modele.ETATS.vert.title), ["data-title-orange"]: escape(modele.ETATS.orange.title), ["data-title-rouge"]: escape(modele.ETATS.rouge.title),
                h.span class: "sr-only", escape(modele.ETATS.rouge.libelle),
              h.noscript h.span class: "etat-fallback", "Hors ligne",
            h.div class: "volume-general pedale-general",
              h.label class: "volume-etiquette", ["for"]: "volume-pedale", "Pédale",
              h.input type: "range", id: "volume-pedale", min: "0", max: "100", step: "1", value: "50", ["aria-valuetext"]: "50\u{00A0}%",
              h.span class: "value", id: "value-pedale", ["aria-hidden"]: "true", "50\u{00A0}%",
            h.button type: "button", class: "btn mute", id: "mute", ["aria-pressed"]: "false", ["aria-label"]: "Couper le son", "Muet",
            h.div class: "combo", ["aria-label"]: "Combinaison",
              h.button type: "button", class: "btn small", id: "combo-prev", ["aria-label"]: "Combinaison précédente", "◀",
              h.input type: "number", id: "combo-num", min: "1", max: tostring(steps), value: "1", ["aria-label"]: "Numéro de combinaison",
              h.button type: "button", class: "btn small", id: "combo-next", ["aria-label"]: "Combinaison suivante", "▶",
            h.div class: "combo-btns", ["aria-label"]: "Combinaisons",
              table.unpack [h.button(type: "button", class: "combo-btn", ["data-step"]: tostring(n - 1), tostring n) for n = 1, steps],
            h.button type: "button", class: "btn panic", id: "panic", "Panique",
            h.a class: "btn small", href: "/midi", "MIDI",
            h.a class: "btn small lien-qualite charge-gris", href: "/audio", id: "lien-qualite", ["aria-label"]: "Audio — #{escape modele.CHARGE_NIVEAUX[1].libelle}", ["data-charge-classe-0"]: modele.CHARGE_NIVEAUX[1].classe, ["data-charge-classe-1"]: modele.CHARGE_NIVEAUX[2].classe, ["data-charge-classe-2"]: modele.CHARGE_NIVEAUX[3].classe, ["data-charge-classe-3"]: modele.CHARGE_NIVEAUX[4].classe, ["data-charge-libelle-0"]: escape(modele.CHARGE_NIVEAUX[1].libelle), ["data-charge-libelle-1"]: escape(modele.CHARGE_NIVEAUX[2].libelle), ["data-charge-libelle-2"]: escape(modele.CHARGE_NIVEAUX[3].libelle), ["data-charge-libelle-3"]: escape(modele.CHARGE_NIVEAUX[4].libelle), "Audio",
          bandeau_degrade,
          h.p class: "note", "L'affichage reflète l'état mémorisé par le serveur ; il peut différer si les jeux sont tirés ailleurs.",
          h.div class: "divisions", table.unpack [division_html(di - 1, div, divisions, transposition, colonne_transposition) for di, div in ipairs divisions],
          h.p class: "note", h.a(href: "https://github.com/jperon/organum", "Code source (AGPL-3.0)"),
        clavier_html divisions,
      h.script client

  "<!DOCTYPE html>\n" .. page