# Assistant natif macOS — mode d'emploi

Organum parle au MIDI et à l'audio de macOS par des sockets Unix. Un seul
petit binaire Mach-O, hors de l'arbre cosmopolitan, `organum-helper`, fait le
pont avec les frameworks Apple :

- côté **MIDI** (CoreMIDI), il sert la socket `organum-midi-<uid>.sock` et le
  protocole [`PROTOCOLE-MIDI.md`](PROTOCOLE-MIDI.md) ;
- côté **audio** (CoreAudio), il sert la socket `organum-audio-<uid>.sock`,
  son fichier anneau `<socket>.pcm` et le protocole
  [`PROTOCOLE-AUDIO.md`](PROTOCOLE-AUDIO.md).

Les deux domaines vivent dans le **même processus** mais restent
**indépendants** : chacun a sa socket d'écoute, son client, son état et son
décodeur, et l'échec de l'un ne touche jamais l'autre (voir « Domaines de
défaillance » plus bas). Une seule boucle `poll()` surveille les deux sockets
d'écoute et les deux clients. Les chemins et les protocoles sont ceux
d'organum : le backend n'a pas changé.

## Compiler

Sur un Mac avec les outils de développement Xcode :

```bash
xcode-select --install          # une seule fois, si nécessaire
sh plateforme/macos/construire_assistant.sh
```

Le script refuse de continuer, avec la marche à suivre et le code 2, si
`xcode-select -p` échoue. Il produit deux fichiers :

- `plateforme/macos/build/organum-helper`, l'assistant natif ;
- `plateforme/macos/build/ape-m1-arm64`, le loader APE arm64 précompilé et
  signé qui permet à `organum.com` de démarrer nativement sur Apple Silicon
  sans appel à `cc` (voir « Architecture » plus bas).

Par défaut, le binaire est **universel** (Intel et Apple Silicon) quand le
SDK fournit les deux architectures ; sinon le script se replie sur
l'architecture de l'hôte avec un message explicite. Pour forcer l'hôte seul :

```bash
ARCHIVES=0 sh plateforme/macos/construire_assistant.sh
```

Après la compilation, le script **signe toujours ad-hoc** :

```bash
codesign --force --sign - plateforme/macos/build/organum-helper
```

Ce n'est pas décoratif : macOS **arm64 refuse d'exécuter un Mach-O non
signé**, même ad-hoc. Le script vérifie ensuite la signature avec
`codesign --verify --strict` et `codesign -dv`, publie `lipo -info` et
`codesign -dv`, et sort en code 3 si la signature ou une architecture
annoncée manque. Un binaire signé par un compte de développeur n'est pas
nécessaire : la signature ad-hoc suffit à l'exécution locale.

La compilation ne fait pas partie de `scripts/construire.sh` : elle demande
les frameworks Apple, absents de la chaîne cosmocc. Construire l'assistant
**avant** `web/scripts/build.sh` (ou `scripts/construire.sh`) pour qu'il soit
embarqué dans `organum.com` ; c'est ce que fait la recette macOS.

### Construction automatisée (GitHub Actions)

Le workflow `.github/workflows/rolling.yml` construit le helper et le loader
sur un runner `macos-latest` (clang + codesign + lipo seulement, ni cosmocc
ni moteur), les signe, vérifie `lipo -info` et `codesign --verify`, puis les
publie comme artefacts **`organum-helper`** et **`ape-m1-arm64`**. Le job
Linux les récupère dans `plateforme/macos/build/` avant
`scripts/construire.sh` : l'`organum.com` de la CI contient donc le helper
universel signé et le loader arm64 précompilé. Si un artefact est absent, le
job Linux continue avec un avertissement et produit un `organum.com` sans
helper, ou avec le repli `ape-m1.c` (compilation exigée au premier lancement
sur Apple Silicon).

Un job séparé **`validation-arm64`** tourne sur un runner Apple Silicon
(`macos-14`). Il ne recompile ni cosmocc ni le projet : il télécharge
l'artefact `organum-com` produit par le job Linux, vérifie `uname -m` =
`arm64` et `sysctl -n sysctl.proc_translated` = 0 (donc pas Rosetta), puis
lance le binaire avec un **faux `cc` qui échoue** en tête de `PATH` et
contrôle qu'il n'a pas été appelé. Il vérifie aussi `codesign --verify
--strict` sur le helper extrait de l'APE, et obtient une réponse de
`/api/orgue` sans carte son (mode dégradé attendu sur un runner).

