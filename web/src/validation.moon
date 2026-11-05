-- Fonctions pures de validation et de fusion des réglages, extraites de
-- init.moon pour être éprouvées sans redbean ni moteur. Aucune n'écrit ni
-- n'appelle le module « organum » : elles se contentent de accepter, refuser
-- ou normaliser une valeur.

TAUX_VALIDES = {[44100]: true, [48000]: true}
PERIODES_VALIDES = {[128]: true, [256]: true, [512]: true, [1024]: true, [2048]: true}
DEMARRAGE_DEFAUT = {periode: 512, taux: 48000, peripherique: "", limiteur: true}

entier_borne = (v, min, max) ->
  type(v) == "number" and v == math.floor(v) and v >= min and v <= max

-- Un périphérique audio est un nom ALSA : au plus 200 octets, sans caractère
-- de contrôle (une chaîne vide désigne le périphérique par défaut).
peripherique_valide = (s) ->
  return false unless type(s) == "string" and #s <= 200
  for i = 1, #s
    b = s\byte i
    return false if b < 32 or b == 127
  true

is_finite_number = (v) ->
  type(v) == "number" and v == v and v != math.huge and v != -math.huge

is_integer = (v) ->
  is_finite_number(v) and v == math.floor(v)

-- Tempérament lu dans etat.json : entier 0..maximum, sinon la valeur par
-- défaut (absent, invalide, flottant ou chaîne sont ignorés).
temperament_depuis_etat = (v, defaut, maximum) ->
  return defaut unless entier_borne v, 0, maximum
  math.tointeger v

-- Réglages de qualité enregistrés : chaque champ valide du fichier est gardé,
-- chaque champ absent ou invalide retombe sur la valeur locale (défauts).
qualite_defauts = (defauts) ->
  {
    niveau: defauts.niveau, auto: defauts.auto,
    tete_reverb: defauts.tete_reverb,
    periode: defauts.periode, taux: defauts.taux,
    peripherique: defauts.peripherique, limiteur: defauts.limiteur
  }

qualite_fichier_normalisee = (q, defauts) ->
  return qualite_defauts(defauts) unless type(q) == "table"
  niveau = q.niveau
  niveau = defauts.niveau unless type(niveau) == "number"
  auto = q.auto
  auto = defauts.auto unless type(auto) == "boolean"
  tete = q.tete_reverb
  tete = defauts.tete_reverb unless type(tete) == "boolean"
  periode = q.periode
  periode = defauts.periode unless PERIODES_VALIDES[periode] == true
  taux = q.taux
  taux = defauts.taux unless TAUX_VALIDES[taux] == true
  peripherique = q.peripherique
  peripherique = defauts.peripherique unless peripherique_valide peripherique
  limiteur = q.limiteur
  limiteur = defauts.limiteur unless type(limiteur) == "boolean"
  {niveau: niveau, auto: auto, tete_reverb: tete,
   periode: periode, taux: taux, :peripherique, :limiteur}

