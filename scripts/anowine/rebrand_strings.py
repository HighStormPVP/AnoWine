"""Rebrand user-visible strings in an Xcode string catalog from Whisky to AnoWine.

Rewrites localized VALUES only, never keys, so Swift code (which uses the keys)
stays identical to upstream and merges stay clean. Re-run after every upstream
merge; it is idempotent.

  WhiskyWine -> "Wine runtime" (English) / "Wine" (other languages)
  Whisky     -> AnoWine

A key whose text mentions Whisky but has no English localization gets one,
because Xcode would otherwise show the key itself.

Usage: python3 rebrand_strings.py [--check] <Localizable.xcstrings>
  --check  exit 1 if a rewrite would change the file, without writing it
"""
import json
import re
import sys

# References to the upstream repo (e.g. "frankea/Whisky#41") name a real
# place and must survive the rebrand.
_UPSTREAM_REF = re.compile(r"\b[\w.-]+/Whisky\b")
_PLACEHOLDER = "\x00upstream%d\x00"


def _rewrite(text, english):
    refs = []

    def stash(match):
        refs.append(match.group(0))
        return _PLACEHOLDER % (len(refs) - 1)

    text = _UPSTREAM_REF.sub(stash, text)
    # "The Wine runtime (WhiskyWine)" already says it; drop the old brand name.
    text = re.sub(r" ?\(WhiskyWine\)", "", text)
    text = text.replace("WhiskyWine", "Wine runtime" if english else "Wine")
    text = text.replace("Whisky", "AnoWine")
    for i, ref in enumerate(refs):
        text = text.replace(_PLACEHOLDER % i, ref)
    return text


def _is_english(lang):
    return lang == "en" or lang.startswith("en-")


def rebrand(catalog):
    """Rewrite catalog in place. Returns True if anything changed."""
    changed = False
    source = catalog.get("sourceLanguage", "en")
    for key, entry in catalog.get("strings", {}).items():
        localizations = entry.setdefault("localizations", {})
        for lang, loc in localizations.items():
            unit = loc.get("stringUnit")
            if unit and "value" in unit:
                new = _rewrite(unit["value"], _is_english(lang))
                if new != unit["value"]:
                    unit["value"] = new
                    changed = True
        if "Whisky" in key and source not in localizations:
            localizations[source] = {"stringUnit": {"state": "translated", "value": _rewrite(key, True)}}
            entry["localizations"] = dict(sorted(localizations.items()))
            changed = True
        if not entry["localizations"]:
            del entry["localizations"]
    return changed


def dump(catalog):
    """Serialise exactly the way Xcode writes .xcstrings files."""
    return json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))


def main(argv):
    check = "--check" in argv
    paths = [a for a in argv if a != "--check"]
    if len(paths) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    path = paths[0]
    with open(path, encoding="utf-8") as f:
        catalog = json.load(f)
    if not rebrand(catalog):
        print("rebrand_strings: up to date")
        return 0
    if check:
        print("rebrand_strings: %s needs rebranding (run without --check)" % path)
        return 1
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(dump(catalog))
    print("rebrand_strings: rewrote %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
