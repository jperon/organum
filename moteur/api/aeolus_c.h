#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Résultat de la calibration automatique de la qualité (étape Q3a).
   Les coûts « cout_spat* » sont exprimés par voix et par sous-trame de
   64 échantillons, en microsecondes ; les coûts de réverbération sont par
   bloc de `periode` trames, en millisecondes. estimation_ms[i] est le temps
   de bloc estimé pour le niveau i (0..3) tel que défini par la spécification. */
typedef struct {
    int niveau;
    int tete_reverb;
    double echeance_ms;
    double cout_spat2_us;
    double cout_spat1_us;
    double cout_reverb_tete_ms;
    double cout_reverb_sans_tete_ms;
    double estimation_ms[4];
    int voix_ref;
    double duree_calibration_ms;
} aeolus_calibrage;

/* Micro-banc autonome (aucune instance du moteur) : mesure le coût par voix
   des spatialisations et de la réverbération, puis renvoie le niveau 0..3
   recommandé et remplit `sortie`. `periode` en trames, `taux` en Hz. */
int aeolus_calibrer(int taux, int periode, aeolus_calibrage* sortie);

void* aeolus_creer(int taux);
void aeolus_detruire(void* moteur);

/* Tempérament : nombre de valeurs, nom de chacune (chaîne allouée à
   libérer avec free()), application et lecture de la valeur effective. */
int aeolus_nb_temperaments(void);
const char* aeolus_nom_temperament(int type);
/* Applique à chaud : reconstruit le jeu de tuyaux parallèle puis bascule.
   À appeler hors du fil audio (le moteur conserve le son courant). Renvoie
   0 en cas de succès, -1 si le type est hors bornes. */
int aeolus_temperament(void* moteur, int type);
int aeolus_lire_temperament(void* moteur);

int aeolus_nb_divisions(void* moteur);
const char* aeolus_nom_division(void* moteur, int div);
int aeolus_nb_jeux(void* moteur, int div);
const char* aeolus_nom_jeu(void* moteur, int div, int j);
void aeolus_jeu(void* moteur, int div, int j, int actif);

void aeolus_midi(void* moteur, const unsigned char* octets, int n);
void aeolus_volume(void* moteur, float v);
void aeolus_reverb(void* moteur, float v);
/* Tête de convolution zéro latence de la réverbération (défaut : active).
   Peut être appelée depuis le fil audio, entre deux tampons : elle suit le
   même chemin que le changement d'IR déjà traité par le moteur. */
void aeolus_reverb_tete(void* moteur, int actif);
/* Valeur EFFECTIVE de la tête après application de l'option et de
   ORGANUM_REVERB_TETE : 1 si elle est active, 0 sinon. */
int aeolus_lire_reverb_tete(void* moteur);
/* Limiteur de sortie : actif par défaut (voir aeolus_creer). */
void aeolus_limiteur(void* moteur, int actif);
/* Valeur effective du limiteur (1 actif, 0 coupé). */
int aeolus_lire_limiteur(void* moteur);
void aeolus_gain(void* moteur, int div, float v);

/* Réglages de qualité (voir spécification) :
   champ 0 bruit_attaque (0/1), 1 instabilite (0/1), 2 spatialisation (0/1/2),
   3 polyphonie_max (0..512). Les valeurs hors bornes sont bornées ; un champ
   inconnu est ignoré (aeolus_lire_qualite renvoie -1). */
void aeolus_qualite(void* moteur, int champ, int valeur);
int aeolus_lire_qualite(void* moteur, int champ);

/* Diagnostic : voix prises au pool, et voix tenues (hors release). */
int aeolus_nb_voix(void* moteur);
int aeolus_nb_voix_actives(void* moteur);
int aeolus_note_active(void* moteur, int note);

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