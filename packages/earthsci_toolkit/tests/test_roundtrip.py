"""Tests for round-trip functionality: load(save(load(json))) == load(json)."""

import json

from conftest import FIXTURES_ROOT, VALID_DIR

from earthsci_toolkit import load, save
from earthsci_toolkit.esm_types import EsmFile, Metadata, Model, ModelVariable, Equation


def test_roundtrip_minimal():
    """Test round-trip with minimal ESM file."""
    original_json = {
        "esm": "0.1.0",
        "metadata": {"name": "Minimal Test"},
        "models": {
            "simple": {"variables": {"x": {"type": "state"}}, "equations": [{"lhs": "x", "rhs": 1}]}
        },
    }

    # Convert to JSON string
    json_str = json.dumps(original_json)

    # First load
    esm_file1 = load(json_str)

    # Save to JSON string
    json_str2 = save(esm_file1)

    # Second load
    esm_file2 = load(json_str2)

    # Third save (should be identical to second)
    json_str3 = save(esm_file2)

    # Compare the final two JSON strings - they should be identical
    data2 = json.loads(json_str2)
    data3 = json.loads(json_str3)

    assert data2 == data3


def test_roundtrip_reaction_system():
    """Test round-trip with reaction system."""
    original_json = {
        "esm": "0.1.0",
        "metadata": {
            "name": "Reaction Round-trip Test",
            "description": "Test reaction system round-trip",
        },
        "reaction_systems": {
            "simple_reaction": {
                "species": {
                    "A": {"units": "mol", "description": "Species A"},
                    "B": {"units": "mol", "description": "Species B"},
                    "C": {"units": "mol", "description": "Product C"},
                },
                "parameters": {
                    "k1": {"units": "1/(mol*s)", "default": 0.1, "description": "Rate constant"},
                    "k2": {"units": "1/s", "default": 0.05},
                },
                "reactions": [
                    {
                        "id": "R1",
                        "name": "Forward reaction",
                        "substrates": [
                            {"species": "A", "stoichiometry": 1},
                            {"species": "B", "stoichiometry": 1},
                        ],
                        "products": [{"species": "C", "stoichiometry": 1}],
                        "rate": "k1",
                    },
                    {
                        "id": "R2",
                        "name": "Reverse reaction",
                        "substrates": [{"species": "C", "stoichiometry": 1}],
                        "products": [
                            {"species": "A", "stoichiometry": 1},
                            {"species": "B", "stoichiometry": 1},
                        ],
                        "rate": "k2",
                    },
                ],
            }
        },
    }

    json_str = json.dumps(original_json)

    # First round-trip
    esm_file1 = load(json_str)
    json_str2 = save(esm_file1)
    esm_file2 = load(json_str2)
    json_str3 = save(esm_file2)

    # Compare final two JSON outputs
    data2 = json.loads(json_str2)
    data3 = json.loads(json_str3)

    assert data2 == data3

    # Verify specific components are preserved
    assert data2["esm"] == "0.1.0"
    assert data2["metadata"]["name"] == "Reaction Round-trip Test"
    assert "simple_reaction" in data2["reaction_systems"]

    rs_data = data2["reaction_systems"]["simple_reaction"]
    assert len(rs_data["species"]) == 3
    assert len(rs_data["parameters"]) == 2
    assert len(rs_data["reactions"]) == 2


def test_roundtrip_complex_expression():
    """Test round-trip with complex nested expressions."""
    original_json = {
        "esm": "0.1.0",
        "metadata": {"name": "Expression Test"},
        "models": {
            "complex_model": {
                "variables": {
                    "x": {"type": "state"},
                    "y": {"type": "state"},
                    "z": {
                        "type": "observed",
                        "expression": {"op": "*", "args": [{"op": "+", "args": ["x", "y"]}, 2.5]},
                    },
                },
                "equations": [
                    {
                        "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                        "rhs": {"op": "sin", "args": ["y"]},
                    },
                    {
                        "lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                        "rhs": {"op": "-", "args": ["x", {"op": "^", "args": ["y", 2]}]},
                    },
                ],
            }
        },
    }

    json_str = json.dumps(original_json)

    # Double round-trip
    esm_file1 = load(json_str)
    json_str2 = save(esm_file1)
    esm_file2 = load(json_str2)
    json_str3 = save(esm_file2)

    # Parse final JSON
    data2 = json.loads(json_str2)
    data3 = json.loads(json_str3)

    assert data2 == data3

    # Check complex expressions are preserved
    model_data = data2["models"]["complex_model"]

    # Check observed variable expression
    z_expr = model_data["variables"]["z"]["expression"]
    assert z_expr["op"] == "*"
    assert z_expr["args"][1] == 2.5
    assert z_expr["args"][0]["op"] == "+"

    # Check equation expressions
    eq1_lhs = model_data["equations"][0]["lhs"]
    assert eq1_lhs["op"] == "D"
    assert eq1_lhs["wrt"] == "t"

    eq2_rhs = model_data["equations"][1]["rhs"]
    assert eq2_rhs["op"] == "-"
    assert eq2_rhs["args"][1]["op"] == "^"