**Conséquence pour une construction locale sous Linux** : un `organum.com`
construit ainsi n'a **pas** de helper (sauf si l'on copie soi-même
`plateforme/macos/build/organum-helper` avant `web/scripts/build.sh`), et
n'a pas de loader arm64 préconstruit (sauf si l'on copie
`plateforme/macos/build/ape-m1-arm64`). L'APE universel est quand même
produit si l'outillage aarch64 est présent ; sans loader préconstruit, il
embarque `ape-m1.c` et demandera Xcode CLT au premier lancement sur Apple
Silicon. L'archive reste utilisable sous Linux ; sous macOS, elle affiche
l'état `non_embarque` pour l'assistant et fonctionne sans audio ni MIDI
natifs tant qu'on ne reconstruit pas avec le helper.

### Architecture : organum.com universel x86-64 + arm64

`scripts/construire.sh` produit par défaut un **APE universel** : moteur et
exécutable x86-64, moteur et exécutable aarch64, puis fusion avec
`apelink`. Sur Apple Silicon, `organum.com` s'exécute donc **nativement**,
sans Rosetta 2. Le zip de l'interface web est partagé par les deux
architectures.

Le loader arm64 précompilé `plateforme/macos/build/ape-m1-arm64` est produit
par `plateforme/macos/construire_assistant.sh` (ou directement par
`plateforme/macos/construire_loader.sh`) : compilation de
`plateforme/macos/ape-m1.c` avec `clang -arch arm64 -O2 -w
-mmacosx-version-min=11.0`, puis signature ad-hoc et vérifications
`codesign`/`lipo`. `-mmacosx-version-min=11.0` est indispensable : sans lui,
le loader prend le SDK de compilation comme cible et exige macOS 15.
`apelink` ne vérifie pas la signature ; c'est ce script qui la produit.
Le source embarqué est la copie fidèle de `cosmopolitan/ape/ape-m1.c`
(licence ISC, © Justine Tunney), figée pour que le job macOS de la CI n'ait
pas besoin de construire cosmocc.

Sans ce loader, la fusion utilise `apelink -M ape/ape-m1.c` et l'APE compile
son loader sur la machine cible : il exige alors Xcode CLT au premier
lancement. C'est un repli annoncé explicitement, pas le mode normal de la
CI. `ORGANUM_UNIVERSEL=0 scripts/construire.sh` force l'ancien comportement
(APE x86-64 seulement) ; si l'outillage aarch64 manque ou échoue, la
construction se replie d'elle-même sur cet APE x86-64 sans échouer.

### Après extraction : intégrité et signature

Au démarrage, organum extrait le helper dans `$TMPDIR/.organum/organum-helper`
(droits `0700`, fichier temporaire puis renommage), puis vérifie que le
contenu extrait est **identique à l'archive** (taille et octets : un extrait
tronqué est refusé) et exécute l'extrait avec `--aide`. Si ce lancement
échoue, l'état publié est `inutilisable` — signature absente sous arm64,
architecture refusée, quarantaine ou binaire corrompu — avec un message
clair, et le heartbeat ne réessaie pas indéfiniment. Le `chmod 0700` après
extraction ne modifie que les droits, pas le contenu signé : la signature
reste valide (vérifié avec `codesign -v` sur le fichier extrait). L'écriture
depuis le zip ne pose pas d'attribut `com.apple.quarantine` ; si un jour elle
en posait un, le test `--aide` le signalerait, et il faudrait alors retirer
l'attribut (`xattr -d com.apple.quarantine`) après extraction.

**Recompiler l'assistant en même temps qu'organum** à chaque mise à jour : la
version du protocole audio et celle de l'anneau partagé changent ensemble
(version 2 depuis le drapeau `demarre`). Un couple hétérogène est refusé
explicitement, avec un message français nommant les deux versions ; organum
ne produit alors aucun son, mais l'erreur est visible dans `/api/orgue` et le
panneau Audio.

## Vérifier

```bash
plateforme/macos/build/organum-helper --liste
```

Un seul outil de diagnostic affiche **les deux** axes :

