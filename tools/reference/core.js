
/*
 * Trail keyboard engine, web build.
 * A port of the Android app's Java (app/src/com/trailkeys/keyboard): WordList,
 * SwipeDecoder, TypingSuggester, UserWords and TrailIME's typing logic, plus Editor,
 * a small model of a text field. On top of the Java version it handles several
 * languages: each has its own word list, learned words and never-suggest list, and the
 * language you're writing in is worked out from the words you've just typed.
 * With English alone it gives exactly the same results as the Android app.
 * Nothing here touches the page, so the same file runs under Node for testing.
 */
'use strict';

var Trail = (function () {
  const LETTER = /\p{L}/u;
  const OPEN_PUNCT = /\p{Ps}/u;
  const CLOSE_PUNCT = /\p{Pe}/u;
  const COMBINING = /[̀-ͯ]/g;
  const EMPTY_IDS = new Int32Array(0);

  function isLetter(ch) {
    return LETTER.test(ch);
  }

  function isUpper(ch) {
    return ch !== ch.toLowerCase() && ch === ch.toUpperCase();
  }

  /**
   * The letters a word is swiped or typed with, lowercase, accents removed:
   * "Don't" -> "dont", "mañana" -> "manana". "" if anything else is in the word.
   */
  function keyOf(word) {
    let out = '';
    for (let i = 0; i < word.length; i++) {
      let c = word.charCodeAt(i);
      if (c >= 65 && c <= 90) c += 32;
      if (c >= 97 && c <= 122) {
        out += String.fromCharCode(c);
        continue;
      }
      if (c === 39 || c === 0x2019) continue;
      if (c < 128) return '';
      const base = word[i].normalize('NFD').replace(COMBINING, '');
      if (base.length === 1) {
        let b = base.charCodeAt(0);
        if (b >= 65 && b <= 90) b += 32;
        if (b >= 97 && b <= 122) {
          out += String.fromCharCode(b);
          continue;
        }
      }
      return '';
    }
    return out;
  }

  // ---- word list ---------------------------------------------------------------------------

  class WordList {
    /** @param {string} text lines of "word<TAB>zipf*100", most common first */
    constructor(text) {
      const display = [];
      const keys = [];
      const score = [];
      let start = 0;
      const n = text.length;
      while (start < n) {
        let end = text.indexOf('\n', start);
        if (end < 0) end = n;
        const line = text.slice(start, end);
        start = end + 1;
        const tab = line.indexOf('\t');
        if (tab <= 0) continue;
        const s = parseInt(line.slice(tab + 1), 10);
        if (isNaN(s)) continue;
        const word = line.slice(0, tab);
        const key = keyOf(word);
        if (!key) continue;
        display.push(word);
        keys.push(key);
        score.push(s);
      }
      this.size = display.length;
      this.display = display;
      this.keys = keys;
      this.score = Int16Array.from(score);

      const counts = new Int32Array(676);
      const firstCounts = new Int32Array(26);
      for (let i = 0; i < this.size; i++) {
        const k = keys[i];
        counts[(k.charCodeAt(0) - 97) * 26 + (k.charCodeAt(k.length - 1) - 97)]++;
        firstCounts[k.charCodeAt(0) - 97]++;
      }
      this.byFirstLast = [];
      for (let b = 0; b < 676; b++) this.byFirstLast.push(new Int32Array(counts[b]));
      this.byFirst = [];
      for (let b = 0; b < 26; b++) this.byFirst.push(new Int32Array(firstCounts[b]));
      const fill = new Int32Array(676);
      const firstFill = new Int32Array(26);
      this.byLower = new Map();
      this.byKey = new Map();
      for (let i = 0; i < this.size; i++) {
        const k = keys[i];
        const f = k.charCodeAt(0) - 97;
        const b = f * 26 + (k.charCodeAt(k.length - 1) - 97);
        this.byFirstLast[b][fill[b]++] = i;
        this.byFirst[f][firstFill[f]++] = i;
        const lower = display[i].toLowerCase();
        if (!this.byLower.has(lower)) this.byLower.set(lower, i);
        let g = this.byKey.get(k);
        if (!g) {
          g = [];
          this.byKey.set(k, g);
        }
        g.push(i);
      }
      const order = [];
      for (let i = 0; i < this.size; i++) order.push(i);
      order.sort((a, b) => (keys[a] < keys[b] ? -1 : keys[a] > keys[b] ? 1 : 0));
      this.sorted = Int32Array.from(order);
    }

    withFirstLast(first, last) {
      return this.byFirstLast[first * 26 + last];
    }

    withFirst(first) {
      return this.byFirst[first];
    }

    /** Id of the word whose spelling matches ignoring case (accents count), or -1. */
    find(word) {
      const id = this.byLower.get(word.toLowerCase());
      return id === undefined ? -1 : id;
    }

    /** Ids of words with exactly this key ("its" gives its and it's, "ano" gives año and ano). */
    withKey(key) {
      return this.byKey.get(key) || EMPTY_IDS;
    }

    /** [start, end) positions, in key order, of words whose key starts with prefix. */
    prefixRange(prefix) {
      const keys = this.keys;
      const sorted = this.sorted;
      let lo = 0;
      let hi = this.size;
      while (lo < hi) {
        const mid = (lo + hi) >>> 1;
        if (keys[sorted[mid]] < prefix) lo = mid + 1;
        else hi = mid;
      }
      const a = lo;
      hi = this.size;
      const upper = prefix + '￿';
      while (lo < hi) {
        const mid = (lo + hi) >>> 1;
        if (keys[sorted[mid]] < upper) lo = mid + 1;
        else hi = mid;
      }
      return [a, lo];
    }

    sortedId(position) {
      return this.sorted[position];
    }
  }

  // ---- what it learns about you --------------------------------------------------------------

  const USE_WEIGHT = 0.9;
  const REJECT_WEIGHT = 0.8;
  const MAX_REJECTS = 5;
  const NEW_WORD_ACTIVE_USES = 2;
  const ADDED_WORD_ZIPF = 3.4;
  const STARTER_BLOCKS = ['Java', 'Cleo', 'haba', "Hab's"];

  /** Only plain words: letters with an optional inner apostrophe. */
  function isLearnable(word) {
    if (word == null) return false;
    const n = word.length;
    if (n === 0 || n > 30) return false;
    let letters = 0;
    for (let i = 0; i < n; i++) {
      const c = word[i];
      if (isLetter(c)) {
        letters++;
      } else if (c === "'" || c === '’') {
        if (i === 0 || i === n - 1) return false;
      } else {
        return false;
      }
    }
    return letters > 0;
  }

  class Entry {
    constructor(word) {
      this.word = word;
      this.uses = 0;
      this.rejects = 0;
      this.added = false;
    }

    /** Words you taught it start being suggested after two uses. */
    active() {
      return !this.added || this.uses >= NEW_WORD_ACTIVE_USES;
    }
  }

  /** One language's learned words and never-suggest list. */
  class UserWords {
    /** @param starters words blocked from the start (removable in settings) */
    constructor(starters) {
      this.starters = starters || STARTER_BLOCKS;
      this.entries = new Map();
      this.blocked = new Map();
      this.version = 0;
      this.onChange = null;
      for (const w of this.starters) this.blocked.set(w.toLowerCase(), w);
    }

    changed() {
      this.version++;
      if (this.onChange) this.onChange();
    }

    /** Personal adjustment in zipf units: up for words you use, down for ones you rejected. */
    bonus(word) {
      const e = this.entries.get(word.toLowerCase());
      if (!e) return 0;
      return USE_WEIGHT * Math.log(1 + e.uses) - REJECT_WEIGHT * Math.min(e.rejects, MAX_REJECTS);
    }

    isBlocked(word) {
      return this.blocked.has(word.toLowerCase());
    }

    get(word) {
      return this.entries.get(word.toLowerCase()) || null;
    }

    recordUse(word, amount, inBaseList) {
      if (!isLearnable(word) || this.isBlocked(word)) return;
      const k = word.toLowerCase();
      let e = this.entries.get(k);
      if (!e) {
        e = new Entry(word);
        e.added = !inBaseList;
        this.entries.set(k, e);
      }
      e.uses = Math.min(e.uses + amount, 100000);
      if (e.rejects > 0 && amount >= 2) e.rejects--;
      this.changed();
    }

    recordReject(word) {
      if (!isLearnable(word)) return;
      const k = word.toLowerCase();
      let e = this.entries.get(k);
      if (!e) {
        e = new Entry(word);
        this.entries.set(k, e);
      }
      if (e.rejects < MAX_REJECTS) e.rejects++;
      e.uses = Math.max(0, e.uses - 1);
      this.changed();
    }

    addManual(word) {
      word = word.trim();
      if (!isLearnable(word)) return false;
      const k = word.toLowerCase();
      this.blocked.delete(k);
      let e = this.entries.get(k);
      if (!e) {
        e = new Entry(word);
        e.added = true;
        this.entries.set(k, e);
      }
      e.uses = Math.max(e.uses, NEW_WORD_ACTIVE_USES);
      e.rejects = 0;
      this.changed();
      return true;
    }

    setInBaseList(word, inBase) {
      const e = this.entries.get(word.toLowerCase());
      if (e && e.added === inBase) {
        e.added = !inBase;
        this.changed();
      }
    }

    remove(word) {
      if (this.entries.delete(word.toLowerCase())) this.changed();
    }

    clearLearned() {
      if (this.entries.size > 0) {
        this.entries.clear();
        this.changed();
      }
    }

    block(word) {
      word = word.trim();
      if (!word) return;
      this.blocked.set(word.toLowerCase(), word);
      this.entries.delete(word.toLowerCase());
      this.changed();
    }

    unblock(word) {
      if (this.blocked.delete(word.toLowerCase())) this.changed();
    }

    blockedWords() {
      return Array.from(this.blocked.entries())
        .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
        .map((e) => e[1]);
    }

    /** Everything learned, most used first. */
    all() {
      const list = Array.from(this.entries.values());
      list.sort((a, b) => {
        if (b.uses !== a.uses) return b.uses - a.uses;
        const x = a.word.toLowerCase();
        const y = b.word.toLowerCase();
        return x < y ? -1 : x > y ? 1 : 0;
      });
      return list;
    }

    /** Words you taught it that are ready to be suggested. */
    activeAdded() {
      const list = [];
      for (const e of this.entries.values()) {
        if (e.added && e.active() && keyOf(e.word)) list.push(e);
      }
      return list;
    }

    count() {
      return this.entries.size;
    }

    toJSON(maxEntries) {
      let list = this.all();
      if (maxEntries && list.length > maxEntries) list = list.slice(0, maxEntries);
      return {
        learned: list.map((e) => [e.word, Math.round(e.uses * 10) / 10, e.rejects, e.added ? 1 : 0]),
        blocked: this.blockedWords(),
      };
    }

    /** Replaces everything with a saved copy. A copy with no blocked list gets the starter blocks. */
    load(data) {
      this.entries.clear();
      this.blocked.clear();
      const learned = data && Array.isArray(data.learned) ? data.learned : [];
      for (const row of learned) {
        if (!Array.isArray(row) || !isLearnable(row[0])) continue;
        const e = new Entry(row[0]);
        e.uses = Number(row[1]) || 0;
        e.rejects = Math.max(0, Math.min(MAX_REJECTS, Number(row[2]) || 0));
        e.added = row[3] === 1 || row[3] === true;
        this.entries.set(e.word.toLowerCase(), e);
      }
      if (data && Array.isArray(data.blocked)) {
        for (const w of data.blocked) {
          if (typeof w === 'string' && w.trim()) this.blocked.set(w.trim().toLowerCase(), w.trim());
        }
      } else {
        for (const w of this.starters) this.blocked.set(w.toLowerCase(), w);
      }
      this.version++;
    }
  }

  // ---- languages -----------------------------------------------------------------------------

  const LANG_INFO = {
    en: { name: 'English', short: 'EN', starters: STARTER_BLOCKS },
    es: { name: 'Español', short: 'ES', starters: ['haba', 'java'] },
  };

  /**
   * While you write in one language, words from the others count as this much rarer, in
   * zipf units (1 = ten times rarer). They can still win when your swipe clearly fits them.
   */
  const LANG_PENALTY = 1.5;

  /** Every language the keyboard knows: its word list (once loaded) and what it has learned. */
  class Lexicon {
    constructor() {
      this.langs = [];
    }

    add(code) {
      const info = LANG_INFO[code] || { name: code, short: code.toUpperCase(), starters: [] };
      const L = { code, name: info.name, short: info.short, words: null, user: new UserWords(info.starters), enabled: false };
      this.langs.push(L);
      return L;
    }

    get(code) {
      for (const L of this.langs) if (L.code === code) return L;
      return null;
    }

    /** Languages that are switched on and whose word list is loaded. */
    enabled() {
      return this.langs.filter((L) => L.enabled && L.words);
    }
  }

  // Word sources are {words, user, bias, lang}, one per language, with the language you're
  // writing in first at full weight and the others marked down (bias < 0).

  /** The source for the language you're writing in, or null. */
  function primaryOf(sources) {
    const P = sources && sources[0];
    return P && !(P.bias < 0) ? P : null;
  }

  /** A source for a language you're not writing in right now. */
  function isForeign(S, P) {
    return !!P && S !== P && S.bias < 0;
  }

  /**
   * What you've done with a word, in zipf units, for one source. For a language you're not
   * writing in only the minuses count, from that language or the one you are writing in:
   * using "yo" a lot in Spanish shouldn't make it come up while you write English.
   */
  function bonusIn(S, P, word) {
    if (!isForeign(S, P)) return S.user ? S.user.bonus(word) : 0;
    let b = S.user ? Math.min(0, S.user.bonus(word)) : 0;
    if (P.user) b += Math.min(0, P.user.bonus(word));
    return b;
  }

  /** Blocked in the word's own language, or (for another language's word) in the one you're writing in. */
  function blockedIn(S, P, word) {
    if (S.user && S.user.isBlocked(word)) return true;
    return isForeign(S, P) && !!P.user && P.user.isBlocked(word);
  }

  /**
   * Which words of list W the list P also has, spelled the same. While you write P's language
   * those count as P's words, at P's frequency, so W's copy is left out: "yo" stays rare in
   * English even though it's common in Spanish. Worked out once per pair of lists.
   */
  function sharedWith(W, P) {
    if (!W.shared) W.shared = new Map();
    let s = W.shared.get(P);
    if (!s) {
      if (!P.displaySet) P.displaySet = new Set(P.display);
      const set = P.displaySet;
      s = new Uint8Array(W.size);
      for (let i = 0; i < W.size; i++) if (set.has(W.display[i])) s[i] = 1;
      W.shared.set(P, s);
    }
    return s;
  }

  /** Works out the shared words for every pair of these languages now, rather than on the first swipe. */
  function prepareShared(langs) {
    for (const A of langs) {
      for (const B of langs) if (A !== B && A.words && B.words) sharedWith(B.words, A.words);
    }
  }

  /** How strongly a word says "this language": its zipf frequency there, or low if unknown. */
  function wordEvidence(L, w) {
    const id = L.words.find(w);
    if (id >= 0) return L.words.score[id] / 100;
    const e = L.user.get(w);
    if (e && e.uses > 0) return ADDED_WORD_ZIPF;
    const key = keyOf(w);
    if (key) {
      let best = 0;
      for (const j of L.words.withKey(key)) best = Math.max(best, L.words.score[j] / 100);
      if (best > 0) return best - 0.5; // typed without its accents
    }
    return 1.0;
  }

  /**
   * The language of the last few words before the cursor (in the current line), or null when
   * they don't clearly favour one. Recent words count most.
   */
  function detectLang(text, langs) {
    if (langs.length < 2) return langs.length ? langs[0].code : null;
    const line = text.slice(text.lastIndexOf('\n') + 1);
    const tokens = line.match(/[\p{L}'’]+/gu);
    if (!tokens) return null;
    const recent = tokens.slice(-8);
    const scores = langs.map(() => 0);
    let weight = 1;
    for (let t = recent.length - 1; t >= 0; t--) {
      for (let i = 0; i < langs.length; i++) scores[i] += weight * wordEvidence(langs[i], recent[t]);
      weight *= 0.85;
    }
    let best = 0;
    for (let i = 1; i < langs.length; i++) if (scores[i] > scores[best]) best = i;
    let second = -Infinity;
    for (let i = 0; i < langs.length; i++) if (i !== best) second = Math.max(second, scores[i]);
    return scores[best] - second >= 1.0 ? langs[best].code : null;
  }

  // ---- swipe decoder -------------------------------------------------------------------------

  function dist(ax, ay, bx, by) {
    const dx = ax - bx;
    const dy = ay - by;
    return Math.sqrt(dx * dx + dy * dy);
  }

  function pathLength(x, y, n) {
    let len = 0;
    for (let i = 1; i < n; i++) len += dist(x[i - 1], y[i - 1], x[i], y[i]);
    return len;
  }

  /** Resamples a polyline to n points spaced evenly along its length. */
  function resample(x, y, count, ox, oy, n) {
    const total = pathLength(x, y, count);
    if (total <= 0 || count < 2) {
      for (let i = 0; i < n; i++) {
        ox[i] = x[0];
        oy[i] = y[0];
      }
      return;
    }
    const step = total / (n - 1);
    ox[0] = x[0];
    oy[0] = y[0];
    let outI = 1;
    let carried = 0;
    let prevX = x[0];
    let prevY = y[0];
    let i = 1;
    while (i < count && outI < n - 1) {
      const seg = dist(prevX, prevY, x[i], y[i]);
      if (carried + seg >= step && seg > 0) {
        const r = (step - carried) / seg;
        const nx = prevX + r * (x[i] - prevX);
        const ny = prevY + r * (y[i] - prevY);
        ox[outI] = nx;
        oy[outI] = ny;
        outI++;
        prevX = nx;
        prevY = ny;
        carried = 0;
      } else {
        carried += seg;
        prevX = x[i];
        prevY = y[i];
        i++;
      }
    }
    while (outI < n) {
      ox[outI] = x[count - 1];
      oy[outI] = y[count - 1];
      outI++;
    }
  }

  // ---- how you swipe ---------------------------------------------------------------------------

  const ROLE_START = 0;
  const ROLE_CORNER = 1;
  const ROLE_END = 2;
  /** A letter where the path turns more than about 40 degrees counts as a corner. */
  const CORNER_MIN = 0.7;
  const ROLE_DIR = new Float64Array(2);
  /** Points a swipe is resampled to before it's lined up with its letters. */
  const ALIGN_POINTS = 64;
  /** Each new test swipe makes the older ones count this much less, so the profile follows changes. */
  const PROFILE_DECAY = 0.997;
  /** Test swipes before the profile starts adjusting anything. */
  const PROFILE_MIN_SWIPES = 20;
  /** About where more test swipes stop helping. */
  const PROFILE_FULL_SWIPES = 150;
  /** A key's own offset counts fully only after about this many swipes over it (fewer: it leans on the overall one). */
  const KEY_SHRINK = 8;
  const GLOBAL_SHRINK = 3;
  const ROLE_SHRINK = 5;
  /** A letter counts as missed when the swipe passes outside its key, made this much bigger. */
  const MISS_SLACK = 1.2;

  /**
   * What a letter is in a word's path: the first one, a corner, the last one, or -1 for a
   * letter the path goes straight through. dir gets the direction its habit is measured along:
   * leaving the first letter, into the inside of a corner, arriving at the last letter.
   */
  function nodeRole(cx, cy, tpl, t, i, dir) {
    if (t < 2) return -1;
    if (i === 0 || i === t - 1) {
      const a = i === 0 ? tpl[0] : tpl[t - 2];
      const b = i === 0 ? tpl[1] : tpl[t - 1];
      const dx = cx[b] - cx[a];
      const dy = cy[b] - cy[a];
      const len = Math.sqrt(dx * dx + dy * dy);
      if (len < 1e-9) return -1;
      dir[0] = dx / len;
      dir[1] = dy / len;
      return i === 0 ? ROLE_START : ROLE_END;
    }
    const ax = cx[tpl[i]] - cx[tpl[i - 1]];
    const ay = cy[tpl[i]] - cy[tpl[i - 1]];
    const bx = cx[tpl[i + 1]] - cx[tpl[i]];
    const by = cy[tpl[i + 1]] - cy[tpl[i]];
    const la = Math.sqrt(ax * ax + ay * ay);
    const lb = Math.sqrt(bx * bx + by * by);
    if (la < 1e-9 || lb < 1e-9) return -1;
    const wx = bx / lb - ax / la;
    const wy = by / lb - ay / la;
    const lw = Math.sqrt(wx * wx + wy * wy);
    if (lw < CORNER_MIN) return -1;
    dir[0] = wx / lw;
    dir[1] = wy / lw;
    return ROLE_CORNER;
  }

  /**
   * For each letter of a word (repeats merged), the point of the swipe that goes with it: the
   * first point for the first letter, the last point for the last, and for the ones between the
   * closest point, in order.
   */
  function alignNodes(px, py, m, nodes, cx, cy) {
    const R = ALIGN_POINTS;
    const ax = new Float64Array(R);
    const ay = new Float64Array(R);
    resample(px, py, m, ax, ay, R);
    const t = nodes.length;
    const outX = new Array(t);
    const outY = new Array(t);
    outX[0] = px[0];
    outY[0] = py[0];
    outX[t - 1] = px[m - 1];
    outY[t - 1] = py[m - 1];
    if (t > 2) {
      const INF = 1e30;
      let best = new Float64Array(R).fill(INF);
      best[0] = 0;
      const back = [];
      for (let j = 1; j <= t - 2; j++) {
        const k = nodes[j];
        const cur = new Float64Array(R);
        const bk = new Int32Array(R);
        let pm = INF;
        let pi = 0;
        for (let i = 0; i < R; i++) {
          if (best[i] < pm) {
            pm = best[i];
            pi = i;
          }
          const dx = ax[i] - cx[k];
          const dy = ay[i] - cy[k];
          cur[i] = pm + dx * dx + dy * dy;
          bk[i] = pi;
        }
        back[j] = bk;
        best = cur;
      }
      let i = 0;
      for (let q = 1; q < R; q++) if (best[q] < best[i]) i = q;
      for (let j = t - 2; j >= 1; j--) {
        outX[j] = ax[i];
        outY[j] = ay[i];
        i = back[j][i];
      }
    }
    return { x: outX, y: outY };
  }

  /**
   * How you swipe, learned from test swipes where the word is known: where your finger really
   * goes for each key, how far short of (or past) the last letter you stop, where you start,
   * and how much you cut corners. It keeps running totals only, never the swipes themselves.
   * All distances are in key widths.
   */
  class SwipeProfile {
    constructor() {
      this.reset();
    }

    reset() {
      this.total = 0; // test swipes learned from
      this.n = 0; // the same, with older ones counting a little less
      this.N = 0; // letters seen
      this.sy = new Float64Array(2);
      this.nk = new Float64Array(26);
      this.syk = new Float64Array(52);
      this.missk = new Float64Array(26);
      this.nr = new Float64Array(3);
      this.su = new Float64Array(6);
      this.sry = new Float64Array(6);
      this.m2 = new Float64Array(6);
      this.nkr = new Float64Array(78);
      this.suk = new Float64Array(156);
      /** Test swipes since it switched on: how many were right first time with it, and without it. */
      this.ab = { n: 0, on: 0, off: 0 };
      this.fitted = null;
    }

    /** Learns from a swipe lined up with its word (SwipeDecoder.align). Returns what stood out about it. */
    learn(al) {
      const notes = this.check(al);
      const all = [this.sy, this.nk, this.syk, this.missk, this.nr, this.su, this.sry, this.m2, this.nkr, this.suk];
      for (const a of all) for (let i = 0; i < a.length; i++) a[i] *= PROFILE_DECAY;
      this.n = this.n * PROFILE_DECAY + 1;
      this.N *= PROFILE_DECAY;
      this.total++;
      const cx = al.cx;
      const cy = al.cy;
      const t = al.nodes.length;
      for (let i = 0; i < t; i++) {
        const k = al.nodes[i];
        const yx = al.x[i] - cx[k];
        const yy = al.y[i] - cy[k];
        this.N += 1;
        this.sy[0] += yx;
        this.sy[1] += yy;
        this.nk[k] += 1;
        this.syk[2 * k] += yx;
        this.syk[2 * k + 1] += yy;
        if (notes.missed.indexOf(i) >= 0) this.missk[k] += 1;
        const role = nodeRole(cx, cy, al.nodes, t, i, ROLE_DIR);
        if (role < 0) continue;
        const ux = ROLE_DIR[0];
        const uy = ROLE_DIR[1];
        const along = ux * yx + uy * yy;
        const cross = -uy * yx + ux * yy;
        this.nr[role] += 1;
        this.su[2 * role] += ux;
        this.su[2 * role + 1] += uy;
        this.sry[2 * role] += along;
        this.sry[2 * role + 1] += cross;
        this.m2[2 * role] += along * along;
        this.m2[2 * role + 1] += cross * cross;
        this.nkr[k * 3 + role] += 1;
        this.suk[(k * 3 + role) * 2] += ux;
        this.suk[(k * 3 + role) * 2 + 1] += uy;
      }
      this.fitted = null;
      return notes;
    }

    /**
     * What stood out about one swipe: letters it missed (by index in al.nodes) and how far
     * along the path it stopped past (+) or short of (-) the last letter, and started off the first.
     */
    check(al) {
      const cx = al.cx;
      const cy = al.cy;
      const t = al.nodes.length;
      const halfW = 0.5 * MISS_SLACK;
      const halfH = ((cy[0] - cy[16]) / 2) * MISS_SLACK; // a (row 2) minus q (row 1): one row
      const missed = [];
      for (let i = 0; i < t; i++) {
        const k = al.nodes[i];
        if (Math.abs(al.x[i] - cx[k]) > halfW || Math.abs(al.y[i] - cy[k]) > halfH) missed.push(i);
      }
      let endAlong = 0;
      let startAlong = 0;
      if (nodeRole(cx, cy, al.nodes, t, t - 1, ROLE_DIR) === ROLE_END) {
        const k = al.nodes[t - 1];
        endAlong = ROLE_DIR[0] * (al.x[t - 1] - cx[k]) + ROLE_DIR[1] * (al.y[t - 1] - cy[k]);
      }
      if (nodeRole(cx, cy, al.nodes, t, 0, ROLE_DIR) === ROLE_START) {
        const k = al.nodes[0];
        startAlong = ROLE_DIR[0] * (al.x[0] - cx[k]) + ROLE_DIR[1] * (al.y[0] - cy[k]);
      }
      return { missed, endAlong, startAlong };
    }

    /** True once it has enough to go on. */
    ready() {
      return this.total >= PROFILE_MIN_SWIPES;
    }

    /**
     * The fitted profile for SwipeDecoder.setProfile, or null before it's ready: each key's offset
     * (dx, dy), and the start, corner and end habits as [along, across] the path.
     */
    params() {
      if (!this.ready()) return null;
      if (this.fitted) return this.fitted;
      let gx = 0;
      let gy = 0;
      const d = new Float64Array(52);
      const b = [[0, 0], [0, 0], [0, 0]];
      // Each part in turn, holding the others: per-key offsets, the overall offset, the habits.
      for (let it = 0; it < 12; it++) {
        for (let k = 0; k < 26; k++) {
          let rx = this.syk[2 * k] - this.nk[k] * gx;
          let ry = this.syk[2 * k + 1] - this.nk[k] * gy;
          for (let r = 0; r < 3; r++) {
            const sx = this.suk[(k * 3 + r) * 2];
            const sy = this.suk[(k * 3 + r) * 2 + 1];
            rx -= b[r][0] * sx - b[r][1] * sy;
            ry -= b[r][0] * sy + b[r][1] * sx;
          }
          d[2 * k] = rx / (this.nk[k] + KEY_SHRINK);
          d[2 * k + 1] = ry / (this.nk[k] + KEY_SHRINK);
        }
        let ox = this.sy[0];
        let oy = this.sy[1];
        for (let k = 0; k < 26; k++) {
          ox -= this.nk[k] * d[2 * k];
          oy -= this.nk[k] * d[2 * k + 1];
        }
        for (let r = 0; r < 3; r++) {
          ox -= b[r][0] * this.su[2 * r] - b[r][1] * this.su[2 * r + 1];
          oy -= b[r][0] * this.su[2 * r + 1] + b[r][1] * this.su[2 * r];
        }
        gx = ox / (this.N + GLOBAL_SHRINK);
        gy = oy / (this.N + GLOBAL_SHRINK);
        for (let r = 0; r < 3; r++) {
          let a = this.sry[2 * r] - (gx * this.su[2 * r] + gy * this.su[2 * r + 1]);
          let c = this.sry[2 * r + 1] - (-gx * this.su[2 * r + 1] + gy * this.su[2 * r]);
          for (let k = 0; k < 26; k++) {
            const sx = this.suk[(k * 3 + r) * 2];
            const sy = this.suk[(k * 3 + r) * 2 + 1];
            a -= d[2 * k] * sx + d[2 * k + 1] * sy;
            c -= -d[2 * k] * sy + d[2 * k + 1] * sx;
          }
          b[r][0] = a / (this.nr[r] + ROLE_SHRINK);
          b[r][1] = c / (this.nr[r] + ROLE_SHRINK);
        }
      }
      const dx = new Float64Array(26);
      const dy = new Float64Array(26);
      for (let k = 0; k < 26; k++) {
        dx[k] = gx + d[2 * k];
        dy[k] = gy + d[2 * k + 1];
      }
      const reach = b.map((v) => Math.sqrt(v[0] * v[0] + v[1] * v[1]));
      this.fitted = { dx, dy, overall: [gx, gy], bias: b, reach };
      return this.fitted;
    }

    /** Plain numbers about your habits, for showing. */
    summary() {
      const P = this.params();
      const keys = [];
      for (let k = 0; k < 26; k++) {
        if (this.nk[k] >= 4) keys.push({ key: String.fromCharCode(97 + k), seen: this.nk[k], missRate: this.missk[k] / this.nk[k] });
      }
      keys.sort((a, b) => b.missRate - a.missRate);
      let keysSeen = 0;
      for (let k = 0; k < 26; k++) if (this.nk[k] >= KEY_SHRINK) keysSeen++;
      return {
        total: this.total,
        ready: !!P,
        progress: Math.min(1, this.total / PROFILE_FULL_SWIPES),
        minSwipes: PROFILE_MIN_SWIPES,
        fullSwipes: PROFILE_FULL_SWIPES,
        keysSeen,
        start: P ? P.bias[ROLE_START] : null,
        corner: P ? P.bias[ROLE_CORNER] : null,
        end: P ? P.bias[ROLE_END] : null,
        overall: P ? P.overall : null,
        missedKeys: keys.filter((e) => e.missRate >= 0.25).slice(0, 3),
        ab: Object.assign({}, this.ab),
      };
    }

    /** How many times each key has been seen first, anywhere, and last (for picking test words). */
    seen(k) {
      return { all: this.nk[k], first: this.nkr[k * 3 + ROLE_START], last: this.nkr[k * 3 + ROLE_END] };
    }

    toJSON() {
      const r = (a) => Array.from(a, (v) => Math.round(v * 10000) / 10000);
      return {
        v: 1,
        total: this.total,
        n: r([this.n])[0],
        N: r([this.N])[0],
        sy: r(this.sy),
        nk: r(this.nk),
        syk: r(this.syk),
        missk: r(this.missk),
        nr: r(this.nr),
        su: r(this.su),
        sry: r(this.sry),
        m2: r(this.m2),
        nkr: r(this.nkr),
        suk: r(this.suk),
        ab: { n: this.ab.n, on: this.ab.on, off: this.ab.off },
      };
    }

    /** Replaces everything with a saved copy (anything malformed starts it over). */
    load(data) {
      this.reset();
      if (!data || typeof data !== 'object' || data.v !== 1) return;
      const sizes = { sy: 2, nk: 26, syk: 52, missk: 26, nr: 3, su: 6, sry: 6, m2: 6, nkr: 78, suk: 156 };
      for (const name in sizes) {
        const a = data[name];
        if (!Array.isArray(a) || a.length !== sizes[name] || !a.every((v) => typeof v === 'number' && isFinite(v))) {
          this.reset();
          return;
        }
        this[name] = Float64Array.from(a);
      }
      this.total = Number(data.total) || 0;
      this.n = Number(data.n) || 0;
      this.N = Number(data.N) || 0;
      const ab = data.ab || {};
      this.ab = { n: Number(ab.n) || 0, on: Number(ab.on) || 0, off: Number(ab.off) || 0 };
    }
  }

  /** Same tuning as the Android app (chosen with its simulator). */
  const DECODER_DEFAULTS = {
    samples: 50,
    band: 12,
    endRadius: 1.4,
    maxEndKeys: 4,
    wLoc: 4,
    wEnd: 1,
    wFreq: 0.35,
    wUser: 0.35,
    prefilter: 300,
    cheapSamples: 12,
    minLengthRatio: 0.7,
    maxLengthRatio: 2.2,
  };

  const SRC_SHIFT = 0x1000000;

  /**
   * Swipe path -> ranked words. Only words that start near where the finger went down and
   * end near where it lifted are considered; each candidate's ideal path is compared with
   * the swipe (a quick pass, then dynamic time warping for the best few hundred), and the
   * result is weighed with how common the word is and your own history with it.
   *
   * Words come from "sources": one per language, each {words, user, bias, lang}, where bias
   * is added to the word's frequency (0 for the language you're writing in).
   */
  class SwipeDecoder {
    constructor(params) {
      this.params = Object.assign({}, DECODER_DEFAULTS, params || {});
      const n = this.params.samples;
      const c = this.params.cheapSamples;
      this.cx = new Float64Array(26);
      this.cy = new Float64Array(26);
      this.keyWidth = 1;
      this.hasGeometry = false;
      this.gx = new Float64Array(n);
      this.gy = new Float64Array(n);
      this.tx = new Float64Array(n);
      this.ty = new Float64Array(n);
      this.dtwPrev = new Float64Array(n);
      this.dtwCur = new Float64Array(n);
      this.hx = new Float64Array(c);
      this.hy = new Float64Array(c);
      this.ux = new Float64Array(c);
      this.uy = new Float64Array(c);
      this.tpl = new Int32Array(64);
      this.tplX = new Float64Array(64);
      this.tplY = new Float64Array(64);
      this.dS = new Float64Array(26);
      this.dE = new Float64Array(26);
      this.candId = new Int32Array(4096);
      this.candCheap = new Float64Array(4096);
      this.candFixed = new Float64Array(4096);
      /** Where your finger goes for each key: the key centers moved by your swipe profile. */
      this.ex = new Float64Array(26);
      this.ey = new Float64Array(26);
      /** Your swipe profile (SwipeProfile.params()), or null. */
      this.profile = null;
      this.gsx = 0;
      this.gsy = 0;
      this.gex = 0;
      this.gey = 0;
    }

    /** Key centers for a..z and the width of one letter key, in the swipe's pixel space. */
    setKeyCenters(xPx, yPx, keyWidthPx) {
      this.keyWidth = keyWidthPx;
      for (let i = 0; i < 26; i++) {
        this.cx[i] = xPx[i] / keyWidthPx;
        this.cy[i] = yPx[i] / keyWidthPx;
      }
      this.hasGeometry = true;
      this.placeKeys();
    }

    /** Uses a swipe profile from SwipeProfile.params() (null for none). */
    setProfile(params) {
      this.profile = params || null;
      this.placeKeys();
    }

    placeKeys() {
      const P = this.profile;
      for (let i = 0; i < 26; i++) {
        this.ex[i] = P ? this.cx[i] + P.dx[i] : this.cx[i];
        this.ey[i] = P ? this.cy[i] + P.dy[i] : this.cy[i];
      }
    }

    /**
     * The path your finger is expected to take for the template in tpl[0..t): through each
     * key's spot, starting and stopping where you tend to, cutting corners as you do.
     */
    placeNodes(t) {
      const tpl = this.tpl;
      const X = this.tplX;
      const Y = this.tplY;
      const P = this.profile;
      if (!P) {
        for (let i = 0; i < t; i++) {
          X[i] = this.cx[tpl[i]];
          Y[i] = this.cy[tpl[i]];
        }
        return;
      }
      for (let i = 0; i < t; i++) {
        X[i] = this.ex[tpl[i]];
        Y[i] = this.ey[tpl[i]];
      }
      if (t < 2) return;
      const cx = this.cx;
      const cy = this.cy;
      for (let i = 0; i < t; i++) {
        // Everyone's path rounds corners and the comparison already allows for that, so only
        // the first and last letters move (unless useCorner is set, for experiments).
        if (i > 0 && i < t - 1 && !P.useCorner) continue;
        const role = nodeRole(cx, cy, tpl, t, i, ROLE_DIR);
        if (role < 0) continue;
        const b = P.bias[role];
        X[i] += b[0] * ROLE_DIR[0] - b[1] * ROLE_DIR[1];
        Y[i] += b[0] * ROLE_DIR[1] + b[1] * ROLE_DIR[0];
      }
    }

    /**
     * Lines up a swipe with the word it was meant to be. Returns the key of each letter (repeats
     * merged) and the point of the swipe that goes with it, in key widths, or null.
     */
    align(word, xs, ys, count) {
      if (!this.hasGeometry) return null;
      const key = keyOf(word);
      const t = this.buildTemplate(key);
      if (t < 2 || count < 2) return null;
      const px = new Float64Array(count);
      const py = new Float64Array(count);
      let m = 0;
      for (let i = 0; i < count; i++) {
        const x = xs[i] / this.keyWidth;
        const y = ys[i] / this.keyWidth;
        if (m > 0 && Math.abs(x - px[m - 1]) + Math.abs(y - py[m - 1]) < 1e-4) continue;
        px[m] = x;
        py[m] = y;
        m++;
      }
      if (m < 2) return null;
      const nodes = Array.from(this.tpl.subarray(0, t));
      const at = alignNodes(px, py, m, nodes, this.cx, this.cy);
      return { nodes, x: at.x, y: at.y, cx: this.cx, cy: this.cy };
    }

    ready() {
      return this.hasGeometry;
    }

    /** @returns {{word: string, cost: number, lang: string}[]} best first */
    decode(xs, ys, count, sources, max) {
      const out = [];
      if (!this.hasGeometry || count < 2 || !sources || !sources.length) return out;
      const p = this.params;
      const px = new Float64Array(count);
      const py = new Float64Array(count);
      let m = 0;
      for (let i = 0; i < count; i++) {
        const x = xs[i] / this.keyWidth;
        const y = ys[i] / this.keyWidth;
        if (m > 0 && Math.abs(x - px[m - 1]) + Math.abs(y - py[m - 1]) < 1e-4) continue;
        px[m] = x;
        py[m] = y;
        m++;
      }
      if (m < 2) return out;
      const gLen = pathLength(px, py, m);
      if (gLen < 0.5) return out;

      const n = p.samples;
      resample(px, py, m, this.gx, this.gy, n);
      resample(px, py, m, this.hx, this.hy, p.cheapSamples);

      const sx = px[0];
      const sy = py[0];
      const ex = px[m - 1];
      const ey = py[m - 1];
      this.gsx = sx;
      this.gsy = sy;
      this.gex = ex;
      this.gey = ey;
      for (let k = 0; k < 26; k++) {
        this.dS[k] = dist(sx, sy, this.ex[k], this.ey[k]);
        this.dE[k] = dist(ex, ey, this.ex[k], this.ey[k]);
      }
      // With a profile, where you start and stop can sit further from the key (by your habit).
      const prof = this.profile;
      const startOk = prof ? this.nearestKeys(this.dS, p.endRadius + prof.reach[ROLE_START], p.maxEndKeys + 1) : this.nearestKeys(this.dS);
      const endOk = prof ? this.nearestKeys(this.dE, p.endRadius + prof.reach[ROLE_END], p.maxEndKeys + 1) : this.nearestKeys(this.dE);

      // Pass 1: quick score for every word with a plausible first and last letter.
      const P = primaryOf(sources);
      let c = 0;
      for (let si = 0; si < sources.length; si++) {
        const S = sources[si];
        const W = S.words;
        const bias = S.bias || 0;
        const shared = isForeign(S, P) ? sharedWith(W, P.words) : null;
        for (let f = 0; f < 26; f++) {
          if (!startOk[f]) continue;
          for (let l = 0; l < 26; l++) {
            if (!endOk[l]) continue;
            const ids = W.withFirstLast(f, l);
            for (let q = 0; q < ids.length; q++) {
              const id = ids[q];
              if (shared !== null && shared[id] === 1) continue;
              let prior = p.wFreq * (W.score[id] / 100 + bias);
              if (S.user) prior += p.wUser * bonusIn(S, P, W.display[id]);
              c = this.consider(si * SRC_SHIFT + id, W.keys[id], prior, gLen, c);
            }
          }
        }
      }
      // Words you taught it, per language.
      const added = [];
      for (let si = 0; si < sources.length; si++) {
        const S = sources[si];
        if (!S.user) continue;
        const foreign = isForeign(S, P);
        for (const e of S.user.activeAdded()) {
          const key = keyOf(e.word);
          if (!key || S.words.find(e.word) >= 0) continue;
          if (foreign && P.words.find(e.word) >= 0) continue;
          if (!startOk[key.charCodeAt(0) - 97] || !endOk[key.charCodeAt(key.length - 1) - 97]) continue;
          added.push({ word: e.word, key, si });
          const prior = p.wFreq * (ADDED_WORD_ZIPF + (S.bias || 0)) + p.wUser * bonusIn(S, P, e.word);
          c = this.consider(-added.length, key, prior, gLen, c);
        }
      }
      if (c === 0) return out;

      // Pass 2: careful score for the best few hundred.
      const order = new Array(c);
      for (let i = 0; i < c; i++) order[i] = i;
      const cheap = this.candCheap;
      order.sort((a, b) => cheap[a] - cheap[b]);
      const keep = Math.min(c, p.prefilter);
      const finalCost = new Float64Array(keep);
      const finalWord = new Array(keep);
      const finalSrc = new Int32Array(keep);
      for (let r = 0; r < keep; r++) {
        const slot = order[r];
        const cid = this.candId[slot];
        let key;
        if (cid >= 0) {
          const S = sources[(cid / SRC_SHIFT) | 0];
          const id = cid % SRC_SHIFT;
          key = S.words.keys[id];
          finalWord[r] = S.words.display[id];
          finalSrc[r] = (cid / SRC_SHIFT) | 0;
        } else {
          const a = added[-cid - 1];
          key = a.key;
          finalWord[r] = a.word;
          finalSrc[r] = a.si;
        }
        const t = this.buildTemplate(key);
        this.placeNodes(t);
        this.resampleTemplate(t, this.tx, this.ty, n);
        const d = this.dtw(this.gx, this.gy, this.tx, this.ty, n, p.band);
        finalCost[r] = p.wLoc * d + this.candFixed[slot];
      }
      const rank = new Array(keep);
      for (let i = 0; i < keep; i++) rank[i] = i;
      rank.sort((a, b) => finalCost[a] - finalCost[b]);
      const seen = new Set();
      for (let i = 0; i < keep && out.length < max; i++) {
        const w = finalWord[rank[i]];
        const S = sources[finalSrc[rank[i]]];
        const lower = w.toLowerCase();
        if (seen.has(lower)) continue;
        if (blockedIn(S, P, w)) continue;
        seen.add(lower);
        out.push({ word: w, cost: finalCost[rank[i]], lang: S.lang || null });
      }
      return out;
    }

    consider(id, key, prior, gLen, c) {
      const p = this.params;
      const t = this.buildTemplate(key);
      if (t < 2) return c;
      this.placeNodes(t);
      const X = this.tplX;
      const Y = this.tplY;
      let len = 0;
      for (let i = 1; i < t; i++) len += dist(X[i - 1], Y[i - 1], X[i], Y[i]);
      if (len < p.minLengthRatio * gLen - 1 || len > p.maxLengthRatio * gLen + 1) return c;
      let fixed;
      if (this.profile) {
        // Distance from where you started and stopped to where you'd start and stop for this word.
        const ds = dist(this.gsx, this.gsy, X[0], Y[0]);
        const de = dist(this.gex, this.gey, X[t - 1], Y[t - 1]);
        fixed = p.wEnd * (ds * ds + de * de) - prior;
      } else {
        const f = this.tpl[0];
        const l = this.tpl[t - 1];
        fixed = p.wEnd * (this.dS[f] * this.dS[f] + this.dE[l] * this.dE[l]) - prior;
      }
      this.resampleTemplate(t, this.ux, this.uy, p.cheapSamples);
      let sum = 0;
      for (let i = 0; i < p.cheapSamples; i++) sum += dist(this.hx[i], this.hy[i], this.ux[i], this.uy[i]);
      const cheapCost = p.wLoc * (sum / p.cheapSamples) + fixed;
      if (c === this.candId.length) {
        const grow = (a, T) => {
          const b = new T(a.length * 2);
          b.set(a);
          return b;
        };
        this.candId = grow(this.candId, Int32Array);
        this.candCheap = grow(this.candCheap, Float64Array);
        this.candFixed = grow(this.candFixed, Float64Array);
      }
      this.candId[c] = id;
      this.candCheap[c] = cheapCost;
      this.candFixed[c] = fixed;
      return c + 1;
    }

    /** The word's key letters with repeats merged ("hello" -> h e l o). */
    buildTemplate(key) {
      const tpl = this.tpl;
      let t = 0;
      let last = -1;
      for (let i = 0; i < key.length && t < tpl.length; i++) {
        const k = key.charCodeAt(i) - 97;
        if (k < 0 || k >= 26) continue;
        if (k !== last) {
          tpl[t++] = k;
          last = k;
        }
      }
      return t;
    }

    /** Resamples the path placed by placeNodes(t). */
    resampleTemplate(t, ox, oy, n) {
      resample(this.tplX, this.tplY, t, ox, oy, n);
    }

    nearestKeys(d, radius, maxKeys) {
      const r = radius === undefined ? this.params.endRadius : radius;
      const most = maxKeys === undefined ? this.params.maxEndKeys : maxKeys;
      const idx = [];
      for (let i = 0; i < 26; i++) idx.push(i);
      idx.sort((a, b) => d[a] - d[b]);
      const ok = new Uint8Array(26);
      for (let i = 0; i < most; i++) {
        if (i < 2 || d[idx[i]] <= r) ok[idx[i]] = 1;
      }
      return ok;
    }

    /** Average distance between two paths after the best in-order alignment. */
    dtw(ax, ay, bx, by, n, band) {
      const inf = 1e30;
      let prev = this.dtwPrev;
      let cur = this.dtwCur;
      prev.fill(inf);
      for (let i = 0; i < n; i++) {
        cur.fill(inf);
        const lo = Math.max(0, i - band);
        const hi = Math.min(n - 1, i + band);
        for (let j = lo; j <= hi; j++) {
          const dx = ax[i] - bx[j];
          const dy = ay[i] - by[j];
          const d = Math.sqrt(dx * dx + dy * dy);
          let best;
          if (i === 0 && j === 0) {
            best = 0;
          } else {
            best = inf;
            if (i > 0) {
              if (prev[j] < best) best = prev[j];
              if (j > 0 && prev[j - 1] < best) best = prev[j - 1];
            }
            if (j > 0 && cur[j - 1] < best) best = cur[j - 1];
          }
          cur[j] = d + best;
        }
        const tmp = prev;
        prev = cur;
        cur = tmp;
      }
      this.dtwPrev = prev;
      this.dtwCur = cur;
      return prev[n - 1] / n;
    }
  }

  // ---- suggestions while tap-typing ------------------------------------------------------------

  const EXACT = 0;
  const COMPLETION = 1;
  const CORRECTION = 2;

  class TypingSuggester {
    constructor() {
      this.keyDist = new Float64Array(676);
      this.hasGeometry = false;
      this.buf = new Float64Array(32 * 32);
    }

    setKeyCenters(x, y, keyWidth) {
      for (let a = 0; a < 26; a++) {
        for (let b = 0; b < 26; b++) {
          const dx = (x[a] - x[b]) / keyWidth;
          const dy = (y[a] - y[b]) / keyWidth;
          this.keyDist[a * 26 + b] = Math.sqrt(dx * dx + dy * dy);
        }
      }
      this.hasGeometry = true;
    }

    subCost(a, b) {
      if (a === b) return 0;
      const ia = a - 97;
      const ib = b - 97;
      if (!this.hasGeometry || ia < 0 || ia >= 26 || ib < 0 || ib >= 26) return 1;
      return this.keyDist[ia * 26 + ib] <= 1.25 ? 0.5 : 1;
    }

    /** Weighted Damerau-Levenshtein distance; a neighbouring key costs half. Gives up above limit. */
    editCost(typed, cand, limit) {
      const n = typed.length;
      const m = cand.length;
      const w = m + 1;
      if (this.buf.length < (n + 1) * w) this.buf = new Float64Array((n + 1) * w * 2);
      const d = this.buf;
      for (let i = 0; i <= n; i++) d[i * w] = i * 0.8;
      for (let j = 0; j <= m; j++) d[j] = j * 0.8;
      for (let i = 1; i <= n; i++) {
        let rowMin = Infinity;
        const a = typed.charCodeAt(i - 1);
        for (let j = 1; j <= m; j++) {
          const b = cand.charCodeAt(j - 1);
          let v = Math.min(d[(i - 1) * w + j - 1] + this.subCost(a, b),
            Math.min(d[(i - 1) * w + j] + 0.8, d[i * w + j - 1] + 0.8));
          if (i > 1 && j > 1 && a === cand.charCodeAt(j - 2) && typed.charCodeAt(i - 2) === b) {
            v = Math.min(v, d[(i - 2) * w + j - 2] + 0.7);
          }
          d[i * w + j] = v;
          if (v < rowMin) rowMin = v;
        }
        if (rowMin > limit) return Infinity;
      }
      return d[n * w + m];
    }

    /**
     * Ranked suggestions for a word in progress, best first, never blocked words.
     * @param sources one per language: {words, user, bias, lang}
     */
    suggest(typed, sources, max) {
      const key = keyOf(typed);
      if (!key) return [];
      const P = primaryOf(sources);
      const best = new Map();
      const add = (S, word, score, kind, cost) => {
        if (blockedIn(S, P, word)) return;
        const k = word.toLowerCase();
        const old = best.get(k);
        if (!old || old.score < score) best.set(k, { word, score, kind, cost, lang: S.lang });
      };

      let exact = false;
      for (const S of sources) {
        const W = S.words;
        const user = S.user;
        const bias = S.bias || 0;
        const foreign = isForeign(S, P);
        const shared = foreign ? sharedWith(W, P.words) : null;
        const bonus = (word) => bonusIn(S, P, word);
        for (const id of W.withKey(key)) {
          if (shared !== null && shared[id] === 1) continue;
          add(S, W.display[id], W.score[id] / 100 + bias + bonus(W.display[id]) + 2, EXACT, 0);
          exact = true;
        }
        const range = W.prefixRange(key);
        let scanned = 0;
        for (let pos = range[0]; pos < range[1] && scanned < 8000; pos++, scanned++) {
          const id = W.sortedId(pos);
          if (W.keys[id].length === key.length) continue;
          if (shared !== null && shared[id] === 1) continue;
          const extra = W.keys[id].length - key.length;
          add(S, W.display[id], W.score[id] / 100 + bias + bonus(W.display[id]) - 0.4 - 0.05 * extra, COMPLETION, 0);
        }
        if (user) {
          for (const e of user.activeAdded()) {
            if (foreign && P.words.find(e.word) >= 0) continue;
            const k = keyOf(e.word);
            if (k === key) {
              exact = true;
              add(S, e.word, ADDED_WORD_ZIPF + bias + bonus(e.word) + 2, EXACT, 0);
            } else if (k.startsWith(key)) {
              add(S, e.word, ADDED_WORD_ZIPF + bias + bonus(e.word) - 0.4, COMPLETION, 0);
            }
          }
        }
      }
      // Typo fixes, only when what you typed isn't a word in any of them.
      if (!exact && key.length >= 2) {
        const limit = key.length <= 4 ? 1.0 : 2.0;
        const first = key.charCodeAt(0) - 97;
        for (const S of sources) {
          const W = S.words;
          const bias = S.bias || 0;
          const shared = isForeign(S, P) ? sharedWith(W, P.words) : null;
          for (let f = 0; f < 26; f++) {
            if (f !== first && (!this.hasGeometry || this.keyDist[first * 26 + f] > 1.25)) continue;
            const ids = W.withFirst(f);
            for (let q = 0; q < ids.length; q++) {
              const id = ids[q];
              if (shared !== null && shared[id] === 1) continue;
              const k = W.keys[id];
              if (Math.abs(k.length - key.length) > 2) continue;
              const cost = this.editCost(key, k, limit);
              if (cost > limit) continue;
              add(S, W.display[id], W.score[id] / 100 + bias + bonusIn(S, P, W.display[id]) - 1.5 * cost, CORRECTION, cost);
            }
          }
        }
      }
      const out = Array.from(best.values());
      out.sort((a, b) => b.score - a.score);
      return out.length > max ? out.slice(0, max) : out;
    }
  }

  // ---- a text field --------------------------------------------------------------------------

  /** The few things a keyboard does to a text field, modelled on Android's InputConnection. */
  class Editor {
    constructor() {
      this.text = '';
      this.sel = 0;
      this.cs = -1;
      this.ce = -1;
      this.batch = 0;
      this.onChange = null;
    }

    changed() {
      if (this.batch === 0 && this.onChange) this.onChange();
    }

    beginBatchEdit() {
      this.batch++;
    }

    endBatchEdit() {
      if (this.batch > 0) this.batch--;
      this.changed();
    }

    commitText(t) {
      t = String(t);
      if (this.cs >= 0) {
        this.text = this.text.slice(0, this.cs) + t + this.text.slice(this.ce);
        this.sel = this.cs + t.length;
      } else {
        this.text = this.text.slice(0, this.sel) + t + this.text.slice(this.sel);
        this.sel += t.length;
      }
      this.cs = this.ce = -1;
      this.changed();
    }

    setComposingText(t) {
      t = String(t);
      const start = this.cs >= 0 ? this.cs : this.sel;
      const end = this.cs >= 0 ? this.ce : this.sel;
      this.text = this.text.slice(0, start) + t + this.text.slice(end);
      if (t.length === 0) {
        this.cs = this.ce = -1;
        this.sel = start;
      } else {
        this.cs = start;
        this.ce = start + t.length;
        this.sel = this.ce;
      }
      this.changed();
    }

    finishComposingText() {
      this.cs = this.ce = -1;
      this.changed();
    }

    deleteSurroundingText(before, after) {
      const s = Math.max(0, this.sel - before);
      const e = Math.min(this.text.length, this.sel + after);
      if (this.cs >= 0 && this.cs < e && this.ce > s) this.cs = this.ce = -1;
      this.text = this.text.slice(0, s) + this.text.slice(e);
      if (this.cs >= s) {
        this.cs -= e - s;
        this.ce -= e - s;
      }
      this.sel = s;
      this.changed();
    }

    getTextBeforeCursor(n) {
      return this.text.slice(Math.max(0, this.sel - n), this.sel);
    }

    /** Android's sentence-start rule (TextUtils.getCapsMode), also skipping Spanish ¿ and ¡. */
    capsAtCursor() {
      const cs = this.text;
      let i = this.sel;
      for (; i > 0; i--) {
        const c = cs[i - 1];
        if (c !== '"' && c !== "'" && c !== '¿' && c !== '¡' && !OPEN_PUNCT.test(c)) break;
      }
      let j = i;
      while (j > 0 && (cs[j - 1] === ' ' || cs[j - 1] === '\t')) j--;
      if (j === 0 || cs[j - 1] === '\n') return true;
      if (i === j) return false;
      for (; j > 0; j--) {
        const c = cs[j - 1];
        if (c !== '"' && c !== "'" && !CLOSE_PUNCT.test(c)) break;
      }
      if (j > 0) {
        const c = cs[j - 1];
        if (c === '.' || c === '?' || c === '!') {
          if (c === '.') {
            for (let k = j - 2; k >= 0; k--) {
              const d = cs[k];
              if (d === '.') return false;
              if (!isLetter(d)) break;
            }
          }
          return true;
        }
      }
      return false;
    }

    /** Moves the cursor by whole characters (an emoji counts as one). */
    moveCursor(chars) {
      let s = this.sel;
      const step = chars < 0 ? -1 : 1;
      for (let i = 0; i < Math.abs(chars); i++) {
        if (step < 0 && s > 0) {
          s--;
          if (s > 0 && isLow(this.text.charCodeAt(s)) && isHigh(this.text.charCodeAt(s - 1))) s--;
        } else if (step > 0 && s < this.text.length) {
          s++;
          if (s < this.text.length && isLow(this.text.charCodeAt(s)) && isHigh(this.text.charCodeAt(s - 1))) s++;
        }
      }
      this.sel = s;
      this.changed();
    }

    setCursor(index) {
      this.sel = Math.max(0, Math.min(this.text.length, index));
      this.changed();
    }

    clear() {
      this.text = '';
      this.sel = 0;
      this.cs = this.ce = -1;
      this.changed();
    }
  }

  function isHigh(c) {
    return c >= 0xd800 && c <= 0xdbff;
  }

  function isLow(c) {
    return c >= 0xdc00 && c <= 0xdfff;
  }

  let segmenter = null;
  try {
    if (typeof Intl !== 'undefined' && Intl.Segmenter) segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
  } catch (e) {
    segmenter = null;
  }

  /** Start index of the last visible character (emoji and accents count as one). */
  function lastGraphemeStart(s) {
    if (!s) return 0;
    if (segmenter) {
      let last = 0;
      for (const part of segmenter.segment(s)) last = part.index;
      return last;
    }
    let start = s.length - 1;
    if (start > 0 && isLow(s.charCodeAt(start)) && isHigh(s.charCodeAt(start - 1))) start--;
    return start;
  }

  // ---- the keyboard's typing logic ---------------------------------------------------------------

  const K = { SHIFT: -1, DELETE: -2, SYMBOLS: -3, LETTERS: -4, SYMBOLS2: -5, ENTER: -6, EMOJI: -7, SPACE: 32 };
  const SLOT_GEAR = -1;
  const PROMPT_YES = 10;
  const PROMPT_NO = 11;
  const SHIFT_OFF = 0;
  const SHIFT_ON = 1;
  const SHIFT_LOCK = 2;
  const STRIP_NONE = 0;
  const STRIP_TYPED = 1;
  const STRIP_GESTURE = 2;

  function needsSpaceBefore(c) {
    return !/\s/.test(c) && '([{"\'“‘/-@#\n¿¡'.indexOf(c) < 0;
  }

  /** 0 = as is, 1 = Capitalized, 2 = ALL CAPS. */
  function capsOf(s) {
    if (!s || !isUpper(s[0])) return 0;
    if (s.length >= 2 && s === s.toUpperCase()) return 2;
    return 1;
  }

  function withCaps(word, caps) {
    if (!word) return word;
    if (caps === 2) return word.toUpperCase();
    if (caps === 1) return word[0].toUpperCase() + word.slice(1);
    return word;
  }

  /**
   * Typing, swiping, suggestions and learning, ported from TrailIME.java, in several
   * languages. The field is a plain multi-line text box with sentence capitals.
   * `view` is the keyboard on screen; `lex` holds the languages.
   */
  class Ime {
    constructor(editor, view, lex, now) {
      this.ic = editor;
      this.view = view;
      this.lex = lex;
      this.now = now || (() => Date.now());
      this.decoder = new SwipeDecoder();
      this.suggester = new TypingSuggester();
      this.settings = { swipe: true, smartFix: true, autocorrect: false, doubleSpace: true, learn: true, typingLang: 'auto' };
      /** The language you were last writing in, used until the words before the cursor say otherwise. */
      this.lastLang = 'en';
      this.canSuggest = true;
      this.canSwipe = true;
      this.canLearn = true;
      this.capsFlags = true;
      this.capChars = false;
      this.shift = SHIFT_OFF;
      this.autoShifted = false;
      this.lastShiftTap = 0;
      this.typed = '';
      this.typedFirstAutoCap = false;
      this.gestureWord = null;
      this.gestureBase = null;
      this.gestureLang = null;
      /** The language you were writing in when you swiped it (where a rejection of it belongs). */
      this.gestureCtx = null;
      this.gestureResults = null;
      this.gestureCaps = 0;
      this.gestureSpaceAdded = false;
      this.gesturePath = null;
      this.afterGesture = false;
      this.stripKind = STRIP_NONE;
      this.stripText = [null, null, null];
      this.stripBase = [null, null, null];
      this.stripLang = [null, null, null];
      this.blockCandidate = null;
      this.blockLang = null;
      this.spaceAfterPick = false;
      this.lastSpaceTime = -1e9;
      this.revertFrom = null;
      this.revertTo = null;
      this.revertLang = null;
      this.deletedGestureWord = null;
      this.deletedGestureLang = null;
      this.deletedGestureTime = 0;
      /** Called when you swap a swiped word for another suggestion. */
      this.onCorrection = null;
    }

    onGeometry(cx, cy, kw) {
      this.decoder.setKeyCenters(cx, cy, kw);
      this.suggester.setKeyCenters(cx, cy, kw);
    }

    /** Learning needs a word list (to tell built-in words from new ones). */
    learning() {
      return this.canLearn && this.lex.enabled().length > 0;
    }

    applySettings(s) {
      Object.assign(this.settings, s || {});
      if (this.settings.lastLang) this.lastLang = this.settings.lastLang;
      this.canSwipe = this.canSuggest && this.settings.swipe;
      this.canLearn = this.canSuggest && this.settings.learn;
    }

    /** Like onStartInputView for a plain text field with sentence capitals. */
    start(settings) {
      if (this.typed.length > 0 || this.gestureWord !== null) this.ic.finishComposingText();
      this.resetComposing();
      this.deletedGestureWord = null;
      this.blockCandidate = null;
      this.applySettings(settings);
      this.view.setLayout('letters');
      this.view.showEmoji(false);
      this.view.clearStrip();
      this.shift = SHIFT_OFF;
      this.autoShifted = false;
      this.updateShift();
    }

    resetComposing() {
      this.typed = '';
      this.gestureWord = null;
      this.gestureBase = null;
      this.gestureLang = null;
      this.gestureCtx = null;
      this.gestureResults = null;
      this.gesturePath = null;
      this.gestureSpaceAdded = false;
      this.afterGesture = false;
      this.spaceAfterPick = false;
      this.revertFrom = null;
      this.revertTo = null;
      this.stripKind = STRIP_NONE;
    }

    composing() {
      return this.typed.length > 0 || this.gestureWord !== null;
    }

    // ---- languages ----

    /** The language you're writing in right now. */
    contextLang() {
      const langs = this.lex.enabled();
      if (!langs.length) return null;
      const codes = langs.map((L) => L.code);
      const fixed = this.settings.typingLang;
      if (fixed && fixed !== 'auto' && codes.indexOf(fixed) >= 0) return fixed;
      if (langs.length === 1) return codes[0];
      // The words before the one being tapped out (a swiped word counts: it's finished).
      const end = this.typed.length > 0 && this.ic.cs >= 0 ? this.ic.cs : this.ic.sel;
      const found = detectLang(this.ic.text.slice(Math.max(0, end - 400), end), langs);
      if (found) this.lastLang = found;
      return found || (codes.indexOf(this.lastLang) >= 0 ? this.lastLang : codes[0]);
    }

    /** Where words come from: the context language at full weight, the others marked down. */
    sources(ctx) {
      const fixed = this.settings.typingLang && this.settings.typingLang !== 'auto';
      const out = [];
      for (const L of this.lex.enabled()) {
        if (fixed && L.code !== ctx) continue;
        const S = { words: L.words, user: L.user, bias: L.code === ctx ? 0 : -LANG_PENALTY, lang: L.code };
        if (L.code === ctx) out.unshift(S);
        else out.push(S);
      }
      return out;
    }

    lang(code) {
      return this.lex.get(code);
    }

    inBase(word, code) {
      const L = this.lex.get(code);
      return !!(L && L.words && L.words.find(word) >= 0);
    }

    recordUse(word, amount, code) {
      const L = this.lex.get(code);
      if (L) L.user.recordUse(word, amount, this.inBase(word, code));
    }

    recordReject(word, code) {
      const L = this.lex.get(code);
      if (L) L.user.recordReject(word);
    }

    blockedIn(word, code) {
      const L = this.lex.get(code);
      return !!(L && L.user.isBlocked(word));
    }

    /** The language a typed word belongs to: yours if it knows the word, else one that does. */
    langOfTyped(word, ctx) {
      const srcs = this.sources(ctx);
      for (const S of srcs) if (S.words.find(word) >= 0) return S.lang;
      for (const S of srcs) if (S.user.get(word)) return S.lang;
      return ctx;
    }

    /** The typing language or the languages switched on changed: redo the word being tapped out. */
    refreshSuggestions() {
      if (this.stripKind === STRIP_TYPED && this.typed.length > 0) this.showTypedSuggestions();
    }

    // ---- keys ----

    onKey(key) {
      this.dismissPrompt();
      if (key.code === K.ENTER) {
        this.handleEnter();
        return;
      }
      this.ic.beginBatchEdit();
      try {
        switch (key.code) {
          case K.SHIFT:
            this.handleShift();
            break;
          case K.SYMBOLS:
            this.finalizeAll();
            this.view.setLayout('symbols');
            break;
          case K.SYMBOLS2:
            this.view.setLayout('symbols2');
            break;
          case K.LETTERS:
            this.view.setLayout('letters');
            this.updateShift();
            break;
          case K.EMOJI:
            this.finalizeAll();
            this.view.showEmoji(true);
            break;
          case K.SPACE:
            this.handleSpace();
            break;
          default:
            if (key.code > 0) this.handleChar(String.fromCharCode(key.code));
            break;
        }
      } finally {
        this.ic.endBatchEdit();
      }
    }

    /** Holding a key: its first alternative (the number on the top row). */
    onLongPress(key) {
      const ch = (key.alts && key.alts[0]) || key.longPress;
      if (ch) this.typeAlt(ch);
    }

    /** A character picked from a key's pop-up (an accent or a number). */
    typeAlt(ch) {
      this.dismissPrompt();
      this.ic.beginBatchEdit();
      try {
        this.handleChar(ch);
      } finally {
        this.ic.endBatchEdit();
      }
    }

    onDelete() {
      this.dismissPrompt();
      this.ic.beginBatchEdit();
      try {
        this.deleteInner(this.ic);
      } finally {
        this.ic.endBatchEdit();
      }
    }

    deleteInner(ic) {
      if (this.gestureWord !== null) {
        // One backspace removes the whole swiped word (and the space added before it).
        ic.commitText('');
        if (this.gestureSpaceAdded) {
          const b = ic.getTextBeforeCursor(1);
          if (b === ' ') ic.deleteSurroundingText(1, 0);
        }
        this.deletedGestureWord = this.learning() ? this.gestureBase : null;
        this.deletedGestureLang = this.gestureCtx || this.gestureLang;
        this.deletedGestureTime = this.now();
        this.resetComposing();
        this.view.clearStrip();
        this.updateShift();
        return;
      }
      if (this.typed.length > 0) {
        this.typed = this.typed.slice(0, -1);
        if (this.typed.length === 0) {
          ic.commitText('');
          this.stripKind = STRIP_NONE;
          this.view.clearStrip();
          this.updateShift();
        } else {
          ic.setComposingText(this.typed);
          this.showTypedSuggestions();
        }
        return;
      }
      if (this.revertFrom !== null && this.revertTo !== null) {
        const b = ic.getTextBeforeCursor(this.revertFrom.length + 1);
        if (b === this.revertFrom + ' ') {
          // Undo the automatic fix: put back exactly what you typed.
          ic.deleteSurroundingText(this.revertFrom.length + 1, 0);
          ic.commitText(this.revertTo);
          if (this.learning()) {
            this.recordReject(this.revertFrom, this.revertLang);
            if (this.revertTo.length >= 2) {
              const lang = this.langOfTyped(this.revertTo, this.contextLang());
              this.recordUse(this.learnForm(this.revertTo, false, lang), 1, lang);
            }
          }
          this.revertFrom = null;
          this.revertTo = null;
          return;
        }
        this.revertFrom = null;
        this.revertTo = null;
      }
      this.afterGesture = false;
      this.spaceAfterPick = false;
      const before = ic.getTextBeforeCursor(24);
      if (before.length > 0) ic.deleteSurroundingText(before.length - lastGraphemeStart(before), 0);
      if (this.stripKind !== STRIP_NONE) {
        this.stripKind = STRIP_NONE;
        this.view.clearStrip();
      }
      this.updateShift();
    }

    /** @param path the raw swipe ({xs, ys, ts, n}) kept for correction reports */
    onSwipe(xs, ys, count, path) {
      this.dismissPrompt();
      if (!this.canSwipe || !this.decoder.ready()) return;
      const ctx = this.contextLang();
      if (!ctx) return;
      const res = this.decoder.decode(xs, ys, count, this.sources(ctx), 8);
      this.ic.beginBatchEdit();
      try {
        this.swipeInner(this.ic, res, path, ctx);
      } finally {
        this.ic.endBatchEdit();
      }
    }

    swipeInner(ic, res, path, ctx) {
      if (this.gestureWord !== null) this.finalizeGesture();
      if (this.typed.length > 0) this.commitTyped();
      if (res.length === 0) return;
      this.gestureCaps = this.shift === SHIFT_LOCK || this.capChars ? 2 : this.shift === SHIFT_ON ? 1 : 0;
      this.gestureBase = res[0].word;
      this.gestureLang = res[0].lang || ctx;
      this.gestureCtx = ctx;
      this.gestureResults = res;
      this.gesturePath = path || null;
      if (path) path.ctx = ctx;
      let shown = withCaps(this.gestureBase, this.gestureCaps);
      const before = ic.getTextBeforeCursor(1);
      this.gestureSpaceAdded = false;
      if (before.length === 1 && needsSpaceBefore(before)) {
        ic.commitText(' ');
        this.gestureSpaceAdded = true;
        // "Done." + swipe: the space just added starts a new sentence.
        if (this.gestureCaps === 0 && this.capsFlags && ic.capsAtCursor()) {
          this.gestureCaps = 1;
          shown = withCaps(this.gestureBase, this.gestureCaps);
        }
      }
      ic.setComposingText(shown);
      this.gestureWord = shown;
      this.afterGesture = false;
      this.spaceAfterPick = false;
      this.revertFrom = null;
      if (this.shift === SHIFT_ON && !this.capChars) {
        this.shift = SHIFT_OFF;
        this.autoShifted = false;
        this.refreshShift();
      }
      this.showGestureStrip();
    }

    onCursorMove(chars) {
      this.dismissPrompt();
      this.ic.beginBatchEdit();
      try {
        this.finalizeAll();
      } finally {
        this.ic.endBatchEdit();
      }
      // The cursor is going somewhere new: forget anything tied to the old spot.
      this.afterGesture = false;
      this.spaceAfterPick = false;
      this.revertFrom = null;
      this.revertTo = null;
      this.ic.moveCursor(chars);
      this.updateShift();
    }

    /** You tapped somewhere in the text (onUpdateSelection on Android). */
    onCursorPlaced(index) {
      if (this.composing()) {
        if (index === this.ic.ce) return;
        // Leave the half-done word exactly as it is.
        this.ic.finishComposingText();
        this.resetComposing();
        this.view.clearStrip();
      } else {
        this.afterGesture = false;
        this.spaceAfterPick = false;
        this.revertFrom = null;
        if (!this.view.hasPrompt() && this.stripKind !== STRIP_NONE) {
          this.stripKind = STRIP_NONE;
          this.view.clearStrip();
        }
      }
      this.ic.setCursor(index);
      this.updateShift();
    }

    onStripTap(slot) {
      if (slot === SLOT_GEAR) {
        this.view.openSettings();
        return;
      }
      if (slot === PROMPT_YES || slot === PROMPT_NO) {
        this.answerPrompt(slot === PROMPT_YES);
        return;
      }
      if (slot < 0 || slot > 2 || this.stripText[slot] == null) return;
      this.ic.beginBatchEdit();
      try {
        this.pickInner(this.ic, slot);
      } finally {
        this.ic.endBatchEdit();
      }
    }

    pickInner(ic, slot) {
      const chosen = this.stripText[slot];
      const base = this.stripBase[slot];
      const lang = this.stripLang[slot];
      if (this.stripKind === STRIP_GESTURE && this.gestureWord !== null) {
        if (chosen === this.gestureWord) {
          this.finalizeGesture();
        } else {
          ic.setComposingText(chosen);
          ic.finishComposingText();
          if (this.onCorrection) {
            this.onCorrection({
              picked: base, pickedLang: lang, guess: this.gestureBase, guessLang: this.gestureLang,
              results: this.gestureResults, path: this.gesturePath,
            });
          }
          if (this.learning()) {
            this.recordUse(base, 2, lang);
            // Rejected while writing in gestureCtx: that's where it should come up less.
            this.recordReject(this.gestureBase, this.gestureCtx || this.gestureLang);
          }
          this.gestureWord = null;
          this.gestureBase = null;
          this.gestureLang = null;
          this.gestureCtx = null;
          this.gestureResults = null;
          this.gesturePath = null;
          this.deletedGestureWord = null;
          this.afterGesture = true;
        }
        this.stripKind = STRIP_NONE;
        this.view.clearStrip();
        return;
      }
      if (this.stripKind === STRIP_TYPED && this.typed.length > 0) {
        const literal = this.typed;
        ic.setComposingText(chosen);
        ic.finishComposingText();
        if (this.learning()) {
          if (chosen === literal) {
            if (literal.length >= 2 || this.inBase(literal, lang)) {
              this.recordUse(this.learnForm(literal, this.typedFirstAutoCap, lang), 1, lang);
            }
          } else {
            this.recordUse(base, 2, lang);
          }
        }
        this.typed = '';
        ic.commitText(' ');
        this.spaceAfterPick = true;
        this.stripKind = STRIP_NONE;
        this.view.clearStrip();
        this.updateShift();
      }
    }

    onStripLongPress(slot) {
      if (slot < 0 || slot > 2 || this.stripBase[slot] == null) return;
      this.blockCandidate = this.stripBase[slot];
      // Blocked in the language you're writing in: blocking a Spanish word that turned up in
      // English leaves it alone for Spanish.
      this.blockLang = (this.stripKind === STRIP_GESTURE && this.gestureCtx) || this.contextLang() || this.stripLang[slot];
      const L = this.lex.get(this.blockLang);
      const where = this.lex.enabled().length > 1 && L ? ' in ' + L.name : '';
      this.view.setPrompt('Never suggest “' + this.blockCandidate + '”' + where + '?');
    }

    answerPrompt(yes) {
      const word = this.blockCandidate;
      const code = this.blockLang;
      this.blockCandidate = null;
      this.view.setPrompt(null);
      if (yes && word !== null) {
        const L = this.lex.get(code);
        if (L) L.user.block(word);
        if (this.stripKind === STRIP_GESTURE && this.gestureWord !== null && this.gestureResults !== null) {
          const gone = (w, lang) => this.blockedIn(w, lang) || this.blockedIn(w, code);
          const kept = this.gestureResults.filter((r) => !gone(r.word, r.lang));
          this.gestureResults = kept;
          if (this.gestureBase !== null && gone(this.gestureBase, this.gestureLang)) {
            if (kept.length === 0) {
              this.ic.commitText('');
              this.resetComposing();
              this.view.clearStrip();
              return;
            }
            this.gestureBase = kept[0].word;
            this.gestureLang = kept[0].lang;
            this.gestureWord = withCaps(this.gestureBase, this.gestureCaps);
            this.ic.setComposingText(this.gestureWord);
          }
          this.showGestureStrip();
          return;
        }
      }
      if (this.stripKind === STRIP_GESTURE) this.showGestureStrip();
      else if (this.stripKind === STRIP_TYPED) this.showTypedSuggestions();
      else this.view.clearStrip();
    }

    dismissPrompt() {
      if (this.blockCandidate !== null) {
        this.blockCandidate = null;
        this.view.setPrompt(null);
      }
    }

    onEmoji(text) {
      this.ic.beginBatchEdit();
      try {
        this.finalizeAll();
        this.ic.commitText(text);
      } finally {
        this.ic.endBatchEdit();
      }
      this.afterGesture = false;
      this.spaceAfterPick = false;
      this.updateShift();
    }

    onEmojiBack() {
      this.view.showEmoji(false);
      this.updateShift();
    }

    // ---- typing ----

    handleShift() {
      if (this.gestureWord !== null) {
        // Shift right after a swipe cycles the word: lowercase, Capitalized, ALL CAPS.
        this.gestureCaps = (this.gestureCaps + 1) % 3;
        const shown = withCaps(this.gestureBase, this.gestureCaps);
        this.ic.setComposingText(shown);
        this.gestureWord = shown;
        this.showGestureStrip();
        return;
      }
      const now = this.now();
      if (this.shift === SHIFT_LOCK) {
        this.shift = SHIFT_OFF;
      } else if (this.lastShiftTap > 0 && now - this.lastShiftTap < 350) {
        this.shift = SHIFT_LOCK;
      } else if (this.shift === SHIFT_ON) {
        this.shift = SHIFT_OFF;
      } else {
        this.shift = SHIFT_ON;
      }
      this.autoShifted = false;
      this.lastShiftTap = this.shift === SHIFT_LOCK ? 0 : now;
      this.refreshShift();
    }

    refreshShift() {
      this.view.setShift(this.shift !== SHIFT_OFF, this.shift === SHIFT_LOCK);
    }

    /** Shift on at the start of a sentence. */
    updateShift() {
      if (this.shift === SHIFT_LOCK || (this.shift === SHIFT_ON && !this.autoShifted)) {
        this.refreshShift();
        return;
      }
      let auto = false;
      if (this.capChars) auto = true;
      else if (this.capsFlags && this.typed.length === 0 && this.gestureWord === null) auto = this.ic.capsAtCursor();
      this.shift = auto ? SHIFT_ON : SHIFT_OFF;
      this.autoShifted = auto;
      this.refreshShift();
    }

    handleChar(c) {
      const ic = this.ic;
      this.revertFrom = null;
      this.lastShiftTap = 0;
      if (isLetter(c)) {
        if (this.gestureWord !== null) {
          this.finalizeGesture();
          ic.commitText(' ');
        } else if (this.afterGesture) {
          ic.commitText(' ');
        }
        this.afterGesture = false;
        this.spaceAfterPick = false;
        const out = this.shift !== SHIFT_OFF ? c.toUpperCase() : c;
        if (this.canSuggest) {
          if (this.typed.length === 0) this.typedFirstAutoCap = this.shift === SHIFT_ON && this.autoShifted;
          this.typed += out;
          ic.setComposingText(this.typed);
          this.showTypedSuggestions();
        } else {
          ic.commitText(out);
        }
        if (this.shift === SHIFT_ON && !this.capChars) {
          this.shift = SHIFT_OFF;
          this.autoShifted = false;
          this.refreshShift();
        }
        return;
      }
      if ((c === "'" || c === '’') && this.typed.length > 0 && this.canSuggest) {
        this.typed += c;
        ic.setComposingText(this.typed);
        this.showTypedSuggestions();
        return;
      }
      // Punctuation, digits and symbols end the current word.
      this.finalizeAll();
      const attaches = '.,!?;:)]}'.indexOf(c) >= 0;
      if (this.spaceAfterPick && attaches) {
        const b = ic.getTextBeforeCursor(1);
        if (b === ' ') {
          ic.deleteSurroundingText(1, 0);
          const sentence = '.,!?;:'.indexOf(c) >= 0;
          ic.commitText(sentence ? c + ' ' : c);
          this.spaceAfterPick = sentence;
          this.afterGesture = false;
          this.updateShift();
          return;
        }
      }
      ic.commitText(c);
      this.spaceAfterPick = false;
      this.afterGesture = false;
      this.updateShift();
    }

    handleSpace() {
      const ic = this.ic;
      const now = this.now();
      this.revertFrom = null;
      if (this.gestureWord !== null) {
        this.finalizeGesture();
        ic.commitText(' ');
        this.afterGesture = false;
        this.lastSpaceTime = now;
        this.updateShift();
        return;
      }
      if (this.typed.length > 0) {
        this.commitTyped();
        ic.commitText(' ');
        this.lastSpaceTime = now;
        this.updateShift();
        return;
      }
      if (this.spaceAfterPick) {
        // The space after a picked suggestion is already there.
        this.spaceAfterPick = false;
        this.lastSpaceTime = now;
        return;
      }
      if (this.settings.doubleSpace && this.canSuggest && now - this.lastSpaceTime < 600) {
        const b = ic.getTextBeforeCursor(2);
        if (b.length === 2 && b[1] === ' ' && /[\p{L}\p{N}]/u.test(b[0])) {
          ic.deleteSurroundingText(1, 0);
          ic.commitText('. ');
          this.lastSpaceTime = -1e9;
          this.afterGesture = false;
          this.updateShift();
          return;
        }
      }
      ic.commitText(' ');
      this.lastSpaceTime = now;
      this.afterGesture = false;
      this.updateShift();
    }

    handleEnter() {
      this.ic.beginBatchEdit();
      try {
        this.finalizeAll();
        this.afterGesture = false;
        this.spaceAfterPick = false;
        this.ic.commitText('\n');
      } finally {
        this.ic.endBatchEdit();
      }
      this.updateShift();
    }

    /** Commits whatever word is in progress (with learning), leaving the text as shown. */
    finalizeAll() {
      if (this.gestureWord !== null) this.finalizeGesture();
      if (this.typed.length > 0) this.commitTyped();
      if (this.stripKind !== STRIP_NONE) {
        this.stripKind = STRIP_NONE;
        this.view.clearStrip();
      }
    }

    finalizeGesture() {
      this.ic.finishComposingText();
      if (this.learning() && this.gestureBase !== null) {
        this.recordUse(this.gestureBase, 1, this.gestureLang);
        if (this.deletedGestureWord !== null && this.now() - this.deletedGestureTime < 20000 &&
            this.deletedGestureWord.toLowerCase() !== this.gestureBase.toLowerCase()) {
          // You deleted a swiped word and swiped again: the first guess was wrong.
          this.recordReject(this.deletedGestureWord, this.deletedGestureLang);
        }
      }
      this.deletedGestureWord = null;
      this.gestureWord = null;
      this.gestureBase = null;
      this.gestureLang = null;
      this.gestureCtx = null;
      this.gestureResults = null;
      this.gesturePath = null;
      this.gestureSpaceAdded = false;
      this.afterGesture = true;
      this.stripKind = STRIP_NONE;
      this.view.clearStrip();
    }

    /** Commits the tapped word, applying apostrophe, accent and capital fixes (and typo fixes if on). */
    commitTyped() {
      const ic = this.ic;
      const literal = this.typed;
      const ctx = this.contextLang();
      this.typed = '';
      const fix = this.decideTypedCommit(literal, ctx);
      const commit = fix.text;
      if (commit !== literal) {
        ic.setComposingText(commit);
        this.revertFrom = commit;
        this.revertTo = literal;
        this.revertLang = ctx;
      } else {
        this.revertFrom = null;
        this.revertTo = null;
      }
      ic.finishComposingText();
      if (this.learning()) {
        const lang = commit === literal ? this.langOfTyped(literal, ctx) : fix.lang;
        const base = commit === literal ? this.learnForm(literal, this.typedFirstAutoCap, lang) : this.baseFormOf(commit, lang);
        if (isLearnable(base) && (base.length >= 2 || this.inBase(base, lang))) this.recordUse(base, 1, lang);
      }
      this.deletedGestureWord = null;
      this.stripKind = STRIP_NONE;
      this.view.clearStrip();
    }

    /** What pressing space turns the tapped word into: {text, lang} (lang null if unchanged). */
    decideTypedCommit(literal, ctx) {
      const plain = { text: literal, lang: null };
      if (ctx === undefined) ctx = this.contextLang();
      if (!this.canSuggest || !ctx || !literal) return plain;
      const srcs = this.sources(ctx);
      const caps = capsOf(literal);
      if (this.settings.smartFix) {
        const key = keyOf(literal);
        // Typed with plain letters only: "dont" -> "don't", "tambien" -> "también",
        // "im" -> "I'm" (but "its", "ill", "como" stay, since they're words too).
        if (key && literal.toLowerCase() === key) {
          const P = primaryOf(srcs);
          let literalScore = -99;
          for (const S of srcs) {
            const id = S.words.find(literal);
            if (id >= 0) literalScore = Math.max(literalScore, S.words.score[id] / 100 + S.bias + bonusIn(S, P, literal));
            else if (this.isActiveAddedIn(literal, S)) literalScore = 99;
          }
          let best = null;
          let bestScore = -99;
          for (const S of srcs) {
            const shared = isForeign(S, P) ? sharedWith(S.words, P.words) : null;
            for (const id of S.words.withKey(key)) {
              if (shared !== null && shared[id] === 1) continue;
              const d = S.words.display[id];
              if (d.toLowerCase() === literal.toLowerCase() || blockedIn(S, P, d)) continue;
              const s = S.words.score[id] / 100 + S.bias + bonusIn(S, P, d);
              if (s > bestScore) {
                bestScore = s;
                best = { word: d, lang: S.lang };
              }
            }
          }
          if (best && bestScore - literalScore >= 1.5) return { text: withCaps(best.word, caps), lang: best.lang };
        }
        // "i" -> "I", "toronto" -> "Toronto", "mexico" handled above, "méxico" -> "México"
        if (literal === literal.toLowerCase()) {
          const P = primaryOf(srcs);
          for (const S of srcs) {
            const id = S.words.find(literal);
            if (id < 0) continue;
            const d = S.words.display[id];
            if (d !== literal && d !== d.toUpperCase() && !blockedIn(S, P, d)) return { text: d, lang: S.lang };
            if (d === 'I') return { text: d, lang: S.lang };
            break;
          }
        }
      }
      if (this.settings.autocorrect && literal.length >= 2 && !srcs.some((S) => S.words.find(literal) >= 0) &&
          !srcs.some((S) => this.isActiveAddedIn(literal, S))) {
        const s = this.suggester.suggest(literal, srcs, 3);
        if (s.length > 0) {
          const top = s[0];
          if ((top.kind === CORRECTION && top.cost <= 1.0) || top.kind === EXACT) {
            return { text: withCaps(top.word, caps), lang: top.lang };
          }
        }
      }
      return plain;
    }

    // ---- suggestion strip ----

    showGestureStrip() {
      if (!this.gestureResults || this.gestureResults.length === 0) {
        this.view.clearStrip();
        return;
      }
      this.stripKind = STRIP_GESTURE;
      const b0 = this.gestureBase;
      let r1 = null;
      let r2 = null;
      for (const r of this.gestureResults) {
        if (r.word.toLowerCase() === b0.toLowerCase()) continue;
        if (r1 === null) {
          r1 = r;
        } else if (r2 === null && r.word.toLowerCase() !== r1.word.toLowerCase()) {
          r2 = r;
          break;
        }
      }
      this.setSlot(0, r1 && r1.word, r1 === null ? null : withCaps(r1.word, this.gestureCaps), r1 && r1.lang);
      this.setSlot(1, b0, this.gestureWord, this.gestureLang);
      this.setSlot(2, r2 && r2.word, r2 === null ? null : withCaps(r2.word, this.gestureCaps), r2 && r2.lang);
      this.view.setSuggestions(this.stripText[0], this.stripText[1], this.stripText[2], 1);
    }

    showTypedSuggestions() {
      if (!this.canSuggest || this.typed.length === 0) {
        this.stripKind = STRIP_NONE;
        this.view.clearStrip();
        return;
      }
      const ctx = this.contextLang();
      if (!ctx) {
        this.view.clearStrip();
        return;
      }
      this.stripKind = STRIP_TYPED;
      const literal = this.typed;
      const caps = capsOf(literal);
      const fix = this.decideTypedCommit(literal, ctx);
      const onSpace = fix.text;
      const list = this.suggester.suggest(literal, this.sources(ctx), 6);
      const alts = [];
      for (const s of list) {
        if (s.word.toLowerCase() === literal.toLowerCase() || s.word.toLowerCase() === onSpace.toLowerCase()) continue;
        alts.push(s);
      }
      const literalLang = this.langOfTyped(literal, ctx);
      if (onSpace !== literal) {
        this.setSlot(0, literal, literal, literalLang);
        this.setSlot(1, this.baseFormOf(onSpace, fix.lang), onSpace, fix.lang);
        const a = alts.length ? alts[0] : null;
        this.setSlot(2, a && a.word, a === null ? null : withCaps(a.word, caps), a && a.lang);
        this.view.setSuggestions('“' + literal + '”', onSpace, this.stripText[2], 1);
        return;
      }
      const a0 = alts.length > 0 ? alts[0] : null;
      const a1 = alts.length > 1 ? alts[1] : null;
      this.setSlot(0, a0 && a0.word, a0 === null ? null : withCaps(a0.word, caps), a0 && a0.lang);
      this.setSlot(1, literal, literal, literalLang);
      this.setSlot(2, a1 && a1.word, a1 === null ? null : withCaps(a1.word, caps), a1 && a1.lang);
      this.view.setSuggestions(this.stripText[0], this.stripText[1], this.stripText[2], 1);
    }

    setSlot(i, base, text, lang) {
      this.stripBase[i] = base == null ? null : base;
      this.stripText[i] = text;
      this.stripLang[i] = lang || null;
    }

    // ---- helpers ----

    isActiveAddedIn(word, S) {
      const e = S.user.get(word);
      return e !== null && e.added && e.active();
    }

    /** The dictionary's own spelling ("hello" for "Hello" at a sentence start). */
    baseFormOf(word, code) {
      const L = this.lex.get(code);
      if (L && L.words) {
        const id = L.words.find(word);
        if (id >= 0) return L.words.display[id];
      }
      const e = L ? L.user.get(word) : null;
      return e ? e.word : word;
    }

    /** How to store a typed word: drop a capital that only came from sentence-start shift. */
    learnForm(literal, firstFromAutoCap, code) {
      const L = this.lex.get(code);
      if (L && L.words) {
        const id = L.words.find(literal);
        if (id >= 0) return L.words.display[id];
      }
      const e = L ? L.user.get(literal) : null;
      if (e) return e.word;
      if (firstFromAutoCap && literal.length > 1 && literal !== literal.toUpperCase()) {
        return literal[0].toLowerCase() + literal.slice(1);
      }
      return literal;
    }
  }

  return {
    keyOf,
    isLearnable,
    WordList,
    UserWords,
    Lexicon,
    LANG_INFO,
    LANG_PENALTY,
    detectLang,
    prepareShared,
    SwipeProfile,
    SwipeDecoder,
    TypingSuggester,
    Editor,
    Ime,
    K,
    SLOT_GEAR,
    PROMPT_YES,
    PROMPT_NO,
    STARTER_BLOCKS,
    withCaps,
  };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = Trail;

