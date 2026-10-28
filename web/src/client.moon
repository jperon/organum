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

  function setStatus(isOnline) {
    var text = isOnline ? 'Connecté' : 'Hors ligne…';
    if (statusDisplay.textContent !== text) {
      statusDisplay.textContent = text;
    }
    statusDisplay.classList.toggle('online', isOnline);
    statusDisplay.classList.toggle('offline', !isOnline);
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
    function syncEl() {
      var el = document.getElementById('orgue-sync');
      if (!el) {
        el = document.createElement('span');
        el.id = 'orgue-sync';
        el.textContent = 'synchronisé';
        el.setAttribute('style', 'font-size:0.78rem;color:#7cf0b2;margin-left:8px;');
        var st = document.getElementById('status');
        if (st && st.parentNode) { st.parentNode.appendChild(el); }
      }
      return el;
    }
    function updateSyncUI() {
      var note = document.querySelector('#panel-orgue .note');
      var sync = document.getElementById('orgue-sync');
      if (aeolusMode) {
        if (note) { note.style.display = 'none'; }
        var s = sync || syncEl();
        if (s) { s.style.display = ''; }
      } else {
        if (note) { note.style.display = ''; }
        if (sync) { sync.style.display = 'none'; }
      }
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
          if (token !== orgueToken) { return; }
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
          if (token !== orgueToken) { return; }
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