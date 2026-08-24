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
needs to. ``esm_problem`` therefore runs the rewrite BEFORE ``parse.load`` and
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

from .classification import observed_definitions
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
            raise bad(f'"range" is empty: stop {bounds["stop"]} precedes start {bounds["start"]}')
        return {"range": bounds}
    raise bad(
        f"unrecognised axis selector keys {sorted(map(str, ax))}; expected one of "
        "fixed, range, gated_by"
    )


def parse_select_axes(ctx: str, axes: Any, gated_by_override: str | None = None) -> list[Any]:
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


def _pd_matvec_factors(body: Any, c_sym: str, out_syms: list[str]) -> tuple[str, str] | None:
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
    """Parse a containment predicate — an ``and``/``*`` of comparisons, each
    between a factor subscripted by ``c_sym`` and one subscripted by ``r_sym``
    — into the §5.5.6 overlap-gate envelopes ``(src_env, tgt_env)``, where
    ``src_env`` is the ``r_sym`` side. TWO shapes are read, told apart by how
    many DISTINCT ``r_sym``-side factors appear and how many ``c_sym``-side
    bounds each carries:

    * **point-in-rect** — 2 factors, each with a min AND a max bound:
      ``src_env=[Px,Py]``, ``tgt_env=[xmin,ymin,xmax,ymax]``;
    * **envelope-overlap** — 4 factors, each with EXACTLY ONE bound, i.e. the
      AABB test ``cxmin<=rxmax and rxmin<=cxmax and cymin<=rymax and
      rymin<=cymax``: ``src_env=[rxmin,rymin,rxmax,rymax]``,
      ``tgt_env=[cxmin,cymin,cxmax,cymax]``.

    A bound's KIND comes from the ORIENTATION of its comparison, so the
    comparisons may be authored in any order and either direction.

    Which factors share an axis is decided by appearance order, and that choice
    is FREE: the envelope predicate is a perfect matching between the four cell
    and four record factors and nothing in it says which two comparisons are the
    x pair, but §5.5.6's broad phase is the conjunction of the same four
    inequalities under any pairing that puts one lower and one upper bound in
    each axis — each emitted inequality pairs an envelope entry with the partner
    matched here. The axis labels are a relabelling the AABB test is invariant
    under. Appearance order is used because it is deterministic.

    ``None`` on any other shape."""
    if not isinstance(pred, dict):
        return None
    comps = pred.get("args") if pred.get("op") in ("and", "*") else [pred]
    if not isinstance(comps, list):
        return None
    bounds: dict[str, dict[str, str]] = {}
    rec_order: list[str] = []
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
            rec_order.append(fp)
            bounds[fp] = {}
        if kind in bounds[fp]:
            return None  # one bound of each kind per factor
        bounds[fp][kind] = fc
    if len(rec_order) == 2 and all(len(bounds[p]) == 2 for p in rec_order):
        px, py = rec_order
        return {
            "src_env": [px, py],
            "tgt_env": [
                bounds[px]["min"],
                bounds[py]["min"],
                bounds[px]["max"],
                bounds[py]["max"],
            ],
        }
    if len(rec_order) == 4 and all(len(bounds[p]) == 1 for p in rec_order):
        # A record factor carrying a LOWER cell bound (``cmin <= r``) is that
        # axis's record MAXIMUM, and vice versa — the AABB test compares each
        # side's min against the other side's max.
        his = [p for p in rec_order if "min" in bounds[p]]
        los = [p for p in rec_order if "max" in bounds[p]]
        if len(his) != 2 or len(los) != 2:
            return None
        return {
            "src_env": [los[0], los[1], his[0], his[1]],
            "tgt_env": [
                bounds[his[0]]["min"],
                bounds[his[1]]["min"],
                bounds[los[0]]["max"],
                bounds[los[1]]["max"],
            ],
        }
    return None


def _ranges_of(agg: dict) -> dict:
    r = agg.get("ranges")
    return r if isinstance(r, dict) else {}


def _range_from(v: Any) -> str | None:
    if isinstance(v, dict) and isinstance(v.get("from"), str):
        return v["from"]
    return None


