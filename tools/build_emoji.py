#!/usr/bin/env python3
"""Builds Resources/Emoji/emoji.tsv, the emoji panel's list and search words, from the
emojibase-data npm package (MIT licence; names and keywords come from Unicode CLDR).

    npm pack emojibase-data@18.0.0 && tar -xzf emojibase-data-18.0.0.tgz
    python3 tools/build_emoji.py package            # writes Resources/Emoji/emoji.tsv
    python3 tools/build_emoji.py package --check    # fails if the file would change

One line per emoji, in the order the panel shows them:
    emoji <TAB> category <TAB> emoji version <TAB> English name <TAB> Spanish name <TAB> keywords
    <TAB> popularity
Names and keywords are lower case without accents (what a search is compared with).
Popularity is the place in the list of most used emoji below (blank for the rest): searches
show these first among equally good matches ("heart" gives the red heart first).
Categories follow Apple's keyboard: 0 Smileys & People, 1 Animals & Nature, 2 Food & Drink,
3 Activity, 4 Travel & Places, 5 Objects, 6 Symbols, 7 Flags. As on Apple's keyboard, hearts
open the Symbols page and clothing ends Smileys & People. Skin-tone variants and the bare
components (tones, hair) are left out; emoji newer than Emoji 17.0 too (no iPhone draws them yet).
"""
import json
import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Resources", "Emoji", "emoji.tsv")
NEWEST = 17.0

# Unicode group -> Apple category.
GROUP_TO_CAT = {0: 0, 1: 0, 3: 1, 4: 2, 6: 3, 5: 4, 7: 5, 8: 6, 9: 7}
# Subgroups placed as Apple does (subgroup numbers from emojibase's meta/groups.json).
HEART, EMOTION, CLOTHING = 14, 15, 65
EMOTION_TO_SYMBOLS = {"💯", "💢", "💬", "👁️‍🗨️", "🗨️", "🗯️", "💭", "💤"}
EMOTION_TO_NATURE = {"💥", "💫", "💦", "💨"}
EMOTION_TO_OBJECTS = {"🕳️"}

# The 50 most used emoji (Unicode's emoji frequency list, 2021), most used first.
POPULAR = ("😂 ❤️ 🤣 👍 😭 🙏 😘 🥰 😍 😊 🎉 😁 💕 🥺 😅 🔥 ☺️ 🤦 ♥️ 🤷 🙄 😆 🤗 😉 🎂 🤔 👏 🙂 😳 🥳 "
           "😎 👌 💜 😔 💪 ✨ 💖 👀 😋 😏 😢 👉 💗 😩 💯 🌹 💞 🎈 💙 😃").split()


def norm(s):
    s = unicodedata.normalize("NFKD", s.lower())
    s = "".join(c for c in s if not unicodedata.combining(c))
    return " ".join(re.sub(r"[^0-9a-zñ]+", " ", s.replace("ñ", "n")).split())


def words(*parts):
    seen, out = set(), []
    for p in parts:
        for w in norm(p).split():
            if w not in seen:
                seen.add(w)
                out.append(w)
    return " ".join(out)


def place(e):
    """(category, rank within the category) for an emoji."""
    cat = GROUP_TO_CAT[e["group"]]
    sub = e["subgroup"]
    order = e["order"]
    if sub == HEART:
        if e["emoji"] == "💌":
            return 5, (3, order)  # Apple keeps the love letter with the mail
        return 6, (0, order)
    if sub == EMOTION:
        if e["emoji"] in EMOTION_TO_SYMBOLS:
            return 6, (1, order)
        if e["emoji"] in EMOTION_TO_NATURE:
            return 1, (3, order)
        if e["emoji"] in EMOTION_TO_OBJECTS:
            return 5, (3, order)
    if sub == CLOTHING:
        return 0, (3, order)
    return cat, (2, order)


def build(pkg):
    en = json.load(open(os.path.join(pkg, "en", "data.json"), encoding="utf-8"))
    es = {e["hexcode"]: e for e in json.load(open(os.path.join(pkg, "es", "data.json"), encoding="utf-8"))}
    rows = []
    for e in en:
        if e.get("group") is None or e["group"] == 2 or e["version"] > NEWEST:
            continue
        s = es.get(e["hexcode"], {})
        cat, rank = place(e)
        en_name = norm(e["label"])
        es_name = norm(s.get("label", ""))
        keys = words(*e.get("tags", []), *s.get("tags", []))
        version = ("%g" % e["version"])
        popular = str(POPULAR.index(e["emoji"])) if e["emoji"] in POPULAR else ""
        rows.append((cat, rank, "\t".join([e["emoji"], str(cat), version, en_name, es_name, keys, popular])))
    found = {r[2].split("\t")[0] for r in rows}
    missing = [p for p in POPULAR if p not in found]
    if missing:
        sys.exit("popular emoji not in the data: " + " ".join(missing))
    rows.sort(key=lambda r: (r[0], r[1]))
    return "".join(r[2] + "\n" for r in rows)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    text = build(args[0])
    if "--check" in sys.argv:
        old = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if old != text:
            sys.exit("emoji.tsv is out of date: run tools/build_emoji.py without --check")
        print("emoji.tsv is up to date")
        return
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote %d emoji, %d bytes" % (text.count("\n"), len(text.encode("utf-8"))))


if __name__ == "__main__":
    main()
