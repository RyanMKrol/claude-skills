#!/usr/bin/env python3
"""Content-only Anki deck builder for one JBP lesson (NO audio — that's a later TTS phase).

This is the adapt-per-lesson TEMPLATE. Replace the per-lesson DATA block (VOCAB / NUMBERS / KEY /
GRAMMAR / IMAGES / deck title) for each lesson; the machinery (model, templates, CSS, romaji
overrides, page lookup, audit table) stays the same. The data below is the worked Lesson 2 example.

Nothing is hard-coded about the textbook location:
  - the lesson chapter xhtml is taken from  $JBP_LESSON_XHTML  or  argv[1]   (used for page lookup)
  - cropped images are taken from            $JBP_MEDIA_DIR    or  argv[2]   (a dir of PNGs)
  - the output .apkg goes to                 $JBP_OUT          or  argv[3]   (default under state home)
Per-user romaji fixes load from  $JBP_DECK_HOME/romaji-overrides.json  (seeded from ../defaults).

Deps: genanki, cutlet, pykakasi, Pillow (for cropping, elsewhere).
"""
import os, re, sys, json, shutil
import cutlet, genanki

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tts_common import slug  # noqa: E402  (shared kana->mp3 filename with the TTS phase)
DEFAULTS = os.path.join(HERE, "..", "defaults")
HOME = os.path.expanduser(os.environ.get("JBP_DECK_HOME", "~/.jbp-lesson-deck"))

# ---- state home: create + seed from bundled defaults on first run ----
os.makedirs(HOME, exist_ok=True)
for f in ("romaji-overrides.json", "learnings.md"):
    dst, src = os.path.join(HOME, f), os.path.join(DEFAULTS, f)
    if not os.path.exists(dst) and os.path.exists(src):
        shutil.copy(src, dst)

def _load_overrides():
    ov = {}
    for p in (os.path.join(DEFAULTS, "romaji-overrides.json"), os.path.join(HOME, "romaji-overrides.json")):
        if os.path.exists(p):
            try: ov.update(json.load(open(p, encoding="utf-8")))
            except Exception as e: print(f"warn: bad overrides {p}: {e}", file=sys.stderr)
    return ov
OVERRIDES = _load_overrides()

katsu = cutlet.Cutlet(); katsu.use_foreign_spelling = False
def romaji(kana):
    k = kana.strip()
    if k in OVERRIDES: return OVERRIDES[k]
    return re.sub(r"\s+", " ", katsu.romaji(k.replace("／", " ").replace("〜", ""))).strip()

# ---- inputs (no hard-coded paths) ----
XHTML = os.environ.get("JBP_LESSON_XHTML") or (sys.argv[1] if len(sys.argv) > 1 else "")
MEDIA = os.environ.get("JBP_MEDIA_DIR") or (sys.argv[2] if len(sys.argv) > 2 else "")
OUT = os.environ.get("JBP_OUT") or (sys.argv[3] if len(sys.argv) > 3 else
                                    os.path.join(HOME, "decks", "Lesson.apkg"))
os.makedirs(os.path.dirname(OUT), exist_ok=True)
# audio dir (from the TTS phase). Voice-specific by default so switching voices never reuses
# another voice's files. If a card's mp3 exists here it's attached; else the card is silent.
AUDIO_DIR = os.environ.get("JBP_AUDIO_DIR") or (sys.argv[4] if len(sys.argv) > 4 else
            os.path.join(HOME, "audio", os.environ.get("JBP_TTS_VOICE", "default")))

# ---- page lookup: map each item to the textbook page (audit-table cross-reference) ----
_raw = open(XHTML, encoding="utf-8").read() if XHTML and os.path.exists(XHTML) else ""
_pbs = [(m.start(), m.group(1)) for m in re.finditer(r'epub:type="pagebreak"[^>]*title="(\d+)"', _raw)]
def page_of(text, override=None):
    if override: return override
    if not _raw: return "?"
    frag = re.sub(r"[〜。、\s]", "", text)
    for L in (len(frag), 6, 4, 3):
        f = frag[:L]
        if f and _raw.find(f) != -1:
            pos = _raw.find(f); pg = "?"
            for off, npg in _pbs:
                if off <= pos: pg = npg
                else: break
            return pg
    return "?"

