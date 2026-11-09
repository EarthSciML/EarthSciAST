"""
Layer 1 of 2: raw-dict structural validation (post-schema, pre-parse).

This module hosts the raw-dict structural-validation suite that
``earthsci_ast.parse.load`` runs after JSON-schema validation and template
resolution but before JSON→dataclass parsing: operator arity, symbol tables
and scoped-reference resolution, metadata formats,
data-loader/reaction-system/event checks, and the registered-function call
audit — everything invoked from :func:`_validate_structural`. It checks no
units (see below).

Layer boundary (what lives where):

* THIS module operates on the raw ``dict`` decoded from JSON, BEFORE the
  document is parsed into :mod:`earthsci_ast.esm_types` dataclasses. It is a
  load-time gate: any finding aborts ``load()`` by raising
  :class:`StructuralValidationError` (a :class:`SchemaValidationError`
  subclass) whose human-readable ``str()`` is a collapsed blob of all
  findings and whose ``.findings`` list carries the same findings as
  machine-readable ``(code, message)`` records. Rules that need only the raw
  shape of the document (arity, reference resolution, metadata/temporal
  string formats, the registered-function-call audit) belong here.

* :mod:`earthsci_ast.validation` is Layer 2: dataclass-level *semantic*
  validation. It runs later, on a parsed :class:`~earthsci_ast.esm_types.EsmFile`,
  is invoked explicitly via ``validation.validate()`` (not by ``load()``),
  collects structured :class:`~earthsci_ast.error_handling.ErrorCode` records
  into a ``ValidationResult`` instead of raising, and owns the semantic rules
  (equation-unknown balance, reaction consistency, event consistency, and
  every unit rule). New semantic rules should go THERE, in the coded channel —
  not here. See that module's docstring for the reciprocal note.

* Units live only in Layer 2, as in the other bindings: ``validate()`` runs
  the one unit checker, :class:`earthsci_ast.units.UnitValidator`, which
  types whole expressions. ``load()`` therefore accepts a document whose only
  defect is a unit one (an unreal unit string, a dimensional mismatch), and
  ``validate()`` reports it as a ``unit_parse_error`` / ``unit_inconsistency``
  error. Do not add a unit check here.

Split out of ``parse.py`` so raw-dict validation and dataclass parsing stay
separate concerns. ``parse`` imports from this module at module top; this
module only imports from ``parse`` lazily inside :func:`_validate_structural`
and :func:`_structural_validation_error_cls` (for
:class:`~earthsci_ast.parse.SchemaValidationError`), keeping the
module-import graph acyclic.
"""

from __future__ import annotations

import re
from collections.abc import Callable, Iterator, Mapping
from typing import Any

from . import index_alignment, op_registry, recurrence
from .classification import (
    _derivative_targets,
    _equations,
    _field,
    _variables,
    algebraic_unknowns,
    model_nodes,
    observed_definitions,
    ode_states,
    system_kind,
)
from .error_handling import (
    CIRCULAR_DEPENDENCY,
    COUPLING_EDGE_UNKNOWN_ROLE,
    FAQ_BARE_ARRAY_OPERAND,
    OBSERVED_CYCLE,
    RAGGED_VALUES_NOT_GATHERED,
)
from .esm_types import effective_records_per_sample
from .index_alignment import faq_bare_array_operand_message, faq_bare_array_operands
from .json_walk import iter_child_values, walk_dict_exprs

# StructuralValidationError is built lazily (and cached) so that its base class,
# ``earthsci_ast.parse.SchemaValidationError``, can be imported without
# reintroducing the parse<->structural_checks import cycle this module's
# docstring documents. It subclasses SchemaValidationError so existing
# ``except SchemaValidationError`` / ``pytest.raises(SchemaValidationError)``
# callers keep catching structural failures unchanged, while carrying the
# findings additionally as machine-readable ``(code, message)`` records on
# ``.findings`` — the counterpart to validation.py's structured ErrorCode
# records. Exposed as the module attribute ``StructuralValidationError`` via
# the PEP 562 ``__getattr__`` below.
_STRUCTURAL_VALIDATION_ERROR_CLS: type | None = None


def _structural_validation_error_cls() -> type:
    """Return the cached :class:`StructuralValidationError` class, building it
    (and lazily importing its ``SchemaValidationError`` base) on first use."""
    global _STRUCTURAL_VALIDATION_ERROR_CLS
    if _STRUCTURAL_VALIDATION_ERROR_CLS is None:
        from .parse import SchemaValidationError

        class StructuralValidationError(SchemaValidationError):
            """Raised by :func:`_validate_structural` when raw-dict structural
            checks find problems.

            ``str(err)`` is the same collapsed human-readable blob the raw
            structural pass has always produced (so message-matching callers are
            unchanged); ``err.findings`` is the same set of problems as a list of
            ``(code, message)`` tuples, giving the stable diagnostic codes a
            machine-readable home alongside the prose blob.

            ``err.records`` carries the same findings with a JSON-Pointer
            ``path`` and a ``details`` payload — the shape
            ``tests/invalid/expected_errors.json`` pins for every binding.
            ``validation.validate()`` re-emits these as structured
            ``ValidationError``s so a caller sees ``code`` + ``path`` instead of
            a single opaque prose blob."""

            def __init__(
                self,
                message: str,
                findings: list[tuple[str, str]] | None = None,
                records: list[dict] | None = None,
            ):
                super().__init__(message)
                self.findings: list[tuple[str, str]] = list(findings or [])
                self.records: list[dict] = list(records or [])

        _STRUCTURAL_VALIDATION_ERROR_CLS = StructuralValidationError
    return _STRUCTURAL_VALIDATION_ERROR_CLS


def __getattr__(name: str):  # PEP 562: lazy module-level attribute.
    if name == "StructuralValidationError":
        return _structural_validation_error_cls()
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


# Operator arity bounds ``op -> (min_args, max_args)`` (``max_args`` None =
# unbounded). DERIVED from the canonical op registry
# (:mod:`earthsci_ast.op_registry`), the single source for the AST op vocabulary
# and each op's arity contract, so this table cannot drift from it. The registry
# supplies exactly the ops that carry a structural arity check — array /
# relational / geometry ops (index-set-driven shapes), spelling aliases, boolean
# literals, and the closed-registry ops whose args live in dedicated fields (`fn`
# arity is checked by its dispatcher; `table_lookup`/`apply_expression_template`
# carry no `args`) are intentionally absent, exactly as before. Notably `grad`/
# `div` are (1, 2): they accept an optional per-field boundary metavariable bound
# by a two-arg `grad(f, inflow, dim)` expression-template `match` (esm-spec §9.6).
_OPERATOR_ARITY = op_registry.arity_bounds_map()

# Built-in symbols always available in expressions.
#
# The COORDINATE names here are the conventional spellings, kept as a fallback
# for a document that declares no `index_sets`. The authoritative source is the
# DOCUMENT — see :func:`_implicit_document_symbols`, which adds the domain's
# `independent_variable` and every declared index-set name. A model is never
# required to declare its independent variable or its spatial coordinates as
# variables (esm-spec §5.3's own example writes `t` undeclared), so neither may
# ever be reported as an `undefined_variable`.
_BUILTIN_SYMBOLS = frozenset(
    {
        "t",
        "pi",
        "e",
        "true",
        "false",
        "x",
        "y",
        "z",
        "lon",
        "lat",
        "lev",
        "longitude",
        "latitude",
        "level",
    }
)


def _implicit_document_symbols(data: dict[str, Any]) -> set[str]:
    """Symbols a document declares IMPLICITLY, and which are therefore always in
    scope in its expressions (esm-spec §5.3, §11.1).

    Two sources:

    * the domain's ``independent_variable`` (default ``"t"``) — the time symbol
      an equation differentiates with respect to; and
    * every ``index_sets`` key — the document-scoped registry of iteration
      domains, i.e. the spatial/categorical AXES a model's variables are shaped
      over (``lon``, ``lat``, ``lev``, …).

    Neither is ever declared as a *variable*, so a checker that only consults
    ``variables`` reports both as undefined. This function is why
    ``_BUILTIN_SYMBOLS``' hard-coded coordinate list is a fallback rather than
    the rule: a document is free to name its independent variable ``tau`` or its
    axis ``depth``, and those are just as implicitly declared as ``t`` and
    ``lon``.
    """
    symbols: set[str] = set()
    domain = data.get("domain")
    if isinstance(domain, dict):
        symbols.add(str(domain.get("independent_variable") or "t"))
    else:
        symbols.add("t")
    index_sets = data.get("index_sets")
    if isinstance(index_sets, dict):
        symbols.update(str(k) for k in index_sets)
    return symbols


# Pint-compatible unit aliases for normalizing
# The raw-dict expression child-field set lives in ONE place now — the shared
# combinator ``json_walk.iter_child_values`` (the dict-form counterpart of
# ``expr_walk.iter_children``). The three reference-integrity walkers below
# descend through it instead of each re-listing ``lower``/``upper``/``expr``/
# ``filter``/``key`` + ``args``/``values``/``axes``/``bindings``/``regions`` by
# hand. Each keeps its own LEAF logic; where a walker historically visited a
# strict SUBSET of that set it filters the combinator's yielded field names to
# preserve its exact traversal.


# Fields that BIND index/integration symbols for a node's body (esm-spec §5;
# expr_walk.py's module docstring). A symbol introduced here is a bound
# variable of the aggregate/makearray/integral, not a reference to a declared
# model symbol, so reference checks must not flag it as undefined.
def _bare_string_leaves(expr) -> set[str]:
    """Collect every bare-string leaf reachable from ``expr`` across the
    child-field set (used to pull loop symbols out of index-coordinate
    sub-expressions like ``i + 1``).

    Descends the shared combinator's child set MINUS ``regions``: this walker
    predates ``makearray`` region bounds and never visited them, so they are
    skipped to keep its result byte-identical."""
    out: set[str] = set()
    if isinstance(expr, str):
        out.add(expr)
    elif isinstance(expr, dict):
        for field_name, child in iter_child_values(expr):
            if field_name == "regions":
                continue
            out |= _bare_string_leaves(child)
    return out


def _expression_bound_symbols(expr) -> set[str]:
    """Collect every index/integration symbol BOUND anywhere in ``expr``.

    Explicit binders live in ``ranges`` (dict keys), ``output_idx`` (string
    entries), ``wrt`` (derivative variable) and ``var`` (integral variable).
    A ``makearray`` stencil lowered from a grad/div template, however, carries
    NO explicit binder field once round-tripped — its loop symbols (``i``/``j``)
    appear only as the COORDINATE arguments of the ``index`` ops in its region
    bodies (``index(field, i + 1, j)``). Those coordinate symbols are therefore
    also treated as bound. Used by :func:`_check_variable_references` to avoid
    flagging a contracted/loop index symbol as an undefined variable once the
    walker descends into aggregate/makearray bodies."""
    bound: set[str] = set()
    if not isinstance(expr, dict):
        return bound
    ranges = expr.get("ranges")
    if isinstance(ranges, dict):
        bound.update(ranges.keys())
    output_idx = expr.get("output_idx")
    if isinstance(output_idx, list):
        bound.update(s for s in output_idx if isinstance(s, str))
    for binder_field in ("wrt", "var"):
        sym = expr.get(binder_field)
        if isinstance(sym, str):
            bound.add(sym)
    if expr.get("op") == "index":
        # Coordinate positions (everything after the indexed field) are index
        # expressions over loop symbols, never top-level declared references.
        for coord in (expr.get("args", []) or [])[1:]:
            bound |= _bare_string_leaves(coord)
    # Recurse into every child (args, single-child slots, values, axes,
    # `apply_expression_template` bindings values — free-variable TARGETS whose
    # bound symbols must stay visible, §10.10.2 — and makearray region bounds)
    # via the shared child combinator: a binder introduced deeper in the tree is
    # bound here too.
    for _field_name, child in iter_child_values(expr):
        bound |= _expression_bound_symbols(child)
    return bound


def _walk_expression_strings(expr) -> list[str]:
    """Recursively collect string leaves from EVERY child-expression slot of an
    op-expression node, not just ``args``.

    Earlier this descended only ``args`` and silently skipped the nested
    single-expression fields (``expr``/``filter``/``key``/``lower``/``upper``),
    the ``values`` list, and the ``axes`` map — so references hidden in
    aggregate bodies, ``filter`` predicates, integral bounds, Skolem ``key``
    terms, ``makearray`` value lists, and ``table_lookup`` axis expressions were
    invisible to the reference checks. It now visits the full child-field set
    the sibling walkers (and :mod:`earthsci_ast.expr_walk`) use. Bound index
    symbols surfaced from aggregate bodies are filtered by the caller via
    :func:`_expression_bound_symbols`."""
    result: list[str] = []
    if not (isinstance(expr, dict) and "op" in expr):
        return result
    if expr.get("op") == "enum":
        # `enum`'s two args are STRING LITERALS -- an enum name and a symbol
        # (esm-spec §4.5) -- not variable references. They are checked by the
        # load-time lowering pass (`unknown_enum` / `unknown_enum_symbol`),
        # which is the only thing that can check them. Collecting them here
        # made every `enum` op outside an `index` coordinate position (where
        # `_expression_bound_symbols` already masks bare strings) report two
        # bogus `undefined_variable` findings -- so an `enum` under `+` did
        # not load at all.
        return result
    # Descend the full child set — args, the single-child slots, values, axes,
    # `apply_expression_template` bindings values (free-variable targets,
    # §10.10.2), and makearray `[[lo, hi], …]` region bounds — via the shared
    # combinator, preserving the historical visit ORDER so the order of the
    # collected references (and hence of any `undefined_variable` findings) is
    # unchanged. Nested dicts re-apply the `op` guard on recursion; a reference
    # hidden in a region bound (e.g. metaparameter `N` in `[[2, N - 1]]`) is a
    # reference like any other.
    for _field_name, child in iter_child_values(expr):
        if isinstance(child, str):
            result.append(child)
        elif isinstance(child, dict):
            result.extend(_walk_expression_strings(child))
    return result


# The value-invention / index-set-producing semirings (RFC semiring-faq-unified-ir
# §5.1). ``bool_and_or`` (⊕=or) is the only BOOLEAN/RELATIONAL semiring in the
# closed registry; the numeric ones (sum_product / max_product / min_sum /
# max_sum) are not value-inventing. Kept as a set so a future relational semiring
# extends it in one place.
_RELATIONAL_SEMIRINGS: frozenset[str] = frozenset({"bool_and_or"})


def _models_and_subsystems(data: dict[str, Any]):
    """Every model as ``(location name, model, top-level model)``: each
    top-level model, then its inline subsystem models at every depth, named by
    their path below ``models`` (``M/subsystems/Sub``)."""

    def walk(name: str, m: dict[str, Any], top: dict[str, Any]):
        yield name, m, top
        for sname, sub in (m.get("subsystems") or {}).items():
            if isinstance(sub, dict):
                yield from walk(f"{name}/subsystems/{sname}", sub, top)

    for mname, m in (data.get("models") or {}).items():
        if isinstance(m, dict):
            yield from walk(mname, m, m)


def _iter_aggregate_nodes(expr):
    """Yield every ``op:"faq"`` node reachable from ``expr`` (depth-first,
    including aggregates nested inside another aggregate's child fields)."""
    if isinstance(expr, dict):
        if expr.get("op") == "faq":
            yield expr
        for value in expr.values():
            yield from _iter_aggregate_nodes(value)
    elif isinstance(expr, list):
        for value in expr:
            yield from _iter_aggregate_nodes(value)


#: Body ops that make a ``faq`` a value-invention node. Over such a node a ragged
#: range binds the MEMBER ``values[parent, k]`` itself (esm-spec §4.3.1 "Ragged
#: ranges"), so its ``values`` gather is implicit rather than authored.
_VALUE_INVENTION_BODY_OPS = frozenset({"skolem", "rank", "distinct", "argmin", "argmax"})


def _is_value_invention_faq(agg: dict[str, Any]) -> bool:
    """Whether ``agg`` is a value-invention ``faq``: ``distinct: true``, a
    ``skolem`` key, or a skolem / rank / distinct / arg-witness body."""
    if agg.get("distinct") is True:
        return True
    key = agg.get("key")
    if isinstance(key, dict) and key.get("op") == "skolem":
        return True
    body = agg.get("expr")
    return isinstance(body, dict) and body.get("op") in _VALUE_INVENTION_BODY_OPS


def _contains_template_reference(expr: Any) -> bool:
    """Whether ``expr`` holds a surviving ``apply_expression_template`` reference
    (esm-spec §9.6.4), whose body a static walk of this document cannot see."""
    if not isinstance(expr, dict):
        return False
    if expr.get("op") == "apply_expression_template":
        return True
    return any(_contains_template_reference(child) for _, child in iter_child_values(expr))


def _ragged_ranges_missing_values_gather(
    agg: dict[str, Any], index_sets: dict[str, Any]
) -> list[dict[str, Any]]:
    """Every range of ``agg`` over a declared ``kind: "ragged"`` index set whose
    ``values`` array the body (``expr`` / ``filter``) never reads.

    Such a range symbol binds the POSITION k in 1..offsets[parent], so a body
    that never gathers ``values`` reads positions where the author meant members
    (``ragged_values_not_gathered``, esm-spec §4.3.1). Not decided for a
    value-invention node, which binds the member itself, nor for a body that
    still holds a template reference, which may do the gather out of sight."""
    ranges = agg.get("ranges")
    if not isinstance(ranges, dict) or _is_value_invention_faq(agg):
        return []
    body = [agg.get("expr"), agg.get("filter")]
    if any(_contains_template_reference(part) for part in body):
        return []
    refs = _bare_string_leaves(body[0]) | _bare_string_leaves(body[1])
    found: list[dict[str, Any]] = []
    for sym in sorted(ranges):
        spec = ranges[sym]
        set_name = spec.get("from") if isinstance(spec, dict) else None
        entry = index_sets.get(set_name) if isinstance(set_name, str) else None
        if not (isinstance(entry, dict) and entry.get("kind") == "ragged"):
            continue
        values = entry.get("values")
        if not isinstance(values, str):
            continue
        if any(ref == values or ref.endswith("." + values) for ref in refs):
            continue
        of = spec.get("of")
        found.append(
            {
                "range": str(sym),
                "index_set": set_name,
                "values": values,
                "offsets": entry.get("offsets"),
                "of": [str(p) for p in of] if isinstance(of, list) else [],
            }
        )
    return found


