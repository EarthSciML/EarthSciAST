"""Canonical registry of the ESM expression-AST ``op`` vocabulary.

This module is the **single source of truth** for the set of ``op`` strings that
may appear on an :class:`~earthsci_ast.esm_types.ExprNode`. It exists because the
vocabulary was previously implicit, scattered across at least six independent
tables / dispatch chains that could (and did) drift apart:

* :mod:`earthsci_ast.expression` — ``_UNARY_SYMPY`` / ``_BINARY_SYMPY`` (ESM→SymPy)
  and the ``_FROM_SYMPY_*`` reverse tables.
* :mod:`earthsci_ast.display` — the operator-precedence map plus the big
  render dispatch (``_format_structural_op`` + ``_format_expression_node``).
* :mod:`earthsci_ast.codegen` — the Julia and Python ``op → handler`` chains.
* :mod:`earthsci_ast.numpy_interpreter` — ``_SCALAR_FUNCS`` / ``_CMP_UFUNCS`` /
  ``_broadcast_fn`` and the ``eval_expr`` dispatch.
* :mod:`earthsci_ast.cadence` — ``RELATIONAL_OPS`` (the value-invention guard).
* :mod:`earthsci_ast.flatten` — ``_SPATIAL_OPS`` (the spatial-sugar detector).

The historical failure mode (flagged by the Python audit): when a new op is
added it raises loudly in the SymPy path but **silently degrades** to generic
``op(args)`` rendering in ``display`` / ``codegen`` — no error, just wrong-looking
output. The registry, together with ``tests/test_op_registry.py``, closes that
gap: the test asserts each renderer/dispatcher stays in sync with this registry,
so adding an op without updating a renderer fails loudly at test time; and the
generic fallbacks in ``display`` / ``codegen`` now warn when they meet an op that
is not even in this registry (a genuinely unregistered op).

**Contract for renderers/dispatchers.** Every op below is part of the accepted
vocabulary. A renderer/dispatcher is expected to cover the subset appropriate to
its role (see the per-table scoping in ``tests/test_op_registry.py``). This
registry is **additive** — it documents and cross-checks the existing tables; it
does not replace them, and none of the working dispatch tables were rewritten to
route through it.

**Derivation.** The set is the union of esm-spec.md §4.2's op vocabulary and
every one of the six tables above (read exhaustively). It is intentionally the
honest union, so accepted spelling aliases (``**`` / ``pow`` for ``^``; ``=`` for
``==``) are included and marked via :attr:`OpSpec.alias_of`.

Categories
----------

``arithmetic``       ``+ - * / ^`` (and the ``**`` / ``pow`` spellings)
``elementary``       spec §4.2 "Elementary Functions": exp/log/trig/hyperbolic
                     families, ``atan2``, ``min``/``max``, ``floor``/``ceil``,
                     ``abs``, ``sign``
``comparison``       ``> < >= <= == !=`` (and the ``=`` equality spelling)
``logical``          ``and`` / ``or`` / ``not`` and the ``true`` / ``false``
                     boolean literals
``conditional``      ``ifelse``
``calculus``         ``D`` (structural time-derivative LHS) and ``ic``
``event``            ``Pre``
``closed_registry``  ``fn`` / ``enum`` / ``table_lookup`` (spec §4.4/§4.5/§9.5)
``template``         ``apply_expression_template`` (spec §9.6)
``constant``         ``const`` (inline literal)
``array``            aggregate/makearray/index/broadcast/reshape/transpose/concat
``relational``       value-invention & index-returning reducers: skolem, rank,
                     argmin, argmax, distinct, join (RFC semiring-faq-unified-ir)
``geometry``         intersect_polygon, polygon_intersection_area (§8.6 kernels)
``spatial_sugar``    rewrite-target open-tier sugar: grad/div/laplacian/curl and
                     ``integral`` (no evaluator; lowered by a discretization rule)

Tiers
-----

``core``            evaluable-core (closed) op — every binding's evaluator
                    implements it directly (esm-spec §4.2).
``rewrite_target``  open-tier op with **no** evaluator; it MUST be eliminated by
                    a rewrite rule before evaluation (``unlowered_operator`` if
                    not, esm-spec §9.6.6). The ``spatial_sugar`` ops.
"""

from __future__ import annotations

from dataclasses import dataclass

#: The closed set of category labels (see the module docstring).
CATEGORIES: frozenset[str] = frozenset(
    {
        "arithmetic",
        "elementary",
        "comparison",
        "logical",
        "conditional",
        "calculus",
        "event",
        "closed_registry",
        "template",
        "constant",
        "array",
        "relational",
        "geometry",
        "spatial_sugar",
    }
)

