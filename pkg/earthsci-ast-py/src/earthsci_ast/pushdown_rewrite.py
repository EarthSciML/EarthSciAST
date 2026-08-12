"""Automatic projection-pushdown desugar — the Python port of the Julia
reference (``pkg/EarthSciAST.jl/src/pushdown_rewrite.jl``, current as of the
Phase-1 clean consolidation: idempotency guard + record/gate helpers).

A pre-build model-transform pass that recognises the ISRM-shaped
``+``-semiring "apply a provider-backed full-domain array to a sparsely
supported binned factor" pattern in a CLEAN model and AUTO-GENERATES the four
hand-authored constructs (derived IndexSet + ``distinct`` producer +
``member_factor`` + ``gated_select`` record) so the existing value-invention /
gated-provider pipeline runs unchanged. The author writes NO derived set, NO
producer, and NO gated_select — only the natural math.

This is a NARROW desugarer (a pattern recogniser), NOT a general optimizer.
It fires ONLY when the reduction's semiring is the additive ``(+, 0)`` monoid;
a ``max_product`` / ``min_sum`` / etc. aggregate of the SAME shape is left
untouched (the soundness guard).

DESIGN DECISION (raw-dict path): unlike the Julia implementation — which
type-parses the document for *detection* and mutates the raw dict for
*emission* — this port both detects and emits on the RAW document dict. The
Python typed parser drops unknown top-level ``metadata`` keys
(``parse._parse_metadata`` fills only fixed keys), so the rewrite's provenance
record ``metadata.x_esd.pushdown`` would not survive a typed round-trip;
keeping the whole pass (and every record consumer: ``_pushdown_record``,
``_pushdown_provider_gates``) on the raw-dict side means the record never
needs to. ``prepare`` therefore runs the rewrite BEFORE ``parse.load`` and
derives the provider gates from the raw rewritten document — the typed
pipeline downstream only ever sees the generated *constructs* (index set,
producer equation, member variables), which the parser preserves.

Output parity with Julia is pinned by the shared conformance corpus
(``tests/conformance/pushdown/``): for each committed input the rewritten
document must deep-equal the Julia-emitted golden (see the corpus README for
the comparison contract).
"""

from __future__ import annotations

import copy
import math
from typing import Any

__all__ = [
    "desugar_pushdown",
    "PushdownRewriteError",
    "parse_select_axis",
    "parse_select_axes",
]


class PushdownRewriteError(Exception):
    """A malformed gate/record encountered while deriving provider gates
    (mirrors the Julia ``RefreshError`` sites in pushdown_rewrite.jl)."""


# --------------------------------------------------------------------------- #
# The per-axis loader-selection vocabulary (esm-spec §8.9.2, CONFORMANCE_SPEC
# §5.5). ONE parser, because the same four selectors are written in three
# places — a loader's ``select``, a variable's ``select``, and the pushdown
# record's gate template — and the spelling an author writes must be the
# spelling the rewrite generates.
# --------------------------------------------------------------------------- #


