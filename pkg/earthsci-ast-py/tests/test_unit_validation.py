"""
Test fixtures for unit validation, dimensional consistency, and unit operations.

This module provides comprehensive tests for:
- Unit conversion between compatible units
- Dimensional analysis for mathematical operations
- Unit compatibility checking
- Error cases for incompatible units
- Mathematical operations with units
- Coupling scenarios with dimensional consistency
"""

import json

import pytest
from conftest import CORPUS_UNIT_DEFECTS, VALID_DIR
from pint import UnitRegistry, DimensionalityError
from earthsci_ast import load
from earthsci_ast.validation import validate
from earthsci_ast.esm_types import (
    ModelVariable,
    Parameter,
    Species,
    Model,
    ReactionSystem,
    Reaction,
    Equation,
    ExprNode,
)
from earthsci_ast.units import (
    UnitValidator,
    UnitValidationResult,
    DimensionalMismatchError,
)


# Initialize unit registry for testing
ureg = UnitRegistry()
Q_ = ureg.Quantity


class TestUnitConversion:
    """Test unit conversion operations."""

    def test_basic_unit_conversion(self):
        """Test basic unit conversions within the same dimension."""
        # Length conversions
        assert Q_(1, "meter").to("centimeter").magnitude == 100
        assert Q_(1000, "meter").to("kilometer").magnitude == 1
        assert Q_(1, "inch").to("centimeter").magnitude == pytest.approx(2.54)

        # Mass conversions
        assert Q_(1, "kilogram").to("gram").magnitude == 1000
        assert Q_(1, "pound").to("kilogram").magnitude == pytest.approx(0.453592)

        # Time conversions
        assert Q_(1, "hour").to("second").magnitude == 3600
        assert Q_(1, "day").to("hour").magnitude == 24

    def test_temperature_conversion(self):
        """Test temperature conversions including offset units."""
        # Celsius to Kelvin
        temp_c = Q_(0, "celsius")
        temp_k = temp_c.to("kelvin")
        assert temp_k.magnitude == pytest.approx(273.15)

        # Fahrenheit to Celsius
        temp_f = Q_(32, "fahrenheit")
        temp_c = temp_f.to("celsius")
        assert temp_c.magnitude == pytest.approx(0.0)

    def test_compound_unit_conversion(self):
        """Test conversions of compound units."""
        # Velocity
        velocity = Q_(1, "meter/second")
        assert velocity.to("kilometer/hour").magnitude == pytest.approx(3.6)

        # Acceleration
        accel = Q_(1, "meter/second**2")
        assert accel.to("kilometer/hour**2").magnitude == pytest.approx(12960)

        # Concentration
        conc = Q_(1, "gram/liter")
        assert conc.to("kilogram/meter**3").magnitude == pytest.approx(1.0)


class TestDimensionalAnalysis:
    """Test dimensional analysis for mathematical operations."""

    def test_addition_subtraction_dimensional_consistency(self):
        """Test that addition/subtraction requires same dimensions."""
        # Valid operations - same dimensions
        a = Q_(1, "meter")
        b = Q_(100, "centimeter")
        result = a + b
        assert result.magnitude == pytest.approx(2.0)
        assert str(result.units) == "meter"

        # Invalid operations - different dimensions
        length = Q_(1, "meter")
        mass = Q_(1, "kilogram")

        with pytest.raises(DimensionalityError):
            length + mass

        with pytest.raises(DimensionalityError):
            length - mass

    def test_multiplication_division_dimensional_combination(self):
        """Test dimensional combination in multiplication/division."""
        # Multiplication combines dimensions
        length = Q_(5, "meter")
        width = Q_(3, "meter")
        area = length * width
        assert area.magnitude == 15
        assert str(area.dimensionality) == "[length] ** 2"

        # Division creates derived dimensions
        distance = Q_(100, "meter")
        time = Q_(10, "second")
        velocity = distance / time
        assert velocity.magnitude == 10
        assert str(velocity.dimensionality) == "[length] / [time]"

    def test_power_operations_dimensional_scaling(self):
        """Test dimensional behavior with power operations."""
        length = Q_(2, "meter")

        # Square
        area = length**2
        assert area.magnitude == 4
        assert str(area.dimensionality) == "[length] ** 2"

        # Cube
        volume = length**3
        assert volume.magnitude == 8
        assert str(volume.dimensionality) == "[length] ** 3"

        # Square root
        side = Q_(4, "meter**2") ** 0.5
        assert side.magnitude == 2
        assert str(side.dimensionality) == "[length]"


class TestUnitCompatibility:
    """Test unit compatibility checking."""

    def test_compatible_units_identification(self):
        """Test identification of compatible units."""
        # Same base dimensions should be compatible
        assert Q_(1, "meter").check("[length]")
        assert Q_(1, "kilogram").check("[mass]")
        assert Q_(1, "second").check("[time]")

        # Compound units
        assert Q_(1, "meter/second").check("[length]/[time]")
        assert Q_(1, "kilogram/meter**3").check("[mass]/[length]**3")

    def test_incompatible_units_detection(self):
        """Test detection of incompatible units."""
        length = Q_(1, "meter")
        mass = Q_(1, "kilogram")

        # Different base dimensions are incompatible
        assert not length.check("[mass]")
        assert not mass.check("[length]")

        # Compound dimension mismatch
        velocity = Q_(1, "meter/second")
        assert not velocity.check("[mass]")
        assert not velocity.check("[length]**2")

    def test_dimensionless_compatibility(self):
        """Test dimensionless quantity compatibility."""
        # Pure numbers are dimensionless
        ratio = Q_(1.5, "dimensionless")
        assert ratio.check("[]")

        # Ratios of same dimensions are dimensionless
        length_ratio = Q_(2, "meter") / Q_(1, "meter")
        assert length_ratio.check("[]")


