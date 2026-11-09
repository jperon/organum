-- Assistant natif macOS (organum-helper) embarqué dans organum.com : chemins
-- et décisions pures. L'extraction et le lancement restent dans init.moon ;
-- rien ici ne touche au système, pour rester testable sous Linux.
--
-- L'utilisateur ne lance qu'un binaire : organum installe l'assistant depuis
-- /zip/.organum/organum-helper, puis le lance dans son groupe de processus.
-- Un assistant déjà vivant (lancement manuel ou LaunchAgent) est réutilisé.

ARCHIVE = "/zip/.organum/organum-helper"

-- Base du dossier stable : TMPDIR, qui est propre à l'utilisateur sous macOS
-- et le même que celui des sockets de l'assistant. À défaut, le cache de
-- l'utilisateur, puis /tmp (comme le repli des sockets).
base_dossier = (tmpdir, home) ->
  if tmpdir and tmpdir != "" then tmpdir
  elseif home and home != "" then "#{home}/Library/Caches"
  else "/tmp"

dossier = (tmpdir, home) -> "#{base_dossier tmpdir, home}/.organum"
chemin = (tmpdir, home) -> "#{dossier tmpdir, home}/organum-helper"
chemin_log = (tmpdir, home) -> "#{dossier tmpdir, home}/organum-helper.log"

sans_barre_finale = (p) ->
  return p unless p and p != ""
  q = p\gsub "/+$", ""
  -- Ne jamais réduire la racine « / » à la chaîne vide.
  q == "" and "/" or q

-- Même règle que trame_chemin_socket_nom (plateforme/macos/trames.h) :
-- variable non vide prioritaire, sinon <tmpdir ou /tmp>/<nom>-<uid>.sock.
chemin_socket = (variable, tmpdir, uid, nom) ->
  if variable and variable != "" then variable
  else
    base = sans_barre_finale if tmpdir and tmpdir != "" then tmpdir else "/tmp"
    separateur = if base == "/" then "" else "/"
    "#{base}#{separateur}#{nom}-#{uid}.sock"

-- Faut-il un assistant ? Uniquement sous macOS, et seulement si un des deux
-- axes socket est réellement utilisé (le helper sert les deux domaines).
besoin = (plateforme, sans_backend, midi_actif, midi_socket) ->
  return false unless plateforme == "macos"
  (sans_backend != true) or (midi_actif == true and midi_socket == true)

-- États publiés par init.moon :
--   nil                     : pas concerné (Linux, ou aucun axe socket) ;
--   "actif"                 : lancé par organum, ou instance déjà vivante ;
--   "non_embarque"          : archive construite sans organum-helper ;
--   "extraction_impossible" : écriture de l'extrait refusée, ou contenu
--                             extrait différent de l'archive (tronqué) ;
--   "inutilisable"          : l'extrait refuse de démarrer (--aide en échec :
--                             signature absente sous arm64, architecture
--                             inconnue, quarantaine, binaire corrompu) ;
--   "lancement_impossible"  : extrait présent mais exécution impossible.
-- Tout autre état (processus mort en attente de relance) se tait : le
-- heartbeat s'en occupe, sans alarmer l'utilisateur.

-- Intégrité de l'extrait, puis test d'exécution réel. Le contenu doit être
-- identique à l'archive (une écriture partielle est ainsi démasquée) ;
-- `--aide` doit rendre 0. C'est le seul contrôle qui couvre aussi une
-- signature absente (macOS arm64 refuse alors l'exécution) et un attribut de
-- quarantaine, sans dépendre d'un outil externe (codesign, xattr).
-- `source` et `extrait` sont des chaînes ; `code_aide` le code de sortie de
-- l'extrait lancé avec --aide (nil si le lancement n'a pas rendu de code).
verifier_extrait = (source, extrait, code_aide) ->
  return "extraction_impossible" unless type(extrait) == "string" and #extrait > 0
  return "extraction_impossible" unless #extrait == #source and extrait == source
  return "inutilisable" unless code_aide == 0
  nil

-- Message d'état de l'assistant : nil quand tout va bien (ou hors macOS).
-- Le journal n'est nommé que pour les échecs qui demandent une enquête ; le
-- texte dit quoi faire, sans jamais accuser l'utilisateur.
message = (etat, log) ->
  if etat == "non_embarque"
    "Assistant natif macOS absent de cette archive : reconstruisez organum avec plateforme/macos/build/organum-helper présent (voir plateforme/macos/LANCEMENT.md)."
  elseif etat == "extraction_impossible"
    "Assistant natif macOS impossible à installer : l'orgue fonctionne sans audio ni MIDI natifs. Voir le journal « #{log or "?"} » et plateforme/macos/LANCEMENT.md."
  elseif etat == "inutilisable"
    "Assistant natif macOS inutilisable : le système refuse de l'exécuter (signature absente, architecture non prise en charge ou fichier corrompu). L'orgue fonctionne sans audio ni MIDI natifs. Voir le journal « #{log or "?"} » et plateforme/macos/LANCEMENT.md."
  elseif etat == "lancement_impossible"
    "Assistant natif macOS impossible à lancer : l'orgue fonctionne sans audio ni MIDI natifs. Voir le journal « #{log or "?"} » et plateforme/macos/LANCEMENT.md."
  else
    nil

{ :ARCHIVE, :base_dossier, :dossier, :chemin, :chemin_log, :chemin_socket,
  :besoin, :verifier_extrait, :message }
