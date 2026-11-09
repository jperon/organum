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
`xcode-select -p` échoue. Il produit un binaire unique :

- `plateforme/macos/build/organum-helper`

Pour un binaire universel (Intel et Apple Silicon) :

```bash
ARCHIVES=1 sh plateforme/macos/construire_assistant.sh
```

La compilation ne fait pas partie de `scripts/construire.sh` : elle demande
les frameworks Apple, absents de la chaîne cosmocc.

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

## Lancer

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
`$TMPDIR/organum-audio-<uid>.sock` (ou `/tmp/…`), les mêmes que ceux
calculés par organum. Si organum est lancé avec `ORGANUM_MIDI_SOCKET` /
`ORGANUM_AUDIO_SOCKET`, l'assistant doit recevoir la même variable (ou le
même `--socket-midi` / `--socket-audio`).

Chaque message du journal est préfixé `organum-helper : midi :` ou
`organum-helper : audio :`, pour distinguer les deux domaines.

L'assistant possède la socket audio **et** le fichier `<socket>.pcm`
(l'anneau partagé, `0600`) : il les crée au démarrage et les retire à l'arrêt
propre. Un second exemplaire sort avec le code 3 et laisse les sockets et
les clients du premier intacts.

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

L'assistant est unique ; l'ordre avec organum n'a pas d'importance. En
pratique :

1. `organum-helper` (démarrage automatique par LaunchAgent, ou à la main) ;
2. `organum`.

Un assistant lancé après organum est vu au réessai suivant (environ une
seconde), sans redémarrer l'orgue. Un assistant arrêté laisse les deux axes
indisponibles ; organum continue de fonctionner en mode dégradé.

## Lancement automatique (LaunchAgent)

Un seul agent suffit désormais. Créer
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
