-- Contrôle d'accès par sous-réseau source, facultatif et indépendant de
-- l'authentification HTTP Digest. Module pur : il n'écrit ni ne lit aucun
-- fichier et ne connaît ni redbean ni le moteur, ce qui permet de l'éprouver
-- avec redbean -i. L'appelant lui passe la valeur brute de GetClientAddr
-- (entier pour IPv4, chaîne binaire de 16 octets pour IPv6 ; voir
-- externe/cosmopolitan/tool/net/help.txt, GetClientAddr).
--
-- Une liste vide n'autorise rien de spécial : c'est l'appelant qui décide
-- qu'elle ne filtre pas. Les adresses strictement locales (127.0.0.1 et
-- ::1) sont reconnues par source_locale et toujours exemptées par
-- l'appelant.
--
-- Analyse stricte : une adresse seule vaut /32 (IPv4) ou /128 (IPv6) ;
-- les masques hors bornes, les adresses malformées et les bits d'hôte non
-- nuls sont refusés (choix explicite : une erreur de saisie ne doit pas
-- élargir silencieusement un sous-réseau). Une adresse IPv4 embarquée dans
-- une forme ::ffff:a.b.c.d est traitée comme IPv4 ; la zone d'une adresse
-- lien-local (fe80::1%wlo1) n'entre jamais dans la comparaison, et GetClientAddr
-- ne la renvoie pas.

M = {}

