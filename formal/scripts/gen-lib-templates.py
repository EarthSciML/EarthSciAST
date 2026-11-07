#!/usr/bin/env python3
"""Generate the Lean ASTs of a standard-library template file.

    python3 formal/scripts/gen-lib-templates.py            # write the Lean file
    python3 formal/scripts/gen-lib-templates.py --check    # fail if it is stale

Reads the `expression_templates` of each library file in `TARGETS`
(`lib/interp.esm`, `lib/calendar.esm`, …) and writes its Lean file
(`formal/Esm/Lib/Interp.lean`, …), one `Esm.Expr.Template` per template, its body
transcribed node for node into `Esm.Expr.Ast` (formal/Esm/Expr/Core.lean). The
theorems in `formal/Esm/Closed/Interp/TemplateAst.lean` (and the matching file
of each library) are about these
definitions, so `--check` (run by the formal CI workflow) keeps the proofs tied
to the committed library file: an edit to `lib/interp.esm` that is not
regenerated fails the check, and a regenerated file the proofs no longer fit
fails the Lean build.

A node outside what `Esm.Expr.Ast` carries (an op field other than `op`,
`args`, and a `faq`'s `output_idx`/`reduce`/`ranges`/`expr`, or a `const`'s
`value` and `units`; `units` is dropped, as evaluation does not read it) is an
error here rather than a silent drop, as is a missing field
the transcription needs and a literal `-0.0`: `Ast.num` is an integer mantissa
and a decimal exponent, which has no negative zero.
"""

import argparse
import decimal
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# (source library file, Lean output file, Lean namespace)
TARGETS = [
    ("lib/interp.esm", "formal/Esm/Lib/Interp.lean", "Esm.Lib.Interp"),
    ("lib/calendar.esm", "formal/Esm/Lib/Calendar.lean", "Esm.Lib.Calendar"),
    ("lib/relational.esm", "formal/Esm/Lib/Relational.lean", "Esm.Lib.Relational"),
    ("lib/geometry.esm", "formal/Esm/Lib/Geometry.lean", "Esm.Lib.Geometry"),
]


class Unsupported(Exception):
    pass


def lean_str(s):
    if not isinstance(s, str):
        raise Unsupported(f"expected a string, got {s!r}")
    return json.dumps(s)


def lit(v, path):
    if isinstance(v, bool):
        raise Unsupported(f"{path}: boolean literal {v!r}")
    d = decimal.Decimal(v) if isinstance(v, int) else v
    sign, digits, exp = d.as_tuple()
    if not isinstance(exp, int):
        raise Unsupported(f"{path}: non-finite literal {v!r}")
    m = int("".join(map(str, digits)) or "0")
    if sign and m == 0:
        raise Unsupported(f"{path}: literal {v!r} is a negative zero, which Ast.num cannot carry")
    if exp >= 0:
        m *= 10 ** exp
        e = 0
    else:
        e = -exp
    if sign:
        m = -m
    return f"(Ast.num ({m}) {e})"


def const_value(v, path):
    if isinstance(v, list):
        return "(Const.arr [" + ", ".join(
            const_value(x, f"{path}[{i}]") for i, x in enumerate(v)) + "])"
    if isinstance(v, (int, decimal.Decimal)) and not isinstance(v, bool):
        inner = lit(v, path)[len("(Ast.num "):-1]
        return f"(Const.leaf {inner})"
    raise Unsupported(f"{path}: const value {v!r}")


