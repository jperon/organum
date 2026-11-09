-- Page des réglages de qualité : niveau, champs à chaud et paramètres audio.
-- Le contenu est construit par le script à partir de /api/orgue ; les
-- réglages sont envoyés par POST /api/orgue {qualite}.
h = require "html"
style = require "style"
modele = require "modele"

css = [[
  .qualite-page {
    width: 100%;
    max-width: 1200px;
    margin: 0 auto;
    padding: 8px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    min-width: 0;
  }
  .qualite-page .entete {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-wrap: wrap;
  }
  .qualite-page .entete a { color: inherit; }
  .qualite-page .entete h2 { margin: 0; font-size: 1rem; }

  /* Réglages de qualité : une rangée par réglage, libellé à gauche et
     commandes à droite dès que la largeur le permet. Aucune largeur
     minimale fixe : au téléphone les rangées s'empilent sans débordement. */
  .qualite {
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 8px;
    background: var(--panel);
    min-width: 0;
  }
  .qualite[hidden] { display: none; }
  .qualite-corps {
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-width: 0;
  }
  .qualite-ligne {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 6px;
    align-items: center;
    min-width: 0;
  }
  @media (min-width: 640px) {
    .qualite-ligne {
      grid-template-columns: minmax(120px, 0.3fr) minmax(0, 1fr);
      gap: 6px 16px;
    }
    /* Rangée de commandes sans libellé (deux bascules côte à côte). */
    .qualite-ligne-pleine .qualite-commandes { grid-column: 1 / -1; }
  }
  .qualite-libelle {
    font-size: 0.85rem;
    font-weight: 600;
    color: var(--text-dim);
    line-height: 1.2;
    min-width: 0;
  }
  .qualite-commandes {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 6px;
    min-width: 0;
  }
  /* Boutons segmentés : une valeur par bouton, l'actif en accent. */
  .qualite-segments {
    display: flex;
    flex-wrap: wrap;
    align-items: stretch;
    gap: 6px;
    min-width: 0;
    flex: 1 1 auto;
  }
  .qualite-segment,
  .qualite-bascule {
    min-height: 44px;
    padding: 4px 12px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--panel-raised);
    color: var(--text);
    font: inherit;
    font-size: 0.88rem;
    font-weight: 600;
    line-height: 1.15;
    cursor: pointer;
    touch-action: manipulation;
    -webkit-tap-highlight-color: var(--transparent);
  }
  .qualite-segment {
    position: relative;
    flex: 1 1 auto;
    min-width: 2.6em;
    text-align: center;
  }
  /* Demande de tempérament en cours : contour accentué et « … » en coin,
     sans modifier le libellé ni la largeur du bouton. */
  .qualite-segment[aria-busy="true"] {
    border-color: var(--accent);
    outline: 2px solid var(--accent);
    outline-offset: -2px;
    cursor: progress;
  }
  .qualite-segment[aria-busy="true"]::after {
    content: "…";
    position: absolute;
    top: 1px;
    right: 4px;
    font-size: 0.8em;
    line-height: 1;
    color: var(--accent);
    pointer-events: none;
  }
  .qualite-bascule {
    flex: 1 1 12em;
    text-align: left;
  }
  .qualite-segment[aria-pressed="true"],
  .qualite-bascule[aria-pressed="true"] {
    border-color: var(--accent);
    background: var(--accent);
    color: var(--accent-ink);
  }
  .qualite-segment:hover:not(:disabled),
  .qualite-bascule:hover:not(:disabled) {
    border-color: var(--accent);
  }
  .qualite input[type="text"] {
    width: 100%;
    min-height: 44px;
    min-width: 0;
    box-sizing: border-box;
    padding: 8px 10px;
    border: 1px solid var(--border);
    border-radius: 8px;
    background: var(--panel-raised);
    color: var(--text);
    font: inherit;
    font-size: 0.9rem;
  }
  /* Une rangée par sous-réseau : sous-réseau, commentaire facultatif,
     bouton de retrait. Empilée sous 640 px, sans débordement à 420 px. */
  .reseaux-entrees {
    display: flex;
    flex-direction: column;
    gap: 6px;
    min-width: 0;
  }
  .reseau-entree {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 6px;
    min-width: 0;
  }
  @media (min-width: 640px) {
    .reseau-entree {
      grid-template-columns: minmax(0, 1.3fr) minmax(0, 1fr) auto;
      align-items: center;
    }
  }
  .reseau-retirer {
    flex: 0 0 auto;
    min-width: 44px;
    text-align: center;
  }
  /* Le curseur occupe toute sa zone tactile : 48 px de haut, ce qui contient
     le pouce de 48 px sans qu'il déborde sur le libellé au-dessus. */
  .qualite input[type="range"] {
    position: static;
    transform: none;
    width: 100%;
    min-width: 0;
    height: 48px;
    padding: 0;
    margin: 0;
  }
  .qualite input#reverb { height: 48px; }
  /* Polyphonie : curseur et valeur sur la même ligne. */
  .qualite-commandes-curseur { flex-wrap: nowrap; }
  .qualite-commandes-curseur input[type="range"] { flex: 1 1 auto; }
  .qualite output {
    flex: 0 0 auto;
    min-width: 4.2em;
    text-align: right;
    font-variant-numeric: tabular-nums;
    color: var(--text);
  }
  /* Notes (valeur imposée, écart avec la valeur effective) : leur propre
     ligne, sous le libellé et les commandes. */
  .qualite-note {
    display: block;
    flex-basis: 100%;
    font-size: 0.75rem;
    color: var(--text-dim);
    font-style: italic;
    margin: 0;
  }
  .qualite-note[hidden] { display: none; }
  /* Statut de la rangée Tempérament : sa place est réservée en permanence,
     pour qu'apparaître « Application de… » ne décale aucune ligne. */
  .qualite-note.qualite-statut {
    display: block;
    min-height: 1em;
    visibility: hidden;
  }
  .qualite-note.qualite-statut:not([hidden]) { visibility: visible; }
  .qualite-repli,
  .qualite-erreur,
  .qualite-calibration,
  .qualite-message,
  .qualite-indisponible {
    margin: 6px 0 0;
    font-size: 0.78rem;
  }
  .qualite button:focus-visible,
  .qualite input:focus-visible {
    outline: 3px solid var(--focus);
    outline-offset: 2px;
  }
  .qualite button:disabled,
  .qualite input:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }
]]

niveaux_qualite = {"auto", "0", "1", "2", "3"}
niveaux_segments = {{"auto", "Auto"}, {"0", "0"}, {"1", "1"}, {"2", "2"}, {"3", "3"}}

duree_periode = (periode, taux = 48000) ->
  texte = string.format "%.1f", tonumber(periode) * 1000 / taux
  texte\gsub "%.", ","

periodes = {"128", "256", "512", "768", "1024", "1536", "2048"}
taux_valides = {"44100", "48000"}

