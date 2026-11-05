// Pilote des tests de bout en bout de l'interface web d'organum, sans
// dépendance : protocole DevTools de Chromium en Node (WebSocket global).
//
//   CDP_PORT=... BASE_URL=... MODE=full node scripts/e2e-web.mjs
//
// MODE=full  : pages /, /midi, /audio, clics réels, erreurs console,
//              stabilité, largeurs 420/1100 px et remplissage des curseurs.
// MODE=fill  : contrôle ciblé du remplissage (--fill) après mutation.
//
// Sortie : une ligne OK / ÉCHEC par contrôle ; code non nul si échec.

const CDP_PORT = process.env.CDP_PORT;
const BASE = process.env.BASE_URL;
const MODE = process.env.MODE || 'full';

let echecs = 0;
let total = 0;

function ok(message) {
  total += 1;
  console.log(`OK    : ${message}`);
}

function echec(message) {
  total += 1;
  echecs += 1;
  console.log(`ÉCHEC : ${message}`);
}

function verifie(condition, message) {
  if (condition) ok(message);
  else echec(message);
}

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function attendre(condition, message, delai = 10000) {
  const debut = Date.now();
  let dernier;
  while (Date.now() - debut < delai) {
    try {
      dernier = await condition();
      if (dernier) return dernier;
    } catch (e) {
      dernier = e;
    }
    await delay(80);
  }
  echec(`${message} (délai ${delai} ms dépassé${dernier ? ` : ${dernier}` : ''})`);
  return null;
}

async function api(chemin) {
  const reponse = await fetch(BASE + chemin, { cache: 'no-store' });
  return reponse.json();
}

async function poster(chemin, objet) {
  const reponse = await fetch(BASE + chemin, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify(objet)
  });
  let corps = {};
  try { corps = await reponse.json(); } catch (e) { corps = {}; }
  return { code: reponse.status, corps };
}

class Cdp {
  constructor(socket) {
    this.socket = socket;
    this.id = 0;
    this.pending = new Map();
    this.erreurs = [];
    this.evenements = [];
    socket.addEventListener('message', (evenement) => {
      const message = JSON.parse(evenement.data);
      if (message.id !== undefined) {
        const attente = this.pending.get(message.id);
        if (!attente) return;
        this.pending.delete(message.id);
        if (message.error) attente.rejeter(new Error(message.error.message));
        else attente.resoudre(message.result);
        return;
      }
      this.evenements.push(message.method);
      if (message.method === 'Runtime.exceptionThrown') {
        const details = message.params.exceptionDetails || {};
        const exception = details.exception || {};
        this.erreurs.push(exception.description || details.text || 'exception sans texte');
      } else if (message.method === 'Log.entryAdded') {
        const entree = message.params.entry || {};
        if (entree.level === 'error' && !(entree.url || '').includes('favicon')) {
          this.erreurs.push(`${entree.source || 'log'} : ${entree.text || ''}`);
        }
      } else if (message.method === 'Runtime.consoleAPICalled') {
        if (message.params.type === 'error') {
          const args = (message.params.args || []).map((a) => a.value ?? a.description ?? '');
          this.erreurs.push(`console : ${args.join(' ')}`);
        }
      }
    });
  }

  envoyer(methode, params = {}) {
    const id = ++this.id;
    return new Promise((resoudre, rejeter) => {
      this.pending.set(id, { resoudre, rejeter });
      this.socket.send(JSON.stringify({ id, method: methode, params }));
    });
  }
}

async function connecter() {
  let cibles = [];
  for (let i = 0; i < 100; i += 1) {
    try {
      const reponse = await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`);
      cibles = await reponse.json();
      if (cibles.length > 0) break;
    } catch (e) { /* Chromium démarre encore. */ }
    await delay(100);
  }
  let cible = cibles.find((c) => c.type === 'page');
  if (!cible) {
    const reponse = await fetch(`http://127.0.0.1:${CDP_PORT}/json/new?about:blank`, { method: 'PUT' });
    cible = await reponse.json();
  }
  const socket = new WebSocket(cible.webSocketDebuggerUrl);
  await new Promise((resoudre, rejeter) => {
    socket.addEventListener('open', resoudre, { once: true });
    socket.addEventListener('error', rejeter, { once: true });
  });
  const cdp = new Cdp(socket);
  await cdp.envoyer('Runtime.enable');
  await cdp.envoyer('Log.enable');
  await cdp.envoyer('Page.enable');
  return cdp;
}

let cdp;

async function evaluer(expression) {
  const resultat = await cdp.envoyer('Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: true
  });
  if (resultat.exceptionDetails) {
    const d = resultat.exceptionDetails;
    throw new Error((d.exception && d.exception.description) || d.text || 'erreur JS');
  }
  return resultat.result.value;
}

