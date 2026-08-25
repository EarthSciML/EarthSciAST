//! Shared `{code, message}` diagnostic error for the load-time lowering
//! passes (expression templates / template imports, enum lowering).
//!
//! The `code` field is a STABLE cross-binding diagnostic identifier (e.g.
//! `template_import_unknown_name`, `unknown_enum`) that the conformance
//! fixtures match on — bindings must agree on codes, while `message` prose is
//! binding-local. The per-pass public names (`ExpressionTemplateError`,
//! `EnumLoweringError`) are aliases of this one type so each pass keeps its
//! documented API surface without duplicating the struct and its impls.

/// A lowering-pass diagnostic: stable `code` plus human-readable `message`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticError {
    /// Stable cross-binding diagnostic code (snake_case).
    pub code: &'static str,
    /// Human-readable description (binding-local prose).
    pub message: String,
}

impl std::fmt::Display for DiagnosticError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl std::error::Error for DiagnosticError {}

/// Shorthand constructor used throughout the lowering passes.
pub(crate) fn err(code: &'static str, message: impl Into<String>) -> DiagnosticError {
    DiagnosticError {
        code,
        message: message.into(),
    }
}

/// Central registry of the diagnostic code STRINGS this binding emits on a
/// [`DiagnosticError`] (the load-time lowering passes: §9.6 expression
/// templates, §9.7 template-library and coupling-library imports, §9.3 enum
/// lowering, §4.7 subsystem refs).
///
/// Cross-binding contract — **these values must never change**. They are pinned
/// by the shared conformance fixtures (`tests/invalid/expected_errors.json`)
/// and mirrored by TypeScript's `ERROR_CODES`
/// (`pkg/earthsci-ast-ts/src/errors.ts`) and Python's `ErrorCode` enum
/// (`pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py`). Every constant
/// below equals, byte for byte, a literal that was already emitted somewhere in
/// `src/`; this module only CENTRALIZES the references — it does not (and must
/// not) change any emitted string. Adding a new diagnostic means adding an entry
/// here AND coordinating the value across every binding.
///
/// Constant names are the SCREAMING_SNAKE_CASE form of the value (mirroring the
/// TypeScript keys and the Python enum), so a reference reads as
/// `codes::TEMPLATE_IMPORT_UNKNOWN_NAME`.
///
/// Scope: every diagnostic code string this binding emits, whichever error
/// type carries it — [`DiagnosticError`], `StructuralError`
/// (`crate::validate::StructuralErrorCode::to_string` is defined off these
/// constants), `ClosedFunctionError` and the `UnitWarning` finding kinds
/// (`crate::units::UNIT_FINDING_*` are aliases of the three below). The one
/// deliberate exclusion is the DAE lowering's Rust-local `E_*` names, which
/// are not a cross-binding vocabulary — Julia excludes its `E_TREEWALK_*`
/// names from `ERROR_CODES` for the same reason.
///
/// [`ERROR_CODES`] is the enumerable form of this module, for tests and
/// cross-binding vocabulary diffs.
pub mod codes {
    // ---- expression templates: §9.6 lowering (`lower_expression_templates.rs`)
    //      ----

    /// An `apply_expression_template` whose supplied bindings do not match the
    /// template's declared parameter list (missing, extra, or duplicated).
    pub const APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH: &str =
        "apply_expression_template_bindings_mismatch";
    /// A malformed `expression_templates` declaration — the single most-emitted
    /// code in this pass, covering every shape violation of the template
    /// declaration itself.
    pub const APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION: &str =
        "apply_expression_template_invalid_declaration";
    /// A template body that (directly or transitively) applies itself.
    pub const APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY: &str =
        "apply_expression_template_recursive_body";
    /// An `apply_expression_template` naming a template the document does not
    /// declare (and no import supplies).
    pub const APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE: &str =
        "apply_expression_template_unknown_template";
    /// A template declaring a `min_spec_version` newer than this binding
    /// implements.
    pub const APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD: &str =
        "apply_expression_template_version_too_old";
    /// A rewrite rule whose repeated application does not reach a fixed point.
    pub const REWRITE_RULE_NONTERMINATING: &str = "rewrite_rule_nonterminating";
    /// Template body expansion exceeded the depth budget (a runaway, but not
    /// provably self-recursive, expansion).
    pub const TEMPLATE_BODY_EXPANSION_TOO_DEEP: &str = "template_body_expansion_too_deep";
    /// A template `constraints` entry naming an index set absent from the
    /// document's `index_sets` registry.
    pub const TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET: &str = "template_constraint_unknown_index_set";

