#!/usr/bin/env python3
"""Generate an Elm module from the conformance fixture JSON files.

Elm 0.19 can't read files at test time, so fixtures have to be
baked into an Elm module. This script reads every JSON file under
`lynrummy/conformance/` and emits
`elm-lynrummy/tests/LynRummy/Fixtures.elm` as a list of
(name, raw-JSON) pairs. The Elm test suite parses the raw JSON via
the existing `refereeMoveDecoder` / `cardStackDecoder` etc., so the
JSON decoders get exercised as part of the test.

Re-run whenever a fixture is added, removed, or edited.
"""

import json
from pathlib import Path

REPO = Path("/home/steve/showell_repos/angry-gopher")
FIXTURES_DIR = REPO / "lynrummy" / "conformance"
OUT_PATH = Path("/home/steve/showell_repos/angry-gopher/elm-lynrummy/tests/LynRummy/Fixtures.elm")


TRIPLE = '"' * 3


def elm_string_literal(s: str) -> str:
    # Render a Python string as an Elm triple-quoted literal.
    # Elm's triple-quote string is safer than single-quote for JSON
    # blobs — no need to escape inner double quotes, backslashes, or
    # newlines. Only guard: an actual triple-quote sequence in the
    # source (never happens in our fixtures).
    if TRIPLE in s:
        raise ValueError("fixture contains triple-quote; loader can't handle this")
    return TRIPLE + s + TRIPLE


def main() -> None:
    fixtures = []
    for path in sorted(FIXTURES_DIR.glob("*.json")):
        raw = path.read_text()
        # Round-trip through json to normalize whitespace (makes
        # regenerated Fixtures.elm diffs smaller).
        normalized = json.dumps(
            json.loads(raw),
            separators=(",", ":"),
            ensure_ascii=False,  # Elm triple-quote handles UTF-8 directly;
            # avoids \uXXXX escapes Elm won't parse.
        )
        fixtures.append((path.stem, normalized))

    entries = ",\n      ".join(
        f'( "{name}", {elm_string_literal(raw)} )'
        for name, raw in fixtures
    )

    body = f"""module LynRummy.Fixtures exposing (fixtures)

{{-| GENERATED FILE — DO NOT EDIT BY HAND.

Regenerate with:
  python3 angry-gopher/tools/gen_elm_fixtures.py

Source: angry-gopher/lynrummy/conformance/*.json

Each tuple is (fixture-name, raw-JSON). The test suite decodes the
raw JSON at test time, so parser bugs in Elm decoders surface as
fixture failures.
-}}


fixtures : List ( String, String )
fixtures =
    [ {entries}
    ]
"""

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(body)
    print(f"Wrote {len(fixtures)} fixtures to {OUT_PATH}")


if __name__ == "__main__":
    main()
