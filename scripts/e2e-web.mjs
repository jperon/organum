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

// Glissement vertical relatif : la colonne (curseur général ou de gain)
// reçoit le pointeur ; le déplacement de la fraction demandée de la course
// ajuste la valeur depuis la valeur courante (haut = plus fort, donc une
// fraction négative baisse). Aucun saut au point cliqué.
async function glisserVertical(expression, fraction) {
  const r = await rect(expression);
  if (!r) {
    echec(`colonne de curseur introuvable : ${expression}`);
    return false;
  }
  const x = r.x + r.w / 2;
  const y = r.y + r.h / 2;
  if (!(await cibleSousPoint(expression, x, y))) {
    echec(`colonne de curseur non cliquable : ${expression}`);
    return false;
  }
  const course = r.h - 24;
  // fraction positive : vers le haut (valeur qui monte) ; négative : vers le bas.
  const arrivee = Math.round(Math.max(r.y + 2, Math.min(r.y + r.h - 2, y - fraction * course)));
  await cdp.envoyer('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  await cdp.envoyer('Input.dispatchMouseEvent', {
    type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1
  });
  await delay(60);
  for (let pas = 1; pas <= 4; pas += 1) {
    await cdp.envoyer('Input.dispatchMouseEvent', {
      type: 'mouseMoved', x, y: y + (arrivee - y) * pas / 4, button: 'left', buttons: 1
    });
    await delay(50);
  }
  // Le dernier mouvement doit être traité avant le relâchement : sinon le
  // client envoie la valeur de l'avant-dernier pas (glissement à moitié).
  await delay(120);
  await cdp.envoyer('Input.dispatchMouseEvent', {
    type: 'mouseReleased', x, y: arrivee, button: 'left', buttons: 0, clickCount: 1
  });
  await delay(300);
  return true;
}

// Glissement horizontal relatif (bandeau compact des écrans étroits) : la
// ligne reçoit le pointeur ; vers la droite, la valeur monte. Même contrat
// que glisserVertical (aucun saut au point cliqué).
async function glisserHorizontal(expression, fraction) {
  const r = await rect(expression);
  if (!r) {
    echec(`ligne de curseur introuvable : ${expression}`);
    return false;
  }
  const x = r.x + r.w / 2;
  const y = r.y + r.h / 2;
  if (!(await cibleSousPoint(expression, x, y))) {
    echec(`ligne de curseur non cliquable : ${expression}`);
    return false;
  }
  const course = r.w - 24;
  const arrivee = Math.round(Math.max(r.x + 2, Math.min(r.x + r.w - 2, x + fraction * course)));
  await cdp.envoyer('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  await cdp.envoyer('Input.dispatchMouseEvent', {
    type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1
  });
  await delay(60);
  for (let pas = 1; pas <= 4; pas += 1) {
    await cdp.envoyer('Input.dispatchMouseEvent', {
      type: 'mouseMoved', x: x + (arrivee - x) * pas / 4, y, button: 'left', buttons: 1
    });
    await delay(50);
  }
  await delay(120);
  await cdp.envoyer('Input.dispatchMouseEvent', {
    type: 'mouseReleased', x: arrivee, y, button: 'left', buttons: 0, clickCount: 1
  });
  await delay(300);
  return true;
}

