"""
Layer 2 of 2: dataclass-level semantic validation.

This module provides a standardized validation interface for cross-language
conformance testing, returning structured validation results.

Layer boundary (what lives where):

* THIS module runs on a PARSED :class:`~earthsci_ast.esm_types.EsmFile`
  (dataclasses), AFTER ``load()`` has already succeeded. It is invoked
  explicitly through :func:`validate` (``load()`` does NOT call it), and it
  COLLECTS problems as structured records rather than raising: semantic errors
  become :class:`~earthsci_ast.error_handling.ErrorCode`-coded
  ``ValidationError`` entries and unit problems become ``UnitWarning`` entries,
  all returned in a :class:`ValidationResult`. It owns the *semantic* rules:
  equation-unknown balance (:func:`_validate_equation_balance_enhanced`),
  reaction consistency (:func:`_validate_reaction_consistency`), reaction
  rate dimensions, reaction-system ``ic`` rejection, event consistency, and
  unit warnings. New semantic rules belong HERE, in the coded channel.

* :mod:`earthsci_ast.structural_checks` is Layer 1: raw-``dict`` structural
  validation that ``load()`` runs BEFORE parsing to dataclasses. It is a
  load-time gate that RAISES
  :class:`~earthsci_ast.structural_checks.StructuralValidationError` (a
  ``SchemaValidationError`` subclass) collapsing its findings into a prose
  blob (also exposed structurally on ``.findings``). Rules that need only the
  raw document shape belong there. See that module's docstring for the
  reciprocal note. A few rules historically existed in both layers; where a
  semantic rule is owned here, the raw-dict twin over there carries a
  cross-reference back to this module.
"""

from __future__ import annotations

import math
import traceback
from dataclasses import dataclass
from typing import Any

from jsonschema import ValidationError as JsonSchemaValidationError

from .error_handling import ErrorCode
from .esm_types import EsmFile
from .parse import SchemaValidationError, SubsystemRefError, load


@dataclass
class ValidationError:
    """Represents a single validation error."""

    path: str
    message: str
    code: str = ""
    details: dict[str, Any] = None

    def __post_init__(self):
        if self.details is None:
            self.details = {}


@dataclass
class UnitWarning:
    """Represents a unit validation warning."""

    path: str
    message: str
    lhs_units: str = ""
    rhs_units: str = ""
    details: dict[str, Any] = None

    def __post_init__(self):
        if self.details is None:
            self.details = {}


@dataclass
class ValidationResult:
    """Represents the result of validation."""

    is_valid: bool
    schema_errors: list[ValidationError]
    structural_errors: list[ValidationError]
    unit_warnings: list[UnitWarning] = None

    def __post_init__(self):
        if self.unit_warnings is None:
            self.unit_warnings = []


def _json_pointer(parts) -> str:
    """Build an RFC-6901 JSON Pointer from a sequence of object keys / array
    indices. The document root is the empty string ``""`` (NOT ``$``), and each
    reference token escapes ``~`` -> ``~0`` and ``/`` -> ``~1`` per the RFC. This
    is the cross-language wire form the conformance comparator matches on
    (CONFORMANCE_SPEC §7.1.2)."""
    tokens = [str(p).replace("~", "~0").replace("/", "~1") for p in parts]
    return "/" + "/".join(tokens) if tokens else ""


def _flatten_schema_errors(errors):
    """Yield every violation in an ``iter_errors`` tree, descending into the
    ``.context`` of combinator errors (``oneOf`` / ``anyOf`` / ``not``).

    A schema that discriminates a node's shape with ``oneOf``/``anyOf`` reports,
    at the top level, only the combinator failure at the PARENT node — the leaf
    keyword that actually failed (``required``/``type``/``enum``/``minItems`` at
    its own deep JSON Pointer) is stashed in ``.context``. AJV — the
    cross-language reference — surfaces those leaves directly, so we descend and
    emit them too. jsonschema gives each context sub-error a fully-qualified
    ``absolute_path``, so no path stitching is needed. Both the combinator node
    and its descendants are yielded; the required-subset contract permits the
    extra records (CONFORMANCE_SPEC §7.1.2)."""
    for err in errors:
        yield err
        if err.context:
            yield from _flatten_schema_errors(err.context)


def _convert_jsonschema_error(error: JsonSchemaValidationError) -> ValidationError:
    """Convert a jsonschema ValidationError to our ValidationError format.

    ``path`` is an RFC-6901 JSON Pointer to the offending node with the document
    root spelled as ``""`` (see :func:`_json_pointer`). ``code`` carries the
    failing JSON-Schema keyword (``error.validator`` — ``required``, ``type``,
    ``enum``, ``pattern``, ``additionalProperties``, …), which the conformance
    producer reads through verbatim as the ``keyword`` field.
    """
    return ValidationError(
        path=_json_pointer(error.absolute_path),
        message=error.message,
        code=error.validator or "",
        details={
            "validator": error.validator,
            "validator_value": error.validator_value,
            "schema_path": list(error.schema_path),
            "instance": error.instance,
        },
    )


