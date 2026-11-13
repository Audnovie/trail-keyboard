#!/usr/bin/env node
/*
 * Runs the JavaScript engine (tools/reference/core.js, the web trial's engine) on a fixed set
 * of inputs and writes what it does to Tests/EngineTests/Fixtures/*.json. The Swift tests run
 * the iPhone engine on the same inputs and must get the same answers.
 *
 *     node tools/fixtures/gen.js           # rewrite the fixtures
 *     node tools/fixtures/gen.js --check   # fail if the committed fixtures are out of date
 *
 * Everything is seeded, so the output only changes when core.js or the word lists do.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const T = require('../reference/core.js');

const ROOT = path.join(__dirname, '..', '..');
const OUT = path.join(ROOT, 'Tests', 'EngineTests', 'Fixtures');
const check = process.argv.includes('--check');

// ---- seeded randomness ----------------------------------------------------------------------

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
let rand = mulberry32(20261113);
function gauss() {
  let u = 0;
  let v = 0;
  while (u === 0) u = rand();
  while (v === 0) v = rand();
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
}
const r3 = (x) => Math.round(x * 1000) / 1000;

// ---- word lists -----------------------------------------------------------------------------

const lists = {};
for (const code of ['en', 'es']) {
  lists[code] = new T.WordList(fs.readFileSync(path.join(ROOT, 'tools', 'wordlists', 'words-' + code + '.txt'), 'utf8'));
}

function lexicon(langs, users) {
  const lex = new T.Lexicon();
  for (const code of ['en', 'es']) {
    const L = lex.add(code);
    L.words = lists[code];
    L.enabled = langs.indexOf(code) >= 0;
    if (users && users[code]) L.user.load(users[code]);
  }
  return lex;
}

// ---- the keyboard's shape (the web trial's letters layout, 390 points wide) -------------------

const WIDTH = 390;
const STRIP_H = 44;
const ROW_H = 54;
const GAP_X = 5;
const GAP_Y = 8;
const KW = WIDTH / 10;
const rows = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];
const rowWidths = [[10, 0], [9, 0], [7, 3]]; // letters, plus shift and delete (1.5 each) on row 3
const CX = new Array(26);
const CY = new Array(26);
rows.forEach((row, r) => {
  const total = rowWidths[r][0] + rowWidths[r][1];
  let x = ((10 - total) / 2) * KW;
  if (r === 2) x += 1.5 * KW;
  const y = STRIP_H + r * ROW_H;
  for (const ch of row) {
    const k = ch.charCodeAt(0) - 97;
    CX[k] = x + KW / 2;
    CY[k] = (y + GAP_Y / 2 + y + ROW_H - GAP_Y / 2) / 2;
    x += KW;
  }
});

/** A swipe for a word: through its keys (smoothed), with hand-like wobble, offsets and stops. */
function swipeFor(word, style) {
  const key = T.keyOf(word);
  const nodes = [];
  let last = -1;
  for (let i = 0; i < key.length; i++) {
    const k = key.charCodeAt(i) - 97;
    if (k !== last) nodes.push([CX[k], CY[k]]);
    last = k;
  }
  if (nodes.length === 1) nodes.push([nodes[0][0] + KW * 0.3, nodes[0][1] + 2]);
  const s = style || {};
  const jitter = s.jitter == null ? 0.18 : s.jitter;
  const ox = (s.dx || 0) * KW + gauss() * jitter * 0.4 * KW;
  const oy = (s.dy || 0) * KW + gauss() * jitter * 0.4 * KW;
  const pts = nodes.map((p) => [p[0] + ox + gauss() * jitter * KW, p[1] + oy + gauss() * jitter * KW]);
  // Stop short of (negative) or past (positive) the last letter, and start late or early.
  const n = pts.length;
  const endShift = s.end || 0;
  const ex = pts[n - 1][0] - pts[n - 2][0];
  const ey = pts[n - 1][1] - pts[n - 2][1];
  const el = Math.hypot(ex, ey) || 1;
  pts[n - 1] = [pts[n - 1][0] + (ex / el) * endShift * KW, pts[n - 1][1] + (ey / el) * endShift * KW];
  const xs = [];
  const ys = [];
  const per = s.per || 9;
  for (let i = 0; i < n - 1; i++) {
    const p0 = pts[Math.max(0, i - 1)];
    const p1 = pts[i];
    const p2 = pts[i + 1];
    const p3 = pts[Math.min(n - 1, i + 2)];
    for (let q = 0; q < per; q++) {
      const t = q / per;
      const t2 = t * t;
      const t3 = t2 * t;
      const f = (a, b, c, d) => 0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3);
      xs.push(r3(f(p0[0], p1[0], p2[0], p3[0]) + gauss() * 0.6));
      ys.push(r3(f(p0[1], p1[1], p2[1], p3[1]) + gauss() * 0.6));
    }
  }
  xs.push(r3(pts[n - 1][0]));
  ys.push(r3(pts[n - 1][1]));
  return { xs, ys };
}

