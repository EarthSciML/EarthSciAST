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
import warnings
from typing import Any

from .error_handling import TEMPLATE_BODY_REFERENCES_PUSHDOWN_REWRITTEN_VARIABLE
from .json_walk import APPLY_OP, ExpressionTemplateError

__all__ = [
    "desugar_pushdown",
    "pushdown_diagnostics",
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


def _pd_detect_binning(ev: Any, out_set: str):
    """Is ``ev`` a BINNING aggregate — a ``+``-semiring reduction over TWO 1-D
    index sets whose body carries a rectangle-containment predicate between a
    CELL-indexed rect factor and a RECORD-indexed point factor? BOTH
    orientations are recognised (CONFORMANCE_SPEC §5.5.7):

    * FORWARD ``E[c] = Σ_r [contains(cell_c, pt_r)]·…``  (cell axis is output)
    * MIRROR  ``P[r] = Σ_c [contains(cell_c, pt_r)]·…``  (record axis is output)

    The gate is IDENTICAL either way — the enumeration driver binds its two
    symbols from the clause's declared envelopes and knows nothing about cells
    vs records, and the aggregate's own ``output_idx`` decides the result's
    orientation. So the guards here are on the aggregate's SHAPE, not on which
    axis is which: ``out_set`` is the index set the observed is shaped on, the
    single other range supplies the opposite side, and the CONTAINMENT
    PREDICATE itself says which symbol is the cell (it carries the four rect
    BOUND factors) and which is the record (the two point coordinates).

    Returns the binding dict — ``c_sym``, ``r_sym``, ``C``, ``R``,
    ``out_is_cell``, ``src_env``, ``tgt_env`` — or ``None``.
    """
    if not (isinstance(ev, dict) and ev.get("type") == "observed"):
        return None
    shape = ev.get("shape")
    if not (isinstance(shape, list) and len(shape) == 1 and shape[0] == out_set):
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
    out_sym = oi[0]
    ranges = _ranges_of(agg)
    if len(ranges) != 2 or _range_from(ranges.get(out_sym)) != out_set:
        return None
    in_sym = next((k for k in ranges if k != out_sym), None)
    if in_sym is None:
        return None
    in_set = _range_from(ranges[in_sym])
    if in_set is None:
        return None
    body = agg.get("expr")
    if not isinstance(body, dict):
        return None
    pred = _pd_find_ifelse_cond(body)
    if pred is None:
        return None
    # Exactly one of the two assignments parses: `_pd_parse_containment` demands
    # each comparison put the cell symbol on one side and the record symbol on
    # the other, and that the record side yield exactly two coordinates each
    # with a min AND a max cell bound.
    env = _pd_parse_containment(pred, out_sym, in_sym)
    if env is not None:
        return {
            "c_sym": out_sym,
            "r_sym": in_sym,
            "C": out_set,
            "R": in_set,
            "out_is_cell": True,
            "src_env": env["src_env"],
            "tgt_env": env["tgt_env"],
        }
    env = _pd_parse_containment(pred, in_sym, out_sym)
    if env is None:
        return None
    return {
        "c_sym": in_sym,
        "r_sym": out_sym,
        "C": in_set,
        "R": out_set,
        "out_is_cell": False,
        "src_env": env["src_env"],
        "tgt_env": env["tgt_env"],
    }


# --------------------------------------------------------------------------- #
# Detection-time template-reference expansion (esm-spec §9.6.4 rule 2).
#
# Under Option B (§9.6.4) ``load`` PRESERVES ``apply_expression_template``
# references: they ride to the build boundary, where they are expanded ONCE with
# site recording (the ~50x node-lowering win). ``prepare`` therefore hands
# ``desugar_pushdown`` a document whose binning body may be a surviving reference
# rather than the containment ``ifelse`` the recogniser looks for.
#
# §9.6.4 rule 4 ("patterns do not see through surviving references") governs the
# §9.6.3 REWRITE-RULE ENGINE. This desugar is a different consumer and rule 2
# governs it: a reference DENOTES its expansion, and observable behavior must be
# as if evaluated on ``Expand(tree)``. So whether the pushdown fires MUST NOT
# depend on whether the author factored the body through a template — detection
# runs on the EXPANDED view.
#
# EMISSION does not: ``_pd_apply`` edits the call site's ``bindings`` (and the
# aggregate's own ``ranges`` / ``args`` / ``shape`` / ``join``), never the shared
# template body, so the body stays shared and singly-lowered and Option B
# survives the rewrite. ``_pd_assert_rects_rebound`` is the post-condition that
# proves it.
# --------------------------------------------------------------------------- #


def _pd_templates(model: dict) -> dict | None:
    """The component template registry of ``model``, or ``None``.

    Only the component-level ``expression_templates`` block is consulted, which
    is what the Julia reference reads (``coerce_esm_file`` fills
    ``component_templates`` from exactly these blocks) — a top-level authored
    registry is a DECLARATION that load materialises into the components, so on
    the ``prepare`` input form the per-component block is the registry.
    """
    tpl = model.get("expression_templates")
    return tpl if isinstance(tpl, dict) and tpl else None


def _pd_has_apply(node: Any) -> bool:
    """Does ``node`` carry a surviving ``apply_expression_template`` reference?
    Descends every dict value, ``bindings`` included."""
    if isinstance(node, dict):
        if node.get("op") == APPLY_OP:
            return True
        return any(_pd_has_apply(v) for v in node.values())
    if isinstance(node, list):
        return any(_pd_has_apply(x) for x in node)
    return False


def _pd_first_apply_name(node: Any) -> str | None:
    """The ``name`` of the first surviving reference in ``node`` (pre-order),
    for the residual diagnostic; ``None`` when it carries none."""
    if isinstance(node, dict):
        if node.get("op") == APPLY_OP:
            n = node.get("name")
            return str(n) if isinstance(n, str) else None
        for v in node.values():
            r = _pd_first_apply_name(v)
            if r is not None:
                return r
    elif isinstance(node, list):
        for x in node:
            r = _pd_first_apply_name(x)
            if r is not None:
                return r
    return None


def _pd_expand_for_detection(node: Any, templates: dict | None) -> Any:
    """``Expand(node)`` against ``templates`` — DETECTION ONLY; nothing of the
    result is emitted. Returns ``node`` itself when there is nothing to expand,
    and returns it UNCHANGED (rather than raising) when expansion fails: the
    pass's contract is to leave a document it cannot recognise alone, and an
    unexpandable reference is then reported by :func:`_pd_binning_refusal` if the
    variable is join-shaped."""
    if templates is None or not _pd_has_apply(node):
        return node
    from .lower_expression_templates import _expand_all  # local: avoid a cycle

    try:
        return _expand_all(copy.deepcopy(node), templates, "pushdown_rewrite")
    except Exception:  # unresolvable reference, malformed bindings, …
        return node


def _pd_detection_variables(model: dict) -> dict:
    """``model["variables"]`` with every surviving ``apply_expression_template``
    reference in a variable's ``expression`` expanded — the ``Expand(tree)`` view
    the pattern matcher must see. Returns the variables dict ITSELF (no copy)
    when there is no registry or no reference, so a template-free document takes
    the byte-identical pre-existing path."""
    variables = model.get("variables")
    if not isinstance(variables, dict):
        return {}
    templates = _pd_templates(model)
    if templates is None:
        return variables
    if not any(
        isinstance(v, dict) and _pd_has_apply(v.get("expression"))
        for v in variables.values()
    ):
        return variables
    out = dict(variables)
    for name, v in variables.items():
        if not (isinstance(v, dict) and _pd_has_apply(v.get("expression"))):
            continue
        ex = _pd_expand_for_detection(v["expression"], templates)
        if ex is not v["expression"]:
            nv = dict(v)
            nv["expression"] = ex
            out[name] = nv
    return out


# --------------------------------------------------------------------------- #
# Residual diagnostics.
#
# A pattern recogniser that declines SILENTLY is indistinguishable from one that
# fired — until, hours later, an ungated provider fetch runs the machine out of
# memory. These keep the two cases apart:
#
#   NOT A JOIN           — a ``+``-aggregate with no containment predicate is a
#                          legitimately dense factor. Nothing to gate, no
#                          diagnostic.
#   A JOIN I CANNOT READ — the aggregate bins records into cells of the SAME set
#                          that indexes a provider-backed rank-2 array it feeds,
#                          but the containment could not be recovered. Reported.
#
# WARNING, not error: the pass's contract (CONFORMANCE_SPEC §5.5.7) is that an
# unrecognised document comes back unchanged, and the residue is a PERFORMANCE
# defect — the numbers stay right, the fetch gets big. The one hard error in this
# pass is :func:`_pd_assert_rects_rebound`, where the rewrite HAS fired and a
# rect factor could not be re-pointed: wrong numbers, not slow ones.
# --------------------------------------------------------------------------- #

PD_UNGATED_CONSEQUENCE = (
    "the provider-backed array is fetched WHOLESALE — no derived support set "
    "is produced and no gate is emitted"
)


def _pd_binning_refusal(ev: Any, out_set: str) -> tuple[str, str | None] | None:
    """Why :func:`_pd_detect_binning` refused ``ev``, for a caller that has
    ALREADY established ``ev`` sits in the join position.

    ``None`` ⇒ ``ev`` is simply not join-shaped (no diagnostic warranted).
    Otherwise ``(reason, template)``: ``("surviving_template_reference", name)``
    when the body carries a reference that could not be expanded for matching,
    ``("predicate_unparsed", None)`` when a containment ``ifelse`` was found but
    did not read as a rectangle containment in either orientation."""
    if not (isinstance(ev, dict) and ev.get("type") == "observed"):
        return None
    shape = ev.get("shape")
    if not (isinstance(shape, list) and len(shape) == 1 and shape[0] == out_set):
        return None
    agg = ev.get("expression")
    if not (isinstance(agg, dict) and _is_aggregate_op(agg.get("op"))):
        return None
    if _pd_oplus(agg) != ("+", 0.0):
        return None
    oi = agg.get("output_idx")
    if not (isinstance(oi, list) and len(oi) == 1 and isinstance(oi[0], str)):
        return None
    out_sym = oi[0]
    ranges = _ranges_of(agg)
    if len(ranges) != 2 or _range_from(ranges.get(out_sym)) != out_set:
        return None
    in_sym = next((k for k in ranges if k != out_sym), None)
    if in_sym is None or _range_from(ranges[in_sym]) is None:
        return None
    body = agg.get("expr")
    if not isinstance(body, dict):
        return None
    if _pd_find_ifelse_cond(body) is None:
        tname = _pd_first_apply_name(body)
        if tname is None:
            return None  # no predicate at all ⇒ genuinely dense
        return ("surviving_template_reference", tname)
    return ("predicate_unparsed", None)


def _pd_diagnostic_message(d: dict) -> str:
    """The human-readable rendering of one diagnostic record: what was
    recognised, what could not be read, and what it costs."""
    if d.get("reason") == "surviving_template_reference":
        tpl = d.get("template")
        why = (
            "its body carries a surviving `apply_expression_template` reference"
            + ("" if tpl is None else f" to '{tpl}'")
            + " that could not be expanded for matching"
        )
    else:
        why = (
            "its containment predicate did not read as a rectangle containment "
            "between four cell-indexed rect bounds and two record-indexed point "
            "coordinates"
        )
    return (
        f"projection-pushdown desugar: '{d['variable']}' is join-shaped — it bins "
        f"records into the cells of index set '{d['index_set']}' and feeds the "
        f"provider-backed array '{d['array']}' through '{d['consumer']}' — but "
        f"{why}, so the rewrite does NOT fire for it and {PD_UNGATED_CONSEQUENCE}. "
        "Bind the containment's factors through the template's params, or write "
        "the predicate longhand."
    )


def _pd_mirror_specs(
    variables: dict, C: str, R: str, forward_names: set
) -> list[tuple[str, list[str], list[str]]]:
    """The MIRRORED-orientation binning aggregates of a model: per-RECORD
    observeds ``P[r] = Σ_{c∈C} [contains(cell_c, pt_r)]·…`` over the plan's
    cell set ``C`` and record set ``R``. Returned as ``(name, src_env,
    tgt_env)`` triples, sorted by name so the emitted document is identical
    across bindings and hash seeds.

    A mirror needs NOTHING but the gate (see the note on the mirrored arm in
    :func:`_pd_apply`). Its cell axis stays the FULL ``C``, so its envelope
    factors are the document's own const-array rects, unrewritten.
    """
    out: list[tuple[str, list[str], list[str]]] = []
    for name, v in variables.items():
        if name in forward_names:
            continue
        bind = _pd_detect_binning(v, R)
        if bind is None:
            continue
        if bind["out_is_cell"] or bind["C"] != C or bind["R"] != R:
            continue
        # Never stack a second gate on an aggregate that already declares a join.
        expr = v.get("expression")
        if isinstance(expr, dict) and expr.get("join") is not None:
            continue
        out.append((name, bind["src_env"], bind["tgt_env"]))
    out.sort(key=lambda t: t[0])
    return out


def _pd_detect(model: dict, index_sets: Any):
    """Detect the pushdown pattern across a model's observeds.

    Matching runs on the DETECTION view (:func:`_pd_detection_variables`): the
    model's variables with surviving template references expanded, so a binning
    body factored through a template matches exactly as its expansion would.

    Returns ``(plan, diagnostics)`` — ``plan`` ``None`` when nothing matches /
    the semiring guard fails, ``diagnostics`` the residual "a join I could not
    read" records (see :func:`_pd_binning_refusal`)."""
    variables = _pd_detection_variables(model)
    diags: list[dict] = []
    if not variables:
        return None, diags
    conc_specs: list[tuple[str, str]] = []
    a_names: list[str] = []
    # (E name, cell output symbol, gate src_env, gate tgt_env)
    e_specs: list[tuple[str, str, list[str], list[str]]] = []
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
        if bind is None or not bind["out_is_cell"]:  # FORWARD arm only
            # `ev` is the rank-1 factor of a `+`-mat-vec against a
            # provider-backed `[c_set, r_set]` array: the join position. If it is
            # ALSO binning-shaped but unreadable, say so — silence here is the
            # ungated whole-array fetch that surfaces hours later.
            if bind is None:
                why = _pd_binning_refusal(ev, c_set)
                if why is not None:
                    diags.append(
                        {
                            "code": "pushdown_join_unrecognised",
                            "variable": ename,
                            "consumer": cname,
                            "array": aname,
                            "index_set": c_set,
                            "reason": why[0],
                            "template": why[1],
                            "consequence": PD_UNGATED_CONSEQUENCE,
                        }
                    )
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
            e_specs.append((ename, bind["c_sym"], bind["src_env"], bind["tgt_env"]))
    # Deterministic, deduplicated diagnostic order: the same E can be reached
    # from several `conc` consumers.
    diags.sort(key=lambda d: (d["variable"], d["consumer"], d["array"]))
    _seen: set = set()
    diags = [
        d
        for d in diags
        if not (
            (d["variable"], d["consumer"], d["array"]) in _seen
            or _seen.add((d["variable"], d["consumer"], d["array"]))
        )
    ]
    if not conc_specs:
        return None, diags
    # Deterministic plan order (mirrors the Julia `sort!(A_names)`): the one
    # collection-order-dependent list that leaks into the emitted document
    # (`gated_select.applies_to`) is sorted so all bindings agree.
    a_names.sort()
    # MIRRORED-orientation binning aggregates (`P[r] = Σ_c […]`) over the SAME
    # cell/record sets. They are collected only once the forward pattern has
    # fixed `C`/`R`: the mirror is a rider on the rewrite, never its trigger.
    mirror_specs = _pd_mirror_specs(variables, C, R, {e[0] for e in e_specs})
    return {
        "C": C,
        "rcv_set": rcv_set,
        "R": R,
        "conc_specs": conc_specs,
        "A_names": a_names,
        "E_specs": e_specs,
        "mirror_specs": mirror_specs,
        "src_env": src_env,
        "tgt_env": tgt_env,
        "rep_ename": rep_ename,
        "rep_csym": rep_csym,
        "rep_rsym": rep_rsym,
    }, diags


# --------------------------------------------------------------------------- #
# Emission
# --------------------------------------------------------------------------- #


def _pd_rewrite_rects(node: Any, rectmap: dict[str, str]) -> Any:
    """In-place: rewrite every ``index(F, …)`` whose factor ``F`` is a key of
    ``rectmap`` to ``index(rectmap[F], …)`` throughout a raw AST subtree.

    This walk descends EVERY dict value, ``bindings`` included, so a rect factor
    that reaches the binning body through an ``apply_expression_template`` call
    site is reached AT THE CALL SITE — which is exactly where the rewrite must
    land, so the shared template body stays untouched and singly-lowered
    (esm-spec §9.6.4 Option B). Two binding spellings carry a rect factor and
    both are handled: a subscripted binding (``{"F": index(src_W, "c")}``) by the
    ``index`` arm above, and a BARE FACTOR-NAME binding (``{"F": "src_W"}``,
    substituted into the body's own ``index(F, c)``) by the ``bindings`` arm
    below. A bare string is rewritten ONLY inside ``bindings`` — elsewhere a
    string is an ``output_idx`` entry, a range key, a scalar field or a template
    ``name``, none of which are variable references."""
    if isinstance(node, dict):
        if node.get("op") == "index":
            a = node.get("args")
            if isinstance(a, list) and a and isinstance(a[0], str) and a[0] in rectmap:
                a[0] = rectmap[a[0]]
        if node.get("op") == APPLY_OP:
            b = node.get("bindings")
            if isinstance(b, dict):
                for k, v in list(b.items()):
                    if isinstance(v, str) and v in rectmap:
                        b[k] = rectmap[v]
        for v in node.values():
            _pd_rewrite_rects(v, rectmap)
    elif isinstance(node, list):
        for x in node:
            _pd_rewrite_rects(x, rectmap)
    return node


def _pd_ix(f: Any, *idx: Any) -> dict:
    return {"op": "index", "args": [f, *idx]}


def _pd_overlap_clause(src_env: Any, tgt_env: Any) -> dict:
    """One dict-form ``join.overlap`` clause (CONFORMANCE_SPEC §5.5.6 wire
    form). ``eps`` is always ``0.0``: the rewrite derives the envelopes from an
    EXACT rectangle-containment predicate that stays on as the narrow
    ``filter``, so no FP slack is wanted."""
    return {
        "overlap": {
            "src_env": [str(f) for f in src_env],
            "tgt_env": [str(f) for f in tgt_env],
            "eps": 0.0,
        }
    }


def _pd_collect_stale_rects(node: Any, rectmap: dict[str, str], out: set) -> set:
    """Collect every factor name in ``rectmap`` that still appears in an
    ``index(F, …)`` position — every occurrence :func:`_pd_rewrite_rects`
    targets but did not reach."""
    if isinstance(node, dict):
        if node.get("op") == "index":
            a = node.get("args")
            if isinstance(a, list) and a and isinstance(a[0], str) and a[0] in rectmap:
                out.add(a[0])
        for v in node.values():
            _pd_collect_stale_rects(v, rectmap, out)
    elif isinstance(node, list):
        for x in node:
            _pd_collect_stale_rects(x, rectmap, out)
    return out


def _pd_assert_rects_rebound(
    expr: Any, ename: str, rectmap: dict[str, str], templates: dict | None
) -> None:
    """POST-CONDITION of the forward arm's rect re-pointing, discharged on the
    EXPANDED form of the rewritten aggregate (esm-spec §9.6.4 rule 2: what the
    evaluator sees is ``Expand(tree)``).

    ``E``'s reduction axis now ranges over the COMPACT derived support set, so
    every rect reference in its body must have become the corresponding
    ``pd_cell__*`` gather. The rewrite achieves that by editing the CALL SITE,
    which is what keeps the shared template body untouched. A rect factor named
    FREE inside a template body is therefore unreachable: rewriting it would mean
    rewriting the shared body, corrupting every other call site (the generated
    producer ``filter`` among them, which must keep full-grid references). Left
    alone it would index a compact per-support gather with full-grid positions —
    WRONG NUMBERS, silently. Hence a hard error, whose remedy is the one the
    template machinery already prescribes: bind the value through the params."""
    if not rectmap:
        return
    view = _pd_expand_for_detection(expr, templates)
    stale = _pd_collect_stale_rects(view, rectmap, set())
    if not stale:
        return
    names = "', '".join(sorted(stale))
    raise ExpressionTemplateError(
        TEMPLATE_BODY_REFERENCES_PUSHDOWN_REWRITTEN_VARIABLE,
        f"projection-pushdown desugar: the binning aggregate '{ename}' still reads "
        f"'{names}' after its reduction axis was re-pointed onto the generated "
        "derived support set. Those references live in an expression-template BODY, "
        "not in the call site's `bindings`, so the rewrite — which edits call sites "
        "only, to keep the template body shared and singly-lowered (esm-spec §9.6.4 "
        "Option B) — cannot re-point them, and they would index the compact "
        "per-support cell gathers with full-grid positions. Bind the value through "
        "the template's params, or write the binning body longhand.",
    )


def _pd_apply(esm: dict, mname: str, plan: dict, templates: dict | None = None) -> dict:
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
        # The body is factored through a template. Read the predicate off the
        # EXPANDED body (§9.6.4 rule 2) — the producer wants the FULL-GRID rect
        # references, which is exactly what the pre-rewrite expansion yields. The
        # expansion is a scratch value: nothing of it is emitted except these
        # comparisons, so the document's template block and call sites are
        # untouched. A template-free document never reaches this branch, so its
        # emitted filter is byte-identical to before.
        ifcond = _pd_find_ifelse_cond(
            _pd_expand_for_detection(repexpr.get("expr"), templates)
        )
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

    # --- rewrite E: axis → derived set, rect factors → cell gathers, + GATE ---
    # The rewritten `E` still reduces over the FULL record axis, so without a
    # gate it visits |support|·|records| pairs — 1520·43650 on isrm.esm. Attach
    # the SAME overlap clause the producer carries, re-pointed at the generated
    # cell gathers, and the enumeration driver (§5.5.6) walks one candidate
    # partner list per output cell instead. The clause is derived, not authored:
    # its envelopes are exactly the ones `_pd_parse_containment` read out of
    # this aggregate's own containment predicate.
    for ename, csym, e_src, e_tgt in plan["E_specs"]:
        # DEEP-COPY before the in-place rect rewrite. `copy.deepcopy` is
        # memoised by object identity, so a document built in memory keeps
        # whatever subtree sharing its author created — and the ISRM-shaped
        # fixtures share one `contains(...)` predicate object across every
        # aggregate that bins. Rewriting E's rects in place would then reach
        # through the shared node into a variable that is NOT being re-pointed
        # (a mirrored per-record aggregate, say) and leave it gathering the
        # compact cell buffers with full-grid indices. Copying first confines
        # the rewrite to this variable; the emitted JSON is unchanged (sharing
        # is not a document-level property).
        expr = copy.deepcopy(mv[ename]["expression"])
        mv[ename]["expression"] = expr
        expr["ranges"][csym]["from"] = setname
        _pd_rewrite_rects(expr, rectmap)
        if "args" in expr:
            expr["args"] = [rectmap.get(str(s), s) for s in expr["args"]]
        mv[ename]["shape"] = [setname]
        if "join" not in expr:
            expr["join"] = [
                _pd_overlap_clause(e_src, [rectmap.get(f, f) for f in e_tgt])
            ]
        _pd_assert_rects_rebound(expr, ename, rectmap, templates)

    # --- MIRRORED orientation: gate only ---
    # A per-record binning aggregate `P[r] = Σ_{c∈C} [contains(cell_c, pt_r)]·…`
    # is the same join read the other way round. It gets ONLY the gate — no
    # derived index set, no `distinct` producer, no `member_factor`, no provider
    # gating — because it wants the FULL record axis: every record must produce
    # a value, and a record outside the grid must come out as the semiring
    # identity (the driver leaves such a position with no term and 0̄ is
    # emitted). There is nothing to compact, so a mirrored VALUE-INVENTION would
    # derive a support set nobody reads. Its envelopes stay the document's own
    # const-array factors (the cell axis is not re-pointed), so the mirror also
    # needs no rect gathers.
    for pname, p_src, p_tgt in plan.get("mirror_specs", ()):
        pexpr = copy.deepcopy(mv[pname]["expression"])  # see the deep-copy note
        mv[pname]["expression"] = pexpr
        if "join" not in pexpr:
            pexpr["join"] = [_pd_overlap_clause(p_src, p_tgt)]

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
    an = _pd_analyze(esm, model_name)
    if an is None:
        return esm
    plan, diags, mname, templates = an
    # RESIDUAL DIAGNOSTICS (CONFORMANCE_SPEC §5.5.7): a join-shaped aggregate the
    # recogniser could NOT read is reported here, not swallowed. See
    # `_pd_binning_refusal` for the "not a join" / "a join I could not read"
    # split, and `pushdown_diagnostics` for the inspectable form.
    for d in diags:
        warnings.warn(_pd_diagnostic_message(d), UserWarning, stacklevel=2)
    if plan is None:
        return esm
    return _pd_apply(esm, mname, plan, templates)


def pushdown_diagnostics(esm: dict, model_name: str | None = None) -> list[dict]:
    """The residual diagnostics :func:`desugar_pushdown` would emit for ``esm``.

    One record per aggregate that IS join-shaped (it bins records into the cells
    of an index set and feeds a provider-backed rank-2 array through a
    ``+``-semiring mat-vec) but whose containment predicate the recogniser could
    not read, so the rewrite does not fire for it and that array is fetched
    WHOLESALE.

    Inspectable, side-effect-free counterpart of the warning stream: same
    records, same order (sorted by ``variable``/``consumer``/``array``), stable
    field set (``code``, ``variable``, ``consumer``, ``array``, ``index_set``,
    ``reason``, ``template``, ``consequence``), pinned across bindings by the
    ``tests/conformance/pushdown/`` corpus. Empty for a document that already
    carries the rewrite record, for one with no model selected, and —
    deliberately — for one that simply is NOT join-shaped: "no join here" is not
    a defect."""
    if not isinstance(esm, dict) or _pushdown_record(esm) is not None:
        return []
    an = _pd_analyze(esm, model_name)
    return [] if an is None else an[1]


def _pd_analyze(esm: dict, model_name: str | None):
    """The ONE detection entry point shared by :func:`desugar_pushdown` (which
    then emits) and :func:`pushdown_diagnostics` (which only reports). ``None``
    when no model is selected; otherwise
    ``(plan, diagnostics, model_name, templates)`` — ``plan`` ``None`` meaning
    the pattern did not match."""
    models = esm.get("models")
    if not isinstance(models, dict):
        return None
    mname = _pd_model_name(esm, model_name)
    if mname is None or mname not in models:
        return None
    m = models[mname]
    if not isinstance(m, dict):
        return None
    plan, diags = _pd_detect(m, esm.get("index_sets"))
    return plan, diags, mname, _pd_templates(m)


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
