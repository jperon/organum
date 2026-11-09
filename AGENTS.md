# AGENTS.md

Notes pour les agents qui travaillent sur ce dépôt. Langue du code, des
commentaires et des messages : français.

## Vue d'ensemble

`organum.com` = redbean (cosmopolitan) + module Lua C `organum` + moteur
Aeolus (C++/JUCE) + interface web MoonScript zippée dans l'exécutable.

- Le **processus principal** de redbean (`.init.lua`) démarre le moteur et
  le fil audio (SCHED_FIFO 70 si permis). Les requêtes HTTP tournent dans
  des **processus fils** (fork par connexion).
- Fils → moteur : commandes de taille fixe (`struct commande`) écrites dans
  un tube (atomique), lues par le fil audio entre deux tampons.
- Moteur → fils : `struct etat` en mémoire partagée (`MAP_SHARED`), avec
  numéro de séquence ; `/api/orgue/attendre` fait de l'attente longue dessus.
- Persistance (`sauvegarder`) : uniquement dans le processus principal,
  depuis `OnServerHeartbeat`, par fichier temporaire + renommage.

## Fichiers clés

- `cosmo/lorganum.c` : module Lua (fil audio, MIDI, commandes, état partagé,
  associations de contrôleurs).
- `cosmo/organum.c` : enregistre le module puis inclut `tool/net/redbean.c`.
- `cosmo/BUILD.mk` : cible `o//tool/organum/organum` dans l'arbre
  cosmopolitan. Les prérequis sont en **ordre inverse** (bibliothèques
  d'abord) car l'édition des liens les reçoit inversés.
- `cosmo/cosmopolitan.patch` : correctif indispensable de `libc/dlopen`
  (TLS dans `%fs` et thunk x86-64 réactivé ; sans lui libasound plante) et
  inclusion de `tool/organum/BUILD.mk`.
- `cosmo/aide/` : programmes d'aide de `cosmo_dlopen` précompilés, tolérants
  aux versions (glibc : symboles liés à `GLIBC_2.2.5`, `_start` manuel ;
  musl). Embarqués dans `/zip/.cosmo/`, installés dans `~/.cosmo/` au
  démarrage.
- `moteur/api/aeolus_c.{h,cpp}` : API C du moteur. Modifications du moteur
  d'origine : `aeolus/division.cpp` (masque de canal d'expression) et
  `aeolus/engine.cpp` (réverbération Elveden Hall retirée, licence NC).
- `moteur/compat/` : en-têtes de remplacement pour compiler JUCE avec
  cosmocc (`__linux__` forcé, en-têtes système vides).
- `moteur/binarydata.py` + `ressources.tsv` : génèrent `BinaryData` (format
  JUCE, `.incbin`). Les **noms de ressources** dans `ressources.tsv` sont
  ceux du greffon d'origine : le moteur en dérive les noms de jeux
  référencés par `configs/default_organ.json` ; ne pas les renommer.
- `plateforme/` : `audio_*`/`midi_*`, aiguillage par `IsWindows()`.
  Sous cosmocc, `__linux__` n'est pas défini : tester avec `IsLinux()`.
  Les fichiers `cosmo/plateforme_*.c` incluent ces sources ; make ne suit pas
  ces inclusions (faire `touch` après modification).
  `audio_supportee()` rend `IsLinux() || IsWindows() || IsXnu()`,
  `midi_supportee()` rend `IsLinux() || IsWindows() || IsXnu()` (backend
  socket macOS) ;
  `organum.plateforme()` rend `"linux"`, `"windows"`, `"macos"` ou
  `"autre"`. L'aiguillage MIDI ajoute la branche socket sous `IsXnu()` ou
  quand `ORGANUM_MIDI_SOCKET` (non vide) l'impose sous Linux pour les tests ;
  l'audio macOS utilise le même principe : `audio_socket_actif()` est vrai
  sous XNU, ou sous Linux quand `ORGANUM_AUDIO_SOCKET` (non vide) l'impose
  pour les tests.
