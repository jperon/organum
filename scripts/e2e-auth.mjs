// Vérifie l'authentification Digest dans Chromium headless : la page se
// charge avec identifiants, les jeux restent cliquables, l'attente longue ne
// redemande pas le mot de passe à chaque requête.
//
//   CDP_PORT=... BASE_URL=http://hôte:port ORGANUM_USER=... ORGANUM_PASS=... \
//     node scripts/e2e-auth.mjs
//
// Sortie : une ligne OK / ÉCHEC par contrôle ; code non nul si échec.

import crypto from 'node:crypto';

const CDP_PORT = process.env.CDP_PORT;
const BASE = process.env.BASE_URL;
const USER = process.env.ORGANUM_USER || 'organiste';
const PASS = process.env.ORGANUM_PASS;

let echecs = 0;
let total = 0;
function ok(message) { total += 1; console.log(`OK    : ${message}`); }
function echec(message) { total += 1; echecs += 1; console.log(`ÉCHEC : ${message}`); }
function verifie(condition, message) { if (condition) ok(message); else echec(message); }

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

async function attendre(condition, message, delai = 10000) {
  const debut = Date.now();
  let dernier;
  while (Date.now() - debut < delai) {
    try {
      dernier = await condition();
      if (dernier) return dernier;
    } catch (e) { dernier = e; }
    await delay(80);
  }
  echec(`${message} (délai ${delai} ms dépassé${dernier ? ` : ${dernier}` : ''})`);
  return null;
}

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
let nonce = null;

function enteteDigest(methode, uri) {
  const nc = '00000001';
  const cnonce = crypto.randomBytes(16).toString('hex');
  const ha1 = sha256(`${USER}:organum:${PASS}`);
  const ha2 = sha256(`${methode}:${uri}`);
  const reponse = sha256(`${ha1}:${nonce}:${nc}:${cnonce}:auth:${ha2}`);
  return `Digest username="${USER}", realm="organum", uri="${uri}", ` +
    `algorithm=SHA-256, nonce="${nonce}", nc=${nc}, cnonce="${cnonce}", ` +
    `qop=auth, response="${reponse}"`;
}

// Requête Node avec Digest : premier 401, puis rejeu ; un second 401 avec
// stale=true recharge le nonce une fois.
async function api(chemin, options = {}) {
  const url = new URL(BASE + chemin);
  const uri = url.pathname + url.search;
  const methode = options.method || 'GET';
  const entetes = Object.assign({}, options.headers || {});
  let reponse;
  for (let essai = 0; essai < 3; essai += 1) {
    reponse = await fetch(url, { ...options, headers: entetes });
    if (reponse.status !== 401) break;
    const defi = reponse.headers.get('www-authenticate') || '';
    const vu = /nonce="([^"]+)"/.exec(defi);
    if (!vu) break;
    nonce = vu[1];
    entetes.Authorization = enteteDigest(methode, uri);
  }
  return reponse;
}

async function apiJson(chemin) {
  const r = await api(chemin);
  return r.json();
}

class Cdp {
  constructor(socket, surEvenement) {
    this.socket = socket;
    this.id = 0;
    this.pending = new Map();
    this.erreurs = [];
    this.authDemandes = 0;
    socket.addEventListener('message', async (evenement) => {
      const message = JSON.parse(evenement.data);
      if (message.id !== undefined) {
        const attente = this.pending.get(message.id);
        if (!attente) return;
        this.pending.delete(message.id);
        if (message.error) attente.rejeter(new Error(message.error.message));
        else attente.resoudre(message.result);
        return;
      }
      if (message.method === 'Runtime.exceptionThrown') {
        const d = message.params.exceptionDetails || {};
        this.erreurs.push((d.exception && d.exception.description) || d.text || 'exception');
      } else if (message.method === 'Log.entryAdded') {
        const e = message.params.entry || {};
        if (e.level === 'error' && !(e.url || '').includes('favicon')) {
          this.erreurs.push(`${e.source || 'log'} : ${e.text || ''}`);
        }
      } else if (message.method === 'Runtime.consoleAPICalled') {
        if (message.params.type === 'error') {
          const args = (message.params.args || []).map((a) => a.value ?? a.description ?? '');
          this.erreurs.push(`console : ${args.join(' ')}`);
        }
      }
      if (surEvenement) surEvenement(message);
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
      const r = await fetch(`http://127.0.0.1:${CDP_PORT}/json/list`);
      cibles = await r.json();
      if (cibles.length > 0) break;
    } catch (e) { /* Chromium démarre. */ }
    await delay(100);
  }
  let cible = cibles.find((c) => c.type === 'page');
  if (!cible) {
    const r = await fetch(`http://127.0.0.1:${CDP_PORT}/json/new?about:blank`, { method: 'PUT' });
    cible = await r.json();
  }
  const socket = new WebSocket(cible.webSocketDebuggerUrl);
  await new Promise((resoudre, rejeter) => {
    socket.addEventListener('open', resoudre, { once: true });
    socket.addEventListener('error', rejeter, { once: true });
  });
  let cdp;
  const surEvenement = async (message) => {
    if (message.method === 'Fetch.requestPaused') {
      cdp.envoyer('Fetch.continueRequest', { requestId: message.params.requestId }).catch(() => {});
    } else if (message.method === 'Fetch.authRequired') {
      cdp.authDemandes += 1;
      cdp.envoyer('Fetch.continueWithAuth', {
        requestId: message.params.requestId,
        authChallengeResponse: { response: 'ProvideCredentials', username: USER, password: PASS }
      }).catch(() => {});
    }
  };
  cdp = new Cdp(socket, surEvenement);
  await cdp.envoyer('Runtime.enable');
  await cdp.envoyer('Log.enable');
  await cdp.envoyer('Page.enable');
  await cdp.envoyer('Fetch.enable', { handleAuthRequests: true, patterns: [{ urlPattern: '*' }] });
  return cdp;
}

let cdp;

async function evaluer(expression) {
  const r = await cdp.envoyer('Runtime.evaluate', {
    expression, returnByValue: true, awaitPromise: true
  });
  if (r.exceptionDetails) {
    const d = r.exceptionDetails;
    throw new Error((d.exception && d.exception.description) || d.text || 'erreur JS');
  }
  return r.result.value;
}

async function navigate(chemin) {
  await cdp.envoyer('Page.navigate', { url: BASE + chemin });
  await attendre(async () => (await evaluer('document.readyState')) === 'complete',
    `chargement de ${chemin}`);
  await delay(500);
}

async function rect(expression) {
  return evaluer(`(() => {
    const e = (${expression});
    if (!e) return null;
    e.scrollIntoView({ block: 'center', inline: 'center' });
    const r = e.getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height };
  })()`);
}

async function clic(expression) {
  const r = await rect(expression);
  if (!r) return echec(`élément introuvable : ${expression}`);
  const x = r.x + r.w / 2, y = r.y + r.h / 2;
  await cdp.envoyer('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  await cdp.envoyer('Input.dispatchMouseEvent', {
    type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1
  });
  await cdp.envoyer('Input.dispatchMouseEvent', {
    type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1
  });
  await delay(200);
  return true;
}