// ---- learned-word states used by several fixtures -----------------------------------------------

function userStates() {
  const en = new T.UserWords(T.LANG_INFO.en.starters);
  en.recordUse('haha', 6, true);
  en.recordUse('sense', 3, true);
  en.recordUse('swipe', 4, true);
  en.recordUse('clear', 2, true);
  en.recordReject('summary');
  en.recordReject('summary');
  en.recordReject('spot');
  en.addManual('Terry');
  en.recordUse('Terry', 1, false);
  en.addManual('Audnovie');
  en.recordUse('lol', 3, true);
  en.recordUse('Yo', 1, true);
  en.block('Cleo');
  en.block('sent');
  en.recordUse('don\'t', 5, true);
  const es = new T.UserWords(T.LANG_INFO.es.starters);
  es.recordUse('yo', 12, true);
  es.recordUse('jaja', 7, true);
  es.recordUse('también', 3, true);
  es.recordUse('que', 4, true);
  es.recordReject('ya');
  es.addManual('chido');
  es.recordUse('chido', 2, false);
  es.block('mañanas');
  return { en: en.toJSON(), es: es.toJSON() };
}
const USERS = userStates();
const FRESH = { en: new T.UserWords(T.LANG_INFO.en.starters).toJSON(), es: new T.UserWords(T.LANG_INFO.es.starters).toJSON() };

function sourcesFor(lex, ctx, fixed) {
  const out = [];
  for (const L of lex.enabled()) {
    if (fixed && L.code !== ctx) continue;
    const S = { words: L.words, user: L.user, bias: L.code === ctx ? 0 : -T.LANG_PENALTY, lang: L.code };
    if (L.code === ctx) out.unshift(S);
    else out.push(S);
  }
  return out;
}

const files = {};

// ---- text helpers ----------------------------------------------------------------------------

{
  const words = ["Don't", 'mañana', 'ÁRBOL', 'naïve', 'hello', "it's", 'it’s', 'x-ray', '3d', '', 'Ñu', 'İstanbul', 'straße',
    'œuvre', 'Ærø', 'façade', 'über', '😀a', 'aé', "''", "a'", "'a", 'a’b', 'ﬁ', 'ǅ', 'Σ', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'naïve', 'São', 'ç', 'ÿ', 'Ł', 'ø', 'ð', 'þ'];
  const caps = ['hello', 'Hello', 'HELLO', 'H', 'hELLO', 'Éxito', 'ÉXITO', '', 'é', "DON'T", 'I', 'iPhone', '1abc', 'ß'];
  const before = ['', 'Hello', 'Hello.', 'Hello. ', 'Hello.  ', 'Hello. "', 'e.g. ', 'U.S. ', 'Hi!', 'Hi! ', 'Hi? (', 'Hola. ¿',
    'Line\n', 'Line\n  ', 'end." ', 'end.) ', 'Mr. ', 'a', ' ', '\t', 'x\t', 'Wait... ', '¡', 'yes, ', 'ok.\'', 'ok.’ ', '«'];
  files['text.json'] = {
    keyOf: words.map((w) => [w, T.keyOf(w)]),
    isLearnable: words.map((w) => [w, T.isLearnable(w)]),
    caps: caps.map((w) => [w, capsOf(w), T.withCaps(w, 0), T.withCaps(w, 1), T.withCaps(w, 2)]),
    capsAtEnd: before.map((b) => {
      const e = new T.Editor();
      e.commitText(b);
      return [b, e.capsAtCursor()];
    }),
  };
}

function capsOf(s) {
  const isUpper = (ch) => ch !== ch.toLowerCase() && ch === ch.toUpperCase();
  if (!s || !isUpper(s[0])) return 0;
  if (s.length >= 2 && s === s.toUpperCase()) return 2;
  return 1;
}

