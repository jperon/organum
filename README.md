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
  taille de la fenêtre, sans défilement. X11 aussi par TCP (`DISPLAY=hôte:n`),
  ce qui permet en principe un serveur X pour Windows (VcXsrv, Xming…), non
  testé sous Windows.
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
| `ORGANUM_LIBASOUND` | auto | Bibliothèque libasound à charger : fichier `.so` ou répertoire le contenant |
| `ORGANUM_VOLUME` | auto | Outil de volume : `wpctl`, `pactl` ou `amixer` ; `aucun` désactive la recherche |
| `ORGANUM_AMIXER_CONTROLE` | `Master` | Contrôle ALSA utilisé avec `amixer` |
| `ORGANUM_ETAT` | `~/.config/organum/etat.json` | Registration et combinaisons |
| `ORGANUM_CONFIG_MIDI` | `~/.config/organum/midi.json` | Associations MIDI |

Sur NixOS et Guix, libasound se trouve souvent uniquement dans le magasin
(`/nix/store`) et le chargeur dynamique ne sait pas le trouver sans cache
`ld.so`. Indiquer alors le fichier ou son répertoire :

```bash
ORGANUM_LIBASOUND=/nix/store/…-alsa-lib/lib organum.com
```

Sous NixOS, ajouter `pkgs.alsa-lib` à `programs.nix-ld.libraries` évite de
préciser la variable. En cas d'échec, le message d'erreur indique les chemins
essayés et l'erreur de chargement ou d'ouverture ALSA.

Variable interne réservée aux tests : `ORGANUM_LIBASOUND_STRICT=1` empêche le
repli sur `libasound.so.2`/`libasound.so` quand `ORGANUM_LIBASOUND` est défini
et a échoué. Elle n'est pas destinée à l'usage courant.

Avec `ORGANUM_PERIPHERIQUE=hw:C,D`, organum accède directement au PCM
`/dev/snd/pcmCCDDP` sans passer par libasound. L'ouverture se fait sans
bloquer : si PipeWire (ou un autre serveur audio) détient le périphérique,
l'accès échoue rapidement avec un message explicite au lieu d'attendre.
Dans ce cas, revenir au périphérique `default` (la valeur par défaut), qui
passe par le serveur audio.

### Serveur audio figé

Si PipeWire ou PulseAudio ne répond plus, la recherche de l'outil de volume
(`wpctl`, `pactl` ou `amixer`) est bornée à **2 secondes** par commande : un
outil figé est tué, un avertissement est journalisé, et Organum continue sans
contrôle du volume système. `ORGANUM_VOLUME=aucun` évite même de lancer un
outil.

L'ouverture du périphérique `default` passe en revanche par libasound et le
serveur audio. Organum ne peut pas la borner par une alarme : `cosmo_dlopen`
bloque tous les signaux pendant les appels dans la bibliothèque étrangère.
Si le serveur est figé, l'ouverture peut donc encore attendre indéfiniment ;
le journal le montre, et il faut redémarrer le serveur audio. Pour éviter
cette attente, `ORGANUM_PERIPHERIQUE=hw:C,D` ouvre le PCM direct en mode non
bloquant (voir ci-dessus) et échoue rapidement si PipeWire le détient.

### Bouton Panique

Envoie « All Notes Off » (CC 123) sur les 16 canaux : coupe les notes
bloquées sans toucher à la registration.

### API MIDI

`GET /api/midi` renvoie la configuration MIDI : canaux de chaque clavier,
canaux de contrôle et d'expression, associations, dernier contrôleur reçu.
Le champ `canaux_actifs` est une liste de canaux 1-16 ayant reçu un message
(récemment, environ 250 ms) : il est **éphémère**, n'entre pas dans `seq`
(il ne réveille donc pas `/api/orgue/attendre`) et n'est jamais enregistré
dans `midi.json`. Il reste un **tableau JSON**, même vide (`[]`), comme les
listes de canaux de la configuration.

Les contrôleurs (CC) réveillent en revanche `/api/orgue/attendre` : ils
mettent à jour `dernier_controle` et incrémentent `seq`, afin que la page
MIDI voie immédiatement le contrôleur reçu pour l'apprentissage. Les notes,
elles, ne réveillent pas cette attente : elles ne modifient ni `seq` ni
`dernier_controle` (seul `canaux_actifs` les reflète).

`GET /api/midi/ports` décrit les ports du séquenceur :

```json
{
  "adresse": "128:0",
  "ports": [
    {"client": 24, "port": 0, "nom_client": "Clavier", "nom_port": "…",
     "source": true, "destination": false, "connecte": true, "organum": false,
     "lecture": true, "ecriture": false, "abonnement": true, "generique": true,
     "capacites": 97, "type": 131074, "adresse": "24:0",
     "libelle": "24:0 — Clavier", "etat": "connecte"}
  ]
}
```

`capacites` et `type` sont les valeurs brutes ALSA du port. `libelle` et
`etat` sont calculés par `modele.moon`, commun aux interfaces web et native ;
`etat` vaut `organum`, `connecte`, `destination` ou `disponible`. Si le
séquenceur est indisponible, la réponse reste **200** avec `ports: []`
(tableau vide, et un avertissement dans le journal). Seul `GET` est accepté :
toute autre méthode reçoit **405** avec l'en-tête `Allow: GET`.

`POST /api/midi/connexion` prend `{"client": 24, "port": 0, "connecte":
true}` : `client` et `port` doivent être des entiers entre 0 et 255, et
`connecte` un booléen. Une connexion abonne la source au port d'Organum ;
une déconnexion la mémorise pour que la connexion automatique ne la
rétablisse pas avant le prochain démarrage. Le port `0:1` (annonces du
système, qui détecte les nouveaux ports) ne peut pas être déconnecté. En
cas de corps invalide, de valeur hors bornes ou d'adresse refusée, la
réponse est **400** avec un message générique (`connexion MIDI impossible :
adresse refusée`) ; le détail reste dans le journal. Si le moteur n'est pas
démarré, la réponse est **503** (`moteur indisponible`). Sinon **200** avec
`ok`, `connecte`, `adresse`, `ports` et le champ `port` : ce dernier n'est
présent que si le port figure encore dans la liste à jour, il peut donc
manquer. Seul `POST` est accepté ; toute autre méthode reçoit **405** avec
l'en-tête `Allow: POST`.

Au démarrage, Organum se connecte automatiquement à toutes les sources MIDI
présentes (claviers, accordéon…) et aux ports branchés à chaud. Une
déconnexion explicite exclut l'adresse jusqu'au prochain démarrage ; une
reconnexion explicite lève l'exclusion.

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

Les tests de la couche plate-forme (dont le diagnostic libasound) se lancent
séparément, après une construction :

```bash
scripts/tester.sh
```

`ORGANUM_TESTS=1 scripts/construire.sh` les enchaîne à la fin de la
construction. La CI les exécute avant de publier `rolling`.

Variante sans interface native (ni Nuklear ni fenêtre X11/Wayland),
seulement l'interface web, après `scripts/construire.sh` :

```bash
make -C externe/cosmopolitan -j m= o//tool/organum/organum-web
ORGANUM_WEB=1 web/scripts/build.sh
```

Résultat : `web/build/organum-web.com`.

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
