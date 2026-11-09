-- Règles pures du clavier jouable de la page d'orgue : noms français des
-- notes, disposition des touches blanches et noires, canal MIDI associé à
-- une division publiée par /api/orgue, et message « aucun jeu allumé ».
-- Aucun accès au DOM ni au moteur : ce module est éprouvé par
-- web/tests/clavier.lua et consommé par page.moon et client.moon.

-- Noms sans capitale, pour les libellés accessibles ; l'index est la classe
-- de hauteur dans l'octave (0 = do). Les dièses sont écrits en toutes
-- lettres pour rester lisibles par un lecteur d'écran.
NOMS = {
  "do", "do dièse", "ré", "ré dièse", "mi", "fa",
  "fa dièse", "sol", "sol dièse", "la", "la dièse", "si"
}

COURTS = {
  "Do", "Do♯", "Ré", "Ré♯", "Mi", "Fa",
  "Fa♯", "Sol", "Sol♯", "La", "La♯", "Si"
}

-- Classes de hauteur noires dans une octave : do♯, ré♯, fa♯, sol♯, la♯.
NOIRES = {[1]: true, [3]: true, [6]: true, [8]: true, [10]: true}

note_valide = (note) ->
  return false unless type(note) == "number"
  n = math.tointeger note
  n != nil and n >= 0 and n <= 127

classe = (note) ->
  return nil unless note_valide note
  math.tointeger(note) % 12

est_noire = (note) ->
  c = classe note
  c != nil and NOIRES[c] == true

nom = (note) ->
  c = classe note
  return nil unless c
  NOMS[c + 1]

court = (note) ->
  c = classe note
  return nil unless c
  COURTS[c + 1]

-- Diapason scientifique : do 4 = note MIDI 60.
octave = (note) ->
  return nil unless note_valide note
  math.floor(math.tointeger(note) / 12) - 1

libelle = (note) ->
  n = nom note
  return nil unless n
  "#{n} #{octave note}"

-- Nombre de touches blanches avant une noire dans son octave : la position
-- visuelle de la noire, en largeurs de touche blanche (1 à 6).
position_noire = (note) ->
  return nil unless est_noire note
  c = classe note
  p = 0
  for i = 0, c - 1
    p += 1 unless NOIRES[i]
  p

-- Deux octaves (ou plus) regroupées par octave. Chaque groupe porte ses
-- blanches dans l'ordre et ses noires avec leur position. Les notes qui
-- dépasseraient 127 sont omises : le moteur refuse tout le reste.
octaves = (debut = 60, nombre = 2) ->
  debut = math.tointeger(debut) or 60
  nombre = math.tointeger(nombre) or 2
  nombre = 1 if nombre < 1
  liste = {}
  for o = 0, nombre - 1
    base = debut + o * 12
    blanches, noires = {}, {}
    for i = 0, 11
      note = base + i
      continue if note > 127
      if est_noire note
        noires[#noires + 1] = {
          note: note, nom: court(note), libelle: libelle(note),
          position: position_noire(note)
        }
      else
        blanches[#blanches + 1] = {
          note: note, nom: court(note), libelle: libelle(note)
        }
    liste[#liste + 1] = {blanches: blanches, noires: noires} if #blanches > 0 or #noires > 0
  liste

-- Premier canal MIDI d'une division telle que publiée par /api/orgue
-- ({canaux = {1, 2, …}}), ou nil si elle n'en écoute aucun. Le clavier joue
-- sur ce canal : une division peut en écouter plusieurs, on prend le
-- premier comme le fait naturellement le moteur pour un clavier simple.
canal_division = (division) ->
  return nil unless type(division) == "table" and type(division.canaux) == "table"
  c = math.tointeger division.canaux[1]
  return nil unless c and c >= 1 and c <= 16
  c

-- Vrai si aucune division ne publie au moins un jeu allumé. Les jeux dont
-- l'état est inconnu ne comptent pas comme allumés : c'est la même règle
-- que l'affichage « unknown » de page.moon.
aucun_jeu_actif = (divisions) ->
  return true unless type(divisions) == "table"
  for division in *divisions
    for jeu in *(division.stops or {})
      return false if jeu.on == true
  true

{
  :NOMS
  :COURTS
  :note_valide
  :classe
  :est_noire
  :nom
  :court
  :octave
  :libelle
  :position_noire
  :octaves
  :canal_division
  :aucun_jeu_actif
}