// ---- word lists ------------------------------------------------------------------------------

{
  const out = {};
  for (const code of ['en', 'es']) {
    const W = lists[code];
    const probes = ['hello', 'HELLO', 'Hello', 'its', "it's", 'ano', 'año', 'Año', 'manana', 'mañana', 'i', 'I', 'im', "I'm",
      'canada', 'Canada', 'toronto', 'mexico', 'méxico', 'México', 'xyzzy', '', 'a', 'que', 'qué', 'yo', 'Yo', 'el', 'él'];
    for (let i = 0; i < 40; i++) probes.push(W.display[Math.floor(rand() * W.size)]);
    for (let i = 0; i < 20; i++) probes.push(W.display[Math.floor(rand() * W.size)].toUpperCase());
    const keys = ['its', 'ano', 'manana', 'a', 'el', 'que', 'hello', 'zzzz', 'im', 'dont', 'tambien', 'como', 'esta'];
    const prefixes = ['a', 'th', 'hel', 'zz', 'que', 'tamb', 'x', 'q', 'aaaa', 'z', 'ya'];
    // Every word looked up in upper case: a checksum, so the fixture stays small.
    let sum = 0;
    for (let i = 0; i < W.size; i++) sum = (sum + (W.find(W.display[i].toUpperCase()) + 1) * ((i % 97) + 1)) % 1000000007;
    out[code] = {
      size: W.size,
      find: probes.map((p) => [p, W.find(p)]),
      withKey: keys.map((k) => [k, Array.from(W.withKey(k))]),
      prefixRange: prefixes.map((p) => [p, W.prefixRange(p)]),
      findUpperChecksum: sum,
    };
  }
  files['wordlist.json'] = out;
}

// ---- language detection ------------------------------------------------------------------------

{
  const lex = lexicon(['en', 'es'], USERS);
  const both = lex.enabled();
  const texts = ['', 'hello how are you', 'hola como estas', 'yo', 'Yo', 'yo quiero', 'I think yo', 'que tal amigo',
    'the quick brown fox', 'es muy bueno', 'Me llamo Terry', 'see you mañana', 'line one\nhola amigo', 'hola\nhi there',
    'jaja', 'haha', 'tambien', 'también', 'chido', 'Terry', '123 456', 'ok', 'no', 'a la casa', 'in the house',
    'I am going to the store and then', 'voy a la tienda y luego', "don't know", 'él dijo que no'];
  files['detect.json'] = {
    users: USERS,
    cases: texts.map((t) => [t, T.detectLang(t, both), T.detectLang(t, [both[0]])]),
  };
}

// ---- swipes ---------------------------------------------------------------------------------------

const SWIPE_WORDS_EN = ['hello', 'haha', 'sense', 'swipe', 'clear', 'spot', 'summary', 'the', 'and', 'you', 'that', 'was',
  'for', 'are', 'with', 'his', 'they', 'this', 'have', 'from', 'one', 'had', 'word', 'but', 'not', 'what', 'all', 'were',
  'when', 'your', 'can', 'said', 'there', 'use', 'each', 'which', 'she', 'how', 'their', 'will', 'other', 'about', 'out',
  'many', 'then', 'them', 'these', 'some', 'her', 'would', 'make', 'like', 'him', 'into', 'time', 'look', 'two', 'more',
  'write', 'see', 'number', 'way', 'could', 'people', 'than', 'first', 'water', 'been', 'call', 'who', 'its', 'now', 'find',
  'long', 'down', 'day', 'did', 'get', 'come', 'made', 'may', 'part', 'keyboard', 'thanks', 'tomorrow', 'definitely',
  'lol', 'yes', 'okay', 'Terry', 'dont', 'im', 'cool', 'yeah', 'wait', 'maybe', 'tonight', 'awesome', 'quiz', 'jazz'];
const SWIPE_WORDS_ES = ['hola', 'yo', 'que', 'jaja', 'gracias', 'mañana', 'también', 'como', 'esta', 'para', 'pero', 'muy',
  'bien', 'tengo', 'quiero', 'casa', 'amigo', 'chido', 'noche', 'ahora', 'donde', 'siempre', 'nada', 'todo', 'mucho'];

