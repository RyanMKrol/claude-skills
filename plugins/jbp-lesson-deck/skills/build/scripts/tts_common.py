#!/usr/bin/env python3
"""Shared helpers for the ElevenLabs TTS phase: stable per-kana filenames + spoken text.

Kept tiny and dependency-free so both build_deck.py and generate_audio.py import it, guaranteeing
the deck and the audio agree on filenames (so caching works and every [sound:] ref resolves)."""
import hashlib, re


def slug(kana):
    """Deterministic, collision-free audio filename for a kana string (stable across runs, so a
    word's mp3 is generated once and reused — including across lessons)."""
    return "tts_" + hashlib.sha1(kana.encode("utf-8")).hexdigest()[:12] + ".mp3"


def speak_text(kana):
    """Turn a card's Kana field into the text to send to TTS.
    - drop the placeholder wave-dash 〜 (〜じゃありません → じゃありません; お〜 → お)
    - dual readings joined by ／ become a spoken pause (ゼロ／れい → ゼロ、れい) so BOTH are voiced
    - keep 。、 as natural pauses; collapse whitespace."""
    t = kana.replace("／", "、").replace("〜", "")
    t = re.sub(r"\s+", " ", t).strip()
    return t