class TestUnitValidationErrors:
    """Test error cases for incompatible unit operations."""

    def test_addition_incompatible_units(self):
        """Test error handling for adding incompatible units."""
        test_cases = [
            (Q_(1, "meter"), Q_(1, "kilogram")),  # length + mass
            (Q_(1, "second"), Q_(1, "kelvin")),  # time + temperature
            (Q_(1, "meter/second"), Q_(1, "kilogram")),  # velocity + mass
        ]

        for a, b in test_cases:
            with pytest.raises(DimensionalityError):
                a + b

    def test_unit_assignment_validation(self):
        """Test validation when assigning units to model variables."""
        # Valid unit assignments
        valid_vars = [
            ModelVariable(type="state", units="kg/m**3"),
            ModelVariable(type="parameter", units="1/second"),
            ModelVariable(type="observed", units="kelvin"),
        ]

        for var in valid_vars:
            # Should not raise exception when parsing with pint
            if var.units:
                Q_(1, var.units)

    def test_invalid_unit_string_handling(self):
        """Test handling of invalid unit strings."""
        invalid_units = [
            "invalid_unit",
            "kg/invalid",
            "meter**invalid",
            "",
        ]

        for unit_str in invalid_units:
            if unit_str:  # Skip empty string
                with pytest.raises((Exception, ValueError)):
                    Q_(1, unit_str)


class TestMathematicalOperationsWithUnits:
    """Test mathematical operations preserving dimensional consistency."""

    def test_kinematic_equations(self):
        """Test kinematic equations with proper dimensional analysis."""
        # v = v0 + a*t
        v0 = Q_(10, "meter/second")
        a = Q_(2, "meter/second**2")
        t = Q_(5, "second")

        v = v0 + a * t
        assert v.magnitude == 20
        assert str(v.dimensionality) == "[length] / [time]"

    def test_chemical_reaction_rate_units(self):
        """Test units in chemical reaction rate calculations."""
        # First order reaction: rate = k * [A]
        k = Q_(0.1, "1/second")  # first order rate constant
        concentration = Q_(2.0, "mol/liter")

        rate = k * concentration
        assert rate.magnitude == pytest.approx(0.2)
        assert str(rate.dimensionality) == "[substance] / [time] / [length] ** 3"

    def test_thermodynamic_calculations(self):
        """Test units in thermodynamic calculations."""
        # Ideal gas law: PV = nRT
        n = Q_(1, "mole")  # amount of substance
        R = Q_(8.314, "joule/(mole*kelvin)")  # gas constant
        T = Q_(300, "kelvin")  # temperature
        V = Q_(0.025, "meter**3")  # volume

        P = (n * R * T) / V
        assert P.magnitude == pytest.approx(99768)
        assert str(P.dimensionality) == "[mass] / [length] / [time] ** 2"


class TestCouplingDimensionalConsistency:
    """Test dimensional consistency in model coupling scenarios."""

    def test_atmosphere_ocean_coupling(self):
        """Test dimensional consistency in atmosphere-ocean coupling."""
        # Atmospheric model outputs wind stress [Pa = N/m^2 = kg/(m*s^2)]
        wind_stress = Q_(0.1, "pascal")

        # Ocean model needs surface stress in same units
        # Should be able to convert without issues
        surface_stress = wind_stress.to("newton/meter**2")
        assert surface_stress.magnitude == pytest.approx(0.1)

    def test_chemistry_transport_coupling(self):
        """Test dimensional consistency in chemistry-transport coupling."""
        # Chemistry model outputs reaction rates [mol/(L*s)]
        reaction_rate = Q_(1e-6, "mol/(liter*second)")

        # Transport model needs rates in [mol/(m^3*s)]
        transport_rate = reaction_rate.to("mol/(meter**3*second)")
        assert transport_rate.magnitude == pytest.approx(1e-3)

    def test_energy_balance_coupling(self):
        """Test energy balance coupling between components."""
        # Solar radiation input [W/m^2]
        solar_flux = Q_(1000, "watt/meter**2")

        # Heat flux to surface should have same dimensions
        heat_flux = solar_flux * Q_(0.8, "dimensionless")  # albedo factor
        assert heat_flux.magnitude == 800
        assert str(heat_flux.dimensionality) == "[mass] / [time] ** 3"