-- Découpe une adresse IPv4 stricte en quatre octets, sinon nil.
analyser_ipv4 = (texte) ->
  return nil unless type(texte) == "string" and texte\match "^%d+%.%d+%.%d+%.%d+$"
  octets = {}
  for morceau in texte\gmatch "[^.]+"
    return nil unless #morceau >= 1 and #morceau <= 3
    return nil if #morceau > 1 and morceau\sub(1, 1) == "0"
    n = tonumber morceau
    return nil unless n != nil and n <= 255
    octets[#octets + 1] = n
  return nil unless #octets == 4
  octets

-- Groupes hexadécimaux d'une moitié d'adresse IPv6 (celle qui ne contient
-- pas « :: »). Renvoie nil si un groupe est vide ou trop long.
groupes_hexa = (partie) ->
  return {} if partie == ""
  return nil if partie\match("^:") or partie\match(":$")
  return nil if partie\match "::"
  groupes = {}
  for groupe in partie\gmatch "[^:]+"
    return nil unless #groupe >= 1 and #groupe <= 4 and groupe\match "^%x+$"
    groupes[#groupes + 1] = tonumber groupe, 16
  -- Un « :: » absent : le nombre de deux-points doit correspondre.
  nombre = select 2, partie\gsub ":", ""
  return nil unless #groupes == nombre + 1
  groupes

-- Analyse une adresse IPv6 stricte (formes compressées et casse admises).
-- Renvoie une adresse de famille 4 pour ::ffff:a.b.c.d, sinon de famille 6.
analyser_ipv6 = (texte) ->
  return nil unless type(texte) == "string" and #texte > 0
  return nil if texte\find "%", 1, true
  -- Partie IPv4 embarquée (::ffff:1.2.3.4 ou x:x:x:x:x:x:1.2.3.4) : deux
  -- groupes hexadécimaux remplacent le dernier pointé.
  tete, queue = texte\match "^(.*:)(%d+%.%d+%.%d+%.%d+)$"
  if queue
    octets4 = analyser_ipv4 queue
    return nil unless octets4
    premier = (octets4[1] << 8) | octets4[2]
    second = (octets4[3] << 8) | octets4[4]
    texte = tete .. string.format("%x:%x", premier, second)
  groupes = nil
  i = texte\find "::", 1, true
  if i
    return nil if texte\find "::", i + 2, true
    gauche = groupes_hexa texte\sub 1, i - 1
    droite = groupes_hexa texte\sub i + 2
    return nil unless gauche and droite
    return nil if #gauche + #droite > 7
    milieux = {}
    for _ = 1, 8 - #gauche - #droite
      milieux[#milieux + 1] = 0
    groupes = {}
    for g in *gauche
      groupes[#groupes + 1] = g
    for g in *milieux
      groupes[#groupes + 1] = g
    for g in *droite
      groupes[#groupes + 1] = g
  else
    groupes = groupes_hexa texte
    return nil unless groupes and #groupes == 8
  octets = {}
  for g in *groupes
    octets[#octets + 1] = (g >> 8) & 0xff
    octets[#octets + 1] = g & 0xff
  -- ::ffff:a.b.c.d : adresse IPv4 mappée, traitée comme IPv4.
  mappee = true
  for k = 1, 10
    mappee = false if octets[k] != 0
  mappee = false unless mappee and octets[11] == 0xff and octets[12] == 0xff
  if mappee
    return {famille: 4, octets: {octets[13], octets[14], octets[15], octets[16]}}
  {famille: 6, :octets}

-- Réseau {famille, octets, prefixe} ; formatage canonique.
formater_ipv4 = (octets) ->
  table.concat octets, "."

formater_ipv6 = (octets) ->
  groupes = {}
  for i = 1, 16, 2
    groupes[#groupes + 1] = string.format "%x", (octets[i] << 8) | octets[i + 1]
  -- RFC 5952 : plus longue suite de zéros (au moins deux groupes), la
  -- première en cas d'égalité.
  debut, longueur = nil, 0
  i = 1
  while i <= 8
    if groupes[i] == "0"
      j = i
      while j <= 8 and groupes[j] == "0"
        j += 1
      if j - i > longueur
        debut, longueur = i, j - i
      i = j
    else
      i += 1
  return table.concat groupes, ":" unless debut and longueur >= 2
  gauche = {}
  for k = 1, debut - 1
    gauche[#gauche + 1] = groupes[k]
  droite = {}
  for k = debut + longueur, 8
    droite[#droite + 1] = groupes[k]
  "#{table.concat gauche, ":"}::#{table.concat droite, ":"}"

M.formater_adresse = (adresse) ->
  return nil unless adresse
  if adresse.famille == 4
    formater_ipv4 adresse.octets
  else
    formater_ipv6 adresse.octets

M.formater_reseau = (reseau) ->
  "#{M.formater_adresse reseau}/#{reseau.prefixe}"

-- Une adresse textuelle (IPv4, IPv6, ou IPv4 mappée) en {famille, octets}.
M.analyser_adresse = (texte) ->
  return nil, "adresse vide" unless type(texte) == "string" and #texte > 0
  octets4 = analyser_ipv4 texte
  return {famille: 4, octets: octets4} if octets4
  adresse6 = analyser_ipv6 texte
  return adresse6 if adresse6
  nil, "adresse invalide"

-- Vrai si tous les bits au-delà du préfixe sont nuls.
bits_hotes_nuls = (octets, prefixe) ->
  for i = 1, #octets
    reste = prefixe - (i - 1) * 8
    if reste <= 0
      return false if octets[i] != 0
    elseif reste < 8
      masque = (1 << (8 - reste)) - 1
      return false if octets[i] & masque != 0
  true

-- Un sous-réseau textuel : « 10.35.0.0/16 », « 2001:470:ca35::/48 », ou une
-- adresse seule (/32 ou /128). Renvoie le réseau ou nil, message d'erreur.
M.analyser_reseau = (texte) ->
  return nil, "réseau vide" unless type(texte) == "string"
  texte = texte\match "^%s*(.-)%s*$"
  return nil, "réseau vide" if texte == ""
  barres = select 2, texte\gsub "/", ""
  return nil, "barre oblique multiple" if barres > 1
  adresse_txt, masque_txt = texte\match "^([^/]+)/(.*)$"
  unless adresse_txt
    adresse_txt, masque_txt = texte, nil
  adresse, err = M.analyser_adresse adresse_txt
  return nil, err unless adresse
  maximum = adresse.famille == 4 and 32 or 128
  prefixe = nil
  if masque_txt != nil
    return nil, "masque vide" if masque_txt == ""
    return nil, "masque invalide" unless masque_txt\match "^%d+$"
    return nil, "masque invalide" if #masque_txt > 1 and masque_txt\sub(1, 1) == "0"
    prefixe = tonumber masque_txt
    return nil, "masque hors 0..#{maximum}" unless prefixe != nil and prefixe <= maximum
  else
    prefixe = maximum
  unless bits_hotes_nuls adresse.octets, prefixe
    return nil, "bits d'hôte non nuls (masque /#{prefixe} trop large)"
  reseau = {famille: adresse.famille, octets: adresse.octets, :prefixe}
  reseau.texte = M.formater_reseau reseau
  reseau

-- Commentaire de fin de ligne : facultatif, 200 octets au plus, jamais de
-- saut de ligne (il ne doit pas casser le format un-sous-réseau-par-ligne).
commentaire_valide = (commentaire) ->
  return true if commentaire == nil or commentaire == ""
  type(commentaire) == "string" and #commentaire <= 200 and not commentaire\find "[\r\n]"

-- Découpe « 10.35.0.0/16 # chapelle » en sous-réseau et commentaire. Le
-- commentaire commence au premier « # », avec ou sans espace avant.
decouper_ligne = (texte) ->
  avant, apres = texte\match "^([^#]*)#(.*)$"
  unless avant
    return texte, ""
  avant\match("^%s*(.-)%s*$") or "", apres\match("^%s*(.-)%s*$") or ""

-- Entrée {reseau, commentaire} à partir d'un sous-réseau et d'un commentaire.
entree = (reseau, commentaire, numero) ->
  commentaire = "" if commentaire == nil
  unless commentaire_valide commentaire
    return nil, "ligne #{numero or "?"} : commentaire invalide (200 octets au plus, sans saut de ligne)"
  {reseau: reseau, commentaire: commentaire}

-- Liste d'entrées {reseau, commentaire}. Accepte encore une chaîne ou un
-- tableau de chaînes (ancienne forme, commentaire vide), et la nouvelle
-- forme tableau d'objets {reseau, commentaire}. Les entrées vides sont
-- ignorées ; une entrée invalide fait échouer toute la liste.
M.normaliser_liste = (valeur) ->
  entrees = {}
  ajouter = (texte) ->
    for morceau in texte\gmatch "[^,%s]+"
      reseau, err = M.analyser_reseau morceau
      return nil, "« #{morceau} » : #{err}" unless reseau
      entrees[#entrees + 1] = {reseau: reseau, commentaire: ""}
    true
  if valeur == nil
    return {}
  elseif type(valeur) == "string"
    ok, err = ajouter valeur
    return nil, err unless ok
  elseif type(valeur) == "table"
    for i, v in ipairs valeur
      if type(v) == "string"
        ok, err = ajouter v
        return nil, err unless ok
      elseif type(v) == "table"
        return nil, "entrée #{i} : champ reseau attendu" unless type(v.reseau) == "string"
        reseau, err = M.analyser_reseau v.reseau
        return nil, "entrée #{i} : « #{v.reseau} » : #{err}" unless reseau
        e, err = entree reseau, v.commentaire, nil
        return nil, "entrée #{i} : #{err}" unless e
        entrees[#entrees + 1] = e
      else
        return nil, "entrée #{i} : chaîne ou objet attendu"
  else
    return nil, "liste attendue"
  entrees

M.formater_liste = (entrees) ->
  textes = {}
  for e in *entrees
    reseau = e.reseau or e
    texte = M.formater_reseau reseau
    texte = texte .. " # " .. e.commentaire if type(e.commentaire) == "string" and e.commentaire != ""
    textes[#textes + 1] = texte
  table.concat textes, ", "

-- Analyse le fichier éditable à la main : un sous-réseau par ligne, suivi
-- d'un commentaire facultatif « # … ». Les lignes vides et les lignes qui ne
-- sont qu'un commentaire sont admises. Une ligne invalide fait échouer tout
-- le fichier (une faute de saisie ne doit pas élargir silencieusement
-- l'accès). Les commentaires ne participent jamais au contrôle d'accès.
M.analyser_fichier = (contenu) ->
  return nil, "contenu attendu" unless type(contenu) == "string"
  entrees = {}
  numero = 0
  for ligne in contenu\gmatch "[^\n]*"
    numero += 1
    texte = ligne\match "^%s*(.-)%s*$"
    if texte != "" and texte\sub(1, 1) != "#"
      sous_reseau, commentaire = decouper_ligne texte
      reseau, err = M.analyser_reseau sous_reseau
      return nil, "ligne #{numero} : « #{sous_reseau} » : #{err}" unless reseau
      e, err = entree reseau, commentaire, numero
      return nil, err unless e
      entrees[#entrees + 1] = e
  entrees, nil

-- Forme écrite sur disque : un sous-réseau canonique par ligne, son
-- commentaire d'entrée conservé. Les lignes qui n'étaient qu'un commentaire
-- ne sont pas représentées (elles sont perdues à l'écriture web).
M.formater_fichier = (entrees) ->
  lignes = {}
  for e in *entrees
    reseau = e.reseau or e
    texte = M.formater_reseau reseau
    texte = texte .. " # " .. e.commentaire if type(e.commentaire) == "string" and e.commentaire != ""
    lignes[#lignes + 1] = texte
  table.concat(lignes, "\n") .. (if #lignes > 0 then "\n" else "")

-- Adresse source brute de GetClientAddr en {famille, octets}. Une chaîne de
-- 16 octets dont les dix premiers sont nuls et les deux suivants 0xffff est
-- une adresse IPv4 mappée : elle est ramenée à IPv4.
M.depuis_client = (valeur) ->
  if type(valeur) == "number" and valeur >= 0
    return {
      famille: 4
      octets: {
        (valeur >> 24) & 0xff
        (valeur >> 16) & 0xff
        (valeur >> 8) & 0xff
        valeur & 0xff
      }
    }
  return nil unless type(valeur) == "string" and #valeur == 16
  octets = {}
  for i = 1, 16
    octets[i] = valeur\byte i
  mappee = true
  for i = 1, 10
    mappee = false if octets[i] != 0
  mappee = false unless mappee and octets[11] == 0xff and octets[12] == 0xff
  if mappee
    return {famille: 4, octets: {octets[13], octets[14], octets[15], octets[16]}}
  {famille: 6, :octets}

-- Adresse strictement locale : 127.0.0.1 ou ::1, pas tout 127.0.0.0/8.
locale = (adresse) ->
  return false unless adresse
  if adresse.famille == 4
    o = adresse.octets
    return o[1] == 127 and o[2] == 0 and o[3] == 0 and o[4] == 1
  return false unless adresse.famille == 6
  for i = 1, 15
    return false if adresse.octets[i] != 0
  adresse.octets[16] == 1

M.source_locale = (valeur) ->
  locale M.depuis_client valeur

M.texte_source = (valeur) ->
  adresse = M.depuis_client valeur
  return nil unless adresse
  M.formater_adresse adresse

-- Compare les bits du préfixe, octet plein puis bits restants.
comparer = (gauche, droite, prefixe) ->
  pleins = math.floor prefixe / 8
  for i = 1, pleins
    return false if gauche[i] != droite[i]
  reste = prefixe % 8
  return true if reste == 0
  masque = ((0xff << (8 - reste)) & 0xff)
  (gauche[pleins + 1] & masque) == (droite[pleins + 1] & masque)

M.appartient = (reseau, adresse) ->
  return false unless reseau and adresse and reseau.famille == adresse.famille
  comparer reseau.octets, adresse.octets, reseau.prefixe

-- Vrai si la source est locale ou appartient à l'un des réseaux. Une liste
-- vide est réputée sans filtre (l'appelant peut aussi le décider lui-même).
M.autorise = (entrees, valeur) ->
  return true if #entrees == 0
  adresse = M.depuis_client valeur
  return false unless adresse
  return true if locale adresse
  for e in *entrees
    reseau = e.reseau or e
    return true if M.appartient reseau, adresse
  false

M
