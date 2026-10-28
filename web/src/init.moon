-- organum : redbean et moteur d'Aeolus dans un même exécutable. API du
-- volume général (wpctl, pactl ou amixer) et de l'orgue (module « organum »).
-- Lua 5.4 (redbean). Aucun shell n'est utilisé pour lancer les binaires.


-- Exécute un binaire sans shell : pipe + fork + execve, puis lit la sortie.
run = (bin, args, env) ->
  r, w = unix.pipe!
  unless r and w
    return nil, "unix.pipe a échoué"

  pid = unix.fork!
  unless pid
    unix.close r
    unix.close w
    return nil, "unix.fork a échoué"

  if pid == 0
    unix.close r
    unix.close 1
    unix.dup w
    unix.close 2
    unix.dup w
    unix.close w
    argv = {bin}
    for a in *args
      argv[#argv + 1] = a
    e = env or unix.environ!
    pcall unix.execve, bin, argv, e
    unix.exit 127

  unix.close w
  chunks = {}
  while true
    chunk = unix.read r, 4096
    break unless chunk
    break if #chunk == 0
    chunks[#chunks + 1] = chunk
  unix.close r

  _, status = unix.wait pid
  output = table.concat chunks
  code = -1
  if status
    code = unix.WEXITSTATUS status
  return output, code

-- Volume général : le premier outil disponible parmi wpctl (PipeWire),
-- pactl (PulseAudio, ou PipeWire par pipewire-pulse) et amixer (ALSA seul).
-- ORGANUM_VOLUME=wpctl|pactl|amixer impose le choix ; avec amixer, la
-- commande ALSA est ORGANUM_AMIXER_CONTROLE (Master par défaut).
borner = (v) -> math.max 0, math.min 100, math.floor(v + 0.5)

-- Sortie en anglais et en point décimal, quelle que soit la langue.
ENV_C = do
  env = [e for e in *unix.environ! when not e\match "^LC_ALL="]
  env[#env + 1] = "LC_ALL=C"
  env

-- Lance un outil ; nil, erreur s'il échoue.
outil = (bin, args) ->
  sortie, code = run bin, args, ENV_C
  return sortie if code == 0
  nil, "#{bin} #{table.concat args, ' '} a échoué (code #{code}) : #{sortie}"

trouver = (nom) ->
  for dossier in ((os.getenv("PATH") or "") .. ":/usr/bin:/bin:/usr/local/bin")\gmatch "[^:]+"
    chemin = "#{dossier}/#{nom}"
    return chemin if unix.stat chemin
  nil

CONTROLE_ALSA = os.getenv("ORGANUM_AMIXER_CONTROLE") or "Master"

OUTILS_VOLUME = {
  {
    nom: "wpctl"
    lire: (bin) ->
      sortie, err = outil bin, {"get-volume", "@DEFAULT_AUDIO_SINK@"}
      return nil, err unless sortie
      v = tonumber sortie\match "Volume:%s*([%d%.]+)"
      return nil, "sortie de wpctl illisible : #{sortie}" unless v
      {volume: borner(v * 100), muted: sortie\find("%[MUTED%]") != nil}
    regler: (bin, v) -> outil bin, {"set-volume", "@DEFAULT_AUDIO_SINK@", string.format("%.2f", v / 100)}
    couper: (bin, oui) -> outil bin, {"set-mute", "@DEFAULT_AUDIO_SINK@", oui and "1" or "0"}
  }
  {
    nom: "pactl"
    lire: (bin) ->
      sortie, err = outil bin, {"get-sink-volume", "@DEFAULT_SINK@"}
      return nil, err unless sortie
      v = tonumber sortie\match "(%d+)%%"
      return nil, "sortie de pactl illisible : #{sortie}" unless v
      muet, err2 = outil bin, {"get-sink-mute", "@DEFAULT_SINK@"}
      return nil, err2 unless muet
      {volume: borner(v), muted: muet\match("Mute:%s*yes") != nil}
    regler: (bin, v) -> outil bin, {"set-sink-volume", "@DEFAULT_SINK@", "#{v}%"}
    couper: (bin, oui) -> outil bin, {"set-sink-mute", "@DEFAULT_SINK@", oui and "1" or "0"}
  }
  {
    nom: "amixer"
    lire: (bin) ->
      sortie, err = outil bin, {"get", CONTROLE_ALSA}
      return nil, err unless sortie
      v = tonumber sortie\match "%[(%d+)%%%]"
      return nil, "sortie d'amixer illisible : #{sortie}" unless v
      {volume: borner(v), muted: sortie\find("%[off%]") != nil}
    regler: (bin, v) -> outil bin, {"sset", CONTROLE_ALSA, "#{v}%"}
    couper: (bin, oui) -> outil bin, {"sset", CONTROLE_ALSA, oui and "mute" or "unmute"}
  }
}

-- Choisi une fois, dans le processus principal ; hérité par les requêtes.
VOLUME = do
  impose = os.getenv "ORGANUM_VOLUME"
  choix = nil
  for o in *OUTILS_VOLUME
    continue if impose and impose != "" and o.nom != impose
    bin = trouver o.nom
    if bin and o.lire bin
      choix = {outil: o, bin: bin}
      break
  Log kLogWarn, "organum : aucun outil de volume (wpctl, pactl, amixer)" unless choix
  choix

get_state = ->
  return nil, "aucun outil de volume (wpctl, pactl, amixer)" unless VOLUME
  etat, err = VOLUME.outil.lire VOLUME.bin
  return nil, err unless etat
  etat.outil = VOLUME.outil.nom
  etat

apply_volume = (v) ->
  return nil, "aucun outil de volume" unless VOLUME
  v = borner v
  ok, err = VOLUME.outil.regler VOLUME.bin, v
  return nil, err unless ok
  v

apply_mute = (muted) ->
  return nil, "aucun outil de volume" unless VOLUME
  ok, err = VOLUME.outil.couper VOLUME.bin, muted
  return nil, err unless ok
  true

-- Orgue : le moteur tourne dans le processus principal (fil audio), lancé
-- ici, avant que redbean ne crée les processus de requêtes.
entier_env = (nom, defaut) -> math.tointeger(tonumber os.getenv nom) or defaut

-- État de l'orgue d'un lancement à l'autre : celui du moteur (jeux,
-- accouplements, combinaisons) plus le volume, la réverbération et le gain
-- des claviers, qui n'en font pas partie.
ETAT_FICHIER = os.getenv("ORGANUM_ETAT") or "#{os.getenv 'HOME'}/.config/organum/etat.json"

-- cosmo_dlopen (pour libasound) a besoin d'un petit programme d'aide lié à
-- la libc du système ; faute de l'y trouver, il le compile avec cc. On
-- installe celui qu'embarque organum, sans compilateur : pour la glibc, lié
-- aux plus anciennes versions de ses symboles (il convient à toute glibc),
-- sinon pour musl. La glibc d'abord : c'est elle qui accompagne libasound
-- quand les deux chargeurs sont présents.
installer_aide = ->
  libc = if unix.stat "/lib64/ld-linux-x86-64.so.2" then "glibc"
  elseif unix.stat "/lib/ld-musl-x86_64.so.1" then "musl"
  return unless libc
  base = os.getenv "TMPDIR"
  base = os.getenv "HOME" if not base or base == ""
  dossier = "#{base}/.cosmo"
  return if unix.stat "#{dossier}/dlopen-helper"
  unix.makedirs dossier, tonumber("755", 8)
  aide, source = Slurp("/zip/.cosmo/dlopen-helper-#{libc}-x86_64"), Slurp("/zip/.cosmo/dlopen-helper.c")
  return unless aide and source
  Barf "#{dossier}/dlopen-helper.c", source, tonumber("644", 8)
  Barf "#{dossier}/dlopen-helper", aide, tonumber("755", 8)

installer_aide!

etat_sauve = do
  contenu = Slurp ETAT_FICHIER
  ok, e = pcall DecodeJson, contenu if contenu
  ok and type(e) == "table" and e or {}

if organum.demarrer
  ok, err = organum.demarrer {
    taux: entier_env "ORGANUM_TAUX", 48000
    periode: entier_env "ORGANUM_PERIODE", 512
    peripherique: os.getenv "ORGANUM_PERIPHERIQUE"
    etat: type(etat_sauve.moteur) == "string" and etat_sauve.moteur or nil
  }
  unless ok
    Log kLogFatal, "organum : #{err}"
    unix.exit 1
  organum.volume etat_sauve.volume if type(etat_sauve.volume) == "number"
  organum.reverb etat_sauve.reverb if type(etat_sauve.reverb) == "number"
  if type(etat_sauve.gains) == "table"
    for i, g in ipairs etat_sauve.gains
      organum.gain i, g if type(g) == "number" and i <= #organum.etat!.divisions

-- Sauvegarde, dans le processus principal (seul à accéder au moteur), dès
-- que l'état a changé ; redbean appelle ce crochet régulièrement.
seq_sauve = nil
sauvegarder_etat = ->
  e = organum.etat!
  return if e.seq == seq_sauve
  seq_sauve = e.seq
  dossier = ETAT_FICHIER\match "^(.*)/[^/]*$"
  unix.makedirs dossier, tonumber("755", 8) if dossier
  contenu = EncodeJson {
    moteur: organum.sauvegarder!
    volume: e.volume, reverb: e.reverb
    gains: [d.gain for d in *e.divisions]
  }
  -- Fichier temporaire puis renommage : jamais de sauvegarde à moitié écrite.
  if Barf "#{ETAT_FICHIER}.tmp", contenu, tonumber("644", 8)
    unix.rename "#{ETAT_FICHIER}.tmp", ETAT_FICHIER

_G.OnServerHeartbeat = ->
  pcall sauvegarder_etat
  return
ProgramHeartbeatInterval 2000

-- Identifiant de ce lancement : un client qui le voit changer recharge la
-- page (la structure de l'orgue a pu changer).
INSTANCE = "#{unix.getpid!}-#{os.time!}"
NB_ETAPES = 32

-- Associations MIDI : canaux de chaque clavier, du contrôle (jeux,
-- combinaisons) et de l'expression ; contrôleurs (CC) vers des réglages.
-- Les masques de 16 bits du moteur sont présentés comme des listes de
-- canaux 1-16. La configuration est enregistrée et réappliquée au démarrage.
CONFIG_MIDI = os.getenv("ORGANUM_CONFIG_MIDI") or "#{os.getenv 'HOME'}/.config/organum/midi.json"

canaux_liste = (masque) -> [c for c = 1, 16 when (masque >> (c - 1)) & 1 == 1]

canaux_masque = (liste) ->
  m = 0
  for c in *liste
    m |= 1 << (c - 1) if math.type(c) == "integer" and c >= 1 and c <= 16
  m

etat_midi = ->
  e = organum.etat!
  {
    midi: e.midi
    divisions: [{nom: d.nom, canaux: canaux_liste d.canaux} for d in *e.divisions]
    controle: canaux_liste e.canaux_controle
    expression: canaux_liste e.canaux_expression
    associations: e.associations
    dernier_controle: e.dernier_controle
  }

-- Applique une configuration (même forme que etat_midi, champs facultatifs) ;
-- renvoie nil, erreur si elle est invalide.
appliquer_midi = (cfg) ->
  return nil, "configuration invalide" unless type(cfg) == "table"
  nb = #organum.etat!.divisions
  if type(cfg.divisions) == "table"
    for i, d in ipairs cfg.divisions
      break if i > nb
      organum.canaux_division i, canaux_masque d.canaux if type(d) == "table" and type(d.canaux) == "table"
  organum.canaux_controle canaux_masque cfg.controle if type(cfg.controle) == "table"
  organum.canaux_expression canaux_masque cfg.expression if type(cfg.expression) == "table"
  if type(cfg.associations) == "table"
    ok, err = pcall organum.associations, cfg.associations
    return nil, tostring err unless ok
  true

enregistrer_midi = (cfg) ->
  dossier = CONFIG_MIDI\match "^(.*)/[^/]*$"
  unix.makedirs dossier, tonumber("755", 8) if dossier
  Barf CONFIG_MIDI, EncodeJson(cfg), tonumber("644", 8)

do
  contenu = Slurp CONFIG_MIDI
  if contenu
    ok, cfg = pcall DecodeJson, contenu
    if ok
      ok2, err = appliquer_midi cfg
      Log kLogWarn, "organum : #{CONFIG_MIDI} : #{err}" unless ok2
    else
      Log kLogWarn, "organum : #{CONFIG_MIDI} illisible"

-- État au format du socket d'Aeolus (PROTOCOLE-SOCKET.md), que le client
-- connaît déjà ; les divisions et jeux y sont indexés à partir de 0.
etat_orgue = ->
  e = organum.etat!
  {
    source: "aeolus", instance: INSTANCE, seq: e.seq, step: e.etape, steps: e.netapes
    volume: e.volume, reverb: e.reverb, xruns: e.xruns, midi: e.midi, temps_reel: e.temps_reel
    divisions: for d in *e.divisions
      {
        name: d.nom, gain: d.gain
        links: [{division: l.division - 1, on: l.actif} for l in *d.liens]
        stops: [{name: j.nom\gsub("\n", " "), on: j.actif} for j in *d.jeux]
      }
  }

is_finite_number = (v) ->
  type(v) == "number" and v == v and v != math.huge and v != -math.huge

is_integer = (v) ->
  is_finite_number(v) and v == math.floor(v)

send_json = (status, payload) ->
  SetStatus status
  SetHeader "Content-Type", "application/json"
  Write EncodeJson payload

handle_volume = ->
  method = GetMethod!

  if method == "GET"
    state, err = get_state!
    unless state
      send_json 500, {error: err}
      return
    send_json 200, state
    return

  unless method == "POST"
    SetHeader "Allow", "GET, POST"
    send_json 405, {error: "méthode non autorisée"}
    return

  body = GetBody!
  ok, data = pcall DecodeJson, body
  unless ok and type(data) == "table"
    send_json 400, {error: "corps JSON invalide"}
    return

  has_field = false
  volume = nil
  delta = nil
  muted = nil

  if data.volume != nil
    unless is_finite_number data.volume
      send_json 400, {error: "volume doit être un nombre"}
      return
    volume = data.volume
    has_field = true

  if data.delta != nil
    unless is_finite_number data.delta
      send_json 400, {error: "delta doit être un nombre"}
      return
    delta = data.delta
    has_field = true

  if data.muted != nil
    unless type(data.muted) == "boolean"
      send_json 400, {error: "muted doit être un booléen"}
      return
    muted = data.muted
    has_field = true

  unless has_field
    send_json 400, {error: "aucun champ valide (volume, delta ou muted)"}
    return

  if volume != nil
    applied, err = apply_volume volume
    unless applied
      send_json 500, {error: err}
      return

  if delta != nil
    current, err = get_state!
    unless current
      send_json 500, {error: err}
      return
    applied, err = apply_volume current.volume + delta
    unless applied
      send_json 500, {error: err}
      return

  if muted != nil
    okm, err = apply_mute muted
    unless okm
      send_json 500, {error: err}
      return

  state, err = get_state!
  unless state
    send_json 500, {error: err}
    return
  send_json 200, state


handle_orgue_attendre = ->
  unless GetMethod! == "GET"
    SetHeader "Allow", "GET"
    send_json 405, {error: "méthode non autorisée"}
    return
  seq = math.tointeger tonumber GetParam "seq"
  if GetParam("instance") == INSTANCE and seq
    max_s = tonumber(os.getenv "ORGUE_ATTENTE_MAX") or 25
    if organum.attendre(seq, math.floor max_s * 1000) == seq
      SetStatus 204
      return
  send_json 200, etat_orgue!

handle_orgue = ->
  method = GetMethod!
  if method == "GET"
    send_json 200, etat_orgue!
    return

  unless method == "POST"
    SetHeader "Allow", "GET, POST"
    send_json 405, {error: "méthode non autorisée"}
    return

  ok, data = pcall DecodeJson, GetBody!
  unless ok and type(data) == "table"
    send_json 400, {error: "corps JSON invalide"}
    return

  actions = {stop: true, cancel: true, step: true, reverb: true, panic: true, gain: true, link: true}
  n = 0
  for k in pairs data
    unless actions[k]
      send_json 400, {error: "champ inconnu : #{k}"}
      return
    n += 1
  unless n == 1
    send_json 400, {error: "une seule action attendue"}
    return

  divisions = organum.etat!.divisions
  division_valide = (d) -> is_integer(d) and d >= 0 and d < #divisions

  if st = data.stop
    unless type(st) == "table" and division_valide(st.division) and is_integer(st.index) and type(st.on) == "boolean"
      send_json 400, {error: "stop invalide"}
      return
    unless st.index >= 0 and st.index < #divisions[st.division + 1].jeux
      send_json 400, {error: "jeu hors limites"}
      return
    organum.jeu st.division + 1, st.index + 1, st.on

  elseif l = data.link
    unless type(l) == "table" and division_valide(l.division) and is_integer(l.index) and type(l.on) == "boolean"
      send_json 400, {error: "link invalide"}
      return
    unless l.index >= 0 and l.index < #divisions[l.division + 1].liens
      send_json 400, {error: "accouplement hors limites"}
      return
    organum.lien l.division + 1, l.index + 1, l.on

  elseif data.cancel != nil
    unless division_valide data.cancel
      send_json 400, {error: "division hors limites"}
      return
    for j = 1, #divisions[data.cancel + 1].jeux
      organum.jeu data.cancel + 1, j, false

  elseif data.step != nil
    unless is_integer(data.step) and data.step >= 0 and data.step < NB_ETAPES
      send_json 400, {error: "step hors limites"}
      return
    organum.midi 0xCF, data.step  -- Program Change, canal de contrôle 16

  elseif data.reverb != nil
    unless is_integer(data.reverb) and data.reverb >= 0 and data.reverb <= 127
      send_json 400, {error: "reverb hors limites"}
      return
    organum.reverb data.reverb / 127

  elseif g = data.gain
    unless type(g) == "table" and division_valide(g.division) and is_finite_number(g.value) and g.value >= 0 and g.value <= 1
      send_json 400, {error: "gain invalide"}
      return
    organum.gain g.division + 1, g.value

  elseif data.panic == true
    organum.panique!

  else
    send_json 400, {error: "panic doit être true"}
    return

  send_json 200, {ok: true}

handle_midi = ->
  method = GetMethod!
  if method == "POST"
    ok, cfg = pcall DecodeJson, GetBody!
    unless ok and type(cfg) == "table"
      send_json 400, {error: "corps JSON invalide"}
      return
    ok, err = appliquer_midi cfg
    unless ok
      send_json 400, {error: err}
      return
    -- On enregistre la configuration telle que demandée : l'état publié
    -- par le fil audio ne la reflète qu'au tour suivant.
    actuel = etat_midi!
    for k in *{"controle", "expression", "associations"}
      actuel[k] = cfg[k] if cfg[k] != nil
    if type(cfg.divisions) == "table"
      for i, d in ipairs cfg.divisions
        actuel.divisions[i].canaux = d.canaux if actuel.divisions[i] and type(d) == "table" and type(d.canaux) == "table"
    enregistrer_midi {divisions: actuel.divisions, controle: actuel.controle, expression: actuel.expression, associations: actuel.associations}
    send_json 200, actuel
  elseif method == "GET"
    send_json 200, etat_midi!
  else
    SetHeader "Allow", "GET, POST"
    send_json 405, {error: "méthode non autorisée"}

page_midi = require "page_midi"

page = require "page"

-- Divisions (et nombre de combinaisons) affichées : celles publiées par Aeolus (noms et état réels),
-- sinon la table de repli d'orgue.moon (état inconnu).

divisions_page = ->
  e = etat_orgue!
  e.divisions, e.steps

_G.OnHttpRequest = ->
  path = GetPath!
  if path == "/api/volume"
    handle_volume!
  elseif path == "/api/orgue/attendre"
    handle_orgue_attendre!
  elseif path == "/api/orgue"
    handle_orgue!
  elseif path == "/api/midi"
    handle_midi!
  elseif path == "/midi"
    SetStatus 200
    SetHeader "Content-Type", "text/html; charset=utf-8"
    Write page_midi!
  elseif path == "/"
    SetStatus 200
    SetHeader "Content-Type", "text/html; charset=utf-8"
    Write page divisions_page!
  else
    Route!