-- Règle pure de l'axe MIDI, distinct de l'axe audio (SANS_BACKEND).
-- Le MIDI est actif quand un backend existe pour la plate-forme, sauf
-- ORGANUM_SANS_BACKEND=1 qui force le mode dégradé (valeur exacte 1, comme
-- degradation.moon). Un backend socket imposé (ORGANUM_MIDI_SOCKET non vide)
-- garde le MIDI actif sous ce forçage : c'est le cas d'un Mac sans audio et
-- celui des tests Linux qui simulent l'assistant CoreMIDI.

actif = (supportee, force, socket) ->
  supportee == true and (force != "1" or socket == true)

-- Backend socket effectivement choisi par l'aiguillage de plateforme/midi.c :
-- sous macOS (IsXnu()), ou sous Linux quand ORGANUM_MIDI_SOCKET l'impose.
-- Windows garde toujours WinMM, même si la variable est posée. Sert à
-- /api/midi/ports : sans backend socket, il n'y a aucun assistant à lancer.
socket_actif = (plateforme, imposee) ->
  plateforme == "macos" or (imposee == true and plateforme != "windows")

-- Message d'état de l'axe MIDI, distinct du message de liste vide de
-- modele.message_ports_vide (qui ne parle que des ports). Un backend absent
-- ou coupé est annoncé ; un backend socket sans assistant l'est aussi, car
-- aucun port ne peut alors apparaître. Sinon nil : le MIDI fonctionne, ou
-- utilise ALSA/WinMM sans assistant à lancer.
message = (disponible, assistant, socket) ->
  if disponible != true
    "MIDI désactivé sur cette plate-forme."
  elseif socket == true and assistant == false
    "Assistant MIDI absent : lancez organum-midi (voir plateforme/macos/LANCEMENT.md)."
  else
    nil

{ :actif, :socket_actif, :message }
