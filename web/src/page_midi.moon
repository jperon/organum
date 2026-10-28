-- Page des associations MIDI : quels canaux jouent sur quel clavier, et
-- quels contrôleurs (molette, pédale…) agissent sur quels réglages.
-- Le contenu est construit par le script à partir de /api/midi.
h = require "html"
style = require "style"

css = [[
  .midi { max-width: none; display: flex; flex-direction: column; gap: 12px; padding: 8px; }
  .midi h2 { margin: 0; font-size: 1rem; }
  .midi .entete { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .midi .entete a { color: inherit; }
  .grille { display: grid; grid-template-columns: minmax(6em, max-content) repeat(16, minmax(1.8em, 1fr)); gap: 2px; overflow-x: auto; }
  .grille .nom { align-self: center; padding-right: 8px; }
  .grille .num { text-align: center; opacity: .7; font-size: .8rem; }
  .canal { min-height: 2.2em; border: 1px solid var(--border); background: var(--panel); color: inherit; border-radius: 4px; cursor: pointer; }
  .canal[aria-pressed="true"] { background: var(--accent, #3b82f6); color: #fff; }
  .assoc { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; padding: 4px 0; }
  .assoc select, .assoc input { min-height: 2.2em; background: var(--panel); color: inherit; border: 1px solid var(--border); border-radius: 4px; }
  .assoc input { width: 4.5em; }
  .apprentissage { outline: 2px solid var(--accent, #3b82f6); }
  .dernier { opacity: .8; font-size: .9rem; }
]]

script = [[
(function () {
  var etat = null, apprendre = -1, dernierVu = null;
  var grille = document.getElementById('grille');
  var liste = document.getElementById('associations');
  var dernier = document.getElementById('dernier');

  function bouton(actif, titre, clic) {
    var b = document.createElement('button');
    b.type = 'button'; b.className = 'canal'; b.title = titre;
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
        (function (c) { return function () { basculer(listeCanaux, c); }; })(c)));
    }
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
      option(canal, '', 'Tous canaux', !a.canal);
      for (var c = 1; c <= 16; c++) option(canal, c, 'Canal ' + c, a.canal === c);
      canal.addEventListener('change', function () { a.canal = canal.value ? +canal.value : undefined; envoyer(); });
      var cc = document.createElement('input');
      cc.type = 'number'; cc.min = 0; cc.max = 127; cc.value = a.cc;
      cc.setAttribute('aria-label', 'Numéro de contrôleur');
      cc.addEventListener('change', function () { a.cc = Math.max(0, Math.min(127, +cc.value || 0)); envoyer(); });
      var cible = document.createElement('select');
      option(cible, 'volume', 'Volume', a.cible === 'volume');
      option(cible, 'reverb', 'Réverbération', a.cible === 'reverb');
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
  }

  function afficherDernier() {
    var d = etat.dernier_controle;
    dernier.textContent = d ? 'Dernier contrôle reçu : canal ' + d.canal + ', CC ' + d.cc + ' = ' + d.valeur : 'Aucun contrôle reçu';
  }

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

  // Suivi du dernier contrôle reçu (et apprentissage).
  function suivre() {
    fetch('/api/midi', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (e) {
      if (!etat) { etat = e; afficher(); return; }
      etat.dernier_controle = e.dernier_controle;
      afficherDernier();
      var vu = JSON.stringify(e.dernier_controle || null);
      if (apprendre >= 0 && vu !== dernierVu && e.dernier_controle) {
        var a = etat.associations[apprendre];
        a.canal = e.dernier_controle.canal; a.cc = e.dernier_controle.cc;
        apprendre = -1;
        envoyer();
      }
    }).catch(function () {}).then(function () { setTimeout(suivre, 400); });
  }
  suivre();
})();
]]

->
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
        h.div id: "associations", "",
      h.script script

  "<!DOCTYPE html>\n" .. page
