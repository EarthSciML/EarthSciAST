"""Test for round-trip preservation of previously missing fields: events, data_loaders, operators, couplings, solvers."""

import json

from earthsci_toolkit.esm_types import (
    EsmFile,
    Metadata,
    DataLoader,
    DataLoaderKind,
    DataLoaderSource,
    DataLoaderVariable,
    Operator,
    VariableMapCoupling,
    ContinuousEvent,
    AffectEquation,
)
from earthsci_toolkit.serialize import save


def test_roundtrip_preserves_data_loaders():
    """Test that data loaders are preserved through serialization."""
    # Create minimal metadata
    metadata = Metadata(
        title="Data Loader Test",
        description="Test data loader preservation",
        authors=[],
        created=None,
        modified=None,
        version="1.0",
        references=[],
        keywords=[],
    )

    # Create data loader
    data_loader = DataLoader(
        name="test_loader",
        kind=DataLoaderKind.GRID,
        source=DataLoaderSource(url_template="file:///data/test_{date:%Y%m%d}.nc"),
        variables={
            "temperature": DataLoaderVariable(
                file_variable="T", units="K", description="Air temperature"
            ),
            "pressure": DataLoaderVariable(
                file_variable="P", units="Pa", description="Air pressure"
            ),
        },
    )

    # Create ESM file
    esm_file = EsmFile(
        version="0.1.0",
        metadata=metadata,
        models={},
        reaction_systems={},
        events=[],
        data_loaders={"test_loader": data_loader},
        operators=[],
        coupling=[],
    )

    # Serialize to JSON
    json_str = save(esm_file)
    data = json.loads(json_str)

    # Verify data_loaders field is present
    assert "data_loaders" in data
    assert "test_loader" in data["data_loaders"]

    loader_data = data["data_loaders"]["test_loader"]
    assert loader_data["kind"] == "grid"
    assert loader_data["source"]["url_template"] == "file:///data/test_{date:%Y%m%d}.nc"
    assert "variables" in loader_data
    assert loader_data["variables"]["temperature"]["file_variable"] == "T"
    assert loader_data["variables"]["temperature"]["units"] == "K"


def test_roundtrip_preserves_operators():
    """Test that operators are preserved through serialization."""
    metadata = Metadata(
        title="Operator Test",
        description="Test operator preservation",
        authors=[],
        created=None,
        modified=None,
        version="1.0",
        references=[],
        keywords=[],
    )

    # Create operator
    operator = Operator(
        operator_id="test_operator",
        needed_vars=["x", "y"],
        modifies=["z"],
        config={"param1": "value1", "param2": 42},
    )

    # Create ESM file
    esm_file = EsmFile(
        version="0.1.0",
        metadata=metadata,
        models={},
        reaction_systems={},
        events=[],
        data_loaders={},
        operators=[operator],
        coupling=[],
    )

    # Serialize to JSON
    json_str = save(esm_file)
    data = json.loads(json_str)

    # Verify operators field is present
    assert "operators" in data
    assert "test_operator" in data["operators"]

    operator_data = data["operators"]["test_operator"]
    assert operator_data["operator_id"] == "test_operator"
    assert operator_data["config"]["param1"] == "value1"
    assert operator_data["config"]["param2"] == 42
    assert operator_data["needed_vars"] == ["x", "y"]
    assert operator_data["modifies"] == ["z"]


def test_roundtrip_preserves_couplings():
    """Test that coupling entries are preserved through serialization."""
    metadata = Metadata(
        title="Coupling Test",
        description="Test coupling preservation",
        authors=[],
        created=None,
        modified=None,
        version="1.0",
        references=[],
        keywords=[],
    )

    # Create coupling entry
    coupling = VariableMapCoupling(
        from_var="model1.x",
        to_var="model2.y",
    )

    # Create ESM file
    esm_file = EsmFile(
        version="0.1.0",
        metadata=metadata,
        models={},
        reaction_systems={},
        events=[],
        data_loaders={},
        operators=[],
        coupling=[coupling],
    )

    # Serialize to JSON
    json_str = save(esm_file)
    data = json.loads(json_str)

    # Verify coupling field is present
    assert "coupling" in data
    assert len(data["coupling"]) == 1

    coupling_data = data["coupling"][0]
    assert coupling_data["type"] == "variable_map"
    assert coupling_data["from"] == "model1.x"
    assert coupling_data["to"] == "model2.y"


def test_roundtrip_preserves_events():
    """Test that events are preserved through serialization."""
    metadata = Metadata(
        title="Event Test",
        description="Test event preservation",
        authors=[],
        created=None,
        modified=None,
        version="1.0",
        references=[],
        keywords=[],
    )

    # Create continuous event
    event = ContinuousEvent(
        name="test_event",
        conditions=["x > 5.0"],  # Changed to array
        affects=[AffectEquation(lhs="y", rhs="0.0")],
        priority=1,
    )

    # Create ESM file
    esm_file = EsmFile(
        version="0.1.0",
        metadata=metadata,
        models={},
        reaction_systems={},
        events=[event],
        data_loaders={},
        operators=[],
        coupling=[],
    )

    # Serialize to JSON
    json_str = save(esm_file)
    data = json.loads(json_str)

    # Verify events are present
    assert "continuous_events" in data
    assert len(data["continuous_events"]) == 1

    event_data = data["continuous_events"][0]
    assert event_data["name"] == "test_event"
    assert event_data["priority"] == 1
    assert len(event_data["conditions"]) == 1
    assert len(event_data["affects"]) == 1