def _join_key_columns(agg: dict[str, Any]) -> set[str]:
    """Range-variable names used as value-equality join key columns by any
    ``join`` clause carrying ``on`` on this aggregate (RFC §5.3). A clause is
    ``{"on": [[left, right], ...]}``; each column is a range-variable name."""
    cols: set[str] = set()
    for clause in agg.get("join") or []:
        if not isinstance(clause, dict):
            continue
        for pair in clause.get("on") or []:
            if isinstance(pair, list):
                cols.update(c for c in pair if isinstance(c, str))
            elif isinstance(pair, str):
                cols.add(pair)
    return cols


def _check_aggregate_semantics(data: dict[str, Any], errors: list) -> None:
    """Three statically-decidable ``faq`` defects that are SCHEMA-VALID (so
    they slip past JSON Schema), each reported at the CONTAINING expression field
    (equation side / observed expression — the Phase-2 pointer convention):

    * ``join_key_invalid_type`` — a value-equality ``join`` (a clause carrying
      ``on``) whose key column resolves through ``ranges[col].from`` to a
      *categorical* index set whose ``members`` contain a FLOAT or NULL. Floats
      are not portably equality-comparable and null is unmatchable as a key
      (RFC §5.3 / §5.7 rule 1; CONFORMANCE_SPEC §5.5.1 rule 1). Ints/strings pass.
    * ``relational_node_in_continuous`` — a value-invention aggregate
      (``distinct: true`` under a relational/boolean semiring) whose ``key``/``expr``
      reads a declared STATE variable, so the cadence partition classifies the
      node CONTINUOUS and state-dependent topology would run on the per-step hot
      path (RFC §6.1; CONFORMANCE_SPEC §5.7.6 guard 2). A ``distinct`` over CONST
      mesh literals / parameters is allowed (positive control:
      ``tests/valid/cadence/pure_topology.esm``).
    * ``undefined_index_set`` — a ``ranges`` entry ``{"from": NAME}`` whose NAME
      is not a key of the document ``index_sets`` registry (RFC §5.2). Run only
      when the document DECLARES a registry: a document that declares none is a
      §9.7.10 discretization-agnostic leaf whose index sets arrive by injection
      at mount / test time (§6.6.6), so its effective registry is not knowable
      at standalone load and the check is deferred to the resolver, exactly as
      §9.6.1 defers ``template_constraint_unknown_index_set`` for a library file
      validated standalone (issue #185).

    Emitted as ``(code, json_pointer, message, details)`` 4-tuples so each finding
    carries its own code (the collect-level code is a fallback only), deduped per
    ``(code, pointer)``.
    """
    index_sets = data.get("index_sets") or {}
    # A document that declares NO `index_sets` of its own does not close its own
    # registry: under §9.7.10 the sets arrive from a discretization library that
    # a composing document, a subsystem-ref edge or an inline test injects into
    # this component's scope (§6.6.6), and the effective registry only exists in
    # that per-run build. Resolving `{from: NAME}` against an empty local
    # registry there rejects every conforming agnostic PDE leaf, so the check is
    # deferred — the evaluating bindings still reject a name that is still
    # unresolved once injection has run (`E_REF_UNDECLARED_INDEX_SET` and its
    # peers), which is where the typo-catching value actually lives. A document
    # that DOES declare a registry is resolved against it, unchanged.
    check_index_sets = bool(index_sets)
    seen: set[tuple[str, str]] = set()

    def emit(code: str, pointer: str, message: str, details: dict) -> None:
        if (code, pointer) in seen:
            return
        seen.add((code, pointer))
        errors.append((code, pointer, message, details))

    for mname, m, top in _models_and_subsystems(data):
        # The unknowns the solver integrates or solves for -- DERIVED from the
        # equations (esm-spec §6.3.1). An observed unknown is eliminable, so it
        # is not a "state" for the purposes of the continuous-relational guard.
        state_vars = set(ode_states(m)) | set(algebraic_unknowns(m))
        # A join key may name a DATA COLUMN, whose range symbol comes from its
        # declared 1-D shape -- so the join-side checks need the model's shapes.
        var_shapes = {
            vn: list(v["shape"])
            for vn, v in (m.get("variables") or {}).items()
            if isinstance(v, dict) and isinstance(v.get("shape"), list)
        }
        bare_axes = {
            vn: tuple(str(a) for a in shape) for vn, shape in var_shapes.items() if shape
        }
        # A subsystem's template calls expand against its top-level model's
        # registry, as the load-time rewrite does.
        from_map = _from_param_map(_model_template_registry(data, top)) if check_index_sets else {}
        for site in _model_expression_sites(m, mname):
            location, expr = site[0], site[1]
            pointer = _pointer(location)
            # --- undefined_index_set: a template call binding a `ranges` `from`
            # parameter (esm-spec §9.6.1) to a name that is not a declared set.
            for call in _iter_template_calls(expr) if from_map else []:
                for param in from_map.get(call.get("name"), ()):
                    name = (call.get("bindings") or {}).get(param)
                    if isinstance(name, str) and name not in index_sets:
                        emit(
                            "undefined_index_set",
                            pointer,
                            f"template '{call.get('name')}' ranges over undeclared index set "
                            f"'{name}' (bound to its parameter '{param}'; declared: {sorted(index_sets)})",
                            {"index_set": name, "declared": sorted(index_sets)},
                        )
            # --- faq_bare_array_operand: a shaped variable read by bare name in
            # a faq body or filter (esm-spec §4.3.1, issue #441). Not decided for
            # an expression still holding a template reference; the build
            # front door checks the expanded form.
            if not _contains_template_reference(expr):
                for field_name, name, axes in faq_bare_array_operands(expr, bare_axes):
                    emit(
                        FAQ_BARE_ARRAY_OPERAND,
                        pointer,
                        faq_bare_array_operand_message(field_name, name, axes),
                        {"field": field_name, "variable": name, "shape": list(axes)},
                    )
            for agg in _iter_aggregate_nodes(expr):
                ranges = agg.get("ranges") or {}

                # --- undefined_index_set: a {"from": NAME} not in the registry.
                for spec in (
                    ranges.values() if check_index_sets and isinstance(ranges, dict) else []
                ):
                    if isinstance(spec, dict):
                        name = spec.get("from")
                        if isinstance(name, str) and name not in index_sets:
                            emit(
                                "undefined_index_set",
                                pointer,
                                f"aggregate range references undeclared index set "
                                f"'{name}' (declared: {sorted(index_sets)})",
                                {"index_set": name, "declared": sorted(index_sets)},
                            )

                # --- ragged_values_not_gathered: a range over a ragged set binds
                # the POSITION k in 1..offsets[parent], never a member (esm-spec
                # §4.3.1), so a body that never reads the set's `values` array
                # reads positions -- a plausible wrong number (issue #259).
                for miss in _ragged_ranges_missing_values_gather(agg, index_sets):
                    parent = ", ".join(miss["of"]) or "<parent>"
                    emit(
                        RAGGED_VALUES_NOT_GATHERED,
                        pointer,
                        f"faq range {miss['range']!r} iterates ragged index set "
                        f"{miss['index_set']!r}, so it binds the POSITION k in "
                        f"1..{miss['offsets']}[{parent}], not a member; the body never "
                        f"reads the set's `values` array {miss['values']!r}. Gather the "
                        f"member explicitly: index({miss['values']}, {parent}, "
                        f"{miss['range']})",
                        miss,
                    )

                # --- join_key_invalid_type: a value-equality join key column
                # drawn from a categorical set with a float/null member.
                if isinstance(ranges, dict):
                    for col in _join_key_columns(agg):
                        spec = ranges.get(col)
                        if not isinstance(spec, dict):
                            continue
                        iset = index_sets.get(spec.get("from"))
                        if not (isinstance(iset, dict) and iset.get("kind") == "categorical"):
                            continue
                        for mem in iset.get("members") or []:
                            # bool is a subclass of int, not float, so booleans
                            # pass; only genuine floats and null are rejected.
                            if mem is None or isinstance(mem, float):
                                kind = "null" if mem is None else "float"
                                emit(
                                    "join_key_invalid_type",
                                    pointer,
                                    f"join key column '{col}' draws from categorical "
                                    f"index set '{spec.get('from')}' with a {kind} "
                                    f"member ({mem!r}); floats and null are invalid "
                                    f"join keys",
                                    {
                                        "column": col,
                                        "index_set": spec.get("from"),
                                        "member": mem,
                                    },
                                )
                                break

                # --- join_side_ambiguous / join_syms_unknown_symbol: the two
                # static SIDE checks of CONFORMANCE_SPEC §5.5.8, decidable from
                # this ONE document -- the node's ``ranges``, the declared
                # variable shapes and the clause are all here. Stated about the
                # DOCUMENT rather than about where any implementation resolves a
                # join, which is what lets all five bindings pin the same
                # fixtures (``tests/invalid/expected_errors.json``).
                #
                # ``join_syms_unknown_symbol``: a clause's ``syms`` entry that is
                # not a key of the node's ``ranges``. Unchecked, that side
                # resolves to no symbol at all and RFC §5.3's
                # degenerate-positional rule silently DROPS the pair -- an
                # ungated full product reported as a number.
                #
                # ``join_side_ambiguous``: an ``on`` key for which the document
                # does not determine a range symbol. The symbol comes from an
                # index set (named outright, or the sole shape axis of the
                # declared 1-D variable that names it); if that set is drawn by
                # MORE THAN ONE of the node's ranges and the clause carries no
                # ``syms``, the key does not say which. TWO candidates resolve by
                # the default side assignment only for a DATA COLUMN -- a key
                # naming the index set can already say which side it means by
                # naming the range symbol instead.
                if isinstance(ranges, dict):
                    set_to_syms: dict[str, list[str]] = {}
                    for sym, spec in ranges.items():
                        if isinstance(spec, dict) and isinstance(spec.get("from"), str):
                            set_to_syms.setdefault(spec["from"], []).append(str(sym))
                    for v in set_to_syms.values():
                        v.sort()
                    for clause in agg.get("join") or []:
                        if not isinstance(clause, dict):
                            continue
                        csyms = clause.get("syms")
                        if csyms is not None:
                            bad = next(
                                (c for c in csyms if c not in ranges)
                                if isinstance(csyms, (list, tuple))
                                else iter(()),
                                None,
                            )
                            if bad is not None:
                                emit(
                                    "join_syms_unknown_symbol",
                                    pointer,
                                    f"aggregate join `syms` names {bad!r}, which is not a "
                                    f"range symbol of this aggregate; both entries must "
                                    f"name one of its `ranges`",
                                    {
                                        "join_syms_entry": bad,
                                        "declared_ranges": sorted(ranges),
                                    },
                                )
                                break
                            # An explicit `syms` answers every pair of the clause.
                            continue
                        done = False
                        for pair in clause.get("on") or []:
                            if not (isinstance(pair, (list, tuple)) and len(pair) == 2):
                                continue
                            for side, key in (("left", pair[0]), ("right", pair[1])):
                                if not isinstance(key, str) or key in ranges:
                                    continue
                                if key in set_to_syms:
                                    set_name, via_column = key, False
                                else:
                                    shape = var_shapes.get(key)
                                    if not (isinstance(shape, list) and len(shape) == 1):
                                        continue
                                    set_name, via_column = str(shape[0]), True
                                cands = set_to_syms.get(set_name)
                                # One candidate: two distinct relations. Two: the
                                # default assignment, but only for a data column.
                                # Three or more: never.
                                if not cands or len(cands) < 2:
                                    continue
                                if len(cands) == 2 and via_column:
                                    continue
                                msg = (
                                    f"aggregate join key column {key!r} lives on index set "
                                    f"{set_name!r}, which {len(cands)} range symbols of this "
                                    f"aggregate draw, so the document does not determine "
                                    f"which one the key is read at; name the clause's two "
                                    f"sides with `syms`"
                                    if via_column
                                    else f"aggregate join key {key!r} names an index set that "
                                    f"{len(cands)} range symbols of this aggregate draw; "
                                    f"reference the range symbol directly, or name the "
                                    f"clause's two sides with `syms`"
                                )
                                emit(
                                    "join_side_ambiguous",
                                    pointer,
                                    msg,
                                    {
                                        "join_key": key,
                                        "side": side,
                                        "index_set": set_name,
                                        "candidate_range_symbols": cands,
                                    },
                                )
                                done = True
                                break
                            if done:
                                break
                        if done:
                            break

                # --- relational_node_in_continuous: a distinct value-invention
                # node under a relational semiring that reads a STATE variable.
                if agg.get("distinct") is True and agg.get("semiring") in _RELATIONAL_SEMIRINGS:
                    refs = _bare_string_leaves(agg.get("key")) | _bare_string_leaves(
                        agg.get("expr")
                    )
                    hit = refs & state_vars
                    if hit:
                        emit(
                            "relational_node_in_continuous",
                            pointer,
                            f"value-invention aggregate (distinct under "
                            f"{agg.get('semiring')!r}) reads state variable(s) "
                            f"{sorted(hit)} in its key/expr, classifying the node "
                            f"CONTINUOUS; state-dependent relational topology may "
                            f"not run on the per-step hot path",
                            {
                                "state_variables": sorted(hit),
                                "semiring": agg.get("semiring"),
                            },
                        )


# ---------------------------------------------------------------------------
# Causal self-reference (recurrence) well-foundedness — esm-spec §4.3.1.1
# ---------------------------------------------------------------------------
#
# The STATIC half of the construct, and the half every binding implements
# whether or not it evaluates anything (CONFORMANCE_SPEC §5.19.5). The analysis
# itself lives in :mod:`earthsci_ast.recurrence`, shared verbatim with the
# evaluator, so a document cannot validate here and then be refused (or, worse,
# quietly mis-swept) there.
#
# The rule is deliberately CONSERVATIVE about a lag it cannot prove: a lag that
# straddles zero, and one nothing static can bound at all (a parameter-valued
# offset), are both ADMITTED, because the runtime is fail-closed — a cell the
# sweep has not published cannot be read at all. So the static check's job is
# only to reject what is PROVABLY wrong and to identify the axis, never to
# certify what is right. A VALIDATOR necessarily proves less than an EVALUATOR,
# which has resolved every range against the registry first, and one that
# treated "unproven" as "illegal" would reject documents its own evaluator
# accepts.


def _recurrence_symbol_bounds(spec: Any, index_sets: dict[str, Any]) -> tuple[int, int] | None:
    """Bounds of an index symbol as the VALIDATOR can resolve them.

    A dense literal interval, a strided range's endpoints, an ``interval`` index
    set's ``1..size``, or a ``categorical`` set's ``1..len(members)``. Anything
    else is unknown — and an unknown symbol makes a lag UNPROVABLE rather than
    illegal, which is why this returns ``None`` instead of raising."""
    if isinstance(spec, (list, tuple)):
        if len(spec) == 2:
            lo, hi = spec
        elif len(spec) == 3:
            lo, _step, hi = spec
        else:
            return None
        if isinstance(lo, bool) or isinstance(hi, bool):
            return None
        if isinstance(lo, (int, float)) and isinstance(hi, (int, float)):
            return (int(lo), int(hi))
        return None
    if isinstance(spec, dict) and spec.get("of") is None:
        name = spec.get("from")
        entry = index_sets.get(name) if isinstance(name, str) else None
        if not isinstance(entry, dict):
            return None
        # `interval` by declared size, `categorical` by member count. Both are
        # 1-origin dense ranges at evaluation and the EVALUATOR resolves both
        # before it sweeps, so leaving `categorical` out here would make the
        # validator prove less than the evaluator and reject a document the
        # evaluator accepts.
        if entry.get("kind") == "interval":
            size = entry.get("size")
            return (1, int(size)) if isinstance(size, int) else None
        if entry.get("kind") == "categorical":
            members = entry.get("members")
            return (1, len(members)) if isinstance(members, list) else None
    return None


def _recurrence_lhs_target(lhs: Any) -> str | None:
    """The variable an equation DEFINES, if its LHS names one.

    A bare variable, or the §4.3 indexed-`faq` LHS form
    ``faq{expr: index(V, k…)}``. A derivative LHS (``D(u)``) defines no
    array algebraically — a stencil read of ``u`` at ``i−1`` there is a gather on
    the SOLVER's state vector, not a self-reference — so it deliberately yields
    ``None``."""
    if isinstance(lhs, str):
        return lhs
    if isinstance(lhs, dict) and lhs.get("op") == "faq":
        inner = lhs.get("expr")
        if isinstance(inner, dict) and inner.get("op") == "index":
            args = inner.get("args") or []
            if args and isinstance(args[0], str):
                return args[0]
    return None