{
  const dec = new T.SwipeDecoder();
  dec.setKeyCenters(CX, CY, KW);
  const configs = [
    { name: 'en', langs: ['en'], ctx: 'en', users: FRESH },
    { name: 'en-learned', langs: ['en'], ctx: 'en', users: USERS },
    { name: 'both-en', langs: ['en', 'es'], ctx: 'en', users: USERS },
    { name: 'both-es', langs: ['en', 'es'], ctx: 'es', users: USERS },
    { name: 'es-fixed', langs: ['en', 'es'], ctx: 'es', fixed: true, users: USERS },
  ];
  const cases = [];
  const styles = [{}, { jitter: 0.1 }, { jitter: 0.3 }, { end: -0.35 }, { end: 0.4, dy: 0.15 }, { dx: -0.2, per: 5 }];
  let si = 0;
  for (const cfg of configs) {
    const pool = cfg.ctx === 'es' ? SWIPE_WORDS_ES.concat(SWIPE_WORDS_EN.slice(0, 12)) : SWIPE_WORDS_EN.concat(SWIPE_WORDS_ES.slice(0, 6));
    const count = cfg.name === 'en' ? pool.length : 36;
    for (let i = 0; i < count; i++) {
      const word = cfg.name === 'en' ? pool[i] : pool[Math.floor(rand() * pool.length)];
      const style = styles[si++ % styles.length];
      const p = swipeFor(word, style);
      const lex = lexicon(cfg.langs, cfg.users);
      const res = dec.decode(p.xs, p.ys, p.xs.length, sourcesFor(lex, cfg.ctx, cfg.fixed), 8);
      cases.push({ config: cfg.name, word, xs: p.xs, ys: p.ys, results: res.map((r) => [r.word, r.cost, r.lang]) });
    }
  }
  // Degenerate input.
  const lex = lexicon(['en'], FRESH);
  for (const p of [{ xs: [100], ys: [120] }, { xs: [100, 100.00001], ys: [120, 120] }, { xs: [100, 104], ys: [120, 121] },
    { xs: [-50, 900], ys: [-40, 600] }]) {
    const res = dec.decode(p.xs, p.ys, p.xs.length, sourcesFor(lex, 'en'), 8);
    cases.push({ config: 'en', word: '', xs: p.xs, ys: p.ys, results: res.map((r) => [r.word, r.cost, r.lang]) });
  }
  files['decoder.json'] = {
    geometry: { cx: CX, cy: CY, kw: KW },
    configs: configs.map((c) => ({ name: c.name, langs: c.langs, ctx: c.ctx, fixed: !!c.fixed, learned: c.users === USERS })),
    users: USERS,
    cases,
  };
}

// ---- swipe profile ---------------------------------------------------------------------------------

{
  const dec = new T.SwipeDecoder();
  dec.setKeyCenters(CX, CY, KW);
  const P = new T.SwipeProfile();
  const steps = [];
  const habit = { end: -0.4, dy: 0.18, dx: 0.08, jitter: 0.14 };
  for (let i = 0; i < 64; i++) {
    const word = SWIPE_WORDS_EN[(i * 7) % SWIPE_WORDS_EN.length];
    const p = swipeFor(word, habit);
    const al = dec.align(word, p.xs, p.ys, p.xs.length);
    const notes = al ? P.learn(al) : null;
    steps.push({
      word, xs: p.xs, ys: p.ys,
      aligned: al ? { nodes: al.nodes, x: al.x, y: al.y } : null,
      notes,
      ready: P.ready(),
    });
  }
  const params = P.params();
  const summary = P.summary();
  // Decoding with the profile.
  dec.setProfile(params);
  const lex = lexicon(['en', 'es'], USERS);
  const decodes = [];
  for (let i = 0; i < 30; i++) {
    const word = SWIPE_WORDS_EN[(i * 11 + 3) % SWIPE_WORDS_EN.length];
    const p = swipeFor(word, habit);
    const res = dec.decode(p.xs, p.ys, p.xs.length, sourcesFor(lex, 'en'), 8);
    decodes.push({ word, xs: p.xs, ys: p.ys, results: res.map((r) => [r.word, r.cost, r.lang]) });
  }
  files['profile.json'] = {
    geometry: { cx: CX, cy: CY, kw: KW },
    users: USERS,
    steps,
    params: { dx: Array.from(params.dx), dy: Array.from(params.dy), overall: params.overall, bias: params.bias, reach: params.reach },
    summary: {
      total: summary.total, ready: summary.ready, progress: summary.progress, keysSeen: summary.keysSeen,
      start: summary.start, corner: summary.corner, end: summary.end, overall: summary.overall,
      missedKeys: summary.missedKeys.map((k) => [k.key, k.seen, k.missRate]),
    },
    saved: P.toJSON(),
    decodes,
  };
}