def parse_select_axis(ctx: str, ax: Any, gated_by_override: str | None = None) -> Any:
    """Parse one axis selector into its canonical form.

    Returns ``"all"``, ``{"fixed": i}``, ``{"range": {"start", "stop", "step"}}``
    or ``{"gated_by": name}``. ``ctx`` names the declaring site for the error
    message; ``gated_by_override``, when given, replaces the declared set name —
    the pushdown path substitutes its GENERATED set name into a loader's
    authored ``{"gated_by": …}`` slot.

    An unrecognised selector is an ERROR, never a silently-widened ``"all"``: a
    mis-spelled selector that reads the whole axis surfaces much later, as an
    array of the wrong length or a fetch of the whole store.
    """

    def bad(detail: str) -> PushdownRewriteError:
        return PushdownRewriteError(f"{ctx}: {detail}")

    if ax is None or ax == "all":
        return "all"
    if not isinstance(ax, dict):
        raise bad(
            f"unrecognised axis selector {ax!r}; expected \"all\", {{'fixed': i}}, "
            "{'range': {'start': s, 'stop': e}} or {'gated_by': '<set>'}"
        )
    if "gated_by" in ax:
        if gated_by_override is not None:
            return {"gated_by": str(gated_by_override)}
        name = ax["gated_by"]
        if not isinstance(name, str):
            raise bad('"gated_by" must name a derived index set')
        return {"gated_by": name}
    if "fixed" in ax:
        fx = ax["fixed"]
        fx = fx[0] if isinstance(fx, (list, tuple)) and fx else fx
        if not isinstance(fx, int) or isinstance(fx, bool) or fx < 0:
            raise bad('"fixed" must be a non-negative integer index')
        return {"fixed": int(fx)}
    if "range" in ax:
        r = ax["range"]
        if not isinstance(r, dict):
            raise bad('"range" must be an object {start, stop, step?}')
        bounds: dict[str, int] = {}
        for name, dflt in (("start", 0), ("stop", None), ("step", 1)):
            v = r.get(name, dflt)
            if name == "stop" and v is None:
                raise bad('"range" needs an integer "stop"')
            if not isinstance(v, int) or isinstance(v, bool) or v < 0:
                raise bad(f'"range.{name}" must be a non-negative integer, got {v!r}')
            bounds[name] = int(v)
        if bounds["step"] == 0:
            raise bad('"range.step" must be >= 1')
        if bounds["stop"] < bounds["start"]:
            raise bad(
                f'"range" is empty: stop {bounds["stop"]} precedes start {bounds["start"]}'
            )
        return {"range": bounds}
    raise bad(
        f"unrecognised axis selector keys {sorted(map(str, ax))}; expected one of "
        "fixed, range, gated_by"
    )


def parse_select_axes(
    ctx: str, axes: Any, gated_by_override: str | None = None
) -> list[Any]:
    """Parse a whole ``axes`` array of the selector vocabulary
    (:func:`parse_select_axis`)."""
    if not isinstance(axes, (list, tuple)):
        raise PushdownRewriteError(f'{ctx}: needs an "axes" array')
    return [parse_select_axis(ctx, ax, gated_by_override) for ax in axes]


# --------------------------------------------------------------------------- #
# Record / model-selection helpers
# --------------------------------------------------------------------------- #


def _pushdown_record(doc: Any) -> dict | None:
    """The rewrite's provenance record ``metadata.x_esd.pushdown`` (written by
    :func:`desugar_pushdown`), or ``None`` when ``doc`` carries none. This is
    the record the engine reads BACK to derive provider gates."""
    if not isinstance(doc, dict):
        return None
    md = doc.get("metadata")
    if not isinstance(md, dict):
        return None
    xe = md.get("x_esd")
    if not isinstance(xe, dict):
        return None
    rec = xe.get("pushdown")
    return rec if isinstance(rec, dict) else None


def _pd_model_name(doc: dict, model_name: str | None) -> str | None:
    if model_name is not None:
        return str(model_name)
    models = doc.get("models")
    if isinstance(models, dict) and len(models) == 1:
        return str(next(iter(models)))
    return None


# --------------------------------------------------------------------------- #
# Raw-AST leaf helpers (the Julia typed-IR helpers, on raw dicts)
# --------------------------------------------------------------------------- #


def _pd_varname(e: Any) -> str | None:
    return e if isinstance(e, str) else None


def _pd_index_split(e: Any) -> tuple[str, str] | None:
    """``index(F, sym)`` with EXACTLY one index → ``(F, sym)``; else None."""
    if not (isinstance(e, dict) and e.get("op") == "index"):
        return None
    a = e.get("args")
    if not (isinstance(a, list) and len(a) == 2):
        return None
    f, s = _pd_varname(a[0]), _pd_varname(a[1])
    if f is None or s is None:
        return None
    return (f, s)


