-- Règle pure de l'axe MIDI, distinct de l'axe audio (SANS_BACKEND).
-- Le MIDI est actif quand un backend existe pour la plate-forme, sauf
-- ORGANUM_SANS_BACKEND=1 qui force le mode dégradé (valeur exacte 1, comme
-- degradation.moon). Un backend socket imposé (ORGANUM_MIDI_SOCKET non vide)
-- garde le MIDI actif sous ce forçage : c'est le cas d'un Mac sans audio et
-- celui des tests Linux qui simulent l'assistant CoreMIDI.

actif = (supportee, force, socket) ->
  supportee == true and (force != "1" or socket == true)

{ :actif }