#: The closed set of tier labels.
TIERS: frozenset[str] = frozenset({"core", "rewrite_target"})

#: The closed set of arity descriptors. These are documentation-grade labels; the
#: authoritative numeric arity bounds live in
#: ``structural_checks._OPERATOR_ARITY`` (which this mirrors in prose).
ARITIES: frozenset[str] = frozenset(
    {
        "nullary",  # args == []; the payload lives in dedicated fields
        "unary",
        "binary",
        "ternary",
        "nary",  # variadic, >= 2 operands (n-ary fold)
        "variadic",  # variadic, >= 1 operand
        "unary_or_binary",  # `-` (negation vs subtraction)
        "special",  # bespoke shape (aggregate-family; index-set-driven)
    }
)


@dataclass(frozen=True)
class OpSpec:
    """Metadata for one canonical ``op`` string.

    Attributes:
        name: The op string as it appears in an ``ExprNode.op``.
        category: One of :data:`CATEGORIES`.
        arity: One of :data:`ARITIES` (documentation-grade; see note there).
        tier: One of :data:`TIERS` — ``core`` (evaluable) or ``rewrite_target``.
        alias_of: For a pure spelling alias, the canonical op it spells (e.g.
            ``**`` → ``^``); ``None`` for a canonical op.
        note: Optional human-readable clarification.
    """

    name: str
    category: str
    arity: str
    tier: str = "core"
    alias_of: str | None = None
    note: str = ""