def _pd_detect_binning(ev: Any, agg: Any, out_set: str, out_is_cell: bool | None = None):
    """Is the observed unknown ``ev`` (declared shape) with defining expression
    ``agg`` a BINNING aggregate — a ``+``-semiring reduction over TWO 1-D
    index sets whose body carries a containment predicate between CELL-indexed
    and RECORD-indexed factors (either shape :func:`_pd_parse_containment`
    reads)? BOTH orientations are recognised (CONFORMANCE_SPEC §5.5.7):

    * FORWARD ``E[c] = Σ_r [contains(cell_c, rec_r)]·…``  (cell axis is output)
    * MIRROR  ``P[r] = Σ_c [contains(cell_c, rec_r)]·…``  (record axis is output)

    The gate is IDENTICAL either way — the enumeration driver binds its two
    symbols from the clause's declared envelopes and knows nothing about cells
    vs records, and the aggregate's own ``output_idx`` decides the result's
    orientation. So the guards here are on the aggregate's SHAPE, not on which
    axis is which: ``out_set`` is the index set the observed is shaped on, and
    the single other range supplies the opposite side.

    For a POINT-IN-RECT predicate the predicate itself also says which symbol is
    the cell — it carries the four rect BOUND factors, against the record's two
    point coordinates. An ENVELOPE-OVERLAP predicate is symmetric and parses
    BOTH ways, so a caller that already knows passes ``out_is_cell``: the
    forward arm's cell set comes from the mat-vec array's first axis, and
    mirrors are collected only once ``C``/``R`` are fixed. Left ``None`` the
    out-as-cell reading is preferred, which is what the point case always gave.

    Returns the binding dict — ``c_sym``, ``r_sym``, ``C``, ``R``,
    ``out_is_cell``, ``src_env``, ``tgt_env`` — or ``None``.
    """
    if not isinstance(ev, dict):
        return None
    shape = ev.get("shape")
    if not (isinstance(shape, list) and len(shape) == 1 and shape[0] == out_set):
        return None
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
    if out_is_cell is not False:
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
    if out_is_cell is True:
        return None
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
# site recording (the ~50x node-lowering win). ``esm_problem`` therefore hands
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
    the ``esm_problem`` input form the per-component block is the registry.
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


def _pd_detection_defs(model: dict) -> dict:
    """:func:`_pd_observed_defs` with every surviving
    ``apply_expression_template`` reference expanded — the ``Expand(tree)`` view
    the pattern matcher must see. From esm 1.0.0 an observed unknown's body is
    its defining EQUATION's right-hand side, so this — not the variable table —
    is what the detector matches against. Returns the definition map ITSELF (no
    copy) when there is no registry or no reference, so a template-free document
    takes the byte-identical pre-existing path.

    DETECTION ONLY. The emission side re-reads :func:`_pd_observed_defs` so it
    edits the AUTHORED body (and, for a template-factored one, the call site's
    ``bindings``) rather than a detached expansion."""
    defs = _pd_observed_defs(model)
    templates = _pd_templates(model)
    if templates is None or not any(_pd_has_apply(e) for e in defs.values()):
        return defs
    out = dict(defs)
    for name, expr in defs.items():
        if not _pd_has_apply(expr):
            continue
        ex = _pd_expand_for_detection(expr, templates)
        if ex is not expr:
            out[name] = ex
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


def _pd_binning_refusal(ev: Any, agg: Any, out_set: str) -> tuple[str, str | None] | None:
    """Why :func:`_pd_detect_binning` refused ``ev``, for a caller that has
    ALREADY established ``ev`` sits in the join position. ``agg`` is ``ev``'s
    defining equation RHS from the detection view, exactly as
    :func:`_pd_detect_binning` received it; ``None`` (a variable that is not an
    observed unknown, so has no definition) is never join-shaped.

    ``None`` ⇒ ``ev`` is simply not join-shaped (no diagnostic warranted).
    Otherwise ``(reason, template)``: ``("surviving_template_reference", name)``
    when the body carries a reference that could not be expanded for matching,
    ``("predicate_unparsed", None)`` when a containment ``ifelse`` was found but
    did not read as a containment — point-in-rect or envelope overlap — in
    either orientation."""
    if not isinstance(ev, dict):
        return None
    shape = ev.get("shape")
    if not (isinstance(shape, list) and len(shape) == 1 and shape[0] == out_set):
        return None
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
            "its containment predicate did not read as a point-in-rectangle "
            "containment (four cell-indexed rect bounds against two record-indexed "
            "point coordinates) nor as an envelope-overlap one (four bounds on each "
            "side)"
        )
    return (
        f"projection-pushdown desugar: '{d['variable']}' is join-shaped — it bins "
        f"records into the cells of index set '{d['index_set']}' and feeds the "
        f"provider-backed array '{d['array']}' through '{d['consumer']}' — but "
        f"{why}, so the rewrite does NOT fire for it and {PD_UNGATED_CONSEQUENCE}. "
        "Bind the containment's factors through the template's params, or write "
        "the predicate longhand."
    )


