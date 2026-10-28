# organum

Orgue à tuyaux virtuel en un seul fichier : le moteur de synthèse
d'[Aeolus](https://github.com/Archie3d/aeolus_plugin) (Archie3d, d'après
Fons Adriaensen), une entrée MIDI et une interface web, réunis dans un
exécutable [cosmopolitan](https://github.com/jart/cosmopolitan)/redbean.

- **Un fichier, aucune dépendance** : `organum.com` contient le moteur, les
  jeux, les réverbérations et l'interface. Rien à installer, pas de
  compilateur requis sur la machine.
- **Audio compatible PipeWire / PulseAudio** : sortie par libasound sur le
  périphérique `default` (chargée dynamiquement), sans arrêter le serveur de
  son ; à défaut, accès direct ALSA.
- **MIDI** : port du séquenceur ALSA, avec connexion automatique des claviers
  présents et branchés à chaud.
- **Interface web** (téléphone, tablette, ordinateur) : jeux, accouplements,
  combinaisons, volumes par clavier, réverbération, volume du système.
- **Fenêtre native** (Wayland ou X11, sans bibliothèque) ouverte au
  démarrage à côté de l'interface web : console d'orgue qui s'adapte à la
  taille de la fenêtre, sans défilement.
- **Page MIDI** (`/midi`) : canaux MIDI ↔ claviers, contrôleurs ↔ réglages
  (par exemple la molette sur le volume), avec apprentissage.
- **Persistance** : registration, combinaisons et réglages sont restaurés
  au démarrage.

Plate-forme : **Linux x86-64**. Le code Windows (WinMM) est écrit mais non
testé ; macOS n'est pas pris en charge.

## Utilisation

Télécharger `organum.com` depuis la publication
[rolling](../../releases/tag/rolling) (reconstruite à chaque commit sur
`master`), puis :

```bash
chmod +x organum.com && ./organum.com
```

Ouvrir <http://localhost:8080> (ou l'adresse de la machine depuis une
tablette). Les options de redbean s'appliquent, par exemple `-p 9000` pour
changer de port ou `-l 127.0.0.1` pour n'écouter qu'en local.

### Craquements et temps réel

Le fil audio demande la priorité temps réel (SCHED_FIFO). Sans ce droit, il
tourne en priorité normale et peut craquer sous charge. Pour l'accorder
durablement, ajouter l'utilisateur au groupe qui dispose de `rtprio` (souvent
`pipewire`, `audio` ou `realtime` selon la distribution), puis se
reconnecter. L'état courant est visible dans `/api/orgue` (`temps_reel`).

### Variables d'environnement

| Variable | Défaut | Rôle |
|---|---|---|
| `ORGANUM_FENETRE` | auto | `non` : pas de fenêtre native ; `x11` ou `wayland` : impose le protocole |
| `ORGANUM_PERIODE` | `512` | Taille de période audio (trames) |
| `ORGANUM_TAUX` | `48000` | Fréquence d'échantillonnage |
| `ORGANUM_PERIPHERIQUE` | `default` | Périphérique ALSA |
| `ORGANUM_VOLUME` | auto | Outil de volume : `wpctl`, `pactl` ou `amixer` |
| `ORGANUM_AMIXER_CONTROLE` | `Master` | Contrôle ALSA utilisé avec `amixer` |
| `ORGANUM_ETAT` | `~/.config/organum/etat.json` | Registration et combinaisons |
| `ORGANUM_CONFIG_MIDI` | `~/.config/organum/midi.json` | Associations MIDI |

### Bouton Panique

Envoie « All Notes Off » (CC 123) sur les 16 canaux : coupe les notes
bloquées sans toucher à la registration.

## Construction

Prérequis (Debian/Ubuntu) : `git make python3 zip gcc musl-tools luarocks`,
puis `luarocks install moonscript`.

```bash
scripts/construire.sh
```

Le résultat est `web/build/organum.com`. Le script :

1. place les dépendances dans `externe/` (`scripts/dependances.sh`) :
   cosmopolitan à un commit fixe, corrigé par `cosmo/cosmopolitan.patch`,
   la chaîne cosmocc construite depuis cet arbre (**longue** la première
   fois), et JUCE ;
2. construit les programmes d'aide de `cosmo_dlopen` (glibc et musl) ;
3. compile le moteur (`moteur/`) en `libaeolus.a` ;
4. lie l'exécutable dans l'arbre cosmopolitan (`tool/organum` → `cosmo/`) ;
5. compile l'interface MoonScript et l'ajoute au zip de l'exécutable.

Une copie existante d'une dépendance peut être réutilisée en la plaçant (ou
un lien) dans `externe/` avant de lancer le script.

## Organisation

| Dossier | Contenu |
|---|---|
| `moteur/` | Moteur d'Aeolus (C++/JUCE), API C (`api/`), ressources embarquées |
| `plateforme/` | Audio et MIDI : ALSA (Linux), WinMM (Windows) |
| `cosmo/` | Module Lua `organum`, intégration à redbean, correctif cosmopolitan |
| `ui/` | Fenêtre sans bibliothèque (protocoles Wayland et X11), Nuklear |
| `web/` | Interfaces web et native (MoonScript), assemblage de `organum.com` |
| `scripts/` | Dépendances et construction complète |

## Licence

Copyright © 2026 jperon. AGPL-3.0 (voir `LICENSE.txt`) : JUCE, utilisé par
le moteur, est sous AGPLv3, et le moteur Aeolus sous GPL-3.0 ou ultérieure.
Comme organum est un serveur web, l'interface offre un lien vers le code
source (article 13 de l'AGPL).

Auteurs et licences des composants repris (moteur, JUCE, cosmopolitan,
réponses impulsionnelles d'OpenAIR) : voir [CREDITS.md](CREDITS.md).