def _pd_index_syms(e: Any) -> tuple[str, list[str]] | None:
    """``index(F, sym…)`` with ≥1 index → ``(F, [syms…])``; else None."""
    if not (isinstance(e, dict) and e.get("op") == "index"):
        return None
    a = e.get("args")
    if not (isinstance(a, list) and len(a) >= 2):
        return None
    f = _pd_varname(a[0])
    if f is None:
        return None
    syms: list[str] = []
    for x in a[1:]:
        s = _pd_varname(x)
        if s is None:
            return None
        syms.append(s)
    return (f, syms)


def _pd_matvec_factors(
    body: Any, c_sym: str, out_syms: list[str]
) -> tuple[str, str] | None:
    """Classify an aggregate BODY ``A[c, out…] · E[c]`` — a two-factor ``⊗=·``
    product of a rank-(1+|out|) array factor ``A`` subscripted ``[c, out…]``
    and a rank-1 factor ``E`` subscripted ``[c]`` — into ``(Aname, Ename)``,
    or ``None`` when ``body`` is not that exact shape. PURE STRUCTURAL check
    on index symbols (the caller applies the semiring guard)."""
    if not (isinstance(body, dict) and body.get("op") == "*"):
        return None
    args = body.get("args")
    if not (isinstance(args, list) and len(args) == 2) or not out_syms:
        return None
    parts = [_pd_index_syms(a) for a in args]
    if any(p is None for p in parts):
        return None
    a_syms = [str(c_sym)] + [str(s) for s in out_syms]
    e_syms = [str(c_sym)]
    aname = ename = None
    for f, syms in parts:  # type: ignore[misc]
        if syms == a_syms:
            aname = f
        elif syms == e_syms:
            ename = f
    if aname is None or ename is None:
        return None
    return (aname, ename)


# (⊕ spelling, 0̄) — mirrors the Julia `_aggregate_oplus_identity` used by the
# semiring guard; only the ("+", 0.0) comparison matters to this pass.
_SEMIRING_OPLUS = {
    "sum_product": ("+", 0.0),
    "max_product": ("max", -math.inf),
    "min_sum": ("min", math.inf),
    "max_sum": ("max", -math.inf),
    "bool_and_or": ("or", 0.0),
}
_OPLUS_IDENTITY = {"+": 0.0, "max": -math.inf, "min": math.inf, "*": 1.0, "or": 0.0}


def _pd_oplus(agg: dict) -> tuple[str, float] | None:
    semiring = agg.get("semiring")
    if semiring is not None:
        return _SEMIRING_OPLUS.get(str(semiring))
    r = agg.get("reduce")
    r = "+" if r is None else str(r)
    if r not in _OPLUS_IDENTITY:
        return None
    return (r, _OPLUS_IDENTITY[r])


def _is_aggregate_op(op: Any) -> bool:
    return op in ("aggregate", "arrayop")


def _pd_flip(op: str) -> str:
    return {"<": ">", "<=": ">=", ">": "<"}.get(op, "<=")


def _pd_find_ifelse_cond(e: Any) -> Any:
    """Condition of the first ``ifelse(cond, then, else)`` in a raw subtree."""
    if isinstance(e, dict):
        if e.get("op") == "ifelse":
            a = e.get("args")
            if isinstance(a, list) and len(a) == 3:
                return a[0]
        for v in e.values():
            r = _pd_find_ifelse_cond(v)
            if r is not None:
                return r
    elif isinstance(e, list):
        for x in e:
            r = _pd_find_ifelse_cond(x)
            if r is not None:
                return r
    return None


