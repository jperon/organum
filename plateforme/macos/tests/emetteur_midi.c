/* Émetteur MIDI de test : crée une source virtuelle CoreMIDI et joue une note
 * en boucle jusqu'à recevoir SIGTERM, puis relâche la note.
 *
 * Utilisé par plateforme/macos/tests/valider_audio_midi.sh : il rend le MIDI
 * réel vérifiable sur une machine sans clavier (un runner de CI, par
 * exemple). L'émission est répétée toutes les 100 ms parce que
 * `canaux_actifs` côté organum ne retient un canal que 250 ms après le
 * dernier message.
 *
 * Compilation : clang -O2 -framework CoreMIDI -framework CoreFoundation \
 *                       emetteur_midi.c -o emetteur_midi
 * Usage : emetteur_midi [nom] | emetteur_midi --aide
 * Sortie : « emetteur-midi : prêt » une fois la source créée, puis un bilan
 * à l'arrêt. Code 0 si au moins une note a été envoyée.
 */
#include <CoreMIDI/CoreMIDI.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static _Atomic int g_arreter;
static _Atomic unsigned long g_envoyes;

static void sur_signal(int sig)
{
  (void)sig;
  atomic_store(&g_arreter, 1);
}

/* Horodatage 0 : « jouer maintenant ». Ne PAS utiliser CLOCK_MONOTONIC : un
   MIDITimeStamp CoreMIDI est en ticks Mach, et un horodatage en nanosecondes
   place l'événement très loin dans le futur, où il n'arrive jamais. */
static MIDIPacket *paquet_note(MIDIPacketList *liste, MIDIPacket *p,
                               const unsigned char *octets, size_t n)
{
  return MIDIPacketListAdd(liste, 256, p, 0, n, octets);
}

int main(int argc, char **argv)
{
  if (argc > 1 && strcmp(argv[1], "--aide") == 0) {
    printf("emetteur_midi : crée une source MIDI virtuelle et joue do (note "
           "60) sur le canal 1\n"
           "jusqu'à SIGTERM, puis relâche la note. Sert aux tests macOS sans "
           "clavier.\n");
    return 0;
  }
  const char *nom = argc > 1 ? argv[1] : "organum-test-midi";

  MIDIClientRef client = 0;
  OSStatus st = MIDIClientCreate(CFSTR("emetteur-midi"), NULL, NULL, &client);
  if (st != noErr) {
    printf("emetteur-midi : MIDIClientCreate a échoué (%d)\n", (int)st);
    return 1;
  }
  MIDIEndpointRef source = 0;
  CFStringRef nom_cf = CFStringCreateWithCString(kCFAllocatorDefault, nom,
                                                 kCFStringEncodingUTF8);
  st = MIDISourceCreate(client, nom_cf, &source);
  CFRelease(nom_cf);
  if (st != noErr) {
    printf("emetteur-midi : MIDISourceCreate a échoué (%d)\n", (int)st);
    MIDIClientDispose(client);
    return 1;
  }

  signal(SIGTERM, sur_signal);
  signal(SIGINT, sur_signal);
  printf("emetteur-midi : prêt (source « %s »)\n", nom);
  fflush(stdout);

  const unsigned char note_on[3] = {0x90, 60, 100};
  const unsigned char note_off[3] = {0x80, 60, 0};
  unsigned char tampon[256];
  struct timespec pause = {.tv_sec = 0, .tv_nsec = 100000000};
  while (!atomic_load(&g_arreter)) {
    MIDIPacketList *liste = (MIDIPacketList *)tampon;
    MIDIPacket *p = MIDIPacketListInit(liste);
    p = paquet_note(liste, p, note_on, sizeof note_on);
    if (p != NULL) {
      st = MIDIReceived(source, liste);
      if (st == noErr)
        atomic_fetch_add(&g_envoyes, 1);
    }
    nanosleep(&pause, NULL);
  }

  {
    MIDIPacketList *liste = (MIDIPacketList *)tampon;
    MIDIPacket *p = MIDIPacketListInit(liste);
    p = paquet_note(liste, p, note_off, sizeof note_off);
    if (p != NULL)
      MIDIReceived(source, liste);
  }
  nanosleep(&pause, NULL);

  const unsigned long envoyes = atomic_load(&g_envoyes);
  printf("emetteur-midi : %lu note(s) envoyée(s), note relâchée\n", envoyes);
  MIDIEndpointDispose(source);
  MIDIClientDispose(client);
  return envoyes == 0 ? 2 : 0;
}
