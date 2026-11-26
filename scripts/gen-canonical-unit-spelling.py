#!/usr/bin/env python3
"""Generate the canonical unit-spelling fixtures from the Lean model.

The canonical unit spelling (esm-spec §4.8.2) is defined by the Lean function
`Esm.Units.canon` (formal/Esm/Units/Canonical.lean). This script evaluates it
on every case below with `lake env lean`, so Lean is the oracle for the
fixtures every binding's canonicalizer must reproduce byte for byte:

* `unit_spelling.json`: one `const` node per case under an order-preserving
  `max`, so the canonical JSON lists the spellings in case order.
* `unit_spelling_ordering.json`: two `const` nodes under `*`, whose §5.4.2 order
  flips once their units are respelled; a binding that respells after sorting
  (or only when emitting) gets the order wrong.
* `tests/conformance/canonical_document/units.json`: a document whose `units`
  and `default_units` strings (variables, parameters, species, coordinates,
  const nodes, nested subsystems, template bodies) all take the canonical
  spelling under `canonicalize_document`, while look-alike keys inside
  free-form objects and name-keyed maps are left alone. The walk here mirrors
  the bindings' (`document_units_walk`); Lean spells every string. Its numbers
  are in canonical form in `expected` (an integral value in Int64 is an integer).
* `tests/conformance/canonical_document/ops_and_numbers.json`: the other rules of
  `canonicalize_document`. The deprecated `neg` and `pow` become unary `-` and
  `^` (and a `broadcast` of `neg` maps `-`), and every number, free-form objects
  included, takes its canonical form (CONFORMANCE §5.5.3.1). Its `expected` is
  what `esm-lean canon` writes for the input, keys back in input order, so the
  built `esm-lean` (formal/.lake/build/bin) must be current.

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
    ("m^0.00000000000000000000000000000000000000001", "exponents are exact at any precision"),
    ("m^(1234567890123456789012345678901234567890/2)", "integer exponents of any size"),
    ("m^0*s", "a zero exponent drops a table symbol"),
    ("%^0*s", "a zero exponent drops %, a table key"),
    ("%^0", "a zero exponent drops %, leaving 1"),
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


class Raw:
    """A JSON number token written exactly as given (Python would respell it)."""

    def __init__(self, text: str):
        self.text = text


def dumps(doc, indent=2) -> str:
    """JSON text with every `Raw` token spelled as written."""
    raws: list[str] = []

    def mark(v):
        if isinstance(v, Raw):
            raws.append(v.text)
            return f"@@raw{len(raws) - 1}@@"
        if isinstance(v, dict):
            return {k: mark(x) for k, x in v.items()}
        if isinstance(v, list):
            return [mark(x) for x in v]
        return v

    text = json.dumps(mark(doc), indent=indent, ensure_ascii=False)
    for i, raw in enumerate(raws):
        text = text.replace(f'"@@raw{i}@@"', raw)
    return text


def write(path: Path, doc: dict) -> None:
    path.write_text(dumps(doc) + "\n", encoding="utf-8")
    print(f"wrote {path.relative_to(ROOT)}")


def canonical_numbers(value):
    """Every number in canonical form (CONFORMANCE §5.5.3.1): an integral float in Int64
    is an integer, an integer outside it a float."""
    if isinstance(value, bool):
        return value
    if isinstance(value, float) and value.is_integer() and -(2**63) <= value < 2**63:
        return int(value)
    if isinstance(value, int) and not -(2**63) <= value < 2**63:
        return float(value)
    if isinstance(value, list):
        return [canonical_numbers(v) for v in value]
    if isinstance(value, dict):
        return {k: canonical_numbers(v) for k, v in value.items()}
    return value


# --- The document-level step (esm-spec §4.8.2, canonicalize_document) ---------

# Object properties whose value is a NAME-KEYED map (from esm-schema.json): a
# map's keys are names, never fields, so a variable named `units` is not a
# units string.
MAP_KEYS = frozenset(
    """
    bind bindings coordinates coords coupling_roles data_sources enums
    expression_template_imports expression_templates guesses index_set_rename
    index_sets initial_conditions map metaparameters models parameter_overrides
    parameters pinned_coords ranges reaction_systems rebind rename species
    subsystems translate url_substitutions variables where
