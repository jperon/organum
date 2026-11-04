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

Le fil audio demande la priorité temps réel `SCHED_FIFO 70`. Sans ce droit,
il tourne en priorité normale, peut être interrompu par d'autres tâches et
le son hache. Au démarrage, un refus est signalé une seule fois sur
`stderr` (visible dans le journal du service ou le terminal) :

```text
organum : priorité temps réel SCHED_FIFO 70 refusée : Operation not permitted ; droit rtprio manquant ? voir /etc/security/limits.d (groupe audio/pipewire), ou lancer avec « sudo chrt -f 70 ».
```

`/api/orgue` reflète l'état courant et quelques compteurs utiles :

```bash
curl -s localhost:8080/api/orgue \
  | jq '{temps_reel, xruns, taux, periode, nb_periodes, erreurs_ecriture}'
```

- `temps_reel` : `true` si le fil a obtenu `SCHED_FIFO 70` ;
- `xruns` : nombre de défauts de la sortie ALSA (périphérique en retard) ;
- `taux`, `periode`, `nb_periodes` : réglage effectivement demandé ;
- `erreurs_ecriture` : nombre d'écritures audio en échec depuis le
  démarrage (hors `xruns`, déjà comptés par ALSA).

#### Réglages de qualité

`/api/orgue` expose aussi un objet `qualite` :

| Champ | Type | Défaut | Valeurs |
|---|---|---|---|
| `bruit_attaque` | booléen | `true` | bruit d'attaque et résonateur du tuyau |
| `instabilite` | booléen | `true` | instabilité aléatoire de hauteur |
| `spatialisation` | entier | `2` | 0 = coupée, 1 = simplifiée, 2 = complète |
| `polyphonie_max` | entier | `0` | 0 = illimitée, sinon 1 à 512 voix |
| `tete_reverb` | booléen | `true` | tête zéro latence EFFECTIVE (ORGANUM_REVERB_TETE compris), au prochain démarrage pour un changement |
| `tete_reverb_impose` | booléen | `false` | vrai quand ORGANUM_REVERB_TETE force la valeur |
| `niveau` | entier | présélection correspondante, sinon `-1` | 0 à 3 |
| `auto` | booléen | `true` au premier lancement | calibration automatique au démarrage |
| `calibration` | objet | absent si aucune calibration | résultat de la calibration de ce démarrage |

Les quatre premiers champs s'appliquent à chaud, aux notes déclenchées
ensuite. `tete_reverb` expose la valeur EFFECTIVE (après application de
`ORGANUM_REVERB_TETE`) ; un changement de configuration ne s'applique qu'au
démarrage suivant.

Mode automatique : au premier lancement (fichier d'état sans clé `qualite`)
ou avec `ORGANUM_QUALITE=auto`, une calibration mesure la machine **avant
d'ouvrir l'audio**, sans créer d'instance du moteur, et choisit le niveau
dont le temps de bloc estimé à 250 voix reste sous 60 % de l'échéance réelle
(`periode / taux`). Le niveau retenu est appliqué comme une présélection, et
`auto` reste vrai tant qu'un champ individuel n'a pas été modifié à la main.
Si la calibration échoue ou dépasse 1,5 s, organum se replie sur le niveau 3
et l'écrit dans le journal. Quand `auto` est faux (réglage manuel
sauvegardé), aucune recalibration n'a lieu au démarrage suivant.

Quand une calibration a eu lieu, `qualite.calibration` contient `niveau`,
`tete_reverb`, `echeance_ms`, `estimation_ms` (table de 4 valeurs, une par
niveau), `cout_spat2_us`, `cout_spat1_us`, `cout_reverb_tete_ms`,
`cout_reverb_sans_tete_ms`, `voix_ref` et `duree_calibration_ms`. La clé est
absente si aucune calibration n'a eu lieu à ce démarrage.

`POST /api/orgue` accepte un unique champ `qualite`, objet contenant un ou
plusieurs réglages :

```bash
curl -s -X POST localhost:8080/api/orgue \
  -d '{"qualite":{"spatialisation":1,"bruit_attaque":false}}'
curl -s -X POST localhost:8080/api/orgue -d '{"qualite":{"niveau":1}}'
```

Toute modification d'un champ individuel passe `niveau` à `-1` («
personnalisé ») et `auto` à `false`. `niveau` applique d'un coup une
présélection :

| niveau | spatialisation | bruit_attaque | instabilite | polyphonie_max | tete_reverb |
|---|---|---|---|---|---|
| 0 | 0 | non | non | 64 | non |
| 1 | 1 | non | non | 128 | non |
| 2 | 1 | oui | oui | 192 | oui |
| 3 | 2 | oui | oui | 0 (illimité) | oui |

Une valeur invalide (champ inconnu, type incorrect, valeur hors bornes,
objet vide) renvoie `400` avec un message en français. La réponse reflète
les valeurs **demandées** pour les champs à chaud (elle n'attend pas que le
fil audio les ait publiées) ; `tete_reverb` y reste la valeur effective, un
changement ne s'appliquant qu'au redémarrage. La réponse indique
`redemarrage_requis: true` quand `tete_reverb` change. Les réglages sont
enregistrés dans `etat.json` (clé `qualite`) et restaurés au démarrage.

Vérifier aussi la classe et la priorité des fils, et le graphe PipeWire :

```bash
ps -L -o pid,tid,cls,rtprio -C organum.com   # attendu : FF 70 pour le fil audio
pw-top                                      # quantum et erreurs du graphe
```

#### Accorder le droit `rtprio`

