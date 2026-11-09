-- Feuille de style (chaîne longue).
CSS = [[
  :root {
    color-scheme: dark;
    --bg: #05070a;
    --panel: #10151c;
    --panel-raised: #19212b;
    --track: #2b3644;
    --border: #435164;
    --text: #f7fafc;
    --text-dim: #b9c5d3;
    --accent: #63d2ff;
    --accent-bright: #a6e7ff;
    --accent-ink: #02131c;
    --warn: #ffb86b;
    --warn-bg: #3a2712;
    --ok: #7cf0b2;
    --off: #ff9a9a;
    --focus: #ffe066;
    --shadow: 0 10px 30px rgba(0, 0, 0, 0.45);
    --transparent: transparent;
    --on: #7cf0b2;
    --unknown: #b9c5d3;
  }

  *,
  *::before,
  *::after {
    box-sizing: border-box;
  }

  html {
    -webkit-text-size-adjust: 100%;
  }

  body {
    margin: 0;
    min-height: 100vh;
    min-height: 100svh;
    padding: 16px;
    display: flex;
    align-items: flex-start;
    justify-content: center;
    background: var(--bg);
    color: var(--text);
    font-family: system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    font-size: 18px;
    line-height: 1.4;
    -webkit-font-smoothing: antialiased;
  }

  main {
    width: 100%;
    max-width: 480px;
    min-width: 0;
    margin: 0 auto;
    padding: 8px 0 24px;
    display: flex;
    flex-direction: column;
    gap: 20px;
  }

  .app-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }

  h1 {
    margin: 0;
    font-size: 1.65rem;
    font-weight: 700;
    letter-spacing: -0.015em;
  }

  .readout {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 2px;
  }

  .value {
    margin: 0;
    color: var(--text);
    font-size: 2.4rem;
    font-weight: 800;
    line-height: 0.95;
    letter-spacing: -0.05em;
    font-variant-numeric: tabular-nums;
    text-align: center;
    white-space: nowrap;
  }

  .status {
    flex: 0 0 auto;
    width: 12px;
    height: 12px;
    min-width: 12px;
    min-height: 12px;
    margin: 0;
    padding: 0;
    border: 0;
    border-radius: 50%;
    background: var(--off);
    box-shadow: none;
    transition: background-color 0.2s ease, border-color 0.2s ease, box-shadow 0.2s ease;
  }

  .status.etat-vert {
    background: var(--ok);
  }

  .status.etat-orange {
    background: var(--warn);
    box-shadow: inset 0 0 0 3px var(--bg);
  }

  .status.etat-rouge {
    border: 2px solid var(--off);
    background: transparent;
  }

  .etat-fallback {
    color: var(--text-dim);
    font-size: 0.78rem;
    font-weight: 500;
    white-space: nowrap;
  }

  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    clip-path: inset(50%);
    white-space: nowrap;
    border: 0;
  }

  .controls {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }

  .slider-wrap {
    --slider-len: min(62vh, 520px);
    position: relative;
    height: var(--slider-len);
    min-width: 0;
  }

  input[type="range"] {
    -webkit-appearance: none;
    appearance: none;
    display: block;
    position: absolute;
    top: 50%;
    left: 50%;
    width: calc(var(--slider-len) - 48px);
    height: 64px;
    transform: translate(-50%, -50%) rotate(-90deg);
    touch-action: none;
    margin: 0;
    padding: 0;
    border: 0;
    background: var(--transparent);
    cursor: pointer;
    --fill: 50%;
  }

  /* Curseur de réverbération : horizontal, dans le flux. */
  input#reverb {
    position: static;
    width: 100%;
    height: 44px;
    transform: none;
  }

  input[type="range"]::-webkit-slider-runnable-track {
    height: 20px;
    border: 1px solid var(--border);
    border-radius: 999px;
    background: linear-gradient(
      to right,
      var(--accent) 0%,
      var(--accent) var(--fill),
      var(--track) var(--fill),
      var(--track) 100%
    );
  }

  input[type="range"]::-webkit-slider-thumb {
    -webkit-appearance: none;
    appearance: none;
    width: 48px;
    height: 48px;
    margin-top: -15px;
    border: 4px solid var(--accent-ink);
    border-radius: 50%;
    background: var(--accent-bright);
    box-shadow: var(--shadow);
    cursor: grab;
  }

  input[type="range"]:active::-webkit-slider-thumb {
    cursor: grabbing;
  }

  input[type="range"]::-moz-range-track {
    height: 20px;
    border: 1px solid var(--border);
    border-radius: 999px;
    background: var(--track);
  }

  input[type="range"]::-moz-range-progress {
    height: 20px;
    border-radius: 999px;
    background: var(--accent);
  }

  input[type="range"]::-moz-range-thumb {
    width: 48px;
    height: 48px;
    border: 4px solid var(--accent-ink);
    border-radius: 50%;
    background: var(--accent-bright);
    box-shadow: var(--shadow);
    cursor: grab;
  }

  .steps {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
  }

  .btn {
    min-height: 56px;
    padding: 0 16px;
    border: 2px solid var(--border);
    border-radius: 16px;
    background: var(--panel-raised);
    color: var(--text);
    font: inherit;
    font-size: 1.3rem;
    font-weight: 700;
    line-height: 1;
    cursor: pointer;
    touch-action: manipulation;
    -webkit-tap-highlight-color: var(--transparent);
    user-select: none;
    transition: background-color 0.15s ease, border-color 0.15s ease, transform 0.06s ease;
  }

  .btn:hover {
    border-color: var(--accent);
  }

  .btn:active {
    background: var(--panel);
    transform: translateY(1px);
  }

  .btn.mute {
    width: 100%;
    min-height: 60px;
    font-size: 1.05rem;
    letter-spacing: 0.01em;
  }

  .btn.mute.is-muted {
    border-color: var(--warn);
    background: var(--warn-bg);
    color: var(--warn);
  }

  .btn:focus-visible,
  input[type="range"]:focus-visible {
    outline: 4px solid var(--focus);
    outline-offset: 4px;
  }

  /* Onglets */
  .tabs {
    display: flex;
    gap: 8px;
  }
  .tab {
    flex: 1 1 0;
    min-height: 48px;
    border: 2px solid var(--border);
    border-radius: 12px;
    background: var(--panel);
    color: var(--text-dim);
    font: inherit;
    font-size: 1rem;
    font-weight: 700;
    cursor: pointer;
    touch-action: manipulation;
  }
  .tab.active {
    border-color: var(--accent);
    background: var(--panel-raised);
    color: var(--text);
  }
  .tab-panel[hidden] {
    display: none;
  }

  /* Orgue */
  .division {
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 10px;
    background: var(--panel);
    margin: 0;
  }
  .division-nom {
    margin: 0;
    cursor: pointer;
    font-weight: 700;
    font-size: 1.1rem;
    padding: 4px 0;
  }
  /* Claviers : une colonne au téléphone, côte à côte dès que la largeur le
     permet ; l'onglet Orgue élargit alors la page (l'onglet Volume reste
     étroit). */
  main:has(#panel-orgue:not([hidden])) {
    max-width: 1600px;
  }

  .divisions {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 300px), 1fr));
    gap: 12px;
    align-items: start;
  }

  .links { display: flex; flex-wrap: wrap; gap: 2px; margin-top: 2px; }
  .links .link { flex: 1 1 4em; }
  /* Transposition globale, en bas de la colonne du Manuel III. */
  .transposition {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    margin-top: 10px;
    padding: 4px;
    border: 1px solid transparent;
    border-radius: 10px;
  }
  .transposition-libelle {
    flex: 1 1 100%;
    font-size: 0.85rem;
    color: var(--text-dim);
  }
  .transposition .btn.small {
    min-width: 48px;
    min-height: 44px;
    padding: 0 10px;
  }
  .transposition-valeur {
    min-width: 2.6em;
    text-align: center;
    font-size: 1.15rem;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
  }
  /* La valeur est un bouton (clic = retour à 0) qui garde l'apparence de
     l'ancien texte : fond transparent, même graisse et chiffres tabulaires,
     cible d'au moins 44 px, sans déborder sur les bornes voisines. */
  .transposition .btn.transposition-valeur {
    min-width: 2.6em;
    min-height: 44px;
    padding: 0 6px;
    background: transparent;
  }
  .transposition:not(.active) .btn.transposition-valeur {
    border-color: transparent;
  }
  .transposition .btn.transposition-valeur:hover {
    border-color: var(--accent);
  }
  .transposition.active {
    border-color: var(--accent);
    background: rgba(99, 210, 255, 0.12);
  }
  .transposition.active .transposition-valeur,
  .transposition.active .transposition-libelle {
    color: var(--accent-bright);
  }
  .transposition.active .btn.small {
    border-color: var(--accent);
    color: var(--accent-bright);
  }
  .transposition .btn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
    border-color: var(--border);
  }
  /* Clavier jouable : panneau repliable natif, replié par défaut. Les
     touches ont une largeur fixe (≥ 44 px) et les deux octaves passent
     l'une sous l'autre au téléphone ; aucun débordement horizontal. */
  .clavier-panneau {
    border: 1px solid var(--border);
    border-radius: 12px;
    background: var(--panel);
    overflow: hidden;
  }
  .clavier-panneau > summary {
    display: flex;
    align-items: center;
    min-height: 44px;
    padding: 0 10px;
    font-weight: 700;
    cursor: pointer;
    touch-action: manipulation;
    -webkit-tap-highlight-color: transparent;
  }
  .clavier-panneau[open] > summary {
    border-bottom: 1px solid var(--border);
  }
  .clavier-corps {
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 8px;
    min-width: 0;
  }
  .clavier-barre {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }
  .clavier-etiquette {
    font-size: 0.85rem;
    color: var(--text-dim);
  }
  #clavier-canal {
    min-height: 44px;
    min-width: 0;
    max-width: 100%;
    padding: 4px 8px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--panel-raised);
    color: var(--text);
    font: inherit;
    font-size: 0.9rem;
  }
  .clavier-aide { flex: 1 1 180px; }
  .clavier-avertissement { color: #ffcf7a; }
  .clavier-avertissement[hidden] { display: none; }
  .clavier-octaves {
    --touche-largeur: 48px;
    /* Cible tactile de 44 px ; le capuchon noir visible reste plus étroit. */
    --touche-noire-largeur: 44px;
    --touche-noire-visuel: 30px;
    --touche-hauteur: 150px;
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    min-width: 0;
    user-select: none;
    -webkit-user-select: none;
  }
  .octave {
    position: relative;
    display: flex;
    flex: 0 0 auto;
    width: calc(7 * var(--touche-largeur));
    height: var(--touche-hauteur);
  }
  .touche {
    font: inherit;
    cursor: pointer;
    padding: 0;
    touch-action: none;
    -webkit-tap-highlight-color: transparent;
  }
  .touche-blanche {
    flex: 1 1 0;
    min-width: var(--touche-largeur);
    height: 100%;
    display: flex;
    align-items: flex-end;
    justify-content: center;
    padding-bottom: 6px;
    border: 1px solid var(--border);
    border-radius: 0 0 6px 6px;
    background: #f7fafc;
    color: #10151c;
    font-size: 0.75rem;
    font-weight: 600;
  }
  .touche-noire {
    position: absolute;
    top: 0;
    z-index: 2;
    width: var(--touche-noire-largeur);
    height: 62%;
    padding: 0;
    border: 0;
    background: transparent;
    color: #f7fafc;
  }
  .touche-noire::before {
    content: "";
    position: absolute;
    top: 0;
    left: 50%;
    width: var(--touche-noire-visuel);
    height: 100%;
    transform: translateX(-50%);
    border: 1px solid #05070a;
    border-radius: 0 0 4px 4px;
    background: #10151c;
    box-shadow: 0 2px 3px rgba(0, 0, 0, 0.5);
  }
  .touche-blanche[aria-pressed="true"] {
    background: var(--accent);
    border-color: var(--accent-bright);
    color: var(--accent-ink);
  }
  .touche-noire[aria-pressed="true"]::before {
    background: var(--accent);
    border-color: var(--accent-bright);
  }
  .noire-position-1 { left: calc(var(--touche-largeur) - var(--touche-noire-largeur) / 2); }
  .noire-position-2 { left: calc(2 * var(--touche-largeur) - var(--touche-noire-largeur) / 2); }
  .noire-position-3 { left: calc(3 * var(--touche-largeur) - var(--touche-noire-largeur) / 2); }
  .noire-position-4 { left: calc(4 * var(--touche-largeur) - var(--touche-noire-largeur) / 2); }
  .noire-position-5 { left: calc(5 * var(--touche-largeur) - var(--touche-noire-largeur) / 2); }
  .noire-position-6 { left: calc(6 * var(--touche-largeur) - var(--touche-noire-largeur) / 2); }
  .stops-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
    gap: 8px;
    margin-top: 10px;
  }
  .stop, .link {
    min-height: 46px;
    padding: 6px 8px;
    border: 2px solid var(--border);
    border-radius: 10px;
    background: var(--panel-raised);
    color: var(--text);
    font: inherit;
    font-size: 0.85rem;
    font-weight: 600;
    line-height: 1.2;
    cursor: pointer;
    touch-action: manipulation;
  }
  .stop[data-state="on"], .link[data-state="on"] {
    border-color: var(--on);
    background: rgba(124, 240, 178, 0.15);
    color: var(--on);
  }
  .stop[data-state="off"], .link[data-state="off"] {
    border-color: var(--border);
    color: var(--text-dim);
  }
  .stop[data-state="unknown"], .link[data-state="unknown"] {
    border-style: dashed;
    color: var(--unknown);
  }
  /* Barre de commandes : combinaison, réverbération, panique. */
  .barre {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    align-items: center;
    margin: 4px 0 12px;
  }
  .combo {
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .reverb {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1 1 160px;
    font-size: 0.9rem;
    color: var(--text-dim);
  }
  /* Boutons de combinaisons dédiés : seulement sur grand écran. */
  .combo-btns {
    display: none;
    flex: 1 1 100%;
    grid-template-columns: repeat(16, 1fr);
    gap: 4px;
  }
  .combo-btn {
    min-height: 36px;
    font: inherit;
    font-size: 0.85rem;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--panel-raised);
    color: var(--text);
    cursor: pointer;
  }
  .combo-btn.actif {
    border-color: var(--accent);
    background: var(--accent);
    color: var(--bg);
    font-weight: 700;
  }
  @media (min-width: 900px) {
    .combo { display: none; }
    .combo-btns { display: grid; }
    .reverb { flex: 0 1 320px; }
    .barre .btn.panic { flex: 0 0 auto; min-height: 44px; margin-left: auto; padding: 0 24px; }
  }
  .combo input {
    width: 64px;
    text-align: center;
    font: inherit;
    font-size: 1rem;
    padding: 6px;
    border: 2px solid var(--border);
    border-radius: 8px;
    background: var(--panel-raised);
    color: var(--text);
  }
  .btn.small {
    min-height: 40px;
    font-size: 1rem;
    padding: 0 12px;
  }
  .btn.panic {
    flex: 1 1 100%;
    min-height: 56px;
    font-size: 1.2rem;
    border-color: #ff5a5a;
    background: #3a1212;
    color: #ff9a9a;
  }
  .note {
    font-size: 0.78rem;
    color: var(--text-dim);
    margin: 0;
  }
  .note.degrade {
    color: #ffcf7a;
  }

  @media (min-width: 640px) {
    body {
      align-items: center;
      padding: 32px;
    }

    main {
      gap: 24px;
      padding-bottom: 32px;
    }

    h1 {
      font-size: 1.9rem;
    }
  }

  /* Mise en page compacte, façon gestionnaire de fenêtres en mosaïque :
     espacements minimes, boutons qui remplissent leur case ; sur grand
     écran, l'onglet Orgue occupe exactement la hauteur de la fenêtre et
     les claviers s'étirent pour la remplir. */
  body { padding: 4px; }
  main { gap: 4px; padding: 0; }
  main:has(#panel-orgue:not([hidden])) { max-width: none; }
  .tabs { gap: 4px; }
  .tab { min-height: 36px; border-width: 1px; border-radius: 6px; }
  #panel-orgue:not([hidden]) { display: flex; flex-direction: column; gap: 4px; }
  .barre { gap: 4px; margin: 0; }
  .combo-btns { gap: 2px; }
  .combo-btn { min-height: 32px; border-radius: 4px; }
  .btn.small { min-height: 36px; }
  .note { font-size: 0.7rem; }
  .divisions { gap: 4px; }
  .division {
    display: flex;
    flex-direction: column;
    gap: 3px;
    padding: 3px;
    border-width: 1px;
    border-radius: 6px;
  }
  .division-nom { padding: 0 2px; font-size: 0.85rem; }
  .stops-grid {
    gap: 3px;
    grid-template-columns: repeat(auto-fill, minmax(100px, 1fr));
  }
  .stop, .link { min-height: 40px; padding: 2px 4px; border-width: 1px; border-radius: 4px; }
  .transposition { margin-top: 2px; gap: 4px; padding: 2px; }
  .transposition .btn.small { min-width: 44px; min-height: 44px; }
  .cancel-division { min-height: 30px; }

  @media (min-width: 900px) {
    body { padding: 4px; align-items: stretch; }
    main:has(#panel-orgue:not([hidden])) { height: calc(100dvh - 8px); }
    #panel-orgue:not([hidden]) { flex: 1; min-height: 0; }
    .divisions { flex: 1; min-height: 0; grid-auto-rows: 1fr; align-items: stretch; }
    .division { min-height: 0; }
    .stops-grid { flex: 1; min-height: 0; grid-auto-rows: 1fr; }
    .stop { min-height: 0; }
  }

  /* Page unique : volume général dans la barre, volume de chaque clavier
     dans son en-tête. Curseurs horizontaux (le style de base des curseurs
     est celui, pivoté, de l'ancien curseur vertical). */
  .barre input[type="range"],
  .division-tete input[type="range"] {
    position: static;
    transform: none;
    width: 100%;
    height: 36px;
  }
  .volume-general {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1 1 220px;
    min-width: 0;
  }
  .volume-general input[type="range"] { min-width: 0; }
  .volume-general .value {
    font-size: 1.1rem;
    min-width: 3.5em;
    text-align: right;
  }
  .volume-etiquette, .reverb { font-size: 0.85rem; color: var(--text-dim); }
  .barre .btn.mute,
  .barre .btn.panic { flex: 1 1 0; width: auto; min-height: 44px; font-size: 1rem; margin: 0; }
  .combo-btns { order: 10; }
  .division-tete {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .division-tete .division-nom { flex: 0 0 auto; }
  .division-tete .gain { flex: 1 1 auto; min-width: 60px; }

  @media (min-width: 900px) {
    .volume-general { flex: 1 1 260px; }
    .barre .btn.mute,
    .barre .btn.panic { flex: 0 0 auto; padding: 0 24px; margin: 0; }
  }

  /* Puce d'adaptation et bouton Qualité : la couleur double toujours un
     libellé, jamais l'information seule. */
  .lien-qualite { font-weight: 700; }
  .lien-qualite.charge-gris {
    background: var(--panel-raised);
    color: var(--text);
    border-color: var(--border);
  }
  .lien-qualite.charge-vert {
    background: var(--ok);
    color: #062016;
    border-color: var(--ok);
  }
  .lien-qualite.charge-orange {
    background: var(--warn);
    color: #2b1800;
    border-color: var(--warn);
  }
  .lien-qualite.charge-rouge {
    background: var(--off);
    color: #2b0505;
    border-color: var(--off);
  }
  .puce-bloc {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 4px;
    min-width: 0;
  }
  .puce-charge {
    display: inline-block;
    max-width: 100%;
    padding: 4px 12px;
    border: 1px solid var(--border);
    border-radius: 999px;
    font-weight: 700;
    font-size: 0.85rem;
    line-height: 1.25;
  }
  .puce-charge.charge-gris {
    background: var(--panel-raised);
    color: var(--text);
  }
  .puce-charge.charge-vert {
    background: var(--ok);
    color: #062016;
    border-color: var(--ok);
  }
  .puce-charge.charge-orange {
    background: var(--warn);
    color: #2b1800;
    border-color: var(--warn);
  }
  .puce-charge.charge-rouge {
    background: var(--off);
    color: #2b0505;
    border-color: var(--off);
  }

  /* Liens MIDI et Audio de la page principale : même hauteur que Panique,
     texte centré au lieu d'être collé en haut. */
  a.btn.small {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-height: 44px;
    padding: 0 16px;
    text-align: center;
    line-height: 1.1;
  }

  @media (prefers-reduced-motion: reduce) {
    *,
    *::before,
    *::after {
      transition: none !important;
      animation: none !important;
    }
  }
]]

return CSS