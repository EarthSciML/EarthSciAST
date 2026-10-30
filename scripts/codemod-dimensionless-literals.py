#!/usr/bin/env python3
"""Stage-2 codemod for "bare literals become dimensionless" (esm-spec §4.8.6).

At the warning stage every binding reports `units_dimensionless_literal_mismatch`
at a check site that the current neutral-literal rule passes but that fails once
every nonzero bare literal is read as dimensionless at scale 1. The repair is to
write the unit a literal carries: `T - 273.15` becomes
`T - const(273.15, units "K")` (esm-spec §4.8.5). This tool proposes that repair
for every warning site in a file, and proves it before writing anything.

How a rewrite is chosen
-----------------------
The Python binding is the engine. For a file it

1. asks the binding which sites warn;
2. reloads the document with every eligible nonzero literal of those sites
   replaced by a MARKER `const` (a template body a site applies is included,
   so a literal bound into a template is reached through its expansion);
3. for each site, types it with a subclass of the binding's `UnitValidator`
   in which chosen markers carry an UNKNOWN unit `X_i` and every other marker
   is dimensionless (the §4.8.6 rule). Wherever the binding would demand that
   two units agree, or that an argument be a pure number, the subclass records
   a linear equation in log-unit space (`Σ k_i·X_i = known`, over the eight
   axes, the prime factors of the exact scale and π) instead of comparing;
4. searches the literal subsets by increasing size for the SMALLEST one whose
   system is consistent with a unique solution in which every chosen literal
   carries a unit. A unique minimal subset is the proposal. Several minimal
   subsets ("either literal could carry the unit") are AMBIGUOUS and no rewrite
   is proposed;
5. spells each solved unit in the simplest §4.8.2 string built from the units
   declared at the site plus the SI base symbols (fewest factors, smallest
   exponents), checked by parsing it back to the exact dimension and scale.

Every proposal for a file is then verified on the rewritten document by the
binding itself: validity and the set of structural errors are unchanged, every
rewritten site is now warning-free and no other site starts warning, the
JSON of the rewritten text equals the JSON transform (literal -> const of the
SAME value), and, where the binding's scalar evaluator can run the site, the
rewritten expressions evaluate to the same numbers. A site whose proposal fails
verification is reported unresolved and its literals are left alone.

Classes
-------
* mechanical  — a conversion factor (dimensionless dimension at a non-unit
  scale, e.g. `Pa/atm`), an offset, threshold or bound in an agreement position
  (`T - 273.15 K`, `x > 0.01 m`), a literal that is the whole side of the
  equation, or a reference constant whose unit is exactly one declared at the
  site (`exp(-1370 K / T)`, `T / 300 K`, `k = 1e-3 [1/s]` with `k` in `1/s`).
* suspicious  — anything else: a coefficient whose unit is declared nowhere at
  the site (`H [m/s] = 1.4 * phi [m]` needs `1.4 [1/s]`), a fractional or
  large exponent, or an axis no declared unit at the site has. These may be
  model bugs. They ARE proposed (the rewrite preserves every value and makes the
  site pass), but listed prominently for review.
* unresolved  — no consistent minimal subset, an ambiguous one, a unit that
  cannot be spelled, two sites demanding different units of one template
  literal, a site inherited from a mounted file, or a failed verification.

Version
-------
A unit-bearing `const` needs esm >= 1.2.0 (§4.8.5 item 6). A file declaring an
older version is REPORTED and left alone unless --bump-version is given, in
which case its `esm` is raised to 1.2.0 in the same edit and the bump is
reported.

Formatting
----------
Edits are TEXT edits at the literal's own span, so the rest of the file keeps
its formatting: a bare number `273.15` becomes
`{"op": "const", "args": [], "value": 273.15, "units": "K"}` (the number's own
text is kept, so its value is bit-identical) and a unit-less `const` gains
`, "units": "K"` after its value.

Usage (run with Python >= 3.10 and pint, e.g. the binding's environment;
use `python -B` so no .pyc lands in a repository)
-----
    codemod-dimensionless-literals.py --check  [--bump-version] PATH...
    codemod-dimensionless-literals.py --write  [--bump-version] PATH...
    codemod-dimensionless-literals.py --patch-dir DIR [--bump-version] PATH...

PATH is an .esm file or a directory; a directory inside a git work tree is
expanded to its TRACKED .esm files. `--skip PREFIX` (repeatable) drops paths
under PREFIX relative to the root given. `--json FILE` writes the full
per-file report. `--summary FILE` writes a Markdown summary.
"""

from __future__ import annotations

import argparse
import copy
import difflib
import itertools
import json
import math
import os
import random
import re
import subprocess
import sys
import time
import warnings
from fractions import Fraction
from pathlib import Path

sys.dont_write_bytecode = True
_HERE = Path(__file__).resolve().parent
_DEFAULT_ENGINE = _HERE.parent / "pkg" / "earthsci-ast-py" / "src"

MIN_CONST_UNITS_VERSION = (1, 2, 0)
WARNING_CODE = "units_dimensionless_literal_mismatch"
MARK = "__esm_codemod_x"  # fake axis / tag inside the symbolic validator
# A marker const in the probe document: a unit string no real document uses
# (the loader validates unit strings) and a value encoding the marker id.
MARK_UNITS = "cd^7"
MARK_BASE = 9_000_000_000

# Ops through which a literal's unit is TYPED (esm-spec §4.8.3). Literals
# anywhere else (subscripts, exponents, function arguments, ranges, shapes) are
# read by value or not typed at all, and are never candidates.
_TYPED_ALL_ARGS = frozenset(
    {
        "+",
        "-",
        "*",
        "/",
        "min",
        "max",
        "ifelse",
        "exp",
        "log",
        "ln",
        "log10",
        "sinh",
        "cosh",
        "tanh",
        "asinh",
        "acosh",
        "atanh",
        "sin",
        "cos",
        "tan",
        "asin",
        "acos",
        "atan",
        "atan2",
        "sqrt",
        "abs",
        "floor",
        "ceil",
        "ic",
        "Pre",
        "D",
        ">",
        "<",
        ">=",
        "<=",
        "==",
        "!=",
        "and",
        "or",
        "not",
        "concat",
    }
)
_AGREEMENT_OPS = frozenset(
    {"+", "-", "min", "max", ">", "<", ">=", "<=", "==", "!=", "concat", "atan2"}
)


# ---------------------------------------------------------------------------
# JSON text with spans
# ---------------------------------------------------------------------------

_WS = re.compile(r"[ \t\n\r]*")
_NUM = re.compile(r"-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?")
_STR = re.compile(r'"(?:[^"\\]|\\.)*"', re.S)


class Spanned:
    """A JSON value with the [start, end) offsets of its text."""

    __slots__ = ("end", "start", "value")

    def __init__(self, value, start, end):
        self.value, self.start, self.end = value, start, end


def parse_spans(text: str):
    """Parse JSON text into nested Spanned (dict -> {key: Spanned}, list -> [Spanned])."""

    def ws(i):
        return _WS.match(text, i).end()

    def val(i):
        i = ws(i)
        c = text[i]
        if c == "{":
            start, out = i, {}
            i = ws(i + 1)
            if text[i] == "}":
                return Spanned(out, start, i + 1)
            while True:
                m = _STR.match(text, i)
                key = json.loads(m.group(0))
                i = ws(m.end())
                assert text[i] == ":"
                item = val(i + 1)
                out[key] = item
                i = ws(item.end)
                if text[i] == ",":
                    i = ws(i + 1)
                    continue
                assert text[i] == "}"
                return Spanned(out, start, i + 1)
        if c == "[":
            start, out = i, []
            i = ws(i + 1)
            if text[i] == "]":
                return Spanned(out, start, i + 1)
            while True:
                item = val(i)
                out.append(item)
                i = ws(item.end)
                if text[i] == ",":
                    i += 1
                    continue
                assert text[i] == "]"
                return Spanned(out, start, i + 1)
        if c == '"':
            m = _STR.match(text, i)
            return Spanned(json.loads(m.group(0)), i, m.end())
        m = _NUM.match(text, i)
        if m and m.end() > i:
            return Spanned(json.loads(m.group(0)), i, m.end())
        for word, v in (("true", True), ("false", False), ("null", None)):
            if text.startswith(word, i):
                return Spanned(v, i, i + len(word))
        raise ValueError(f"bad JSON at offset {i}")

    return val(0)


def span_at(root: Spanned, path):
    node = root
    for k in path:
        node = node.value[k]
    return node


def get_at(doc, path):
    for k in path:
        doc = doc[k]
    return doc


def set_at(doc, path, value):
    get_at(doc, path[:-1])[path[-1]] = value


def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def version_tuple(v):
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", str(v or ""))
    return tuple(int(x) for x in m.groups()) if m else None


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------


def import_engine(src: Path):
    sys.path.insert(0, str(src))
    global EA, U, ExprNode, ExactScale, Fraction_
    import earthsci_ast as EA  # noqa: N813
    from earthsci_ast import units as U
    from earthsci_ast.esm_types import ExprNode
    from earthsci_ast.units import ExactScale

    return EA