def _pd_observed_defs(model: dict) -> dict:
    """``{observed unknown -> its defining equation's RHS}`` for ``model``.

    From esm 1.0.0 an observed unknown carries no ``expression`` field: it is
    DEFINED by the bare-variable-LHS equation whose LHS is its name (esm-spec
    §6.3.1). The RHS nodes are returned BY REFERENCE, so mutating one in place
    edits the equation — which is what the rewrites below rely on.
    """
    return observed_definitions(model)


def _pd_set_observed(model: dict, name: str, expr: dict) -> None:
    """Rebind ``name``'s defining equation RHS, inserting the equation when the
    model does not already carry one for it.

    A NEW definition is placed so the bare-variable-LHS equations stay ordered by
    LHS name: before the first one that sorts after ``name``, else at the end.
    Equation order carries no meaning (classification is a property of the
    equation SET), but it must be DETERMINISTIC and identical across bindings,
    and sorted-by-name is the only order derivable from the document itself
    rather than from this rewriter's internal traversal. It is also the order the
    cross-binding goldens in tests/conformance/pushdown carry.
    """
    equations = model.get("equations")
    if not isinstance(equations, list):
        equations = []
        model["equations"] = equations
    for eq in equations:
        if isinstance(eq, dict) and eq.get("lhs") == name:
            eq["rhs"] = expr
            return
    for i, eq in enumerate(equations):
        lhs = eq.get("lhs") if isinstance(eq, dict) else None
        if isinstance(lhs, str) and lhs > name:
            equations.insert(i, {"lhs": name, "rhs": expr})
            return
    equations.append({"lhs": name, "rhs": expr})


def _pd_mirror_specs(
    model: dict, obs_defs: dict, C: str, R: str, forward_names: set
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
    variables = model.get("variables") or {}
    for name, expr in obs_defs.items():
        if name in forward_names:
            continue
        bind = _pd_detect_binning(variables.get(name), expr, R, out_is_cell=False)
        if bind is None:
            continue
        if bind["out_is_cell"] or bind["C"] != C or bind["R"] != R:
            continue
        # Never stack a second gate on an aggregate that already declares a join.
        if isinstance(expr, dict) and expr.get("join") is not None:
            continue
        out.append((name, bind["src_env"], bind["tgt_env"]))
    out.sort(key=lambda t: t[0])
    return out


def _pd_detect(model: dict, index_sets: Any):
    """Detect the pushdown pattern across a model's observeds.

    Matching runs on the DETECTION view (:func:`_pd_detection_defs`): the
    model's variables with surviving template references expanded, so a binning
    body factored through a template matches exactly as its expansion would.

    Returns ``(plan, diagnostics)`` — ``plan`` ``None`` when nothing matches /
    the semiring guard fails, ``diagnostics`` the residual "a join I could not
    read" records (see :func:`_pd_binning_refusal`)."""
    variables = model.get("variables")
    if not isinstance(variables, dict):
        variables = {}
    diags: list[dict] = []
    if not variables:
        return None, diags
    conc_specs: list[tuple[str, str]] = []
    a_names: list[str] = []
    # (E name, cell output symbol, gate src_env, gate tgt_env)
    e_specs: list[tuple[str, str, list[str], list[str]]] = []
    # EVERY array any binning body reads on the cell axis, name -> declared
    # shape, and the ungatherable ones. The envelope factors are a SUBSET of
    # this: a binning body is free to read the cell's geometry, its area, its
    # ring stack. All of them ride the same re-pointing (`_pd_cell_factors`).
    cell_factors: dict[str, list] = {}
    cell_bad: dict[str, str] = {}
    C = rcv_set = R = None
    src_env = tgt_env = None
    rep_ename = rep_csym = rep_rsym = None

    observed_defs = _pd_detection_defs(model)
    for cname, agg in observed_defs.items():
        cv = variables.get(cname)
        if not isinstance(cv, dict):
            continue
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
        bind = _pd_detect_binning(ev, observed_defs.get(ename), c_set)
        if bind is None or not bind["out_is_cell"]:  # FORWARD arm only
            # `ev` is the rank-1 factor of a `+`-mat-vec against a
            # provider-backed `[c_set, r_set]` array: the join position. If it is
            # ALSO binning-shaped but unreadable, say so — silence here is the
            # ungated whole-array fetch that surfaces hours later.
            if bind is None:
                why = _pd_binning_refusal(ev, observed_defs.get(ename), c_set)
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
            # Collected on the DETECTION view, like every other pattern read:
            # a body factored through a template must yield the same gather set
            # as its longhand twin (esm-spec §9.6.4 rule 2). Emission still
            # edits the authored body / call-site bindings, and
            # `_pd_assert_rects_rebound` proves the substitution landed.
            _pd_cell_factors(
                observed_defs[ename], bind["c_sym"], variables, c_set,
                cell_factors, cell_bad,
            )
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
    mirror_specs = _pd_mirror_specs(model, observed_defs, C, R, {e[0] for e in e_specs})
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
        "cell_factors": cell_factors,
        "cell_bad": cell_bad,
        "rep_ename": rep_ename,
        "rep_csym": rep_csym,
        "rep_rsym": rep_rsym,
    }, diags