// Molette sur une colonne de curseur : un cran = ±1 pas (haut = plus fort).
async function molette(expression, crans) {
  const r = await rect(expression);
  if (!r) {
    echec(`colonne de curseur introuvable (molette) : ${expression}`);
    return false;
  }
  const x = r.x + r.w / 2;
  const y = r.y + r.h / 2;
  await cdp.envoyer('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  for (let i = 0; i < Math.abs(crans); i += 1) {
    await cdp.envoyer('Input.dispatchMouseEvent', {
      type: 'mouseWheel', x, y, deltaX: 0, deltaY: crans > 0 ? -100 : 100
    });
    await delay(90);
  }
  await delay(250);
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

  // Curseurs généraux verticaux, dans le bandeau de gauche : un appui seul
  // ne change rien (saisie relative), le glissement ajuste la valeur depuis
  // la valeur courante ; la valeur est relue dans l'API.
  await poster('/api/volume', { volume: 50, muted: false });
  await attendre(async () => (await api('/api/volume')).volume === 50,
    'web / : volume système remis à 50 avant le glissement');
  const avantVolume = (await api('/api/volume')).volume;
  await glisserVertical('document.querySelector(".curseur-general")', -0.2);
  const glisseVolume = await attendre(
    async () => {
      const etat = await api('/api/volume');
      return Math.abs(etat.volume - (avantVolume - 20)) <= 6 ? etat.volume : null;
    },
    'web / : curseur de volume système, glissement de −20 % (≈ 30 %)'
  );
  verifie(!!glisseVolume, `web / : curseur de volume système glissé, valeur relue (${glisseVolume || '?'} %)`);
  await poster('/api/orgue', { volume: 0.5 });
  await attendre(async () => Math.abs((await api('/api/orgue')).volume - 0.5) < 0.02,
    'web / : pédale remise à 50 avant le glissement');
  const avantPedale = (await api('/api/orgue')).volume;
  await glisserVertical('document.querySelector(".pedale-general")', 0.2);
  const glissePedale = await attendre(
    async () => {
      const etat = await api('/api/orgue');
      return Math.abs(etat.volume - (avantPedale + 0.2)) <= 0.06 ? Math.round(etat.volume * 100) : null;
    },
    'web / : curseur de pédale, glissement de +20 % (≈ 70 %)'
  );
  verifie(!!glissePedale, `web / : curseur de pédale glissé, valeur relue (${glissePedale || '?'} %)`);
  // Un appui simple, sans déplacement, ne doit pas faire sauter la valeur.
  const avantAppui = (await api('/api/orgue')).volume;
  await clic('document.querySelector(".pedale-general")', 0.5, 0.15);
  await delay(300);
  const apresAppui = (await api('/api/orgue')).volume;
  verifie(Math.abs(apresAppui - avantAppui) < 0.02,
    `web / : un appui dans la colonne ne change pas la valeur (${avantAppui.toFixed(2)} → ${apresAppui.toFixed(2)})`);

  // Molette : un cran = +1 % sur la colonne du curseur (haut = plus fort).
  await poster('/api/orgue', { volume: 0.5 });
  await attendre(async () => Math.abs((await api('/api/orgue')).volume - 0.5) < 0.02,
    'web / : pédale remise à 50 avant la molette');
  await molette('document.querySelector(".pedale-general")', 1);
  const roue = await attendre(async () => {
    const v = (await api('/api/orgue')).volume;
    return v >= 0.5 && v <= 0.52 ? Math.round(v * 100) : null;
  }, 'web / : molette d’un cran sur la pédale (+1 %)');
  verifie(!!roue, `web / : molette d’un cran sur la pédale (${roue || '?'} %)`);

  // Curseur de gain d'un clavier : vertical, à droite des jeux, même saisie
  // relative ; la valeur est relue dans l'API.
  await poster('/api/orgue', { gain: { division: 0, value: 0.5 } });
  await attendre(async () => Math.abs((await api('/api/orgue')).divisions[0].gain - 0.5) < 0.02,
    'web / : gain de la première division remis à 50 avant le glissement');
  const avantGain = (await api('/api/orgue')).divisions[0].gain;
  await glisserVertical('document.querySelectorAll(".gain-colonne")[0]', -0.2);
  const glisseGain = await attendre(
    async () => {
      const etat = await api('/api/orgue');
      const g = etat.divisions[0].gain;
      return Math.abs(g - (avantGain - 0.2)) <= 0.06 ? Math.round(g * 100) : null;
    },
    'web / : curseur de gain d’un clavier, glissement de −20 % (≈ 30 %)'
  );
  verifie(!!glisseGain, `web / : curseur de gain d’un clavier glissé, valeur relue (${glisseGain || '?'} %)`);
  const valeurGain = await evaluer(`(() => {
    const colonne = document.querySelectorAll('.gain-colonne')[0];
    return colonne ? colonne.querySelector('.gain-valeur').textContent.trim() : '';
  })()`);
  verifie(/^3\d\u00a0%$/.test(valeurGain),
    `web / : valeur du curseur de gain affichée en % (${valeurGain})`);
  await poster('/api/orgue', { gain: { division: 0, value: 0.5 } });
  await attendre(async () => Math.abs((await api('/api/orgue')).divisions[0].gain - 0.5) < 0.02,
    'web / : gain de la première division remis à 50 après le test');

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
  await clic('document.querySelector(".transposition-valeur")');
  const retourValeurZero = await attendre(
    async () => {
      const e = await api('/api/orgue');
      const texte = await evaluer('document.querySelector(".transposition-valeur").textContent');
      const actif = await evaluer('document.querySelector(".transposition").classList.contains("active")');
      return (e.transposition === 0 && texte === '0' && !actif) ? e : null;
    },
    'web / : clic sur la valeur remet la transposition à 0'
  );
  verifie(!!retourValeurZero, 'web / : clic sur la valeur ramène à 0 sans accent');
  await clic('document.querySelector(".transposition-valeur")');
  const resteZero = await attendre(
    async () => (await api('/api/orgue')).transposition === 0,
    'web / : un clic sur la valeur à 0 ne change rien'
  );
  verifie(!!resteZero, 'web / : clic sur la valeur à 0 reste à 0');
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
    return { volume: mesure('volume'), pedale: mesure('volume-pedale'),
             piano: mesure('piano-volume') };
  })()`);
  for (const [nom, m] of Object.entries(remplissages)) {
    verifie(
      m && Math.abs(m.attendu - m.vu) < 1.5,
      `web / : --fill cohérent avec le pouce (${nom} ${m ? `${m.vu}% / ${m.attendu.toFixed(1)}%` : 'absent'})`
    );
  }

  // Piano échantillonné : un bouton par clavier, dernier de la rangée basse,
  // qui bascule divisions[d].piano ; le curseur du bandeau règle
  // piano_volume. Tout est absent si le SoundFont n'a pas été chargé.
  const pianoDisponible = (await api('/api/orgue')).piano_disponible === true;
  verifie(pianoDisponible, 'web / : piano échantillonné disponible');
  if (pianoDisponible) {
    const nbBoutons = await evaluer('document.querySelectorAll(".piano-bouton").length');
    verifie(nbBoutons === ndiv, `web / : un bouton Piano par clavier (${nbBoutons}/${ndiv})`);
    const rangs = await evaluer(`(() => {
      const anomalies = [];
      document.querySelectorAll('.division').forEach((section, i) => {
        const bouton = section.querySelector('.piano-bouton');
        if (!bouton) { anomalies.push('absent ' + i); return; }
        const rangee = bouton.parentNode;
        if (rangee.lastElementChild !== bouton) { anomalies.push('pas en dernier ' + i); }
      });
      return anomalies;
    })()`);
    verifie(rangs.length === 0,
      `web / : bouton Piano en dernier sur chaque rangée (${rangs.join(', ') || 'tous'})`);
    const piedBandeau = await evaluer(`(() => {
      const t = document.querySelector('.transposition');
      if (!t) return null;
      return { dansBandeau: !!t.closest('.bandeau'),
               dansBandeauPied: !!t.closest('.bandeau-pied'),
               dansClavier: !!t.closest('.division') };
    })()`);
    verifie(piedBandeau && piedBandeau.dansBandeauPied && !piedBandeau.dansClavier,
      'web / : transposition dans le pied du bandeau, hors des claviers');

    // Clic réel sur le bouton du dernier clavier (le pédalier) : état relu
    // dans l'API et bouton enfoncé (data-state).
    const dp = ndiv - 1;
    const boutonPiano = `document.querySelectorAll('.division')[${dp}].querySelector('.piano-bouton')`;
    await poster('/api/orgue', { piano: { division: dp, actif: false } });
    await attendre(async () => (await api('/api/orgue')).divisions[dp].piano === false,
      'web / : piano du dernier clavier remis à l’arrêt');
    await clic(boutonPiano);
    const pianoActif = await attendre(
      async () => {
        const e = await api('/api/orgue');
        const etat = await evaluer(`${boutonPiano}.getAttribute('data-state')`);
        return (e.divisions[dp].piano === true && etat === 'on') ? e : null;
      },
      'web / : bouton Piano du dernier clavier bascule et s’affiche enfoncé'
    );
    verifie(!!pianoActif,
      `web / : divisions[${dp}].piano vrai après le clic, bouton enfoncé`);
    await clic(boutonPiano);
    await attendre(async () => (await api('/api/orgue')).divisions[dp].piano === false,
      'web / : second clic sur Piano relâche la division');

    // La transposition est un réglage global, dans le bandeau : le clic sur
    // Piano d'un clavier ne la touche pas, et un POST d'une autre interface
    // se reflète dans le bouton.
    const dtrans = 0;
    const transDansBandeau = await evaluer(
      "!!document.querySelector('.bandeau .transposition')");
    verifie(transDansBandeau, 'web / : transposition dans le bandeau, pas dans un clavier');
    {
      await poster('/api/orgue', { transposition: 0 });
      await attendre(async () => (await api('/api/orgue')).transposition === 0,
        'web / : transposition remise à 0 avant le bouton Piano');
      await poster('/api/orgue', { piano: { division: dtrans, actif: false } });
      await attendre(async () => (await api('/api/orgue')).divisions[dtrans].piano === false,
        'web / : piano du clavier remis à l’arrêt');
      await clic(`document.querySelectorAll('.division')[${dtrans}].querySelector('.piano-bouton')`);
      const vu = await attendre(
        async () => {
          const e = await api('/api/orgue');
          return (e.divisions[dtrans].piano === true && e.transposition === 0) ? e : null;
        },
        'web / : Piano du clavier, transposition inchangée'
      );
      verifie(!!vu, `web / : divisions[${dtrans}].piano vrai et transposition à 0`);
      // POST venu d'ailleurs : le bouton suit par l'attente longue.
      await poster('/api/orgue', { piano: { division: dtrans, actif: false } });
      const relache = await attendre(
        async () => {
          const etat = await evaluer(
            `document.querySelectorAll('.division')[${dtrans}].querySelector('.piano-bouton').getAttribute('data-state')`);
          return etat === 'off' ? etat : null;
        },
        'web / : bouton Piano reflète un changement venu de l’API'
      );
      verifie(!!relache, 'web / : bouton Piano relâché par un POST extérieur');
    }

    // Curseur Piano du bandeau : même saisie relative que les autres.
    await poster('/api/orgue', { piano_volume: 0.5 });
    await attendre(async () => Math.abs((await api('/api/orgue')).piano_volume - 0.5) < 0.02,
      'web / : volume du piano remis à 50 avant le glissement');
    const avantPiano = (await api('/api/orgue')).piano_volume;
    await glisserVertical('document.querySelector(".piano-general")', -0.2);
    const glissePiano = await attendre(
      async () => {
        const etat = await api('/api/orgue');
        return Math.abs(etat.piano_volume - (avantPiano - 0.2)) <= 0.06
          ? Math.round(etat.piano_volume * 100) : null;
      },
      'web / : curseur Piano, glissement de −20 % (≈ 30 %)'
    );
    verifie(!!glissePiano,
      `web / : curseur Piano glissé, piano_volume relu (${glissePiano || '?'} %)`);
    const valeurPiano = await evaluer(`(() => {
      const colonne = document.querySelector('.piano-general');
      return colonne ? colonne.querySelector('.value').textContent.trim() : '';
    })()`);
    verifie(/^3\d\u00a0%$/.test(valeurPiano),
      `web / : valeur du curseur Piano affichée en % (${valeurPiano})`);
    await poster('/api/orgue', { piano_volume: 0.6 });
    const pianoVenu = await attendre(
      async () => {
        const e = await api('/api/orgue');
        const valeur = await evaluer(
          'document.getElementById("piano-volume").value');
        return (Math.abs(e.piano_volume - 0.6) < 0.02 && valeur === '60') ? e : null;
      },
      'web / : curseur Piano suit un POST extérieur'
    );
    verifie(!!pianoVenu, 'web / : curseur Piano mis à jour par l’attente longue');
    await poster('/api/orgue', { piano_volume: 0.5 });
  }

  // Remise à zéro des volumes des claviers et du piano : bouton à icône
  // seule sous les curseurs. On dérègle deux gains, le piano et la Pédale,
  // on met aussi le Volume système ailleurs, puis un clic réel doit ramener
  // les gains et le piano aux défauts publiés par le moteur, sans toucher au
  // Volume ni à la Pédale. Les curseurs affichés suivent (attente longue).
  const boutonReset = await evaluer(`(() => {
    const b = document.getElementById('reinitialiser-volumes');
    if (!b) return null;
    const r = b.getBoundingClientRect();
    return { texte: b.textContent.trim(), label: b.getAttribute('aria-label'),
             title: b.getAttribute('title'), w: r.width, h: r.height };
  })()`);
  verifie(boutonReset && boutonReset.texte === '\u21ba',
    `web / : bouton de remise à zéro à icône seule (${boutonReset && boutonReset.texte})`);
  verifie(boutonReset && boutonReset.label === 'Volumes des claviers et du piano par défaut',
    `web / : libellé accessible du bouton de remise à zéro (${boutonReset && boutonReset.label})`);
  verifie(boutonReset && boutonReset.title === 'Volumes des claviers et du piano par défaut',
    `web / : infobulle du bouton de remise à zéro (${boutonReset && boutonReset.title})`);
  verifie(boutonReset && boutonReset.h >= 44 && boutonReset.w >= 44,
    `web / : cible tactile du bouton de remise à zéro (${boutonReset ? `${boutonReset.w.toFixed(0)}x${boutonReset.h.toFixed(0)}` : 'absent'})`);

  const etatDefauts = await api('/api/orgue');
  const gainDefaut = etatDefauts.gain_defaut;
  const pianoDefaut = etatDefauts.piano_volume_defaut;
  verifie(typeof gainDefaut === 'number' && typeof pianoDefaut === 'number',
    `web / : défauts publiés par le moteur (gain ${gainDefaut}, piano ${pianoDefaut})`);
  const dr0 = 0, dr1 = Math.min(ndiv - 1, 1);
  await poster('/api/orgue', { gain: { division: dr0, value: 0.3 } });
  await poster('/api/orgue', { gain: { division: dr1, value: 0.7 } });
  await poster('/api/orgue', { volume: 0.7 });
  await poster('/api/volume', { volume: 70, muted: false });
  if (pianoDisponible) { await poster('/api/orgue', { piano_volume: 0.3 }); }
  const derange = await attendre(
    async () => {
      const e = await api('/api/orgue');
      const v = await api('/api/volume');
      const ok = Math.abs(e.divisions[dr0].gain - 0.3) < 0.03 &&
        Math.abs(e.divisions[dr1].gain - 0.7) < 0.03 &&
        Math.abs(e.volume - 0.7) < 0.03 && Math.abs(v.volume - 70) < 1 &&
        (!pianoDisponible || Math.abs(e.piano_volume - 0.3) < 0.03);
      return ok ? { e, v } : null;
    },
    'web / : gains, piano, Pédale et Volume déréglés avant le clic'
  );
  verifie(!!derange, 'web / : état déréglé relu avant le clic');
  await clic('document.getElementById("reinitialiser-volumes")');
  const remis = await attendre(
    async () => {
      const e = await api('/api/orgue');
      const v = await api('/api/volume');
      const gainsOk = e.divisions.every((d) => Math.abs(d.gain - gainDefaut) < 0.03);
      const pianoOk = !pianoDisponible || Math.abs(e.piano_volume - pianoDefaut) < 0.03;
      const volumeInchange = Math.abs(e.volume - 0.7) < 0.03;
      const systemeInchange = Math.abs(v.volume - 70) < 1;
      if (!(gainsOk && pianoOk && volumeInchange && systemeInchange)) return null;
      const affiches = await evaluer(`(() => {
        const gains = Array.from(document.querySelectorAll('input.gain'))
          .map((g) => Number(g.value));
        const piano = document.getElementById('piano-volume');
        return { gains, piano: piano ? Number(piano.value) : null,
                 pedale: Number(document.getElementById('volume-pedale').value),
                 systeme: Number(document.getElementById('volume').value) };
      })()`);
      const gainsAffiches = affiches.gains.every((v) => Math.abs(v - gainDefaut * 100) <= 1);
      const pianoAffiche = !pianoDisponible ||
        Math.abs(affiches.piano - pianoDefaut * 100) <= 1;
      const pedaleAffichee = Math.abs(affiches.pedale - 70) <= 2;
      const systemeAffiche = Math.abs(affiches.systeme - 70) <= 1;
      return (gainsAffiches && pianoAffiche && pedaleAffichee && systemeAffiche) ? e : null;
    },
    'web / : clic sur la remise à zéro, gains et piano aux défauts, Volume et Pédale inchangés',
    15000
  );
  verifie(!!remis, 'web / : remise à zéro appliquée et curseurs affichés à jour');
  // Remise en ordre pour la suite.
  await poster('/api/volume', { volume: 50, muted: false });
  await poster('/api/orgue', { volume: 0.5 });
  await attendre(async () => Math.abs((await api('/api/orgue')).volume - 0.5) < 0.02,
    'web / : Pédale remise à 50 après le test de remise à zéro');
}

async function testClavier() {
  await viewport(1100);
  await navigate('/');
  await attendre(
    () => evaluer('document.getElementById("clavier-panneau") !== null'),
    'web / : panneau Clavier présent'
  );
  const etatInitial = await evaluer(`(() => {
    const d = document.getElementById('clavier-panneau');
    const s = d && d.querySelector('summary');
    return { ouvert: !!(d && d.open), libelle: s ? s.textContent.trim() : '' };
  })()`);
  verifie(
    etatInitial.ouvert === false && etatInitial.libelle === 'Clavier',
    'web / : panneau Clavier replié par défaut, libellé français'
  );

  await clic('document.querySelector("#clavier-panneau > summary")');
  const ouvert = await attendre(
    async () => (await evaluer('document.getElementById("clavier-panneau").open')) === true,
    'web / : panneau Clavier ouvert par clic sur le résumé'
  );
  verifie(!!ouvert, 'web / : panneau Clavier ouvert par clic');

  const disposition = await evaluer(`(() => {
    const select = document.getElementById('clavier-canal');
    const blancs = document.querySelectorAll('#clavier-panneau .touche-blanche');
    const noirs = document.querySelectorAll('#clavier-panneau .touche-noire');
    return {
      canal: Number(select && select.value),
      blancs: blancs.length,
      noirs: noirs.length,
      premier: blancs.length ? Number(blancs[0].getAttribute('data-note')) : null,
      dernier: blancs.length ? Number(blancs[blancs.length - 1].getAttribute('data-note')) : null
    };
  })()`);
  verifie(disposition.blancs >= 14 && disposition.noirs >= 10,
    `web / : clavier d'au moins deux octaves (${disposition.blancs} blanches, ${disposition.noirs} noires)`);
  verifie(disposition.canal >= 1 && disposition.canal <= 16,
    `web / : canal de division sélectionné (${disposition.canal})`);
  verifie(disposition.dernier - disposition.premier >= 23,
    'web / : deux octaves continues de do à si');

  const touche = 'document.querySelector("#clavier-panneau .touche-blanche")';
  const r = await rect(touche);
  if (!r) return;
  const x = r.x + r.w / 2;
  const y = r.y + r.h * 0.8;
  await cdp.envoyer('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  await cdp.envoyer('Input.dispatchMouseEvent', {
    type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1
  });
  const recue = await attendre(
    async () => {
      const e = await api('/api/midi');
      return (e.canaux_actifs || []).includes(disposition.canal) ? e : null;
    },
    `web / : note du clavier reçue (canal ${disposition.canal} actif)`
  );
  verifie(!!recue, 'web / : une touche enfoncée envoie la note au moteur');

  // Sortie de la touche : le glissando relâche la note sans attendre le
  // relâchement du bouton (piège classique de la note bloquée).
  await cdp.envoyer('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 2, y: 2 });
  await cdp.envoyer('Input.dispatchMouseEvent', {
    type: 'mouseReleased', x: 2, y: 2, button: 'left', buttons: 0, clickCount: 1
  });
  const relachee = await attendre(
    async () => {
      const e = await api('/api/midi');
      return !(e.canaux_actifs || []).includes(disposition.canal) ? e : null;
    },
    'web / : sortie de la touche relâche la note'
  );
  verifie(!!relachee, 'web / : un clic hors de la touche relâche bien la note');

  // Téléphone : panneau ouvert à 420 px, aucune débordement et cibles ≥ 44 px.
  await viewport(420);
  await navigate('/');
  await attendre(
    () => evaluer('document.getElementById("clavier-panneau") !== null'),
    'web / à 420 px : panneau Clavier présent'
  );
  await clic('document.querySelector("#clavier-panneau > summary")');
  await attendre(
    async () => (await evaluer('document.getElementById("clavier-panneau").open')) === true,
    'web / à 420 px : panneau Clavier ouvert'
  );
  const mesure = await evaluer(`(() => {
    const d = document.documentElement;
    const debord = Math.max(d.scrollWidth, document.body.scrollWidth) - d.clientWidth;
    const petits = [];
    for (const e of document.querySelectorAll('#clavier-panneau .touche')) {
      const r = e.getBoundingClientRect();
      if (r.width < 44 || r.height < 44) {
        petits.push((e.getAttribute('aria-label') || 'touche') + '=' + r.width.toFixed(0) + 'x' + r.height.toFixed(0));
      }
    }
    return { debord, petits };
  })()`);
  verifie(mesure.debord <= 1,
    `web / à 420 px, clavier ouvert : aucun débordement horizontal (${mesure.debord} px)`);
  verifie(mesure.petits.length === 0,
    `web / à 420 px : touches ≥ 44 px (${mesure.petits.join(', ') || 'toutes'})`);
}