# The canonical vocabulary. Order groups by category for readability; lookups go
# through the OPS dict below.
_ALL: tuple[OpSpec, ...] = (
    # --- arithmetic (esm-spec §4.2 Arithmetic) ---
    OpSpec("+", "arithmetic", "nary"),
    OpSpec("-", "arithmetic", "unary_or_binary", note="unary negation or binary subtraction"),
    OpSpec("*", "arithmetic", "nary"),
    OpSpec("/", "arithmetic", "binary"),
    OpSpec("^", "arithmetic", "binary", note="power"),
    OpSpec("**", "arithmetic", "binary", alias_of="^", note="Python-style power spelling"),
    OpSpec("pow", "arithmetic", "binary", alias_of="^", note="word spelling of power"),
    # --- elementary functions (esm-spec §4.2 Elementary Functions) ---
    OpSpec("exp", "elementary", "unary"),
    OpSpec("log", "elementary", "unary", note="natural log"),
    OpSpec("log10", "elementary", "unary"),
    OpSpec("sqrt", "elementary", "unary"),
    OpSpec("abs", "elementary", "unary"),
    OpSpec("sign", "elementary", "unary"),
    OpSpec("sin", "elementary", "unary"),
    OpSpec("cos", "elementary", "unary"),
    OpSpec("tan", "elementary", "unary"),
    OpSpec("asin", "elementary", "unary"),
    OpSpec("acos", "elementary", "unary"),
    OpSpec("atan", "elementary", "unary"),
    OpSpec("atan2", "elementary", "binary"),
    OpSpec("sinh", "elementary", "unary"),
    OpSpec("cosh", "elementary", "unary"),
    OpSpec("tanh", "elementary", "unary"),
    OpSpec("asinh", "elementary", "unary"),
    OpSpec("acosh", "elementary", "unary"),
    OpSpec("atanh", "elementary", "unary"),
    OpSpec("min", "elementary", "nary", note="n-ary (>= 2); clamp/clip primitive"),
    OpSpec("max", "elementary", "nary", note="n-ary (>= 2); clamp/clip primitive"),
    OpSpec("floor", "elementary", "unary"),
    OpSpec("ceil", "elementary", "unary"),
    # --- comparison (esm-spec §4.2 Conditionals) ---
    OpSpec(">", "comparison", "binary"),
    OpSpec("<", "comparison", "binary"),
    OpSpec(">=", "comparison", "binary"),
    OpSpec("<=", "comparison", "binary"),
    OpSpec("==", "comparison", "binary"),
    OpSpec("!=", "comparison", "binary"),
    OpSpec("=", "comparison", "binary", alias_of="==",
           note="equality spelling used by the equation/display layer"),
    # --- logical (esm-spec §4.2 Conditionals + boolean literals) ---
    OpSpec("and", "logical", "nary"),
    OpSpec("or", "logical", "nary"),
    OpSpec("not", "logical", "unary"),
    OpSpec("true", "logical", "nullary", note="boolean-literal constant (spec §4.2)"),
    OpSpec("false", "logical", "nullary", note="boolean-literal constant"),
    # --- conditional ---
    OpSpec("ifelse", "conditional", "ternary"),
    # --- calculus (esm-spec §4.2 Calculus) ---
    OpSpec("D", "calculus", "unary",
           note="structural time-derivative LHS; a spatial/RHS D is rewrite-target"),
    OpSpec("ic", "calculus", "unary", note="initial-condition declaration (esm-spec §11.4)"),
    # --- event-specific (esm-spec §4.2 Event-specific / §5) ---
    OpSpec("Pre", "event", "unary"),
    # --- closed-registry invocation (esm-spec §4.4 / §4.5 / §9.5) ---
    OpSpec("fn", "closed_registry", "variadic", note="closed function call; carries `name`"),
    OpSpec("enum", "closed_registry", "binary", note="[enum_name, symbol]; lowered at load"),
    OpSpec("table_lookup", "closed_registry", "nullary",
           note="args empty; `table`/`axes` fields; lowered at load"),
    # --- expression templates (esm-spec §9.6) ---
    OpSpec("apply_expression_template", "template", "nullary",
           note="args empty; `name`/`bindings` fields; expanded at load"),
    # --- inline constants (esm-spec §4.2 Inline Constants) ---
    OpSpec("const", "constant", "nullary", note="args empty; literal in `value`"),
    # --- array / tensor (esm-spec §4.2 Array / Tensor, §4.3) ---
    OpSpec("aggregate", "array", "special", note="FAQ semiring aggregate"),
    OpSpec("makearray", "array", "special"),
    OpSpec("index", "array", "variadic"),
    OpSpec("broadcast", "array", "variadic", note="carries scalar `fn`"),
    OpSpec("reshape", "array", "unary", note="carries `shape`"),
    OpSpec("transpose", "array", "unary", note="optional `perm`"),
    OpSpec("concat", "array", "variadic", note="carries `axis`"),
    # --- relational / value-invention (esm-spec §4.2 FAQ companions; RFC §5) ---
    OpSpec("skolem", "relational", "variadic", note="build-time value invention"),
    OpSpec("rank", "relational", "variadic", note="build-time dense IDs"),
    OpSpec("argmin", "relational", "special", note="index-returning reduction"),
    OpSpec("argmax", "relational", "special", note="index-returning reduction"),
    OpSpec("distinct", "relational", "variadic",
           note="dedup reducer / aggregate distinct flag (cadence guard)"),
    OpSpec("join", "relational", "special", note="equi-join gate (cadence guard)"),
    # --- geometry kernel leaves (esm-spec §8.6) ---
    OpSpec("intersect_polygon", "geometry", "binary", note="clipped overlap ring; carries `manifold`"),
    OpSpec("polygon_intersection_area", "geometry", "binary",
           note="fused scalar overlap area; carries `manifold`"),
    # --- spatial-sugar (open tier, esm-spec §4.2 rewrite-target) ---
    OpSpec("grad", "spatial_sugar", "unary", tier="rewrite_target", note="sugar over D"),
    OpSpec("div", "spatial_sugar", "unary", tier="rewrite_target", note="sugar over D"),
    OpSpec("laplacian", "spatial_sugar", "unary", tier="rewrite_target", note="sugar over D"),
    OpSpec("curl", "spatial_sugar", "unary", tier="rewrite_target", note="sugar over D"),
    OpSpec("integral", "spatial_sugar", "unary", tier="rewrite_target",
           note="PIDE spatial integral; carries `var`/`lower`/`upper`"),
)


#: The canonical registry: op string -> :class:`OpSpec`. This is the object
#: renderers/dispatchers cross-check against.
OPS: dict[str, OpSpec] = {spec.name: spec for spec in _ALL}


def names() -> frozenset[str]:
    """All op strings in the registry (canonical ops **and** spelling aliases)."""
    return frozenset(OPS)


def canonical_names() -> frozenset[str]:
    """Op strings that are canonical (not a spelling alias of another op)."""
    return frozenset(name for name, spec in OPS.items() if spec.alias_of is None)


def by_category(category: str) -> frozenset[str]:
    """All op names in ``category`` (including any aliases in that category)."""
    return frozenset(name for name, spec in OPS.items() if spec.category == category)


def by_tier(tier: str) -> frozenset[str]:
    """All op names in ``tier`` (``"core"`` or ``"rewrite_target"``)."""
    return frozenset(name for name, spec in OPS.items() if spec.tier == tier)


def is_known(op: str) -> bool:
    """True iff ``op`` is part of the canonical AST op vocabulary.

    Used by the ``display`` / ``codegen`` generic fallbacks to decide whether a
    node reaching generic ``op(args)`` rendering is a known op (grad/div/…, or a
    relational build-time op — legitimately generic) or a genuinely unregistered
    op that should be surfaced with a :class:`RuntimeWarning`.
    """
    return op in OPS
