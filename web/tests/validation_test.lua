package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local v = require "validation"

-- entier_borne
aide.egal(v.entier_borne(0, 0, 3), true, "entier_borne : borne basse")
aide.egal(v.entier_borne(3, 0, 3), true, "entier_borne : borne haute")
aide.egal(v.entier_borne(4, 0, 3), false, "entier_borne : au-dessus")
aide.egal(v.entier_borne(-1, 0, 3), false, "entier_borne : en dessous")
aide.egal(v.entier_borne(2.0, 0, 3), true, "entier_borne : flottant entier")
aide.egal(v.entier_borne(2.5, 0, 3), false, "entier_borne : flottant")
aide.egal(v.entier_borne("2", 0, 3), false, "entier_borne : chaîne")
aide.egal(v.entier_borne(nil, 0, 3), false, "entier_borne : nil")

-- peripherique_valide
aide.egal(v.peripherique_valide(""), true, "périphérique : vide accepté")
aide.egal(v.peripherique_valide("hw:0,0"), true, "périphérique : nom ALSA")
aide.egal(v.peripherique_valide(nil), false, "périphérique : nil refusé")
aide.egal(v.peripherique_valide(12), false, "périphérique : nombre refusé")
aide.egal(v.peripherique_valide(string.rep("a", 200)), true, "périphérique : 200 octets")
aide.egal(v.peripherique_valide(string.rep("a", 201)), false, "périphérique : 201 octets")
aide.egal(v.peripherique_valide("hw:0\1"), false, "périphérique : caractère de contrôle")
aide.egal(v.peripherique_valide("hw:0\t"), false, "périphérique : tabulation")
aide.egal(v.peripherique_valide("hw:0\127"), false, "périphérique : DEL")
aide.egal(v.peripherique_valide("carte-é"), true, "périphérique : octets UTF-8")

-- is_finite_number / is_integer
aide.egal(v.is_finite_number(0), true, "fini : zéro")
aide.egal(v.is_finite_number(math.huge), false, "fini : infini")
aide.egal(v.is_finite_number(-math.huge), false, "fini : -infini")
aide.egal(v.is_finite_number(0 / 0), false, "fini : NaN")
aide.egal(v.is_finite_number("1"), false, "fini : chaîne")
aide.egal(v.is_integer(2), true, "entier : 2")
aide.egal(v.is_integer(2.0), true, "entier : 2.0")
aide.egal(v.is_integer(2.5), false, "entier : 2.5")
aide.egal(v.is_integer(math.huge), false, "entier : infini")

-- temperament_depuis_etat
aide.egal(v.temperament_depuis_etat(nil, 5, 10), 5, "tempérament : absent")
aide.egal(v.temperament_depuis_etat(0, 5, 10), 0, "tempérament : 0")
aide.egal(v.temperament_depuis_etat(9, 5, 10), 9, "tempérament : 9")
aide.egal(v.temperament_depuis_etat(10, 5, 10), 10, "tempérament : 10")
aide.egal(v.temperament_depuis_etat(11, 5, 10), 5, "tempérament : 11 refusé")
aide.egal(v.temperament_depuis_etat(-1, 5, 10), 5, "tempérament : -1 refusé")
aide.egal(v.temperament_depuis_etat(2.5, 5, 10), 5, "tempérament : flottant refusé")
aide.egal(v.temperament_depuis_etat("3", 5, 10), 5, "tempérament : chaîne refusée")
aide.egal(v.temperament_depuis_etat(true, 5, 10), 5, "tempérament : booléen refusé")
aide.egal(v.temperament_depuis_etat(nil, 5, 10), 5, "tempérament : défaut explicite")

-- qualite_defauts / qualite_fichier_normalisee
local defauts = {niveau = -1, auto = false, tete_reverb = true,
  periode = 512, taux = 48000, peripherique = "", limiteur = true}
local q = v.qualite_defauts(defauts)
for k, val in pairs(defauts) do
  aide.egal(q[k], val, "qualité défauts : " .. k)
end
q = v.qualite_fichier_normalisee(nil, defauts)
aide.egal(q.periode, 512, "qualité fichier : nil -> défauts")
q = v.qualite_fichier_normalisee({niveau = 2, auto = true, tete_reverb = false,
  periode = 1024, taux = 44100, peripherique = "hw:1", limiteur = false}, defauts)