def engine_report(text: str, base: str):
    """(is_valid, structural error multiset, dimless-warning pointers, other unit warnings)."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        r = EA.validate_text(text, base_path=base)
    errs = sorted((e.code, e.path) for e in r.structural_errors)
    dim = sorted(w.path for w in r.unit_warnings if w.code == WARNING_CODE)
    other = sorted((w.code, w.path) for w in r.unit_warnings if w.code != WARNING_CODE)
    return r.is_valid, errs, dim, other


def engine_messages(text: str, base: str) -> dict:
    """{site pointer: warning message} for the dimensionless-literal warnings."""
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        r = EA.validate_text(text, base_path=base)
    return {w.path: w.message for w in r.unit_warnings if w.code == WARNING_CODE}


# ---------------------------------------------------------------------------
# Declaration fixes (angle units)
# ---------------------------------------------------------------------------


def _angle_power(unit_text):
    try:
        vec = unit_vec(U.parse_unit(unit_text))
    except Exception:
        return None
    return vec.get(("d", "[angle]"), Fraction(0))


def _with_angle_power(unit_text, k):
    """`unit_text` times rad^k, in the simplest spelling (or None)."""
    vec = unit_vec(U.parse_unit(unit_text))
    target = vadd(vec, {("d", "[angle]"): Fraction(k)})
    if not target:
        return "1"
    return spell_unit(target, [unit_text, "rad"])


def _component_of(rpath):
    """Raw path of the component that owns an equation / reaction path."""
    return rpath[:-2]


def declaration_fixes(text, base, sites, rep):
    """Repair sites whose only mismatch is a `rad` factor by changing ONE
    variable's declared `units` (never a literal `1/rad`).

    A site qualifies when its warning names the `[angle]` axis and a variable of
    its own component that appears at the site has declared units. Candidates,
    in order: the equation's left-hand variable, observed (defined) variables,
    then every other variable at the site. Each candidate declaration
    `old * rad^k` is accepted only if, on the whole document, validity and the
    structural errors are unchanged, the site stops warning, and no warning or
    other unit finding appears anywhere else (every site that uses the variable
    is re-typed by the engine; another unit finding may only disappear). Returns
    the edited text."""
    msgs = engine_messages(text, base)
    angle_sites = [p for p, m in msgs.items() if "[angle]" in m and p in sites]
    if not angle_sites:
        return text
    valid0, errs0, warn0, other0 = engine_report(text, base)
    deadline = time.monotonic() + DECLARATION_BUDGET
    for ptr in sorted(angle_sites):
        if ptr not in warn0:
            continue  # already repaired by an earlier declaration change
        if time.monotonic() > deadline:
            rep["declaration_unresolved"].append(
                {
                    "site": ptr,
                    "equation": _site_equation(
                        get_at(json.loads(text), sites[ptr][0]), sites[ptr][1]
                    ),
                    "tried": [
                        f"not tried: the {DECLARATION_BUDGET} s declaration search budget was spent"
                    ],
                }
            )
            continue
        doc = json.loads(text)
        spans = parse_spans(text)
        rpath, kind = sites[ptr]
        comp_path = _component_of(rpath)
        comp = get_at(doc, comp_path)
        variables = comp.get("variables") if isinstance(comp, dict) else None
        if not isinstance(variables, dict):
            continue
        raw = get_at(doc, rpath)
        if _has_angle_constant(raw):
            # A pi multiple or a degree/radian factor at the site is a genuine
            # angle literal; the literal pass gives it its rad.
            continue
        names = []
        for side in ("lhs", "rhs", "rate"):
            if side in raw:
                for n in _raw_names(raw[side]):
                    if n not in names:
                        names.append(n)
        if any(_is_mixed_angle_unit((variables.get(n) or {}).get("units")) for n in names):
            # An angular quantity (rad/s, rad*m) meets units without the angle:
            # the Coriolis pattern, which each model author resolves (the
            # literal pass lists it). No declaration is changed automatically.
            continue
        observed = {
            eq.get("lhs")
            for eq in comp.get("equations") or []
            if isinstance(eq, dict) and isinstance(eq.get("lhs"), str)
        }
        lhs = raw.get("lhs")
        lhs_var = lhs if isinstance(lhs, str) else None
        if isinstance(lhs, dict) and lhs.get("op") == "D" and lhs.get("args"):
            lhs_var = lhs["args"][0] if isinstance(lhs["args"][0], str) else None
        order = [n for n in [lhs_var] if n]
        order += [n for n in names if n in observed and n not in order]
        order += [n for n in names if n not in order]
        tried = []
        accepted = None
        for name in order:
            var = variables.get(name)
            if not isinstance(var, dict) or not isinstance(var.get("units"), str):
                continue
            old = var["units"]
            e = _angle_power(old)
            if e is None or not _has_non_angle_axis(old):
                # Giving a pure number or a pure angle a power of rad relabels
                # what the quantity IS (an hour of day is not an angle); the
                # site is left to the literal pass and the model author.
                continue
            powers = ([-e] if e else []) + [k for k in (1, -1, 2, -2) if k != -e]
            for k in powers:
                if time.monotonic() > deadline:
                    break
                try:
                    new = _with_angle_power(old, k)
                except Exception:
                    new = None
                if new is None:
                    continue
                sp = span_at(spans, comp_path + ("variables", name, "units"))
                cand = text[: sp.start] + json.dumps(new) + text[sp.end :]
                try:
                    valid1, errs1, warn1, other1 = engine_report(cand, base)
                except Exception:
                    continue
                ok = (
                    valid1 == valid0
                    and errs1 == errs0
                    and set(other1) <= set(other0)
                    and ptr not in warn1
                    and set(warn1) <= set(warn0)
                )
                tried.append(f"{name}: {old} -> {new}" + ("" if ok else " (breaks another site)"))
                if ok:
                    accepted = (name, old, new, cand, warn1)
                    break
            if accepted:
                break
        info = {"site": ptr, "equation": _site_equation(raw, kind)}
        if accepted:
            name, old, new, cand, warn1 = accepted
            fixed = sorted(set(warn0) - set(warn1))
            rep["declarations"].append(
                {
                    **info,
                    "component": "/" + "/".join(ptr_token(x) for x in comp_path),
                    "variable": name,
                    "before": old,
                    "after": new,
                    "sites_fixed": fixed,
                }
            )
            text, warn0 = cand, warn1
        else:
            rep["declaration_unresolved"].append(
                {**info, "tried": tried or ["no variable at the site carries a declared unit"]}
            )
    return text


_ANGLE_CONSTANTS = (2 * math.pi, math.pi, math.pi / 2, math.pi / 4, 180 / math.pi, math.pi / 180)


def _has_angle_constant(raw):
    """Whether an equation or rate carries a literal (or literal-only
    subexpression) equal to a pi multiple or a degree/radian factor."""
    found = []
    for side in ("lhs", "rhs", "rate"):
        if side in raw:
            eligible_literals(raw[side], (side,), found, set())
    for path, kind in found:
        node = get_at(raw, path)
        val = (
            node
            if kind == "number"
            else node.get("value")
            if kind == "const"
            else fold_literal_only(node)
        )
        if any(_near(abs(val), c, 1e-4) for c in _ANGLE_CONSTANTS if isinstance(val, (int, float))):
            return True
    return False


def _has_non_angle_axis(spelled):
    try:
        dv = unit_vec(U.parse_unit(spelled))
    except Exception:
        return False
    return any(k[0] == "d" and k != ("d", "[angle]") for k in dv)


def _is_mixed_angle_unit(spelled):
    if not isinstance(spelled, str):
        return False
    try:
        dv = unit_vec(U.parse_unit(spelled))
    except Exception:
        return False
    axes = {k for k in dv if k[0] == "d"}
    return ("d", "[angle]") in axes and len(axes) > 1


def _raw_names(expr):
    if isinstance(expr, str):
        yield expr
    elif isinstance(expr, list):
        for v in expr:
            yield from _raw_names(v)
    elif isinstance(expr, dict):
        for k, v in expr.items():
            if k in ("args", "expr", "filter", "values", "bindings"):
                yield from _raw_names(v if k != "bindings" else list(v.values()))


def _site_equation(raw, kind):
    if kind == "eq":
        return f"{show(raw.get('lhs'))} = {show(raw.get('rhs'))}"
    return f"rate: {show(raw.get('rate'))}"


# ---- log-unit vectors ------------------------------------------------------


def typed_vec(t):
    """Split a _Typed into ({marker id: coefficient}, {key: exponent})."""
    coef, known = {}, {}
    for axis, e in t.dim.items():
        e = Fraction(e).limit_denominator(10000)
        if e == 0:
            continue
        if axis.startswith("[" + MARK):
            coef[int(axis[len(MARK) + 1 : -1])] = e
        else:
            known[("d", axis)] = e
    for p, e in t.scale._primes.items():
        if p > 0 and e != 0:
            known[("p", p)] = e
    if t.scale._pi != 0:
        known[("pi",)] = t.scale._pi
    return coef, known


def vsub(a, b):
    out = dict(a)
    for k, v in b.items():
        out[k] = out.get(k, 0) - v
        if out[k] == 0:
            del out[k]
    return out


def vadd(a, b, s=1):
    out = dict(a)
    for k, v in b.items():
        out[k] = out.get(k, 0) + s * v
        if out[k] == 0:
            del out[k]
    return out


def vscale(a, s):
    return {k: v * s for k, v in a.items() if v * s != 0}


def unit_vec(unit):
    """Log-vector of a parsed pint unit (exact)."""
    t = U._Typed(unit.dimensionality, U.exact_scale_of(unit))
    return typed_vec(t)[1]


class SymbolicValidator:
    """Factory for the constraint-recording subclass (built once the engine is imported)."""

    cls = None

    @classmethod
    def build(cls):
        base = U.UnitValidator

        class V(base):
            def __init__(self):
                super().__init__()
                self.dimensionless_literals = True
                self.active: set[int] = set()
                self.constraints: list = []  # (coef, rhs_options)
                self.seen_markers: list[int] = []

            # -- markers --
            def _type_node(self, node):
                i = marker_id(node)
                if i is not None:
                    if i not in self.seen_markers:
                        self.seen_markers.append(i)
                    if i in self.active:
                        dim = U.UnitsContainer({f"[{MARK}{i}]": 1})
                        return U._Typed(dim, ExactScale({-(i + 1): Fraction(1)}))
                    return self._dimensionless
                if node.op == "makearray":
                    for a in node.args:
                        self._type(a)
                    return self._agree([self._type(v) for v in (node.values or [])], "makearray")
                return super()._type_node(node)

            # -- constraint recording --
            def _record(self, a, b_options, what):
                """a must equal one of b_options (each a known vector)."""
                coef, known = typed_vec(a)
                if not coef:
                    if not any(vsub(known, b) == {} for b in b_options):
                        raise U.DimensionalMismatchError(f"{what}: known mismatch")
                    return
                self.constraints.append((coef, [vsub(b, known) for b in b_options]))

            def equal(self, a, b, what="="):
                ca, ka = typed_vec(a)
                cb, kb = typed_vec(b)
                coef = vadd(ca, cb, -1)
                known = vsub(ka, kb)
                if not coef:
                    if known:
                        raise U.DimensionalMismatchError(f"{what}: known mismatch")
                    return
                self.constraints.append((coef, [vscale(known, -1)]))

            def _agree(self, operands, op):
                known = [t for t in operands if t is not None]
                if not known:
                    return None
                known = _angle_cancels(known, op)
                for t in known[1:]:
                    self.equal(known[0], t, op)
                return known[0]

            def _require_pure_number(self, typed, op, what):
                if typed is None:
                    return
                if not typed_vec(typed)[0]:
                    return super()._require_pure_number(typed, op, what)
                self._record(typed, [{}], op)

            def _require_dimensionless(self, typed, op, what):
                self._require_pure_number(typed, op, what)

            def _require_angle_or_pure_number(self, typed, op):
                if typed is None:
                    return
                if not typed_vec(typed)[0]:
                    return super()._require_angle_or_pure_number(typed, op)
                self._record(typed, [{}, {("d", "[angle]"): Fraction(1)}], op)

        cls.cls = V
        return V


def _angle_cancels(known, op):
    """The engine's "an angle meets a pure number" rule (esm-spec §4.8.3) over
    operands whose unit is fully known; an operand carrying an unknown literal
    unit is left alone, so the solver never treats a candidate as an angle."""
    if not hasattr(U, "_ANGLE_AGREEMENT_OPS") or op not in U._ANGLE_AGREEMENT_OPS:
        return known
    plain = [t for t in known if not typed_vec(t)[0]]
    if any(U._is_pure_number(t.dim) for t in plain) and any(U._is_pure_angle(t.dim) for t in plain):
        return [
            U._angle_as_number(t) if not typed_vec(t)[0] and U._is_pure_angle(t.dim) else t
            for t in known
        ]
    return known


def check_site(v, lhs, rhs):
    """Type one site under v, recording constraints (mirrors units._site_mismatch)."""
    left = v._type(lhs) if lhs is not None else None
    right = v._type(rhs)
    state = U._derivative_of_undeclared_time(v, lhs)
    if state is not None:
        st = v._type(state)
        if st is not None and right is not None:
            sec = U._Typed(U.ureg.parse_units("s").dimensionality, ExactScale.one())
            v.equal(U._Typed(st.dim / sec.dim, st.scale), right, "D")
        return
    if lhs is None or left is None or right is None:
        return
    if hasattr(U, "_angle_meets_number") and not typed_vec(left)[0] and not typed_vec(right)[0]:
        left, right = U._angle_meets_number(left, right)
    v.equal(left, right, "lhs=rhs")


def solve(constraints, unknowns):
    """Solve Σ coef_i X_i = rhs over log-unit vectors. Returns (status, {i: vec}).

    status: 'unique', 'underdetermined', 'inconsistent'."""
    alt_idx = [k for k, (_, opts) in enumerate(constraints) if len(opts) > 1]
    choices = itertools.product(*[range(len(constraints[k][1])) for k in alt_idx[:6]])
    best = None
    for choice in choices:
        pick = dict(zip(alt_idx[:6], choice))
        rows = []
        for k, (coef, opts) in enumerate(constraints):
            rows.append(([Fraction(coef.get(i, 0)) for i in unknowns], dict(opts[pick.get(k, 0)])))
        status, sol = _gauss(rows, len(unknowns))
        if status == "unique":
            return status, {u: sol[j] for j, u in enumerate(unknowns)}
        if status == "underdetermined" and best is None:
            best = (status, None)
    return best or ("inconsistent", None)


def _gauss(rows, n):
    rows = [(list(c), dict(r)) for c, r in rows]
    piv_rows = []
    r = 0
    for col in range(n):
        p = next((k for k in range(r, len(rows)) if rows[k][0][col] != 0), None)
        if p is None:
            continue
        rows[r], rows[p] = rows[p], rows[r]
        c0, r0 = rows[r]
        f = c0[col]
        c0 = [x / f for x in c0]
        r0 = vscale(r0, 1 / f)
        rows[r] = (c0, r0)
        for k in range(len(rows)):
            if k != r and rows[k][0][col] != 0:
                g = rows[k][0][col]
                rows[k] = ([a - g * b for a, b in zip(rows[k][0], c0)], vadd(rows[k][1], r0, -g))
        piv_rows.append(col)
        r += 1
    for k in range(r, len(rows)):
        if rows[k][1]:
            return "inconsistent", None
    if r < n:
        return "underdetermined", None
    sol = [None] * n
    for k, col in enumerate(piv_rows):
        sol[col] = rows[k][1]
    return "unique", sol


# ---------------------------------------------------------------------------
# Unit spelling
# ---------------------------------------------------------------------------

_BASE_SYMBOLS = ("m", "kg", "s", "K", "mol", "A", "cd", "rad")
_SYMBOL_RE = re.compile(r"(?:[^\W\d]|%)\w*")


def _fmt_exp(e):
    e = Fraction(e)
    if e.denominator == 1:
        return f"^{e.numerator}" if e != 1 else ""
    return f"^({e.numerator}/{e.denominator})"


def _wrap(s):
    return f"({s})" if re.search(r"[*/ ^]", s) else s


def spell(factors):
    num = [(s, e) for s, e in factors if e > 0]
    den = [(s, -e) for s, e in factors if e < 0]

    def part(fs):
        alone = len(factors) == 1 and fs is num
        return "*".join((s if alone and e == 1 else _wrap(s)) + _fmt_exp(e) for s, e in fs)

    out = part(num) if num else "1"
    if den:
        d = part(den)
        out += "/" + (f"({d})" if len(den) > 1 else d)
    return out


def _key(v):
    return tuple(sorted(v.items(), key=repr))


def _parses_to(s, target):
    try:
        return unit_vec(U.parse_unit(s)) == target
    except Exception:
        return False


def spell_unit(target, atom_strings):
    """Simplest §4.8.2 spelling of log-vector `target`.

    1. A unit string declared at the site that IS the target, verbatim.
    2. A product of powers of the unit SYMBOLS the site's declared units use,
       plus the SI base symbols: fewest factors, then smallest exponents.
    3. At scale 1, the SI base symbols with whatever exponents it takes.
    Every spelling is parsed back and must give the target exactly."""
    if not target:
        return "1"
    for s in atom_strings:
        if _parses_to(s, target):
            return s
    symbols = []
    for s in atom_strings:
        for sym in _SYMBOL_RE.findall(s):
            if sym not in symbols:
                symbols.append(sym)
    atoms, seen = [], set()
    for s in symbols + list(_BASE_SYMBOLS):
        try:
            vec = unit_vec(U.parse_unit(s))
        except Exception:
            continue
        if not vec or _key(vec) in seen:
            continue
        seen.add(_key(vec))
        atoms.append((s, vec))
    order = {s: i for i, (s, _) in enumerate(atoms)}
    foreign = {s for s, _ in atoms if s not in symbols}  # base symbols the site never wrote

    def table(exps):
        out = {}
        for ai, (s, vec) in enumerate(atoms):
            for e in exps:
                k = _key(vscale(vec, e))
                cand = ((1, int(s in foreign), abs(e)), ((s, e),))
                if k not in out or cand[0] < out[k][0]:
                    out[k] = cand
        return out

    def combine(t1, t2):
        out = {}
        for k1, c1 in t1.items():
            for k2, c2 in t2.items():
                if {f[0] for f in c1[1]} & {f[0] for f in c2[1]}:
                    continue
                k = _key(vadd(dict(k1), dict(k2)))
                cand = (tuple(x + y for x, y in zip(c1[0], c2[0])), c1[1] + c2[1])
                if k not in out or cand[0] < out[k][0]:
                    out[k] = cand
        return out

    tk = _key(target)
    singles = table((1, -1, 2, -2, 3, -3))
    best = singles.get(tk)
    if best is None:
        pairs = combine(singles, singles)
        best = pairs.get(tk)
        if best is None:
            for k, c in pairs.items():
                d = singles.get(_key(vsub(target, dict(k))))
                if d and not ({f[0] for f in c[1]} & {f[0] for f in d[1]}):
                    cand = (tuple(x + y for x, y in zip(c[0], d[0])), c[1] + d[1])
                    if best is None or cand[0] < best[0]:
                        best = cand
        if best is None:
            unit_pairs = combine(table((1, -1)), table((1, -1)))
            unit_singles = table((1, -1, 2, -2))
            for k, c in pairs.items():
                d = pairs.get(_key(vsub(target, dict(k))))
                if d and not ({f[0] for f in c[1]} & {f[0] for f in d[1]}):
                    cand = (tuple(x + y for x, y in zip(c[0], d[0])), c[1] + d[1])
                    if best is None or cand[0] < best[0]:
                        best = cand
            if best is None:
                for k1, c1 in unit_pairs.items():
                    rest = vsub(target, dict(k1))
                    for k2, c2 in unit_pairs.items():
                        d = unit_singles.get(_key(vsub(rest, dict(k2))))
                        if d is None:
                            continue
                        names = [f[0] for f in c1[1] + c2[1] + d[1]]
                        if len(set(names)) != len(names):
                            continue
                        cand = (
                            tuple(x + y + z for x, y, z in zip(c1[0], c2[0], d[0])),
                            c1[1] + c2[1] + d[1],
                        )
                        if best is None or cand[0] < best[0]:
                            best = cand
    candidates = []
    if best is not None:
        fs = sorted(best[1], key=lambda f: (f[1] < 0, order[f[0]]))
        candidates.append(spell(fs))
    if all(k[0] == "d" for k in target):
        dims = {
            "[length]": "m",
            "[mass]": "kg",
            "[time]": "s",
            "[substance]": "mol",
            "[temperature]": "K",
            "[current]": "A",
            "[luminosity]": "cd",
            "[angle]": "rad",
        }
        fs = [(dims[k[1]], e) for k, e in target.items() if k[1] in dims]
        if len(fs) == len(target):
            candidates.append(spell(sorted(fs, key=lambda f: f[1] < 0)))
    for s in candidates:
        if _parses_to(s, target):
            return s
    return None


# ---------------------------------------------------------------------------
# Raw document walk
# ---------------------------------------------------------------------------


def ptr_token(name):
    return str(name).replace("~", "~0").replace("/", "~1")


def raw_sites(doc):
    """{pointer: (raw path, kind)} for every check site written in THIS file.
    kind is 'eq' (lhs/rhs) or 'rate'. Mounted ({ref}) subsystems are not here."""
    out = {}

    def model(path, ptr, m):
        if not isinstance(m, dict) or "ref" in m:
            return
        for f in ("equations", "initialization_equations"):
            for i, _ in enumerate(m.get(f) or []):
                out[f"{ptr}/{f}/{i}"] = (path + (f, i), "eq")
        for n, sub in (m.get("subsystems") or {}).items():
            model(path + ("subsystems", n), f"{ptr}/subsystems/{ptr_token(n)}", sub)

    def rs(path, ptr, s):
        if not isinstance(s, dict) or "ref" in s:
            return
        for i, _ in enumerate(s.get("constraint_equations") or []):
            out[f"{ptr}/constraint_equations/{i}"] = (path + ("constraint_equations", i), "eq")
        for i, r in enumerate(s.get("reactions") or []):
            out[f"{ptr}/reactions/{i}"] = (path + ("reactions", i), "rate")
        for n, sub in (s.get("subsystems") or {}).items():
            rs(path + ("subsystems", n), f"{ptr}/subsystems/{ptr_token(n)}", sub)

    for n, m in (doc.get("models") or {}).items():
        model(("models", n), f"/models/{ptr_token(n)}", m)
    for n, s in (doc.get("reaction_systems") or {}).items():
        rs(("reaction_systems", n), f"/reaction_systems/{ptr_token(n)}", s)
    return out


def eligible_literals(expr, path, out, templates_used):
    """Collect raw paths of nonzero literals whose unit is typed (see _TYPED_ALL_ARGS)."""
    if is_number(expr):
        if expr != 0:
            out.append((path, "number"))
        return
    if not isinstance(expr, dict):
        return
    op = expr.get("op")
    args = expr.get("args") or []
    folded = fold_literal_only(expr)
    if folded is not None:
        # A literal-only subexpression (`1 / 64`, `2 * 3600`): any of its
        # literals could carry the unit, so it is ONE candidate, rewritten as
        # a single const of its folded IEEE value. Only one level is folded:
        # a nested literal tree is structure the author wrote on purpose.
        if folded != 0:
            out.append((path, "fold"))
        return
    if op == "const":
        if is_number(expr.get("value")) and expr.get("value") != 0 and "units" not in expr:
            out.append((path, "const"))
        return
    if op == "apply_expression_template":
        templates_used.add(expr.get("name"))
        for k, b in (expr.get("bindings") or {}).items():
            eligible_literals(b, path + ("bindings", k), out, templates_used)
        return
    if op in _TYPED_ALL_ARGS:
        for i, a in enumerate(args):
            eligible_literals(a, path + ("args", i), out, templates_used)
    elif op in ("^", "index", "reshape", "transpose") and args:
        eligible_literals(args[0], path + ("args", 0), out, templates_used)
    elif op == "makearray":
        for i, v in enumerate(expr.get("values") or []):
            eligible_literals(v, path + ("values", i), out, templates_used)
    elif op in ("faq", "aggregate") and expr.get("expr") is not None:
        eligible_literals(expr["expr"], path + ("expr",), out, templates_used)
    elif op == "broadcast" and expr.get("fn") in _TYPED_ALL_ARGS:
        for i, a in enumerate(args):
            eligible_literals(a, path + ("args", i), out, templates_used)


def _leaf_value(e):
    if is_number(e):
        return e
    if isinstance(e, dict) and e.get("op") == "-" and len(e.get("args") or []) == 1:
        inner = _leaf_value(e["args"][0])
        return None if inner is None else -inner
    return None


def fold_literal_only(expr):
    """The folded value of a `+ - * /` node with at least two arguments, every
    one a literal or a negated literal (left folds, in the evaluator's order),
    else None. A node with a nested operator among its arguments is not folded."""
    if not isinstance(expr, dict) or expr.get("op") not in ("+", "-", "*", "/"):
        return None
    args = expr.get("args") or []
    if len(args) < 2:
        return None
    vals = []
    for a in args:
        v = _leaf_value(a)
        if v is None:
            return None
        vals.append(v)
    acc = vals[0]
    try:
        for v in vals[1:]:
            op = expr["op"]
            acc = (
                acc + v
                if op == "+"
                else acc - v
                if op == "-"
                else acc * v
                if op == "*"
                else acc / v
            )
    except ZeroDivisionError:
        return None
    if isinstance(acc, float) and not math.isfinite(acc):
        return None
    return acc


def find_templates(doc):
    """{name: [raw path of body]} for every expression_templates block in the file."""
    out = {}

    def walk(node, path):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "expression_templates" and isinstance(v, dict):
                    for n, t in v.items():
                        if isinstance(t, dict) and "body" in t:
                            out.setdefault(n, []).append(path + (k, n, "body"))
                walk(v, path + (k,))
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, path + (i,))

    walk(doc, ())
    return out


# ---------------------------------------------------------------------------
# Loaded-document walk
# ---------------------------------------------------------------------------


def loaded_sites(esm):
    """{pointer: (component, units dict, lhs, rhs)} mirroring dimensionless_literal_findings."""
    out = {}

    def walk_model(ptr, m):
        units = {n: v.units for n, v in (m.variables or {}).items()}
        for f in ("equations", "initialization_equations"):
            for i, eq in enumerate(getattr(m, f, None) or []):
                out[f"{ptr}/{f}/{i}"] = (m, units, eq.lhs, eq.rhs)
        subs(ptr, m, walk_model)

    def walk_rs(ptr, rs):
        units = {sp.name: sp.units for sp in rs.species or []}
        units.update({p.name: p.units for p in rs.parameters or []})
        for i, eq in enumerate(rs.constraint_equations or []):
            out[f"{ptr}/constraint_equations/{i}"] = (rs, units, eq.lhs, eq.rhs)
        for i, r in enumerate(rs.reactions or []):
            rate = getattr(r, "rate_constant", None)
            if rate is not None:
                out[f"{ptr}/reactions/{i}"] = (rs, units, None, rate)
        subs(ptr, rs, walk_rs)

    def subs(ptr, comp, walk):
        for n, sub in (getattr(comp, "subsystems", None) or {}).items():
            if not isinstance(sub, dict):
                walk(f"{ptr}/subsystems/{ptr_token(n)}", sub)

    for n, m in (esm.models or {}).items():
        walk_model(f"/models/{ptr_token(n)}", m)
    for n, s in (esm.reaction_systems or {}).items():
        walk_rs(f"/reaction_systems/{ptr_token(n)}", s)
    return out


def iter_nodes(e, parent=None):
    yield e, parent
    if isinstance(e, ExprNode):
        for a in e.args or []:
            yield from iter_nodes(a, e)
        for a in (e.expr, e.filter):
            if a is not None:
                yield from iter_nodes(a, e)
        for a in e.values or []:
            yield from iter_nodes(a, e)


def marker_id(e):
    if (
        isinstance(e, ExprNode)
        and e.op == "const"
        and e.units == MARK_UNITS
        and isinstance(e.value, int)
        and e.value >= MARK_BASE
    ):
        return e.value - MARK_BASE
    return None


def names_in(e):
    out = []
    for n, _ in iter_nodes(e):
        if isinstance(n, str) and n not in out:
            out.append(n)
    return out


# ---------------------------------------------------------------------------
# Per-site solve
# ---------------------------------------------------------------------------


def make_validator(comp, units, scoped):
    V = SymbolicValidator.cls
    v = V()
    v.scoped_units = scoped.for_component(comp)
    for name, spelled in units.items():
        if not spelled:
            continue
        try:
            v.known_units[name] = U.parse_unit(spelled)
        except Exception:
            continue
    return v


def try_subset(comp, units, scoped, lhs, rhs, subset):
    v = make_validator(comp, units, scoped)
    v.active = set(subset)
    try:
        check_site(v, lhs, rhs)
    except U.DimensionalMismatchError:
        return "inconsistent", None
    except Exception as exc:  # pint or engine failure: treat as no solution
        return "error:" + type(exc).__name__, None
    if not subset:
        return ("unique", {}) if not v.constraints else ("inconsistent", None)
    status, sol = solve(v.constraints, list(subset))
    if status == "unique" and any(not x for x in sol.values()):
        return "nonminimal", None
    return status, sol


def solve_site(comp, units, scoped, lhs, rhs, candidates, max_exhaustive=3):
    """Return ('ok', {id: vec}) | ('ambiguous', [sols]) | ('unresolved', reason)."""
    deadline = time.monotonic() + SITE_BUDGET

    def over():
        return time.monotonic() > deadline

    budget_msg = f"the literal-subset search exceeded its {SITE_BUDGET} s budget"
    n = len(candidates)
    if n == 0:
        return "unresolved", "no eligible nonzero literal at the site (the mismatch is elsewhere)"
    limit = max_exhaustive if n <= 25 else (2 if n <= 60 else 1)
    for size in range(1, min(limit, n) + 1):
        sols = []
        for subset in itertools.combinations(candidates, size):
            if over():
                return "unresolved", budget_msg
            status, sol = try_subset(comp, units, scoped, lhs, rhs, subset)
            if status == "unique":
                sols.append(sol)
        if len(sols) == 1:
            return "ok", sols[0]
        if len(sols) > 1:
            return "ambiguous", sols
    # greedy elimination for larger subsets
    active = list(candidates)
    status, sol = try_subset(comp, units, scoped, lhs, rhs, active)
    if status not in ("unique", "underdetermined", "nonminimal"):
        return "unresolved", "no assignment of units to the site's literals makes it pass"
    for c in list(candidates):
        if over():
            return "unresolved", budget_msg
        trial = [x for x in active if x != c]
        st, _ = try_subset(comp, units, scoped, lhs, rhs, trial)
        if st in ("unique", "underdetermined", "nonminimal"):
            active = trial
    status, sol = try_subset(comp, units, scoped, lhs, rhs, active)
    if status != "unique":
        return "unresolved", f"minimal literal set {len(active)} is {status}"
    for i in active:
        for j in candidates:
            if over():
                return "unresolved", budget_msg
            if j in active:
                continue
            swap = [x for x in active if x != i] + [j]
            st, other = try_subset(comp, units, scoped, lhs, rhs, swap)
            if st == "unique":
                return "ambiguous", [sol, other]
    return "ok", sol


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------


def role_of(site_exprs, mid):
    """(parent op of the marker, skipping unary +/-, and whether it is a whole side)."""
    for side in site_exprs:
        if side is None:
            continue
        chain = []

        def find(e, stack):
            if marker_id(e) == mid:
                chain.extend(stack)
                return True
            if isinstance(e, ExprNode):
                kids = (
                    list(e.args or [])
                    + [x for x in (e.expr, e.filter) if x is not None]
                    + list(e.values or [])
                )
                return any(find(k, stack + [(e, i)]) for i, k in enumerate(kids))
            return False

        if find(side, []):
            parents = [
                (p, i) for p, i in chain if not (p.op in ("+", "-") and len(p.args or []) == 1)
            ]
            whole = len(parents) == 0
            role = None
            if parents:
                node, idx = parents[-1]
                role = "/den" if node.op == "/" and idx >= 1 else node.op
            return role, whole, [p.op for p, _ in chain]
    return None, False, []


def _near(value, target, rel=2e-5):
    return isinstance(value, (int, float)) and abs(float(value) - target) <= rel * abs(target)


_RAD = {("d", "[angle]"): Fraction(1)}


def _angle_literal_class(val, vec, unit, declared_vecs):
    """(class, why) for a literal that carries an angle, or None to defer to
    `classify`. Genuine angle quantities are mechanical: a degree/radian
    conversion factor, a multiple of pi next to an angle (or 2*pi radians per
    cycle), and a radius per radian. Any other literal that needs a power of
    rad (at scale 1, so not deg) is suspicious, since the angle usually
    belongs in a declaration."""
    angle_power = vec.get(("d", "[angle]"), 0)
    has_pi = ("pi",) in vec
    if (
        (_near(val, 180 / math.pi) or _near(val, 180))
        and has_pi
        and not any(k[0] == "d" for k in vec)
    ):
        return "mechanical", "degree/radian conversion factor (deg/rad)"
    if (
        (_near(val, math.pi / 180) or _near(val, 1 / 180))
        and has_pi
        and not any(k[0] == "d" for k in vec)
    ):
        return "mechanical", "radian/degree conversion factor (rad/deg)"
    if vec == _RAD and any(_near(abs(val), m * math.pi) for m in (2, 1, 0.5, 0.25, 4)):
        return "mechanical", "a multiple of pi in radians (an angle, or radians per cycle)"
    dims = {k: e for k, e in vec.items() if k[0] == "d"}
    if dims == {("d", "[length]"): Fraction(1), ("d", "[angle]"): Fraction(-1)}:
        return "mechanical", "a radius per radian (arc length per angle)"
    if angle_power and set(vec) == {("d", "[angle]")}:
        return (
            "suspicious",
            "the literal needs a bare power of rad; the angle usually belongs in a declaration",
        )
    return None


def _angle_velocity_mismatch(val, vec, declared):
    """A message template when a literal would need a pure power of rad at a site
    where a mixed angular unit (rad/s, rad*m, ...) meets units without the angle
    (the Coriolis pattern), else None."""
    if set(k for k in vec if k[0] == "d") != {("d", "[angle]")} or ("pi",) in vec:
        return None
    if isinstance(val, (int, float)) and any(_near(abs(val), c, 1e-4) for c in _ANGLE_CONSTANTS):
        return None  # 2*pi radians per cycle, pi/2 ...: a genuine angle literal
    mixed = []
    for name, spelled in declared.items():
        try:
            dv = unit_vec(U.parse_unit(spelled))
        except Exception:
            continue
        axes = {k for k in dv if k[0] == "d"}
        if ("d", "[angle]") in axes and len(axes) > 1:
            mixed.append(f"{name} [{spelled}]")
    if not mixed:
        return None
    return (
        "an angular quantity ({m}) meets a quantity without the angle in `{{eq}}`; under the "
        "strict angle rule the formula consumes a radian, so literal {{val}} would need "
        "units rad^{p}. Either keep the left-hand side's declaration and write the literal "
        "with that rad power (for f = 2*Omega*sin(lat): declare f in 1/s and write "
        'const(2, units "1/rad")), or declare the angular quantity without rad '
        "(Omega in 1/s). Each model author decides which; nothing is proposed."
    ).format(m=", ".join(mixed), p=vec[("d", "[angle]")])


#: Suspicious sub-kinds, most alarming first; the summary lists them in this order.
ODD_REASONS = (
    "the needed unit has an axis no declared unit at the site has",
    "the needed unit has a fractional or large exponent",
)


def classify(vec, unit, role, whole, declared_vecs, site_symbols, chain_ops, lhs_is_d=False):
    """(class, why) for one rewrite. Mechanical means the unit is forced and
    unremarkable; anything else is suspicious, with the oddest reasons first."""
    dims = {k: e for k, e in vec.items() if k[0] == "d"}
    if not dims:
        return "mechanical", "conversion factor (dimensionless, scale != 1)"
    if role in _AGREEMENT_OPS or role in ("ifelse", "makearray"):
        return "mechanical", f"offset / threshold / bound in `{role}` (takes its sibling's unit)"
    if whole:
        return "mechanical", "the literal is the whole side of the equation"
    if any(dv == vec for dv in declared_vecs):
        return "mechanical", "reference constant in a unit declared at the site"
    if any(dv == vscale(vec, -1) for dv in declared_vecs) and (
        {"exp", "log", "ln", "log10", "sin", "cos", "tan"} & set(chain_ops)
    ):
        return "mechanical", "inverse of a unit declared at the site, inside a transcendental"
    m = re.fullmatch(r"(?:1/)?((?:[^\W\d]|%)\w*)", unit or "")
    transcendental = {"exp", "log", "ln", "log10", "sin", "cos", "tan"} & set(chain_ops)
    if m and m.group(1) in site_symbols and (role == "/den" or transcendental):
        return (
            "mechanical",
            "reference constant (a divisor, or inside a transcendental) in a unit symbol the site uses",
        )
    if lhs_is_d and unit == "1/s":
        return "mechanical", "first-order rate constant in a time derivative"
    all_axes = {k for dv in declared_vecs for k in dv if k[0] == "d"} | {("d", "[time]")}
    if set(dims) - all_axes:
        return "suspicious", ODD_REASONS[0]
    if any(Fraction(e).denominator != 1 or abs(e) > 4 for e in dims.values()):
        return "suspicious", ODD_REASONS[1]
    return "suspicious", "a dimensional coefficient whose unit is declared nowhere at the site"


# ---------------------------------------------------------------------------
# Expression display
# ---------------------------------------------------------------------------


def show(e, depth=0):
    if depth > 12:
        return "…"
    if isinstance(e, bool):
        return str(e).lower()
    if is_number(e):
        return repr(e)
    if isinstance(e, str):
        return e
    if not isinstance(e, dict):
        return json.dumps(e)[:60]
    op = e.get("op")
    args = [show(a, depth + 1) for a in e.get("args") or []]
    if op == "const":
        u = e.get("units")
        return f"const({e.get('value')}{', ' + json.dumps(u) if u else ''})"
    if op in ("+", "*", "/", ">", "<", ">=", "<=", "==", "!=") and len(args) >= 2:
        return "(" + f" {op} ".join(args) + ")"
    if op == "-" and len(args) == 1:
        return f"-{args[0]}"
    if op == "-" and len(args) >= 2:
        return "(" + " - ".join(args) + ")"
    if op == "^" and len(args) == 2:
        return f"{args[0]}^{args[1]}"
    if op == "D":
        return f"D({', '.join(args)})"
    if op == "apply_expression_template":
        b = ", ".join(f"{k}={show(v, depth + 1)}" for k, v in (e.get("bindings") or {}).items())
        return f"{e.get('name')}<{b}>"
    extra = []
    for k in ("expr", "filter"):
        if e.get(k) is not None:
            extra.append(f"{k}={show(e[k], depth + 1)}")
    if e.get("values"):
        extra.append("values=[" + ", ".join(show(v, depth + 1) for v in e["values"]) + "]")
    for k in ("fn", "name", "wrt", "dim"):
        if isinstance(e.get(k), str) and not (k == "wrt" and e[k] == "t"):
            extra.append(f"{k}={e[k]}")
    return f"{op}({', '.join(args + extra)})"


# ---------------------------------------------------------------------------
# One file
# ---------------------------------------------------------------------------


def process_file(path: str, bump: bool, evaluate: bool = True) -> dict:
    rep = {"file": path, "rewrites": [], "unresolved": [], "notes": [], "status": "ok"}
    text = Path(path).read_text()
    base = str(Path(path).resolve().parent)
    try:
        doc = json.loads(text)
        spans = parse_spans(text)
    except Exception as exc:
        rep["status"] = "skipped: not JSON"
        rep["notes"].append(f"unparseable JSON: {exc}")
        return rep
    try:
        valid0, errs0, warn0, other0 = engine_report(text, base)
    except Exception as exc:
        rep["status"] = f"engine failed on the original: {type(exc).__name__}: {exc}"[:300]
        return rep
    rep["is_valid"] = valid0
    rep["warnings_before"] = warn0
    rep["declarations"] = []
    rep["declaration_unresolved"] = []
    if not warn0:
        return rep
    version = version_tuple(doc.get("esm"))
    rep["esm"] = doc.get("esm")
    sites = raw_sites(doc)
    decl_text = declaration_fixes(text, base, sites, rep)
    if decl_text != text:
        text = decl_text
        doc = json.loads(text)
        spans = parse_spans(text)
        valid0, errs0, warn0, other0 = engine_report(text, base)
        if not warn0:
            rep["new_text"] = text
            rep["warnings_after"] = warn0
            rep["applied"] = True
            return rep
    templates = find_templates(doc)

    # 1. markers
    marks = {}  # id -> (raw path, kind, value)
    site_marks = {}
    foreign_templates = {}  # site -> templates it applies that this file does not define
    for ptr in warn0:
        if ptr not in sites:
            rep["unresolved"].append(
                {"site": ptr, "reason": "the site is in a mounted ({ref}) file; repair it there"}
            )
            continue
        rpath, kind = sites[ptr]
        raw = get_at(doc, rpath)
        found, used = [], set()
        if kind == "eq":
            for side in ("lhs", "rhs"):
                if side in raw:
                    eligible_literals(raw[side], rpath + (side,), found, used)
        else:
            if "rate" in raw:
                eligible_literals(raw["rate"], rpath + ("rate",), found, used)
        for name in sorted(n for n in used if n):
            for body in templates.get(name, []):
                eligible_literals(get_at(doc, body), body, found, set())
        site_marks[ptr] = found
        foreign = sorted(n for n in used if n and n not in templates)
        if foreign:
            foreign_templates[ptr] = foreign
        for p, k in found:
            if all(m[0] != p for m in marks.values()):
                raw_val = get_at(doc, p)
                val = (
                    raw_val
                    if k == "number"
                    else raw_val["value"]
                    if k == "const"
                    else fold_literal_only(raw_val)
                )
                marks[len(marks)] = (p, k, val)

    probe = copy.deepcopy(doc)
    if version is None or version < MIN_CONST_UNITS_VERSION:
        probe["esm"] = "1.2.0"
    for i, (p, k, val) in marks.items():
        if k in ("number", "fold"):
            set_at(
                probe, p, {"op": "const", "args": [], "value": MARK_BASE + i, "units": MARK_UNITS}
            )
        else:
            get_at(probe, p)["units"] = MARK_UNITS
            get_at(probe, p)["value"] = MARK_BASE + i
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            esm = EA.load_document(probe, base_path=base)
    except Exception as exc:
        rep["status"] = f"probe load failed: {type(exc).__name__}: {exc}"[:300]
        for ptr in site_marks:
            rep["unresolved"].append({"site": ptr, "reason": "probe document did not load"})
        return rep
    scoped = U.ScopedUnits(esm)
    lsites = loaded_sites(esm)

    # 2. solve each site
    proposals = {}  # id -> list of (site, vec)
    site_info = {}
    for ptr in site_marks:
        if ptr not in lsites:
            rep["unresolved"].append({"site": ptr, "reason": "site not found after load"})
            continue
        comp, units, lhs, rhs = lsites[ptr]
        cands = []
        for e in (lhs, rhs):
            if e is None:
                continue
            for node, _ in iter_nodes(e):
                mid = marker_id(node)
                if mid is not None and mid not in cands:
                    cands.append(mid)
        status, sol = solve_site(comp, units, scoped, lhs, rhs, cands)
        rpath, kind = sites[ptr]
        raw = get_at(doc, rpath)
        eq_text = (
            f"{show(raw.get('lhs'))} = {show(raw.get('rhs'))}"
            if kind == "eq"
            else f"rate: {show(raw.get('rate'))}"
        )
        declared = {}
        for e in (lhs, rhs):
            if e is None:
                continue
            for nm in names_in(e):
                spelled = units.get(nm)
                if spelled is None:
                    t = v_scoped(scoped, comp, nm)
                    spelled = t
                if spelled:
                    declared[nm] = spelled
        if any(
            nm == "t" and nm not in declared and units.get(nm) is None
            for e in (lhs, rhs)
            if e is not None
            for nm in names_in(e)
        ) or any(isinstance(e, ExprNode) and e.op == "D" for e in (lhs,)):
            declared.setdefault("t", "s")
        site_info[ptr] = {"equation": eq_text, "declared": declared, "lhs": lhs, "rhs": rhs}
        if status == "ok":
            for mid, vec in sol.items():
                proposals.setdefault(mid, []).append((ptr, vec))
        elif status == "ambiguous":
            alts = []
            for s in sol[:4]:
                alts.append(
                    ", ".join(
                        f"{marks[m][2]} -> {spell_unit(v, list(declared.values())) or v}"
                        for m, v in s.items()
                    )
                )
            rep["unresolved"].append(
                {
                    "site": ptr,
                    "equation": eq_text,
                    "declared_units": declared,
                    "reason": "ambiguous: several literal sets could carry the unit",
                    "alternatives": alts,
                }
            )
        else:
            if ptr in foreign_templates:
                sol += (
                    "; the site applies template(s) defined in another file ("
                    + ", ".join(foreign_templates[ptr])
                    + "), whose literals are repaired there"
                )
            rep["unresolved"].append(
                {"site": ptr, "equation": eq_text, "declared_units": declared, "reason": sol}
            )

    # 3. spell, classify, detect conflicts
    edits = {}  # raw path -> (kind, unit)
    bad_sites = set()
    for mid, uses in proposals.items():
        vecs = {_key(v) for _, v in uses}
        p, k, val = marks[mid]
        if len(vecs) > 1:
            for ptr, _ in uses:
                bad_sites.add(
                    (
                        ptr,
                        f"literal {val} (a template body) needs different units at different sites",
                    )
                )
            continue
        ptr0, vec = uses[0]
        atoms = []
        for ptr, _ in uses:
            atoms += list(site_info[ptr]["declared"].values())
        coriolis = _angle_velocity_mismatch(val, vec, site_info[ptr0]["declared"])
        if coriolis is not None:
            # An angular quantity meets a length or a 1/s quantity, and a literal
            # would have to consume the radian: that is a modelling decision.
            for ptr, _ in uses:
                bad_sites.add((ptr, coriolis.format(val=val, eq=site_info[ptr]["equation"])))
            continue
        unit = spell_unit(vec, atoms)
        if unit is None:
            for ptr, _ in uses:
                bad_sites.add(
                    (
                        ptr,
                        f"literal {val}: the needed unit {vec} has no spelling from the site's units",
                    )
                )
            continue
        info = site_info[ptr0]
        role, whole, chain = role_of((info["lhs"], info["rhs"]), mid)
        declared_vecs = []
        for s in info["declared"].values():
            try:
                declared_vecs.append(unit_vec(U.parse_unit(s)))
            except Exception:
                pass
        site_symbols = {sym for s in info["declared"].values() for sym in _SYMBOL_RE.findall(s)}
        lhs_is_d = isinstance(info["lhs"], ExprNode) and info["lhs"].op == "D"
        cls, why = classify(vec, unit, role, whole, declared_vecs, site_symbols, chain, lhs_is_d)
        angle = _angle_literal_class(val, vec, unit, declared_vecs)
        if angle is not None:
            cls, why = angle
        if k == "fold":
            why += f"; the literal-only `{show(get_at(doc, p))}` is folded to {json.dumps(val)}"
        edits[p] = {
            "kind": k,
            "unit": unit,
            "value": val,
            "class": cls,
            "why": why,
            "sites": [u[0] for u in uses],
            "mid": mid,
        }
    for ptr, reason in sorted(bad_sites):
        rep["unresolved"].append(
            {
                "site": ptr,
                "equation": site_info[ptr]["equation"],
                "declared_units": site_info[ptr]["declared"],
                "reason": reason,
            }
        )
    bad = {s for s, _ in bad_sites}
    edits = {p: e for p, e in edits.items() if not (set(e["sites"]) & bad)}

    # 4. apply + verify, dropping sites whose proposal fails, up to 3 rounds
    needs_bump = version is None or version < MIN_CONST_UNITS_VERSION
    for _round in range(3):
        if not edits:
            break
        if needs_bump and not bump:
            break
        new_text, new_doc = apply_edits(text, spans, doc, edits, bump=needs_bump)
        try:
            if json.loads(new_text) != new_doc:
                raise AssertionError("text edit does not match the JSON transform")
            valid1, errs1, warn1, other1 = engine_report(new_text, base)
        except Exception as exc:
            rep["status"] = f"verification failed: {type(exc).__name__}: {exc}"[:300]
            edits = {}
            break
        fixed_sites = {s for e in edits.values() for s in e["sites"]}
        failing = set()
        if valid1 != valid0 or errs1 != errs0:
            rep["notes"].append(
                f"validity/errors changed: {valid0}->{valid1}; dropping all rewrites"
            )
            edits = {}
            break
        still = set(warn1) & fixed_sites
        new_w = set(warn1) - set(warn0)
        failing |= still | new_w
        if other1 != other0:
            changed = set(p for _, p in set(other1) ^ set(other0))
            failing |= changed & fixed_sites if changed & fixed_sites else fixed_sites
        if evaluate and not failing:
            failing |= eval_mismatch(doc, new_doc, sites, fixed_sites, base)
        if not failing:
            rep["new_text"] = new_text
            rep["warnings_after"] = warn1
            break
        for s in sorted(failing):
            info = site_info.get(s, {})
            rep["unresolved"].append(
                {
                    "site": s,
                    "equation": info.get("equation"),
                    "declared_units": info.get("declared"),
                    "reason": "the proposal did not verify (site still warns, a new warning, or values changed)",
                }
            )
        edits = {p: e for p, e in edits.items() if not (set(e["sites"]) & failing)}
    else:
        edits = {}
    if not rep.get("new_text"):
        edits_out = edits if (needs_bump and not bump) else {}
        if needs_bump and not bump and edits:
            rep["status"] = "needs esm >= 1.2.0"
            rep["notes"].append(
                f"declares esm {doc.get('esm')}; a unit-bearing const needs >= 1.2.0. "
                "Proposals listed but NOT applied (re-run with --bump-version)."
            )
        edits = edits_out
    rep["bumped"] = bool(rep.get("new_text")) and needs_bump
    rep["applied"] = bool(rep.get("new_text"))
    final_warn = set(rep.get("warnings_after", warn0) if rep.get("new_text") else warn0)
    rep["declaration_unresolved"] = [
        d for d in rep["declaration_unresolved"] if d["site"] in final_warn
    ]
    if not rep.get("new_text") and rep["declarations"]:
        # Only declaration changes verified: they stand on their own.
        rep["new_text"] = text
        rep["bumped"] = False
        rep["applied"] = True
    for p, e in edits.items():
        rep["rewrites"].append(
            {
                "sites": e["sites"],
                "path": "/" + "/".join(ptr_token(x) for x in p),
                "value": e["value"],
                "units": e["unit"],
                "class": e["class"],
                "why": e["why"],
                "equation": site_info[e["sites"][0]]["equation"],
                "declared_units": site_info[e["sites"][0]]["declared"],
                "applied": bool(rep.get("new_text")),
            }
        )
    return rep


def v_scoped(scoped, comp, name):
    t = scoped.for_component(comp).get(name)
    return t.units if t is not None else None


def apply_edits(text, spans, doc, edits, bump):
    new_doc = copy.deepcopy(doc)
    reps = []
    # A minified file (no newline before its end) gets a minified node.
    compact = "\n" not in text.rstrip("\n")
    sep, colon = (",", ":") if compact else (", ", ": ")

    def const_node(num, unit):
        return f'{{"op"{colon}"const"{sep}"args"{colon}[]{sep}"value"{colon}{num}{sep}"units"{colon}{unit}}}'

    for p, e in edits.items():
        sp = span_at(spans, p)
        unit = json.dumps(e["unit"])
        if e["kind"] == "number":
            num = text[sp.start : sp.end]
            reps.append((sp.start, sp.end, const_node(num, unit)))
            set_at(
                new_doc, p, {"op": "const", "args": [], "value": get_at(doc, p), "units": e["unit"]}
            )
        elif e["kind"] == "fold":
            num = json.dumps(e["value"])
            reps.append((sp.start, sp.end, const_node(num, unit)))
            set_at(new_doc, p, {"op": "const", "args": [], "value": e["value"], "units": e["unit"]})
        else:
            vsp = sp.value["value"]
            reps.append((vsp.end, vsp.end, f'{sep}"units"{colon}{unit}'))
            get_at(new_doc, p)["units"] = e["unit"]
    if bump:
        vsp = spans.value["esm"]
        reps.append((vsp.start, vsp.end, '"1.2.0"'))
        new_doc["esm"] = "1.2.0"
    out = text
    for s, en, r in sorted(reps, reverse=True):
        out = out[:s] + r + out[en:]
    return out, new_doc


def eval_mismatch(doc, new_doc, sites, fixed_sites, base):
    """Sites whose rewritten expressions evaluate differently (where evaluable)."""
    bad = set()
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            a = loaded_sites(EA.load_document(copy.deepcopy(doc), base_path=base))
            b = loaded_sites(EA.load_document(copy.deepcopy(new_doc), base_path=base))
    except Exception:
        return bad
    rng = random.Random(1)
    for s in fixed_sites:
        if s not in a or s not in b:
            continue
        for ea, eb in zip(a[s][2:], b[s][2:]):
            if ea is None:
                continue
            names = {n for n, _ in iter_nodes(ea) if isinstance(n, str)}
            bind = {n: rng.uniform(0.5, 2.0) for n in names}
            bind["t"] = 1.0
            try:
                va = EA.evaluate(ea, bind)
            except Exception:
                continue
            try:
                vb = EA.evaluate(eb, bind)
            except Exception:
                bad.add(s)
                continue
            if not (va == vb or (math.isnan(va) and math.isnan(vb))):
                bad.add(s)
    return bad


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def expand(paths, skips):
    out = []
    for p in paths:
        p = Path(p)
        if p.is_file():
            out.append((str(p), p.parent, os.path.relpath(p)))
            continue
        try:
            listed = subprocess.run(
                ["git", "-C", str(p), "ls-files", "--", "*.esm"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.split("\n")
        except Exception:
            listed = [str(f.relative_to(p)) for f in p.rglob("*.esm")]
        for rel in sorted(x for x in listed if x):
            if any(rel == s or rel.startswith(s.rstrip("/") + "/") for s in skips):
                continue
            if (p / rel).is_symlink():
                # The link's target is a tracked file of its own and is
                # rewritten there; a patch at the link would replace the link.
                continue
            out.append((str(p / rel), p, rel))
    return out


def _init_worker(engine_src):
    if SymbolicValidator.cls is None:
        import_engine(Path(engine_src))
        SymbolicValidator.build()


class _FileTimeout(BaseException):
    """Not an Exception, so no `except Exception` inside the engine swallows it."""

    pass


def _on_alarm(signum, frame):
    raise _FileTimeout()


#: Seconds one file may take; a site with very many candidate literals can
#: make the subset search slow, and one file must not stall a corpus run.
FILE_TIMEOUT = 1800

#: Seconds the declaration search may spend on one file: each candidate is a
#: whole-document validation, which is slow for a large file.
DECLARATION_BUDGET = 300

#: Seconds the literal-subset search may spend on one site.
SITE_BUDGET = 60


def _run_one(item):
    import signal

    path, rel, bump, evaluate = item
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(FILE_TIMEOUT)
    try:
        rep = process_file(path, bump, evaluate=evaluate)
    except _FileTimeout:
        rep = {
            "file": path,
            "rewrites": [],
            "unresolved": [{"site": "(whole file)", "reason": f"timed out after {FILE_TIMEOUT} s"}],
            "notes": [],
            "status": f"timed out after {FILE_TIMEOUT} s; nothing proposed",
        }
    except Exception as exc:
        rep = {
            "file": path,
            "rewrites": [],
            "unresolved": [],
            "notes": [],
            "status": f"codemod crashed: {type(exc).__name__}: {exc}"[:300],
        }
    finally:
        signal.alarm(0)
    rep["rel"] = rel
    return rep


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--patch-dir")
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--skip", action="append", default=[])
    ap.add_argument("--exclude", action="append", default=[], help="exact file path to leave alone")
    ap.add_argument("--bump-version", action="store_true")
    ap.add_argument("--no-eval", action="store_true")
    ap.add_argument("--engine-src", default=str(_DEFAULT_ENGINE))
    ap.add_argument("--json")
    ap.add_argument("--summary")
    ap.add_argument("--title", default="")
    ap.add_argument("--jobs", type=int, default=1, help="worker processes (not with --write)")
    args = ap.parse_args(argv)
    if args.write and args.jobs > 1:
        ap.error("--write runs serially: a file may mount one rewritten before it")

    _init_worker(args.engine_src)
    excluded = {str(Path(x).resolve()) for x in args.exclude}
    todo = [
        (path, rel, args.bump_version, not args.no_eval)
        for path, root, rel in expand(args.paths, args.skip)
        if str(Path(path).resolve()) not in excluded
    ]
    if args.jobs > 1:
        import multiprocessing as mp

        pool = mp.get_context("fork").Pool(args.jobs, _init_worker, (args.engine_src,))
        results = pool.imap_unordered(_run_one, todo)
    else:
        results = map(_run_one, todo)
    reports = []
    for rep in results:
        path, rel = rep["file"], rep["rel"]
        reports.append(rep)
        new_text = rep.pop("new_text", None)
        if not rep.get("warnings_before") and rep.get("status") in ("ok", "skipped: not JSON"):
            continue
        n = len([r for r in rep["rewrites"] if r["applied"]])
        print(
            f"{rel}: {len(rep.get('warnings_before', []))} warning site(s), {n} rewrite(s), "
            f"{len(rep['unresolved'])} unresolved [{rep['status']}]",
            flush=True,
        )
        if new_text is None:
            continue
        if args.write:
            Path(path).write_text(new_text)
        elif args.patch_dir:
            old = Path(path).read_text()
            diff = difflib.unified_diff(
                old.splitlines(keepends=True),
                new_text.splitlines(keepends=True),
                fromfile=f"a/{rel}",
                tofile=f"b/{rel}",
            )
            out = Path(args.patch_dir) / (rel + ".patch")
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text("".join(diff))
    reports.sort(key=lambda r: r["rel"])
    if args.json:
        Path(args.json).write_text(json.dumps(reports, indent=1, default=str))
    if args.summary:
        Path(args.summary).write_text(summary_md(reports, args.title, args))
    return 0


def summary_md(reports, title, args):
    from collections import Counter

    touched = [
        r
        for r in reports
        if any(x["applied"] for x in r["rewrites"]) or (r.get("declarations") and r.get("applied"))
    ]
    decls = [(r["rel"], d) for r in reports for d in r.get("declarations", []) if r.get("applied")]
    decl_open = [(r["rel"], d) for r in reports for d in r.get("declaration_unresolved", [])]
    cls = Counter(x["class"] for r in reports for x in r["rewrites"] if x["applied"])
    warned = [r for r in reports if r.get("warnings_before")]
    unresolved = [(r["rel"], u) for r in reports for u in r["unresolved"]]
    unapplied = [(r["rel"], x) for r in reports for x in r["rewrites"] if not x["applied"]]
    failed = [
        r for r in reports if r["status"] not in ("ok", "needs esm >= 1.2.0", "skipped: not JSON")
    ]
    not_json = [r for r in reports if r["status"] == "skipped: not JSON"]
    lines = [f"# Dimensionless-literal codemod: {title}", ""]
    lines += [
        f"- .esm files scanned: {len(reports)}",
        f"- files with `{WARNING_CODE}` warnings: {len(warned)} "
        f"({sum(len(r['warnings_before']) for r in warned)} warning sites)",
        f"- files with a proposed patch: {len(touched)}"
        + (
            f" (esm bumped to 1.2.0 in {sum(1 for r in touched if r.get('bumped'))})"
            if touched
            else ""
        ),
        f"- rewrites proposed: {sum(cls.values())} — mechanical {cls['mechanical']}, "
        f"suspicious {cls['suspicious']}",
        f"- declaration changes (angle units): {len(decls)}; angle sites with no verified "
        f"declaration change: {len(decl_open)}",
        f"- unresolved sites (no rewrite proposed): {len(unresolved)}",
        f"- files whose own processing failed: {len(failed)}",
        f"- files skipped because they are not JSON (deliberately malformed fixtures): {len(not_json)}",
        "",
        "Verification (per patched file, by the Python binding on the patched text): "
        "validity and the structural-error set are unchanged, every rewritten site is "
        "warning-free, no other site starts warning, the patched JSON equals the "
        "literal->const transform, and the rewritten sites evaluate to the same numbers "
        "where the scalar evaluator can run them. "
        + ("All patched files passed." if touched else "No file was patched."),
        "",
    ]
    lines += ["## Declaration changes (angle units) — review each", ""]
    lines += [
        "A site whose only mismatch is a `rad` factor is repaired by changing one "
        "variable's declared `units`, never by a literal `1/rad`. The equation's "
        "left-hand variable is tried first, then observed variables, then the rest; a "
        "change is kept only if validity is unchanged, the site stops warning and no "
        "other site that uses the variable starts warning or erroring. `rad` has scale "
        "1, so no value changes. Only a unit with some axis besides the angle is "
        "changed (`1/s` -> `rad/s`): a pure number or a pure angle never gains or "
        "loses a `rad`. A Coriolis-type site, where an angular quantity (`rad/s`) "
        "meets a quantity without the angle, is never changed automatically: it is "
        "listed under Unresolved for the model author to decide.",
        "",
        "Each change below says what a model variable IS, which the checker cannot "
        "judge: confirm the new unit is right for the quantity, or reject the change "
        "and repair the model instead.",
        "",
    ]
    if not decls:
        lines += ["None.", ""]
    for rel, d in decls:
        lines += [
            f"- `{rel}` {d['component']}: `{d['variable']}` units `{d['before']}` -> "
            f"`{d['after']}` (fixes {', '.join(d['sites_fixed'])})",
            f"  - equation: `{d['equation']}`",
        ]
    if decl_open:
        lines += [
            "",
            "Angle sites where no single declaration change verified (left as they are):",
            "",
        ]
        for rel, d in decl_open:
            lines += [
                f"- `{rel}` {d['site']}: `{d['equation']}`",
                "  - tried: " + "; ".join(d["tried"]),
            ]
    lines += [""]
    if any(r.get("bumped") for r in touched):
        lines += ["## esm version bumps (1.2.0 is the first version with unit-bearing `const`)", ""]
        lines += [
            f"- `{r['rel']}`: {r.get('esm')} -> 1.2.0" for r in touched if r.get("bumped")
        ] + [""]
    sus = [
        (r["rel"], x)
        for r in reports
        for x in r["rewrites"]
        if x["class"] == "suspicious" and x["applied"]
    ]
    rank = {w: i for i, w in enumerate(ODD_REASONS)}
    sus.sort(key=lambda rx: rank.get(rx[1]["why"].split(";")[0], len(rank)))
    odd = sum(1 for _, x in sus if x["why"].split(";")[0] in rank)
    lines += [
        "## Suspicious rewrites (possible model bugs — review each)",
        "",
        f"{odd} have an odd unit (an axis nothing at the site declares, or a fractional or "
        f"large exponent) and are listed first; the other {len(sus) - odd} are dimensional "
        "coefficients whose unit is declared nowhere at the site (an empirical fit or a rate "
        "constant written as a bare number — or a missing variable, as in "
        "`H [m/s] = 1.4 * phi [m]`).",
        "",
    ]
    if not sus:
        lines += ["None.", ""]
    for rel, x in sus:
        lines += [
            f'- `{rel}` {", ".join(x["sites"])}: literal `{x["value"]}` -> `const({x["value"]}, units "{x["units"]}")` '
            f"— {x['why']}",
            f"  - equation: `{x['equation']}`",
            f"  - declared units: {', '.join(f'{k} [{v}]' for k, v in x['declared_units'].items()) or '(none)'}",
        ]
    lines += ["", "## Unresolved sites (no rewrite proposed)", ""]
    if not unresolved:
        lines += ["None.", ""]
    for rel, u in unresolved:
        lines.append(f"- `{rel}` {u['site']}: {u['reason']}")
        if u.get("equation"):
            lines.append(f"  - equation: `{u['equation']}`")
        if u.get("declared_units"):
            lines.append(
                "  - declared units: "
                + ", ".join(f"{k} [{v}]" for k, v in u["declared_units"].items())
            )
        for a in u.get("alternatives", []):
            lines.append(f"  - could be: {a}")
    if unapplied:
        lines += ["", "## Proposals not applied (file declares esm < 1.2.0)", ""]
        for rel, x in unapplied:
            lines.append(
                f'- `{rel}` {", ".join(x["sites"])}: `{x["value"]}` -> units "{x["units"]}" ({x["class"]})'
            )
    if failed:
        lines += ["", "## Files the codemod could not process", ""]
        lines += [f"- `{r['rel']}`: {r['status']}" for r in failed]
    lines += ["", "## Mechanical rewrites", ""]
    for r in reports:
        for x in r["rewrites"]:
            if x["class"] == "mechanical" and x["applied"]:
                lines.append(
                    f'- `{r["rel"]}` {", ".join(x["sites"])}: `{x["value"]}` -> "{x["units"]}" ({x["why"]})'
                )
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    sys.exit(main())