def validate(esm_file, *, base_path: str | None = None) -> ValidationResult:
    """
    Validate an ESM file against schema, structural, and unit requirements.

    This function implements comprehensive validation including:
    1. Equation-unknown balance
    2. Reference integrity (variable refs, scoped refs, discrete_parameters, coupling refs, operator refs)
    3. Reaction consistency (species declared, positive stoichiometries, no null-null, rate refs)
    4. Event consistency (condition types, affect vars, functional affect refs)

    Args:
        esm_file: The EsmFile object, JSON string, or dict to validate
        base_path: Directory that relative ``{"ref": ...}`` subsystem/model mounts
            (§4.7) and ``expression_template_imports`` (§9.7.2) resolve against.

            Validating a document that mounts another file is only meaningful if
            the mount target can be OPENED: whether a ref resolves — and whether
            the index sets it merges in conflict — is not decidable from the
            document's own bytes. When the caller passes the JSON *content* (as a
            conformance harness does, holding the fixture text rather than its
            path), there is nothing to anchor a relative ref to, and every
            subsystem-ref and template-import fixture becomes unsatisfiable.
            Passing the fixture's directory here makes those pins reachable: a
            MISSING target yields ``unresolved_subsystem_ref`` (or the
            template-import equivalent) at the mount's pointer, and a PRESENT one
            validates through.

            Omitted, behaviour is unchanged: relative refs are resolved against
            the process CWD, so an unopenable target is still reported as an
            unresolved ref — never silently accepted. Passing a *file path* as
            ``esm_file`` needs no ``base_path``; the file's own directory anchors
            it.

    Returns:
        ValidationResult containing schema_errors, structural_errors, unit_warnings, and is_valid flag
    """
    # Handle JSON string or dict input by parsing first
    if isinstance(esm_file, (str, dict)):
        try:
            esm_file = load(esm_file, base_path=base_path)
        except SchemaValidationError as e:
            # A STRUCTURAL failure (StructuralValidationError subclasses
            # SchemaValidationError) carries machine-readable records — a stable
            # diagnostic `code` and a JSON-Pointer `path` each. Re-emit those as
            # structured structural_errors instead of collapsing them into one
            # opaque `$` prose blob filed under schema_errors: the shared
            # contract in tests/invalid/expected_errors.json pins these fixtures
            # as `"schema_errors": []` plus a coded structural error at a
            # specific path (e.g. `unit_inconsistency` @
            # `/models/BadUnitsModel/equations/0`).
            records = getattr(e, "records", None)
            if records:
                return ValidationResult(
                    is_valid=False,
                    schema_errors=[],
                    structural_errors=[
                        ValidationError(
                            path=r.get("path", ""),
                            message=r.get("message", ""),
                            code=r.get("code", ""),
                            details=r.get("details", {}),
                        )
                        for r in records
                    ],
                )
            # A jsonschema failure now arrives with the FULL list of per-node
            # violations attached (parse.load collects them via iter_errors).
            # Emit one structured schema_error each — a JSON-Pointer path + the
            # failing keyword — instead of collapsing them into a single opaque
            # blob at the document root (CONFORMANCE_SPEC §7.1.2).
            js_errors = getattr(e, "schema_errors", None)
            if js_errors:
                seen: set[tuple[str, str]] = set()
                converted: list[ValidationError] = []
                for je in _flatten_schema_errors(js_errors):
                    ve = _convert_jsonschema_error(je)
                    # Dedup on the exact (keyword, path) the comparator matches
                    # on, so a combinator that fans out to the same leaf across
                    # branches contributes one record, not many.
                    key = (ve.code, ve.path)
                    if key in seen:
                        continue
                    seen.add(key)
                    converted.append(ve)
                # Stable output: `iter_errors` order is not guaranteed, so sort
                # by the (path, keyword) the comparator matches on.
                converted.sort(key=lambda ve: (ve.path, ve.code))
                return ValidationResult(
                    is_valid=False,
                    schema_errors=converted,
                    structural_errors=[],
                )
            return ValidationResult(
                is_valid=False,
                schema_errors=[
                    ValidationError(path="", message=str(e), code=ErrorCode.SCHEMA.value)
                ],
                structural_errors=[],
            )
        except SubsystemRefError as e:
            # A §4.7 mount that does not resolve is a STRUCTURAL defect at the
            # pointer of the mount, not a parse failure of the document as a
            # whole: `unresolved_subsystem_ref` / `ambiguous_subsystem_ref` at
            # `/models/<M>/subsystems/<name>` (tests/invalid/expected_errors.json
            # pins these fixtures as `"schema_errors": []`).
            return ValidationResult(
                is_valid=False,
                schema_errors=[],
                structural_errors=[
                    ValidationError(
                        path=getattr(e, "path", "") or "",
                        message=str(e),
                        code=getattr(e, "code", "") or ErrorCode.PARSE.value,
                        details=getattr(e, "details", None) or {},
                    )
                ],
            )
        except Exception as e:
            return ValidationResult(
                is_valid=False,
                schema_errors=[
                    ValidationError(path="", message=str(e), code=ErrorCode.PARSE.value)
                ],
                structural_errors=[],
            )

    schema_errors = []
    structural_errors = []
    unit_warnings = []

    try:
        # Schema validation is assumed to have been done during parsing
        # Focus on structural validation

        # 0. Check that at least one of models or reaction_systems is present
        _validate_content_presence(esm_file, structural_errors)

        # 1. Equation-Unknown Balance validation
        _validate_equation_balance_enhanced(esm_file, structural_errors)

        # 2. Reaction Consistency validation
        _validate_reaction_consistency(esm_file, structural_errors)

        # 3b. Reaction rate/stoichiometry dimensional check (mass-action contract)
        _validate_reaction_rate_dimensions(esm_file, structural_errors)

        # 3c. Reject `ic`-op equations inside a reaction system's
        # constraint_equations (spec §11.4.1).
        _validate_reaction_system_ics(esm_file, structural_errors)

        # 4. Event Consistency validation
        _validate_event_consistency(esm_file, structural_errors)

        # 4a. Domain-unit mismatch on identity variable_map couplings (§4.7.6) —
        # the same defect flatten's `_check_variable_map_units` raises, decided
        # statically from this one document and mirrored into validate().
        _validate_coupling_units(esm_file, structural_errors)

        # 4b. An observed variable's DECLARED units must equal the dimension its
        # expression computes (esm-spec §4.8.4) — a HARD error, not a warning.
        _validate_observed_dimensions(esm_file, structural_errors)

        # 5. Unit validation (warnings only)
        _validate_units(esm_file, unit_warnings)

    except Exception as e:
        # Catch-all for unexpected errors
        structural_errors.append(
            ValidationError(
                path="",
                message=f"Validation failed with unexpected error: {str(e)}",
                code=ErrorCode.VALIDATION_ERROR.value,
                details={"exception_type": type(e).__name__, "traceback": traceback.format_exc()},
            )
        )

    is_valid = len(schema_errors) == 0 and len(structural_errors) == 0

    return ValidationResult(
        is_valid=is_valid,
        schema_errors=schema_errors,
        structural_errors=structural_errors,
        unit_warnings=unit_warnings,
    )