# --------------------------------------------------------------------------- #
# Emission
# --------------------------------------------------------------------------- #


def _pd_cell_factors(node: Any, c_sym: str, variables: dict, C: str, out: dict, bad: dict) -> None:
    """Walk a binning body and record EVERY array it reads at a position on the
    cell axis — not only the envelope factors of the containment predicate.

    The rewrite re-points the aggregate's reduction range onto the compact
    derived support set, so from that moment on the loop symbol ``c_sym`` counts
    support positions, not grid cells. Any array still indexed by it that was
    NOT re-pointed then reads full-grid values at support positions: WRONG
    NUMBERS, no diagnostic. The set collected here is exactly the set that must
    be gathered, and an array whose cell subscript cannot be re-pointed lands in
    ``bad`` so the caller can refuse loudly rather than emit silent garbage.

    Membership is decided by the DECLARATION, not by the subscript: an array is
    on the cell axis iff its declared ``shape[0]`` is the cell index set ``C``.
    That is what keeps a flat-offset gather into a DIFFERENT axis — the
    ``index(Temperature, layer*N_SRC + c)`` spelling a layered met read wants,
    whose base is declared over the full ``[all_cells]`` axis — out of the map:
    it is not on the cell axis, it stays full-grid, and it is still correct
    after the rewrite because nothing about it moved.

    Three subscript shapes on a cell-axis array, and they are not alike:

      ``index(F, c)``           the whole trailing slice at cell ``c`` — a rank-3
                               ring stack read as a polygon operand. Gatherable.
      ``index(F, c, v, d)``     a fully-subscripted scalar read. Gatherable, and
                               by the SAME gather: the generated array keeps
                               ``F``'s rank, so both spellings survive untouched
                               past the substitution of the name.
      ``index(F, <expr in c>)`` arithmetic on the cell position. NOT gatherable —
                               the compact axis is a renumbering, so ``c+1`` or
                               ``2*c`` mean nothing in it. Recorded in ``bad``.

    A cell-axis array indexed WITHOUT the cell symbol (a constant position, or a
    record-driven lookup) is deliberately left alone: it still reads the
    full-grid array at a full-grid position, which the rewrite does not disturb.
    """
    if isinstance(node, dict):
        if node.get("op") == "index":
            a = node.get("args")
            if isinstance(a, list) and len(a) >= 2 and isinstance(a[0], str):
                v = variables.get(a[0])
                shp = v.get("shape") if isinstance(v, dict) else None
                if isinstance(shp, list) and shp and shp[0] == C:
                    if a[1] == c_sym:
                        out.setdefault(a[0], list(shp))
                    elif _pd_mentions_sym(a[1], c_sym):
                        bad.setdefault(a[0], _pd_subscript_sketch(a[1]))
        for v in node.values():
            _pd_cell_factors(v, c_sym, variables, C, out, bad)
    elif isinstance(node, list):
        for x in node:
            _pd_cell_factors(x, c_sym, variables, C, out, bad)


