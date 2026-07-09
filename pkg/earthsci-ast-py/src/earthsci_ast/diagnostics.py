"""Stable machine-readable diagnostic codes for the ESM format.

These constants are CROSS-BINDING CONTRACT STRINGS: the same code values are
emitted by every language binding (Julia, TypeScript, Python, Rust, Go) and
are asserted verbatim by the shared conformance fixtures
(``tests/invalid/expected_errors.json`` and friends). The VALUES of these
constants must therefore NEVER change — renaming a constant is fine, changing
the string it holds is a cross-language breaking change requiring a spec rev.

This is a leaf module: it imports nothing from the package so any module
(including :mod:`earthsci_ast.parse` and the template machinery) can use
it without creating import cycles.
"""

# ---------------------------------------------------------------------------
# Expression-template codes (esm-spec §9.6 / §9.6.6), raised as
# ``ExpressionTemplateError`` from ``lower_expression_templates.py``.
# ---------------------------------------------------------------------------

from __future__ import annotations

APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION = "apply_expression_template_invalid_declaration"
APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE = "apply_expression_template_unknown_template"
APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH = "apply_expression_template_bindings_mismatch"
APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY = "apply_expression_template_recursive_body"
APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD = "apply_expression_template_version_too_old"
REWRITE_RULE_NONTERMINATING = "rewrite_rule_nonterminating"
TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET = "template_constraint_unknown_index_set"
GEOMETRY_MANIFOLD_INVALID = "geometry_manifold_invalid"
MAKEARRAY_REGION_INVERTED = "makearray_region_inverted"

# ---------------------------------------------------------------------------
# Template-library import / metaparameter codes (esm-spec §9.7), raised as
# ``ExpressionTemplateError`` from ``template_imports.py`` (and
# ``subsystem_ref_is_template_library`` from ``parse.py``).
# ---------------------------------------------------------------------------

TEMPLATE_IMPORT_VERSION_TOO_OLD = "template_import_version_too_old"
TEMPLATE_IMPORT_UNRESOLVED = "template_import_unresolved"
TEMPLATE_IMPORT_NOT_LIBRARY = "template_import_not_library"
SUBSYSTEM_REF_IS_TEMPLATE_LIBRARY = "subsystem_ref_is_template_library"
TEMPLATE_IMPORT_CYCLE = "template_import_cycle"
TEMPLATE_IMPORT_NAME_CONFLICT = "template_import_name_conflict"
TEMPLATE_IMPORT_UNKNOWN_NAME = "template_import_unknown_name"
TEMPLATE_IMPORT_INDEX_SET_CONFLICT = "template_import_index_set_conflict"
TEMPLATE_BODY_EXPANSION_TOO_DEEP = "template_body_expansion_too_deep"
METAPARAMETER_UNBOUND = "metaparameter_unbound"
METAPARAMETER_TYPE_ERROR = "metaparameter_type_error"
METAPARAMETER_NAME_CONFLICT = "metaparameter_name_conflict"

# Import-renaming codes (esm-spec §9.7.7).
TEMPLATE_IMPORT_RENAME_UNKNOWN_NAME = "template_import_rename_unknown_name"
TEMPLATE_IMPORT_REBIND_UNKNOWN_NAME = "template_import_rebind_unknown_name"
TEMPLATE_IMPORT_RENAME_COLLISION = "template_import_rename_collision"
TEMPLATE_IMPORT_RENAME_INVALID = "template_import_rename_invalid"

# Scope-injection codes (esm-spec §9.7.10).
TEMPLATE_INJECT_TARGET_UNKNOWN = "template_inject_target_unknown"
TEMPLATE_INJECT_TARGET_NOT_COMPONENT = "template_inject_target_not_component"
TEMPLATE_INJECT_TARGET_IS_LOADER = "template_inject_target_is_loader"

# ---------------------------------------------------------------------------
# Closed function registry codes (esm-spec §9.1–§9.3), raised as
# ``ClosedFunctionError`` (or ``ValueError`` for the enum codes) from
# ``registered_functions.py``.
# ---------------------------------------------------------------------------

UNKNOWN_CLOSED_FUNCTION = "unknown_closed_function"
CLOSED_FUNCTION_ARITY = "closed_function_arity"
CLOSED_FUNCTION_OVERFLOW = "closed_function_overflow"
SEARCHSORTED_NON_MONOTONIC = "searchsorted_non_monotonic"
SEARCHSORTED_NAN_IN_TABLE = "searchsorted_nan_in_table"
INTERP_NON_MONOTONIC_AXIS = "interp_non_monotonic_axis"
INTERP_AXIS_LENGTH_MISMATCH = "interp_axis_length_mismatch"
INTERP_NAN_IN_AXIS = "interp_nan_in_axis"
INTERP_AXIS_TOO_SHORT = "interp_axis_too_short"
UNKNOWN_ENUM = "unknown_enum"
UNKNOWN_ENUM_SYMBOL = "unknown_enum_symbol"