def _pd_parse_containment(pred: Any, c_sym: str, r_sym: str):
    """Parse a rectangle-containment predicate — an ``and``/``*`` of
    comparisons, each between a CELL-indexed rect factor and a RECORD-indexed
    point factor — into the overlap-gate envelopes ``(src_env=[Px,Py],
    tgt_env=[xmin,ymin,xmax,ymax])``; ``None`` unless exactly two point
    coordinates each carry BOTH a min and a max cell bound."""
    if not isinstance(pred, dict):
        return None
    comps = pred.get("args") if pred.get("op") in ("and", "*") else [pred]
    if not isinstance(comps, list):
        return None
    bounds: dict[str, dict[str, str]] = {}
    point_order: list[str] = []
    for cmp_ in comps:
        if not (
            isinstance(cmp_, dict)
            and cmp_.get("op") in ("<", "<=", ">", ">=")
            and isinstance(cmp_.get("args"), list)
            and len(cmp_["args"]) == 2
        ):
            return None
        s1 = _pd_index_split(cmp_["args"][0])
        s2 = _pd_index_split(cmp_["args"][1])
        if s1 is None or s2 is None:
            return None
        (f1, sym1), (f2, sym2) = s1, s2
        if sym1 == c_sym and sym2 == r_sym:
            fc, fp, cell_on_left = f1, f2, True
        elif sym1 == r_sym and sym2 == c_sym:
            fc, fp, cell_on_left = f2, f1, False
        else:
            return None
        opn = cmp_["op"] if cell_on_left else _pd_flip(cmp_["op"])
        kind = "min" if opn in ("<", "<=") else "max"
        if fp not in bounds:
            point_order.append(fp)
            bounds[fp] = {}
        bounds[fp][kind] = fc
    if len(point_order) != 2:
        return None
    px, py = point_order
    for p in (px, py):
        if "min" not in bounds[p] or "max" not in bounds[p]:
            return None
    return {
        "src_env": [px, py],
        "tgt_env": [bounds[px]["min"], bounds[py]["min"], bounds[px]["max"], bounds[py]["max"]],
    }


def _ranges_of(agg: dict) -> dict:
    r = agg.get("ranges")
    return r if isinstance(r, dict) else {}


def _range_from(v: Any) -> str | None:
    if isinstance(v, dict) and isinstance(v.get("from"), str):
        return v["from"]
    return None


def _pd_detect_binning(ev: Any, c_set: str):
    """Is ``ev`` a binning aggregate ``E[c] = Σ_r [contains(cell_c, pt_r)]·…``
    over cell set ``c_set``? Returns the binding dict or ``None``."""
    if not (isinstance(ev, dict) and ev.get("type") == "observed"):
        return None
    shape = ev.get("shape")
    if not (isinstance(shape, list) and len(shape) == 1 and shape[0] == c_set):
        return None
    agg = ev.get("expression")
    if not (isinstance(agg, dict) and _is_aggregate_op(agg.get("op"))):
        return None
    oz = _pd_oplus(agg)
    if oz is None or oz != ("+", 0.0):  # SEMIRING GUARD
        return None
    oi = agg.get("output_idx")
    if not (isinstance(oi, list) and len(oi) == 1 and isinstance(oi[0], str)):
        return None
    c_sym = oi[0]
    ranges = _ranges_of(agg)
    if len(ranges) != 2 or _range_from(ranges.get(c_sym)) != c_set:
        return None
    r_sym = next((k for k in ranges if k != c_sym), None)
    if r_sym is None or _range_from(ranges[r_sym]) is None:
        return None
    body = agg.get("expr")
    if not isinstance(body, dict):
        return None
    pred = _pd_find_ifelse_cond(body)
    if pred is None:
        return None
    env = _pd_parse_containment(pred, c_sym, r_sym)
    if env is None:
        return None
    return {
        "c_sym": c_sym,
        "r_sym": r_sym,
        "R": _range_from(ranges[r_sym]),
        "src_env": env["src_env"],
        "tgt_env": env["tgt_env"],
    }