async function navigate(chemin) {
  await cdp.envoyer('Page.navigate', { url: BASE + chemin });
  await attendre(
    async () => (await evaluer('document.readyState')) === 'complete',
    `chargement de ${chemin}`,
    10000
  );
  await delay(400);
}

async function viewport(largeur, hauteur = 900) {
  await cdp.envoyer('Emulation.setDeviceMetricsOverride', {
    width: largeur,
    height: hauteur,
    deviceScaleFactor: 1,
    mobile: false
  });
}

async function rect(expression) {
  return evaluer(`(async () => {
    const e = (${expression});
    if (!e) return null;
    e.scrollIntoView({ block: 'center', inline: 'center' });
    await new Promise((r) => requestAnimationFrame(() => r()));
    const r = e.getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  })()`);
}

async function clic(expression, fx = 0.5, fy = 0.5) {
  const r = await rect(expression);
  if (!r) {
    echec(`élément introuvable : ${expression}`);
    return false;
  }
  const x = r.x + r.w * fx;
  const y = r.y + r.h * fy;
  await cdp.envoyer('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  await cdp.envoyer('Input.dispatchMouseEvent', {
    type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1
  });
  await cdp.envoyer('Input.dispatchMouseEvent', {
    type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1
  });
  await delay(180);
  return true;
}

function selecteur(groupe, valeur) {
  return `document.querySelector('#${groupe} [data-valeur="${valeur}"]')`;
}

async function clicGroupe(groupe, valeur) {
  return clic(selecteur(groupe, valeur));
}

function etatsJeux(etat) {
  const sortie = [];
  for (const division of etat.divisions || []) {
    for (const jeu of division.stops || []) sortie.push(jeu.on === true);
  }
  return sortie;
}

function memeJeux(a, b) {
  return JSON.stringify(etatsJeux(a)) === JSON.stringify(etatsJeux(b));
}

async function stableSansAction(nom) {
  const avant = await api('/api/orgue');
  await delay(5000);
  const apres = await api('/api/orgue');
  verifie(
    avant.seq === apres.seq && memeJeux(avant, apres),
    `${nom} : état stable sans action pendant 5 s (seq ${avant.seq}→${apres.seq})`
  );
}