def _validate_content_presence(
    esm_file: EsmFile, structural_errors: list[ValidationError]
) -> None:
    """
    Validate that at least one of models, reaction_systems, or data_loaders is
    present and non-empty.

    This ensures that the ESM file contains actual computational content rather than
    being empty or containing only metadata. A loader-only file (sole component
    `data_loaders`) is valid — it is referenceable as a loader subsystem
    (RFC pure-io-data-loaders §4.4 / esm-spec §4.7).

    A TEMPLATE-LIBRARY file (esm-spec §9.7.1) is likewise valid with no component
    at all: it carries only `expression_templates` and exists to be IMPORTED. It
    is empty by DESIGN, not by mistake. The registry is a top-level DECLARATION
    that survives load (§9.6.4 rule 5), so it is checked directly; without it a
    library validated standalone looked like an empty document and was rejected
    (`template_import_lib.esm`, `template_import_rename_lib.esm` — both pinned
    VALID).
    """
    has_models = bool(esm_file.models)
    has_reaction_systems = bool(esm_file.reaction_systems)
    has_data_loaders = bool(esm_file.data_loaders)
    is_library = bool(getattr(esm_file, "expression_templates", None))

    if not has_models and not has_reaction_systems and not has_data_loaders and not is_library:
        structural_errors.append(
            ValidationError(
                path="",
                message="ESM file must contain at least one model, reaction system, or data loader. Empty files are not valid.",
                code=ErrorCode.MISSING_REQUIRED_FIELD.value,
                details={
                    "models_count": len(esm_file.models) if esm_file.models else 0,
                    "reaction_systems_count": len(esm_file.reaction_systems)
                    if esm_file.reaction_systems
                    else 0,
                    "data_loaders_count": len(esm_file.data_loaders)
                    if esm_file.data_loaders
                    else 0,
                    "fix_suggestions": [
                        "Add a model with variables and equations",
                        "Add a reaction system with species and reactions",
                        "Add a data loader",
                        "Import content from existing ESM files",
                    ],
                },
            )
        )


def _is_initial_condition_equation(equation) -> bool:
    """True if an equation's LHS is an ``ic`` node (an initial-condition spec).

    An ``ic`` equation (``{op:"ic", args:[state]}`` = value) pins a state's
    starting value; it is NOT a governing equation that determines an unknown, so
    it must be excluded from the equation-unknown balance count. A model may
    therefore carry one governing ``D``/algebraic equation per state PLUS any
    number of ``ic`` equations (e.g. a second-order system supplying ICs for both
    the value and its derivative) without tripping the balance check.
    """
    lhs = getattr(equation, "lhs", None)
    return getattr(lhs, "op", None) == "ic"


def _is_operator_style(model) -> bool:
    """True if the model is an OPERATOR (spec §6.4) — its equations are written
    against the reserved ``_var`` placeholder rather than against locally
    declared states.

    An operator is a rewrite rule applied to *another* system's states, so it
    balances no equations of its own: `Transport` carries one `D(_var) = ...`
    equation and zero state variables. Counting its equations against its
    (empty) state list is meaningless and reports a spurious imbalance.
    """
    from .expression import free_variables

    for eq in model.equations:
        for side in (getattr(eq, "lhs", None), getattr(eq, "rhs", None)):
            if side is not None and "_var" in free_variables(side):
                return True
    return False


def _validate_equation_balance_enhanced(
    esm_file: EsmFile, structural_errors: list[ValidationError]
) -> None:
    """Enhanced equation-unknown balance validation with detailed suggestions.

    Equation balance is a property of a system solved on its OWN. It is skipped
    for two shapes that are balanced only after composition, matching the Go
    reference (which reaches 82/82 on the valid corpus):

    * a COUPLED document — a model's states may be driven by equations
      contributed at the coupling edge, so the model's own equation count is not
      the whole story;
    * an OPERATOR-style model (§6.4) — see :func:`_is_operator_style`.

    Counting either against its locally declared states produced a false
    ``equation_count_mismatch`` on 8 valid fixtures.
    """
    is_coupled = bool(getattr(esm_file, "coupling", None))
    for _i, model in enumerate(esm_file.models.values()):
        if is_coupled or _is_operator_style(model):
            continue

        # Count state variables (unknowns)
        state_vars = [name for name, var in model.variables.items() if var.type == "state"]
        num_unknowns = len(state_vars)

        # Count governing equations only — `ic` equations pin initial conditions,
        # not unknowns, so they do not participate in the balance (see
        # `_is_initial_condition_equation`).
        num_equations = sum(1 for eq in model.equations if not _is_initial_condition_equation(eq))

        if num_equations != num_unknowns:
            structural_errors.append(
                ValidationError(
                    # A JSON Pointer to the offending model (CONFORMANCE_SPEC
                    # §7.1.2; pinned as `/models/<name>`).
                    path=f"/models/{model.name}",
                    message=(
                        f"Equation-unknown balance error in model '{model.name}': "
                        f"{num_equations} equations for {num_unknowns} unknowns "
                        f"(state variables: {', '.join(state_vars)})"
                    ),
                    code=ErrorCode.EQUATION_COUNT_MISMATCH.value,
                    details={
                        "model_name": model.name,
                        "num_equations": num_equations,
                        "num_unknowns": num_unknowns,
                        "state_variables": state_vars,
                    },
                )
            )