def _check_recurrence_wellfoundedness(data: dict[str, Any], errors: list) -> None:
    """Reject a causal self-read that is not a well-founded causal read.

    Emitted as ``(code, json_pointer, message, details)`` 4-tuples at the
    containing equation's ``rhs`` — the pointer convention the rest of this
    module's equation-level findings use — with the esm-spec §4.3.1.1 code
    (``recurrence_not_wellfounded`` / ``recurrence_unsupported_form``).

    Emits nothing for an equation whose RHS contains no self-read, which is every
    equation of every document that does not use the construct."""
    index_sets = data.get("index_sets") or {}

    def bounds(spec: Any) -> tuple[int, int] | None:
        return _recurrence_symbol_bounds(spec, index_sets)

    for mname, m in (data.get("models") or {}).items():
        if not isinstance(m, dict):
            continue
        variables = m.get("variables") or {}
        for i, eq in enumerate(m.get("equations") or []):
            if not isinstance(eq, dict):
                continue
            var = _recurrence_lhs_target(eq.get("lhs"))
            if var is None:
                continue
            decl = variables.get(var)
            # Only an ARRAY-shaped unknown can carry a recurrence: a scalar has
            # no axis to fold along, and a self-read of a parameter is not a
            # definition at all.
            if not (isinstance(decl, dict) and decl.get("shape")):
                continue
            try:
                recurrence.analyze_recurrence(
                    var, eq.get("lhs"), eq.get("rhs"), symbol_bounds=bounds
                )
            except recurrence.RecurrenceError as err:
                errors.append(
                    (
                        err.code,
                        _pointer(f"models/{mname}/equations[{i}]/rhs"),
                        err.message,
                        {"variable": var},
                    )
                )


def _is_observed_cycle_self_edge_exempt(var: str, rhs: Any, *, array_shaped: bool) -> bool:
    """Is ``var``'s self-edge dropped from the §4.9.6 observed-dependency graph?

    :func:`earthsci_ast.recurrence.is_recurrence_candidate` is the canonical
    predicate and answers this on its own for every ordinary document. It is
    widened here for exactly one reason: **the two walks must see the same
    tree.**

    The edge ``V -> V`` is manufactured by :func:`_walk_expression_strings`,
    which descends the FULL canonical child set (:func:`iter_child_values` —
    ``args``, the single-child slots, ``values``, ``axes``, ``bindings``,
    ``regions``). ``find_self_reads``, which candidacy is built on, descends the
    smaller set the recurrence LOWERING has to reason about (``args``, the
    single-child slots, ``values``). Where the two disagree, a self-read that is
    invisible to candidacy still produces an edge — and a perfectly legal
    recurrence is reported as a length-one cycle.

    That gap is reachable, not theoretical: ``apply_expression_template``
    carries its call-site arguments in ``bindings``, and this validator runs
    BEFORE the §9.6.4 Option-B expansion in ``load`` (``_validate_structural``
    precedes ``lower_expression_templates`` / ``expand_document`` in
    :func:`earthsci_ast.parse.load`), so a self-read bound to a template
    parameter — ``twice(v = s[k-1])``, fixture
    ``tests/fixtures/recurrence/09_recurrence_through_expression_template.esm``
    — is present as an edge and absent as a self-read. Widening the WALK rather
    than the RULE is what keeps this faithful: the exemption is still "an
    array-shaped unknown with at least one ``index`` self-read in its own
    defining RHS", still gated on CANDIDACY and never on the well-foundedness
    verdict (CONFORMANCE_SPEC §5.19.5), and still narrower than "reads its own
    name" — a bare ``s ~ s + 1`` has no ``index`` read anywhere and stays a
    cycle of length one.

    Narrowing the edge walk instead would be wrong: a template binding that
    names a DIFFERENT observed (``f(v = b)``) is a real dependency on ``b`` once
    the application expands, so those edges have to stay."""
    if not array_shaped:
        return False
    if recurrence.is_recurrence_candidate(var, rhs, array_shaped=True):
        return True
    return any(
        isinstance(node, dict)
        and node.get("op") == "index"
        and (node.get("args") or [None])[0] == var
        for node in walk_dict_exprs(rhs)
    )


def _observed_definition_reads(var: str, rhs: Any, variables: dict[str, Any]) -> set[str]:
    """The names ``var``'s defining RHS reads: the out-edges of ``var`` in the
    observed-dependency graph before they are intersected with a node set.

    ONE walk for both graphs that use it, §4.9.6 ``observed_cycle`` (one
    model) and §4.9.7 ``circular_dependency`` (the whole document), so the two
    cannot disagree about what a definition reads.

    Free names of the RHS: every string leaf the reference walker reaches, minus
    the index/integration symbols the expression itself binds. Subtracting the
    binders BEFORE intersecting with a node set is what stops a loop symbol that
    happens to share a name with an observed from manufacturing an edge. A
    top-level bare string RHS (``a ~ b``, the alias form) is a reference in its
    own right, and :func:`_walk_expression_strings` only descends op-nodes, so
    it is added here.

    The SELF-EDGE of a §4.3.1.1 causal self-reference is dropped: a causal
    self-read is an ORDERING WITHIN one variable — the sweep publishes each cell
    before the axis advances — rather than a dependency between two.

    Gated on CANDIDACY, never on the well-foundedness verdict (CONFORMANCE_SPEC
    §5.19.5). Verdict-gating would leave the exemption off for an ILL-founded
    self-read, so the cycle check would fire first and collapse the document to
    one cycle error, and the ``recurrence_not_wellfounded`` /
    ``recurrence_unsupported_form`` diagnosis would never be reached — the
    masking defect the construct exists to remove, moved from the legal case to
    the illegal one.

    Candidacy is also narrower than "is this a self-edge at all": a scalar
    ``x ~ x + 1``, or a bare ``s ~ s + 1`` over an array, has no axis to fold
    along, can never be a recurrence, and IS a cycle of length one that
    ``observed_cycle`` must report."""
    names = set(_walk_expression_strings(rhs))
    if isinstance(rhs, str):
        names.add(rhs)
    names -= _expression_bound_symbols(rhs)
    if var in names and _is_observed_cycle_self_edge_exempt(
        var, rhs, array_shaped=bool(_field(variables.get(var), "shape"))
    ):
        names.discard(var)
    return names


def _first_observed_cycle(
    successors: dict[str, list[str]],
    keep: Callable[[list[str]], bool] | None = None,
) -> list[str] | None:
    """The first cycle a deterministic DFS closes over ``successors``, or ``None``.

    ``keep`` filters the back edges that count: a cycle it rejects is skipped
    and the search continues past that edge, which is how §4.9.7 passes over a
    cycle that lies in one scope (that cycle is §4.9.6's) without losing a
    cross-scope one the same search reaches later.

    Roots are visited in sorted name order and each node's successors are already
    sorted by the caller, so the SAME cycle is named on every run — the
    determinism esm-spec §4.9.6 requires of a diagnostic that reports one cycle
    per model out of possibly several. WHITE/GRAY/BLACK colouring: a GRAY successor
    is on the current stack, so the cycle is the tail of the path from it
    onwards, closed by repeating it.

    ITERATIVE, not recursive, and that is not a style choice. The depth of a
    recursive walk here is the length of the longest observed CHAIN, which is a
    property of the document rather than of its nesting, and CPython's default
    limit is ~1000 frames: an acyclic chain of ~800 observeds — one large
    lowered mechanism — raised ``RecursionError`` out of :func:`load_string`
    instead of validating clean. An explicit stack of ``(node, successor
    iterator)`` frames costs the same asymptotics and has no such ceiling.
    ``path`` is maintained as the GRAY stack itself, so closing a cycle is a
    slice of it rather than a per-edge copy."""
    WHITE, GRAY, BLACK = 0, 1, 2
    color = dict.fromkeys(successors, WHITE)

    for root in sorted(successors):
        if color[root] != WHITE:
            continue
        color[root] = GRAY
        path = [root]
        # Each frame is the node's own successor iterator, so resuming a parent
        # after a child finishes picks up exactly where it left off.
        stack: list[Iterator[str]] = [iter(successors.get(root, ()))]
        while stack:
            nxt = next(stack[-1], None)
            if nxt is None:
                color[path[-1]] = BLACK
                path.pop()
                stack.pop()
                continue
            state = color.get(nxt)
            if state == GRAY:
                cycle = path[path.index(nxt) :] + [nxt]
                if keep is None or keep(cycle):
                    return cycle
                continue
            if state == WHITE:
                color[nxt] = GRAY
                path.append(nxt)
                stack.append(iter(successors.get(nxt, ())))
    return None


def _check_observed_cycles(data: dict[str, Any], errors: list) -> None:
    """``observed_cycle`` (esm-spec §4.9.6): a cycle among a model's OBSERVED
    definitions.

    An observed unknown is *defined* by the RHS of the equation whose LHS names
    it (§6.3.1), so a model's observed definitions induce a dependency graph over
    the observed names: ``V -> W`` whenever ``W`` occurs free in ``V``'s defining
    RHS and ``W`` is itself an observed of the same model. A cycle in that graph
    means no evaluation order satisfies every definition, and the equations ALONE
    decide it — no shapes, no values, no solver — so it is a hard structural
    error here rather than something the build discovers.

    Naming the cycle is the requirement, not a nicety. A binding that lets the
    cycle through materializes the observeds in some order and then reads one
    that has no value yet, and the name it reports is whichever the walk reached
    first — typically an observed that is declared, referenced and defined
    perfectly well (issue #181: ``in_pbl``). This check replaces that
    mis-attribution with the names actually on the cycle.

    Emitted as ``(code, json_pointer, message, details)`` 4-tuples at
    ``/models/<M>``: a cycle belongs to no single equation, so it pins at the
    model exactly as ``equation_count_mismatch`` does. ``details["cycle"]`` is
    the path in traversal order with the entry node repeated to close it — a
    PATH, so it is ordered semantically, not lexicographically.

    One cycle is reported per model (the first the sorted DFS closes), the same
    search :func:`circular_dependency_cycle` runs over the whole document."""
    for mname, m in (data.get("models") or {}).items():
        if not isinstance(m, dict):
            continue
        variables = m.get("variables") or {}
        # `observed_definitions` is this binding's single answer to "which
        # unknowns are observed, and what defines each" — the same one
        # `cadence.py` resolves through — so the graph's NODE SET is exactly its
        # keys. An unknown with no defining equation (an ODE state, or one the
        # equation-balance check will report) is not a node and cannot be on a
        # cycle.
        definitions = observed_definitions(m)
        if not definitions:
            continue
        nodes = set(definitions)

        # Sorted successors (and sorted roots in the traversal): the walk must be
        # deterministic so the binding names the SAME cycle on every run.
        successors = {
            var: sorted(_observed_definition_reads(var, rhs, variables) & nodes)
            for var, rhs in definitions.items()
        }

        found = _first_observed_cycle(successors)
        if found is not None:
            joined = " -> ".join(found)
            errors.append(
                (
                    OBSERVED_CYCLE,
                    _pointer(f"models/{mname}"),
                    f"models/{mname}: observed definition cycle: {joined} — each of these "
                    f"observeds is defined in terms of the next, so no evaluation order "
                    f"satisfies every definition",
                    # `dependency_type` distinguishes this payload from
                    # `circular_dependency`'s, whose cycle crosses a scope
                    # boundary; the other four bindings emit the same pair.
                    {"cycle": found, "dependency_type": "observed_definitions"},
                )
            )


def _check_expression_arity(expr, errors: list[str], path: str) -> None:
    """Walk an expression tree and check operator arity."""
    if isinstance(expr, dict) and "op" in expr and "args" in expr:
        op = expr["op"]
        args = expr["args"]
        # `D` is the ONE op whose operand contract depends on a FIELD of the node
        # rather than on the op string alone (esm-spec §4.2 "Arity of `D`"): the
        # STRUCTURAL time derivative (`wrt: "t"`, or absent) is strictly unary,
        # while a REWRITE-TARGET `D` (spatial `wrt`) MAY carry unbounded trailing
        # auxiliary operands — the per-face boundary/halo values a discretization
        # rule binds and consumes (§9.6.8). The predicate lives in the registry so
        # this walk does not re-derive it.
        bounds = _OPERATOR_ARITY.get(op)
        if op_registry.is_rewrite_target_derivative(op, expr.get("wrt")):
            bounds = op_registry.REWRITE_TARGET_DERIVATIVE_ARITY_BOUNDS
        if bounds is not None:
            min_args, max_args = bounds
            n = len(args)
            if n < min_args:
                errors.append(f"{path}: operator '{op}' requires at least {min_args} args, got {n}")
            elif max_args is not None and n > max_args:
                errors.append(f"{path}: operator '{op}' accepts at most {max_args} args, got {n}")
        for i, arg in enumerate(args):
            _check_expression_arity(arg, errors, f"{path}/args[{i}]")


def _check_broadcast_fn(data: dict[str, Any], errors: list, path: str = "") -> None:
    """``broadcast`` nodes name a real scalar operator, applied at a legal arity
    (esm-spec §4.3.4).

    ``broadcast`` is the one op whose OPERATOR lives in a field (``fn``) rather
    than in ``op``, and every arity/vocabulary check walked ``args`` only — so
    ``fn`` was never validated by anything. A ``fn`` naming an op that does not
    exist (``"not_a_real_op"``), no ``fn`` at all, or a ``fn`` naming a
    non-scalar op such as ``faq`` all passed ``validate()`` cleanly and, at
    best, became a run-time table miss much later. Worse, a ONE-operand node
    silently returned its operand unchanged, so ``{"fn": "-", "args": [x]}``
    evaluated to ``+x`` — a dropped sign, no diagnostic anywhere (issue #101).

    Arity is checked against the registry's contract for the named op, so a
    ``fn`` requiring two operands given one is an error rather than a degenerate
    single-element fold. The n-ary ops keep folding over any operand count their
    bounds admit.
    """
    if isinstance(data, dict):
        if data.get("op") == "broadcast":
            fn = data.get("fn")
            n = len(data.get("args") or [])
            legal = op_registry.scalar_fn_names()
            if fn is None:
                errors.append(
                    f"{path}: `broadcast` node has no `fn` field naming the scalar "
                    f"operator to apply (esm-spec §4.3.4)"
                )
            elif not isinstance(fn, str) or fn not in legal:
                if isinstance(fn, str) and fn in op_registry.names():
                    errors.append(
                        f"{path}: `broadcast` fn {fn!r} names the non-scalar "
                        f"{op_registry.OPS[fn].category} op {fn!r}; `fn` must name a "
                        f"scalar operator (esm-spec §4.3.4)"
                    )
                else:
                    errors.append(
                        f"{path}: `broadcast` fn {fn!r} is not a registered operator; "
                        f"`fn` must name a scalar operator (esm-spec §4.3.4)"
                    )
            else:
                bounds = op_registry.effective_arity_bounds(fn)
                if bounds is not None:
                    lo, hi = bounds
                    if n < lo:
                        errors.append(
                            f"{path}: `broadcast` fn {fn!r} requires at least {lo} "
                            f"operand(s), got {n}"
                        )
                    elif hi is not None and n > hi:
                        errors.append(
                            f"{path}: `broadcast` fn {fn!r} accepts at most {hi} "
                            f"operand(s), got {n}"
                        )
        for key, value in data.items():
            _check_broadcast_fn(value, errors, f"{path}/{key}")
    elif isinstance(data, list):
        for i, value in enumerate(data):
            _check_broadcast_fn(value, errors, f"{path}[{i}]")


def _index_frame_sites(m: dict[str, Any], mname: str, var_axes: dict):
    """Every expression whose RESULT has a declared index-set frame, as
    ``(location, expression, target_name, target_axes)``.

    Two such sites exist, and they are exactly the two places an array-level
    operand is combined into a declared-shape result:

    * a whole-array state derivative ``D(var) = rhs`` (the frame is ``var``'s
      declared shape); and
    * an observed variable's ``expression`` (the frame is its own).

    An ``faq``-LHS equation is excluded: it declares its own frame through
    ``output_idx``/``ranges`` and is the oracle name-alignment reproduces.
    """
    for i, eq in enumerate(m.get("equations", []) or []):
        lhs = eq.get("lhs")
        if not (isinstance(lhs, dict) and lhs.get("op") == "D" and lhs.get("args")):
            continue
        target_name = lhs["args"][0]
        if not isinstance(target_name, str):
            continue
        target_axes = var_axes.get(target_name)
        if target_axes and "rhs" in eq:
            yield f"models/{mname}/equations[{i}]/rhs", eq["rhs"], target_name, target_axes

    for vname, vdef in (m.get("variables") or {}).items():
        if not isinstance(vdef, dict) or vdef.get("expression") is None:
            continue
        target_axes = var_axes.get(vname)
        if target_axes:
            yield (
                f"models/{mname}/variables/{vname}/expression",
                vdef["expression"],
                vname,
                target_axes,
            )


