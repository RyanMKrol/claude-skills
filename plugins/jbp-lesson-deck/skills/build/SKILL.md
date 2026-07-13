---
name: build
description: >-
  Build a rich Anki deck for one lesson of a "Japanese for Busy People" textbook from a
  USER-PROVIDED EPUB. Use when the user asks to build/redo a JBP lesson deck — e.g. "build
  lesson 2", "make the Anki cards for lesson N of Japanese for Busy People", "do the next JBP
  lesson", "rebuild lesson X". The user MUST supply the textbook EPUB (nothing about its
  location is hard-coded). Extracts vocabulary, Word Power sets, Key Sentences, and grammar
  example sentences; crops textbook illustrations onto cards; writes kana, romaji, and usage
  hints; then presents an AUDIT TABLE for review. Audio is a separate, not-yet-built phase
  (ElevenLabs TTS) — this skill produces silent cards with an empty Audio field.
---

# Build a JBP Anki lesson deck (content extraction + audit)

Produce a `.apkg` for one lesson that the user imports and reviews. Work one lesson at a time.
Every card carries kana, romaji, English, an optional usage hint, and a cropped textbook image
where the book has one. **Audio is intentionally out of scope for now** — the Audio field is left
empty and will be filled by a later ElevenLabs TTS phase (see the end of this doc).

> ## 🔴 Two non-negotiable rules (do not violate)
> 1. **READ EVERY SINGLE PAGE / EVERY IMAGE of the lesson.** Never infer content from section
>    headings or from a script's counts. Enumerate every image the chapter references, build
>    labeled contact sheets, and actually **Read** them before deciding what goes on cards.
>    Skipping a page is unacceptable — it has already caused a deck to ship missing content.
> 2. **NOTHING IS HARD-CODED.** The user provides the EPUB path and the lesson number. Never
>    assume a textbook location, an audio folder, or a NAS mount. If you don't have the EPUB, ask
>    for it.
>
> When you learn something new during a run (a romaji fix, a book quirk), **write it back**: to
> `$JBP_DECK_HOME` for per-user state, and — if it's broadly useful — into this SKILL.md and the
> bundled `defaults/`. The skill must accumulate every lesson learned.

## Inputs (all user-provided)
- **The textbook EPUB** — a path the user gives you (e.g. `~/Downloads/JBP1.epub`). Unzip it into
  the run's work dir. Do not assume any pre-existing unzipped copy.
- **The lesson number** to build.
- Optional: an output path for the `.apkg` (default: `$JBP_DECK_HOME/decks/Lesson_<N>.apkg`).

## State & fixes home — `$JBP_DECK_HOME`  (persists across runs, NEVER in git)
Per-user state lives **outside** the plugin (the plugin install is a versioned cache that is wiped
on every update, so state kept inside it would be lost). Location: the env var **`JBP_DECK_HOME`**,
default **`~/.jbp-lesson-deck/`**. Create it on first run and seed it from this skill's `defaults/`:
- **`romaji-overrides.json`** — a `{ "かな": "Romaji" }` map of manual romaji fixes (cutlet gets some
  words wrong). Loaded on every run and merged over cutlet's output. **Append new fixes here as you
  find them.** Seed shipped in `defaults/romaji-overrides.json`.
- **`learnings.md`** — free-text notes the agent should read FIRST each run and append to at the end
  (book quirks, per-lesson gotchas). Seed shipped in `defaults/learnings.md`.
- **`work/`** — scratch: unzipped EPUBs, image crops, contact sheets. Safe to delete.
- **`decks/`** — output `.apkg` files.
`$JBP_DECK_HOME` is never committed. Keep secrets (e.g. a future `ELEVENLABS_API_KEY`) out of it and
out of the repo — use an environment variable.

## Card scope per lesson (locked)
Card everything teachable. Images are best-effort; a missing image never blocks a card.
- ✅ **Main vocabulary** — every `<table class="voca">` entry.
- ✅ **Word Power** — every themed set, in full (incl. number/counter lists).
- ✅ **Key Sentences** — every model sentence.
- ✅ **Grammar example sentences** — the full example sentences in the GRAMMAR section (japanese
  span ending in 。, e.g. `これは わたしの ペンです。`). EXCLUDE pattern placeholders (`これは
  nounです。`) and bare paradigm fragments (`〜です`/`〜でした`). A copula-paradigm reference card is
  optional. `extract_lesson.py` does NOT pull these — grab them by hand from the GRAMMAR block.
- ⏸️ **Target Dialogue** — do not card as its own sentences (context-dependent, low ROI).
- ❌ **Exercises & Speaking Practice** — SKIP entirely: interactive drills, better done from the book.
- 📇 **Reference content** (conjugation tables, counter charts, image-only list pages) → optional
  reference cards (image or formatted text). Best-effort. `extract_lesson.py` reports their counts.

## Per-lesson procedure

### 0. Setup
Ensure `$JBP_DECK_HOME` exists; seed `romaji-overrides.json` + `learnings.md` from `defaults/` if
missing. **Read `learnings.md` first.** Confirm Python deps import: `genanki cutlet pykakasi numpy
Pillow` (`pip install --user` any missing). macOS `afconvert` is built in. Make a scratch work dir
under `$JBP_DECK_HOME/work/lesson-<N>/`.

### 1. Ingest the EPUB + locate the lesson
Unzip the user's EPUB into the work dir (`unzip -oq <epub> -d <work>/epub`). Lesson chapters are in
`OEBPS/xhtml/*_cNN_r1.xhtml`; images in `OEBPS/images/`. **The chapter number ≠ the lesson number** —
grep the xhtml files for the `LESSON <N>` heading to find the right file.

