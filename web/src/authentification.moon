-- Authentification HTTP Digest SHA-256 (RFC 7616), réduite à ce dont
-- organum a besoin : algorithme SHA-256, qop=auth, royaume fixe.
--
-- Module pur : il n'écrit ni ne lit aucun fichier, et ne connaît ni le
-- moteur ni redbean au-delà de GetCryptoHash, fourni par redbean. Les
-- processus de requête l'utilisent après le fork ; le secret du nonce est
-- tiré au démarrage par init.moon avant le fork.

M = {}

ROYAUME = "organum"
UTILISATEUR_DEFAUT = "organiste"
DUREE_NONCE = 300

M.ROYAUME = ROYAUME
M.UTILISATEUR_DEFAUT = UTILISATEUR_DEFAUT
M.DUREE_NONCE = DUREE_NONCE

-- Octets binaires → hexadécimal minuscule.
hexa = (bin) ->
  converti = bin\gsub ".", (c) ->
    string.format "%02x", c\byte!
  converti

M.hexa = hexa

sha256_hexa = (texte) ->
  hexa GetCryptoHash "SHA256", texte

M.sha256_hexa = sha256_hexa

-- HA1 = SHA-256(utilisateur:royaume:mot de passe), la seule forme du mot de
-- passe conservée sur disque.
M.ha1 = (utilisateur, royaume, mot_de_passe) ->
  sha256_hexa "#{utilisateur}:#{royaume}:#{mot_de_passe}"

M.hmac_hexa = (secret, message) ->
  hexa GetCryptoHash "SHA256", message, secret

-- Nonce sans état : horodatage (secondes UNIX) et HMAC-SHA256 du secret sur
-- cet horodatage. Aucune table n'est tenue côté serveur.
M.creer_nonce = (secret, horodatage) ->
  "#{horodatage}-#{M.hmac_hexa secret, tostring horodatage}"

-- Analyse un nonce, sans vérifier son authenticité : renvoie l'horodatage et
-- la partie HMAC, ou nil si la forme est invalide.
M.analyser_nonce = (nonce) ->
  return nil unless type(nonce) == "string"
  horodatage, mac = nonce\match "^(%d+)%-(%x+)$"
  return nil unless horodatage and mac and #mac == 64
  tonumber(horodatage), mac

-- Comparaison à temps constant, adaptée aux chaînes de même longueur.
M.egal_temps_constant = (a, b) ->
  return false unless type(a) == "string" and type(b) == "string" and #a == #b
  difference = 0
  for i = 1, #a
    difference += math.abs a\byte(i) - b\byte(i)
  difference == 0

-- « valide », « perime » ou « invalide ». Un nonce périmé est authentique :
-- le client peut rejouer sans redemander le mot de passe (stale=true).
M.valider_nonce = (secret, nonce, maintenant, duree = DUREE_NONCE) ->
  horodatage, mac = M.analyser_nonce nonce
  return "invalide" unless horodatage
  attendu = M.hmac_hexa secret, tostring horodatage
  return "invalide" unless M.egal_temps_constant mac, attendu
  age = maintenant - horodatage
  return "perime" if age < 0 or age > duree
  "valide"

-- Analyse l'en-tête Authorization. Renvoie une table de champs en minuscules
-- (les noms sont insensibles à la casse) ou nil si ce n'est pas du Digest.
M.analyser_entete = (valeur) ->
  return nil unless type(valeur) == "string"
  reste = valeur\match "^%s*[Dd][Ii][Gg][Ee][Ss][Tt]%s+(.*)$"
  return nil unless reste
  champs = {}
  i = 1
  n = #reste
  while i <= n
    -- Virgules et espaces de séparation.
    while i <= n and (reste\sub(i, i) == "," or reste\sub(i, i)\match "%s")
      i += 1
    break if i > n
    nom = reste\match "^([%w%-_]+)%s*=", i
    break unless nom
    i += #nom
    while i <= n and reste\sub(i, i)\match "%s"
      i += 1
    if reste\sub(i, i) ~= "="
      break
    i += 1
    while i <= n and reste\sub(i, i)\match "%s"
      i += 1
    valeur_champ = nil
    if reste\sub(i, i) == '"'
      i += 1
      morceaux = {}
      while i <= n
        c = reste\sub i, i
        if c == '"'
          i += 1
          break
        elseif c == "\\" and i < n
          i += 1
          morceaux[#morceaux + 1] = reste\sub i, i
          i += 1
        else
          morceaux[#morceaux + 1] = c
          i += 1
      valeur_champ = table.concat morceaux
    else
      valeur_champ = reste\match "^([^,%s]*)", i
      i += #valeur_champ
    break unless valeur_champ
    champs[nom\lower!] = valeur_champ
  champs

-- Réponse attendue par le client, en hexadécimal :
-- SHA-256(HA1:nonce:nc:cnonce:qop:HA2), HA2 = SHA-256(méthode:uri).
M.calculer_reponse = (p) ->
  ha2 = sha256_hexa "#{p.methode}:#{p.uri}"
  sha256_hexa "#{p.ha1}:#{p.nonce}:#{p.nc}:#{p.cnonce}:#{p.qop}:#{ha2}"

-- Vérifie une requête. p contient entete, methode, uri, ha1, utilisateur,
-- secret, maintenant (et, pour les tests, duree du nonce). Renvoie vrai si
-- acceptée ; sinon nil, stale, raison.
M.verifier = (p) ->
  duree = p.duree or DUREE_NONCE
  champs = M.analyser_entete p.entete
  return nil, false, "en-tête absent" unless champs
  return nil, false, "utilisateur absent" unless champs.username
  return nil, false, "utilisateur différent" unless M.egal_temps_constant champs.username, p.utilisateur
  return nil, false, "royaume différent" unless champs.realm == ROYAUME
  algorithme = champs.algorithm or "MD5"
  return nil, false, "algorithme non pris en charge" unless algorithme\upper! == "SHA-256"
  return nil, false, "qop absent ou différent" unless champs.qop == "auth"
  return nil, false, "uri différente" unless champs.uri == p.uri
  return nil, false, "nc absent" unless champs.nc and #champs.nc > 0
  return nil, false, "cnonce absent" unless champs.cnonce and #champs.cnonce > 0
  etat_nonce = M.valider_nonce p.secret, champs.nonce, p.maintenant, duree
  return nil, false, "nonce invalide" unless etat_nonce == "valide" or etat_nonce == "perime"
  attendue = M.calculer_reponse {
    ha1: p.ha1, nonce: champs.nonce, nc: champs.nc,
    cnonce: champs.cnonce, qop: champs.qop,
    methode: p.methode, uri: champs.uri
  }
  return nil, false, "réponse différente" unless M.egal_temps_constant champs.response or "", attendue
  return nil, true, "nonce périmé" if etat_nonce == "perime"
  return true, false, nil

-- En-tête de défi. stale=true demande au client de rejouer avec un nouveau
-- nonce sans redemander le mot de passe.
M.entete_defi = (secret, maintenant, stale = false) ->
  nonce = M.creer_nonce secret, maintenant
  texte = 'Digest realm="' .. ROYAUME .. '", qop="auth", algorithm=SHA-256, nonce="' .. nonce .. '"'
  texte = texte .. ", stale=true" if stale
  texte

M