def _check_index_set_alignment(data: dict[str, Any], errors: list) -> None:
    """An array-level operand must be alignable to its result by index-set NAME
    (esm-spec §4.3.4 "Broadcast compatibility"; issue #100).

    Emitted as ``array_shape_mismatch``, the spelling registered in esm-spec
    §4.3.4 / CONFORMANCE_SPEC §7.1 and pinned by the shared fixture
    ``tests/invalid/array_broadcast/operand_index_set_not_in_result.esm``. The
    message and ``details`` payload deliberately mirror Rust's on that fixture
    (one finding per operand, naming the FIRST offending axis) so the two
    bindings' records compare equal rather than merely agreeing on the code.

    Shapes are fully known statically — ``ModelVariable.shape`` names index sets
    and the document registry gives their extents — so an operand carrying an
    axis the result does not have is decidable here, at validate() time. It used
    to be decided by arithmetic luck at RUN time instead: an operand whose
    element count happened not to divide the result's raised a size error, and
    one whose count happened to match was silently mis-broadcast onto whichever
    axes NumPy's right-to-left positional rule landed it on. A ``[lat]`` field in
    a ``[lon,lat,lev]`` result came out varying along ``lev``, with
    ``valid=True``, ``success=True`` and no warning.

    Only the UNALIGNABLE case is an error. A subset of the result's axes (which
    broadcasts) and a permutation of them (which transposes) are both legal and
    are handled by :mod:`earthsci_ast.index_alignment`.
    """
    for mname, m in (data.get("models") or {}).items():
        if not isinstance(m, dict):
            continue
        var_axes: dict[str, tuple[str, ...]] = {}
        for vname, vdef in (m.get("variables") or {}).items():
            if isinstance(vdef, dict):
                axes = index_alignment.declared_axes(vdef.get("shape"))
                if axes:
                    var_axes[vname] = axes
        if not var_axes:
            continue
        for location, expr, target, target_axes in _index_frame_sites(m, mname, var_axes):
            for leaf, axes in index_alignment.iter_named_operands(expr, var_axes):
                extra = index_alignment.unalignable_axes(axes, target_axes)
                if not extra:
                    continue
                # First offending axis only, one finding per operand — Rust
                # reports the same way, and a per-axis fan-out would make the
                # two bindings' record COUNTS differ on the shared fixture.
                axis = extra[0]
                errors.append(
                    (
                        _pointer(location),
                        f"Operand '{leaf}' of the array-level expression for "
                        f"'{target}' is declared over index set '{axis}', which "
                        f"'{target}' is not shaped over",
                        {
                            "variable": target,
                            "operand": leaf,
                            "operand_shape": list(axes),
                            "result_shape": list(target_axes),
                            "missing_index_set": axis,
                        },
                    )
                )


def _build_symbol_tables(data: dict[str, Any]) -> dict[str, Any]:
    """Build symbol tables for all systems and global symbols in the file."""
    models = {}
    # Top-level models included by reference (schema `models`
    # oneOf[Model, SubsystemRef]). Their variables live in the referenced file,
    # which is not loaded during structural validation, so they are registered
    # as known systems with no known variables and var-existence checks against
    # them are skipped (see _resolve_scoped_ref) — mirroring the leniency
    # already applied to subsystem-nested refs.
    ref_systems = set()
    for mname, m in data.get("models", {}).items():
        if isinstance(m, dict) and "ref" in m:
            ref_systems.add(mname)
            models[mname] = {}
            continue
        var_info = {}
        for vname, vdef in m.get("variables", {}).items():
            var_info[vname] = vdef
        models[mname] = var_info

    reaction_systems = {}
    for rsname, rs in data.get("reaction_systems", {}).items():
        # A top-level reaction system mounted by reference (§4.7 "Two mount
        # forms, one mechanism"): its species live in another file, so it is a
        # known system whose symbols are checked after resolution, as above.
        if isinstance(rs, dict) and "ref" in rs and "species" not in rs:
            ref_systems.add(rsname)
            reaction_systems[rsname] = {}
            continue
        sym_info = {}
        for sname, sdef in rs.get("species", {}).items():
            sym_info[sname] = {"type": "species", **sdef}
        for pname, pdef in rs.get("parameters", {}).items():
            sym_info[pname] = {"type": "parameter", **pdef}
        reaction_systems[rsname] = sym_info

    # Global symbol set: the UNION of every DECLARATION site. Reference integrity
    # (§4.9.5) is only as good as this set — a name that is genuinely declared but
    # missing here turns the false-negative fix into a FALSE-POSITIVE rejection,
    # which is a net loss. The sites are: every model variable/parameter, every
    # reaction species/parameter, the symbols the
    # DOCUMENT declares implicitly (the domain's independent variable and every
    # index-set / coordinate name — §5.3), and a coupling edge's
    # `config.callback_variables`, which a callback INJECTS into the target
    # system (§4.9.5 row (k); `tests/coupling/callback_examples.esm`).
    global_symbols = set(_BUILTIN_SYMBOLS) | _implicit_document_symbols(data)
    for m in models.values():
        global_symbols.update(m.keys())
    for rs in reaction_systems.values():
        global_symbols.update(rs.keys())
    for c in data.get("coupling", []) or []:
        if not isinstance(c, dict):
            continue
        for cv in (c.get("config") or {}).get("callback_variables") or []:
            name = cv.get("name") if isinstance(cv, dict) else None
            if isinstance(name, str):
                # A callback variable may be injected under a bare or a qualified
                # name; register both spellings' tail so either resolves.
                global_symbols.add(name)
                global_symbols.add(name.split(".")[-1])

    # A data source is NOT a system from 1.0.0: it is not a coupling endpoint,
    # not a subsystem, and not a path root in a scoped reference. It contributes
    # no symbols and no system name -- which is exactly what makes
    # `data_source_undefined` the ONLY way to name one wrongly.
    return {
        "models": models,
        "reaction_systems": reaction_systems,
        "data_sources": set(data.get("data_sources") or {}),
        "global_symbols": global_symbols,
        "all_systems": set(models.keys()) | set(reaction_systems.keys()),
        "ref_systems": ref_systems,
    }


def _resolve_scoped_ref(ref: str, tables: dict[str, Any]) -> tuple:
    """
    Resolve a scoped reference against the document's symbol tables.

    Scoped references are ARBITRARY DEPTH (esm-spec §4.6): ``System.var``,
    ``System.Sub.var``, ``A.B.C.d``. The path walks a chain of SUBSYSTEM mounts
    and ends at a variable. Splitting on ``"."`` and taking ``[0]`` / ``[-1]``
    is therefore only ever right for the two-part case: for ``A.B.c`` it asks
    whether ``c`` is a variable of ``A``, when ``c`` actually lives in ``A``'s
    subsystem ``B``.

    Only the DEPTH-2 case can be decided here. A deeper reference walks into a
    subsystem whose contents come from another FILE, which structural validation
    has not loaded — so it is deferred (``ok``) once its head names a real
    system, exactly as a ref-included model is. Resolution proper happens in
    ``resolve_subsystem_refs`` / flatten, which do have the mounted document.

    Returns ``(system_name, var_name, status)`` where status is one of:
    - ``'ok'``: resolved, or deferred to a layer that can resolve it
    - ``'no_system'``: the HEAD of the path is not a system in this document
    - ``'no_var'``: a depth-2 ref whose variable is not in the named system
    - ``'not_scoped'``: the ref has no dot
    """
    if "." not in ref:
        return (None, None, "not_scoped")
    parts = ref.split(".")
    system = parts[0]
    var = parts[-1]
    if system not in tables["all_systems"]:
        return (system, var, "no_system")
    # A model included by reference has its variables in another file not
    # available during structural validation — accept any var against it
    # (deferred to resolve_model_refs, which schema-validates the referenced
    # file, and to coupling/flatten resolution).
    if system in tables.get("ref_systems", set()):
        return (system, var, "ok")
    # Depth 3+: the tail names a symbol inside a SUBSYSTEM of `system`, not a
    # variable of `system` itself. The subsystem's contents live in another file,
    # so defer rather than test the tail against the wrong table.
    if len(parts) > 2:
        return (system, var, "ok")
    # Depth 2 — the only case this layer can actually decide.
    if system in tables["models"]:
        if var in tables["models"][system]:
            return (system, var, "ok")
    if system in tables["reaction_systems"]:
        if var in tables["reaction_systems"][system]:
            return (system, var, "ok")
    return (system, var, "no_var")


def _model_template_registry(data: dict[str, Any], model: dict[str, Any]) -> dict[str, Any]:
    """The expression-template registry VISIBLE to a model's expressions on the
    resolved document (§9.7 machinery already folded imports in): the top-level
    ``expression_templates`` block with the model's own block layered over it."""
    registry: dict[str, Any] = {}
    for block in (data.get("expression_templates"), model.get("expression_templates")):
        if isinstance(block, dict):
            registry.update({k: v for k, v in block.items() if isinstance(v, dict)})
    return registry


def _literal_param_map(registry: dict[str, Any]) -> dict[str, frozenset[str]]:
    """The literal-only half of :func:`_template_param_maps`."""
    return _template_param_maps(registry)[0]


def _from_param_map(registry: dict[str, Any]) -> dict[str, frozenset[str]]:
    """The index-set half of :func:`_template_param_maps`."""
    return _template_param_maps(registry)[1]


def _template_param_maps(
    registry: dict[str, Any],
) -> tuple[dict[str, frozenset[str]], dict[str, frozenset[str]]]:
    """Two maps from each template in ``registry`` to a set of its params, both
    following a param forwarded through a nested ``apply_expression_template``
    (``outer(S)`` calling ``inner(T = S)`` uses ``S`` wherever ``inner`` uses
    ``T``), built in one walk of the template bodies.

    The second map holds the params a body uses as a ``ranges`` ``from``
    (esm-spec §9.6.1: a substitution site whose bound value is an index-set
    name), so a call site's binding for one is checked as an index-set name.

    The first holds the param names a body consumes
    ONLY as a literal, never in a variable-reference position, directly or
    forwarded through a nested ``apply_expression_template``. Two literal
    positions exist:

    * a scalar-FIELD substitution site (esm-spec §9.6.1) — today the
      ``manifold`` field of the geometry ops, whose bound value is field
      vocabulary (the closed manifold set, CONFORMANCE_SPEC §5.8.4). The schema
      admits any string there so a body can carry a parameter name, and
      admissibility is enforced on the expanded form (§9.6.4,
      ``geometry_manifold_invalid``);
    * an argument of an ``enum`` op (esm-spec §4.5, §9.3). Substitution is
      position-blind (§9.6.3 constraint 5), so a string bound to such a param
      lands as an enum name or symbol, which the load-time lowering checks
      (``unknown_enum`` / ``unknown_enum_symbol``).

    A call-site STRING binding for such a param is therefore not an expression
    reference. A document is valid iff its expansion is (§9.6.9), and the other
    bindings validate references after expansion, where the literal sits in the
    ``manifold`` field or the ``enum`` op; this map is how the raw-stage walk
    reaches the same verdict. A param a body ALSO uses in a reference position
    is left out: its bound string is a reference there, and must be declared."""
    resolved: dict[str, tuple[frozenset[str], frozenset[str]]] = {}
    empty: tuple[frozenset[str], frozenset[str]] = (frozenset(), frozenset())

    def params_of(name: str, stack: tuple[str, ...]) -> tuple[frozenset[str], frozenset[str]]:
        if name in resolved:
            return resolved[name]
        if name in stack:  # cyclic template application — let the resolver report it
            return empty
        tpl = registry.get(name)
        if not isinstance(tpl, dict):
            return empty
        params = {p for p in tpl.get("params") or [] if isinstance(p, str)}
        literal: set[str] = set()
        referenced: set[str] = set()
        from_params: set[str] = set()
        stack = stack + (name,)
        nodes: list[Any] = [tpl.get("body")]
        while nodes:
            node = nodes.pop()
            if isinstance(node, list):
                nodes.extend(node)
                continue
            if not isinstance(node, dict):
                continue
            mf = node.get("manifold")
            if isinstance(mf, str) and mf in params:
                literal.add(mf)
            own_from = _from_params_of_node(node, params)
            literal.update(own_from)
            from_params.update(own_from)
            if node.get("op") == "enum":
                for a in node.get("args") or []:
                    if isinstance(a, str) and a in params:
                        literal.add(a)
                continue
            inner_name = node.get("name")
            bindings = node.get("bindings")
            if (
                node.get("op") == "apply_expression_template"
                and isinstance(inner_name, str)
                and isinstance(bindings, dict)
            ):
                inner_literal, inner_from = params_of(inner_name, stack)
                for k, v in bindings.items():
                    if isinstance(v, str) and v in params:
                        (literal if k in inner_literal else referenced).add(v)
                        if k in inner_from:
                            from_params.add(v)
            for field_name, child in iter_child_values(node):
                if field_name != "bindings" and isinstance(child, str) and child in params:
                    referenced.add(child)
            nodes.extend(node.values())
        resolved[name] = (frozenset(literal - referenced), frozenset(from_params))
        return resolved[name]

    maps = {name: params_of(name, ()) for name in registry}
    return (
        {name: m[0] for name, m in maps.items()},
        {name: m[1] for name, m in maps.items()},
    )


def _from_params_of_node(node: dict[str, Any], params: set[str]) -> set[str]:
    """The params a node's ``ranges`` name as a ``{"from": NAME}`` (esm-spec
    §9.6.1: a substitution site whose bound value is an index-set name)."""
    ranges = node.get("ranges")
    if not isinstance(ranges, dict):
        return set()
    return {
        spec["from"]
        for spec in ranges.values()
        if isinstance(spec, dict) and isinstance(spec.get("from"), str) and spec["from"] in params
    }


def _iter_template_calls(expr: Any):
    """Every ``apply_expression_template`` node in ``expr``."""
    stack = [expr]
    while stack:
        e = stack.pop()
        if isinstance(e, list):
            stack.extend(e)
        elif isinstance(e, dict):
            if e.get("op") == "apply_expression_template":
                yield e
            stack.extend(e.values())


def _strip_literal_bindings(expr: Any, literal_map: dict[str, frozenset[str]]) -> Any:
    """Non-mutating copy of ``expr`` with every ``apply_expression_template``
    node's STRING bindings for literal-only params (see
    :func:`_literal_param_map`) removed, so the reference walker does not read
    field vocabulary (``manifold: "planar"``) or an enum symbol as a variable
    reference. Expression-valued bindings are kept — their references are real."""
    if isinstance(expr, list):
        return [_strip_literal_bindings(x, literal_map) for x in expr]
    if not isinstance(expr, dict):
        return expr
    out = {k: _strip_literal_bindings(v, literal_map) for k, v in expr.items()}
    name = out.get("name")
    bindings = out.get("bindings")
    if (
        out.get("op") == "apply_expression_template"
        and isinstance(name, str)
        and isinstance(bindings, dict)
    ):
        sf = literal_map.get(name, frozenset())
        if sf:
            out["bindings"] = {
                k: v for k, v in bindings.items() if not (k in sf and isinstance(v, str))
            }
    return out


def _check_variable_references(
    data: dict[str, Any], tables: dict[str, Any], errors: list[str]
) -> None:
    """
    Check variable references in every EXPRESSION-BEARING field of a model.

    Two flavors of check:
    1. Scoped refs (Model.var): system must exist; for 2-part refs the var must exist
       in the named system. Deeper refs walk subsystem mounts and are deferred (§4.6).
    2. Bare-string refs: every ref must resolve to a symbol declared somewhere in
       the file (or implicitly by the document — see
       :func:`_implicit_document_symbols`).

    Reference integrity applies to every field that CARRIES an expression, not
    just ``equations``. An observed variable's ``expression`` is a governing
    definition like any other, and an undefined name inside one used to be
    invisible — a silent FALSE NEGATIVE that no fixture pinned. The
    expression-bearing sites are enumerated by :func:`_model_expression_sites`.

    Within an expression, the walker (:func:`_walk_expression_strings`) descends
    the full child-field set — ``args``, ``expr``, ``axes``, ``lower``, ``upper``,
    ``filter``, ``key``, ``values``, ``bindings``, ``regions`` — so a reference
    hidden in an aggregate body, a filter predicate, an integral bound, a Skolem
    key or a ``makearray`` region bound is visible here. Index symbols BOUND by
    the expression's own aggregate/makearray/integral nodes are collected via
    :func:`_expression_bound_symbols` and skipped: they are binders, not
    references (esm-spec §5).
    """
    global_symbols = tables["global_symbols"]
    for m, sites in _component_reference_sites(data):
        subsystems = m.get("subsystems") or {}
        # Literal-only template params (§9.6.1 scalar fields, §9.3 `enum` args):
        # a call-site STRING binding for one is field vocabulary
        # (`manifold: "planar"`) or an enum symbol, not a reference — strip
        # those bindings before the reference walk (never mutating the
        # document). See :func:`_literal_param_map`.
        literal_map = _literal_param_map(_model_template_registry(data, m))
        for location, expr, check_bare, phrase, extra in sites:
            bound_symbols = _expression_bound_symbols(expr)
            if literal_map:
                expr = _strip_literal_bindings(expr, literal_map)
            for ref in _walk_expression_strings(expr):
                # `_var` is the reserved operator placeholder (spec §6.4): in an
                # operator-style model it is substituted with each matching state
                # variable of the target system at operator_compose time. It is
                # never a declared symbol, so it is a valid reference at ANY
                # nesting depth — not merely in the top-level `D(_var)` position
                # but also nested, as in the advection idiom `grad(_var, dim)`.
                if ref == "_var":
                    continue
                # A symbol BOUND by an aggregate/makearray/integral in this
                # expression (a contracted index like `i`/`j`/`e`, or an
                # integration variable) is a binder, not a reference. It is in
                # scope inside the construct that introduces it.
                if ref in bound_symbols:
                    continue
                if "." in ref:
                    # A ref whose HEAD is a SUBSYSTEM of the current model is
                    # subsystem-LOCAL dot-notation, not a `System.var` reference.
                    # A pure-I/O data-loader mounted as a subsystem (RFC
                    # pure-io-data-loaders §4.3) is consumed by the owning model's
                    # own equations this way — `raw.elevation` for
                    # `models.<mname>.subsystems.raw` — and flatten lowers it to
                    # the observed `<mname>.raw.elevation`. Its target lives in the
                    # mounted file, so it is deferred to flatten. This holds at ANY
                    # depth (`raw.grid.elevation`), so the HEAD — not a fixed part
                    # count — is what decides it.
                    if ref.split(".")[0] in subsystems:
                        continue
                    # Arbitrary depth (§4.6): _resolve_scoped_ref decides the
                    # depth-2 case and defers deeper ones once their head names a
                    # real system.
                    system, var, status = _resolve_scoped_ref(ref, tables)
                    if status == "no_system":
                        errors.append(
                            f"{location}: reference '{ref}' to undefined system '{system}'"
                        )
                    elif status == "no_var":
                        errors.append(
                            f"{location}: reference '{ref}' — variable '{var}' not found "
                            f"in system '{system}'"
                        )
                elif check_bare and ref not in global_symbols:
                    # Report against the field that actually CARRIES the defect, in
                    # the corpus-pinned message/details shape. `details.variable` is
                    # the settled key across bindings (CONFORMANCE_SPEC row (j)).
                    if phrase is None:
                        errors.append(
                            (
                                _pointer(location),
                                f"Variable '{ref}' referenced in equation is not declared",
                                {"variable": ref, **extra},
                            )
                        )
                    else:
                        errors.append(
                            (
                                _pointer(location),
                                f'Variable "{ref}" referenced in {phrase} but not declared',
                                {"variable": ref},
                            )
                        )


