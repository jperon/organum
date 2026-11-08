# Assistant CoreMIDI sur macOS — mode d'emploi

Organum parle MIDI sur macOS par une socket Unix ; c'est cet assistant, un
petit binaire Mach-O, qui parle CoreMIDI. Sans lui, l'orgue fonctionne mais
le MIDI reste absent. Le protocole est décrit dans
[`PROTOCOLE-MIDI.md`](PROTOCOLE-MIDI.md).

## Compiler

Sur un Mac avec les outils de développement Xcode :

```bash
xcode-select --install          # une seule fois, si nécessaire
sh plateforme/macos/construire_assistant.sh
```

Le script refuse de continuer, avec la marche à suivre, si `xcode-select -p`
échoue. Il produit `plateforme/macos/build/organum-midi`. Pour un binaire
universel (Intel et Apple Silicon) :

```bash
ARCHIVES=1 sh plateforme/macos/construire_assistant.sh
```

La compilation ne fait pas partie de `scripts/construire.sh` : elle demande
les frameworks Apple, absents de la chaîne cosmocc.

## Vérifier les sources MIDI

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

## Lancer

```bash
plateforme/macos/build/organum-midi --verbose
```

Sans option, le chemin de la socket est `$TMPDIR/organum-midi-<uid>.sock`
(ou `/tmp/organum-midi-<uid>.sock`), le même que celui calculé par organum.
`--socket CHEMIN` le force ; `--verbose` journalise sur la sortie d'erreur,
tous les messages étant préfixés `organum-midi :`. Si organum est lancé avec
`ORGANUM_MIDI_SOCKET`, l'assistant doit recevoir la même variable (ou le
même `--socket`).

Organum et l'assistant peuvent démarrer dans n'importe quel ordre : si la
socket manque, organum reste en MIDI dégradé et réessaie ; si c'est organum
qui manque, l'assistant écoute et attend son client. L'assistant ne doit
tourner qu'une fois : un second exemplaire sort avec le code 3 et laisse la
socket du premier intacte.

## Lancement automatique (LaunchAgent)

Créer `~/Library/LaunchAgents/com.organum.midi.plist` avec des chemins
absolus (remplacer `/Users/jacques` par le compte réel) :

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

Puis :

```bash
launchctl load ~/Library/LaunchAgents/com.organum.midi.plist
launchctl list | grep organum
```

`KeepAlive` relance l'assistant s'il tombe. CoreMIDI n'est pas soumis à TCC :
aucune autorisation n'est à donner dans « Confidentialité et sécurité », ni
pour l'entrée MIDI ni pour l'automatisation. Éviter en particulier les
scripts qui pilotent « System Events » (automatisation AppleScript), lesquels
demandent une autorisation interactive — inutile ici.
