# Assistants natifs macOS — mode d'emploi

Organum parle au MIDI et à l'audio de macOS par des sockets Unix. Deux petits
binaires Mach-O, hors de l'arbre cosmopolitan, font le pont avec les
frameworks Apple :

- **`organum-midi`** (CoreMIDI) : sans lui, l'orgue fonctionne mais le MIDI
  reste absent. Protocole :
  [`PROTOCOLE-MIDI.md`](PROTOCOLE-MIDI.md).
- **`organum-audio`** (CoreAudio) : sans lui, l'orgue fonctionne mais le son
  reste absent. Protocole :
  [`PROTOCOLE-AUDIO.md`](PROTOCOLE-AUDIO.md).

## Compiler

Sur un Mac avec les outils de développement Xcode :

```bash
xcode-select --install          # une seule fois, si nécessaire
sh plateforme/macos/construire_assistant.sh
```

Le script refuse de continuer, avec la marche à suivre et le code 2, si
`xcode-select -p` échoue. Il produit les deux binaires :

- `plateforme/macos/build/organum-midi`
- `plateforme/macos/build/organum-audio`

Pour des binaires universels (Intel et Apple Silicon) :

```bash
ARCHIVES=1 sh plateforme/macos/construire_assistant.sh
```

La compilation ne fait pas partie de `scripts/construire.sh` : elle demande
les frameworks Apple, absents de la chaîne cosmocc.

## Vérifier le MIDI

```bash
plateforme/macos/build/organum-midi --liste
```

La commande affiche l'identifiant unique et le nom de chaque source CoreMIDI,
puis sort. C'est le premier réflexe de diagnostic : sans source, organum ne
recevra rien, même si l'assistant tourne.

Pour créer une source sans clavier physique, ouvrir **Configuration audio et
MIDI**, menu **Fenêtre → Afficher le studio MIDI**, double-cliquer sur
**IAC Driver** et cocher **Périphérique en ligne**. Un pilote IAC coché
apparaît ensuite dans `--liste`. Un clavier MIDI USB branché fait aussi
l'affaire.

## Vérifier l'audio

```bash
plateforme/macos/build/organum-audio --liste
```

La commande affiche le périphérique de sortie **par défaut**, son taux
nominal, son nombre de canaux et une latence estimée, puis sort avec le code
0. Quand aucun périphérique de sortie n'existe — cas d'une machine virtuelle
sans carte son — elle le dit clairement en français et sort avec le code 1.
C'est le premier réflexe de diagnostic : sans sortie, organum restera en
audio dégradé, sans planter.

L'assistant utilise **toujours le périphérique système par défaut**. Le champ
`peripherique` des réglages d'organum est ignoré en v1 : pour changer de
sortie, passer par **Réglages Système → Son → Sortie**.

## Lancer

```bash
plateforme/macos/build/organum-midi  --verbose
plateforme/macos/build/organum-audio --verbose
```

Sans option, les chemins sont `$TMPDIR/organum-<midi|audio>-<uid>.sock` (ou
`/tmp/…`), les mêmes que ceux calculés par organum. `--socket CHEMIN` les
force ; `--verbose` journalise sur la sortie d'erreur, tous les messages
étant préfixés `organum-midi :` ou `organum-audio :`. Si organum est lancé
avec `ORGANUM_MIDI_SOCKET` / `ORGANUM_AUDIO_SOCKET`, l'assistant doit
recevoir la même variable (ou le même `--socket`).

`organum-audio` possède la socket **et** le fichier `<socket>.pcm` (l'anneau
partagé, `0600`) : il les crée au démarrage et les retire à l'arrêt propre.
Comme pour le MIDI, un second exemplaire sort avec le code 3 et laisse la
socket du premier intacte.

Organum et chaque assistant peuvent démarrer dans n'importe quel ordre : si
la socket manque, organum reste dégradé sur l'axe concerné et réessaie ; si
c'est organum qui manque, l'assistant écoute et attend son client. Les deux
axes sont indépendants : on peut avoir le MIDI sans l'audio (Mac sans carte
son) et inversement.

## Ordre de démarrage

Les deux assistants sont indépendants ; l'ordre n'a pas d'importance, et
organum peut être lancé avant, pendant ou après eux. En pratique :

1. `organum-midi` et `organum-audio` (démarrage automatique par LaunchAgent,
   ou à la main) ;
2. `organum`.

Un assistant lancé après organum est vu au réessai suivant (environ une
seconde), sans redémarrer l'orgue. Un assistant arrêté laisse l'axe
concerné indisponible ; l'autre continue. Pour vérifier un axe sans lancer
organum, `--liste` est le diagnostic de référence des **deux** binaires :

```bash
plateforme/macos/build/organum-midi  --liste   # sources CoreMIDI
plateforme/macos/build/organum-audio --liste   # sortie audio par défaut
```

Sur un Mac sans carte son, `organum-audio --liste` sort avec le code 1 ;
l'orgue démarre quand même et publie « aucune sortie audio » dans son
interface. Sur une machine sans pilote IAC ni clavier USB,
`organum-midi --liste` n'affiche aucune source ; l'orgue démarre quand même,
sans MIDI.

## Lancement automatique (LaunchAgent)

Créer `~/Library/LaunchAgents/com.organum.midi.plist`, puis
`~/Library/LaunchAgents/com.organum.audio.plist`, avec des chemins absolus
(remplacer `/Users/jacques` par le compte réel).

MIDI :

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.organum.midi</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/jacques/organum/plateforme/macos/build/organum-midi</string>
    <string>--verbose</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>/tmp/organum-midi.log</string>
  <key>StandardOutPath</key>
  <string>/tmp/organum-midi.log</string>
</dict>
</plist>
```

Audio (même forme, label et binaire différents) :

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.organum.audio</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/jacques/organum/plateforme/macos/build/organum-audio</string>
    <string>--verbose</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardErrorPath</key>
  <string>/tmp/organum-audio.log</string>
  <key>StandardOutPath</key>
  <string>/tmp/organum-audio.log</string>
</dict>
</plist>
```

Puis :

```bash
launchctl load ~/Library/LaunchAgents/com.organum.midi.plist
launchctl load ~/Library/LaunchAgents/com.organum.audio.plist
launchctl list | grep organum
```

Les deux LaunchAgent peuvent être chargés à la suite, dans n'importe quel
ordre : ils ne partagent que la convention de chemin de socket, que chaque
assistant calcule de la même façon. Pour redémarrer un seul assistant sans
toucher à l'orgue :

```bash
launchctl kickstart -k gui/$(id -u)/com.organum.audio
launchctl kickstart -k gui/$(id -u)/com.organum.midi
```

`KeepAlive` relance l'assistant s'il tombe. Ni CoreMIDI ni la sortie audio
par défaut ne sont soumises à TCC : aucune autorisation n'est à donner dans
« Confidentialité et sécurité », ni pour l'entrée MIDI, ni pour le
microphone (aucune entrée n'est ouverte), ni pour l'automatisation. Éviter en
particulier les scripts qui pilotent « System Events » (automatisation
AppleScript), lesquels demandent une autorisation interactive — inutile ici.
