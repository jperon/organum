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
  `audio_supportee()` rend `IsLinux() || IsWindows()` ; `midi_supportee()`
  rend `IsLinux() || IsWindows() || IsXnu()` (backend socket macOS) ;
  `organum.plateforme()` rend `"linux"`, `"windows"`, `"macos"` ou
  `"autre"`. L'aiguillage MIDI ajoute la branche socket sous `IsXnu()` ou
  quand `ORGANUM_MIDI_SOCKET` (non vide) l'impose sous Linux pour les tests ;
  l'audio macOS reste sans backend.
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
  sans recopier sa règle en MoonScript. L'échec audio reste fatal sur Linux
  quand un backend existe ; le mode dégradé n'appelle jamais `unix.exit`.
  Tests : `web/tests/degradation.lua`,
  `web/tests/midi_actif.lua`, `web/scripts/test-sans-backend.sh` et
  `web/scripts/test-midi-socket.sh` (dont MIDI socket + audio dégradé).
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

- Ne jamais arrêter PipeWire : l'audio passe par libasound `default`.
- Sortie ALSA `null` : `audio_ecrire` rend aussitôt et la boucle audio
  tournerait à 100 % d'un cœur. `g_sortie_null`, recalculé à chaque ouverture
  (`cosmo/sortie_null.h`), n'active l'attente `clock_nanosleep` que pour ce
  nom exact ; `default` et un nom vide n'attendent pas, et une vraie carte ne
  paie que le test d'entier.
- Ne pas copier par-dessus un `organum.com` en cours d'exécution :
  `build.sh` écrit un fichier temporaire puis renomme.
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
