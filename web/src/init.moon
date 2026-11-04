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
TAUX_VALIDES = {[44100]: true, [48000]: true}
PERIODES_VALIDES = {[128]: true, [256]: true, [512]: true, [1024]: true, [2048]: true}
DEMARRAGE_DEFAUT = {periode: 512, taux: 48000, peripherique: "", limiteur: true}

entier_borne = (v, min, max) ->
  type(v) == "number" and v == math.floor(v) and v >= min and v <= max

-- Un périphérique audio est un nom ALSA : au plus 200 octets, sans caractère
-- de contrôle (une chaîne vide désigne le périphérique par défaut).
peripherique_valide = (s) ->
  return false unless type(s) == "string" and #s <= 200
  for i = 1, #s
    b = s\byte i
    return false if b < 32 or b == 127
  true

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
  q = qualite_fichier QUALITE_FICHIER
  if q
    niveau = q.niveau
    niveau = qualite_locale.niveau unless type(niveau) == "number"
    auto = q.auto
    auto = qualite_locale.auto unless type(auto) == "boolean"
    tete = q.tete_reverb
    tete = qualite_locale.tete_reverb unless type(tete) == "boolean"
    periode = q.periode
    periode = qualite_locale.periode unless PERIODES_VALIDES[periode] == true
    taux = q.taux
    taux = qualite_locale.taux unless TAUX_VALIDES[taux] == true
    peripherique = q.peripherique
    peripherique = qualite_locale.peripherique unless peripherique_valide peripherique
    limiteur = q.limiteur
    limiteur = qualite_locale.limiteur unless type(limiteur) == "boolean"
    return {niveau: niveau, auto: auto, tete_reverb: tete,
            periode: periode, taux: taux, :peripherique, :limiteur}
  {
    niveau: qualite_locale.niveau, auto: qualite_locale.auto,
    tete_reverb: qualite_locale.tete_reverb,
    periode: qualite_locale.periode, taux: qualite_locale.taux,
    peripherique: qualite_locale.peripherique, limiteur: qualite_locale.limiteur
  }

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
EFFECTIF = {
  taux: qualite_locale.taux
  periode: qualite_locale.periode
  peripherique: qualite_locale.peripherique
  limiteur: qualite_locale.limiteur
}
IMPOSE = {taux: false, periode: false, peripherique: false, limiteur: false}
AUDIO_REPLI = ""

do
  v = os.getenv "ORGANUM_TAUX"
  if v and v != ""
    n = math.tointeger tonumber v
    if n and TAUX_VALIDES[n] == true
      EFFECTIF.taux = n
      IMPOSE.taux = true
    else
      Log kLogWarn, "organum : ORGANUM_TAUX invalide (#{v}), ignoré"
  v = os.getenv "ORGANUM_PERIODE"
  if v and v != ""
    n = math.tointeger tonumber v
    if n and PERIODES_VALIDES[n] == true
      EFFECTIF.periode = n
      IMPOSE.periode = true
    else
      Log kLogWarn, "organum : ORGANUM_PERIODE invalide (#{v}), ignoré"
  v = os.getenv "ORGANUM_PERIPHERIQUE"
  if v != nil
    if peripherique_valide v
      EFFECTIF.peripherique = v
      IMPOSE.peripherique = true
    else
      Log kLogWarn, "organum : ORGANUM_PERIPHERIQUE invalide, ignoré"
  v = os.getenv "ORGANUM_LIMITEUR"
  if v and v != ""
    EFFECTIF.limiteur = v != "non"
    IMPOSE.limiteur = true

taux_demarrage = EFFECTIF.taux
periode_demarrage = EFFECTIF.periode
calibration_demarrage = nil

