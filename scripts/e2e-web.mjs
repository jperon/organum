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

import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

const CDP_PORT = process.env.CDP_PORT;
const BASE = process.env.BASE_URL;
const MODE = process.env.MODE || 'full';
const WID = process.env.WID;
const CAPTURES = process.env.CAPTURES;

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
          const ou = entree.url ? ` (${entree.url})` : '';
          this.erreurs.push(`${entree.source || 'log'} : ${entree.text || ''}${ou}`);
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

// Un état relu peut déplacer les rangées entre la mesure du rectangle et
// l'envoi des événements : un clic parti aux anciennes coordonnées tombe à
// côté, sans aucune erreur. Vérifier la cible sous le point, et remesurer si
// le document a bougé.
async function cibleSousPoint(expression, x, y) {
  return evaluer(`(() => {
    const c = document.elementFromPoint(${x}, ${y});
    const t = (${expression});
    return !!(c && t && (c === t || t.contains(c)));
  })()`);
}

async function clic(expression, fx = 0.5, fy = 0.5) {
  for (let essai = 0; essai < 3; essai += 1) {
    const r = await rect(expression);
    if (!r) {
      echec(`élément introuvable : ${expression}`);
      return false;
    }
    const x = r.x + r.w * fx;
    const y = r.y + r.h * fy;
    if (!(await cibleSousPoint(expression, x, y))) {
      if (essai === 0) console.log(`        clic recalé : ${expression}`);
      await delay(80);
      continue;
    }
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
  echec(`élément non cliquable (une autre cible reçoit le clic) : ${expression}`);
  return false;
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

  // Transposition globale : boutons réels, valeur relue dans l'API, accent
  // et bornes. Un POST doit aussi se refléter dans le DOM (autre interface).
  verifie(
    await evaluer('document.querySelector(".transposition") !== null'),
    'web / : commande de transposition affichée'
  );
  await poster('/api/orgue', { transposition: 0 });
  await attendre(
    async () => (await api('/api/orgue')).transposition === 0,
    'web / : transposition remise à 0 avant le test'
  );
  await clic('document.querySelector(".transposition-plus")');
  const plusUn = await attendre(
    async () => {
      const e = await api('/api/orgue');
      const texte = await evaluer('document.querySelector(".transposition-valeur").textContent');
      const actif = await evaluer('document.querySelector(".transposition").classList.contains("active")');
      return (e.transposition === 1 && texte === '+1' && actif) ? e : null;
    },
    'web / : + transposite de +1, valeur « +1 » et accent visibles'
  );
  verifie(!!plusUn, 'web / : + transposite de +1 avec mise en évidence');
  await clic('document.querySelector(".transposition-moins")');
  const retourZero = await attendre(
    async () => {
      const e = await api('/api/orgue');
      const actif = await evaluer('document.querySelector(".transposition").classList.contains("active")');
      return (e.transposition === 0 && !actif) ? e : null;
    },
    'web / : − ramène à 0 et retire l’accent'
  );
  verifie(!!retourZero, 'web / : retour à 0 par clic');
  await poster('/api/orgue', { transposition: -2 });
  const venuApi = await attendre(
    async () => {
      const texte = await evaluer('document.querySelector(".transposition-valeur").textContent');
      return texte === '\u22122' ? texte : null;
    },
    'web / : valeur -2 venue de l’API affichée dans la page'
  );
  verifie(!!venuApi, 'web / : changement d’une autre interface reflété (valeur −2)');
  await poster('/api/orgue', { transposition: 12 });
  await attendre(async () => (await api('/api/orgue')).transposition === 12,
    'web / : borne +12 posée par l’API');
  const plusDesactive = await evaluer('document.querySelector(".transposition-plus").disabled === true');
  verifie(plusDesactive, 'web / : + inactif à la borne +12');
  await poster('/api/orgue', { transposition: 0 });
  await attendre(async () => (await api('/api/orgue')).transposition === 0,
    'web / : transposition remise à 0 après le test');

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

async function etatLimiteurDom() {
  return evaluer(`(() => {
    const b = document.getElementById('qualite-limiteur');
    const n = document.getElementById('qualite-limiteur-note');
    if (!b) return null;
    return {
      pressed: b.getAttribute('aria-pressed'),
      disabled: b.disabled === true,
      note: n && !n.hidden ? n.textContent : ''
    };
  })()`);
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
  const cibleA = await attendre(
    async () => {
      const e = await api('/api/orgue');
      return e.qualite.temperament_cible === a ? e : null;
    },
    `web /audio : la cible ${a} est publiée dans l’état partagé`,
    5000
  );
  verifie(!!cibleA, `web /audio : état partagé porte la cible ${a} pendant le calcul`);
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
      return (e.temperament === b && e.qualite.temperament_cible === -1) ? e : null;
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

async function testTemperamentRechargement() {
  const depart = (await api('/api/orgue')).temperament;
  const cible = (depart + 5) % 11;
  await clicGroupe('qualite-temperament', String(cible));
  const publiee = await attendre(
    async () => {
      const e = await api('/api/orgue');
      return e.qualite.temperament_cible === cible ? e : null;
    },
    `web /audio : cible ${cible} publiée côté serveur avant rechargement`,
    5000
  );
  if (!publiee) return;
  await navigate('/audio');
  const dom = await etatTemperamentDom();
  verifie(
    dom && dom.enCours.includes(cible),
    `web /audio : rechargement en plein calcul conserve la cible ${cible} (« ${dom && dom.enCours} »)`
  );
  verifie(
    dom && dom.statut.includes('Application'),
    'web /audio : rechargement en plein calcul affiche « Application… » dans la rangée'
  );
  const fin = await attendre(
    async () => {
      const e = await api('/api/orgue');
      return (e.temperament === cible && e.qualite.temperament_cible === -1) ? e : null;
    },
    `web /audio : la cible ${cible} aboutit après rechargement`,
    30000
  );
  if (fin) {
    const final = await attendre(
      async () => {
        const d = await etatTemperamentDom();
        return (d && d.enCours.length === 0 && d.statut === '' && d.actifs.includes(cible)) ? d : null;
      },
      `web /audio : état final après rechargement, tempérament ${cible} actif`,
      5000
    );
    verifie(!!final, `web /audio : la cible ${cible} devient active après rechargement`);
  }
}

async function testTemperamentPost() {
  const depart = (await api('/api/orgue')).temperament;
  const cible = (depart + 2) % 11;
  const reponse = await poster('/api/orgue', { temperament: cible });
  verifie(reponse.code === 200, `web /audio : POST tempérament ${cible} accepté`);
  const dom = await attendre(
    async () => {
      const d = await etatTemperamentDom();
      return d && (d.enCours.includes(cible) || d.actifs.includes(cible)) ? d : null;
    },
    `web /audio : changement par POST vu dans la rangée Tempérament (${cible})`,
    5000
  );
  if (dom) {
    verifie(dom.statut.includes('Application'),
      'web /audio : le POST affiche aussi « Application… » dans la rangée');
  }
  await attendre(
    async () => {
      const e = await api('/api/orgue');
      return (e.temperament === cible && e.qualite.temperament_cible === -1) ? e : null;
    },
    `web /audio : tempérament ${cible} appliqué après POST`,
    30000
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

  const avantLimiteur = await api('/api/orgue');
  const limiteurAvant = avantLimiteur.qualite.limiteur;
  const domLimiteurAvant = await etatLimiteurDom();
  await clic('document.getElementById("qualite-limiteur")');
  const basculeLimiteur = await attendreChamp(
    'web /audio : limiteur bascule par clic',
    () => api('/api/orgue'),
    (e) => e.qualite.limiteur !== limiteurAvant
  );
  if (!basculeLimiteur) {
    const apresLimiteur = await api('/api/orgue');
    const domLimiteurApres = await etatLimiteurDom();
    console.log('        diagnostic limiteur : ' + JSON.stringify({
      avant: {
        limiteur: avantLimiteur.qualite.limiteur,
        limiteur_prochain: avantLimiteur.qualite.limiteur_prochain,
        dom: domLimiteurAvant
      },
      apres: {
        limiteur: apresLimiteur.qualite.limiteur,
        limiteur_prochain: apresLimiteur.qualite.limiteur_prochain,
        seq: apresLimiteur.seq,
        dom: domLimiteurApres
      }
    }));
  }

  const teteAvant = (await api('/api/orgue')).qualite.tete_reverb_prochain;
  await clic('document.getElementById("qualite-tete")');
  await attendreChamp(
    'web /audio : tête de réverbération bascule par clic',
    () => api('/api/orgue'),
    (e) => e.qualite.tete_reverb_prochain !== teteAvant
  );

  let cibleVueRangée = false;
  let applicationEnBas = false;
  for (let temperament = 0; temperament <= 10; temperament += 1) {
    const avant = (await api('/api/orgue')).temperament;
    await clicGroupe('qualite-temperament', String(temperament));
    const debut = Date.now();
    let applique = false;
    while (Date.now() - debut < 12000) {
      const dom = await etatTemperamentDom();
      if (dom && dom.statut.includes('Application')) cibleVueRangée = true;
      const texte = await evaluer('document.getElementById("qualite-message").textContent');
      if (texte.includes('Application')) applicationEnBas = true;
      const etat = await api('/api/orgue');
      if (etat.temperament === temperament &&
          etat.qualite.temperament_cible === -1) {
        applique = true;
        break;
      }
      await delay(80);
    }
    verifie(applique, `web /audio : tempérament ${temperament} appliqué par clic (avant ${avant})`);
  }
  verifie(cibleVueRangée, 'web /audio : la cible en cours s’affiche dans la rangée Tempérament');
  verifie(!applicationEnBas,
    'web /audio : aucun « Application… » en bas pour un changement de tempérament');

  await testTemperamentRafale();
  await testTemperamentRechargement();
  await testTemperamentPost();

  let messageFinal = '';
  for (let i = 0; i < 60; i += 1) {
    messageFinal = await evaluer('document.getElementById("qualite-message").textContent');
    if (!messageFinal.includes('Application')) break;
    await delay(50);
  }
  verifie(!messageFinal.includes('Application'), 'web /audio : « Application… » a disparu après application');
}

async function testReseaux() {
  await viewport(1100);
  await navigate('/audio');
  await attendre(() => evaluer('document.getElementById("reseaux-entrees") !== null'), 'page /audio : section Réseaux');

  // Repart d'une liste vide, puis une rangée par sous-réseau avec commentaire.
  await poster('/api/reseaux', { reseaux: [] });
  await delay(300);
  await clic('document.getElementById("reseaux-ajouter")');
  await clic('document.getElementById("reseaux-ajouter")');
  await evaluer(`(() => {
    const lignes = document.querySelectorAll('#reseaux-entrees .reseau-entree');
    lignes[0].querySelector('.reseau-sous-reseau').value = '127.0.0.1/32';
    lignes[0].querySelector('.reseau-commentaire').value = '<script>window.__pwned = 1<\/script>';
    lignes[1].querySelector('.reseau-sous-reseau').value = '10.35.0.0/16';
    lignes[1].querySelector('.reseau-commentaire').value = 'chapelle';
    return lignes.length;
  })()`);
  await clic('document.getElementById("reseaux-enregistrer")');
  const enregistre = await attendre(async () => {
    const r = await api('/api/reseaux');
    const entrees = r.reseaux || [];
    if (entrees.length !== 2) return null;
    if (!entrees.some((e) => e.reseau === '10.35.0.0/16' && e.commentaire === 'chapelle')) return null;
    return r;
  }, 'web /audio : deux sous-réseaux avec commentaires enregistrés');
  verifie(!!enregistre, 'web /audio : deux sous-réseaux avec commentaires enregistrés');

  await navigate('/audio');
  await attendre(async () => {
    const lignes = await evaluer('document.querySelectorAll("#reseaux-entrees .reseau-entree").length');
    return lignes === 2 ? lignes : null;
  }, 'web /audio : une rangée par sous-réseau après rechargement');
  const commentaireScript = await evaluer(
    'document.querySelectorAll("#reseaux-entrees .reseau-commentaire")[0].value');
  verifie(commentaireScript === '<script>window.__pwned = 1<\/script>',
    'web /audio : commentaire <script> conservé comme valeur, pas exécuté');
  const execute = await evaluer('typeof window.__pwned');
  verifie(execute === 'undefined', 'web /audio : commentaire <script> non exécuté');
  const scripts = await evaluer(
    'Array.from(document.querySelectorAll("script")).filter((e) => (e.textContent || "").includes("__pwned")).length');
  verifie(scripts === 0, 'web /audio : aucun <script> injecté dans le document');

  // Retrait d'une rangée puis enregistrement : une seule entrée restante.
  await clic('document.querySelector("#reseaux-entrees .reseau-retirer")');
  const restantes = await evaluer('document.querySelectorAll("#reseaux-entrees .reseau-entree").length');
  verifie(restantes === 1, 'web /audio : bouton Retirer enlève la rangée');
  await clic('document.getElementById("reseaux-enregistrer")');
  const apres = await attendre(async () => {
    const r = await api('/api/reseaux');
    return (r.reseaux || []).length === 1 ? r : null;
  }, 'web /audio : retrait enregistré');
  verifie(!!apres, 'web /audio : retrait enregistré');

  // Remet la liste vide pour ne pas gêner la suite (source locale exemptée).
  await poster('/api/reseaux', { reseaux: [] });
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
          for (const e of document.querySelectorAll('.qualite-segment, .qualite-bascule, .qualite input[type=\"text\"]')) {
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
        const petitsTrans = [];
        if (${JSON.stringify(chemin)} === '/') {
          for (const e of document.querySelectorAll('.transposition .btn')) {
            if (e.offsetParent === null) continue;
            const r = e.getBoundingClientRect();
            if (r.height < 44 || r.width < 44) {
              petitsTrans.push((e.className || 'bouton') + '=' + r.width.toFixed(0) + 'x' + r.height.toFixed(0));
            }
          }
        }
        return {
          debord,
          petits,
          petitsTrans,
          remplissages: ${JSON.stringify(chemin)} === '/audio'
            ? [remplissage('reverb'), remplissage('qualite-polyphonie')]
            : (${JSON.stringify(chemin)} === '/' ? [remplissage('volume'), remplissage('volume-pedale')] : [])
        };
      })()`);
      verifie(mesure.debord <= 1, `web ${chemin} à ${largeur} px : aucun débordement horizontal (${mesure.debord} px)`);
      if (chemin === '/') {
        verifie(
          mesure.petitsTrans.length === 0,
          `web / à ${largeur} px : cibles de transposition ≥ 44 px (${mesure.petitsTrans.join(', ') || 'toutes'})`
        );
      }
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

function capturerNatif(nom) {
  const fichier = `${CAPTURES}/${nom}.png`;
  execFileSync('import', ['-display', process.env.DISPLAY, '-window', WID, fichier]);
  return createHash('md5').update(readFileSync(fichier)).digest('hex');
}

function clicNatif(x, y) {
  // Pressions séparées, comme le harnais bash : sans gestionnaire de
  // fenêtres, Nuklear ne lit parfois qu'un survol sur un clic instantané.
  execFileSync('xdotool', ['mousemove', '--window', WID, String(x), String(y)]);
  execFileSync('sleep', ['0.08']);
  execFileSync('xdotool', ['mousedown', '1']);
  execFileSync('sleep', ['0.15']);
  execFileSync('xdotool', ['mouseup', '1']);
  execFileSync('sleep', ['0.4']);
}

async function attendreCible(cible, nom, delai = 5000) {
  return attendre(
    async () => {
      const e = await api('/api/orgue');
      return e.qualite.temperament_cible === cible ? e : null;
    },
    nom,
    delai
  );
}

async function attendreApplique(cible, nom, delai = 30000) {
  return attendre(
    async () => {
      const e = await api('/api/orgue');
      return (e.temperament === cible && e.qualite.temperament_cible === -1) ? e : null;
    },
    nom,
    delai
  );
}

async function modeCroise() {
  await viewport(1100);
  await navigate('/audio');
  await attendre(
    () => evaluer('document.getElementById("qualite-temperament") !== null'),
    'page /audio affichée (croisé)'
  );

  // 1. Clic web vu côté natif : la cible partagée change l'affichage natif.
  let depart = (await api('/api/orgue')).temperament;
  let cible = (depart + 3) % 11;
  const avantWeb = capturerNatif('croise-web-natif-avant');
  await clicGroupe('qualite-temperament', String(cible));
  const publiee = await attendreCible(
    cible, `croisé : cible ${cible} publiée après clic web`, 5000
  );
  verifie(!!publiee, `croisé : clic web publie la cible ${cible}`);
  await delay(350);
  const apresWeb = capturerNatif('croise-web-natif-apres');
  verifie(
    avantWeb !== apresWeb,
    'croisé : un clic web sur le tempérament change l’affichage de la fenêtre native'
  );
  const domWeb = await attendre(
    async () => {
      const d = await etatTemperamentDom();
      return d && (d.enCours.includes(cible) || d.actifs.includes(cible)) ? d : null;
    },
    `croisé : la page web montre la cible ${cible} (en cours ou appliquée)`,
    5000
  );
  verifie(!!domWeb, `croisé : la page web reflète le clic web (cible ${cible})`);
  await attendreApplique(cible, `croisé : cible ${cible} appliquée après clic web`);

  // 2. Clic natif vu côté web.
  depart = (await api('/api/orgue')).temperament;
  const cibleNatif = depart === 1 ? 3 : 1;
  const xn = String(cibleNatif === 1 ? process.env.TEMP1_X : process.env.TEMP3_X);
  const yn = String(cibleNatif === 1 ? process.env.TEMP1_Y : process.env.TEMP3_Y);
  clicNatif(Number(xn), Number(yn));
  const publieeNatif = await attendreCible(
    cibleNatif, `croisé : cible ${cibleNatif} publiée après clic natif`, 5000
  );
  verifie(!!publieeNatif, `croisé : clic natif publie la cible ${cibleNatif}`);
  const domNatif = await attendre(
    async () => {
      const d = await etatTemperamentDom();
      return d && (d.enCours.includes(cibleNatif) || d.actifs.includes(cibleNatif)) ? d : null;
    },
    `croisé : clic natif vu dans la page web (cible ${cibleNatif})`,
    5000
  );
  verifie(!!domNatif, `croisé : la page web reflète le clic natif (cible ${cibleNatif})`);
  await attendreApplique(cibleNatif, `croisé : cible ${cibleNatif} appliquée après clic natif`);

  // 3. Changement par POST vu des deux côtés.
  depart = (await api('/api/orgue')).temperament;
  cible = (depart + 4) % 11;
  const avantPost = capturerNatif('croise-post-natif-avant');
  const reponse = await poster('/api/orgue', { temperament: cible });
  verifie(reponse.code === 200, `croisé : POST tempérament ${cible} accepté`);
  const publieePost = await attendreCible(
    cible, `croisé : cible ${cible} publiée après POST`, 5000
  );
  verifie(!!publieePost, `croisé : POST publie la cible ${cible}`);
  await delay(350);
  const apresPost = capturerNatif('croise-post-natif-apres');
  verifie(
    avantPost !== apresPost,
    'croisé : un POST de tempérament change l’affichage de la fenêtre native'
  );
  const domPost = await attendre(
    async () => {
      const d = await etatTemperamentDom();
      return d && (d.enCours.includes(cible) || d.actifs.includes(cible)) ? d : null;
    },
    `croisé : POST vu dans la page web (cible ${cible})`,
    5000
  );
  verifie(!!domPost, `croisé : la page web reflète le POST (cible ${cible})`);
  await attendreApplique(cible, `croisé : cible ${cible} appliquée après POST`);

  // 4. Transposition croisée : natif de retour sur la console, web sur /.
  clicNatif(Number(process.env.RETOUR_X), Number(process.env.RETOUR_Y));
  await delay(400);
  await navigate('/');
  await attendre(
    () => evaluer('document.querySelector(".transposition") !== null'),
    'page / affichée (transposition croisée)'
  );
  await poster('/api/orgue', { transposition: 0 });
  await attendre(async () => (await api('/api/orgue')).transposition === 0,
    'croisé : transposition remise à 0');

  const avantTrans = capturerNatif('croise-trans-avant');
  await clic('document.querySelector(".transposition-plus")');
  const transWeb = await attendre(
    async () => (await api('/api/orgue')).transposition === 1,
    'croisé : clic web + transposite et publie +1', 5000
  );
  verifie(!!transWeb, 'croisé : clic web + publié dans /api/orgue');
  await delay(350);
  const apresTrans = capturerNatif('croise-trans-apres');
  verifie(
    avantTrans !== apresTrans,
    'croisé : le clic web sur la transposition change l’affichage natif'
  );

  clicNatif(Number(process.env.TRANS_PLUS_X), Number(process.env.TRANS_PLUS_Y));
  const transNatif = await attendre(
    async () => (await api('/api/orgue')).transposition === 2,
    'croisé : clic natif + transposite et publie +2', 5000
  );
  verifie(!!transNatif, 'croisé : clic natif + publié dans /api/orgue');
  const domTrans = await attendre(
    async () => {
      const texte = await evaluer('document.querySelector(".transposition-valeur").textContent');
      const actif = await evaluer('document.querySelector(".transposition").classList.contains("active")');
      return (texte === '+2' && actif) ? texte : null;
    },
    'croisé : la page web reflète le clic natif (+2 accentué)', 5000
  );
  verifie(!!domTrans, 'croisé : valeur +2 venue du natif affichée et accentuée');
  await poster('/api/orgue', { transposition: 0 });
  await attendre(async () => (await api('/api/orgue')).transposition === 0,
    'croisé : transposition remise à 0 après le test');

  // Le serveur du croisé tourne avec ORGANUM_VOLUME=aucun (la fenêtre native
  // ne doit pas toucher au volume système) : la page / reçoit alors un 500
  // attendu de /api/volume. On ne tolère que celui-là ; toute autre erreur
  // console fait échouer le croisé.
  const erreursInattendues = cdp.erreurs.filter(
    (e) => !(e.includes('500') && e.includes('/api/volume'))
  );
  verifie(
    erreursInattendues.length === 0,
    `croisé : aucune erreur console hors volume système désactivé (${erreursInattendues.length})`
  );
  for (const erreur of erreursInattendues.slice(0, 5)) console.log(`        ${erreur}`);
  return echecs === 0 ? 0 : 1;
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
  if (MODE === 'croise') return modeCroise();
  if (MODE === 'fill') return modeFill();

  await testAccueil();
  await testMidi();
  await testAudio();
  await testReseaux();
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