def _pd_detect(model: dict, index_sets: Any):
    """Detect the pushdown pattern across a model's observeds. Returns a plan
    dict, or ``None`` when nothing matches / the semiring guard fails."""
    variables = model.get("variables")
    if not isinstance(variables, dict):
        return None
    conc_specs: list[tuple[str, str]] = []
    a_names: list[str] = []
    e_specs: list[tuple[str, str]] = []
    C = rcv_set = R = None
    src_env = tgt_env = None
    rep_ename = rep_csym = rep_rsym = None

    for cname, cv in variables.items():
        if not (isinstance(cv, dict) and cv.get("type") == "observed"):
            continue
        agg = cv.get("expression")
        if not (isinstance(agg, dict) and _is_aggregate_op(agg.get("op"))):
            continue
        oz = _pd_oplus(agg)
        if oz is None or oz != ("+", 0.0):  # SEMIRING GUARD
            continue
        oi = agg.get("output_idx")
        if not (isinstance(oi, list) and len(oi) == 1 and isinstance(oi[0], str)):
            continue
        rcv_sym = oi[0]
        ranges = _ranges_of(agg)
        if len(ranges) != 2 or rcv_sym not in ranges:
            continue
        s_sym = next((k for k in ranges if k != rcv_sym), None)
        if s_sym is None:
            continue
        c_set = _range_from(ranges[s_sym])
        r_set = _range_from(ranges[rcv_sym])
        if c_set is None or r_set is None:
            continue
        facs = _pd_matvec_factors(agg.get("expr"), s_sym, [rcv_sym])
        if facs is None:
            continue
        aname, ename = facs
        av = variables.get(aname)
        if not (
            isinstance(av, dict)
            and av.get("type") == "parameter"
            and isinstance(av.get("shape"), list)
            and len(av["shape"]) == 2
            and av["shape"][0] == c_set
            and av["shape"][1] == r_set
        ):
            continue
        ev = variables.get(ename)
        if ev is None:
            continue
        bind = _pd_detect_binning(ev, c_set)
        if bind is None:
            continue

        if C is None:
            C, rcv_set, R = c_set, r_set, bind["R"]
            src_env, tgt_env = bind["src_env"], bind["tgt_env"]
            rep_ename, rep_csym, rep_rsym = ename, bind["c_sym"], bind["r_sym"]
        elif not (c_set == C and r_set == rcv_set):  # narrow: one cell set
            continue
        conc_specs.append((cname, s_sym))
        if aname not in a_names:
            a_names.append(aname)
        if not any(e[0] == ename for e in e_specs):
            e_specs.append((ename, bind["c_sym"]))
    if not conc_specs:
        return None
    # Deterministic plan order (mirrors the Julia `sort!(A_names)`): the one
    # collection-order-dependent list that leaks into the emitted document
    # (`gated_select.applies_to`) is sorted so all bindings agree.
    a_names.sort()
    return {
        "C": C,
        "rcv_set": rcv_set,
        "R": R,
        "conc_specs": conc_specs,
        "A_names": a_names,
        "E_specs": e_specs,
        "src_env": src_env,
        "tgt_env": tgt_env,
        "rep_ename": rep_ename,
        "rep_csym": rep_csym,
        "rep_rsym": rep_rsym,
    }


# --------------------------------------------------------------------------- #
# Emission
# --------------------------------------------------------------------------- #


def _pd_rewrite_rects(node: Any, rectmap: dict[str, str]) -> Any:
    """In-place: rewrite every ``index(F, …)`` whose factor ``F`` is a key of
    ``rectmap`` to ``index(rectmap[F], …)`` throughout a raw AST subtree."""
    if isinstance(node, dict):
        if node.get("op") == "index":
            a = node.get("args")
            if isinstance(a, list) and a and isinstance(a[0], str) and a[0] in rectmap:
                a[0] = rectmap[a[0]]
        for v in node.values():
            _pd_rewrite_rects(v, rectmap)
    elif isinstance(node, list):
        for x in node:
            _pd_rewrite_rects(x, rectmap)
    return node


def _pd_ix(f: Any, *idx: Any) -> dict:
    return {"op": "index", "args": [f, *idx]}


