-- Le harnais charge fenetre.lua et modele.lua compilés (par défaut dans
-- /tmp/fenetre) ; FENETRE_PATH peut désigner un autre dossier.
package.path = ((os.getenv "FENETRE_PATH") or "/tmp/fenetre/?.lua") .. ";" .. package.path

lancer = require "fenetre"
modele = require "modele"


-- état factice
etat = {
  seq: 0
  -- Niveau de la puce, pour exercer le bouton Qualité orange (2) ou rouge (3).
  charge_niveau: tonumber(os.getenv "CHARGE_NIVEAU") or 1
  volume: 0.5
  reverb: 0.3
  temperament: 5
  etape: 0
  netapes: 32
  midi: "128:0"
  canaux_controle: 1 << 15
  canaux_expression: 1 << 15
  -- Activité simulée des canaux 3 et 6 (hors seq, comme le moteur).
  canaux_actifs: (1 << 2) | (1 << 5)
  associations: {
    {cc: 1, cible: "volume"}
    {canal: 1, cc: 7, cible: "gain", division: 2}
  }
  dernier_controle: {canal: 1, cc: 7, valeur: 100}
  divisions: {}
  -- Réglages de qualité factices, avec une calibration au démarrage pour
  -- exercer la ligne d'information du panneau.
  qualite: {
    temperament: 5
    bruit_attaque: true
    instabilite: true
    spatialisation: 2
    polyphonie_max: 0
    tete_reverb: true
    niveau: 3
    auto: false
    charge_niveau: tonumber(os.getenv "CHARGE_NIVEAU") or 1
    calibration: {
      niveau: 2
      tete_reverb: true
      echeance_ms: 10.67
      estimation_ms: {4.2, 5.1, 6.3, 8.9}
      voix_ref: 250
      duree_calibration_ms: 35.0
    }
  }
}

