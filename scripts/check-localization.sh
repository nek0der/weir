#!/usr/bin/env bash
# Weir — fail when a string in the catalog is not finished in English and Japanese, or its Japanese drops a long vowel.
#
# Every user-visible string ships in English and Japanese; an English-only
# entry is incomplete, but nothing caught it except a reviewer's eye. Xcode
# adds a key on build with no `ja` at all, or marks an edited one
# `needs_review`, so we check the state rather than the presence: each key
# that should be translated needs a `ja` entry whose string units (including
# every plural or device variation and every substitution) are all
# `translated`. An English entry, where a key has one, is held to the same
# state, so an English value that was never confirmed is caught as well.
#
# The Japanese also writes words such as 「フォルダー」, 「エディター」, and
# 「コンピューター」 with their long vowel, so each word has one form. Most
# of the catalog came to say 「フォルダ」 one string at a time, so the short
# forms are refused here rather than left to a reviewer.
#
# Usage: scripts/check-localization.sh [CATALOG]
# Default catalog: Weir/Resources/Localizable.xcstrings

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="${1:-${REPO_ROOT}/Weir/Resources/Localizable.xcstrings}"

# -I keeps the interpreter from importing anything from the working directory
# or the user's site-packages; the check needs only the standard library.
python3 -I - "$CATALOG" <<'PY'
import json
import re
import sys

catalog_path = sys.argv[1]
with open(catalog_path, encoding="utf-8") as handle:
    strings = json.load(handle).get("strings", {})


def string_units(node):
    """Every stringUnit under a localization.

    Walks plural and device `variations` at any depth, and `substitutions`,
    which Xcode writes when a string with several arguments varies by plural:
    each substitution holds its own variations.
    """
    if not isinstance(node, dict):
        return
    if "stringUnit" in node:
        yield node["stringUnit"]
    for cases in node.get("variations", {}).values():
        for case in cases.values():
            yield from string_units(case)
    for substitution in node.get("substitutions", {}).values():
        yield from string_units(substitution)


# A short form is the word with no 「ー」 after it; 「フォルダー」 and
# 「フォルダーを」 pass, 「フォルダ」 and 「フォルダを」 do not.
SHORT_FORMS = re.compile("(フォルダ|エディタ|コンピュータ|ユーザ|サーバ|ブラウザ|パラメータ|プロバイダ|マネージャ)(?!ー)")

problems = []
for key, entry in strings.items():
    if entry.get("shouldTranslate") is False:
        continue
    en = entry.get("localizations", {}).get("en")
    if en is not None:
        en_states = sorted({unit.get("state", "missing") for unit in string_units(en)})
        if en_states and en_states != ["translated"]:
            problems.append((key, "en state is " + ", ".join(en_states)))
    ja = entry.get("localizations", {}).get("ja")
    if ja is None:
        problems.append((key, "no ja localization"))
        continue
    units = list(string_units(ja))
    if not units:
        problems.append((key, "ja has no string units"))
        continue
    states = sorted({unit.get("state", "missing") for unit in units})
    if states != ["translated"]:
        problems.append((key, "ja state is " + ", ".join(states)))
    short = sorted({match.group(0) for unit in units for match in SHORT_FORMS.finditer(unit.get("value", ""))})
    if short:
        problems.append((key, "ja writes without the long vowel: " + "、".join(short)))

for key, reason in problems:
    print(f"✗ {reason}: {json.dumps(key, ensure_ascii=False)}", file=sys.stderr)
if problems:
    print(f"{len(problems)} string(s) lack a finished translation or the long vowel in {catalog_path}", file=sys.stderr)
    sys.exit(1)
print(f"✓ every string to translate is finished, with the long vowel in Japanese ({len(strings)} keys)")
PY