- la sortie audio **par défaut** (nom, taux nominal, canaux, latence estimée,
  capacité de l'anneau) ;
- les sources CoreMIDI, avec leur identifiant unique et leur nom.

Il sort avec le code 0 si tout va bien, 1 si un axe manque (aucune sortie
audio, ou CoreMIDI indisponible). Sur une machine virtuelle sans carte son,
la partie audio le dit clairement en français ; sur une machine sans pilote
IAC ni clavier USB, la partie MIDI n'affiche aucune source ; dans les deux
cas l'orgue démarre quand même, en mode dégradé sur l'axe concerné.

Pour créer une source MIDI sans clavier physique, ouvrir **Configuration
audio et MIDI**, menu **Fenêtre → Afficher le studio MIDI**, double-cliquer
sur **IAC Driver** et cocher **Périphérique en ligne**. Un pilote IAC coché
apparaît ensuite dans `--liste`. Un clavier MIDI USB branché fait aussi
l'affaire.

L'assistant utilise **toujours le périphérique audio système par défaut**. Le
champ `peripherique` des réglages d'organum est ignoré en v1 : pour changer de
sortie, passer par **Réglages Système → Son → Sortie**.

## Lancement automatique par organum (cas normal)

L'utilisateur ne lance **qu'un seul binaire** : `organum.com`. Si
`plateforme/macos/build/organum-helper` existe au moment de la construction,
`web/scripts/build.sh` l'embarque dans l'archive sous
`.organum/organum-helper` (avertissement sans échec s'il est absent, pour
pouvoir construire sous Linux).

Au démarrage sous macOS, organum :

1. extrait l'assistant dans `$TMPDIR/.organum/organum-helper` (droits
   `0700`, écriture par fichier temporaire puis renommage : jamais
   par-dessus un binaire en cours d'exécution) ;
2. sonde les sockets `$TMPDIR/organum-midi-<uid>.sock` et
   `$TMPDIR/organum-audio-<uid>.sock` ; si un assistant y répond déjà, il le
   **réutilise** (lancement manuel ou LaunchAgent) au lieu d'en créer un
   second ;
3. sinon, lance l'assistant dans son propre groupe de processus, avec sa
   sortie dans `$TMPDIR/.organum/organum-helper.log`. Un drapeau de
   débogage, `ORGANUM_ASSISTANT_VERBOSE=1`, ajoute `--verbose` ;
4. vérifie périodiquement, depuis `OnServerHeartbeat`, que l'assistant vit
   encore et le relance s'il est tombé. Trois échecs rapprochés sont
   annoncés comme « impossible à lancer » au lieu de relancer sans fin.

À l'arrêt d'organum, redbean envoie `SIGTERM` à son groupe de processus :
l'assistant lancé par organum meurt avec lui. Les sockets et le `.pcm`
doivent alors disparaître (arrêt propre). S'il a été lancé par LaunchAgent,
il est dans un autre groupe et survit, par choix.

Trois situations sont distinguées dans `/api/orgue` (champs
`qualite.assistant_etat`, `audio_etat`, `audio_message`, `midi_message`) et
dans les pages web :

| Situation | Message affiché |
|---|---|
| tout fonctionne | aucun |
| archive construite sans assistant (`non_embarque`) | reconstruire organum avec `plateforme/macos/build/organum-helper` présent |
| extraction impossible (`extraction_impossible`) | chemin du journal à consulter |
| lancement impossible (`lancement_impossible`) | chemin du journal à consulter |
| assistant connecté mais aucune sortie audio | vérifier Réglages Système → Son → Sortie |

Dans tous ces cas l'orgue démarre et reste utilisable ; aucun n'est fatal.

## Lancer l'assistant à la main (dépannage)

Normalement inutile : organum s'en charge. Pour diagnostiquer, ou pour un
service permanent indépendant de l'orgue :

```bash
plateforme/macos/build/organum-helper --verbose
```

Options (noms harmonisés) :

| Option | Effet |
|---|---|
| `--socket-midi CHEMIN` | force le chemin de la socket MIDI |
| `--socket-audio CHEMIN` | force le chemin de la socket audio |
| `--verbose` | journal détaillé sur la sortie d'erreur |
| `--liste` | affiche les deux axes et sort |
| `--aide`, `-h` | rappel de l'usage |

Sans option, les chemins sont `$TMPDIR/organum-midi-<uid>.sock` et
`$TMPDIR/organum-audio-<uid>.sock` (ou `/tmp/…`), **exactement** ceux que
calcule organum. Si organum est lancé avec `ORGANUM_MIDI_SOCKET` /
`ORGANUM_AUDIO_SOCKET`, l'assistant doit recevoir la même variable (ou le
même `--socket-midi` / `--socket-audio`).

Chaque message du journal est préfixé `organum-helper : midi :` ou
`organum-helper : audio :`, pour distinguer les deux domaines.

L'assistant possède la socket audio **et** le fichier `<socket>.pcm`
(l'anneau partagé, `0600`) : il les crée au démarrage et les retire à l'arrêt
propre. Un second exemplaire sort avec le code 3 et laisse les sockets et
les clients du premier intacts : c'est ce qui protège une instance déjà
vivante lorsqu'organum en lance une autre par erreur.

Organum et l'assistant peuvent démarrer dans n'importe quel ordre : si une
socket manque, organum reste dégradé sur l'axe concerné et réessaie ; si
c'est organum qui manque, l'assistant écoute et attend son client. Les deux
axes sont indépendants : on peut avoir le MIDI sans l'audio (Mac sans carte
son) et inversement.

