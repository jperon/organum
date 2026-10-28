local ui, err = nk.ouvrir("organum (essai)", 560, 360, 22)
if not ui then print(err); os.exit(1) end
local jeux = {false, false, false, false}
local volume = 0.5
local noms = {"Bourdon 8", "Prestant 4", "Doublette 2", "Trompette 8"}
while true do
  local continuer, sale = ui:evenements(50)
  if not continuer then break end
  if not sale then goto suite end
  if ui:debut("Orgue", 0, 0, ui:taille()) then
    ui:ligne(40, 4)
    for i = 1, 4 do
      local nv = ui:choix(noms[i], jeux[i])
      if nv ~= jeux[i] then jeux[i] = nv; print(noms[i], nv) end
    end
    ui:ligne(30, 1)
    ui:texte("Volume", "gauche")
    local nv = ui:curseur(volume, 0, 1, 0.01)
    if nv ~= volume then volume = nv; print("volume", volume) end
    ui:ligne(40, 1)
    if ui:bouton("Panique") then print("panique") end
  end
  ui:fin()
  ui:dessiner(30, 30, 30)
  ::suite::
end
print("fermeture")
