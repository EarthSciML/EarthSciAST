"""Test for round-trip preservation of previously missing fields: events, data_sources, operators, couplings, solvers."""

import json

from earthsci_ast.esm_types import (
    EsmFile,
    Metadata,
    Model,
    ModelVariable,
    Equation,
    DataSource,
    DataSourceKind,
    DataSourceLocation,
    DataSourceBinding,
    ParameterUpdate,
    Operator,
    VariableMapCoupling,
    ContinuousEvent,
    AffectEquation,
)
from earthsci_ast.serialize import save


def test_roundtrip_preserves_data_sources():
    """Test that data sources — and the parameter bindings that consume them —
    are preserved through serialization.

    A source is pure I/O from 1.0.0: it declares NO `variables` map. Each
    per-variable binding lives on the CONSUMING PARAMETER's `update.from`, and
    the parameter owns the units (esm-spec §8.5), so both halves have to survive
    for the document to still name what it reads.
    """
    # Create minimal metadata
    metadata = Metadata(
        title="Data Source Test",
        description="Test data source preservation",
        authors=[],
        created=None,
        modified=None,
        version="1.0",
        references=[],
        keywords=[],
    )

    # Create data source
    data_source = DataSource(
        name="test_loader",
        kind=DataSourceKind.GRID,
        source=DataSourceLocation(url_template="file:///data/test_{date:%Y%m%d}.nc"),
    )

    # The consumers: one parameter per file variable, each carrying its own
    # units and the `from` binding naming the source's file variable.
    consumer = Model(
        name="consumer",
        variables={
            "temperature": ModelVariable(
                type="parameter",
                units="K",
                default=0.0,
                shape=[],
                description="Air temperature",
                update=ParameterUpdate(
                    kind="data",
                    source="test_loader",
                    from_source=DataSourceBinding(file_variable="T"),
                ),
            ),
            "pressure": ModelVariable(
                type="parameter",
                units="Pa",
                default=0.0,
                shape=[],
                description="Air pressure",
                update=ParameterUpdate(
                    kind="data",
                    source="test_loader",
                    from_source=DataSourceBinding(file_variable="P"),
                ),
            ),
            "x": ModelVariable(type="unknown", units="1"),
        },
        equations=[Equation(lhs="x", rhs="temperature")],
    )

    # Create ESM file
    esm_file = EsmFile(
        version="1.0.0",
        metadata=metadata,
        models={"consumer": consumer},
        reaction_systems={},
        events=[],
        data_sources={"test_loader": data_source},
        operators=[],
        coupling=[],
    )

    # Serialize to JSON
    json_str = save(esm_file)
    data = json.loads(json_str)

    # Verify data_sources field is present
    assert "data_sources" in data
    assert "test_loader" in data["data_sources"]

    loader_data = data["data_sources"]["test_loader"]
    assert loader_data["kind"] == "grid"
    assert loader_data["source"]["url_template"] == "file:///data/test_{date:%Y%m%d}.nc"
    # A source is not a component: it exposes no variables map at all.
    assert "variables" not in loader_data

    # The binding and the units live on the consuming parameter instead.
    variables = data["models"]["consumer"]["variables"]
    assert variables["temperature"]["units"] == "K"
    assert variables["temperature"]["update"] == {
        "kind": "data",
        "source": "test_loader",
        "from": {"file_variable": "T"},
    }
    assert variables["pressure"]["units"] == "Pa"
    assert variables["pressure"]["update"]["from"]["file_variable"] == "P"


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
        version="1.0.0",
        metadata=metadata,
        models={},
        reaction_systems={},
        events=[],
        data_sources={},
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
        version="1.0.0",
        metadata=metadata,
        models={},
        reaction_systems={},
        events=[],
        data_sources={},
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
        version="1.0.0",
        metadata=metadata,
        models={},
        reaction_systems={},
        events=[event],
        data_sources={},
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
    data_source = DataSource(
        name="loader",
        kind=DataSourceKind.GRID,
        source=DataSourceLocation(url_template="file:///data/emissions_{date:%Y%m}.nc"),
    )

    # The parameter that consumes it: it owns the units and the `from` binding.
    consumer = Model(
        name="consumer",
        variables={
            "temp": ModelVariable(
                type="parameter",
                units="K",
                default=0.0,
                shape=[],
                update=ParameterUpdate(
                    kind="data",
                    source="loader",
                    from_source=DataSourceBinding(file_variable="T"),
                ),
            ),
            "x": ModelVariable(type="unknown", units="1"),
        },
        equations=[Equation(lhs="x", rhs="temp")],
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
        version="1.0.0",
        metadata=metadata,
        models={"consumer": consumer},
        reaction_systems={},
        events=[event],
        data_sources={"loader": data_source},
        operators=[operator],
        coupling=[coupling],
    )

    # Serialize to JSON
    json_str = save(esm_file)
    data = json.loads(json_str)

    # Verify all fields are present
    assert "data_sources" in data
    assert "operators" in data
    assert "coupling" in data
    assert "continuous_events" in data

    # Verify they have the expected content
    assert "loader" in data["data_sources"]
    assert "operator" in data["operators"]
    assert len(data["coupling"]) == 1
    assert len(data["continuous_events"]) == 1
    # The source's consumer survives with its binding intact.
    assert data["models"]["consumer"]["variables"]["temp"]["update"]["source"] == "loader"