def _validate_stoich(
    species_stoich: dict[str, Any],
    species_names: set[str],
    rs_name: str,
    reaction_path: str,
    side_key: str,
    label: str,
    structural_errors: list[ValidationError],
    reaction_id: str | None = None,
) -> None:
    """
    Validate one side (substrates or products) of a reaction: each species must
    be declared and its stoichiometry must be a finite, positive number.

    Shared by the substrate and product checks in
    :func:`_validate_reaction_consistency`. ``side_key`` is the SPEC path segment
    (``"substrates"`` / ``"products"`` — the wire keys, not the ``reactants``
    dataclass alias) and ``label`` is the human-readable side name
    (``"Substrate"`` / ``"Product"``) used in the error messages.

    Each side is a name→stoichiometry map that preserves the source list's order,
    so the JSON Pointer names the array POSITION and the field carrying the defect
    — ``.../{side_key}/{index}/species`` for an undeclared species,
    ``.../{side_key}/{index}/stoichiometry`` for a bad stoichiometry — matching
    the cross-language contract (CONFORMANCE_SPEC §7.1.2; TypeScript reference).
    """
    for idx, (species_name, stoich) in enumerate(species_stoich.items()):
        entry_path = f"{reaction_path}/{side_key}/{idx}"
        if species_name not in species_names:
            structural_errors.append(
                ValidationError(
                    path=f"{entry_path}/species",
                    message=f'Species "{species_name}" in reaction {side_key} is not declared',
                    code=ErrorCode.UNDEFINED_SPECIES.value,
                    details={
                        "species": species_name,
                        "reaction_id": reaction_id,
                        "reaction_system": rs_name,
                        "available_species": list(species_names),
                    },
                )
            )

        if not isinstance(stoich, (int, float)) or isinstance(stoich, bool):
            structural_errors.append(
                ValidationError(
                    path=f"{entry_path}/stoichiometry",
                    message=f"{label} stoichiometry must be a number, got {type(stoich).__name__}",
                    code=ErrorCode.INVALID_STOICHIOMETRY_TYPE.value,
                    details={
                        "species": species_name,
                        "stoichiometry": stoich,
                        "stoichiometry_type": type(stoich).__name__,
                    },
                )
            )
        elif isinstance(stoich, float) and (math.isnan(stoich) or math.isinf(stoich)):
            structural_errors.append(
                ValidationError(
                    path=f"{entry_path}/stoichiometry",
                    message=f"{label} stoichiometry must be finite, got {stoich}",
                    code=ErrorCode.INVALID_STOICHIOMETRY.value,
                    details={"species": species_name, "stoichiometry": stoich},
                )
            )
        elif stoich <= 0:
            structural_errors.append(
                ValidationError(
                    path=f"{entry_path}/stoichiometry",
                    message=f"{label} stoichiometry must be positive, got {stoich}",
                    code=ErrorCode.NEGATIVE_STOICHIOMETRY.value,
                    details={"species": species_name, "stoichiometry": stoich},
                )
            )


def _validate_reaction_consistency(
    esm_file: EsmFile, structural_errors: list[ValidationError]
) -> None:
    """
    Validate reaction consistency in reaction systems.

    Checks:
    - Every species in substrates/products is declared in species
    - Stoichiometries are positive
    - No reaction has both substrates: null and products: null
    - Rate expressions only reference declared parameters/species

    This is the single owner of the undeclared-reaction-species rule; the
    raw-dict layer's twin in
    ``earthsci_ast.structural_checks._check_reaction_systems`` was dropped.
    """
    for rs_name, rs in esm_file.reaction_systems.items():
        # Name-keyed JSON pointer, matching the sibling reaction checks
        # (_validate_reaction_system_ics / _validate_reaction_rate_dimensions).
        # reaction_systems is a name-keyed map, so a numeric enumerate() index
        # here would be a meaningless pointer.
        rs_path = f"/reaction_systems/{rs_name}"

        # Build set of declared species and parameters
        species_names = {species.name for species in rs.species}
        param_names = {param.name for param in rs.parameters}

        for r_idx, reaction in enumerate(rs.reactions):
            reaction_path = f"{rs_path}/reactions/{r_idx}"

            # Check for null-null reaction
            if not reaction.reactants and not reaction.products:
                structural_errors.append(
                    ValidationError(
                        path=reaction_path,
                        message="Reaction has both substrates: null and products: null",
                        code=ErrorCode.NULL_REACTION.value,
                        details={"reaction_name": reaction.name},
                    )
                )

            # Validate substrate species exist and have positive stoichiometry.
            # The dataclass field is `reactants`; the SPEC/wire key (and the
            # pinned JSON-Pointer segment) is `substrates`.
            _validate_stoich(
                reaction.reactants,
                species_names,
                rs.name,
                reaction_path,
                "substrates",
                "Substrate",
                structural_errors,
                reaction_id=reaction.id,
            )

            # Validate product species exist and have positive stoichiometry
            _validate_stoich(
                reaction.products,
                species_names,
                rs.name,
                reaction_path,
                "products",
                "Product",
                structural_errors,
                reaction_id=reaction.id,
            )

            # Validate rate constant references (full expression parsing)
            if hasattr(reaction, "rate_constant") and reaction.rate_constant is not None:
                _validate_rate_expression(
                    reaction.rate_constant,
                    param_names,
                    species_names,
                    rs.name,
                    reaction_path,
                    structural_errors,
                )


def _validate_reaction_system_ics(
    esm_file: EsmFile, structural_errors: list[ValidationError]
) -> None:
    """Reject ``ic``-op equations placed inside a reaction system's
    ``constraint_equations`` (spec §11.4.1).

    A reaction system has no ``equations`` field and hosts no initial
    conditions: a species' initial value is its scalar ``species.default``, and a
    non-constant / spatial IC is declared with a scoped-reference ``ic`` equation
    in a MODEL (``ic(Chemistry.O3) ~ <field>``), never inside the reaction
    system. Such a file is SCHEMA-VALID (``constraint_equations`` is an array of
    Equation and ``ic`` is a legal op, so nothing in JSON Schema forbids it) but
    MUST be rejected structurally with code ``ic_in_reaction_system``.
    """
    for rs_name, rs in esm_file.reaction_systems.items():
        for ce_idx, eq in enumerate(rs.constraint_equations):
            lhs = getattr(eq, "lhs", None)
            if getattr(lhs, "op", None) != "ic":
                continue
            args = getattr(lhs, "args", None) or []
            species = args[0] if args and isinstance(args[0], str) else None
            structural_errors.append(
                ValidationError(
                    path=f"/reaction_systems/{rs_name}/constraint_equations/{ce_idx}",
                    message=(
                        "ic equation not allowed in a reaction system; a reaction "
                        "system has no equations field and hosts no ic equations "
                        "(ICs are model-hosted: species.default, or a scoped-reference "
                        "ic equation in a model, spec §11.4.1)"
                    ),
                    code=ErrorCode.IC_IN_REACTION_SYSTEM.value,
                    details={
                        "system": rs_name,
                        "species": species,
                        "constraint_equation_index": ce_idx,
                    },
                )
            )


