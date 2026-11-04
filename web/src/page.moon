-- Page HTML générée via html.moon.
-- Le module renvoie une fonction (divisions, steps) -> html : les divisions et
-- leurs jeux viennent de l'état publié par Aeolus ({name, stops: {{name, on}}}),
-- ou de la table de repli d'orgue.moon quand le plugin est injoignable.
h = require "html"
style = require "style"
client = require "client"
modele = require "modele"

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

division_html = (di, div, divisions) ->
  d = tostring di
  liens = for i, l in ipairs div.links or {}
    cible = divisions[l.division + 1]
    continue unless cible
    h.button class: "link", ["data-division"]: d, ["data-index"]: tostring(i - 1), ["data-state"]: (l.on and "on" or "off"), type: "button", title: "Accoupler #{escape cible.name} à #{escape div.name}", "#{modele.abrege div.name}+#{modele.abrege cible.name}"
  btns = for i, jeu in ipairs div.stops
    h.button class: "stop", ["data-division"]: d, ["data-index"]: tostring(i - 1), ["data-state"]: etat_jeu(jeu), type: "button", display jeu.name
  gain = math.floor((tonumber(div.gain) or 0.5) * 100 + 0.5)
  h.section class: "division",
    h.div class: "division-tete",
      h.h2 class: "division-nom", display div.name,
      h.input type: "range", class: "gain", ["data-division"]: d, min: "0", max: "100", step: "1", value: tostring(gain), ["aria-label"]: "Volume #{escape div.name}",
    h.div class: "stops-grid", table.unpack btns,
    #liens > 0 and h.div(class: "links", table.unpack liens) or "",
    h.button class: "btn small cancel-division", ["data-division"]: d, type: "button", "Tout annuler"

-- Section « Qualité » : les valeurs initiales reproduisent les réglages par
-- défaut ; client.moon les remplace dès la première lecture de /api/orgue.
-- Tous les contrôles sont nommés par leur identifiant `qualite-…`.
option_qualite = (valeur, nom, choisi) ->
  attrs = {value: valeur}
  attrs.selected = true if choisi
  attrs.disabled = true if valeur == "-1"
  h.option attrs, nom

niveaux_qualite = {"auto", "0", "1", "2", "3", "-1"}
noms_niveaux = {auto: "Auto", "0": "0", "1": "1", "2": "2", "3": "3", "-1": "Personnalisé"}

qualite_html = ->
  h.section class: "qualite", id: "qualite", ["aria-labelledby"]: "qualite-titre",
    h.h2 class: "qualite-titre", id: "qualite-titre", "Qualité",
    h.p class: "note qualite-indisponible", id: "qualite-indisponible", hidden: true,
      "Réglages de qualité indisponibles sur ce serveur.",
    h.div class: "qualite-corps",
      h.label class: "qualite-champ",
        h.span "Niveau",
        h.select id: "qualite-niveau", ["aria-label"]: "Niveau de qualité",
          table.unpack [option_qualite v, noms_niveaux[v], v == "3" for v in *niveaux_qualite],
      h.div class: "qualite-cases",
        h.label class: "qualite-case",
          h.input type: "checkbox", id: "qualite-bruit", checked: true,
          h.span "Bruit d'attaque",
        h.label class: "qualite-case",
          h.input type: "checkbox", id: "qualite-instabilite", checked: true,
          h.span "Instabilité",
      h.label class: "qualite-champ",
        h.span "Spatialisation",
        h.select id: "qualite-spatialisation", ["aria-label"]: "Spatialisation",
          h.option value: "0", "Coupée",
          h.option value: "1", "Simplifiée",
          h.option value: "2", selected: true, "Complète",
      h.label class: "qualite-champ qualite-polyphonie",
        h.span "Polyphonie maximale",
        h.input type: "range", id: "qualite-polyphonie", min: "0", max: "512", step: "1", value: "0", ["aria-label"]: "Polyphonie maximale",
        h.output id: "qualite-polyphonie-valeur", ["for"]: "qualite-polyphonie", "Illimitée",
      h.label class: "qualite-case qualite-tete",
        h.input type: "checkbox", id: "qualite-tete", checked: true,
        h.span {}, "Tête de réverbération zéro latence ", h.em {}, "(au prochain démarrage)",
    h.p class: "note", id: "qualite-tete-impose", hidden: true,
      "Valeur imposée par ORGANUM_REVERB_TETE : non modifiable ici.",
    h.p class: "note qualite-calibration", id: "qualite-calibration", hidden: true,
    h.p class: "note qualite-message", id: "qualite-message", role: "status", ["aria-live"]: "polite", hidden: true

(divisions, steps = 32) ->
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
            h.button type: "button", class: "btn mute", id: "mute", ["aria-pressed"]: "false", ["aria-label"]: "Couper le son", "Muet",
            h.div class: "combo", ["aria-label"]: "Combinaison",
              h.button type: "button", class: "btn small", id: "combo-prev", ["aria-label"]: "Combinaison précédente", "◀",
              h.input type: "number", id: "combo-num", min: "1", max: tostring(steps), value: "1", ["aria-label"]: "Numéro de combinaison",
              h.button type: "button", class: "btn small", id: "combo-next", ["aria-label"]: "Combinaison suivante", "▶",
            h.div class: "combo-btns", ["aria-label"]: "Combinaisons",
              table.unpack [h.button(type: "button", class: "combo-btn", ["data-step"]: tostring(n - 1), tostring n) for n = 1, steps],
            h.label class: "reverb", "Réverb.",
              h.input type: "range", id: "reverb", min: "0", max: "127", step: "1", value: "64",
            h.button type: "button", class: "btn panic", id: "panic", "Panique",
            h.a class: "btn small", href: "/midi", "MIDI",
          h.p class: "note", "L'affichage reflète l'état mémorisé par le serveur ; il peut différer si les jeux sont tirés ailleurs.",
          h.div class: "divisions", table.unpack [division_html di - 1, div, divisions for di, div in ipairs divisions],
          qualite_html!,
          h.p class: "note", h.a(href: "https://github.com/jperon/organum", "Code source (AGPL-3.0)"),
      h.script client

  "<!DOCTYPE html>\n" .. page