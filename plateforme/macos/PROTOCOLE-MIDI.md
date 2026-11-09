# Protocole de la socket MIDI macOS

Spécification de référence du dialogue entre un **assistant CoreMIDI
externe** (binaire Mach-O, hors build cosmocc) et **organum** (APE
cosmopolitan). Le codec pur correspondant est
`plateforme/macos/trames_midi.h`, éprouvé par
`plateforme/tests/trames_midi.c`.

L'assistant est seul à parler CoreMIDI : il énumère les sources et
destinations, s'abonne aux sources choisies et écrit les messages reçus dans
la socket. Organum se contente de lire des trames déjà normalisées, comme il
lirait un séquenceur ALSA.

## 1. Transport

- Famille `AF_UNIX`, type `SOCK_STREAM`.
- Un seul client à la fois côté organum.
- Le chemin est résolu dans cet ordre :
  1. `ORGANUM_MIDI_SOCKET`, si la variable existe et n'est pas vide
     (prioritaire ; sert aux tests) ;
  2. `$TMPDIR/organum-midi-<uid>.sock`, si `TMPDIR` existe et n'est pas vide ;
  3. `/tmp/organum-midi-<uid>.sock` sinon.
- `<uid>` est l'identifiant numérique effectif de l'utilisateur qui lance
  organum. Si `TMPDIR` se termine déjà par `/`, la barre n'est pas doublée.
- La longueur du chemin doit être **strictement inférieure** à
  `sizeof(sun_path)`, soit au plus 103 octets sur XNU
  (`sun_path[104]`). Un chemin trop long est **refusé explicitement** : il
  n'est jamais tronqué.
- L'assistant est le **serveur** : il crée la socket, la possède et
  l'écoute. Organum est l'unique **client** et s'y connecte.
- La socket est créée avec les permissions `0600`. L'assistant applique
  `umask(077)` avant `bind()` ; organum vérifie le propriétaire et les
  permissions avant de se connecter.

### Création et socket périmée

**Seul l'assistant** appelle `unlink()`. Organum ne supprime jamais la
socket et ne fait jamais `bind()`.

Au démarrage, l'assistant sonde la socket par `connect()` :

- `ECONNREFUSED` ou `ENOENT` : la socket est périmée ou absente ; l'assistant
  fait `unlink()` puis `bind()` et écoute ;
- connexion réussie : un autre assistant vit déjà ; le nouveau venu sort
  avec le **code 3** sans toucher à la socket ni au pair déjà connecté ;
- toute autre erreur : sortie en erreur, sans `unlink()`.

Organum, de son côté, se contente de `connect()` : si la socket manque encore
(assistant pas démarré), il réessaie plus tard et reste en mode MIDI dégradé
sans jamais créer ni retirer le fichier.

## 2. Poignée de main

Les deux côtés échangent exactement **8 octets** :

| Octet | Contenu |
|---|---|
| 0..3 | magic ASCII `OMID` (`4F 4D 49 44`) |
| 4 | version du protocole : `1` |
| 5 | côté client : `0` ; côté serveur : statut |
| 6..7 | `max_frame` en petit-boutiste (LE16) |

Statuts du serveur (octet 5) :

| Valeur | Sens |
|---|---|
| `0` | accepté |
| `1` | version incompatible |
| `2` | déjà un client |
| `3` | refus interne |

Le client envoie sa poignée (statut `0`), le serveur répond avec la sienne.
La valeur retenue pour la connexion est `min(max_frame client, max_frame
serveur)`, **bornée à 64..8192**. Un `max_frame` hors de ces bornes est
refusé.

Si le statut reçu est différent de `0`, les deux côtés ferment la connexion
après la réponse ; aucune trame ne suit. Une version différente de `1` reçoit
le statut `1` puis la fermeture.

## 3. Trame

En-tête de **4 octets**, puis le corps :

| Octet | Contenu |
|---|---|
| 0 | `type` (u8) |
| 1 | `flags` (u8) |
| 2..3 | `longueur` du corps en petit-boutiste (LE16) |
| 4.. | corps (`longueur` octets) |