def _pd_mentions_sym(node: Any, sym: str) -> bool:
    """Does ``node`` reference the loop symbol ``sym`` anywhere?"""
    if isinstance(node, str):
        return node == sym
    if isinstance(node, dict):
        return any(_pd_mentions_sym(v, sym) for k, v in node.items() if k != "name")
    if isinstance(node, list):
        return any(_pd_mentions_sym(x, sym) for x in node)
    return False


def _pd_subscript_sketch(node: Any) -> str:
    """A one-line rendering of a subscript expression, for the refusal message."""
    if isinstance(node, str):
        return node
    if isinstance(node, (int, float)):
        return repr(node)
    if isinstance(node, dict):
        op = node.get("op")
        if op == "index":
            a = node.get("args") or []
            return f"{_pd_subscript_sketch(a[0])}[" + ", ".join(
                _pd_subscript_sketch(x) for x in a[1:]) + "]"
        args = ", ".join(_pd_subscript_sketch(x) for x in (node.get("args") or []))
        return f"{op}({args})"
    return "?"


def _pd_gather_defn(
    f: str, shape: list, setname: str, mfactor: str, index_sets: Any, C: str
) -> tuple[dict, dict]:
    """The ``(variable declaration, defining aggregate)`` for one per-support
    cell gather ``pd_cell__C__f``, RANK-PRESERVING.

    Rank 1 — the envelope factors — emits exactly what it always did::

        pd_cell__C__F[c] = F[member_factor[c]]

    Rank k keeps every trailing axis, so a ``[cells, vertex, xy]`` ring stack
    comes out as a ``[support, vertex, xy]`` ring stack and every use of it
    survives the rename unchanged — the sliced polygon-operand form
    ``index(F, c)`` and the fully-subscripted scalar form alike::

        pd_cell__C__F[c, t0, t1] = F[member_factor[c], t0, t1]

    This is a map, not a reduction: every range appears in ``output_idx``. The
    trailing loop symbols are named ``pd_t0…`` rather than reusing the
    document's own, because the gather is generated in its own scope and a
    collision with an authored symbol would be a silent capture."""
    decl = {"type": "unknown", "shape": [setname] + [t for t in shape[1:]]}
    syms = ["pd_t%d" % i for i in range(len(shape) - 1)]
    ranges: dict = {"c": {"from": setname}}
    for s, t in zip(syms, shape[1:]):
        if not (isinstance(t, str) and _pd_is_index_set(index_sets, t)):
            raise PushdownRewriteError(
                f"projection-pushdown desugar: cannot gather '{f}' onto the derived "
                f"support set of '{C}'. Its declared shape is {shape!r}, whose trailing "
                f"entry {t!r} is not a named index set, so the generated gather has no "
                "range to iterate it over. Declare the array's trailing axes as index "
                "sets, or keep the value off the cell axis."
            )
        ranges[s] = {"from": t}
    return decl, {
        "op": "aggregate",
        "output_idx": ["c"] + syms,
        "ranges": ranges,
        "args": [f, mfactor],
        "expr": _pd_ix(f, _pd_ix(mfactor, "c"), *syms),
    }


def _pd_is_index_set(index_sets: Any, name: str) -> bool:
    return isinstance(index_sets, dict) and name in index_sets