def _validate_rate_expression(
    rate_expr,
    param_names: set[str],
    species_names: set[str],
    reaction_system_name: str,
    reaction_path: str,
    structural_errors: list[ValidationError],
) -> None:
    """
    Validate that a rate expression only references declared parameters and species.

    Args:
        rate_expr: The rate expression (string, number, or ExprNode)
        param_names: Set of declared parameter names in the reaction system
        species_names: Set of declared species names in the reaction system
        reaction_system_name: Name of the reaction system for error messages
        reaction_path: Path to the reaction for error reporting
        structural_errors: List to append validation errors to
    """
    from .expression import free_variables

    if isinstance(rate_expr, str):
        # Simple parameter reference. A SCOPED one (`Other.k`) names a symbol in
        # another system and is resolved at coupling/flatten time — see the
        # matching note in the expression branch below.
        if "." in rate_expr:
            return
        if rate_expr not in param_names:
            structural_errors.append(
                ValidationError(
                    path=f"{reaction_path}/rate_constant",
                    message=f"Rate constant parameter '{rate_expr}' not declared in reaction system '{reaction_system_name}'",
                    code=ErrorCode.UNDECLARED_PARAMETER.value,
                    details={
                        "parameter": rate_expr,
                        "reaction_system": reaction_system_name,
                        "available_parameters": list(param_names),
                    },
                )
            )
    elif isinstance(rate_expr, (int, float)):
        # Numeric constant - always valid
        pass
    else:
        # Complex expression - parse and validate all variables
        try:
            referenced_vars = free_variables(rate_expr)

            # Check that all referenced variables are declared parameters or species
            for var in referenced_vars:
                # A SCOPED reference (`Meteorology.temperature`) names a symbol in
                # ANOTHER system, so it is not expected in this reaction system's
                # own parameters/species — a rate expression MAY carry one
                # (esm-spec §4.6; `tests/valid/events_cross_system.esm` drives an
                # atmospheric rate from `MeteorologicalSystem.solar_intensity`).
                # It is resolved by the coupling/flatten layer, exactly as a
                # scoped ref in a model equation is deferred there; checking it
                # against the LOCAL symbol table can only produce false
                # `undeclared_rate_variable` findings.
                if "." in var:
                    continue
                if var not in param_names and var not in species_names:
                    # Variable is not declared in this reaction system
                    structural_errors.append(
                        ValidationError(
                            path=f"{reaction_path}/rate_constant",
                            message=f"Rate expression references undeclared variable '{var}' in reaction system '{reaction_system_name}'",
                            code=ErrorCode.UNDECLARED_RATE_VARIABLE.value,
                            details={
                                "variable": var,
                                "reaction_system": reaction_system_name,
                                "available_parameters": list(param_names),
                                "available_species": list(species_names),
                                "rate_expression": str(rate_expr),
                            },
                        )
                    )

        except Exception as e:
            # Error parsing expression - report as validation error
            structural_errors.append(
                ValidationError(
                    path=f"{reaction_path}/rate_constant",
                    message=f"Could not parse rate expression in reaction system '{reaction_system_name}': {str(e)}",
                    code=ErrorCode.INVALID_RATE_EXPRESSION.value,
                    details={
                        "reaction_system": reaction_system_name,
                        "rate_expression": str(rate_expr),
                        "parse_error": str(e),
                    },
                )
            )


def _validate_reaction_rate_dimensions(
    esm_file: EsmFile, structural_errors: list[ValidationError]
) -> None:
    """
    Mass-action dimensional check for reaction rates (spec §7.4).

    For each reaction with a declared-unit rate and declared-unit substrates,
    compare the rate expression's dimensions to conc_unit^(1-total_order)/time,
    where conc_unit is the first substrate's species units. Emit
    ``unit_inconsistency`` when they disagree. Dimensionless-concentration
    systems (mole-fraction families) are skipped for Julia parity.

    Mirrors Julia's ``validate_reaction_system_dimensions`` and the Go/Rust
    ``validate_reaction_rate_units`` ports; the error payload matches the
    contract in ``tests/invalid/expected_errors.json``.
    """
    try:
        # The SHARED ESM registry, not a bare `pint.UnitRegistry()`. A vanilla
        # pint registry does not define `ppb`/`ppbv`/`Dobson`/… and gives `molec`
        # a [substance] dimension, so this check used to run against a registry
        # that disagreed with every other unit check in the package — silently
        # skipping (parse_dim -> None) exactly the atmospheric-chemistry rates it
        # exists to verify.
        from .units import PINT_AVAILABLE, unit_dimensionality

        if not PINT_AVAILABLE:
            return
    except ImportError:
        return
    from .structural_checks import _BUILTIN_SYMBOLS, _normalize_unit

    # Spell these with TABLE symbols. The ESM registry is the closed §4.8.1
    # table, so pint's long-form names (`second`, `meter`, `celsius`, …) are no
    # longer defined — `ureg("second")` used to work only because the registry
    # was vanilla pint, and it now raises UndefinedUnitError.
    time_dim = unit_dimensionality("s")
    dimensionless_dim = unit_dimensionality("")

    def parse_dim(unit_str):
        if not unit_str:
            return None
        try:
            return unit_dimensionality(_normalize_unit(unit_str))
        except Exception:
            return None

    for rs_name, rs in esm_file.reaction_systems.items():
        species_units = {sp.name: sp.units for sp in rs.species}
        param_units = {p.name: p.units for p in rs.parameters}

        for r_idx, reaction in enumerate(rs.reactions):
            reaction_path = f"/reaction_systems/{rs_name}/reactions/{r_idx}"
            rate = reaction.rate_constant
            # Only bare-string rate refs are dimensionally checkable here;
            # compound rate expressions carry implicit unit constants that
            # defeat literal dimensional analysis.
            if not isinstance(rate, str):
                continue
            if "." in rate or rate in _BUILTIN_SYMBOLS:
                continue
            if rate in param_units:
                rate_units_str = param_units[rate]
            elif rate in species_units:
                rate_units_str = species_units[rate]
            else:
                continue  # undefined refs flagged elsewhere
            rate_dim = parse_dim(rate_units_str)
            if rate_dim is None:
                continue

            # reactants dict preserves insertion order from _parse_reaction
            if not reaction.reactants:
                continue
            substrate_names = list(reaction.reactants.keys())
            first_sp = substrate_names[0]
            first_sp_units = species_units.get(first_sp)
            first_sp_dim = parse_dim(first_sp_units)
            if first_sp_dim is None:
                continue
            if first_sp_dim == dimensionless_dim:
                # Julia parity: skip mole-fraction families.
                continue

            substrate_dim = dimensionless_dim
            total_order = 0
            resolvable = True
            for sp_name, stoich in reaction.reactants.items():
                try:
                    stoich_i = int(stoich)
                except (TypeError, ValueError):
                    resolvable = False
                    break
                if stoich_i != stoich:
                    resolvable = False
                    break
                sp_dim = parse_dim(species_units.get(sp_name))
                if sp_dim is None:
                    resolvable = False
                    break
                substrate_dim = substrate_dim * (sp_dim**stoich_i)
                total_order += stoich_i
            if not resolvable:
                continue

            # Equivalent to rate_dim == first_sp_dim^(1-order) / time but
            # avoids pint's [substance]^0 * [length]^0 ≠ dimensionless quirk
            # by checking rate * prod(substrate^stoich) == first_species/time.
            expected_dim = first_sp_dim / time_dim
            full_dim = rate_dim * substrate_dim
            if full_dim != expected_dim:
                rxn_label = reaction.id if reaction.id is not None else reaction.name
                structural_errors.append(
                    ValidationError(
                        path=reaction_path,
                        message="Reaction rate expression has incompatible units for reaction stoichiometry",
                        code=ErrorCode.UNIT_INCONSISTENCY.value,
                        details={
                            "reaction_id": rxn_label,
                            "rate_units": rate_units_str or "",
                            "expected_rate_units": _format_expected_rate_units(
                                first_sp_units or "", total_order
                            ),
                            "reaction_order": total_order,
                        },
                    )
                )


