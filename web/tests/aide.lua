-- Petit assistant d'assertions pour les tests unitaires (aucune dépendance).
local M = {total = 0, echecs = 0}

function M.verifie(condition, nom, detail)
  M.total = M.total + 1
  if condition then
    print("OK    : " .. nom)
  else
    M.echecs = M.echecs + 1
    local fin = detail ~= nil and (" (" .. tostring(detail) .. ")") or ""
    print("ÉCHEC : " .. nom .. fin)
  end
end

function M.egal(obtenu, attendu, nom)
  M.verifie(obtenu == attendu, nom,
    "attendu " .. tostring(attendu) .. ", obtenu " .. tostring(obtenu))
end

function M.presque(obtenu, attendu, epsilon, nom)
  local ok = type(obtenu) == "number" and
    math.abs(obtenu - attendu) <= (epsilon or 1e-9)
  M.verifie(ok, nom, "attendu " .. tostring(attendu) .. " ± " ..
    tostring(epsilon or 1e-9) .. ", obtenu " .. tostring(obtenu))
end

function M.entre(valeur, min, max, nom)
  M.verifie(type(valeur) == "number" and valeur >= min and valeur <= max, nom,
    tostring(valeur) .. " hors [" .. tostring(min) .. ", " .. tostring(max) .. "]")
end

function M.echoue(fn, nom)
  local ok = pcall(fn)
  M.verifie(not ok, nom, "aucune erreur levée")
end

function M.termine()
  print(string.format("-- %d test(s), %d échec(s)", M.total, M.echecs))
  os.exit(M.echecs == 0 and 0 or 1)
end

return M
