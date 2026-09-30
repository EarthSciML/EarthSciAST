"""What ``esm_problem`` refuses at construction (esm-libraries-spec §2.5.2).

Pinned here: a ``callback`` coupling variable no callback supplies
(``callback_unregistered``), a degenerate polygon operand in a state-free
observed nothing reads (esm-spec §8.6.1), a self-recomputing parameter update
(an event in esm 1.0.0, §5.4), an ``ic`` inside a reaction system, and a
control character in a declared name (§4.9.1.2, a schema error at load).
"""

from pathlib import Path

import pytest

from earthsci_ast import esm_problem, load_path
from earthsci_ast.error_handling import CALLBACK_UNREGISTERED
from earthsci_ast.parse import SchemaValidationError

REPO = Path(__file__).resolve().parents[3]


def _refusal(rel: str) -> str:
    with pytest.raises(Exception) as info:
        esm_problem(str(REPO / rel), (0.0, 1.0))
    return str(info.value)


def test_callback_variable_without_a_registered_callback_is_refused():
    msg = _refusal("tests/coupling/callback_examples.esm")
    assert CALLBACK_UNREGISTERED in msg and "CropWeatherCoupling" in msg


def test_degenerate_polygon_operand_is_refused_at_build():
    assert "E_TREEWALK_GEOMETRY_CLIP" in _refusal(
        "tests/conformance/pushdown/fixtures/pushdown_polygon_area.esm"
    )


def test_self_recomputing_parameter_update_is_refused():
    msg = _refusal("tests/events/mixed_event_interactions.esm")
    assert "unsupported_construct" in msg and "update of parameter" in msg


def test_ic_in_reaction_system_is_refused():
    assert "ic_in_reaction_system" in _refusal("tests/invalid/ic_in_reaction_system.esm")


def test_control_character_in_a_declared_name_is_a_schema_error():
    with pytest.raises(SchemaValidationError):
        load_path(str(REPO / "tests/future/security/null_byte_injection.esm"))
