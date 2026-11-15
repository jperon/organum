// Piano échantillonné : un second générateur, mixé dans le fil audio juste
// après Aeolus (voir boucle_audio dans lorganum.c).
//
// TinySoundFont lit le SoundFont SF3 embarqué (Ogg Vorbis, décodé par
// stb_vorbis) ; un canal TSF par division porte le sustain (CC64) et permet
// de relâcher les seules notes de cette division. Toutes les allocations
// (décodage du SoundFont, voix et canaux) ont lieu dans piano_charger(),
// avant le démarrage du fil audio : piano_rendre() et les fonctions MIDI
// n'allouent ni ne bloquent. Seul piano_taux() touche à l'objet pendant que
// le fil tourne, appelé entre deux tampons lors d'une reconfiguration.
#pragma once

// Opaque : tsf.h reste interne à piano.c (l'orgue n'a pas à connaître TSF).
struct piano;

#define PIANO_CHEMIN "/zip/piano/piano.sf3"
// Volume par défaut du piano (0..1), seule source de la valeur : le fil
// audio l'applique au démarrage et la remise à zéro des volumes la relit.
#define PIANO_VOLUME_DEFAUT 0.5f
// Polyphonie maximale : voix préallouées, donc aucune allocation pendant
// tsf_note_on (un échantillon de ce SoundFont produit une voix par note).
#define PIANO_MAX_VOIX 48

// Charge PIANO_CHEMIN, règle la sortie sur taux, borne la polyphonie à
// max_voix et prépare ncanaux canaux sur le programme 0. Renvoie NULL et
// laisse un seul message au journal si le fichier manque ou est illisible :
// l'orgue reste alors intact, sans piano.
struct piano *piano_charger(int taux, int max_voix, int ncanaux);
void piano_fermer(struct piano *p);

// Nouveau taux d'échantillonnage : coupe les voix en cours (leurs rapports
// de hauteur visent l'ancien taux) puis règle la sortie.
void piano_taux(struct piano *p, int taux);

// MIDI, canal 0..ncanaux-1, note 0..127, vélocité 1..127.
void piano_note_on(struct piano *p, int canal, int note, int velocite);
void piano_note_off(struct piano *p, int canal, int note);
void piano_sustain(struct piano *p, int canal, int actif);
// Relâche les notes d'un canal, pédale comprise (drapeau piano coupé).
void piano_relacher_canal(struct piano *p, int canal);
// Relâche toutes les notes (panique), avec leur relâchement naturel.
void piano_panique(struct piano *p);

// Rend n trames stéréo entrelacées (2 × n flottants) dans tampon, après
// l'avoir remis à zéro. Renvoie 0 sans voix active (rien n'est écrit), 1
// sinon : l'appelant n'ajoute le tampon que dans ce cas.
int piano_rendre(struct piano *p, float *tampon, int n);
// Nombre de voix actives (y compris retenues par la pédale).
int piano_voix(struct piano *p);
