# Audit « déplacer vers MoonScript » — inventaire

But : déplacer vers MoonScript ce qui peut l'être sans ajouter le moindre
xrun. Règle absolue : rien qui s'exécute dans le fil audio (`boucle_audio`,
`appliquer`, `publier`, `associer`, ni ce qu'ils appellent) ni dans le fil de
tempérament ne reçoit de Lua, de verrou, d'attente, d'allocation ou d'appel
système supplémentaire. En cas de doute, le code reste compilé.

Fréquences : « audio » = à chaque tampon (≈ 10 ms à 512 trames / 48 kHz) ;
« réveil seq » = quand un réglage change ; « requête » = par requête HTTP ou
action d'interface ; « démarrage » = une fois au lancement ; « image » = à
chaque image de la fenêtre native.

## 1. `cosmo/lorganum.c`

### Fil audio et ce qu'il appelle — RESTE (interdit de déplacement)

| Fonction | Ligne | Fréquence | Verdict | Raison |
|---|---:|---|---|---|
| `mesure_reinitialiser` | 231 | réglage | reste | remet à zéro la mesure, appelée depuis `appliquer` (fil audio) |
| `publier` | 418 | ~toutes les 4 tampons | reste | lit le moteur et écrit la mmap partagée depuis le fil audio |
| `panique` | 505 | commande | reste | appelée par `appliquer`, envoie 16 messages MIDI au moteur |
| `appliquer` | 512 | chaque commande | reste | cœur du fil audio, jamais de Lua |
| `associer` | 584 | chaque CC MIDI | reste | fil audio, parcourt les associations et pilote le moteur |
| `verrou_prendre` / `verrou_rendre` | 603 / 610 | reconfiguration | reste | attente atomique utilisée dans le fil audio |
| `attendre_tampon_null` | 900 | chaque tampon (sortie nulle) | reste | attente de cadencement du fil audio |
| `boucle_audio` | 930 | boucle temps réel | reste | le fil audio lui-même |
| `calculer_charge_niveau` (`cosmo/charge_niveau.h`) | — | 1×/s dans `boucle_audio` | reste | règle C pure appelée dans le fil audio ; la déplacer ajouterait du Lua sur ce chemin |

### Fil de tempérament — RESTE (interdit de déplacement)

| Fonction | Ligne | Fréquence | Verdict | Raison |
|---|---:|---|---|---|
| `boucle_temperament` | 620 | demande | reste | fil dédié ; appelle `retunePipes`/`prepareToPlay`, verrou `g_moteur_verrou` |
| `demarrer_fil_temperament` / `arreter_fil_temperament` | 681 / 688 | démarrage / arrêt | reste | gestion du fil temps réel |

### Démarrage, audio, PCM, moteur — RESTE

| Fonction | Ligne | Fréquence | Verdict | Raison |
|---|---:|---|---|---|
| `liberer_demarrage` | 380 | échec de démarrage | reste | libère tube, mmap, moteur |
| `copier_nom` | 410 | démarrage | reste | copie et libère les chaînes de l'API C |
| `copier_demande` | 695 | reconfiguration | reste | lit le mmap sous verrou, côté fil audio |
| `fermer_audio_cumuler` | 705 | reconfiguration | reste | ferme le PCM, cumule les xruns |
| `ouvrir_audio_cfg` | 714 | reconfiguration | reste | ouvre le PCM (ALSA) |
| `erreur_audio` | 722 | échec | reste | publie le message d'erreur audio |
| `capturer_moteur` / `appliquer_sauvegarde` | 740 / 757 | changement de taux | reste | sauvegarde/restaure l'état du moteur |
| `recreer_moteur` | 774 | changement de taux | reste | détruit/recrée le moteur C++ |
| `maintenant_ms` | 792 | réessais audio | reste | horloge monotone |
| `ouvrir_audio_attente` | 801 | reconfiguration | reste | réessaie l'ouverture sur EBUSY |
| `appliquer_demande` | 816 | reconfiguration | reste | réalloue les tampons, rouvre la sortie, fil audio |
| `fermer_pcm_herites` | 285 | fils de requête | reste | ferme les descripteurs PCM hérités sans ALSA |
| `collecter_zone` | 310 | fils de requête | reste | lit `/proc/self/maps` |
| `oublier_audio_fils` | 325 | fils de requête | reste | oublie les mappages PCM hérités |
| `commence_par` | 281 | fils de requête | reste | utilitaire de `collecter_zone` |
| `mesure_init` | 257 | démarrage | reste | initialise les compteurs de mesure |

