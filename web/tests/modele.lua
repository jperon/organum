package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local m = require "modele"

-- abrege
aide.egal(m.abrege("Manual II"), "II", "abrege : Manual II")
aide.egal(m.abrege("Manual  III"), "III", "abrege : espaces multiples")
aide.egal(m.abrege("manual IV"), "IV", "abrege : minuscules")
aide.egal(m.abrege("Pedal"), "P", "abrege : Pedal")
aide.egal(m.abrege("Pedalboard"), "P", "abrege : Pedalboard")
aide.egal(m.abrege("Récit"), "Récit", "abrege : autre nom inchangé")
aide.egal(m.abrege(42), "42", "abrege : nombre converti")
aide.egal(m.abrege(nil), "nil", "abrege : nil converti")

-- nom_jeu
aide.egal(m.nom_jeu(nil), "", "nom_jeu : nil")
aide.egal(m.nom_jeu({}), "", "nom_jeu : jeu sans nom")
aide.egal(m.nom_jeu({nom = "Bourdon\n8"}), "Bourdon 8", "nom_jeu : retour à la ligne")
aide.egal(m.nom_jeu({nom = "A\n\nB"}), "A  B", "nom_jeu : deux retours")
aide.egal(m.nom_jeu({nom = 12}), "12", "nom_jeu : nombre")

