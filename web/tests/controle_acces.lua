package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local c = require "controle_acces"

-- Aides : un réseau analysé, une adresse source.
local function reseau(texte)
  local r, err = c.analyser_reseau(texte)
  assert(r ~= nil, "réseau refusé : " .. tostring(texte) .. " (" .. tostring(err) .. ")")
  return r
end

local function source(texte)
  local a = c.analyser_adresse(texte)
  assert(a ~= nil, "adresse refusée : " .. tostring(texte))
  return a
end

local function appartient(cidr, adresse)
  return c.appartient(reseau(cidr), source(adresse))
end

-- Formes et formatage canonique.
aide.egal(c.formater_reseau(reseau("10.35.0.0/16")), "10.35.0.0/16", "IPv4 /16 canonique")
aide.egal(c.formater_reseau(reseau("10.35.1.2")), "10.35.1.2/32", "adresse IPv4 seule = /32")
aide.egal(c.formater_reseau(reseau("2001:470:ca35::/48")), "2001:470:ca35::/48", "IPv6 /48 canonique")
aide.egal(c.formater_reseau(reseau("2001:0DB8:0000:0000:0000:0000:0000:0001")),
  "2001:db8::1/128", "IPv6 compressé et minuscule")
aide.egal(c.formater_reseau(reseau("::1")), "::1/128", "adresse IPv6 seule = /128")
aide.egal(c.formater_reseau(reseau("2001:db8:1:0:1:0:0:1")), "2001:db8:1:0:1::1/128",
  "IPv6 : première plus longue suite de zéros")
aide.egal(c.formater_reseau(reseau("0:0:0:0:0:0:0:0")), "::/128", "IPv6 non spécifiée")

-- Bornes des masques : 0, maximum, et au-delà refusé.
aide.egal(c.formater_reseau(reseau("0.0.0.0/0")), "0.0.0.0/0", "IPv4 /0")
aide.egal(c.formater_reseau(reseau("255.255.255.255/32")), "255.255.255.255/32", "IPv4 /32")
aide.egal(c.formater_reseau(reseau("::/0")), "::/0", "IPv6 /0")
aide.egal(c.formater_reseau(reseau("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/128")),
  "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff/128", "IPv6 /128")
aide.egal(c.analyser_reseau("10.0.0.0/33"), nil, "IPv4 /33 refusé")
aide.egal(c.analyser_reseau("::/129"), nil, "IPv6 /129 refusé")
aide.egal(c.analyser_reseau("10.0.0.0/-1"), nil, "masque négatif refusé")
aide.egal(c.analyser_reseau("10.0.0.0/"), nil, "masque vide refusé")
aide.egal(c.analyser_reseau("10.0.0.0/016"), nil, "masque à zéro initial refusé")

-- Appartenance IPv4, bornes de sous-réseau.
aide.verifie(appartient("10.35.0.0/16", "10.35.0.0"), "IPv4 /16 : première adresse")
aide.verifie(appartient("10.35.0.0/16", "10.35.255.255"), "IPv4 /16 : dernière adresse")
aide.verifie(not appartient("10.35.0.0/16", "10.36.0.0"), "IPv4 /16 : juste au-dessus")
aide.verifie(not appartient("10.35.0.0/16", "10.34.255.255"), "IPv4 /16 : juste en dessous")
aide.verifie(appartient("10.35.0.0/24", "10.35.0.1"), "IPv4 /24")
aide.verifie(not appartient("10.35.0.0/24", "10.35.1.1"), "IPv4 /24 : voisin exclu")
aide.verifie(appartient("0.0.0.0/0", "192.168.1.1"), "IPv4 /0 : tout")
aide.verifie(appartient("10.35.1.2/32", "10.35.1.2"), "IPv4 /32 : exacte")
aide.verifie(not appartient("10.35.1.2/32", "10.35.1.3"), "IPv4 /32 : voisine exclue")
aide.verifie(appartient("10.34.0.0/15", "10.35.0.1"), "IPv4 /15 non aligné sur un octet")
aide.verifie(not appartient("10.34.0.0/15", "10.36.0.1"), "IPv4 /15 : au-delà")
aide.verifie(appartient("128.0.0.0/1", "255.255.255.255"), "IPv4 /1 : moitié haute")

-- IPv6, formes compressées, casse, bornes.
aide.verifie(appartient("2001:470:ca35::/48", "2001:470:ca35:0:1:2:3:4"), "IPv6 /48")
aide.verifie(not appartient("2001:470:ca35::/48", "2001:470:ca36::1"), "IPv6 /48 : dehors")
aide.verifie(appartient("2001:DB8::/32", "2001:db8:ffff::1"), "IPv6 /32 : casse ignorée")
aide.verifie(appartient("::/0", "2001:db8::1"), "IPv6 /0 : tout")
aide.verifie(appartient("fe80::/10", "fe80::d180:3a29:a91c:a61f"),
  "IPv6 lien-local /10 (zone absente)")
aide.verifie(not appartient("fe80::/10", "fec0::1"), "IPv6 /10 : au-delà de fe80")
aide.verifie(appartient("2001:db8::1/128", "2001:DB8::1"), "IPv6 /128 : casse")
aide.verifie(not appartient("2001:db8::1/128", "2001:db8::2"), "IPv6 /128 : voisine")
aide.verifie(appartient("::1/128", "::1"), "IPv6 loopback /128")
aide.verifie(appartient("2001:db8::/63", "2001:db8:0:1::1"), "IPv6 /63 non aligné")
aide.verifie(not appartient("2001:db8::/63", "2001:db8:0:2::1"), "IPv6 /63 : dehors")

