-- organum : redbean et moteur d'Aeolus dans un même exécutable. API du
-- volume général (wpctl, pactl ou amixer) et de l'orgue (module « organum »).
-- Lua 5.4 (redbean). Aucun shell n'est utilisé pour lancer les binaires.


-- Horloge monotone, en secondes (pour les délais de run).
maintenant = ->
  secondes, nanos = unix.clock_gettime unix.CLOCK_MONOTONIC
  return nil unless secondes
  secondes + nanos / 1e9

-- Les erreurs de redbean sont des objets unix.Errno, mais un appel peut
-- aussi renvoyer un simple numéro : reconnaître EINTR dans les deux cas.
est_eintr = (err) ->
  return false unless err
  if type(err) == "number"
    err == unix.EINTR
  else
    type(err) == "userdata" and err\errno! == unix.EINTR

-- Récolte un fils même si wait est interrompu par un signal : sans cela
-- un dépassement de délai pourrait laisser un zombie.
attendre = (pid) ->
  while true
    fils, statut = unix.wait pid
    return statut if fils
    return nil unless est_eintr statut

-- Exécute un binaire sans shell : pipe + fork + execve, puis lit la sortie.
-- « delai_max » (en secondes) est facultatif : sans lui, la lecture attend
-- la fin du fils ; avec lui, le fils est tué et récolté si la sortie n'est
-- pas terminée à l'échéance. Renvoie la sortie lue, le code de sortie et,
-- en cas de dépassement, un message d'erreur.
run = (bin, args, env, delai_max) ->
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
  echeance = nil
  if delai_max
    debut = maintenant!
    echeance = debut + delai_max if debut
  depasse = false
  while true
    if echeance
      restant = echeance - maintenant!
      if restant <= 0
        depasse = true
        break
      -- Attente bornée : un outil figé ne bloque pas le démarrage.
      attente = math.max 1, math.min 100, math.floor(restant * 1000)
      prets, err = unix.poll {[r]: unix.POLLIN}, attente
      unless prets
        -- Un signal (EINTR) interrompt poll : réessayer sans conclure.
        continue if est_eintr err
        depasse = true
        break
      -- Rien à lire dans le délai : boucler pour vérifier l'échéance.
      continue unless prets[r]
    chunk, err = unix.read r, 4096
    unless chunk
      continue if est_eintr err
      break
    break if #chunk == 0
    chunks[#chunks + 1] = chunk

  if depasse
    pcall unix.kill, pid, unix.SIGKILL
    attendre pid
    -- Le fils a pu écrire juste avant l'échéance : vider le tube avant de
    -- rendre la main, sinon une sortie légitime serait tronquée.
    while true
      prets = unix.poll {[r]: unix.POLLIN}, 0
      break unless prets and prets[r] and (prets[r] & unix.POLLIN) != 0
      chunk, err = unix.read r, 4096
      unless chunk
        continue if est_eintr err
        break
      break if #chunk == 0
      chunks[#chunks + 1] = chunk
    unix.close r
    return table.concat(chunks), -1, "délai de #{delai_max} s dépassé"

  unix.close r
  status = attendre pid
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

-- Délai maximal d'un outil de volume : un serveur audio figé ne doit pas
-- empêcher Organum de démarrer (le contrôle du volume est alors désactivé).
DELAI_OUTIL = 2

-- Lance un outil ; nil, erreur s'il échoue ou dépasse DELAI_OUTIL.
outil = (bin, args) ->
  sortie, code, delai = run bin, args, ENV_C, DELAI_OUTIL
  if delai
    message = "#{bin} #{table.concat args, ' '} : #{delai}, processus tué"
    Log kLogWarn, "organum : #{message}#{sortie != '' and " : #{sortie}" or ''}"
    return nil, message
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

-- Présentation partagée avec l'interface native (modele.moon).
modele = require "modele"

etat_midi = ->
  e = organum.etat!
  {
    midi: e.midi
    divisions: [{nom: d.nom, canaux: modele.liste_json modele.canaux_liste d.canaux} for d in *e.divisions]
    controle: modele.liste_json modele.canaux_liste e.canaux_controle
    expression: modele.liste_json modele.canaux_liste e.canaux_expression
    -- Activité récente, éphémère : jamais enregistrée dans midi.json.
    canaux_actifs: modele.liste_json modele.canaux_liste e.canaux_actifs
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
      organum.canaux_division i, modele.canaux_masque d.canaux if type(d) == "table" and type(d.canaux) == "table"
  organum.canaux_controle modele.canaux_masque cfg.controle if type(cfg.controle) == "table"
  organum.canaux_expression modele.canaux_masque cfg.expression if type(cfg.expression) == "table"
  if type(cfg.associations) == "table"
    ok, err = pcall organum.associations, cfg.associations
    return nil, tostring err unless ok
  true

enregistrer_midi = (cfg) ->
  dossier = CONFIG_MIDI\match "^(.*)/[^/]*$"
  unix.makedirs dossier, tonumber("755", 8) if dossier
  -- Même forme qu'etat_midi : le port et le dernier contrôle (diagnostic)
  -- ne sont pas enregistrés. Une entrée divisions malformée est ignorée.
  propre = {
    divisions: [{nom: d.nom, canaux: d.canaux} for d in *(cfg.divisions or {}) when type(d) == "table"]
    controle: cfg.controle
    expression: cfg.expression
    associations: cfg.associations
  }
  -- Fichier temporaire propre à ce processus puis renommage : le processus
  -- principal et les fils de requête peuvent enregistrer en même temps, et
  -- un lecteur ne voit jamais un midi.json à moitié écrit. Le suffixe par
  -- pid évite que deux écrivains se partagent le même temporaire.
  tmp = "#{CONFIG_MIDI}.tmp.#{unix.getpid!}"
  if Barf tmp, EncodeJson(propre), tonumber("644", 8)
    ok = pcall unix.rename, tmp, CONFIG_MIDI
    pcall unix.unlink, tmp unless ok
  else
    pcall unix.unlink, tmp
    Log kLogWarn, "organum : écriture impossible de #{tmp}"

do
  contenu = Slurp CONFIG_MIDI
  if contenu
    ok, cfg = pcall DecodeJson, contenu
    if ok
      ok2, err = appliquer_midi cfg
      Log kLogWarn, "organum : #{CONFIG_MIDI} : #{err}" unless ok2
    else
      Log kLogWarn, "organum : #{CONFIG_MIDI} illisible"

-- Interface native (Nuklear, voir fenetre.moon) dans un processus fils, à
-- côté de l'interface web, si un serveur d'affichage local est joignable.
-- ORGANUM_FENETRE=non la désactive (x11 ou wayland imposent le protocole).
-- La fenêtre fermée, organum continue ; organum arrêté, elle se ferme.
-- Lancée après les fonctions MIDI : le processus fils doit les connaître
-- pour que le panneau MIDI enregistre la configuration (midi.json).
lancer_fenetre = ->
  return if os.getenv("ORGANUM_FENETRE") == "non" or not nk or not organum.demarrer
  -- Sous Windows, un serveur X local (VcXsrv, Xming…) est essayé par défaut.
  return unless os.getenv("WAYLAND_DISPLAY") or os.getenv("DISPLAY") or GetHostOs! == "WINDOWS"
  return unless unix.fork! == 0
  maitre = unix.getppid!
  ok, err = pcall ->
    lancer = require "fenetre"
    volume = if VOLUME
      {
        lire: -> (get_state! or {}).volume
        regler: apply_volume
      }
    midi = {
      etat: etat_midi
      appliquer: appliquer_midi
      enregistrer: enregistrer_midi
    }
    ouvert, raison = lancer organum, nk, {titre: "organum", :volume, :midi, continuer: -> unix.getppid! == maitre}
    Log kLogWarn, "fenêtre : #{raison}" unless ouvert
  Log kLogWarn, "fenêtre : #{err}" unless ok
  unix.exit 0

lancer_fenetre!

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

-- 405 avec en-tête Allow : SetStatus remet le tampon d'en-têtes à zéro,
-- il doit donc être appelé avant SetHeader (voir la documentation redbean).
send_json_405 = (allow) ->
  SetStatus 405
  SetHeader "Allow", allow
  SetHeader "Content-Type", "application/json"
  Write EncodeJson {error: "méthode non autorisée"}

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
    send_json_405 "GET, POST"
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
    send_json_405 "GET"
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
    send_json_405 "GET, POST"
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

-- Ports du séquenceur, dans la forme commune aux deux interfaces :
-- champs bruts du moteur, plus « libelle » et « etat » calculés par
-- modele.moon. Séquenceur indisponible : 200 avec ports = [] (les
-- interfaces affichent simplement une liste vide) et un message journalisé.
etat_midi_ports = ->
  adresse = ""
  ok_etat, e = pcall organum.etat
  adresse = e.midi if ok_etat and type(e) == "table"
  ok, ports = pcall organum.midi_ports
  unless ok
    Log kLogWarn, "organum : ports MIDI indisponibles : #{ports}"
    return {adresse: adresse, ports: modele.liste_json {}}
  liste = for p in *ports
    p.libelle = modele.libelle_port p
    p.etat = modele.etat_port p
    p
  {adresse: adresse, ports: modele.liste_json liste}

handle_midi_ports = ->
  if GetMethod! == "GET"
    send_json 200, etat_midi_ports!
  else
    send_json_405 "GET"

-- POST /api/midi/connexion {client, port, connecte} : abonne ou désabonne
-- explicitement un port. Les bornes 0..255 sont celles d'ALSA ; 0:1 (port
-- d'annonces du système) est refusé à la déconnexion par le moteur.
handle_midi_connexion = ->
  unless GetMethod! == "POST"
    send_json_405 "POST"
    return
  ok, data = pcall DecodeJson, GetBody!
  unless ok and type(data) == "table"
    send_json 400, {error: "corps JSON invalide"}
    return
  unless is_integer(data.client) and data.client >= 0 and data.client <= 255 and
         is_integer(data.port) and data.port >= 0 and data.port <= 255
    send_json 400, {error: "client et port doivent être des entiers entre 0 et 255"}
    return
  unless type(data.connecte) == "boolean"
    send_json 400, {error: "connecte doit être un booléen"}
    return
  action = data.connecte and organum.midi_connecter or organum.midi_deconnecter
  ok, err = pcall action, data.client, data.port
  unless ok
    -- Détail dans le journal seulement : le client reçoit un message stable.
    detail = tostring err
    Log kLogWarn, "organum : #{data.connecte and 'connexion' or 'déconnexion'} MIDI #{data.client}:#{data.port} : #{detail}"
    if detail\find "non démarré", 1, true
      send_json 503, {error: "moteur indisponible"}
    else
      send_json 400, {error: "connexion MIDI impossible : adresse refusée"}
    return
  etat = etat_midi_ports!
  cible = nil
  for p in *etat.ports
    cible = p if p.client == data.client and p.port == data.port
  connecte = if cible then cible.connecte else data.connecte
  send_json 200, {
    ok: true
    connecte: connecte
    adresse: "#{data.client}:#{data.port}"
    port: cible
    ports: etat.ports
  }

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
    send_json_405 "GET, POST"

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
  elseif path == "/api/midi/ports"
    handle_midi_ports!
  elseif path == "/api/midi/connexion"
    handle_midi_connexion!
  elseif path == "/api/midi" or path == "/api/midi/"
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