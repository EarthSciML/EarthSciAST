"""A name read from a :class:`Solution` selects ONE variable (CONFORMANCE_SPEC §5.17.4).

The exact name wins; failing that, the one variable whose last dotted segment is
the name. A last segment two components share -- both declare ``O3`` -- is
refused with ``ambiguous_output_name`` rather than returning an arbitrary
component's trajectory, or every component's rows at once.
"""

from __future__ import annotations

import numpy as np
import pytest

from earthsci_ast.error_handling import ERROR_CODES
from earthsci_ast.errors import AmbiguousOutputNameError
from earthsci_ast.simulation_common import ReturnCode, Solution


def _solution(names: list[str]) -> Solution:
    t = np.array([0.0, 1.0])
    y = np.array([[float(i), float(i) + 0.5] for i in range(len(names))])
    return Solution(t=t, y=y, vars=names, retcode=ReturnCode.Success)


SCALARS = ["Chem.O3", "Sink.O3", "Chem.NO2"]
ELEMENTS = ["Chem.O3[1]", "Chem.O3[2]", "Sink.O3[1]", "Sink.O3[2]", "Chem.NO2[1]"]


@pytest.mark.parametrize("names", [SCALARS, ELEMENTS], ids=["scalar", "array"])
def test_a_shared_last_segment_is_refused(names):
    sol = _solution(names)
    with pytest.raises(AmbiguousOutputNameError) as info:
        sol["O3"]
    assert info.value.code == ERROR_CODES.AMBIGUOUS_OUTPUT_NAME == "ambiguous_output_name"
    assert info.value.candidates == ["Chem.O3", "Sink.O3"]
    # Still a KeyError, so membership and `get` keep their not-found behaviour.
    assert "O3" not in sol
    assert sol.get("O3") is None


@pytest.mark.parametrize("names", [SCALARS, ELEMENTS], ids=["scalar", "array"])
def test_the_exact_name_and_a_unique_last_segment_still_resolve(names):
    sol = _solution(names)
    rows = [i for i, v in enumerate(names) if v.split("[", 1)[0] == "Chem.O3"]
    np.testing.assert_array_equal(np.atleast_2d(sol["Chem.O3"]), np.atleast_2d(sol.y[rows]))
    no2 = [i for i, v in enumerate(names) if v.split("[", 1)[0] == "Chem.NO2"]
    np.testing.assert_array_equal(np.atleast_2d(sol["NO2"]), np.atleast_2d(sol.y[no2]))