def test_roundtrip_preserves_metadata():
    """Test that all metadata fields are preserved through round-trip."""
    original_json = {
        "esm": "0.1.0",
        "metadata": {
            "name": "Full Metadata Test",
            "description": "A test with all metadata fields",
            "authors": ["Alice Smith", "Bob Jones"],
            "created": "2024-01-01T00:00:00Z",
            "modified": "2024-01-02T00:00:00Z",
            "tags": ["test", "metadata", "validation"],
            "references": [
                {
                    "citation": "Smith et al. (2024)",
                    "doi": "10.1000/test.doi",
                    "url": "https://example.com/paper",
                }
            ],
        },
        "models": {
            "meta_model": {
                "variables": {"x": {"type": "state"}},
                "equations": [{"lhs": "x", "rhs": 0}],
            }
        },
    }

    json_str = json.dumps(original_json)

    # Round-trip
    esm_file = load(json_str)
    json_str2 = save(esm_file)
    data = json.loads(json_str2)

    # Check all metadata is preserved
    metadata = data["metadata"]
    assert metadata["name"] == "Full Metadata Test"
    assert metadata["description"] == "A test with all metadata fields"
    assert metadata["authors"] == ["Alice Smith", "Bob Jones"]
    assert metadata["created"] == "2024-01-01T00:00:00Z"
    assert metadata["modified"] == "2024-01-02T00:00:00Z"
    assert metadata["tags"] == ["test", "metadata", "validation"]
    assert len(metadata["references"]) == 1

    ref = metadata["references"][0]
    assert ref["citation"] == "Smith et al. (2024)"
    assert ref["doi"] == "10.1000/test.doi"
    assert ref["url"] == "https://example.com/paper"


def test_roundtrip_index_outside_arrayop():
    """Round-trip for `index` op used in scalar RHS contexts (outside
    `arrayop.expr`), per RFC discretization §5.1. Exercises integer-literal
    and composite-arithmetic index arguments, plus a coexisting `index`
    inside an `arrayop.expr` body, to ensure both contexts survive
    load → save → load idempotently.
    """
    fixture_path = FIXTURES_ROOT / "indexing" / "idx_outside_arrayop.esm"
    json_str = fixture_path.read_text()

    esm1 = load(json_str)
    json_str2 = save(esm1)
    esm2 = load(json_str2)
    json_str3 = save(esm2)

    # Idempotence: second save must equal third save under parsed JSON comparison.
    assert json.loads(json_str2) == json.loads(json_str3)

    # Semantic anchor: verify the `index` nodes survive on the right equations.
    data = json.loads(json_str3)
    eqs = data["models"]["IdxOutsideArrayop"]["equations"]
    assert len(eqs) == 3
    # Scalar ODE with integer-literal index: D(s_literal) = index(u, 2)
    assert eqs[1]["rhs"]["op"] == "index"
    assert eqs[1]["rhs"]["args"][0] == "u"
    assert eqs[1]["rhs"]["args"][1] == 2
    # Scalar ODE with composite index expression: index(u, 1+2)
    assert eqs[2]["rhs"]["op"] == "index"
    composite_idx = eqs[2]["rhs"]["args"][1]
    assert isinstance(composite_idx, dict)
    assert composite_idx["op"] == "+"