class TestModelVariableUnitValidation:
    """Test unit validation for ESM format model variables."""

    def test_valid_atmospheric_variables(self):
        """Test valid atmospheric model variables with units."""
        variables = [
            ModelVariable(type="state", units="pascal", description="Pressure"),
            ModelVariable(type="state", units="kelvin", description="Temperature"),
            ModelVariable(type="state", units="kg/kg", description="Specific humidity"),
            ModelVariable(type="state", units="meter/second", description="Wind velocity"),
            ModelVariable(
                type="parameter", units="joule/(kilogram*kelvin)", description="Specific heat"
            ),
        ]

        for var in variables:
            # Validate units can be parsed by pint
            if var.units:
                quantity = Q_(1.0, var.units)
                assert quantity is not None

    def test_valid_oceanic_variables(self):
        """Test valid oceanic model variables with units."""
        variables = [
            ModelVariable(type="state", units="kg/meter**3", description="Density"),
            ModelVariable(type="state", units="meter/second", description="Current velocity"),
            ModelVariable(type="state", units="celsius", description="Temperature"),
            ModelVariable(type="state", units="gram/kilogram", description="Salinity"),
            ModelVariable(type="parameter", units="meter**2/second", description="Diffusivity"),
        ]

        for var in variables:
            if var.units:
                quantity = Q_(1.0, var.units)
                assert quantity is not None

    def test_valid_chemical_species_variables(self):
        """Test valid chemical species variables with units."""
        species_list = [
            Species(name="CO2", formula="CO2", default=44.01, units="gram/mole"),
            Species(name="O3", formula="O3", default=48.0, units="gram/mole"),
            Species(name="H2O", formula="H2O", default=18.01, units="gram/mole"),
        ]

        for species in species_list:
            if species.units and species.default is not None:
                quantity = Q_(species.default, species.units)
                assert quantity is not None


class TestParameterUnitValidation:
    """Test unit validation for reaction and model parameters."""

    def test_reaction_rate_constant_units(self):
        """Test units for different order reaction rate constants."""
        # Zero order: [concentration/time]
        k0 = Parameter(name="k0", value=1e-3, units="mol/(liter*second)")

        # First order: [1/time]
        k1 = Parameter(name="k1", value=0.1, units="1/second")

        # Second order: [1/(concentration*time)]
        k2 = Parameter(name="k2", value=1e6, units="liter/(mol*second)")

        for param in [k0, k1, k2]:
            if param.units:
                quantity = Q_(param.value, param.units)
                assert quantity is not None

    def test_physical_parameter_units(self):
        """Test units for physical parameters."""
        parameters = [
            Parameter(name="gravity", value=9.81, units="meter/second**2"),
            Parameter(name="gas_constant", value=8.314, units="joule/(mol*kelvin)"),
            Parameter(name="avogadro", value=6.022e23, units="1/mol"),
            Parameter(name="planck", value=6.626e-34, units="joule*second"),
        ]

        for param in parameters:
            quantity = Q_(param.value, param.units)
            assert quantity is not None


class TestUnitConsistencyInEquations:
    """Test unit consistency in mathematical equations."""

    def test_differential_equation_units(self):
        """Test unit consistency in differential equations."""
        # Example: dc/dt = k*c (first-order decay)
        # Units: [concentration/time] = [1/time] * [concentration]

        k = Q_(0.1, "1/second")
        c = Q_(1.0, "mol/liter")

        dcdt = k * c
        expected_units = "mol/(liter*second)"

        assert dcdt.to(expected_units).magnitude == pytest.approx(0.1)

    def test_mass_balance_equation_units(self):
        """Test unit consistency in mass balance equations."""
        # Mass balance: accumulation = input - output - consumption
        # All terms must have units of [mass/time] or [concentration*volume/time]

        accumulation = Q_(1.0, "kilogram/second")
        input_rate = Q_(2.0, "kilogram/second")
        output_rate = Q_(0.5, "kilogram/second")
        consumption = Q_(0.5, "kilogram/second")

        balance = input_rate - output_rate - consumption
        assert balance.magnitude == pytest.approx(accumulation.magnitude)
        assert balance.dimensionality == accumulation.dimensionality


class TestAdvancedUnitScenarios:
    """Test advanced unit validation scenarios."""

    def test_unit_propagation_through_expressions(self):
        """Test unit propagation through complex expressions."""
        # Expression: sqrt(2*g*h) for velocity from height
        g = Q_(9.81, "meter/second**2")
        h = Q_(10, "meter")

        # Calculate velocity
        v_squared = 2 * g * h
        v = v_squared**0.5

        assert str(v.dimensionality) == "[length] / [time]"
        assert v.magnitude == pytest.approx(14.007, rel=1e-2)

    def test_dimensionless_numbers(self):
        """Test handling of dimensionless numbers in calculations."""
        # Reynolds number: Re = ρvL/μ
        density = Q_(1000, "kilogram/meter**3")
        velocity = Q_(1, "meter/second")
        length = Q_(0.1, "meter")
        viscosity = Q_(1e-3, "pascal*second")

        reynolds = (density * velocity * length) / viscosity

        # Should be dimensionless
        assert reynolds.check("[]")
        assert reynolds.magnitude == pytest.approx(1e5)

    def test_unit_conversion_in_coupled_models(self):
        """Test unit conversion requirements in model coupling."""
        # Atmospheric model outputs precipitation in mm/day
        precip_atm = Q_(5, "millimeter/day")

        # Hydrological model needs input in m/s
        precip_hydro = precip_atm.to("meter/second")

        assert precip_hydro.magnitude == pytest.approx(5.787e-8)
        assert str(precip_hydro.dimensionality) == "[length] / [time]"