def _pd_apply(esm: dict, mname: str, plan: dict) -> dict:
    d = copy.deepcopy(esm)  # fresh, mutable
    C = plan["C"]
    setname = "pd_support__" + C
    faqid = "pd_faq__" + C
    memvar = "pd_members__" + C
    mfactor = "pd_member_factor__" + C

    def cellgath(f: str) -> str:
        return "pd_cell__" + C + "__" + f

    rects: list[str] = []
    for f in plan["tgt_env"]:
        if f not in rects:
            rects.append(f)
    rectmap = {f: cellgath(f) for f in rects}

    # --- derived index set ---
    d.setdefault("index_sets", {})[setname] = {
        "kind": "derived",
        "from_faq": faqid,
        "member_factor": mfactor,
    }

    mv = d["models"][mname]["variables"]

    # --- producer filter comparisons, deep-copied from the representative E
    #     BEFORE E is rewritten (they must keep full-grid rect factor refs) ---
    repexpr = mv[plan["rep_ename"]]["expression"]
    ifcond = _pd_find_ifelse_cond(repexpr.get("expr"))
    if ifcond is None:
        raise PushdownRewriteError(
            "pushdown desugar: representative E lost its containment ifelse"
        )
    comps = ifcond["args"] if ifcond.get("op") in ("and", "*") else [ifcond]
    prod_filter = {"op": "*", "args": [copy.deepcopy(c) for c in comps]}

    # --- member state var + member_factor param ---
    mv[memvar] = {"type": "state", "shape": [setname]}
    mv[mfactor] = {"type": "parameter", "default": 0.0, "shape": [setname]}

    # --- per-rect cell-gather observeds ---
    for f in rects:
        mv[cellgath(f)] = {
            "type": "observed",
            "shape": [setname],
            "expression": {
                "op": "aggregate",
                "output_idx": ["c"],
                "ranges": {"c": {"from": setname}},
                "args": [f, mfactor],
                "expr": _pd_ix(f, _pd_ix(mfactor, "c")),
            },
        }

    # --- gate the provider-backed arrays onto the derived axis ---
    for a in plan["A_names"]:
        mv[a]["shape"] = [setname, plan["rcv_set"]]

    # --- rewrite E: axis → derived set, rect factors → cell gathers ---
    for ename, csym in plan["E_specs"]:
        expr = mv[ename]["expression"]
        expr["ranges"][csym]["from"] = setname
        _pd_rewrite_rects(expr, rectmap)
        if "args" in expr:
            expr["args"] = [rectmap.get(str(s), s) for s in expr["args"]]
        mv[ename]["shape"] = [setname]

    # --- restrict the conc reductions to the derived axis ---
    for cname, ssym in plan["conc_specs"]:
        mv[cname]["expression"]["ranges"][ssym]["from"] = setname

    # --- generated `distinct` producer (reuses E's containment + geometry) ---
    prod_args: list[str] = []
    for s in list(plan["src_env"]) + list(plan["tgt_env"]):
        if s not in prod_args:
            prod_args.append(s)
    producer = {
        "lhs": _pd_ix(memvar, "m"),
        "rhs": {
            "op": "aggregate",
            "output_idx": ["m"],
            "ranges": {
                plan["rep_rsym"]: {"from": plan["R"]},
                plan["rep_csym"]: {"from": C},
            },
            "expr": {"op": "true", "args": []},
            "distinct": True,
            "semiring": "bool_and_or",
            "id": faqid,
            "join": [
                {
                    "overlap": {
                        "src_env": list(plan["src_env"]),
                        "tgt_env": list(plan["tgt_env"]),
                        "eps": 0.0,
                    }
                }
            ],
            "filter": prod_filter,
            "key": {"op": "skolem", "label": "cell", "args": [plan["rep_csym"]]},
            "args": prod_args,
        },
    }
    eqs = d["models"][mname].get("equations")
    if not isinstance(eqs, list):
        eqs = []
        d["models"][mname]["equations"] = eqs
    eqs.append(producer)

    # --- inspectable pushdown provenance / gated_select record ---
    md = d.setdefault("metadata", {})
    xesd = md.setdefault("x_esd", {})
    xesd["pushdown"] = {
        "derived_set": setname,
        "producer_id": faqid,
        "member_factor": mfactor,
        "member_var": memvar,
        "gated_select": {
            "gated_by": setname,
            "applies_to": list(plan["A_names"]),
            "gated_axis": 0,
        },
    }
    return d


