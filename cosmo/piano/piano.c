// Piano échantillonné : TinySoundFont sur le SoundFont embarqué.
//
// Une seule unité de compilation porte l'implémentation de stb_vorbis et de
// TSF : c'est la condition pour lire un SF3 (échantillons Ogg Vorbis). Sans
// stb_vorbis, TSF prendrait les octets Ogg pour du PCM et produirait du bruit.
#include "piano.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// stb_vorbis.c définit STB_VORBIS_INCLUDE_STB_VORBIS_H, que tsf.h teste pour
// activer son chemin SF3 : l'inclure avant TSF_IMPLEMENTATION.
#include "stb_vorbis.c"

#define TSF_IMPLEMENTATION
#include "tsf.h"

struct piano {
  tsf *tsf;
  int ncanaux;
};

// Lit tout le fichier embarqué (zip de l'exécutable, via zipos). Renvoie le
// tampon alloué et sa taille, ou NULL avec errno renseigné : appelé au
// démarrage seulement.
static void *lire_fichier(const char *chemin, size_t *taille) {
  int fd = open(chemin, O_RDONLY);
  if (fd < 0) return NULL;
  struct stat st;
  if (fstat(fd, &st) != 0 || st.st_size <= 0) {
    if (!errno) errno = EINVAL;
    close(fd);
    return NULL;
  }
  size_t attendu = (size_t)st.st_size, lu = 0;
  void *donnees = malloc(attendu);
  if (!donnees) {
    errno = ENOMEM;
    close(fd);
    return NULL;
  }
  while (lu < attendu) {
    ssize_t n = read(fd, (char *)donnees + lu, attendu - lu);
    if (n <= 0) break;
    lu += (size_t)n;
  }
  close(fd);
  if (lu != attendu) {
    free(donnees);
    errno = EIO;
    return NULL;
  }
  *taille = attendu;
  return donnees;
}

struct piano *piano_charger(int taux, int max_voix, int ncanaux) {
  size_t taille = 0;
  int echec = 0;
  void *donnees = lire_fichier(PIANO_CHEMIN, &taille);
  if (!donnees) {
    echec = errno ? errno : ENOENT;
    // Message unique : le piano reste indisponible, l'orgue continue.
    fprintf(stderr,
            "organum : piano indisponible (%s illisible : %s) ; l'orgue "
            "fonctionne sans piano\n",
            PIANO_CHEMIN, strerror(echec));
    return NULL;
  }
  tsf *t = tsf_load_memory(donnees, (int)taille);
  free(donnees);  // TSF a décodé et copié les échantillons
  if (!t) {
    fprintf(stderr,
            "organum : piano indisponible (%s illisible : SoundFont refusé) ; "
            "l'orgue fonctionne sans piano\n",
            PIANO_CHEMIN);
    return NULL;
  }
  int preset = tsf_get_presetindex(t, 0, 0);
  if (preset < 0) {
    fprintf(stderr,
            "organum : piano indisponible (%s : pas de programme 0 en "
            "banque 0) ; l'orgue fonctionne sans piano\n",
            PIANO_CHEMIN);
    tsf_close(t);
    return NULL;
  }
  // Toutes les allocations de voix ont lieu ici : tsf_note_on ne réallouera
  // plus (maxVoiceNum fixé), condition pour ne rien allouer dans le fil.
  if (!tsf_set_max_voices(t, max_voix)) {
    fprintf(stderr,
            "organum : piano indisponible (voix : mémoire insuffisante) ; "
            "l'orgue fonctionne sans piano\n");
    tsf_close(t);
    return NULL;
  }
  tsf_set_output(t, TSF_STEREO_INTERLEAVED, taux, 0.0f);
  // Canaux créés maintenant, un par division : tsf_channel_* ne réallouera
  // pas non plus pendant le rendu (voir la note « Thread safety » de tsf.h).
  if (ncanaux < 1) ncanaux = 1;
  for (int c = 0; c < ncanaux; ++c)
    if (!tsf_channel_set_presetindex(t, c, preset)) {
      fprintf(stderr,
              "organum : piano indisponible (canaux : mémoire insuffisante) ; "
              "l'orgue fonctionne sans piano\n");
      tsf_close(t);
      return NULL;
    }
  struct piano *p = malloc(sizeof(*p));
  if (!p) {
    tsf_close(t);
    return NULL;
  }
  p->tsf = t;
  p->ncanaux = ncanaux;
  return p;
}

void piano_fermer(struct piano *p) {
  if (!p) return;
  tsf_close(p->tsf);
  free(p);
}

void piano_taux(struct piano *p, int taux) {
  if (!p) return;
  // Les voix en cours ont leur rapport de hauteur calculé pour l'ancien
  // taux : les couper franchement (relâchement de 10 ms) évite un canard.
  for (int c = 0; c < p->ncanaux; ++c) {
    tsf_channel_set_sustain(p->tsf, c, 0);
    tsf_channel_sounds_off_all(p->tsf, c);
  }
  tsf_set_output(p->tsf, TSF_STEREO_INTERLEAVED, taux, 0.0f);
}

void piano_note_on(struct piano *p, int canal, int note, int velocite) {
  if (!p || canal < 0 || canal >= p->ncanaux || note < 0 || note > 127) return;
  if (velocite <= 0) {
    piano_note_off(p, canal, note);
    return;
  }
  if (velocite > 127) velocite = 127;
  tsf_channel_note_on(p->tsf, canal, note, velocite / 127.0f);
}

void piano_note_off(struct piano *p, int canal, int note) {
  if (!p || canal < 0 || canal >= p->ncanaux || note < 0 || note > 127) return;
  tsf_channel_note_off(p->tsf, canal, note);
}

void piano_sustain(struct piano *p, int canal, int actif) {
  if (!p || canal < 0 || canal >= p->ncanaux) return;
  tsf_channel_midi_control(p->tsf, canal, 64, actif ? 127 : 0);
}

void piano_relacher_canal(struct piano *p, int canal) {
  if (!p || canal < 0 || canal >= p->ncanaux) return;
  // La pédale d'abord : elle libère les notes qu'elle retenait, puis
  // note_off_all relâche les autres (il ignore le sustain).
  tsf_channel_set_sustain(p->tsf, canal, 0);
  tsf_channel_note_off_all(p->tsf, canal);
}

void piano_panique(struct piano *p) {
  if (!p) return;
  tsf_note_off_all(p->tsf);
}

int piano_rendre(struct piano *p, float *tampon, int n) {
  if (!p || !tampon || n <= 0) return 0;
  if (tsf_active_voice_count(p->tsf) <= 0) return 0;
  tsf_render_float(p->tsf, tampon, n, 0);
  return 1;
}

int piano_voix(struct piano *p) { return p ? tsf_active_voice_count(p->tsf) : 0; }