- Mode dégradé (macOS, ou `ORGANUM_SANS_BACKEND=1` pour les tests) :
  l'axe **audio** et l'axe **MIDI** sont désormais séparés. `organum.demarrer
  {sans_backend=true, midi=…}` coupe l'audio (`sans_backend`, plus l'absence
  de backend audio) et le MIDI suit `g_sans_midi` : option `midi` explicite,
  sinon comportement historique où `sans_backend` coupait aussi le MIDI.
  Avec `midi=false`, le moteur et l'état partagé existent, ni ALSA/WinMM ni
  le séquenceur ne sont ouverts, et aucune boucle de réessai audio n'est
  lancée ; le fil audio continue de lire les commandes et de publier l'état
  (20 ms d'attente par tour, sans rendu). Sur macOS, `sans_backend` peut être
  vrai (pas d'audio) tandis que `midi=true` ouvre le backend socket : le
  MIDI fonctionne sans audio, via l'assistant CoreMIDI externe (voir
  `plateforme/macos/PROTOCOLE-MIDI.md`). `struct etat` publie
  `audio_disponible` (axe audio) et `midi_disponible` (axe MIDI, désormais
  `!g_sans_midi`) ; `appliquer_demande` retient les réglages audio sans rien
  ouvrir. La décision audio se prend dans `web/src/degradation.moon`
  (`degradation.detecter`) ; seule la valeur exacte `1`
  d'`ORGANUM_SANS_BACKEND` force l'axe audio, toute autre valeur laisse Linux
  inchangé. `web/src/midi_actif.moon` décide de l'axe MIDI : backend présent,
  et `ORGANUM_SANS_BACKEND=1` le coupe sauf si `ORGANUM_MIDI_SOCKET` impose
  le socket. `organum.midi_assistant()` rend 1 (assistant connecté), 0
  (absent, avertissement unique au démarrage) ou -1 (sans objet : ALSA/WinMM
  ou MIDI non ouvert) ; `organum.midi_chemin()` donne le chemin de la socket
  sans recopier sa règle en MoonScript. `midi_actif.socket_actif`
  (`web/src/midi_actif.moon`) dit si l'aiguillage a réellement retenu le
  backend socket (macOS, ou forçage Linux ; jamais Windows) ; `GET
  /api/midi/ports` publie ce choix en `socket` à côté d'`assistant`, et
  `/midi` n'affiche son message « assistant absent » que si `socket` est
  vrai, au lieu d'inviter à lancer un assistant sous ALSA. L'échec audio reste fatal sur Linux
  quand un backend existe ; le mode dégradé n'appelle jamais `unix.exit`.
  Tests : `web/tests/degradation.lua`,
  `web/tests/midi_actif.lua`, `web/scripts/test-sans-backend.sh` et
  `web/scripts/test-midi-socket.sh` (dont MIDI socket + audio dégradé).
- États audio affichés : la règle pure
  `degradation.etat_audio {supportee, sans_backend, socket, assistant,
  disponible, erreur, assistant_etat, assistant_log}` (dans
  `web/src/degradation.moon`) distingue notamment, dans cet ordre :
  `sans_backend` (aucun backend sur la plate-forme → « Audio non pris en
  charge sur cette plate-forme. »),
  `desactive` (forçage `ORGANUM_SANS_BACKEND` ou axe coupé), `sans_sortie`
  (`audio_erreur` contient « aucune sortie audio », ACK statut 2 de
  l'assistant → « Aucune sortie audio : vérifiez Réglages Système → Son →
  Sortie. »), `incompatible` (`audio_erreur` contient « version du protocole
  audio incompatible » ou « version de l'anneau audio incompatible » : le
  message brut, qui nomme les deux versions et demande de recompiler les deux
  binaires, reste affiché), puis les états de l'assistant embarqué
  (`non_embarque` : archive sans binaire ; `extraction_impossible` ;
  `lancement_impossible`), avec le message de `web/src/assistant.moon`, puis
  `assistant_absent` (`audio_assistant == 0` → « Assistant audio absent :
  organum ne l'a pas lancé… », non alarmant).
  Audio opérationnel : `nil, nil`, aucun message. L'erreur est examinée
  **avant** l'assistant, car un ACK statut 2 ou un refus de version laisse
  aussi `audio_assistant` à 0.
  `web/src/midi_actif.moon` expose de même `midi_actif.message(disponible,
  connecte, socket, etat, log)` (« MIDI désactivé… », état précis de
  l'assistant, ou « Assistant MIDI absent… »), nil quand le MIDI fonctionne.
  `qualite_etat` publie `audio_etat`,
  `audio_message` et `midi_message` dans `/api/orgue` ; `page.moon`
  (bandeau, id `mode-degrade` conservé), `page_audio.moon` (ligne
  `qualite-plateforme`) et `fenetre.moon` (une ligne tronquée par message)
  ne font qu'afficher ces chaînes. Tests : `web/tests/degradation.lua`,
  `web/tests/midi_actif.lua`, `web/tests/pages.lua`, et les contrôles b/c/f
  de `web/scripts/test-audio-socket.sh` sur `audio_etat`/`audio_message`.
  `ORGANUM_AUDIO_SOCKET` (non vide) force le backend socket sous Linux ; le
  démarrage est alors opportuniste, comme sur macOS, ce qui permet de tester
  l'assistant absent sans carte son. `test-sans-backend.sh` garde ses
  attentes : le bandeau `id="mode-degrade"` et la ligne
  `id="qualite-plateforme"` restent présents.
- Assistant natif macOS fusionné (`plateforme/macos/`) : `assistant_helper.c`
  est un **seul** binaire Mach-O `organum-helper`, hors de la chaîne cosmocc,
  qui sert les deux protocoles : socket MIDI `organum-midi-<uid>.sock`
  (`trames_midi.h`, `PROTOCOLE-MIDI.md`) et socket audio
  `organum-audio-<uid>.sock` avec son `.pcm` (`trames_audio.h`,
  `anneau_audio.h`, `PROTOCOLE-AUDIO.md`). Les chemins et protocoles sont
  inchangés ; les backends `midi_socket.c` et `audio_socket.c` ne sont pas
  touchés. Les deux domaines ont chacun leur socket d'écoute, leur client,
  leur état et leur décodeur, et **échouent indépendamment** : CoreMIDI
  indisponible n'empêche pas l'audio, un `AudioUnit` en échec (statut
  d'ACK, ou aucune sortie) ne tue ni le MIDI ni le processus, une
déconnexion d'un client n'affecte pas l'autre axe, la perte du périphérique
  audio ne touche pas les connexions CoreMIDI. Une seule boucle `poll()`
  surveille les deux sockets d'écoute et les deux clients ; le processus ne
  sort que sur `SIGINT`/`SIGTERM` (ou si les deux domaines échouent au
  démarrage). `sh plateforme/macos/construire_assistant.sh` produit
  `plateforme/macos/build/organum-helper` (ignoré par git) : **universel**
  x86_64 + arm64 par défaut quand le SDK fournit les deux architectures,
  sinon repli explicite sur l'architecture de l'hôte ; `ARCHIVES=0` force
  l'hôte seul. Le script **signe toujours ad-hoc** (`codesign --force --sign
  -`) puis vérifie avec `codesign --verify --strict` et `codesign -dv` :
  macOS arm64 refuse d'exécuter un Mach-O non signé, même ad-hoc. Il publie
  `lipo -info` et `codesign -dv` et sort en erreur (code 3) si la signature
  ou une architecture annoncée manque. Il refuse de continuer (code 2)
  sans `xcode-select -p`. Options : `--socket-midi`, `--socket-audio`,
  `--verbose`, `--liste` (sortie audio par défaut **et** sources CoreMIDI,
  code 0 ou 1 si un axe manque), `--aide`. L'assistant sonde chaque socket
  (`connect`, `unlink` si périmée, code 3 si un autre assistant vit), possède
  la socket audio et le `.pcm` (`O_TRUNC`, `0600`,
  `ANNEAU_AUDIO_CAPACITE_MAX`), énumère les sources CoreMIDI et publie une
  `DEVICE_LIST` à chaque changement ; les `SUBSCRIBE` d'organum activent le
  filtrage par identifiant. Les rappels CoreMIDI et de rendu CoreAudio
  n'allouent ni ne bloquent. L'`AudioUnit` est
  `kAudioUnitType_Output`/`kAudioUnitSubType_DefaultOutput` avec
  `AURenderCallback`, float32 entrelacé 2 canaux au taux d'organum, avec
  repli non entrelacé désentrelacé dans le rappel ; taux changé à chaud par
  arrêt/reformatage/relance ; périphérique perdu : `arret` et `AUDIO_STOP`
  (raison 1), sans quitter. Le helper est **destiné à être lancé par
  organum** : il n'a plus la protection `LOCAL_PEERPID` de l'ancien
  assistant MIDI et meurt donc avec le groupe de processus de son parent
  (SIGTERM de redbean) ; un service permanent passe par un LaunchAgent, dans
  son propre groupe. `web/scripts/build.sh` l'embarque sous
  `.organum/organum-helper` **si le fichier existe** (avertissement sans échec
  sinon, pour construire sous Linux). Au démarrage macOS, `init.moon`
  l'extrait dans `$TMPDIR/.organum/organum-helper` (`0700`, écriture par
  fichier temporaire puis renommage), sonde les sockets pour **réutiliser**
  une instance existante (lancement manuel ou LaunchAgent), sinon le lance
  dans son groupe de processus avec sa sortie dans
  `$TMPDIR/.organum/organum-helper.log` (`ORGANUM_ASSISTANT_VERBOSE=1` ajoute
  `--verbose`). Redbean récolte lui-même tous ses fils (`wait4(-1)`) : la
  surveillance depuis `OnServerHeartbeat` ne fait donc pas de `wait` ciblé,
  elle sonde les sockets et relance ; trois échecs rapprochés, ou un `exec`
  en code 126, donnent `assistant_etat = "lancement_impossible"`. États
  publiés : `non_embarque` (archive sans binaire), `extraction_impossible`,
  `lancement_impossible`, `actif` (nil = pas concerné) ; les messages
  correspondants, en français et sans reproche, sont dans
  `web/src/assistant.moon` et repris par `degradation.moon`,
  `midi_actif.moon` et `modele.moon`. Rien de tout cela n'existe sous Linux
  (aucune extraction, aucun lancement, aucune variable). Les chemins de
  socket par défaut du helper sont bien `organum-midi-<uid>.sock` et
  `organum-audio-<uid>.sock` : `choisir_chemin` recevait `"midi"`/`"audio"`
  au lieu des préfixes complets, ce qui créait `midi<uid>.sock` et rendait
  l'assistant invisible. Tests purs : `web/tests/assistant.lua`. Mode
  d'emploi et dépannage : `plateforme/macos/LANCEMENT.md`. Après extraction,
  `init.moon` **vérifie l'intégrité** (contenu extrait identique à l'archive,
  donc non tronqué) puis **exécute l'extrait avec `--aide`** : un code non
  nul donne l'état `inutilisable` (signature absente sous arm64,
  architecture refusée, quarantaine, binaire corrompu), avec un message
  clair ; le heartbeat ne réessaie pas indéfiniment. C'est plus robuste
  qu'une simple taille attendue, car cela couvre aussi le refus d'exécution
  par le noyau. L'`xattr` de quarantaine n'est pas posé par l'écriture
  depuis le zip (vérifié sur la VM macOS) ; s'il l'était, le test `--aide`
  le signalerait. Compilé sur la VM macOS de test (clang 17,
  SDK 15.5), universel x86_64 + arm64, signature ad-hoc vérifiée, MIDI et
  audio simultanés validés sur cette VM (VMPK abonné, `audio_assistant:1`,
  `latence_ms` ≈ 56, `trames_jouees` en progression, crête non nulle dans
  l'anneau avec un jeu allumé), ainsi que les échecs indépendants par
  clients bruts, le nettoyage sur SIGTERM et la reprise après SIGKILL.
  Le demi-arm64 du helper n'est pas exercé sur cette VM x86_64 : arm64
  n'est validé que par la compilation et `lipo`/`codesign`. Le fonctionnement
  réel sur un Mac Apple Silicon avec clavier physique reste à confirmer.
- **CI et binaire universel** : le job `assistant-macos` de
  `.github/workflows/rolling.yml` (runner `macos-latest` hébergé) ne fait que
  compiler et signer le helper et le loader arm64 (ni cosmocc ni moteur), et
  les publie comme artefacts `organum-helper` et `ape-m1-arm64` ; le job
  Linux les télécharge dans `plateforme/macos/build/` avant
  `scripts/construire.sh`, donc l'`organum.com` de la CI embarque le helper
  et le loader. Si un artefact manque (job macOS en échec), le job Linux
  continue avec un avertissement : sans helper, ou avec le repli
  `ape-m1.c`. Le job `validation-arm64` (runner Apple Silicon `macos-latest`,
  sans reconstruction) télécharge l'artefact `organum-com`, vérifie
  `uname -m` = arm64 et `sysctl -n sysctl.proc_translated` = 0, lance le
  binaire avec un faux `cc` qui échoue en tête de `PATH` (et vérifie qu'il
  n'a pas été appelé), contrôle la signature du helper extrait, affiche
  `organum-helper --liste`, puis exécute **deux scénarios distincts** :
  d'abord le mode dégradé forcé (`ORGANUM_SANS_BACKEND=1`, aucun backend),
  ensuite `plateforme/macos/tests/valider_audio_midi.sh` **sans forçage**,
  qui valide le chemin réel audio et MIDI.
  **Ce que le runner macOS offre réellement** (mesuré le 2026-11-09, run
  `42651520609`, ne pas le supposer) : `system_profiler SPAudioDataType`
  annonce « Apple Virtual Sound Device », sortie par défaut, 2 canaux,
  48 kHz ; la sonde `plateforme/macos/tests/sonde_audio.c` compte
  « rappels de rendu en 1 s : 99 » (code 0) ; `sonde_midi.c` rend
  « MIDI fonctionnel (source virtuelle, note reçue) » (code 0) ; le session
  graphique existe (`who` → console, `launchctl print gui/501` → 0) et
  `organum-helper --liste` voit la sortie audio. Aucun matériel physique
  n'est branché, mais les deux chemins CoreAudio et CoreMIDI sont donc
  exerçables en CI.
  Contrôles du script : `audio_disponible`, `audio_assistant = 1`,
  `latence_ms > 0`, `audio_demarre`, cadence sur 3 s à ≤ 2 % de `taux`,
  `xruns`/`xruns_recents` à 0, puis MIDI de bout en bout (source virtuelle
  CoreMIDI `emetteur_midi.c` → assistant → socket → orgue :
  `canaux_actifs` non vide, puis revenu à vide au relâchement). Mesure
  réelle du 2026-11-09 (run `42653100117`, 10 s pour le script) :
  « latence audio publiée (55.416 ms, taux 48000 Hz) », « cadence sur 3 s :
  151040 trames pour 149263 attendues (119‱ d'écart, ≤ 2 %) », « note
  CoreMIDI reçue, canaux_actifs non vide ([1]) », « relâchement vu,
  canaux_actifs revenu à vide ». Le scénario dégradé volontaire reste
  nécessaire : il prouve le repli, alors que le second prouve le chemin
  nominal. **Piège de l'émetteur MIDI** : `MIDIPacketListAdd` attend un
  horodatage en **ticks Mach** ; zéro signifie « maintenant ». Un
  horodatage en nanosecondes (`CLOCK_MONOTONIC`) place la note très loin
  dans le futur et elle n'arrive jamais (constaté : aucune activité dans
  `/api/midi`). **Piège de la mesure de cadence** : prendre `trames_jouees`
  dans un JSON périmé (dernière requête d'attente) surestime la cadence de
  ~2,5 % ; le script relit `/api/orgue` juste avant la mesure.
  **Limites** : pas de carte son physique (donc pas de mesure de latence
  audible ni de périphérique USB), pas de test du LaunchAgent ni de
  quarantaine (l'assistant est lancé par organum), et les suites Linux
  (`tests-longs.sh`, `tests-e2e.sh`) ne tournent pas sur macOS. Le helper
  extrait s'exécute bien dans sa tranche arm64 sur ce runner (contrairement
  à l'ancienne VM x86_64) ; la tranche x86_64 du helper reste seulement
  vérifiée par `lipo`/`codesign`.
  Les sondes `plateforme/macos/tests/sonde_audio.c` et `sonde_midi.c`
  restent utilisables à la main (`clang -framework …`) pour reposer la
  question si une image de runner change.
  **Un `organum.com` construit localement sur Linux n'a pas de helper ni de
  loader arm64** (build.sh avertit), sauf si l'on place ces fichiers dans
  `plateforme/macos/build/` avant `web/scripts/build.sh`.
  **Étiquette de runner macOS** : ne pas coder `macos-14`. GitHub a retiré
  cette image (`actions/runner-images` : `macos-14*` s'arrête au 31/08/2026)
  et répond « The configuration 'macos-14-arm64-us-default' is not
  supported » : aucun runner n'est accordé, le job se termine en ~1 s sans
  aucune étape, ce qui ressemble à une erreur de code alors que seul le label
  est invalide. Les deux jobs macOS utilisent donc `macos-latest` (résout en
  `macos-26-arm64`) et **vérifient l'architecture dans le job** (`uname -m`,
  `sysctl -n sysctl.proc_translated`) au lieu de se fier à l'étiquette.
- **architectures macOS** : `scripts/construire.sh` produit désormais par
  défaut un APE **universel x86-64 + arm64** : moteur x86-64 et aarch64
  (`moteur/Makefile` avec `ARCH=aarch64`, objets `o-aarch64/`, archive
  `libaeolus-aarch64.a`), exécutables x86-64 et aarch64, puis fusion
  `apelink -l ape-x86_64.elf -l ape-aarch64.elf` avec, si présent,
  `plateforme/macos/build/ape-m1-arm64` (loader Mach-O arm64 précompilé et
  signé, sinon `-M ape/ape-m1.c` avec Xcode CLT requis au premier
  lancement). `web/scripts/build.sh` n'est appelé qu'une fois sur l'APE
  fusionné : le zip d'interface est partagé. `ORGANUM_UNIVERSEL=0` force
  l'ancien APE x86-64 ; tout échec aarch64 se replie dessus sans faire
  échouer la construction. `scripts/dependances.sh` complète
  `externe/cosmocc/aarch64-linux-cosmo/lib` depuis
  `externe/cosmopolitan/o/aarch64/` s'il manque (idempotent). Le loader est
  produit par `plateforme/macos/construire_loader.sh`, appelé par
  `construire_assistant.sh`, à partir de la copie fidèle
  `plateforme/macos/ape-m1.c` (ISC, `-mmacosx-version-min=11.0`).
- Horloge sous XNU (piège `CLOCK_MONOTONIC`) : sous XNU x86-64, cosmocc
  reconstitue `CLOCK_MONOTONIC` depuis le TSC avec un diviseur supposant
  3 GHz (`libc/intrin/clock_gettime-mono.c:80`) ; sur une VM à 0,88 GHz, il
  avance à ~0,29 × le temps réel (un recul d'une seconde durait 3,4 s).
  Règle : toute **durée humaine** (fenêtre d'activité, réessais audio, recul
  de reconnexion MIDI) se mesure avec `horloge_mur()` — `CLOCK_REALTIME` sous
  XNU, `CLOCK_MONOTONIC` ailleurs — définie dans `cosmo/lorganum.c` et
  reprise localement dans `plateforme/macos/midi_socket.c`. `CLOCK_REALTIME`
  peut sauter vers l'arrière : un reste négatif vaut échéance atteinte, et un
  reste supérieur au plus long recul normal (`MIDI_SOCKET_DELAI_VERSION` +
  marge) aussi, sinon un saut NTP repousserait la reconnexion. En revanche,
  deux lectures rapprochées pour un pourcentage (mesure de charge du fil
  audio) gardent `CLOCK_MONOTONIC` : un diviseur TSC faux n'affecte pas le
  rapport, et l'absence de saut NTP le protège. `attendre_tampon_null()` le
  garde aussi car il doit être le même que `clock_nanosleep` ; la sortie
  « null » ne concerne pas macOS. Le faux assistant `faux_assistant.c` est
  compilé par le cc de l'hôte, pas par cosmocc : son `CLOCK_MONOTONIC` est
  celui de la libc native et n'a pas ce défaut. Tests :
  `plateforme/tests/horloge_midi_socket.c` (horloge simulée, recul mural et
  saut arrière) et le contrôle `j` de `web/scripts/test-midi-socket.sh`
  (reconnexion réelle ≤ 2 s).
- `web/src/init.moon` : démarrage, API HTTP (`/api/orgue`, `/api/midi`,
  `/api/volume`), persistance. `POST /api/orgue {"volume":0..1}` règle le
  volume du moteur (pédale), distinct de `/api/volume` (volume système), déjà
  persisté et pilotable par une association MIDI de cible « volume ».
  `page.moon` (orgue), `page_midi.moon`
  (`/midi`), `page_audio.moon` (`/audio`, panneau « Audio » ; `/qualite`
  redirige vers `/audio`), `client.moon` (JS de la page orgue),
  `style.moon` : interface. `web/src/.lua/html.moon` : générateur
  HTML.
- Réglages de qualité : champs du moteur dans `cosmo/lorganum.c`
  (`CMD_QUALITE`, fonction Lua `organum.qualite`, `organum.demarrer{qualite,
  tete_reverb}`) ; présélections, validation de `POST /api/orgue {qualite}`,
  `ORGANUM_QUALITE` et persistance (clé `qualite` d'`etat.json`) dans
  `web/src/init.moon`, panneau dédié `web/src/page_audio.moon`. Tous les
  réglages s'appliquent à chaud, sans bouton
  de redémarrage : limiteur (`CMD_LIMITEUR`) et tête (`CMD_TETE`) par le
  tube, période/taux/périphérique par `organum.reconfigurer_audio{...}`
  (`CMD_RECONFIG`, demande complète dans le mmap partagé). Le fil audio
  ferme et rouvre la sortie entre deux tampons ; en cas d'échec il rouvre
  l'ancienne configuration et publie `qualite.audio_erreur`, en réessayant
  toutes les ~1 s si même l'ancienne échoue. Un changement de taux recrée le
  moteur (sauvegarde, création, restauration, volume/réverbération/gains/
  qualité/limiteur/tête réappliqués), sous un verrou partagé avec
  `organum.sauvegarder`. `X` est la valeur effective publiée par le fil
  audio, `X_prochain` la valeur enregistrée, `X_impose` une variable
  d'environnement prioritaire ; `ORGANUM_TAUX`, `ORGANUM_PERIODE`,
  `ORGANUM_PERIPHERIQUE` et `ORGANUM_LIMITEUR` ne sont jamais recopiés dans
  la valeur enregistrée. Si un réglage enregistré non imposé empêche
  l'ouverture audio au démarrage, `init.moon` réessaie une fois avec les
  défauts et publie `qualite.audio_repli` ; pour cela `l_demarrer` libère
  tout sur échec audio ou MIDI. Calibration automatique :
  `organum.calibrer` dans `cosmo/lorganum.c` appelle `aeolus_calibrer`
  (`moteur/api/aeolus_c.h`, micro-banc autonome) ; `init.moon` la lance
  avant `organum.demarrer` quand `auto` est vrai (premier lancement ou
  `ORGANUM_QUALITE=auto`), avec le taux et la période retenus, applique la
  présélection retenue, se replie sur le niveau 3 au-delà de 1,5 s, et expose
  le résultat dans `qualite.calibration`.
- Tempérament : `moteur/aeolus/scale.h` définit 11 types (`Scale::Type`,
  égal par défaut) ; `moteur/api/aeolus_c.{h,cpp}` expose
  `aeolus_nb_temperaments`, `aeolus_nom_temperament`,
  `aeolus_temperament` (reconstruit les jeux de tuyaux et bascule) et
  `aeolus_lire_temperament`. Le recalcul (`retunePipes` dans le jeu de
  tuyaux parallèle puis `prepareToPlay`, `engine.cpp`) est long (2 à 3 s) :
  `cosmo/lorganum.c` le fait dans un fil dédié, jamais dans le fil audio,
  sous `g_moteur_verrou` (aucune course avec `organum.sauvegarder` ni avec
  une reconfiguration) ; le son tenu continue sur l'ancien jeu et n'est
  basculé qu'une fois le nouveau prêt. Une petite section de la mmap
  partagée porte la dernière demande, un compteur demandes/traitées et le
  verrou associé ; `qualite.application` couvre donc aussi le tempérament.
  Seule la dernière demande rapprochée compte, les précédentes restant
  comptées jusqu'au calcul qui les couvre. Lua : `organum.temperament(type)`
  et option `temperament` de `organum.demarrer`. `POST /api/orgue
  {"temperament": N}` (entier 0..10, sinon 400) et `GET /api/orgue`
  (`temperament`) ; clé `temperament` d'`etat.json`, absente ou invalide =
  égal (5). Libellés français dans `modele.TEMPERAMENTS`, utilisés par
  `page_audio.moon` et `fenetre.moon` (deux rangées de 11 boutons au
  panneau Audio). Le changement de taux recrée le moteur : `recreer_moteur`
  capture et réapplique le tempérament. MTS reste désactivé dans
  `aeolus_creer`, sans priorité sur notre valeur (le fichier de réglages
  utilisateur d'Aeolus, `~/.config/Aeolus.settings`, est écrasé par
  l'application explicite au démarrage).
- Transposition globale : décalage de −12 à +12 demi-tons appliqué à toutes
  les notes MIDI entrantes, jamais persisté (remis à 0 à chaque démarrage ;
  absent d'`etat.json` et des combinaisons). Le filtre est
  `cosmo/transposition.h` (règle pure, testée en C natif par
  `cosmo/tests/transposition.c`) : table fixe `int8_t[16][128]` des notes
  réellement envoyées, appui sur 0x9n vélocité > 0, relâchement sur 0x8n ou
  0x9n vélocité 0 (renvoie la note retenue, même si le réglage a changé
  entre-temps), pression polyphonique 0xAn décalée via la même table, notes
  hors 0..127 ignorées à l'appui comme au relâchement, tous les autres
  messages inchangés. Aucun verrou, allocation, appel système ni Lua dans le
  fil audio ; la table n'est touchée que par ce fil et remise à zéro par
  `panique()` et `recreer_moteur()`. Valeur effective dans `g_transposition`
  (fil audio), commande `CMD_TRANSPOSITION` par le tube, publiée dans
  `struct etat` (avance de `seq`). Lua : `organum.transposition(n)` borne
  −12..12. `POST /api/orgue {"transposition": N}` (entier −12..12, sinon
  400, validation dans `web/src/validation.moon`) et `GET /api/orgue`
  publient `transposition`. Interface : bloc « Transposition » (−, valeur
  signée, +) en bas de la colonne du Manuel III dans `web/src/page.moon` /
  `client.moon` / `style.moon` et `web/src/fenetre.moon` (la colonne est
  choisie par `modele.colonne_transposition` : Manuel III, sinon première
  division sans accouplement) ; valeur non nulle accentuée, bornes inactives,
  cibles web ≥ 44 px. Un clic sur la valeur centrale (page web et fenêtre
  native) remet la transposition à 0. Côté natif, le signe moins est l'hyphen ASCII (la
  police latin embarquée n'a pas U+2212). Tests réels :
  `web/scripts/test-transposition.sh`, e2e web et natif (dont croisé),
  `scripts/tests-unitaires.sh` pour l'en-tête C.
- Authentification facultative HTTP Digest SHA-256 (RFC 7616, `qop=auth`,
  royaume `organum`) : désactivée sans mot de passe ; ne sert qu'à vérifier
  les droits, sans chiffrement. Règles pures dans
  `web/src/authentification.moon` (analyse de l'en-tête, de la réponse et du
  fichier texte, nonce sans état horodaté et signé par HMAC-SHA256,
  comparaisons à temps constant), testées avec le vecteur de la RFC.
  Persistance dans un fichier texte éditable à la main, voisin d'`etat.json`
  : `etat.json.digest` (0600) ou le chemin donné par `ORGANUM_DIGEST`
  (absent ou vide : chemin par défaut). Une seule entrée
  `utilisateur:organum:HA1`, HA1 = SHA-256 hexadécimal de
  `utilisateur:organum:motdepasse` ; lignes vides et commentaires `#`
  admis, plusieurs entrées refusées. `web/src/init.moon` applique la garde en
  tête de `_G.OnHttpRequest` (toutes les routes, attente longue comprise),
  exempte uniquement `127.0.0.1` et `::1` via `GetClientAddr`, et publie
  `/api/authentification` (GET/POST, retrait). Fichier absent ou sans entrée :
  pas de contrôle ; fichier présent mais invalide ou illisible : l'orgue
  démarre quand même, mais `503` pour les sources non locales, erreur publiée
  dans l'API et les deux interfaces, accès local conservé. Le fichier est relu
  à chaque requête ; depuis `127.0.0.1` ou `::1`, `GET /audio` et
  `GET`/`POST /api/authentification` restent utilisables et un POST valide
  écrase le fichier invalide et rétablit le contrôle. Durée du nonce réglable seulement par
  `ORGANUM_AUTH_NONCE_DUREE` pour les tests, 5 min par défaut. Seule la page
  web règle le mot de passe ; la fenêtre native n'affiche qu'une ligne d'état
  en lecture seule et ne saisit plus de texte. Tests :
  `web/scripts/test-authentification.sh` (curl --digest, 401, stale=true,
  exemption locale, fichier écrit à la main avec `sha256sum`, fichier 0600,
  fichier invalide au démarrage et à chaud, variable vide) et
  `scripts/e2e-auth.mjs` (Chromium headless sur adresse non locale).
- Contrôle d'accès facultatif par sous-réseau source, indépendant de
  l'authentification : `web/src/controle_acces.moon` (module pur, analysé par
  `web/tests/controle_acces.lua`). Quatre cas : liste vide sans mot de passe =
  aucun contrôle ; liste vide avec mot de passe = Digest seul ; liste remplie
  sans mot de passe = sous-réseau seul ; les deux = sous-réseau PUIS Digest.
  Exception unique : `127.0.0.1` et `::1` passent toujours, et la fenêtre
  native n'emprunte pas HTTP. Source hors liste : `403` avant toute analyse
  Digest, sans `WWW-Authenticate`. L'adresse vient de `GetClientAddr` (jamais
  `X-Forwarded-For`) ; `::ffff:a.b.c.d` est traitée comme IPv4 et la zone
  d'une lien-local n'entre pas dans la comparaison (GetClientAddr la retire,
  vérifié sur connexion réelle). Analyse stricte : adresse seule = /32 ou
  /128, formes compressées et casse IPv6 admises, masques hors bornes et
  adresses invalides refusés, **bits d'hôte non nuls refusés** (choix
  documenté). Comparaison bit à bit, sans bibliothèque ajoutée ; `ParseIp`
  n'est pas utilisé (trop permissif : `1.2.3` et `1.2.3.4.5` passent).
  Persistance dans un fichier texte éditable à la main, voisin d'`etat.json`
  : `etat.json.reseaux` (0600) ou le chemin donné par
  `ORGANUM_RESEAUX_FICHIER` (absent ou vide : chemin par défaut), un
  sous-réseau par ligne suivi d'un commentaire facultatif
  (`10.35.0.0/16 # chapelle`), lignes vides et lignes de commentaire admises,
  lecture à chaque requête ; fichier absent ou sans entrée = aucun filtrage.
  Fichier présent mais invalide ou illisible : l'orgue démarre quand même,
  mais `503` pour les sources non locales, erreur publiée, accès local
  conservé ; un POST local valide rétablit le contrôle. Le commentaire
  n'entre jamais dans le contrôle d'accès. Routes `GET/POST /api/reseaux`
  par entrées `{reseau, commentaire}` (commentaire ≤ 200 octets, sans saut de
  ligne) ; une liste non vide qui exclut la source HTTP courante est refusée
  (400), sauf source locale. L'écriture depuis le web conserve les
  commentaires d'entrée mais perd les lignes qui ne sont qu'un commentaire
  (signalé dans l'interface). Panneau Audio web (`page_audio.moon`) : une
  rangée par sous-réseau (sous-réseau, commentaire, retrait) plus un bouton
  d'ajout, cibles ≥ 44 px. La fenêtre native (`fenetre.moon`) n'affiche
  qu'une ligne d'état en lecture seule, sans commentaires. Tests réels :
  `web/scripts/test-reseaux.sh`, lancé par `scripts/tests-longs.sh`.

- Puce d'adaptation à la machine : le fil audio mesure le rendu avec deux
  `clock_gettime(CLOCK_MONOTONIC)` par tampon (vDSO sous Linux, donc sans
  appel système), hors attente d'écriture. Pour chaque seconde pleine, la
  moyenne des tampons de cette seconde est retenue quand des voix sonnent (les
  secondes sans voix valent 0) ; `qualite.charge_pointe` est le maximum de ces
  moyennes sur un anneau fixe de 60 secondes, remis à zéro par
  `mesure_reinitialiser`. Une préemption isolée est donc lissée sur la seconde.
  Il publie aussi `qualite.charge` (moyenne ~1 s), `qualite.charge_evaluee`
  (1 s de jeu mesurée), la seconde partielle en cours n'étant jamais comptée,
  `qualite.charge_niveau` (0 gris, 1 vert, 2 orange, 3 rouge, calculé en C au
  plus une fois par seconde), `qualite.xruns` et `qualite.xruns_recents`
  (anneau de 60 s, hors `application` et hors trois secondes suivant une
  reconfiguration ou une bascule de tête). Un réglage remet à zéro la mesure,
  les xruns récents et le niveau publié (avec avance de `seq` si le niveau
  change), toujours dans le fil audio. `seq` ne change que si le niveau ou
  les xruns changent, jamais pour un pourcentage ; `charge` et `charge_pointe`
  s'écrivent sans réveiller les attentes. `modele.CHARGE_NIVEAUX` traduit le
  niveau en libellé et classe CSS pour le web et la fenêtre. Le point
  d'entrée `organum.charge_niveau(pointe, xruns, evaluee)` et la route
  `/api/diagnostic/charge` (si `ORGANUM_DIAGNOSTIC=1`) testent la règle C.

- `ui/fenetre.h` : fenêtre sans bibliothèque ; `ui/wayland.c` et `ui/x11.c`
  parlent les protocoles directement sur la socket du serveur (aucun
  dlopen). `cosmo/lnuklear.c` : module Lua `nk` (Nuklear, rendu logiciel
  rawfb, police recuite à la taille voulue). `web/src/fenetre.moon` :
  console d'orgue, lancée par `init.moon` dans un processus fils
  (`ORGANUM_FENETRE=non` pour s'en passer). Avec un volume système, deux
  curseurs distincts : « Volume » (système) et « Pédale » (volume du moteur,
  avec sa valeur en %) ; sans lui, le curseur unique règle déjà le moteur.
  La réverbération n'est plus sur la console principale : elle est réglée
  dans le panneau « Audio », comme le curseur de la page web.
  Exigence : tout doit tenir dans la fenêtre, sans défilement, et grossir
  quand elle est agrandie. La police visée croît avec la largeur de la
  fenêtre ; parmi 1 à 3 sous-colonnes, on maximise d'abord la police
  jusqu'à cette cible, puis la hauteur des boutons. Les rangées de
  réglages, combinaisons, nom et gain prennent environ 2,2 × police (36 px
  si la place le permet) et toute la hauteur restante est répartie entre
  jeux et accouplements. Un nom de jeu trop large est coupé en deux lignes
  équilibrées par `ui:choix_deux` (`cosmo/lnuklear.c`) ; sur une ligne, le
  rendu reste celui de `ui:choix`.
  Essai hors moteur : `ui/essai_fenetre.moon` (état factice). X11 : socket
  Unix pour `:n`, TCP (port 6000+n) pour `hôte:n` ; testable sans
  rien ouvrir sur le bureau avec `Xvfb :2 -listen tcp -ac` et `DISPLAY=localhost:2`
  (ne pas utiliser Xephyr, qui ouvre une fenêtre).

## Construire et tester

```bash
scripts/construire.sh                 # tout ; résultat web/build/organum.com
make -C moteur -j                     # moteur seul
make -C externe/cosmopolitan -j m= o//tool/organum/organum
web/scripts/build.sh                  # réassemble seulement l'interface
make -C externe/cosmopolitan -j m= o//tool/organum/organum-web
ORGANUM_WEB=1 web/scripts/build.sh    # variante sans UI native : web/build/organum-web.com
```

Test rapide : lancer `web/build/organum.com -p 8099`, puis
`curl localhost:8099/api/orgue`. Un clavier MIDI virtuel suffit pour le MIDI.

Les programmes d'aide de `cosmo_dlopen` (`cosmo/aide/`) sont reconstruits à
chaque `scripts/construire.sh` avec le `cc` de l'hôte, puis embarqués dans
`/zip/.cosmo/` (`web/scripts/build.sh`) et installés dans `~/.cosmo/` au
démarrage. Ils sont liés aux symboles `GLIBC_2.2.5` par
`cosmo/aide/versions-glibc.h`, afin de fonctionner sans compilateur sur une
machine cible plus ancienne. Le script compile en `-std=gnu11` : à partir de
GCC 15 (C23 par défaut), les en-têtes de la glibc 2.38+ redirigent `strtol`
vers `__isoc23_strtol@GLIBC_2.38`, que les `.symver` ne couvrent pas ; la
vérification finale (`objdump -T`, aucune version postérieure à 2.2.5) refuse
un tel binaire. Si elle échoue, ajouter le `.symver` du symbole en cause dans
`versions-glibc.h` (ou une option qui évite la redirection C23), jamais
contourner le contrôle. La variante musl n'est construite que si `musl-gcc`
est présent (un avertissement suffit sinon). Les binaires produits sont ignorés
par git : rien à mettre à jour dans le dépôt, il suffit de relancer
`scripts/construire.sh`.

Quatre commandes, du plus rapide au plus complet :

```bash
scripts/tests-unitaires.sh            # ~3 s : MoonScript, Lua, C/C++ purs
scripts/tests-longs.sh                # API qualité, bancs moteur, plate-forme
scripts/tests-e2e.sh                  # web (Chromium) et natif (Xvfb/xdotool)
scripts/tests.sh                      # les trois, arrêt au premier échec
scripts/tests.sh --rapide             # unitaires seulement
```

`tests-unitaires.sh` compile tous les `.moon` avec `moonc`, les exécute avec
`redbean -i` (Lua 5.4), vérifie la syntaxe JavaScript avec `node --check`,
lint les globales MoonScript (liste explicite, toute nouvelle globale
échoue), et éprouve les règles C/C++ pures (`cosmo/charge_niveau.h`,
`moteur/tests/scale_tables.cpp`). La disposition et les validations ont été
extraites dans `web/src/fenetre_disposition.moon` et `web/src/validation.moon`
pour être testables sans Nuklear ni redbean ; `web/src/fenetre.moon` et
`web/src/init.moon` les requièrent. Les tests Lua sont dans `web/tests/`.
Les objets C++ sont mis en cache dans `web/build/objets-tests` : la première
exécution compile `scale.cpp` (quelques secondes), les suivantes restent
sous 3 s.

`tests-longs.sh` lance `web/scripts/test-qualite.sh` (serveur réel sur sortie
muette), `scripts/tester.sh` (couche ALSA/MIDI sans carte) et les bancs de
`moteur/tests/` hors suite rapide, compilés par
`moteur/tests/compiler-test-x86.sh` (chaîne x86-64 seule). Un banc
qui ne se compile plus est signalé IGNORÉ avec sa raison, jamais compté OK.

`tests-e2e.sh` pilote Chromium headless par le protocole DevTools (Node,
sans dépendance nouvelle) sur `/`, `/midi` et `/audio` : clics réels, valeurs
relues dans l'API, erreurs console, stabilité de `seq` et des `on`, largeurs
420/1100 px, cibles tactiles et remplissage `--fill` des curseurs. Il pilote
aussi la fenêtre native sous Xvfb avec xdotool (console, Audio, MIDI,
Connexions aux trois tailles ; tempérament et réverbération par clic), puis
réintroduit temporairement les régressions `--fill` et `nouveau` local pour
vérifier que la suite les détecte, avant de restaurer les sources.

Règle de sûreté pour tout script de test : en tête, `ulimit -r 0` et
`unset WAYLAND_DISPLAY` ; jamais le bureau réel (`DISPLAY` retiré, sauf vers
un Xvfb lancé par le script, jamais Xephyr) ; Chromium uniquement
`--headless=new --no-sandbox --disable-gpu` avec `env -u LD_LIBRARY_PATH` ;
sortie audio muette `ORGANUM_PERIPHERIQUE=null`, port et dossier d'état
temporaires, jamais les réglages de l'utilisateur ; arrêt par PID de tout ce
qui a été lancé, même en échec (trap), et vérification de `temps_reel` faux
dans chaque serveur.

## Licences

Projet sous AGPL-3.0 (JUCE est AGPLv3). Toute ressource ajoutée doit avoir
une licence compatible (pas de clause NC/ND) et figurer dans `CREDITS.md`.
Le lien « Code source » de l'interface (`web/src/page.moon`) est requis
par l'article 13 de l'AGPL.

## Pièges connus

- redbean génère un certificat TLS auto-signé entre `Listen()` et
  `EventLoop()`, et `ConfigureCertificate` reverse-résout chaque adresse
  non-loopback (dont `0.0.0.0`). Sous XNU, `getnameinfo(..., NI_NAMEREQD)`
  échoue en ~17 s, deux fois (EC puis RSA) : le port écoute alors ~34 s sans
  que personne n'appelle `accept()`. `cosmo/organum.c` renomme donc le `main`
  de redbean et insère `-X` (TLS désactivé) avant de l'appeler, mais
  **seulement sous XNU** (`IsXnu()`, macro d'exécution : ne pas la remplacer
  par un `#if`, le binaire peut être universel) et sauf si l'utilisateur
  fournit `-C`/`-K`. Linux et Windows conservent le comportement d'origine,
  TLS auto-signé compris. Ne pas élargir la condition sans mesurer la
  première réponse HTTP ; `web/scripts/test-demarrage.sh` la borne à 10 s et
  vérifie le certificat (généré hors XNU, absent sous XNU).
- Ne jamais arrêter PipeWire : l'audio passe par libasound `default`.
- Sortie ALSA `null` : `audio_ecrire` rend aussitôt et la boucle audio
  tournerait à 100 % d'un cœur. `g_sortie_null`, recalculé à chaque ouverture
  (`cosmo/sortie_null.h`), n'active l'attente `clock_nanosleep` que pour ce
  nom exact ; `default` et un nom vide n'attendent pas, et une vraie carte ne
  paie que le test d'entier.
- Ne pas copier par-dessus un `organum.com` en cours d'exécution :
  `build.sh` écrit un fichier temporaire puis renomme.
- **Arrêter organum tue tout son groupe de processus** : sur `SIGTERM`,
  redbean appelle `HandleShutdown()` (`externe/cosmopolitan/tool/net/redbean.c`,
  ~l. 7228), qui fait `KillGroup()` → `kill(0, SIGTERM)`, donc **SIGTERM à
  tout le groupe**. Conséquences mesurées : dans un shell sans contrôle de
  tâches (script, CI, `nohup`), `kill $pid` sur organum tue le shell appelant
  (code 143) ; en CI, le SIGTERM atteint l'**agent du runner GitHub**, qui
  annule le job juste après des contrôles pourtant réussis (« The runner has
  received a shutdown signal ») ; sur macOS, cela explique aussi que
  l'assistant audio/MIDI mourait à chaque redémarrage d'organum (fait
  attribué à tort à autre chose). Remèdes : depuis un script ou une CI,
  arrêter organum par **`kill -KILL`** (SIGKILL n'est pas capté) — idiome de
  `web/scripts/test-qualite.sh`, `test-sans-backend.sh`, `test-demarrage.sh`,
  `test-authentification.sh`, `test-reseaux.sh`, `test-transposition.sh`,
  `test-clavier.sh`, `test-midi-socket.sh`, `test-audio-socket.sh`,
  `scripts/tests-e2e.sh` et du job `validation-arm64` —, ou lancer organum
  dans son propre groupe (`set -m`, `setsid`) si l'on tient à `SIGTERM`. Tout
  nouveau script de test qui arrête un serveur doit respecter cette règle.
  `SIGTERM` reste légitime vers un **assistant** (`faux_assistant`,
  `organum-helper`) ou vers Xvfb : ils ne propagent pas au groupe.
- `pkill -f organum` / `pgrep -f` peuvent viser le shell qui les lance.
- JSON de redbean : une table Lua vide est encodée `{}` ; côté client,
  normaliser en tableau.
- `html.moon` produit `<div/>` pour un élément vide : passer `""`.
- Aeolus ne mémorise une combinaison qu'en la quittant : `publier()` appelle
  `aeolus_capturer_etape` à chaque changement de registration.
- PCM hérité au fork : tout fils durable (fenêtre native, et chaque fils de
  requête via `OnWorkerStart`) doit appeler `organum.oublier_audio`, qui ferme
  les descripteurs `/dev/snd/pcm` hérités et oublie leurs mappages sans aucun
  appel ALSA (jamais `snd_pcm_close`/`drop`/ioctl, qui arrêteraient le flux du
  parent). Sans cela, le périphérique reste occupé après `audio_fermer` et la
  sortie ne se rouvre plus. Le fil audio réessaie l'ouverture sur EBUSY
  pendant au plus ~500 ms.
- Les binaires cosmo bouclent sous Wine 9 (`MapViewOfFileEx`) : Windows n'est
  pas testable ainsi.
- CI : `.github/workflows/rolling.yml` construit à chaque push sur `master`
  et remplace la publication `rolling`. La chaîne cosmocc est en cache, clé
  = empreinte de `scripts/dependances.sh` et du correctif.