def ast(e, indent, path):
    pad = "  " * indent
    if isinstance(e, (int, decimal.Decimal)) and not isinstance(e, bool):
        return pad + lit(e, path)
    if isinstance(e, str):
        return pad + f"(Ast.var {lean_str(e)})"
    if not isinstance(e, dict) or "op" not in e:
        raise Unsupported(f"{path}: not an Expression: {e!r}")
    op = e["op"]
    if op == "const":
        # `units` (§4.8.5) is a declaration for the units checker; the value is
        # all evaluation reads, so the transcription drops it.
        extra = set(e) - {"op", "value", "args", "units"}
        if extra or e.get("args", []) != []:
            raise Unsupported(f"{path}: const node fields {sorted(extra)}")
        if "value" not in e:
            raise Unsupported(f"{path}: const node has no value")
        return pad + f"(Ast.const {const_value(e['value'], path + '.value')})"
    if op == "faq":
        extra = set(e) - {"op", "args", "output_idx", "reduce", "ranges", "expr"}
        if extra:
            raise Unsupported(f"{path}: faq fields {sorted(extra)}")
        if "expr" not in e:
            raise Unsupported(f"{path}: faq has no expr")
        out = e.get("output_idx", [])
        if any(not isinstance(o, str) for o in out):
            raise Unsupported(f"{path}: faq output_idx entry that is not a symbol")
        ranges = "Ranges.nil"
        for k, r in reversed(list(e.get("ranges", {}).items())):
            if not isinstance(r, list):
                raise Unsupported(f"{path}: faq range {k!r} is not a tuple")
            ranges = (f"(Ranges.cons {lean_str(k)} ["
                      + ", ".join(ast(x, 0, f"{path}.ranges.{k}[{i}]") for i, x in enumerate(r))
                      + f"] {ranges})")
        lines = [
            pad + "(Ast.faq [" + ", ".join(lean_str(o) for o in out) + "] "
            + lean_str(e.get("reduce", "+")) + " " + ranges,
            ast(e["expr"], indent + 1, path + ".expr"),
            pad + "  [" + ", ".join(ast(a, 0, f"{path}.args[{i}]")
                                    for i, a in enumerate(e.get("args", []))) + "])",
        ]
        return "\n".join(lines)
    extra = set(e) - {"op", "args"}
    if extra:
        raise Unsupported(f"{path}: {op} node fields {sorted(extra)}")
    args = e.get("args", [])
    if not args:
        return pad + f"(Ast.node {lean_str(op)} [])"
    inner = ",\n".join(ast(a, indent + 1, f"{path}.args[{i}]") for i, a in enumerate(args))
    return pad + f"(Ast.node {lean_str(op)} [\n{inner}])"


def generate(src, ns):
    doc = json.loads((ROOT / src).read_text(encoding="utf-8"), parse_float=decimal.Decimal)
    out = [
        f"-- Generated by formal/scripts/gen-lib-templates.py from {src}. Do not edit:",
        "-- regenerate, and `--check` in the formal CI workflow keeps this file current.",
        "import Esm.Expr.Template",
        "",
        "/-! The expression templates of `" + src + "` as `Esm.Expr.Template` values",
        "(esm-spec §9.6.1, §9.7.1), transcribed node for node. -/",
        "",
        f"namespace {ns}",
        "",
        "open Esm.Expr",
        "",
    ]
    for name, t in doc.get("expression_templates", {}).items():
        where = f"expression_templates.{name}"
        if not isinstance(t, dict):
            raise Unsupported(f"{where}: not a template object")
        if "match" in t or "where" in t:
            raise Unsupported(f"{where}: has a match rule; only match-less ones are modelled")
        for field in ("params", "body"):
            if field not in t:
                raise Unsupported(f"{where}: no {field}")
        out.append(f"/-- `{name}` (params " + ", ".join(f"`{p}`" for p in t["params"]) + "). -/")
        out.append(f"def {name} : Template where")
        out.append("  params := [" + ", ".join(lean_str(p) for p in t["params"]) + "]")
        out.append("  body :=")
        out.append(ast(t["body"], 2, where + ".body"))
        out.append("")
    out.append(f"end {ns}")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--check", action="store_true", help="fail if a generated file is stale")
    args = ap.parse_args()
    ok = True
    for src, dst, ns in TARGETS:
        try:
            text = generate(src, ns)
        except Unsupported as exc:
            print(f"{src}: {exc}", file=sys.stderr)
            ok = False
            continue
        path = ROOT / dst
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                print(f"{dst} is stale: run python3 formal/scripts/gen-lib-templates.py", file=sys.stderr)
                ok = False
            else:
                print(f"{dst}: current")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            print(f"wrote {dst}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