aide.egal(q.niveau, 2, "qualité fichier : niveau valide")
aide.egal(q.auto, true, "qualité fichier : auto valide")
aide.egal(q.tete_reverb, false, "qualité fichier : tête valide")
aide.egal(q.periode, 1024, "qualité fichier : période valide")
aide.egal(q.taux, 44100, "qualité fichier : taux valide")
aide.egal(q.peripherique, "hw:1", "qualité fichier : périphérique valide")
aide.egal(q.limiteur, false, "qualité fichier : limiteur valide")
q = v.qualite_fichier_normalisee({niveau = "2", auto = "oui", tete_reverb = 1,
  periode = 100, taux = 22050, peripherique = "hw:0\1", limiteur = "non"}, defauts)
aide.egal(q.niveau, -1, "qualité fichier : niveau invalide -> défaut")
aide.egal(q.auto, false, "qualité fichier : auto invalide -> défaut")
aide.egal(q.tete_reverb, true, "qualité fichier : tête invalide -> défaut")
aide.egal(q.periode, 512, "qualité fichier : période invalide -> défaut")
aide.egal(q.taux, 48000, "qualité fichier : taux invalide -> défaut")
aide.egal(q.peripherique, "", "qualité fichier : périphérique invalide -> défaut")
aide.egal(q.limiteur, true, "qualité fichier : limiteur invalide -> défaut")
q = v.qualite_fichier_normalisee({niveau = 3}, defauts)
aide.egal(q.niveau, 3, "qualité fichier : champ partiel gardé")
aide.egal(q.auto, false, "qualité fichier : champ partiel complété")