""".split()
)
# Free-form objects (schema `additionalProperties: true`): not descended.
FREE_KEYS = frozenset({"attrs", "config", "metadata", "reader_options", "x_esd"})
UNIT_KEYS = ("units", "default_units")


def document_units_walk(value, spell, is_map=False):
    """Apply `spell` to every units string of a decoded document."""
    if isinstance(value, list):
        return [document_units_walk(v, spell) for v in value]
    if not isinstance(value, dict):
        return value
    if is_map:
        return {k: document_units_walk(v, spell) for k, v in value.items()}
    units = value.get("units")
    if value.get("op") == "const" and isinstance(units, str) and spell(units) == "1":
        # A dimensionless const drops its units: a scalar is the bare literal.
        literal = value.get("value")
        if isinstance(literal, (int, float)) and not isinstance(literal, bool):
            return literal
        value = {k: v for k, v in value.items() if k != "units"}
    out = {}
    for k, v in value.items():
        if k in UNIT_KEYS and isinstance(v, str):
            out[k] = spell(v)
        elif k in FREE_KEYS:
            out[k] = v
        else:
            out[k] = document_units_walk(v, spell, k in MAP_KEYS)
    return out


def units_document() -> dict:
    def const(value, units):
        return {"op": "const", "args": [], "value": value, "units": units}

    return {
        "esm": "2.1.0",
        "metadata": {
            "name": "CanonicalUnitsDocument",
            "description": "Every units string takes the canonical spelling.",
            "x_esd": {"units": "m h"},
        },
        "coordinates": {
            "lev": {"source": "lev", "standard_name": "air_pressure", "units": "kg m^-1 s^-2"},
            "lat": {"source": "lat", "standard_name": "latitude", "units": "degrees_north"},
        },
        "models": {
            "Atmos": {
                "variables": {
                    "T": {"type": "state", "units": "K", "default": 280.0},
                    "speed": {"type": "state", "units": "m h/(mi s)", "default": 1.0},
                    "R": {
                        "type": "parameter",
                        "units": "J/mol/K",
                        "default": 8.314,
                        "default_units": "J/(mol*K)",
                    },
                    "frac": {"type": "parameter", "units": "dimensionless", "default": 0.5},
                    "units": {"type": "parameter", "units": "", "default": 1.0},
                    "label": {"type": "parameter", "units": "g/hp-hr", "default": 1.0},
                },
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["T"], "wrt": "t"},
                        "rhs": {"op": "*", "args": [const(0.1, "s^-1"), "T"]},
                    },
                    {
                        "lhs": "frac",
                        "rhs": {
                            "op": "*",
                            "args": [
                                const(0.5, "1"),
                                {"op": "const", "args": [], "value": [1.0, 2.0], "units": ""},
                                # Other fields do not keep a dimensionless const an
                                # object: a scalar one is still the bare literal, an
                                # array one keeps them and loses only its units, and
                                # its free-form `attrs` stay untouched.
                                {
                                    "op": "const",
                                    "args": [],
                                    "value": 2,
                                    "units": "dimensionless",
                                    "id": "two",
                                },
                                {
                                    "op": "const",
                                    "args": [],
                                    "value": [3.0, 4.0],
                                    "units": "1",
                                    "id": "pair",
                                    "attrs": {"note": {"op": "const", "value": 1, "units": "1"}},
                                },
                            ],
                        },
                    },
                ],
                "subsystems": {
                    "Inner": {
                        "variables": {
                            "q": {"type": "state", "units": "kg/kg", "default": 0.01},
                            "flux": {"type": "parameter", "units": "kg m^-2 s^-1", "default": 0.0},
                        },
                        "equations": [
                            {
                                "lhs": {"op": "D", "args": ["q"], "wrt": "t"},
                                "rhs": {
                                    "op": "+",
                                    "args": [
                                        {"op": "*", "args": ["flux", const(1.0, "m^2/kg")]},
                                        const(0, "dimensionless"),
                                    ],
                                },
                            }
                        ],
                        "subsystems": {
                            "Deep": {
                                "variables": {
                                    "c": {"type": "state", "units": "molec cm^-3", "default": 1.0}
                                },
                                "equations": [
                                    {
                                        "lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                                        "rhs": {"op": "*", "args": [const(1.0, "1/s^0.5"), "c"]},
                                    }
                                ],
                            }
                        },
                    }
                },
            }
        },
        "reaction_systems": {
            "Chem": {
                "species": {
                    "O3": {"units": "mol/mol", "default": 4e-08},
                    "NO2": {"units": "ppb", "default": 1.0, "default_units": "ppm"},
                },
                "parameters": {
                    "k1": {"units": "cm^3 molec^-1 s^-1", "default": 1.8e-12},
                    "j": {"units": "mol/mol/s", "default": 0.01},
                },
                "reactions": [
                    {
                        "id": "R1",
                        "substrates": [{"species": "O3", "stoichiometry": 1}],
                        "products": [{"species": "NO2", "stoichiometry": 1}],
                        "rate": {"op": "*", "args": ["k1", const(2.5e19, "molec/cm^3")]},
                    }
                ],
                "subsystems": {
                    "Aerosol": {
                        "species": {"SO4": {"units": "µg/m³", "default": 1.0}},
                        "parameters": {"kd": {"units": "s⁻¹", "default": 0.001}},
                        "reactions": [],
                    }
                },
            }
        },
        "data_sources": {
            "met": {
                "kind": "grid",
                "url_template": "file:///met.nc",
                "metadata": {"units": "m s-1"},
                "reader_options": {"units": "W m^-2"},
            }
        },
    }


def write_document_fixture(formal: Path) -> None:
    doc = units_document()
    seen: list[str] = []
    document_units_walk(doc, lambda u: seen.append(u) or u)
    unique = sorted(set(seen))
    spelled = dict(zip(unique, lean_canon(formal, unique)))
    out_dir = ROOT / "tests" / "conformance" / "canonical_document"
    out_dir.mkdir(exist_ok=True)
    write(
        out_dir / "units.json",
        {
            "id": "units",
            "description": (
                "canonicalize_document respells every units and default_units string of a "
                "document (variables, parameters, species, coordinates, const nodes, nested "
                "subsystems) in the canonical unit spelling (esm-spec §4.8.2); a string that does "
                "not parse (`g/hp-hr`) is left unchanged, a const whose units spell `1` drops them "
                "(a scalar one becomes the bare literal even when it carries other fields such "
                "as an `id`) while a variable keeps units `1`, a "
                "variable NAMED `units` is not a units "
                "string, and free-form objects (`metadata`, `x_esd`, `reader_options`) are not "
                "touched. Generated by scripts/gen-canonical-unit-spelling.py from the Lean "
                "definition Esm.Units.canon."
            ),
            "input": doc,
            "expected": canonical_numbers(document_units_walk(doc, spelled.__getitem__)),
            "tags": ["units", "unit_spelling", "document"],
        },
    )
    write_ops_numbers_fixture(formal, out_dir)
    write(
        out_dir / "manifest.json",
        {
            "category": "canonical_document",
            "version": "1.0",
            "description": (
                "Document-level canonical form (esm-spec §4.8.2): each fixture's `expected` is "
                "the JSON document every binding's canonicalize_document(input) must equal, "
                "compared as JSON values."
            ),
            "fixtures": [
                {"id": "units", "path": "units.json"},
                {"id": "ops_and_numbers", "path": "ops_and_numbers.json"},
            ],
        },
    )


def ops_numbers_document() -> dict:
    def var(default, units="1"):
        return {"type": "parameter", "units": units, "default": default}

    return {
        "esm": "2.1.0",
        "metadata": {
            "name": "CanonicalOpsAndNumbers",
            "description": "Deprecated ops rewritten, faq defaults dropped, every number in canonical form.",
            # Free-form: its numbers are canonical too, its ops are not rewritten.
            "x_esd": {
                "scale": Raw("2.0"),
                "node": {"op": "neg", "args": ["x"]},
                "sum": {"op": "faq", "args": [], "expr": 1, "output_idx": [], "reduce": "+"},
            },
        },
        "models": {
            "M": {
                "variables": {
                    "x": {"type": "state", "units": "m", "default": Raw("2.0")},
                    # Not the shortest digits of its double: 1.4715177646857693.
                    "a": var(Raw("1.4715177646857694")),
                    # Rounds to the double 1.0, so it is the integer 1.
                    "b": var(Raw("1.0000000000000001")),
                    # A decimal token is a double: the nearest one to
                    # -19999999999999990 is -19999999999999992, an integer in Int64.
                    "c": var(Raw("-1.999999999999999e16")),
                    # An integer token in Int64 is that integer, past 2^53 too.
                    "d": var(Raw("-19999999999999990")),
                    "e": var(Raw("-0.0")),
                    # An integral double outside Int64 stays a float.
                    "f": var(Raw("1.0e19")),
                    "g": var(Raw("4.940656458412465e-324")),
                    "h": var(Raw("2.50e1")),
                    "values": var([Raw("1.0"), Raw("2.5")]),
                },
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                        "rhs": {
                            "op": "neg",
                            "args": [{"op": "pow", "args": ["x", Raw("2.0")]}],
                        },
                    },
                    {
                        "lhs": "a",
                        "rhs": {
                            "op": "+",
                            "args": [
                                # The wrong operand count: not rewritten.
                                {"op": "neg", "args": ["x", "b"]},
                                {"op": "pow", "args": ["x", "b", "c"]},
                                {"op": "broadcast", "fn": "neg", "args": ["values"]},
                            ],
                        },
                    },
                    {
                        "lhs": "b",
                        "rhs": {
                            "op": "+",
                            "args": [
                                # The default reduce and semiring are dropped,
                                # with or without `args`.
                                faq(reduce="+"),
                                faq(reduce="+", semiring="sum_product"),
                                faq(semiring="sum_product"),
                                faq(args=None, reduce="+"),
                                # Any other reduce, or any other semiring, keeps
                                # both fields: the semiring decides there.
                                faq(reduce="max"),
                                faq(reduce="+", semiring="max_product"),
                                faq(reduce="max", semiring="sum_product"),
                            ],
                        },
                    },
                ],
            }
        },
    }


def faq(args=("values",), **fields) -> dict:
    """A sum of `values` over `i`, with the given `reduce` / `semiring` fields."""
    node = {"op": "faq"}
    if args is not None:
        node["args"] = list(args)
    node |= {
        "expr": {"op": "index", "args": ["values", "i"]},
        "output_idx": [],
        "ranges": {"i": [1, 2]},
    }
    return node | fields


def esm_lean_canon(formal: Path, text: str):
    """What `esm-lean canon` writes for a document's JSON text."""
    binary = formal / ".lake" / "build" / "bin" / "esm-lean"
    path = formal / ".lake" / "gen" / "ops_and_numbers.esm"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    proc = subprocess.run([str(binary), "canon", str(path)], capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"esm-lean canon failed:\n{proc.stdout}{proc.stderr}")
    # Floats keep the canonical spelling esm-lean writes (`1.0e19`, not `1e+19`).
    return json.loads(proc.stdout, parse_float=Raw)