_ELEMENT_SUFFIX = re.compile(r"^(.*?)\[[^\]]*\]$")


def _strip_element_suffix(name: str) -> tuple[str, bool]:
    """``u[1]`` -> ``("u", True)``; a name without an element suffix is unchanged."""
    m = _ELEMENT_SUFFIX.match(name)
    return (m.group(1), True) if m else (name, False)


def _pointer_token(key: str) -> str:
    """Escape one JSON Pointer reference token (RFC 6901)."""
    return key.replace("~", "~0").replace("/", "~1")


def _test_target_declarations(component: dict[str, Any], section: str) -> dict[str, Any]:
    """The names an inline test's assertion may target by a bare name, mapped to
    the declared ``shape`` (``None`` when absent): a model's ``variables``, or a
    reaction system's ``species`` (which carry no shape) and ``parameters``."""
    if section == "models":
        return {
            n: (v.get("shape") if isinstance(v, dict) else None)
            for n, v in (component.get("variables") or {}).items()
        }
    out: dict[str, Any] = {n: None for n in (component.get("species") or {})}
    for n, v in (component.get("parameters") or {}).items():
        out[n] = v.get("shape") if isinstance(v, dict) else None
    return out


def _declared_override_names(data: dict[str, Any]) -> tuple[set, set, bool]:
    """The document's declared names qualified as a flatten qualifies them
    (``<component>.<name>``, ``<component>.<subsystem>.<name>`` at any depth),
    the component and subsystem names rule 2 of esm-spec §6.6.2 validates a
    key's leading segments against, and whether every mount is resolved."""
    names: set = set()
    namespaces: set = set()
    complete = True

    def walk(prefix: str, component: Any, section: str) -> None:
        nonlocal complete
        if not isinstance(component, dict) or "ref" in component:
            complete = False
            return
        namespaces.add(prefix.rsplit(".", 1)[-1])
        for name in _test_target_declarations(component, section):
            names.add(f"{prefix}.{name}")
        for sub_name, sub in (component.get("subsystems") or {}).items():
            walk(f"{prefix}.{sub_name}", sub, section)

    for section in ("models", "reaction_systems"):
        for cname, component in (data.get(section) or {}).items():
            walk(cname, component, section)
    return names, namespaces, complete


def _override_key_matches(key: str, names: set, namespaces: set) -> bool:
    """Whether ``key`` reaches a declared name under esm-spec §6.6.2 rules 1-3:
    an exact hit; a dotted suffix of the key that is a name, every dropped
    leading segment naming a component or subsystem; or the key a dotted suffix
    of some name. Ambiguity is a runtime diagnostic, so one match suffices."""
    if key in names:
        return True
    parts = key.split(".")
    for i in range(1, len(parts)):
        if ".".join(parts[i:]) in names and all(p in namespaces for p in parts[:i]):
            return True
    tail = "." + key
    return any(n.endswith(tail) for n in names)


def _check_inline_tests(data: dict[str, Any], errors: list) -> None:
    """Static checks on every inline test (esm-spec §6.6):

    * an assertion ``variable`` that is a bare name (element suffix removed) the
      component does not declare is ``undefined_variable`` (§6.6.3); a dotted
      target is resolved by the runtime;
    * an ``initial_conditions`` / ``parameter_overrides`` key that matches no
      declared name is ``unknown_override_key`` (§6.6.2); skipped when the
      document holds an unresolved mount a key could name into;
    * an assertion whose form does not match the declared rank of its target is
      ``assertion_rank_mismatch`` (§6.6.5).
    """
    names, namespaces, complete = _declared_override_names(data)
    for section in ("models", "reaction_systems"):
        for cname, component in (data.get(section) or {}).items():
            if not isinstance(component, dict) or "ref" in component:
                continue
            declared = _test_target_declarations(component, section)
            for ti, test in enumerate(component.get("tests") or []):
                if not isinstance(test, dict):
                    continue
                base = f"/{section}/{cname}/tests/{ti}"
                if complete:
                    for field in ("initial_conditions", "parameter_overrides"):
                        for key in test.get(field) or {}:
                            bare_key, _ = _strip_element_suffix(key)
                            if not _override_key_matches(bare_key, names, namespaces):
                                errors.append(
                                    (
                                        "unknown_override_key",
                                        f"{base}/{field}/{_pointer_token(key)}",
                                        f'Override key "{key}" in {field} matches no declared name',
                                        {"key": key, "field": field},
                                    )
                                )
                for ai, assertion in enumerate(test.get("assertions") or []):
                    if not isinstance(assertion, dict):
                        continue
                    target = assertion.get("variable")
                    if not isinstance(target, str):
                        continue
                    bare, is_element = _strip_element_suffix(target)
                    if "." in bare:
                        continue
                    pointer = f"{base}/assertions/{ai}"
                    if bare not in declared:
                        errors.append(
                            (
                                "undefined_variable",
                                f"{pointer}/variable",
                                f'Variable "{bare}" referenced in assertion variable '
                                f"but not declared",
                                {"variable": bare},
                            )
                        )
                        continue
                    if is_element:
                        continue
                    shape = declared[bare]
                    shape = list(shape) if isinstance(shape, list) else []
                    selects = (
                        assertion.get("coords") is not None or assertion.get("reduce") is not None
                    )
                    if shape and not selects:
                        errors.append(
                            (
                                "assertion_rank_mismatch",
                                pointer,
                                f'Assertion on shaped variable "{bare}" selects no scalar '
                                f"(give coords, reduce, or an element name)",
                                {"variable": bare, "shape": shape},
                            )
                        )
                    elif not shape and selects:
                        errors.append(
                            (
                                "assertion_rank_mismatch",
                                pointer,
                                f'Assertion on scalar variable "{bare}" carries coords or reduce',
                                {"variable": bare, "shape": []},
                            )
                        )


def _update_rules_with_paths(update: Any):
    """Yield ``(path_suffix, rule)`` for a parameter's ``update``: ``("", rule)``
    for the single-rule object form and ``("[i]", rule)`` for each entry of the
    ordered array form (esm-spec §5.4)."""
    if isinstance(update, dict):
        yield "", update
    elif isinstance(update, list):
        for i, rule in enumerate(update):
            yield f"[{i}]", rule


def _lhs_is_closed_definition(lhs: Any, declared: set) -> bool:
    """True when an equation's LHS makes it a closed local definition: a
    derivative, or a bare / indexed reference to a locally declared variable."""
    if isinstance(lhs, str):
        return lhs in declared
    if not isinstance(lhs, dict):
        return False
    op = lhs.get("op")
    if op == "D":
        return True
    if op in ("index", "ic"):
        args = lhs.get("args") or []
        return bool(args) and _lhs_is_closed_definition(args[0], declared)
    if op == "faq":
        return _lhs_is_closed_definition(lhs.get("expr"), declared)
    return False


def _model_expression_sites(m: dict[str, Any], mname: str):
    """Every EXPRESSION-BEARING field of a model, as
    ``(location, expression, check_bare_names, phrase)``.

    This is the ONE shared traversal esm-spec §4.9.5 prescribes. Reference
    integrity applies to every field that CARRIES an expression, not just
    ``equations``: the walkers descended ``equations`` (and reaction ``rate``)
    and NOTHING else, so an undefined name in any of the other nine model sites
    was invisible — a silent FALSE NEGATIVE in every binding, pinned now by
    ``tests/invalid/undefined_variable_in_*.esm``.

    ``location`` is the slash-delimited path that :func:`_json_pointer_from_message`
    turns into the JSON Pointer reported with the finding, so an error names the
    field that actually carries the defect.

    ``phrase`` names the site in the emitted message (``None`` for an equation,
    which keeps its established finding shape).

    ``check_bare_names`` gates the BARE-name check (scoped refs are always
    checked). An equation's RHS is checked only when the LHS is a derivative: a
    plain assignment-style equation is the shape an operator-composed model uses
    for values coupled in from another system, which are not declared locally.
    Every other site is a closed definition — every name in it must resolve.
    """
    declared = set(m.get("variables") or {})
    for i, eq in enumerate(m.get("equations", []) or []):
        lhs = eq.get("lhs")
        # An equation is a CLOSED definition -- every bare name in its RHS must
        # resolve -- when its LHS is a derivative or names a locally declared
        # unknown. The latter is the 1.0.0 observed form: what used to live in
        # `variables[v].expression` (and was checked) is now a bare-variable-LHS
        # equation, so exempting every non-derivative LHS would reopen exactly
        # the false negative `_model_expression_sites` was written to close.
        # The exemption that remains is the operator-composed shape, whose LHS
        # names no local variable and whose RHS is coupled in from elsewhere.
        closed = _lhs_is_closed_definition(lhs, declared)
        for side in ("lhs", "rhs"):
            if side in eq:
                yield (
                    f"models/{mname}/equations[{i}]/{side}",
                    eq[side],
                    closed and side == "rhs",
                    None,
                    {"equation_index": i, "expected_in": "variables"},
                )

    # A parameter's `update` carries expression positions (esm-spec §5.4): the
    # `condition`/`crossing` trigger, the `expression` value form, and the `from`
    # binding's `unit_conversion` (§8.5). All are subject to reference integrity;
    # the last of these used to live on the data loader and is the one site that
    # MOVED into `models` with 1.0.0.
    for vname, vdef in (m.get("variables") or {}).items():
        if not isinstance(vdef, dict):
            continue
        for suffix, rule in _update_rules_with_paths(vdef.get("update")):
            base = f"models/{mname}/variables/{vname}/update{suffix}"
            if not isinstance(rule, dict):
                continue
            if rule.get("when") is not None:
                yield (f"{base}/when", rule["when"], True, "parameter update trigger", {})
            if rule.get("expression") is not None:
                yield (
                    f"{base}/expression",
                    rule["expression"],
                    True,
                    "parameter update expression",
                    {},
                )
            binding = rule.get("from")
            if isinstance(binding, dict) and binding.get("unit_conversion") is not None:
                yield (
                    f"{base}/from/unit_conversion",
                    binding["unit_conversion"],
                    True,
                    "unit_conversion expression",
                    {},
                )

    for vname, expr in (m.get("guesses") or {}).items():
        yield (f"models/{mname}/guesses/{vname}", expr, True, "guesses expression", {})

    for i, eq in enumerate(m.get("initialization_equations", []) or []):
        if not isinstance(eq, dict):
            continue
        for side in ("lhs", "rhs"):
            if side in eq:
                yield (
                    f"models/{mname}/initialization_equations[{i}]/{side}",
                    eq[side],
                    True,
                    "initialization equation",
                    {},
                )

    yield from _event_expression_sites(m, f"models/{mname}")
    yield from _test_reference_sites(m, f"models/{mname}")


def _event_expression_sites(component: dict[str, Any], location: str):
    """A component's continuous- and discrete-event expressions, in the
    :func:`_model_expression_sites` tuple shape. An event is the same site on a
    reaction system as on a model, so both component kinds share this."""
    for i, ev in enumerate(component.get("continuous_events", []) or []):
        if not isinstance(ev, dict):
            continue
        for j, cond in enumerate(ev.get("conditions", []) or []):
            yield (
                f"{location}/continuous_events[{i}]/conditions[{j}]",
                cond,
                True,
                "continuous event condition",
                {},
            )
        for key in ("affects", "affect_neg"):
            for j, aff in enumerate(ev.get(key, []) or []):
                if isinstance(aff, dict) and "rhs" in aff:
                    yield (
                        f"{location}/continuous_events[{i}]/{key}[{j}]/rhs",
                        aff["rhs"],
                        True,
                        "continuous event affect RHS",
                        {},
                    )

    for i, ev in enumerate(component.get("discrete_events", []) or []):
        if not isinstance(ev, dict):
            continue
        trigger = ev.get("trigger")
        if isinstance(trigger, dict) and trigger.get("expression") is not None:
            yield (
                f"{location}/discrete_events[{i}]/trigger/expression",
                trigger["expression"],
                True,
                "discrete event trigger expression",
                {},
            )
        for j, aff in enumerate(ev.get("affects", []) or []):
            if isinstance(aff, dict) and "rhs" in aff:
                yield (
                    f"{location}/discrete_events[{i}]/affects[{j}]/rhs",
                    aff["rhs"],
                    True,
                    "discrete event affect RHS",
                    {},
                )


def _reaction_system_expression_sites(rs: dict[str, Any], rsname: str):
    """A reaction system's reference sites outside its reaction rates: its
    constraint equations, events and inline-test references. Each is the same
    site as on a model and reports ``undefined_variable`` as the model's does;
    a reaction ``rate`` keeps ``undefined_parameter`` (:func:`_check_reaction_systems`)."""
    location = f"reaction_systems/{rsname}"
    for i, eq in enumerate(rs.get("constraint_equations", []) or []):
        if not isinstance(eq, dict):
            continue
        for side in ("lhs", "rhs"):
            if side in eq:
                yield (
                    f"{location}/constraint_equations[{i}]/{side}",
                    eq[side],
                    True,
                    None,
                    {"equation_index": i, "expected_in": "variables"},
                )
    yield from _event_expression_sites(rs, location)
    yield from _test_reference_sites(rs, location)


def _test_reference_sites(component: dict[str, Any], location: str):
    """An inline test's assertion ``reference`` expressions (§6.6), in the
    :func:`_model_expression_sites` tuple shape. A test is the same site on a
    reaction system as on a model, so both component kinds share this."""
    for i, t in enumerate(component.get("tests", []) or []):
        if not isinstance(t, dict):
            continue
        for j, a in enumerate(t.get("assertions", []) or []):
            if isinstance(a, dict) and a.get("reference") is not None:
                yield (
                    f"{location}/tests[{i}]/assertions[{j}]/reference",
                    a["reference"],
                    True,
                    "assertion reference expression",
                    {},
                )


def _component_reference_sites(data: dict[str, Any]):
    """Yield ``(component, sites)`` for every component whose expressions the
    reference-integrity check walks: each model's full site list, and each
    reaction system's sites outside its reaction rates."""
    for mname, m in (data.get("models") or {}).items():
        if isinstance(m, dict):
            yield m, _model_expression_sites(m, mname)
    for rsname, rs in (data.get("reaction_systems") or {}).items():
        if isinstance(rs, dict):
            yield rs, _reaction_system_expression_sites(rs, rsname)


def _pointer(location: str) -> str:
    """Slash/bracket location (``models/M/equations[0]/rhs``) -> JSON Pointer."""
    return "/" + location.replace("[", "/").replace("]", "").strip("/")


def _check_coupling_expressions(
    data: dict[str, Any], tables: dict[str, Any], errors: list[str]
) -> None:
    """§4.9.5: the two Expression-bearing fields of a coupling edge — a
    connector equation's ``expression`` and a ``variable_map``'s Expression-form
    ``transform``. Coupling refs are FULLY QUALIFIED (§4.6), so an unresolvable
    name here is an ``unresolved_scoped_ref``, not an ``undefined_variable``.
    Bare names are left alone: a coupling expression may legitimately name the
    edge's own operands, which are not document symbols.
    """
    # A coupling LIBRARY names roles, not systems, at every §10.10.2 occurrence
    # site, and holds no systems to resolve against (esm-spec §10.9); its refs
    # are checked by _check_coupling_role_references instead.
    if "coupling_roles" in data:
        return

    def check(expr, pointer: str, what: str) -> None:
        bound = _expression_bound_symbols(expr)
        for ref in _walk_expression_strings(expr):
            if ref == "_var" or ref in bound or "." not in ref:
                continue
            _system, _var, status = _resolve_scoped_ref(ref, tables)
            if status in ("no_system", "no_var"):
                errors.append(
                    (
                        "unresolved_scoped_ref",
                        pointer,
                        f'Variable "{ref}" referenced in {what} does not resolve',
                        {"variable": ref},
                    )
                )

    for i, c in enumerate(data.get("coupling", []) or []):
        if not isinstance(c, dict):
            continue
        connector = c.get("connector")
        if isinstance(connector, dict):
            for j, eq in enumerate(connector.get("equations", []) or []):
                if isinstance(eq, dict) and eq.get("expression") is not None:
                    check(
                        eq["expression"],
                        f"/coupling/{i}/connector/equations/{j}/expression",
                        "connector equation expression",
                    )
        # `transform` is a string (a named transform like "additive") OR an
        # Expression; only the Expression form carries references.
        transform = c.get("transform")
        if isinstance(transform, dict):
            check(
                transform,
                f"/coupling/{i}/transform",
                "variable_map Expression transform",
            )


