#!/usr/bin/env python3
"""Generate per-card audio with ElevenLabs TTS (the audio phase; run AFTER content is approved).

Reads a manifest of card kana (written by build_deck.py) and produces one MP3 per unique kana into
an audio dir, named by tts_common.slug() so build_deck.py can attach them. Idempotent + cached:
a kana whose MP3 already exists is skipped, so re-runs cost no quota and add no new API calls.

Config (nothing hard-coded, no secrets in files):
  ELEVENLABS_API_KEY   (required)  — the API key; env var ONLY, never written to disk
  JBP_TTS_VOICE        (required)  — the ElevenLabs voice_id to use
  JBP_TTS_MODEL        default eleven_multilingual_v2
  JBP_AUDIO_DIR        default $JBP_DECK_HOME/audio/<voice_id>  — voice-specific; shared across lessons
  argv[1]              path to cards.json manifest (else $JBP_DECK_HOME/work/cards.json)

Prints per-word status and the total characters billed (for quota awareness).
Deps: certifi (for TLS on the python.org build); stdlib otherwise.
"""
import os, sys, json, ssl, time, urllib.request, urllib.error
import certifi
from tts_common import slug, speak_text

KEY = os.environ.get("ELEVENLABS_API_KEY")
VOICE = os.environ.get("JBP_TTS_VOICE")
MODEL = os.environ.get("JBP_TTS_MODEL", "eleven_multilingual_v2")
HOME = os.path.expanduser(os.environ.get("JBP_DECK_HOME", "~/.jbp-lesson-deck"))
MANIFEST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HOME, "work", "cards.json")
CTX = ssl.create_default_context(cafile=certifi.where())

if not KEY:   sys.exit("ERROR: set ELEVENLABS_API_KEY (env var only — never commit it)")
if not VOICE: sys.exit("ERROR: set JBP_TTS_VOICE to the ElevenLabs voice_id to use")
AUDIO_DIR = os.environ.get("JBP_AUDIO_DIR", os.path.join(HOME, "audio", VOICE))


def tts(text):
    body = json.dumps({"text": text, "model_id": MODEL,
                       "voice_settings": {"stability": 0.5, "similarity_boost": 0.75}}).encode()
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE}", data=body,
        headers={"xi-api-key": KEY, "Content-Type": "application/json", "Accept": "audio/mpeg"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60, context=CTX) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            msg = e.read().decode("utf-8", "replace")
            if e.code in (429, 500, 502, 503) and attempt < 3:
                time.sleep(2 * (attempt + 1)); continue
            raise SystemExit(f"TTS failed HTTP {e.code}: {msg[:300]}")
    raise SystemExit("TTS failed after retries")


def main():
    os.makedirs(AUDIO_DIR, exist_ok=True)
    cards = json.load(open(MANIFEST, encoding="utf-8"))
    seen, made, cached, chars = {}, 0, 0, 0
    for c in cards:
        kana = c["kana"]
        if kana in seen: continue
        seen[kana] = True
        out = os.path.join(AUDIO_DIR, slug(kana))
        if os.path.exists(out):
            cached += 1; print(f"  · cached  {kana}"); continue
        text = speak_text(kana)
        audio = tts(text)
        open(out, "wb").write(audio)
        chars += len(text); made += 1
        print(f"  ✓ made    {kana:22} -> {os.path.basename(out)}  ({len(audio)} B, {len(text)} chars)")
    print(f"\nvoice={VOICE} model={MODEL}")
    print(f"unique kana: {len(seen)}  made: {made}  cached: {cached}  characters billed this run: {chars}")
    print(f"audio dir: {AUDIO_DIR}")


if __name__ == "__main__":
    main()
