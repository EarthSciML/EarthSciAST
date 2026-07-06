"""Tests for the coupled-system flattening implementation (spec §4.7.5)."""

import pytest

from earthsci_toolkit.flatten import (
    ConflictingDerivativeError,
    _namespace_expr,
    flatten,
)
from earthsci_toolkit.esm_types import (
    EsmFile,
    Metadata,
    Model,
    ModelVariable,
    Equation,
    ExprNode,
    ReactionSystem,
    Species,
    Parameter,
    Reaction,
    OperatorComposeCoupling,
    VariableMapCoupling,
)


def _make_metadata() -> Metadata:
    return Metadata(title="test")


def _empty_file(**kwargs) -> EsmFile:
    base = dict(version="0.1.0", metadata=_make_metadata())
    base.update(kwargs)
    return EsmFile(**base)


def test_flatten_empty_raises():
    file = _empty_file()
    with pytest.raises(ValueError):
        flatten(file)


def test_flatten_single_model_namespaces_variables():
    var_T = ModelVariable(type="state", units="K", default=300.0, description="Temperature")
    var_k = ModelVariable(type="parameter", default=0.1)
    eq = Equation(
        lhs=ExprNode(op="D", args=["T"], wrt="t"),
        rhs=ExprNode(op="*", args=["k", "T"]),
    )
    model = Model(name="Atmos", variables={"T": var_T, "k": var_k}, equations=[eq])

    file = _empty_file(models={"Atmos": model})

    flat = flatten(file)
    assert "Atmos.T" in flat.state_variables
    assert "Atmos.k" in flat.parameters
    assert flat.state_variables["Atmos.T"].units == "K"
    assert flat.metadata.source_systems == ["Atmos"]
    assert len(flat.equations) == 1
    eq0 = flat.equations[0]
    assert eq0.source_system == "Atmos"
    assert "Atmos.T" in eq0.lhs_str
    assert "Atmos.k" in eq0.rhs_str
    assert "Atmos.T" in eq0.rhs_str
    # The Expr tree is preserved.
    assert isinstance(eq0.lhs, ExprNode)
    assert eq0.lhs.op == "D"


def test_flatten_reaction_system_namespaces_species_and_params():
    species = Species(name="O3", units="mol/L", default=1e-6)
    param = Parameter(name="k1", value=0.1, units="1/s")
    rs = ReactionSystem(name="Chem", species=[species], parameters=[param])

    file = _empty_file(reaction_systems={"Chem": rs})

    flat = flatten(file)
    assert "Chem.O3" in flat.state_variables
    assert "Chem.k1" in flat.parameters
    assert flat.metadata.source_systems == ["Chem"]


def test_flatten_records_coupling_rules():
    var_x = ModelVariable(type="state")
    var_y = ModelVariable(type="parameter")
    model_a = Model(name="A", variables={"x": var_x})
    model_b = Model(name="B", variables={"y": var_y})

    coupling = VariableMapCoupling(
        from_var="A.x",
        to_var="B.y",
        transform="identity",
    )

    file = _empty_file(models={"A": model_a, "B": model_b}, coupling=[coupling])

    flat = flatten(file)
    assert any("variable_map" in r for r in flat.metadata.coupling_rules)


def test_flatten_recurses_into_subsystems():
    inner_var = ModelVariable(type="state")
    inner = Model(name="Inner", variables={"x": inner_var})
    outer_var = ModelVariable(type="state")
    outer = Model(name="Outer", variables={"y": outer_var}, subsystems={"Inner": inner})

    file = _empty_file(models={"Outer": outer})

    flat = flatten(file)
    assert "Outer.y" in flat.state_variables
    assert "Outer.Inner.x" in flat.state_variables


def test_namespace_expr_qualifies_subsystem_local_refs():
    """A reference rooted at a SUBSYSTEM KEY of the model being namespaced is
    subsystem-local and must be qualified with the owner; a genuinely absolute
    reference (head not a local subsystem) is left alone. Regression for the
    camp_fire 'Unresolved symbol raw.fuel_model'."""
    assert _namespace_expr("u", "M") == "M.u"  # bare -> prefixed
    assert _namespace_expr("Other.x", "M", subsystem_keys={"raw"}) == "Other.x"  # absolute
    assert (
        _namespace_expr("raw.fuel_model", "LANDFIRE", subsystem_keys={"raw"})
        == "LANDFIRE.raw.fuel_model"
    )  # subsystem-local -> qualified
    assert _namespace_expr("raw.fuel_model", "LANDFIRE") == "raw.fuel_model"  # legacy: no keys
    assert (
        _namespace_expr("t", "M", leave_alone={"t"}, subsystem_keys={"t"}) == "t"
    )  # leave_alone wins