def _check_coupling_systems(
    data: dict[str, Any], tables: dict[str, Any], errors: list[str]
) -> None:
    """A coupling entry's ``systems`` list must name systems the document
    declares. Nothing checked it, so a coupling edge could compose against a
    system that exists nowhere and the document still validated
    (``tests/invalid/undefined_system.esm``).
    """
    # A coupling LIBRARY names roles, not systems, at every §10.10.2 occurrence
    # site, and holds no systems to resolve against (esm-spec §10.9); its refs
    # are checked by _check_coupling_role_references instead.
    if "coupling_roles" in data:
        return
    all_systems = tables["all_systems"]
    for i, c in enumerate(data.get("coupling", []) or []):
        if not isinstance(c, dict):
            continue
        for name in c.get("systems", []) or []:
            if not isinstance(name, str):
                continue
            # A `systems` entry may be a DOTTED path naming a SUBSYSTEM at
            # arbitrary depth (`EmissionSources.Biogenic.Forest`, §4.6). Only the
            # HEAD is decidable from this document — a deeper mount's target may
            # live in a referenced file — so resolve the head and defer the rest,
            # the same posture the variable/scoped-ref checks take.
            head = name.split(".")[0]
            if head not in all_systems:
                errors.append(
                    (
                        f"/coupling/{i}/systems",
                        f'Coupling entry references nonexistent system "{name}"',
                        {"system": name},
                    )
                )


def _check_coupling_role_references(data: dict[str, Any], errors: list) -> None:
    """Resolve a coupling library's role-scoped refs against its declared roles.

    esm-spec §10.9 suspends ordinary §4.6 system resolution for a library
    validated on its own and requires the top-level segment at every §10.10.2
    occurrence site to name a declared role instead. The site walk is shared with
    the import-time check in :mod:`earthsci_ast.coupling_imports`, so the two
    cannot drift apart.
    """
    from .coupling_imports import _collect_role_segments

    roles = data.get("coupling_roles") or {}
    for i, c in enumerate(data.get("coupling", [])):
        if not isinstance(c, dict):
            continue
        for role in sorted(seg for seg in _collect_role_segments(c) if seg not in roles):
            errors.append(
                (
                    COUPLING_EDGE_UNKNOWN_ROLE,
                    f"/coupling/{i}",
                    f"coupling[{i}]: edge references '{role}', which is not a declared "
                    f"role (esm-spec §10.9: a coupling library's refs name a role in "
                    f"`coupling_roles`)",
                    {"role": role, "expected_in": "coupling_roles"},
                )
            )


def _check_coupling_references(
    data: dict[str, Any], tables: dict[str, Any], errors: list[str]
) -> None:
    """Check that coupling 'from' references resolve to valid scoped refs.
    'to' is intentionally lenient since variable_map can introduce new target vars."""
    # In a coupling-library file (esm-spec §10.9) the from/to prefixes name
    # declared ROLES, not systems, and the library holds no models by
    # definition — resolving them against the symbol tables would reject every
    # well-formed library. `coupling_roles` is the sole positive identifier of
    # the kind.
    if "coupling_roles" in data:
        _check_coupling_role_references(data, errors)
        return
    for i, c in enumerate(data.get("coupling", [])):
        ref = c.get("from")
        if not isinstance(ref, str) or "." not in ref:
            continue
        # Scoped refs are ARBITRARY DEPTH (§4.6). _resolve_scoped_ref decides the
        # depth-2 case and defers deeper ones (their target lives in a mounted
        # file) once their head names a real system.
        system, var, status = _resolve_scoped_ref(ref, tables)
        if status == "no_system":
            errors.append(f"coupling[{i}]/from: reference '{ref}' to undefined system '{system}'")
        elif status == "no_var":
            errors.append(
                f"coupling[{i}]/from: reference '{ref}' — variable '{var}' not provided by '{system}'"
            )


def _wire_expression(expr: Any) -> Any:
    """``expr`` in its wire (dict) spelling: the reference walkers here read
    dicts, and :func:`circular_dependency_cycle` also runs on a parsed
    :class:`~earthsci_ast.esm_types.EsmFile` whose expressions are ExprNodes."""
    if isinstance(expr, (dict, str, int, float)) or expr is None:
        return expr
    from .serialize import _serialize_expression

    return _serialize_expression(expr)


def _member_names(component: Any) -> list[str]:
    """The names a component declares: a model's ``variables``, a reaction
    system's ``species`` and ``parameters`` (a mapping, or a list of named
    entries), in either the dict or the dataclass spelling."""
    names = list(_variables(component))
    for attr in ("species", "parameters"):
        members = _field(component, attr)
        if isinstance(members, Mapping):
            names.extend(members)
        elif isinstance(members, (list, tuple)):
            names.extend(n for n in (_field(m, "name") for m in members) if isinstance(n, str))
    return names


def _declared_scoped_names(document: Any) -> set[str]:
    """The full scoped name of every member of every top-level model and
    reaction system and of their subsystems at every depth: what a dotted
    reference can resolve to (esm-spec §4.6). A ``{"ref"}`` mount edge not yet
    resolved contributes nothing."""
    out: set[str] = set()

    def walk(prefix: str, component: Any) -> None:
        if isinstance(component, Mapping) and "ref" in component:
            return
        out.update(f"{prefix}.{name}" for name in _member_names(component))
        subsystems = _field(component, "subsystems") or {}
        if isinstance(subsystems, Mapping):
            for name, sub in subsystems.items():
                walk(f"{prefix}.{name}", sub)

    for section in ("models", "reaction_systems"):
        components = _field(document, section) or {}
        if isinstance(components, Mapping):
            for name, component in components.items():
                walk(name, component)
    return out


def _resolve_scoped_name(scope: str, name: str, declared: set[str]) -> str:
    """The full scoped name ``name`` resolves to when read in the model node
    at ``scope``, with the reference-integrity precedence (esm-spec §4.8.4, "A
    scoped reference carries its target's units"; §4.9.7): the node's own
    names for a bare name; for a dotted one, a path relative to the node's own
    subsystems when it names a declared member — winning even when that member
    is not an observed — and otherwise a top-level system path."""
    if "." not in name:
        return f"{scope}.{name}"
    relative = f"{scope}.{name}"
    return relative if relative in declared else name


def circular_dependency_cycle(document: Any) -> list[str] | None:
    """The §4.9.7 ``circular_dependency`` cycle of ``document``, or ``None``.

    ``document`` is either the raw dict (the load-time pass) or a parsed
    :class:`~earthsci_ast.esm_types.EsmFile` (``validate``); both are walked
    through :func:`earthsci_ast.classification.model_nodes`, the binding's one
    walk over top-level models and their subsystems at every depth. A
    subsystem still held as a ``{"ref": ...}`` mount edge is not a model node
    until it is resolved, so the raw-dict pass cannot see into it; the parsed
    document has it resolved, which is why ``load`` re-runs this after mounting
    a document that has refs and why ``validate`` runs it on the parsed tree.

    The graph is §4.9.6's built over the whole document. Its nodes are the
    OBSERVED unknowns of every model node by full scoped name: the keys of
    :func:`~earthsci_ast.classification.observed_definitions`, the same
    classification ``observed_cycle`` uses, so ODE states, algebraic unknowns,
    parameters and unknowns with no defining equation are not nodes. An
    unknown another model puts under ``D(·, t)`` through its scoped name is an
    ODE state too and is removed. ``V -> W`` when ``W`` is in
    :func:`_observed_definition_reads` of ``V`` (the §4.9.6 walk, with its
    recurrence self-edge exemption), resolved by :func:`_resolve_scoped_name`
    from ``V``'s model node, and only a name that resolves to a node is an
    edge. The scoped name under a ``D`` resolves the same way.

    The search is the pinned one: roots and successors in lexicographic order,
    and the first back edge whose cycle crosses a scope boundary is reported. A
    cycle whose nodes all share one model node is that node's
    ``observed_cycle``, so it is skipped and the search continues."""
    definitions: dict[str, tuple[str, Any, dict[str, Any]]] = {}
    scoped_derivatives: list[tuple[str, str]] = []
    for path, model in model_nodes(document):
        variables = _variables(model)
        for var, rhs in observed_definitions(model).items():
            definitions[f"{path}.{var}"] = (var, _wire_expression(rhs), variables)
        for equation in _equations(model):
            scoped_derivatives.extend(
                (path, name) for name in _derivative_targets(_field(equation, "lhs")) if "." in name
            )
    if not definitions:
        return None
    declared = _declared_scoped_names(document)
    nodes = set(definitions) - {
        _resolve_scoped_name(scope, name, declared) for scope, name in scoped_derivatives
    }
    if not nodes:
        return None

    successors: dict[str, list[str]] = {}
    for scoped in nodes:
        var, rhs, variables = definitions[scoped]
        scope = scoped.rsplit(".", 1)[0]
        resolved = {
            _resolve_scoped_name(scope, name, declared)
            for name in _observed_definition_reads(var, rhs, variables)
        }
        successors[scoped] = sorted(resolved & nodes)

    def crosses_scopes(cycle: list[str]) -> bool:
        return len({name.rsplit(".", 1)[0] for name in cycle}) > 1

    return _first_observed_cycle(successors, keep=crosses_scopes)


def circular_dependency_record(cycle: list[str]) -> tuple[str, str, str, dict[str, Any]]:
    """The pinned ``(code, path, message, details)`` of a §4.9.7 cycle. A cycle
    belongs to no single model, so it pins at ``/models``."""
    return (
        CIRCULAR_DEPENDENCY,
        "/models",
        f"Circular dependency among observeds: {' → '.join(cycle)}",
        {"cycle": cycle},
    )


def _refuse_circular_dependency(esm_file: Any) -> None:
    """Raise :class:`StructuralValidationError` when the parsed, mounted
    ``esm_file`` has a §4.9.7 cycle: ``load``'s refusal for a cycle that runs
    through a ``{"ref"}`` mount the raw-dict pass could not see into."""
    cycle = circular_dependency_cycle(esm_file)
    if cycle is None:
        return
    code, path, message, details = circular_dependency_record(cycle)
    raise _structural_validation_error_cls()(
        f"Structural validation failed:\n  - {message}",
        findings=[(code, message)],
        records=[{"code": code, "path": path, "message": message, "details": details}],
    )


def _check_circular_references(data: dict[str, Any], errors: list) -> None:
    """``circular_dependency`` (esm-spec §4.9.7): a cycle among OBSERVED
    unknowns that crosses a model or subsystem boundary. See
    :func:`circular_dependency_cycle`."""
    cycle = circular_dependency_cycle(data)
    if cycle is not None:
        errors.append(circular_dependency_record(cycle))


def _check_data_source_references(data: dict[str, Any], errors: list[str]) -> None:
    """``data_source_undefined``: a parameter whose ``update.source`` names no
    declared ``data_sources`` entry (esm-spec §8).

    A source is not a component from 1.0.0, so ``update.source`` is the ONLY way
    a document can name one — and it is schema-valid by construction (any
    string), which is what makes this a genuinely reachable structural finding
    rather than one masked by a schema error.
    """
    declared = data.get("data_sources") or {}
    available = sorted(declared) if isinstance(declared, dict) else []
    for mname, m in data.get("models", {}).items():
        if not isinstance(m, dict):
            continue
        for vname, vdef in (m.get("variables") or {}).items():
            if not isinstance(vdef, dict):
                continue
            for suffix, rule in _update_rules_with_paths(vdef.get("update")):
                if not isinstance(rule, dict) or rule.get("kind") != "data":
                    continue
                source = rule.get("source")
                if source in available:
                    continue
                errors.append(
                    (
                        f"/models/{mname}/variables/{vname}/update{suffix.replace('[', '/').replace(']', '')}",
                        f"Parameter update names data source '{source}', which the "
                        f"document does not declare",
                        {
                            "variable": vname,
                            "source": source,
                            "available_sources": available,
                        },
                    )
                )


def record_shape_holds_a_pair(index_sets: dict[str, Any], shape: Any) -> bool:
    """True iff ``shape`` can carry two records (esm-spec §8.5.1 rule 3): it is
    not empty and its first entry names an ``interval`` of size 2 or a
    ``categorical`` of two members. Shared by structural validation and by the
    ``flatten`` re-check after ``coupling_import`` expansion."""
    if not shape:
        return False
    return _index_set_has_two_members(index_sets, shape[0])


def records_per_sample_shape_message(vname: str, shape: Any) -> str:
    """The ``records_per_sample_invalid`` message for a record shape that cannot
    carry two records (esm-spec §8.5.1 rule 3)."""
    return (
        f"Parameter '{vname}' asks for two records per sample, so its first dimension "
        f"must be an index set of exactly two members; its record shape is {list(shape)}"
    )


def _records_per_sample_origin(binding: Any, source: Any) -> tuple[Any, str | None]:
    """Where a data rule's EFFECTIVE ``records_per_sample`` comes from (esm-spec
    §8.5.1): ``(value, "from")`` for the rule's ``from.records_per_sample``,
    else ``(value, "temporal")`` for the source's
    ``temporal.records_per_sample``, else ``(1, None)``. The value is returned
    as written, unchecked: ``providers_from_document`` checks it strictly, while
    validation and ``flatten`` read it through
    :func:`~earthsci_ast.esm_types.effective_records_per_sample`.

    ``binding`` and ``source`` are either raw JSON dicts or the typed
    :class:`~earthsci_ast.esm_types.DataSourceBinding` /
    :class:`~earthsci_ast.esm_types.DataSource`; ``source`` may be None.
    """

    def get(obj: Any, key: str) -> Any:
        if obj is None:
            return None
        if isinstance(obj, dict):
            return obj.get(key)
        return getattr(obj, key, None)

    own = get(binding, "records_per_sample")
    if own is not None:
        return own, "from"
    inherited = get(get(source, "temporal"), "records_per_sample")
    if inherited is not None:
        return inherited, "temporal"
    return 1, None


def _index_set_has_two_members(index_sets: dict[str, Any], name: Any) -> bool:
    """True iff index set ``name`` is an ``interval`` of size 2 or a
    ``categorical`` of two members (esm-spec §8.5.1 rule 3)."""
    iset = index_sets.get(name) if isinstance(name, str) else None
    if not isinstance(iset, dict):
        return False
    kind = iset.get("kind")
    if kind == "interval":
        size = iset.get("size")
        return isinstance(size, int) and not isinstance(size, bool) and size == 2
    if kind == "categorical":
        members = iset.get("members")
        return isinstance(members, list) and len(members) == 2
    return False


def _declared_variable(data: dict[str, Any], scoped: Any) -> dict[str, Any] | None:
    """The raw declaration of a scoped variable ``Model[.Sub…].var``, or None
    when the loaded document cannot reach it: not declared, or behind a
    ``{"ref"}`` mount that structural validation runs ahead of."""
    if not isinstance(scoped, str) or "." not in scoped:
        return None
    *path, vname = scoped.split(".")
    node: Any = (data.get("models") or {}).get(path[0])
    for seg in path[1:]:
        if not isinstance(node, dict):
            return None
        node = (node.get("subsystems") or {}).get(seg)
    if not isinstance(node, dict):
        return None
    var = (node.get("variables") or {}).get(vname)
    return var if isinstance(var, dict) else None


def _has_unmounted_refs(data: dict[str, Any]) -> bool:
    """True when a model or a subsystem at any depth is still a ``{"ref"}``
    mount edge, as it is when structural validation runs ahead of mounting."""

    def pending(comp: Any) -> bool:
        if not isinstance(comp, dict):
            return False
        if "ref" in comp:
            return True
        return any(pending(sub) for sub in (comp.get("subsystems") or {}).values())

    return any(pending(m) for m in (data.get("models") or {}).values())


