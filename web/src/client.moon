-- Code client (chaîne longue).
JS = [[
(function () {
  'use strict';

  // --- Volume (comportement original conservé) ---
  var API_ENDPOINT = '/api/volume';
  var POLL_DELAY = 2000;
  var THROTTLE_DELAY = 150;
  var REQUEST_TIMEOUT = 5000;

  var slider = document.getElementById('volume');
  var valueDisplay = document.getElementById('value');
  var statusDisplay = document.getElementById('status');
  var muteButton = document.getElementById('mute');

  var etatReseau = false;
  var etatAeolus = false;
  // Libellés injectés par page.moon depuis modele.ETATS ; repli sur les
  // chaînes historiques si les attributs manquent.
  var ETATS_DEFAUT = {
    vert: { libelle: 'Connecté et synchronisé', title: 'Connecté et synchronisé' },
    orange: { libelle: 'Connecté, non synchronisé', title: 'Connecté, non synchronisé' },
    rouge: { libelle: 'Déconnecté', title: 'Déconnecté' }
  };
  var LIBELLES_ETAT = {};
  ['vert', 'orange', 'rouge'].forEach(function (etat) {
    var defaut = ETATS_DEFAUT[etat];
    var libelle = statusDisplay && statusDisplay.getAttribute('data-libelle-' + etat);
    var titre = statusDisplay && statusDisplay.getAttribute('data-title-' + etat);
    LIBELLES_ETAT[etat] = {
      libelle: libelle || defaut.libelle,
      title: titre || libelle || defaut.title
    };
  });

  var state = { volume: 50, muted: false };
  var revision = 0;
  var dragging = false;
  var pointerActive = false;
  var interacting = false;
  var pendingPosts = 0;
  var polling = false;
  var throttleTimer = null;
  var pendingVolume = null;
  var lastVolumePost = 0;

  function clampVolume(value) {
    var number = Number(value);
    if (!isFinite(number)) {
      return null;
    }
    number = Math.round(number);
    if (number < 0) { number = 0; }
    if (number > 100) { number = 100; }
    return number;
  }

  function normalizeState(data) {
    if (!data || typeof data !== 'object') {
      return null;
    }
    var volume = clampVolume(data.volume);
    if (volume === null) {
      return null;
    }
    return { volume: volume, muted: data.muted === true };
  }

  function paint() {
    var volume = state.volume;
    valueDisplay.textContent = volume + '\u00a0%';
    slider.setAttribute('aria-valuetext', volume + '\u00a0%');
    slider.style.setProperty('--fill', volume + '%');

    if (!dragging) {
      slider.value = String(volume);
    }

    muteButton.textContent = state.muted ? 'Rétablir le son' : 'Muet';
    muteButton.setAttribute('aria-pressed', state.muted ? 'true' : 'false');
    muteButton.setAttribute('aria-label', state.muted ? 'Rétablir le son' : 'Couper le son');
    muteButton.classList.toggle('is-muted', state.muted);
  }

  function majPuceEtat() {
    var etat = !etatReseau ? 'rouge' : (etatAeolus ? 'vert' : 'orange');
    var classe = 'etat-' + etat;
    var info = LIBELLES_ETAT[etat] || LIBELLES_ETAT.rouge;
    statusDisplay.classList.remove('etat-vert', 'etat-orange', 'etat-rouge');
    statusDisplay.classList.add(classe);
    statusDisplay.title = info.title;
    var texte = statusDisplay.querySelector('.sr-only');
    if (texte && texte.textContent !== info.libelle) {
      texte.textContent = info.libelle;
    }
  }

  function setStatus(isOnline) {
    etatReseau = isOnline === true;
    majPuceEtat();
  }

  function setAeolusMode(actif) {
    etatAeolus = actif === true;
    majPuceEtat();
  }

  function applyState(next) {
    if (!next) { return; }
    if (dragging) {
      state.muted = next.muted;
      paint();
      return;
    }
    state.volume = next.volume;
    state.muted = next.muted;
    paint();
  }

  function requestState(method, payload) {
    var controller = new AbortController();
    var timer = window.setTimeout(function () { controller.abort(); }, REQUEST_TIMEOUT);
    var options = {
      method: method,
      headers: { Accept: 'application/json' },
      cache: 'no-store',
      signal: controller.signal
    };
    if (payload !== null && payload !== undefined) {
      options.headers['Content-Type'] = 'application/json';
      options.body = JSON.stringify(payload);
    }
    return fetch(API_ENDPOINT, options)
      .then(function (response) {
        if (!response.ok) { throw new Error('HTTP ' + response.status); }
        return response.json();
      })
      .then(function (data) {
        var next = normalizeState(data);
        if (!next) { throw new Error('État invalide'); }
        return next;
      })
      .finally(function () { window.clearTimeout(timer); });
  }

  function send(payload) {
    var sentRevision = revision;
    pendingPosts += 1;
    return requestState('POST', payload)
      .then(function (next) {
        setStatus(true);
        if (sentRevision === revision) { applyState(next); }
      })
      .catch(function () { setStatus(false); })
      .finally(function () { pendingPosts -= 1; });
  }

  function flushVolume() {
    if (pendingVolume === null) { return; }
    var volume = pendingVolume;
    pendingVolume = null;
    lastVolumePost = Date.now();
    send({ volume: volume });
  }

  function queueVolume(volume) {
    pendingVolume = volume;
    if (throttleTimer !== null) { return; }
    var wait = Math.max(0, THROTTLE_DELAY - (Date.now() - lastVolumePost));
    if (wait === 0) {
      flushVolume();
      return;
    }
    throttleTimer = window.setTimeout(function () {
      throttleTimer = null;
      flushVolume();
    }, wait);
  }

  function finishInteraction() {
    if (!dragging && !interacting) { return; }
    var volume = clampVolume(slider.value);
    dragging = false;
    pointerActive = false;
    interacting = false;
    if (throttleTimer !== null) {
      window.clearTimeout(throttleTimer);
      throttleTimer = null;
    }
    pendingVolume = null;
    if (volume === null) { return; }
    revision += 1;
    state.volume = volume;
    paint();
    send({ volume: volume });
  }

  function refresh() {
    if (polling || dragging || interacting || pendingPosts > 0) { return; }
    polling = true;
    var requestedRevision = revision;
    requestState('GET', null)
      .then(function (next) {
        setStatus(true);
        if (requestedRevision === revision && !dragging) { applyState(next); }
      })
      .catch(function () { setStatus(false); })
      .finally(function () { polling = false; });
  }

  slider.addEventListener('pointerdown', function () {
    pointerActive = true;
    dragging = true;
    interacting = true;
  });
  slider.addEventListener('input', function () {
    var volume = clampVolume(slider.value);
    if (volume === null) { return; }
    interacting = true;
    if (pointerActive) { dragging = true; }
    revision += 1;
    state.volume = volume;
    paint();
    queueVolume(volume);
  });
  slider.addEventListener('change', finishInteraction);
  slider.addEventListener('blur', finishInteraction);
  window.addEventListener('pointerup', finishInteraction);
  window.addEventListener('touchend', finishInteraction, { passive: true });
  window.addEventListener('pointercancel', finishInteraction);

  muteButton.addEventListener('click', function () {
    revision += 1;
    send({ muted: !state.muted });
  });

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) { refresh(); }
  });

  paint();
  setStatus(false);
  refresh();
  window.setInterval(refresh, POLL_DELAY);

  // --- Qualité (section « Qualité ») ---
  // qualiteMaj est appelé par la boucle d'état de l'orgue (plus bas) avec
  // l'objet `qualite` de GET /api/orgue, et par les réponses de POST.
  var qualiteMaj = null;
  (function () {
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
    var ligneCalibration = document.getElementById('qualite-calibration');
    var message = document.getElementById('qualite-message');
    var indisponible = document.getElementById('qualite-indisponible');
    var enAttente = 0;
    var polyActif = false;
    var polyEnvoye = null;

    function note(el, texte) {
      if (!el) { return; }
      el.textContent = texte || '';
      el.hidden = !texte;
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

    function nombre(valeur) {
      var n = Number(valeur);
      return isFinite(n) ? n : null;
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

    function afficherMessage(texte) {
      if (!message) { return; }
      message.textContent = texte || '';
      message.hidden = !texte;
    }

    function desactiver(actif) {
      [selNiveau, caseBruit, caseInstabilite, selSpatialisation, curseurPolyphonie, caseTete,
       selPeriode, selTaux, champPeripherique, caseLimiteur].forEach(function (el) {
        if (el) { el.disabled = actif; }
      });
    }

    function maj(q) {
      if (enAttente > 0) { return; }
      if (!q || typeof q !== 'object') {
        // Serveur sans réglages de qualité (ancienne version) : la section
        // reste visible mais ses contrôles sont inertes, avec une explication.
        section.hidden = false;
        desactiver(true);
        if (indisponible) { indisponible.hidden = false; }
        if (noteTeteImpose) { noteTeteImpose.hidden = true; }
        if (ligneCalibration) { ligneCalibration.hidden = true; }
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
      // Tête de réverbération : le contrôle montre la valeur ENREGISTRÉE
      // (prochain démarrage), pas seulement la valeur effective en cours.
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
      if (ligneCalibration) {
        var texte = texteCalibration(q.calibration);
        ligneCalibration.textContent = texte;
        ligneCalibration.hidden = !texte;
      }
    }

    function envoyer(payload) {
      enAttente += 1;
      afficherMessage('');
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
          if (data && data.redemarrage_requis) {
            afficherMessage('Réglage enregistré : il s’appliquera au prochain démarrage.');
          }
          maj(data);
        })
        .catch(function (err) {
          enAttente -= 1;
          var detail = err && err.message ? err.message : 'erreur réseau';
          afficherMessage('Qualité : échec de l’enregistrement (' + detail + ').');
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
    qualiteMaj = maj;
  })();

  // --- Orgue (temps réel Aeolus + repli mémoire) ---
  (function () {
    var ORGUE_API = '/api/orgue';
    var orgueState = { step: 0, reverb: 64, stops: [] };
    var aeolusInstance = null;
    var aeolusSeq = null;
    var aeolusMode = false;
    var orgueToken = 0;
    var reverbManip = false;

    function orgueTabActive() { return true; }
    function shouldPollOrgue() {
      return orgueTabActive() && document.visibilityState === 'visible';
    }
    function updateSyncUI() {
      var note = document.querySelector('#panel-orgue .note');
      if (aeolusMode) {
        if (note) { note.style.display = 'none'; }
      } else {
        if (note) { note.style.display = ''; }
      }
      setAeolusMode(aeolusMode);
    }

    function stateOf(div, idx) {
      if (!orgueState.stops || !orgueState.stops[div]) { return -1; }
      var v = orgueState.stops[div][idx];
      if (v === 1) return 1;
      if (v === 0) return 0;
      return -1;
    }

    function renderMemoire(data) {
      if (typeof data.step === 'number') { orgueState.step = data.step; }
      if (typeof data.reverb === 'number') { orgueState.reverb = data.reverb; }
      if (Array.isArray(data.stops)) { orgueState.stops = data.stops; }
      document.querySelectorAll('.stop').forEach(function (btn) {
        var d = parseInt(btn.getAttribute('data-division'), 10);
        var i = parseInt(btn.getAttribute('data-index'), 10);
        var s = stateOf(d, i);
        var st = (s === 1) ? 'on' : (s === 0) ? 'off' : 'unknown';
        btn.setAttribute('data-state', st);
      });
      var comboInput = document.getElementById('combo-num');
      if (comboInput) { comboInput.value = String((orgueState.step || 0) + 1); }
      majCombos();
      var reverbSlider = document.getElementById('reverb');
      if (reverbSlider && typeof orgueState.reverb === 'number' && orgueState.reverb >= 0) {
        reverbSlider.value = String(orgueState.reverb);
      }
      updateSyncUI();
    }

    function renderAeolus(data) {
      if (typeof data.step === 'number') { orgueState.step = data.step; }
      var comboInput = document.getElementById('combo-num');
      if (comboInput) { comboInput.value = String((orgueState.step || 0) + 1); }
      majCombos();
      if (typeof data.reverb === 'number' && isFinite(data.reverb)) {
        var v = Math.round(data.reverb * 127);
        if (v < 0) { v = 0; }
        if (v > 127) { v = 127; }
        orgueState.reverb = v;
        var reverbSlider = document.getElementById('reverb');
        if (reverbSlider && !reverbManip) { reverbSlider.value = String(v); }
      }
      if (Array.isArray(data.divisions)) {
        var stops = [];
        var panels = document.querySelectorAll('#panel-orgue .division');
        // Structure différente de la page (autre orgue chargé dans Aeolus) :
        // on recharge pour régénérer les divisions côté serveur.
        var differe = panels.length !== data.divisions.length;
        for (var k = 0; !differe && k < panels.length; k++) {
          var l = (data.divisions[k] || {}).stops;
          differe = !Array.isArray(l) || panels[k].querySelectorAll('.stop').length !== l.length;
        }
        if (differe) { location.reload(); return; }
        for (var d = 0; d < data.divisions.length; d++) {
          var div = data.divisions[d] || {};
          var arr = [];
          var list = Array.isArray(div.stops) ? div.stops : [];
          for (var i = 0; i < list.length; i++) {
            arr.push(list[i] && list[i].on === true ? 1 : 0);
          }
          stops.push(arr);
          var panel = panels[d];
          if (panel) {
            var summary = panel.querySelector('.division-nom');
            if (summary && typeof div.name === 'string' && div.name) { summary.textContent = div.name; }
            var btns = panel.querySelectorAll('.stop');
            for (var j = 0; j < btns.length; j++) {
              var st = list[j];
              if (st && typeof st.name === 'string' && st.name) { btns[j].textContent = st.name; }
            }
          }
        }
        orgueState.stops = stops;
        if (window.majGains) { window.majGains(data.divisions); }
        if (window.majLiens) { window.majLiens(data.divisions); }
      }
      document.querySelectorAll('.stop').forEach(function (btn) {
        var d = parseInt(btn.getAttribute('data-division'), 10);
        var i = parseInt(btn.getAttribute('data-index'), 10);
        var s = stateOf(d, i);
        btn.setAttribute('data-state', s === 1 ? 'on' : 'off');
      });
      updateSyncUI();
    }

    function applyOrgueData(data) {
      if (qualiteMaj) {
        qualiteMaj(data && typeof data === 'object' ? data.qualite : null);
      }
      if (data && typeof data === 'object' && data.source === 'aeolus') {
        aeolusMode = true;
        if (typeof data.instance === 'string') { aeolusInstance = data.instance; }
        if (typeof data.seq === 'number' && isFinite(data.seq)) { aeolusSeq = data.seq; }
        renderAeolus(data);
      } else if (data && typeof data === 'object') {
        aeolusMode = false;
        aeolusInstance = null;
        aeolusSeq = null;
        renderMemoire(data);
      }
    }

    function attendreLoop(instance, seq, token) {
      if (token !== orgueToken || !shouldPollOrgue()) { return; }
      var url = ORGUE_API + '/attendre?instance=' + encodeURIComponent(instance) + '&seq=' + encodeURIComponent(String(seq));
      fetch(url, { cache: 'no-store', headers: { Accept: 'application/json' } })
        .then(function (r) {
          if (r.status === 204) { return null; }
          if (!r.ok) { throw new Error('HTTP ' + r.status); }
          return r.json();
        })
        .then(function (data) {
          if (token !== orgueToken || !shouldPollOrgue()) { return; }
          if (data === null) {
            attendreLoop(instance, seq, token);
            return;
          }
          applyOrgueData(data);
          if (aeolusMode && aeolusInstance !== null && aeolusSeq !== null) {
            attendreLoop(aeolusInstance, aeolusSeq, token);
          } else {
            fetchOrgueInitial(token);
          }
        })
        .catch(function () {
          if (token !== orgueToken || !shouldPollOrgue()) { return; }
          setAeolusMode(false);
          window.setTimeout(function () {
            if (token === orgueToken && shouldPollOrgue()) { attendreLoop(instance, seq, token); }
          }, 2000);
        });
    }

    function fetchOrgueInitial(token) {
      fetch(ORGUE_API, { cache: 'no-store', headers: { Accept: 'application/json' } })
        .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
        .then(function (data) {
          if (token !== orgueToken || !shouldPollOrgue()) { return; }
          applyOrgueData(data);
          if (aeolusMode && aeolusInstance !== null && aeolusSeq !== null) {
            attendreLoop(aeolusInstance, aeolusSeq, token);
          } else {
            window.setTimeout(function () {
              if (token === orgueToken && shouldPollOrgue()) { fetchOrgueInitial(token); }
            }, 3000);
          }
        })
        .catch(function () {
          if (token !== orgueToken || !shouldPollOrgue()) { return; }
          setAeolusMode(false);
          window.setTimeout(function () {
            if (token === orgueToken && shouldPollOrgue()) { fetchOrgueInitial(token); }
          }, 2000);
        });
    }

    function startOrgueLoop() {
      if (!shouldPollOrgue()) { return; }
      orgueToken += 1;
      fetchOrgueInitial(orgueToken);
    }

    // Bouton de la combinaison active (grand écran).
    function majCombos() {
      var cur = String(orgueState.step || 0);
      document.querySelectorAll('.combo-btn').forEach(function (b) {
        var actif = b.getAttribute('data-step') === cur;
        b.classList.toggle('actif', actif);
        b.setAttribute('aria-pressed', actif ? 'true' : 'false');
      });
    }

    function postOrgue(payload) {
      fetch(ORGUE_API, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify(payload)
      })
        .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
        .then(function (data) {
          if (!data || typeof data !== 'object') { return; }
          if (data.source === 'aeolus') {
            if (shouldPollOrgue()) { applyOrgueData(data); }
          } else if (!aeolusMode) {
            renderMemoire(data);
          }
        })
        .catch(function () {});
    }

    document.querySelectorAll('.stop').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var d = parseInt(btn.getAttribute('data-division'), 10);
        var i = parseInt(btn.getAttribute('data-index'), 10);
        var current = stateOf(d, i);
        var next = (current === 1) ? false : true;
        postOrgue({ stop: { division: d, index: i, on: next } });
      });
    });

    document.querySelectorAll('.cancel-division').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var d = parseInt(btn.getAttribute('data-division'), 10);
        postOrgue({ cancel: d });
      });
    });

    var prevBtn = document.getElementById('combo-prev');
    var nextBtn = document.getElementById('combo-next');
    var comboInput = document.getElementById('combo-num');
    if (prevBtn) {
      prevBtn.addEventListener('click', function () {
        var n = (orgueState.step || 0) - 1;
        if (n < 0) n = 0;
        postOrgue({ step: n });
      });
    }
    if (nextBtn) {
      nextBtn.addEventListener('click', function () {
        var n = (orgueState.step || 0) + 1;
        if (n > 31) n = 31;
        postOrgue({ step: n });
      });
    }
    if (comboInput) {
      comboInput.addEventListener('change', function () {
        var v = parseInt(comboInput.value, 10);
        if (!isFinite(v)) return;
        if (v < 1) v = 1;
        if (v > 32) v = 32;
        postOrgue({ step: v - 1 });
      });
    }

    document.querySelectorAll('.combo-btn').forEach(function (btn) {
      btn.addEventListener('click', function () {
        postOrgue({ step: parseInt(btn.getAttribute('data-step'), 10) });
      });
    });

    var reverbSlider = document.getElementById('reverb');
    if (reverbSlider) {
      reverbSlider.addEventListener('pointerdown', function () { reverbManip = true; });
      reverbSlider.addEventListener('input', function () { reverbManip = true; });
      reverbSlider.addEventListener('change', function () {
        var v = parseInt(reverbSlider.value, 10);
        reverbManip = false;
        if (!isFinite(v)) return;
        if (v < 0) v = 0;
        if (v > 127) v = 127;
        postOrgue({ reverb: v });
      });
      reverbSlider.addEventListener('blur', function () { reverbManip = false; });
    }

    var panicBtn = document.getElementById('panic');
    if (panicBtn) {
      panicBtn.addEventListener('click', function () {
        postOrgue({ panic: true });
      });
    }

    // Volume de chaque clavier (via le socket d'Aeolus).
    var gainManip = {};
    document.querySelectorAll('input.gain').forEach(function (g) {
      var d = parseInt(g.getAttribute('data-division'), 10);
      g.addEventListener('input', function () { gainManip[d] = true; });
      g.addEventListener('change', function () {
        gainManip[d] = false;
        postOrgue({ gain: { division: d, value: parseInt(g.value, 10) / 100 } });
      });
    });
    // Accouplements (P+I, I+II…) : état publié par le moteur.
    document.querySelectorAll('.link').forEach(function (btn) {
      btn.addEventListener('click', function () {
        postOrgue({ link: {
          division: parseInt(btn.getAttribute('data-division'), 10),
          index: parseInt(btn.getAttribute('data-index'), 10),
          on: btn.getAttribute('data-state') !== 'on'
        } });
      });
    });
    window.majLiens = function (divisions) {
      document.querySelectorAll('.link').forEach(function (btn) {
        var div = divisions[parseInt(btn.getAttribute('data-division'), 10)];
        var l = div && div.links && div.links[parseInt(btn.getAttribute('data-index'), 10)];
        if (l) { btn.setAttribute('data-state', l.on ? 'on' : 'off'); }
      });
    };

    window.majGains = function (divisions) {
      document.querySelectorAll('input.gain').forEach(function (g) {
        var d = parseInt(g.getAttribute('data-division'), 10);
        var div = divisions[d];
        if (div && typeof div.gain === 'number' && !gainManip[d]) {
          g.value = String(Math.round(div.gain * 100));
        }
      });
    };

    startOrgueLoop();
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && orgueTabActive()) { startOrgueLoop(); }
      else if (document.hidden) { orgueToken += 1; }
    });

    updateSyncUI();
  })();
})();
]]

return JS