// ---- typing suggestions ------------------------------------------------------------------------------

{
  const sug = new T.TypingSuggester();
  sug.setKeyCenters(CX, CY, KW);
  const typed = ['h', 'he', 'hel', 'helo', 'hellp', 'teh', 'thr', 'yo', 'Yo', 'que', 'qeu', 'tambien', 'mañ', 'man', 'dont',
    "don'", 'im', 'i', 'I', 'cn', 'jaj', 'Ter', 'Aud', 'chi', 'sum', 'sens', 'swip', 'clea', 'spo', 'xq', 'zzzz', 'cafe',
    'café', 'Toro', 'mexi', 'gracais', 'nohce', 'thnaks', 'definately', 'recieve', 'a', 'y', 'e', 'qu', 'ACER', 'Ha'];
  const configs = [
    { name: 'en', langs: ['en'], ctx: 'en', users: FRESH },
    { name: 'both-en', langs: ['en', 'es'], ctx: 'en', users: USERS },
    { name: 'both-es', langs: ['en', 'es'], ctx: 'es', users: USERS },
  ];
  const cases = [];
  for (const cfg of configs) {
    const lex = lexicon(cfg.langs, cfg.users);
    for (const t of typed) {
      const res = sug.suggest(t, sourcesFor(lex, cfg.ctx), 6);
      cases.push({ config: cfg.name, typed: t, results: res.map((r) => [r.word, r.score, r.kind, r.cost, r.lang]) });
    }
  }
  // Edit costs on their own.
  const pairs = [['helo', 'hello'], ['teh', 'the'], ['abc', ''], ['', 'abc'], ['ab', 'ba'], ['qwerty', 'qwrety'], ['xyz', 'abc']];
  files['suggest.json'] = {
    geometry: { cx: CX, cy: CY, kw: KW },
    configs: configs.map((c) => ({ name: c.name, langs: c.langs, ctx: c.ctx, learned: c.users === USERS })),
    users: USERS,
    cases,
    editCost: pairs.map((p) => [p[0], p[1], sug.editCost(p[0], p[1], 99)]),
  };
}

// ---- learned words ---------------------------------------------------------------------------------------

{
  const ops = [
    ['use', 'hello', 1, true], ['use', 'Hello', 2, true], ['use', 'Terry', 1, false], ['reject', 'hello'], ['use', 'hello', 2, true],
    ['add', '  Audnovie '], ['add', 'x-ray'], ['add', ''], ['block', 'Java'], ['block', 'spot'], ['use', 'spot', 3, true],
    ['unblock', 'Cleo'], ['reject', 'brand'], ['reject', 'brand'], ['reject', 'brand'], ['reject', 'brand'], ['reject', 'brand'],
    ['reject', 'brand'], ['use', 'brand', 1, true], ['setBase', 'Terry', true], ['setBase', 'Terry', false], ['remove', 'hello'],
    ['use', "it's", 1, true], ['use', 'naïve', 4, true], ['use', '12', 1, true], ['use', 'a b', 1, true], ['add', 'zzz'],
    ['use', 'Zzz', 0.5, false], ['use', 'apple', 100001, true], ['reject', 'Audnovie'],
  ];
  const U = new T.UserWords(T.LANG_INFO.en.starters);
  const trace = [];
  for (const op of ops) {
    if (op[0] === 'use') U.recordUse(op[1], op[2], op[3]);
    else if (op[0] === 'reject') U.recordReject(op[1]);
    else if (op[0] === 'add') U.addManual(op[1]);
    else if (op[0] === 'block') U.block(op[1]);
    else if (op[0] === 'unblock') U.unblock(op[1]);
    else if (op[0] === 'setBase') U.setInBaseList(op[1], op[2]);
    else if (op[0] === 'remove') U.remove(op[1]);
    const probes = ['hello', 'Terry', 'Audnovie', 'brand', 'spot', 'apple', 'zzz'];
    trace.push({
      version: U.version,
      bonus: probes.map((w) => [w, U.bonus(w)]),
      blocked: U.blockedWords(),
      active: U.activeAdded().map((e) => e.word),
      count: U.count(),
    });
  }
  const loads = [
    null, {}, { learned: 'x' }, { learned: [['ok', 3, 1, 0], ['bad word', 1, 0, 0], 'row', [5], ['Uses', '7', '2', true], ['neg', -3, -2, 1], ['big', 1, 99, 1]] },
    { learned: [], blocked: [] }, { blocked: ['  Foo ', '', 3, 'bar'] }, { learned: [['dup', 1, 0, 0], ['DUP', 2, 0, 0]] },
  ].map((d) => {
    const V = new T.UserWords(T.LANG_INFO.en.starters);
    V.load(d);
    return { input: d, saved: V.toJSON(), all: V.all().map((e) => [e.word, e.uses, e.rejects, e.added]) };
  });
  files['userwords.json'] = { ops, trace, saved: U.toJSON(), savedCapped: U.toJSON(3), all: U.all().map((e) => [e.word, e.uses, e.rejects, e.added]), loads };
}