// Téléphone (420 px) : le bandeau compact place les curseurs généraux à
// l'horizontale ; la saisie relative doit suivre cet axe, et les commandes du
// pied (remise à zéro, transposition) rester opérantes.
async function testEtroit() {
  await viewport(420);
  await navigate('/');
  await attendre(() => evaluer('document.querySelector(".piano-general") !== null'),
    'web / à 420 px : curseur Piano présent');

  await poster('/api/orgue', { piano_volume: 0.6 });
  await attendre(async () => Math.abs((await api('/api/orgue')).piano_volume - 0.6) < 0.02,
    'web / à 420 px : volume du piano remis à 60 avant le glissement');
  const avantPiano = (await api('/api/orgue')).piano_volume;
  await glisserHorizontal('document.querySelector(".piano-general")', -0.25);
  const glisse = await attendre(
    async () => {
      const etat = await api('/api/orgue');
      return Math.abs(etat.piano_volume - (avantPiano - 0.25)) <= 0.07
        ? Math.round(etat.piano_volume * 100) : null;
    },
    'web / à 420 px : curseur Piano horizontal, glissement de −25 %'
  );
  verifie(!!glisse,
    `web / à 420 px : curseur Piano glissé horizontalement, piano_volume relu (${glisse || '?'} %)`);
  const valeurPiano = await evaluer(`(() => {
    const c = document.querySelector('.piano-general .value');
    return c ? c.textContent.trim() : '';
  })()`);
  verifie(/^3\d\u00a0%$/.test(valeurPiano),
    `web / à 420 px : valeur du curseur Piano horizontal affichée (${valeurPiano})`);
  await poster('/api/orgue', { piano_volume: 0.5 });

  // ↺ dans le pied du bandeau : les gains des claviers reviennent au défaut.
  const defaut = (await api('/api/orgue')).gain_defaut;
  await poster('/api/orgue', { gain: { division: 0, value: 0.2 } });
  await attendre(async () => Math.abs((await api('/api/orgue')).divisions[0].gain - 0.2) < 0.02,
    'web / à 420 px : gain du premier clavier réglé à 20 % avant ↺');
  await clic('document.getElementById("reinitialiser-volumes")');
  const remis = await attendre(
    async () => {
      const e = await api('/api/orgue');
      return Math.abs(e.divisions[0].gain - defaut) < 0.02 ? e.divisions[0].gain : null;
    },
    'web / à 420 px : ↺ remet les gains au défaut'
  );
  verifie(remis !== null, `web / à 420 px : ↺ fonctionnel (${remis !== null ? (remis * 100).toFixed(0) : '?'} %)`);

  // Transposition dans le pied : + puis clic sur la valeur.
  await poster('/api/orgue', { transposition: 0 });
  await attendre(async () => (await api('/api/orgue')).transposition === 0,
    'web / à 420 px : transposition remise à 0 avant le test');
  await clic('document.querySelector(".transposition-plus")');
  const plusUn = await attendre(
    async () => {
      const e = await api('/api/orgue');
      const texte = await evaluer('document.querySelector(".transposition-valeur").textContent');
      return (e.transposition === 1 && texte === '+1') ? e : null;
    },
    'web / à 420 px : + transposite de +1'
  );
  verifie(!!plusUn, 'web / à 420 px : transposition +1 relue dans /api/orgue');
  await clic('document.querySelector(".transposition-valeur")');
  const retour = await attendre(
    async () => (await api('/api/orgue')).transposition === 0,
    'web / à 420 px : clic sur la valeur remet la transposition à 0'
  );
  verifie(!!retour, 'web / à 420 px : valeur de transposition cliquable');
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

  for (const periode of [128, 256, 512, 768, 1024, 1536, 2048]) {
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
        const curseurs = [];
        if (${JSON.stringify(chemin)} === '/') {
          for (const s of document.querySelectorAll('.curseur-general, .gain-colonne')) {
            if (s.offsetParent === null) continue;
            const r = s.getBoundingClientRect();
            curseurs.push({ classe: s.className, w: r.width, h: r.height });
          }
        }
        // Curseurs (piste) : orientation et taille, et appartenance au
        // bandeau (vertical plein écran d'un côté, barre compacte de l'autre).
        const ranges = [];
        if (${JSON.stringify(chemin)} === '/') {
          for (const e of document.querySelectorAll('.bandeau input[type="range"], .gain-colonne input[type="range"]')) {
            if (e.offsetParent === null) continue;
            const r = e.getBoundingClientRect();
            ranges.push({ id: e.id || e.className, w: r.width, h: r.height,
                          bandeau: !!e.closest('.bandeau') });
          }
        }
        const stops = [];
        if (${JSON.stringify(chemin)} === '/') {
          for (const e of document.querySelectorAll('.stop')) {
            if (e.offsetParent === null) continue;
            const r = e.getBoundingClientRect();
            // \s doit rester \s dans le code évalué : la chaîne est d'abord
            // un littéral gabarit JS.
            stops.push({ texte: e.textContent.trim().replace(/\\s+/g, ' '),
                         h: r.height, sh: e.scrollHeight, ch: e.clientHeight,
                         sw: e.scrollWidth, cw: e.clientWidth });
          }
        }
        const reset = [];
        if (${JSON.stringify(chemin)} === '/') {
          const b = document.getElementById('reinitialiser-volumes');
          if (b) {
            const r = b.getBoundingClientRect();
            reset.push({ w: r.width, h: r.height, texte: b.textContent.trim() });
          }
        }
        const pianos = [];
        if (${JSON.stringify(chemin)} === '/') {
          for (const e of document.querySelectorAll('.piano-bouton')) {
            if (e.offsetParent === null) continue;
            const r = e.getBoundingClientRect();
            pianos.push({ texte: e.textContent.trim(),
                          h: r.height, sh: e.scrollHeight, ch: e.clientHeight,
                          sw: e.scrollWidth, cw: e.clientWidth });
          }
        }
        // Bandeau de gauche : toute la hauteur visible (console entière au
        // grand écran, barre « Clavier » dégagée ; hauteur de la vue en
        // étroit, où la page défile et où le bandeau reste collé).
        const bandeau = [];
        if (${JSON.stringify(chemin)} === '/') {
          const b = document.querySelector('.bandeau').getBoundingClientRect();
          const c = document.querySelector('.curseur-general').getBoundingClientRect();
          const consoleR = document.querySelector('.console').getBoundingClientRect();
          const summary = document.querySelector('#clavier-panneau > summary');
          bandeau.push({
            h: b.height, haut: b.top, bas: b.bottom, vue: window.innerHeight,
            consoleBas: consoleR.bottom, curseur: c.height, defile: window.scrollY,
            clavierHaut: summary ? summary.getBoundingClientRect().top : null
          });
        }
        return {
          debord,
          petits,
          petitsTrans,
          curseurs,
          ranges,
          stops,
          pianos,
          reset,
          bandeau,
          remplissages: ${JSON.stringify(chemin)} === '/audio'
            ? [remplissage('reverb'), remplissage('qualite-polyphonie')]
            : (${JSON.stringify(chemin)} === '/'
              ? [remplissage('volume'), remplissage('volume-pedale'), remplissage('piano-volume')]
              : [])
        };
      })()`);
      verifie(mesure.debord <= 1, `web ${chemin} à ${largeur} px : aucun débordement horizontal (${mesure.debord} px)`);
      if (chemin === '/') {
        verifie(
          mesure.petitsTrans.length === 0,
          `web / à ${largeur} px : cibles de transposition ≥ 44 px (${mesure.petitsTrans.join(', ') || 'toutes'})`
        );
        const etroites = mesure.curseurs.filter((c) => c.w < 44);
        verifie(
          mesure.curseurs.length >= 5 && etroites.length === 0,
          `web / à ${largeur} px : colonnes de curseurs verticales ≥ 44 px (${mesure.curseurs.length} colonnes, ${etroites.map((c) => c.w.toFixed(0)).join(', ') || 'toutes'})`
        );
        const duBandeau = mesure.ranges.filter((c) => c.bandeau);
        if (largeur >= 900) {
          // Rail vertical : les curseurs du bandeau sont verticaux et
          // larges d'au moins 44 px, comme ceux des claviers.
          const mauvais = duBandeau.filter((c) => c.h <= c.w || c.w < 44);
          verifie(
            duBandeau.length >= 2 && mauvais.length === 0,
            `web / à ${largeur} px : curseurs du bandeau verticaux ≥ 44 px (${duBandeau.length} curseurs, ${mauvais.map((c) => `${c.id} ${c.w.toFixed(0)}x${c.h.toFixed(0)}`).join(', ') || 'tous verticaux'})`
          );
          const gain = mesure.ranges.filter((c) => !c.bandeau);
          const mauvaisGain = gain.filter((c) => c.h <= c.w || c.w < 44);
          verifie(
            gain.length >= 1 && mauvaisGain.length === 0,
            `web / à ${largeur} px : curseurs de gain verticaux ≥ 44 px (${gain.length}, ${mauvaisGain.map((c) => c.id).join(', ') || 'tous'})`
          );
        } else {
          // Barre compacte : les curseurs généraux sont horizontaux (plus
          // larges que hauts) et hauts d'au moins 44 px ; ceux des claviers
          // restent des colonnes verticales.
          const mauvais = duBandeau.filter((c) => c.w <= c.h || c.h < 44);
          verifie(
            duBandeau.length >= 2 && mauvais.length === 0,
            `web / à ${largeur} px : curseurs du bandeau horizontaux ≥ 44 px de haut (${duBandeau.length} curseurs, ${mauvais.map((c) => `${c.id} ${c.w.toFixed(0)}x${c.h.toFixed(0)}`).join(', ') || 'tous horizontaux'})`
          );
          const gain = mesure.ranges.filter((c) => !c.bandeau);
          const mauvaisGain = gain.filter((c) => c.h <= c.w || c.w < 44);
          verifie(
            gain.length >= 1 && mauvaisGain.length === 0,
            `web / à ${largeur} px : curseurs de gain verticaux ≥ 44 px (${gain.length}, ${mauvaisGain.map((c) => c.id).join(', ') || 'tous'})`
          );
        }
        // Le texte de chaque bouton de jeu doit tenir entièrement dans la
        // case (scrollHeight <= clientHeight + 1) : une grille étirée ou des
        // colonnes trop étroites coupent les noms sur deux ou trois lignes.
        // Le nom doit tenir entièrement dans le bouton : ni hauteur coupée
        // (rangée trop basse), ni largeur coupée (mot plus large que la case,
        // coupé au bord).
        const debordStops = mesure.stops.filter((b) => b.sh > b.ch + 1 || b.sw > b.cw + 1);
        verifie(
          mesure.stops.length > 0 && debordStops.length === 0,
          `web / à ${largeur} px : aucun texte de bouton de jeu ne déborde (${debordStops.map((b) => b.texte + ' ' + b.sh + '>' + b.ch + ' / ' + b.sw + '>' + b.cw).join(', ') || mesure.stops.length + ' boutons complets'})`
        );
        const petitsStops = mesure.stops.filter((b) => b.h < 44);
        verifie(
          petitsStops.length === 0,
          `web / à ${largeur} px : boutons de jeu ≥ 44 px (${petitsStops.map((b) => b.texte + '=' + b.h.toFixed(0)).join(', ') || 'tous'})`
        );
        // Le bouton Piano garde son libellé entier et la cible tactile, aux
        // deux largeurs : il partage la rangée des accouplements (ou de la
        // transposition).
        const debordPianos = mesure.pianos.filter((b) => b.sh > b.ch + 1 || b.sw > b.cw + 1);
        verifie(
          mesure.pianos.length > 0 && debordPianos.length === 0,
          `web / à ${largeur} px : aucun texte de bouton Piano ne déborde (${debordPianos.map((b) => b.texte + ' ' + b.sh + '>' + b.ch + ' / ' + b.sw + '>' + b.cw).join(', ') || mesure.pianos.length + ' boutons complets'})`
        );
        const petitsPianos = mesure.pianos.filter((b) => b.h < 44);
        verifie(
          petitsPianos.length === 0,
          `web / à ${largeur} px : boutons Piano ≥ 44 px (${petitsPianos.map((b) => b.texte + '=' + b.h.toFixed(0)).join(', ') || 'tous'})`
        );
        // Bouton de remise à zéro : icône seule, cible tactile, dans le
        // bandeau (donc dans la fenêtre avec le reste).
        const reset = mesure.reset[0];
        verifie(
          reset && reset.h >= 44 && reset.w >= 44 && reset.texte === '↺',
          `web / à ${largeur} px : bouton de remise à zéro ≥ 44 px et à icône seule (${reset ? `${reset.w.toFixed(0)}x${reset.h.toFixed(0)} « ${reset.texte} »` : 'absent'})`
        );
        // Bandeau : rail vertical pleine hauteur au grand écran (barre
        // « Clavier » dégagée dessous) ; barre compacte en haut de la page en
        // étroit, la plus basse possible pour libérer l'écran.
        const b = mesure.bandeau[0];
        if (largeur >= 900) {
          verifie(
            b && b.h >= b.vue * 0.9,
            `web / à ${largeur} px : bandeau sur toute la hauteur visible (${b ? b.h.toFixed(0) : '?'} px sur ${b ? b.vue : '?'})`
          );
          verifie(
            b && Math.abs(b.bas - b.consoleBas) <= 1 &&
              b.clavierHaut !== null && b.clavierHaut >= b.bas - 1,
            `web / à ${largeur} px : bandeau jusqu'au bas de la console, barre Clavier dégagée (bas ${b ? b.bas.toFixed(0) : '?'} / console ${b ? b.consoleBas.toFixed(0) : '?'} / Clavier ${b && b.clavierHaut !== null ? b.clavierHaut.toFixed(0) : '?'})`
          );
          verifie(
            b && b.curseur >= 400,
            `web / à ${largeur} px : curseurs étirés sur la hauteur du bandeau (${b ? b.curseur.toFixed(0) : '?'} px)`
          );
        } else {
          verifie(
            b && b.h <= 200 && b.haut <= 6,
            `web / à ${largeur} px : bandeau compact en haut de la page (${b ? b.h.toFixed(0) : '?'} px, haut ${b ? b.haut.toFixed(0) : '?'})`
          );
          verifie(
            b && b.h < b.vue / 2,
            `web / à ${largeur} px : le bandeau ne prend plus la hauteur de la vue (${b ? b.h.toFixed(0) : '?'} px sur ${b ? b.vue : '?'})`
          );
          const pied = await evaluer(`(() => {
            const p = document.querySelector('.bandeau-pied');
            const r = p.getBoundingClientRect();
            const t = document.querySelector('.bandeau .transposition');
            const rt = t ? t.getBoundingClientRect() : null;
            return { haut: r.top, bas: r.bottom, h: r.height,
                     trans: rt ? { h: rt.height, w: rt.width } : null };
          })()`);
          verifie(
            pied.trans && pied.trans.w >= 44 && pied.trans.h >= 44,
            `web / à ${largeur} px : transposition dans le pied du bandeau (${pied.trans ? `${pied.trans.w.toFixed(0)}x${pied.trans.h.toFixed(0)}` : 'absente'})`
          );
        }
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
  await testClavier();
  await testEtroit();
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
