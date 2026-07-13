# jbp-lesson-deck

Build a rich Anki deck for one lesson of a **"Japanese for Busy People"** textbook, from a
**user-provided EPUB**. One skill, `build`.

## What it does

Given the textbook EPUB and a lesson number, it:

- extracts **vocabulary**, **Word Power** sets, **Key Sentences**, and **grammar example sentences**;
- crops the textbook's **illustrations** onto the relevant cards (best-effort);
- writes **kana**, **romaji** (cutlet + a per-user overrides file), and usage **hints**;
- builds a two-template Anki deck (**Recognition** JP→EN and **Production** EN→JP), each lesson a
  sub-deck of one shared `Japanese for Busy People 1` deck so imports accumulate;
- finishes by printing an **audit table** — English · Kana · Romaji · textbook page · image? — so you
  can review the deck against the book before trusting it.

It **reads every page and every image** (never infers content from headings), and produces a
`.apkg` you import and review.

## Usage

```
/jbp-lesson-deck:build
```

Then give it the path to your textbook EPUB and the lesson number. Nothing about the textbook's
location is hard-coded — you supply the EPUB.

## State & fixes — `$JBP_DECK_HOME` (default `~/.jbp-lesson-deck/`, never in git)

Per-user state lives outside the plugin (the plugin install is a versioned cache that is replaced on
every update). Created on first run, seeded from the skill's `defaults/`:

- `romaji-overrides.json` — `{ "かな": "Romaji" }` manual fixes for the words cutlet gets wrong;
  grows as you find more.
- `learnings.md` — cross-run notes the agent reads first and appends to.
- `work/`, `decks/` — scratch and output.

## Audio (planned, not yet implemented)

Cards currently ship **silent** (empty Audio field). Audio will be a separate phase using
**ElevenLabs TTS** (kana → MP3, `eleven_multilingual_v2`), with the API key supplied via the
`ELEVENLABS_API_KEY` environment variable — never committed.

## Note on textbook content

The skill reads a copyrighted textbook you supply; it does not ship any textbook text, images, or
audio. Generated decks (and any cropped images) stay in your local `$JBP_DECK_HOME` and are not part
of this repo.