def _format_expected_rate_units(species_units: str, total_order: int) -> str:
    """Compose the canonical rate-unit string from the reference species unit
    and total reaction order, matching the contract in
    ``tests/invalid/expected_errors.json``. Ports the Go/Rust implementations.

    Examples:
        ("mol/L", 2) -> "L/(mol*s)"
        ("mol/L", 1) -> "1/s"
        ("mol/L", 0) -> "mol/(L*s)"
        ("mol/m^3", 2) -> "m^3/(mol*s)"
    """
    exp = 1 - total_order
    if exp == 0:
        return "1/s"
    num, den = _split_unit_num_den(species_units)
    exp_abs = exp
    if exp < 0:
        num, den = den, num
        exp_abs = -exp
    num_str = _power_factor(num, exp_abs)
    den_factors = []
    df = _power_factor(den, exp_abs)
    if df:
        den_factors.append(df)
    den_factors.append("s")
    if not num_str:
        num_str = "1"
    if len(den_factors) == 1:
        return f"{num_str}/{den_factors[0]}"
    return f"{num_str}/({'*'.join(den_factors)})"


def _split_unit_num_den(s: str):
    """Split a unit string on its first top-level '/'. ``"mol/L"`` → ``("mol",
    "L")``; ``"mol/(L*s)"`` → ``("mol", "L*s")``. If no top-level '/' appears,
    the whole string is the numerator."""
    s = s.strip()
    if not s:
        return "", ""
    depth = 0
    for i, c in enumerate(s):
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == "/" and depth == 0:
            num = s[:i].strip()
            den = s[i + 1 :].strip()
            if den.startswith("(") and den.endswith(")"):
                den = den[1:-1]
            return num, den
    return s, ""


def _power_factor(s: str, n: int) -> str:
    """Raise a unit factor to an integer power, rendering as a string.
    Parenthesises compound factors when the power is not 1."""
    s = s.strip()
    if not s:
        return ""
    if n == 1:
        return s
    if "*" in s or "/" in s:
        return f"({s})^{n}"
    return f"{s}^{n}"


def _validate_functional_affect(
    affect,
    affect_path: str,
    all_variables: set[str],
    all_parameters: set[str],
    all_operators: set[str],
    param_label: str,
    structural_errors: list[ValidationError],
) -> None:
    """
    Validate a ``FunctionalAffect``'s ``handler_id``, ``read_vars``,
    ``read_params``, and ``modified_params`` references.

    Shared by the ``affects`` and ``affect_neg`` branches of
    :func:`_validate_event_consistency`. ``param_label`` distinguishes the
    read/modified-parameter error messages (``"Functional affect"`` for
    ``affects`` vs ``"Affect_neg functional affect"`` for ``affect_neg``); the
    emitted errors are otherwise identical to the previously inlined checks.
    """
    # A `handler_id` is NOT required to name an entry in the document's
    # `operators` block: a FunctionalAffect's handler may be supplied by the HOST
    # (a `callback` handler registered by the runtime), and `full_coupled.esm`
    # — a valid fixture — declares no `operators` block at all. Requiring
    # `handler_id in operators` rejected it. The Go reference accepts it; a
    # handler the host does not register is a run-time error, not a structural
    # one, so nothing is checked here.

    # Validate read_vars exist
    for var_idx, read_var in enumerate(affect.read_vars):
        if not _is_operator_placeholder(read_var) and read_var not in all_variables:
            structural_errors.append(
                ValidationError(
                    path=f"{affect_path}/read_vars/{var_idx}",
                    message=f"Variable '{read_var}' in event affects/conditions is not declared",
                    code=ErrorCode.EVENT_VAR_UNDECLARED.value,
                    details={
                        "variable": read_var,
                        "available_variables": sorted(all_variables),
                    },
                )
            )

    # Validate read_params exist
    for param_idx, read_param in enumerate(affect.read_params):
        if read_param not in all_parameters:
            structural_errors.append(
                ValidationError(
                    path=f"{affect_path}/read_params/{param_idx}",
                    message=f"{param_label} read parameter '{read_param}' not declared",
                    code=ErrorCode.UNDECLARED_READ_PARAMETER.value,
                    details={
                        "parameter": read_param,
                        "available_parameters": sorted(all_parameters),
                    },
                )
            )

    # Validate modified_params exist
    for param_idx, mod_param in enumerate(affect.modified_params):
        if mod_param not in all_parameters:
            structural_errors.append(
                ValidationError(
                    path=f"{affect_path}/modified_params/{param_idx}",
                    message=f"{param_label} modified parameter '{mod_param}' not declared",
                    code=ErrorCode.UNDECLARED_MODIFIED_PARAMETER.value,
                    details={
                        "parameter": mod_param,
                        "available_parameters": sorted(all_parameters),
                    },
                )
            )