`longueur` va de `0` à `max_frame` inclus. Une longueur supérieure à
`max_frame` est une **erreur de décodage** : l'appelant ferme la connexion.
Une longueur inférieure ou égale est lue intégralement, même si le type est
inconnu.

### Types

| Type | Nom | Corps |
|---|---|---|
| `0x01` | MIDI | 1 à 3 octets |
| `0x02` | SYSEX | morceaux de SysEx ; `flags` bit 0 = d'autres morceaux suivent |
| `0x10` | DEVICE_LIST | `n` (u8) puis `n` entrées |
| `0x11` | DEVICE_EVENT | `id` (u8), `present` (u8) |
| `0x20` | SUBSCRIBE | `id` (u8), `actif` (u8) |
| `0x30` | PING | vide |
| `0x31` | PONG | vide |
| `0x7E` | BYE | vide |
| `0x00` | — | refusé |

Tout autre type est **ignoré** (compatibilité ascendante) : la trame est
lue, validée en longueur, puis jetée sans fermer la connexion. Le type
`0x00` est réservé et refusé.

### Trame MIDI (`0x01`)

Le corps contient un unique message MIDI de canal :

- 1 à 3 octets ;
- premier octet entre `0x80` et `0xEF` (statut de canal) ;
- longueur cohérente avec le statut : 2 octets pour `0xCn` et `0xDn`,
  3 octets pour `0x8n`, `0x9n`, `0xAn`, `0xBn` et `0xEn`.

Un corps vide, un statut système (`0xF0`..`0xFF`) ou une longueur
incohérente rendent la trame **invalide** : elle est ignorée et la connexion
est conservée. Les autres messages (SysEx, horloge, transport) passent par
`0x02` ou ne sont pas transmis en v1.

### Trame SYSEX (`0x02`)

Le corps est un morceau de message système exclusif. `flags` bit 0
(`0x01`) indique que d'autres morceaux suivent ; il vaut `0` sur le dernier.
Organum v1 ignore ces trames, mais le format est **définitif** : le bit 0 est
réservé à la suite et ne doit pas recevoir d'autre sens.

### DEVICE_LIST (`0x10`)

Corps : `n` (u8), puis `n` entrées consécutives :

| Champ | Taille |
|---|---|
| `id` | u8 |
| `capacites` | u8 : bit 0 source, bit 1 destination |
| `nom_len` | u8, au plus 63 |
| `nom` | `nom_len` octets UTF-8, sans NUL final |

`n` peut dépasser 32 : l'appelant ne range que les **32 premières** entrées.
Un `n` qui annonce plus d'entrées que le corps n'en contient est **tronqué**
au nombre d'entrées complètes réellement présentes (ni erreur, ni lecture
hors du corps). Un `nom_len` supérieur à 63 est un refus explicite. Un corps
vide (aucun octet `n`) est invalide.

### DEVICE_EVENT (`0x11`)

Corps : `id` (u8) et `present` (u8 : `0` absent, `1` présent). Signale
l'apparition ou la disparition d'un périphérique déjà décrit.

### SUBSCRIBE (`0x20`)

Corps : `id` (u8) et `actif` (u8 : `0` désabonné, `1` abonné). Confirme ou
révoque l'intérêt d'organum pour une source.

### PING / PONG / BYE

`PING` (`0x30`) et `PONG` (`0x31`) ont un corps vide et servent à vérifier
que le pair répond. `BYE` (`0x7E`) annonce une fermeture propre imminente.

## 4. Bornes et comportement en cas d'erreur

- `longueur > max_frame` : erreur de décodage, fermeture de la connexion.
- Version différente de `1` : statut `1` dans la poignée, puis fermeture.
- Corps MIDI invalide : trame ignorée, connexion conservée.
- Type inconnu : trame lue puis ignorée, connexion conservée.
- Corps d'un type connu mal formé (DEVICE_LIST vide, nom de 64 octets) :
  trame ignorée, connexion conservée.

### File pleine et non-blocage

Côté organum, le producteur (fil de lecture de la socket) dépose les messages
MIDI dans une file bornée. Si elle est pleine, il **jette le message et
compte le rejet** ; il ne bloque jamais.

