package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local a = require "authentification"

-- SHA-256 de référence (vecteur FIPS 180-4 également cité par la RFC 7616).
aide.egal(a.sha256_hexa("abc"),
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  "SHA-256 : vecteur abc")

-- HMAC-SHA-256, vecteur de la RFC 4231 (cas 1).
aide.egal(a.hmac_hexa("key", "The quick brown fox jumps over the lazy dog"),
  "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
  "HMAC-SHA-256 : vecteur RFC 4231")

-- Vecteur de test de la RFC 7616 §3.9.1 (utilisateur Mufasa, mot de passe
-- « Circle of Life », royaume http-auth@example.org). Le royaume d'organum
-- est fixe, mais le calcul de HA1 et de la réponse est le même.
local ha1 = a.ha1("Mufasa", "http-auth@example.org", "Circle of Life")
aide.egal(ha1, "7987c64c30e25f1b74be53f966b49b90f2808aa92faf9a00262392d7b4794232",
  "RFC 7616 : HA1 SHA-256")

local entete_rfc = 'Digest username="Mufasa", realm="http-auth@example.org", ' ..
  'uri="/dir/index.html", algorithm=SHA-256, ' ..
  'nonce="7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v", nc=00000001, ' ..
  'cnonce="f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ", qop=auth, ' ..
  'response="753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1", ' ..
  'opaque="FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS"'
local champs = a.analyser_entete(entete_rfc)
aide.verifie(champs ~= nil, "en-tête Digest : analysé")
aide.egal(champs and champs.username, "Mufasa", "en-tête Digest : username")
aide.egal(champs and champs.nonce, "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v",
  "en-tête Digest : nonce")
aide.egal(champs and champs.nc, "00000001", "en-tête Digest : nc")
aide.egal(champs and champs.qop, "auth", "en-tête Digest : qop")
aide.egal(champs and champs.algorithm, "SHA-256", "en-tête Digest : algorithm")

local reponse = a.calculer_reponse {
  ha1 = ha1,
  nonce = "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v",
  nc = "00000001",
  cnonce = "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ",
  qop = "auth",
  methode = "GET",
  uri = "/dir/index.html",
}
aide.egal(reponse, "753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1",
  "RFC 7616 : réponse SHA-256")

-- En-tête refusé proprement.
aide.egal(a.analyser_entete("Basic dXNlcjpwYXNz"), nil, "en-tête Basic : refusé")
aide.egal(a.analyser_entete(nil), nil, "en-tête nil : refusé")
aide.egal(a.analyser_entete('Digest username="a", realm="b"').username, "a",
  "en-tête : champs partiels")
aide.egal(a.analyser_entete('Digest username="a\\"b"').username, 'a"b',
  "en-tête : guillemet échappé")

-- Nonce : création, analyse et péremption.
local secret = "secret-de-test"
local maintenant = 1000000
local nonce = a.creer_nonce(secret, maintenant)
aide.egal(a.valider_nonce(secret, nonce, maintenant), "valide", "nonce : valide")
aide.egal(a.valider_nonce(secret, nonce, maintenant + a.DUREE_NONCE), "valide",
  "nonce : valide à la limite")
aide.egal(a.valider_nonce(secret, nonce, maintenant + a.DUREE_NONCE + 1), "perime",
  "nonce : périmé au-delà de 5 min")
aide.egal(a.valider_nonce(secret, nonce, maintenant - 1), "perime",
  "nonce : horodatage futur refusé")
aide.egal(a.valider_nonce("autre-secret", nonce, maintenant), "invalide",
  "nonce : HMAC d'un autre secret")
aide.egal(a.valider_nonce(secret, "abc", maintenant), "invalide",
  "nonce : forme invalide")

-- Comparaison à temps constant (mêmes longueurs, contenus différents).
aide.verifie(a.egal_temps_constant("abc", "abc"), "comparaison : égal")
aide.verifie(not a.egal_temps_constant("abc", "abd"), "comparaison : différent")
aide.verifie(not a.egal_temps_constant("abc", "abcd"), "comparaison : longueurs")

-- Défi.
local defi = a.entete_defi(secret, maintenant)
aide.verifie(defi:find('realm="organum"', 1, true) ~= nil, "défi : royaume organum")
aide.verifie(defi:find("algorithm=SHA-256", 1, true) ~= nil, "défi : algorithme SHA-256")
aide.verifie(defi:find('qop="auth"', 1, true) ~= nil, "défi : qop auth")
aide.verifie(defi:find("stale=true", 1, true) == nil, "défi : stale absent")
local defi_stale = a.entete_defi(secret, maintenant, true)
aide.verifie(defi_stale:find("stale=true", 1, true) ~= nil, "défi : stale présent")