-- impositions
local imp = v.impositions({}, defauts)
aide.egal(imp.effectif.taux, 48000, "impositions : taux par défaut")
aide.egal(imp.effectif.periode, 512, "impositions : période par défaut")
aide.egal(imp.effectif.peripherique, "", "impositions : périphérique par défaut")
aide.egal(imp.effectif.limiteur, true, "impositions : limiteur par défaut")
aide.egal(imp.impose.taux, false, "impositions : taux non imposé")
aide.egal(#imp.erreurs, 0, "impositions : aucune erreur sans variable")
imp = v.impositions({ORGANUM_TAUX = "44100", ORGANUM_PERIODE = "1024",
  ORGANUM_PERIPHERIQUE = "hw:2", ORGANUM_LIMITEUR = "non"}, defauts)
aide.egal(imp.effectif.taux, 44100, "impositions : taux imposé")
aide.egal(imp.impose.taux, true, "impositions : taux marqué")
aide.egal(imp.effectif.periode, 1024, "impositions : période imposée")
aide.egal(imp.impose.periode, true, "impositions : période marquée")
aide.egal(imp.effectif.peripherique, "hw:2", "impositions : périphérique imposé")
aide.egal(imp.impose.peripherique, true, "impositions : périphérique marqué")
aide.egal(imp.effectif.limiteur, false, "impositions : limiteur non")
aide.egal(imp.impose.limiteur, true, "impositions : limiteur marqué")
aide.egal(#imp.erreurs, 0, "impositions : aucune erreur valide")
imp = v.impositions({ORGANUM_TAUX = "22050", ORGANUM_PERIODE = "100",
  ORGANUM_PERIPHERIQUE = "hw:0\1", ORGANUM_LIMITEUR = "oui"}, defauts)
aide.egal(imp.effectif.taux, 48000, "impositions : taux invalide ignoré")
aide.egal(imp.impose.taux, false, "impositions : taux invalide non marqué")
aide.egal(imp.effectif.periode, 512, "impositions : période invalide ignorée")
aide.egal(#imp.erreurs, 3, "impositions : trois erreurs")
aide.egal(imp.effectif.limiteur, true, "impositions : limiteur oui")
imp = v.impositions({ORGANUM_TAUX = "", ORGANUM_PERIODE = "", ORGANUM_LIMITEUR = ""}, defauts)
aide.egal(imp.impose.taux, false, "impositions : variables vides ignorées")
aide.egal(imp.impose.periode, false, "impositions : période vide ignorée")
aide.egal(imp.impose.limiteur, false, "impositions : limiteur vide ignoré")
imp = v.impositions({ORGANUM_PERIPHERIQUE = ""}, defauts)
aide.egal(imp.impose.peripherique, true, "impositions : périphérique vide imposé")
aide.egal(imp.effectif.peripherique, "", "impositions : périphérique vide effectif")

-- divisions factices pour valider_orgue
local divisions = {
  {jeux = {{}, {}}, liens = {{}}},
  {jeux = {{}}, liens = {}},
}
local function orgue(data) return v.valider_orgue(data, divisions, 32, 10) end

local action, err = orgue({})
aide.egal(action, nil, "orgue : aucune action refusée")
aide.verifie(err ~= nil, "orgue : message pour aucune action")
action, err = orgue({inconnu = 1})
aide.egal(action, nil, "orgue : champ inconnu refusé")
action, err = orgue({panic = true, cancel = 0})
aide.egal(action, nil, "orgue : deux actions refusées")
action = orgue({stop = {division = 0, index = 0, on = true}})
aide.egal(action, "stop", "orgue : stop valide")
action = orgue({stop = {division = 1, index = 0, on = false}})
aide.egal(action, "stop", "orgue : stop seconde division")
action = orgue({stop = {division = 2, index = 0, on = true}})
aide.egal(action, nil, "orgue : stop division hors limites")
action = orgue({stop = {division = 0.5, index = 0, on = true}})
aide.egal(action, nil, "orgue : stop division flottante")
action = orgue({stop = {division = 0, index = 2, on = true}})
aide.egal(action, nil, "orgue : stop index hors limites")
action = orgue({stop = {division = 0, index = -1, on = true}})
aide.egal(action, nil, "orgue : stop index négatif")
action = orgue({stop = {division = 0, index = 0, on = 1}})
aide.egal(action, nil, "orgue : stop on non booléen")
action = orgue({stop = "x"})
aide.egal(action, nil, "orgue : stop non table")

action = orgue({link = {division = 0, index = 0, on = true}})
aide.egal(action, "link", "orgue : lien valide")
action = orgue({link = {division = 0, index = 1, on = true}})
aide.egal(action, nil, "orgue : lien hors limites")
action = orgue({link = {division = 0, index = 0, on = nil}})
aide.egal(action, nil, "orgue : lien on manquant")

aide.egal(orgue({cancel = 0}), "cancel", "orgue : cancel valide")
aide.egal(orgue({cancel = 1}), "cancel", "orgue : cancel seconde division")
aide.egal(orgue({cancel = 2}), nil, "orgue : cancel hors limites")
aide.egal(orgue({cancel = -1}), nil, "orgue : cancel négatif")
aide.egal(orgue({cancel = 1.5}), nil, "orgue : cancel flottant")

aide.egal(orgue({step = 0}), "step", "orgue : step 0")
aide.egal(orgue({step = 31}), "step", "orgue : step 31")
aide.egal(orgue({step = 32}), nil, "orgue : step 32 refusé")
aide.egal(orgue({step = -1}), nil, "orgue : step négatif")
aide.egal(orgue({step = 1.5}), nil, "orgue : step flottant")

aide.egal(orgue({reverb = 0}), "reverb", "orgue : reverb 0")
aide.egal(orgue({reverb = 127}), "reverb", "orgue : reverb 127")
aide.egal(orgue({reverb = 128}), nil, "orgue : reverb 128 refusé")
aide.egal(orgue({reverb = -1}), nil, "orgue : reverb négatif")
aide.egal(orgue({reverb = 2.5}), nil, "orgue : reverb flottant")

aide.egal(orgue({gain = {division = 0, value = 0}}), "gain", "orgue : gain 0")
aide.egal(orgue({gain = {division = 1, value = 1}}), "gain", "orgue : gain 1")
aide.egal(orgue({gain = {division = 1, value = 0.5}}), "gain", "orgue : gain 0,5")
aide.egal(orgue({gain = {division = 2, value = 0.5}}), nil, "orgue : gain division hors limites")
aide.egal(orgue({gain = {division = 0, value = 1.1}}), nil, "orgue : gain trop grand")
aide.egal(orgue({gain = {division = 0, value = -0.1}}), nil, "orgue : gain négatif")
aide.egal(orgue({gain = {division = 0, value = 0 / 0}}), nil, "orgue : gain NaN")
aide.egal(orgue({gain = {division = 0, value = math.huge}}), nil, "orgue : gain infini")
aide.egal(orgue({gain = {division = 0, value = "0.5"}}), nil, "orgue : gain chaîne")

aide.egal(orgue({qualite = {}}), "qualite", "orgue : qualité déléguée")
aide.egal(orgue({qualite = 5}), "qualite", "orgue : qualité non table déléguée")

aide.egal(orgue({temperament = 0}), "temperament", "orgue : tempérament 0")
aide.egal(orgue({temperament = 10}), "temperament", "orgue : tempérament 10")
aide.egal(orgue({temperament = 11}), nil, "orgue : tempérament 11 refusé")
aide.egal(orgue({temperament = -1}), nil, "orgue : tempérament négatif")
aide.egal(orgue({temperament = 2.5}), nil, "orgue : tempérament flottant")
aide.egal(orgue({temperament = "1"}), nil, "orgue : tempérament chaîne")
aide.egal(orgue({temperament = true}), nil, "orgue : tempérament booléen")

aide.egal(orgue({volume = 0}), "volume", "orgue : volume 0")
aide.egal(orgue({volume = 1}), "volume", "orgue : volume 1")
aide.egal(orgue({volume = 0.5}), "volume", "orgue : volume 0,5")
aide.egal(orgue({volume = -0.1}), nil, "orgue : volume négatif")
aide.egal(orgue({volume = 1.1}), nil, "orgue : volume trop grand")
aide.egal(orgue({volume = 0 / 0}), nil, "orgue : volume NaN")
aide.egal(orgue({volume = math.huge}), nil, "orgue : volume infini")
aide.egal(orgue({volume = "0.5"}), nil, "orgue : volume chaîne")

aide.egal(orgue({panic = true}), "panic", "orgue : panique valide")
aide.egal(orgue({panic = false}), nil, "orgue : panique false refusé")
aide.egal(orgue({panic = 1}), nil, "orgue : panique non booléen")

-- valider_qualite
local function qualite(q) return v.valider_qualite(q) end
aide.egal(qualite({}), nil, "qualité : objet vide refusé")
aide.egal(qualite(5), nil, "qualité : non table refusée")
aide.egal(qualite({inconnu = 1}), nil, "qualité : champ inconnu refusé")
local complet = {bruit_attaque = true, instabilite = false, spatialisation = 2,
  polyphonie_max = 512, tete_reverb = true, niveau = 3, auto = false,
  periode = 2048, taux = 44100, peripherique = "hw:0", limiteur = false}
aide.egal(qualite(complet), true, "qualité : tous les champs valides")
for _, cas in ipairs({
  {{bruit_attaque = 1}, "bruit_attaque"},
  {{instabilite = 0}, "instabilite"},
  {{spatialisation = -1}, "spatialisation basse"},
  {{spatialisation = 3}, "spatialisation haute"},
  {{spatialisation = 1.5}, "spatialisation flottante"},
  {{polyphonie_max = -1}, "polyphonie basse"},
  {{polyphonie_max = 513}, "polyphonie haute"},
  {{tete_reverb = "oui"}, "tête non booléenne"},
  {{niveau = -1}, "niveau bas"},
  {{niveau = 4}, "niveau haut"},
  {{auto = "non"}, "auto non booléen"},
  {{periode = 100}, "période invalide"},
  {{periode = "512"}, "période chaîne"},
  {{taux = 22050}, "taux invalide"},
  {{taux = "48000"}, "taux chaîne"},
  {{peripherique = "hw:0\1"}, "périphérique de contrôle"},
  {{peripherique = string.rep("a", 201)}, "périphérique trop long"},
  {{limiteur = 1}, "limiteur non booléen"},
}) do
  local action = qualite(cas[1])
  aide.egal(action, nil, "qualité : refus " .. cas[2])
end
aide.egal(qualite({niveau = 0}), true, "qualité : un seul champ suffit")

-- valider_connexion_midi
aide.egal(v.valider_connexion_midi({client = 0, port = 0, connecte = true}), true,
  "connexion : 0:0 valide")
aide.egal(v.valider_connexion_midi({client = 255, port = 255, connecte = false}), true,
  "connexion : 255:255 valide")
for _, cas in ipairs({
  {{client = -1, port = 0, connecte = true}, "client négatif"},
  {{client = 0, port = 256, connecte = true}, "port trop grand"},
  {{client = 1.5, port = 0, connecte = true}, "client flottant"},
  {{client = "1", port = 0, connecte = true}, "client chaîne"},
  {{client = 1, port = 0, connecte = 1}, "connecte non booléen"},
  {{client = 1, port = 0}, "connecte absent"},
  {{}, "champs absents"},
}) do
  aide.egal(v.valider_connexion_midi(cas[1]), nil, "connexion : refus " .. cas[2])
end

-- tables exposées
aide.egal(v.TAUX_VALIDES[44100], true, "constantes : taux 44100")
aide.egal(v.TAUX_VALIDES[22050], nil, "constantes : taux 22050 absent")
aide.egal(v.PERIODES_VALIDES[2048], true, "constantes : période 2048")
aide.egal(v.PERIODES_VALIDES[100], nil, "constantes : période 100 absente")
aide.egal(v.DEMARRAGE_DEFAUT.periode, 512, "constantes : période par défaut")
for _, cle in ipairs({"stop", "cancel", "step", "reverb", "panic", "gain",
                      "link", "qualite", "volume", "temperament"}) do
  aide.egal(v.ACTIONS_ORGUE[cle], true, "constantes : action " .. cle)
end

aide.termine()