def _pd_refuse_ungatherable(bad: dict, C: str, setname: str) -> None:
    """Refuse, loudly, when a binning body reads a cell-axis array at a computed
    cell position. See :func:`_pd_cell_factors` for why it cannot be re-pointed.

    A hard error, not a warning, and not a silent decline. The pattern HAS
    matched: declining here would leave the document correct but ungated, and
    the residual-diagnostic machinery is the right home for that — but the
    caller is already past the point where the plan is committed, and an
    aggregate reading a cell-axis array at ``c+1`` cannot be gated at all
    without renumbering arithmetic the compact axis does not admit. Say so."""
    if not bad:
        return
    detail = "; ".join(f"'{f}' at [{s}]" for f, s in sorted(bad.items()))
    raise PushdownRewriteError(
        "projection-pushdown desugar: the binning aggregate reads a cell-axis array "
        f"at a COMPUTED cell position ({detail}). The rewrite re-points the reduction "
        f"onto the derived support set '{setname}', which renumbers '{C}' — support "
        "position i is grid cell member_factor[i], and no arithmetic on i survives "
        "that renumbering. A gather can carry `F[c]`, and `F[c, …]`, but not "
        "`F[f(c)]`. Index the array with the bare cell symbol, or move the value off "
        f"the '{C}' axis (declare it over the axis it is really indexed by, so it "
        "stays full-grid and is left alone)."
    )


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

    # The gather set is the envelope factors PLUS every other array a binning
    # body reads on the cell axis. Envelopes lead, so a document whose bodies
    # read nothing else emits exactly what it emitted before; the rest follow in
    # sorted order, and emission below re-sorts anyway.
    cell_shapes: dict[str, list] = dict(plan.get("cell_factors") or {})
    _pd_refuse_ungatherable(plan.get("cell_bad") or {}, C, setname)
    rects: list[str] = []
    for f in list(plan["tgt_env"]) + sorted(cell_shapes):
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
    repexpr = _pd_observed_defs(d["models"][mname])[plan["rep_ename"]]
    ifcond = _pd_find_ifelse_cond(repexpr.get("expr"))
    if ifcond is None:
        # The body is factored through a template. Read the predicate off the
        # EXPANDED body (§9.6.4 rule 2) — the producer wants the FULL-GRID rect
        # references, which is exactly what the pre-rewrite expansion yields. The
        # expansion is a scratch value: nothing of it is emitted except these
        # comparisons, so the document's template block and call sites are
        # untouched. A template-free document never reaches this branch, so its
        # emitted filter is byte-identical to before.
        ifcond = _pd_find_ifelse_cond(_pd_expand_for_detection(repexpr.get("expr"), templates))
    if ifcond is None:
        raise PushdownRewriteError("pushdown desugar: representative E lost its containment ifelse")
    comps = ifcond["args"] if ifcond.get("op") in ("and", "*") else [ifcond]
    prod_filter = {"op": "*", "args": [copy.deepcopy(c) for c in comps]}

    # --- member state var + member_factor param ---
    # An UNKNOWN, defined by the generated `distinct` producer equation below.
    # 1.0.0 has no `state` type to declare -- the producer's LHS is what makes
    # it one (esm-spec §6.3.1).
    mv[memvar] = {"type": "unknown", "shape": [setname]}
    mv[mfactor] = {"type": "parameter", "default": 0.0, "shape": [setname]}

    # --- per-rect cell-gather observeds ---
    # SORTED by rect name: the generated gathers are declarations, so their
    # emission order is arbitrary semantically -- and the cross-binding goldens
    # in tests/conformance/pushdown carry them sorted, which is also the only
    # order every binding can agree on without sharing tgt_env traversal.
    for f in sorted(rects):
        shape = cell_shapes.get(f)
        if not shape:
            shape = mv[f]["shape"] if isinstance(mv.get(f), dict) and mv[f].get("shape") else [C]
        decl, defn = _pd_gather_defn(f, list(shape), setname, mfactor, d.get("index_sets"), C)
        mv[cellgath(f)] = decl
        _pd_set_observed(d["models"][mname], cellgath(f), defn)

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
        expr = copy.deepcopy(_pd_observed_defs(d["models"][mname])[ename])
        _pd_set_observed(d["models"][mname], ename, expr)
        expr["ranges"][csym]["from"] = setname
        _pd_rewrite_rects(expr, rectmap)
        if "args" in expr:
            expr["args"] = [rectmap.get(str(s), s) for s in expr["args"]]
        mv[ename]["shape"] = [setname]
        if "join" not in expr:
            expr["join"] = [_pd_overlap_clause(e_src, [rectmap.get(f, f) for f in e_tgt])]
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
        # see the deep-copy note
        pexpr = copy.deepcopy(_pd_observed_defs(d["models"][mname])[pname])
        _pd_set_observed(d["models"][mname], pname, pexpr)
        if "join" not in pexpr:
            pexpr["join"] = [_pd_overlap_clause(p_src, p_tgt)]

    # --- restrict the conc reductions to the derived axis ---
    for cname, ssym in plan["conc_specs"]:
        _pd_observed_defs(d["models"][mname])[cname]["ranges"][ssym]["from"] = setname

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
    # PREPENDED, not appended: the producer materialises the derived index set
    # that every rewritten E / A / conc reduction below now ranges over, so it
    # reads as "define the support set, then reduce over it" -- and it is the
    # order the cross-binding goldens in tests/conformance/pushdown carry.
    # Equation order is not semantically meaningful (classification is a property
    # of the equation SET), so this is a presentation choice the goldens fix.
    eqs = d["models"][mname].get("equations")
    if not isinstance(eqs, list):
        eqs = []
        d["models"][mname]["equations"] = eqs
    eqs.insert(0, producer)

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
    """The (from, to) name routings of a raw document, for array aliasing.

    Two sources, in this order:

    1. A parameter bound to a data source by its own ``update`` (1.0.0):
       ``("<Source>.<file_variable>", "<ModelPath>.<param>")``. A provider is
       keyed by the consuming parameter -- the `to` side -- so this is what lets
       an array supplied under the SOURCE's spelling still reach its consumer.
    2. A ``variable_map`` coupling edge, still admissible between two ordinary
       components (it is data SOURCES that stopped being coupling endpoints).

    Deriving (1) from the document is the point: scanning for `variable_map`
    alone returns [] on every 1.0.0 document, which silently left the aliasing
    to a bare-tail fallback -- a name coincidence rather than a declaration.
    """
    out: list[tuple[str, str]] = []

    def visit(model: Any, prefix: str) -> None:
        if not isinstance(model, dict):
            return
        for vname in sorted((model.get("variables") or {}).keys()):
            vdef = (model.get("variables") or {})[vname]
            if not isinstance(vdef, dict):
                continue
            update = vdef.get("update")
            rules = update if isinstance(update, list) else [update]
            for rule in rules:
                if not isinstance(rule, dict) or rule.get("kind") != "data":
                    continue
                source = rule.get("source")
                binding = rule.get("from")
                if not isinstance(source, str) or not isinstance(binding, dict):
                    continue
                fv = binding.get("file_variable")
                if not isinstance(fv, str):
                    continue
                key = f"{prefix}.{vname}" if prefix else str(vname)
                out.append((f"{source}.{fv}", key))
        for sname in sorted((model.get("subsystems") or {}).keys()):
            sub = (model.get("subsystems") or {})[sname]
            visit(sub, f"{prefix}.{sname}" if prefix else str(sname))

    for mname in sorted((doc.get("models") or {}).keys()):
        visit((doc.get("models") or {})[mname], str(mname))

    cp = doc.get("coupling")
    if isinstance(cp, list):
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


