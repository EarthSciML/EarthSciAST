"""Test the type definitions in earthsci_toolkit.types."""

from earthsci_toolkit.esm_types import (
    ExprNode,
    Equation,
    AffectEquation,
    ModelVariable,
    Model,
    Species,
    Parameter,
    Reaction,
    ReactionSystem,
    DataLoader,
    DataLoaderKind,
    DataLoaderSource,
    DataLoaderVariable,
    Operator,
    CouplingType,
    VariableMapCoupling,
    OperatorComposeCoupling,
    Domain,
    Reference,
    Metadata,
    EsmFile,
)


def test_expr_node():
    """Test ExprNode creation."""
    node = ExprNode(op="+", args=[1, 2])
    assert node.op == "+"
    assert node.args == [1, 2]
    assert node.wrt is None
    assert node.dim is None


def test_equation():
    """Test Equation creation."""
    eq = Equation(lhs="x", rhs=5)
    assert eq.lhs == "x"
    assert eq.rhs == 5


def test_affect_equation():
    """Test AffectEquation creation."""
    affect = AffectEquation(lhs="y", rhs=ExprNode(op="*", args=[2, "x"]))
    assert affect.lhs == "y"
    assert isinstance(affect.rhs, ExprNode)


def test_model_variable():
    """Test ModelVariable creation."""
    var = ModelVariable(type="state", units="kg/m^3", default=0.0, description="Concentration")
    assert var.type == "state"
    assert var.units == "kg/m^3"
    assert var.default == 0.0
    assert var.description == "Concentration"


def test_model():
    """Test Model creation."""
    model = Model(name="TestModel")
    assert model.name == "TestModel"
    assert len(model.variables) == 0
    assert len(model.equations) == 0


def test_species():
    """Test Species creation."""
    species = Species(name="CO2", formula="CO2", units="gram/mole", default=44.01)
    assert species.name == "CO2"
    assert species.formula == "CO2"
    assert species.units == "gram/mole"
    assert species.default == 44.01


def test_parameter():
    """Test Parameter creation."""
    param = Parameter(name="k1", value=0.1, units="1/s")
    assert param.name == "k1"
    assert param.value == 0.1
    assert param.units == "1/s"


def test_reaction():
    """Test Reaction creation."""
    reaction = Reaction(name="R1", reactants={"A": 1, "B": 1}, products={"C": 1}, rate_constant=0.1)
    assert reaction.name == "R1"
    assert reaction.reactants == {"A": 1, "B": 1}
    assert reaction.products == {"C": 1}
    assert reaction.rate_constant == 0.1


def test_reaction_system():
    """Test ReactionSystem creation."""
    system = ReactionSystem(name="TestSystem")
    assert system.name == "TestSystem"
    assert len(system.species) == 0
    assert len(system.reactions) == 0


def test_data_loader():
    """Test DataLoader creation."""
    loader = DataLoader(
        name="test",
        kind=DataLoaderKind.GRID,
        source=DataLoaderSource(url_template="file:///data/test_{date:%Y%m%d}.nc"),
        variables={
            "T": DataLoaderVariable(file_variable="T", units="K", description="temperature"),
        },
    )
    assert loader.name == "test"
    assert loader.kind == DataLoaderKind.GRID
    assert loader.source.url_template == "file:///data/test_{date:%Y%m%d}.nc"
    assert "T" in loader.variables
    assert loader.variables["T"].file_variable == "T"


def test_operator():
    """Test Operator creation."""
    op = Operator(operator_id="interp_op", needed_vars=["temperature", "pressure"])
    assert op.operator_id == "interp_op"
    assert op.needed_vars == ["temperature", "pressure"]
    assert op.modifies is None
    assert op.config == {}


def test_coupling_entry():
    """Test CouplingEntry discriminated union creation."""
    # Test VariableMapCoupling
    coupling = VariableMapCoupling(
        from_var="Model1.x",
        to_var="Model2.y",
        transform="identity",
        factor=1.0,
        description="Test variable mapping",
    )
    assert coupling.from_var == "Model1.x"
    assert coupling.to_var == "Model2.y"
    assert coupling.coupling_type == CouplingType.VARIABLE_MAP
    assert coupling.transform == "identity"
    assert coupling.factor == 1.0

    # Test OperatorComposeCoupling
    op_coupling = OperatorComposeCoupling(
        systems=["model1", "model2"], translate={"var1": "var2"}, description="Operator composition"
    )
    assert op_coupling.systems == ["model1", "model2"]
    assert op_coupling.translate == {"var1": "var2"}
    assert op_coupling.coupling_type == CouplingType.OPERATOR_COMPOSE


def test_domain():
    """Test Domain creation."""
    domain = Domain(name="2D", dimensions={"x": 100, "y": 50})
    assert domain.name == "2D"
    assert domain.dimensions == {"x": 100, "y": 50}


def test_reference():
    """Test Reference creation."""
    ref = Reference(title="Test Paper", authors=["Smith, J."], year=2024)
    assert ref.title == "Test Paper"
    assert ref.authors == ["Smith, J."]
    assert ref.year == 2024


def test_metadata():
    """Test Metadata creation."""
    metadata = Metadata(title="Test Model", version="1.0")
    assert metadata.title == "Test Model"
    assert metadata.version == "1.0"


def test_esm_file():
    """Test EsmFile creation."""
    metadata = Metadata(title="Test", version="1.0")
    esm_file = EsmFile(version="1.0", metadata=metadata)
    assert esm_file.version == "1.0"
    assert esm_file.metadata == metadata
    assert len(esm_file.models) == 0


def test_complex_expression():
    """Test complex nested expression."""
    # Create expression: (x + y) * 2
    add_expr = ExprNode(op="+", args=["x", "y"])
    mult_expr = ExprNode(op="*", args=[add_expr, 2])

    assert mult_expr.op == "*"
    assert len(mult_expr.args) == 2
    assert mult_expr.args[1] == 2
    assert isinstance(mult_expr.args[0], ExprNode)
    assert mult_expr.args[0].op == "+"
