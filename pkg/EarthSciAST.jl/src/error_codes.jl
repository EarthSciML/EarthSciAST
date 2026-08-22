"""
Central registry of the diagnostic code STRINGS this binding emits.

Julia carried these as inline string literals at ~160 raise sites — an
`error_type` positional on `StructuralError`, a first positional on
`ExpressionTemplateError` / `ClosedFunctionError`, a `code=` keyword on
`SubsystemRefError` / `ParseError` — with no single place to read the
vocabulary off. This file is that place, the Julia twin of TypeScript's
`ERROR_CODES` object (`pkg/earthsci-ast-ts/src/errors.ts`), Python's
`ErrorCode` enum (`pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py`),
Go's `codes.go` and Rust's `diagnostic::codes`.

**The values are a cross-binding contract and must never change.** Every value
below equals, byte for byte, a literal this package emitted before
centralization; the shared corpus `tests/invalid/expected_errors.json` pins
many of them by value. Centralizing them does not (and must not) change any
emitted string. Adding a new diagnostic means adding an entry here AND
coordinating the value across every binding.

Field names are the SCREAMING_SNAKE_CASE form of the value (mirroring the
TypeScript keys and the Python enum members), so a reference reads as
`ERROR_CODES.UNDEFINED_VARIABLE`. `ERROR_CODES` is a `NamedTuple`, so every
lookup is resolved and constant-folded at compile time — a typo is a
`FieldError` at precompile, not a silently wrong code string at runtime, which
is the whole point of having the registry.
"""