    // ---- templates: geometry / makearray structural folds (also emitted from
    //      `lower_expression_templates.rs` during template lowering) ----

    /// A `geometry` manifold declaration that is not a well-formed manifold.
    pub const GEOMETRY_MANIFOLD_INVALID: &str = "geometry_manifold_invalid";
    /// A `makearray` region whose `hi` bound precedes its `lo` bound.
    pub const MAKEARRAY_REGION_INVERTED: &str = "makearray_region_inverted";

    // ---- template-library imports: §9.7 (`template_imports.rs`) ----

    /// An imported metaparameter name collides with a name already in scope.
    pub const METAPARAMETER_NAME_CONFLICT: &str = "metaparameter_name_conflict";
    /// A metaparameter bound to a value of the wrong type (or used where its
    /// declared type does not admit it).
    pub const METAPARAMETER_TYPE_ERROR: &str = "metaparameter_type_error";
    /// A metaparameter referenced by a template body with no binding in scope.
    pub const METAPARAMETER_UNBOUND: &str = "metaparameter_unbound";
    /// A cycle in the template-library import graph.
    pub const TEMPLATE_IMPORT_CYCLE: &str = "template_import_cycle";
    /// A `template_imports` entry resolving to a COUPLING library, which
    /// exports roles rather than templates.
    pub const TEMPLATE_IMPORT_IS_COUPLING_LIBRARY: &str = "template_import_is_coupling_library";
    /// A `template_imports` entry resolving to a document that is not a library
    /// at all.
    pub const TEMPLATE_IMPORT_NOT_LIBRARY: &str = "template_import_not_library";
    /// A `rebind` naming a metaparameter the imported library does not declare.
    pub const TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME: &str = "template_import_rebind_unknown_name";
    /// A `rename` whose target name is already taken in the importing scope.
    pub const TEMPLATE_IMPORT_RENAME_COLLISION: &str = "template_import_rename_collision";
    /// A `rename` whose target is not a syntactically valid name.
    pub const TEMPLATE_IMPORT_RENAME_INVALID: &str = "template_import_rename_invalid";
    /// A `rename` naming a source the imported library does not export.
    pub const TEMPLATE_IMPORT_RENAME_UNKNOWN_NAME: &str = "template_import_rename_unknown_name";
    /// An explicit import `names` entry the library does not export.
    pub const TEMPLATE_IMPORT_UNKNOWN_NAME: &str = "template_import_unknown_name";
    /// A `template_imports` `ref` that does not resolve (missing file, remote
    /// URL, unreadable or unparseable document).
    pub const TEMPLATE_IMPORT_UNRESOLVED: &str = "template_import_unresolved";
    /// An imported library declaring a `min_spec_version` newer than this
    /// binding implements.
    pub const TEMPLATE_IMPORT_VERSION_TOO_OLD: &str = "template_import_version_too_old";
    /// An `inject` whose target names a data LOADER rather than a component.
    pub const TEMPLATE_INJECT_TARGET_IS_LOADER: &str = "template_inject_target_is_loader";
    /// An `inject` whose target resolves to something that is not a component.
    pub const TEMPLATE_INJECT_TARGET_NOT_COMPONENT: &str = "template_inject_target_not_component";
    /// An `inject` whose target names nothing in the importing document.
    pub const TEMPLATE_INJECT_TARGET_UNKNOWN: &str = "template_inject_target_unknown";

    // ---- coupling libraries: §9.7 coupling-library imports
    //      (`coupling_imports.rs`) ----