def _check_records_per_sample(data: dict[str, Any], errors: list) -> None:
    """``records_per_sample_invalid`` (esm-spec §8.5.1): ``from.records_per_sample``
    on a rule that is not ``data``; or an effective value of 2 on a parameter
    whose source declares no ``temporal`` block or a ``temporal`` with no
    ``start`` (a time-invariant source), or whose record shape's first
    dimension is not an index set of exactly two members.

    The record shape is the declared ``shape`` when there is one (``[]``
    included); when ``shape`` is absent, the
    declared ``shape`` of EVERY inline ``param_to_var`` target of the parameter,
    one finding per rule at the first that fails. A target this validation
    cannot reach (behind a ref not yet mounted, or not declared) is not
    decidable and is skipped, never read as empty. An empty record shape is
    refused here only when nothing can supply one later: no inline
    ``param_to_var`` entry names the parameter and the coupling holds no
    ``coupling_import``. While a ref is unmounted, a record shape whose first
    dimension names an index set the document does not declare is not
    decidable either. ``flatten`` re-checks the rest after expansion."""
    sources = data.get("data_sources") or {}
    if not isinstance(sources, dict):
        sources = {}
    index_sets = data.get("index_sets") or {}
    if not isinstance(index_sets, dict):
        index_sets = {}
    p2v_targets: dict[str, list[Any]] = {}
    has_coupling_import = False
    for entry in data.get("coupling") or []:
        if not isinstance(entry, dict):
            continue
        if entry.get("type") == "coupling_import":
            has_coupling_import = True
        elif (
            entry.get("type") == "variable_map"
            and entry.get("transform") == "param_to_var"
            and isinstance(entry.get("from"), str)
        ):
            p2v_targets.setdefault(entry["from"], []).append(entry.get("to"))

    # A mounted file may declare index sets of its own, which reach the
    # document only when the mount resolves. Until then a first dimension
    # naming a set the root does not declare is not decidable.
    refs_pending = _has_unmounted_refs(data)

    def fails(shape: list[Any]) -> bool:
        if refs_pending and shape and shape[0] not in index_sets:
            return False
        return not record_shape_holds_a_pair(index_sets, shape)

    def failing_record_shape(vdef: dict[str, Any], scoped: str) -> list[Any] | None:
        """The first record shape that cannot carry two records, or None when
        every shape validation can decide holds a pair."""
        shape = vdef.get("shape")
        if shape is not None:
            # A declared shape is the record shape, `[]` included: it declares
            # a scalar buffer. Only an ABSENT shape takes its targets'.
            shape = list(shape) if isinstance(shape, list) else []
            return shape if fails(shape) else None
        targets = p2v_targets.get(scoped, [])
        if not targets:
            return None if has_coupling_import else []
        for to in targets:
            target = _declared_variable(data, to)
            if target is None:
                continue
            tshape = target.get("shape") or []
            if fails(tshape):
                return list(tshape)
        return None

    def walk(comp: dict[str, Any], scope: str, pointer: str) -> None:
        for vname, vdef in (comp.get("variables") or {}).items():
            if not isinstance(vdef, dict):
                continue
            for suffix, rule in _update_rules_with_paths(vdef.get("update")):
                if not isinstance(rule, dict):
                    continue
                binding = rule.get("from")
                if not isinstance(binding, dict):
                    continue
                at = (
                    f"{pointer}/variables/{vname}/update{suffix.replace('[', '/').replace(']', '')}"
                )
                if rule.get("kind") != "data":
                    if "records_per_sample" in binding:
                        errors.append(
                            (
                                at,
                                f"Parameter '{vname}' sets from.records_per_sample on a "
                                f"'{rule.get('kind')}' rule; only a 'data' rule names a source "
                                f"to read records from",
                                {"variable": vname, "kind": rule.get("kind")},
                            )
                        )
                    continue
                source = sources.get(rule.get("source"))
                if not isinstance(source, dict):
                    continue  # data_source_undefined reports it
                if effective_records_per_sample(binding, source) != 2:
                    continue
                temporal = source.get("temporal")
                if not isinstance(temporal, dict) or not temporal.get("start"):
                    errors.append(
                        (
                            at,
                            f"Parameter '{vname}' asks for two records per sample from "
                            f"data source '{rule.get('source')}', which is time-invariant "
                            f"(it declares no temporal start) and so has no successor record",
                            {"variable": vname, "source": rule.get("source")},
                        )
                    )
                    continue
                shape = failing_record_shape(vdef, f"{scope}.{vname}")
                if shape is not None:
                    errors.append(
                        (
                            at,
                            records_per_sample_shape_message(vname, shape),
                            {"variable": vname, "shape": shape},
                        )
                    )
        for sname, sub in (comp.get("subsystems") or {}).items():
            if isinstance(sub, dict):
                walk(sub, f"{scope}.{sname}", f"{pointer}/subsystems/{sname}")

    for mname, m in (data.get("models") or {}).items():
        if isinstance(m, dict):
            walk(m, mname, f"/models/{mname}")


def _check_system_kind(data: dict[str, Any], errors: list[str]) -> None:
    """``system_kind_mismatch``: a model whose declared ``system_kind`` FIELD
    contradicts the derivation (esm-spec §6.3.1).

    The field is optional and the derivation is authoritative -- a binding uses
    it whenever the field is absent -- so a present field that disagrees is
    always an author error, never a legitimate override.
    """
    for mname, m in (data.get("models") or {}).items():
        if not isinstance(m, dict):
            continue
        declared = m.get("system_kind")
        if not isinstance(declared, str):
            continue
        derived = system_kind(m)
        if declared == derived:
            continue
        errors.append(
            (
                f"/models/{mname}/system_kind",
                f"Model '{mname}' declares system_kind '{declared}' but its "
                f"equations and parameters derive '{derived}'",
                {"declared": declared, "derived": derived, "model": mname},
            )
        )


def _reserved_declaration_names(data: dict[str, Any]) -> dict[str, str]:
    """The names no declaration map may spell, mapped to WHY (esm-spec §4.9.1.1).

    Two symbols, both of them GLOBALLY scoped: the document's independent
    variable (``domain.independent_variable``, default ``"t"``) and the §6.4
    operator placeholder. §4.9.1.1 is the normative home of this set; the
    sibling ``reserved_index_symbol`` rule for an ``faq`` binder reads the
    same set, so the two cannot drift apart. (That sibling rule is currently
    implemented only in the Rust binding; this one is implemented in all five.)

    Spatial coordinate names are deliberately absent: ``x``, ``y``, ``lon`` are
    coordinates only in a coordinate position (§11.4), and
    ``tests/valid/units_dimensional_analysis.esm`` declares ``x`` as an ordinary
    position variable.
    """
    domain = data.get("domain")
    independent = "t"
    if isinstance(domain, dict):
        independent = str(domain.get("independent_variable") or "t")
    return {independent: "independent_variable", "_var": "operator_placeholder"}


def _check_reserved_declaration_names(data: dict[str, Any], errors: list[str]) -> None:
    """``reserved_variable_name``: a declaration spelled with a globally-scoped
    name (esm-spec §4.9.1.1).

    The independent variable and ``_var`` are in scope in every model and are
    resolved BY NAME, ahead of the declaration maps, so such a declaration is
    unreachable -- it does not shadow the implicit symbol, the implicit symbol
    shadows it. What that cost before the rejection existed is why it is a hard
    error and not a lint (issue #200): the document VALIDATED, a bare build
    reported the observed as having no defining expression, and a build with a
    subsystem mounted handed every reader of ``t`` the simulation clock instead
    -- ``log(t)`` was ``-inf`` at ``t = 0`` and every number downstream was
    finite, plausible and wrong.

    All three declaration maps are covered, because a species and a reaction
    parameter become symbols of the derived ODE system exactly as a
    ``variables`` entry does (§7.4).
    """
    reserved = _reserved_declaration_names(data)

    def scan(container: dict[str, Any], pointer: str, owner: str, kind: str) -> None:
        # Sorted, not authored, order: Go decodes ``variables`` into a plain map
        # and cannot reproduce the authored order at all, so sorted is the one
        # ordering all five bindings can agree on.
        for name in sorted(container, key=str):
            why = reserved.get(str(name))
            if why is None:
                continue
            role = (
                "the document's independent variable"
                if why == "independent_variable"
                else "the operator-model placeholder"
            )
            errors.append(
                (
                    f"{pointer}/{name}",
                    f"{owner} declares a {kind} named '{name}', which is {role}",
                    {"name": str(name), "reserved_as": why},
                )
            )

    def scan_model(m: Any, pointer: str, owner: str) -> None:
        """One model's ``variables``, then every inline subsystem of it.

        A subsystem is a model, so its ``variables`` map is a declaration map
        like any other -- and a MOUNTED subsystem is exactly the shape issue
        #200 was reported in, where every reader of ``t`` silently received the
        simulation clock. A ``$ref`` mount has already been spliced in by the
        time this runs, so it is covered by the same walk.
        """
        if not isinstance(m, dict):
            return
        if isinstance(m.get("variables"), dict):
            scan(m["variables"], f"{pointer}/variables", owner, "variable")
        for sname, sub in (m.get("subsystems") or {}).items():
            scan_model(sub, f"{pointer}/subsystems/{sname}", f"Model '{sname}'")

    for mname, m in (data.get("models") or {}).items():
        scan_model(m, f"/models/{mname}", f"Model '{mname}'")
    for rname, rs in (data.get("reaction_systems") or {}).items():
        if not isinstance(rs, dict):
            continue
        owner = f"Reaction system '{rname}'"
        if isinstance(rs.get("species"), dict):
            scan(rs["species"], f"/reaction_systems/{rname}/species", owner, "species")
        if isinstance(rs.get("parameters"), dict):
            scan(rs["parameters"], f"/reaction_systems/{rname}/parameters", owner, "parameter")


def _check_array_default_without_shape(data: dict[str, Any], errors: list[str]) -> None:
    """``array_default_without_shape``: inline array data as the ``default`` of a
    variable that declares no ``shape`` (esm-spec §6.3).

    Inline array data is a SHAPED variable's value: its nesting is matched
    against the declared ``shape``. With no shape (omitted, null or empty) there
    is nothing for the array to fill and no scalar reading of it, so the
    document is malformed. Rejected here, at the declaration, rather than left
    to a runtime that would have to drop the parameter or fabricate a value.
    Inline subsystems are models, so they are walked too.
    """

    def scan_model(m: Any, pointer: str, owner: str) -> None:
        if not isinstance(m, dict):
            return
        variables = m.get("variables")
        if isinstance(variables, dict):
            for name in sorted(variables, key=str):
                var = variables[name]
                if not isinstance(var, dict) or not isinstance(var.get("default"), list):
                    continue
                if var.get("shape"):
                    continue
                errors.append(
                    (
                        f"{pointer}/variables/{name}/default",
                        f"{owner} variable '{name}' has inline array data as its default "
                        "but declares no shape; inline array data is a shaped variable's "
                        "value (esm-spec §6.3)",
                        {"variable": str(name), "variable_type": str(var.get("type"))},
                    )
                )
        subsystems = m.get("subsystems")
        if isinstance(subsystems, dict):
            for sname in sorted(subsystems, key=str):
                scan_model(subsystems[sname], f"{pointer}/subsystems/{sname}", f"Model '{sname}'")

    models = data.get("models")
    if isinstance(models, dict):
        for mname in sorted(models, key=str):
            scan_model(models[mname], f"/models/{mname}", f"Model '{mname}'")


def _check_event_affects_parameter(data: dict[str, Any], errors: list[str]) -> None:
    """``event_affects_parameter``: an event ``affects`` LHS naming a PARAMETER.

    From 1.0.0 an event may affect UNKNOWNS only. A parameter that changes during
    a run declares its own ``update`` block, so the 0.x ``discrete_parameters``
    list and the ``functional_affect`` handler are both gone; the defect they
    used to describe is now reached through ``affects``.

    The pointer names the offending affect entry, and the remedy names the update
    rule that replaces it — for a periodic trigger there is an exact one.
    """
    for mname, m in data.get("models", {}).items():
        if not isinstance(m, dict):
            continue
        var_types = {
            n: v.get("type") for n, v in (m.get("variables") or {}).items() if isinstance(v, dict)
        }
        for event_kind, key in (
            ("continuous", "continuous_events"),
            ("discrete", "discrete_events"),
        ):
            for ei, event in enumerate(m.get(key, []) or []):
                if not isinstance(event, dict):
                    continue
                trigger = event.get("trigger") if isinstance(event.get("trigger"), dict) else {}
                for side in ("affects", "affect_neg"):
                    for ai, affect in enumerate(event.get(side) or []):
                        if not isinstance(affect, dict):
                            continue
                        lhs = affect.get("lhs")
                        if not isinstance(lhs, str) or var_types.get(lhs) != "parameter":
                            continue
                        details = {
                            "variable": lhs,
                            "variable_type": "parameter",
                            "event_name": event.get("name", ""),
                            "event_type": event_kind,
                        }
                        # `trigger_type` is reported only when it DECIDES the
                        # remedy: a fixed-interval rewrite of a parameter has an
                        # exact 1.0.0 replacement (`update: {kind: "schedule",
                        # interval}`), so the trigger is worth naming. Every
                        # other trigger gets the general remedy and no tag.
                        trigger_type = trigger.get("type")
                        if trigger_type == "periodic" and trigger.get("interval") is not None:
                            details["trigger_type"] = trigger_type
                            details["remedy"] = (
                                f'declare the change as update: {{kind: "schedule", '
                                f"interval: {trigger['interval']}}} on '{lhs}' (esm-spec 5.4)"
                            )
                        else:
                            details["remedy"] = (
                                "declare the change as the parameter's own update (esm-spec 5.4)"
                            )
                        errors.append(
                            (
                                f"/models/{mname}/{key}/{ei}/{side}/{ai}",
                                f"Event '{event.get('name', '')}' affects '{lhs}', which is "
                                f"a parameter; an event may affect unknowns only",
                                details,
                            )
                        )


def _lhs_variable_type(data: dict[str, Any], mpath: list[str], model: dict, name: str):
    """The declared ``type`` of the variable an equation LHS names, resolving a
    scoped reference (``sub.L`` / ``Top.sub.L``) through subsystems."""
    v = (model.get("variables") or {}).get(name)
    if isinstance(v, dict):
        return v.get("type")
    parts = name.split(".")
    if len(parts) < 2:
        return None

    def walk(start: dict, segs: list[str]):
        cur = start
        for seg in segs[:-1]:
            nxt = (cur.get("subsystems") or {}).get(seg) if isinstance(cur, dict) else None
            if not isinstance(nxt, dict):
                return None
            cur = nxt
        var = (cur.get("variables") or {}).get(segs[-1])
        return var.get("type") if isinstance(var, dict) else None

    # Relative to this model, then with this model's own path as the prefix,
    # then from the document root.
    t = walk(model, parts)
    if t is None and parts[: len(mpath)] == mpath and len(parts) > len(mpath):
        t = walk(model, parts[len(mpath) :])
    if t is None:
        root = (data.get("models") or {}).get(parts[0])
        if isinstance(root, dict):
            t = walk(root, parts[1:])
    return t


def _lhs_base_name(lhs: Any):
    """The variable an equation LHS names, through ``faq``/``index`` wrappers
    and a time derivative (``D`` with ``wrt`` absent or ``t``: a parameter may
    have neither a definition nor dynamics); ``None`` for an ``ic`` or an
    expression LHS."""
    e = lhs
    while isinstance(e, dict):
        op = e.get("op")
        if op in ("faq", "aggregate") and isinstance(e.get("expr"), (dict, str)):
            e = e["expr"]
        elif op == "index" and e.get("args"):
            e = e["args"][0]
        elif op == "D" and e.get("args") and e.get("wrt") in (None, "t"):
            e = e["args"][0]
        else:
            return None
    return e if isinstance(e, str) else None


def _lhs_defined_name(lhs: Any):
    """The variable an equation LHS defines or differentiates, through
    ``faq``/``index``/``D`` wrappers — the name an ``unbound_index_symbol``
    message reports."""
    e = lhs
    while isinstance(e, dict):
        op = e.get("op")
        if op in ("faq", "aggregate") and isinstance(e.get("expr"), (dict, str)):
            e = e["expr"]
        elif op in ("index", "D") and e.get("args"):
            e = e["args"][0]
        else:
            return None
    return e if isinstance(e, str) else None


def _lhs_free_index_symbols(lhs: Any, bound: set, names: set) -> list[str]:
    out: list[str] = []

    def walk(e: Any, b: set) -> None:
        if not isinstance(e, dict):
            return
        op = e.get("op")
        if op in ("faq", "aggregate"):
            nb = set(b)
            nb.update(x for x in (e.get("output_idx") or []) if isinstance(x, str))
            nb.update((e.get("ranges") or {}).keys())
            walk(e.get("expr"), nb)
            for a in e.get("args") or []:
                walk(a, nb)
            return
        if op == "index":
            args = e.get("args") or []
            if args:
                walk(args[0], b)
            for sub in args[1:]:
                if isinstance(sub, str):
                    if sub not in b and sub not in names and sub not in out:
                        out.append(sub)
                else:
                    walk(sub, b)
            return
        for a in e.get("args") or []:
            walk(a, b)

    walk(lhs, bound)
    return out


def _check_equation_lhs_names(data: dict[str, Any], errors: list) -> None:
    """``equation_defines_parameter`` and ``unbound_index_symbol`` (esm-spec
    §6.3.1): an equation's left-hand side never defines a parameter, and an index
    symbol on it is bound by a ``faq`` (on the left, or the right-hand side's
    ``output_idx`` for the bare-index definition)."""
    metas = data.get("metaparameters")
    meta_names = set(metas.keys()) if isinstance(metas, dict) else set()

    def visit(model: dict, mpath: list[str], ptr: str) -> None:
        names = set((model.get("variables") or {}).keys()) | meta_names | {"t"}
        for k, eq in enumerate(model.get("equations") or []):
            if not isinstance(eq, dict):
                continue
            lhs = eq.get("lhs")
            if isinstance(lhs, dict) and lhs.get("op") == "ic":
                continue
            path = f"{ptr}/equations/{k}/lhs"
            base = _lhs_base_name(lhs)
            if base is not None and _lhs_variable_type(data, mpath, model, base) == "parameter":
                errors.append(
                    (
                        "equation_defines_parameter",
                        path,
                        f"Equation {k} defines '{base}', which is a parameter; an equation "
                        f"defines unknowns only",
                        {"variable": base},
                    )
                )
            rhs = eq.get("rhs")
            bound = set()
            if isinstance(rhs, dict) and rhs.get("op") in ("faq", "aggregate"):
                bound = {x for x in (rhs.get("output_idx") or []) if isinstance(x, str)}
            free = _lhs_free_index_symbols(lhs, bound, names)
            defining = _lhs_defined_name(lhs) if free else None
            for sym in free:
                what = f" (defining '{defining}')" if defining else ""
                errors.append(
                    (
                        "unbound_index_symbol",
                        path,
                        f"Equation {k}{what} subscripts its left-hand side with '{sym}', "
                        f"which no faq binds",
                        {"symbol": sym},
                    )
                )
        for sname, sub in (model.get("subsystems") or {}).items():
            if isinstance(sub, dict):
                visit(sub, mpath + [sname], f"{ptr}/subsystems/{sname}")

    for mname, m in (data.get("models") or {}).items():
        if isinstance(m, dict):
            visit(m, [mname], f"/models/{mname}")


_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?$")
_URL_RE = re.compile(r"^https?://[^\s/$.?#].[^\s]*$")
_DOI_RE = re.compile(r"^10\.\d{4,9}/[^\s]+$")
_DURATION_RE = re.compile(
    r"^P(?:\d+Y)?(?:\d+M)?(?:\d+W)?(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$"
)


