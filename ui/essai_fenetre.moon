package.path = (os.getenv "FENETRE_PATH" or "/tmp/fenetre/?.lua") .. ";" .. package.path

lancer = require "fenetre"


-- etat factice
etat = {
  seq: 0
  volume: 0.5
  reverb: 0.3
  etape: 0
  netapes: 32
  divisions: {}
}

noms_claviers = {"Pedal", "Manual I", "Manual II", "Manual III"}
jeux_par_clavier = {12, 13, 14, 15}
for ci = 1, #noms_claviers
  div = {nom: noms_claviers[ci], gain: 0.7, liens: {}, jeux: {}}
  for j = 1, jeux_par_clavier[ci]
    div.jeux[#div.jeux + 1] = {nom: "Double Open Diapason\n#{j}", actif: j % 3 == 0}
  for cj = 1, ci - 1  -- comme l'orgue par défaut : P+I…, I+II…
    div.liens[#div.liens + 1] = {division: cj, actif: cj == 1}
  etat.divisions[#etat.divisions + 1] = div

organum = {}
organum.etat = -> etat

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
organum._panique_ancienne = ->
  print "panique"
  for d in *etat.divisions
    for j in *d.jeux
      j.actif = false
  bump!
organum.midi = (status, n) ->
  etat.etape = n
  print "midi status=#{status} n=#{n}"
  bump!

largeur = tonumber(os.getenv "LARGEUR") or 800
hauteur = tonumber(os.getenv "HAUTEUR") or 600

ok, err = lancer organum, nk, {titre: "essai organum", largeur: largeur, hauteur: hauteur}
print err if err
print "fin"