-- Adresses mixtes : IPv4 mappée traitée comme IPv4.
local mappee = c.analyser_adresse("::ffff:10.35.1.2")
aide.egal(mappee and mappee.famille, 4, "::ffff: traitée comme IPv4")
aide.egal(mappee and c.formater_adresse(mappee), "10.35.1.2", "::ffff: formatée IPv4")
aide.verifie(c.appartient(reseau("10.35.0.0/16"), mappee), "IPv4 mappée dans un réseau IPv4")
aide.egal(c.analyser_adresse("::FFFF:10.35.1.2").famille, 4, "::FFFF: casse")
aide.egal(c.formater_reseau(reseau("::ffff:10.35.0.0/16")), "10.35.0.0/16",
  "réseau IPv4 mappé ramené à IPv4 (masque IPv4)")
aide.egal(c.analyser_reseau("::ffff:10.35.0.0/104"), nil,
  "masque mappé hors bornes IPv4 refusé")

-- Adresses et masques invalides.
for _, mauvais in ipairs({
  "", "1.2.3", "1.2.3.4.5", "01.2.3.4", "256.1.1.1", "1.2.3.256",
  "a.b.c.d", "2001:db8:::1", "1::2::3", "2001:db8::g",
  "1:2:3:4:5:6:7:8:9", "fe80::1%wlo1", "[::1]", "::ffff:1.2.3",
  "10.0.0.0//16", "10.0.0.0/1/2",
}) do
  aide.egal(c.analyser_reseau(mauvais), nil, "refusé : « " .. mauvais .. " »")
end

-- Bits d'hôte non nuls : refus explicite (choix documenté).
aide.egal(c.analyser_reseau("10.35.1.2/16"), nil, "bits d'hôte IPv4 refusés")
aide.egal(c.analyser_reseau("2001:470:ca35::1/48"), nil, "bits d'hôte IPv6 refusés")
aide.egal(c.analyser_reseau("10.35.0.0/8"), nil, "octets d'hôte IPv4 refusés")

-- Listes.
local liste = c.normaliser_liste("10.35.0.0/16, 2001:470:ca35::/48")
aide.egal(liste and #liste, 2, "liste : virgule")
aide.egal(c.formater_liste(liste or {}), "10.35.0.0/16, 2001:470:ca35::/48", "liste formatée")
aide.egal(#(c.normaliser_liste("10.0.0.0/8 192.168.0.0/16\t2001:db8::/32") or {}), 3,
  "liste : espaces et tabulation")
aide.egal(#(c.normaliser_liste("") or {}), 0, "liste vide")
aide.egal(#(c.normaliser_liste("  ,  ") or {}), 0, "liste de séparateurs seuls")
aide.egal(#(c.normaliser_liste({}) or {}), 0, "tableau vide")
aide.egal(#(c.normaliser_liste({"10.0.0.0/8", "192.168.0.0/16"}) or {}), 2, "tableau de chaînes")
aide.egal(c.normaliser_liste("10.0.0.0/8, faux"), nil, "liste : entrée invalide refusée")
aide.egal(c.normaliser_liste({1}), nil, "liste : élément non chaîne refusé")

-- Sources GetClientAddr : entier IPv4, chaîne 16 octets IPv6, IPv4 mappée.
aide.egal(c.texte_source(0x0a230102), "10.35.1.2", "source IPv4 entière")
aide.egal(c.texte_source(0x7f000001), "127.0.0.1", "source 127.0.0.1")
local v6 = string.rep("\0", 15) .. "\1"
aide.egal(c.texte_source(v6), "::1", "source IPv6 binaire ::1")
local v6_autre = string.rep("\0", 10) .. "\xff\xff" ..
  string.char(10, 35, 1, 2)
aide.egal(c.texte_source(v6_autre), "10.35.1.2", "source ::ffff: ramenée à IPv4")
aide.egal(c.texte_source(nil), nil, "source absente")

-- Exception locale stricte.
aide.verifie(c.source_locale(0x7f000001), "127.0.0.1 est locale")
aide.verifie(not c.source_locale(0x7f000002), "127.0.0.2 n'est pas locale")
aide.verifie(c.source_locale(v6), "::1 est locale")
aide.verifie(not c.source_locale(v6_autre), "::ffff:10.x n'est pas locale")
aide.verifie(not c.source_locale(0x0a000001), "10.0.0.1 n'est pas locale")

-- Autorisation : liste vide, appartenance, exception locale.
aide.verifie(c.autorise({}, 0x0a230102), "liste vide : autorisé")
aide.verifie(c.autorise({reseau("10.35.0.0/16")}, 0x0a230102), "réseau : autorisé")
aide.verifie(not c.autorise({reseau("10.35.0.0/16")}, 0x0a240001), "hors réseau : refusé")
aide.verifie(c.autorise({reseau("10.35.0.0/16")}, 0x7f000001),
  "source locale : autorisée malgré la liste")
aide.verifie(not c.autorise({reseau("10.35.0.0/16")}, nil), "source inconnue : refusée")

aide.termine()