// ---- typing sessions -----------------------------------------------------------------------------------

class RecordingView {
  constructor() {
    this.layout = 'letters';
    this.emoji = false;
    this.strip = [null, null, null];
    this.bold = 1;
    this.prompt = null;
    this.shifted = false;
    this.capsLock = false;
    this.settingsOpened = 0;
  }
  setLayout(n) { this.layout = n; }
  showEmoji(s) { this.emoji = s; }
  clearStrip() { this.setSuggestions(null, null, null, 1); }
  setShift(s, l) { this.shifted = s; this.capsLock = l; }
  setSuggestions(a, b, c, bold) { this.strip = [a, b, c]; this.bold = bold; this.prompt = null; }
  setPrompt(t) { this.prompt = t; }
  hasPrompt() { return this.prompt !== null; }
  openSettings() { this.settingsOpened++; }
}

function snapshot(ime, ed, view) {
  return {
    text: ed.text, sel: ed.sel, cs: ed.cs, ce: ed.ce,
    strip: view.strip.slice(), prompt: view.prompt, shifted: view.shifted, lock: view.capsLock,
    layout: view.layout, emoji: view.emoji, settingsOpened: view.settingsOpened,
  };
}

/** Turns a script into events: "type:hello there" taps keys, "swipe:word" swipes, etc. */
function expand(script) {
  const ev = [];
  for (const step of script) {
    if (typeof step !== 'string') {
      ev.push(step);
      continue;
    }
    const i = step.indexOf(':');
    const op = i < 0 ? step : step.slice(0, i);
    const arg = i < 0 ? '' : step.slice(i + 1);
    if (op === 'type') {
      for (const ch of Array.from(arg)) {
        if (ch === ' ') ev.push({ t: 'key', code: 32 });
        else if (ch === '⇧') ev.push({ t: 'key', code: T.K.SHIFT });
        else if (ch === '⌫') ev.push({ t: 'del' });
        else if (ch === '⏎') ev.push({ t: 'key', code: T.K.ENTER });
        else if (/[a-z]/.test(ch) || ch.length === 1 && ch.charCodeAt(0) < 128) ev.push({ t: 'key', code: ch.charCodeAt(0) });
        else ev.push({ t: 'alt', ch });
        ev.push({ t: 'wait', ms: 120 });
      }
    } else if (op === 'swipe') {
      const p = swipeFor(arg, { jitter: 0.12 });
      ev.push({ t: 'swipe', word: arg, xs: p.xs, ys: p.ys });
      ev.push({ t: 'wait', ms: 400 });
    } else if (op === 'pick') ev.push({ t: 'strip', slot: Number(arg) });
    else if (op === 'hold') ev.push({ t: 'stripLong', slot: Number(arg) });
    else if (op === 'yes') ev.push({ t: 'strip', slot: T.PROMPT_YES });
    else if (op === 'no') ev.push({ t: 'strip', slot: T.PROMPT_NO });
    else if (op === 'gear') ev.push({ t: 'strip', slot: T.SLOT_GEAR });
    else if (op === 'del') ev.push({ t: 'del' });
    else if (op === 'wait') ev.push({ t: 'wait', ms: Number(arg) });
    else if (op === 'move') ev.push({ t: 'move', chars: Number(arg) });
    else if (op === 'place') ev.push({ t: 'place', index: Number(arg) });
    else if (op === 'emoji') ev.push({ t: 'emoji', text: arg });
    else if (op === 'key') ev.push({ t: 'key', code: Number(arg) });
    else if (op === 'alt') ev.push({ t: 'alt', ch: arg });
    else if (op === 'start') ev.push({ t: 'start' });
    else throw new Error('unknown step ' + step);
  }
  return ev;
}