# Integration test combining multiple unit validation aspects
class TestIntegratedUnitValidation:
    """Integration tests combining multiple aspects of unit validation."""

    def test_complete_model_unit_validation(self):
        """Test unit validation across a complete model definition."""
        # Create a simple atmospheric chemistry model
        model = Model(name="SimpleAtmChem")

        # Add variables with units
        model.variables["temperature"] = ModelVariable(
            type="state", units="kelvin", description="Air temperature"
        )
        model.variables["pressure"] = ModelVariable(
            type="state", units="pascal", description="Air pressure"
        )
        model.variables["ozone"] = ModelVariable(
            type="state", units="mol/meter**3", description="Ozone concentration"
        )

        # Validate all units can be parsed
        for name, var in model.variables.items():
            if var.units:
                quantity = Q_(1.0, var.units)
                assert quantity is not None, f"Invalid units for {name}: {var.units}"

    def test_reaction_system_unit_consistency(self):
        """Test unit consistency across a reaction system."""
        # Create a simple reaction system
        system = ReactionSystem(name="SimpleReaction")

        # Add species with consistent units
        system.species.extend(
            [
                Species(name="A", default=30.0, units="gram/mole"),
                Species(name="B", default=45.0, units="gram/mole"),
                Species(name="C", default=75.0, units="gram/mole"),
            ]
        )

        # Add parameters with appropriate units
        system.parameters.extend(
            [
                Parameter(name="k_forward", value=1e-3, units="liter/(mol*second)"),
                Parameter(name="k_backward", value=1e-4, units="liter/(mol*second)"),
            ]
        )

        # Add reaction: A + B <-> C
        reaction = Reaction(
            name="formation",
            reactants={"A": 1, "B": 1},
            products={"C": 1},
            rate_constant=1e-3,  # Will use parameter units
        )
        system.reactions.append(reaction)

        # Validate unit consistency
        for species in system.species:
            if species.units and species.default is not None:
                mass_quantity = Q_(species.default, species.units)
                assert mass_quantity is not None

        for param in system.parameters:
            if param.units:
                param_quantity = Q_(param.value, param.units)
                assert param_quantity is not None


# Cross-binding units fixtures (gt-gtf): the three units_*.esm files in
# tests/valid/ are shared across Julia/Python/Rust/TypeScript/Go and exist
# specifically to drive cross-binding agreement on units handling. Wire them
# into the Python suite by loading each fixture through the public API and
# running the binding's UnitValidator on every model. The fixtures
# intentionally cover the union of binding unit-registry coverage, so this
# test asserts only that load and validation complete without raising.
UNITS_FIXTURE_NAMES = [
    "units_conversions.esm",
    "units_dimensional_analysis.esm",
    "units_propagation.esm",
]


@pytest.fixture
def units_fixtures_dir():
    return VALID_DIR


@pytest.mark.parametrize("fixture_name", UNITS_FIXTURE_NAMES)
class TestCrossBindingUnitsFixtures:
    def test_fixture_loads(self, units_fixtures_dir, fixture_name):
        if fixture_name in CORPUS_UNIT_DEFECTS:
            pytest.skip(f"{fixture_name}: {CORPUS_UNIT_DEFECTS[fixture_name]}")
        path = units_fixtures_dir / fixture_name
        assert path.is_file(), f"missing fixture {path}"
        esm = load(path.read_text())
        assert esm.models, f"{fixture_name}: no models loaded"

    def test_unit_validator_runs(self, units_fixtures_dir, fixture_name):
        if fixture_name in CORPUS_UNIT_DEFECTS:
            pytest.skip(f"{fixture_name}: {CORPUS_UNIT_DEFECTS[fixture_name]}")
        path = units_fixtures_dir / fixture_name
        esm = load(path.read_text())
        validator = UnitValidator()
        result = validator.validate_esm_file(esm)
        assert isinstance(result, UnitValidationResult)
        for model in esm.models.values():
            model_result = validator.validate_model(model)
            assert isinstance(model_result, UnitValidationResult)