def _pushdown_gate_axes(doc: dict, loader: str, gset: str, gaxis: int, mrank: int) -> list[Any]:
    """Per-NATIVE-axis gate ``axes`` for ``loader``: the loader's declared
    ``metadata.x_esd.gated_select.axes`` template with the GENERATED set name
    substituted into its ``gated_by`` slot (validated against the record's
    ``gated_axis``); else a rank-``mrank`` all-axes gate with ``gated_by`` at
    ``gaxis``."""
    tpl = None
    loaders = doc.get("data_sources")
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
            f"data_sources.{loader} gated_select template", tpl, gated_by_override=gset
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
                f"data_sources.{loader} gated_select template puts the gated axis "
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


def _pushdown_data_fed_parameters(doc: dict):
    """``(data_sources key, flattened parameter name, local name, file_variable)``
    for every parameter in the document whose ``update`` reads a source
    (esm-spec §8.5). The flattened name is the parameter's namespaced path --
    what keys its provider. Sorted, so the derived gate map is identical across
    bindings and hash seeds."""
    out = []

    def visit(model, prefix: str) -> None:
        if not isinstance(model, dict):
            return
        for vname, vdef in (model.get("variables") or {}).items():
            if not isinstance(vdef, dict) or vdef.get("type") != "parameter":
                continue
            update = vdef.get("update")
            rules = update if isinstance(update, list) else [update]
            for rule in rules:
                if not (isinstance(rule, dict) and rule.get("kind") == "data"):
                    continue
                source = rule.get("source")
                binding = rule.get("from")
                if not isinstance(source, str) or not isinstance(binding, dict):
                    continue
                key = f"{prefix}.{vname}" if prefix else str(vname)
                out.append(
                    (
                        source,
                        key,
                        str(vname),
                        str(binding.get("file_variable", vname)),
                    )
                )
        for sname, sub_model in (model.get("subsystems") or {}).items():
            visit(sub_model, f"{prefix}.{sname}" if prefix else str(sname))

    for mname, m in (doc.get("models") or {}).items():
        visit(m, str(mname))
    return sorted(set(out))