noms_claviers = {"Pedal", "Manual I", "Manual II", "Manual III"}
jeux_par_clavier = {12, 13, 14, 15}
for ci = 1, #noms_claviers
  div = {nom: noms_claviers[ci], gain: 0.7, canaux: 1 << (ci - 1), liens: {}, jeux: {}}
  for j = 1, jeux_par_clavier[ci]
    div.jeux[#div.jeux + 1] = {nom: "Double Open Diapason\n#{j}", actif: j % 3 == 0}
  for cj = 1, ci - 1  -- comme l'orgue par défaut : P+I…, I+II…
    div.liens[#div.liens + 1] = {division: cj, actif: cj == 1}
  etat.divisions[#etat.divisions + 1] = div

organum = {}
-- L'activité simulée s'éteint après quelques secondes pour exercer le
-- redessin d'extinction (condition actifs != seq_actifs) ; ACTIVITE_SECONDES
-- règle le délai, une valeur <= 0 la garde indéfiniment.
debut_activite = os.time!
duree_activite = tonumber(os.getenv "ACTIVITE_SECONDES") or 5
organum.etat = ->
  if duree_activite > 0 and etat.canaux_actifs != 0 and os.time! - debut_activite >= duree_activite
    etat.canaux_actifs = 0
    print "activité éteinte"
  etat

bump = ->
  etat.seq = etat.seq + 1
  print "seq=#{etat.seq}"

organum.jeu = (d, j, actif) ->
  etat.divisions[d].jeux[j].actif = actif
  print "jeu d=#{d} j=#{j} actif=#{actif}"
  bump!
organum.lien = (d, l, actif) ->
  etat.divisions[d].liens[l].actif = actif
  print "lien d=#{d} l=#{l} actif=#{actif}"
  bump!
organum.gain = (d, v) ->
  etat.divisions[d].gain = v
  print "gain d=#{d} v=#{v}"
  bump!
organum.volume = (v) ->
  etat.volume = v
  print "volume v=#{v}"
  bump!
organum.reverb = (v) ->
  etat.reverb = v
  print "reverb v=#{v}"
  bump!
organum.panique = ->
  print "panique"
  bump!
organum.temperament = (t) ->
  etat.temperament = t
  etat.qualite.temperament = t
  print "temperament=#{t}"
  bump!
-- Repli sans options.qualite : la fenêtre écrit directement les quatre
-- champs à chaud du moteur.
organum.qualite = (champ, valeur) ->
  etat.qualite[champ] = valeur
  print "qualite #{champ}=#{valeur}"
  bump!
organum.midi = (status, n) ->
  etat.etape = n
  print "midi status=#{status} n=#{n}"
  bump!

-- Panneau MIDI : mêmes commandes que le moteur, sur l'état factice.
organum.canaux_division = (d, masque) ->
  etat.divisions[d].canaux = masque
  print "canaux_division d=#{d} masque=#{masque}"
  bump!
organum.canaux_controle = (masque) ->
  etat.canaux_controle = masque
  print "canaux_controle masque=#{masque}"
  bump!
organum.canaux_expression = (masque) ->
  etat.canaux_expression = masque
  print "canaux_expression masque=#{masque}"
  bump!
organum.associations = (liste) ->
  copie = {}
  for a in *liste
    copie[#copie + 1] = {canal: a.canal, cc: a.cc, cible: a.cible, division: a.division}
  etat.associations = copie
  print "associations n=#{#etat.associations}"
  bump!

-- Ports factices de l'écran Connexions : Organum, port d'annonces 0:1,
-- sources connectées ou non, destinations. Les actions modifient « connecte ».
ports_factices = {
  {client: 128, port: 0, nom_client: "Organum", nom_port: "Entrée", source: false, destination: true, connecte: true, organum: true}
  {client: 0, port: 1, nom_client: "System", nom_port: "Annonces", source: true, destination: false, connecte: true, organum: false}
  {client: 24, port: 0, nom_client: "Clavier USB", nom_port: "MIDI 1", source: true, destination: false, connecte: false, organum: false}
  {client: 24, port: 1, nom_client: "Clavier USB", nom_port: "Contrôle", source: true, destination: false, connecte: true, organum: false}
  {client: 14, port: 0, nom_client: "Synthé", nom_port: "Entrée", source: false, destination: true, connecte: false, organum: false}
}
organum.midi_ports = -> ports_factices
organum.midi_connecter = (client, port) ->
  for p in *ports_factices
    if p.client == client and p.port == port
      p.connecte = true
      print "midi_connecter #{client}:#{port}"
      return true
  error "port inconnu #{client}:#{port}"
organum.midi_deconnecter = (client, port) ->
  error "déconnexion MIDI 0:1 refusée" if client == 0 and port == 1
  for p in *ports_factices
    if p.client == client and p.port == port
      p.connecte = false
      print "midi_deconnecter #{client}:#{port}"
      return true
  error "port inconnu #{client}:#{port}"

canaux_liste = modele.canaux_liste
canaux_masque = modele.canaux_masque

midi = {
  etat: ->
    {
      midi: etat.midi
      divisions: [{nom: d.nom, canaux: canaux_liste d.canaux} for d in *etat.divisions]
      controle: canaux_liste etat.canaux_controle
      expression: canaux_liste etat.canaux_expression
      associations: etat.associations
      dernier_controle: etat.dernier_controle
    }
  appliquer: (cfg) ->
    for i, d in ipairs cfg.divisions
      organum.canaux_division i, canaux_masque d.canaux if type(d) == "table" and type(d.canaux) == "table"
    organum.canaux_controle canaux_masque cfg.controle if type(cfg.controle) == "table"
    organum.canaux_expression canaux_masque cfg.expression if type(cfg.expression) == "table"
    organum.associations cfg.associations if type(cfg.associations) == "table"
    true
  enregistrer: (cfg) ->
    print "enregistrer midi : #{#cfg.associations} association(s)"
}

-- État complet de qualité, comme le fournira init.moon : niveau, mode auto,
-- tête de réverbération et calibration. Les mutations suivent les règles du
-- serveur (une présélection écrit les quatre champs ; un champ seul passe en
-- « personnalisé »).
qualite = {
  etat: -> etat.qualite
  regler: (payload) ->
    redemarrage = false
    if payload.niveau != nil
      p = modele.PRESELECTIONS[payload.niveau + 1]
      if p
        redemarrage = p.tete_reverb != etat.qualite.tete_reverb
        etat.qualite.spatialisation = p.spatialisation
        etat.qualite.bruit_attaque = p.bruit_attaque
        etat.qualite.instabilite = p.instabilite
        etat.qualite.polyphonie_max = p.polyphonie_max
        etat.qualite.tete_reverb = p.tete_reverb
      etat.qualite.niveau = payload.niveau
      etat.qualite.auto = false
    else
      if payload.tete_reverb != nil
        redemarrage = payload.tete_reverb != etat.qualite.tete_reverb
      for k, v in pairs payload
        etat.qualite[k] = v
      if payload.auto != nil
        etat.qualite.auto = payload.auto == true
      else
        etat.qualite.niveau = -1
        etat.qualite.auto = false
    print "qualite regler niveau=#{etat.qualite.niveau} auto=#{etat.qualite.auto} redemarrage=#{redemarrage}"
    bump!
    {ok: true, redemarrage_requis: redemarrage}
}

largeur = tonumber(os.getenv "LARGEUR") or 800
hauteur = tonumber(os.getenv "HAUTEUR") or 600

-- Volume système factice : exerce les deux curseurs (système et pédale).
-- SANS_VOLUME_SYS=1 reproduit le cas sans volume système (curseur unique).
volume_sys = tonumber(os.getenv "VOLUME_SYS") or 70
systeme = {
  lire: -> volume_sys
  regler: (v) ->
    volume_sys = v
    print "volume_systeme v=#{v}"
    bump!
}
options = {titre: "essai organum", largeur: largeur, hauteur: hauteur, :midi, :qualite}
options.volume = systeme unless os.getenv("SANS_VOLUME_SYS") == "1"

ok, err = lancer organum, nk, options
print err if err
print "fin"