### Bindings Lua — RESTE sauf décision de calibration (jalon 2)

Tous ces points d'entrée sont appelés depuis le processus principal ou un
fils de requête, jamais dans le fil audio. Ils restent compilés : ils
manipulent la mmap, le tube, le moteur C++ ou le PCM, ce que MoonScript ne
peut pas faire sans une nouvelle couche C.

| Fonction | Ligne | Fréquence | Verdict | Raison |
|---|---:|---|---|---|
| `champ_qualite` | 1123 | réglage | reste | conversion nom → index ; le contrôle de bornes C reste le dernier rempart d'indexation du moteur (jalon 3) |
| `appliquer_qualite_table` | 1130 | démarrage | reste | applique la qualité avant l'ouverture audio, directement via l'API C (le tube n'est pas encore lu) |
| `l_qualite` | 1147 | réglage | reste | contrôle de bornes 0..3 protégeant l'indexation du moteur |
| `l_calibrer` | 1172 | démarrage | **décision à déplacer (jalon 2)** | la mesure reste en C++ ; seule la décision (niveau, tête, estimations) part en Moon |
| `l_demarrer` | 1215 | démarrage | reste | crée mmap/tube/moteur, ouvre audio et MIDI, lance le fil audio |
| `l_limiteur` | 1419 | réglage | reste | envoie une commande fixe au tube |
| `l_tete_reverb` | 1425 | réglage | reste | envoie une commande fixe au tube |
| `l_temperament` | 1435 | réglage | reste | écrit la demande de tempérament dans la mmap |
| `l_oublier_audio` | 1459 | fils | reste | oublie le PCM hérité |
| `l_reconfigurer_audio` | 1468 | réglage | reste | écrit la demande complète dans la mmap sous verrou |
| `etat_ou_erreur` / `envoyer` | 1509 / 1514 | réglage | reste | garde d'état et écriture atomique dans le tube |
| `l_etat` | 1530 | requête | reste | lit la mmap partagée (comme demandé, non déplacé : appelé souvent, gain nul) |
| `l_attendre` | 1661 | requête | reste | attente longue sur `seq` (comme demandé, non déplacé) |
| `l_jeu` | 1678 | requête | reste | envoie une commande au tube |
| `l_gain` | 1684 | requête | reste | envoie une commande au tube |
| `l_volume` | 1690 | requête | reste | envoie une commande au tube |
| `l_reverb` | 1695 | requête | reste | envoie une commande au tube |
| `l_midi` | 1700 | requête | reste | envoie un message MIDI au tube |
| `l_panique` | 1706 | requête | reste | envoie une commande au tube |
| `l_sauvegarder` | 1714 | requête | reste | sérialise l'état du moteur C++ (JSON JUCE) |
| `l_lien` | 1727 | requête | reste | envoie une commande au tube |
| `l_canaux_division` | 1734 | requête | reste | envoie un masque au tube |
| `l_canaux_controle` | 1740 | requête | reste | envoie un masque au tube |
| `l_canaux_expression` | 1745 | requête | reste | envoie un masque au tube |
| `l_associations` | 1752 | requête | reste | borne la longueur et les indices avant de remplir le tableau fixe ; Moon ne valide pas encore cette forme (jalon 3) |
| `l_midi_ports` / `verifier_adresse_midi` / `l_midi_connecter` / `l_midi_deconnecter` | 1788 / 1825 / 1832 / 1845 | requête | reste | parle directement à ALSA, descripteur hérité |
| `l_charge_niveau_diag` | 1861 | diagnostic | reste | expose la règle C `calculer_charge_niveau` ; la déplacer dupliquerait la règle réellement utilisée dans le fil audio |
| `luaopen_organum` | 1891 | chargement | reste | enregistrement du module Lua |

## 2. `moteur/api/aeolus_c.cpp`

Toutes ces fonctions sont l'API C du moteur C++. Elles restent compilées :
ce sont des passerelles minces vers des objets C++ (JUCE/Aeolus) ; les
déplacer en MoonScript ne déplacerait que l'appel, pas la logique, et
exposerait davantage de surface. Plusieurs sont appelées dans le fil audio.

| Fonction | Ligne | Fréquence | Verdict | Raison |
|---|---:|---|---|---|
| `aeolus_creer` | 42 | démarrage | reste | construit le moteur C++ |
| `aeolus_detruire` | 81 | arrêt | reste | détruit le moteur |
| `aeolus_nb_temperaments` | 93 | démarrage/requête | reste | interroge l'enum C++ |
| `aeolus_nom_temperament` | 98 | démarrage/requête | reste | alloue une chaîne depuis `juce::String` |
| `aeolus_temperament` | 107 | réglage | reste | applique le tempérament dans le moteur |
| `aeolus_lire_temperament` | 115 | réveil seq | reste | lu par `publier` (fil audio) |
| `aeolus_nb_divisions` | 120 | démarrage | reste | interroge le moteur |
| `aeolus_nom_division` | 126 | démarrage | reste | alloue une chaîne |
| `aeolus_nb_jeux` | 137 | démarrage | reste | interroge le moteur |
| `aeolus_nom_jeu` | 145 | démarrage | reste | alloue une chaîne |
| `aeolus_jeu` | 158 | audio | reste | active/désactive un jeu |
| `aeolus_midi` | 168 | audio | reste | traite un message MIDI |
| `aeolus_volume` | 177 | audio | reste | règle le volume |
| `aeolus_limiteur` | 183 | audio | reste | règle le limiteur |
| `aeolus_lire_limiteur` | 189 | réveil seq | reste | lecture |
| `aeolus_reverb` | 196 | audio | reste | règle la réverbération |
| `aeolus_reverb_tete` | 202 | audio | reste | bascule la tête zéro latence |
| `aeolus_lire_reverb_tete` | 208 | réveil seq | reste | lu par `publier` |
| `aeolus_gain` | 216 | audio | reste | règle le gain d'une division |
| `aeolus_qualite` | 226 | audio | reste | règle la qualité |
| `aeolus_lire_qualite` | 232 | réveil seq | reste | lu par `publier` |
| `aeolus_nb_voix` | 237 | audio | reste | lu à chaque tampon |
| `aeolus_nb_voix_actives` | 242 | requête | reste | lecture |
| `aeolus_note_active` | 247 | requête | reste | lecture |
| `aeolus_rendre` | 252 | audio | reste | rendu du moteur |
| `aeolus_jeu_actif` | 260 | réveil seq | reste | lu par `publier` |
| `aeolus_lire_gain` | 270 | réveil seq | reste | lu par `publier` |
| `aeolus_lire_volume` / `aeolus_lire_reverb` | 279 / 284 | réveil seq | reste | lus par `publier` |
| `aeolus_canaux_division` / `aeolus_fixer_canaux_division` | 289 / 297 | réveil seq / audio | reste | masque MIDI |
| `aeolus_canaux_controle` / `aeolus_fixer_canaux_controle` | 305 / 310 | réveil seq / audio | reste | masque MIDI |
| `aeolus_canaux_expression` / `aeolus_fixer_canaux_expression` | 315 / 320 | réveil seq / audio | reste | masque MIDI |
| `division` (interne) | 326 | requête | reste | résolution d'index |
| `aeolus_nb_liens` / `aeolus_division_liee` | 335 / 341 | démarrage | reste | interroge le moteur |
| `aeolus_lien_actif` | 352 | réveil seq | reste | lu par `publier` |
| `aeolus_lien` | 358 | audio | reste | active un accouplement |
| `aeolus_etape` / `aeolus_nb_etapes` | 364 / 369 | réveil seq / démarrage | reste | séquenceur |
| `aeolus_sauvegarder` | 374 | requête | reste | JSON JUCE |
| `aeolus_restaurer` | 381 | démarrage | reste | JSON JUCE |
| `aeolus_capturer_etape` | 390 | réveil seq | reste | capture de combinaison |

## 3. `moteur/aeolus/calibration.cpp` — décision seulement

| Élément | Ligne | Fréquence | Verdict | Raison |
|---|---:|---|---|---|
| `maintenant_ms`, `Alea`, `minimum_ms`, `mesurer_spatial2_us`, `mesurer_spat1_us`, `fabriquer_reponse`, `mesurer_reverb_ms`, `lire_env_reel`, `lire_env_entier`, `aeolus_calibrer` (mesures) | 45–337 | démarrage (avant `organum.demarrer`) | reste en C++ | le banc mesure des classes C++ (SpatialSource, BiquadFilter, Convolver) ; on ne peut pas mesurer du C++ depuis Lua |
| décision : `K_RESTE`, `FRACTION_ECHEANCE`, `NIVEAU_SPATIAL`, `NIVEAU_POLYPHONIE`, `NIVEAU_TETE`, boucle d'estimation et choix de `meilleur`, `tete_reverb` | 279–288, 339–371 | démarrage | **à déplacer (jalon 2)** | arithmétique pure sur des mesures déjà prises ; aucun accès au moteur ni au fil audio ; testable en Moon |

Autres usages de `aeolus_calibrer` vérifiés : `cosmo/lorganum.c:1196` (binding
`l_calibrer`) et `moteur/tests/calibration.cpp` (banc). Aucun autre.

## 4. `cosmo/lnuklear.c` — RESTE (comme demandé, sauf preuve)

| Fonction | Ligne | Fréquence | Verdict | Raison |
|---|---:|---|---|---|
| `ui_gc` | 49 | libération | reste | libère l'état Nuklear |
| `cuire_police` | 64 | redimensionnement | reste | recuit la police (coût ponctuel) |
| `lnk_ouvrir` | 91 | démarrage fenêtre | reste | initialise Nuklear et le rawfb |
| `ui_police` / `ui_largeur_texte` | 127 / 134 | image | reste | appels Nuklear par image |
| `ui_protocole` / `ui_evenements` | 143 / 149 | image | reste | entrées du serveur d'affichage |
| `ui_debut` / `ui_fin` / `ui_taille` | 182 / 196 / 202 | image | reste | cadre Nuklear |
| `ui_ligne` / `ui_ligne_ratio` | 209 / 220 | image | reste | disposition Nuklear |
| `ui_texte` / `ui_bouton` / `ui_choix` | 244 / 262 / 296 | image | reste | widgets Nuklear |
| `dessiner_ligne_centree` | 308 | image | reste | rendu |
| `ui_choix_deux` | 325 | image | reste | découpe un libellé sur deux lignes |
| `ui_case` / `ui_etat` / `ui_curseur` | 353 / 375 / 407 | image | reste | widgets Nuklear |
| `ui_groupe_debut` / `ui_groupe_fin` | 418 / 425 | image | reste | groupes Nuklear |
| `ui_dessiner` | 431 | image | reste | rendu brut |
| `luaopen_nk` | 470 | chargement | reste | enregistrement du module |

Conclusion de l'inventaire : seule la **décision de calibration** est un
calcul pur déplaçable sans risque. Les autres candidats restent compilés
(accès mémoire partagée, tube, PCM/ALSA, objets C++, ou chemins temps réel).