def desugar_pushdown(esm: dict, model_name: str | None = None) -> dict:
    """Recognise the projection-pushdown pattern in ``esm``'s named model and,
    when it matches, return a NEW document with the four constructs desugared
    in (a ``kind:"derived"`` index set, a ``distinct:true`` overlap-gated
    producer aggregate, a ``member_factor`` const parameter, and an
    inspectable ``gated_select`` record) plus the reduction axis of the
    matched E / A / conc nodes re-pointed onto the generated derived set.
    Returns ``esm`` UNCHANGED (the same object) when no model is selected, the
    pattern does not match, or the reduction's semiring is not the additive
    ``(+, 0)`` monoid (the soundness guard).

    IDEMPOTENT: a document already carrying the provenance record
    ``metadata.x_esd.pushdown`` is returned unchanged — the generated
    constructs would otherwise re-match and stack a second
    ``pd_support__pd_support__…`` layer."""
    if not isinstance(esm, dict) or _pushdown_record(esm) is not None:
        return esm
    models = esm.get("models")
    if not isinstance(models, dict):
        return esm
    mname = _pd_model_name(esm, model_name)
    if mname is None or mname not in models:
        return esm
    m = models[mname]
    if not isinstance(m, dict):
        return esm
    plan = _pd_detect(m, esm.get("index_sets"))
    if plan is None:
        return esm
    return _pd_apply(esm, mname, plan)


# --------------------------------------------------------------------------- #
# RECORD-DERIVED PROVIDER GATING (the Julia Phase-1 helpers, raw-dict side).
# --------------------------------------------------------------------------- #


def _pushdown_coupling_pairs(doc: dict) -> list[tuple[str, str]]:
    """The coupling ``variable_map`` (from, to) pairs of a raw document."""
    out: list[tuple[str, str]] = []
    cp = doc.get("coupling")
    if not isinstance(cp, list):
        return out
    for c in cp:
        if not (isinstance(c, dict) and c.get("type") == "variable_map"):
            continue
        frm, to = str(c.get("from", "")), str(c.get("to", ""))
        if frm and to:
            out.append((frm, to))
    return out


def _pushdown_gated_rank(doc: dict, applies: list[str]) -> int:
    """Rank of the (rewritten) gated model arrays — the fallback native rank
    when a loader declares no axes template (2 for the ISRM shape; read from
    the document rather than hard-coded)."""
    models = doc.get("models")
    if isinstance(models, dict):
        for m in models.values():
            if not isinstance(m, dict):
                continue
            mv = m.get("variables")
            if not isinstance(mv, dict):
                continue
            for a in applies:
                v = mv.get(a)
                if isinstance(v, dict):
                    shp = v.get("shape")
                    if isinstance(shp, list) and shp:
                        return len(shp)
    return 2


def _pushdown_gate_axes(
    doc: dict, loader: str, gset: str, gaxis: int, mrank: int
) -> list[Any]:
    """Per-NATIVE-axis gate ``axes`` for ``loader``: the loader's declared
    ``metadata.x_esd.gated_select.axes`` template with the GENERATED set name
    substituted into its ``gated_by`` slot (validated against the record's
    ``gated_axis``); else a rank-``mrank`` all-axes gate with ``gated_by`` at
    ``gaxis``."""
    tpl = None
    loaders = doc.get("data_loaders")
    if isinstance(loaders, dict):
        ld = loaders.get(str(loader))
        if isinstance(ld, dict):
            md = ld.get("metadata")
            xe = md.get("x_esd") if isinstance(md, dict) else None
            gsel = xe.get("gated_select") if isinstance(xe, dict) else None
            if isinstance(gsel, dict):
                tpl = gsel.get("axes")
    if isinstance(tpl, list):
        # Through the SAME parser a loader's own `select` goes through, so the
        # authored template and a document-declared selection are one vocabulary
        # (CONFORMANCE_SPEC §5.5) — and an unrecognised selector here is an
        # error rather than a silently-widened whole axis.
        axes = parse_select_axes(
            f"data_loaders.{loader} gated_select template", tpl, gated_by_override=gset
        )
        nonfixed = 0
        gpos = -1
        for ax in axes:
            if isinstance(ax, dict) and "fixed" in ax:
                continue
            if isinstance(ax, dict) and "gated_by" in ax:
                gpos = nonfixed
            nonfixed += 1
        if gpos != gaxis:
            raise PushdownRewriteError(
                f"data_loaders.{loader} gated_select template puts the gated axis "
                f"at non-fixed position {gpos}, but the rewrite record gates model "
                f"axis {gaxis} — the loader template and the rewritten arrays disagree"
            )
        return axes
    if not (0 <= gaxis < mrank):
        raise PushdownRewriteError(
            f"rewrite record gated_axis {gaxis} out of range for rank-{mrank} gated arrays"
        )
    axes = ["all"] * mrank
    axes[gaxis] = {"gated_by": str(gset)}
    return axes