async function principal() {
  // Sans identifiants, le serveur répond 401 : c'est bien l'authentification
  // qui protège la route, pas une exemption locale.
  const nu = await fetch(BASE + '/api/orgue');
  verifie(nu.status === 401, `sans identifiant : 401 (vu ${nu.status})`);

  cdp = await connecter();

  await navigate('/');
  const ndiv = await attendre(
    async () => evaluer('document.querySelectorAll(".division").length'),
    'page / chargée avec identifiants');
  verifie(ndiv > 0, `page / : ${ndiv} division(s) affichée(s)`);

  const stop = 'document.querySelectorAll(".division")[0].querySelector(".stop")';
  const avant = (await apiJson('/api/orgue')).divisions[0].stops[0].on === true;
  await clic(stop);
  const bascule = await attendre(async () => {
    const e = await apiJson('/api/orgue');
    return e.divisions[0].stops[0].on === !avant;
  }, 'web / : jeu basculé par clic sous authentification');
  if (bascule) {
    await clic(stop);
    await attendre(async () => {
      const e = await apiJson('/api/orgue');
      return e.divisions[0].stops[0].on === avant;
    }, 'web / : jeu revenu à son état');
  }

  // Laisse l'attente longue et la relève périodique tourner, puis vérifie
  // qu'aucune nouvelle boîte d'authentification n'est demandée par requête.
  const avantAttente = cdp.authDemandes;
  await delay(6000);
  const apresAttente = cdp.authDemandes;
  verifie(apresAttente - avantAttente <= 1,
    `attente longue : pas de nouvelle authentification (${avantAttente}→${apresAttente})`);

  await navigate('/audio');
  const panneau = await attendre(
    async () => evaluer('document.getElementById("authentification") !== null'),
    'page /audio : panneau Authentification présent');
  verifie(panneau === true, 'page /audio : panneau Authentification présent');
  const statut = await evaluer('document.getElementById("auth-etat").textContent');
  verifie(/Activée/.test(statut || ''), `page /audio : état affiché « ${statut} »`);
  const avertissement = await evaluer(
    'document.body.textContent.includes("envoyé en clair")');
  verifie(avertissement === true, 'page /audio : limite HTTP documentée');

  const avantTemp = (await apiJson('/api/orgue')).temperament;
  const cible = (avantTemp + 3) % 11;
  await clic(`document.querySelector('#qualite-temperament [data-valeur="${cible}"]')`);
  const change = await attendre(async () => {
    const e = await apiJson('/api/orgue');
    return e.temperament === cible && e.qualite.application === false;
  }, `web /audio : tempérament ${cible} appliqué par clic`, 30000);
  verifie(change === true, `web /audio : tempérament ${cible} appliqué par clic`);

  await delay(500);
  verifie(cdp.erreurs.length === 0,
    `aucune erreur console${cdp.erreurs.length ? ` (${cdp.erreurs.slice(0, 3).join(' | ')})` : ''}`);

  console.log(`-- ${total} test(s), ${echecs} échec(s)`);
  process.exit(echecs === 0 ? 0 : 1);
}

principal().catch((e) => {
  console.error(`ÉCHEC : ${e && e.stack ? e.stack : e}`);
  process.exit(1);
});
