"""THE single registry of stable, machine-readable diagnostic codes for the
ESM format.

Single source of truth
----------------------
Every stable diagnostic-code string in the Python binding is defined here, in
one of two co-located representations (see "Why two representations coexist"
below). A maintainer adding or auditing a code therefore has exactly ONE place
to look -- this module:

* :class:`ErrorCode` -- an ``Enum`` of the *validation* codes emitted by the
  dataclass-level validator (:mod:`earthsci_ast.validation`) as coded
  ``ValidationError`` records.
* module-level ``str`` constants -- the *template*, *coupling*,
  *metaparameter*, *geometry*, and *closed-function* code families raised as
  ``ExpressionTemplateError`` / ``ClosedFunctionError`` during load-time
  lowering, where the code travels as a bare ``code=`` string.

These ``str`` constants are *defined* here and imported directly by their
consumers (``from earthsci_ast.error_handling import <CODE>``).

Cross-binding contract
----------------------
The VALUES of every code below are CROSS-BINDING CONTRACT STRINGS: the same
values are emitted by every language binding (Julia, TypeScript, Python, Rust,
Go) and are asserted verbatim by the shared conformance fixtures
(``tests/invalid/expected_errors.json`` and friends). Renaming a Python symbol
is safe; changing the string it holds is a cross-language breaking change
requiring a spec rev. Never change a value.

Why two representations coexist
-------------------------------
The two forms are a deliberate, load-bearing distinction, not an accident:

* ``ErrorCode`` members are emitted as coded ``ValidationError`` records by the
  validator, so an ``Enum`` gives them identity, ``repr`` and exhaustiveness for
  the validator path.
* The template / coupling / closed-function codes are attached as bare
  ``code=`` strings on ``ExpressionTemplateError`` (the cross-binding raise
  path), where consumers pass the constant directly -- e.g.
  ``code=TEMPLATE_IMPORT_UNRESOLVED`` -- so bare ``str`` constants avoid a
  ``.value`` unwrap at every raise site and keep the five importer modules
  (``lower_expression_templates``, ``coupling_imports``,
  ``registered_functions``, ``template_imports``, ``parse``) unchanged.

Import-cycle safety
-------------------
This module imports only the standard library, so it is a true leaf: any module
(including :mod:`earthsci_ast.parse` and the template machinery) can import it
without creating an import cycle.
"""

from __future__ import annotations

from enum import Enum

# ===========================================================================
# Validation codes
# ---------------------------------------------------------------------------
# Emitted by the dataclass-level validator (:mod:`earthsci_ast.validation`) as
# coded ``ValidationError`` records. Modelled as an ``Enum`` so they carry
# identity/repr through the validator path.
# ===========================================================================


class ErrorCode(Enum):
    """Error codes for ESM validation.

    The values are stable machine-readable diagnostic strings shared across
    the language bindings: they are part of the cross-binding contract and must
    never change. The template / coupling / closed-function code families live
    alongside this enum as module-level ``str`` constants (see the module
    docstring for why the two representations coexist).
    """

    SCHEMA_VALIDATION_ERROR = "schema_validation_error"
    EQUATION_COUNT_MISMATCH = "equation_count_mismatch"
    UNDEFINED_VARIABLE = "undefined_variable"
    UNDEFINED_SPECIES = "undefined_species"
    UNDEFINED_PARAMETER = "undefined_parameter"
    UNDEFINED_SYSTEM = "undefined_system"
    UNRESOLVED_SCOPED_REF = "unresolved_scoped_ref"
    UNDEFINED_OPERATOR = "undefined_operator"
    INVALID_DISCRETE_PARAM = "invalid_discrete_param"
    NULL_REACTION = "null_reaction"
    MISSING_OBSERVED_EXPR = "missing_observed_expr"
    EVENT_VAR_UNDECLARED = "event_var_undeclared"
    MISSING_REQUIRED_FIELD = "missing_required_field"
    UNIT_MISMATCH = "unit_mismatch"
    # Codes emitted by earthsci_ast.validation (previously ad-hoc string
    # literals at the raise sites; the enum is the single source of truth).
    UNDECLARED_SPECIES = "undeclared_species"
    INVALID_STOICHIOMETRY_TYPE = "invalid_stoichiometry_type"
    INVALID_STOICHIOMETRY = "invalid_stoichiometry"
    NEGATIVE_STOICHIOMETRY = "negative_stoichiometry"
    IC_IN_REACTION_SYSTEM = "ic_in_reaction_system"
    UNDECLARED_PARAMETER = "undeclared_parameter"
    UNDECLARED_RATE_VARIABLE = "undeclared_rate_variable"
    INVALID_RATE_EXPRESSION = "invalid_rate_expression"
    # The two unit findings are DISTINCT (esm-spec §4.8.4): `unit_parse_error` is
    # an unreadable/unreal unit STRING, `unit_inconsistency` is a provable
    # DIMENSIONAL mismatch between strings that both parse. One tells the author
    # to fix a spelling, the other to fix the physics.
    UNIT_PARSE_ERROR = "unit_parse_error"
    UNIT_INCONSISTENCY = "unit_inconsistency"
    # §4.7.6: a variable_map identity coupling between two variables whose
    # declared units are both present and DIFFERENT (statically decidable from a
    # single document; mirrors flatten's DomainUnitMismatchError into validate()).
    DOMAIN_UNIT_MISMATCH = "domain_unit_mismatch"
    UNDECLARED_READ_PARAMETER = "undeclared_read_parameter"
    UNDECLARED_MODIFIED_PARAMETER = "undeclared_modified_parameter"
    # Phase markers used when load()/validate() fails wholesale.
    SCHEMA = "schema"
    PARSE = "parse"
    VALIDATION_ERROR = "validation_error"