class TestEsmSpecificUnitsStandard:
    """Cross-binding ESM units standard (docs/units-standard.md).

    Uses the package's own registry so these tests exercise the definitions
    added in ``earthsci_ast.units`` rather than a vanilla pint registry.
    """

    def setup_method(self):
        from earthsci_ast.units import ureg as pkg_ureg

        self.ureg = pkg_ureg

    def test_mole_fraction_family_is_dimensionless(self):
        dimensionless = self.ureg.dimensionless.dimensionality
        for name, factor in [
            ("ppm", 1e-6),
            ("ppmv", 1e-6),
            ("ppb", 1e-9),
            ("ppbv", 1e-9),
            ("ppt", 1e-12),
            ("pptv", 1e-12),
        ]:
            q = self.ureg.Quantity(1.0, name)
            assert q.dimensionality == dimensionless, (
                f"{name} must be dimensionless per ESM standard"
            )
            # Scale factor must match the canonical doc exactly.
            assert q.to("dimensionless").magnitude == pytest.approx(factor)

    def test_mol_per_mol_is_dimensionless(self):
        q = self.ureg.Quantity(1.0, "mol/mol")
        assert q.dimensionality == self.ureg.dimensionless.dimensionality

    def test_volume_mixing_ratio_aliases_match_mole_fraction(self):
        # `ppmv`/`ppbv`/`pptv` must be interchangeable with `ppm`/`ppb`/`ppt`
        # — otherwise cross-binding docs emit spurious unit mismatches.
        assert self.ureg.Quantity(1.0, "ppmv").to("ppm").magnitude == pytest.approx(1.0)
        assert self.ureg.Quantity(1.0, "ppbv").to("ppb").magnitude == pytest.approx(1.0)
        assert self.ureg.Quantity(1.0, "pptv").to("ppt").magnitude == pytest.approx(1.0)

    def test_dobson_is_areal_number_density(self):
        # Standard: 1 Dobson = 2.6867e20 molec/m^2 = 2.6867e16 molec/cm^2, with
        # dimension [length]^-2 — NOT dimensionless, and NOT [substance]/area:
        # `molec` is a dimensionless COUNT atom, so an areal molecule density is
        # a pure inverse area (units-standard.md §"Dobson unit").
        dobson = self.ureg.Quantity(1.0, "Dobson")
        assert dobson.dimensionality == self.ureg.Quantity(1.0, "1/m**2").dimensionality
        assert dobson.to("1 / cm**2").magnitude == pytest.approx(2.6867e16, rel=1e-6)
        assert self.ureg.Quantity(1.0, "DU").to("Dobson").magnitude == pytest.approx(1.0)

    def test_molec_is_a_dimensionless_count(self):
        # `molec` is a dimensionless count atom, so `molec/cm^3` (number density)
        # is [length]^-3 (units-standard.md §"Molecule count atom").
        #
        # Vanilla pint disagrees: it aliases `molec` to `particle` (= 1/N_A mol),
        # giving `molec/cm^3` a [substance]/[length]^3 dimension. The ESM registry
        # overrides that, otherwise Python alone would type every atmospheric
        # number density differently from Go/TS/Rust/Julia.
        dimensionless = self.ureg.dimensionless.dimensionality
        assert self.ureg.Quantity(1.0, "molec").dimensionality == dimensionless
        assert (
            self.ureg.Quantity(1.0, "molec / cm**3").dimensionality
            == self.ureg.Quantity(1.0, "1 / cm**3").dimensionality
        )
        assert (
            self.ureg.Quantity(1.0, "cm**3 / molec / s").dimensionality
            == self.ureg.Quantity(1.0, "cm**3 / s").dimensionality
        )

    def test_count_nouns_are_dimensionless(self):
        # Counts of discrete things carry no physical dimension. `units` is the
        # trap: pint has no unit by that name, so its SI-prefix mechanism reads it
        # as `u` + `nit` = MICRO-NIT, a LUMINANCE — which silently gave the
        # corpus's clinical `units/L` and `units/s` a [luminosity] dimension.
        dimensionless = self.ureg.dimensionless.dimensionality
        for name in ("molec", "individuals", "vehicles", "units", "count"):
            assert self.ureg.Quantity(1.0, name).dimensionality == dimensionless, (
                f"{name} must be a dimensionless count noun"
            )
        assert (
            self.ureg.Quantity(1.0, "units / L").dimensionality
            == self.ureg.Quantity(1.0, "1 / L").dimensionality
        )

    def test_contract_spellings_absent_from_vanilla_pint(self):
        # Symbols the shared contract requires that a bare pint registry lacks.
        assert self.ureg.Quantity(1.0, "Ohm").dimensionality == (
            self.ureg.Quantity(1.0, "ohm").dimensionality
        )
        assert self.ureg.Quantity(1.0, "Torr").to("Pa").magnitude == pytest.approx(133.322, rel=1e-4)
        assert self.ureg.Quantity(1.0, "individuals / km**2").dimensionality == (
            self.ureg.Quantity(1.0, "1 / km**2").dimensionality
        )