-- canaux
local liste = m.canaux_liste(0)
aide.egal(#liste, 0, "canaux_liste : masque nul")
liste = m.canaux_liste(1)
aide.egal(#liste, 1, "canaux_liste : un canal")
aide.egal(liste[1], 1, "canaux_liste : canal 1")
liste = m.canaux_liste(0xFFFF)
aide.egal(#liste, 16, "canaux_liste : seize canaux")
aide.egal(liste[16], 16, "canaux_liste : dernier canal 16")
aide.egal(#m.canaux_liste("1"), 1, "canaux_liste : chaîne numérique acceptée")
aide.egal(m.canaux_masque({1, 16}), 1 + 32768, "canaux_masque : 1 et 16")
aide.egal(m.canaux_masque({1, 1, 2}), 3, "canaux_masque : doublons")
aide.egal(m.canaux_masque({0, 17, 2.5}), 0, "canaux_masque : hors bornes ignorés")
aide.egal(m.canaux_masque({2.0, 3.0}), 6, "canaux_masque : flottants entiers")
aide.egal(m.canaux_masque(m.canaux_liste(0xFFFF)), 0xFFFF, "canaux : aller-retour")

-- liste_json
local l = m.liste_json({})
aide.egal(l[0], false, "liste_json : marque tableau vide")
l = m.liste_json({a = 1})
aide.egal(l[0], false, "liste_json : marque même non vide")
aide.egal(l.a, 1, "liste_json : contenu conservé")
aide.egal(m.liste_json(nil)[0], false, "liste_json : nil -> table marquée")

-- libelle_plateforme
aide.egal(m.libelle_plateforme("linux"), "Linux", "libelle_plateforme : linux")
aide.egal(m.libelle_plateforme("macos"), "macOS", "libelle_plateforme : macos")
aide.egal(m.libelle_plateforme("inconnue"), "plate-forme inconnue",
  "libelle_plateforme : inconnue")
aide.egal(m.libelle_plateforme(nil), "plate-forme inconnue",
  "libelle_plateforme : nil")

-- ETATS
aide.egal(m.ETATS.vert.classe, "etat-vert", "ETATS : classe vert")
aide.egal(m.ETATS.orange.libelle, "Connecté, non synchronisé", "ETATS : libellé orange")
aide.egal(m.ETATS.rouge.title, "Déconnecté", "ETATS : infobulle rouge")
for _, cle in ipairs({"vert", "orange", "rouge"}) do
  local e = m.ETATS[cle]
  aide.verifie(type(e.classe) == "string" and type(e.libelle) == "string" and
    type(e.title) == "string", "ETATS : champs complets " .. cle)
end

-- CHARGE_NIVEAUX
aide.egal(#m.CHARGE_NIVEAUX, 4, "CHARGE_NIVEAUX : quatre niveaux")
aide.egal(m.CHARGE_NIVEAUX[1].classe, "charge-gris", "CHARGE_NIVEAUX : 0 gris")
aide.egal(m.CHARGE_NIVEAUX[2].classe, "charge-vert", "CHARGE_NIVEAUX : 1 vert")
aide.egal(m.CHARGE_NIVEAUX[3].classe, "charge-orange", "CHARGE_NIVEAUX : 2 orange")
aide.egal(m.CHARGE_NIVEAUX[4].classe, "charge-rouge", "CHARGE_NIVEAUX : 3 rouge")
aide.egal(m.CHARGE_NIVEAUX[4].court, "Inadapté !", "CHARGE_NIVEAUX : libellé court rouge")
for i = 1, 4 do
  local n = m.CHARGE_NIVEAUX[i]
  aide.verifie(type(n.libelle) == "string" and type(n.court) == "string",
    "CHARGE_NIVEAUX : champs complets " .. (i - 1))
end

-- charge_niveau
aide.egal(m.charge_niveau(nil), 0, "charge_niveau : nil -> 0")
aide.egal(m.charge_niveau(-1), 0, "charge_niveau : négatif -> 0")
aide.egal(m.charge_niveau(0), 0, "charge_niveau : 0")
aide.egal(m.charge_niveau(1), 1, "charge_niveau : 1")
aide.egal(m.charge_niveau(2), 2, "charge_niveau : 2")
aide.egal(m.charge_niveau(3), 3, "charge_niveau : 3")
aide.egal(m.charge_niveau(4), 3, "charge_niveau : 4 borné à 3")
aide.egal(m.charge_niveau(2.0), 2, "charge_niveau : flottant entier")
aide.egal(m.charge_niveau(2.5), 0, "charge_niveau : flottant non entier -> 0")

-- etat_puce
aide.egal(m.etat_puce(false, false), "rouge", "etat_puce : déconnecté")
aide.egal(m.etat_puce(false, true), "rouge", "etat_puce : déconnecté mais synchronisé")
aide.egal(m.etat_puce(true, false), "orange", "etat_puce : connecté non synchronisé")
aide.egal(m.etat_puce(true, true), "vert", "etat_puce : connecté synchronisé")

-- cibles MIDI
for _, cle in ipairs({"volume", "reverb", "gain", "aucune"}) do
  aide.verifie(type(m.cible_midi[cle]) == "string" and type(m.cible_midi_court[cle]) == "string",
    "cible_midi : libellé présent " .. cle)
end
aide.egal(m.cible_midi.reverb, "Réverbération", "cible_midi : réverbération")
aide.egal(m.cible_midi_court.aucune, "Aucune", "cible_midi_court : aucune")

-- canal_texte
aide.egal(m.canal_texte(nil), "Tous", "canal_texte : nil")
aide.egal(m.canal_texte(3), "3", "canal_texte : numéro")

-- libelle_association
aide.egal(m.libelle_association({}), "Tous · CC ? → Aucune", "association : champs absents")
aide.egal(m.libelle_association({canal = 3, cc = 7, cible = "volume"}),
  "Canal 3 · CC 7 → Volume", "association : canal et volume")
aide.egal(m.libelle_association({cc = 64, cible = "gain", division = 1},
  {{nom = "Manual II"}}), "Tous · CC 64 → Gain (Manual II)", "association : gain avec division")
aide.egal(m.libelle_association({cc = 64, cible = "gain", division = 1},
  {{name = "Manual I"}}), "Tous · CC 64 → Gain (Manual I)", "association : division name")
aide.egal(m.libelle_association({canal = 1, cc = 2, cible = "gain", division = 9},
  {{nom = "Pedal"}}), "Canal 1 · CC 2 → Gain", "association : division absente")
aide.egal(m.libelle_association({canal = 1, cc = 2, cible = "inconnue"}),
  "Canal 1 · CC 2 → Aucune", "association : cible inconnue")
aide.egal(m.libelle_association(nil), "Tous · CC ? → Aucune", "association : nil")

-- PRESELECTIONS
aide.egal(#m.PRESELECTIONS, 4, "PRESELECTIONS : quatre niveaux")
local attendu = {
  {0, false, false, 64, false},
  {1, false, false, 128, false},
  {1, true, true, 192, true},
  {2, true, true, 0, true},
}
for i, p in ipairs(attendu) do
  local q = m.PRESELECTIONS[i]
  aide.egal(q.spatialisation, p[1], "présélection " .. (i - 1) .. " : spatialisation")
  aide.egal(q.bruit_attaque, p[2], "présélection " .. (i - 1) .. " : bruit")
  aide.egal(q.instabilite, p[3], "présélection " .. (i - 1) .. " : instabilité")
  aide.egal(q.polyphonie_max, p[4], "présélection " .. (i - 1) .. " : polyphonie")
  aide.egal(q.tete_reverb, p[5], "présélection " .. (i - 1) .. " : tête")
end

-- niveau_correspondant
for i, p in ipairs(m.PRESELECTIONS) do
  aide.egal(m.niveau_correspondant(p), i - 1, "niveau_correspondant : présélection " .. (i - 1))
end
aide.egal(m.niveau_correspondant({spatialisation = 2, bruit_attaque = true,
  instabilite = true, polyphonie_max = 12}), -1, "niveau_correspondant : personnalisé")
aide.egal(m.niveau_correspondant({}), -1, "niveau_correspondant : vide")
aide.egal(m.niveau_correspondant(nil), -1, "niveau_correspondant : nil")
aide.egal(m.niveau_correspondant({spatialisation = 0, bruit_attaque = false,
  instabilite = false, polyphonie_max = 64}), 0,
  "niveau_correspondant : booléens faux explicites")
aide.egal(m.niveau_correspondant({spatialisation = 0, polyphonie_max = 64}), -1,
  "niveau_correspondant : booléens absents ne correspondent pas")
aide.egal(m.niveau_correspondant({spatialisation = 1, bruit_attaque = 1,
  instabilite = 1, polyphonie_max = 192}), 2, "niveau_correspondant : valeurs vraies non booléennes")

-- TEMPERAMENTS
local temperaments = {
  "Pythagoricien", "Mésotonique", "Werckmeister III", "Kirnberger III",
  "Bien tempéré", "Égal", "Ahrend", "Vallotti", "Kellner", "Lehman", "Juste (do)",
}
aide.egal(#m.TEMPERAMENTS, 11, "TEMPERAMENTS : onze libellés")
for i, nom in ipairs(temperaments) do
  aide.egal(m.TEMPERAMENTS[i], nom, "TEMPERAMENTS : ordre de l'enum " .. (i - 1))
end

-- libelle_port
aide.egal(m.libelle_port({client = 24, port = 0, nom_client = "Clavier USB"}),
  "24:0 — Clavier USB", "libelle_port : adresse et client")
aide.egal(m.libelle_port({client = 24, port = 0, nom_port = "MIDI 1"}),
  "24:0 — MIDI 1", "libelle_port : repli sur le port")
aide.egal(m.libelle_port({adresse = "128:0", nom_client = "Organum"}),
  "128:0 — Organum", "libelle_port : adresse directe")
aide.egal(m.libelle_port({client = 1, port = 2}), "1:2", "libelle_port : adresse seule")
aide.egal(m.libelle_port({nom_client = "Solo"}), "Solo", "libelle_port : nom seul")
aide.egal(m.libelle_port({}), "?", "libelle_port : vide")
aide.egal(m.libelle_port(nil), "?", "libelle_port : nil")
aide.egal(m.libelle_port({client = 1, port = 2, nom_client = "", nom_port = "P"}),
  "1:2 — P", "libelle_port : nom client vide")

-- etat_port
aide.egal(m.etat_port({organum = true}), "organum", "etat_port : organum prioritaire")
aide.egal(m.etat_port({organum = true, connecte = true}), "organum", "etat_port : organum avant connecté")
aide.egal(m.etat_port({connecte = true, destination = true}), "connecte", "etat_port : connecté avant destination")
aide.egal(m.etat_port({destination = true}), "destination", "etat_port : destination")
aide.egal(m.etat_port({}), "disponible", "etat_port : disponible")
aide.egal(m.etat_port(nil), "disponible", "etat_port : nil")

aide.egal(m.texte_transposition(0), "0", "transposition : zéro")
aide.egal(m.texte_transposition(3), "+3", "transposition : positif")
aide.egal(m.texte_transposition(-2), "\226\136\1462", "transposition : négatif (moins U+2212)")
aide.egal(m.texte_transposition(20), "+12", "transposition : borne haute")
aide.egal(m.texte_transposition(-20), "\226\136\14612", "transposition : borne basse")
aide.egal(m.texte_transposition(nil), "0", "transposition : nil -> 0")

aide.egal(m.colonne_transposition({{name = "Manual III", links = {}}, {name = "Manual II", links = {{}}}, {name = "Pedal", links = {{}}}}), 1,
  "transposition : Manuel III par son nom")
aide.egal(m.colonne_transposition({{name = "Grand Orgue", links = {{}}}, {name = "Récit", links = {}}}), 2,
  "transposition : repli sur la division sans accouplement")
aide.egal(m.colonne_transposition({{nom = "Manual III", liens = {}}}), 1,
  "transposition : forme native (nom/liens)")
aide.egal(m.colonne_transposition({{name = "I", links = {{}}}, {name = "II", links = {{}}}}), nil,
  "transposition : aucune colonne libre")
aide.egal(m.colonne_transposition(nil), nil, "transposition : divisions absentes")

aide.termine()