Le droit vient d'une limite PAM (`RLIMIT_RTPRIO`) et de l'appartenance au
groupe autorisé. Créer par exemple `/etc/security/limits.d/90-organum.conf` :

```text
@audio    -  rtprio     95
@audio    -  memlock    unlimited
```

puis ajouter l'utilisateur au groupe `audio` (ou `pipewire`/`realtime` selon
la distribution) :

```bash
sudo usermod -aG audio "$USER"
```

**Se reconnecter** (session graphique comprise) : les limites sont lues à
l'ouverture de session, pas à chaque lancement d'organum. `memlock` est
utile aux serveurs audio ; organum lui-même ne verrouille pas sa mémoire.
Si la limite ne peut pas être accordée durablement, lancer le programme avec
une priorité temps réel explicite, ce qui exige les privilèges correspondants :
`sudo chrt -f 70 organum.com` (ou la capacité `CAP_SYS_NICE`).

Sans systemd (runit, sway lancé par `startx` ou un script), PAM et
`limits.d` ne s'appliquent qu'aux sessions ouvertes par `login`, `sshd` ou
un gestionnaire de connexion. Un service lancé directement par le
superviseur (runit, s6) n'hérite pas de ces limites : les poser dans le
script de service (`ulimit -r 95`, ou `chrt -f 70` si le service tourne avec
les privilèges adéquats) ou dans la configuration du superviseur.

#### Période, quantum et hachures

`ORGANUM_PERIODE` (trames par écriture, 512 par défaut) et `ORGANUM_TAUX`
(48000 Hz) déterminent la latence et la fréquence des réveils du fil audio.
Avec PipeWire, la période doit rester cohérente avec le quantum du graphe
(`pw-top`, souvent 1024, parfois 256) : une période beaucoup plus petite
multiplie les réveils et les risques de retard, un quantum plus petit que
la période fragmente les transferts. En cas de hachures persistantes,
monter `ORGANUM_PERIODE` à 1024 (les `xruns` doivent cesser de croître), ou
régler le quantum PipeWire à une valeur au moins égale.

Pour le périphérique `default`, Organum définit lui-même
`PIPEWIRE_LATENCY=<période>/<taux>` avant d'ouvrir le PCM, si l'utilisateur
ne l'a pas déjà fournie. Le plugin ALSA de PipeWire lit cette variable à
l'ouverture : elle aligne sa période interne sur celle d'Organum et évite
un flux à 600/48000 alors que le programme écrit par blocs de 512 ou 1024
trames. Le réglage est sans effet sur `hw:C,D` (accès direct ALSA) ; une
valeur explicite de `PIPEWIRE_LATENCY` reste prioritaire. La latence du
tampon libasound demandée à ALSA est par ailleurs `période × nb_periodes`
(au lieu d'une valeur fixe de 50 ms).

La priorité 70 est volontairement **inférieure** à celle du fil de PipeWire
(environ 88) : le serveur audio doit pouvoir interrompre organum pour
livrer le son à temps. Ne pas la relever au-dessus de PipeWire.

### Variables d'environnement

| Variable | Défaut | Rôle |
|---|---|---|
| `ORGANUM_FENETRE` | auto | `non` : pas de fenêtre native ; `x11` ou `wayland` : impose le protocole |
| `ORGANUM_PERIODE` | `512` | Taille de période audio (trames) |
| `ORGANUM_TAUX` | `48000` | Fréquence d'échantillonnage |
| `PIPEWIRE_LATENCY` | `ORGANUM_PERIODE/ORGANUM_TAUX` | Latence du plugin PipeWire, définie automatiquement pour `default` si absente ; une valeur fournie n'est jamais remplacée |
| `ORGANUM_PERIPHERIQUE` | `default` | Périphérique ALSA |
| `ORGANUM_LIMITEUR` | `oui` | `non` : désactive le limiteur de sortie (diagnostic seulement) |
| `ORGANUM_LIBASOUND` | auto | Bibliothèque libasound à charger : fichier `.so` ou répertoire le contenant |
| `ORGANUM_VOLUME` | auto | Outil de volume : `wpctl`, `pactl` ou `amixer` ; `aucun` désactive la recherche |
| `ORGANUM_AMIXER_CONTROLE` | `Master` | Contrôle ALSA utilisé avec `amixer` |
| `ORGANUM_ETAT` | `~/.config/organum/etat.json` | Registration et combinaisons |
| `ORGANUM_CONFIG_MIDI` | `~/.config/organum/midi.json` | Associations MIDI |
| `ORGANUM_QUALITE` | auto | `auto` ou `0`..`3` : force la qualité au démarrage, prioritaire sur `etat.json` |
| `ORGANUM_REVERB_TETE` | oui | `non` (ou `0`) coupe la tête zéro latence de la réverbération, prioritaire sur `tete_reverb` |
| `ORGANUM_CALIBRATION_FACTEUR` | `1` | Réservé aux tests : multiplie tous les coûts mesurés par la calibration (simule une machine plus lente) |
| `ORGANUM_CALIBRATION_VOIX` | `250` | Réservé aux tests : nombre de voix de référence de la calibration |

Le limiteur de sortie est actif par défaut. Les pilotes audio convertissent
les échantillons flottants en entiers et **écrêtent dur** au-delà de 1.0 :
sans limiteur, un accord dense dont la somme des jeux dépasse cette valeur
sature et « craque ». Le limiteur, de seuil 0.8, ne réduit le gain que dans
ce cas et reste transparent pour une note seule. `ORGANUM_LIMITEUR=non` le
désactive, ce qui n'est utile que pour mesurer la sortie brute ou comparer
un enregistrement ; ne pas l'utiliser en jeu normal.

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
