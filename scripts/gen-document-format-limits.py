#!/usr/bin/env python3
"""Generate tests/conformance/document_format/limits.json: the reader limits.

The Lean model has no limits: its numbers are exact decimals and its readers recurse
as deep as the input goes. A binding reads into binary64 numbers on a finite stack,
so every binding refuses, with `parse_error`, the same texts:

* a number beyond the binary64 range (`1.0e400`, `1.0e4294967296`); a number below
  the smallest subnormal reads as 0, as every binding's JSON reader rounds it;
* a text that holds more than 128 reader constructs open at once (brackets,
  fractions, signs, operator chains, flow collections, YAML levels), or that reads
  as a value nested more than 127 arrays and objects deep;

and reports `removed_op` only for a removed operator the math reader meets, never
for one named in prose or code.

The expected outcomes are the Rust binding's (its driver,
`earthsci-document-format-adapter-rust`); the other four bindings must agree. A case
gives its input as a recipe, so the deep inputs are built at run time rather than
stored:

    input = heads[surface] + prefix + open * n + middle + close * n + suffix

or, for `yaml_levels`, a metaparameters block nested `n` list levels deep (see
`yaml_levels` below). Usage (from the repository root):

    python3 scripts/gen-document-format-limits.py [--check] [--rust PATH]
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tests" / "conformance" / "document_format" / "limits.json"
HEADS = {
    "markdown": '---\nesm: "3.0.0"\nname: "fixture"\n---\n\n::model[M]\n\n'
    ":param[$k$]{}\n\n:var[$y$]{}\n\n",
    "typst": '#import "@preview/esm:0.1.0": *\n'
    '#show: esm-document.with(esm: "3.0.0", name: "fixture")\n\n'
    '#model("M")\n\n#param($k$)\n\n#var($y$)\n\n',
}
DEEP = 50_000


def build(case: dict) -> str:
    """The input text of a case (the same rule every binding's test applies)."""
    r = case["input"]
    head = HEADS[case["surface"]]
    if r.get("yaml_levels"):
        n = r["yaml_levels"]
        lines = "".join(" " * (2 * i) + "-\n" for i in range(1, n))
        return head + "```esm:metaparameters\nx:\n" + lines + "```\n"
    n = r.get("n", 0)
    return (
        head
        + r.get("prefix", "")
        + r.get("open", "") * n
        + r.get("middle", "")
        + r.get("close", "") * n
        + r.get("suffix", "")
    )


def md_math(open_, close, n, middle="k"):
    return {
        "prefix": "$$\ny = ",
        "open": open_,
        "n": n,
        "middle": middle,
        "close": close,
        "suffix": "\n$$\n",
    }


def typ_math(open_, close, n, middle="k"):
    return {
        "prefix": "$ y = ",
        "open": open_,
        "n": n,
        "middle": middle,
        "close": close,
        "suffix": " $\n",
    }


def flow(n):
    return {
        "prefix": ":var[$z$]{default='",
        "open": "[",
        "n": n,
        "middle": "1",
        "close": "]",
        "suffix": "'}\n",
    }


# (id stem, surface, recipe for n, deepest n the Rust reader accepts)
NESTS = [
    ("parens", "markdown", lambda n: md_math("(", ")", n), 63),
    ("parens", "typst", lambda n: typ_math("(", ")", n), 63),
    ("fractions", "markdown", lambda n: md_math("\\frac{", "}{k}", n), 61),
    ("left_right", "markdown", lambda n: md_math("\\left(", "\\right)", n), 63),
    ("signs", "markdown", lambda n: md_math("-", "", n), 61),
    ("signs", "typst", lambda n: typ_math("-", "", n), 61),
    ("chain", "markdown", lambda n: md_math("", " - k", n), 61),
    (
        "derivatives",
        "markdown",
        lambda n: md_math("\\frac{\\mathrm{d}}{\\mathrm{d} t} \\left(", "\\right)", n),
        61,
    ),
    ("derivatives", "typst", lambda n: typ_math("(dif)/(dif t) (", ")", n), 61),
    ("flow_collection", "markdown", flow, 122),
    ("yaml_block", "markdown", lambda n: {"yaml_levels": n}, 123),
]


def cases() -> list[dict]:
    out = []
    for stem, surface, recipe, deepest in NESTS:
        ext = "md" if surface == "markdown" else "typ"
        for n, what in ((deepest, "the deepest nesting read"), (deepest + 1, "one level past it")):
            out.append(
                {
                    "id": f"limit_{stem}_{ext}_{n}",
                    "surface": surface,
                    "input": recipe(n),
                    "description": f"{stem.replace('_', ' ')}, {what}",
                }
            )
        deep = 2000 if stem == "yaml_block" else DEEP
        out.append(
            {
                "id": f"limit_{stem}_{ext}_deep",
                "surface": surface,
                "input": recipe(deep),
                "description": f"{stem.replace('_', ' ')}, {deep} levels: refused without exhausting the stack",
            }
        )
    for surface, mk in (("markdown", md_math), ("typst", typ_math)):
        ext = "md" if surface == "markdown" else "typ"
        out.append(
            {
                "id": f"number_overflow_{ext}",
                "surface": surface,
                "input": mk("", "", 0, "1.0e400 k"),
                "description": "a number beyond the binary64 range is refused",
            }
        )
    out.append(
        {
            "id": "number_exponent_wrap_md",
            "surface": "markdown",
            "input": md_math("", "", 0, "1.0e4294967296 k"),
            "description": "an exponent past 2^32 is not wrapped: still beyond binary64",
        }
    )
    out.append(
        {
            "id": "number_underflow_md",
            "surface": "markdown",
            "input": md_math("", "", 0, "1.0e-400 k"),
            "description": "a number below the smallest subnormal reads as 0",
        }
    )
    out.append(
        {
            "id": "removed_op_math_md",
            "surface": "markdown",
            "input": md_math("", "", 0, "\\operatorname{arrayop}(k)"),
            "description": "a removed operator in math",
        }
    )
    out.append(
        {
            "id": "removed_op_math_typ",
            "surface": "typst",
            "input": typ_math("", "", 0, 'op("fn")(k)'),
            "description": "a removed operator in math",
        }
    )
    for i, prose in enumerate(
        [
            "The old `\\operatorname{arrayop}` is gone.\n\n",
            "```\n\\esm{arrayop}{}{k}\n```\n\n",
            "Write \\operatorname{fn} no more.\n\n",
        ]
    ):
        r = md_math("", "", 0, "k +")
        r["prefix"] = prose + r["prefix"]
        out.append(
            {
                "id": f"removed_op_prose_md_{i}",
                "surface": "markdown",
                "input": r,
                "description": "a removed operator named in prose or code does not hide the real error",
            }
        )
    for i, prose in enumerate(['Call stop("fn") here.\n\n', 'No more op("rank").\n\n']):
        r = typ_math("", "", 0, "k +")
        r["prefix"] = prose + r["prefix"]
        out.append(
            {
                "id": f"removed_op_prose_typ_{i}",
                "surface": "typst",
                "input": r,
                "description": "a removed operator named in prose is not math",
            }
        )
    return out


def run_rust(binary: str, cs: list[dict]) -> list[dict]:
    with tempfile.TemporaryDirectory(dir=os.environ.get("ESM_LIMITS_SCRATCH")) as tmp:
        tmp = Path(tmp)
        items = []
        for c in cs:
            p = tmp / f"{c['id']}.txt"
            p.write_text(build(c), encoding="utf-8")
            items.append({"id": c["id"], "path": str(p), "format": c["surface"]})
        (tmp / "m.json").write_text(json.dumps(items), encoding="utf-8")
        (tmp / "out").mkdir()
        subprocess.run([binary, "parse", str(tmp / "m.json"), str(tmp / "out")], check=True)
        for c in cs:
            j, e = tmp / "out" / f"{c['id']}.json", tmp / "out" / f"{c['id']}.error"
            if j.is_file():
                # As text: the deepest expected documents are within the 127 levels a
                # reader takes, but not once nested inside this file.
                c["esm_json"] = json.dumps(
                    json.loads(j.read_text(encoding="utf-8")),
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                )
            else:
                c["error"] = e.read_text(encoding="utf-8").split(":", 1)[0]
    return cs


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--check", action="store_true", help="fail if the committed file differs")
    ap.add_argument(
        "--rust",
        default=os.environ.get("ESM_GATE_RUST"),
        help="the Rust driver (default: $ESM_GATE_RUST)",
    )
    args = ap.parse_args()
    if not args.rust:
        sys.exit(
            "pass --rust (cargo build --features conformance-adapters "
            "--bin earthsci-document-format-adapter-rust)"
        )
    doc = {
        "$comment": "Generated by scripts/gen-document-format-limits.py; do not edit. "
        "Contract: README.md in this directory, section Limits.",
        "oracle": "the Rust binding (earthsci-document-format-adapter-rust); the Lean model has no limits",
        "area": "limits",
        "heads": HEADS,
        "cases": run_rust(args.rust, cases()),
    }
    # One case per line: a deep expected document pretty-printed is mostly indentation.
    head = {k: v for k, v in doc.items() if k != "cases"}
    text = json.dumps(head, indent=2, ensure_ascii=False)[:-2] + ',\n  "cases": [\n'
    text += ",\n".join(
        "    " + json.dumps(c, ensure_ascii=False, separators=(",", ":")) for c in doc["cases"]
    )
    text += "\n  ]\n}\n"
    if args.check:
        if OUT.read_text(encoding="utf-8") != text:
            sys.exit(
                f"{OUT.relative_to(ROOT)} is stale: rerun scripts/gen-document-format-limits.py"
            )
        print("limits.json is current")
        return
    OUT.write_text(text, encoding="utf-8")
    kinds = {}
    for c in doc["cases"]:
        k = c.get("error", "reads")
        kinds[k] = kinds.get(k, 0) + 1
    print(f"wrote {OUT.relative_to(ROOT)}: {len(doc['cases'])} cases {kinds}")


if __name__ == "__main__":
    main()
