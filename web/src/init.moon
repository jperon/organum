-- organum : redbean et moteur d'Aeolus dans un même exécutable. API du
-- volume général (wpctl, pactl ou amixer) et de l'orgue (module « organum »).
-- Lua 5.4 (redbean). Aucun shell n'est utilisé pour lancer les binaires.

-- Validations et fusions pures, partagées avec les tests unitaires.
validation = require "validation"
calibration = require "calibration"
authentification = require "authentification"
controle_acces = require "controle_acces"
degradation = require "degradation"
midi_actif = require "midi_actif"
assistant = require "assistant"

-- Plate-forme et mode dégradé : décidés une fois au démarrage.
PLATEFORME = if type(organum.plateforme) == "function" then organum.plateforme! else "autre"
-- C'est le backend natif qui fait foi, plus le seul nom de plate-forme :
-- macOS a désormais un backend audio socket (assistant CoreAudio).
AUDIO_SUPPORTEE = if type(organum.audio_supportee) == "function" then organum.audio_supportee! else nil
SANS_BACKEND, RAISON_SANS_BACKEND = degradation.detecter PLATEFORME, os.getenv("ORGANUM_SANS_BACKEND"), AUDIO_SUPPORTEE
-- macOS démarre sans assistant audio : l'échec d'ouverture n'est pas fatal et
-- la boucle de réessai périodique reste active. Absent : comportement strict.
-- Sous Linux, ORGANUM_AUDIO_SOCKET force le backend socket pour les tests :
-- ce forçage simule macOS et doit donc rendre le démarrage opportuniste, sinon
-- le cas « assistant absent » ne serait pas testable sans carte son.
AUDIO_SOCKET_IMPOSE = type(organum.audio_socket_imposee) == "function" and organum.audio_socket_imposee!
AUDIO_OPPORTUNISTE = PLATEFORME == "macos" or AUDIO_SOCKET_IMPOSE == true

-- Axe MIDI, distinct de l'axe audio : le MIDI socket macOS existe même sans
-- audio. ORGANUM_SANS_BACKEND=1 coupe le MIDI sauf si ORGANUM_MIDI_SOCKET
-- impose explicitement le backend socket (simulation Linux, cas macOS).
midi_supportee = type(organum.midi_supportee) == "function" and organum.midi_supportee!
midi_socket = type(organum.midi_socket_imposee) == "function" and organum.midi_socket_imposee!
MIDI_ACTIF = midi_actif.actif midi_supportee, os.getenv("ORGANUM_SANS_BACKEND"), midi_socket
-- Backend socket réellement retenu (macOS, ou forçage Linux) : lui seul a un
-- assistant à lancer. Publié par /api/midi/ports pour la page /midi.
MIDI_SOCKET = midi_actif.socket_actif PLATEFORME, midi_socket

-- Assistant natif macOS géré par organum (extrait du zip et lancé plus bas).
-- nil hors macOS, ou quand aucun axe socket n'a besoin de lui.
HELPER = nil

-- Message de l'axe MIDI pour le bandeau de la page d'orgue. Même règle pure
-- que la page /midi, mais état de l'assistant lu ici : le bandeau n'a pas
-- besoin d'attendre /api/midi/ports.
message_midi_courant = ->
  assistant = false
  if type(organum.midi_assistant) == "function"
    ok, valeur = pcall organum.midi_assistant
    assistant = ok and valeur == 1
  etat = HELPER and HELPER.etat
  log = HELPER and HELPER.log
  midi_actif.message MIDI_ACTIF, assistant, MIDI_SOCKET, etat, log