-- Vérification complète d'une requête construite comme le client.
local utilisateur = "organiste"
local ha1_org = a.ha1(utilisateur, "organum", "motdepasse")
local nonce_org = a.creer_nonce(secret, maintenant)
local cnonce = "0123456789abcdef"
local uri = "/api/orgue/attendre?instance=1-2&seq=3"
local rep_org = a.calculer_reponse {
  ha1 = ha1_org, nonce = nonce_org, nc = "00000001", cnonce = cnonce,
  qop = "auth", methode = "GET", uri = uri,
}
local entete_org = 'Digest username="' .. utilisateur .. '", realm="organum", ' ..
  'uri="' .. uri .. '", algorithm=SHA-256, nonce="' .. nonce_org .. '", ' ..
  'nc=00000001, cnonce="' .. cnonce .. '", qop=auth, response="' .. rep_org .. '"'
local ok, stale, raison = a.verifier {
  entete = entete_org, methode = "GET", uri = uri,
  ha1 = ha1_org, utilisateur = utilisateur, secret = secret,
  maintenant = maintenant,
}
aide.verifie(ok == true and stale == false, "vérification : requête acceptée", raison)

local ok2, stale2, raison2 = a.verifier {
  entete = entete_org, methode = "GET", uri = uri,
  ha1 = ha1_org, utilisateur = utilisateur, secret = secret,
  maintenant = maintenant + a.DUREE_NONCE + 1,
}
aide.verifie(ok2 == nil and stale2 == true and raison2 == "nonce périmé",
  "vérification : nonce périmé signalé stale", raison2)

local ok3, stale3 = a.verifier {
  entete = (entete_org:gsub('response="[^"]*"', 'response="' .. string.rep("0", 64) .. '"')),
  methode = "GET", uri = uri, ha1 = ha1_org, utilisateur = utilisateur,
  secret = secret, maintenant = maintenant,
}
aide.verifie(ok3 == nil and stale3 == false, "vérification : mauvaise réponse refusée")

local ok4 = a.verifier {
  entete = (entete_org:gsub('username="[^"]*"', 'username="intrus"')),
  methode = "GET", uri = uri, ha1 = ha1_org, utilisateur = utilisateur,
  secret = secret, maintenant = maintenant,
}
aide.verifie(ok4 == nil, "vérification : autre utilisateur refusé")

local ok5 = a.verifier {
  entete = entete_org, methode = "POST", uri = uri,
  ha1 = ha1_org, utilisateur = utilisateur, secret = secret,
  maintenant = maintenant,
}
aide.verifie(ok5 == nil, "vérification : méthode différente refusée")

-- Majuscules de l'algorithme admises (RFC 7616 : insensible à la casse).
local entete_min = (entete_org:gsub("algorithm=SHA-256", "algorithm=sha-256"))
local ok6 = a.verifier {
  entete = entete_min, methode = "GET", uri = uri,
  ha1 = ha1_org, utilisateur = utilisateur, secret = secret,
  maintenant = maintenant,
}
aide.verifie(ok6 == true, "vérification : algorithme en minuscules accepté")

-- Fichier Digest éditable : une entrée utilisateur:organum:HA1.
local ha1_fichier = a.ha1("organiste", "organum", "motdepasse")
local entree = a.analyser_fichier("organiste:organum:" .. ha1_fichier .. "\n")
aide.verifie(entree ~= nil and entree ~= false, "fichier Digest : entrée acceptée")
aide.egal(entree and entree.utilisateur, "organiste", "fichier Digest : utilisateur")
aide.egal(entree and entree.ha1, ha1_fichier, "fichier Digest : HA1")
aide.egal(a.formater_fichier("organiste", ha1_fichier),
  "organiste:organum:" .. ha1_fichier .. "\n", "fichier Digest : forme écrite")
local aid = a.analyser_fichier("  # commentaire\n\norganiste:organum:" .. string.upper(ha1_fichier) .. "\r\n")
aide.verifie(aid ~= nil and aid ~= false, "fichier Digest : commentaires et lignes vides")
aide.egal(aid and aid.ha1, ha1_fichier, "fichier Digest : HA1 ramené en minuscules")
aide.egal(a.analyser_fichier("# commentaire\n\n"), false, "fichier Digest : sans entrée")
aide.egal(a.analyser_fichier("organiste:organum:abc"), nil, "fichier Digest : HA1 trop court refusé")
aide.egal(a.analyser_fichier("organiste:organum:" .. string.rep("z", 64)), nil,
  "fichier Digest : HA1 non hexadécimal refusé")
aide.egal(a.analyser_fichier("organiste:autre:" .. ha1_fichier), nil,
  "fichier Digest : royaume différent refusé")
aide.egal(a.analyser_fichier("organiste organum " .. ha1_fichier), nil,
  "fichier Digest : ligne mal formée refusée")
aide.egal(a.analyser_fichier("a:organum:" .. ha1_fichier .. "\nb:organum:" .. ha1_fichier), nil,
  "fichier Digest : plusieurs entrées refusées")
aide.egal(a.analyser_fichier("or:ganiste:organum:" .. ha1_fichier), nil,
  "fichier Digest : deux-points dans l'utilisateur refusés")

aide.termine()
