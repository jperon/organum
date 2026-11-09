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
  var lienQualite = document.getElementById('lien-qualite');

  // Couleur du lien Qualité : vient de charge_niveau déjà reçu par la boucle
  // d'état, sans requête supplémentaire. Le texte porte aussi le niveau.
  function majLienQualite(qualite) {
    if (!lienQualite) { return; }
    if (qualite && qualite.application_audio === true) { return; }
    var niveau = qualite && typeof qualite.charge_niveau === 'number'
      ? qualite.charge_niveau : 0;
    if (niveau < 0 || niveau > 3) { niveau = 0; }
    var classe = lienQualite.getAttribute('data-charge-classe-' + niveau) || 'charge-gris';
    var libelle = lienQualite.getAttribute('data-charge-libelle-' + niveau) || 'Pas encore évalué';
    lienQualite.className = 'btn small lien-qualite ' + classe;
    lienQualite.textContent = niveau >= 3 ? 'Audio !!' : niveau >= 2 ? 'Audio !' : 'Audio';
    lienQualite.setAttribute('aria-label', 'Audio — ' + libelle);
  }

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

  // --- Volume de la pédale (volume du moteur, distinct du volume système) ---
  var PEDALE_API = '/api/orgue';
  var pedalSlider = document.getElementById('volume-pedale');
  var pedalValueDisplay = document.getElementById('value-pedale');
  var pedalManip = false;
  var pedalPending = null;
  var pedalThrottleTimer = null;
  var lastPedalPost = 0;

  function paintPedale(percent) {
    if (!pedalSlider || !pedalValueDisplay) { return; }
    pedalValueDisplay.textContent = percent + '\u00a0%';
    pedalSlider.setAttribute('aria-valuetext', percent + '\u00a0%');
    pedalSlider.style.setProperty('--fill', percent + '%');
    if (!pedalManip) { pedalSlider.value = String(percent); }
  }

  function sendPedale(percent) {
    return fetch(PEDALE_API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ volume: percent / 100 })
    }).catch(function () {});
  }

  function flushPedale() {
    if (pedalPending === null) { return; }
    var percent = pedalPending;
    pedalPending = null;
    lastPedalPost = Date.now();
    sendPedale(percent);
  }

  function queuePedale(percent) {
    pedalPending = percent;
    if (pedalThrottleTimer !== null) { return; }
    var wait = Math.max(0, THROTTLE_DELAY - (Date.now() - lastPedalPost));
    if (wait === 0) {
      flushPedale();
      return;
    }
    pedalThrottleTimer = window.setTimeout(function () {
      pedalThrottleTimer = null;
      flushPedale();
    }, wait);
  }

  function finishPedale() {
    if (!pedalManip) { return; }
    var percent = clampVolume(pedalSlider.value);
    pedalManip = false;
    if (pedalThrottleTimer !== null) {
      window.clearTimeout(pedalThrottleTimer);
      pedalThrottleTimer = null;
    }
    pedalPending = null;
    if (percent === null) { return; }
    paintPedale(percent);
    sendPedale(percent);
  }

  if (pedalSlider) {
    pedalSlider.addEventListener('pointerdown', function () { pedalManip = true; });
    pedalSlider.addEventListener('input', function () {
      var percent = clampVolume(pedalSlider.value);
      if (percent === null) { return; }
      pedalManip = true;
      paintPedale(percent);
      queuePedale(percent);
    });
    pedalSlider.addEventListener('change', finishPedale);
    pedalSlider.addEventListener('blur', finishPedale);
    window.addEventListener('pointerup', finishPedale);
    window.addEventListener('touchend', finishPedale, { passive: true });
    window.addEventListener('pointercancel', finishPedale);
    var initial = clampVolume(pedalSlider.value);
    paintPedale(initial === null ? 50 : initial);
  }

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) { refresh(); }
  });

  paint();
  setStatus(false);
  refresh();
  window.setInterval(refresh, POLL_DELAY);

  // --- Orgue (temps réel Aeolus + repli mémoire) ---
  (function () {
    var ORGUE_API = '/api/orgue';
    var orgueState = { step: 0, reverb: 64, stops: [] };
    var aeolusInstance = null;
    var aeolusSeq = null;
    var aeolusMode = false;
    var orgueToken = 0;

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

    // Message discret du clavier : tant qu'aucun jeu publié n'est allumé,
    // jouer ne produira rien. Aucun jeu n'est allumé automatiquement.
    function majClavierAvertissement() {
      var p = document.getElementById('clavier-avertissement');
      if (!p) { return; }
      var actif = false;
      (orgueState.stops || []).forEach(function (ligne) {
        if (!Array.isArray(ligne)) { return; }
        ligne.forEach(function (v) { if (v === 1) { actif = true; } });
      });
      p.hidden = actif;
    }

    // Le premier canal de chaque division peut changer depuis la page MIDI :
    // le sélecteur du clavier suit les valeurs publiées, sans nom en dur.
    function majClavierCanaux(divisions) {
      var select = document.getElementById('clavier-canal');
      if (!select || !Array.isArray(divisions)) { return; }
      var options = select.querySelectorAll('option[data-division]');
      var premier = null;
      for (var k = 0; k < options.length; k++) {
        var div = divisions[parseInt(options[k].getAttribute('data-division'), 10)];
        var canaux = div && Array.isArray(div.canaux) ? div.canaux : [];
        var canal = canaux.length ? Number(canaux[0]) : NaN;
        var valide = isFinite(canal) && canal >= 1 && canal <= 16;
        options[k].value = valide ? String(canal) : '';
        options[k].disabled = !valide;
        if (valide && premier === null) { premier = String(canal); }
      }
      var choisi = select.options[select.selectedIndex];
      if (!select.value || (choisi && choisi.disabled)) {
        select.value = premier === null ? '' : premier;
      }
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
      updateSyncUI();
      majClavierAvertissement();
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
        majClavierCanaux(data.divisions);
      }
      document.querySelectorAll('.stop').forEach(function (btn) {
        var d = parseInt(btn.getAttribute('data-division'), 10);
        var i = parseInt(btn.getAttribute('data-index'), 10);
        var s = stateOf(d, i);
        btn.setAttribute('data-state', s === 1 ? 'on' : 'off');
      });
      updateSyncUI();
      majClavierAvertissement();
    }

    function applyOrgueData(data) {
      majLienQualite(data && typeof data === 'object' ? data.qualite : null);
      if (data && typeof data === 'object' && typeof data.transposition === 'number' && isFinite(data.transposition)) {
        if (window.majTransposition) { window.majTransposition(data.transposition); }
      }
      if (data && typeof data === 'object' && typeof data.volume === 'number' && isFinite(data.volume)) {
        var pourcent = Math.round(Math.max(0, Math.min(1, data.volume)) * 100);
        if (!pedalManip) { paintPedale(pourcent); }
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


    var panicBtn = document.getElementById('panic');
    if (panicBtn) {
      panicBtn.addEventListener('click', function () {
        postOrgue({ panic: true });
      });
    }

    // --- Clavier jouable (panneau replié par défaut) --------------------
    // Les notes partent par POST /api/orgue {note:{canal,note,actif,…}} :
    // le serveur les écrit dans le tube du moteur (CMD_MIDI), jamais dans
    // le fil MIDI du système. Pointer Events couvre souris et doigt ; les
    // navigateurs sans PointerEvent gardent les événements tactiles.
    (function () {
      var panneau = document.getElementById('clavier-panneau');
      if (!panneau) { return; }
      var select = document.getElementById('clavier-canal');
      var notesActives = Object.create(null);
      var pointeurs = Object.create(null);
      var touchers = Object.create(null);
      var VELOCITE = 100;

      function canalCourant() {
        if (!select) { return null; }
        var canal = parseInt(select.value, 10);
        return (isFinite(canal) && canal >= 1 && canal <= 16) ? canal : null;
      }

      function toucheDepuisElement(el) {
        while (el && el !== panneau) {
          if (el.classList && el.classList.contains('touche')) { return el; }
          el = el.parentNode;
        }
        return null;
      }

      function toucheSous(x, y) {
        return toucheDepuisElement(document.elementFromPoint(x, y));
      }

      function noteDe(touche) {
        var note = parseInt(touche.getAttribute('data-note'), 10);
        return (isFinite(note) && note >= 0 && note <= 127) ? note : null;
      }

      function envoyerNote(canal, note, actif, velocite) {
        fetch(ORGUE_API, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
          body: JSON.stringify({
            note: { canal: canal, note: note, velocite: velocite, actif: actif }
          }),
          keepalive: true
        }).catch(function () {});
      }

      function presser(touche, canal) {
        var note = noteDe(touche);
        if (note === null) { return; }
        var cle = canal + ':' + note;
        var etat = notesActives[cle];
        if (etat) { etat.compte += 1; return; }
        notesActives[cle] = { touche: touche, canal: canal, note: note, compte: 1 };
        touche.setAttribute('aria-pressed', 'true');
        envoyerNote(canal, note, true, VELOCITE);
      }

      function relacher(touche, canal) {
        var note = noteDe(touche);
        if (note === null) { return; }
        var cle = canal + ':' + note;
        var etat = notesActives[cle];
        if (!etat) { return; }
        etat.compte -= 1;
        if (etat.compte > 0) { return; }
        delete notesActives[cle];
        etat.touche.setAttribute('aria-pressed', 'false');
        envoyerNote(canal, note, false, 0);
      }

      function relacherTout() {
        for (var cle in notesActives) {
          var etat = notesActives[cle];
          etat.touche.setAttribute('aria-pressed', 'false');
          envoyerNote(etat.canal, etat.note, false, 0);
        }
        notesActives = Object.create(null);
        pointeurs = Object.create(null);
        touchers = Object.create(null);
      }

      if (select) {
        select.addEventListener('change', relacherTout);
      }
      panneau.addEventListener('toggle', function () {
        if (!panneau.open) { relacherTout(); }
      });
      window.addEventListener('blur', relacherTout);
      window.addEventListener('pagehide', relacherTout);
      document.addEventListener('visibilitychange', function () {
        if (document.hidden) { relacherTout(); }
      });

      if (window.PointerEvent) {
        panneau.addEventListener('pointerdown', function (e) {
          var touche = toucheDepuisElement(e.target);
          if (!touche) { return; }
          var canal = canalCourant();
          if (!canal) { return; }
          e.preventDefault();
          pointeurs[e.pointerId] = { touche: touche, canal: canal };
          presser(touche, canal);
          try { panneau.setPointerCapture(e.pointerId); } catch (err) {}
        }, { passive: false });

        document.addEventListener('pointermove', function (e) {
          var p = pointeurs[e.pointerId];
          if (!p) { return; }
          e.preventDefault();
          var touche = toucheSous(e.clientX, e.clientY);
          if (touche === p.touche) { return; }
          if (p.touche) { relacher(p.touche, p.canal); }
          p.touche = touche;
          if (touche) { presser(touche, p.canal); }
        }, { passive: false });

        function finPointeur(e) {
          var p = pointeurs[e.pointerId];
          if (!p) { return; }
          if (p.touche) { relacher(p.touche, p.canal); }
          delete pointeurs[e.pointerId];
        }
        document.addEventListener('pointerup', finPointeur);
        document.addEventListener('pointercancel', finPointeur);
      } else {
        panneau.addEventListener('touchstart', function (e) {
          var canal = canalCourant();
          if (!canal) { return; }
          var pris = false;
          for (var i = 0; i < e.changedTouches.length; i++) {
            var t = e.changedTouches[i];
            var touche = toucheSous(t.clientX, t.clientY);
            if (!touche) { continue; }
            pris = true;
            touchers[t.identifier] = { touche: touche, canal: canal };
            presser(touche, canal);
          }
          if (pris) { e.preventDefault(); }
        }, { passive: false });

        panneau.addEventListener('touchmove', function (e) {
          if (!Object.keys(touchers).length) { return; }
          e.preventDefault();
          for (var i = 0; i < e.changedTouches.length; i++) {
            var t = e.changedTouches[i];
            var p = touchers[t.identifier];
            if (!p) { continue; }
            var touche = toucheSous(t.clientX, t.clientY);
            if (touche === p.touche) { continue; }
            relacher(p.touche, p.canal);
            p.touche = touche;
            if (touche) { presser(touche, p.canal); }
          }
        }, { passive: false });

        function finToucher(e) {
          for (var i = 0; i < e.changedTouches.length; i++) {
            var t = e.changedTouches[i];
            var p = touchers[t.identifier];
            if (!p) { continue; }
            if (p.touche) { relacher(p.touche, p.canal); }
            delete touchers[t.identifier];
          }
        }
        document.addEventListener('touchend', finToucher);
        document.addEventListener('touchcancel', finToucher);
      }
    })();

    // Transposition globale : −, valeur signée, +. La valeur vient de l'API
    // (GET ou attente longue), donc un changement fait dans la fenêtre native
    // apparaît ici, et réciproquement.
    var transpositionCourante = 0;
    var transpositionBloc = document.getElementById('transposition');
    function paintTransposition(valeur) {
      if (!transpositionBloc) { return; }
      var v = Math.round(Number(valeur));
      if (!isFinite(v)) { return; }
      if (v < -12) { v = -12; }
      if (v > 12) { v = 12; }
      transpositionCourante = v;
      var texte = v > 0 ? '+' + v : v < 0 ? '\u2212' + Math.abs(v) : '0';
      var champ = transpositionBloc.querySelector('.transposition-valeur');
      if (champ) {
        champ.textContent = texte;
        var libelleValeur = 'Transposition ' + texte + ' : remettre à 0';
        champ.setAttribute('aria-label', libelleValeur);
        champ.setAttribute('title', libelleValeur);
      }
      transpositionBloc.setAttribute('data-transposition', String(v));
      transpositionBloc.classList.toggle('active', v !== 0);
      var moins = transpositionBloc.querySelector('.transposition-moins');
      var plus = transpositionBloc.querySelector('.transposition-plus');
      if (moins) {
        moins.disabled = v <= -12;
        moins.setAttribute('aria-disabled', v <= -12 ? 'true' : 'false');
      }
      if (plus) {
        plus.disabled = v >= 12;
        plus.setAttribute('aria-disabled', v >= 12 ? 'true' : 'false');
      }
    }
    function reglerTransposition(valeur) {
      paintTransposition(valeur);
      postOrgue({ transposition: transpositionCourante });
    }
    window.majTransposition = paintTransposition;
    if (transpositionBloc) {
      var initialTransposition = parseInt(transpositionBloc.getAttribute('data-transposition'), 10);
      paintTransposition(isFinite(initialTransposition) ? initialTransposition : 0);
      var transpositionMoins = transpositionBloc.querySelector('.transposition-moins');
      var transpositionPlus = transpositionBloc.querySelector('.transposition-plus');
      if (transpositionMoins) {
        transpositionMoins.addEventListener('click', function () {
          if (transpositionCourante > -12) { reglerTransposition(transpositionCourante - 1); }
        });
      }
      if (transpositionPlus) {
        transpositionPlus.addEventListener('click', function () {
          if (transpositionCourante < 12) { reglerTransposition(transpositionCourante + 1); }
        });
      }
      var transpositionValeur = transpositionBloc.querySelector('.transposition-valeur');
      if (transpositionValeur) {
        transpositionValeur.addEventListener('click', function () {
          if (transpositionCourante !== 0) { reglerTransposition(0); }
        });
      }
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