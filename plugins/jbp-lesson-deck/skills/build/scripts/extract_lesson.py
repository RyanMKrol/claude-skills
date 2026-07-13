#!/usr/bin/env python3
"""
Extract card material from one JBP1 lesson XHTML file.

The book has a RIGID, identical template across all 24 lessons, so this one parser
works for every lesson. It pulls:
  - Main VOCABULARY: every <table class="voca"> row — Japanese in
    <span class="japanese" lang="ja">, English in the sibling cell. Rows with
    <td class="sub"> are component sub-entries (kept, flagged is_sub=True).
  - WORD POWER figures (Type A): <figure> with <img> + <figcaption> containing a
    numbered marker + <span class="japanese">. These give an image PER word.
  - KEY SENTENCES: numbered JP/EN pairs (two parallel numbered lists).
It also REPORTS (does not silently drop) content that isn't discrete-vocab:
  - reference tables (<table class="tab1"> — conjugation / counter / period charts)
  - image-only Word Power lists (a shared image + a marginL1 numbered text list)
so you can turn those into reference cards (per the user's decision) or review them.

The book is 100% kana (no kanji, no <ruby>), so the Japanese cell IS the kana.
Katakana appears organically for loanwords — that's fine, it's still the Kana field.

Deps: standard library only (regex-based; the markup is clean and consistent).
Usage: python3 extract_lesson.py <lesson.xhtml>  -> prints a JSON summary.
"""
import re, html, json, sys

JP = re.compile(r'<span class="japanese"[^>]*>(.*?)</span>', re.S)
def clean(s):
    s = re.sub(r'<[^>]+>', '', s); return html.unescape(s).replace('　',' ').strip()

def extract(path):
    raw = open(path, encoding="utf-8").read()
    out = {"vocab": [], "word_power": [], "key_sentences": [],
           "reference_tables": 0, "image_only_lists": 0}

    # --- VOCABULARY (and grammar-section vocab): every <table class="voca"> ---
    for tbl in re.findall(r'<table class="voca".*?</table>', raw, re.S):
        for tr in re.findall(r'<tr>.*?</tr>', tbl, re.S):
            is_sub = 'class="sub"' in tr
            cells = re.findall(r'<td[^>]*>(.*?)</td>', tr, re.S)
            if len(cells) < 2: continue
            jp = JP.search(cells[0]); en = clean(cells[1])
            if jp and clean(jp.group(1)):
                out["vocab"].append({"kana": clean(jp.group(1)), "english": en, "is_sub": is_sub})

    # --- WORD POWER Type A: figure + img + figcaption(number + japanese) ---
    for fig in re.findall(r'<figure[^>]*>.*?</figure>', raw, re.S):
        img = re.search(r'<img[^>]*src="[^"]*?([^/"]+\.jpg)"', fig)
        cap = re.search(r'<figcaption.*?</figcaption>', fig, re.S)
        if img and cap:
            jp = JP.search(cap.group(0))
            if jp:
                marker = clean(re.sub(r'<span class="japanese".*?</span>', '', cap.group(0), flags=re.S))
                out["word_power"].append({"kana": clean(jp.group(1)), "image": img.group(1),
                                          "marker": marker})

    # --- KEY SENTENCES: numbered japanese list + parallel english list ---
    for blk in re.findall(r'<div class="key-sentence-sub">.*?</div>\s*</div>', raw, re.S):
        jps = [clean(x) for x in JP.findall(blk)]
        # english list items are role="listitem" lines without a japanese span
        items = re.findall(r'<p class="list_ul"[^>]*>(.*?)</p>', blk, re.S)
        ens = [clean(re.sub(r'<span class="list_ornament".*?</span>', '', it, flags=re.S))
               for it in items if 'class="japanese"' not in it]
        for jp, en in zip(jps, ens):
            out["key_sentences"].append({"kana": jp, "english": en})

    # --- report non-vocab content (for reference cards / manual handling) ---
    out["reference_tables"] = len(re.findall(r'<table class="tab1"', raw))
    out["image_only_lists"] = len(re.findall(r'<div class="marginL1">', raw))
    return out

if __name__ == "__main__":
    data = extract(sys.argv[1])
    print(json.dumps({k:(len(v) if isinstance(v,list) else v) for k,v in data.items()},
                     ensure_ascii=False, indent=2))
    print("\n--- first 5 vocab ---")
    for v in data["vocab"][:5]:
        print(f"  {'  (sub)' if v['is_sub'] else ''}{v['kana']}  =  {v['english']}")