def test_roundtrip_preserves_all_missing_fields():
    """Test that all previously missing fields are preserved together."""
    metadata = Metadata(
        title="Complete Test",
        description="Test all missing field preservation",
        authors=[],
        created=None,
        modified=None,
        version="1.0",
        references=[],
        keywords=[],
    )

    # Create all components
    data_loader = DataLoader(
        name="loader",
        kind=DataLoaderKind.GRID,
        source=DataLoaderSource(url_template="file:///data/emissions_{date:%Y%m}.nc"),
        variables={
            "temp": DataLoaderVariable(file_variable="T", units="K"),
        },
    )

    operator = Operator(
        operator_id="operator", needed_vars=["temp"], modifies=["processed_temp"], config={}
    )

    coupling = VariableMapCoupling(
        from_var="m1.a",
        to_var="m2.b",
    )

    event = ContinuousEvent(
        name="event",
        conditions=["t > 10"],  # Changed to array
        affects=[AffectEquation(lhs="x", rhs="1.0")],
        priority=0,
    )

    # Create ESM file with all components
    esm_file = EsmFile(
        version="0.1.0",
        metadata=metadata,
        models={},
        reaction_systems={},
        events=[event],
        data_loaders={"loader": data_loader},
        operators=[operator],
        coupling=[coupling],
    )

    # Serialize to JSON
    json_str = save(esm_file)
    data = json.loads(json_str)

    # Verify all fields are present
    assert "data_loaders" in data
    assert "operators" in data
    assert "coupling" in data
    assert "continuous_events" in data

    # Verify they have the expected content
    assert "loader" in data["data_loaders"]
    assert "operator" in data["operators"]
    assert len(data["coupling"]) == 1
    assert len(data["continuous_events"]) == 1


def test_parse_domain_with_empty_temporal_block():
    """An empty 'temporal': {} block must parse to a TemporalDomain with start/end None
    (schema permits it; several simulation fixtures use this). Regression for gt-qgui."""
    from earthsci_toolkit.parse import _parse_domain

    domain = _parse_domain({"temporal": {}})
    assert domain.temporal is not None
    assert domain.temporal.start is None
    assert domain.temporal.end is None
    assert domain.temporal.reference_time is None


def test_roundtrip_preserves_empty_temporal_block():
    """Serializing a domain with an empty TemporalDomain must emit 'temporal': {}
    rather than injecting nulls for start/end. Regression for gt-qgui."""
    from earthsci_toolkit.esm_types import Domain, TemporalDomain
    from earthsci_toolkit.parse import _parse_domain
    from earthsci_toolkit.serialize import _serialize_domain

    domain = Domain()
    domain.temporal = TemporalDomain()

    serialized = _serialize_domain(domain)
    assert serialized["temporal"] == {}

    reparsed = _parse_domain(serialized)
    assert reparsed.temporal is not None
    assert reparsed.temporal.start is None
    assert reparsed.temporal.end is None


def test_roundtrip_preserves_example_expression_template_imports():
    """An Example's `expression_template_imports` (esm-spec §9.7.10 form C — a
    per-run discretization injected for an example) is authored per-run config
    and MUST survive load → _serialize_esm_file, exactly like a Test's does.
    Regression: the Python binding previously dropped it on parse → emit."""
    from earthsci_toolkit.parse import load
    from earthsci_toolkit.serialize import _serialize_esm_file

    imports = [{"ref": "./upwind1.esm", "bindings": {"N": 100}}]
    decay = {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": {"op": "*", "args": [-1, "u"]}}
    doc = {
        "esm": "0.8.0",
        "metadata": {"name": "example_import_roundtrip"},
        "models": {
            "M": {
                "variables": {"u": {"type": "state", "units": "1"}},
                "equations": [decay],
                "examples": [
                    {
                        "id": "run_under_discretization",
                        "time_span": {"start": 0.0, "end": 1.0},
                        "expression_template_imports": imports,
                    }
                ],
            }
        },
    }

    f = load(json.dumps(doc))

    # The parsed Example carries the imports on its dataclass field.
    example = f.models["M"].examples[0]
    assert example.expression_template_imports == imports

    # ... and they round-trip verbatim on emit.
    ser = _serialize_esm_file(f)["models"]["M"]["examples"][0]
    assert ser["expression_template_imports"] == imports


def test_example_without_imports_omits_key():
    """An Example with no `expression_template_imports` must not emit the key
    (empty-list default stays backward-compatible / off the wire)."""
    from earthsci_toolkit.parse import load
    from earthsci_toolkit.serialize import _serialize_esm_file

    decay = {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": {"op": "*", "args": [-1, "u"]}}
    doc = {
        "esm": "0.8.0",
        "metadata": {"name": "example_no_import"},
        "models": {
            "M": {
                "variables": {"u": {"type": "state", "units": "1"}},
                "equations": [decay],
                "examples": [
                    {
                        "id": "plain",
                        "time_span": {"start": 0.0, "end": 1.0},
                    }
                ],
            }
        },
    }

    f = load(json.dumps(doc))
    assert f.models["M"].examples[0].expression_template_imports == []
    ser = _serialize_esm_file(f)["models"]["M"]["examples"][0]
    assert "expression_template_imports" not in ser
