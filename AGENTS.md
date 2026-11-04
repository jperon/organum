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
- `web/src/init.moon` : démarrage, API HTTP (`/api/orgue`, `/api/midi`,
  `/api/volume`), persistance. `page.moon` (orgue), `page_midi.moon`
  (`/midi`), `page_qualite.moon` (`/qualite`), `client.moon` (JS de la page
  orgue), `style.moon` : interface. `web/src/.lua/html.moon` : générateur
  HTML.
- Réglages de qualité : champs du moteur dans `cosmo/lorganum.c`
  (`CMD_QUALITE`, fonction Lua `organum.qualite`, `organum.demarrer{qualite,
  tete_reverb}`) ; présélections, validation de `POST /api/orgue {qualite}`,
  `ORGANUM_QUALITE` et persistance (clé `qualite` d'`etat.json`) dans
  `web/src/init.moon`, panneau dédié `web/src/page_qualite.moon`. Tous les
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
  (anneau de 60 s, hors `application` et hors seconde suivant une
  reconfiguration ou une bascule de tête). `seq` ne change que si le niveau ou
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
  (`ORGANUM_FENETRE=non` pour s'en passer). Exigence : tout doit tenir dans
  la fenêtre, sans défilement, et grossir quand elle est agrandie.
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

## Licences

Projet sous AGPL-3.0 (JUCE est AGPLv3). Toute ressource ajoutée doit avoir
une licence compatible (pas de clause NC/ND) et figurer dans `CREDITS.md`.
Le lien « Code source » de l'interface (`web/src/page.moon`) est requis
par l'article 13 de l'AGPL.

## Pièges connus

- Ne jamais arrêter PipeWire : l'audio passe par libasound `default`.
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