def _validate_observed_dimensions(
    esm_file: EsmFile, structural_errors: list[ValidationError]
) -> None:
    """esm-spec §4.8.4: an observed variable whose DECLARED units disagree with
    the dimension its EXPRESSION computes is a *provable* dimensional mismatch,
    and therefore a hard error (``unit_inconsistency``).

    This is the check the whole §4.8 dimensional apparatus exists to make, and
    it was missing: ``units.UnitValidator`` could type an expression (each op
    carries a dimensional rule), and ``structural_checks`` could reject an
    unreal unit STRING — but nothing ever compared the two, so
    ``{"units": "N", "expression": charge * efield}`` was accepted no matter
    what dimension the right-hand side actually had. Every discriminator in
    ``tests/valid/units_registry_grammar.esm`` passed *vacuously* until this
    landed.

    The §4.8.4 severity contract is honoured exactly:

    * an UNDETERMINABLE dimension (``None`` — a symbolic exponent, an op with no
      dimensional rule, an undeclared operand) SKIPS the check; it is never
      treated as dimensionless;
    * an unparseable declared unit is skipped here — it is reported once, on its
      own, by ``structural_checks._check_unparseable_units``;
    * only a mismatch between two KNOWN dimensions is reported.
    """
    try:
        from .units import (
            PINT_AVAILABLE,
            DimensionalMismatchError,
            UnitValidator,
            UnparseableUnitError,
            parse_unit,
        )

        if not PINT_AVAILABLE:
            return
    except ImportError:
        return

    for model in esm_file.models.values():
        # Seed the typer with every declared unit in THIS model, so bare-name
        # operands resolve (and a name reused in another model cannot collide).
        known = {}
        for name, var in model.variables.items():
            if not var.units:
                continue
            try:
                known[name] = parse_unit(var.units)
            except UnparseableUnitError:
                continue  # reported by _check_unparseable_units; not our finding

        validator = UnitValidator()
        validator.known_units = known

        for vname, var in model.variables.items():
            if var.type != "observed" or var.expression is None or not var.units:
                continue
            if vname not in known:
                continue  # its own declared unit is unparseable — already reported

            declared = known[vname].dimensionality
            path = f"/models/{model.name}/variables/{vname}"
            try:
                computed = validator._get_expression_dimension(var.expression)
            except DimensionalMismatchError as exc:
                # A provable inconsistency INSIDE the expression (adding metres
                # to kilograms, a transcendental with a dimensional argument).
                structural_errors.append(
                    ValidationError(
                        path=path,
                        message=(
                            f"Observed variable '{vname}' has a dimensionally "
                            f"inconsistent expression: {exc}"
                        ),
                        code=ErrorCode.UNIT_INCONSISTENCY.value,
                        details={"variable": vname, "declared_units": var.units},
                    )
                )
                continue

            if computed is None:
                continue  # undeterminable (§4.8.4) — skip, never assume dimensionless
            if computed == declared:
                continue

            structural_errors.append(
                ValidationError(
                    path=path,
                    message=(
                        f"Observed variable '{vname}' is declared as '{var.units}' "
                        f"({declared}) but its expression has dimension {computed}"
                    ),
                    code=ErrorCode.UNIT_INCONSISTENCY.value,
                    details={
                        "variable": vname,
                        "declared_units": var.units,
                        "declared_dimension": str(declared),
                        "expression_dimension": str(computed),
                    },
                )
            )


#: The reserved OPERATOR PLACEHOLDER (esm-spec §6.4). In an operator-style model
#: `_var` stands for "each matching state variable of the target system", and is
#: substituted at `operator_compose` time — so it is never a declared symbol, and
#: an event affect that writes it (`_var ~ Pre(_var) * decay`) is legal in exactly
#: the operator-composed / coupled models that `operator_compose` exists for.
#: Reporting it as `event_var_undeclared` rejects `tests/valid/full_coupled.esm`,
#: which the spec's own §6.4 example is written from.
_OPERATOR_PLACEHOLDER = "_var"


def _is_operator_placeholder(name: object) -> bool:
    return name == _OPERATOR_PLACEHOLDER