    /// A coupling edge naming a role the library does not declare.
    pub const COUPLING_EDGE_UNKNOWN_ROLE: &str = "coupling_edge_unknown_role";
    /// A role `bind` target that is not a component.
    pub const COUPLING_IMPORT_BIND_NOT_A_COMPONENT: &str = "coupling_import_bind_not_a_component";
    /// A `coupling_imports` entry resolving to a document that is not a
    /// coupling library.
    pub const COUPLING_IMPORT_NOT_LIBRARY: &str = "coupling_import_not_library";
    /// A declared role left without a binding at the import site.
    pub const COUPLING_IMPORT_ROLE_UNBOUND: &str = "coupling_import_role_unbound";
    /// A `bind` naming a role the imported library does not declare.
    pub const COUPLING_IMPORT_UNKNOWN_ROLE: &str = "coupling_import_unknown_role";
    /// A `coupling_imports` `ref` that does not resolve.
    pub const COUPLING_IMPORT_UNRESOLVED: &str = "coupling_import_unresolved";
    /// A coupling library carrying payload a coupling library may not hold.
    pub const COUPLING_LIBRARY_ILLEGAL_PAYLOAD: &str = "coupling_library_illegal_payload";
    /// A coupling library that itself declares an import (nesting is not
    /// permitted).
    pub const COUPLING_LIBRARY_NESTED_IMPORT: &str = "coupling_library_nested_import";
    /// A declared role that no imported coupling edge ever uses.
    pub const COUPLING_ROLE_UNUSED: &str = "coupling_role_unused";

    // ---- enums: §9.3 load-time enum lowering (`lower_enums.rs`) ----

    /// An enum operator applied to an argument list its arity does not admit.
    pub const ENUM_INVALID_ARGS: &str = "enum_invalid_args";
    /// An enum construct survived lowering — nothing downstream can interpret
    /// it, so loading must fail rather than silently discard it.
    pub const ENUM_LOWERING_RESIDUAL: &str = "enum_lowering_residual";
    /// A malformed top-level `enums` block.
    pub const INVALID_ENUMS_BLOCK: &str = "invalid_enums_block";
    /// A reference to an enum the document does not declare.
    pub const UNKNOWN_ENUM: &str = "unknown_enum";
    /// A reference to a symbol the named enum does not declare.
    pub const UNKNOWN_ENUM_SYMBOL: &str = "unknown_enum_symbol";

    // ---- subsystem refs: §4.7 reference resolution (`ref_loading.rs`) ----
    //
    // `unresolved_subsystem_ref` and `ambiguous_subsystem_ref` are the
    // canonical cross-binding names, pinned by
    // `tests/invalid/expected_errors.json` (`subsystem_ref_not_found.esm`,
    // `subsystem_ref_ambiguous.esm`).

    /// A subsystem `{ "ref": ... }` that does not resolve: a missing file, a
    /// remote URL, a cycle, or an unreadable/unparseable document.
    pub const UNRESOLVED_SUBSYSTEM_REF: &str = "unresolved_subsystem_ref";
    /// A subsystem ref that resolved to a file holding MORE (or fewer) than one
    /// top-level system; §4.7 requires exactly one, so which system to mount is
    /// ambiguous. Only the resolver can raise this — it is the only layer that
    /// reads the referenced file.
    pub const AMBIGUOUS_SUBSYSTEM_REF: &str = "ambiguous_subsystem_ref";
    /// A top-level `models.<k>` mount edge that does not resolve.
    pub const TOPLEVEL_MODEL_REF_UNRESOLVED: &str = "toplevel_model_ref_unresolved";
    /// A referenced subsystem file's top-level `index_sets` entry collides with
    /// a non-deep-equal declaration in the importing document (§4.7).
    pub const SUBSYSTEM_INDEX_SET_CONFLICT: &str = "subsystem_index_set_conflict";
    /// A `subsystem` ref pointing at a COUPLING library, which exports roles
    /// rather than a mountable system.
    pub const SUBSYSTEM_REF_IS_COUPLING_LIBRARY: &str = "subsystem_ref_is_coupling_library";
    /// A `subsystem` ref pointing at a TEMPLATE library, which exports
    /// templates rather than a mountable system.
    pub const SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY: &str = "subsystem_ref_is_template_library";