def test_parse_domain_with_empty_temporal_block():
    """An empty 'temporal': {} block must parse to a TemporalDomain with start/end None
    (schema permits it; several simulation fixtures use this). Regression for gt-qgui."""
    from earthsci_ast.parse import _parse_domain

    domain = _parse_domain({"temporal": {}})
    assert domain.temporal is not None
    assert domain.temporal.start is None
    assert domain.temporal.end is None
    assert domain.temporal.reference_time is None


def test_roundtrip_preserves_empty_temporal_block():
    """Serializing a domain with an empty TemporalDomain must emit 'temporal': {}
    rather than injecting nulls for start/end. Regression for gt-qgui."""
    from earthsci_ast.esm_types import Domain, TemporalDomain
    from earthsci_ast.parse import _parse_domain
    from earthsci_ast.serialize import _serialize_domain

    domain = Domain()
    domain.temporal = TemporalDomain()

    serialized = _serialize_domain(domain)
    assert serialized["temporal"] == {}

    reparsed = _parse_domain(serialized)
    assert reparsed.temporal is not None
    assert reparsed.temporal.start is None
    assert reparsed.temporal.end is None


def test_roundtrip_preserves_analysis_expression_template_imports():
    """An Analysis's `expression_template_imports` (esm-spec §9.7.10 form C — a
    per-run discretization injected for an analysis) is authored per-run config
    and MUST survive load → _serialize_esm_file, exactly like a Test's does.
    Regression: the Python binding previously dropped it on parse → emit."""
    from earthsci_ast.parse import load
    from earthsci_ast.serialize import _serialize_esm_file

    imports = [{"ref": "./upwind1.esm", "bindings": {"N": 100}}]
    decay = {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": {"op": "*", "args": [-1, "u"]}}
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "analysis_import_roundtrip"},
        "models": {
            "M": {
                "variables": {"u": {"type": "unknown", "units": "1"}},
                "equations": [decay],
                "analyses": [
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

    # The parsed Analysis carries the imports on its dataclass field.
    analysis = f.models["M"].analyses[0]
    assert analysis.expression_template_imports == imports

    # ... and they round-trip verbatim on emit.
    ser = _serialize_esm_file(f)["models"]["M"]["analyses"][0]
    assert ser["expression_template_imports"] == imports


def test_analysis_without_imports_omits_key():
    """An Analysis with no `expression_template_imports` must not emit the key
    (empty-list default stays backward-compatible / off the wire)."""
    from earthsci_ast.parse import load
    from earthsci_ast.serialize import _serialize_esm_file

    decay = {"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": {"op": "*", "args": [-1, "u"]}}
    doc = {
        "esm": "1.0.0",
        "metadata": {"name": "analysis_no_import"},
        "models": {
            "M": {
                "variables": {"u": {"type": "unknown", "units": "1"}},
                "equations": [decay],
                "analyses": [
                    {
                        "id": "plain",
                        "time_span": {"start": 0.0, "end": 1.0},
                    }
                ],
            }
        },
    }

    f = load(json.dumps(doc))
    assert f.models["M"].analyses[0].expression_template_imports == []
    ser = _serialize_esm_file(f)["models"]["M"]["analyses"][0]
    assert "expression_template_imports" not in ser
