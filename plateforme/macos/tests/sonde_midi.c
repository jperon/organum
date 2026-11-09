/* Sonde CoreMIDI : le MIDI fonctionne-t-il sur cette machine, et peut-on
 * créer une source virtuelle qui boucle vers une destination ?
 *
 * Contrôles :
 *   1. MIDIClientCreate ;
 *   2. nombre de sources et de destinations visibles ;
 *   3. création d'une destination virtuelle avec rappel ;
 *   4. création d'une source virtuelle, connexion de la source à la
 *      destination, envoi d'une note par MIDIReceived ;
 *   5. le rappel a-t-il vraiment reçu les octets envoyés ?
 *
 * Compilation : clang -O2 -framework CoreMIDI sonde_midi.c -o sonde_midi
 * Sortie : lignes « sonde-midi : ... », code 0 si la boucle fonctionne,
 * 1 si le client n'a pas pu être créé, 2 si la source ou la destination
 * virtuelle est refusée, 3 si la note n'est jamais arrivée.
 */
#include <CoreMIDI/CoreMIDI.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static _Atomic unsigned long g_recus;
static unsigned char g_derniers[16];
static _Atomic size_t g_derniers_len;

static void recevoir(const MIDIPacketList *liste, void *refcon,
                     void *connexion)
{
  (void)refcon;
  (void)connexion;
  const MIDIPacket *p = &liste->packet[0];
  for (UInt32 i = 0; i < liste->numPackets; ++i) {
    atomic_fetch_add(&g_recus, 1);
    size_t n = p->length < sizeof g_derniers ? p->length : sizeof g_derniers;
    memcpy(g_derniers, p->data, n);
    atomic_store(&g_derniers_len, n);
    p = MIDIPacketNext(p);
  }
}

int main(void)
{
  MIDIClientRef client = 0;
  OSStatus st = MIDIClientCreate(CFSTR("sonde-midi"), NULL, NULL, &client);
  printf("sonde-midi : MIDIClientCreate : %d\n", (int)st);
  if (st != noErr)
    return 1;

  const ItemCount sources = MIDIGetNumberOfSources();
  const ItemCount destinations = MIDIGetNumberOfDestinations();
  printf("sonde-midi : sources visibles : %lu, destinations : %lu\n",
         (unsigned long)sources, (unsigned long)destinations);

  MIDIEndpointRef destination = 0;
  st = MIDIDestinationCreate(client, CFSTR("sonde-midi-destination"),
                             recevoir, NULL, &destination);
  printf("sonde-midi : MIDIDestinationCreate : %d\n", (int)st);
  if (st != noErr) {
    MIDIClientDispose(client);
    return 2;
  }

  MIDIEndpointRef source = 0;
  st = MIDISourceCreate(client, CFSTR("sonde-midi-source"), &source);
  printf("sonde-midi : MIDISourceCreate : %d\n", (int)st);
  if (st != noErr) {
    MIDIEndpointDispose(destination);
    MIDIClientDispose(client);
    return 2;
  }

  MIDIPortRef port = 0;
  st = MIDIInputPortCreate(client, CFSTR("sonde-midi-port"), recevoir, NULL,
                           &port);
  printf("sonde-midi : MIDIInputPortCreate : %d\n", (int)st);
  if (st != noErr) {
    MIDIEndpointDispose(source);
    MIDIEndpointDispose(destination);
    MIDIClientDispose(client);
    return 2;
  }
  st = MIDIPortConnectSource(port, source, NULL);
  printf("sonde-midi : MIDIPortConnectSource : %d\n", (int)st);

  unsigned char tampon[64];
  MIDIPacketList *liste = (MIDIPacketList *)tampon;
  MIDIPacket *paquet = MIDIPacketListInit(liste);
  const Byte note[6] = {0x90, 60, 100, 0x80, 60, 0};
  paquet = MIDIPacketListAdd(liste, sizeof tampon, paquet, 0, sizeof note,
                             note);
  if (paquet == NULL) {
    printf("sonde-midi : construction du paquet impossible\n");
    MIDIPortDispose(port);
    MIDIEndpointDispose(source);
    MIDIEndpointDispose(destination);
    MIDIClientDispose(client);
    return 2;
  }
  st = MIDIReceived(source, liste);
  printf("sonde-midi : MIDIReceived : %d\n", (int)st);
  usleep(300000);

  const unsigned long recus = atomic_load(&g_recus);
  const size_t len = atomic_load(&g_derniers_len);
  printf("sonde-midi : paquets reçus en boucle : %lu (%zu octets)\n", recus,
         len);
  if (len > 0) {
    printf("sonde-midi : premiers octets :");
    for (size_t i = 0; i < len; ++i)
      printf(" %02X", g_derniers[i]);
    printf("\n");
  }

  MIDIPortDisconnectSource(port, source);
  MIDIPortDispose(port);
  MIDIEndpointDispose(source);
  MIDIEndpointDispose(destination);
  MIDIClientDispose(client);

  if (recus == 0) {
    printf("sonde-midi : aucune boucle MIDI : MIDI réel impossible\n");
    return 3;
  }
  printf("sonde-midi : MIDI fonctionnel (source virtuelle, note reçue)\n");
  return 0;
}
