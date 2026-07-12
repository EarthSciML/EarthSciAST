"""Tests for the ``identity``-transform ``variable_map`` unit-mismatch preflight
(spec §4.7.6).

Port of EarthSciAST.jl's ``_check_variable_map_units``: when a ``variable_map``
coupling with ``transform == "identity"`` bridges two variables whose declared,
non-empty units DIFFER, ``flatten()`` raises ``DomainUnitMismatchError``. When
the units match — or either side has no declared units — no error is raised.
"""

import pytest

from earthsci_ast.esm_types import (
    Equation,
    EsmFile,
    ExprNode,
    Metadata,
    Model,
    ModelVariable,
    VariableMapCoupling,
)
from earthsci_ast.flatten import DomainUnitMismatchError, flatten


def _esm_file(src_units, dst_units) -> EsmFile:
    """Two models coupled by an ``identity`` variable_map from ``Src.T`` onto
    the consumer parameter ``Dst.T_ext`` (which drives ``d(u)/dt = T_ext``).
    ``src_units``/``dst_units`` set the two declared unit strings under test."""
    src = Model(
        name="Src",
        variables={"T": ModelVariable(type="observed", units=src_units, expression=300.0)},
    )
    dst = Model(
        name="Dst",
        variables={
            "T_ext": ModelVariable(type="parameter", units=dst_units),
            "u": ModelVariable(type="state", default=0.0),
        },
        equations=[Equation(lhs=ExprNode(op="D", args=["u"], wrt="t"), rhs="T_ext")],
    )
    vm = VariableMapCoupling(from_var="Src.T", to_var="Dst.T_ext", transform="identity")
    return EsmFile(
        version="0.8.0",
        metadata=Metadata(title="vm identity unit check"),
        models={"Src": src, "Dst": dst},
        coupling=[vm],
    )


def test_identity_variable_map_unit_mismatch_raises():
    """K on the source and degC on the target differ → DomainUnitMismatchError,
    naming the ``from`` variable and both unit strings."""
    with pytest.raises(DomainUnitMismatchError) as excinfo:
        flatten(_esm_file("K", "degC"))
    msg = str(excinfo.value)
    assert "Src.T" in msg
    assert "K" in msg
    assert "degC" in msg


def test_identity_variable_map_matching_units_ok():
    """Identical units (K on both sides) flatten without error."""
    flat = flatten(_esm_file("K", "K"))
    # Sanity: the coupling was actually applied (identity substitutes T_ext -> Src.T).
    u_eqs = [
        e
        for e in flat.equations
        if isinstance(e.lhs, ExprNode) and e.lhs.op == "D" and e.lhs.args == ["Dst.u"]
    ]
    assert len(u_eqs) == 1
    assert u_eqs[0].rhs == "Src.T"


def test_identity_variable_map_absent_units_does_not_raise():
    """A missing/empty unit on either side is exempt (mirrors Julia's
    ``src_units === nothing`` skip)."""
    flatten(_esm_file(None, "degC"))
    flatten(_esm_file("K", None))
    flatten(_esm_file("", "degC"))