    // ---- template-library import MERGE collisions (`template_imports.rs`) ----

    /// Two imported template libraries export the same template name.
    pub const TEMPLATE_IMPORT_NAME_CONFLICT: &str = "template_import_name_conflict";
    /// Two imported template libraries export the same index-set name.
    pub const TEMPLATE_IMPORT_INDEX_SET_CONFLICT: &str = "template_import_index_set_conflict";

    // ---- structural validation: the `error_type` of a `StructuralError`
    // (`validate.rs`), pinned by `tests/invalid/expected_errors.json`. ----

    /// A `ranges[*]`/expression reference to an undeclared array index set.
    pub const ARRAY_SHAPE_MISMATCH: &str = "array_shape_mismatch";
    /// An equation graph that depends on itself.
    pub const CIRCULAR_DEPENDENCY: &str = "circular_dependency";
    /// A parameter `update` naming no declared data source.
    pub const DATA_SOURCE_UNDEFINED: &str = "data_source_undefined";
    /// A domain axis whose units disagree with the coordinate's.
    pub const DOMAIN_UNIT_MISMATCH: &str = "domain_unit_mismatch";
    /// A model whose equation count cannot match its unknown count.
    pub const EQUATION_COUNT_MISMATCH: &str = "equation_count_mismatch";
    /// An event `affect` writing a parameter rather than an unknown.
    pub const EVENT_AFFECTS_PARAMETER: &str = "event_affects_parameter";
    /// An event referring to a variable the model does not declare.
    pub const EVENT_VAR_UNDECLARED: &str = "event_var_undeclared";
    /// A coupling `factor` carrying an expression transform.
    pub const FACTOR_WITH_EXPRESSION_TRANSFORM: &str = "factor_with_expression_transform";
    /// An `ic` block inside a reaction system (§4.7).
    pub const IC_IN_REACTION_SYSTEM: &str = "ic_in_reaction_system";
    /// A `broadcast` node whose `fn` names no scalar operator.
    pub const INVALID_BROADCAST_FN: &str = "invalid_broadcast_fn";
    /// A `join.on` key of a type the join cannot compare.
    pub const JOIN_KEY_INVALID_TYPE: &str = "join_key_invalid_type";
    /// A null entry in a reaction list.
    pub const NULL_REACTION: &str = "null_reaction";
    /// An `operator` whose declared variable the model does not have.
    pub const OPERATOR_VARIABLE_MISSING: &str = "operator_variable_missing";
    /// A relational node in a continuous (ODE-position) expression.
    pub const RELATIONAL_NODE_IN_CONTINUOUS: &str = "relational_node_in_continuous";
    /// A provable dimensional inconsistency, promoted from a unit finding.
    pub const UNIT_INCONSISTENCY: &str = "unit_inconsistency";
    /// A declared unit string that denotes no real unit, promoted from a
    /// unit finding.
    pub const UNIT_PARSE_ERROR: &str = "unit_parse_error";
    /// A reference to an index set the document does not declare.
    pub const UNDEFINED_INDEX_SET: &str = "undefined_index_set";
    /// A reference to an operator the registry does not carry.
    pub const UNDEFINED_OPERATOR: &str = "undefined_operator";
    /// A reference to a parameter the component does not declare.
    pub const UNDEFINED_PARAMETER: &str = "undefined_parameter";
    /// A reference to a species the reaction system does not declare.
    pub const UNDEFINED_SPECIES: &str = "undefined_species";
    /// A coupling endpoint naming no declared component.
    pub const UNDEFINED_SYSTEM: &str = "undefined_system";
    /// A reference to a variable the component does not declare.
    pub const UNDEFINED_VARIABLE: &str = "undefined_variable";
    /// A scoped reference (`A.b`) that resolves to nothing.
    pub const UNRESOLVED_SCOPED_REF: &str = "unresolved_scoped_ref";

