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

/// Generates the diagnostic-code registry's two public faces from ONE
/// declaration list: the [`codes`] module of per-code `pub const`s (the form
/// raise sites reference — Rust-idiomatic, and checked at compile time) and
/// the enumerable [`ERROR_CODES`] `(name, value)` table (the form tests and
/// cross-binding vocabulary diffs iterate). One declaration per code means the
/// two faces cannot drift apart.
macro_rules! diagnostic_code_registry {
    ($( $(#[$doc:meta])* $NAME:ident = $value:literal; )+) => {
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
        /// to the `diagnostic_code_registry!` list AND coordinating the value across
        /// every binding.
        ///
        /// Constant names are the SCREAMING_SNAKE_CASE form of the value (mirroring the
        /// TypeScript keys and the Python enum), so a reference reads as
        /// `codes::TEMPLATE_IMPORT_UNKNOWN_NAME`.
        ///
        /// Scope: every diagnostic code string this binding emits, whichever error
        /// type carries it — [`DiagnosticError`], `StructuralError`
        /// (`crate::validate::StructuralErrorCode::to_string` is defined off these
        /// constants), `ClosedFunctionError` and the `UnitWarning` finding kinds
        /// (`crate::units::UNIT_FINDING_*` are aliases of three of them). The one
        /// deliberate exclusion is the DAE lowering's Rust-local `E_*` names, which
        /// are not a cross-binding vocabulary — Julia excludes its `E_TREEWALK_*`
        /// names from `ERROR_CODES` for the same reason.
        ///
        /// [`ERROR_CODES`] is the enumerable form of this module, for tests and
        /// cross-binding vocabulary diffs; both are generated from the single
        /// `diagnostic_code_registry!` declaration list.
        pub mod codes {
            $( $(#[$doc])* pub const $NAME: &str = $value; )+
        }

        /// The [`codes`] registry in ENUMERABLE form: `(constant name, code string)`
        /// for every diagnostic code this binding emits, in declaration order
        /// (grouped by the pass that emits it, as the [`codes`] module is).
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
        /// Both this table and [`codes`] expand from the one
        /// `diagnostic_code_registry!` declaration list, so the table covers every
        /// constant by construction.
        ///
        /// By convention each name is the SCREAMING_SNAKE_CASE form of its value —
        /// the same convention the TypeScript keys and the Python enum members follow.
        /// `error_codes_are_well_formed` in this module enforces it.
        pub const ERROR_CODES: &[(&str, &str)] = &[
            $( (stringify!($NAME), codes::$NAME), )+
        ];
    };
}

diagnostic_code_registry! {
    // ---- expression templates: §9.6 lowering (`lower_expression_templates.rs`)
    //      ----

    /// An `apply_expression_template` whose supplied bindings do not match the
    /// template's declared parameter list (missing, extra, or duplicated).
    APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH = "apply_expression_template_bindings_mismatch";
    /// A malformed `expression_templates` declaration — the single most-emitted
    /// code in this pass, covering every shape violation of the template
    /// declaration itself.
    APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION = "apply_expression_template_invalid_declaration";
    /// A template body that (directly or transitively) applies itself.
    APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY = "apply_expression_template_recursive_body";
    /// An `apply_expression_template` naming a template the document does not
    /// declare (and no import supplies).
    APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE = "apply_expression_template_unknown_template";
    /// A template declaring a `min_spec_version` newer than this binding
    /// implements.
    APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD = "apply_expression_template_version_too_old";
    /// A rewrite rule whose repeated application does not reach a fixed point.
    REWRITE_RULE_NONTERMINATING = "rewrite_rule_nonterminating";
    /// Template body expansion exceeded the depth budget (a runaway, but not
    /// provably self-recursive, expansion).
    TEMPLATE_BODY_EXPANSION_TOO_DEEP = "template_body_expansion_too_deep";
    /// A template `constraints` entry naming an index set absent from the
    /// document's `index_sets` registry.
    TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET = "template_constraint_unknown_index_set";

    // ---- templates: geometry / makearray structural folds (also emitted from
    //      `lower_expression_templates.rs` during template lowering) ----

    /// A `geometry` manifold declaration that is not a well-formed manifold.
    GEOMETRY_MANIFOLD_INVALID = "geometry_manifold_invalid";
    /// A `makearray` region whose `hi` bound precedes its `lo` bound.
    MAKEARRAY_REGION_INVERTED = "makearray_region_inverted";

    // ---- template-library imports: §9.7 (`template_imports.rs`) ----

    /// An imported metaparameter name collides with a name already in scope.
    METAPARAMETER_NAME_CONFLICT = "metaparameter_name_conflict";
    /// A metaparameter bound to a value of the wrong type (or used where its
    /// declared type does not admit it).
    METAPARAMETER_TYPE_ERROR = "metaparameter_type_error";
    /// A metaparameter referenced by a template body with no binding in scope.
    METAPARAMETER_UNBOUND = "metaparameter_unbound";
    /// A cycle in the template-library import graph.
    TEMPLATE_IMPORT_CYCLE = "template_import_cycle";
    /// A `template_imports` entry resolving to a COUPLING library, which
    /// exports roles rather than templates.
    TEMPLATE_IMPORT_IS_COUPLING_LIBRARY = "template_import_is_coupling_library";
    /// A `template_imports` entry resolving to a document that is not a library
    /// at all.
    TEMPLATE_IMPORT_NOT_LIBRARY = "template_import_not_library";
    /// A `rebind` naming a metaparameter the imported library does not declare.
    TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME = "template_import_rebind_unknown_name";
    /// A `rename` whose target name is already taken in the importing scope.
    TEMPLATE_IMPORT_RENAME_COLLISION = "template_import_rename_collision";
    /// A `rename` whose target is not a syntactically valid name.
    TEMPLATE_IMPORT_RENAME_INVALID = "template_import_rename_invalid";
    /// A `rename` naming a source the imported library does not export.
    TEMPLATE_IMPORT_RENAME_UNKNOWN_NAME = "template_import_rename_unknown_name";
    /// An explicit import `names` entry the library does not export.
    TEMPLATE_IMPORT_UNKNOWN_NAME = "template_import_unknown_name";
    /// A `template_imports` `ref` that does not resolve (missing file, remote
    /// URL, unreadable or unparseable document).
    TEMPLATE_IMPORT_UNRESOLVED = "template_import_unresolved";
    /// An imported library declaring a `min_spec_version` newer than this
    /// binding implements.
    TEMPLATE_IMPORT_VERSION_TOO_OLD = "template_import_version_too_old";
    /// An `inject` whose target names a data LOADER rather than a component.
    TEMPLATE_INJECT_TARGET_IS_LOADER = "template_inject_target_is_loader";
    /// An `inject` whose target resolves to something that is not a component.
    TEMPLATE_INJECT_TARGET_NOT_COMPONENT = "template_inject_target_not_component";
    /// An `inject` whose target names nothing in the importing document.
    TEMPLATE_INJECT_TARGET_UNKNOWN = "template_inject_target_unknown";

    // ---- coupling libraries: §9.7 coupling-library imports
    //      (`coupling_imports.rs`) ----

    /// A coupling edge naming a role the library does not declare.
    COUPLING_EDGE_UNKNOWN_ROLE = "coupling_edge_unknown_role";
    /// A role `bind` target that is not a component.
    COUPLING_IMPORT_BIND_NOT_A_COMPONENT = "coupling_import_bind_not_a_component";
    /// A `coupling_imports` entry resolving to a document that is not a
    /// coupling library.
    COUPLING_IMPORT_NOT_LIBRARY = "coupling_import_not_library";
    /// A declared role left without a binding at the import site.
    COUPLING_IMPORT_ROLE_UNBOUND = "coupling_import_role_unbound";
    /// A `bind` naming a role the imported library does not declare.
    COUPLING_IMPORT_UNKNOWN_ROLE = "coupling_import_unknown_role";
    /// A `coupling_imports` `ref` that does not resolve.
    COUPLING_IMPORT_UNRESOLVED = "coupling_import_unresolved";
    /// A coupling library carrying payload a coupling library may not hold.
    COUPLING_LIBRARY_ILLEGAL_PAYLOAD = "coupling_library_illegal_payload";
    /// A coupling library that itself declares an import (nesting is not
    /// permitted).
    COUPLING_LIBRARY_NESTED_IMPORT = "coupling_library_nested_import";
    /// A declared role that no imported coupling edge ever uses.
    COUPLING_ROLE_UNUSED = "coupling_role_unused";

    // ---- enums: §9.3 load-time enum lowering (`lower_enums.rs`) ----

    /// An enum operator applied to an argument list its arity does not admit.
    ENUM_INVALID_ARGS = "enum_invalid_args";
    /// An enum construct survived lowering — nothing downstream can interpret
    /// it, so loading must fail rather than silently discard it.
    ENUM_LOWERING_RESIDUAL = "enum_lowering_residual";
    /// A malformed top-level `enums` block.
    INVALID_ENUMS_BLOCK = "invalid_enums_block";
    /// A reference to an enum the document does not declare.
    UNKNOWN_ENUM = "unknown_enum";
    /// A reference to a symbol the named enum does not declare.
    UNKNOWN_ENUM_SYMBOL = "unknown_enum_symbol";

    // ---- subsystem refs: §4.7 reference resolution (`ref_loading.rs`) ----
    //
    // `unresolved_subsystem_ref` and `ambiguous_subsystem_ref` are the
    // canonical cross-binding names, pinned by
    // `tests/invalid/expected_errors.json` (`subsystem_ref_not_found.esm`,
    // `subsystem_ref_ambiguous.esm`).

    /// A subsystem `{ "ref": ... }` that does not resolve: a missing file, a
    /// remote URL, a cycle, or an unreadable/unparseable document.
    UNRESOLVED_SUBSYSTEM_REF = "unresolved_subsystem_ref";
    /// A subsystem ref that resolved to a file holding MORE (or fewer) than one
    /// top-level system; §4.7 requires exactly one, so which system to mount is
    /// ambiguous. Only the resolver can raise this — it is the only layer that
    /// reads the referenced file.
    AMBIGUOUS_SUBSYSTEM_REF = "ambiguous_subsystem_ref";
    /// A top-level `models.<k>` mount edge that does not resolve.
    TOPLEVEL_MODEL_REF_UNRESOLVED = "toplevel_model_ref_unresolved";
    /// A referenced subsystem file's top-level `index_sets` entry collides with
    /// a non-deep-equal declaration in the importing document (§4.7).
    SUBSYSTEM_INDEX_SET_CONFLICT = "subsystem_index_set_conflict";
    /// A `subsystem` ref pointing at a COUPLING library, which exports roles
    /// rather than a mountable system.
    SUBSYSTEM_REF_IS_COUPLING_LIBRARY = "subsystem_ref_is_coupling_library";
    /// A `subsystem` ref pointing at a TEMPLATE library, which exports
    /// templates rather than a mountable system.
    SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY = "subsystem_ref_is_template_library";

    // ---- template-library import MERGE collisions (`template_imports.rs`) ----

    /// Two imported template libraries export the same template name.
    TEMPLATE_IMPORT_NAME_CONFLICT = "template_import_name_conflict";
    /// Two imported template libraries export the same index-set name.
    TEMPLATE_IMPORT_INDEX_SET_CONFLICT = "template_import_index_set_conflict";

    // ---- structural validation: the `error_type` of a `StructuralError`
    // (`validate.rs`), pinned by `tests/invalid/expected_errors.json`. ----

    /// A `ranges[*]`/expression reference to an undeclared array index set.
    ARRAY_SHAPE_MISMATCH = "array_shape_mismatch";
    /// An equation graph that depends on itself.
    CIRCULAR_DEPENDENCY = "circular_dependency";
    /// A parameter `update` naming no declared data source.
    DATA_SOURCE_UNDEFINED = "data_source_undefined";
    /// A `data_sources[*].source.url_template` (or `mirrors` entry) that
    /// cannot be resolved to a URL at load time (esm-spec §8.2.1): an
    /// unexpanded `${VAR}` — §8.2 does not expand environment variables
    /// into a source's location at all — or a resolved path carrying a `?`
    /// or `#`. The message names the offending data source and template.
    DATA_SOURCE_URL_UNRESOLVED = "data_source_url_unresolved";
    /// A domain axis whose units disagree with the coordinate's.
    DOMAIN_UNIT_MISMATCH = "domain_unit_mismatch";
    /// A model whose equation count cannot match its unknown count.
    EQUATION_COUNT_MISMATCH = "equation_count_mismatch";
    /// An event `affect` writing a parameter rather than an unknown.
    EVENT_AFFECTS_PARAMETER = "event_affects_parameter";
    /// An event referring to a variable the model does not declare.
    EVENT_VAR_UNDECLARED = "event_var_undeclared";
    /// A coupling `factor` carrying an expression transform.
    FACTOR_WITH_EXPRESSION_TRANSFORM = "factor_with_expression_transform";
    /// An `ic` block inside a reaction system (§4.7).
    IC_IN_REACTION_SYSTEM = "ic_in_reaction_system";
    /// A `broadcast` node whose `fn` names no scalar operator.
    INVALID_BROADCAST_FN = "invalid_broadcast_fn";
    /// A `join.on` key of a type the join cannot compare.
    JOIN_KEY_INVALID_TYPE = "join_key_invalid_type";
    /// A `join.on` key whose range symbol the document does not determine —
    /// its index set is drawn by more than one of the node's ranges and the
    /// clause names no `syms` (CONFORMANCE_SPEC §5.5.8).
    JOIN_SIDE_AMBIGUOUS = "join_side_ambiguous";
    /// A `join.syms` entry that is not a range symbol of the node.
    JOIN_SYMS_UNKNOWN_SYMBOL = "join_syms_unknown_symbol";
    /// A null entry in a reaction list.
    NULL_REACTION = "null_reaction";
    /// An `operator` whose declared variable the model does not have.
    OPERATOR_VARIABLE_MISSING = "operator_variable_missing";
    /// A causal self-read (esm-spec §4.3.1.1) that is not strictly earlier
    /// along exactly one axis.
    RECURRENCE_NOT_WELLFOUNDED = "recurrence_not_wellfounded";
    /// A causal self-read the runtime cannot restrict to one cell.
    RECURRENCE_UNSUPPORTED_FORM = "recurrence_unsupported_form";
    /// A relational node in a continuous (ODE-position) expression.
    RELATIONAL_NODE_IN_CONTINUOUS = "relational_node_in_continuous";
    /// An `aggregate` binder (a `ranges` key or an `output_idx` entry) spelled
    /// with a globally-scoped name — the document's independent variable
    /// (esm-spec §11.3) or the §6.4 `_var` placeholder — which every consumer
    /// resolves by name before the loop bindings, so the symbol would never
    /// address the loop it declares.
    RESERVED_INDEX_SYMBOL = "reserved_index_symbol";
    /// A provable dimensional inconsistency, promoted from a unit finding.
    UNIT_INCONSISTENCY = "unit_inconsistency";
    /// A declared unit string that denotes no real unit, promoted from a
    /// unit finding.
    UNIT_PARSE_ERROR = "unit_parse_error";
    /// A reference to an index set the document does not declare.
    UNDEFINED_INDEX_SET = "undefined_index_set";
    /// A reference to an operator the registry does not carry.
    UNDEFINED_OPERATOR = "undefined_operator";
    /// A reference to a parameter the component does not declare.
    UNDEFINED_PARAMETER = "undefined_parameter";
    /// A reference to a species the reaction system does not declare.
    UNDEFINED_SPECIES = "undefined_species";
    /// A coupling endpoint naming no declared component.
    UNDEFINED_SYSTEM = "undefined_system";
    /// A reference to a variable the component does not declare.
    UNDEFINED_VARIABLE = "undefined_variable";
    /// A scoped reference (`A.b`) that resolves to nothing.
    UNRESOLVED_SCOPED_REF = "unresolved_scoped_ref";

    // ---- unit FINDING kinds (`units.rs`): a second, smaller vocabulary
    // carried on `UnitWarning.code` rather than on a `StructuralError`. The
    // first two state a defect in the FILE, the third a limit of the ANALYSIS.
    // Shared verbatim with Go's `UnitFinding*` and TypeScript's
    // `UnitWarning['code']` union. ----

    /// A PROVABLE dimensional inconsistency.
    DIMENSIONAL_MISMATCH = "dimensional_mismatch";
    /// A declared unit string that does not denote a real unit.
    UNPARSEABLE_UNIT = "unparseable_unit";
    /// The checker cannot DETERMINE a dimension — not a defect in the file.
    ANALYSIS = "analysis";

    // ---- closed-function registry: esm-spec §9.1-§9.2
    // (`registered_functions.rs`, raised as `ClosedFunctionError`). ----

    /// A call to a function the closed registry does not carry.
    UNKNOWN_CLOSED_FUNCTION = "unknown_closed_function";
    /// A closed-function call at an arity the function does not accept.
    CLOSED_FUNCTION_ARITY = "closed_function_arity";
    /// A closed-function result that would overflow.
    CLOSED_FUNCTION_OVERFLOW = "closed_function_overflow";
    /// A closed-function argument of a kind the function does not accept.
    CLOSED_FUNCTION_ARG_TYPE = "closed_function_arg_type";
    /// A `searchsorted` table that is not monotonically non-decreasing.
    SEARCHSORTED_NON_MONOTONIC = "searchsorted_non_monotonic";
    /// A `searchsorted` table containing a NaN.
    SEARCHSORTED_NAN_IN_TABLE = "searchsorted_nan_in_table";
    /// An `interp` axis that is not strictly increasing.
    INTERP_NON_MONOTONIC_AXIS = "interp_non_monotonic_axis";
    /// An `interp` axis whose length does not match the table's.
    INTERP_AXIS_LENGTH_MISMATCH = "interp_axis_length_mismatch";
    /// An `interp` axis containing a NaN.
    INTERP_NAN_IN_AXIS = "interp_nan_in_axis";
    /// An `interp` axis with fewer than two points.
    INTERP_AXIS_TOO_SHORT = "interp_axis_too_short";
}

/// Every diagnostic code string in [`ERROR_CODES`], sorted. Handy for
/// cross-binding vocabulary diffs and for asserting in a test that a raise
/// site uses a registered code. Mirrors Julia's `error_code_names()`.
pub fn error_code_names() -> Vec<&'static str> {
    let mut values: Vec<&'static str> = ERROR_CODES.iter().map(|(_, value)| *value).collect();
    values.sort_unstable();
    values
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

    /// The full vocabulary, pinned value by value. The code strings are a
    /// cross-binding contract (`tests/invalid/expected_errors.json` and the
    /// peer bindings' registries match on them), so a registry edit that
    /// drops, renames, or retypes one must fail here rather than surface as a
    /// conformance break later.
    #[test]
    fn the_diagnostic_vocabulary_is_pinned() {
        let expected: Vec<&str> = vec![
            "ambiguous_subsystem_ref",
            "analysis",
            "apply_expression_template_bindings_mismatch",
            "apply_expression_template_invalid_declaration",
            "apply_expression_template_recursive_body",
            "apply_expression_template_unknown_template",
            "apply_expression_template_version_too_old",
            "array_shape_mismatch",
            "circular_dependency",
            "closed_function_arg_type",
            "closed_function_arity",
            "closed_function_overflow",
            "coupling_edge_unknown_role",
            "coupling_import_bind_not_a_component",
            "coupling_import_not_library",
            "coupling_import_role_unbound",
            "coupling_import_unknown_role",
            "coupling_import_unresolved",
            "coupling_library_illegal_payload",
            "coupling_library_nested_import",
            "coupling_role_unused",
            "data_source_undefined",
            "data_source_url_unresolved",
            "dimensional_mismatch",
            "domain_unit_mismatch",
            "enum_invalid_args",
            "enum_lowering_residual",
            "equation_count_mismatch",
            "event_affects_parameter",
            "event_var_undeclared",
            "factor_with_expression_transform",
            "geometry_manifold_invalid",
            "ic_in_reaction_system",
            "interp_axis_length_mismatch",
            "interp_axis_too_short",
            "interp_nan_in_axis",
            "interp_non_monotonic_axis",
            "invalid_broadcast_fn",
            "invalid_enums_block",
            "join_key_invalid_type",
            "join_side_ambiguous",
            "join_syms_unknown_symbol",
            "makearray_region_inverted",
            "metaparameter_name_conflict",
            "metaparameter_type_error",
            "metaparameter_unbound",
            "null_reaction",
            "operator_variable_missing",
            "recurrence_not_wellfounded",
            "recurrence_unsupported_form",
            "relational_node_in_continuous",
            "reserved_index_symbol",
            "rewrite_rule_nonterminating",
            "searchsorted_nan_in_table",
            "searchsorted_non_monotonic",
            "subsystem_index_set_conflict",
            "subsystem_ref_is_coupling_library",
            "subsystem_ref_is_template_library",
            "template_body_expansion_too_deep",
            "template_constraint_unknown_index_set",
            "template_import_cycle",
            "template_import_index_set_conflict",
            "template_import_is_coupling_library",
            "template_import_name_conflict",
            "template_import_not_library",
            "template_import_rebind_unknown_name",
            "template_import_rename_collision",
            "template_import_rename_invalid",
            "template_import_rename_unknown_name",
            "template_import_unknown_name",
            "template_import_unresolved",
            "template_import_version_too_old",
            "template_inject_target_is_loader",
            "template_inject_target_not_component",
            "template_inject_target_unknown",
            "toplevel_model_ref_unresolved",
            "undefined_index_set",
            "undefined_operator",
            "undefined_parameter",
            "undefined_species",
            "undefined_system",
            "undefined_variable",
            "unit_inconsistency",
            "unit_parse_error",
            "unknown_closed_function",
            "unknown_enum",
            "unknown_enum_symbol",
            "unparseable_unit",
            "unresolved_scoped_ref",
            "unresolved_subsystem_ref",
        ];
        assert_eq!(error_code_names(), expected);
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
