# Protocole de la socket audio macOS

Spécification de référence du dialogue entre un **assistant CoreAudio
externe** (binaire Mach-O, hors build cosmocc) et **organum** (APE
cosmopolitan). Le codec pur correspondant est
`plateforme/macos/trames_audio.h` (qui s'appuie sur `trames.h`), l'anneau
partagé `plateforme/macos/anneau_audio.h`, et le client côté organum
`plateforme/macos/audio_socket.c`. Le faux assistant de test
`plateforme/tests/faux_assistant_audio.c` est une implémentation POSIX
complète du côté serveur, utilisée sous Linux.

L'assistant est seul à parler CoreAudio : il possède un périphérique de
sortie, configure une AudioUnit et joue les échantillons que organum dépose
dans un anneau en mémoire partagée. Organum ne fait aucune conversion : le
flux est déjà celui de `boucle_audio`, float32 entrelacé stéréo.

Comme pour le MIDI, l'interface est un **fichier de socket Unix** pour le
contrôle et un **fichier partagé** pour les données, afin qu'aucune copie de
tampon audio ne traverse la socket.

## 1. Transport

- Famille `AF_UNIX`, type `SOCK_STREAM`.
- Un seul client à la fois côté organum.
- Le chemin de la socket est résolu dans cet ordre :
  1. `ORGANUM_AUDIO_SOCKET`, si la variable existe et n'est pas vide
     (prioritaire ; sert aussi aux tests sous Linux) ;
  2. `$TMPDIR/organum-audio-<uid>.sock`, si `TMPDIR` existe et n'est pas vide ;
  3. `/tmp/organum-audio-<uid>.sock` sinon.
- `<uid>` est l'identifiant numérique effectif de l'utilisateur qui lance
  organum. Si `TMPDIR` se termine déjà par `/`, la barre n'est pas doublée.
- La longueur du chemin doit être **strictement inférieure** à
  `sizeof(sun_path)`, soit au plus 103 octets sur XNU. Un chemin trop long est
  **refusé explicitement** : il n'est jamais tronqué.
- L'assistant est le **serveur** : il crée la socket, la possède et l'écoute.
  Organum est l'unique **client** et s'y connecte.
- La socket est créée avec les permissions `0600`. L'assistant applique
  `umask(077)` avant `bind()`.

### Le fichier anneau

Le fichier anneau est `<chemin de la socket>.pcm`, par exemple
`/tmp/organum-audio-501.sock.pcm`. C'est **l'assistant** qui le crée :

- `open(chemin, O_RDWR | O_CREAT | O_TRUNC, 0600)` ;
- `fchmod(0600)` ;
- `ftruncate` à `sizeof(struct anneau_entete) + capacite * octets_trame`,
  avec `capacite = ANNEAU_AUDIO_CAPACITE_MAX` (16384 trames) et
  `octets_trame = canaux * 4 = 8`, soit 131 200 octets ;
- `mmap(..., PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)` ;
- `anneau_initialiser(...)` avec un en-tête provisoire (48 000 Hz, période
  512, génération 1), remplacé à chaque `AUDIO_CONFIG`.

`O_TRUNC` récupère un fichier laissé par un assistant tué par `SIGKILL`.
Comme la troncature et le `ftruncate` ne sont pas atomiques, un organum encore
connecté à l'ancien assistant pourrait théoriquement voir le fichier
rétrécir ; en pratique l'ancien assistant est mort et organum a déjà lâché son
mappage (il le fait dès qu'il constate la perte). Le fichier de socket et le
`.pcm` sont retirés par l'assistant à son arrêt propre.

### Création et socket périmée

**Seul l'assistant** appelle `unlink()`. Organum ne supprime jamais ni la
socket ni le `.pcm`.

Au démarrage, l'assistant sonde la socket par `connect()` :

- `ECONNREFUSED` ou `ENOENT` : la socket est périmée ou absente ; l'assistant
  fait `unlink()` puis `bind()` et écoute ;
- connexion réussie : un autre assistant vit déjà ; le nouveau venu sort
  avec le **code 3** sans toucher à la socket ni au pair déjà connecté ;
- toute autre erreur : sortie en erreur, sans `unlink()`.

Organum se contente de `connect()` avec un délai global de 200 ms. Si la
socket manque encore (assistant pas démarré), l'échec n'est pas fatal :
organum démarre en audio dégradé et réessaie l'ouverture environ toutes les
secondes, indéfiniment.

## 2. Poignée de main

Les deux côtés échangent exactement **8 octets** :

| Octet | Contenu |
|---|---|
| 0..3 | magic ASCII `OAUD` (`4F 41 55 44`) |
| 4 | version du protocole : `2` |
| 5 | côté client : `0` ; côté serveur : statut |
| 6..7 | `max_frame` en petit-boutiste (LE16) |

Statuts de la poignée côté serveur :

| Valeur | Sens |
|---|---|
| `0` | accepté |
| `3` | version de protocole ou d'en-tête d'anneau incompatible |
| `4` | refus interne (dont « déjà un client ») |

Le client envoie sa poignée (statut `0`), le serveur répond avec la sienne.
La valeur retenue pour la connexion est `min(max_frame client, max_frame
serveur)`, **bornée à 64..8192**. Un `max_frame` hors de ces bornes est
refusé (code de décodage `-3`). Une version différente de `2` reçoit le
statut `3`, puis la connexion est fermée.

Le délai de la poignée est court : organum n'accorde que **200 ms** à
l'ensemble connexion + poignée. L'assistant doit donc répondre aussitôt
après `accept()` (il lit les 8 octets avec une borne de 150 ms).

### Versions et compatibilité

La version de la poignée (`TRAMES_AUDIO_VERSION`, dans `trames_audio.h`) et
la version de l'en-tête de l'anneau (`ANNEAU_AUDIO_VERSION`, dans
`anneau_audio.h`) valent **2**. La première couvre le protocole de contrôle
et la seconde la disposition de la mémoire partagée ; **toute modification
de l'un ou de l'autre impose d'incrémenter les deux**, et de recompiler
organum et l'assistant ensemble. La version 2 correspond à l'ajout du
drapeau `demarre` à l'offset 108.

Règle absolue : **un couple hétérogène est REFUSÉ, jamais toléré en
silence**. Un organum d'une autre version ne doit jamais ouvrir l'anneau d'un
assistant qui en attend une autre : l'absence de son ne doit pas être
présentée comme un fonctionnement normal. Concrètement :

- la poignée porte la version du serveur ; si elle diffère, le client refuse
  l'ouverture avec un message français nommant les deux versions et
  demandant de recompiler les deux binaires ;
- l'assistant répond le statut `3` à une poignée de version inconnue, reste à
  l'écoute et ne crée aucune session ;
- après l'ACK, organum vérifie `magie` et `version` de l'en-tête mappé ; un
  désaccord est refusé avec un message explicite ;
- l'assistant vérifie aussi cet en-tête avant d'appliquer une
  `AUDIO_CONFIG` et répond alors le statut `3` (configuration invalide), au
  lieu de jouer du silence.

Cette règle a été ajoutée après un défaut réel : un organum antérieur au
drapeau `demarre` écrivait dans un anneau que le nouvel assistant refusait de
lire (`demarre = 0`), et l'utilisateur n'entendait rien sans aucun message.

## 3. Trame

En-tête de **4 octets**, puis le corps :

| Octet | Contenu |
|---|---|
| 0 | `type` (u8) |
| 1 | `flags` (u8, réservé, `0`) |
| 2..3 | `longueur` du corps en petit-boutiste (LE16) |
| 4.. | corps (`longueur` octets) |

`longueur` va de `0` à `max_frame` inclus. Une longueur supérieure à
`max_frame` est une **erreur de décodage** : l'appelant ferme la connexion.
Une longueur inférieure ou égale est lue intégralement, même si le type est
inconnu.

### Types

| Type | Nom | Corps |
|---|---|---|
| `0x40` | AUDIO_CONFIG | 24 octets (voir ci-dessous) |
| `0x41` | AUDIO_ACK | 17 octets |
| `0x42` | AUDIO_DEVICE | `nom_len` + nom + 2 u32 |
| `0x43` | AUDIO_STOP | `raison` (u8) |
| `0x30` | PING | vide |
| `0x31` | PONG | vide |
| `0x7E` | BYE | vide |

Tout autre type est **ignoré** (compatibilité ascendante) : la trame est
lue, validée en longueur, puis jetée sans fermer la connexion. Un type
inconnu ne doit pas être interprété comme une erreur.

### AUDIO_CONFIG (`0x40`)

Corps de 24 octets, entiers en petit-boutiste :

| Décalage | Champ | Taille |
|---|---|---|
| 0 | `generation` | u32 |
| 4 | `taux` | u32 |
| 8 | `periode` | u32 |
| 12 | `canaux` | u16 |
| 14 | `format` | u16 |
| 16 | `capacite` | u32 |
| 20 | `octets` | u32 |

`format` vaut `0` : float32 **entrelacé**. `capacite` est un nombre de trames,
puissance de deux entre 256 et 16384 ; `octets` vaut
`capacite * canaux * 4` et doit correspondre à la taille des données utiles de
l'anneau. `periode` est la période nominale du fil audio d'organum (nombre de
trames par tampon) ; elle sert de repère, pas de contrainte de rendu.

Organum **négocie** la capacité sur la profondeur demandée à l'ouverture
(`nb_periodes` périodes, 3 par défaut) : plus petite puissance de deux ≥
`nb_periodes × periode`, bornée par 256 et 16384. Avec 512 trames de période,
la fenêtre vaut ainsi 2048 trames (43 ms à 48 kHz), et non 16384 (341 ms).
Le fichier `.pcm` reste dimensionné à `ANNEAU_AUDIO_CAPACITE_MAX` : c'est sa
taille, pas la fenêtre utilisée. L'assistant réécrit l'en-tête avec la
capacité de la configuration avant l'ACK ; un assistant qui garderait une
autre capacité fait échouer l'ouverture (erreur explicite), pour ne jamais
annoncer une petite latence avec une grande fenêtre.

Un `AUDIO_CONFIG` peut arriver plusieurs fois sur la même connexion ou sur
une connexion neuve : c'est ainsi que se fait un **changement de taux à
chaud** (organum ferme l'ancienne sortie, envoie la nouvelle configuration,
puis reprend l'écriture dans l'anneau réinitialisé).

### AUDIO_ACK (`0x41`)

Corps de 17 octets :

| Décalage | Champ | Taille |
|---|---|---|
| 0 | `statut` | u8 |
| 1 | `generation` | u32 |
| 5 | `taux` | u32 |
| 9 | `periode` | u32 |
| 13 | `capacite` | u32 |

Statuts :

| Valeur | Sens | Effet côté organum |
|---|---|---|
| `0` | OK | la session audio démarre |
| `1` | format ou taux refusé | erreur `format audio refusé par l'assistant` |
| `2` | aucune sortie audio disponible | erreur `aucune sortie audio disponible` |
| `3` | configuration invalide | erreur `configuration audio refusée par l'assistant` |
| `4` | erreur interne | erreur `erreur interne de l'assistant audio` |

Un statut différent de `0` fait fermer la connexion par organum : la session
n'existe pas, `audio_assistant` reste `0` et `audio_disponible` reste `false`.
L'assistant reste à l'écoute et la tentative suivante (environ toutes les
secondes) refait toute la séquence. C'est le comportement attendu sur une
machine **sans carte son** : statut `2`, message français « aucune sortie
audio disponible », aucun plantage.

L'anneau est réécrit (`anneau_initialiser`, compteurs et `arret` remis à zéro)
**avant** l'envoi de l'ACK `0`, pour qu'organum retrouve un en-tête cohérent
dès qu'il écrit.

### AUDIO_DEVICE (`0x42`)

Corps : `nom_len` (u8, au plus 63), `nom` en UTF-8 sans NUL final, puis
`taux_natif` (u32) et `latence_us` (u32). Le décodeur exige une longueur
exactement égale à `9 + nom_len`. L'assistant l'envoie après un ACK `0` ; il
décrit le périphérique de sortie par défaut retenu. Organum peut l'ignorer
sans conséquence.

### AUDIO_STOP (`0x43`)

Corps : `raison` (u8). L'assistant l'envoie quand il ne peut plus jouer alors
que la session était établie. Valeurs :

| Valeur | Sens |
|---|---|
| `0` | raison non précisée |
| `1` | périphérique de sortie perdu |

Avant l'envoi, l'assistant positionne `arret` dans l'en-tête de l'anneau.
Organum détecte l'arrêt par ce drapeau (et non par le contenu de la socket),
marque la sortie perdue, ferme la connexion et réessaie. L'assistant **ne
quitte pas** : il reste à l'écoute pour une prochaine `AUDIO_CONFIG`, que le
périphérique soit revenu ou non.

### PING / PONG / BYE

`PING` (`0x30`) et `PONG` (`0x31`) ont un corps vide et servent à vérifier
que le pair répond. `BYE` (`0x7E`) annonce une fermeture propre imminente.
**Attention** : le type BYE vaut `0x7E`, valeur qui peut apparaître dans un
corps (nom de périphérique, par exemple). Un lecteur ne doit jamais chercher
l'octet `0x7E` dans le flux brut : il décode les trames.

## 4. L'anneau partagé

`struct anneau_entete` (`anneau_audio.h`) occupe les **128 premiers octets**
du fichier, suivis immédiatement des données. Tous les champs sont en
petit-boutiste natif (aucune sérialisation : la mémoire est partagée).

| Décalage | Champ | Type |
|---|---|---|
| 0 | `magie` (`0x4455414F`, « OAUD ») | u32 |
| 4 | `version` (`2`) | u32 |
| 8 | `canaux` | u32 |
| 12 | `octets_trame` | u32 |
| 16 | `taux` | u32 |
| 20 | `periode` | u32 |
| 24 | `capacite` (trames, puissance de deux) | u32 |
| 28 | `generation` | u32 |
| 32 | `drapeaux` (réservé, `0`) | u32 |
| 36..63 | réserve | u32[7] |
| 64 | `ecrit` | \_Atomic u64 |
| 72 | `lu` | \_Atomic u64 |
| 80 | `underruns` (trames) | \_Atomic u64 |
| 88 | `overruns` (trames) | \_Atomic u64 |
| 96 | `trames_jouees` | \_Atomic u64 |
| 104 | `arret` (drapeau) | \_Atomic u32 |
| 108 | `demarre` (drapeau producteur) | \_Atomic u32 |
| 112..127 | réserve d'alignement | u32[4] |

Les données commencent à l'octet 128 : `capacite` trames de `octets_trame`
octets. La position réelle d'un compteur vaut `compteur & (capacite - 1)`.

Producteur unique (le fil audio d'organum), consommateur unique (le rappel de
rendu de l'assistant). Les compteurs sont libres sur 64 bits ; l'ordre
mémoire est `release` à l'écriture du compteur, `acquire` à sa lecture, sans
`seq_cst` ni `volatile`. `anneau_lire` compte en `underruns` les trames
manquantes et en `trames_jouees` celles réellement lues ; `anneau_ecrire`
compte en `overruns` les trames refusées faute de place.

`arret` non nul arrête les deux côtés : `anneau_lire` et `anneau_ecrire` ne
touchent plus aux données. L'assistant le positionne sur perte de
périphérique ou de client ; `anneau_reinitialiser` (à chaque
`AUDIO_CONFIG`) le remet à zéro.

`demarre` est positionné par le producteur à sa première écriture d'une
génération, et remis à zéro par `anneau_initialiser` et
`anneau_reinitialiser`. Tant qu'il vaut 0, `anneau_lire` rend 0 **sans**
compter d'underrun : le consommateur complète le bloc par du silence. Une
ouverture, ou la recréation du moteur pendant un changement de taux, n'est
donc plus une famine de centaines de milliers de trames ; organum publie
`audio_demarre` faux et l'interface annonce explicitement que le son est
suspendu. Dès la première écriture, les underruns réels sont de nouveau
comptés.

## 5. Le rappel de rendu CoreAudio

L'assistant utilise une AudioUnit `kAudioUnitType_Output` /
`kAudioUnitSubType_DefaultOutput`, pas une `AudioQueue` : il n'y a donc pas de
tampon interne supplémentaire (une copie et de la latence en moins). Le
format demandé est float32 entrelacé 2 canaux au taux d'organum
(`kAudioUnitProperty_StreamFormat`, portée `Input`, élément 0). Si l'unité le
refuse, l'assistant se replie sur `kAudioFormatFlagIsNonInterleaved` (deux
tampons d'un canal) et **désentrelace dans le rappel**, sur un tampon de pile
borné (512 trames). Le rappel :

- n'alloue jamais, ne prend aucun verrou, n'appelle ni `printf` ni aucune
  fonction libc bloquante ;
- lit l'anneau par blocs de 512 trames au plus, et complète le manque par du
  silence en comptant un underrun (sauf avant `demarre`, où le silence est un
  démarrage et n'est pas compté) ;
- respecte `arret` (anneau arrêté ⇒ silence) ;
- n'écrit jamais au-delà de `mDataByteSize`.

Le format non entrelacé, le rendu réel des échantillons, la latence effective
et l'absence de clic ne sont pas vérifiables sans carte son.

## 6. Qui possède quoi, et dans quel ordre on ferme

| Ressource | Propriétaire | Création | Destruction |
|---|---|---|---|
| fichier de socket | assistant | `bind()` | `unlink()` à l'arrêt propre |
| fichier `.pcm` | assistant | `open(O_CREAT)` + `mmap` | `unlink()` à l'arrêt propre |
| connexion acceptée | assistant et organum, chacun son descripteur | `accept()` / `connect()` | chacun ferme le sien |
| AudioUnit | assistant | `AudioComponentInstanceNew` | `AudioComponentInstanceDispose` |
| anneau mappé | les deux, chacun son mappage | `mmap` | `munmap` |

Ordre d'arrêt de l'assistant, sur `SIGINT`/`SIGTERM` :

1. `AudioOutputUnitStop`, `AudioUnitUninitialize`,
   `AudioComponentInstanceDispose` (plus aucun rappel ne peut tourner) ;
2. `BYE` au mieux puis fermeture de la connexion acceptée ;
3. `munmap` de l'anneau ;
4. `unlink` du `.pcm` puis de la socket ;
5. sortie avec le code **0**.

Scénarios :

1. **Organum démarre avant l'assistant.** `connect()` échoue
   (`ENOENT`/`ECONNREFUSED`) : organum reste en audio dégradé, publie
   `audio_erreur` (« assistant audio absent ») et réessaie chaque seconde.
   Quand l'assistant démarre, sa sonde échoue, il remplace la socket périmée
   et écoute ; la tentative suivante d'organum aboutit.
2. **Organum s'arrête.** Il envoie `BYE` si possible et ferme sa connexion,
   sans toucher aux fichiers. L'assistant voit la fin de flux, ferme la
   connexion, positionne `arret` et arrête l'AudioUnit (plus personne ne
   produit), mais **garde** sa socket et son `.pcm` pour le client suivant.
3. **L'assistant s'arrête.** Voir l'ordre ci-dessus. Organum lit la fin de
   flux ou constate `arret`, ferme, repasse en audio dégradé et réessaie ; il
   ne recrée ni la socket ni le `.pcm`.
4. **L'assistant meurt brutalement (`SIGKILL`, panique).** La socket reste sur
   disque, le `.pcm` aussi. Organum voit la fin de flux, ferme et réessaie ;
   le prochain assistant sonde la socket (`ECONNREFUSED`), la remplace, et
   tronque le `.pcm` (`O_TRUNC` + `ftruncate`). Aucune intervention
   manuelle n'est nécessaire.
5. **Le périphérique audio disparaît en cours de jeu.** L'assistant
   positionne `arret`, envoie `AUDIO_STOP` (raison 1), arrête l'AudioUnit et
   **reste en vie**. Organum ferme et réessaie ; la prochaine
   `AUDIO_CONFIG` réussit si le périphérique est revenu, sinon l'assistant
   répond statut `2`.
6. **Fils de requête redbean.** Chaque fils hérite du descripteur de socket
   et du mappage. Il doit les oublier (`audio_socket_audio_oublier_fils`) :
   ni lecture, ni écriture, ni `unlink`. Seul le processus principal écrit
   dans l'anneau.

En résumé : l'assistant crée, possède et retire la socket et le `.pcm` ;
organum s'y connecte en client `AF_UNIX`, possède son propre mappage et ne
retire jamais aucun fichier.