    // ---- unit FINDING kinds (`units.rs`): a second, smaller vocabulary
    // carried on `UnitWarning.code` rather than on a `StructuralError`. The
    // first two state a defect in the FILE, the third a limit of the ANALYSIS.
    // Shared verbatim with Go's `UnitFinding*` and TypeScript's
    // `UnitWarning['code']` union. ----

    /// A PROVABLE dimensional inconsistency.
    pub const DIMENSIONAL_MISMATCH: &str = "dimensional_mismatch";
    /// A declared unit string that does not denote a real unit.
    pub const UNPARSEABLE_UNIT: &str = "unparseable_unit";
    /// The checker cannot DETERMINE a dimension — not a defect in the file.
    pub const ANALYSIS: &str = "analysis";

    // ---- closed-function registry: esm-spec §9.1-§9.2
    // (`registered_functions.rs`, raised as `ClosedFunctionError`). ----

    /// A call to a function the closed registry does not carry.
    pub const UNKNOWN_CLOSED_FUNCTION: &str = "unknown_closed_function";
    /// A closed-function call at an arity the function does not accept.
    pub const CLOSED_FUNCTION_ARITY: &str = "closed_function_arity";
    /// A closed-function result that would overflow.
    pub const CLOSED_FUNCTION_OVERFLOW: &str = "closed_function_overflow";
    /// A closed-function argument of a kind the function does not accept.
    pub const CLOSED_FUNCTION_ARG_TYPE: &str = "closed_function_arg_type";
    /// A `searchsorted` table that is not monotonically non-decreasing.
    pub const SEARCHSORTED_NON_MONOTONIC: &str = "searchsorted_non_monotonic";
    /// A `searchsorted` table containing a NaN.
    pub const SEARCHSORTED_NAN_IN_TABLE: &str = "searchsorted_nan_in_table";
    /// An `interp` axis that is not strictly increasing.
    pub const INTERP_NON_MONOTONIC_AXIS: &str = "interp_non_monotonic_axis";
    /// An `interp` axis whose length does not match the table's.
    pub const INTERP_AXIS_LENGTH_MISMATCH: &str = "interp_axis_length_mismatch";
    /// An `interp` axis containing a NaN.
    pub const INTERP_NAN_IN_AXIS: &str = "interp_nan_in_axis";
    /// An `interp` axis with fewer than two points.
    pub const INTERP_AXIS_TOO_SHORT: &str = "interp_axis_too_short";
}