def _validate_event_consistency(
    esm_file: EsmFile, structural_errors: list[ValidationError]
) -> None:
    """
    Validate event consistency.

    Checks:
    - Continuous event conditions are expressions (not booleans)
    - Discrete event conditions produce boolean values
    - Variables in affects are declared
    - Variables in affect_neg (direction-dependent affects) are declared
    - Functional affect references are valid (handler_id, read_vars, read_params, modified_params)
    - discrete_parameters in coupling entries are valid

    The reserved `_var` placeholder is never an undeclared variable — see
    :data:`_OPERATOR_PLACEHOLDER`.
    """
    # Build variable lookup for validation
    all_variables = set()
    all_parameters = set()

    for model in esm_file.models.values():
        for var_name in model.variables:
            all_variables.add(var_name)
            all_variables.add(f"{model.name}.{var_name}")
            # Parameters are also variables
            if model.variables[var_name].type == "parameter":
                all_parameters.add(var_name)
                all_parameters.add(f"{model.name}.{var_name}")

    for rs in esm_file.reaction_systems.values():
        for species in rs.species:
            all_variables.add(species.name)
            all_variables.add(f"{rs.name}.{species.name}")
        for param in rs.parameters:
            all_variables.add(param.name)
            all_variables.add(f"{rs.name}.{param.name}")
            all_parameters.add(param.name)
            all_parameters.add(f"{rs.name}.{param.name}")

    # Build operator/handler lookup for functional affects
    all_operators = set()
    for operator in esm_file.operators:
        all_operators.add(operator.operator_id)

    for event_idx, event in enumerate(esm_file.events):
        event_path = f"/events/{event_idx}"

        # Validate affects - check that target variables exist and functional affects are valid
        for affect_idx, affect in enumerate(event.affects):
            affect_path = f"{event_path}/affects/{affect_idx}"

            if hasattr(affect, "lhs"):  # AffectEquation
                if not _is_operator_placeholder(affect.lhs) and affect.lhs not in all_variables:
                    structural_errors.append(
                        ValidationError(
                            path=f"{affect_path}/lhs",
                            message=f"Variable '{affect.lhs}' in event affects/conditions is not declared",
                            code=ErrorCode.EVENT_VAR_UNDECLARED.value,
                            details={
                                "variable": affect.lhs,
                                "available_variables": sorted(all_variables),
                            },
                        )
                    )
            elif hasattr(affect, "handler_id"):  # FunctionalAffect
                _validate_functional_affect(
                    affect,
                    affect_path,
                    all_variables,
                    all_parameters,
                    all_operators,
                    "Functional affect",
                    structural_errors,
                )

        # Validate affect_neg (direction-dependent affects) if present
        if hasattr(event, "affect_neg") and event.affect_neg is not None:
            for affect_idx, affect in enumerate(event.affect_neg):
                affect_path = f"{event_path}/affect_neg/{affect_idx}"

                if hasattr(affect, "lhs"):  # AffectEquation
                    if not _is_operator_placeholder(affect.lhs) and affect.lhs not in all_variables:
                        structural_errors.append(
                            ValidationError(
                                path=f"{affect_path}/lhs",
                                message=f"Variable '{affect.lhs}' in event affects/conditions is not declared",
                                code=ErrorCode.EVENT_VAR_UNDECLARED.value,
                                details={
                                    "variable": affect.lhs,
                                    "available_variables": sorted(all_variables),
                                },
                            )
                        )
                elif hasattr(affect, "handler_id"):  # FunctionalAffect
                    # Same validation as regular affects
                    _validate_functional_affect(
                        affect,
                        affect_path,
                        all_variables,
                        all_parameters,
                        all_operators,
                        "Affect_neg functional affect",
                        structural_errors,
                    )

    # Validate discrete_parameters in coupling entries
    for coupling_idx, coupling in enumerate(esm_file.coupling):
        coupling_path = f"/coupling/{coupling_idx}"

        # Check if this coupling entry has discrete_parameters
        if hasattr(coupling, "discrete_parameters") and coupling.discrete_parameters is not None:
            for param_idx, discrete_param in enumerate(coupling.discrete_parameters):
                param_path = f"{coupling_path}/discrete_parameters/{param_idx}"

                if discrete_param not in all_parameters:
                    structural_errors.append(
                        ValidationError(
                            path=param_path,
                            message=f"Discrete parameter '{discrete_param}' does not match a declared parameter",
                            code=ErrorCode.INVALID_DISCRETE_PARAM.value,
                            details={
                                "parameter": discrete_param,
                                "available_parameters": sorted(all_parameters),
                            },
                        )
                    )


def _validate_coupling_units(
    esm_file: EsmFile, structural_errors: list[ValidationError]
) -> None:
    """esm-spec §4.7.6: a ``variable_map`` coupling with ``transform == "identity"``
    whose ``from`` and ``to`` variables carry declared units that are both present,
    non-empty, and DIFFERENT is a provable domain mismatch — decidable statically
    from this single document, so it belongs in ``validate()``.

    This mirrors :func:`earthsci_ast.flatten._check_variable_map_units` (which
    raises :class:`~earthsci_ast.flatten.DomainUnitMismatchError` at flatten time)
    into the coded validate() channel, emitting ``domain_unit_mismatch`` at the
    coupling entry's pointer ``/coupling/{i}``. ``param_to_var`` and
    ``conversion_factor`` transforms are EXEMPT (the former does not imply unit
    equivalence at the mapping site, the latter declares the conversion
    explicitly), an expression transform is not ``"identity"``, and matching or
    absent units are legal.
    """
    from .esm_types import VariableMapCoupling
    from .flatten import _lookup_variable_units

    for i, entry in enumerate(esm_file.coupling):
        if not isinstance(entry, VariableMapCoupling):
            continue
        if entry.transform != "identity":
            continue
        src_units = _lookup_variable_units(esm_file, entry.from_var or "")
        tgt_units = _lookup_variable_units(esm_file, entry.to_var or "")
        if not src_units or not tgt_units:
            continue
        if src_units != tgt_units:
            structural_errors.append(
                ValidationError(
                    path=f"/coupling/{i}",
                    message=(
                        f"variable_map identity coupling maps {entry.from_var!r} "
                        f"({src_units}) to {entry.to_var!r} ({tgt_units}); declared "
                        f"units differ (esm-spec §4.7.6)"
                    ),
                    code=ErrorCode.DOMAIN_UNIT_MISMATCH.value,
                    details={
                        "from": entry.from_var,
                        "to": entry.to_var,
                        "from_units": src_units,
                        "to_units": tgt_units,
                        "transform": "identity",
                    },
                )
            )


def _validate_units(esm_file: EsmFile, unit_warnings: list[UnitWarning]) -> None:
    """
    Validate dimensional consistency (warnings only).

    Uses the UnitValidator from units.py to perform comprehensive dimensional analysis
    and unit validation across models and reaction systems.
    """
    try:
        from .units import UnitValidator

        # Create unit validator instance
        validator = UnitValidator()

        # Validate the entire ESM file
        unit_result = validator.validate_esm_file(esm_file)

        # Convert validation errors to warnings (as per function contract)
        for error_msg in unit_result.errors:
            unit_warnings.append(
                UnitWarning(
                    path="unit_validation",
                    message=error_msg,
                    details={"validation_type": "dimensional_analysis"},
                )
            )

        # Convert validation warnings to our warning format
        for warning_msg in unit_result.warnings:
            unit_warnings.append(
                UnitWarning(
                    path="unit_validation",
                    message=warning_msg,
                    details={"validation_type": "unit_warning"},
                )
            )

    except ImportError:
        # If pint is not available, add a warning about missing unit validation
        unit_warnings.append(
            UnitWarning(
                path="unit_validation",
                message="Unit validation skipped: pint library not available. Install with: pip install pint",
                details={"validation_type": "dependency_missing"},
            )
        )
    except Exception as e:
        # If unit validation fails for any reason, add a warning but don't break validation
        unit_warnings.append(
            UnitWarning(
                path="unit_validation",
                message=f"Unit validation failed: {str(e)}",
                details={"validation_type": "validation_error", "exception": str(e)},
            )
        )