async function testAccueil() {
  await viewport(1100);
  await navigate('/');
  await attendre(() => evaluer('document.querySelector(".stop") !== null'), 'page / affichée');
  await stableSansAction('web /');

  const ndiv = await evaluer('document.querySelectorAll(".division").length');
  verifie(ndiv > 0, `web / : ${ndiv} division(s) affichée(s)`);

  for (let d = 0; d < ndiv; d += 1) {
    const expression = `document.querySelectorAll(".division")[${d}].querySelector(".stop")`;
    const avant = (await api('/api/orgue')).divisions[d].stops[0].on === true;
    if (!(await clic(expression))) continue;
    const attendu = !avant;
    const vu = await attendre(
      async () => (await api('/api/orgue')).divisions[d].stops[0].on === attendu,
      `web / : jeu 0 de la division ${d} bascule par clic`
    );
    if (vu) {
      await clic(expression);
      await attendre(
        async () => (await api('/api/orgue')).divisions[d].stops[0].on === avant,
        `web / : jeu 0 de la division ${d} revient à son état`
      );
    }
  }

  const avantStep = (await api('/api/orgue')).step;
  const cibleStep = avantStep === 2 ? 3 : 2;
  await clic(`document.querySelector('.combo-btn[data-step="${cibleStep}"]')`);
  await attendre(
    async () => (await api('/api/orgue')).step === cibleStep,
    `web / : combinaison ${cibleStep + 1} sélectionnée par clic`
  );

  const stop0 = 'document.querySelectorAll(".division")[0].querySelector(".stop")';
  const etait = (await api('/api/orgue')).divisions[0].stops[0].on === true;
  if (!etait) await clic(stop0);
  await attendre(
    async () => (await api('/api/orgue')).divisions[0].stops[0].on === true,
    'web / : jeu activé avant Annuler'
  );
  await clic('document.querySelectorAll(".division")[0].querySelector(".cancel-division")');
  await attendre(
    async () => (await api('/api/orgue')).divisions[0].stops.every((j) => j.on !== true),
    'web / : Annuler éteint la division par clic'
  );

  const avantPanique = await api('/api/orgue');
  await clic('document.getElementById("panic")');
  await delay(300);
  const apresPanique = await api('/api/orgue');
  verifie(
    memeJeux(avantPanique, apresPanique),
    'web / : Panique acceptée par clic (les registres ne changent pas)'
  );

  const volumeAvant = (await api('/api/volume')).muted === true;
  await clic('document.getElementById("mute")');
  const mute = await attendre(
    async () => {
      const texte = await evaluer('document.getElementById("mute").textContent');
      const etat = await api('/api/volume');
      return (texte.includes('Rétablir le son') && etat.muted === true) ? texte : null;
    },
    'web / : le bouton Muet devient « Rétablir le son »'
  );
  if (mute) {
    await clic('document.getElementById("mute")');
    await attendre(
      async () => {
        const texte = await evaluer('document.getElementById("mute").textContent');
        const etat = await api('/api/volume');
        return (texte.includes('Muet') && etat.muted === false) ? texte : null;
      },
      'web / : retour à « Muet » par clic'
    );
  }
  if (volumeAvant) {
    await poster('/api/volume', { muted: true });
  }

  await clic('document.getElementById("volume")', 0.3);
  await attendre(
    async () => {
      const etat = await api('/api/volume');
      return etat.volume >= 20 && etat.volume <= 40;
    },
    'web / : curseur de volume système à ~30 % par clic'
  );
  await clic('document.getElementById("volume-pedale")', 0.7);
  await attendre(
    async () => {
      const etat = await api('/api/orgue');
      return etat.volume >= 0.6 && etat.volume <= 0.8;
    },
    'web / : curseur de pédale à ~70 % par clic'
  );

  const remplissages = await evaluer(`(() => {
    function mesure(id) {
      const e = document.getElementById(id);
      if (!e) return null;
      const min = Number(e.min), max = Number(e.max), v = Number(e.value);
      return { attendu: (v - min) / (max - min) * 100,
               vu: parseFloat(e.style.getPropertyValue('--fill')) };
    }
    return { volume: mesure('volume'), pedale: mesure('volume-pedale') };
  })()`);
  for (const [nom, m] of Object.entries(remplissages)) {
    verifie(
      m && Math.abs(m.attendu - m.vu) < 1.5,
      `web / : --fill cohérent avec le pouce (${nom} ${m ? `${m.vu}% / ${m.attendu.toFixed(1)}%` : 'absent'})`
    );
  }
}

async function testMidi() {
  await viewport(1100);
  await navigate('/midi');
  await attendre(() => evaluer('document.querySelector(".canal[data-canal]") !== null'), 'page /midi affichée');

  const canal = 'document.querySelector(".canal[data-canal]")';
  const numero = await evaluer('Number(document.querySelector(".canal[data-canal]").dataset.canal)');
  const avant = await api('/api/midi');
  const actif = (avant.divisions[0].canaux || []).includes(numero);
  await clic(canal);
  await attendre(
    async () => {
      const etat = await api('/api/midi');
      const present = (etat.divisions[0].canaux || []).includes(numero);
      return present === !actif;
    },
    'web /midi : canal basculé par clic'
  );
  await clic(canal);
  await attendre(
    async () => {
      const etat = await api('/api/midi');
      const present = (etat.divisions[0].canaux || []).includes(numero);
      return present === actif;
    },
    'web /midi : canal revenu à son état par clic'
  );
  await clic('document.getElementById("ajouter")');
  await clic('document.getElementById("rafraichir-ports")');
  await attendre(
    async () => (await api('/api/midi')),
    'web /midi : Ajouter et Rafraîchir acceptés sans erreur'
  );
}

async function attendreChamp(nom, lecture, predicat, delai = 12000) {
  return attendre(async () => (predicat(await lecture()) ? true : null), nom, delai);
}

