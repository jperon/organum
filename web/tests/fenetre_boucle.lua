package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local aide = require "aide"
local lancer = require "fenetre"

-- Doublure d'état : quatre claviers, assez de jeux pour la console et le MIDI.
local function nouvel_etat()
  local e = {
    seq = 1, etape = 0, netapes = 32, volume = 0.5, reverb = 0.3,
    temperament = 5, midi = "128:0", canaux_actifs = 0,
    netapes = 32, divisions = {},
    qualite = {
      bruit_attaque = true, instabilite = true, spatialisation = 2,
      polyphonie_max = 0, tete_reverb = true, tete_reverb_impose = false,
      charge = 0, charge_pointe = 0, charge_evaluee = false, charge_niveau = 0,
      xruns_recents = 0, application = false, temperament_erreur = "",
      audio_erreur = "", audio_repli = "", limiteur = true,
      calibration = {niveau = 2, estimation_ms = {4, 5, 6, 7}, echeance_ms = 10.7,
                     voix_ref = 250, tete_reverb = true},
    },
  }
  for i = 1, 4 do
    local div = {nom = "Manual " .. i, gain = 0.5, jeux = {}, liens = {}}
    for j = 1, 12 do
      div.jeux[j] = {nom = "Double Open Diapason " .. j, actif = false}
    end
    if i > 1 then div.liens[1] = {division = 1, actif = false} end
    e.divisions[i] = div
  end
  return e
end

