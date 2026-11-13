#!/usr/bin/env python3
"""
Builds the keyboard's word lists into memory-mappable files, so the keyboard opens
instantly and the lists don't count against its memory limit.

    python3 tools/build_lexicon.py            # writes Resources/Lexicon/*
    python3 tools/build_lexicon.py --check    # fails if the committed files are out of date

Input: tools/wordlists/words-<lang>.txt, lines of "word<TAB>zipf*100", most common first.
The parsing matches WordList in tools/reference/core.js exactly (the web build the
iPhone engine is ported from); tools/fixtures/gen.js checks that against the JS engine.

File layout (little-endian, every array starts on a 4-byte boundary):
    header   magic "TRLX", version, count N, display bytes, key bytes, 3 reserved (32 bytes)
    score    int16[N]            zipf * 100
    dispOff  uint32[N+1]         word i's spelling is display[dispOff[i]:dispOff[i+1]] (UTF-8)
    keyOff   uint32[N+1]         word i's key (letters a-z, accents and apostrophes dropped)
    sorted   int32[N]            ids ordered by key (stable, so equal keys stay in id order)
    flStart  uint32[677]         ids with first letter f and last letter l are
    flIds    int32[N]              flIds[flStart[f*26+l] : flStart[f*26+l+1]], in id order
    fStart   uint32[27]          the same by first letter only
    fIds     int32[N]
    display  bytes
    keys     bytes

Also writes shared-<a>-<b>.bin: one byte per word of list a, 1 when list b has the same
word spelled exactly the same (core.js sharedWith).
"""
import os
import re
import struct
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'tools', 'wordlists')
OUT = os.path.join(ROOT, 'Resources', 'Lexicon')
LANGS = ['en', 'es']
MAGIC = b'TRLX'
VERSION = 1


def key_of(word):
    """core.js keyOf: lowercase letters, accents and apostrophes dropped; '' for anything else."""
    out = []
    for ch in word:
        c = ord(ch)
        if c > 0xFFFF:
            return ''  # JS sees a lone surrogate here
        if 65 <= c <= 90:
            c += 32
        if 97 <= c <= 122:
            out.append(chr(c))
            continue
        if c in (39, 0x2019):
            continue
        if c < 128:
            return ''
        base = ''.join(x for x in unicodedata.normalize('NFD', ch) if not 0x300 <= ord(x) <= 0x36F)
        if len(base) == 1:
            b = ord(base)
            if 65 <= b <= 90:
                b += 32
            if 97 <= b <= 122:
                out.append(chr(b))
                continue
        return ''
    return ''.join(out)


INT_RE = re.compile(r'[\t\n\v\f\r    ﻿]*([+-]?\d+)')


def parse_list(path):
    """core.js WordList constructor: skips lines without a tab, without a number, or without a key."""
    text = open(path, encoding='utf-8').read()
    display, keys, score = [], [], []
    for line in text.split('\n'):
        tab = line.find('\t')
        if tab <= 0:
            continue
        m = INT_RE.match(line[tab + 1:])
        if not m:
            continue
        word = line[:tab]
        key = key_of(word)
        if not key:
            continue
        display.append(word)
        keys.append(key)
        score.append(int(m.group(1)))
    return display, keys, score


def pad4(b):
    return b + b'\0' * ((-len(b)) % 4)


def build(display, keys, score):
    n = len(display)
    disp_blob = bytearray()
    disp_off = [0]
    for w in display:
        disp_blob += w.encode('utf-8')
        disp_off.append(len(disp_blob))
    key_blob = bytearray()
    key_off = [0]
    for k in keys:
        key_blob += k.encode('ascii')
        key_off.append(len(key_blob))
    order = sorted(range(n), key=lambda i: keys[i])  # stable, like Array.prototype.sort
    buckets = [[] for _ in range(676)]
    firsts = [[] for _ in range(26)]
    for i, k in enumerate(keys):
        f = ord(k[0]) - 97
        l = ord(k[-1]) - 97
        buckets[f * 26 + l].append(i)
        firsts[f].append(i)
    fl_start, fl_ids = [0], []
    for b in buckets:
        fl_ids += b
        fl_start.append(len(fl_ids))
    f_start, f_ids = [0], []
    for b in firsts:
        f_ids += b
        f_start.append(len(f_ids))
    for s in score:
        assert -32768 <= s <= 32767, s
    out = bytearray()
    out += MAGIC + struct.pack('<7I', VERSION, n, len(disp_blob), len(key_blob), 0, 0, 0)
    out += pad4(struct.pack('<%dh' % n, *score))
    out += struct.pack('<%dI' % (n + 1), *disp_off)
    out += struct.pack('<%dI' % (n + 1), *key_off)
    out += struct.pack('<%di' % n, *order)
    out += struct.pack('<677I', *fl_start)
    out += struct.pack('<%di' % n, *fl_ids)
    out += struct.pack('<27I', *f_start)
    out += struct.pack('<%di' % n, *f_ids)
    out += pad4(bytes(disp_blob))
    out += pad4(bytes(key_blob))
    return bytes(out)


def main():
    check = '--check' in sys.argv
    lists = {}
    files = {}
    for lang in LANGS:
        display, keys, score = parse_list(os.path.join(SRC, 'words-%s.txt' % lang))
        lists[lang] = display
        files['%s.lex' % lang] = build(display, keys, score)
    for a in LANGS:
        for b in LANGS:
            if a == b:
                continue
            other = set(lists[b])
            files['shared-%s-%s.bin' % (a, b)] = bytes(1 if w in other else 0 for w in lists[a])
    stale = []
    for name, data in sorted(files.items()):
        path = os.path.join(OUT, name)
        if check:
            if not os.path.exists(path) or open(path, 'rb').read() != data:
                stale.append(name)
        else:
            os.makedirs(OUT, exist_ok=True)
            open(path, 'wb').write(data)
            print('wrote %s (%d bytes)' % (os.path.relpath(path, ROOT), len(data)))
    for lang in LANGS:
        print('%s: %d words' % (lang, len(lists[lang])))
    if check:
        if stale:
            print('out of date: ' + ', '.join(stale))
            sys.exit(1)
        print('word list files are up to date')


if __name__ == '__main__':
    main()