### 2. 🔴 Read every page / every image (mandatory)
List every `Page_*_Image_*.jpg` the chapter references. Build labeled contact sheets (PIL: scale
each image, caption it with filename+page+section, tile ~2-wide) and **Read every sheet.** The
EXERCISE pages in particular hide clean, isolated line drawings of the vocab objects that make great
per-word card images once the drill's name-label box is cropped off. Catalogue what each image is
and map drawings to vocab BEFORE building. `word_power: 0` from the extractor does NOT mean "no
images" — it means "no per-word `<figure>` figures"; a shared illustration + a `①②③` numbered list
still needs cards, audio (later), and images.

### 3. Extract content (`scripts/extract_lesson.py <chapter.xhtml>`)
Returns vocab (with `is_sub` flag), Word Power figures, Key Sentences (JP/EN), and counts of
reference tables / image-only lists. Then hand-grab the GRAMMAR example sentences (see scope).
Sub-entries (`is_sub`) are component breakdowns — usually keep as their own cards. Decide grammar
cross-reference stubs (bare particle `の` → "see GRAMMAR 3") case by case — usually drop.

### 4. Romaji (`cutlet`, Hepburn + overrides)
Romanize with cutlet (`use_foreign_spelling = False`), then apply `$JBP_DECK_HOME/romaji-overrides.json`
(exact-kana → romaji). Known fixes seeded in `defaults/`: cutlet inserts a spurious mid-word space in
some words (`かいしゃ→Kaisha`, `かさ→Kasa`, `おねがいします→Onegaishimasu`) and over-splits `いちど`
(`もう いちど→Mou ichido`); honorific style `スミスさんの→Sumisu-san no`. **Add any new mis-romanization
you spot to the overrides file.**

### 5. Images (best-effort; verify every crop)
- **Per-word `<figure>` figures**: copy `OEBPS/images/<file>.jpg` straight in.
- **Clean single-object exercise drawings** (book/watch/umbrella/wallet/key/phone/glasses/pen): crop
  to the object with the drill's name-label box + "1./e.g." marker whited out (`scripts/crop_objects.py`;
  coords read off a grid overlay of the source). **Read each output to verify** the label is gone and
  nothing is clipped; refine and re-crop as needed.
- **Composite scenes / labeled diagrams**: attach whole, or crop a single item out. A labeled diagram
  (parts pointed at by callouts) can only be attached whole.
- Most plain-vocab cards legitimately have no image — that's fine.

### 6. Build the deck (adapt `scripts/build_deck.py`)
Content-only (empty Audio field). See that script for the exact genanki model, two templates, CSS,
overrides loading, page lookup, and audit table — adapt the per-lesson data (VOCAB / NUMBERS / KEY /
GRAMMAR / IMAGES) and the deck title. **Deck organization** (so lessons accumulate under one book
deck): name `Japanese for Busy People 1::Lesson <N> — <Title>`; deck ID `1710000000 + N`; model ID
`1610000021` FIXED for every lesson (identical fields/templates/CSS — reusing one model id is what
lets Anki merge cleanly). Note GUIDs default (hashed from fields), so re-imports update, not duplicate.

### 7. 🔴 Audit table (mandatory hand-off)
Every run MUST finish by printing an audit table so the user can review the deck against the textbook
BEFORE trusting it. One row per note, grouped (Vocab / Numbers / Key Sentences / Grammar), columns:
**English · Kana · Romaji · Page · Image?** — where **Page** is the textbook page (map via the EPUB
`epub:type="pagebreak" title="N"` byte offsets; see `page_of()` in `build_deck.py`) so the user can
cross-reference, and Image? is a ✓/· flag. Follow with totals. (An Audio? column will join once the
TTS phase exists.) Then hand to the user to review and import.

### 8. Save learnings
Append any new romaji fixes to `$JBP_DECK_HOME/romaji-overrides.json` and any new book quirks to
`$JBP_DECK_HOME/learnings.md`. If broadly useful, also update `defaults/` and this SKILL.md.

## Card model (Anki)
Fields: **Kana** (always; katakana for loanwords), **Romaji**, **English**, **Hint** (usage note
when the book gives one), **Image** (only where the book has one), **Audio** (empty for now — TTS
phase), **Kanji** (empty — this is the Kana edition). Two templates per note:
- **Recognition (JP→EN):** front = Image + Kana + Audio → back adds Romaji + English + Hint.
- **Production (EN→JP):** front = English (+ Hint) → back adds Kana + Romaji + Image + Audio.

## Verify (always)
Re-open the `.apkg`: 2 cards/note; every note has Kana/Romaji/English; every `<img>` ref resolves in
the package `media` map; deck name is `Japanese for Busy People 1::Lesson <N> — …`. Spot-check crops.

## Script index (`scripts/`)
- `extract_lesson.py` — parse a lesson's vocab / Word Power / Key Sentences from its chapter xhtml.
- `crop_objects.py` — crop a clean per-object image from an exercise drawing (white out the drill's
  name-label + number marker, then crop to the object). Grid-overlay helper to read coordinates.
- `build_deck.py` — the content-only genanki build template: model, two templates, CSS, romaji
  overrides loading, EPUB page lookup, and the audit table. Adapt the per-lesson data + title.

## Audio — FUTURE PHASE (not implemented in this skill)
Audio will be generated separately with **ElevenLabs TTS** and merged into the Audio field: send each
card's kana to the API (`eleven_multilingual_v2`; free-tier works with default voices such as Sarah/
Laura/George/Brian/Lily/Alice — legacy "library" voices like Rachel/Aria are blocked on free tier),
save the returned MP3, and attach it. The API key MUST come from the `ELEVENLABS_API_KEY` environment
variable — never write it to any file in the repo or to `$JBP_DECK_HOME`. This phase is deliberately
deferred; today's decks ship silent.
