"""
Central registry of the diagnostic code STRINGS this binding emits.

Julia carried these as inline string literals at ~160 raise sites — an
`error_type` positional on `StructuralError`, a first positional on
`ExpressionTemplateError` / `EnumLoweringError`, a `code=` keyword on
`SubsystemRefError` / `ParseError` — with no single place to read the
vocabulary off. This file is that place, the Julia twin of TypeScript's
`ERROR_CODES` object (`pkg/earthsci-ast-ts/src/errors.ts`), Python's
`ErrorCode` enum (`pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py`),
Go's `codes.go` and Rust's `diagnostic::codes`.

**The values are a cross-binding contract and must never change.** The shared
corpus `tests/invalid/expected_errors.json` pins many of them by value. Adding a new diagnostic means adding an entry here AND
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
    # ── Structural validation (src/validation/; the `error_type` of a
    #    `StructuralError`, pinned by tests/invalid/expected_errors.json) ────
    ARRAY_SHAPE_MISMATCH = "array_shape_mismatch",
    # esm-spec §6.6.5: an assertion whose form does not match the declared rank of
    # the variable it names -- pointwise on a shaped variable, or `coords` /
    # `reduce` on a scalar one.
    ASSERTION_RANK_MISMATCH = "assertion_rank_mismatch",
    CIRCULAR_DEPENDENCY = "circular_dependency",
    CONFLICTING_DERIVATIVE = "conflicting_derivative",
    # ── Flatten refusals (esm-libraries-spec §4.7.5, §4.7.6; `FlattenError`).
    #    Each named flatten error type carries the snake_case of its name;
    #    the operator_compose and couple codes are shared with TypeScript,
    #    Python and Go. ─────────────────────────────────────────────────────
    COUPLE_MULTIPLICATIVE_NO_TENDENCY = "couple_multiplicative_no_tendency",
    CYCLIC_PROMOTION = "cyclic_promotion",
    DIMENSION_PROMOTION = "dimension_promotion",
    DOMAIN_EXTENT_MISMATCH = "domain_extent_mismatch",
    # A document with no `models` and no `reaction_systems` (a template
    # library) has nothing to flatten.
    NOTHING_TO_FLATTEN = "nothing_to_flatten",
    OPERATOR_COMPOSE_AMBIGUOUS_BARE_NAME = "operator_compose_ambiguous_bare_name",
    OPERATOR_COMPOSE_NO_MERGE = "operator_compose_no_merge",
    OPERATOR_COMPOSE_REQUIRE_MATCH_UNMATCHED = "operator_compose_require_match_unmatched",
    SLICE_OUT_OF_DOMAIN = "slice_out_of_domain",
    UNMAPPED_DOMAIN = "unmapped_domain",
    UNSUPPORTED_MAPPING = "unsupported_mapping",
    VARIABLE_MAP_SHAPE_CONFLICT = "variable_map_shape_conflict",
    # A `variable_map` expression `transform` that does not read the entry's
    # `from` variable (esm-spec §10.4).
    VARIABLE_MAP_TRANSFORM_MISSING_FROM = "variable_map_transform_missing_from",
    VARIABLE_MAP_UNRESOLVED_ENDPOINT = "variable_map_unresolved_endpoint",
    DATA_SOURCE_UNDEFINED = "data_source_undefined",
    # esm-spec §8.5.1: the deprecated `from.records_per_sample` on a non-`data`
    # rule, or a written `records_per_sample` (the rule's own, else its source's
    # `temporal.records_per_sample`) that disagrees with the number of records
    # the parameter's record shape gives it.
    RECORDS_PER_SAMPLE_INVALID = "records_per_sample_invalid",
    # esm-spec §8.5.1: an index set with `"records": true` whose size is not 2.
    RECORD_AXIS_INVALID = "record_axis_invalid",
    # esm-spec §8.5.1: a data-fed parameter's record shape names a record axis
    # anywhere but first, or its several record shapes disagree about
    # beginning with one.
    RECORD_AXIS_MISPLACED = "record_axis_misplaced",
    # esm-spec §8.5.1: a record shape beginning with a record axis on a source
    # with no `temporal` block or no `temporal.start` (no successor record).
    RECORD_AXIS_TIME_INVARIANT_SOURCE = "record_axis_time_invariant_source",
    # esm-spec §9.6.6 / CONFORMANCE_SPEC §5.46: a data-fed parameter (an `update`
    # of `kind: "data"`) reached a build with NOTHING bound to it -- no provider,
    # no loaded array, no caller-supplied `p` value. Raised at CONSTRUCTION,
    # before any right-hand side is built, naming the parameter, the
    # `data_sources` entry and what to pass. The complement of
    # `data_source_undefined`: that one is the VALIDATOR's finding about a
    # source name that resolves to nothing, this one is the BUILD's finding
    # about a source that resolves and that nothing supplied data for. Refused
    # rather than bound from the parameter's `default`, which produces a whole
    # trajectory under the label of a rate the document says comes from a file.
    DATA_SOURCE_UNBOUND = "data_source_unbound",
    # esm-spec §8.2.1: a `data_sources[*].source.url_template` (or a `mirrors`
    # entry) that cannot be resolved to a URL at load time -- an unexpanded
    # `${VAR}` (§8.2 does not expand environment variables into a source's
    # location at all), or a resolved path carrying a `?` or `#`. Raised as an
    # `ExpressionTemplateError` from `data_source_urls.jl`; the message names
    # the offending data source and template.
    DATA_SOURCE_URL_UNRESOLVED = "data_source_url_unresolved",
    DOMAIN_UNIT_MISMATCH = "domain_unit_mismatch",
    EMPTY_CALLBACK_ID = "empty_callback_id",
    EQUATION_COUNT_MISMATCH = "equation_count_mismatch",
    EVENT_AFFECTS_PARAMETER = "event_affects_parameter",
    # esm-spec §6.3.1: an equation's left-hand side names a parameter, or
    # subscripts with an index symbol no faq binds.
    EQUATION_DEFINES_PARAMETER = "equation_defines_parameter",
    UNBOUND_INDEX_SYMBOL = "unbound_index_symbol",
    # esm-spec §11.4.2: an `ic` right-hand side reads a state, directly or
    # through observeds. A construction error, not a `validate` finding.
    IC_READS_STATE = "ic_reads_state",
    EVENT_VAR_UNDECLARED = "event_var_undeclared",
    INVALID_BROADCAST_FN = "invalid_broadcast_fn",
    INVALID_REFERENCE_SYNTAX = "invalid_reference_syntax",
    INVALID_STOICHIOMETRY = "invalid_stoichiometry",
    JOIN_KEY_INVALID_TYPE = "join_key_invalid_type",
    JOIN_SIDE_AMBIGUOUS = "join_side_ambiguous",
    JOIN_SYMS_UNKNOWN_SYMBOL = "join_syms_unknown_symbol",
    NULL_REACTION = "null_reaction",
    # esm-spec §4.9.6 (issue #181): a dependency cycle among a model's OBSERVED
    # unknowns — each is defined by an equation whose RHS names the next, so no
    # evaluation order satisfies every definition. Decidable from the equations
    # alone, hence a HARD structural error in `validate()` rather than a
    # surprise at build time; the self-edge of a §4.3.1.1 recurrence CANDIDATE
    # is an ordering WITHIN one variable and is not one of these edges.
    OBSERVED_CYCLE = "observed_cycle",
    # esm-spec §4.3.1 "Ragged ranges" (issue #259): a non-value-invention `faq`
    # ranges over a `kind: "ragged"` index set but its body never reads that
    # set's `values` array. The range symbol binds the POSITION k in
    # 1..offsets[parent], not a member, so the body reads positions — a
    # plausible wrong number rather than a failure.
    RAGGED_VALUES_NOT_GATHERED = "ragged_values_not_gathered",
    # A `faq` `expr`/`filter` reads a variable declared with a non-empty `shape`
    # by BARE name in an elementwise position (esm-spec §4.3.1, issue #441).
    FAQ_BARE_ARRAY_OPERAND = "faq_bare_array_operand",
    # An output name -- an `observed` request handed to `derive_output_plan` --
    # that matches no variable exactly and whose last dotted segment is shared
    # by more than one variable (CONFORMANCE_SPEC §5.17.4). A last-segment match
    # is accepted only when it designates exactly one variable, so a request
    # cannot silently select a variable it did not name.
    AMBIGUOUS_OUTPUT_NAME = "ambiguous_output_name",
    # Causal self-reference (esm-spec §4.3.1.1, CONFORMANCE_SPEC §5.19.5).
    # A VALIDATION category, so both codes are owed by every binding whether or
    # not it evaluates array numerics: the pre-1.0 behaviour of an ill-founded
    # self-read was a plausible wrong number, and a binding that only declined
    # to run it would leave the defect undiagnosed.
    RECURRENCE_NOT_WELLFOUNDED = "recurrence_not_wellfounded",
    RECURRENCE_UNSUPPORTED_FORM = "recurrence_unsupported_form",
    # esm-spec §4.3.1.2: the members of a recurrence group do not share one cell
    # frame (the same `output_idx` and ranges) and one recurrence axis.
    RECURRENCE_GROUP_AXIS_MISMATCH = "recurrence_group_axis_mismatch",
    # A bare-index observed definition (`index(V, k…) ~ rhs`, esm-spec §6.3.1)
    # outside the one runnable form, refused when the model is built for
    # simulation (CONFORMANCE_SPEC §5.36.2).
    INDEXED_DEFINITION_UNSUPPORTED_FORM = "indexed_definition_unsupported_form",
    RELATIONAL_NODE_IN_CONTINUOUS = "relational_node_in_continuous",
    # A DECLARATION — a `variables` key, a reaction species, or a reaction
    # parameter — spelled with a globally-scoped name: the document's
    # independent variable (`domain.independent_variable`, default "t") or the
    # §6.4 `_var` placeholder (esm-spec §4.9.1.1). Both are implicitly declared
    # in every component's expression scope and are resolved BY NAME ahead of
    # the declaration maps, so the declaration is unreachable and every reader
    # silently receives the implicit symbol — the simulation clock in place of
    # the declared quantity.
    RESERVED_VARIABLE_NAME = "reserved_variable_name",
    # Inline array data as the `default` of a variable that declares no `shape`
    # (esm-spec §6.3). Inline array data is a SHAPED variable's value, so with no
    # shape there is nothing for the array to fill.
    ARRAY_DEFAULT_WITHOUT_SHAPE = "array_default_without_shape",
    SYSTEM_KIND_MISMATCH = "system_kind_mismatch",
    UNDEFINED_INDEX_SET = "undefined_index_set",
    UNDEFINED_OPERATOR = "undefined_operator",
    UNDEFINED_PARAMETER = "undefined_parameter",
    UNDEFINED_SPECIES = "undefined_species",
    UNDEFINED_SYSTEM = "undefined_system",
    UNDEFINED_VARIABLE = "undefined_variable",
    # esm-spec §6.6.2: an inline test's `initial_conditions` / `parameter_overrides`
    # key that matches no declared name under the override-key rules.
    UNKNOWN_OVERRIDE_KEY = "unknown_override_key",
    # esm-spec §6.6.2 on a caller's keys (`p`, `u0`, `initial_conditions`,
    # `const_arrays`, `providers`): a key several declared names carry as a
    # suffix, and two keys (or two surfaces) that supply one name.
    OVERRIDE_KEY_AMBIGUOUS = "override_key_ambiguous",
    OVERRIDE_KEY_CONFLICT = "override_key_conflict",
    UNRESOLVED_SCOPED_REF = "unresolved_scoped_ref",
    # A coupling event affect target that resolves to no variable (validation/references.jl).
    UNRESOLVED_AFFECT_TARGET = "unresolved_affect_target",

    # ── Units (units.jl §4.8.4). Both are HARD errors: `UNIT_INCONSISTENCY`
    #    is a PROVABLE dimensional mismatch, `UNIT_PARSE_ERROR` a declared
    #    unit string that denotes no real unit. An UNDETERMINABLE dimension is
    #    not a finding at all — the engine returns `nothing` and the enclosing
    #    check is skipped. `UNIT_DIMENSION_MISMATCH` / `UNIT_PARSE_ERROR` in
    #    units.jl are the long-standing public aliases of these two. ────────
    UNIT_INCONSISTENCY = "unit_inconsistency",
    UNIT_PARSE_ERROR = "unit_parse_error",

    # ── Unit-FINDING kinds: a SECOND, smaller vocabulary, carried on
    #    `UnitWarning.code` rather than on a `StructuralError`. The two above
    #    name the STRUCTURAL error a finding is promoted to; these three name
    #    the finding itself, and they are what a caller filters
    #    `ValidationResult.unit_warnings` on. Values shared verbatim with Go's
    #    `UnitFinding*` (`pkg/earthsci-ast-go/pkg/esm/units.go`), Rust's
    #    `UNIT_FINDING_*` and TypeScript's `UnitWarning['code']` union.
    #    The first two state a defect in the FILE, the third a limit of the
    #    ANALYSIS. ───────────────────────────────────────────────────────────
    DIMENSIONAL_MISMATCH = "dimensional_mismatch",
    UNPARSEABLE_UNIT = "unparseable_unit",
    ANALYSIS = "analysis",
    #    A check site the current neutral-literal rule passes or skips fails
    #    once a bare numeric literal is read as dimensionless (esm-spec
    #    §4.8.6). A WARNING at this stage, never promoted to a structural
    #    error. `UNIT_FINDING_DIMENSIONLESS_LITERAL` in units.jl is its
    #    public alias.
    UNITS_DIMENSIONLESS_LITERAL_MISMATCH = "units_dimensionless_literal_mismatch",

    # ── Document load / subsystem-reference resolution (resolve.jl, parse.jl;
    #    esm-spec §4.7). These are THROWN at load, and `validate` renders the
    #    same `(code, path)` pair as a structural finding. ──────────────────
    UNRESOLVED_SUBSYSTEM_REF = "unresolved_subsystem_ref",
    AMBIGUOUS_SUBSYSTEM_REF = "ambiguous_subsystem_ref",
    IC_IN_REACTION_SYSTEM = "ic_in_reaction_system",

    # ── Expression templates (esm-spec §9.6) + the §9.6.4 post-expansion
    #    validators (templates/declarations.jl, templates/rewrite.jl). ──────
    APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE = "apply_expression_template_unknown_template",
    APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH = "apply_expression_template_bindings_mismatch",
    APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY = "apply_expression_template_recursive_body",
    APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION = "apply_expression_template_invalid_declaration",
    APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD = "apply_expression_template_version_too_old",
    REWRITE_RULE_NONTERMINATING = "rewrite_rule_nonterminating",
    TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET = "template_constraint_unknown_index_set",
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

    # ── Document-scoped solver hints (esm-spec §2.2; solver.jl). ─────────
    SOLVER_VERSION_TOO_OLD = "solver_version_too_old",
    SOLVER_EXTERNAL_VERSION_TOO_OLD = "solver_external_version_too_old",
    SOLVER_EXTERNAL_UNRESOLVED = "solver_external_unresolved",
    SOLVER_TIME_SPAN_VERSION_TOO_OLD = "solver_time_span_version_too_old",
    SOLVER_TIME_SPAN_INVALID = "solver_time_span_invalid",
    # The §2.2.7 clock accessors (`time_origin`, `timestamp_to_seconds`), one
    # code per cause, so a caller tells them apart without reading the message.
    TIMESTAMP_MALFORMED = "timestamp_malformed",
    TIMESTAMP_NO_CALENDAR_DAY = "timestamp_no_calendar_day",
    TIME_ORIGIN_INVALID = "time_origin_invalid",

    # ── Declared units on a const node (esm-spec §4.8.5; units.jl). ──────
    CONST_UNITS_VERSION_TOO_OLD = "const_units_version_too_old",

    # ── Variable bounds `lb` / `ub` (esm-spec §6.3.2; variable_bounds.jl).
    #    The version gate is a load rejection; the other three are
    #    `StructuralError`s, beside `undefined_variable` for an unresolved
    #    reference. ─────────────────────────────────────────────────────────
    VARIABLE_BOUNDS_VERSION_TOO_OLD = "variable_bounds_version_too_old",
    VARIABLE_BOUND_SHAPE_MISMATCH = "variable_bound_shape_mismatch",
    VARIABLE_BOUND_CIRCULAR = "variable_bound_circular",
    VARIABLE_BOUNDS_INVERTED = "variable_bounds_inverted",

    # ── Template-library imports + load-time metaparameters (esm-spec §9.7;
    #    templates/imports.jl, templates/metaparameters.jl). ───────────────
    TEMPLATE_IMPORT_VERSION_TOO_OLD = "template_import_version_too_old",
    TEMPLATE_IMPORT_UNRESOLVED = "template_import_unresolved",
    TEMPLATE_IMPORT_NOT_LIBRARY = "template_import_not_library",
    TEMPLATE_IMPORT_IS_COUPLING_LIBRARY = "template_import_is_coupling_library",
    TEMPLATE_LIBRARY_ILLEGAL_PAYLOAD = "template_library_illegal_payload",
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

    # ── A document that fails the schema at load (`SchemaValidationError`;
    #    the code TypeScript's `SchemaValidationError` carries). ─────────────
    SCHEMA_VALIDATION_ERROR = "schema_validation_error",

    # ── A data-source `unit_conversion` that cannot be parsed or applied
    #    (`UnitConversionError`; the code TypeScript's carries). ─────────────
    UNIT_ERROR = "unit_error",

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
    # A mount edge's `index_set_rename` names an index set the RESOLVED mounted
    # document does not declare (esm-spec §4.7 "Mount-edge index-set
    # renaming") — the mount-edge mirror of
    # `template_import_rename_unknown_name`.
    SUBSYSTEM_INDEX_SET_RENAME_UNKNOWN_NAME = "subsystem_index_set_rename_unknown_name",
    # A mount edge's `url_substitutions` key names no bare `{name}` placeholder
    # of any `url_template` / `mirrors` entry of the referenced document's
    # `data_sources` (esm-spec §4.7 "Binding a data source's location at the
    # mount"): like `index_set_rename`, the edge never invents a name.
    URL_SUBSTITUTION_UNKNOWN_NAME = "url_substitution_unknown_name",
    # Two mounts contribute the same `data_sources` name with entries that are
    # not identical after `url_substitutions` and §8.2.1 resolution, and the
    # mounting document does not declare it itself (esm-spec §4.7 "A mounted
    # document's data sources").
    DATA_SOURCE_MERGE_CONFLICT = "data_source_merge_conflict",

    # `index_set_rename` on a mount form that does not implement it (esm-spec
    # §4.7 "Mount-edge index-set renaming", "Where it applies"). The field is a
    # legal `SubsystemRef` property at every mount form, and a binding that
    # cannot apply it at one MUST say so rather than merge the leaf under its
    # pre-rename axis names. This binding applies it at every form, so it never
    # raises it; the constant exists because the code table is cross-language
    # uniform.
    SUBSYSTEM_INDEX_SET_RENAME_UNSUPPORTED_MOUNT_FORM =
        "subsystem_index_set_rename_unsupported_mount_form",
    # A §4.7 `{ref}` mount at a form a binding does not implement. This binding
    # implements every form, so it never raises it; the constant exists because
    # the code table is cross-language uniform.
    MOUNT_FORM_UNSUPPORTED = "mount_form_unsupported",
    # A declared working precision reaches a construct that cannot carry it
    # (esm-spec §4.7 "Working precision crosses a mount", §11.3.1): a mounted
    # leaf's `domain.element_type` that must be written onto a reaction system,
    # whose species and parameters have no per-variable `element_type`.
    ELEMENT_TYPE_UNCARRIED = "element_type_uncarried",
    # A construct an evaluator cannot run at the precision it is declared in
    # (CONFORMANCE_SPEC §5.18.2): refused rather than evaluated in binary64. The
    # tree-walk evaluator computes in binary64 only, so it refuses every binary32
    # variable.
    FLOAT32_UNSUPPORTED = "float32_unsupported",

    # ── Enum lowering (esm-spec §9.3; enum_lowering.jl, raised as
    #    `EnumLoweringError`). The two `unknown_*` values are the ones the
    #    Python binding already carries on its `EnumLoweringError.code`
    #    (`UNKNOWN_ENUM` / `UNKNOWN_ENUM_SYMBOL`) and the ones Julia already
    #    interpolated as a message prefix before this pass raised a structured
    #    error; `ENUM_OP_MALFORMED` is TypeScript's spelling for the
    #    wrong-arity / wrong-arg-type rejection. ─────────────────────────────
    ENUM_OP_MALFORMED = "enum_op_malformed",
    UNKNOWN_ENUM = "unknown_enum",
    UNKNOWN_ENUM_SYMBOL = "unknown_enum_symbol",
    # Two symbols of ONE enum map to the same integer (esm-spec §9.3). A defect
    # of the `enums` block itself, reported before any `enum` op resolves.
    ENUM_DUPLICATE_VALUE = "enum_duplicate_value",

    # ── Discretization pipeline (tree_walk/; esm-spec §4.2 / §9.6.8). The one
    #    `TreeWalkError` code that is NOT an `E_TREEWALK_*` Julia-local name:
    #    it is the uniform cross-binding wire code every implementation
    #    surfaces when a rewrite-target operator (an RHS-position or spatial
    #    `D`, or a user op) reaches evaluation unlowered. ────────────
    UNLOWERED_OPERATOR = "unlowered_operator",
    # An expression node spelling an op that was REMOVED rather than deprecated
    # (`arrayop` at 0.8.0; `fn`, `table_lookup`, `skolem`, `rank`,
    # `intersect_polygon`, `polygon_intersection_area`, `argmin`, `argmax`,
    # `aggregate` and the `function_tables` block at 2.0.0; `grad`, `div` and
    # `laplacian` at 3.0.0), rejected by name at the wire
    # boundary (CONFORMANCE_SPEC §7).
    REMOVED_OP = "removed_op",
    # A document spells `"op": "faq"` while declaring esm below 1.1.0, the
    # version `faq` arrives at; refused at the wire boundary (CONFORMANCE_SPEC
    # §7, esm-spec §4.2 "The `faq` tag").
    FAQ_VERSION_TOO_OLD = "faq_version_too_old",
    # A Markdown or Typst source text is not an ESM document: an unknown word,
    # an ambiguous juxtaposition, an unbalanced delimiter, an unclosed display,
    # container or directive, and every other malformed input the document
    # readers refuse (CONFORMANCE §5.58; document_format.jl). A removed
    # operator in the text is `removed_op` instead.
    PARSE_ERROR = "parse_error",
    # WARNING, not an error: an expression node spelling a DEPRECATED op (`neg`,
    # the word spelling of unary `-`; `pow`, of `^`; or `neg` as a `broadcast`
    # `fn`), rewritten to its replacement at the wire boundary (esm-spec §4.2
    # "Deprecated ops").
    DEPRECATED_OP = "deprecated_op",
    # ── Its complement (esm-spec §9.6.6): an op that IS in the §4.2 evaluable
    #    core but that the tree-walk evaluator has no rule for (an array/query or
    #    value-invention op outside the position that consumes it, an unlowered
    #    `enum`). Refused when the evaluator is BUILT, never at evaluation. ────
    UNEVALUABLE_OPERATOR = "unevaluable_operator",
    # A surviving expression ranges over a `kind: "derived"` index set whose
    # producer could not be materialized at build (esm-spec §9.6.6). Refused
    # rather than contracted as an empty range, which would read as 0.
    DERIVED_INDEX_SET_UNMATERIALIZED = "derived_index_set_unmaterialized",
    # A `distinct` key or a value-invention `join` column evaluates to NaN (a
    # lib/relational.esm key template's out-of-range component), naming the
    # column (esm-spec §9.6.6). Takes precedence over the code above.
    VALUE_INVENTION_KEY_OUT_OF_RANGE = "value_invention_key_out_of_range",
    # ── Evaluator refusal (tree_walk/; esm-spec §9.6.6). A continuous event, a
    #    discrete event or an implicit equation reached the tree-walk evaluator,
    #    which runs none of them. Refused at build rather than skipped, because a
    #    run without the construct reports a wrong answer. The ModelingToolkit
    #    export runs all three and never raises it. ───────────────────────────
    UNSUPPORTED_CONSTRUCT = "unsupported_construct",
    # An equation reads a `callback` coupling variable, and no callback is
    #    registered to supply it at construction (esm-spec §9.6.6).
    CALLBACK_UNREGISTERED = "callback_unregistered",
    # ── Compiler selection (API_SPEC §5.8; esm-spec §9.6.6). The `compiler`
    #    keyword of `esm_problem` names one member of a closed vocabulary, and
    #    the three codes below are the three ways naming one can fail. None of
    #    them is ever answered by running a different compiler than the one the
    #    caller asked for. ─────────────────────────────────────────────────────
    # The value is outside the vocabulary.
    COMPILER_UNKNOWN = "compiler_unknown",
    # The value is in the vocabulary, but this binding, build or process cannot
    # provide it. The message names what to load or build.
    COMPILER_UNAVAILABLE = "compiler_unavailable",
    # The chosen compiler cannot run this document. The message names the
    # compiler, the rule (equation or observed, component-qualified) and the
    # reason.
    COMPILER_REFUSED_RULE = "compiler_refused_rule",
    # ── Range-restricted right-hand sides (API_SPEC §5.8; esm-spec §9.6.6):
    #    `select`, `halo`, `restrict` and `lanes`. Each message names the rule,
    #    the variable or the index set the failure is about. ──────────────────
    # An in-domain read of a tile falls outside its storage box and has no
    # periodic image in it (tile rule 2). Names the missing cells.
    RANGE_HALO_INSUFFICIENT = "range_halo_insufficient",
    # A 0-d state write on a tile, or a contraction, scan or data-dependent
    # gather along a decomposed axis: `global` locality.
    RANGE_GLOBAL_LOCALITY = "range_global_locality",
    # `select`'s `writes` omits a variable its kept contributions write.
    RANGE_SELECTION_WRITES_INCOMPLETE = "range_selection_writes_incomplete",
    # An owned box outside its storage box or outside `1..N`, an unknown index
    # set, a face set declared against an axis that is not cut, a period that
    # is not the axis's extent, or lane sets that do not match the kind.
    RANGE_BOX_INVALID = "range_box_invalid",
    # ── Strip and expose (API_SPEC §5.8; esm-spec §9.6.6) ────────────────────
    # `solve` / `init` on a Problem `strip` removed constructs from.
    STRIPPED_PROBLEM_NOT_SOLVABLE = "stripped_problem_not_solvable",
    # A kernel spec's output, `dt_params` entry or map target does not resolve.
    KERNEL_OUTPUT_UNRESOLVED = "kernel_output_unresolved",
    # An event affect compiled as a kernel reads, bare, a variable its event
    # also assigns.
    AFFECT_READS_POST_VALUE = "affect_reads_post_value",
    # ── Problem construction and the run-time API (`SimulateError`,
    #    `RefreshError`). Julia's own vocabulary for refusals no shared code
    #    names; no other binding raises them yet. ─────────────────────────────
    # A caller argument the API cannot take: a value of the wrong type, two
    # options that exclude each other, a path that names no file, metaparameters
    # handed with an input whose metaparameters are already closed.
    INVALID_ARGUMENT = "invalid_argument",
    # The call needs a package extension that is not loaded; the message names
    # the package to load.
    EXTENSION_UNAVAILABLE = "extension_unavailable",
    # `observed_field` names something that is not a build-time field of the
    # problem: not an observed, or an observed that reads the continuous state
    # and no state was passed.
    OBSERVED_FIELD_UNAVAILABLE = "observed_field_unavailable",
    # A parameter with no default that no override binds.
    PARAMETER_UNBOUND = "parameter_unbound",
    # A `remake` override of a parameter whose value the build fixed
    # (structural, const-folded data, live forcing data).
    PARAMETER_NOT_OVERRIDABLE = "parameter_not_overridable",
    # Providers disagree on a loader's record extent, or a provider's extent
    # contradicts the caller's metaparameter binding or its own gate.
    PROVIDER_EXTENT_CONFLICT = "provider_extent_conflict",
    # A provider's projection-pushdown gate spec is malformed (esm-spec §8.9.2).
    PROVIDER_GATE_INVALID = "provider_gate_invalid",
    # A provider lacks a method of the provider protocol the run needs.
    PROVIDER_METHOD_MISSING = "provider_method_missing",
    # A loader's data does not decode as its declaration says: a value not in
    # the declared `codes` map, a text column with no `codes` map, or a `codes`
    # map on a column that is not text (esm-spec §8.9.1).
    PROVIDER_DATA_INVALID = "provider_data_invalid",
    # An invariant of this binding's own build does not hold; a bug to report.
    INTERNAL_ERROR = "internal_error",
)

"""
    error_code_names() -> Vector{String}