def test_roundtrip_preserves_int_float_distinction():
    """Integer and float literals must round-trip as distinct kinds.

    Per discretization RFC §5.4.1, an integer literal and a float literal
    are distinct AST nodes. Python natively preserves this through `int`
    vs `float` union members; this test pins the invariant.
    """
    original_json = {
        "esm": "0.1.0",
        "metadata": {"name": "int-float-distinction"},
        "models": {
            "m": {
                "variables": {
                    "x": {"type": "state"},
                    "y": {"type": "state"},
                },
                "equations": [
                    {"lhs": "x", "rhs": 1},  # integer literal
                    {"lhs": "y", "rhs": 1.0},  # float literal
                    {"lhs": "x", "rhs": {"op": "+", "args": [1, 2.5]}},
                    {"lhs": "y", "rhs": {"op": "+", "args": [1.0, 2.5]}},
                ],
            }
        },
    }

    json_str = json.dumps(original_json)
    esm_file = load(json_str)
    json_str2 = save(esm_file)
    data = json.loads(json_str2)

    eqs = data["models"]["m"]["equations"]

    # Integer literal survives as JSON integer (type(int), not type(float)).
    assert type(eqs[0]["rhs"]) is int
    assert eqs[0]["rhs"] == 1

    # Float literal survives as JSON float. `1.0` serializes as "1.0".
    assert type(eqs[1]["rhs"]) is float
    assert eqs[1]["rhs"] == 1.0
    assert "1.0" in json_str2  # ensures trailing .0 is emitted for integer-valued float

    # Inside an operator node: mixed int/float preserves each arg's kind.
    assert type(eqs[2]["rhs"]["args"][0]) is int
    assert type(eqs[2]["rhs"]["args"][1]) is float
    assert type(eqs[3]["rhs"]["args"][0]) is float
    assert type(eqs[3]["rhs"]["args"][1]) is float


def test_roundtrip_tests_and_examples_fixture():
    """Round-trip the tests_examples_comprehensive fixture: inline Test/Assertion/
    Example/Plot/ParameterSweep blocks must survive parse -> serialize (gt-krpg)."""
    fixture_path = VALID_DIR / "tests_examples_comprehensive.esm"
    original = fixture_path.read_text()
    orig_obj = json.loads(original)

    esm = load(original)
    dumped = save(esm)
    esm2 = load(dumped)
    dumped2 = save(esm2)

    # Idempotence under re-save (spec §2.1a).
    assert json.loads(dumped) == json.loads(dumped2)

    # Every tests/examples block from the input survives to the output.
    out = json.loads(dumped)
    for comp_kind in ("models", "reaction_systems"):
        for comp_name, comp in orig_obj.get(comp_kind, {}).items():
            if "tolerance" in comp:
                assert out[comp_kind][comp_name]["tolerance"] == comp["tolerance"]
            if "tests" in comp:
                assert len(out[comp_kind][comp_name]["tests"]) == len(comp["tests"])
            if "examples" in comp:
                assert len(out[comp_kind][comp_name]["examples"]) == len(comp["examples"])

    # Spot-check full structure: heatmap-over-sweep assertion values.
    sweep_example = next(
        e for e in out["models"]["LogisticGrowth"]["examples"] if e["id"] == "rK_heatmap_sweep"
    )
    assert len(sweep_example["parameter_sweep"]["dimensions"]) == 2
    assert sweep_example["plots"][0]["value"] == {"variable": "N", "reduce": "final"}
    assert sweep_example["plots"][2]["value"] == {"variable": "N", "at_time": 10.0}

    # PlotSeries survives (multi-series line plot on ReactionSystem).
    rs_example = out["reaction_systems"]["SimpleDecay"]["examples"][0]
    series = rs_example["plots"][0]["series"]
    assert [s["name"] for s in series] == ["A", "B"]

    # Inline array-form y (v0.5.0) is parsed and normalized to canonical form.
    multi_y_example = next(
        e for e in out["reaction_systems"]["SimpleDecay"]["examples"] if e["id"] == "multi_y_trace"
    )
    multi_plot = multi_y_example["plots"][0]
    # After normalization, y is the canonical single PlotAxis (first entry).
    assert multi_plot["y"] == {"variable": "A", "label": "A"}
    # Series is projected from the array.
    assert multi_plot["series"] == [
        {"name": "A", "variable": "A"},
        {"name": "B", "variable": "B"},
    ]


def test_inline_multi_y_parse():
    """Array-form plots.y is normalized: first entry -> canonical y, all -> series."""
    from earthsci_toolkit.parse import _parse_plot

    raw = {
        "id": "p1",
        "type": "line",
        "x": {"variable": "t"},
        "y": [
            {"variable": "A", "label": "Species A"},
            {"variable": "B"},
        ],
    }
    plot = _parse_plot(raw)
    assert plot.y.variable == "A"
    assert plot.y.label == "Species A"
    assert len(plot.series) == 2
    assert plot.series[0].name == "Species A"
    assert plot.series[0].variable == "A"
    assert plot.series[1].name == "B"  # falls back to variable when label absent
    assert plot.series[1].variable == "B"


