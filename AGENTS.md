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
  `/api/volume`), persistance. `page.moon`, `page_midi.moon`, `client.moon`,
  `style.moon` : interface. `web/src/.lua/html.moon` : générateur HTML.

## Construire et tester

```bash
scripts/construire.sh                 # tout ; résultat web/build/organum.com
make -C moteur -j                     # moteur seul
make -C externe/cosmopolitan -j m= o//tool/organum/organum
web/scripts/build.sh                  # réassemble seulement l'interface
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
- Les binaires cosmo bouclent sous Wine 9 (`MapViewOfFileEx`) : Windows n'est
  pas testable ainsi.
- CI : `.github/workflows/rolling.yml` construit à chaque push sur `master`
  et remplace la publication `rolling`. La chaîne cosmocc est en cache, clé
  = empreinte de `scripts/dependances.sh` et du correctif.
