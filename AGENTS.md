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
420/1100 px, cibles tactiles, curseurs verticaux (glissement relatif,
molette, remplissage `--fill`), valeurs en % affichées et texte des boutons
de jeux complet (ni en largeur ni en hauteur, cible ≥ 44 px). Il pilote
aussi la fenêtre native sous Xvfb avec xdotool (console, Audio, MIDI,
Connexions aux trois tailles ; tempérament, réverbération, volume et gain
par clic, glissement ou molette), puis
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
- **Relancer un orgue en service sous un autre utilisateur** (constaté sur un
  orgue en production sous Void Linux, session graphique sway) : passer par
  `runuser`, `su` ou tout chemin passant par PAM remet `RLIMIT_RTPRIO` à 0
  quand le stack PAM employé n'inclut pas `pam_limits` (ou ne lit pas
  `/etc/security/limits.d/` — hypothèse retenue, non instrumentée).
  `pthread_setschedparam(SCHED_FIFO, 70)` échoue alors, `temps_reel` passe à
  `false` et l'orgue tourne **sans priorité temps réel** ; cela ne se voit
  **pas** dans l'API (`audio_disponible` reste vrai, `audio_erreur` vide) et
  ne s'entend que sous charge, par des craquements. Seuls indices :
  `temps_reel:false` dans `GET /api/orgue` et l'avertissement `SCHED_FIFO` du
  journal. Remèdes mesurés : relancer par la **session graphique elle-même**
  (le `exec` de la configuration sway, ou `swaymsg exec`), qui hérite de la
  limite `@audio - rtprio 95` de `/etc/security/limits.d/` ; ou, depuis un
  shell d'administration, en évitant PAM : `prlimit --rtprio=95:95 --
  setpriv --reuid <utilisateur> --regid <utilisateur> --init-groups -- env
  HOME=… XDG_RUNTIME_DIR=… WAYLAND_DISPLAY=… DISPLAY=… <binaire>`. Une
  relance depuis un shell **sans** `XDG_RUNTIME_DIR`/`WAYLAND_DISPLAY` donne
  un orgue **sans fenêtre native et sans audio** alors que l'API répond :
  ne jamais conclure au succès sur la seule réponse HTTP. Pour arrêter
  l'instance précédente, `SIGKILL` uniquement, jamais `SIGTERM` (voir
  l'entrée « Arrêter organum tue tout son groupe de processus ») ; vérifier
  d'abord que le `pgid` visé n'est pas celui du shell courant.
- **Vérifier après toute relance d'un orgue en service**, sans se fier à
  l'API seule : `temps_reel` à `true` ; sortie ALSA réellement en `RUNNING`
  avec un `hw_ptr` qui progresse (`/proc/asound/card*/pcm*p/sub*/status`),
  pas seulement `/api/orgue` qui répond ; présence de la **fenêtre native**
  si une session graphique existe ; et identité des fichiers d'état
  utilisateur (sha256 avant/après la relance), pour être sûr de ne pas avoir
  écrit dans un autre `HOME`.

## Documents détaillés (à lire à la demande)

Ce fichier est relu à chaque requête : il ne contient que le noyau. Avant de travailler sur un sujet, lis le document correspondant. Toute nouvelle note (journal, post-mortem, état des lieux, description de module) s'ajoute dans le document du sujet sous `docs/agents/`, pas ici ; ici, au plus une ligne d'index. Jamais d'import `@chemin`.

- `docs/agents/fichiers-cles.md` — Fichiers clés ; à lire avant de travailler sur les fichiers clés du dépôt.