-- Calibration automatique, uniquement quand auto est vrai (premier lancement,
-- ORGANUM_QUALITE=auto, ou état sauvegardé en mode auto). Elle se fait AVANT
-- organum.demarrer : le micro-banc ne dépend pas du moteur. En cas d'échec
-- ou de dépassement de 1,5 s, repli sur le niveau 3 sans jamais planter.
if qualite_locale.auto
  ok_cal, cal = pcall(organum.calibrer, {
    taux: taux_demarrage
    periode: periode_demarrage
  })
  valide = ok_cal and type(cal) == "table" and
    entier_borne(cal.niveau, 0, 3) and
    type(cal.duree_calibration_ms) == "number" and
    cal.duree_calibration_ms <= 1500
  if valide
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
  signature = "#{e.seq}|#{q.niveau}|#{q.auto}|#{q.tete_reverb}|#{q.periode}|#{q.taux}|#{q.peripherique}|#{q.limiteur}"
  return if signature == seq_sauve
  seq_sauve = signature
  dossier = ETAT_FICHIER\match "^(.*)/[^/]*$"
  unix.makedirs dossier, tonumber("755", 8) if dossier
  contenu = EncodeJson {
    moteur: organum.sauvegarder!
    volume: e.volume, reverb: e.reverb
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
    ouvert, raison = lancer organum, nk, {titre: "organum", :volume, :midi, :qualite, continuer: -> unix.getppid! == maitre}
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
  etat_qualite = {
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
    niveau: q.niveau
    auto: q.auto
  }
  etat_qualite.calibration = calibration_demarrage if calibration_demarrage
  etat_qualite

-- Applique des réglages de qualité (même chemin pour POST /api/orgue et pour
-- la fenêtre native). Renvoie la réponse, ou nil et un message français.
-- Tous les réglages s'appliquent à chaud : les champs à hot passent par le
-- moteur, les réglages audio par une demande de reconfiguration unique. Un
-- échec audio est publié de façon asynchrone dans audio_erreur.
regler_qualite = (q) ->
  return nil, "qualite doit être un objet" unless type(q) == "table"
  connus = {
    bruit_attaque: true, instabilite: true, spatialisation: true,
    polyphonie_max: true, tete_reverb: true, niveau: true, auto: true,
    periode: true, taux: true, peripherique: true, limiteur: true
  }
  nq = 0
  for k in pairs q
    return nil, "qualite : champ inconnu : #{k}" unless connus[k]
    nq += 1
  return nil, "qualite : aucun champ" unless nq > 0
  if q.bruit_attaque != nil and type(q.bruit_attaque) != "boolean"
    return nil, "qualite.bruit_attaque doit être un booléen"
  if q.instabilite != nil and type(q.instabilite) != "boolean"
    return nil, "qualite.instabilite doit être un booléen"
  if q.spatialisation != nil and not entier_borne q.spatialisation, 0, 2
    return nil, "qualite.spatialisation doit être un entier entre 0 et 2"
  if q.polyphonie_max != nil and not entier_borne q.polyphonie_max, 0, 512
    return nil, "qualite.polyphonie_max doit être un entier entre 0 et 512"
  if q.tete_reverb != nil and type(q.tete_reverb) != "boolean"
    return nil, "qualite.tete_reverb doit être un booléen"
  if q.niveau != nil and not entier_borne q.niveau, 0, 3
    return nil, "qualite.niveau doit être un entier entre 0 et 3"
  if q.auto != nil and type(q.auto) != "boolean"
    return nil, "qualite.auto doit être un booléen"
  if q.periode != nil and not (type(q.periode) == "number" and PERIODES_VALIDES[q.periode] == true)
    return nil, "qualite.periode doit valoir 128, 256, 512, 1024 ou 2048"
  if q.taux != nil and not (type(q.taux) == "number" and TAUX_VALIDES[q.taux] == true)
    return nil, "qualite.taux doit valoir 44100 ou 48000"
  if q.peripherique != nil and not peripherique_valide q.peripherique
    return nil, "qualite.peripherique doit être une chaîne de 200 octets au plus, sans caractère de contrôle"
  if q.limiteur != nil and type(q.limiteur) != "boolean"
    return nil, "qualite.limiteur doit être un booléen"

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
    qualite: qualite_etat!
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

  actions = {stop: true, cancel: true, step: true, reverb: true, panic: true, gain: true, link: true, qualite: true}
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

  elseif data.qualite != nil
    reponse, err = regler_qualite data.qualite
    if reponse
      send_json 200, reponse
    else
      send_json 400, {error: err}
    return

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
page_qualite = require "page_qualite"

page = require "page"

-- Divisions (et nombre de combinaisons) affichées : celles publiées par Aeolus (noms et état réels),
-- sinon la table de repli d'orgue.moon (état inconnu).

divisions_page = ->
  e = etat_orgue!
  e.divisions, e.steps

-- Chaque fils de requête hérite des descripteurs PCM du processus principal.
-- Les lâcher avant de servir : sinon le périphérique reste occupé après une
-- fermeture côté fil audio, et la sortie ne peut plus se rouvrir.
_G.OnWorkerStart = ->
  pcall organum.oublier_audio
  return

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
  elseif path == "/qualite"
    SetStatus 200
    SetHeader "Content-Type", "text/html; charset=utf-8"
    Write page_qualite!
  elseif path == "/"
    SetStatus 200
    SetHeader "Content-Type", "text/html; charset=utf-8"
    Write page divisions_page!
  else
    Route!