-- Écoute : redbean, sans adresse explicite (-l), ne programme que 0.0.0.0
-- (tool/net/redbean.c, Listen) ; on ajoute « :: » pour répondre aussi en
-- IPv6. Un -l explicite reste seul appliqué : les arguments réels du
-- processus sont lus par organum.arguments() (__argc/__argv de la libc),
-- qui fonctionne aussi sous macOS où /proc n'existe pas ; à défaut, on
-- retombe sur /proc/self/cmdline (Windows n'en a pas).
-- redbean pose IPV6_V6ONLY, les deux écoutes coexistent sur le même port.
a_un_l = ->
  args = {}
  if type(organum.arguments) == "function"
    args = organum.arguments!
  else
    fd = unix.open "/proc/self/cmdline", unix.O_RDONLY
    return false unless type(fd) == "number" and fd >= 0
    contenu = unix.read fd, 65536
    unix.close fd
    return false unless type(contenu) == "string"
    for morceau in contenu\gmatch "[^%z]+"
      table.insert args, morceau
  for morceau in *args
    return true if morceau == "-l" or (morceau\sub(1, 2) == "-l" and #morceau > 2)
  false

-- Créer puis lier une socket IPv6 sur :: (port 0) dit si la pile IPv6 est
-- utilisable ; la socket est refermée aussitôt. Sinon, on se replie sur IPv4.
ipv6_disponible = ->
  fd = unix.socket unix.AF_INET6, unix.SOCK_STREAM
  return false unless fd
  possible = unix.bind fd, 0, 0
  unix.close fd
  possible and true or false

do
  unless a_un_l!
    ProgramAddr "::" if ipv6_disponible!
    ProgramAddr "0.0.0.0"

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
    -- Le fils ne doit pas garder le PCM hérité pendant l'exécution de
    -- l'outil externe (il retarderait une reconfiguration audio).
    pcall organum.oublier_audio if organum and organum.oublier_audio
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

-- Réglages de qualité (spécification §1 et §3). Le moteur publie les quatre
-- champs à chaud ; niveau (présélection), auto et tete_reverb (démarrage
-- seulement) sont tenus à part dans un petit fichier voisin, car les
-- processus de requête sont des fils séparés : c'est ce fichier qui les
-- rend visibles à tous, et le processus principal le recopie dans etat.json.
QUALITE_FICHIER = "#{ETAT_FICHIER}.qualite.json"

PRESELECTIONS = {
  {spatialisation: 0, bruit_attaque: false, instabilite: false, polyphonie_max: 64, tete_reverb: false}
  {spatialisation: 1, bruit_attaque: false, instabilite: false, polyphonie_max: 128, tete_reverb: false}
  {spatialisation: 1, bruit_attaque: true, instabilite: true, polyphonie_max: 192, tete_reverb: true}
  {spatialisation: 2, bruit_attaque: true, instabilite: true, polyphonie_max: 0, tete_reverb: true}
}

-- Réglages de démarrage (période et taux d'échantillonnage, périphérique
-- audio, limiteur) : eux aussi mémorisés, mais sans faire partie des
-- présélections. Les valeurs effectives du lancement en cours sont tenues à
-- part (EFFECTIF) ; les valeurs enregistrées vivent dans QUALITE_FICHIER.
TAUX_VALIDES = validation.TAUX_VALIDES
PERIODES_VALIDES = validation.PERIODES_VALIDES
DEMARRAGE_DEFAUT = validation.DEMARRAGE_DEFAUT

entier_borne = validation.entier_borne
peripherique_valide = validation.peripherique_valide

-- Au premier lancement (etat.json sans clé qualite), le mode automatique est
-- actif : la calibration choisit le niveau. Un réglage manuel sauvegardé met
-- auto à faux et empêche toute recalibration au démarrage suivant.
qualite_locale = {
  niveau: -1, auto: false, tete_reverb: true
  periode: DEMARRAGE_DEFAUT.periode
  taux: DEMARRAGE_DEFAUT.taux
  peripherique: DEMARRAGE_DEFAUT.peripherique
  limiteur: DEMARRAGE_DEFAUT.limiteur
}

niveau_correspondant = (q, tete) ->
  for i, p in ipairs PRESELECTIONS
    meme_spatialisation = p.spatialisation == q.spatialisation
    meme_bruit = p.bruit_attaque == (q.bruit_attaque and true)
    meme_instabilite = p.instabilite == (q.instabilite and true)
    meme_polyphonie = p.polyphonie_max == q.polyphonie_max
    meme_tete = p.tete_reverb == tete
    if meme_spatialisation and meme_bruit and meme_instabilite and meme_polyphonie and meme_tete
      return i - 1
  -1

qualite_fichier = (chemin) ->
  contenu = Slurp chemin
  return nil unless contenu
  ok, q = pcall DecodeJson, contenu
  ok and type(q) == "table" and q or nil

ecrire_qualite_locale = (q) ->
  dossier = QUALITE_FICHIER\match "^(.*)/[^/]*$"
  unix.makedirs dossier, tonumber("755", 8) if dossier
  tmp = "#{QUALITE_FICHIER}.tmp.#{unix.getpid!}"
  if Barf tmp, EncodeJson(q), tonumber("644", 8)
    ok = pcall unix.rename, tmp, QUALITE_FICHIER
    pcall unix.unlink, tmp unless ok
  else
    pcall unix.unlink, tmp

-- Valeur courante côté Lua : le fichier d'abord (écrit par les processus de
-- requête), à défaut la copie du processus principal.
qualite_locale_actuelle = ->
  validation.qualite_fichier_normalisee qualite_fichier(QUALITE_FICHIER), qualite_locale

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

-- Assistant natif macOS (CoreMIDI et CoreAudio) embarqué dans
-- /zip/.organum/organum-helper. On l'installe dans un dossier stable par
-- utilisateur puis on le lance dans notre groupe de processus, pour qu'il
-- meure avec organum (SIGTERM de redbean). Un assistant déjà vivant (lancement
-- manuel ou LaunchAgent) est réutilisé : on sonde les sockets avant de lancer.
-- L'extraction et le lancement ne sont jamais fatals : l'état publié dit ce
-- qui manque, et l'orgue démarre quand même.
assistant_vivant = ->
  return false unless HELPER
  -- Le moteur voit déjà l'assistant : inutile de sonder, et une connexion
  -- audio sonde bloquerait sa poignée de main.
  for nom in *{"audio_assistant", "midi_assistant"}
    if type(organum[nom]) == "function"
      ok, valeur = pcall organum[nom]
      return true if ok and valeur == 1
  -- Le MIDI d'abord : une connexion sonde y est brève. L'audio n'est sondé
  -- que sans MIDI, et jamais quand le moteur y est déjà connecté (le helper
  -- attendrait notre poignée de main en bloquant sa boucle).
  midi = HELPER.midi
  if midi and unix.stat midi
    fd = unix.socket unix.AF_UNIX, unix.SOCK_STREAM
    if fd
      ok = unix.connect fd, midi
      unix.close fd
      return true if ok
  audio_connecte = false
  if type(organum.audio_assistant) == "function"
    ok, valeur = pcall organum.audio_assistant
    audio_connecte = ok and valeur == 1
  audio = HELPER.audio
  if not audio_connecte and audio and unix.stat audio
    fd = unix.socket unix.AF_UNIX, unix.SOCK_STREAM
    if fd
      ok = unix.connect fd, audio
      unix.close fd
      return true if ok
  false

lancer_assistant = ->
  return unless HELPER and HELPER.chemin
  unless unix.access HELPER.chemin, unix.X_OK
    HELPER.etat = "lancement_impossible"
    Log kLogWarn, "organum : assistant natif macOS non exécutable : #{HELPER.chemin}"
    return
  fd = unix.open HELPER.log, unix.O_WRONLY | unix.O_CREAT | unix.O_TRUNC, tonumber("600", 8)
  -- --verbose seulement sur un drapeau de débogage : le journal ordinaire
  -- reste court, même si le helper explique toujours ses échecs.
  verbose = os.getenv("ORGANUM_ASSISTANT_VERBOSE") == "1"
  pid = unix.fork!
  unless pid
    pcall unix.close, fd if fd
    HELPER.etat = "lancement_impossible"
    Log kLogWarn, "organum : fork de l'assistant natif macOS impossible"
    return
  if pid == 0
    -- Le fils ne garde pas le PCM hérité (il retarderait une reconfiguration).
    pcall organum.oublier_audio if organum and organum.oublier_audio
    if fd
      unix.close 0
      unix.close 1
      unix.dup fd
      unix.close 2
      unix.dup fd
      unix.close fd
    argv = {HELPER.chemin}
    argv[#argv + 1] = "--verbose" if verbose
    pcall unix.execve, HELPER.chemin, argv, unix.environ!
    unix.exit 126
  pcall unix.close, fd if fd
  HELPER.pid = pid
  HELPER.etat = "actif"
  HELPER.externe = false
  HELPER.lance_a = maintenant! or 0
  Log kLogInfo, "organum : assistant natif macOS lancé (#{HELPER.chemin}, journal #{HELPER.log})"

-- Relance après la mort du helper, depuis le heartbeat : pas de fil dédié,
-- pas de boucle qui consomme un cœur. Redbean récolte lui-même tous ses fils
-- (wait4(-1)), donc un wait ciblé sur le helper est illisible : on détecte sa
-- présence en sondant les sockets. Un assistant lancé à la main (ou par
-- LaunchAgent) est ainsi réutilisé, et trois échecs rapprochés sont annoncés
-- comme « impossible à lancer » au lieu de relancer sans fin.
surveiller_assistant = ->
  return unless HELPER and HELPER.chemin
  return if HELPER.etat == "non_embarque" or HELPER.etat == "extraction_impossible" or
    HELPER.etat == "inutilisable" or HELPER.etat == "lancement_impossible"
  now = maintenant! or 0
  if assistant_vivant!
    HELPER.etat = "actif"
    -- Un helper qui a vécu laisse repartir le compteur d'échecs.
    HELPER.echecs = 0 if not HELPER.lance_a or now - HELPER.lance_a >= 10
    return
  if HELPER.pid
    -- Laisse au nouveau processus le temps de lier ses sockets avant de le
    -- déclarer mort (le heartbeat passe toutes les 2 s).
    return if now - (HELPER.lance_a or 0) < 3
    HELPER.pid = nil
    HELPER.echecs = (HELPER.echecs or 0) + 1
    Log kLogWarn, "organum : assistant natif macOS sans socket après lancement (#{HELPER.echecs} échec(s))"
    if HELPER.echecs >= 3
      HELPER.etat = "lancement_impossible"
      Log kLogWarn, "organum : assistant natif macOS impossible à lancer (#{HELPER.chemin}, journal #{HELPER.log})"
      return
  return if now < (HELPER.prochain_essai or 0)
  lancer_assistant!
  delai = math.min 30, 2 ^ math.min(HELPER.echecs or 0, 4)
  HELPER.prochain_essai = (maintenant! or now) + delai

installer_assistant = ->
  return unless assistant.besoin PLATEFORME, SANS_BACKEND, MIDI_ACTIF, MIDI_SOCKET
  tmpdir = os.getenv "TMPDIR"
  homedir = os.getenv "HOME"
  HELPER = {
    chemin: assistant.chemin tmpdir, homedir
    dossier: assistant.dossier tmpdir, homedir
    log: assistant.chemin_log tmpdir, homedir
    midi: assistant.chemin_socket os.getenv("ORGANUM_MIDI_SOCKET"), tmpdir, unix.getuid!, "organum-midi"
    audio: assistant.chemin_socket os.getenv("ORGANUM_AUDIO_SOCKET"), tmpdir, unix.getuid!, "organum-audio"
    pid: nil, etat: nil, echecs: 0, prochain_essai: 0, lance_a: 0, externe: false
  }
  source = Slurp assistant.ARCHIVE
  unless source and #source > 0
    HELPER.etat = "non_embarque"
    Log kLogWarn, "organum : assistant natif macOS non embarqué (#{assistant.ARCHIVE} absent)"
    return
  unless unix.makedirs HELPER.dossier, tonumber("700", 8)
    HELPER.etat = "extraction_impossible"
    Log kLogWarn, "organum : dossier de l'assistant natif macOS impossible à créer : #{HELPER.dossier}"
    return
  pcall unix.chmod, HELPER.dossier, tonumber("700", 8)
  -- Fichier temporaire puis renommage : un assistant en cours d'exécution
  -- garde son inode, et aucun extrait à moitié écrit n'est jamais exécuté.
  deja = Slurp HELPER.chemin
  unless deja == source
    tmp = "#{HELPER.chemin}.tmp.#{unix.getpid!}"
    unless Barf tmp, source, tonumber("700", 8)
      pcall unix.unlink, tmp
      HELPER.etat = "extraction_impossible"
      Log kLogWarn, "organum : extraction de l'assistant natif macOS impossible : #{tmp}"
      return
    unless pcall unix.rename, tmp, HELPER.chemin
      pcall unix.unlink, tmp
      HELPER.etat = "extraction_impossible"
      Log kLogWarn, "organum : installation de l'assistant natif macOS impossible : #{HELPER.chemin}"
      return
  pcall unix.chmod, HELPER.chemin, tonumber("700", 8)
  unless unix.access HELPER.chemin, unix.X_OK
    HELPER.etat = "lancement_impossible"
    Log kLogWarn, "organum : assistant natif macOS non exécutable après installation : #{HELPER.chemin}"
    return
  -- Vérification d'intégrité puis d'exécution : un extrait tronqué, non signé
  -- (refusé par macOS arm64), d'une autre architecture ou frappé de
  -- quarantaine doit donner un état clair, jamais un échec obscur plus tard.
  extrait = Slurp HELPER.chemin
  code_aide = nil
  sortie_aide = nil
  if extrait and #extrait == #source and extrait == source
    sortie_aide, code_aide = run HELPER.chemin, {"--aide"}, nil, 5
  etat_verif = assistant.verifier_extrait source, extrait, code_aide
  if etat_verif
    HELPER.etat = etat_verif
    if etat_verif == "extraction_impossible"
      Log kLogWarn, "organum : assistant natif macOS extrait incomplet (taille #{extrait and #extrait or 0} au lieu de #{#source}) : #{HELPER.chemin}"
    else
      Log kLogWarn, "organum : assistant natif macOS inutilisable (--aide, code #{code_aide}) : #{HELPER.chemin}#{sortie_aide and sortie_aide != "" and " : #{sortie_aide}" or ""}"
    return
  if assistant_vivant!
    HELPER.etat = "actif"
    HELPER.externe = true
    Log kLogInfo, "organum : assistant natif macOS déjà vivant, réutilisé"
    return
  lancer_assistant!

do
  ok, err = pcall installer_assistant
  unless ok
    HELPER = {etat: "extraction_impossible", log: HELPER and HELPER.log} unless HELPER
    HELPER.etat = "extraction_impossible"
    Log kLogWarn, "organum : préparation de l'assistant natif macOS impossible : #{err}"

etat_sauve = do
  contenu = Slurp ETAT_FICHIER
  ok, e = pcall DecodeJson, contenu if contenu
  ok and type(e) == "table" and e or {}

-- Authentification facultative (HTTP Digest SHA-256, RFC 7616). Désactivée
-- tant qu'aucun mot de passe n'est enregistré. Le fichier est un texte
-- éditable à la main, partagé par tous les fils, voisin d'etat.json et à
-- droits 0600 ; il ne contient qu'une ligne utilisateur:organum:HA1, jamais
-- le mot de passe. ORGANUM_DIGEST donne son chemin (absent ou vide : chemin
-- par défaut).
chemin_environnement = (nom, defaut) ->
  valeur = os.getenv nom
  if valeur and valeur != "" then valeur else defaut

AUTH_FICHIER = chemin_environnement "ORGANUM_DIGEST", "#{ETAT_FICHIER}.digest"
AUTH = authentification
-- Secret du nonce : tiré une fois, dans le processus principal, avant que
-- redbean ne crée les processus de requêtes ; chacun en hérite par fork.
SECRET_NONCE = GetRandomBytes 32
-- Durée de validité du nonce : 5 minutes. La variable n'existe que pour
-- éprouver la péremption sans attendre cinq minutes dans les tests.
AUTH_NONCE_DUREE = tonumber(os.getenv "ORGANUM_AUTH_NONCE_DUREE") or AUTH.DUREE_NONCE

-- Fichier texte voisin d'etat.json, ou ORGANUM_RESEAUX_FICHIER (absent ou
-- vide : chemin par défaut). Un sous-réseau par ligne, commentaires « # » et
-- lignes vides admis.
RESEAUX_FICHIER = chemin_environnement "ORGANUM_RESEAUX_FICHIER", "#{ETAT_FICHIER}.reseaux"

-- Seul ENOENT vaut « fichier absent » : une autre erreur de stat (EACCES sur
-- un dossier parent, ENOTDIR…) ne doit jamais ouvrir l'accès.
est_enoent = (err) ->
  return false unless err
  if type(err) == "number"
    err == unix.ENOENT
  else
    type(err) == "userdata" and err\errno! == unix.ENOENT

-- Lecture stricte partagée : nil sans erreur si le fichier n'existe pas,
-- sinon son contenu ; une erreur explicite s'il existe mais reste illisible
-- (permissions comprises) ou si stat échoue autrement qu'en ENOENT.
lire_fichier_texte = (chemin) ->
  stat, stat_err = unix.stat chemin
  unless stat
    return nil, nil if est_enoent stat_err
    return nil, "fichier inaccessible (#{stat_err or "stat impossible"})"
  contenu, err = Slurp chemin
  unless contenu
    return nil, "fichier illisible (#{err or "lecture impossible"})"
  contenu, nil

auth_config = ->
  contenu, erreur = lire_fichier_texte AUTH_FICHIER
  if erreur
    return {active: false, utilisateur: AUTH.UTILISATEUR_DEFAUT, ha1: nil, erreur: erreur}
  unless contenu
    return {active: false, utilisateur: AUTH.UTILISATEUR_DEFAUT, ha1: nil, erreur: nil}
  entree, err = AUTH.analyser_fichier contenu
  if entree == nil
    return {active: false, utilisateur: AUTH.UTILISATEUR_DEFAUT, ha1: nil, erreur: err}
  unless entree
    return {active: false, utilisateur: AUTH.UTILISATEUR_DEFAUT, ha1: nil, erreur: nil}
  {active: true, utilisateur: entree.utilisateur, ha1: entree.ha1, erreur: nil}

auth_utilisateur_valide = (u) ->
  type(u) == "string" and #u >= 1 and #u <= 64 and not u\match "[:%c]"

auth_mot_de_passe_valide = (m) ->
  type(m) == "string" and #m >= 1 and #m <= 1024 and not m\find "\0", 1, true

auth_etat = ->
  config = auth_config!
  {
    active: config.active
    utilisateur: config.utilisateur
    source: if config.active then "fichier" else "aucune"
    erreur: config.erreur
  }

auth_enregistrer = (utilisateur, mot_de_passe) ->
  return nil, "utilisateur invalide" unless auth_utilisateur_valide utilisateur
  return nil, "mot de passe invalide" unless auth_mot_de_passe_valide mot_de_passe
  dossier = AUTH_FICHIER\match "^(.*)/[^/]*$"
  unix.makedirs dossier, tonumber("755", 8) if dossier
  tmp = "#{AUTH_FICHIER}.tmp.#{unix.getpid!}"
  ha1 = AUTH.ha1 utilisateur, AUTH.ROYAUME, mot_de_passe
  contenu = AUTH.formater_fichier utilisateur, ha1
  ok = Barf tmp, contenu, tonumber("600", 8)
  unless ok
    pcall unix.unlink, tmp
    return nil, "écriture impossible"
  ok = pcall unix.rename, tmp, AUTH_FICHIER
  unless ok
    pcall unix.unlink, tmp
    return nil, "écriture impossible"
  pcall unix.chmod, AUTH_FICHIER, tonumber("600", 8)
  true

auth_retirer = ->
  pcall unix.unlink, AUTH_FICHIER
  true

regler_authentification = (data) ->
  return nil, "objet attendu" unless type(data) == "table"
  if data.retirer == true
    ok, err = auth_retirer!
    return nil, err unless ok
    return auth_etat!
  utilisateur = data.utilisateur
  unless utilisateur != nil
    utilisateur = auth_config!.utilisateur
  ok, err = auth_enregistrer utilisateur, data.mot_de_passe
  return nil, err unless ok
  auth_etat!

-- Un fichier invalide n'empêche pas le démarrage : l'orgue joue, mais les
-- sources non locales reçoivent 503 (voir reseaux_autoriser et
-- auth_autoriser). Les adresses locales restent exemptées, afin de garder un
-- moyen de corriger le fichier depuis l'interface web.

-- Source HTTP réelle : GetClientAddr, et non GetRemoteAddr, pour qu'un
-- en-tête X-Forwarded-For venu d'une adresse de confiance ne puisse ni
-- exempter du filtre de sous-réseau ni contourner l'authentification. La
-- reconnaissance des adresses strictement locales est dans
-- controle_acces.source_locale (127.0.0.1 et ::1 seulement).

-- Cible de la requête telle que le client l'a signée : chemin et chaîne de
-- requête, sans schéma ni hôte (GetUrl les ajoute).
auth_cible = ->
  url = GetUrl!
  cible = type(url) == "string" and url\match "^[%a][%w+.-]*://[^/]*(/.*)$"
  cible or GetPath!

auth_autoriser = ->
  config = auth_config!
  if config.erreur
    SetStatus 503
    SetHeader "Content-Type", "application/json"
    Write EncodeJson {error: "configuration de l'authentification invalide : #{config.erreur}"}
    return false
  return true unless config.active
  ok, stale, raison = AUTH.verifier {
    entete: GetHeader "Authorization"
    methode: GetMethod!
    uri: auth_cible!
    ha1: config.ha1
    utilisateur: config.utilisateur
    secret: SECRET_NONCE
    maintenant: os.time!
    duree: AUTH_NONCE_DUREE
  }
  return true if ok
  SetStatus 401
  SetHeader "WWW-Authenticate", AUTH.entete_defi SECRET_NONCE, os.time!, stale
  SetHeader "Content-Type", "application/json"
  Write EncodeJson {error: "authentification requise"}
  false

-- Tempérament au démarrage : entier 0..10 (ordre de l'enum du moteur).
-- Absent ou invalide : égal (5), ce qui préserve les fichiers déjà présents
-- sur l'orgue et neutralise un éventuel réglage utilisateur d'Aeolus.
TEMPERAMENT_DEFAUT = 5
TEMPERAMENT_MAX = 10
temperament_demarrage = validation.temperament_depuis_etat etat_sauve.temperament,
  TEMPERAMENT_DEFAUT, TEMPERAMENT_MAX

-- Qualité au démarrage : etat.json d'abord, puis ORGANUM_QUALITE
-- (auto|0|1|2|3), prioritaire sur le fichier.
qualite_demarrage = {}
niveau_impose = false
do
  q = etat_sauve.qualite
  if type(q) == "table"
    qualite_demarrage.bruit_attaque = q.bruit_attaque if type(q.bruit_attaque) == "boolean"
    qualite_demarrage.instabilite = q.instabilite if type(q.instabilite) == "boolean"
    qualite_demarrage.spatialisation = q.spatialisation if entier_borne q.spatialisation, 0, 2
    qualite_demarrage.polyphonie_max = q.polyphonie_max if entier_borne q.polyphonie_max, 0, 512
    if entier_borne q.niveau, 0, 3
      qualite_locale.niveau = q.niveau
      niveau_impose = true
    qualite_locale.auto = q.auto if type(q.auto) == "boolean"
    qualite_locale.tete_reverb = q.tete_reverb if type(q.tete_reverb) == "boolean"
  else
    qualite_locale.auto = true
  -- QUALITE_FICHIER est écrit à chaque réglage, donc plus frais qu'etat.json
  -- (recopié seulement au battement) : ses valeurs valides le complètent.
  locale = qualite_locale_actuelle!
  qualite_locale.niveau = locale.niveau
  qualite_locale.auto = locale.auto
  qualite_locale.tete_reverb = locale.tete_reverb
  qualite_locale.periode = locale.periode
  qualite_locale.taux = locale.taux
  qualite_locale.peripherique = locale.peripherique
  qualite_locale.limiteur = locale.limiteur
  if type(locale.niveau) == "number" and locale.niveau >= 0
    niveau_impose = true
  impose = os.getenv "ORGANUM_QUALITE"
  if impose and impose != ""
    if impose == "auto"
      qualite_locale.auto = true
    else
      valeur = tonumber impose
      n = valeur and math.tointeger(valeur)
      if n and n >= 0 and n <= 3
        p = PRESELECTIONS[n + 1]
        qualite_demarrage = {
          spatialisation: p.spatialisation
          bruit_attaque: p.bruit_attaque
          instabilite: p.instabilite
          polyphonie_max: p.polyphonie_max
        }
        qualite_locale.tete_reverb = p.tete_reverb
        qualite_locale.niveau = n
        qualite_locale.auto = false
        niveau_impose = true
      else
        Log kLogWarn, "organum : ORGANUM_QUALITE invalide (#{impose}), ignoré"

-- Valeurs EFFECTIVES du lancement et variables d'environnement qui les
-- imposent. Les valeurs enregistrées (qualite_locale) ne sont jamais
-- remplacées par une valeur imposée : elles restent « prochaines ».
EFFECTIF, IMPOSE = nil, nil
do
  env_impose = {
    ORGANUM_TAUX: os.getenv "ORGANUM_TAUX"
    ORGANUM_PERIODE: os.getenv "ORGANUM_PERIODE"
    ORGANUM_PERIPHERIQUE: os.getenv "ORGANUM_PERIPHERIQUE"
    ORGANUM_LIMITEUR: os.getenv "ORGANUM_LIMITEUR"
  }
  imp = validation.impositions env_impose, {
    taux: qualite_locale.taux
    periode: qualite_locale.periode
    peripherique: qualite_locale.peripherique
    limiteur: qualite_locale.limiteur
  }
  EFFECTIF = imp.effectif
  IMPOSE = imp.impose
  for message in *imp.erreurs
    Log kLogWarn, "organum : #{message}"
AUDIO_REPLI = ""

taux_demarrage = EFFECTIF.taux
periode_demarrage = EFFECTIF.periode
calibration_demarrage = nil

-- Calibration automatique, uniquement quand auto est vrai (premier lancement,
-- ORGANUM_QUALITE=auto, ou état sauvegardé en mode auto). Elle se fait AVANT
-- organum.demarrer : le micro-banc ne dépend pas du moteur. En cas d'échec
-- ou de dépassement de 1,5 s, repli sur le niveau 3 sans jamais planter.
if qualite_locale.auto and not SANS_BACKEND
  ok_cal, cal = pcall(organum.calibrer, {
    taux: taux_demarrage
    periode: periode_demarrage
  })
  ok_dec, decision = false, nil
  if ok_cal and type(cal) == "table"
    ok_dec, decision = pcall calibration.choisir, cal
  valide = ok_dec and type(decision) == "table" and
    entier_borne(decision.niveau, 0, 3) and
    type(cal.duree_calibration_ms) == "number" and
    cal.duree_calibration_ms <= 1500
  if valide
    cal.niveau = decision.niveau
    cal.tete_reverb = decision.tete_reverb
    cal.estimation_ms = decision.estimation_ms
    -- Champs internes de la décision : ne pas les publier dans
    -- qualite.calibration (forme inchangée par rapport à l'ancien C).
    cal.taux = nil
    cal.periode = nil
    cal.voix_forcee = nil
    p = PRESELECTIONS[cal.niveau + 1]
    qualite_demarrage = {
      spatialisation: p.spatialisation
      bruit_attaque: p.bruit_attaque
      instabilite: p.instabilite
      polyphonie_max: p.polyphonie_max
    }
    qualite_locale.tete_reverb = p.tete_reverb
    qualite_locale.niveau = cal.niveau
    calibration_demarrage = cal
    Log kLogInfo, "organum : calibration automatique : niveau #{cal.niveau} en #{math.floor cal.duree_calibration_ms} ms"
  else
    p = PRESELECTIONS[4]
    qualite_demarrage = {
      spatialisation: p.spatialisation
      bruit_attaque: p.bruit_attaque
      instabilite: p.instabilite
      polyphonie_max: p.polyphonie_max
    }
    qualite_locale.tete_reverb = p.tete_reverb
    qualite_locale.niveau = 3
    Log kLogWarn, "organum : calibration automatique impossible ou trop longue ; repli sur le niveau 3"

if organum.demarrer
  etat_moteur = type(etat_sauve.moteur) == "string" and etat_sauve.moteur or nil
  demarrer = (taux, periode, peripherique, limiteur) ->
    organum.demarrer {
      :taux, :periode, :peripherique, :limiteur
      sans_backend: SANS_BACKEND
      audio_opportuniste: AUDIO_OPPORTUNISTE
      midi: MIDI_ACTIF
      temperament: temperament_demarrage
      etat: etat_moteur
      qualite: qualite_demarrage
      tete_reverb: qualite_locale.tete_reverb
    }
  periph_effectif = EFFECTIF.peripherique
  ok, err = demarrer EFFECTIF.taux, EFFECTIF.periode, periph_effectif, EFFECTIF.limiteur
  -- Repli unique : un réglage enregistré (non imposé) peut désigner un
  -- périphérique absent (carte USB débranchée) ou un taux que la carte
  -- refuse. On réessaie avec les défauts, sans toucher aux valeurs
  -- enregistrées. Les variables d'environnement restent prioritaires.
  enregistre_utilise = (not IMPOSE.peripherique and qualite_locale.peripherique != "") or
    (not IMPOSE.taux and qualite_locale.taux != DEMARRAGE_DEFAUT.taux) or
    (not IMPOSE.periode and qualite_locale.periode != DEMARRAGE_DEFAUT.periode)
  if not ok and enregistre_utilise
    Log kLogWarn, "organum : démarrage impossible (#{err}) ; nouvel essai avec les réglages par défaut"
    rtaux = IMPOSE.taux and EFFECTIF.taux or DEMARRAGE_DEFAUT.taux
    rperiode = IMPOSE.periode and EFFECTIF.periode or DEMARRAGE_DEFAUT.periode
    rperiph = IMPOSE.peripherique and EFFECTIF.peripherique or DEMARRAGE_DEFAUT.peripherique
    ok, err2 = demarrer rtaux, rperiode, rperiph, EFFECTIF.limiteur
    if ok
      periph_effectif = rperiph
      AUDIO_REPLI = "réglages enregistrés indisponibles (#{err}) ; démarré avec les réglages par défaut"
    else
      err = err2
  unless ok
    Log kLogFatal, "organum : #{err}"
    unix.exit 1
  -- Valeurs réellement retenues (l'ouverture audio peut borner) : le fil
  -- audio les publie dans l'état partagé, hérité par les fils de requête.
  etat_effectif = organum.etat!
  -- Un seul avertissement au démarrage : le MIDI peut être actif même sans
  -- audio (Mac), mais l'assistant CoreMIDI est alors indispensable. Le
  -- chemin vient du backend, jamais d'une règle recopiée ici.
  if MIDI_ACTIF and type(organum.midi_assistant) == "function" and organum.midi_assistant! == 0
    chemin = if type(organum.midi_chemin) == "function" then organum.midi_chemin!
    -- Une socket peut exister sans que la connexion soit encore établie, ou
    -- survivre à un assistant tué : rester neutre plutôt que d'annoncer
    -- « absent » ou « périmée » à tort. Sous macOS, organum gère l'assistant
    -- et le relancera ; ailleurs (socket simulée par les tests Linux), il
    -- n'y a rien à lancer à la main.
    if HELPER
      if chemin and unix.stat chemin
        Log kLogWarn, "organum : assistant MIDI pas encore connecté (socket présente) : #{chemin} ; organum le relancera si besoin (journal #{HELPER.log})"
      else
        Log kLogWarn, "organum : assistant MIDI absent (socket #{chemin or "inconnue"}) ; organum va le relancer (journal #{HELPER.log})"
    else if chemin and unix.stat chemin
      Log kLogWarn, "organum : assistant MIDI pas encore connecté (socket présente) : #{chemin}"
    else
      Log kLogWarn, "organum : assistant MIDI absent (socket #{chemin or "inconnue"})"
  EFFECTIF.taux = etat_effectif.taux
  EFFECTIF.periode = etat_effectif.periode
  EFFECTIF.peripherique = periph_effectif
  unless niveau_impose
    qualite_locale.niveau = niveau_correspondant organum.etat!.qualite, qualite_locale.tete_reverb
  ecrire_qualite_locale qualite_locale
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
  q = qualite_locale_actuelle!
  signature = "#{e.seq}|#{e.temperament}|#{q.niveau}|#{q.auto}|#{q.tete_reverb}|#{q.periode}|#{q.taux}|#{q.peripherique}|#{q.limiteur}"
  return if signature == seq_sauve
  seq_sauve = signature
  dossier = ETAT_FICHIER\match "^(.*)/[^/]*$"
  unix.makedirs dossier, tonumber("755", 8) if dossier
  contenu = EncodeJson {
    moteur: organum.sauvegarder!
    volume: e.volume, reverb: e.reverb
    temperament: e.temperament
    gains: [d.gain for d in *e.divisions]
    qualite: {
      bruit_attaque: e.qualite.bruit_attaque
      instabilite: e.qualite.instabilite
      spatialisation: e.qualite.spatialisation
      polyphonie_max: e.qualite.polyphonie_max
      tete_reverb: q.tete_reverb
      niveau: q.niveau
      auto: q.auto
      periode: q.periode
      taux: q.taux
      peripherique: q.peripherique
      limiteur: q.limiteur
    }
  }
  -- Fichier temporaire puis renommage : jamais de sauvegarde à moitié écrite.
  if Barf "#{ETAT_FICHIER}.tmp", contenu, tonumber("644", 8)
    unix.rename "#{ETAT_FICHIER}.tmp", ETAT_FICHIER

_G.OnServerHeartbeat = ->
  pcall sauvegarder_etat
  pcall surveiller_assistant if HELPER
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

-- Lecture du fichier de réseaux : absent ou sans entrée donne une liste vide
-- (aucun contrôle) ; un fichier illisible ou invalide donne une liste vide et
-- une erreur, qui refuse l'accès non local (503) plutôt que de l'ouvrir.
reseaux_fichier = ->
  contenu, erreur = lire_fichier_texte RESEAUX_FICHIER
  return {}, erreur if erreur
  return {}, nil unless contenu
  liste, err = controle_acces.analyser_fichier contenu
  return {}, err unless liste
  liste, nil

reseaux_config = ->
  liste, erreur = reseaux_fichier!
  {liste: liste, erreur: erreur}

-- État publié (API et panneaux). ip est la valeur brute de GetClientAddr
-- quand elle est connue ; la fenêtre native n'a pas de source HTTP.
reseaux_etat = (ip) ->
  config = reseaux_config!
  entrees = [{reseau: e.reseau.texte, commentaire: e.commentaire} for e in *config.liste]
  {
    active: #config.liste > 0
    texte: controle_acces.formater_liste config.liste
    reseaux: modele.liste_json entrees
    source: if ip != nil then controle_acces.texte_source ip else nil
    erreur: config.erreur
  }

reseaux_ecrire = (liste) ->
  contenu = controle_acces.formater_fichier liste
  dossier = RESEAUX_FICHIER\match "^(.*)/[^/]*$"
  unix.makedirs dossier, tonumber("755", 8) if dossier
  tmp = "#{RESEAUX_FICHIER}.tmp.#{unix.getpid!}"
  unless Barf tmp, contenu, tonumber("600", 8)
    pcall unix.unlink, tmp
    return nil, "écriture impossible"
  ok = pcall unix.rename, tmp, RESEAUX_FICHIER
  unless ok
    pcall unix.unlink, tmp
    return nil, "écriture impossible"
  pcall unix.chmod, RESEAUX_FICHIER, tonumber("600", 8)
  true

-- Enregistre une liste. ip est la source HTTP courante : une liste non vide
-- qui l'exclut est refusée, sauf si cette source est locale (elle passe
-- toujours). Seules les lignes qui ne contiennent qu'un commentaire sont
-- perdues à l'écriture ; les commentaires d'entrée sont conservés.
regler_reseaux = (data, ip = nil) ->
  return nil, "objet attendu" unless type(data) == "table"
  if data.retirer == true
    pcall unix.unlink, RESEAUX_FICHIER
    return reseaux_etat ip
  return nil, "champ reseaux attendu" if data.reseaux == nil
  liste, err = controle_acces.normaliser_liste data.reseaux
  return nil, "liste invalide : #{err}" unless liste
  exclut = false
  if ip != nil and #liste > 0
    exclut = not controle_acces.source_locale(ip) and not controle_acces.autorise liste, ip
  if exclut
    return nil, "la liste exclut l'adresse source (#{controle_acces.texte_source ip})"
  if #liste == 0
    pcall unix.unlink, RESEAUX_FICHIER
  else
    ok, err = reseaux_ecrire liste
    return nil, err unless ok
  reseaux_etat ip

-- Garde de sous-réseau : 403 avant toute analyse Digest, sans défi. Une
-- liste vide ne filtre rien ; les adresses locales ne sont jamais soumises
-- à ce filtre (l'appelant les exempte). Un fichier invalide en cours
-- d'exécution refuse l'accès non local (503) au lieu de l'ouvrir.
reseaux_autoriser = (ip) ->
  config = reseaux_config!
  if config.erreur
    SetStatus 503
    SetHeader "Content-Type", "application/json"
    Write EncodeJson {error: "configuration des réseaux invalide : #{config.erreur}"}
    return false
  return true if #config.liste == 0
  return true if controle_acces.autorise config.liste, ip
  SetStatus 403
  SetHeader "Content-Type", "application/json"
  Write EncodeJson {error: "adresse source non autorisée"}
  false


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

-- Déclarations anticipées : la fenêtre est lancée plus bas, après leur
-- définition, mais lancer_fenetre les référence dans sa fermeture.
qualite_etat = nil
regler_qualite = nil

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
  -- Juste après le fork : lâcher le PCM hérité sans toucher au flux du
  -- parent (le fil audio principal continue de l'utiliser).
  pcall organum.oublier_audio
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
    -- Même chemin que POST /api/orgue (regler_qualite) : la fenêtre
    -- enregistre exactement comme la page web, sans duplication de règles.
    qualite = {
      etat: qualite_etat
      regler: (p) ->
        res, raison = regler_qualite p
        error raison unless res
        res
    }
    auth = {
      etat: auth_etat
    }
    reseaux = {
      etat: reseaux_etat
    }
    ouvert, raison = lancer organum, nk, {titre: "organum", :volume, :midi, :qualite, authentification: auth, :reseaux, continuer: -> unix.getppid! == maitre}
    Log kLogWarn, "fenêtre : #{raison}" unless ouvert
  Log kLogWarn, "fenêtre : #{err}" unless ok
  unix.exit 0

-- Qualité exposée : les quatre champs du moteur (valeur réelle), plus les
-- réglages tenus côté Lua. niveau vaut la présélection correspondante, ou -1
-- si l'utilisateur a modifié un champ à la main. X est la valeur effective
-- publiée par le fil audio (donc à jour après un réglage à chaud), X_prochain
-- la valeur enregistrée, X_impose une variable d'environnement prioritaire.
qualite_etat = ->
  e = organum.etat!
  q = qualite_locale_actuelle!
  audio_etat, audio_message = degradation.etat_audio {
    supportee: AUDIO_SUPPORTEE
    sans_backend: SANS_BACKEND
    socket: e.qualite.audio_socket
    assistant: e.qualite.audio_assistant
    disponible: e.audio_disponible
    erreur: e.qualite.audio_erreur
    demarre: e.qualite.audio_demarre
    application: e.qualite.application_audio == true
    assistant_etat: HELPER and HELPER.etat
    assistant_log: HELPER and HELPER.log
  }
  etat_qualite = {
    temperament: e.temperament
    temperament_erreur: e.qualite.temperament_erreur or ""
    temperament_cible: e.qualite.temperament_cible or -1
    bruit_attaque: e.qualite.bruit_attaque == true
    instabilite: e.qualite.instabilite == true
    spatialisation: e.qualite.spatialisation
    polyphonie_max: e.qualite.polyphonie_max
    tete_reverb: e.qualite.tete_reverb == true
    tete_reverb_prochain: q.tete_reverb == true
    tete_reverb_impose: e.qualite.tete_reverb_impose == true
    periode: e.periode
    periode_prochain: q.periode
    periode_impose: IMPOSE.periode
    taux: e.taux
    taux_prochain: q.taux
    taux_impose: IMPOSE.taux
    peripherique: e.qualite.peripherique or ""
    peripherique_prochain: q.peripherique or ""
    peripherique_impose: IMPOSE.peripherique
    limiteur: e.qualite.limiteur == true
    limiteur_prochain: q.limiteur == true
    limiteur_impose: IMPOSE.limiteur
    audio_repli: AUDIO_REPLI
    audio_erreur: e.qualite.audio_erreur or ""
    application: e.qualite.application == true
    application_audio: e.qualite.application_audio == true
    charge: e.qualite.charge or 0
    charge_pointe: e.qualite.charge_pointe or 0
    charge_evaluee: e.qualite.charge_evaluee == true
    charge_niveau: e.qualite.charge_niveau or 0
    xruns: e.xruns or 0
    xruns_recents: e.qualite.xruns_recents or 0
    audio_socket: e.qualite.audio_socket == true
    audio_assistant: e.qualite.audio_assistant or -1
    audio_chemin: e.qualite.audio_chemin or ""
    trames_jouees: e.qualite.trames_jouees or 0
    capacite: e.qualite.capacite or 0
    latence_ms: e.qualite.latence_ms or 0
    audio_demarre: e.qualite.audio_demarre == true
    assistant_etat: HELPER and HELPER.etat or ""
    assistant_embarque: HELPER != nil and HELPER.etat != "non_embarque"
    assistant_log: HELPER and HELPER.log or ""
    assistant_pid: HELPER and HELPER.pid or 0
    niveau: q.niveau
    auto: q.auto
    audio_disponible: e.audio_disponible == true
    midi_disponible: e.midi_disponible == true
    plateforme: PLATEFORME
    plateforme_libelle: modele.libelle_plateforme PLATEFORME
    mode_degrade: SANS_BACKEND
    audio_etat: audio_etat or ""
    audio_message: audio_message or ""
    midi_message: message_midi_courant! or ""
  }
  etat_qualite.calibration = calibration_demarrage if calibration_demarrage
  etat_qualite

-- Applique des réglages de qualité (même chemin pour POST /api/orgue et pour
-- la fenêtre native). Renvoie la réponse, ou nil et un message français.
-- Tous les réglages s'appliquent à chaud : les champs à hot passent par le
-- moteur, les réglages audio par une demande de reconfiguration unique. Un
-- échec audio est publié de façon asynchrone dans audio_erreur.
regler_qualite = (q) ->
  valide, err = validation.valider_qualite q
  return nil, err unless valide

  impose_tete = organum.etat!.qualite.tete_reverb_impose == true
  loc = qualite_locale_actuelle!
  loc.auto = q.auto if q.auto != nil
  modifie = false
  tete_a_appliquer = nil
  limiteur_a_appliquer = nil
  p = nil
  if q.bruit_attaque != nil
    organum.qualite "bruit_attaque", q.bruit_attaque
    modifie = true
  if q.instabilite != nil
    organum.qualite "instabilite", q.instabilite
    modifie = true
  if q.spatialisation != nil
    organum.qualite "spatialisation", q.spatialisation
    modifie = true
  if q.polyphonie_max != nil
    organum.qualite "polyphonie_max", q.polyphonie_max
    modifie = true
  if q.tete_reverb != nil and not impose_tete
    loc.tete_reverb = q.tete_reverb
    tete_a_appliquer = q.tete_reverb
    modifie = true
  if q.niveau != nil
    p = PRESELECTIONS[q.niveau + 1]
    organum.qualite "spatialisation", p.spatialisation
    organum.qualite "bruit_attaque", p.bruit_attaque
    organum.qualite "instabilite", p.instabilite
    organum.qualite "polyphonie_max", p.polyphonie_max
    unless impose_tete
      loc.tete_reverb = p.tete_reverb
      tete_a_appliquer = p.tete_reverb
    loc.niveau = q.niveau
    loc.auto = false
  elseif modifie
    loc.niveau = -1
    loc.auto = false
  -- Réglages de démarrage : jamais écrits quand l'environnement les impose,
  -- et sans toucher au niveau ni au mode auto (ils ne font pas partie des
  -- présélections).
  if q.periode != nil and not IMPOSE.periode
    loc.periode = q.periode
  if q.taux != nil and not IMPOSE.taux
    loc.taux = q.taux
  if q.peripherique != nil and not IMPOSE.peripherique
    loc.peripherique = q.peripherique
  if q.limiteur != nil and not IMPOSE.limiteur
    loc.limiteur = q.limiteur
    limiteur_a_appliquer = q.limiteur
  ecrire_qualite_locale loc

  -- Une seule demande de reconfiguration par POST, portant les valeurs
  -- voulues ; les dimensions imposées gardent leur valeur effective.
  if q.periode != nil or q.taux != nil or q.peripherique != nil
    e = organum.etat!
    cible = {
      taux: IMPOSE.taux and e.taux or loc.taux
      periode: IMPOSE.periode and e.periode or loc.periode
      peripherique: IMPOSE.peripherique and (e.qualite.peripherique or "") or loc.peripherique
    }
    organum.reconfigurer_audio cible
  organum.limiteur limiteur_a_appliquer if limiteur_a_appliquer != nil
  organum.tete_reverb tete_a_appliquer if tete_a_appliquer != nil

  -- La réponse reflète les valeurs DEMANDÉES, pas celles que le fil audio
  -- n'a pas encore publiées (il reçoit les commandes de façon asynchrone).
  reponse = qualite_etat!
  if q.niveau != nil
    reponse.niveau = q.niveau
    reponse.auto = false
    reponse.spatialisation = p.spatialisation
    reponse.bruit_attaque = p.bruit_attaque
    reponse.instabilite = p.instabilite
    reponse.polyphonie_max = p.polyphonie_max
  else
    reponse.spatialisation = q.spatialisation if q.spatialisation != nil
    reponse.bruit_attaque = q.bruit_attaque if q.bruit_attaque != nil
    reponse.instabilite = q.instabilite if q.instabilite != nil
    reponse.polyphonie_max = q.polyphonie_max if q.polyphonie_max != nil
    reponse.auto = q.auto if q.auto != nil
  reponse.ok = true
  reponse

-- Le processus fils de la fenêtre doit connaître qualite_etat et
-- regler_qualite : lancer après leur définition.
lancer_fenetre!

-- État au format du socket d'Aeolus (PROTOCOLE-SOCKET.md), que le client
-- connaît déjà ; les divisions et jeux y sont indexés à partir de 0.
etat_orgue = ->
  e = organum.etat!
  {
    source: "aeolus", instance: INSTANCE, seq: e.seq, step: e.etape, steps: e.netapes
    volume: e.volume, reverb: e.reverb, xruns: e.xruns, midi: e.midi, temps_reel: e.temps_reel
    taux: e.taux, periode: e.periode, nb_periodes: e.nb_periodes, erreurs_ecriture: e.erreurs_ecriture
    audio_disponible: e.audio_disponible == true
    midi_disponible: e.midi_disponible == true
    plateforme: PLATEFORME
    plateforme_libelle: modele.libelle_plateforme PLATEFORME
    mode_degrade: SANS_BACKEND
    temperament: e.temperament
    transposition: e.transposition or 0
    qualite: qualite_etat!
    divisions: for d in *e.divisions
      {
        name: d.nom, gain: d.gain
        canaux: modele.canaux_liste d.canaux
        links: [{division: l.division - 1, on: l.actif} for l in *d.liens]
        stops: [{name: j.nom\gsub("\n", " "), on: j.actif} for j in *d.jeux]
      }
  }

is_finite_number = validation.is_finite_number
is_integer = validation.is_integer

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


handle_authentification = ->
  method = GetMethod!
  if method == "GET"
    send_json 200, auth_etat!
    return
  unless method == "POST"
    send_json_405 "GET, POST"
    return
  ok, data = pcall DecodeJson, GetBody!
  unless ok and type(data) == "table"
    send_json 400, {error: "corps JSON invalide"}
    return
  reponse, err = regler_authentification data
  if reponse
    send_json 200, reponse
  else
    send_json 400, {error: err}

handle_reseaux = ->
  ip = GetClientAddr!
  method = GetMethod!
  if method == "GET"
    send_json 200, reseaux_etat ip
    return
  unless method == "POST"
    send_json_405 "GET, POST"
    return
  ok, data = pcall DecodeJson, GetBody!
  unless ok and type(data) == "table"
    send_json 400, {error: "corps JSON invalide"}
    return
  reponse, err = regler_reseaux data, ip
  if reponse
    send_json 200, reponse
  else
    send_json 400, {error: err}

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

  divisions = organum.etat!.divisions
  action, err = validation.valider_orgue data, divisions, NB_ETAPES, TEMPERAMENT_MAX
  unless action
    send_json 400, {error: err}
    return

  switch action
    when "stop"
      st = data.stop
      organum.jeu st.division + 1, st.index + 1, st.on
    when "link"
      l = data.link
      organum.lien l.division + 1, l.index + 1, l.on
    when "cancel"
      for j = 1, #divisions[data.cancel + 1].jeux
        organum.jeu data.cancel + 1, j, false
    when "step"
      organum.midi 0xCF, data.step  -- Program Change, canal de contrôle 16
    when "reverb"
      organum.reverb data.reverb / 127
    when "gain"
      g = data.gain
      organum.gain g.division + 1, g.value
    when "qualite"
      reponse, err = regler_qualite data.qualite
      if reponse
        send_json 200, reponse
      else
        send_json 400, {error: err}
      return
    when "temperament"
      organum.temperament data.temperament
    when "transposition"
      organum.transposition data.transposition
    when "note"
      -- Note du clavier web : elle entre par le tube (CMD_MIDI), jamais par
      -- le fil MIDI du système. Le canal est celui du sélecteur de clavier,
      -- déjà borné par validation.moon ; le moteur applique sa transposition.
      n = data.note
      velocite = if n.actif then (n.velocite or 100) else 0
      statut = if n.actif then 0x90 else 0x80
      organum.midi (statut | (n.canal - 1)), n.note, velocite
    when "volume"
      organum.volume data.volume
    when "panic"
      organum.panique!

  send_json 200, {ok: true}

-- Ports du séquenceur, dans la forme commune aux deux interfaces :
-- champs bruts du moteur, plus « libelle » et « etat » calculés par
-- modele.moon. Séquenceur indisponible : 200 avec ports = [] (les
-- interfaces affichent simplement une liste vide) et un message journalisé.
-- État de l'assistant socket : vrai seulement quand il est connecté.
assistant_midi = ->
  return false unless type(organum.midi_assistant) == "function"
  ok, valeur = pcall organum.midi_assistant
  ok and valeur == 1

etat_midi_ports = ->
  adresse = ""
  ok_etat, e = pcall organum.etat
  adresse = e.midi if ok_etat and type(e) == "table"
  ok, ports = pcall organum.midi_ports
  unless ok
    -- Axe MIDI coupé : ce n'est pas une anomalie. Sinon, le moteur n'a
    -- réellement pas démarré, ou les ports sont indisponibles.
    unless MIDI_ACTIF
      Log kLogInfo, "organum : séquenceur MIDI non ouvert (mode dégradé sur #{modele.libelle_plateforme PLATEFORME})"
    else
      Log kLogWarn, "organum : ports MIDI indisponibles : #{ports}"
    return {adresse: adresse, disponible: MIDI_ACTIF,
      assistant: assistant_midi!,
      socket: MIDI_SOCKET,
      plateforme_libelle: modele.libelle_plateforme PLATEFORME,
      ports: modele.liste_json {}}
  liste = for p in *ports
    p.libelle = modele.libelle_port p
    p.etat = modele.etat_port p
    p
  {adresse: adresse, disponible: MIDI_ACTIF,
    assistant: assistant_midi!,
    socket: MIDI_SOCKET,
    plateforme_libelle: modele.libelle_plateforme PLATEFORME,
    ports: modele.liste_json liste}

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
  valide, err = validation.valider_connexion_midi data
  unless valide
    send_json 400, {error: err}
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
page_audio = require "page_audio"

page = require "page"

-- Divisions (et nombre de combinaisons) affichées : celles publiées par Aeolus (noms et état réels),
-- sinon la table de repli d'orgue.moon (état inconnu).

divisions_page = ->
  e = etat_orgue!
  infos = {
    sans_backend: SANS_BACKEND
    plateforme: PLATEFORME
    audio_etat: e.qualite.audio_etat
    audio_message: e.qualite.audio_message
    midi_message: e.qualite.midi_message
  }
  e.divisions, e.steps, e.transposition or 0, infos

-- Chaque fils de requête hérite des descripteurs PCM du processus principal.
-- Les lâcher avant de servir : sinon le périphérique reste occupé après une
-- fermeture côté fil audio, et la sortie ne peut plus se rouvrir.
_G.OnWorkerStart = ->
  pcall organum.oublier_audio
  return

_G.OnHttpRequest = ->
  path = GetPath!
  -- Contrôle d'accès facultatif, dans cet ordre : une source hors des
  -- sous-réseaux autorisés reçoit 403 avant toute analyse Digest (sans défi
  -- WWW-Authenticate) ; l'authentification vient ensuite. Les adresses
  -- strictement locales (127.0.0.1 et ::1) échappent aux deux ; la fenêtre
  -- native n'emprunte pas HTTP. Ces deux réglages couvrent toutes les
  -- routes, y compris les pages, les API et l'attente longue.
  ip = GetClientAddr!
  unless controle_acces.source_locale ip
    return unless reseaux_autoriser ip
    return unless auth_autoriser!
  if path == "/api/reseaux"
    handle_reseaux!
    return
  if path == "/api/authentification"
    handle_authentification!
    return
  -- Diagnostic opt-in : teste la règle C du niveau de charge sans moteur.
  if os.getenv("ORGANUM_DIAGNOSTIC") == "1" and path == "/api/diagnostic/charge"
    pointe = tonumber(GetParam "pointe") or 0
    recents = tonumber(GetParam "xruns") or 0
    evaluee = GetParam("evaluee") == "1"
    send_json 200, {niveau: organum.charge_niveau pointe, recents, evaluee}
    return
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
    Write page_midi MIDI_SOCKET, HELPER and HELPER.etat, HELPER and HELPER.log
  elseif path == "/audio"
    SetStatus 200
    SetHeader "Content-Type", "text/html; charset=utf-8"
    Write page_audio(qualite_etat!.audio_message)
  elseif path == "/qualite"
    -- Anciens signets : le panneau « Qualité » est devenu « Audio ».
    SetStatus 302
    SetHeader "Location", "/audio"
    Write ""
  elseif path == "/"
    SetStatus 200
    SetHeader "Content-Type", "text/html; charset=utf-8"
    divisions, steps, transposition, infos = divisions_page!
    Write page divisions, steps, transposition, infos
  else
    Route!