## Domaines de défaillance indépendants

L'assistant fusionné n'est pas un tout-or-rien :

- si CoreMIDI échoue à s'initialiser, le domaine MIDI est simplement
  indisponible (sa socket est retirée) et l'audio continue ;
- si l'anneau ou la socket audio ne peuvent pas être créés, l'audio est
  indisponible et le MIDI continue ;
- si le client MIDI se déconnecte, la session audio n'est pas touchée (et
  inversement) : chaque client a son état et son décodeur ;
- si l'`AudioUnit` échoue ou si aucune sortie audio n'existe, l'assistant
  répond le statut d'`AUDIO_ACK` correspondant, **ne quitte pas**, et le MIDI
  continue ;
- la perte du périphérique de sortie en cours de jeu arrête la lecture et
  envoie `AUDIO_STOP` (raison 1), sans quitter et sans toucher aux
  connexions CoreMIDI ni à la socket MIDI.

Le processus ne sort que sur `SIGINT`/`SIGTERM` (ou si les **deux** domaines
échouent au démarrage).

## Signaux et propriétaire

L'assistant est destiné à être lancé **par organum lui-même**. Redbean, à
l'arrêt de l'orgue, envoie `SIGTERM` à tout son groupe de processus : lancé
dans ce groupe, l'assistant meurt avec organum, ce qui est le comportement
voulu. Contrairement à l'ancien assistant MIDI, **aucune protection par
`LOCAL_PEERPID` n'est conservée** : elle avait été ajoutée pour qu'un
assistant lancé à la main survive aux redémarrages d'organum, au prix d'un
mécanisme subtil ; l'assistant est désormais relancé par organum à chaque
démarrage.

Pour un service permanent indépendant d'organum, utiliser un LaunchAgent :
launchd le place dans son propre groupe et il survit alors aux arrêts de
l'orgue (voir plus bas).

Un `SIGTERM` ou `SIGINT` direct (PID de l'assistant, launchd, shell) arrête
proprement : `AudioOutputUnitStop`, `AudioUnitUninitialize`,
`AudioComponentInstanceDispose`, fermeture des clients et des sockets,
`munmap` de l'anneau, puis `unlink` du `.pcm`, de la socket audio et de la
socket MIDI. Un `SIGKILL` laisse les fichiers ; l'instance suivante sonde les
sockets (`ECONNREFUSED`), les remplace, et tronque le `.pcm` (`O_TRUNC` +
`ftruncate`). Aucune intervention manuelle n'est nécessaire.

## Ordre de démarrage

L'assistant est unique. Le cas normal est simplement :

```bash
./organum.com
```

Organum extrait, lance ou réutilise l'assistant, puis se connecte. Un
assistant lancé à la main **avant** organum est réutilisé ; lancé **après**,
il est vu au réessai suivant (environ une seconde), sans redémarrer l'orgue.
Un assistant arrêté laisse les deux axes indisponibles ; organum continue de
fonctionner en mode dégradé et publie le message correspondant.

## Service permanent facultatif (LaunchAgent)

Organum lance déjà l'assistant ; un LaunchAgent n'est utile que pour le faire
survivre aux arrêts de l'orgue (par exemple pour un autre client). Un seul
agent suffit. Créer
`~/Library/LaunchAgents/com.organum.helper.plist` avec des chemins absolus
(remplacer `/Users/jacques` par le compte réel) :

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.organum.helper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/jacques/organum/plateforme/macos/build/organum-helper</string>
    <string>--verbose</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>/tmp/organum-helper.log</string>
  <key>StandardOutPath</key>
  <string>/tmp/organum-helper.log</string>
</dict>
</plist>
```

Puis :

```bash
launchctl load ~/Library/LaunchAgents/com.organum.helper.plist
launchctl list | grep organum
```

Pour redémarrer l'assistant sans toucher à l'orgue :

```bash
launchctl kickstart -k gui/$(id -u)/com.organum.helper
```

`KeepAlive` relance l'assistant s'il tombe. Ni CoreMIDI ni la sortie audio
par défaut ne sont soumises à TCC : aucune autorisation n'est à donner dans
« Confidentialité et sécurité », ni pour l'entrée MIDI, ni pour le
microphone (aucune entrée n'est ouverte), ni pour l'automatisation. Éviter en
particulier les scripts qui pilotent « System Events » (automatisation
AppleScript), lesquels demandent une autorisation interactive — inutile ici.