def in_order_of(value, like):
    """`value` with each object's keys in the order `like` (the input) has them."""
    if isinstance(value, dict) and isinstance(like, dict):
        keys = [k for k in like if k in value] + [k for k in value if k not in like]
        return {k: in_order_of(value[k], like.get(k)) for k in keys}
    if isinstance(value, list) and isinstance(like, list) and len(value) == len(like):
        return [in_order_of(v, w) for v, w in zip(value, like)]
    return value


def write_ops_numbers_fixture(formal: Path, out_dir: Path) -> None:
    doc = ops_numbers_document()
    text = dumps(doc)
    expected = in_order_of(esm_lean_canon(formal, text), json.loads(text))
    write(
        out_dir / "ops_and_numbers.json",
        {
            "id": "ops_and_numbers",
            "description": (
                "canonicalize_document rewrites the deprecated ops (esm-spec §4.2): neg with one "
                "operand is unary -, pow with two is ^, a broadcast of neg with one operand maps "
                "-, and a use with the wrong operand count, or inside a free-form object, is "
                'left as written. A faq drops its default reduce "+" and semiring '
                '"sum_product" (esm-spec §4.8.2), and keeps both when either is anything '
                "else. Every number, free-form objects included, takes its canonical "
                "form (CONFORMANCE §5.5.3.1): a decimal token is rounded to binary64, an integral "
                "double in Int64 is an integer (2.0 is 2, 1.0000000000000001 is 1, "
                "-1.999999999999999e16 is -19999999999999992, -0.0 is 0), an integer token in "
                "Int64 is kept exactly (-19999999999999990), and any other double is a float "
                "with its shortest round-trip digits (1.4715177646857694 is 1.4715177646857693, "
                "4.940656458412465e-324 is 5.0e-324, 1.0e19 stays a float). Compare numbers by "
                "type and value: 2 and 2.0 differ. A binding whose JSON reader holds every "
                "number as a double cannot hold -19999999999999990 and reads it as "
                "-19999999999999992 on both sides. Generated by scripts/gen-canonical-unit-"
                "spelling.py; expected is what esm-lean canon writes."
            ),
            "input": json.loads(text, parse_float=Raw, parse_int=Raw),
            "expected": expected,
            "tags": ["deprecated_op", "faq_defaults", "canonical_number", "document"],
        },
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--formal", type=Path, default=ROOT / "formal", help="a built copy of formal/")
    args = ap.parse_args()

    inputs = [u for u, _ in CASES]
    spelled = lean_canon(args.formal.resolve(), inputs + ORDERING_CASES)
    main_out, order_out = spelled[: len(inputs)], spelled[len(inputs) :]
    write_document_fixture(args.formal.resolve())

    write(
        OUT_DIR / "unit_spelling.json",
        {
            "id": "unit_spelling",
            "description": (
                "A const node's units take the canonical unit spelling (esm-spec §4.8.2, "
                "discretization RFC §5.4.10): numerator sorted by symbol, at most one '/', a "
                "compound denominator parenthesized, no cancellation across the bar, the three "
                "dimensionless spellings as '1' (and a const whose units spell '1' is the bare "
                "literal), and a string that does not parse left unchanged. "
                "Generated by scripts/gen-canonical-unit-spelling.py from the Lean definition "
                "Esm.Units.canon; `cases` lists each input and its spelling."
            ),
            "input": {"op": "max", "args": [const(u) for u in inputs]},
            # A const whose units spell `1` is the bare literal (user ruling
            # 2026-11-14).
            "expected": canonical_bytes(
                {"op": "max", "args": [VALUE if c == "1" else const(c) for c in main_out]}
            ),
            "cases": [
                {"units": u, "canonical": c, "note": note} for (u, note), c in zip(CASES, main_out)
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

    # A const whose units spell `1` drops them: a scalar is the bare literal,
    # so the rest of §5.4 applies to it (a zero is eliminated from a sum, a 1
    # from a product); an array is a const without units. The expected bytes
    # are hand-written from those rules; Lean decides only which spellings
    # are `1` (all three of them are, per CanonicalExamples.lean).
    dimensionless = ["dimensionless", "1", "", "dimensionless", "dimensionless"]
    assert lean_canon(args.formal.resolve(), sorted(set(dimensionless))) == ["1", "1", "1"]
    write(
        OUT_DIR / "unit_spelling_dimensionless.json",
        {
            "id": "unit_spelling_dimensionless",
            "description": (
                "A const node whose units spell '1' ('', '1' or 'dimensionless') drops them "
                "(esm-spec §4.8.2, discretization RFC §5.4.10, user ruling 2026-11-14): a scalar "
                "becomes the bare literal and is then canonicalized like one, so x + "
                "const(0, 'dimensionless') is x and const(1, 'dimensionless') * x is x; an array "
                "becomes a const without units."
            ),
            "input": {
                "op": "max",
                "args": [
                    {
                        "op": "+",
                        "args": [
                            "x",
                            {"op": "const", "args": [], "value": 0, "units": "dimensionless"},
                        ],
                    },
                    {
                        "op": "*",
                        "args": [{"op": "const", "args": [], "value": 2.5, "units": "1"}, "y"],
                    },
                    {"op": "const", "args": [], "value": 1.5, "units": ""},
                    {
                        "op": "*",
                        "args": [
                            {"op": "const", "args": [], "value": 1, "units": "dimensionless"},
                            "x",
                        ],
                    },
                    {"op": "const", "args": [], "value": 0, "units": "dimensionless"},
                    {"op": "const", "args": [], "value": [1.5, 2.5], "units": "dimensionless"},
                ],
            },
            "expected": (
                '{"args":["x",{"args":[2.5,"y"],"op":"*"},1.5,"x",0,'
                '{"args":[],"op":"const","value":[1.5,2.5]}],"op":"max"}'
            ),
            "tags": ["supported", "const", "units", "unit_spelling", "zero_elim", "integer"],
        },
    )


if __name__ == "__main__":
    main()
