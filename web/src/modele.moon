-- Modèle de présentation partagé par l'interface web et l'interface native.
-- Ce module ne produit que des données et des chaînes : il ne dépend ni du
-- DOM, ni de Nuklear, ni du module « organum ». Les deux renderers y lisent
-- les mêmes libellés et la même logique d'état ; chacun garde sa mise en page.
--
--   modele = require "modele"
--   modele.abrege "Manual II"        --> "II"
--   modele.etat_puce true, false     --> "orange"
--   modele.libelle_association a, divisions

-- Abréviation d'un clavier pour les accouplements : « Manual III » → III,
-- « Pedal » → P ; sinon le nom tel quel.
abrege = (nom) ->
  nom = tostring nom
  nom\match("^[Mm]anual%s+(%S+)$") or (nom\match("^[Pp]ed") and "P") or nom

-- Nom de jeu sur une seule ligne : les noms d'Aeolus contiennent parfois des
-- retours à la ligne.
nom_jeu = (jeu) ->
  nom = jeu and jeu.nom
  return "" if nom == nil
  nom = (tostring nom)\gsub "\n", " "
  nom

-- Canaux MIDI : le moteur stocke un masque de 16 bits, l'interface présente
-- une liste de canaux 1-16. Init.moon consomme ces fonctions : une seule
-- source de vérité pour les deux interfaces.
canaux_liste = (masque) ->
  masque = tonumber(masque) or 0
  [c for c = 1, 16 when (masque >> (c - 1)) & 1 == 1]

canaux_masque = (liste) ->
  m = 0
  for c in *liste
    -- Les nombres entiers peuvent arriver en flottant (JSON, calculs) :
    -- math.tointeger les accepte, tout en refusant les non-entiers.
    c = math.tointeger c
    m |= 1 << (c - 1) if c and c >= 1 and c <= 16
  m

-- Le JSON de redbean encode une table vide en objet `{}`. Marquer la table
-- avec `[0] = false` la fait encoder en tableau `[]` (voir
-- luaencodejsondata.c) ; la marque est ignorée par le sérialiseur quand la
-- liste a des éléments. À utiliser pour tout champ qui doit rester un
-- tableau JSON, même vide.
liste_json = (liste) ->
  liste = liste or {}
  liste[0] = false
  liste

-- États de la puce de connexion. « classe » est la classe CSS utilisée par
-- la page web ; les deux libellés sont le texte lu par les lecteurs d'écran
-- (sr-only) et l'infobulle.
ETATS =
  vert:
    classe: "etat-vert"
    libelle: "Connecté et synchronisé"
    title: "Connecté et synchronisé"
  orange:
    classe: "etat-orange"
    libelle: "Connecté, non synchronisé"
    title: "Connecté, non synchronisé"
  rouge:
    classe: "etat-rouge"
    libelle: "Déconnecté"
    title: "Déconnecté"

-- Clé d'état de la puce : le réseau est la condition indispensable, la
-- synchronisation Aeolus distingue ensuite vert et orange.
etat_puce = (connecte, synchronise) ->
  return "rouge" unless connecte
  synchronise and "vert" or "orange"

-- Libellés courts des cibles d'une association MIDI.
cible_midi =
  volume: "Volume"
  reverb: "Réverbération"
  gain: "Gain"
  aucune: "Aucune"

-- Variante courte pour les colonnes étroites de l'interface native
-- (Nuklear) : « Réverbération » n'y tient pas.
cible_midi_court =
  volume: "Vol."
  reverb: "Rév."
  gain: "Gain"
  aucune: "Aucune"

-- Texte d'un canal : « Tous » quand il est absent, sinon son numéro. Le
-- préfixe « Canal » est ajouté par les libellés composés.
canal_texte = (c) ->
  return "Tous" if c == nil
  tostring c

-- Libellé d'une association : « Canal 3 · CC 7 → Volume » ou
-- « Tous · CC 64 → Gain (Manual II) ». Les champs absents sont tolérés.
libelle_association = (a, divisions) ->
  a = a or {}
  canal = if a.canal == nil then canal_texte(nil) else "Canal #{canal_texte a.canal}"
  cible = cible_midi[a.cible] or cible_midi.aucune
  if a.cible == "gain" and a.division != nil
    div = divisions and divisions[a.division]
    nom = div and (div.nom or div.name)
    cible = "#{cible} (#{nom})" if nom and nom != ""
  cc = a.cc == nil and "?" or tostring a.cc
  "#{canal} · CC #{cc} → #{cible}"

-- Libellé court d'un port du séquenceur : « 24:0 — Clavier USB ». Le nom du
-- client suffit ; à défaut on prend celui du port ou l'adresse.
libelle_port = (p) ->
  p = p or {}
  adresse = if p.client != nil and p.port != nil
    "#{p.client}:#{p.port}"
  elseif p.adresse != nil
    tostring p.adresse
  nom = p.nom_client
  nom = p.nom_port if nom == nil or nom == ""
  if adresse and nom and nom != ""
    "#{adresse} — #{nom}"
  elseif adresse
    adresse
  elseif nom and nom != ""
    tostring nom
  else
    "?"

-- État synthétique d'un port : le nôtre d'abord, puis une source connectée,
-- puis une destination possible, sinon un port disponible.
etat_port = (p) ->
  p = p or {}
  return "organum" if p.organum
  return "connecte" if p.connecte
  return "destination" if p.destination
  "disponible"

{
  :abrege
  :nom_jeu
  :canaux_liste
  :canaux_masque
  :liste_json
  :ETATS
  :etat_puce
  :cible_midi
  :cible_midi_court
  :canal_texte
  :libelle_association
  :libelle_port
  :etat_port
}
