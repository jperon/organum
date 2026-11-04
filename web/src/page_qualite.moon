-- Page des réglages de qualité : niveau, champs à chaud et paramètres audio.
-- Le contenu est construit par le script à partir de /api/orgue ; les
-- réglages sont envoyés par POST /api/orgue {qualite}.
h = require "html"
style = require "style"
modele = require "modele"

css = [[
  .qualite-page {
    max-width: 900px;
    margin: 0 auto;
    padding: 8px;
    display: flex;
    flex-direction: column;
    gap: 12px;
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

  /* Réglages de qualité : section compacte, une colonne au téléphone, deux
     dès que la largeur le permet ; aucune largeur minimale fixe, donc jamais
     de défilement horizontal. */
  .qualite {
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 4px 6px;
    background: var(--panel);
    min-width: 0;
  }
  .qualite[hidden] { display: none; }
  .qualite-titre {
    margin: 0 0 3px;
    font-size: 0.9rem;
    font-weight: 700;
  }
  .qualite-corps {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(min(100%, 260px), 1fr));
    gap: 6px 12px;
    align-items: start;
    min-width: 0;
  }
  .qualite-champ,
  .qualite-case,
  .qualite-tete {
    min-width: 0;
    font-size: 0.82rem;
    color: var(--text-dim);
  }
  /* Chaque réglage empile son libellé puis son contrôle : la cellule peut
     être étroite sans jamais écraser la valeur affichée. */
  .qualite-champ {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 3px 6px;
    align-items: center;
  }
  .qualite-champ > span { min-width: 0; }
  .qualite-champ select,
  .qualite-champ input[type="text"] {
    width: 100%;
    min-width: 0;
    box-sizing: border-box;
  }
  .qualite-champ input[type="text"] {
    padding: 3px 5px;
    border: 1px solid var(--border);
    border-radius: 5px;
    background: var(--panel-raised);
    color: var(--text);
    font: inherit;
    font-size: 0.82rem;
  }
  /* Les notes (valeur imposée, écart avec la valeur effective) occupent
     leur propre ligne, sous le libellé et le contrôle. */
  .qualite-note {
    display: block;
    font-size: 0.72rem;
    color: var(--text-dim);
    font-style: italic;
  }
  .qualite-note[hidden] { display: none; }
  .qualite-repli {
    margin: 3px 0 0;
    font-size: 0.78rem;
  }
  .qualite select {
    padding: 3px 5px;
    border: 1px solid var(--border);
    border-radius: 5px;
    background: var(--panel-raised);
    color: var(--text);
    font: inherit;
    font-size: 0.82rem;
  }
  .qualite-cases {
    display: flex;
    flex-wrap: wrap;
    gap: 2px 12px;
    min-width: 0;
  }
  /* Case et libellé restent solidaires (même ligne de grille) ; le texte
     peut se replier à droite sans séparer la case. */
  .qualite-case {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr);
    gap: 2px 6px;
    align-items: center;
    min-width: 0;
    cursor: pointer;
  }
  .qualite-case > input { grid-column: 1; }
  .qualite-case > span:not(.qualite-note) { grid-column: 2; min-width: 0; }
  .qualite-case > .qualite-note { grid-column: 1 / -1; }
  .qualite-tete { align-items: start; }
  .qualite-case input[type="checkbox"] {
    width: 18px;
    height: 18px;
    margin: 0;
    accent-color: var(--accent);
  }
  /* Polyphonie : le libellé au-dessus, puis le curseur et sa valeur sur une
     même ligne ; le curseur garde une largeur utile même en colonne étroite. */
  .qualite-polyphonie {
    grid-template-columns: minmax(140px, 1fr) auto;
  }
  .qualite-polyphonie > span { grid-column: 1 / -1; }
  .qualite-polyphonie input[type="range"] {
    width: 100%;
    min-width: 140px;
  }
  /* Le curseur de polyphonie est horizontal et dans le flux, comme celui de
     la réverbération ; le style de base est pivoté. */
  .qualite input[type="range"] {
    position: static;
    transform: none;
    width: auto;
    height: 30px;
    padding: 0;
    margin: 0;
  }
  .qualite output {
    flex: 0 0 auto;
    min-width: 4.2em;
    text-align: right;
    font-variant-numeric: tabular-nums;
    color: var(--text);
  }
  .qualite select:focus-visible,
  .qualite input:focus-visible {
    outline: 3px solid var(--focus);
    outline-offset: 2px;
  }
  .qualite select:disabled,
  .qualite input:disabled {
    opacity: 0.55;
    cursor: not-allowed;
  }
]]

