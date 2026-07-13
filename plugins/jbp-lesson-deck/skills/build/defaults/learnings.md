# JBP lesson-deck — learnings (read this FIRST each run)

This file seeds `$JBP_DECK_HOME/learnings.md`. The agent reads it at the start of every run and
appends new discoveries at the end. Durable process rules live in SKILL.md; this file is for
accumulated, evolving gotchas.

## 🔴 Never skip a page
Read EVERY image in the lesson (contact sheets + actually look). Inferring content from section
headings once shipped a deck with no images and missing content. `word_power: 0` from the extractor
only means "no per-word `<figure>` figures" — it does NOT mean the lesson has no usable images.
The EXERCISE pages hide clean single-object drawings (book/watch/umbrella/wallet/key/phone/glasses/
pen) that make excellent per-word card images once the drill's name-label box is cropped off.

## Content scope
Card: all vocabulary, all Word Power, all Key Sentences, and GRAMMAR **example sentences** (full
sentences ending in 。, e.g. `これは わたしの ペンです。`). The extractor does NOT return grammar
sentences — grab them by hand from the GRAMMAR `<h2>`…next-`<h2>` block. Skip Exercises and Speaking
Practice entirely (interactive). Do not card the Target Dialogue as sentences.

## Romaji (cutlet) quirks — add fixes to romaji-overrides.json
cutlet inserts a spurious mid-word space in some words: `かいしゃ→"Ka isha"` (want Kaisha),
`かさ→"Ka sa"` (Kasa), `おねがいします→"Onegai shimasu"` (Onegaishimasu). It also over-splits
`いちど`. Honorific style: render `〜さん` as `-san` (`スミスさんの → Sumisu-san no`). Whenever you
see a mis-romanization, add the exact kana→romaji to the overrides file.

## Images
Per-word `<figure>` figures copy straight in. Clean single-object exercise drawings: white out the
name-label box + the "1./e.g." marker (read coords off `crop_objects.py grid`), crop to the object,
then **Read the output to verify** (label gone, nothing clipped) and refine. Labeled diagrams (a
business card with ①-⑥ callouts) can only be attached whole. Composite scenes: attach whole or crop
one item out. A faint leftover leader-line stub is acceptable; a visible label is not.

## Deck organization
Sub-deck of one book deck so imports accumulate: `Japanese for Busy People 1::Lesson <N> — <Title>`,
deck id `1710000000 + N`, model id `1610000021` FIXED for every lesson (identical fields/templates/
CSS — reusing the one model id is what lets Anki merge cleanly instead of spawning duplicate note
types).

## Audit table
Always finish by printing the audit table (English · Kana · Romaji · Page · Image?) so the user can
cross-reference the textbook before trusting the deck. Page comes from the EPUB `pagebreak title="N"`
markers.

## Audio (future)
Not built yet. Will be ElevenLabs TTS from kana → MP3 (`eleven_multilingual_v2`; free-tier voices
Sarah/Laura/George/Brian/Lily/Alice work — legacy "library" voices like Rachel/Aria are 402-blocked
on free tier). Key via `ELEVENLABS_API_KEY` env var only — never commit it.