class TestUnparseableUnitIsAnError:
    """An unparseable unit is a HARD ERROR, not a warning.

    The severity follows from what the finding MEANS. A unit string that does
    not denote a real unit ("not_a_unit", "1/time") is a defect in the FILE —
    the declaration is simply false. That is categorically different from "I
    cannot determine this dimension" (a symbolic exponent, an op with no
    dimensional rule, an undeclared variable), which is a statement about the
    CHECKER and stays a warning.

    This suite previously asserted the opposite (``TestUnparseableUnitLeniency``:
    "is_valid is True"), which let a document name a unit that does not exist
    and still be pronounced valid.
    """

    def test_variable_unparseable_unit_is_an_error(self):
        model = Model(name="BadUnits")
        # A syntactically valid identifier that is not a unit.
        model.variables["bad"] = ModelVariable(
            type="state", units="not_a_real_unit_zzz"
        )
        model.variables["good"] = ModelVariable(type="state", units="kelvin")

        validator = UnitValidator()
        result = validator.validate_model(model)

        assert result.is_valid is False
        assert any("Invalid unit" in e and "bad" in e for e in result.errors)

        # The bad variable is still omitted from the known-units registry, so it
        # propagates as an UNKNOWN dimension and cannot also manufacture spurious
        # downstream mismatches — one bad string, one finding.
        assert "bad" not in result.unit_registry
        assert "good" in result.unit_registry

    def test_unparseable_unit_does_not_also_manufacture_a_mismatch(self):
        model = Model(name="BadUnitsEq")
        model.variables["bad"] = ModelVariable(
            type="state", units="not_a_real_unit_zzz"
        )
        model.variables["good"] = ModelVariable(type="observed", units="kelvin")
        # good = bad : `bad` resolves to an unknown dimension (omitted from
        # known_units), so the ONLY finding must be the unparseable unit itself.
        model.equations.append(Equation(lhs="good", rhs="bad"))

        validator = UnitValidator()
        result = validator.validate_model(model)

        assert result.is_valid is False
        assert len(result.errors) == 1
        assert "Invalid unit" in result.errors[0]
        assert not any("mismatch" in e.lower() for e in result.errors)

    def test_unparseable_unit_fails_structural_validation(self):
        """The hard error reaches `load()` / `validate()`, at a JSON-Pointer path."""
        doc = {
            "esm": "0.8.0",
            "metadata": {"name": "BadUnits"},
            "models": {
                "M": {
                    "variables": {
                        "c": {"type": "state", "units": "not_a_unit", "default": 1.0},
                        "k": {"type": "parameter", "units": "1/s", "default": 0.5},
                    },
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                            "rhs": {"op": "*", "args": [{"op": "-", "args": ["k"]}, "c"]},
                        }
                    ],
                }
            },
        }
        result = validate(json.dumps(doc))
        assert result.is_valid is False
        offenders = [
            e
            for e in result.structural_errors
            if e.code == "unit_inconsistency" and e.path == "/models/M/variables/c/units"
        ]
        assert offenders, f"expected an unparseable-unit error, got {result.structural_errors}"
        assert "not_a_unit" in offenders[0].message

    def test_real_units_still_validate(self):
        """The count nouns and ESM units the contract defines must NOT be rejected."""
        for unit in (
            "molec/cm^3",
            "ppb",
            "ppb^-1 s^-1",
            "individuals/km^2",
            "vehicles/km^2",
            "units/L",
            "Dobson",
            "Torr",
            "degC/min",  # offset unit in a compound — pint's Quantity path rejects this
            "μmol/(m^2*s)",
            "cm^3/molec/s",
        ):
            model = Model(name="Ok")
            model.variables["v"] = ModelVariable(type="state", units=unit)
            result = UnitValidator().validate_model(model)
            assert result.is_valid is True, f"{unit!r} must parse: {result.errors}"
            assert "v" in result.unit_registry


class TestDerivativeTimeUnitIsNotFabricated:
    """``d(x)/dt`` with an UNDECLARED ``t`` has an UNKNOWN time unit.

    The structural check used to assume seconds — ``(rhs * second) / lhs`` had to
    be dimensionless — which rejects an ordinary acceleration equation (``x`` in
    ``m``, RHS in ``m/s^2``). Under a hard-error policy that fabricated second is
    a false-rejection factory.

    The defensible rule (Go's ``derivativeTimeMismatch``): the time exponent is
    free, the NON-time dimensions are not.
    """

    def test_undeclared_t_leaves_the_time_exponent_free(self):
        from earthsci_ast.structural_checks import _is_derivative_compatible

        # Accepted: some time unit reconciles these (the ratio is a power of time).
        assert _is_derivative_compatible("m", "m/s") is True
        assert _is_derivative_compatible("m", "m/s^2") is True  # was falsely rejected
        assert _is_derivative_compatible("1", "1/s") is True

    def test_non_time_dimensions_still_cannot_move(self):
        from earthsci_ast.structural_checks import _is_derivative_compatible

        # Rejected: no choice of time unit turns a length into a mass.
        assert _is_derivative_compatible("m", "kg") is False
        assert _is_derivative_compatible("m/s", "kg") is False

    def test_declared_t_makes_the_comparison_exact(self):
        from earthsci_ast.structural_checks import _is_derivative_compatible

        assert _is_derivative_compatible("m", "m/s", "s") is True
        # With t declared, the time exponent is pinned too.
        assert _is_derivative_compatible("m", "m/s^2", "s") is False


