#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void* aeolus_creer(int taux);
void aeolus_detruire(void* moteur);

int aeolus_nb_divisions(void* moteur);
const char* aeolus_nom_division(void* moteur, int div);
int aeolus_nb_jeux(void* moteur, int div);
const char* aeolus_nom_jeu(void* moteur, int div, int j);
void aeolus_jeu(void* moteur, int div, int j, int actif);

void aeolus_midi(void* moteur, const unsigned char* octets, int n);
void aeolus_volume(void* moteur, float v);
void aeolus_reverb(void* moteur, float v);
void aeolus_gain(void* moteur, int div, float v);

void aeolus_rendre(void* moteur, float* g, float* d, int n);

/* Lecture de l'état (les jeux et gains changent aussi par le MIDI). */
int aeolus_jeu_actif(void* moteur, int div, int j);
float aeolus_lire_gain(void* moteur, int div);
float aeolus_lire_volume(void* moteur);
float aeolus_lire_reverb(void* moteur);

/* Canaux MIDI : masques de 16 bits, bit n = canal n+1. */
int aeolus_canaux_division(void* moteur, int div);
void aeolus_fixer_canaux_division(void* moteur, int div, int masque);
int aeolus_canaux_controle(void* moteur);   /* jeux, combinaisons */
void aeolus_fixer_canaux_controle(void* moteur, int masque);
int aeolus_canaux_expression(void* moteur); /* boîte expressive */
void aeolus_fixer_canaux_expression(void* moteur, int masque);

/* Accouplements : liens d'une division vers d'autres (Pedal → Manual I…). */
int aeolus_nb_liens(void* moteur, int div);
int aeolus_division_liee(void* moteur, int div, int lien); /* index, -1 si inconnu */
int aeolus_lien_actif(void* moteur, int div, int lien);
void aeolus_lien(void* moteur, int div, int lien, int actif);

/* Combinaisons (séquenceur d'Aeolus) : étape courante, à partir de 0. */
int aeolus_etape(void* moteur);
int aeolus_nb_etapes(void* moteur);
/* Mémorise la registration courante dans l'étape courante (Aeolus ne le
   fait qu'en quittant l'étape). À appeler depuis le fil audio. */
void aeolus_capturer_etape(void* moteur);

/* État persistant du moteur (jeux, accouplements, canaux, combinaisons) en
   JSON. aeolus_sauvegarder renvoie une chaîne à libérer avec free(). */
char* aeolus_sauvegarder(void* moteur);
int aeolus_restaurer(void* moteur, const char* json);

#ifdef __cplusplus
}
#endif