async function etatTemperamentDom() {
  return evaluer(`(() => {
    const groupe = document.getElementById('qualite-temperament');
    const note = document.getElementById('qualite-temperament-note');
    if (!groupe || !note) return null;
    const boutons = Array.prototype.slice.call(
      groupe.querySelectorAll('.qualite-segment'));
    const nombres = (filtre) => boutons
      .filter((b) => filtre(b.getAttribute('aria-busy'), b.getAttribute('aria-pressed')))
      .map((b) => Number(b.getAttribute('data-valeur')));
    return {
      actifs: nombres((busy, pressed) => pressed === 'true'),
      enCours: nombres((busy) => busy === 'true'),
      statut: note.hidden ? '' : note.textContent,
      role: note.getAttribute('role')
    };
  })()`);
}

async function testTemperamentRafale() {
  const depart = (await api('/api/orgue')).temperament;
  const a = (depart + 3) % 11;
  const b = (depart + 7) % 11;
  const nomA = await evaluer(
    `document.querySelector('#qualite-temperament [data-valeur="${a}"]').textContent`);
  const nomB = await evaluer(
    `document.querySelector('#qualite-temperament [data-valeur="${b}"]').textContent`);

  await clicGroupe('qualite-temperament', String(a));
  const justeA = await etatTemperamentDom();
  verifie(
    justeA && justeA.enCours.includes(a),
    `web /audio : état « en cours » immédiat sur le tempérament ${a}`
  );
  verifie(
    justeA && justeA.actifs.includes(depart),
    `web /audio : l'ancien tempérament ${depart} reste marqué en service`
  );
  verifie(
    justeA && justeA.role === 'status' && justeA.statut.includes('Application') &&
      justeA.statut.includes(nomA),
    `web /audio : message de statut visible dans la rangée Tempérament (« ${justeA && justeA.statut} »)`
  );

  await clicGroupe('qualite-temperament', String(b));
  const justeB = await etatTemperamentDom();
  verifie(
    justeB && justeB.enCours.includes(b) && !justeB.enCours.includes(a),
    `web /audio : la rafale déplace la cible en cours de ${a} à ${b}`
  );
  verifie(
    justeB && justeB.statut.includes(nomB),
    `web /audio : le message suit la dernière cible (« ${justeB && justeB.statut} »)`
  );

  const fin = await attendre(
    async () => {
      const e = await api('/api/orgue');
      return (e.temperament === b && e.qualite.application === false) ? e : null;
    },
    `web /audio : la dernière demande (${b}) aboutit après la rafale`,
    30000
  );
  if (fin) {
    const final = await attendre(
      async () => {
        const d = await etatTemperamentDom();
        return (d && d.enCours.length === 0 && d.statut === '' && d.actifs.includes(b)) ? d : null;
      },
      `web /audio : état final du tempérament ${b} (bouton actif, plus d'« en cours »)`,
      5000
    );
    verifie(
      !!final,
      `web /audio : message effacé et cible ${b} devenue active en fin de calcul`
    );
  }

  const avant = await api('/api/orgue');
  await clicGroupe('qualite-temperament', String(b));
  await delay(500);
  const apres = await api('/api/orgue');
  const domReclic = await etatTemperamentDom();
  verifie(
    avant.seq === apres.seq && apres.temperament === b &&
      domReclic && domReclic.enCours.length === 0,
    'web /audio : recliquer le tempérament déjà actif n’envoie aucune demande'
  );
}

