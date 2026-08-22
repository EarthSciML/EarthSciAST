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
/// Scope: this is the registry for [`DiagnosticError`] codes only. The
/// *structural* validation codes are a separate, already-centralized registry
/// (`StructuralErrorCode` in `crate::validate`), and `ClosedFunctionError` /
/// the DAE lowering carry their own `code: String` names.
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
