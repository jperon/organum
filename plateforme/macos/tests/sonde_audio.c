/* Sonde CoreAudio : que trouve-t-on réellement sur cette machine ?
 *
 * Énumère les périphériques audio, identifie la sortie par défaut, son nom et
 * ses canaux, puis ouvre un AudioUnit de sortie par défaut avec un rappel de
 * rendu qui compte ses appels pendant une seconde. Aucun son n'est produit
 * (le rappel remplit du silence) : l'objectif est seulement de savoir si
 * CoreAudio appelle vraiment un rappel, ce qui conditionne tout le chemin
 * audio d'organum sur cette plate-forme.
 *
 * Compilation : clang -O2 -framework CoreAudio -framework AudioToolbox \
 *                       sonde_audio.c -o sonde_audio
 * Sortie : lignes « sonde-audio : ... », code 0 si un rappel a été appelé,
 * 1 si aucun périphérique de sortie, 2 si l'AudioUnit n'a pas rendu.
 */
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static _Atomic unsigned long g_appels;

static OSStatus rendre(void *refcon, AudioUnitRenderActionFlags *drapeaux,
                       const AudioTimeStamp *horodatage, UInt32 bus,
                       UInt32 trames, AudioBufferList *donnees)
{
  (void)refcon;
  (void)drapeaux;
  (void)horodatage;
  (void)bus;
  atomic_fetch_add(&g_appels, 1);
  if (donnees != NULL) {
    for (UInt32 i = 0; i < donnees->mNumberBuffers; ++i) {
      float *p = donnees->mBuffers[i].mData;
      if (p != NULL)
        for (UInt32 j = 0; j < trames * donnees->mBuffers[i].mNumberChannels;
             ++j)
          p[j] = 0.0f;
    }
  }
  return noErr;
}

static void nom_objet(AudioObjectID objet, char *sortie, size_t capacite)
{
  sortie[0] = '\0';
  CFStringRef nom = NULL;
  AudioObjectPropertyAddress a = {kAudioObjectPropertyName,
                                  kAudioObjectPropertyScopeGlobal,
                                  kAudioObjectPropertyElementMain};
  UInt32 taille = sizeof nom;
  if (AudioObjectGetPropertyData(objet, &a, 0, NULL, &taille, &nom) == noErr &&
      nom != NULL) {
    CFStringGetCString(nom, sortie, (CFIndex)capacite, kCFStringEncodingUTF8);
    CFRelease(nom);
  }
}

static unsigned canaux_sortie(AudioObjectID objet)
{
  AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration,
                                  kAudioDevicePropertyScopeOutput,
                                  kAudioObjectPropertyElementMain};
  UInt32 taille = 0;
  if (AudioObjectGetPropertyDataSize(objet, &a, 0, NULL, &taille) != noErr ||
      taille == 0)
    return 0;
  AudioBufferList *liste = malloc(taille);
  if (liste == NULL)
    return 0;
  unsigned total = 0;
  if (AudioObjectGetPropertyData(objet, &a, 0, NULL, &taille, liste) == noErr)
    for (UInt32 i = 0; i < liste->mNumberBuffers; ++i)
      total += liste->mBuffers[i].mNumberChannels;
  free(liste);
  return total;
}