# =====================================================================================
# PER-LESSON DATA  — replace this whole block per lesson.  (worked example: Lesson 2)
# =====================================================================================
DECK_TITLE = "Japanese for Busy People 1::Lesson 2 — Whose Pen Is This?"
DECK_ID, MODEL_ID = 1710000002, 1610000021   # deck id = 1710000000 + N; model id FIXED across lessons

# (kana, english, hint)
VOCAB = [
    ("これ", "this one", ""), ("だれの", "whose", "だれ (who) + の (possessive particle)"),
    ("だれ", "who", ""), ("ペン", "pen", ""),
    ("さあ、わかりません。", "Well, I'm not sure.", "さあ = hesitation before an uncertain answer"),
    ("わかりません", "I don't know", "negative of わかります (to understand)"),
    ("スミスさんの", "Smith-san's", "name + の = possessive"), ("わたしの", "my, mine", ""),
    ("〜じゃありません", "is / are not", "negative of 〜です"),
    ("ありがとうございます。", "Thank you.", ""), ("とけい", "watch, clock", ""),
    ("めいし", "business card", ""), ("かいしゃの なまえ", "company name", ""),
    ("かいしゃ", "company", ""), ("なまえ", "name", ""), ("じゅうしょ", "address", ""),
    ("でんわばんごう", "telephone number", ""), ("でんわ", "telephone", ""), ("ばんごう", "number", ""),
    ("メールアドレス", "email address", ""), ("かばん", "bag", ""), ("スマホ", "smartphone", ""),
    ("めがね", "glasses", ""), ("かぎ", "key", ""), ("さいふ", "wallet", ""), ("ファイル", "file", ""),
    ("ほん", "book", ""), ("かさ", "umbrella", ""), ("なん", "what", ""),
    ("〜を おしえてください", "please tell me ~", ""), ("にほんの おかし", "Japanese sweets", ""),
    ("おかし", "sweets", ""), ("お〜", "(polite prefix)", "beautifying prefix お-, e.g. おかし"),
    ("かし", "sweets", "plain form of おかし"), ("どうぞ。", "Please (have one).", "offering something"),
    ("もう いちど おねがいします。", "One more time, please.", ""), ("もう いちど", "one more time", ""),
    ("もう", "more", ""), ("いちど", "one time", ""),
    ("おねがいします", "please (lit. “I request you”)", ""),
]
# (kana, english, hint)  Word Power: Numbers 0-9 (both readings where the book lists two)
NUMBERS = [
    ("ゼロ／れい", "0 (zero)", "ゼロ (from English) / れい"), ("いち", "1 (one)", ""),
    ("に", "2 (two)", ""), ("さん", "3 (three)", ""), ("よん／し", "4 (four)", "both readings used"),
    ("ご", "5 (five)", ""), ("ろく", "6 (six)", ""), ("なな／しち", "7 (seven)", "both readings used"),
    ("はち", "8 (eight)", ""), ("きゅう／く", "9 (nine)", "both readings used"),
]
KEY = [
    ("これは とけいです。", "This is a watch.", ""),
    ("これは とけいじゃありません。", "This is not a watch.", ""),
    ("これは スミスさんの とけいです。", "This is Smith-san's watch.", ""),
]
GRAMMAR = [
    ("これは わたしの ペンです。", "This is my pen.", "possessive: noun + の"),
    ("これは わたしのです。", "This is mine.", "の nominalizes: “mine” without repeating the noun"),
]
# kana -> cropped image filename (in MEDIA dir)
IMAGES = {
    "ほん": "l2_hon.png", "とけい": "l2_tokei.png", "さいふ": "l2_saifu.png", "かぎ": "l2_kagi.png",
    "スマホ": "l2_sumaho.png", "めがね": "l2_megane.png", "ペン": "l2_pen.png", "ファイル": "l2_fairu.png",
    "かばん": "l2_kaban.png", "かさ": "l2_kasa.png", "めいし": "l2_meishi.png",
}
# =====================================================================================

CSS = """
.card{font-family:arial;text-align:center;color:#111;background:#fff;font-size:22px}
.img img{max-width:320px;max-height:320px;height:auto;border-radius:6px}
.kana{font-size:28px;margin:12px 0}
.romaji{font-size:17px;color:#888;font-style:italic;margin-top:8px}
.english{font-size:20px;margin-top:8px}
.hint{font-size:13px;color:#999;margin-top:12px}
.audio{margin-top:6px}
hr#answer{margin:16px 0}
"""
recog = {"name": "Recognition (JP→EN)",
 "qfmt": '<div class="img">{{Image}}</div>\n<div class="kana">{{Kana}}</div>\n<div class="audio">{{Audio}}</div>',
 "afmt": '{{FrontSide}}\n<hr id=answer>\n<div class="romaji">{{Romaji}}</div>\n<div class="english">{{English}}</div>\n{{#Hint}}<div class="hint">{{Hint}}</div>{{/Hint}}'}
