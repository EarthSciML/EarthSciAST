"""
Unit validation and dimensional analysis for ESM Format.

Provides unit validation functionality using the pint library to ensure
dimensional consistency across models, reaction systems, and expressions.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

try:
    import pint

    PINT_AVAILABLE = True
    ureg = pint.UnitRegistry()
    UnitsContainer = pint.util.UnitsContainer

    # ESM-specific units standard (docs/units-standard.md).
    # Mole-fraction family: dimensionless with scale factors; ppmv/ppbv/pptv
    # are volume-mixing-ratio aliases that equal ppm/ppb/ppt under the
    # ideal-gas approximation, so every binding must treat them as identical.
    #
    # pint form: `name = <scale>` (omitting the reference unit) registers a
    # pure scaling of the empty dimension — this avoids a pint bug where
    # `name = <scale> * dimensionless` stores `dimensionless` as a reference
    # name and then fails conversion with KeyError: ''.
    ureg.define("ppm = 1e-6 = ppmv")
    ureg.define("ppb = 1e-9 = ppbv")
    ureg.define("ppt = 1e-12 = pptv")
    # `molec` is the schema-doc spelling of pint's predefined `molecule`.
    ureg.define("@alias molecule = molec")
    ureg.define("molecule_cm3 = 1 / cm**3")
    # Dobson unit: areal number density of ozone molecules.
    # 1 Dobson = 2.6867e20 molec/m^2 = 2.6867e16 molec/cm^2 (per standard).
    ureg.define("Dobson = 2.6867e16 * molecule * cm**(-2)")

except ImportError:
    PINT_AVAILABLE = False
    ureg = None
    UnitsContainer = Any

from .esm_types import EsmFile, Expr, ExprNode, Model, ReactionSystem


class DimensionalMismatchError(ValueError):
    """A PROVABLE dimensional inconsistency found while typing an expression.

    Distinct from "could not determine the dimension" (which is signalled by
    returning ``None``) and from "pint could not parse this unit" (a
    ``pint.PintError``). Only this exception is promoted to a validation
    ERROR; the other two remain warnings/skips.

    It subclasses ``ValueError`` so that pre-existing
    ``except ValueError`` callers keep catching it.
    """


# ---------------------------------------------------------------------------
# Operator dimension rules (esm-spec §4.2 evaluable core).
#
# The former catch-all `return dimensionless` for every non-arithmetic op was
# wrong in BOTH directions: it reported `max(P1, P2)` (both in Pa) as
# dimensionless, and it never checked that `sin`/`exp`/`log` arguments ARE
# dimensionless. Each op now states its rule explicitly, and anything not
# listed returns None ("unknown dimension") rather than manufacturing a false
# `dimensionless` — an unknown dimension is skipped by the callers, a
# dimensionless one would produce spurious mismatches.
# ---------------------------------------------------------------------------

#: n-ary ops whose operands must all share one dimension, which is also the
#: dimension of the result.
_DIM_PRESERVING_NARY = frozenset({"+", "-", "min", "max"})

#: Ops that carry through the dimension of their FIRST operand unchanged.
#: (`ic`/`Pre` are value-preserving form ops; `floor`/`ceil`/`abs` preserve
#: magnitude and therefore units.)
_DIM_PRESERVING_UNARY = frozenset({"abs", "floor", "ceil", "ic", "Pre"})

#: Elementary functions whose ARGUMENT must be dimensionless and whose result
#: is dimensionless. `sqrt` is deliberately NOT here — it halves the dimension.
_DIMENSIONLESS_ARG_FUNCS = frozenset(
    {
        "exp",
        "log",
        "log10",
        "sin",
        "cos",
        "tan",
        "asin",
        "acos",
        "atan",
        "sinh",
        "cosh",
        "tanh",
        "asinh",
        "acosh",
        "atanh",
    }
)

#: Comparisons: operands must share a dimension; the result is a dimensionless
#: boolean.
_COMPARISON_OPS = frozenset({">", "<", ">=", "<=", "==", "!="})

#: Booleans (and `sign`, whose result is a dimensionless ±1) yield a
#: dimensionless result regardless of operand dimensions.
_DIMENSIONLESS_RESULT_OPS = frozenset({"and", "or", "not", "sign", "true"})


@dataclass
class UnitValidationResult:
    """Result of unit validation check."""

    is_valid: bool
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    unit_registry: dict[str, str] = field(default_factory=dict)  # variable_name -> unit_string
    dimensional_analysis: dict[str, Any] = field(default_factory=dict)


@dataclass
class UnitConversionResult:
    """Result of unit conversion operation."""

    success: bool
    converted_value: float | None = None
    conversion_factor: float | None = None
    error_message: str | None = None


class UnitValidator:
    """Validator for dimensional consistency in ESM format structures."""

    def __init__(self):
        """Initialize the unit validator."""
        if not PINT_AVAILABLE:
            raise ImportError(
                "pint library is required for unit validation. Install with: pip install pint"
            )

        self.ureg = ureg
        self.known_units: dict[str, pint.Quantity] = {}

    def validate_esm_file(self, esm_file: EsmFile) -> UnitValidationResult:
        """
        Validate unit consistency across an entire ESM file.

        Args:
            esm_file: The ESM file to validate

        Returns:
            UnitValidationResult with validation status and any issues found
        """
        result = UnitValidationResult(is_valid=True)

        if esm_file.models:
            self._merge_component_results(
                esm_file.models.values(), self.validate_model, "Model", result
            )

        if esm_file.reaction_systems:
            self._merge_component_results(
                esm_file.reaction_systems.values(),
                self.validate_reaction_system,
                "ReactionSystem",
                result,
            )

        result.is_valid = len(result.errors) == 0
        return result

    def _merge_component_results(self, components, validator, prefix, result):
        """Validate each component and fold its errors/warnings/registry into
        ``result``, prefixing every message with ``"{prefix} {name}: "``."""
        for component in components:
            sub = validator(component)
            result.errors.extend(f"{prefix} {component.name}: {e}" for e in sub.errors)
            result.warnings.extend(f"{prefix} {component.name}: {w}" for w in sub.warnings)
            result.unit_registry.update(sub.unit_registry)

    def validate_model(self, model: Model) -> UnitValidationResult:
        """
        Validate unit consistency within a model.

        Args:
            model: The model to validate

        Returns:
            UnitValidationResult for the model
        """
        result = UnitValidationResult(is_valid=True)

        # Scope the known-units registry to this component so that a variable
        # name reused in another model/reaction system cannot collide during
        # bare-name dimension lookups in _get_expression_dimension.
        self.known_units = {}

        if not model.variables:
            return result

        # Build unit registry for this model
        for var_name, var_info in model.variables.items():
            if var_info.units:
                try:
                    unit = self.ureg(var_info.units)
                    result.unit_registry[var_name] = var_info.units
                    self.known_units[var_name] = unit
                except pint.PintError as e:
                    # Per esm-libraries-spec §3.3.3/§3.4 and the Julia
                    # reference, an unparseable unit is a WARNING, not a hard
                    # error: the variable is omitted from known_units below
                    # (treated as unknown), so equations referencing it are
                    # skipped rather than reported as dimensional mismatches.
                    result.warnings.append(
                        f"Invalid unit '{var_info.units}' for variable '{var_name}': {e}"
                    )

        # Validate equations
        if model.equations:
            for i, equation in enumerate(model.equations):
                eq_result = self.validate_equation(equation, f"eq_{i}")
                result.errors.extend(eq_result.errors)
                result.warnings.extend(eq_result.warnings)

        # Validate variable expressions
        for var_name, var_info in model.variables.items():
            if hasattr(var_info, "expression") and var_info.expression:
                expr_result = self.validate_expression(var_info.expression, var_name)
                if expr_result.errors:
                    result.errors.extend([f"Variable {var_name}: {e}" for e in expr_result.errors])

        result.is_valid = len(result.errors) == 0
        return result

    def validate_reaction_system(self, rs: ReactionSystem) -> UnitValidationResult:
        """
        Validate unit consistency within a reaction system.

        Args:
            rs: The reaction system to validate

        Returns:
            UnitValidationResult for the reaction system
        """
        result = UnitValidationResult(is_valid=True)

        # Scope the known-units registry to this component (see validate_model).
        self.known_units = {}

        # Register species units
        if rs.species:
            for species in rs.species:
                if species.units:
                    try:
                        unit = self.ureg(species.units)
                        result.unit_registry[species.name] = species.units
                        self.known_units[species.name] = unit
                    except pint.PintError as e:
                        # Unparseable unit is a WARNING, not a hard error (see
                        # validate_model): the species is omitted from
                        # known_units, so it is treated as unknown.
                        result.warnings.append(
                            f"Invalid unit '{species.units}' for species '{species.name}': {e}"
                        )

        # Register parameter units
        if rs.parameters:
            for param in rs.parameters:
                if param.units:
                    try:
                        unit = self.ureg(param.units)
                        result.unit_registry[param.name] = param.units
                        self.known_units[param.name] = unit
                    except pint.PintError as e:
                        # Unparseable unit is a WARNING, not a hard error (see
                        # validate_model): the parameter is omitted from
                        # known_units, so it is treated as unknown.
                        result.warnings.append(
                            f"Invalid unit '{param.units}' for parameter '{param.name}': {e}"
                        )

        # Validate reactions
        if rs.reactions:
            for reaction in rs.reactions:
                reaction_result = self._validate_reaction(reaction)
                result.errors.extend(reaction_result.errors)
                result.warnings.extend(reaction_result.warnings)

        result.is_valid = len(result.errors) == 0
        return result

    def validate_equation(self, equation, equation_id: str) -> UnitValidationResult:
        """
        Validate dimensional consistency of an equation.

        Args:
            equation: The equation to validate
            equation_id: Identifier for the equation (for error reporting)

        Returns:
            UnitValidationResult for the equation
        """
        result = UnitValidationResult(is_valid=True)

        try:
            lhs_dim = self._get_expression_dimension(equation.lhs)
            rhs_dim = self._get_expression_dimension(equation.rhs)

            if lhs_dim is not None and rhs_dim is not None:
                if not self._dimensions_compatible(lhs_dim, rhs_dim):
                    result.errors.append(
                        f"Equation {equation_id}: Dimensional mismatch - "
                        f"LHS has dimension {lhs_dim}, RHS has dimension {rhs_dim}"
                    )
        # A PROVABLE inconsistency inside the expression tree is an ERROR — it
        # used to be filed as a "could not validate" warning, which meant a
        # detected mismatch could never fail validation.
        except DimensionalMismatchError as e:
            result.errors.append(f"Equation {equation_id}: {e}")
        # PintError means we could not PARSE/convert a unit — genuinely
        # indeterminate, so a warning. Nothing broader is caught here: a bare
        # ValueError/AssertionError is a bug and must propagate rather than be
        # silently downgraded (this is exactly how C5 hid for so long).
        except pint.PintError as e:
            result.warnings.append(f"Could not validate dimensions for equation {equation_id}: {e}")

        result.is_valid = len(result.errors) == 0
        return result

    def validate_expression(self, expr: Expr, context: str = "") -> UnitValidationResult:
        """
        Validate dimensional consistency of an expression.

        Note:
            Bare variable names in ``expr`` are resolved against
            ``self.known_units``, which is populated as a side effect of a
            prior :meth:`validate_model` / :meth:`validate_reaction_system`
            call (each seeds it with that component's declared variable/species/
            parameter units, scoped per component). Called standalone on a fresh
            :class:`UnitValidator`, ``known_units`` is empty, so every bare-name
            operand resolves to "unknown dimension" and the check passes
            vacuously. Validate the enclosing model/reaction system (or invoke
            :func:`validate_units`) to get a meaningful result.

        Args:
            expr: The expression to validate
            context: Context string for error reporting

        Returns:
            UnitValidationResult for the expression
        """
        result = UnitValidationResult(is_valid=True)

        try:
            dimension = self._get_expression_dimension(expr)
            if dimension is not None:
                result.dimensional_analysis[context] = str(dimension)
        # A provable inconsistency is an error; an unparseable unit is only a
        # warning (see validate_equation). Nothing broader is caught, so a real
        # bug propagates instead of masquerading as a unit finding.
        except DimensionalMismatchError as e:
            result.errors.append(f"Expression validation failed for {context}: {e}")
        except pint.PintError as e:
            result.warnings.append(f"Could not validate dimensions for {context}: {e}")

        result.is_valid = len(result.errors) == 0
        return result

    def convert_units(self, value: float, from_unit: str, to_unit: str) -> UnitConversionResult:
        """
        Convert a value from one unit to another.

        Args:
            value: The numeric value to convert
            from_unit: Source unit string
            to_unit: Target unit string

        Returns:
            UnitConversionResult with converted value or error information
        """
        try:
            from_quantity = self.ureg.Quantity(value, from_unit)
            to_quantity = from_quantity.to(to_unit)

            return UnitConversionResult(
                success=True,
                converted_value=float(to_quantity.magnitude),
                conversion_factor=float(to_quantity.magnitude) / value if value != 0 else None,
            )
        except pint.PintError as e:
            return UnitConversionResult(success=False, error_message=str(e))

    def _get_expression_dimension(self, expr: Expr) -> UnitsContainer | None:
        """Get the dimensional analysis of an expression.

        ``None`` means "indeterminate" — it does NOT mean dimensionless.

        A bare NUMERIC LITERAL is dimension-POLYMORPHIC: it adopts whatever
        dimension its context requires, so it is reported as indeterminate and
        never constrains (nor contradicts) its neighbours. This is the contract
        the shared corpus pins, not a convenience:

          * ``tests/valid/minimal_chemistry.esm`` writes the Arrhenius rate as
            ``1.8e-12 * exp(-1370 / T) * M`` — the literal ``-1370`` is an
            activation TEMPERATURE, so ``-1370 / T`` is dimensionless only if
            the literal carries kelvin.
          * ``tests/valid/units_conversions.esm`` writes ``T_kelvin + (-273.15)``
            — the literal ``-273.15`` is a temperature.

        Typing a literal as ``dimensionless`` would report both of those
        (VALID) fixtures as dimensionally inconsistent. Treating it as
        indeterminate keeps every pinned ``units_*`` INVALID fixture rejected,
        because each of those states its inconsistency between two DECLARED
        quantities, never against a literal.
        """
        if isinstance(expr, bool):
            # A boolean is a genuine dimensionless truth value, not a
            # polymorphic numeric literal (bool is an int subclass in Python).
            return self.ureg.dimensionless.dimensionality

        if isinstance(expr, (int, float)):
            return None

        if isinstance(expr, str):
            # Variable lookup
            if expr in self.known_units:
                return self.known_units[expr].dimensionality
            # Undeclared symbol: unknown dimension, so it is skipped rather
            # than assumed dimensionless.
            return None

        if isinstance(expr, ExprNode):
            return self._get_expr_node_dimension(expr)

        return None

    @property
    def _dimensionless(self) -> UnitsContainer:
        return self.ureg.dimensionless.dimensionality

    def _agree(self, dims: list[UnitsContainer | None], op: str) -> UnitsContainer | None:
        """Require every KNOWN dimension in ``dims`` to be the same, and return
        it (or ``None`` if every operand's dimension is unknown).

        Unknown (``None``) operands are skipped rather than treated as
        dimensionless: an operand we cannot type must never manufacture a
        mismatch. Two *known* operands that disagree are a provable
        inconsistency.
        """
        known = [d for d in dims if d is not None]
        if not known:
            return None
        first = known[0]
        for dim in known[1:]:
            if not self._dimensions_compatible(first, dim):
                raise DimensionalMismatchError(
                    f"Incompatible dimensions in {op}: {first} vs {dim}"
                )
        return first

    def _require_dimensionless(self, dim: UnitsContainer | None, op: str, what: str) -> None:
        """Raise if ``dim`` is known and is NOT dimensionless."""
        if dim is not None and not self._dimensions_compatible(dim, self._dimensionless):
            raise DimensionalMismatchError(f"{op} {what} must be dimensionless, got {dim}")

    def _get_expr_node_dimension(self, node: ExprNode) -> UnitsContainer | None:
        """Get the dimension of an expression node (an operator with arguments).

        Returns ``None`` for "indeterminate" — an unknown operand, or an
        operator with no dimensional rule. ``None`` NEVER means dimensionless;
        callers skip the check entirely when they see it.

        Raises :class:`DimensionalMismatchError` on a provable inconsistency.
        """
        if not node.args:
            return None

        op = node.op
        arg_dims = [self._get_expression_dimension(arg) for arg in node.args]

        # n-ary dimension-preserving ops: every operand must agree.
        if op in _DIM_PRESERVING_NARY:
            return self._agree(arg_dims, op)

        # Unary carry-through ops.
        if op in _DIM_PRESERVING_UNARY:
            return arg_dims[0]

        if op in _DIMENSIONLESS_RESULT_OPS:
            return self._dimensionless

        if op in _COMPARISON_OPS:
            # Operands must be comparable; the boolean result is dimensionless.
            self._agree(arg_dims, op)
            return self._dimensionless

        if op in _DIMENSIONLESS_ARG_FUNCS:
            self._require_dimensionless(arg_dims[0], op, "argument")
            return self._dimensionless

        if op == "atan2":
            # atan2(y, x): both operands share a dimension; the angle is
            # dimensionless.
            self._agree(arg_dims, op)
            return self._dimensionless

        if op == "sqrt":
            base = arg_dims[0]
            return None if base is None else base ** 0.5

        if op == "ifelse":
            # ifelse(cond, then, else): the condition is a dimensionless
            # boolean; the two branches must agree and give the result.
            if len(arg_dims) < 3:
                return None
            return self._agree(arg_dims[1:3], op)

        if op == "*":
            # A single unknown operand makes the whole product unknown —
            # folding only the KNOWN operands would report `unknown * t` as
            # [time], which is not the dimension of anything.
            if any(d is None for d in arg_dims):
                return None
            result = self._dimensionless
            for dim in arg_dims:
                result = result * dim
            return result

        if op == "/":
            # POSITIONAL: numerator is args[0], every later operand divides it.
            # (The former code filtered None out of the operand list and then
            # indexed it positionally, so `unknown / t` reported [time] — the
            # exact inverse of the right answer.)
            if any(d is None for d in arg_dims):
                return None
            result = arg_dims[0]
            for dim in arg_dims[1:]:
                result = result / dim
            return result

        if op == "^":
            base = arg_dims[0]
            exp_dim = arg_dims[1] if len(arg_dims) > 1 else None
            # An exponent must always be dimensionless, whatever the base is.
            self._require_dimensionless(exp_dim, op, "exponent")
            if base is None:
                return None
            if self._dimensions_compatible(base, self._dimensionless):
                return self._dimensionless
            # A dimensional base needs a literal exponent to give a dimension.
            if len(node.args) > 1 and isinstance(node.args[1], (int, float)) and not isinstance(
                node.args[1], bool
            ):
                return base ** node.args[1]
            return None

        if op == "D":
            # d(f)/d(wrt) has dimension dim(f) / dim(wrt). `wrt` is a sidecar
            # field, not an arg, and is often an undeclared time symbol — in
            # which case the dimension is indeterminate. Never assume seconds.
            wrt = getattr(node, "wrt", None)
            if arg_dims[0] is None or not wrt or wrt not in self.known_units:
                return None
            return arg_dims[0] / self.known_units[wrt].dimensionality

        # Structural / array / query / rewrite-target ops (index, aggregate,
        # fn, const, makearray, table_lookup, grad, ...) carry no dimensional
        # rule here. Report UNKNOWN, not dimensionless.
        return None

    def _dimensions_compatible(self, dim1: UnitsContainer, dim2: UnitsContainer) -> bool:
        """Check whether two DIMENSIONALITY containers denote the same dimension.

        ``dim1``/``dim2`` are pint *dimensionality* containers (e.g.
        ``[length]``), not units. The previous implementation built
        ``ureg.Quantity(1.0, dim1)`` from one and called ``q1.to(q2.units)``,
        which trips pint's ``assert len(names) == 1`` in ``_is_multiplicative``
        and raises a bare ``AssertionError`` for EVERY bracketed dimension —
        which the handler then swallowed, so the function returned ``True`` for
        every input pair and the whole dimensional check was dead code.

        Comparing the containers directly is both correct and total (it is the
        same test ``structural_checks._units_compatible`` already uses), so
        there is no exception path left to swallow a logic error.
        """
        return dim1 == dim2

    def _validate_reaction(self, reaction) -> UnitValidationResult:
        """Validate unit consistency in a single reaction."""
        result = UnitValidationResult(is_valid=True)

        # Check that rate constant has appropriate units
        if hasattr(reaction, "rate_constant") and reaction.rate_constant:
            if isinstance(reaction.rate_constant, (int, float, str)):
                # For now, just warn if no units specified
                result.warnings.append(
                    f"Reaction {reaction.name}: Rate constant has no explicit units"
                )
            elif isinstance(reaction.rate_constant, ExprNode):
                # Validate the rate constant expression
                expr_result = self.validate_expression(
                    reaction.rate_constant, f"rate_constant_{reaction.name}"
                )
                result.errors.extend(expr_result.errors)
                result.warnings.extend(expr_result.warnings)

        result.is_valid = len(result.errors) == 0
        return result


def validate_units(target: EsmFile | Model | ReactionSystem) -> UnitValidationResult:
    """
    Convenience function to validate units of an ESM structure.

    Args:
        target: The ESM file, model, or reaction system to validate

    Returns:
        UnitValidationResult with validation status and issues
    """
    validator = UnitValidator()

    if isinstance(target, EsmFile):
        return validator.validate_esm_file(target)
    if isinstance(target, Model):
        return validator.validate_model(target)
    if isinstance(target, ReactionSystem):
        return validator.validate_reaction_system(target)
    raise ValueError(f"Unsupported type for unit validation: {type(target)}")


def convert_units(value: float, from_unit: str, to_unit: str) -> UnitConversionResult:
    """
    Convenience function to convert units.

    Args:
        value: Numeric value to convert
        from_unit: Source unit string
        to_unit: Target unit string

    Returns:
        UnitConversionResult with conversion result
    """
    validator = UnitValidator()
    return validator.convert_units(value, from_unit, to_unit)
