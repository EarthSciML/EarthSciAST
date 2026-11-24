from pathlib import Path

import pytest

from earthsci_ast import esm_problem
from earthsci_ast.problem import Float32UnsupportedError


def test_scipy_path_refuses_float32_dynamics():
    fixture = (
        Path(__file__).resolve().parents[3]
        / "tests/conformance/precision_integration/vanishing_increment.esm"
    )
    with pytest.raises(Float32UnsupportedError) as error:
        esm_problem(str(fixture), (0.0, 100.0))
    assert error.value.code == "float32_unsupported"