class TestTranscendentalArgumentMustBeDimensionless:
    """The FULL mathematical rule, not just ``ln``/``exp``.

    A transcendental is a power series, so every term of ``1 + x + x^2/2 + …``
    must be addable — which forces ``x`` to be dimensionless. The structural
    check was previously narrowed to ``{ln, exp}`` to accommodate a
    self-contradictory corpus (see conftest.CORPUS_UNIT_DEFECTS).
    """

    @pytest.mark.parametrize(
        "op", ["ln", "log", "log10", "exp", "sin", "cos", "tan", "tanh", "asin", "acosh"]
    )
    def test_dimensional_argument_is_a_hard_error(self, op):
        doc = {
            "esm": "0.8.0",
            "metadata": {"name": "T"},
            "models": {
                "M": {
                    "variables": {
                        "L": {"type": "state", "units": "m", "default": 1.0},
                        "bad": {
                            "type": "observed",
                            "units": "1",
                            "expression": {"op": op, "args": ["L"]},
                        },
                    },
                    "equations": [
                        {"lhs": {"op": "D", "args": ["L"], "wrt": "t"}, "rhs": 0.0}
                    ],
                }
            },
        }
        result = validate(json.dumps(doc))
        assert result.is_valid is False, f"{op}(L) with L in metres must be rejected"
        offenders = [
            e
            for e in result.structural_errors
            if e.code == "unit_inconsistency" and e.path == "/models/M/variables/bad"
        ]
        assert offenders, f"{op}: expected a unit_inconsistency, got {result.structural_errors}"
        assert "dimensionless" in offenders[0].message

    def test_dimensionless_argument_is_accepted(self):
        doc = {
            "esm": "0.8.0",
            "metadata": {"name": "T"},
            "models": {
                "M": {
                    "variables": {
                        "L": {"type": "state", "units": "m", "default": 1.0},
                        "L0": {"type": "parameter", "units": "m", "default": 1.0},
                        # log of a RATIO — the physically meaningful form.
                        "ok": {
                            "type": "observed",
                            "units": "1",
                            "expression": {"op": "log", "args": [{"op": "/", "args": ["L", "L0"]}]},
                        },
                    },
                    "equations": [
                        {"lhs": {"op": "D", "args": ["L"], "wrt": "t"}, "rhs": 0.0}
                    ],
                }
            },
        }
        result = validate(json.dumps(doc))
        assert result.is_valid is True, result.structural_errors

    def test_sqrt_is_not_in_the_rule(self):
        """`sqrt` halves a dimension; it does not require a dimensionless argument."""
        doc = {
            "esm": "0.8.0",
            "metadata": {"name": "T"},
            "models": {
                "M": {
                    "variables": {
                        "A": {"type": "state", "units": "m^2", "default": 1.0},
                        "side": {
                            "type": "observed",
                            "units": "m",
                            "expression": {"op": "sqrt", "args": ["A"]},
                        },
                    },
                    "equations": [
                        {"lhs": {"op": "D", "args": ["A"], "wrt": "t"}, "rhs": 0.0}
                    ],
                }
            },
        }
        result = validate(json.dumps(doc))
        assert result.is_valid is True, result.structural_errors


def _validator_with(**units: str) -> UnitValidator:
    """A UnitValidator whose known_units are exactly ``units`` (name -> unit)."""
    validator = UnitValidator()
    validator.known_units = {
        name: validator.ureg.Unit(unit) for name, unit in units.items()
    }
    return validator


class TestDimensionalMismatchIsDetected:
    """TRUE POSITIVES for the dimensional engine.

    Every other unit test in this module asserts either that validation
    "completes without raising" or that a *false* positive is absent. That is
    precisely how the C5 keystone bug survived: ``_dimensions_compatible``
    built ``ureg.Quantity(1.0, dim)`` from a *dimensionality* container, which
    trips pint's ``assert len(names) == 1`` for every bracketed dimension; the
    bare ``AssertionError`` was then swallowed by ``except (PintError,
    AssertionError): return True``. The predicate therefore returned ``True``
    for *every* input pair, making the entire dimensional engine — including
    every ``raise`` in ``_get_expr_node_dimension`` — unreachable dead code.

    These tests assert the engine can actually FAIL. Without at least one true
    positive here, a regression to the always-``True`` predicate is invisible.
    """

    def test_dimensions_compatible_distinguishes_dimensions(self):
        """The C5 keystone: the predicate must discriminate, not rubber-stamp."""
        validator = UnitValidator()
        length = validator.ureg.Unit("m").dimensionality
        time = validator.ureg.Unit("s").dimensionality
        dimensionless = validator.ureg.dimensionless.dimensionality

        # Pre-fix this returned True — for these and for every other pair.
        assert validator._dimensions_compatible(length, time) is False
        assert validator._dimensions_compatible(length, dimensionless) is False
        # Same dimension via different units still compatible.
        assert (
            validator._dimensions_compatible(
                length, validator.ureg.Unit("km").dimensionality
            )
            is True
        )

    def test_adding_length_to_time_is_an_error(self):
        """The audit's exact C5 repro: `x[m] = x[m] + tt[s]`.

        Pre-fix this yielded ``is_valid=True, errors=[], warnings=[]`` — a
        provable dimensional contradiction reported as a clean bill of health.
        """
        model = Model(name="BadAddition")
        model.variables["x"] = ModelVariable(type="state", units="m")
        model.variables["tt"] = ModelVariable(type="parameter", units="s")
        model.equations.append(
            Equation(lhs="x", rhs=ExprNode(op="+", args=["x", "tt"]))
        )

        result = UnitValidator().validate_model(model)

        assert result.is_valid is False
        assert result.errors, "a provable [length] vs [time] mismatch must be an ERROR"
        assert any("Incompatible dimensions" in e for e in result.errors)

    def test_mismatch_is_an_error_not_a_warning(self):
        """A PROVABLE inconsistency must not be filed as a 'could not validate'
        warning — that downgrade is what made a detected mismatch unable to
        fail validation."""
        model = Model(name="ErrorNotWarning")
        model.variables["L"] = ModelVariable(type="state", units="m")
        model.variables["tt"] = ModelVariable(type="parameter", units="s")
        model.equations.append(
            Equation(lhs="L", rhs=ExprNode(op="-", args=["L", "tt"]))
        )

        result = UnitValidator().validate_model(model)

        assert len(result.errors) == 1
        assert result.warnings == []

    def test_transcendental_argument_must_be_dimensionless(self):
        """`sin(L)` with L in metres is a hard dimensional error.

        Pre-fix, the catch-all `return dimensionless` for every non-arithmetic
        op meant nothing ever checked that a transcendental's *argument* is
        dimensionless.
        """
        validator = _validator_with(L="m")
        with pytest.raises(DimensionalMismatchError, match="dimensionless"):
            validator._get_expression_dimension(ExprNode(op="sin", args=["L"]))

    def test_exponent_must_be_dimensionless(self):
        """`L^tt` (dimensional exponent) is a hard error; `L^2` is [length]**2."""
        validator = _validator_with(L="m", tt="s")
        with pytest.raises(DimensionalMismatchError, match="exponent"):
            validator._get_expression_dimension(ExprNode(op="^", args=["L", "tt"]))

        squared = validator._get_expression_dimension(ExprNode(op="^", args=["L", 2]))
        assert squared == validator.ureg.Unit("m**2").dimensionality