libelle_periode = (valeur) ->
  "#{valeur} (#{duree_periode valeur} ms)"

bouton_segment = (valeur, nom, actif, aria) ->
  attrs =
    type: "button"
    class: "qualite-segment"
    ["data-valeur"]: valeur
    ["aria-pressed"]: actif and "true" or "false"
  attrs["aria-label"] = aria if aria
  h.button attrs, nom

script = [[
(function () {
  'use strict';

  var section = document.getElementById('qualite');
  if (!section) { return; }
  var groupeNiveau = document.getElementById('qualite-niveau');
  var boutonsNiveau = groupeNiveau ?
    Array.prototype.slice.call(groupeNiveau.querySelectorAll('.qualite-segment')) : [];
  var basculeBruit = document.getElementById('qualite-bruit');
  var basculeInstabilite = document.getElementById('qualite-instabilite');
  var groupeSpatialisation = document.getElementById('qualite-spatialisation');
  var boutonsSpatialisation = groupeSpatialisation ?
    Array.prototype.slice.call(groupeSpatialisation.querySelectorAll('.qualite-segment')) : [];
  var curseurPolyphonie = document.getElementById('qualite-polyphonie');
  var valeurPolyphonie = document.getElementById('qualite-polyphonie-valeur');
  var basculeTete = document.getElementById('qualite-tete');
  var noteTeteImpose = document.getElementById('qualite-tete-impose');
  var noteTeteEtat = document.getElementById('qualite-tete-etat');
  var groupePeriode = document.getElementById('qualite-periode');
  var boutonsPeriode = groupePeriode ?
    Array.prototype.slice.call(groupePeriode.querySelectorAll('.qualite-segment')) : [];
  var notePeriode = document.getElementById('qualite-periode-note');
  var groupeTaux = document.getElementById('qualite-taux');
  var boutonsTaux = groupeTaux ?
    Array.prototype.slice.call(groupeTaux.querySelectorAll('.qualite-segment')) : [];
  var noteTaux = document.getElementById('qualite-taux-note');
  var groupeTemperament = document.getElementById('qualite-temperament');
  var boutonsTemperament = groupeTemperament ?
    Array.prototype.slice.call(groupeTemperament.querySelectorAll('.qualite-segment')) : [];
  var noteTemperament = document.getElementById('qualite-temperament-note');
  var champPeripherique = document.getElementById('qualite-peripherique');
  var notePeripherique = document.getElementById('qualite-peripherique-note');
  var basculeLimiteur = document.getElementById('qualite-limiteur');
  var noteLimiteur = document.getElementById('qualite-limiteur-note');
  var noteNiveau = document.getElementById('qualite-niveau-note');
  var curseurReverb = document.getElementById('reverb');
  var reverbManip = false;
  var ligneRepli = document.getElementById('qualite-repli');
  var ligneErreur = document.getElementById('qualite-audio-erreur');
  var ligneCalibration = document.getElementById('qualite-calibration');
  var message = document.getElementById('qualite-message');
  var indisponible = document.getElementById('qualite-indisponible');
  var lignePlateforme = document.getElementById('qualite-plateforme');
  var puce = document.getElementById('qualite-puce');
  var puceDetail = document.getElementById('qualite-puce-detail');
  var enAttente = 0;
  var polyActif = false;
  var polyEnvoye = null;
  var echecEnvoi = '';
  // Tempérament : la cible en cours est publiée par le serveur
  // (qualite.temperament_cible), donc partagée par toutes les interfaces.
  // Seul un retour immédiat au clic est gardé localement, le temps que
  // l'état serveur arrive. `temperamentService` est la dernière valeur
  // effective connue, qui reste marquée comme active.
  var temperamentCibleLocale = null;
  var temperamentEnvoiFini = false;
  var temperamentCibleAffichee = null;
  var temperamentService = null;
  var temperamentEchec = '';
  var temperamentErreurServeur = '';

  function note(el, texte) {
    if (!el) { return; }
    el.textContent = texte || '';
    el.hidden = !texte;
  }

  function nombre(valeur) {
    var n = Number(valeur);
    return isFinite(n) ? n : null;
  }

  function actif(el) {
    return !!el && el.getAttribute('aria-pressed') === 'true';
  }

  function poser(el, etat) {
    if (el) { el.setAttribute('aria-pressed', etat ? 'true' : 'false'); }
  }

  function nomTemperament(n) {
    var nom = null;
    boutonsTemperament.forEach(function (b) {
      if (nombre(b.getAttribute('data-valeur')) === n) { nom = b.textContent; }
    });
    return nom === null ? String(n) : nom;
  }

  // Applique l'état de la rangée Tempérament : la valeur effective reste
  // marquée active (aria-pressed), la cible publiée par le serveur porte
  // aria-busy et un message de statut. Le retour local du clic n'est utilisé
  // que tant que l'état serveur ne l'a pas repris.
  function majTemperament(q) {
    if (q && typeof q === 'object') {
      if (typeof q.temperament === 'number') { temperamentService = q.temperament; }
      temperamentErreurServeur = typeof q.temperament_erreur === 'string' ? q.temperament_erreur : '';
      if (temperamentCibleLocale !== null) {
        var cibleServeur = (typeof q.temperament_cible === 'number' && q.temperament_cible >= 0)
          ? q.temperament_cible : null;
        if (cibleServeur === temperamentCibleLocale) {
          // Le serveur porte maintenant la cible : le local devient inutile.
          temperamentCibleLocale = null;
          temperamentEnvoiFini = false;
        } else if (temperamentEnvoiFini) {
          // Envoi terminé sans que le serveur reprenne cette cible : soit le
          // calcul est déjà fini, soit une demande plus récente l'emporte.
          temperamentCibleLocale = null;
          temperamentEnvoiFini = false;
        }
      }
    }
    var cible = temperamentCibleLocale;
    if (cible === null && q && typeof q === 'object' &&
        typeof q.temperament_cible === 'number' && q.temperament_cible >= 0) {
      cible = q.temperament_cible;
    }
    temperamentCibleAffichee = cible;
    boutonsTemperament.forEach(function (b) {
      var n = nombre(b.getAttribute('data-valeur'));
      poser(b, temperamentService !== null && n === temperamentService);
      b.setAttribute('aria-busy', cible !== null && n === cible ? 'true' : 'false');
    });
    if (noteTemperament) {
      var texte = '';
      if (cible !== null) {
        texte = 'Application de ' + nomTemperament(cible) + '…';
      } else if (temperamentEchec) {
        texte = 'Tempérament : ' + temperamentEchec;
      } else if (temperamentErreurServeur) {
        texte = 'Tempérament : ' + temperamentErreurServeur;
      }
      note(noteTemperament, texte);
    }
  }

  // Remplit la partie colorée du curseur jusqu'à sa valeur : le style de
  // base pose --fill à 50 %, il faut donc le recalculer à chaque changement.
  function majRemplissage(el) {
    if (!el) { return; }
    var min = nombre(el.min);
    var max = nombre(el.max);
    var valeur = nombre(el.value);
    if (min === null || max === null || valeur === null || max <= min) { return; }
    var pourcent = (valeur - min) / (max - min) * 100;
    if (pourcent < 0) { pourcent = 0; }
    if (pourcent > 100) { pourcent = 100; }
    el.style.setProperty('--fill', pourcent + '%');
  }

  function surGroupe(boutons, action) {
    boutons.forEach(function (b) {
      b.addEventListener('click', function () {
        if (b.disabled) { return; }
        action(b.getAttribute('data-valeur'), b);
      });
    });
  }

  function textePeriode(periode, taux) {
    var p = nombre(periode);
    var t = nombre(taux);
    if (p === null) { return String(periode); }
    if (t === null || t <= 0) { t = 48000; }
    return p + ' (' + (p * 1000 / t).toFixed(1).replace('.', ',') + ' ms)';
  }

  function textePolyphonie(n) {
    return n === 0 ? 'Illimitée' : n + ' voix';
  }

  function choixNiveau(q) {
    if (q.auto === true) { return 'auto'; }
    if (typeof q.niveau === 'number' && q.niveau >= 0 && q.niveau <= 3) {
      return String(q.niveau);
    }
    return '-1';
  }

  function texteCalibration(c) {
    if (!c || typeof c !== 'object') { return ''; }
    var parties = [];
    var niveau = nombre(c.niveau);
    parties.push(niveau === null ? 'Calibration automatique' : 'Calibration automatique : niveau ' + niveau);
    var estimation = null;
    if (Object.prototype.toString.call(c.estimation_ms) === '[object Array]' &&
        niveau !== null && typeof c.estimation_ms[niveau] === 'number') {
      estimation = c.estimation_ms[niveau];
    } else if (typeof c.estimation_ms === 'number') {
      estimation = c.estimation_ms;
    }
    if (estimation !== null) { parties.push('estimation ' + estimation.toFixed(1) + ' ms'); }
    if (typeof c.echeance_ms === 'number') { parties.push('échéance ' + c.echeance_ms.toFixed(1) + ' ms'); }
    if (typeof c.voix_ref === 'number') { parties.push(c.voix_ref + ' voix'); }
    if (typeof c.tete_reverb === 'boolean') {
      parties.push(c.tete_reverb ? 'tête zéro latence' : 'sans tête');
    }
    return parties.join(' · ');
  }

  // Le message de la page : « Application… » tant qu'une reconfiguration
  // audio est en cours (application_audio, distinct du tempérament), puis un
  // éventuel échec d'envoi. Un échec audio s'affiche dans sa propre ligne.
  function majMessage(q) {
    if (!message) { return; }
    var texte = '';
    if (q && typeof q === 'object' && q.application_audio === true) {
      texte = 'Application…';
    } else if (echecEnvoi) {
      texte = echecEnvoi;
    }
    message.textContent = texte;
    message.hidden = !texte;
  }

  // Puce d'adaptation : le niveau vient du C ; ce script ne fait que
  // traduire la classe et le libellé. Pendant une reconfiguration audio, on
  // ne réévalue pas la puce.
  function majPuce(q) {
    if (!puce) { return; }
    if (q && typeof q === 'object' && q.application_audio === true) { return; }
    var niveau = q && typeof q.charge_niveau === 'number' ? q.charge_niveau : 0;
    if (niveau < 0 || niveau > 3) { niveau = 0; }
    var classe = section.getAttribute('data-charge-classe-' + niveau) || 'charge-gris';
    var libelle = section.getAttribute('data-charge-libelle-' + niveau) ||
      'Pas encore évalué — jouez quelques accords';
    puce.className = 'puce-charge ' + classe;
    puce.textContent = libelle;
    if (puceDetail) {
      var pointe = q && typeof q.charge_pointe === 'number' ? q.charge_pointe : 0;
      var mesure = q && q.charge_evaluee === true;
      var xrunsRecents = q && typeof q.xruns_recents === 'number' ? q.xruns_recents : 0;
      var xruns = q && typeof q.xruns === 'number' ? q.xruns : 0;
      puceDetail.textContent = (mesure || pointe > 0 ? 'Pointe : ' + pointe + ' %' : 'Pointe : —') +
        ' · Xruns récents : ' + xrunsRecents + ' · total : ' + xruns;
    }
  }

  function desactiver(etat) {
    var tous = boutonsNiveau.concat(boutonsSpatialisation, boutonsPeriode, boutonsTaux,
      boutonsTemperament,
      [basculeBruit, basculeInstabilite, basculeLimiteur, basculeTete,
       curseurPolyphonie, champPeripherique]);
    tous.forEach(function (el) {
      if (el) { el.disabled = etat; }
    });
  }

  function majPlateforme(q) {
    if (!lignePlateforme) { return; }
    // Message calculé côté serveur par la règle pure degradation.etat_audio :
    // backend absent, assistant absent, ou aucune sortie ne disent pas la
    // même chose. Chaîne vide = audio opérationnel, rien à afficher.
    var texte = q && typeof q.audio_message === 'string' ? q.audio_message : '';
    lignePlateforme.textContent = texte;
    lignePlateforme.hidden = !texte;
  }

  function maj(q, reverb) {
    majPlateforme(q);
    if (enAttente > 0) { majMessage(q); majPuce(q); return; }
    // Réverbération : valeur publiée par le moteur (0..1), curseur 0..127.
    // Une association MIDI de cible « reverb » la modifie aussi : ne pas
    // écraser le curseur pendant un glissement.
    if (curseurReverb && !reverbManip && typeof reverb === 'number' && isFinite(reverb)) {
      var vr = Math.round(reverb * 127);
      if (vr < 0) { vr = 0; }
      if (vr > 127) { vr = 127; }
      curseurReverb.value = String(vr);
      majRemplissage(curseurReverb);
    }
    if (!q || typeof q !== 'object') {
      // Serveur sans réglages de qualité (ancienne version) : la section
      // reste visible mais ses contrôles sont inertes, avec une explication.
      section.hidden = false;
      desactiver(true);
      if (indisponible) { indisponible.hidden = false; }
      if (noteTeteImpose) { noteTeteImpose.hidden = true; }
      if (ligneCalibration) { ligneCalibration.hidden = true; }
      majMessage(q);
      majPuce(q);
      return;
    }
    section.hidden = false;
    desactiver(false);
    if (indisponible) { indisponible.hidden = true; }
    var choix = choixNiveau(q);
    boutonsNiveau.forEach(function (b) {
      poser(b, b.getAttribute('data-valeur') === choix);
    });
    note(noteNiveau, choix === '-1' ? 'Personnalisé' : '');
    poser(basculeBruit, q.bruit_attaque === true);
    poser(basculeInstabilite, q.instabilite === true);
    boutonsSpatialisation.forEach(function (b) {
      poser(b, b.getAttribute('data-valeur') === String(q.spatialisation));
    });
    if (!polyActif && typeof q.polyphonie_max === 'number') {
      polyEnvoye = null;
      if (curseurPolyphonie) {
        curseurPolyphonie.value = String(q.polyphonie_max);
        majRemplissage(curseurPolyphonie);
      }
      if (valeurPolyphonie) { valeurPolyphonie.textContent = textePolyphonie(q.polyphonie_max); }
    }
    // Tête de réverbération : le contrôle montre la valeur ENREGISTRÉE.
    if (typeof q.tete_reverb_prochain === 'boolean') {
      poser(basculeTete, q.tete_reverb_prochain);
    }
    if (basculeTete) { basculeTete.disabled = q.tete_reverb_impose === true; }
    if (noteTeteImpose) { noteTeteImpose.hidden = q.tete_reverb_impose !== true; }
    if (noteTeteEtat) {
      var etatTete = '';
      if (q.tete_reverb_impose !== true &&
          typeof q.tete_reverb === 'boolean' &&
          typeof q.tete_reverb_prochain === 'boolean' &&
          q.tete_reverb !== q.tete_reverb_prochain) {
        etatTete = q.tete_reverb ? 'en cours : active' : 'en cours : coupée';
      }
      note(noteTeteEtat, etatTete);
    }

    majTemperament(q);

    var tauxProchain = nombre(q.taux_prochain);
    if (tauxProchain === null) { tauxProchain = 48000; }
    var periodeProchain = nombre(q.periode_prochain);
    if (periodeProchain === null) { periodeProchain = 512; }
    boutonsPeriode.forEach(function (b) {
      var p = nombre(b.getAttribute('data-valeur'));
      b.textContent = p === null ? b.textContent : String(p);
      b.setAttribute('aria-label', textePeriode(p === null ? b.textContent : p, tauxProchain));
      poser(b, p === periodeProchain);
    });
    if (notePeriode) {
      notePeriode.hidden = false;
      var etatPeriode = '';
      if (q.periode_impose === true) { etatPeriode = 'imposée par ORGANUM_PERIODE'; }
      else if (nombre(q.periode) !== null && q.periode !== q.periode_prochain) {
        etatPeriode = 'en cours : ' + textePeriode(q.periode, q.taux);
      }
      note(notePeriode, etatPeriode);
    }
    boutonsPeriode.forEach(function (b) { b.disabled = q.periode_impose === true; });
    boutonsTaux.forEach(function (b) {
      poser(b, nombre(b.getAttribute('data-valeur')) === tauxProchain);
    });
    if (noteTaux) {
      var etatTaux = '';
      if (q.taux_impose === true) { etatTaux = 'imposé par ORGANUM_TAUX'; }
      else if (nombre(q.taux) !== null && q.taux !== q.taux_prochain) {
        etatTaux = 'en cours : ' + q.taux + ' Hz';
      }
      note(noteTaux, etatTaux);
    }
    boutonsTaux.forEach(function (b) { b.disabled = q.taux_impose === true; });
    if (champPeripherique) {
      champPeripherique.disabled = q.peripherique_impose === true;
      // Ne jamais écraser la saisie en cours par la relecture périodique.
      if (document.activeElement !== champPeripherique) {
        champPeripherique.value = typeof q.peripherique_prochain === 'string' ? q.peripherique_prochain : '';
      }
      var etatPeripherique = '';
      if (q.peripherique_impose === true) { etatPeripherique = 'imposé par ORGANUM_PERIPHERIQUE'; }
      else if (typeof q.peripherique === 'string' && q.peripherique !== q.peripherique_prochain) {
        etatPeripherique = 'en cours : ' + (q.peripherique || 'périphérique par défaut');
      }
      note(notePeripherique, etatPeripherique);
    }
    poser(basculeLimiteur, q.limiteur_prochain === true);
    if (basculeLimiteur) { basculeLimiteur.disabled = q.limiteur_impose === true; }
    if (noteLimiteur) {
      var etatLimiteur = '';
      if (q.limiteur_impose === true) { etatLimiteur = 'imposé par ORGANUM_LIMITEUR'; }
      else if (typeof q.limiteur === 'boolean' &&
               typeof q.limiteur_prochain === 'boolean' &&
               q.limiteur !== q.limiteur_prochain) {
        etatLimiteur = q.limiteur ? 'en cours : actif' : 'en cours : coupé';
      }
      note(noteLimiteur, etatLimiteur);
    }
    if (ligneRepli) {
      var repli = typeof q.audio_repli === 'string' ? q.audio_repli : '';
      ligneRepli.textContent = repli ? ('Repli audio : ' + repli) : '';
      ligneRepli.hidden = !repli;
    }
    if (ligneErreur) {
      var erreur = typeof q.audio_erreur === 'string' ? q.audio_erreur : '';
      ligneErreur.textContent = erreur ? ('Reconfiguration audio impossible : ' + erreur) : '';
      ligneErreur.hidden = !erreur;
    }
    if (ligneCalibration) {
      var texte = texteCalibration(q.calibration);
      ligneCalibration.textContent = texte;
      ligneCalibration.hidden = !texte;
    }
    majMessage(q);
    majPuce(q);
  }

  function envoyer(payload) {
    enAttente += 1;
    echecEnvoi = '';
    return fetch('/api/orgue', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ qualite: payload })
    })
      .then(function (r) {
        return r.json().then(
          function (data) {
            if (!r.ok) { throw new Error((data && data.error) || ('HTTP ' + r.status)); }
            return data;
          },
          function () {
            if (!r.ok) { throw new Error('HTTP ' + r.status); }
            return {};
          }
        );
      })
      .then(function (data) {
        enAttente -= 1;
        maj(data);
      })
      .catch(function (err) {
        enAttente -= 1;
        var detail = err && err.message ? err.message : 'erreur réseau';
        echecEnvoi = 'Audio : échec de l’enregistrement (' + detail + ').';
        majMessage(null);
      });
  }

  function envoyer_temperament(n) {
    enAttente += 1;
    echecEnvoi = '';
    return fetch('/api/orgue', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ temperament: n })
    })
      .then(function (r) {
        return r.json().then(
          function (data) {
            if (!r.ok) { throw new Error((data && data.error) || ('HTTP ' + r.status)); }
            return data;
          },
          function () {
            if (!r.ok) { throw new Error('HTTP ' + r.status); }
            return {};
          }
        );
      })
      .then(function () {
        // La réponse de POST temperament est {ok:true} : la relire comme un
        // état complet effacerait la sélection. La boucle d'état publiera la
        // cible partagée puis la valeur effective. À partir d'ici, l'état
        // serveur fait foi pour cette demande.
        enAttente -= 1;
        if (temperamentCibleLocale === n) { temperamentEnvoiFini = true; }
      })
      .catch(function (err) {
        enAttente -= 1;
        if (temperamentCibleLocale !== n) { return; }
        var detail = err && err.message ? err.message : 'erreur réseau';
        temperamentCibleLocale = null;
        temperamentEnvoiFini = false;
        temperamentEchec = 'échec de l’enregistrement (' + detail + ')';
        majTemperament(null);
      });
  }

  surGroupe(boutonsTemperament, function (valeur) {
    var n = nombre(valeur);
    if (n === null || n < 0) { return; }
    n = Math.round(n);
    // Dernière cible gagnante, mais sans renvoyer une demande identique :
    // ni la cible déjà en cours (locale ou publiée par le serveur), ni le
    // tempérament déjà en service.
    if (n === temperamentCibleAffichee) { return; }
    if (temperamentCibleAffichee === null && n === temperamentService) { return; }
    temperamentCibleLocale = n;
    temperamentEnvoiFini = false;
    temperamentEchec = '';
    temperamentErreurServeur = '';
    majTemperament(null);
    envoyer_temperament(n);
  });

  surGroupe(boutonsNiveau, function (valeur) {
    boutonsNiveau.forEach(function (b) {
      poser(b, b.getAttribute('data-valeur') === valeur);
    });
    if (valeur === 'auto') { envoyer({ auto: true }); return; }
    var n = nombre(valeur);
    if (n !== null && n >= 0 && n <= 3) { envoyer({ niveau: Math.round(n) }); }
  });
  if (basculeBruit) {
    basculeBruit.addEventListener('click', function () {
      var nouveau = !actif(basculeBruit);
      poser(basculeBruit, nouveau);
      envoyer({ bruit_attaque: nouveau });
    });
  }
  if (basculeInstabilite) {
    basculeInstabilite.addEventListener('click', function () {
      var nouveau = !actif(basculeInstabilite);
      poser(basculeInstabilite, nouveau);
      envoyer({ instabilite: nouveau });
    });
  }
  surGroupe(boutonsSpatialisation, function (valeur) {
    boutonsSpatialisation.forEach(function (b) {
      poser(b, b.getAttribute('data-valeur') === valeur);
    });
    var n = nombre(valeur);
    if (n !== null && n >= 0 && n <= 2) { envoyer({ spatialisation: Math.round(n) }); }
  });
  if (curseurPolyphonie) {
    curseurPolyphonie.addEventListener('input', function () {
      polyActif = true;
      majRemplissage(curseurPolyphonie);
      var n = nombre(curseurPolyphonie.value);
      if (n !== null && valeurPolyphonie) { valeurPolyphonie.textContent = textePolyphonie(n); }
    });
    var finPolyphonie = function () {
      polyActif = false;
      var n = nombre(curseurPolyphonie.value);
      if (n === null) { return; }
      n = Math.round(n);
      if (n < 0) { n = 0; }
      if (n > 512) { n = 512; }
      if (n === polyEnvoye) { return; }
      polyEnvoye = n;
      envoyer({ polyphonie_max: n });
    };
    curseurPolyphonie.addEventListener('change', finPolyphonie);
    curseurPolyphonie.addEventListener('blur', finPolyphonie);
  }
  if (basculeTete) {
    basculeTete.addEventListener('click', function () {
      var nouveau = !actif(basculeTete);
      poser(basculeTete, nouveau);
      envoyer({ tete_reverb: nouveau });
    });
  }
  surGroupe(boutonsPeriode, function (valeur) {
    boutonsPeriode.forEach(function (b) {
      poser(b, b.getAttribute('data-valeur') === valeur);
    });
    var n = nombre(valeur);
    if (n !== null) { envoyer({ periode: n }); }
  });
  surGroupe(boutonsTaux, function (valeur) {
    boutonsTaux.forEach(function (b) {
      poser(b, b.getAttribute('data-valeur') === valeur);
    });
    var n = nombre(valeur);
    if (n !== null) { envoyer({ taux: n }); }
  });
  if (champPeripherique) {
    champPeripherique.addEventListener('change', function () {
      envoyer({ peripherique: champPeripherique.value });
    });
  }
  if (basculeLimiteur) {
    basculeLimiteur.addEventListener('click', function () {
      var nouveau = !actif(basculeLimiteur);
      poser(basculeLimiteur, nouveau);
      envoyer({ limiteur: nouveau });
    });
  }
  if (curseurReverb) {
    curseurReverb.addEventListener('pointerdown', function () { reverbManip = true; });
    curseurReverb.addEventListener('input', function () {
      reverbManip = true;
      majRemplissage(curseurReverb);
    });
    var envoyerReverb = function () {
      reverbManip = false;
      var v = nombre(curseurReverb.value);
      if (v === null) { return; }
      v = Math.round(v);
      if (v < 0) { v = 0; }
      if (v > 127) { v = 127; }
      fetch('/api/orgue', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ reverb: v })
      }).catch(function () {
        echecEnvoi = 'Audio : échec de l’enregistrement de la réverbération.';
        majMessage(null);
      });
    };
    curseurReverb.addEventListener('change', envoyerReverb);
    curseurReverb.addEventListener('blur', envoyerReverb);
  }

  // Remplissage initial, avant la première réponse du serveur.
  majRemplissage(curseurReverb);
  majRemplissage(curseurPolyphonie);

  // --- Boucle d'état propre à cette page ------------------------------
  // GET /api/orgue puis attente longue /api/orgue/attendre, comme la page
  // principale ; à la perte de connexion, on réessaie après 2 s.
  var device = { instance: null, seq: null, token: 0 };

  function appliquerEtat(data) {
    if (!data || typeof data !== 'object') { return; }
    maj(data.qualite, data.reverb);
  }

  function attendre(instance, seq, token) {
    if (token !== device.token || document.visibilityState === 'hidden') { return; }
    var url = '/api/orgue/attendre?instance=' + encodeURIComponent(instance) +
      '&seq=' + encodeURIComponent(String(seq));
    fetch(url, { cache: 'no-store', headers: { Accept: 'application/json' } })
      .then(function (r) {
        if (r.status === 204) { return null; }
        if (!r.ok) { throw new Error('HTTP ' + r.status); }
        return r.json();
      })
      .then(function (data) {
        if (token !== device.token || document.visibilityState === 'hidden') { return; }
        if (data === null) {
          attendre(instance, seq, token);
          return;
        }
        appliquerEtat(data);
        if (typeof data.instance === 'string' && typeof data.seq === 'number') {
          device.instance = data.instance;
          device.seq = data.seq;
          attendre(data.instance, data.seq, token);
        } else {
          chargerInitial(token);
        }
      })
      .catch(function () {
        if (token !== device.token || document.visibilityState === 'hidden') { return; }
        window.setTimeout(function () {
          if (token === device.token && document.visibilityState !== 'hidden') {
            attendre(instance, seq, token);
          }
        }, 2000);
      });
  }

  function chargerInitial(token) {
    fetch('/api/orgue', { cache: 'no-store', headers: { Accept: 'application/json' } })
      .then(function (r) {
        if (!r.ok) { throw new Error('HTTP ' + r.status); }
        return r.json();
      })
      .then(function (data) {
        if (token !== device.token || document.visibilityState === 'hidden') { return; }
        appliquerEtat(data);
        if (typeof data.instance === 'string' && typeof data.seq === 'number') {
          device.instance = data.instance;
          device.seq = data.seq;
          attendre(data.instance, data.seq, token);
        } else {
          window.setTimeout(function () {
            if (token === device.token) { chargerInitial(token); }
          }, 2000);
        }
      })
      .catch(function () {
        if (token !== device.token || document.visibilityState === 'hidden') { return; }
        window.setTimeout(function () {
          if (token === device.token && document.visibilityState !== 'hidden') {
            chargerInitial(token);
          }
        }, 2000);
      });
  }

  function demarrer() {
    if (document.visibilityState === 'hidden') { return; }
    device.token += 1;
    chargerInitial(device.token);
  }

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) { demarrer(); }
    else { device.token += 1; }
  });

  // Les pourcentages sont publiés sans changer seq : le panneau ouvert les
  // relit au plus une fois toutes les 2 s. Fermé ou caché, aucune requête.
  window.setInterval(function () {
    if (document.visibilityState === 'hidden') { return; }
    fetch('/api/orgue', { cache: 'no-store', headers: { Accept: 'application/json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) { if (data) { appliquerEtat(data); } })
      .catch(function () {});
  }, 2000);

  demarrer();

  // --- Authentification facultative --------------------------------------
  // Le mot de passe n'est jamais relu : le serveur ne renvoie que l'état.
  // Sur HTTP, il est envoyé en clair ; le calcul de HA1 côté navigateur
  // exigerait crypto.subtle, indisponible hors HTTPS.
  var sectionAuth = document.getElementById('authentification');
  var authEtat = document.getElementById('auth-etat');
  var authUtilisateur = document.getElementById('auth-utilisateur');
  var authMotDePasse = document.getElementById('auth-mot-de-passe');
  var authEnregistrer = document.getElementById('auth-enregistrer');
  var authRetirer = document.getElementById('auth-retirer');
  var authNote = document.getElementById('auth-note');
  var authEnCours = false;

  function majAuth(a) {
    if (!sectionAuth || !a || typeof a !== 'object') { return; }
    if (authUtilisateur && document.activeElement !== authUtilisateur &&
        typeof a.utilisateur === 'string') {
      authUtilisateur.value = a.utilisateur;
    }
    if (authEtat) {
      if (a.active === true) {
        authEtat.textContent = 'Activée pour « ' + (a.utilisateur || '') + ' »';
      } else {
        authEtat.textContent = 'Désactivée';
      }
    }
    var enCours = authEnCours;
    if (authUtilisateur) { authUtilisateur.disabled = enCours; }
    if (authMotDePasse) { authMotDePasse.disabled = enCours; }
    if (authEnregistrer) { authEnregistrer.disabled = enCours; }
    if (authRetirer) {
      authRetirer.disabled = enCours;
      authRetirer.hidden = a.active !== true;
    }
    if (authNote) {
      if (a.erreur) {
        authNote.textContent = 'Fichier d’authentification invalide : ' + a.erreur +
          ' — accès non local refusé (503).';
        authNote.hidden = false;
      } else {
        authNote.textContent = '';
        authNote.hidden = true;
      }
    }
  }

  function chargerAuth() {
    fetch('/api/authentification', { cache: 'no-store', headers: { Accept: 'application/json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (a) { if (a) { majAuth(a); } })
      .catch(function () {});
  }

  function envoyerAuth(payload) {
    if (authEnCours) { return; }
    authEnCours = true;
    fetch('/api/authentification', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(payload)
    })
      .then(function (r) {
        return r.json().then(
          function (data) {
            if (!r.ok) { throw new Error((data && data.error) || ('HTTP ' + r.status)); }
            return data;
          },
          function () {
            if (!r.ok) { throw new Error('HTTP ' + r.status); }
            return {};
          }
        );
      })
      .then(function (data) {
        authEnCours = false;
        if (authMotDePasse) { authMotDePasse.value = ''; }
        majAuth(data);
      })
      .catch(function (err) {
        authEnCours = false;
        chargerAuth();
        if (authNote) {
          authNote.textContent = 'Authentification : échec (' +
            (err && err.message ? err.message : 'erreur réseau') + ').';
          authNote.hidden = false;
        }
      });
  }

  if (authEnregistrer) {
    authEnregistrer.addEventListener('click', function () {
      var mot = authMotDePasse ? authMotDePasse.value : '';
      if (!mot) {
        if (authNote) {
          authNote.textContent = 'Saisir un mot de passe avant d’enregistrer.';
          authNote.hidden = false;
        }
        return;
      }
      envoyerAuth({
        utilisateur: authUtilisateur ? authUtilisateur.value : '',
        mot_de_passe: mot
      });
    });
  }
  if (authRetirer) {
    authRetirer.addEventListener('click', function () {
      envoyerAuth({ retirer: true });
    });
  }
  chargerAuth();

  // --- Contrôle d'accès par sous-réseau source -------------------------
  // Une rangée par sous-réseau : champ sous-réseau, commentaire facultatif,
  // bouton de retrait. L'état relu est un tableau d'objets {reseau,
  // commentaire} ; le commentaire n'entre jamais dans le contrôle d'accès.
  var sectionReseaux = document.getElementById('reseaux');
  var reseauxEtat = document.getElementById('reseaux-etat');
  var reseauxSource = document.getElementById('reseaux-source');
  var reseauxEntrees = document.getElementById('reseaux-entrees');
  var reseauxAjouter = document.getElementById('reseaux-ajouter');
  var reseauxEnregistrer = document.getElementById('reseaux-enregistrer');
  var reseauxNote = document.getElementById('reseaux-note');
  var reseauxEnCours = false;

  function ligneReseau(entree) {
    var ligne = document.createElement('div');
    ligne.className = 'reseau-entree';
    var sousReseau = document.createElement('input');
    sousReseau.type = 'text';
    sousReseau.className = 'reseau-sous-reseau';
    sousReseau.maxLength = 64;
    sousReseau.autocomplete = 'off';
    sousReseau.placeholder = '10.35.0.0/16';
    sousReseau.setAttribute('aria-label', 'Sous-réseau');
    sousReseau.value = (entree && typeof entree.reseau === 'string') ? entree.reseau : '';
    var commentaire = document.createElement('input');
    commentaire.type = 'text';
    commentaire.className = 'reseau-commentaire';
    commentaire.maxLength = 200;
    commentaire.autocomplete = 'off';
    commentaire.placeholder = 'Commentaire (facultatif)';
    commentaire.setAttribute('aria-label', 'Commentaire du sous-réseau');
    commentaire.value = (entree && typeof entree.commentaire === 'string') ? entree.commentaire : '';
    var retirer = document.createElement('button');
    retirer.type = 'button';
    retirer.className = 'qualite-bascule reseau-retirer';
    retirer.textContent = 'Retirer';
    retirer.setAttribute('aria-label', 'Retirer ce sous-réseau');
    retirer.addEventListener('click', function () {
      ligne.remove();
    });
    ligne.appendChild(sousReseau);
    ligne.appendChild(commentaire);
    ligne.appendChild(retirer);
    return ligne;
  }

  function afficherEntrees(liste) {
    if (!reseauxEntrees) { return; }
    while (reseauxEntrees.firstChild) { reseauxEntrees.removeChild(reseauxEntrees.firstChild); }
    var entrees = Array.isArray(liste) ? liste : [];
    entrees.forEach(function (e) { reseauxEntrees.appendChild(ligneReseau(e)); });
  }

  function entreesSaisies() {
    if (!reseauxEntrees) { return []; }
    var entrees = [];
    reseauxEntrees.querySelectorAll('.reseau-entree').forEach(function (ligne) {
      var champ = ligne.querySelector('.reseau-sous-reseau');
      var commentaire = ligne.querySelector('.reseau-commentaire');
      var reseau = champ ? champ.value.trim() : '';
      var texte = commentaire ? commentaire.value.trim() : '';
      if (reseau !== '' || texte !== '') {
        entrees.push({ reseau: reseau, commentaire: texte });
      }
    });
    return entrees;
  }

  function majReseaux(r) {
    if (!sectionReseaux || !r || typeof r !== 'object') { return; }
    if (reseauxEtat) {
      reseauxEtat.textContent = r.active === true ? 'Filtrage actif' : 'Aucun filtrage';
    }
    if (reseauxSource) {
      reseauxSource.textContent = 'Source : ' + (r.source || 'locale');
    }
    afficherEntrees(r.reseaux);
    var enCours = reseauxEnCours;
    if (reseauxEntrees) { reseauxEntrees.querySelectorAll('input, button').forEach(function (e) { e.disabled = enCours; }); }
    if (reseauxAjouter) { reseauxAjouter.disabled = enCours; }
    if (reseauxEnregistrer) { reseauxEnregistrer.disabled = enCours; }
    if (reseauxNote) {
      if (r.erreur) {
        reseauxNote.textContent = 'Fichier de réseaux invalide : ' + r.erreur +
          ' — accès non local refusé (503).';
        reseauxNote.hidden = false;
      } else {
        reseauxNote.textContent = '';
        reseauxNote.hidden = true;
      }
    }
  }

  function chargerReseaux() {
    fetch('/api/reseaux', { cache: 'no-store', headers: { Accept: 'application/json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (r) { if (r) { majReseaux(r); } })
      .catch(function () {});
  }

  function envoyerReseaux(payload) {
    if (reseauxEnCours) { return; }
    reseauxEnCours = true;
    fetch('/api/reseaux', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(payload)
    })
      .then(function (r) {
        return r.json().then(
          function (data) {
            if (!r.ok) { throw new Error((data && data.error) || ('HTTP ' + r.status)); }
            return data;
          },
          function () {
            if (!r.ok) { throw new Error('HTTP ' + r.status); }
            return {};
          }
        );
      })
      .then(function (data) {
        reseauxEnCours = false;
        majReseaux(data);
      })
      .catch(function (err) {
        reseauxEnCours = false;
        chargerReseaux();
        if (reseauxNote) {
          reseauxNote.textContent = 'Réseaux : échec (' +
            (err && err.message ? err.message : 'erreur réseau') + ').';
          reseauxNote.hidden = false;
        }
      });
  }

  if (reseauxAjouter) {
    reseauxAjouter.addEventListener('click', function () {
      if (!reseauxEntrees) { return; }
      var ligne = ligneReseau({reseau: '', commentaire: ''});
      reseauxEntrees.appendChild(ligne);
      var champ = ligne.querySelector('.reseau-sous-reseau');
      if (champ) { champ.focus(); }
    });
  }
  if (reseauxEnregistrer) {
    reseauxEnregistrer.addEventListener('click', function () {
      envoyerReseaux({ reseaux: entreesSaisies() });
    });
  }
  chargerReseaux();
})();
]]

-- message_audio : état initial de l'axe audio, calculé par le serveur
-- (degradation.etat_audio). Le script le met ensuite à jour à partir de
-- /api/orgue ; le rendre ici évite un blanc au premier affichage et laisse
-- le message lisible sans JavaScript.
(message_audio = "") ->
  message_audio = tostring(message_audio) or ""
  page = h.html lang: "fr",
    h.head {},
      h.meta charset: "utf-8",
      h.meta name: "viewport", content: "width=device-width, initial-scale=1",
      h.title "Orgue — Audio",
      h.style style .. css,
    h.body {},
      h.main(
        class: "qualite-page"
        h.div(
          class: "entete"
          h.a href: "/", "← Orgue"
          h.h2 "Audio"
        )
        h.div(
          class: "puce-bloc"
          h.span class: "puce-charge charge-gris", id: "qualite-puce", role: "status", ["aria-live"]: "polite", "Pas encore évalué — jouez quelques accords"
          h.p class: "note", id: "qualite-puce-detail", "Pointe : — · Xruns récents : 0 · total : 0"
        )
        h.section(
          class: "qualite", id: "qualite", ["aria-label"]: "Réglages audio", ["data-charge-classe-0"]: modele.CHARGE_NIVEAUX[1].classe, ["data-charge-classe-1"]: modele.CHARGE_NIVEAUX[2].classe, ["data-charge-classe-2"]: modele.CHARGE_NIVEAUX[3].classe, ["data-charge-classe-3"]: modele.CHARGE_NIVEAUX[4].classe, ["data-charge-libelle-0"]: modele.CHARGE_NIVEAUX[1].libelle, ["data-charge-libelle-1"]: modele.CHARGE_NIVEAUX[2].libelle, ["data-charge-libelle-2"]: modele.CHARGE_NIVEAUX[3].libelle, ["data-charge-libelle-3"]: modele.CHARGE_NIVEAUX[4].libelle
          h.p class: "note qualite-indisponible", id: "qualite-indisponible", hidden: true, "Réglages audio indisponibles sur ce serveur."
          h.p class: "note qualite-indisponible", id: "qualite-plateforme", hidden: (message_audio == "") or nil, message_audio
          h.div(
            class: "qualite-corps"
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Niveau"
              h.div(
                class: "qualite-commandes"
                h.div(
                  class: "qualite-segments", id: "qualite-niveau", role: "group", ["aria-label"]: "Niveau de qualité"
                  table.unpack [bouton_segment(v, nom, v == "3") for {v, nom} in *niveaux_segments]
                )
                h.span class: "qualite-note", id: "qualite-niveau-note", hidden: true
              )
            )
            h.div(
              class: "qualite-ligne qualite-ligne-pleine"
              h.div(
                class: "qualite-commandes"
                h.button type: "button", class: "qualite-bascule", id: "qualite-bruit", ["aria-pressed"]: "true", "Bruit d'attaque"
                h.button type: "button", class: "qualite-bascule", id: "qualite-instabilite", ["aria-pressed"]: "true", "Instabilité"
              )
            )
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Spatialisation"
              h.div(
                class: "qualite-commandes"
                h.div(
                  class: "qualite-segments", id: "qualite-spatialisation", role: "group", ["aria-label"]: "Spatialisation"
                  h.button type: "button", class: "qualite-segment", ["data-valeur"]: "0", ["aria-pressed"]: "false", "Coupée"
                  h.button type: "button", class: "qualite-segment", ["data-valeur"]: "1", ["aria-pressed"]: "false", "Simplifiée"
                  h.button type: "button", class: "qualite-segment", ["data-valeur"]: "2", ["aria-pressed"]: "true", "Complète"
                )
              )
            )
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Réverbération"
              h.div(
                class: "qualite-commandes"
                h.input type: "range", id: "reverb", min: "0", max: "127", step: "1", value: "64", ["aria-label"]: "Réverbération"
              )
            )
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Polyphonie maximale"
              h.div(
                class: "qualite-commandes qualite-commandes-curseur"
                h.input type: "range", id: "qualite-polyphonie", min: "0", max: "512", step: "1", value: "0", ["aria-label"]: "Polyphonie maximale"
                h.output id: "qualite-polyphonie-valeur", ["for"]: "qualite-polyphonie", "Illimitée"
              )
            )
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Période"
              h.div(
                class: "qualite-commandes"
                h.div(
                  class: "qualite-segments", id: "qualite-periode", role: "group", ["aria-label"]: "Période audio"
                  table.unpack [bouton_segment(v, v, v == "512", libelle_periode(v)) for v in *periodes]
                )
                h.span class: "qualite-note", id: "qualite-periode-note", hidden: true
              )
            )
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Taux d'échantillonnage"
              h.div(
                class: "qualite-commandes"
                h.div(
                  class: "qualite-segments", id: "qualite-taux", role: "group", ["aria-label"]: "Taux d'échantillonnage"
                  table.unpack [bouton_segment(v, v, v == "48000") for v in *taux_valides]
                )
                h.span class: "qualite-note", id: "qualite-taux-note", hidden: true
              )
            )
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Limiteur"
              h.div(
                class: "qualite-commandes"
                h.button type: "button", class: "qualite-bascule", id: "qualite-limiteur", ["aria-pressed"]: "true", "Actif"
                h.span class: "qualite-note", id: "qualite-limiteur-note", hidden: true
                h.span class: "qualite-note", "évite la saturation sur les gros accords"
              )
            )
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Tempérament"
              h.div(
                class: "qualite-commandes"
                h.div(
                  class: "qualite-segments", id: "qualite-temperament", role: "group", ["aria-label"]: "Tempérament"
                  table.unpack [bouton_segment(tostring(i - 1), nom, i - 1 == 5) for i, nom in ipairs modele.TEMPERAMENTS]
                )
                h.span class: "qualite-note qualite-statut", id: "qualite-temperament-note", role: "status", ["aria-live"]: "polite", hidden: true
              )
            )
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Périphérique audio"
              h.div(
                class: "qualite-commandes"
                h.input type: "text", id: "qualite-peripherique", maxlength: "200", placeholder: "Défaut", ["aria-label"]: "Périphérique audio"
                h.span class: "qualite-note", id: "qualite-peripherique-note", hidden: true
              )
            )
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Tête"
              h.div(
                class: "qualite-commandes"
                h.button type: "button", class: "qualite-bascule", id: "qualite-tete", ["aria-pressed"]: "true", "Réverbération zéro latence"
                h.span class: "qualite-note", id: "qualite-tete-etat", hidden: true
              )
            )
          )
          h.p class: "note", id: "qualite-tete-impose", hidden: true, "Valeur imposée par ORGANUM_REVERB_TETE : non modifiable ici."
          h.p class: "note qualite-repli", id: "qualite-repli", hidden: true
          h.p class: "note qualite-erreur", id: "qualite-audio-erreur", hidden: true
          h.p class: "note qualite-calibration", id: "qualite-calibration", hidden: true
          h.p class: "note qualite-message", id: "qualite-message", role: "status", ["aria-live"]: "polite", hidden: true
        )
        h.section(
          class: "qualite", id: "authentification", ["aria-label"]: "Authentification"
          h.div(
            class: "qualite-corps"
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Authentification"
              h.div(
                class: "qualite-commandes"
                h.span id: "auth-etat", "Désactivée"
              )
            )
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Utilisateur"
              h.div(
                class: "qualite-commandes"
                h.input type: "text", id: "auth-utilisateur", maxlength: "64", value: "organiste", autocomplete: "username", ["aria-label"]: "Utilisateur de l'authentification"
              )
            )
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Mot de passe"
              h.div(
                class: "qualite-commandes"
                h.input type: "password", id: "auth-mot-de-passe", maxlength: "1024", autocomplete: "new-password", ["aria-label"]: "Nouveau mot de passe"
                h.button type: "button", class: "qualite-bascule", id: "auth-enregistrer", "Enregistrer"
                h.button type: "button", class: "qualite-bascule", id: "auth-retirer", hidden: true, "Retirer"
              )
            )
          )
          h.p class: "note", "Sur HTTP, le mot de passe est envoyé en clair : le calcul de HA1 côté navigateur exige HTTPS (crypto.subtle)."
          h.p class: "note qualite-message", id: "auth-note", role: "status", ["aria-live"]: "polite", hidden: true
        )
        h.section(
          class: "qualite", id: "reseaux", ["aria-label"]: "Contrôle d'accès par sous-réseau source"
          h.div(
            class: "qualite-corps"
            h.div(
              class: "qualite-ligne"
              h.span class: "qualite-libelle", "Réseaux autorisés"
              h.div(
                class: "qualite-commandes"
                h.span id: "reseaux-etat", "Aucun filtrage"
                h.span class: "qualite-note", id: "reseaux-source", "Source : —"
              )
            )
            h.div "", class: "reseaux-entrees", id: "reseaux-entrees"
            h.div(
              class: "qualite-ligne qualite-ligne-pleine"
              h.div(
                class: "qualite-commandes"
                h.button type: "button", class: "qualite-bascule", id: "reseaux-ajouter", "Ajouter un sous-réseau"
                h.button type: "button", class: "qualite-bascule", id: "reseaux-enregistrer", "Enregistrer"
              )
            )
          )
          h.p class: "note", "Un sous-réseau par ligne, avec un commentaire facultatif. Une liste vide ne filtre rien ; les adresses locales 127.0.0.1 et ::1 passent toujours. Enregistrer depuis cette page conserve les commentaires d’entrée mais perd les lignes qui ne sont qu’un commentaire."
          h.p class: "note qualite-message", id: "reseaux-note", role: "status", ["aria-live"]: "polite", hidden: true
        )
        h.script script
      )
  "<!DOCTYPE html>\n" .. page