-- Valeurs effectives et variables d'environnement prioritaires. Renvoie
-- effectif, impose et les messages d'avertissement (valeurs invalides).
impositions = (env, defaut) ->
  effectif = {taux: defaut.taux, periode: defaut.periode,
              peripherique: defaut.peripherique, limiteur: defaut.limiteur}
  impose = {taux: false, periode: false, peripherique: false, limiteur: false}
  erreurs = {}
  v = env.ORGANUM_TAUX
  if v and v != ""
    n = math.tointeger tonumber v
    if n and TAUX_VALIDES[n] == true
      effectif.taux = n
      impose.taux = true
    else
      erreurs[#erreurs + 1] = "ORGANUM_TAUX invalide (#{v}), ignoré"
  v = env.ORGANUM_PERIODE
  if v and v != ""
    n = math.tointeger tonumber v
    if n and PERIODES_VALIDES[n] == true
      effectif.periode = n
      impose.periode = true
    else
      erreurs[#erreurs + 1] = "ORGANUM_PERIODE invalide (#{v}), ignoré"
  v = env.ORGANUM_PERIPHERIQUE
  if v != nil
    if peripherique_valide v
      effectif.peripherique = v
      impose.peripherique = true
    else
      erreurs[#erreurs + 1] = "ORGANUM_PERIPHERIQUE invalide, ignoré"
  v = env.ORGANUM_LIMITEUR
  if v and v != ""
    effectif.limiteur = v != "non"
    impose.limiteur = true
  {effectif: effectif, impose: impose, erreurs: erreurs}

-- Champs acceptés par POST /api/orgue (une seule action par requête).
ACTIONS_ORGUE = {
  stop: true, cancel: true, step: true, reverb: true, panic: true,
  gain: true, link: true, qualite: true, volume: true, temperament: true
}

division_valide = (d, divisions) ->
  is_integer(d) and d >= 0 and d < #divisions

-- Valide une requête POST /api/orgue et renvoie le nom de l'action, ou nil
-- et le message d'erreur. Ne vérifie que la forme et les bornes.
valider_orgue = (data, divisions, nb_etapes, max_temperament) ->
  n = 0
  for k in pairs data
    return nil, "champ inconnu : #{k}" unless ACTIONS_ORGUE[k]
    n += 1
  return nil, "une seule action attendue" unless n == 1

  if st = data.stop
    unless type(st) == "table" and division_valide(st.division, divisions) and
           is_integer(st.index) and type(st.on) == "boolean"
      return nil, "stop invalide"
    unless st.index >= 0 and st.index < #divisions[st.division + 1].jeux
      return nil, "jeu hors limites"
    "stop"
  elseif l = data.link
    unless type(l) == "table" and division_valide(l.division, divisions) and
           is_integer(l.index) and type(l.on) == "boolean"
      return nil, "link invalide"
    unless l.index >= 0 and l.index < #divisions[l.division + 1].liens
      return nil, "accouplement hors limites"
    "link"
  elseif data.cancel != nil
    unless division_valide data.cancel, divisions
      return nil, "division hors limites"
    "cancel"
  elseif data.step != nil
    unless is_integer(data.step) and data.step >= 0 and data.step < nb_etapes
      return nil, "step hors limites"
    "step"
  elseif data.reverb != nil
    unless is_integer(data.reverb) and data.reverb >= 0 and data.reverb <= 127
      return nil, "reverb hors limites"
    "reverb"
  elseif g = data.gain
    unless type(g) == "table" and division_valide(g.division, divisions) and
           is_finite_number(g.value) and g.value >= 0 and g.value <= 1
      return nil, "gain invalide"
    "gain"
  elseif data.qualite != nil
    "qualite"
  elseif data.temperament != nil
    unless is_integer(data.temperament) and data.temperament >= 0 and
           data.temperament <= max_temperament
      return nil, "tempérament doit être un entier entre 0 et #{max_temperament}"
    "temperament"
  elseif data.volume != nil
    unless is_finite_number(data.volume) and data.volume >= 0 and data.volume <= 1
      return nil, "volume hors limites"
    "volume"
  elseif data.panic == true
    "panic"
  else
    nil, "panic doit être true"

-- Valide POST /api/orgue {"qualite": {...}} ; renvoie true ou nil, erreur.
valider_qualite = (q) ->
  return nil, "qualite doit être un objet" unless type(q) == "table"
  connus = {
    bruit_attaque: true, instabilite: true, spatialisation: true,
    polyphonie_max: true, tete_reverb: true, niveau: true, auto: true,
    periode: true, taux: true, peripherique: true, limiteur: true
  }
  nq = 0
  for k in pairs q
    return nil, "qualite : champ inconnu : #{k}" unless connus[k]
    nq += 1
  return nil, "qualite : aucun champ" unless nq > 0
  if q.bruit_attaque != nil and type(q.bruit_attaque) != "boolean"
    return nil, "qualite.bruit_attaque doit être un booléen"
  if q.instabilite != nil and type(q.instabilite) != "boolean"
    return nil, "qualite.instabilite doit être un booléen"
  if q.spatialisation != nil and not entier_borne q.spatialisation, 0, 2
    return nil, "qualite.spatialisation doit être un entier entre 0 et 2"
  if q.polyphonie_max != nil and not entier_borne q.polyphonie_max, 0, 512
    return nil, "qualite.polyphonie_max doit être un entier entre 0 et 512"
  if q.tete_reverb != nil and type(q.tete_reverb) != "boolean"
    return nil, "qualite.tete_reverb doit être un booléen"
  if q.niveau != nil and not entier_borne q.niveau, 0, 3
    return nil, "qualite.niveau doit être un entier entre 0 et 3"
  if q.auto != nil and type(q.auto) != "boolean"
    return nil, "qualite.auto doit être un booléen"
  if q.periode != nil and not (type(q.periode) == "number" and PERIODES_VALIDES[q.periode] == true)
    return nil, "qualite.periode doit valoir 128, 256, 512, 1024 ou 2048"
  if q.taux != nil and not (type(q.taux) == "number" and TAUX_VALIDES[q.taux] == true)
    return nil, "qualite.taux doit valoir 44100 ou 48000"
  if q.peripherique != nil and not peripherique_valide q.peripherique
    return nil, "qualite.peripherique doit être une chaîne de 200 octets au plus, sans caractère de contrôle"
  if q.limiteur != nil and type(q.limiteur) != "boolean"
    return nil, "qualite.limiteur doit être un booléen"
  true

-- Valide POST /api/midi/connexion {client, port, connecte}.
valider_connexion_midi = (data) ->
  unless is_integer(data.client) and data.client >= 0 and data.client <= 255 and
         is_integer(data.port) and data.port >= 0 and data.port <= 255
    return nil, "client et port doivent être des entiers entre 0 et 255"
  unless type(data.connecte) == "boolean"
    return nil, "connecte doit être un booléen"
  true

{
  :TAUX_VALIDES, :PERIODES_VALIDES, :DEMARRAGE_DEFAUT, :ACTIONS_ORGUE
  :entier_borne, :peripherique_valide, :is_finite_number, :is_integer
  :temperament_depuis_etat
  :qualite_defauts, :qualite_fichier_normalisee, :impositions
  :division_valide, :valider_orgue, :valider_qualite
  :valider_connexion_midi
}