produce = {"name": "Production (EN→JP)",
 "qfmt": '<div class="english">{{English}}</div>\n{{#Hint}}<div class="hint">{{Hint}}</div>{{/Hint}}',
 "afmt": '{{FrontSide}}\n<hr id=answer>\n<div class="kana">{{Kana}}</div>\n<div class="romaji">{{Romaji}}</div>\n<div class="img">{{Image}}</div>\n<div class="audio">{{Audio}}</div>'}
model = genanki.Model(MODEL_ID, "JBP1 — Expression",
    fields=[{"name": n} for n in ["Kana", "Romaji", "English", "Hint", "Image", "Audio", "Kanji"]],
    templates=[recog, produce], css=CSS)

deck = genanki.Deck(DECK_ID, DECK_TITLE)
media_files = []; REVIEW = []
def add(kana, eng, hint, group, page_override=None):
    rom = romaji(kana)
    img_file = IMAGES.get(kana)
    img = f'<img src="{img_file}">' if img_file else ""
    if img_file and MEDIA:
        media_files.append(os.path.join(MEDIA, img_file))
    # audio: attach the generated mp3 for this kana if the TTS phase has produced it
    aud = ""
    af = os.path.join(AUDIO_DIR, slug(kana))
    if os.path.exists(af):
        aud = f"[sound:{os.path.basename(af)}]"; media_files.append(af)
    deck.add_note(genanki.Note(model=model, fields=[kana, rom, eng, hint, img, aud, ""]))
    REVIEW.append({"group": group, "eng": eng, "kana": kana, "rom": rom,
                   "page": page_of(kana, page_override), "img": bool(img_file), "aud": bool(aud)})

for kana, eng, hint in VOCAB:            add(kana, eng, hint, "Vocab")
for kana, eng, hint in NUMBERS:          add(kana, eng, hint, "Numbers", page_override="11")
for kana, eng, hint in KEY:              add(kana, eng, hint, "KeySent", page_override="10")
for kana, eng, hint in GRAMMAR:          add(kana, eng, hint, "Grammar", page_override="10")

# manifest for the TTS phase (generate_audio.py reads this)
WORK = os.path.join(HOME, "work"); os.makedirs(WORK, exist_ok=True)
json.dump([{"kana": r["kana"], "group": r["group"]} for r in REVIEW],
          open(os.path.join(WORK, "cards.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)

# ---------------- AUDIT TABLE (mandatory hand-off) ----------------
def _w(s, n):  # display width honoring wide CJK glyphs
    return s + " " * max(0, n - sum(2 if ord(c) > 0x2e80 else 1 for c in s))
n_aud = sum(r["aud"] for r in REVIEW)
print("\n" + "=" * 96)
print(f"AUDIT TABLE — {DECK_TITLE.split('::')[-1]}   (✓ = present; Page = textbook page)")
print("=" * 96)
print(f"{_w('ENGLISH',26)} {_w('KANA',20)} {_w('ROMAJI',24)} {'PG':3} {'IMG':3} {'AUD':3}")
print("-" * 96)
for g in ("Vocab", "Numbers", "KeySent", "Grammar"):
    rows = [r for r in REVIEW if r["group"] == g]
    if not rows: continue
    print(f"── {g} ({len(rows)}) " + "─" * 70)
    for r in rows:
        print(f"{_w(r['eng'][:25],26)} {_w(r['kana'],20)} {_w(r['rom'][:23],24)} "
              f"{r['page']:3} {'✓' if r['img'] else '·':3} {'✓' if r['aud'] else '·':3}")
print("-" * 96)
print(f"notes: {len(REVIEW)}  cards: {len(REVIEW)*2}   |   image: {sum(r['img'] for r in REVIEW)}"
      f"   |   audio: {n_aud}" + ("  (run generate_audio.py to fill)" if n_aud == 0 else ""))

pkg = genanki.Package(deck); pkg.media_files = media_files
pkg.write_to_file(OUT)
print(f"\nwritten: {OUT} ({os.path.getsize(OUT)//1024} KB)  media files: {len(media_files)}")
