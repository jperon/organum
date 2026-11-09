// Anneau SPSC sans verrou pour le transport audio entre organum et un
// assistant macOS. Le tout est static inline, sans allocation, sans appel
// système et sans verrou : l'en-tête et les données sont destinés à une
// mémoire partagée (mmap MAP_SHARED), les compteurs étant les seuls points de
// synchronisation.
//
// Les données sont des trames float32 entrelacées stéréo, exactement ce que
// produit boucle_audio dans cosmo/lorganum.c : aucune conversion. La capacité
// est un nombre de trames, une puissance de deux ; la position réelle d'un
// compteur libre est compteur & (capacite - 1).
//
// Un seul producteur écrit ecrit, un seul consommateur écrit lu ; le
// producteur lit lu avec acquire et publie ecrit avec release, le
// consommateur fait l'inverse. Aucun seq_cst, aucun volatile.
#pragma once

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// Magic ASCII « OAUD » lu en petit-boutiste.
#define ANNEAU_AUDIO_MAGIE 0x4455414Fu
/* Version de la disposition et de la sémantique de l'en-tête. Toute
   modification des champs, de leur ordre ou de leur sens (par exemple le
   drapeau demarre ajouté en v2) impose de l'incrémenter : un organum et un
   assistant de versions différentes doivent se REFUSER explicitement, jamais
   partager un anneau dont l'un ignore un champ. Voir PROTOCOLE-AUDIO.md. */
#define ANNEAU_AUDIO_VERSION 2

// 16384 trames = 128 Kio en float32 stéréo.
#define ANNEAU_AUDIO_CAPACITE_MAX 16384u
#define ANNEAU_AUDIO_CAPACITE_MIN 256u

// En-tête partagé. Les champs de configuration sont fixes après
// initialisation ; les compteurs sont libres sur 64 bits. La réserve avant
// ecrit place les compteurs sur une ligne de cache distincte de la
// configuration, celle d'après arrondit l'en-tête à 128 octets pour que les
// données commencent alignées.
struct anneau_entete {
  uint32_t magie;
  uint32_t version;
  uint32_t canaux;
  uint32_t octets_trame;
  uint32_t taux;
  uint32_t periode;
  uint32_t capacite;
  uint32_t generation;
  uint32_t drapeaux;
  uint32_t reserve[7];
  _Atomic uint64_t ecrit;
  _Atomic uint64_t lu;
  _Atomic uint64_t underruns;
  _Atomic uint64_t overruns;
  _Atomic uint64_t trames_jouees;
  _Atomic uint32_t arret;
  /* Producteur : 1 dès la première écriture d'une génération, remis à 0 par
     anneau_initialiser et anneau_reinitialiser. Tant qu'il vaut 0, le
     consommateur ne compte pas d'underrun : l'absence de données est un
     démarrage (ou une reconfiguration), pas une famine. */
  _Atomic uint32_t demarre;
  uint32_t reserve_alignement[4];
};

// Données de l'anneau, juste après l'en-tête. Le tampon doit avoir été
// dimensionné pour capacite * octets_trame octets.
static inline void *anneau_donnees(struct anneau_entete *e) {
  return (void *)(e + 1);
}

// Masque de position pour une capacité puissance de deux.
static inline uint32_t anneau_masque(const struct anneau_entete *e) {
  return e->capacite - 1u;
}

// Capacité à négocier pour une profondeur de nb_periodes périodes : la plus
// petite puissance de deux qui les contient, bornée par MIN et MAX. Le
// fichier .pcm garde sa taille maximale ; seule la fenêtre utile change.
static inline uint32_t anneau_capacite_negocier(uint32_t periode,
                                                uint32_t nb_periodes) {
  if (periode == 0 || nb_periodes == 0)
    return ANNEAU_AUDIO_CAPACITE_MIN;
  const uint64_t besoin = (uint64_t)periode * (uint64_t)nb_periodes;
  if (besoin <= ANNEAU_AUDIO_CAPACITE_MIN)
    return ANNEAU_AUDIO_CAPACITE_MIN;
  if (besoin >= ANNEAU_AUDIO_CAPACITE_MAX)
    return ANNEAU_AUDIO_CAPACITE_MAX;
  uint32_t capacite = ANNEAU_AUDIO_CAPACITE_MIN;
  while (capacite < besoin)
    capacite <<= 1;
  return capacite;
}

// Initialise un en-tête dans une mémoire déjà allouée. Renvoie 0 en cas de
// succès, -1 si la capacité n'est pas une puissance de deux entre les bornes
// ou si un descripteur de trame est nul.
static inline int anneau_initialiser(struct anneau_entete *e, uint32_t canaux,
                                     uint32_t octets_trame, uint32_t taux,
                                     uint32_t periode, uint32_t capacite,
                                     uint32_t generation) {
  if (e == NULL) return -1;
  if (canaux == 0 || octets_trame == 0) return -1;
  if (capacite < ANNEAU_AUDIO_CAPACITE_MIN ||
      capacite > ANNEAU_AUDIO_CAPACITE_MAX ||
      (capacite & (capacite - 1u)) != 0)
    return -1;

  memset(e, 0, sizeof *e);
  e->magie = ANNEAU_AUDIO_MAGIE;
  e->version = ANNEAU_AUDIO_VERSION;
  e->canaux = canaux;
  e->octets_trame = octets_trame;
  e->taux = taux;
  e->periode = periode;
  e->capacite = capacite;
  e->generation = generation;
  e->drapeaux = 0;
  atomic_init(&e->ecrit, 0);
  atomic_init(&e->lu, 0);
  atomic_init(&e->underruns, 0);
  atomic_init(&e->overruns, 0);
  atomic_init(&e->trames_jouees, 0);
  atomic_init(&e->arret, 0);
  atomic_init(&e->demarre, 0);
  return 0;
}