"""
    ERROR_CODES

The registry itself: a `NamedTuple` mapping each SCREAMING_SNAKE_CASE name to
the stable diagnostic code string it stands for. See this file's module-level
documentation for the contract. Grouped by the spec section that pins each
family.

```julia
julia> ERROR_CODES.UNDEFINED_VARIABLE
"undefined_variable"

julia> length(ERROR_CODES)   # how many codes this binding knows
```
"""
const ERROR_CODES = (
    # ── Structural validation (validate.jl; the `error_type` of a
    #    `StructuralError`, pinned by tests/invalid/expected_errors.json) ────
    ARRAY_SHAPE_MISMATCH = "array_shape_mismatch",
    CIRCULAR_DEPENDENCY = "circular_dependency",
    CONFLICTING_DERIVATIVE = "conflicting_derivative",
    DATA_SOURCE_UNDEFINED = "data_source_undefined",
    DOMAIN_UNIT_MISMATCH = "domain_unit_mismatch",
    EMPTY_CALLBACK_ID = "empty_callback_id",
    EQUATION_COUNT_MISMATCH = "equation_count_mismatch",
    EVENT_AFFECTS_PARAMETER = "event_affects_parameter",
    EVENT_VAR_UNDECLARED = "event_var_undeclared",
    INVALID_BROADCAST_FN = "invalid_broadcast_fn",
    INVALID_REFERENCE_SYNTAX = "invalid_reference_syntax",
    INVALID_STOICHIOMETRY = "invalid_stoichiometry",
    JOIN_KEY_INVALID_TYPE = "join_key_invalid_type",
    NULL_REACTION = "null_reaction",
    RELATIONAL_NODE_IN_CONTINUOUS = "relational_node_in_continuous",
    SYSTEM_KIND_MISMATCH = "system_kind_mismatch",
    UNDEFINED_INDEX_SET = "undefined_index_set",
    UNDEFINED_OPERATOR = "undefined_operator",
    UNDEFINED_PARAMETER = "undefined_parameter",
    UNDEFINED_SPECIES = "undefined_species",
    UNDEFINED_SYSTEM = "undefined_system",
    UNDEFINED_VARIABLE = "undefined_variable",
    UNRESOLVED_SCOPED_REF = "unresolved_scoped_ref",

    # ── Units (units.jl §4.8.4). Both are HARD errors: `UNIT_INCONSISTENCY`
    #    is a PROVABLE dimensional mismatch, `UNIT_PARSE_ERROR` a declared
    #    unit string that denotes no real unit. An UNDETERMINABLE dimension is
    #    not a finding at all — the engine returns `nothing` and the enclosing
    #    check is skipped. `UNIT_DIMENSION_MISMATCH` / `UNIT_PARSE_ERROR` in
    #    units.jl are the long-standing public aliases of these two. ────────
    UNIT_INCONSISTENCY = "unit_inconsistency",
    UNIT_PARSE_ERROR = "unit_parse_error",

    # ── Document load / subsystem-reference resolution (resolve.jl, parse.jl;
    #    esm-spec §4.7). These are THROWN at load, and `validate` renders the
    #    same `(code, path)` pair as a structural finding. ──────────────────
    UNRESOLVED_SUBSYSTEM_REF = "unresolved_subsystem_ref",
    AMBIGUOUS_SUBSYSTEM_REF = "ambiguous_subsystem_ref",
    IC_IN_REACTION_SYSTEM = "ic_in_reaction_system",

    # ── Expression templates (esm-spec §9.6) + the §9.6.4 post-expansion
    #    validators (lower_expression_templates.jl; the recursive-body
    #    composition check lives in template_imports.jl). ───────────────────
    APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE = "apply_expression_template_unknown_template",
    APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH = "apply_expression_template_bindings_mismatch",
    APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY = "apply_expression_template_recursive_body",
    APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION = "apply_expression_template_invalid_declaration",
    APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD = "apply_expression_template_version_too_old",
    REWRITE_RULE_NONTERMINATING = "rewrite_rule_nonterminating",
    TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET = "template_constraint_unknown_index_set",
    GEOMETRY_MANIFOLD_INVALID = "geometry_manifold_invalid",
    MAKEARRAY_REGION_INVERTED = "makearray_region_inverted",
    # Flatten-time shadow-registry guard (flatten.jl): a surviving registry
    # body references a variable a coupling `variable_map` rewrote in the
    # flattened equations (esm-spec §9.6.4 / §10.4).
    TEMPLATE_BODY_REFERENCES_COUPLING_REWRITTEN_VARIABLE = "template_body_references_coupling_rewritten_variable",
    # Projection-pushdown desugar post-condition (pushdown_rewrite.jl): a rect
    # factor the rewrite must re-point onto the generated per-support cell
    # gathers is named FREE in a template body instead of bound at the call
    # site, so the call-site-only rewrite cannot reach it (esm-spec §9.6.4
    # Option B / CONFORMANCE_SPEC §5.5.7).
    TEMPLATE_BODY_REFERENCES_PUSHDOWN_REWRITTEN_VARIABLE = "template_body_references_pushdown_rewritten_variable",

    # ── Template-library imports + load-time metaparameters (esm-spec §9.7;
    #    template_imports.jl). ──────────────────────────────────────────────
    TEMPLATE_IMPORT_VERSION_TOO_OLD = "template_import_version_too_old",
    TEMPLATE_IMPORT_UNRESOLVED = "template_import_unresolved",
    TEMPLATE_IMPORT_NOT_LIBRARY = "template_import_not_library",
    TEMPLATE_IMPORT_IS_COUPLING_LIBRARY = "template_import_is_coupling_library",
    TEMPLATE_IMPORT_CYCLE = "template_import_cycle",
    TEMPLATE_IMPORT_NAME_CONFLICT = "template_import_name_conflict",
    TEMPLATE_IMPORT_UNKNOWN_NAME = "template_import_unknown_name",
    TEMPLATE_IMPORT_INDEX_SET_CONFLICT = "template_import_index_set_conflict",
    TEMPLATE_IMPORT_RENAME_UNKNOWN_NAME = "template_import_rename_unknown_name",
    TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME = "template_import_rebind_unknown_name",
    TEMPLATE_IMPORT_RENAME_COLLISION = "template_import_rename_collision",
    TEMPLATE_IMPORT_RENAME_INVALID = "template_import_rename_invalid",
    TEMPLATE_INJECT_TARGET_UNKNOWN = "template_inject_target_unknown",
    TEMPLATE_INJECT_TARGET_NOT_COMPONENT = "template_inject_target_not_component",
    # Registered for cross-binding parity: Rust raises it, Julia's inject
    # validator currently folds the case into TEMPLATE_INJECT_TARGET_NOT_COMPONENT.
    TEMPLATE_INJECT_TARGET_IS_LOADER = "template_inject_target_is_loader",
    TEMPLATE_BODY_EXPANSION_TOO_DEEP = "template_body_expansion_too_deep",
    METAPARAMETER_UNBOUND = "metaparameter_unbound",
    METAPARAMETER_TYPE_ERROR = "metaparameter_type_error",
    METAPARAMETER_NAME_CONFLICT = "metaparameter_name_conflict",

    # ── Coupling-library imports (esm-spec §10.9–§10.11;
    #    coupling_imports.jl). ──────────────────────────────────────────────
    COUPLING_IMPORT_UNRESOLVED = "coupling_import_unresolved",
    COUPLING_IMPORT_NOT_LIBRARY = "coupling_import_not_library",
    COUPLING_IMPORT_UNKNOWN_ROLE = "coupling_import_unknown_role",
    COUPLING_IMPORT_ROLE_UNBOUND = "coupling_import_role_unbound",
    COUPLING_IMPORT_BIND_NOT_A_COMPONENT = "coupling_import_bind_not_a_component",
    COUPLING_EDGE_UNKNOWN_ROLE = "coupling_edge_unknown_role",
    COUPLING_ROLE_UNUSED = "coupling_role_unused",
    COUPLING_LIBRARY_ILLEGAL_PAYLOAD = "coupling_library_illegal_payload",
    COUPLING_LIBRARY_NESTED_IMPORT = "coupling_library_nested_import",

    # ── Subsystem-reference / index-set checks raised as an
    #    `ExpressionTemplateError` from the load pipeline (parse.jl). ───────
    SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY = "subsystem_ref_is_template_library",
    SUBSYSTEM_REF_IS_COUPLING_LIBRARY = "subsystem_ref_is_coupling_library",
    SUBSYSTEM_INDEX_SET_CONFLICT = "subsystem_index_set_conflict",

    # ── Closed function registry (esm-spec §9.1–§9.2;
    #    registered_functions.jl, raised as `ClosedFunctionError`). ─────────
    UNKNOWN_CLOSED_FUNCTION = "unknown_closed_function",
    CLOSED_FUNCTION_ARITY = "closed_function_arity",
    CLOSED_FUNCTION_OVERFLOW = "closed_function_overflow",
    SEARCHSORTED_NON_MONOTONIC = "searchsorted_non_monotonic",
    SEARCHSORTED_NAN_IN_TABLE = "searchsorted_nan_in_table",
    INTERP_NON_MONOTONIC_AXIS = "interp_non_monotonic_axis",
    INTERP_AXIS_LENGTH_MISMATCH = "interp_axis_length_mismatch",
    INTERP_NAN_IN_AXIS = "interp_nan_in_axis",
    INTERP_AXIS_TOO_SHORT = "interp_axis_too_short",
    # Raised by the AST extraction site rather than by
    # `evaluate_closed_function`; registered here because `ClosedFunctionError`
    # documents them as part of its code vocabulary.
    INTERP_TABLE_NOT_CONST = "interp_table_not_const",
    INTERP_AXIS_NOT_CONST = "interp_axis_not_const",

    # ── Discretization pipeline (tree_walk/; esm-spec §4.2 / §9.6.8). The one
    #    `TreeWalkError` code that is NOT an `E_TREEWALK_*` Julia-local name:
    #    it is the uniform cross-binding wire code every implementation
    #    surfaces when a rewrite-target operator (an RHS-position `D`, or
    #    `grad`/`div`/`laplacian`) reaches evaluation unlowered. ────────────
    UNLOWERED_OPERATOR = "unlowered_operator",
)

"""
    error_code_names() -> Vector{String}

Every diagnostic code string in [`ERROR_CODES`](@ref), sorted. Handy for
cross-binding vocabulary diffs and for asserting in tests that a raise site
uses a registered code.
"""
error_code_names()::Vector{String} = sort!(collect(String, values(ERROR_CODES)))
