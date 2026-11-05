package.path = (os.getenv("UNIT_LUA_PATH") or "") .. ";" .. package.path
local dossier = os.getenv("JS_DIR") or "/tmp"

local function ecrire(nom, contenu)
  local f = assert(io.open(dossier .. "/" .. nom, "wb"))
  f:write(contenu)
  f:close()
end

local client = require "client"
ecrire("client.js", client)

local function scripts(nom, html)
  local n = 0
  for contenu in html:gmatch("<script>(.-)</script>") do
    n = n + 1
    ecrire(nom .. "-" .. n .. ".js", contenu)
  end
  print(string.format("-- %s : %d script(s)", nom, n))
end

local page = require "page"
local divisions = {
  {name = "Pedal", gain = 0.5, links = {},
   stops = {{name = "Bourdon 16", on = true}}},
}
scripts("page", page(divisions, 4))

local page_midi = require "page_midi"
scripts("page_midi", page_midi())

local page_audio = require "page_audio"
scripts("page_audio", page_audio())