const SESSIONS = [
  { name: 'typing basics', script: ['type:hello there. how are you', 'type: ', 'type:i think so'] },
  { name: 'smart fixes', script: ['type:dont ', 'type:im ', 'type:its ', 'type:i ', 'type:toronto ', 'type:cant '] },
  { name: 'revert a fix', script: ['type:dont ', 'del', 'type: ok', 'type:im', 'type: ', 'del', 'del'] },
  { name: 'pick suggestions', script: ['type:hel', 'pick:0', 'type:.', 'type:wor', 'pick:2', 'type:,', 'type:th', 'pick:1', 'type:!'] },
  { name: 'double space', script: ['type:ok', 'type: ', 'wait:100', 'type: ', 'type:so', 'type: ', 'wait:900', 'type: '] },
  { name: 'swipes', script: ['swipe:hello', 'swipe:world', 'type:.', 'swipe:thanks', 'type: ', 'swipe:keyboard', 'type:!'] },
  { name: 'swipe after punctuation', script: ['type:Done.', 'swipe:swipe', 'type:(', 'swipe:clear', 'type:)'] },
  { name: 'shift cycles a swipe', script: ['swipe:sense', 'type:⇧', 'type:⇧', 'type:⇧', 'type:⇧', 'type: '] },
  { name: 'correct a swipe', script: ['swipe:spot', 'pick:0', 'swipe:summary', 'pick:2', 'type: ', 'swipe:haha', 'pick:1'] },
  { name: 'delete and swipe again', script: ['swipe:clear', 'del', 'swipe:clear', 'type: ', 'swipe:haha', 'del', 'wait:25000', 'swipe:haha', 'type: '] },
  { name: 'block from strip', script: ['swipe:sense', 'hold:0', 'yes', 'hold:2', 'no', 'type: ', 'type:hel', 'hold:2', 'yes', 'type: '] },
  { name: 'prompt dismissed by typing', script: ['swipe:spot', 'hold:0', 'type:a', 'hold:1', 'type: '] },
  { name: 'gear and caps lock', script: ['gear', 'type:⇧', 'wait:100', 'type:⇧', 'type:abc def', 'type:⇧', 'type:ghi', 'type:⇧', 'type:⇧', 'type:jk'] },
  { name: 'symbols and emoji', script: ['type:hi', { t: 'key', code: T.K.SYMBOLS }, 'type:3', { t: 'key', code: T.K.SYMBOLS2 }, { t: 'key', code: T.K.LETTERS }, 'type:x', { t: 'key', code: T.K.EMOJI }, 'emoji:😀', 'emoji:👍', { t: 'emojiBack' }, 'del', 'del', 'type:ok'] },
  { name: 'enter and new lines', script: ['type:first line', 'type:⏎', 'type:second', 'swipe:hello', 'type:⏎', 'swipe:there'] },
  { name: 'cursor moves', script: ['type:one two three', 'move:-4', 'type:x', 'move:2', 'swipe:hello', 'move:-30', 'type:A ', 'move:100', 'type:z'] },
  { name: 'cursor placed', script: ['type:hello world', 'place:3', 'type:p', 'place:0', 'type:q', 'swipe:there', 'place:5', 'type:r'] },
  { name: 'apostrophes', script: ["type:don't ", "type:it’s ", "type:'quoted' ", "type:rock'n"] },
  { name: 'accents and alts', script: ['alt:é', 'type:t', 'alt:é', 'type: ', 'type:cafe', 'alt:…', 'type: ', 'alt:¿', 'swipe:que'] },
  { name: 'spanish context', langs: ['en', 'es'], script: ['type:hola como estas ', 'swipe:yo', 'swipe:quiero', 'type: tambien ', 'type:manana ', 'swipe:gracias', 'type:. '] },
  { name: 'switching languages', langs: ['en', 'es'], script: ['type:I think ', 'swipe:yo', 'type: ', 'type:hola amigo ', 'swipe:yo', 'type: ', 'swipe:que', 'pick:0'] },
  { name: 'fixed language', langs: ['en', 'es'], settings: { typingLang: 'es' }, script: ['type:the ', 'swipe:hello', 'type: tambien '] },
  { name: 'autocorrect on', settings: { autocorrect: true }, script: ['type:teh ', 'type:helo ', 'type:thnaks ', 'type:zzzq ', 'del', 'type:ok'] },
  { name: 'smart fix off', settings: { smartFix: false }, script: ['type:dont ', 'type:i ', 'type:toronto '] },
  { name: 'learning off', settings: { learn: false }, script: ['type:hello ', 'swipe:there', 'pick:0', 'type: '] },
  { name: 'swipe off', settings: { swipe: false }, script: ['swipe:hello', 'type:hi'] },
  { name: 'learned words', users: 'learned', langs: ['en', 'es'], script: ['swipe:haha', 'type: ', 'swipe:sense', 'type: ', 'type:Ter', 'pick:0', 'type:chi', 'type: ', 'swipe:yo'] },
  { name: 'restart mid word', script: ['type:hel', 'start', 'type:lo', 'swipe:there', 'start', 'type:x'] },
  { name: 'delete everything', script: ['type:ab cd', 'del', 'del', 'del', 'del', 'del', 'del', 'del', 'swipe:hi', 'del', 'del'] },
];