Côté assistant, les écritures de contrôle font **au plus 8 octets** (poignée,
PING/PONG, BYE) et ne doivent jamais bloquer. Sur une socket non bloquante,
`write()` peut renvoyer `EAGAIN` : l'assistant remonte alors `ENOSPC` à Lua
(ou à son appelant) et poursuit, sans attendre.

### SIGPIPE

redbean ignore déjà `SIGPIPE`
(`externe/cosmopolitan/tool/net/redbean.c`, autour de la ligne 7291). Le
protocole ne dépend donc **pas** de `MSG_NOSIGNAL`, qui n'existe pas de façon
uniforme sur toutes les cibles. Une écriture vers un pair disparu renvoie
`EPIPE`, traité comme une fermeture.

## 5. Qui ferme quoi, et dans quel ordre

Un seul côté ferme chaque descripteur ; l'autre détecte la fin de flux
(`read()` renvoie `0`) ou l'erreur d'écriture. L'assistant possède la socket
d'écoute ; organum ne possède que sa connexion.

1. **Organum démarre avant l'assistant.** Organum tente `connect()` et
   reçoit `ENOENT` ou `ECONNREFUSED` : il n'appelle ni `unlink()` ni `bind()`,
   reste en MIDI dégradé et réessaie plus tard. Quand l'assistant démarre,
   sa sonde `connect()` échoue, il fait `unlink()` puis `bind()` et écoute ;
   organum se connecte alors normalement.
2. **Organum s'arrête ou redémarre.** Il envoie `BYE` si possible puis
   ferme sa connexion, sans jamais toucher au fichier de socket. L'assistant
   voit `BYE` ou `read()` renvoyer `0`, ferme la connexion acceptée, garde sa
   socket d'écoute et **toutes ses connexions aux sources CoreMIDI**, puis
   attend un nouveau client. Aucun redémarrage de l'assistant n'est
   nécessaire : le prochain organum échange simplement une nouvelle poignée
   et retrouve les sources déjà énumérées.

   Cas particulier de redbean : à l'arrêt d'organum (`SIGTERM`), redbean
   envoie `SIGTERM` à **tout son groupe de processus** (`kill(0, SIGTERM)`).
   Si l'assistant a été lancé dans ce même groupe, il recevrait ce signal
   alors qu'il n'est pas visé. Il lit donc le PID de son client par
   `LOCAL_PEERPID` et ignore un `SIGTERM` dont l'émetteur est précisément ce
   client organum ; un `SIGTERM` direct (PID de l'assistant, launchd, shell)
   a un autre émetteur et l'arrête normalement. La socket n'est retirée que
   sur cet arrêt direct.
3. **L'assistant s'arrête.** Il envoie `BYE` si possible, ferme la connexion
   acceptée et sa socket d'écoute, puis retire le fichier (`unlink()`).
   Organum lit la fin de flux, ferme sa connexion, repasse en MIDI dégradé et
   réessaie périodiquement ; il ne recrée pas la socket.
4. **Une écriture est en cours au moment de la fermeture.** Le pair qui ferme
   le premier provoque `EPIPE` chez l'autre (SIGPIPE ignoré). L'écrivain
   abandonne l'écriture partielle, ferme à son tour et ne tente pas de
   rejouer la trame : le protocole ne garantit pas la livraison des trames
   en vol.
5. **Fils de requête redbean.** Chaque fils de requête hérite des
   descripteurs de socket du processus principal. Il doit les oublier
   immédiatement (comme `organum.oublier_audio` le fait pour l'audio) : il ne
   lit, n'écrit ni ne ferme la socket MIDI, et ne fait jamais `unlink()`. Seul
   le processus principal (ou le fil dédié qu'il désigne) manipule la socket.
   Un fils qui fermerait le descripteur hérité couperait la connexion du
   processus principal. Le backend applique cette règle : `midi_socket.c`
   mémorise le PID créateur et `midi_lire()` comme `midi_fermer()` ne font
   rien dans tout autre processus.

En résumé : l'assistant crée, possède et retire le fichier de socket ;
organum ne fait que s'y connecter en tant que client `AF_UNIX` et se borne à
fermer ses propres descripteurs.