// Place libre en trames, vue par le producteur. Le consommateur ne peut que
// la faire croître, donc la valeur est une borne inférieure utilisable.
static inline uint64_t anneau_place_libre(struct anneau_entete *e) {
  const uint64_t ecrit =
      atomic_load_explicit(&e->ecrit, memory_order_relaxed);
  const uint64_t lu = atomic_load_explicit(&e->lu, memory_order_acquire);
  const uint64_t utilises = ecrit - lu;
  return utilises >= e->capacite ? 0 : e->capacite - utilises;
}

// Trames disponibles pour le consommateur.
static inline uint64_t anneau_disponible(struct anneau_entete *e) {
  const uint64_t lu = atomic_load_explicit(&e->lu, memory_order_relaxed);
  const uint64_t ecrit =
      atomic_load_explicit(&e->ecrit, memory_order_acquire);
  const uint64_t disponibles = ecrit - lu;
  return disponibles > e->capacite ? e->capacite : disponibles;
}

// Écrit au plus trames trames depuis source, sans jamais dépasser la place
// libre. Renvoie le nombre de trames réellement écrites. Les trames refusées
// faute de place alimentent overruns. Un anneau arrêté n'écrit rien.
static inline size_t anneau_ecrire(struct anneau_entete *e, const void *source,
                                   size_t trames) {
  if (atomic_load_explicit(&e->arret, memory_order_acquire) != 0) return 0;
  if (trames == 0) return 0;

  const uint64_t ecrit =
      atomic_load_explicit(&e->ecrit, memory_order_relaxed);
  const uint64_t lu = atomic_load_explicit(&e->lu, memory_order_acquire);
  const uint64_t utilises = ecrit - lu;
  const uint64_t libre =
      utilises >= e->capacite ? 0 : e->capacite - utilises;
  if ((uint64_t)trames > libre) {
    const uint64_t refuse = (uint64_t)trames - libre;
    atomic_fetch_add_explicit(&e->overruns, refuse, memory_order_relaxed);
    trames = (size_t)libre;
    if (trames == 0) return 0;
  }

  const uint32_t masque = anneau_masque(e);
  const size_t octets = e->octets_trame;
  uint8_t *donnees = (uint8_t *)anneau_donnees(e);
  const size_t position = (size_t)(ecrit & masque);
  size_t premiere = e->capacite - position;
  if (premiere > trames) premiere = trames;

  memcpy(donnees + position * octets, source, premiere * octets);
  if (trames > premiere) {
    const uint8_t *reste = (const uint8_t *)source + premiere * octets;
    memcpy(donnees, reste, (trames - premiere) * octets);
  }

  atomic_store_explicit(&e->ecrit, ecrit + trames, memory_order_release);
  /* Après ecrit : un consommateur qui voit demarre à 1 verra les données. */
  atomic_store_explicit(&e->demarre, 1, memory_order_release);
  return trames;
}

// Lit au plus trames trames vers destination, sans dépasser le disponible.
// Renvoie le nombre de trames réellement lues. Les trames manquantes
// alimentent underruns et les trames lues alimentent trames_jouees. Un
// anneau arrêté ne lit rien.
static inline size_t anneau_lire(struct anneau_entete *e, void *destination,
                                 size_t trames) {
  if (atomic_load_explicit(&e->arret, memory_order_acquire) != 0) return 0;
  if (trames == 0) return 0;
  /* Génération pas encore démarrée : silence, sans compter d'underrun. Le
     consommateur complète le bloc par du silence et l'interface publie cet
     état comme une suspension explicite, pas comme une famine. */
  if (atomic_load_explicit(&e->demarre, memory_order_acquire) == 0) return 0;

  const uint64_t lu = atomic_load_explicit(&e->lu, memory_order_relaxed);
  const uint64_t ecrit =
      atomic_load_explicit(&e->ecrit, memory_order_acquire);
  const uint64_t disponibles = ecrit - lu;
  if ((uint64_t)trames > disponibles) {
    const uint64_t manque = (uint64_t)trames - disponibles;
    atomic_fetch_add_explicit(&e->underruns, manque, memory_order_relaxed);
    trames = (size_t)disponibles;
    if (trames == 0) return 0;
  }

  const uint32_t masque = anneau_masque(e);
  const size_t octets = e->octets_trame;
  const uint8_t *donnees = (const uint8_t *)anneau_donnees(e);
  const size_t position = (size_t)(lu & masque);
  size_t premiere = e->capacite - position;
  if (premiere > trames) premiere = trames;

  memcpy(destination, donnees + position * octets, premiere * octets);
  if (trames > premiere) {
    uint8_t *reste = (uint8_t *)destination + premiere * octets;
    memcpy(reste, donnees, (trames - premiere) * octets);
  }

  atomic_store_explicit(&e->lu, lu + trames, memory_order_release);
  atomic_fetch_add_explicit(&e->trames_jouees, trames, memory_order_relaxed);
  return trames;
}

// Remet les compteurs et le drapeau d'arrêt à zéro, sans toucher à la
// configuration ni aux données.
static inline void anneau_reinitialiser(struct anneau_entete *e) {
  atomic_store_explicit(&e->ecrit, 0, memory_order_relaxed);
  atomic_store_explicit(&e->lu, 0, memory_order_relaxed);
  atomic_store_explicit(&e->underruns, 0, memory_order_relaxed);
  atomic_store_explicit(&e->overruns, 0, memory_order_relaxed);
  atomic_store_explicit(&e->trames_jouees, 0, memory_order_relaxed);
  atomic_store_explicit(&e->arret, 0, memory_order_relaxed);
  atomic_store_explicit(&e->demarre, 0, memory_order_relaxed);
}