Every diagnostic code string in [`ERROR_CODES`](@ref), sorted. Handy for
cross-binding vocabulary diffs and for asserting in tests that a raise site
uses a registered code.
"""
error_code_names()::Vector{String} = sort!(collect(String, values(ERROR_CODES)))


"""
    _LOCAL_ERROR_CODES

The diagnostic codes this binding raises that are NOT in [`ERROR_CODES`](@ref):
the `E_TREEWALK_*` codes of the tree-walk evaluator ([`TreeWalkError`](@ref)),
`E_CANONICAL_*` ([`CanonicalizeError`](@ref)), `E_REF_*`
([`ReferenceResolutionError`](@ref)) and `E_DIRECT_*` ([`DirectEmitError`](@ref)).
They name failures of Julia's own evaluators and are not a cross-binding
contract, so they stay out of the shared registry. Raise sites write them as
literals; `test/error_hierarchy_test.jl` checks that every `"E_…"` literal in
`src` and `ext` is listed here, which is the typo guard the registry gives the
shared codes.
"""
const _LOCAL_ERROR_CODES = (
    # CANONICAL
    "E_CANONICAL_BAD_CONST",
    "E_CANONICAL_BAD_NODE",
    "E_CANONICAL_DIVBY_ZERO",
    "E_CANONICAL_NONFINITE",
    "E_CANONICAL_UNSUPPORTED_FIELD",
    # DIRECT
    "E_DIRECT_EMIT_UNSUPPORTED",
    # REF
    "E_REF_CYCLE",
    "E_REF_DUPLICATE_NODE_ID",
    "E_REF_UNDECLARED_INDEX_SET",
    "E_REF_UNKNOWN_FAQ_NODE",
    "E_REF_UNRESOLVED_JOIN_FACTOR",
    # TREEWALK
    "E_TREEWALK_ACC_BAD_DESC",
    "E_TREEWALK_ACC_UNSUPPORTED_OP",
    "E_TREEWALK_AMBIGUOUS_MODEL",
    "E_TREEWALK_ARITY",
    "E_TREEWALK_ARRAYOP_INDEX_NDIM",
    "E_TREEWALK_ARRAYOP_MALFORMED_LHS",
    "E_TREEWALK_ARRAYOP_NO_BODY",
    "E_TREEWALK_ARRAYOP_UNKNOWN_REDUCE",
    "E_TREEWALK_ARRAYOP_UNSUPPORTED_SEMIRING",
    "E_TREEWALK_ARRAY_SHAPE_MISMATCH",
    "E_TREEWALK_BROADCAST_FN",
    "E_TREEWALK_BROADCAST_SHAPE",
    "E_TREEWALK_COMPILE_ONCE_UNSUPPORTED",
    "E_TREEWALK_CONSTARRAY_BOUNDARY_KIND",
    "E_TREEWALK_CONSTARRAY_BOUNDARY_NDIM",
    "E_TREEWALK_CONSTARRAY_NDIM",
    "E_TREEWALK_CONSTARRAY_OOB",
    "E_TREEWALK_CONTRACTION_LOOP_INTERNAL",
    "E_TREEWALK_CYCLIC_ARRAY_OBSERVED",
    "E_TREEWALK_DERIVED_NO_FAQ",
    "E_TREEWALK_DISCRETE_MATERIALIZE",
    "E_TREEWALK_DUPLICATE_DERIVATIVE",
    "E_TREEWALK_DYNAMIC_RANGE",
    "E_TREEWALK_FLOAT32_STATE",
    "E_TREEWALK_GATED_OBSERVED",
    "E_TREEWALK_GEOMETRY_SETUP",
    "E_TREEWALK_IC_IN_RHS",
    "E_TREEWALK_INDEX_EMPTY",
    "E_TREEWALK_INDEX_NDIM",
    "E_TREEWALK_INDEX_NOT_ARRAY",
    "E_TREEWALK_INDEX_NOT_CONST",
    "E_TREEWALK_INDEX_SET_INCOMPLETE",
    "E_TREEWALK_INEXACT_SUBSCRIPT",
    "E_TREEWALK_INTEGRAL_EMPTY",
    "E_TREEWALK_INTEGRAL_NDIM",
    "E_TREEWALK_INTEGRAL_NO_INTVAR",
    "E_TREEWALK_INTERNAL",
    "E_TREEWALK_JOIN_AMBIGUOUS_KEY",
    "E_TREEWALK_JOIN_FLOAT_KEY",
    "E_TREEWALK_JOIN_KEY_KIND",
    "E_TREEWALK_JOIN_KEY_TYPE",
    "E_TREEWALK_JOIN_NULL_KEY",
    "E_TREEWALK_JOIN_OVERLAP",
    "E_TREEWALK_JOIN_SYMS_CONFLICT",
    "E_TREEWALK_JOIN_SYMS_UNKNOWN",
    "E_TREEWALK_JOIN_UNKNOWN_KEY",
    "E_TREEWALK_MAKEARRAY_MISMATCH",
    "E_TREEWALK_MAKEARRAY_NDIM",
    "E_TREEWALK_MAKEARRAY_VALUE_RANK",
    "E_TREEWALK_MISSING_CELL",
    "E_TREEWALK_MISSING_DATA",
    "E_TREEWALK_MISSING_INITIAL_VALUE",
    "E_TREEWALK_NO_MODEL",
    "E_TREEWALK_OBSERVED_CYCLE",
    "E_TREEWALK_OOP_NOT_EVALUABLE",
    "E_TREEWALK_PARAM_ARRAY_TYPE",
    "E_TREEWALK_PARAM_UNSTAMPABLE",
    "E_TREEWALK_PGATHER_KEY_COLLISION",
    "E_TREEWALK_PGATHER_NDIM",
    "E_TREEWALK_PGATHER_OOB",
    "E_TREEWALK_RAGGED_NO_PARENTS",
    "E_TREEWALK_RANGE_ARITY",
    "E_TREEWALK_RECUR_UNAVAILABLE",
    "E_TREEWALK_SCAN_EMPTY_RANGE",
    "E_TREEWALK_SCAN_UNKNOWN_OPLUS",
    "E_TREEWALK_SHAPE_OP",
    "E_TREEWALK_TIME_NAME_CLASH",
    "E_TREEWALK_TRACED_SUBSCRIPT",
    "E_TREEWALK_UNBOUND_LOOP_VAR",
    "E_TREEWALK_UNBOUND_VARIABLE",
    "E_TREEWALK_UNDECLARED_INDEX_SET",
    "E_TREEWALK_UNKNOWN_FORM",
    "E_TREEWALK_UNKNOWN_INDEX_SET_KIND",
    "E_TREEWALK_UNKNOWN_NODE_KIND",
    "E_TREEWALK_UNKNOWN_SEMIRING",
    "E_TREEWALK_UNKNOWN_STATE",
    "E_TREEWALK_UNRESOLVED_TEMPLATE_REF",
    "E_TREEWALK_UNSUPPORTED_EQUATION",
    "E_TREEWALK_UNSUPPORTED_LHS",
    "E_TREEWALK_UNSUPPORTED_OP",
    "E_TREEWALK_UNSUPPORTED_RECURRENCE",
    "E_TREEWALK_UNSUPPORTED_SHAPE",
    "E_TREEWALK_VI_FLOAT_KEY",
    "E_TREEWALK_VI_INDEX",
    "E_TREEWALK_VI_JOIN",
    "E_TREEWALK_VI_KEY",
    "E_TREEWALK_VI_MAP",
    "E_TREEWALK_VI_MEMBER_FACTOR",
    "E_TREEWALK_VI_NODE",
    "E_TREEWALK_VI_OP",
    "E_TREEWALK_VI_PARAM",
    "E_TREEWALK_VI_PRODUCER",
    "E_TREEWALK_VI_RANGE",
    "E_TREEWALK_VI_RANGE_CYCLE",
    "E_TREEWALK_VI_SYMBOL",
)