-- Construit les doublures et exécute un plan de clics, une entrée par image.
-- plan[n] est une liste de libellés cliqués à l'image n.
local function scenario(plan, nframes, options)
  options = options or {}
  local e = nouvel_etat()
  local commandes = {}

  local ui = {l = options.largeur or 1024, h = options.hauteur or 640,
              frame = 0, police_courante = 20, textes = {}, lignes = 0}
  local function clic(libelle)
    local liste = ui.clics
    if not liste then return false end
    for i, v in ipairs(liste) do
      if v == libelle then table.remove(liste, i); return true end
    end
    return false
  end
  function ui:evenements()
    if self.frame >= nframes then return false, false end
    self.frame = self.frame + 1
    self.clics = plan[self.frame] or {}
    return true, true
  end
  function ui:taille() return self.l, self.h end
  function ui:police(p) self.police_courante = p end
  function ui:largeur_texte(s) return #tostring(s) * 8 end
  function ui:ligne(n, cols) self.lignes = self.lignes + (n or 0) end
  function ui:ligne_ratio(n, ratios) self.lignes = self.lignes + (n or 0) end
  function ui:texte(t) self.textes[#self.textes + 1] = tostring(t) end
  function ui:bouton(libelle) return clic(libelle) end
  function ui:choix(libelle, actif)
    if clic(libelle) then return not actif end
    return actif
  end
  function ui:choix_deux(a, b, actif)
    if clic(a) or clic(b) then return not actif end
    return actif
  end
  function ui:etat(libelle, selection)
    if clic(libelle) then return not selection end
    return selection
  end
  function ui:curseur(valeur) return valeur end
  function ui:debut() return true end
  function ui:fin() end
  function ui:dessiner() end
  function ui:groupe_debut() return true end
  function ui:groupe_fin() end

  local o = {}
  local function noter(nom)
    commandes[#commandes + 1] = {nom = nom, frame = ui.frame}
  end
  o.etat = function() return e end
  o.oublier_audio = function() end
  o.jeu = function(d, j, v)
    noter("jeu"); e.divisions[d].jeux[j].actif = v
  end
  o.lien = function(d, i, v) noter("lien"); e.divisions[d].liens[i].actif = v end
  o.gain = function(d, v) noter("gain"); e.divisions[d].gain = v end
  o.volume = function(v) noter("volume"); e.volume = v end
  o.reverb = function(v) noter("reverb"); e.reverb = v end
  o.qualite = function(k, v) noter("qualite"); e.qualite[k] = v end
  o.temperament = function(t) noter("temperament"); e.temperament = t end
  o.midi = function(s, n) noter("midi"); e.etape = n end
  o.panique = function() noter("panique") end
  o.tete_reverb = function(v) noter("tete_reverb") end
  o.limiteur = function(v) noter("limiteur") end
  o.reconfigurer_audio = function(c) noter("reconfigurer_audio") end
  o.associations = function(l) noter("associations") end
  o.canaux_division = function(d, m) noter("canaux_division") end
  o.canaux_controle = function(m) noter("canaux_controle") end
  o.canaux_expression = function(m) noter("canaux_expression") end
  local ports = {
    {client = 128, port = 0, nom_client = "Organum", source = false,
     destination = true, connecte = true, organum = true},
    {client = 24, port = 0, nom_client = "Clavier USB", nom_port = "MIDI 1",
     source = true, destination = false, connecte = false},
  }
  o.midi_ports = function() return ports end
  o.midi_connecter = function(client, port)
    noter("midi_connecter"); return true
  end
  o.midi_deconnecter = function(client, port)
    noter("midi_deconnecter"); return true
  end

  local midi
  if options.midi then
    midi = {
      etat = function()
        return {
          midi = "128:0",
          divisions = {{nom = "Manual 1", canaux = {1}},
                       {nom = "Manual 2", canaux = {2}},
                       {nom = "Manual 3", canaux = {3}},
                       {nom = "Manual 4", canaux = {4}}},
          controle = {16}, expression = {16},
          associations = {{cc = 1, cible = "volume"}},
          dernier_controle = nil,
        }
      end,
      appliquer = function(cfg) noter("midi_appliquer"); return true end,
      enregistrer = function(cfg) end,
    }
  end
  local nk = {ouvrir = function() return ui, nil end}
  lancer(o, nk, {titre = "test", largeur = ui.l, hauteur = ui.h,
    midi = midi, continuer = function() return true end})
  return commandes, ui
end

local function aucune(cmd, nom)
  aide.egal(#cmd, 0, nom)
  if #cmd > 0 then
    local noms = {}
    for _, c in ipairs(cmd) do noms[#noms + 1] = c.nom .. "@" .. c.frame end
    print("        commandes : " .. table.concat(noms, ", "))
  end
end

-- Console : plusieurs images sans clic n'émettent rien.
local cmd, ui = scenario({}, 6)
aucune(cmd, "console : six images sans clic, aucune commande")
aide.verifie(ui.lignes > 0, "console : le dessin a bien eu lieu")

-- Console : un clic sur un jeu émet exactement une commande.
cmd = scenario({[5] = {"Diapason 1"}}, 7)
aide.egal(#cmd, 1, "console : un clic sur un jeu, une commande")
aide.egal(cmd[1] and cmd[1].nom, "jeu", "console : la commande est un jeu")
aide.egal(cmd[1] and cmd[1].frame, 5, "console : commande à l'image du clic")

-- Console : le clic sur un jeu déjà actif n'émet rien (valeur rendue = état).
e = nil
cmd = scenario({[5] = {"Diapason 1"}}, 7)
aide.egal(#cmd, 1, "console : second clic sur un jeu inactif, une commande")

-- MIDI : navigation puis plusieurs images sans clic n'émettent rien.
cmd = scenario({[1] = {"MIDI"}}, 7, {midi = true})
aucune(cmd, "MIDI : sept images sans clic après navigation, aucune commande")

-- MIDI : un clic sur une cible émet exactement une action d'enregistrement.
cmd = scenario({[1] = {"MIDI"}, [3] = {"Cible Vol."}}, 6, {midi = true})
aide.egal(#cmd, 1, "MIDI : un clic sur la cible, une action")
aide.egal(cmd[1] and cmd[1].nom, "midi_appliquer", "MIDI : action d'application")
aide.egal(cmd[1] and cmd[1].frame, 3, "MIDI : action à l'image du clic")

-- Connexions : navigation, images sans clic, puis un clic = une connexion.
cmd = scenario({[1] = {"MIDI"}, [3] = {"Connexions"}}, 7, {midi = true})
aucune(cmd, "connexions : images sans clic après navigation, aucune commande")

cmd = scenario({[1] = {"MIDI"}, [2] = {"Connexions"}, [4] = {"Connecter"}},
  7, {midi = true})
aide.egal(#cmd, 1, "connexions : un clic Connecter, une commande")
aide.egal(cmd[1] and cmd[1].nom, "midi_connecter", "connexions : connexion demandée")
aide.egal(cmd[1] and cmd[1].frame, 4, "connexions : commande à l'image du clic")

-- Qualité : plusieurs images sans clic n'émettent rien.
cmd = scenario({[1] = {"Audio"}}, 7)
aucune(cmd, "qualité : sept images sans clic, aucune commande")

-- Qualité : un clic sur un réglage émet exactement une commande.
cmd = scenario({[1] = {"Audio"}, [4] = {"Bruit d'attaque"}}, 7)
aide.egal(#cmd, 1, "qualité : un clic sur un réglage, une commande")
aide.egal(cmd[1] and cmd[1].nom, "qualite", "qualité : commande de qualité")
aide.egal(cmd[1] and cmd[1].frame, 4, "qualité : commande à l'image du clic")
if cmd[1] then
  aide.egal(cmd[1].args == nil, true, "qualité : commande compacte")
end

-- Qualité : fenêtre trop petite (rows complet) affiche l'avertissement.
cmd, ui = scenario({[1] = {"Audio"}}, 4, {largeur = 320, hauteur = 240})
local avertissement = false
for _, t in ipairs(ui.textes) do
  if t:find("Fenêtre trop petite pour les réglages audio", 1, true) then
    avertissement = true
  end
end
aide.verifie(avertissement, "qualité : 320x240 signale la fenêtre trop petite")
aucune(cmd, "qualité : fenêtre trop petite, aucune commande")

aide.termine()