def _pushdown_provider_gates(doc: dict, providers: Any) -> dict[str, dict]:
    """Provider-key ⇒ engine gate, derived from ``doc``'s rewrite record
    (``metadata.x_esd.pushdown.gated_select``).

    A provider is GATED when its key names a data-fed parameter
    (``"<Source>"`` or ``"<Source>.<parameter>"``) that is one of the record's
    ``applies_to`` model arrays. From 1.0.0 the routing is the PARAMETER's own
    ``update`` -- there is no coupling edge from a source -- so the pairs come
    from the model variables rather than from ``coupling``. The gate's
    per-NATIVE-axis ``axes`` come from the source's own
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

    # "<Source>.<parameter>" => the gated model array's LOCAL name. A data-fed
    # parameter IS the loaded field from 1.0.0, so this reads the parameters'
    # `update` blocks; the 0.x coupling `variable_map` pairs are still consulted
    # for a document that routes an array through one.
    # A provider key is `"<Source>.<parameter>"`, and the gate's `applies_to`
    # names the MODEL ARRAY the fetched slab binds to -- the consuming parameter.
    # In 0.x that array was reached through a coupling `param_to_var`, so the
    # name was the loader variable's and the alias walk found the model array by
    # tail; from 1.0.0 the parameter IS the loaded field, so it is named
    # directly.
    # provider key -> (data_sources key, the gated model array's LOCAL name).
    # The SOURCE is carried explicitly: a provider is keyed by the consuming
    # parameter, whose prefix names its MODEL, so it can no longer be recovered
    # by splitting the key.
    fed: dict[str, tuple[str, str]] = {}
    for source_key, key, param, _file_variable in _pushdown_data_fed_parameters(doc):
        if param in applies:
            fed[key] = (source_key, param)
    for frm, to in _pushdown_coupling_pairs(doc):
        if "." not in frm:
            continue
        tail = to.rsplit(".", 1)[-1]
        if tail in applies:
            fed.setdefault(frm, (frm.split(".", 1)[0], tail))
    if not fed:
        return gates

    mrank = _pushdown_gated_rank(doc, applies)
    for k0 in providers:
        k = str(k0)
        if k in fed:  # a provider for ONE data-fed parameter
            loader, param = fed[k]
            lvars = [param]
        else:  # a provider for a WHOLE source, serving several of its columns
            loader = k
            lvars = sorted({p for src, p in fed.values() if src == k})
            if not lvars:
                continue
        axes = _pushdown_gate_axes(doc, loader, gset, gaxis, mrank)
        gates[k] = {"axes": axes, "applies_to": list(lvars)}
    return gates


def _inject_pushdown_aliases(
    dst: dict[str, Any], run_doc_variables: list[str], coupling_pairs: list[tuple[str, str]]
) -> dict[str, Any]:
    """Alias-key injection for the ``esm_problem`` pushdown path (same-object
    references, no copies): surface each array under (a) the coupling ``to``
    name for every ``variable_map`` ``from`` key present, and (b) every
    flattened model-variable name whose final dotted segment matches the key's
    own final segment. Existing keys are never overwritten.

    Rule (b) is keyed on the TAIL rather than on a bare key because from esm
    1.0.0 a provider key is `"<Source>.<parameter>"` and the flattened consumer
    is `"<Model>.<parameter>"` -- the same parameter under two prefixes, with no
    coupling edge between them to carry rule (a). A bare key still matches, so
    the 0.x shape keeps working."""
    for frm, to in coupling_pairs:
        if frm in dst and to not in dst:
            dst[to] = dst[frm]
    for k in list(dst.keys()):
        tail = k.rsplit(".", 1)[-1]
        for v in run_doc_variables:
            if v != k and "." in v and v.rsplit(".", 1)[-1] == tail and v not in dst:
                dst[v] = dst[k]
    return dst