# ===========================================================================
# Expression-template codes (esm-spec §9.6 / §9.6.6), raised as
# ``ExpressionTemplateError`` from ``lower_expression_templates.py``.
# ===========================================================================

APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION = "apply_expression_template_invalid_declaration"
APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE = "apply_expression_template_unknown_template"
APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH = "apply_expression_template_bindings_mismatch"
APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY = "apply_expression_template_recursive_body"
APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD = "apply_expression_template_version_too_old"
REWRITE_RULE_NONTERMINATING = "rewrite_rule_nonterminating"
TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET = "template_constraint_unknown_index_set"
GEOMETRY_MANIFOLD_INVALID = "geometry_manifold_invalid"
MAKEARRAY_REGION_INVERTED = "makearray_region_inverted"

# ===========================================================================
# Template-library import / metaparameter codes (esm-spec §9.7), raised as
# ``ExpressionTemplateError`` from ``template_imports.py`` (and
# ``subsystem_ref_is_template_library`` from ``parse.py``).
# ===========================================================================

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

# ===========================================================================
# Coupling-library / coupling_import role-binding codes (esm-spec §10.9–§10.11;
# RFC docs/content/rfcs/coupling-libraries-role-binding.md §8). Named for parity
# with the §9.7 template-import codes. Raised as ``ExpressionTemplateError`` from
# ``coupling_imports.py`` (the expansion codes), ``parse.py``
# (``subsystem_ref_is_coupling_library``), and ``template_imports.py``
# (``template_import_is_coupling_library``).
# ===========================================================================

COUPLING_IMPORT_UNRESOLVED = "coupling_import_unresolved"
COUPLING_IMPORT_NOT_LIBRARY = "coupling_import_not_library"
SUBSYSTEM_REF_IS_COUPLING_LIBRARY = "subsystem_ref_is_coupling_library"
TEMPLATE_IMPORT_IS_COUPLING_LIBRARY = "template_import_is_coupling_library"
COUPLING_LIBRARY_ILLEGAL_PAYLOAD = "coupling_library_illegal_payload"
COUPLING_LIBRARY_NESTED_IMPORT = "coupling_library_nested_import"
COUPLING_EDGE_UNKNOWN_ROLE = "coupling_edge_unknown_role"
COUPLING_ROLE_UNUSED = "coupling_role_unused"
COUPLING_IMPORT_UNKNOWN_ROLE = "coupling_import_unknown_role"
COUPLING_IMPORT_ROLE_UNBOUND = "coupling_import_role_unbound"
COUPLING_IMPORT_BIND_NOT_A_COMPONENT = "coupling_import_bind_not_a_component"

# ===========================================================================
# Closed function registry codes (esm-spec §9.1–§9.3), raised as
# ``ClosedFunctionError`` (or ``ValueError`` for the enum codes) from
# ``registered_functions.py``.
# ===========================================================================

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