async function testAudio() {
  await viewport(1100);
  await navigate('/audio');
  await attendre(() => evaluer('document.getElementById("qualite-temperament") !== null'), 'page /audio affichée');
  await stableSansAction('web /audio');

  await clicGroupe('qualite-niveau', 'auto');
  await attendreChamp(
    'web /audio : niveau Auto par clic',
    () => api('/api/orgue'),
    (e) => e.qualite.auto === true,
    15000
  );
  for (const niveau of [0, 1, 2, 3]) {
    await clicGroupe('qualite-niveau', String(niveau));
    await attendreChamp(
      `web /audio : niveau ${niveau} par clic`,
      () => api('/api/orgue'),
      (e) => e.qualite.niveau === niveau && e.qualite.auto === false
    );
  }

  for (const [id, champ] of [['qualite-bruit', 'bruit_attaque'], ['qualite-instabilite', 'instabilite']]) {
    const avant = (await api('/api/orgue')).qualite[champ] === true;
    await clic(`document.getElementById("${id}")`);
    await attendreChamp(
      `web /audio : ${champ} bascule par clic`,
      () => api('/api/orgue'),
      (e) => (e.qualite[champ] === true) === !avant
    );
  }

  for (const valeur of [0, 1, 2]) {
    await clicGroupe('qualite-spatialisation', String(valeur));
    await attendreChamp(
      `web /audio : spatialisation ${valeur} par clic`,
      () => api('/api/orgue'),
      (e) => e.qualite.spatialisation === valeur
    );
  }

  const reverbAvant = (await api('/api/orgue')).reverb;
  const cibleReverb = reverbAvant > 0.5 ? 0.2 : 0.8;
  await clic('document.getElementById("reverb")', cibleReverb);
  await attendreChamp(
    'web /audio : réverbération par clic sur le curseur',
    () => api('/api/orgue'),
    (e) => Math.abs(e.reverb - reverbAvant) > 0.05
  );
  const remplissageReverb = await evaluer(`(() => {
    const e = document.getElementById('reverb');
    const min = Number(e.min), max = Number(e.max), v = Number(e.value);
    return { attendu: (v - min) / (max - min) * 100,
             vu: parseFloat(e.style.getPropertyValue('--fill')) };
  })()`);
  verifie(
    remplissageReverb && Math.abs(remplissageReverb.attendu - remplissageReverb.vu) < 1.5,
    `web /audio : --fill de la réverbération cohérent (${remplissageReverb.vu}% / ${remplissageReverb.attendu.toFixed(1)}%)`
  );

  await clic('document.getElementById("qualite-polyphonie")', 0.3);
  await attendreChamp(
    'web /audio : polyphonie par clic sur le curseur',
    () => api('/api/orgue'),
    (e) => e.qualite.polyphonie_max > 0
  );

  for (const periode of [128, 256, 512, 1024, 2048]) {
    await clicGroupe('qualite-periode', String(periode));
    await attendreChamp(
      `web /audio : période ${periode} par clic`,
      () => api('/api/orgue'),
      (e) => e.qualite.periode_prochain === periode
    );
  }
  await attendreChamp(
    'web /audio : période 2048 effective',
    () => api('/api/orgue'),
    (e) => e.qualite.periode === 2048
  );

  await clicGroupe('qualite-taux', '44100');
  await attendreChamp(
    'web /audio : taux 44100 par clic',
    () => api('/api/orgue'),
    (e) => e.qualite.taux === 44100 && e.qualite.application === false,
    25000
  );
  await clicGroupe('qualite-taux', '48000');
  await attendreChamp(
    'web /audio : retour au taux 48000 par clic',
    () => api('/api/orgue'),
    (e) => e.qualite.taux === 48000 && e.qualite.application === false,
    25000
  );

  const limiteurAvant = (await api('/api/orgue')).qualite.limiteur;
  await clic('document.getElementById("qualite-limiteur")');
  await attendreChamp(
    'web /audio : limiteur bascule par clic',
    () => api('/api/orgue'),
    (e) => e.qualite.limiteur !== limiteurAvant
  );

  const teteAvant = (await api('/api/orgue')).qualite.tete_reverb_prochain;
  await clic('document.getElementById("qualite-tete")');
  await attendreChamp(
    'web /audio : tête de réverbération bascule par clic',
    () => api('/api/orgue'),
    (e) => e.qualite.tete_reverb_prochain !== teteAvant
  );

  let applicationVue = false;
  for (let temperament = 0; temperament <= 10; temperament += 1) {
    const avant = (await api('/api/orgue')).temperament;
    await clicGroupe('qualite-temperament', String(temperament));
    const debut = Date.now();
    let applique = false;
    while (Date.now() - debut < 12000) {
      const texte = await evaluer('document.getElementById("qualite-message").textContent');
      if (texte.includes('Application')) applicationVue = true;
      const etat = await api('/api/orgue');
      if (etat.temperament === temperament && etat.qualite.application === false) {
        applique = true;
        break;
      }
      await delay(80);
    }
    verifie(applique, `web /audio : tempérament ${temperament} appliqué par clic (avant ${avant})`);
  }
  verifie(applicationVue, 'web /audio : « Application… » apparaît pendant un changement de tempérament');

  await testTemperamentRafale();

  let messageFinal = '';
  for (let i = 0; i < 60; i += 1) {
    messageFinal = await evaluer('document.getElementById("qualite-message").textContent');
    if (!messageFinal.includes('Application')) break;
    await delay(50);
  }
  verifie(!messageFinal.includes('Application'), 'web /audio : « Application… » a disparu après application');
}