option_qualite = (valeur, nom, choisi) ->
  attrs = {value: valeur}
  attrs.selected = true if choisi
  attrs.disabled = true if valeur == "-1"
  h.option attrs, nom

niveaux_qualite = {"auto", "0", "1", "2", "3", "-1"}
noms_niveaux = {auto: "Auto", "0": "0", "1": "1", "2": "2", "3": "3", "-1": "Personnalisé"}

duree_periode = (periode, taux = 48000) ->
  texte = string.format "%.1f", tonumber(periode) * 1000 / taux
  texte\gsub "%.", ","

periodes = {"128", "256", "512", "1024", "2048"}
option_periode = (valeur) ->
  attrs = {value: valeur}
  attrs.selected = true if valeur == "512"
  h.option attrs, "#{valeur} (#{duree_periode valeur} ms)"

taux_valides = {"44100", "48000"}
option_taux = (valeur) ->
  attrs = {value: valeur}
  attrs.selected = true if valeur == "48000"
  h.option attrs, valeur

script = [[
(function () {
  'use strict';

  var section = document.getElementById('qualite');
  if (!section) { return; }
  var selNiveau = document.getElementById('qualite-niveau');
  var caseBruit = document.getElementById('qualite-bruit');
  var caseInstabilite = document.getElementById('qualite-instabilite');
  var selSpatialisation = document.getElementById('qualite-spatialisation');
  var curseurPolyphonie = document.getElementById('qualite-polyphonie');
  var valeurPolyphonie = document.getElementById('qualite-polyphonie-valeur');
  var caseTete = document.getElementById('qualite-tete');
  var noteTeteImpose = document.getElementById('qualite-tete-impose');
  var noteTeteEtat = document.getElementById('qualite-tete-etat');
  var selPeriode = document.getElementById('qualite-periode');
  var notePeriode = document.getElementById('qualite-periode-note');
  var selTaux = document.getElementById('qualite-taux');
  var noteTaux = document.getElementById('qualite-taux-note');
  var champPeripherique = document.getElementById('qualite-peripherique');
  var notePeripherique = document.getElementById('qualite-peripherique-note');
  var caseLimiteur = document.getElementById('qualite-limiteur');
  var noteLimiteur = document.getElementById('qualite-limiteur-note');
  var ligneRepli = document.getElementById('qualite-repli');
  var ligneErreur = document.getElementById('qualite-audio-erreur');
  var ligneCalibration = document.getElementById('qualite-calibration');
  var message = document.getElementById('qualite-message');
  var indisponible = document.getElementById('qualite-indisponible');
  var puce = document.getElementById('qualite-puce');
  var puceDetail = document.getElementById('qualite-puce-detail');
  var enAttente = 0;
  var polyActif = false;
  var polyEnvoye = null;
  var echecEnvoi = '';

  function note(el, texte) {
    if (!el) { return; }
    el.textContent = texte || '';
    el.hidden = !texte;
  }

  function nombre(valeur) {
    var n = Number(valeur);
    return isFinite(n) ? n : null;
  }

  function textePeriode(periode, taux) {
    var p = nombre(periode);
    var t = nombre(taux);
    if (p === null) { return String(periode); }
    if (t === null || t <= 0) { t = 48000; }
    return p + ' (' + (p * 1000 / t).toFixed(1).replace('.', ',') + ' ms)';
  }

  function mettreAJourPeriodes(taux) {
    if (!selPeriode) { return; }
    for (var i = 0; i < selPeriode.options.length; i += 1) {
      var option = selPeriode.options[i];
      var p = nombre(option.value);
      if (p !== null) { option.textContent = textePeriode(p, taux); }
    }
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

  // Le message de la page : « Application… » tant qu'une reconfiguration est
  // en cours côté fil audio (état explicite `application`), puis un éventuel
  // échec d'envoi. Un échec audio s'affiche dans sa propre ligne.
  function majMessage(q) {
    if (!message) { return; }
    var texte = '';
    if (q && typeof q === 'object' && q.application === true) {
      texte = 'Application…';
    } else if (echecEnvoi) {
      texte = echecEnvoi;
    }
    message.textContent = texte;
    message.hidden = !texte;
  }

  // Puce d'adaptation : le niveau vient du C ; ce script ne fait que
  // traduire la classe et le libellé. Pendant « Application… », on ne
  // réévalue pas la puce.
  function majPuce(q) {
    if (!puce) { return; }
    if (q && typeof q === 'object' && q.application === true) { return; }
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

  function desactiver(actif) {
    [selNiveau, caseBruit, caseInstabilite, selSpatialisation, curseurPolyphonie, caseTete,
     selPeriode, selTaux, champPeripherique, caseLimiteur].forEach(function (el) {
      if (el) { el.disabled = actif; }
    });
  }

  function maj(q) {
    if (enAttente > 0) { majMessage(q); majPuce(q); return; }
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
    if (selNiveau) {
      var choix = choixNiveau(q);
      var option = selNiveau.querySelector('option[value="' + choix + '"]');
      if (!option) { option = selNiveau.querySelector('option[value="-1"]'); }
      selNiveau.value = option ? option.value : '-1';
    }
    if (caseBruit) { caseBruit.checked = q.bruit_attaque === true; }
    if (caseInstabilite) { caseInstabilite.checked = q.instabilite === true; }
    if (selSpatialisation && typeof q.spatialisation === 'number') {
      selSpatialisation.value = String(q.spatialisation);
    }
    if (!polyActif && typeof q.polyphonie_max === 'number') {
      polyEnvoye = null;
      if (curseurPolyphonie) { curseurPolyphonie.value = String(q.polyphonie_max); }
      if (valeurPolyphonie) { valeurPolyphonie.textContent = textePolyphonie(q.polyphonie_max); }
    }
    // Tête de réverbération : le contrôle montre la valeur ENREGISTRÉE.
    if (caseTete && typeof q.tete_reverb_prochain === 'boolean') { caseTete.checked = q.tete_reverb_prochain; }
    if (caseTete) { caseTete.disabled = q.tete_reverb_impose === true; }
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

    var tauxProchain = nombre(q.taux_prochain);
    if (tauxProchain === null) { tauxProchain = 48000; }
    mettreAJourPeriodes(tauxProchain);
    var periodeProchain = nombre(q.periode_prochain);
    if (periodeProchain === null) { periodeProchain = 512; }
    if (selPeriode) {
      selPeriode.value = String(periodeProchain);
      selPeriode.disabled = q.periode_impose === true;
      var etatPeriode = '';
      if (q.periode_impose === true) { etatPeriode = 'imposée par ORGANUM_PERIODE'; }
      else if (nombre(q.periode) !== null && q.periode !== q.periode_prochain) {
        etatPeriode = 'en cours : ' + textePeriode(q.periode, q.taux);
      }
      note(notePeriode, etatPeriode);
    }
    if (selTaux) {
      selTaux.value = String(tauxProchain);
      selTaux.disabled = q.taux_impose === true;
      var etatTaux = '';
      if (q.taux_impose === true) { etatTaux = 'imposé par ORGANUM_TAUX'; }
      else if (nombre(q.taux) !== null && q.taux !== q.taux_prochain) {
        etatTaux = 'en cours : ' + q.taux + ' Hz';
      }
      note(noteTaux, etatTaux);
    }
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
    if (caseLimiteur) {
      caseLimiteur.checked = q.limiteur_prochain === true;
      caseLimiteur.disabled = q.limiteur_impose === true;
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
        echecEnvoi = 'Qualité : échec de l’enregistrement (' + detail + ').';
        majMessage(null);
      });
  }

  if (selNiveau) {
    selNiveau.addEventListener('change', function () {
      var valeur = selNiveau.value;
      if (valeur === 'auto') { envoyer({ auto: true }); return; }
      if (valeur === '-1') { return; }
      var n = nombre(valeur);
      if (n !== null && n >= 0 && n <= 3) { envoyer({ niveau: Math.round(n) }); }
    });
  }
  if (caseBruit) {
    caseBruit.addEventListener('change', function () {
      envoyer({ bruit_attaque: caseBruit.checked });
    });
  }
  if (caseInstabilite) {
    caseInstabilite.addEventListener('change', function () {
      envoyer({ instabilite: caseInstabilite.checked });
    });
  }
  if (selSpatialisation) {
    selSpatialisation.addEventListener('change', function () {
      var n = nombre(selSpatialisation.value);
      if (n !== null && n >= 0 && n <= 2) { envoyer({ spatialisation: Math.round(n) }); }
    });
  }
  if (curseurPolyphonie) {
    curseurPolyphonie.addEventListener('input', function () {
      polyActif = true;
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
  if (caseTete) {
    caseTete.addEventListener('change', function () {
      envoyer({ tete_reverb: caseTete.checked });
    });
  }
  if (selPeriode) {
    selPeriode.addEventListener('change', function () {
      var n = nombre(selPeriode.value);
      if (n !== null) { envoyer({ periode: n }); }
    });
  }
  if (selTaux) {
    selTaux.addEventListener('change', function () {
      var n = nombre(selTaux.value);
      if (n !== null) { envoyer({ taux: n }); }
    });
  }
  if (champPeripherique) {
    champPeripherique.addEventListener('change', function () {
      envoyer({ peripherique: champPeripherique.value });
    });
  }
  if (caseLimiteur) {
    caseLimiteur.addEventListener('change', function () {
      envoyer({ limiteur: caseLimiteur.checked });
    });
  }

  // --- Boucle d'état propre à cette page ------------------------------
  // GET /api/orgue puis attente longue /api/orgue/attendre, comme la page
  // principale ; à la perte de connexion, on réessaie après 2 s.
  var device = { instance: null, seq: null, token: 0 };

  function appliquerEtat(data) {
    if (!data || typeof data !== 'object') { return; }
    maj(data.qualite);
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
})();
]]

->
  page = h.html lang: "fr",
    h.head {},
      h.meta charset: "utf-8",
      h.meta name: "viewport", content: "width=device-width, initial-scale=1",
      h.title "Orgue — Qualité",
      h.style style .. css,
    h.body {},
      h.main class: "qualite-page",
        h.div class: "entete",
          h.a href: "/", "← Orgue",
          h.h2 "Qualité",
        h.div class: "puce-bloc",
          h.span class: "puce-charge charge-gris", id: "qualite-puce", role: "status", ["aria-live"]: "polite", "Pas encore évalué — jouez quelques accords",
          h.p class: "note", id: "qualite-puce-detail", "Pointe : — · Xruns récents : 0 · total : 0",
        h.section class: "qualite", id: "qualite", ["aria-label"]: "Réglages de qualité", ["data-charge-classe-0"]: modele.CHARGE_NIVEAUX[1].classe, ["data-charge-classe-1"]: modele.CHARGE_NIVEAUX[2].classe, ["data-charge-classe-2"]: modele.CHARGE_NIVEAUX[3].classe, ["data-charge-classe-3"]: modele.CHARGE_NIVEAUX[4].classe, ["data-charge-libelle-0"]: modele.CHARGE_NIVEAUX[1].libelle, ["data-charge-libelle-1"]: modele.CHARGE_NIVEAUX[2].libelle, ["data-charge-libelle-2"]: modele.CHARGE_NIVEAUX[3].libelle, ["data-charge-libelle-3"]: modele.CHARGE_NIVEAUX[4].libelle,
          h.p class: "note qualite-indisponible", id: "qualite-indisponible", hidden: true,
            "Réglages de qualité indisponibles sur ce serveur.",
          h.div class: "qualite-corps",
            h.label class: "qualite-champ",
              h.span "Niveau",
              h.select id: "qualite-niveau", ["aria-label"]: "Niveau de qualité",
                table.unpack [option_qualite v, noms_niveaux[v], v == "3" for v in *niveaux_qualite],
            h.div class: "qualite-cases",
              h.label class: "qualite-case",
                h.input type: "checkbox", id: "qualite-bruit", checked: true,
                h.span "Bruit d'attaque",
              h.label class: "qualite-case",
                h.input type: "checkbox", id: "qualite-instabilite", checked: true,
                h.span "Instabilité",
            h.label class: "qualite-champ",
              h.span "Spatialisation",
              h.select id: "qualite-spatialisation", ["aria-label"]: "Spatialisation",
                h.option value: "0", "Coupée",
                h.option value: "1", "Simplifiée",
                h.option value: "2", selected: true, "Complète",
            h.label class: "qualite-champ qualite-polyphonie",
              h.span "Polyphonie maximale",
              h.input type: "range", id: "qualite-polyphonie", min: "0", max: "512", step: "1", value: "0", ["aria-label"]: "Polyphonie maximale",
              h.output id: "qualite-polyphonie-valeur", ["for"]: "qualite-polyphonie", "Illimitée",
            h.label class: "qualite-champ qualite-demarrage",
              h.span "Période",
              h.select id: "qualite-periode", ["aria-label"]: "Période audio",
                table.unpack [option_periode v for v in *periodes],
              h.span class: "note qualite-note", id: "qualite-periode-note", hidden: true,
            h.label class: "qualite-champ qualite-demarrage",
              h.span "Taux d'échantillonnage",
              h.select id: "qualite-taux", ["aria-label"]: "Taux d'échantillonnage",
                table.unpack [option_taux v for v in *taux_valides],
              h.span class: "note qualite-note", id: "qualite-taux-note", hidden: true,
            h.label class: "qualite-champ qualite-demarrage",
              h.span "Périphérique audio",
              h.input type: "text", id: "qualite-peripherique", maxlength: "200", placeholder: "Défaut", ["aria-label"]: "Périphérique audio",
              h.span class: "note qualite-note", id: "qualite-peripherique-note", hidden: true,
            h.label class: "qualite-case qualite-demarrage",
              h.input type: "checkbox", id: "qualite-limiteur", checked: true,
              h.span "Limiteur",
              h.span class: "note qualite-note", id: "qualite-limiteur-note", hidden: true,
            h.label class: "qualite-case qualite-tete",
              h.input type: "checkbox", id: "qualite-tete", checked: true,
              h.span "Tête de réverbération zéro latence",
              h.span class: "note qualite-note", id: "qualite-tete-etat", hidden: true,
          h.p class: "note", id: "qualite-tete-impose", hidden: true,
            "Valeur imposée par ORGANUM_REVERB_TETE : non modifiable ici.",
          h.p class: "note qualite-repli", id: "qualite-repli", hidden: true,
          h.p class: "note qualite-erreur", id: "qualite-audio-erreur", hidden: true,
          h.p class: "note qualite-calibration", id: "qualite-calibration", hidden: true,
          h.p class: "note qualite-message", id: "qualite-message", role: "status", ["aria-live"]: "polite", hidden: true,
      h.script script

  "<!DOCTYPE html>\n" .. page
