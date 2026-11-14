#!/usr/bin/env python3
"""Generate tests/conformance/canonical/unit_spelling*.json from the Lean model.

The canonical unit spelling (esm-spec §4.8.2) is defined by the Lean function
`Esm.Units.canon` (formal/Esm/Units/Canonical.lean). This script evaluates it
on every case below with `lake env lean`, so Lean is the oracle for the
fixtures every binding's canonicalizer must reproduce byte for byte:

* `unit_spelling.json`: one `const` node per case under an order-preserving
  `max`, so the canonical JSON lists the spellings in case order.
* `unit_spelling_ordering.json`: two `const` nodes under `*`, whose §5.4.2 order
  flips once their units are respelled; a binding that respells after sorting
  (or only when emitting) gets the order wrong.

The Lean package must already be built (`lake build` in formal/); `--formal`
points at another copy of formal/ that is. Re-run after a change to the cases
or to the Lean definition:

    python3 scripts/gen-canonical-unit-spelling.py [--formal DIR]
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "tests" / "conformance" / "canonical"

# (units string, what it exercises). Inputs that the spelling leaves unchanged
# are ASCII, so the expected bytes do not depend on a binding's JSON escaping.
CASES: list[tuple[str, str]] = [
    # Numerator sorting, one spelling for many.
    ("m*h/(mi*s)", "numerator sorted by symbol"),
    ("m h/(mi s)", "juxtaposition is *"),
    ("m·h/(mi⋅s)", "middot and dot operator are *"),
    ("kg * m / s ^ 2", "whitespace between tokens"),
    ("s*kg", "sorted"),
    ("J/mol/K", "codepoint order: uppercase first; one /"),
    ("J/(mol*K)", "same unit, same spelling"),
    ("J/mol*K", "left-to-right: K is in the numerator"),
    ("cm^3 molec^-1 s^-1", "negative exponents move to the denominator"),
    ("cm^3/molec/s", "chained / folds into one parenthesized denominator"),
    # The denominator.
    ("m^-1", "empty numerator is 1"),
    ("s^-2*kg", "single denominator factor, no parentheses"),
    ("1/(1/s)", "a double negation lands in the numerator"),
    # No cancellation across the fraction bar.
    ("mol/mol", "no cancellation"),
    ("mol/mol/s", "no cancellation, compound denominator"),
    ("m m^-1", "no cancellation of a negative exponent"),
    ("K^-1*K", "no cancellation, numerator first"),
    ("m*m/m", "summing within the numerator only"),
    ("m^2/m^-1", "dividing by a negative exponent adds to the numerator"),
    ("m^(1/2)/m^(1/2)", "no cancellation of rational exponents"),
    # The dimensionless spellings.
    ("", "the empty string is 1"),
    ("1", "1"),
    ("dimensionless", "dimensionless is 1"),
    ("dimensionless/s", "dimensionless inside a product contributes nothing"),
    ("dimensionless m", "dimensionless inside a product contributes nothing"),
    ("ppb^-1 s^-1", "empty numerator is 1"),
    # Exponents.
    ("(m/s)^(-1/3)", "rational exponent through parentheses"),
    ("1/s^0.5", "decimal exponent becomes ^(p/q)"),
    ("m^(4/2)", "rational exponent in lowest terms"),
    ("m^(-6/-4)", "signs of a rational exponent"),
    ("m^1.5", "decimal exponent"),
    ("m^1.0", "exponent 1 is omitted"),
    ("m**2", "** is ^"),
    ("mol^(1/2)*mol^(1/2)", "exponents sum within a side"),
    ("m^10/s^12", "multi-digit exponents"),
    ("m^0*s", "a zero exponent drops a table symbol"),
    # Symbols are kept as written: prefixes, aliases, unknown symbols.
    ("km/h", "prefixed symbols are not reduced"),
    ("µg/m³", "micro sign and superscript digits normalized"),
    ("μmol/mol", "Greek mu normalized"),
    ("°C/min", "degree Celsius normalized"),
    ("Ω*m", "ohm sign normalized"),
    ("s⁻¹", "superscript minus"),
    ("%/h", "percent"),
    ("%h", "percent is a token on its own"),
    ("short_ton/yr", "underscore in a symbol"),
    ("ppm", "mixing ratio kept"),
    ("foo/foo", "unknown symbols are spelled too"),
    # Left unchanged.
    ("g/hp-hr", "unparseable: - is not an operator"),
    ("1000/s", "unparseable: scaling factor"),
    ("1.0/s", "unparseable: 1.0 is a scaling factor"),
    (" ", "unparseable: whitespace only"),
    ("m^+2", "unparseable: + is not a token"),
    ("m^2^3", "unparseable: one exponent per term"),
    ("(m", "unparseable: unbalanced parenthesis"),
    ("1.5m", "a symbol containing . cannot be written"),
    ("bogus^0*s", "a dropped zero-exponent symbol must be a table key"),
]

ORDERING_CASES = ["m", "s*kg"]
VALUE = 1.5


def lean_string(s: str) -> str:
    out = []
    for c in s:
        if c in '"\\':
            out.append("\\" + c)
        elif 0x20 <= ord(c) < 0x7F:
            out.append(c)
        else:
            out.append(f"\\u{ord(c):04x}")
    return '"' + "".join(out) + '"'


def lean_canon(formal: Path, inputs: list[str]) -> list[str]:
    """`Esm.Units.canon` of each input, one JSON string per output line."""
    body = [
        "import Esm.Units.Canonical",
        "import Lean.Data.Json",
        "",
        "def inputs : List String := [",
        ",\n".join("  " + lean_string(s) for s in inputs),
        "]",
        "",
        "#eval inputs.forM fun s => IO.println (Lean.Json.compress (Lean.Json.str (Esm.Units.canon s)))",
    ]
    path = formal / ".lake" / "gen" / "CanonUnits.lean"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(body) + "\n", encoding="utf-8")
    proc = subprocess.run(
        ["lake", "env", "lean", str(path)], cwd=formal, capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise SystemExit(f"lake env lean failed:\n{proc.stdout}{proc.stderr}")
    lines = [ln for ln in proc.stdout.splitlines() if ln.startswith('"')]
    if len(lines) != len(inputs):
        raise SystemExit(f"expected {len(inputs)} outputs, got {len(lines)}:\n{proc.stdout}")
    return [json.loads(ln) for ln in lines]


def const(units: str) -> dict:
    return {"op": "const", "args": [], "value": VALUE, "units": units}


def canonical_bytes(obj) -> str:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def write(path: Path, doc: dict) -> None:
    path.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {path.relative_to(ROOT)}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--formal", type=Path, default=ROOT / "formal", help="a built copy of formal/")
    args = ap.parse_args()

    inputs = [u for u, _ in CASES]
    spelled = lean_canon(args.formal.resolve(), inputs + ORDERING_CASES)
    main_out, order_out = spelled[: len(inputs)], spelled[len(inputs) :]

    write(
        OUT_DIR / "unit_spelling.json",
        {
            "id": "unit_spelling",
            "description": (
                "A const node's units take the canonical unit spelling (esm-spec §4.8.2, "
                "discretization RFC §5.4.10): numerator sorted by symbol, at most one '/', a "
                "compound denominator parenthesized, no cancellation across the bar, the three "
                "dimensionless spellings as '1', and a string that does not parse left unchanged. "
                "Generated by scripts/gen-canonical-unit-spelling.py from the Lean definition "
                "Esm.Units.canon; `cases` lists each input and its spelling."
            ),
            "input": {"op": "max", "args": [const(u) for u in inputs]},
            "expected": canonical_bytes({"op": "max", "args": [const(u) for u in main_out]}),
            "cases": [
                {"units": u, "canonical": c, "note": note}
                for (u, note), c in zip(CASES, main_out)
            ],
            "tags": ["supported", "const", "units", "unit_spelling"],
        },
    )

    # §5.4.2 sorts non-leaf args by their canonical serialization, which must
    # already carry the respelled units.
    order_args = sorted((const(c) for c in order_out), key=canonical_bytes)
    write(
        OUT_DIR / "unit_spelling_ordering.json",
        {
            "id": "unit_spelling_ordering",
            "description": (
                "Units are respelled before the §5.4.2 ordering of a commutative op's args: "
                "'s*kg' becomes 'kg*s', which sorts before 'm' although 's*kg' sorts after it. "
                "Generated by scripts/gen-canonical-unit-spelling.py from the Lean definition "
                "Esm.Units.canon."
            ),
            "input": {"op": "*", "args": [const(u) for u in ORDERING_CASES]},
            "expected": canonical_bytes({"op": "*", "args": order_args}),
            "tags": ["supported", "const", "units", "unit_spelling", "ordering"],
        },
    )


if __name__ == "__main__":
    main()
