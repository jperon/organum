-- Page des associations MIDI : quels canaux jouent sur quel clavier, et
-- quels contrôleurs (molette, pédale…) agissent sur quels réglages.
-- Le contenu est construit par le script à partir de /api/midi.
h = require "html"
style = require "style"
modele = require "modele"

escape = (s) ->
  s = tostring s
  s = s\gsub "&", "&amp;"
  s = s\gsub "<", "&lt;"
  s = s\gsub ">", "&gt;"
  s = s\gsub '"', "&quot;"
  s

css = [[
  .midi { max-width: none; display: flex; flex-direction: column; gap: 12px; padding: 8px; }
  .midi h2 { margin: 0; font-size: 1rem; }
  .midi .entete { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .midi .entete a { color: inherit; }
  .grille { display: grid; grid-template-columns: minmax(6em, max-content) repeat(16, minmax(1.8em, 1fr)); gap: 2px; overflow-x: auto; }
  .grille .nom { align-self: center; padding-right: 8px; }
  .grille .num { text-align: center; opacity: .7; font-size: .8rem; }
  .canal { min-height: 40px; border: 1px solid var(--border); background: var(--panel); color: inherit; border-radius: 4px; cursor: pointer; }
  .midi .btn.small { min-height: 40px; }
  .canal[aria-pressed="true"] { background: var(--accent, #3b82f6); color: #fff; }
  /* Activité MIDI récente : un contour, distinct du fond de sélection. */
  .canal.actif { outline: 2px solid var(--accent-bright, #a6e7ff); outline-offset: -2px; box-shadow: 0 0 0 2px var(--accent, #3b82f6); }
  .assoc { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; padding: 4px 0; }
  .assoc select, .assoc input { min-height: 40px; background: var(--panel); color: inherit; border: 1px solid var(--border); border-radius: 4px; }
  .assoc input { width: 4.5em; }
  .apprentissage { outline: 2px solid var(--accent, #3b82f6); }
  .dernier { opacity: .8; font-size: .9rem; }

  /* Connexions MIDI du système. Liste verticale, sans débordement
     horizontal ; sur téléphone le bouton passe sous le libellé. */
  .connexions { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
  .ports { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
  .port { display: flex; align-items: center; gap: 8px; min-width: 0; padding: 8px; background: var(--panel); border: 1px solid var(--border); border-radius: 8px; }
  .port .infos { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .port .libelle { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .port .etat { display: flex; align-items: center; gap: 6px; font-size: .8rem; color: var(--text-dim); }
  .pastille { flex: 0 0 auto; width: 12px; height: 12px; border-radius: 50%; background: var(--text-dim); box-shadow: inset 0 0 0 1px var(--border); }
  .pastille.etat-organum { background: var(--accent); }
  .pastille.etat-connecte { background: var(--ok); }
  .pastille.etat-destination { background: var(--warn); }
  .pastille.etat-disponible { background: transparent; border: 2px solid var(--off); }
  .port .btn { flex: 0 0 auto; min-height: 40px; }
  .port .btn:disabled { opacity: .55; cursor: wait; }
  .port[data-organum="true"] .libelle { font-weight: 700; }
  .message { min-height: 1.2em; margin: 0; font-size: .85rem; color: var(--text-dim); }
  .message.erreur { color: var(--off); }
  .message.succes { color: var(--ok); }
  @media (max-width: 420px) {
    .port { flex-wrap: wrap; }
    .port .infos { flex-basis: 100%; }
    .port .btn { flex: 1 1 auto; }
  }
]]

script = [[
(function () {
  var etat = null, apprendre = -1, dernierVu = null;
  var grille = document.getElementById('grille');
  var liste = document.getElementById('associations');
  var dernier = document.getElementById('dernier');
  var portsListe = document.getElementById('liste-ports');
  var messageAssistantAbsent = portsListe.getAttribute('data-message-assistant-absent') || '';
  var portsAdresse = document.getElementById('adresse-midi');
  var messageConnexions = document.getElementById('message-connexions');
  var rafraichirPorts = document.getElementById('rafraichir-ports');
  var etatPorts = { adresse: '', ports: [] };
  var portsEnCours = false, portsSeq = 0, portsSignature = null;
  // Une action par port à la fois : le poll peut reconstruire la liste
  // pendant la requête, le bouton recréé reste donc désactivé.
  var portsActions = {};

  // Libellés fournis par modele.moon (attributs de #associations), avec
  // repli sur les chaînes historiques.
  function libelleModele(nom, defaut) {
    var valeur = liste && liste.getAttribute('data-' + nom);
    return valeur || defaut;
  }
  var LIBELLES = {
    volume: libelleModele('cible-volume', 'Volume'),
    reverb: libelleModele('cible-reverb', 'Réverbération'),
    tous: libelleModele('canal-tous', 'Tous')
  };

  function bouton(actif, titre, clic, canal) {
    var b = document.createElement('button');
    b.type = 'button'; b.className = 'canal'; b.title = titre;
    b.setAttribute('aria-label', titre);
    b.dataset.canal = canal;
    b.setAttribute('aria-pressed', actif ? 'true' : 'false');
    b.addEventListener('click', clic);
    return b;
  }

  function basculer(listeCanaux, c) {
    var i = listeCanaux.indexOf(c);
    if (i < 0) listeCanaux.push(c); else listeCanaux.splice(i, 1);
    envoyer();
  }

  function ligne(nom, listeCanaux) {
    var n = document.createElement('div');
    n.className = 'nom'; n.textContent = nom;
    grille.appendChild(n);
    for (var c = 1; c <= 16; c++) {
      grille.appendChild(bouton(listeCanaux.indexOf(c) >= 0, nom + ', canal ' + c,
        (function (c) { return function () { basculer(listeCanaux, c); }; })(c), c));
    }
  }

  // Activité MIDI : on ne touche qu'aux classes, jamais au rendu de la grille
  // ni à aria-pressed (qui reste la sélection voulue par l'utilisateur).
  function allumer(actifs) {
    var vus = {};
    (Array.isArray(actifs) ? actifs : []).forEach(function (c) { vus[c] = true; });
    Array.prototype.forEach.call(grille.querySelectorAll('.canal[data-canal]'), function (b) {
      b.classList.toggle('actif', !!vus[b.dataset.canal]);
    });
  }

  function option(sel, valeur, texte, choisi) {
    var o = document.createElement('option');
    o.value = valeur; o.textContent = texte; o.selected = choisi;
    sel.appendChild(o);
  }

  function afficher() {
    // Une liste vide arrive en {} (le JSON de redbean ne distingue pas).
    function tableau(v) { return Array.isArray(v) ? v : []; }
    etat.associations = tableau(etat.associations);
    etat.controle = tableau(etat.controle);
    etat.expression = tableau(etat.expression);
    etat.divisions = tableau(etat.divisions);
    etat.divisions.forEach(function (d) { d.canaux = tableau(d.canaux); });
    grille.textContent = '';
    grille.appendChild(document.createElement('div'));
    for (var c = 1; c <= 16; c++) {
      var t = document.createElement('div');
      t.className = 'num'; t.textContent = c;
      grille.appendChild(t);
    }
    etat.divisions.forEach(function (d) { ligne(d.nom, d.canaux); });
    ligne('Contrôle (jeux, combinaisons)', etat.controle);
    ligne('Expression', etat.expression);

    liste.textContent = '';
    etat.associations.forEach(function (a, i) {
      var div = document.createElement('div');
      div.className = 'assoc' + (apprendre === i ? ' apprentissage' : '');
      var canal = document.createElement('select');
      option(canal, '', LIBELLES.tous + ' canaux', !a.canal);
      for (var c = 1; c <= 16; c++) option(canal, c, 'Canal ' + c, a.canal === c);
      canal.addEventListener('change', function () { a.canal = canal.value ? +canal.value : undefined; envoyer(); });
      var cc = document.createElement('input');
      cc.type = 'number'; cc.min = 0; cc.max = 127; cc.value = a.cc;
      cc.setAttribute('aria-label', 'Numéro de contrôleur');
      cc.addEventListener('change', function () { a.cc = Math.max(0, Math.min(127, +cc.value || 0)); envoyer(); });
      var cible = document.createElement('select');
      option(cible, 'volume', LIBELLES.volume, a.cible === 'volume');
      option(cible, 'reverb', LIBELLES.reverb, a.cible === 'reverb');
      etat.divisions.forEach(function (d, k) {
        option(cible, 'gain:' + (k + 1), 'Volume ' + d.nom, a.cible === 'gain' && a.division === k + 1);
      });
      cible.addEventListener('change', function () {
        var v = cible.value.split(':');
        a.cible = v[0]; a.division = v[1] ? +v[1] : undefined;
        envoyer();
      });
      var app = document.createElement('button');
      app.type = 'button'; app.className = 'btn small';
      app.textContent = apprendre === i ? 'Bougez un contrôle…' : 'Apprendre';
      app.addEventListener('click', function () {
        apprendre = apprendre === i ? -1 : i;
        dernierVu = JSON.stringify(etat.dernier_controle || null);
        afficher();
      });
      var suppr = document.createElement('button');
      suppr.type = 'button'; suppr.className = 'btn small'; suppr.textContent = 'Retirer';
      suppr.addEventListener('click', function () { etat.associations.splice(i, 1); apprendre = -1; envoyer(); });
      [canal, document.createTextNode('CC'), cc, document.createTextNode('→'), cible, app, suppr]
        .forEach(function (e) { div.appendChild(e); });
      liste.appendChild(div);
    });
    afficherDernier();
    allumer(etat.canaux_actifs);
  }

  function afficherDernier() {
    var d = etat.dernier_controle;
    dernier.textContent = d ? 'Dernier contrôle reçu : canal ' + d.canal + ', CC ' + d.cc + ' = ' + d.valeur : 'Aucun contrôle reçu';
  }

  // --- Connexions MIDI du système -------------------------------------
  // La liste est rechargée lentement (1 s visible, 5 s onglet caché) pour
  // ne pas gêner l'activité, plus vite après une action ou sur demande.
  // Le serveur remplit déjà « libelle » et « etat » via modele.moon ; on ne
  // garde ici qu'un repli minimal pour une réponse incomplète.
  function libellePort(p) {
    if (p.libelle) return p.libelle;
    if (p.adresse != null) return String(p.adresse);
    return (p.client != null && p.port != null) ? p.client + ':' + p.port : 'Port MIDI';
  }

  function etatPort(p) {
    return p.etat || 'disponible';
  }

  function clePort(p) {
    return String(p.client) + ':' + String(p.port);
  }

  var ETATS_PORT = {
    organum: 'Organum', connecte: 'Connecté',
    destination: 'Destination', disponible: 'Disponible'
  };

  function messageConnexionsTexte(texte, genre) {
    messageConnexions.textContent = texte || '';
    messageConnexions.className = 'message' + (genre ? ' ' + genre : '');
  }

  function afficherPorts(donnees) {
    etatPorts = donnees || { adresse: '', ports: [] };
    var ports = Array.isArray(etatPorts.ports) ? etatPorts.ports : [];
    portsAdresse.textContent = etatPorts.adresse ? 'Séquenceur : ' + etatPorts.adresse : '';
    portsListe.textContent = '';
    if (!ports.length) {
      var vide = document.createElement('p');
      vide.className = 'note';
      if (etatPorts.disponible === true && etatPorts.socket === true && etatPorts.assistant === false && messageAssistantAbsent) {
        // Backend socket présent sans son assistant : le dire, sans alarmer.
        vide.className = 'note degrade';
        vide.textContent = messageAssistantAbsent;
      } else {
        vide.textContent = etatPorts.disponible === false
          ? 'MIDI indisponible sur ' + (etatPorts.plateforme_libelle || 'cette plate-forme') + '.'
          : 'Aucun port MIDI détecté.';
      }
      portsListe.appendChild(vide);
      return;
    }
    ports.forEach(function (p) {
      var libelle = libellePort(p);
      var etatLigne = etatPort(p);
      var ligne = document.createElement('div');
      ligne.className = 'port';
      ligne.dataset.client = p.client;
      ligne.dataset.port = p.port;
      ligne.dataset.organum = p.organum ? 'true' : 'false';

      var infos = document.createElement('div');
      infos.className = 'infos';
      var texte = document.createElement('span');
      texte.className = 'libelle';
      texte.textContent = libelle;
      texte.title = libelle;
      var etatTexte = document.createElement('span');
      etatTexte.className = 'etat';
      var pastille = document.createElement('span');
      pastille.className = 'pastille etat-' + etatLigne;
      pastille.setAttribute('aria-hidden', 'true');
      var mot = document.createElement('span');
      mot.textContent = ETATS_PORT[etatLigne] || etatLigne;
      etatTexte.appendChild(pastille);
      etatTexte.appendChild(mot);
      infos.appendChild(texte);
      infos.appendChild(etatTexte);
      ligne.appendChild(infos);

      // Seules les sources du système (hors organum et port d'annonces 0:1)
      // se connectent ; les destinations sont en lecture seule.
      if (p.source && !p.organum && !(p.client === 0 && p.port === 1)) {
        var action = document.createElement('button');
        action.type = 'button';
        action.className = 'btn small';
        action.textContent = p.connecte ? 'Déconnecter' : 'Connecter';
        action.setAttribute('aria-pressed', p.connecte ? 'true' : 'false');
        action.setAttribute('aria-label', (p.connecte ? 'Déconnecter ' : 'Connecter ') + libelle);
        action.disabled = !!portsActions[clePort(p)];
        action.addEventListener('click', function () { basculerPort(p, action); });
        ligne.appendChild(action);
      }
      portsListe.appendChild(ligne);
    });
  }

  function basculerPort(p, action) {
    var cle = clePort(p);
    if (portsActions[cle]) return;
    portsActions[cle] = true;
    var connecte = !p.connecte;
    action.disabled = true;
    messageConnexionsTexte('', '');
    fetch('/api/midi/connexion', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client: p.client, port: p.port, connecte: connecte })
    }).then(function (r) {
      return r.json().then(function (d) { return { ok: r.ok, donnees: d || {} }; });
    }).then(function (res) {
      if (!res.ok) {
        delete portsActions[cle];
        messageConnexionsTexte(res.donnees.error || 'Connexion MIDI impossible.', 'erreur');
        action.disabled = false;
        return;
      }
      // La réponse fait foi (le moteur peut refuser une connexion sans
      // erreur HTTP) ; on ne se fie pas seulement à l'intention du clic.
      var effectif = typeof res.donnees.connecte === 'boolean' ? res.donnees.connecte : connecte;
      var libelle = libellePort(p);
      messageConnexionsTexte((effectif ? 'Connecté : ' : 'Déconnecté : ') + libelle, 'succes');
      // La réponse contient déjà la liste à jour : inutile de la redemander.
      delete portsActions[cle];
      portsSeq++;
      portsEnCours = false;
      var donnees = {
        adresse: etatPorts.adresse,
        ports: Array.isArray(res.donnees.ports) ? res.donnees.ports : etatPorts.ports
      };
      portsSignature = JSON.stringify(donnees);
      afficherPorts(donnees);
      var nouveau = portsListe.querySelector('.port[data-client="' + p.client + '"][data-port="' + p.port + '"] .btn');
      if (nouveau) nouveau.focus();
    }).catch(function () {
      delete portsActions[cle];
      messageConnexionsTexte('Connexion MIDI impossible : serveur indisponible.', 'erreur');
      action.disabled = false;
    });
  }

  function chargerPorts(force) {
    if (portsEnCours && !force) return;
    portsEnCours = true;
    var seq = ++portsSeq;
    fetch('/api/midi/ports', { cache: 'no-store' }).then(function (r) { return r.json(); })
      .then(function (e) {
        if (seq !== portsSeq) return;
        var donnees = e || { adresse: '', ports: [] };
        var signature = JSON.stringify(donnees);
        // Ne pas reconstruire la liste à chaque poll si rien n'a changé
        // (le focus et le défilement restent en place).
        if (force || signature !== portsSignature) {
          portsSignature = signature;
          afficherPorts(donnees);
        }
      }).catch(function () {
        if (seq === portsSeq && force) {
          messageConnexionsTexte('Impossible de charger les ports MIDI.', 'erreur');
        }
      }).then(function () {
        if (seq === portsSeq) portsEnCours = false;
      });
  }

  function suivrePorts() {
    chargerPorts(false);
    setTimeout(suivrePorts, document.visibilityState === 'hidden' ? 5000 : 1000);
  }

  rafraichirPorts.addEventListener('click', function () {
    messageConnexionsTexte('', '');
    chargerPorts(true);
  });

  function envoyer() {
    fetch('/api/midi', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ divisions: etat.divisions.map(function (d) { return { canaux: d.canaux }; }),
        controle: etat.controle, expression: etat.expression, associations: etat.associations })
    }).then(function (r) { return r.json(); }).then(function (e) {
      if (e && !e.error) { etat = e; }
      afficher();
    });
  }

  document.getElementById('ajouter').addEventListener('click', function () {
    etat.associations.push({ cc: 1, cible: 'volume' });
    apprendre = etat.associations.length - 1;
    dernierVu = JSON.stringify(etat.dernier_controle || null);
    envoyer();
  });

  // Suivi du dernier contrôle reçu (et apprentissage). La cadence ralentit
  // quand l'onglet est caché ; seules les classes d'activité sont mises à jour.
  function delaiActivite() {
    return document.visibilityState === 'hidden' ? 500 : 125;
  }

  function suivre() {
    fetch('/api/midi', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (e) {
      if (!etat) { etat = e; afficher(); return; }
      etat.dernier_controle = e.dernier_controle;
      etat.canaux_actifs = e.canaux_actifs;
      allumer(e.canaux_actifs);
      afficherDernier();
      var vu = JSON.stringify(e.dernier_controle || null);
      if (apprendre >= 0 && vu !== dernierVu && e.dernier_controle) {
        var a = etat.associations[apprendre];
        a.canal = e.dernier_controle.canal; a.cc = e.dernier_controle.cc;
        apprendre = -1;
        envoyer();
      }
    }).catch(function () {}).then(function () { setTimeout(suivre, delaiActivite()); });
  }
  suivre();
  suivrePorts();
})();
]]

(socket) ->
  -- Le texte d'avertissement n'est embarqué que si le backend socket est
  -- celui qui est utilisé : sous ALSA/WinMM, aucun organum-midi à lancer.
  attributs_ports = {}
  if socket == true
    attributs_ports["data-message-assistant-absent"] = escape(modele.message_ports_vide(true, false, true) or "")
  page = h.html lang: "fr",
    h.head {},
      h.meta charset: "utf-8",
      h.meta name: "viewport", content: "width=device-width, initial-scale=1",
      h.title "Orgue — MIDI",
      h.style style .. css,
    h.body {},
      h.main class: "midi",
        h.div class: "entete",
          h.a href: "/", "← Orgue",
          h.h2 "Canaux MIDI par clavier",
        h.div class: "grille", id: "grille", "",
        h.div class: "entete",
          h.h2 "Contrôleurs",
          h.button type: "button", class: "btn small", id: "ajouter", "Ajouter",
          h.span class: "dernier", id: "dernier", "",
        h.div id: "associations", "", ["data-cible-volume"]: escape(modele.cible_midi.volume), ["data-cible-reverb"]: escape(modele.cible_midi.reverb), ["data-canal-tous"]: escape(modele.canal_texte nil),
        h.section class: "connexions", ["aria-labelledby"]: "titre-connexions",
          h.div class: "entete",
            h.h2 id: "titre-connexions", "Connexions MIDI",
            h.button type: "button", class: "btn small", id: "rafraichir-ports", ["aria-label"]: "Rafraîchir la liste des ports MIDI", "Rafraîchir",
          h.p class: "note", id: "adresse-midi", "",
          h.div class: "ports", id: "liste-ports", "", attributs_ports,
          h.p class: "message", id: "message-connexions", role: "status", "",
      h.script script

  "<!DOCTYPE html>\n" .. page