def test_inline_multi_y_explicit_series_wins():
    """When y is array and explicit series is present, explicit series takes precedence."""
    from earthsci_toolkit.parse import _parse_plot

    raw = {
        "id": "p2",
        "type": "line",
        "x": {"variable": "t"},
        "y": [{"variable": "A"}, {"variable": "B"}],
        "series": [{"name": "alpha", "variable": "A"}],
    }
    plot = _parse_plot(raw)
    assert plot.y.variable == "A"
    assert len(plot.series) == 1
    assert plot.series[0].name == "alpha"


def test_roundtrip_typed_test_assertion():
    """Construct Test/Assertion directly and ensure they round-trip to the wire."""
    from earthsci_toolkit.esm_types import (
        Tolerance,
        TimeSpan,
        Assertion,
        Test,
    )

    esm = EsmFile(
        version="0.1.0",
        metadata=Metadata(title="T"),
        models={
            "M": Model(
                name="M",
                variables={"x": ModelVariable(type="state", default=0.0)},
                equations=[Equation(lhs="x", rhs=1)],
                tolerance=Tolerance(rel=1e-6),
                tests=[
                    Test(
                        id="t1",
                        time_span=TimeSpan(start=0.0, end=10.0),
                        tolerance=Tolerance(abs=1e-4),
                        assertions=[
                            Assertion(
                                variable="x", time=10.0, expected=1.0, tolerance=Tolerance(abs=1e-8)
                            ),
                        ],
                    ),
                ],
            ),
        },
    )

    dumped = save(esm)
    data = json.loads(dumped)
    t = data["models"]["M"]["tests"][0]
    assert t["id"] == "t1"
    assert t["time_span"] == {"start": 0.0, "end": 10.0}
    assert t["tolerance"] == {"abs": 1e-4}
    assert t["assertions"][0]["tolerance"] == {"abs": 1e-8}
    assert data["models"]["M"]["tolerance"] == {"rel": 1e-6}


def test_roundtrip_nonlinear_isorropia_shape():
    """Round-trip fixture for Model.initialization_equations + guesses + system_kind (gt-ebuq)."""
    fixture = VALID_DIR / "nonlinear_isorropia_shape.esm"
    original_text = fixture.read_text()
    first = load(original_text)
    second = load(save(first))
    assert json.loads(save(first)) == json.loads(save(second))

    model = first.models["IsorropiaEq"]
    assert model.system_kind == "nonlinear"
    assert len(model.initialization_equations) == 2
    assert set(model.guesses.keys()) == {"H", "SO4"}


def test_roundtrip_nonlinear_mogi_shape():
    """Round-trip fixture for algebraic Mogi-shape model (gt-ebuq)."""
    fixture = VALID_DIR / "nonlinear_mogi_shape.esm"
    first = load(fixture.read_text())
    second = load(save(first))
    assert json.loads(save(first)) == json.loads(save(second))

    model = first.models["MogiModel"]
    assert model.system_kind == "nonlinear"
    assert model.initialization_equations == []
    assert model.guesses == {}


def test_roundtrip_fractional_stoichiometry():
    """Reactions with fractional product yields (e.g. ISOP+O3 → 0.87 CH2O)
    round-trip losslessly on the v0.2.x schema (gt-1e96). Integer substrate
    coefficients coexist with fractional products."""
    fixture = VALID_DIR / "fractional_stoichiometry.esm"
    original_text = fixture.read_text()
    first = load(original_text)
    second = load(save(first))
    first_json = json.loads(save(first))
    second_json = json.loads(save(second))
    assert first_json == second_json

    rs = first.reaction_systems["SuperFastLike"]
    assert len(rs.reactions) == 4

    r1 = rs.reactions[0]
    assert r1.products["CH2O"] == 0.87
    assert r1.products["CH3O2"] == 1.86
    assert r1.reactants["ISOP"] == 1

    # Integer coefficients round-trip as integers in the emitted JSON so
    # existing integer-only fixtures stay byte-identical across a parse /
    # re-emit cycle.
    r4_products = first_json["reaction_systems"]["SuperFastLike"]["reactions"][3]["products"]
    assert r4_products[0]["stoichiometry"] == 1
    assert isinstance(r4_products[0]["stoichiometry"], int)

    # Fractional coefficients are emitted as floats.
    r1_products = first_json["reaction_systems"]["SuperFastLike"]["reactions"][0]["products"]
    ch2o = next(p for p in r1_products if p["species"] == "CH2O")
    assert ch2o["stoichiometry"] == 0.87
    assert isinstance(ch2o["stoichiometry"], float)