class TestOperatorDimensionRules:
    """The op rules that the old catch-all `return dimensionless` destroyed.

    These are the two bugs the audit predicted would surface the moment C5 was
    fixed: they were unobservable while the compatibility predicate said
    "everything matches everything".
    """

    def test_min_max_preserve_their_operands_dimension(self):
        """`max(P1, P2)` with both in Pa is a PRESSURE, not dimensionless.

        The old catch-all reported dimensionless, which (once C5 is fixed)
        would manufacture a mismatch against any pressure it was compared to.
        """
        validator = _validator_with(P1="Pa", P2="Pa")
        pressure = validator.ureg.Unit("Pa").dimensionality

        for op in ("max", "min"):
            dim = validator._get_expression_dimension(ExprNode(op=op, args=["P1", "P2"]))
            assert dim == pressure, f"{op} must preserve its operands' dimension"

    def test_min_max_operands_must_agree(self):
        validator = _validator_with(P="Pa", L="m")
        with pytest.raises(DimensionalMismatchError):
            validator._get_expression_dimension(ExprNode(op="max", args=["P", "L"]))

    def test_division_by_an_unknown_operand_is_indeterminate(self):
        """`unknown_x / t` must be UNKNOWN (None), never [time].

        The old code filtered `None` dimensions out of the operand list and
        then indexed `/` positionally as though nothing had been removed, so
        the numerator vanished and `t` became the numerator — reporting
        [time], the exact *inverse* of the only defensible answer.
        """
        validator = _validator_with(t="s")
        dim = validator._get_expression_dimension(
            ExprNode(op="/", args=["unknown_x", "t"])
        )
        assert dim is None

    def test_multiplication_by_an_unknown_operand_is_indeterminate(self):
        validator = _validator_with(t="s")
        dim = validator._get_expression_dimension(
            ExprNode(op="*", args=["unknown_x", "t"])
        )
        assert dim is None

    def test_known_division_still_divides(self):
        """The indeterminacy rule must not cost us the ordinary case."""
        validator = _validator_with(L="m", t="s")
        dim = validator._get_expression_dimension(ExprNode(op="/", args=["L", "t"]))
        assert dim == validator.ureg.Unit("m/s").dimensionality

    def test_abs_preserves_dimension(self):
        validator = _validator_with(L="m")
        dim = validator._get_expression_dimension(ExprNode(op="abs", args=["L"]))
        assert dim == validator.ureg.Unit("m").dimensionality

    def test_structural_ops_are_unknown_not_dimensionless(self):
        """An op with no dimensional rule reports UNKNOWN, so callers skip it.

        Reporting `dimensionless` (the old behaviour) manufactures *false*
        mismatches once the compatibility predicate actually discriminates.
        """
        validator = _validator_with(w="m")
        dim = validator._get_expression_dimension(
            ExprNode(op="table_lookup", args=["w"])
        )
        assert dim is None


class TestNumericLiteralsArePolymorphic:
    """A bare numeric literal must not constrain (nor contradict) its context.

    This is the contract the *valid* corpus pins, and it is what keeps the C5
    fix from rejecting pinned-VALID fixtures: `minimal_chemistry.esm` writes
    Arrhenius as `exp(-1370 / T)` (the literal is an activation TEMPERATURE)
    and `units_conversions.esm` writes `T_kelvin + (-273.15)`. Typing a literal
    as dimensionless would report both as dimensionally inconsistent.
    """

    def test_literal_added_to_a_dimensional_quantity_is_not_a_mismatch(self):
        validator = _validator_with(T_kelvin="kelvin")
        dim = validator._get_expression_dimension(
            ExprNode(op="+", args=["T_kelvin", -273.15])
        )
        assert dim == validator.ureg.Unit("kelvin").dimensionality

    def test_literal_over_dimensional_quantity_does_not_break_exp(self):
        """`exp(-1370 / T)` — the literal carries kelvin, so the quotient is
        dimensionless and `exp` must not raise."""
        validator = _validator_with(T="kelvin")
        dim = validator._get_expression_dimension(
            ExprNode(
                op="exp", args=[ExprNode(op="/", args=[-1370.0, "T"])]
            )
        )
        assert dim == validator.ureg.dimensionless.dimensionality

    def test_a_boolean_is_genuinely_dimensionless(self):
        """`bool` is an `int` subclass in Python, but a truth value is a real
        dimensionless quantity, not a polymorphic numeric literal."""
        validator = UnitValidator()
        dim = validator._get_expression_dimension(True)
        assert dim == validator.ureg.dimensionless.dimensionality