/// The [`codes`] registry in ENUMERABLE form: `(constant name, code string)`
/// for every diagnostic code this binding emits, sorted by name.
///
/// The Rust twin of Julia's `ERROR_CODES` `NamedTuple`
/// (`pkg/EarthSciAST.jl/src/error_codes.jl`), TypeScript's `ERROR_CODES`
/// object (`pkg/earthsci-ast-ts/src/errors.ts`), Python's `ErrorCode` enum and
/// Go's `codes.go`. The individual `pub const`s in [`codes`] are what raise
/// sites reference — that is the Rust-idiomatic form, and it is checked at
/// compile time. This table exists so the vocabulary can be *enumerated*:
/// diffed against a peer binding, or asserted over in a test.
///
/// **The code VALUES are a cross-binding contract and must never change.**
/// Every entry equals, byte for byte, a literal this crate already emitted.
/// Adding a diagnostic means adding a constant to [`codes`], adding it here,
/// AND coordinating the value across every binding.
///
/// By convention each name is the SCREAMING_SNAKE_CASE form of its value —
/// the same convention the TypeScript keys and the Python enum members follow.
/// `error_codes_are_well_formed` in this module enforces it.
pub const ERROR_CODES: &[(&str, &str)] = &[
    ("AMBIGUOUS_SUBSYSTEM_REF", codes::AMBIGUOUS_SUBSYSTEM_REF),
    ("ANALYSIS", codes::ANALYSIS),
    ("APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH", codes::APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH),
    ("APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION", codes::APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION),
    ("APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY", codes::APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY),
    ("APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE", codes::APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE),
    ("APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD", codes::APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD),
    ("ARRAY_SHAPE_MISMATCH", codes::ARRAY_SHAPE_MISMATCH),
    ("CIRCULAR_DEPENDENCY", codes::CIRCULAR_DEPENDENCY),
    ("CLOSED_FUNCTION_ARG_TYPE", codes::CLOSED_FUNCTION_ARG_TYPE),
    ("CLOSED_FUNCTION_ARITY", codes::CLOSED_FUNCTION_ARITY),
    ("CLOSED_FUNCTION_OVERFLOW", codes::CLOSED_FUNCTION_OVERFLOW),
    ("COUPLING_EDGE_UNKNOWN_ROLE", codes::COUPLING_EDGE_UNKNOWN_ROLE),
    ("COUPLING_IMPORT_BIND_NOT_A_COMPONENT", codes::COUPLING_IMPORT_BIND_NOT_A_COMPONENT),
    ("COUPLING_IMPORT_NOT_LIBRARY", codes::COUPLING_IMPORT_NOT_LIBRARY),
    ("COUPLING_IMPORT_ROLE_UNBOUND", codes::COUPLING_IMPORT_ROLE_UNBOUND),
    ("COUPLING_IMPORT_UNKNOWN_ROLE", codes::COUPLING_IMPORT_UNKNOWN_ROLE),
    ("COUPLING_IMPORT_UNRESOLVED", codes::COUPLING_IMPORT_UNRESOLVED),
    ("COUPLING_LIBRARY_ILLEGAL_PAYLOAD", codes::COUPLING_LIBRARY_ILLEGAL_PAYLOAD),
    ("COUPLING_LIBRARY_NESTED_IMPORT", codes::COUPLING_LIBRARY_NESTED_IMPORT),
    ("COUPLING_ROLE_UNUSED", codes::COUPLING_ROLE_UNUSED),
    ("DATA_SOURCE_UNDEFINED", codes::DATA_SOURCE_UNDEFINED),
    ("DIMENSIONAL_MISMATCH", codes::DIMENSIONAL_MISMATCH),
    ("DOMAIN_UNIT_MISMATCH", codes::DOMAIN_UNIT_MISMATCH),
    ("ENUM_INVALID_ARGS", codes::ENUM_INVALID_ARGS),
    ("ENUM_LOWERING_RESIDUAL", codes::ENUM_LOWERING_RESIDUAL),
    ("EQUATION_COUNT_MISMATCH", codes::EQUATION_COUNT_MISMATCH),
    ("EVENT_AFFECTS_PARAMETER", codes::EVENT_AFFECTS_PARAMETER),
    ("EVENT_VAR_UNDECLARED", codes::EVENT_VAR_UNDECLARED),
    ("FACTOR_WITH_EXPRESSION_TRANSFORM", codes::FACTOR_WITH_EXPRESSION_TRANSFORM),
    ("GEOMETRY_MANIFOLD_INVALID", codes::GEOMETRY_MANIFOLD_INVALID),
    ("IC_IN_REACTION_SYSTEM", codes::IC_IN_REACTION_SYSTEM),
    ("INTERP_AXIS_LENGTH_MISMATCH", codes::INTERP_AXIS_LENGTH_MISMATCH),
    ("INTERP_AXIS_TOO_SHORT", codes::INTERP_AXIS_TOO_SHORT),
    ("INTERP_NAN_IN_AXIS", codes::INTERP_NAN_IN_AXIS),
    ("INTERP_NON_MONOTONIC_AXIS", codes::INTERP_NON_MONOTONIC_AXIS),
    ("INVALID_BROADCAST_FN", codes::INVALID_BROADCAST_FN),
    ("INVALID_ENUMS_BLOCK", codes::INVALID_ENUMS_BLOCK),
    ("JOIN_KEY_INVALID_TYPE", codes::JOIN_KEY_INVALID_TYPE),
    ("MAKEARRAY_REGION_INVERTED", codes::MAKEARRAY_REGION_INVERTED),
    ("METAPARAMETER_NAME_CONFLICT", codes::METAPARAMETER_NAME_CONFLICT),
    ("METAPARAMETER_TYPE_ERROR", codes::METAPARAMETER_TYPE_ERROR),
    ("METAPARAMETER_UNBOUND", codes::METAPARAMETER_UNBOUND),
    ("NULL_REACTION", codes::NULL_REACTION),
    ("OPERATOR_VARIABLE_MISSING", codes::OPERATOR_VARIABLE_MISSING),
    ("RELATIONAL_NODE_IN_CONTINUOUS", codes::RELATIONAL_NODE_IN_CONTINUOUS),
    ("REWRITE_RULE_NONTERMINATING", codes::REWRITE_RULE_NONTERMINATING),
    ("SEARCHSORTED_NAN_IN_TABLE", codes::SEARCHSORTED_NAN_IN_TABLE),
    ("SEARCHSORTED_NON_MONOTONIC", codes::SEARCHSORTED_NON_MONOTONIC),
    ("SUBSYSTEM_INDEX_SET_CONFLICT", codes::SUBSYSTEM_INDEX_SET_CONFLICT),
    ("SUBSYSTEM_REF_IS_COUPLING_LIBRARY", codes::SUBSYSTEM_REF_IS_COUPLING_LIBRARY),
    ("SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY", codes::SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY),
    ("TEMPLATE_BODY_EXPANSION_TOO_DEEP", codes::TEMPLATE_BODY_EXPANSION_TOO_DEEP),
    ("TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET", codes::TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET),
    ("TEMPLATE_IMPORT_CYCLE", codes::TEMPLATE_IMPORT_CYCLE),
    ("TEMPLATE_IMPORT_INDEX_SET_CONFLICT", codes::TEMPLATE_IMPORT_INDEX_SET_CONFLICT),
    ("TEMPLATE_IMPORT_IS_COUPLING_LIBRARY", codes::TEMPLATE_IMPORT_IS_COUPLING_LIBRARY),
    ("TEMPLATE_IMPORT_NAME_CONFLICT", codes::TEMPLATE_IMPORT_NAME_CONFLICT),
    ("TEMPLATE_IMPORT_NOT_LIBRARY", codes::TEMPLATE_IMPORT_NOT_LIBRARY),
    ("TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME", codes::TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME),
    ("TEMPLATE_IMPORT_RENAME_COLLISION", codes::TEMPLATE_IMPORT_RENAME_COLLISION),
    ("TEMPLATE_IMPORT_RENAME_INVALID", codes::TEMPLATE_IMPORT_RENAME_INVALID),
    ("TEMPLATE_IMPORT_RENAME_UNKNOWN_NAME", codes::TEMPLATE_IMPORT_RENAME_UNKNOWN_NAME),
    ("TEMPLATE_IMPORT_UNKNOWN_NAME", codes::TEMPLATE_IMPORT_UNKNOWN_NAME),
    ("TEMPLATE_IMPORT_UNRESOLVED", codes::TEMPLATE_IMPORT_UNRESOLVED),
    ("TEMPLATE_IMPORT_VERSION_TOO_OLD", codes::TEMPLATE_IMPORT_VERSION_TOO_OLD),
    ("TEMPLATE_INJECT_TARGET_IS_LOADER", codes::TEMPLATE_INJECT_TARGET_IS_LOADER),
    ("TEMPLATE_INJECT_TARGET_NOT_COMPONENT", codes::TEMPLATE_INJECT_TARGET_NOT_COMPONENT),
    ("TEMPLATE_INJECT_TARGET_UNKNOWN", codes::TEMPLATE_INJECT_TARGET_UNKNOWN),
    ("TOPLEVEL_MODEL_REF_UNRESOLVED", codes::TOPLEVEL_MODEL_REF_UNRESOLVED),
    ("UNDEFINED_INDEX_SET", codes::UNDEFINED_INDEX_SET),
    ("UNDEFINED_OPERATOR", codes::UNDEFINED_OPERATOR),
    ("UNDEFINED_PARAMETER", codes::UNDEFINED_PARAMETER),
    ("UNDEFINED_SPECIES", codes::UNDEFINED_SPECIES),
    ("UNDEFINED_SYSTEM", codes::UNDEFINED_SYSTEM),
    ("UNDEFINED_VARIABLE", codes::UNDEFINED_VARIABLE),
    ("UNIT_INCONSISTENCY", codes::UNIT_INCONSISTENCY),
    ("UNIT_PARSE_ERROR", codes::UNIT_PARSE_ERROR),
    ("UNKNOWN_CLOSED_FUNCTION", codes::UNKNOWN_CLOSED_FUNCTION),
    ("UNKNOWN_ENUM", codes::UNKNOWN_ENUM),
    ("UNKNOWN_ENUM_SYMBOL", codes::UNKNOWN_ENUM_SYMBOL),
    ("UNPARSEABLE_UNIT", codes::UNPARSEABLE_UNIT),
    ("UNRESOLVED_SCOPED_REF", codes::UNRESOLVED_SCOPED_REF),
    ("UNRESOLVED_SUBSYSTEM_REF", codes::UNRESOLVED_SUBSYSTEM_REF),
];