def test_flatten_qualifies_subsystem_local_expression_refs():
    """An observed variable whose expression references a subsystem variable
    (`sub.v`) is qualified to `Outer.sub.v`, matching the lowered subsystem var —
    the pattern by which a model re-exposes a mounted data loader (LANDFIRE's
    `fuel_model = raw.fuel_model`)."""
    inner = Model(name="Inner", variables={"v": ModelVariable(type="state")})
    outer = Model(
        name="Outer",
        variables={"out": ModelVariable(type="observed", expression="sub.v")},
        subsystems={"sub": inner},
    )
    flat = flatten(_empty_file(models={"Outer": outer}))
    eq = next(e for e in flat.equations if e.lhs == "Outer.out")
    assert eq.rhs == "Outer.sub.v"  # subsystem-local ref qualified
    assert "Outer.sub.v" in flat.state_variables  # matches the lowered subsystem var


# ----------------------------------------------------------------------------
# Reaction systems are lowered through derive_odes
# ----------------------------------------------------------------------------


def test_flatten_lowers_reaction_system_to_odes():
    """A reaction system with reactions should produce ODE equations."""
    species_a = Species(name="A")
    species_b = Species(name="B")
    k = Parameter(name="k", value=0.1)
    reaction = Reaction(
        name="forward",
        reactants={"A": 1.0},
        products={"B": 1.0},
        rate_constant=0.1,
    )
    rs = ReactionSystem(
        name="Chem",
        species=[species_a, species_b],
        parameters=[k],
        reactions=[reaction],
    )

    file = _empty_file(reaction_systems={"Chem": rs})

    flat = flatten(file)
    assert "Chem.A" in flat.state_variables
    assert "Chem.B" in flat.state_variables
    assert "Chem.k" in flat.parameters
    # Two ODE equations were derived (one for each species).
    assert len(flat.equations) == 2
    lhs_strs = [eq.lhs_str for eq in flat.equations]
    assert any("Chem.A" in s for s in lhs_strs)
    assert any("Chem.B" in s for s in lhs_strs)


# ----------------------------------------------------------------------------
# Independent variables track spatial operators
# ----------------------------------------------------------------------------


def test_flatten_independent_variables_default_to_t_only():
    var_x = ModelVariable(type="state")
    eq = Equation(
        lhs=ExprNode(op="D", args=["x"], wrt="t"),
        rhs="x",
    )
    model = Model(name="A", variables={"x": var_x}, equations=[eq])
    file = _empty_file(models={"A": model})
    flat = flatten(file)
    assert flat.independent_variables == ["t"]


def test_flatten_independent_variables_pick_up_grad():
    var_u = ModelVariable(type="state")
    eq = Equation(
        lhs=ExprNode(op="D", args=["u"], wrt="t"),
        rhs=ExprNode(op="grad", args=["u"], dim="x"),
    )
    model = Model(name="Adv", variables={"u": var_u}, equations=[eq])
    file = _empty_file(models={"Adv": model})
    flat = flatten(file)
    assert "t" in flat.independent_variables
    assert "x" in flat.independent_variables


# ----------------------------------------------------------------------------
# operator_compose merges equations and applies _var placeholders
# ----------------------------------------------------------------------------


def test_flatten_operator_compose_lhs_match_and_sum():
    """Two systems with D(O3, t) on LHS should merge into one summed equation."""
    chem_o3 = ModelVariable(type="state")
    chem_eq = Equation(
        lhs=ExprNode(op="D", args=["O3"], wrt="t"),
        rhs=ExprNode(op="*", args=[-1, "O3"]),
    )
    chem = Model(name="Chem", variables={"O3": chem_o3}, equations=[chem_eq])

    adv_o3 = ModelVariable(type="state")
    adv_eq = Equation(
        lhs=ExprNode(op="D", args=["O3"], wrt="t"),
        rhs=ExprNode(op="grad", args=["O3"], dim="x"),
    )
    adv = Model(name="Adv", variables={"O3": adv_o3}, equations=[adv_eq])

    coupling = OperatorComposeCoupling(systems=["Chem", "Adv"])
    file = _empty_file(models={"Chem": chem, "Adv": adv}, coupling=[coupling])

    flat = flatten(file)
    # Only the merged equation survives — Chem retains the canonical LHS.
    chem_eqs = [e for e in flat.equations if "Chem.O3" in e.lhs_str]
    assert len(chem_eqs) == 1
    merged = chem_eqs[0]
    # The merged RHS contains BOTH the chemistry and advection terms.
    assert "Chem.O3" in merged.rhs_str
    assert "grad" in merged.rhs_str
    # The Adv equation was consumed — no orphan D(Adv.O3, t).
    assert not any("Adv.O3" in e.lhs_str for e in flat.equations)