def _check_metadata_formats(data: dict[str, Any], errors: list[str]) -> None:
    """Validate ISO 8601 dates, URLs, and DOIs in metadata."""
    md = data.get("metadata", {})
    for field in ("created", "modified"):
        val = md.get(field)
        if isinstance(val, str) and not _DATE_RE.match(val):
            errors.append(f"metadata/{field}: '{val}' is not a valid ISO 8601 date")
    for ri, ref in enumerate(md.get("references", []) or []):
        url = ref.get("url")
        if isinstance(url, str) and not _URL_RE.match(url):
            errors.append(f"metadata/references[{ri}]/url: '{url}' is not a valid URL")
        doi = ref.get("doi")
        if isinstance(doi, str) and not _DOI_RE.match(doi):
            errors.append(f"metadata/references[{ri}]/doi: '{doi}' is not a valid DOI format")


def _check_temporal_resolution(data: dict[str, Any], errors: list[str]) -> None:
    """Validate ISO 8601 duration strings in a data source's temporal fields."""
    for dname, d in data.get("data_sources", {}).items():
        if not isinstance(d, dict):
            continue
        temporal = d.get("temporal", {})
        if not isinstance(temporal, dict):
            continue
        for field_name in ("file_period", "frequency"):
            res = temporal.get(field_name)
            if isinstance(res, str) and res and not _DURATION_RE.match(res):
                errors.append(
                    f"data_sources/{dname}/temporal/{field_name}: '{res}' is not a valid ISO 8601 duration"
                )


def _json_pointer_from_message(msg: str) -> str:
    """Recover a JSON-Pointer path from a legacy ``"a/b/c: message"`` finding.

    The raw structural checks have always prefixed their prose with a
    slash-delimited location (``models/M/variables/v: ...``,
    ``models/M/equations[0]: ...``). This turns that prefix into the
    JSON-Pointer form the shared corpus pins (``/models/M/equations/0``) so
    every legacy check gets a usable path for free. Returns ``"$"`` when the
    message carries no recognizable location.
    """
    head = msg.split(": ", 1)[0].strip()
    if not head or "/" not in head or " " in head:
        return "$"
    # `equations[0]` -> `equations/0`
    head = head.replace("[", "/").replace("]", "")
    return "/" + head.strip("/")


def _check_operator_state_coverage(data: dict[str, Any], errors: list[str]) -> None:
    """
    When a file declares operators, every state variable in each model must be
    covered by either an equation (ODE or assignment) or an operator's modifies list.
    """
    if not data.get("operators"):
        return
    op_modifies = set()
    for op in data.get("operators", {}).values():
        op_modifies.update(op.get("modifies", []) or [])
    for mname, m in data.get("models", {}).items():
        state_vars = ode_states(m) + algebraic_unknowns(m)
        eq_lhs_vars = set()
        for eq in m.get("equations", []):
            lhs = eq.get("lhs")
            if isinstance(lhs, dict) and lhs.get("op") == "D":
                args = lhs.get("args", [])
                if args and isinstance(args[0], str):
                    eq_lhs_vars.add(args[0])
            elif isinstance(lhs, str):
                eq_lhs_vars.add(lhs)
        uncovered = [s for s in state_vars if s not in eq_lhs_vars and s not in op_modifies]
        if uncovered:
            errors.append(
                f"models/{mname}: state variables {uncovered} are not covered by any equation or operator's modifies list"
            )


def _check_reaction_systems(data: dict[str, Any], errors: list[str]) -> None:
    """Validate reaction system rate references (raw-dict, load-time).

    Undeclared-species detection (substrates/products referencing a species not
    in the ``species`` map) is OWNED by the dataclass/coded layer —
    :func:`earthsci_ast.validation._validate_reaction_consistency` via
    ``_validate_stoich`` (code ``undeclared_species``). It formerly had a
    string-blob twin here; that duplicate was removed so the rule has one owner
    (finding: duplicated-rule dedup). The null-null and rate-reference checks
    below have coded twins there too, but are kept here as the raw-dict
    load-time gate.
    """
    for rsname, rs in data.get("reaction_systems", {}).items():
        species = set(rs.get("species", {}).keys())
        params = set(rs.get("parameters", {}).keys())
        valid_rate_syms = species | params | _BUILTIN_SYMBOLS
        for ri, reaction in enumerate(rs.get("reactions", [])):
            reaction_id = reaction.get("id")
            reaction_pointer = f"/reaction_systems/{rsname}/reactions/{ri}"
            substrates = reaction.get("substrates")
            products = reaction.get("products")
            # A reaction with both substrates and products explicitly null is a
            # `null_reaction` (§7.1), carried by the reaction node itself.
            if (
                "substrates" in reaction
                and "products" in reaction
                and substrates is None
                and products is None
            ):
                errors.append(
                    (
                        "null_reaction",
                        reaction_pointer,
                        f'Reaction "{reaction_id}" has both substrates: null and products: null',
                        {"reaction_id": reaction_id},
                    )
                )
                continue
            # A rate expression symbol that names neither a declared species nor
            # a declared parameter is an `undefined_parameter`, carried by the
            # reaction's `rate` field (§7.1; TypeScript reference).
            rate = reaction.get("rate")
            if rate is not None:
                refs = []
                if isinstance(rate, str):
                    refs = [rate]
                elif isinstance(rate, dict):
                    refs = _walk_expression_strings(rate)
                for ref in refs:
                    if "." in ref:
                        continue  # Scoped refs handled elsewhere
                    if ref not in valid_rate_syms:
                        errors.append(
                            (
                                "undefined_parameter",
                                f"{reaction_pointer}/rate",
                                f'Variable "{ref}" in rate expression is not declared '
                                f"as species or parameter",
                                {"variable": ref, "reaction_id": reaction_id},
                            )
                        )


def _check_event_references(
    data: dict[str, Any], tables: dict[str, Any], errors: list[str]
) -> None:
    """Check that event affects reference declared variables.

    The pointer names the affect's ``lhs`` FIELD under its own event container
    (``continuous_events`` / ``discrete_events``) and the affect's array index —
    ``/models/M/continuous_events/0/affects/0/lhs`` — not a flattened
    ``events/<n>`` position (CONFORMANCE_SPEC §7.1.2; TypeScript reference).
    """
    for mname, m in data.get("models", {}).items():
        local_vars = set(m.get("variables", {}).keys())
        for kind in ("continuous_events", "discrete_events"):
            for ei, event in enumerate(m.get(kind, []) or []):
                if not isinstance(event, dict):
                    continue
                for ai, affect in enumerate(event.get("affects", []) or []):
                    if (
                        isinstance(affect, dict)
                        and "lhs" in affect
                        and isinstance(affect["lhs"], str)
                    ):
                        name = affect["lhs"]
                        # Underscore-prefixed names are conventional placeholders
                        if name.startswith("_"):
                            continue
                        if name not in local_vars and name not in tables["global_symbols"]:
                            evt_word = (
                                "continuous event" if kind == "continuous_events" else "event"
                            )
                            errors.append(
                                (
                                    f"/models/{mname}/{kind}/{ei}/affects/{ai}/lhs",
                                    f'Variable "{name}" in {evt_word} affects is not declared',
                                    {"variable": name},
                                )
                            )


def _check_registered_function_calls(data: dict[str, Any], errors: list[str]) -> None:
    """Emit missing_registered_function diagnostics for 'call' ops whose
    handler_id does not appear in the top-level registered_functions map
    (esm-spec §4.4 / §9.2). Also checks arg_count against signature when declared.
    """
    registry = data.get("registered_functions") or {}

    def walk(obj, path):
        if isinstance(obj, dict):
            if obj.get("op") == "call":
                handler_id = obj.get("handler_id")
                if handler_id is None:
                    errors.append(f"{path}: 'call' op is missing required 'handler_id' field")
                elif handler_id not in registry:
                    errors.append(
                        f"{path}: missing_registered_function — 'call' references handler_id "
                        f"'{handler_id}' but no such entry exists in registered_functions"
                    )
                else:
                    entry = registry[handler_id] or {}
                    sig = entry.get("signature") or {}
                    declared = sig.get("arg_count")
                    args = obj.get("args") or []
                    if declared is not None and len(args) != declared:
                        errors.append(
                            f"{path}: 'call' to '{handler_id}' has {len(args)} args but "
                            f"signature declares arg_count={declared}"
                        )
            for k, v in obj.items():
                walk(v, f"{path}/{k}")
        elif isinstance(obj, list):
            for i, v in enumerate(obj):
                walk(v, f"{path}[{i}]")

    # Also sanity-check that each registered_functions entry's id matches its key
    # and its arg_units length agrees with signature.arg_count when both are present.
    for key, entry in registry.items():
        if not isinstance(entry, dict):
            continue
        entry_id = entry.get("id")
        if entry_id is not None and entry_id != key:
            errors.append(
                f"registered_functions/{key}: entry id '{entry_id}' does not match map key '{key}'"
            )
        sig = entry.get("signature") or {}
        arg_count = sig.get("arg_count")
        arg_units = entry.get("arg_units")
        if arg_units is not None and arg_count is not None and len(arg_units) != arg_count:
            errors.append(
                f"registered_functions/{key}: arg_units length {len(arg_units)} != signature.arg_count {arg_count}"
            )
        arg_types = sig.get("arg_types")
        if arg_types is not None and arg_count is not None and len(arg_types) != arg_count:
            errors.append(
                f"registered_functions/{key}: signature.arg_types length {len(arg_types)} != arg_count {arg_count}"
            )

    walk(data, "")


def _validate_structural(data: dict[str, Any], file_path=None) -> None:
    """
    Perform post-schema structural validation.

    Raises :class:`StructuralValidationError` (a ``SchemaValidationError``
    subclass) if any structural problems are found. Each check contributes its
    findings under a stable diagnostic code, collected onto the raised error's
    ``.findings`` list as ``(code, message)`` pairs; the raised error's
    ``str()`` is the same collapsed prose blob as before.
    """
    findings: list[tuple[str, str]] = []
    records: list[dict] = []

    def collect(code: str, run) -> None:
        """Run ``run(sub)`` and tag everything it produced with ``code``.

        A check appends either a bare prose message (legacy form — the
        JSON-Pointer path is then recovered from the conventional
        ``"a/b/c: message"`` prefix), an explicit
        ``(json_pointer, message, details)`` triple, or a
        ``(code, json_pointer, message, details)`` 4-tuple that OVERRIDES the
        collect-level code. The override exists because one pass may legitimately
        emit findings under different codes: the §4.9.5 reference-integrity walk
        reports a bare undefined name as ``undefined_variable`` but an
        unresolvable *scoped* (``System.var``) ref in a coupling expression as
        ``unresolved_scoped_ref``.
        """
        sub: list = []
        run(sub)
        for item in sub:
            item_code = code
            if isinstance(item, tuple):
                if len(item) == 4:
                    item_code, path, msg, details = item
                else:
                    path, msg, details = item
            else:
                msg = item
                path = _json_pointer_from_message(msg)
                details = {}
            findings.append((item_code, msg))
            records.append({"code": item_code, "path": path, "message": msg, "details": details})

    # Operator arity check (walk all expressions)
    def walk_for_arity(errors, obj, path):
        if isinstance(obj, dict):
            if "op" in obj and "args" in obj:
                _check_expression_arity(obj, errors, path)
                return
            for k, v in obj.items():
                walk_for_arity(errors, v, f"{path}/{k}")
        elif isinstance(obj, list):
            for i, v in enumerate(obj):
                walk_for_arity(errors, v, f"{path}[{i}]")

    collect("operator_arity", lambda sub: walk_for_arity(sub, data, ""))
    # `broadcast` names its operator in a `fn` FIELD, which the arity walk above
    # (it reads `args` only) never looked at — so an `fn` naming a nonexistent or
    # non-scalar op, or none at all, validated clean and became a run-time table
    # miss or, for a one-operand node, a silently dropped operator (issue #101).
    collect("invalid_broadcast_fn", lambda sub: _check_broadcast_fn(data, sub))
    # An array-level operand must be alignable to its result by index-set NAME.
    # Statically decidable from declared shapes + the index-set registry; used to
    # be left to NumPy's positional right-align at run time, which silently
    # mis-broadcast or transposed the operand (issue #100).
    collect("array_shape_mismatch", lambda sub: _check_index_set_alignment(data, sub))

    tables = _build_symbol_tables(data)

    # `undefined_variable` (NOT `undefined_reference`): the corpus pins
    # `undefined_variable` and Python was the only binding spelling it otherwise
    # — a cross-language conformance gap, not a cosmetic one.
    collect("undefined_variable", lambda sub: _check_variable_references(data, tables, sub))
    # An inline test's assertion target, override keys and assertion rank (esm-spec
    # §6.6.2, §6.6.3, §6.6.5). Each finding carries its own code via a 4-tuple.
    collect("inline_test_semantics", lambda sub: _check_inline_tests(data, sub))
    # Three statically-decidable aggregate defects (join_key_invalid_type,
    # relational_node_in_continuous, undefined_index_set). Each finding carries
    # its own explicit code via a 4-tuple, so the collect-level code is only a
    # fallback label. F-6 (five static validate() checks).
    collect("aggregate_semantics", lambda sub: _check_aggregate_semantics(data, sub))
    # A causal self-read (esm-spec §4.3.1.1) that is not strictly earlier along
    # exactly one axis. Each finding carries its own code via a 4-tuple; the
    # collect-level label is a fallback only. Rejection parity is a duty of every
    # binding, executing or not (CONFORMANCE_SPEC §5.19.5) -- the pre-1.0
    # behaviour for these shapes was a plausible wrong number.
    collect(
        "recurrence_not_wellfounded",
        lambda sub: _check_recurrence_wellfoundedness(data, sub),
    )
    # §4.9.6: a cycle among ONE model's observed definitions. Ordered AFTER the
    # recurrence pass so that a document carrying both gets the recurrence
    # diagnosis listed first, and BEFORE `circular_dependency`, which is the
    # same graph's cycle across a scope boundary. The self-edge of a recurrence CANDIDATE is
    # not one of these edges — see `_check_observed_cycles` for why the gate is
    # candidacy and never the well-foundedness verdict.
    collect(OBSERVED_CYCLE, lambda sub: _check_observed_cycles(data, sub))
    # A coupling edge's `from` is a FULLY-QUALIFIED scoped reference (§4.6), so an
    # unresolvable one is an `unresolved_scoped_ref`, not a bare
    # `undefined_variable` (CONFORMANCE_SPEC §7.1; TypeScript reference).
    collect("unresolved_scoped_ref", lambda sub: _check_coupling_references(data, tables, sub))
    # §4.9.5: reference integrity applies to EVERY expression-bearing field.
    # A data source's `unit_conversion` moved ONTO the consuming parameter with
    # 1.0.0, so it is now reached by `_model_expression_sites` above; only the
    # coupling edge's connector/transform expressions still live outside models.
    collect("unresolved_scoped_ref", lambda sub: _check_coupling_expressions(data, tables, sub))
    collect("undefined_system", lambda sub: _check_coupling_systems(data, tables, sub))
    collect(CIRCULAR_DEPENDENCY, lambda sub: _check_circular_references(data, sub))
    collect("data_source_undefined", lambda sub: _check_data_source_references(data, sub))
    collect("records_per_sample_invalid", lambda sub: _check_records_per_sample(data, sub))
    collect("event_affects_parameter", lambda sub: _check_event_affects_parameter(data, sub))
    # esm-spec §6.3.1: an equation never defines a parameter, and an index symbol
    # on its left-hand side is bound by a faq. Each finding names its own code.
    collect("equation_defines_parameter", lambda sub: _check_equation_lhs_names(data, sub))
    # A declaration spelled with a globally-scoped name (the independent
    # variable, or `_var`) is unreachable: both resolve BY NAME ahead of the
    # declaration maps, so every reader silently gets the implicit symbol
    # instead of the declared quantity (issue #200).
    collect(
        "reserved_variable_name",
        lambda sub: _check_reserved_declaration_names(data, sub),
    )
    # Inline array data is a shaped variable's value (esm-spec §6.3); on a
    # variable with no `shape` it has nothing to fill.
    collect(
        "array_default_without_shape",
        lambda sub: _check_array_default_without_shape(data, sub),
    )
    collect("system_kind_mismatch", lambda sub: _check_system_kind(data, sub))
    collect("invalid_metadata_format", lambda sub: _check_metadata_formats(data, sub))
    collect("invalid_temporal_resolution", lambda sub: _check_temporal_resolution(data, sub))
    # Subsystem ref existence/parse is checked by resolve_subsystem_refs after
    # structural validation, which raises SubsystemRefError with richer context.
    # Units are not checked here: every unit rule (an unreal unit string, a
    # provable dimensional mismatch) lives in validate(), in
    # units.UnitValidator.
    collect("event_var_undeclared", lambda sub: _check_event_references(data, tables, sub))
    # Equation-unknown balance is OWNED by the dataclass/coded layer,
    # ``earthsci_ast.validation._validate_equation_balance_enhanced`` (code
    # ``equation_count_mismatch``), which correctly EXCLUDES ``ic`` equations
    # from the count. The former raw-dict twin ``_check_equation_balance``
    # counted ``ic`` equations and could disagree with it on the same file; it
    # was removed so the rule has a single owner (finding: duplicated-rule
    # dedup). Operator-state coverage below is a DISTINCT check with no coded
    # twin, so it stays here.
    collect("uncovered_state_variable", lambda sub: _check_operator_state_coverage(data, sub))
    collect("reaction_consistency", lambda sub: _check_reaction_systems(data, sub))
    collect(
        "missing_registered_function",
        lambda sub: _check_registered_function_calls(data, sub),
    )

    if findings:
        blob = "Structural validation failed:\n" + "\n".join(
            f"  - {msg}" for _code, msg in findings
        )
        raise _structural_validation_error_cls()(blob, findings=findings, records=records)