/// Every diagnostic code string in [`ERROR_CODES`], sorted. Handy for
/// cross-binding vocabulary diffs and for asserting in a test that a raise
/// site uses a registered code. Mirrors Julia's `error_code_names()`.
pub fn error_code_names() -> Vec<&'static str> {
    let mut values: Vec<&'static str> = ERROR_CODES.iter().map(|(_, value)| *value).collect();
    values.sort_unstable();
    values
}

#[cfg(test)]
mod error_code_tests {
    use super::{ERROR_CODES, error_code_names};

    /// The registry invariants Julia's `error_hierarchy_test.jl` and
    /// TypeScript's `errors.test.ts` assert on their own registries: each name
    /// is the SCREAMING_SNAKE_CASE form of its value, and no value repeats.
    #[test]
    fn error_codes_are_well_formed() {
        for (name, value) in ERROR_CODES {
            assert_eq!(
                *name,
                value.to_uppercase(),
                "registry name {name} is not the SCREAMING_SNAKE form of {value}"
            );
            assert!(
                value
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'),
                "code {value} is not snake_case"
            );
        }
        let mut seen = error_code_names();
        let count = seen.len();
        seen.dedup();
        assert_eq!(count, seen.len(), "duplicate code value in ERROR_CODES");
    }

    /// The table must cover the whole `codes` module: a constant added there
    /// and forgotten here would be invisible to a vocabulary diff. Checked
    /// against the source text, which is the only place the two can diverge.
    #[test]
    fn error_codes_covers_every_constant() {
        let src = include_str!("diagnostic.rs");
        let declared: Vec<&str> = src
            .split("pub const ")
            .skip(1)
            .filter_map(|rest| rest.split(':').next())
            .filter(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_uppercase() || c == '_' || c.is_ascii_digit()))
            .filter(|n| *n != "ERROR_CODES")
            .collect();
        for name in declared {
            assert!(
                ERROR_CODES.iter().any(|(n, _)| *n == name),
                "codes::{name} is not listed in ERROR_CODES"
            );
        }
    }

    /// The structural-validation codes render off the registry, so the
    /// `StructuralError.error_type` wire values stay pinned to it.
    #[test]
    fn structural_error_codes_come_from_the_registry() {
        use crate::validate::StructuralErrorCode;
        assert_eq!(
            StructuralErrorCode::UndefinedVariable.to_string(),
            super::codes::UNDEFINED_VARIABLE
        );
        assert_eq!(
            StructuralErrorCode::ArrayShapeMismatch.to_string(),
            super::codes::ARRAY_SHAPE_MISMATCH
        );
    }
}

/// Parse a `major.minor.patch` version string into its numeric components.
/// Returns `None` for anything that is not exactly three dot-separated
/// non-negative integers. Shared by the load-time spec-version gates, the
/// migration module, and version-compatibility checking, so all agree on
/// what counts as a well-formed version token.
pub fn parse_semver(version: &str) -> Option<(u32, u32, u32)> {
    let mut parts = version.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((major, minor, patch))
}