async function testResponsive() {
  for (const chemin of ['/', '/midi', '/audio']) {
    for (const largeur of [420, 1100]) {
      await viewport(largeur);
      await navigate(chemin);
      const mesure = await evaluer(`(() => {
        const d = document.documentElement;
        const debord = Math.max(d.scrollWidth, document.body.scrollWidth) - d.clientWidth;
        const petits = [];
        if (${JSON.stringify(chemin)} === '/audio') {
          for (const e of document.querySelectorAll('.qualite-segment, .qualite-bascule')) {
            if (e.offsetParent === null) continue;
            const h = e.getBoundingClientRect().height;
            if (h < 44) petits.push((e.id || e.textContent.trim()) + '=' + h.toFixed(1));
          }
        }
        function remplissage(id) {
          const e = document.getElementById(id);
          if (!e) return null;
          const min = Number(e.min), max = Number(e.max), v = Number(e.value);
          return { attendu: (v - min) / (max - min) * 100,
                   vu: parseFloat(e.style.getPropertyValue('--fill')) };
        }
        return {
          debord,
          petits,
          remplissages: ${JSON.stringify(chemin)} === '/audio'
            ? [remplissage('reverb'), remplissage('qualite-polyphonie')]
            : (${JSON.stringify(chemin)} === '/' ? [remplissage('volume'), remplissage('volume-pedale')] : [])
        };
      })()`);
      verifie(mesure.debord <= 1, `web ${chemin} à ${largeur} px : aucun débordement horizontal (${mesure.debord} px)`);
      if (chemin === '/audio') {
        verifie(
          mesure.petits.length === 0,
          `web /audio à ${largeur} px : cibles tactiles ≥ 44 px (${mesure.petits.join(', ') || 'toutes'})`
        );
      }
      for (const [index, m] of (mesure.remplissages || []).entries()) {
        verifie(
          m && Math.abs(m.attendu - m.vu) < 1.5,
          `web ${chemin} à ${largeur} px : --fill cohérent (curseur ${index})`
        );
      }
    }
  }
}

async function modeFill() {
  await viewport(1100);
  await poster('/api/orgue', { reverb: 110 });
  await delay(300);
  await navigate('/audio');
  await attendre(() => evaluer('document.getElementById("reverb") !== null'), 'page /audio affichée (mutation)');
  await delay(600);
  const m = await evaluer(`(() => {
    const e = document.getElementById('reverb');
    const min = Number(e.min), max = Number(e.max), v = Number(e.value);
    return { valeur: v,
             attendu: (v - min) / (max - min) * 100,
             vu: parseFloat(e.style.getPropertyValue('--fill')) };
  })()`);
  if (Math.abs(m.attendu - m.vu) < 1.5) {
    console.log(`ÉCHEC : la mutation --fill n'a pas été détectée (valeur ${m.valeur}, --fill ${m.vu}%, attendu ${m.attendu.toFixed(1)}%)`);
    return 1;
  }
  ok(`mutation --fill détectée (valeur ${m.valeur}, --fill ${m.vu}%, attendu ${m.attendu.toFixed(1)}%)`);
  return 0;
}

async function principal() {
  cdp = await connecter();
  if (MODE === 'fill') return modeFill();

  await testAccueil();
  await testMidi();
  await testAudio();
  await testResponsive();

  verifie(cdp.erreurs.length === 0, `web : aucune erreur console (${cdp.erreurs.length})`);
  for (const erreur of cdp.erreurs.slice(0, 5)) console.log(`        ${erreur}`);
  return echecs === 0 ? 0 : 1;
}

principal().then((code) => {
  console.log(`== e2e web : ${total} contrôle(s), ${echecs} échec(s)`);
  process.exit(code);
}).catch((erreur) => {
  console.error(`ÉCHEC : pilote web : ${erreur && erreur.stack ? erreur.stack : erreur}`);
  process.exit(1);
});