def _pushdown_provider_gates(doc: dict, providers: Any) -> dict[str, dict]:
    """Provider-key ⇒ engine gate, derived from ``doc``'s rewrite record
    (``metadata.x_esd.pushdown.gated_select``).

    A provider is GATED when its key names a ``data_loaders`` variable
    (``"<Loader>"`` or ``"<Loader>.<var>"``) that a coupling ``variable_map``
    routes onto one of the record's ``applies_to`` model arrays. The gate's
    per-NATIVE-axis ``axes`` come from the loader's own
    ``metadata.x_esd.gated_select.axes`` template when it declares one (with
    the record's GENERATED set name substituted), else from the model array's
    rank with ``gated_by`` at the record's ``gated_axis``. ``applies_to``
    carries the LOADER-variable tails. Empty when ``doc`` carries no record,
    no coupling routes a provider onto a gated array, or ``providers`` is
    ``None``."""
    gates: dict[str, dict] = {}
    if providers is None:
        return gates
    rec = _pushdown_record(doc)
    if rec is None:
        return gates
    gs = rec.get("gated_select")
    if not isinstance(gs, dict):
        return gates
    applies = [str(a) for a in (gs.get("applies_to") or [])]
    gset = str(gs.get("gated_by", ""))
    gaxis = int(gs.get("gated_axis", 0))
    if not applies or not gset:
        return gates

    # coupling: "<Loader>.<var>" => the gated model array's LOCAL (tail) name.
    fed: dict[str, str] = {}
    for frm, to in _pushdown_coupling_pairs(doc):
        if "." not in frm:
            continue
        if to.rsplit(".", 1)[-1] in applies:
            fed[frm] = to
    if not fed:
        return gates

    mrank = _pushdown_gated_rank(doc, applies)
    for k0 in providers:
        k = str(k0)
        if k in fed:  # "<Loader>.<var>" provider
            loader, tail = k.split(".", 1)
            lvars = [tail]
        else:  # whole-loader provider?
            loader = k
            lvars = sorted(
                f.split(".", 1)[1] for f in fed if f.split(".", 1)[0] == k
            )
            if not lvars:
                continue
        axes = _pushdown_gate_axes(doc, loader, gset, gaxis, mrank)
        gates[k] = {"axes": axes, "applies_to": list(lvars)}
    return gates


def _inject_pushdown_aliases(
    dst: dict[str, Any], run_doc_variables: list[str], coupling_pairs: list[tuple[str, str]]
) -> dict[str, Any]:
    """Alias-key injection for the ``prepare`` pushdown path (same-object
    references, no copies): surface each array under (a) the coupling ``to``
    name for every ``variable_map`` ``from`` key present, and (b) every
    flattened model-variable name whose final dotted segment matches a bare
    key. Existing keys are never overwritten."""
    for frm, to in coupling_pairs:
        if frm in dst and to not in dst:
            dst[to] = dst[frm]
    for k in list(dst.keys()):
        if "." in k:
            continue
        for v in run_doc_variables:
            if "." in v and v.rsplit(".", 1)[-1] == k and v not in dst:
                dst[v] = dst[k]
    return dst