def test_flatten_operator_compose_var_placeholder_expansion():
    """An advection system using _var should clone its equation per state var."""
    chem_a = ModelVariable(type="state")
    chem_b = ModelVariable(type="state")
    chem_eq_a = Equation(lhs=ExprNode(op="D", args=["A"], wrt="t"), rhs=0)
    chem_eq_b = Equation(lhs=ExprNode(op="D", args=["B"], wrt="t"), rhs=0)
    chem = Model(
        name="Chem", variables={"A": chem_a, "B": chem_b}, equations=[chem_eq_a, chem_eq_b]
    )

    adv_eq = Equation(
        lhs=ExprNode(op="D", args=["_var"], wrt="t"),
        rhs=ExprNode(op="grad", args=["_var"], dim="x"),
    )
    adv = Model(name="Adv", variables={}, equations=[adv_eq])

    coupling = OperatorComposeCoupling(systems=["Chem", "Adv"])
    file = _empty_file(models={"Chem": chem, "Adv": adv}, coupling=[coupling])

    flat = flatten(file)
    # Both A and B should now have advection terms summed into their equations.
    chem_eqs = [e for e in flat.equations if e.source_system == "Chem"]
    assert len(chem_eqs) == 2
    rhs_strs = [e.rhs_str for e in chem_eqs]
    assert any("Chem.A" in r and "grad" in r for r in rhs_strs)
    assert any("Chem.B" in r and "grad" in r for r in rhs_strs)


# ----------------------------------------------------------------------------
# variable_map substitutes parameters with shared variables
# ----------------------------------------------------------------------------


def test_flatten_variable_map_param_to_var():
    """variable_map(param_to_var) removes the parameter and substitutes refs."""
    chem_o3 = ModelVariable(type="state")
    chem_T = ModelVariable(type="parameter", default=298.0)
    chem_eq = Equation(
        lhs=ExprNode(op="D", args=["O3"], wrt="t"),
        rhs=ExprNode(op="*", args=["T", "O3"]),
    )
    chem = Model(
        name="Chem",
        variables={"O3": chem_o3, "T": chem_T},
        equations=[chem_eq],
    )

    geos_T = ModelVariable(type="state")
    geos = Model(name="GEOSFP", variables={"T": geos_T})

    coupling = VariableMapCoupling(
        from_var="GEOSFP.T",
        to_var="Chem.T",
        transform="param_to_var",
    )
    file = _empty_file(models={"Chem": chem, "GEOSFP": geos}, coupling=[coupling])

    flat = flatten(file)
    # Chem.T was promoted to a variable and removed from parameters.
    assert "Chem.T" not in flat.parameters
    # The chemistry equation now references GEOSFP.T.
    chem_eqs = [e for e in flat.equations if "Chem.O3" in e.lhs_str]
    assert len(chem_eqs) == 1
    assert "GEOSFP.T" in chem_eqs[0].rhs_str
    assert "Chem.T" not in chem_eqs[0].rhs_str


# ----------------------------------------------------------------------------
# Conflict detection
# ----------------------------------------------------------------------------


def test_flatten_conflicting_derivatives_raise():
    """Two systems defining different equations for the same variable conflict."""
    a_var = ModelVariable(type="state")
    a_eq = Equation(lhs=ExprNode(op="D", args=["x"], wrt="t"), rhs="x")
    a = Model(name="A", variables={"x": a_var}, equations=[a_eq])

    b_var = ModelVariable(type="state")
    b_eq = Equation(
        lhs=ExprNode(op="D", args=["x"], wrt="t"),
        rhs=ExprNode(op="*", args=[-1, "x"]),
    )
    b = Model(name="B", variables={"x": b_var}, equations=[b_eq])

    # variable_map unifies A.x and B.x without operator_compose merging — the
    # resulting flat system would then have two distinct equations for the
    # same dependent variable.
    vm = VariableMapCoupling(
        from_var="A.x",
        to_var="B.x",
        transform="param_to_var",
    )
    file = _empty_file(models={"A": a, "B": b}, coupling=[vm])

    with pytest.raises(ConflictingDerivativeError):
        flatten(file)


def test_flatten_same_system_multi_lhs_passes_through():
    """A single source system with two algebraic equations sharing an LHS is a
    legitimate DAE (e.g. equilibrium model: K = f(T) AND K = product([H+], [OH-])).
    flatten() must not raise — only cross-system conflicts are errors."""
    K_var = ModelVariable(type="state")
    OH_var = ModelVariable(type="state")
    H_var = ModelVariable(type="parameter", default=1e-4)
    Kref_var = ModelVariable(type="parameter", default=1e-8)

    eq_K_temp = Equation(lhs="K", rhs="K_ref")
    eq_K_prod = Equation(
        lhs="K",
        rhs=ExprNode(op="*", args=["H", "OH"]),
    )

    model = Model(
        name="Eq",
        variables={"K": K_var, "OH": OH_var, "H": H_var, "K_ref": Kref_var},
        equations=[eq_K_temp, eq_K_prod],
    )
    file = _empty_file(models={"Eq": model})

    flat = flatten(file)
    eqs_for_K = [e for e in flat.equations if e.lhs_str == "Eq.K"]
    assert len(eqs_for_K) == 2


# ----------------------------------------------------------------------------
# Empty input still raises
# ----------------------------------------------------------------------------


def test_flatten_empty_file_still_raises():
    file = _empty_file()
    with pytest.raises(ValueError):
        flatten(file)
