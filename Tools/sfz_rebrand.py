#!/usr/bin/env python3
"""sfz rebrand: show NOOP's on-screen text with sfz's names, without touching code logic.

Writes English values into the String Catalog so that, on screen:
  NOOP   -> Sfz Health
  Charge -> Recovery   (the score, not "charge your strap")
  Effort -> Strain
  Rest   -> Sleep      (the score)

Only localized UI strings change. Identifiers that the code compares (category keys, stored
values) are plain strings, not catalog lookups, so they are unaffected.

Re-run after every merge from upstream NOOP: take upstream's Localizable.xcstrings, then
    python3 Tools/sfz_rebrand.py
"""
import json
import re
import sys
from pathlib import Path

CATALOGS = [
    Path("Strand/Resources/Localizable.xcstrings"),
    Path("Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings"),
    Path("NOOPWatch/Localizable.xcstrings"),
    Path("NOOPWatchComplications/Localizable.xcstrings"),
]

# Strings that must keep NOOP's name (licence attribution, links, legal identity).
KEEP_IF_CONTAINS = ("I am not a WHOOP employee", "I own the WHOOP device", "I understand NOOP is unofficial",
                    "To the fullest extent the law allows", "NoopApp", "github.com", "Copyright", "PolyForm", "noop.fans", "r/NoopBand")

# Keys where "Rest" means a workout pause or resting heart rate, not the sleep score.
SKIP_KEYS = {"Rest (seconds)", "Rest period", "Rest HR", "Rest up"}

# "Charge" followed by one of these words is about the strap battery, not the score.
BATTERY_FOLLOWERS = r"(?:it|your|the|before|now|up|tonight|overnight|level|cable|puck|soon|when|while)"


def rebrand(text: str) -> str:
    if any(k in text for k in KEEP_IF_CONTAINS):
        return text
    out = re.sub(r"\bNOOP\b", "Sfz Health", text)
    out = re.sub(r"\bCharge\b(?!\s+" + BATTERY_FOLLOWERS + r"\b)", "Recovery", out)
    out = re.sub(r"\bEffort\b", "Strain", out)
    out = re.sub(r"\bRest\b", "Sleep", out)
    # Tidy doubles created where NOOP listed Rest beside Sleep, or Charge beside Recovery.
    for word in ("Sleep", "Recovery"):
        out = re.sub(rf"\b{word}( &| and| \+| ·| /|,) {word}\b", word, out)
    out = re.sub(r"\bSleep or Sleep\b", "Sleep", out)
    out = out.replace("Recovery (recovery)", "Recovery")
    out = out.replace("Recovery, Sfz Health's Recovery score,", "Sfz Health's Recovery score")
    return out


def apply_to_unit(node):
    """Rewrite every stringUnit value inside a localization node (handles plural/device variations)."""
    if isinstance(node, dict):
        if "stringUnit" in node and isinstance(node["stringUnit"], dict):
            unit = node["stringUnit"]
            if "value" in unit:
                unit["value"] = rebrand(unit["value"])
        for value in node.values():
            apply_to_unit(value)
    elif isinstance(node, list):
        for value in node:
            apply_to_unit(value)


STRING_LIT = r'"(?:[^"\\]|\\.)*"'
STRING_RE = re.compile(STRING_LIT)


def matching_brace(text, open_idx):
    """Index of the brace closing the one at open_idx, skipping string literals."""
    depth, i, n = 0, open_idx, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i = STRING_RE.match(text, i).end()
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("unbalanced braces")


def rebrand_block(block, key, source):
    """Rewrite only the English values inside one catalog entry's text. Returns new text."""
    if key in SKIP_KEYS:
        return block
    m = re.search(r'"' + re.escape(source) + r'"\s*:\s*\{', block)
    if m:
        lo = m.end() - 1
        hi = matching_brace(block, lo)
        span = block[lo:hi + 1]

        def fix(vm):
            old = json.loads(vm.group(2))
            new = rebrand(old)
            return vm.group(1) + (json.dumps(new, ensure_ascii=False) if new != old else vm.group(2))

        span2 = re.sub(r'("value"\s*:\s*)(' + STRING_LIT + ')', fix, span)
        return block[:lo] + span2 + block[hi + 1:]
    new_text = rebrand(key)
    if new_text == key:
        return block
    en = f'"{source}": {{"stringUnit": {{"state": "translated", "value": {json.dumps(new_text, ensure_ascii=False)}}}}}'
    lm = re.search(r'"localizations"\s*:\s*\{', block)
    if lm:
        rest = block[lm.end():].lstrip()
        sep = "" if rest.startswith("}") else ", "
        return block[:lm.end()] + en + sep + block[lm.end():]
    # Entry with no translations at all, e.g.  "Key": {}  or  "Key": {"comment": ...}
    km = re.match(r'(\s*' + STRING_LIT + r'\s*:\s*\{)', block)
    rest = block[km.end():].lstrip()
    sep = "" if rest.startswith("}") else ", "
    return block[:km.end()] + '"localizations": {' + en + "}" + sep + block[km.end():]


def main() -> int:
    # Edit text in place so only touched values change: upstream's layout is hand-formatted and
    # mixed, and a re-serialised file would turn every merge from NOOP into a conflict.
    for path in CATALOGS:
        if not path.exists():
            print(f"skip (missing): {path}")
            continue
        text = path.read_text(encoding="utf-8")
        source = json.loads(text).get("sourceLanguage", "en")
        sm = re.search(r'"strings"\s*:\s*\{', text)
        i, end = sm.end(), matching_brace(text, sm.end() - 1)
        out, changed, prev = [], 0, 0
        while True:
            km = re.compile(r'\s*,?\s*(' + STRING_LIT + r')\s*:\s*\{').match(text, i)
            if not km or km.start() >= end:
                break
            st = km.start(1)
            close = matching_brace(text, km.end() - 1)
            block = text[st:close + 1]
            new_block = rebrand_block(block, json.loads(km.group(1)), source)
            if new_block != block:
                changed += 1
            out.append(text[prev:st])
            out.append(new_block)
            prev = i = close + 1
        out.append(text[prev:])
        new_text = "".join(out)
        json.loads(new_text)  # must still be valid JSON
        path.write_text(new_text, encoding="utf-8")
        print(f"{path}: {changed} strings rebranded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