{
  const out = [];
  for (const sess of SESSIONS) {
    const langs = sess.langs || ['en'];
    const users = sess.users === 'learned' ? USERS : FRESH;
    const lex = lexicon(langs, users);
    const ed = new T.Editor();
    const view = new RecordingView();
    let clock = 1000;
    const ime = new T.Ime(ed, view, lex, () => clock);
    const corrections = [];
    ime.onCorrection = (c) => corrections.push([c.picked, c.pickedLang, c.guess, c.guessLang]);
    ime.onGeometry(CX, CY, KW);
    const settings = Object.assign({ swipe: true, smartFix: true, autocorrect: false, doubleSpace: true, learn: true, typingLang: 'auto', lastLang: 'en' }, sess.settings || {});
    ime.start(settings);
    const events = expand(sess.script);
    const steps = [];
    for (const e of events) {
      if (e.t === 'key') ime.onKey({ code: e.code });
      else if (e.t === 'alt') ime.typeAlt(e.ch);
      else if (e.t === 'del') ime.onDelete();
      else if (e.t === 'swipe') ime.onSwipe(e.xs, e.ys, e.xs.length, null);
      else if (e.t === 'strip') ime.onStripTap(e.slot);
      else if (e.t === 'stripLong') ime.onStripLongPress(e.slot);
      else if (e.t === 'move') ime.onCursorMove(e.chars);
      else if (e.t === 'place') ime.onCursorPlaced(e.index);
      else if (e.t === 'emoji') ime.onEmoji(e.text);
      else if (e.t === 'emojiBack') ime.onEmojiBack();
      else if (e.t === 'start') ime.start(settings);
      else if (e.t === 'wait') clock += e.ms;
      clock += 1;
      steps.push(snapshot(ime, ed, view));
    }
    out.push({
      name: sess.name, langs, learned: users === USERS, settings, events, steps, corrections,
      users: { en: lex.get('en').user.toJSON(), es: lex.get('es').user.toJSON() },
    });
  }
  files['sessions.json'] = { geometry: { cx: CX, cy: CY, kw: KW }, users: USERS, sessions: out };
}

// ---- write -------------------------------------------------------------------------------------------

let stale = [];
for (const name of Object.keys(files).sort()) {
  const body = JSON.stringify(files[name]) + '\n';
  const p = path.join(OUT, name);
  if (check) {
    if (!fs.existsSync(p) || fs.readFileSync(p, 'utf8') !== body) stale.push(name);
  } else {
    fs.mkdirSync(OUT, { recursive: true });
    fs.writeFileSync(p, body);
    console.log('wrote ' + path.relative(ROOT, p) + ' (' + body.length + ' bytes)');
  }
}
if (check) {
  if (stale.length) {
    console.log('out of date: ' + stale.join(', '));
    process.exit(1);
  }
  console.log('fixtures are up to date');
}