int main(void)
{
  /* 1. Énumération de tous les périphériques. */
  AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices,
                                  kAudioObjectPropertyScopeGlobal,
                                  kAudioObjectPropertyElementMain};
  UInt32 taille = 0;
  OSStatus st = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0,
                                               NULL, &taille);
  if (st != noErr) {
    printf("sonde-audio : énumération impossible (OSStatus %d)\n", (int)st);
    return 1;
  }
  const unsigned n = taille / sizeof(AudioObjectID);
  printf("sonde-audio : %u périphérique(s) audio\n", n);
  AudioObjectID *objets = n ? malloc(taille) : NULL;
  if (n && objets == NULL)
    return 1;
  if (n && AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL,
                                      &taille, objets) != noErr) {
    free(objets);
    return 1;
  }
  for (unsigned i = 0; i < n; ++i) {
    char nom[256];
    nom_objet(objets[i], nom, sizeof nom);
    printf("sonde-audio :   objet %u « %s », %u canal(aux) de sortie\n",
           (unsigned)objets[i], nom, canaux_sortie(objets[i]));
  }
  free(objets);

  /* 2. Sortie par défaut. */
  AudioObjectID defaut = kAudioObjectUnknown;
  taille = sizeof defaut;
  a.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
  st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL,
                                  &taille, &defaut);
  if (st != noErr || defaut == kAudioObjectUnknown || defaut == 0) {
    printf("sonde-audio : aucune sortie par défaut (OSStatus %d)\n", (int)st);
    return 1;
  }
  char nom[256];
  nom_objet(defaut, nom, sizeof nom);
  printf("sonde-audio : sortie par défaut : « %s », %u canal(aux)\n", nom,
         canaux_sortie(defaut));

  /* 3. AudioUnit de sortie par défaut, rappel compté pendant 1 s. */
  AudioComponentDescription desc = {
      .componentType = kAudioUnitType_Output,
      .componentSubType = kAudioUnitSubType_DefaultOutput,
      .componentManufacturer = kAudioUnitManufacturer_Apple};
  AudioComponent composant = AudioComponentFindNext(NULL, &desc);
  if (composant == NULL) {
    printf("sonde-audio : aucun composant DefaultOutput\n");
    return 2;
  }
  AudioUnit unite = NULL;
  st = AudioComponentInstanceNew(composant, &unite);
  if (st != noErr) {
    printf("sonde-audio : AudioComponentInstanceNew a échoué (%d)\n", (int)st);
    return 2;
  }
  AudioStreamBasicDescription format = {
      .mSampleRate = 48000.0,
      .mFormatID = kAudioFormatLinearPCM,
      .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      .mBytesPerPacket = 8,
      .mFramesPerPacket = 1,
      .mBytesPerFrame = 8,
      .mChannelsPerFrame = 2,
      .mBitsPerChannel = 32};
  st = AudioUnitSetProperty(unite, kAudioUnitProperty_StreamFormat,
                            kAudioUnitScope_Input, 0, &format,
                            sizeof format);
  if (st != noErr)
    printf("sonde-audio : StreamFormat refusé (%d)\n", (int)st);
  AURenderCallbackStruct rappel = {.inputProc = rendre, .inputProcRefCon = NULL};
  st = AudioUnitSetProperty(unite, kAudioUnitProperty_SetRenderCallback,
                            kAudioUnitScope_Input, 0, &rappel,
                            sizeof rappel);
  if (st != noErr)
    printf("sonde-audio : SetRenderCallback refusé (%d)\n", (int)st);
  st = AudioUnitInitialize(unite);
  if (st != noErr) {
    printf("sonde-audio : AudioUnitInitialize a échoué (%d)\n", (int)st);
    AudioComponentInstanceDispose(unite);
    return 2;
  }
  st = AudioOutputUnitStart(unite);
  if (st != noErr) {
    printf("sonde-audio : AudioOutputUnitStart a échoué (%d)\n", (int)st);
    AudioUnitUninitialize(unite);
    AudioComponentInstanceDispose(unite);
    return 2;
  }
  sleep(1);
  AudioOutputUnitStop(unite);
  AudioUnitUninitialize(unite);
  AudioComponentInstanceDispose(unite);

  const unsigned long appels = atomic_load(&g_appels);
  printf("sonde-audio : rappels de rendu en 1 s : %lu\n", appels);
  if (appels == 0) {
    printf("sonde-audio : CoreAudio n'a appelé aucun rappel : audio réel "
           "impossible\n");
    return 2;
  }
  printf("sonde-audio : sortie audio fonctionnelle\n");
  return 0;
}
