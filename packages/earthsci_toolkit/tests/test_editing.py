"""Tests for ESMEditor add/remove/rename variable operations (spec §4.9)."""

from earthsci_toolkit import (
    ESMEditor,
    Equation,
    ExprNode,
    Model,
    ModelVariable,
    add_variable_to_model,
    remove_variable_from_model,
    rename_variable_in_model,
)


def _make_model() -> Model:
    return Model(
        name="m",
        variables={
            "x": ModelVariable(type="state", units="m", default=1.0),
            "k": ModelVariable(type="parameter", units="1/s", default=0.1),
        },
        equations=[Equation(lhs="x", rhs=ExprNode(op="*", args=["k", "x"]))],
    )


def test_add_variable_success():
    model = _make_model()
    editor = ESMEditor(validate_after_edit=False)

    new_var = ModelVariable(type="parameter", units="kg", default=2.0)
    result = editor.add_variable(model, "mass", new_var)

    assert result.success
    assert "mass" in result.modified_object.variables
    assert result.modified_object.variables["mass"].default == 2.0
    # Original is deep-copied, not mutated.
    assert "mass" not in model.variables


def test_add_variable_duplicate_fails():
    model = _make_model()
    editor = ESMEditor(validate_after_edit=False)

    result = editor.add_variable(model, "x", ModelVariable(type="state", units="m", default=0.0))

    assert not result.success
    assert any("already exists" in e for e in result.errors)


def test_remove_variable_success():
    model = _make_model()
    editor = ESMEditor(validate_after_edit=False)

    result = editor.remove_variable(model, "k")

    assert result.success
    assert "k" not in result.modified_object.variables
    assert "x" in result.modified_object.variables


def test_remove_variable_missing_fails():
    model = _make_model()
    editor = ESMEditor(validate_after_edit=False)

    result = editor.remove_variable(model, "does_not_exist")

    assert not result.success
    assert any("not found" in e for e in result.errors)


def test_rename_variable_updates_equations():
    model = _make_model()
    editor = ESMEditor(validate_after_edit=False)

    result = editor.rename_variable(model, "x", "position")

    assert result.success
    modified = result.modified_object
    assert "position" in modified.variables
    assert "x" not in modified.variables

    # Equation lhs and rhs references get rewritten.
    eq = modified.equations[0]
    assert eq.lhs == "position"
    assert "position" in eq.rhs.args
    assert "x" not in eq.rhs.args


def test_rename_variable_collision_fails():
    model = _make_model()
    editor = ESMEditor(validate_after_edit=False)

    result = editor.rename_variable(model, "x", "k")

    assert not result.success
    assert any("already exists" in e for e in result.errors)


def test_rename_variable_missing_fails():
    model = _make_model()
    editor = ESMEditor(validate_after_edit=False)

    result = editor.rename_variable(model, "ghost", "shadow")

    assert not result.success
    assert any("not found" in e for e in result.errors)


def test_module_level_helpers_match_editor():
    model = _make_model()

    r_add = add_variable_to_model(
        model, "mass", ModelVariable(type="parameter", default=1.0), validate=False
    )
    assert r_add.success and "mass" in r_add.modified_object.variables

    r_rename = rename_variable_in_model(model, "x", "position", validate=False)
    assert r_rename.success and "position" in r_rename.modified_object.variables

    r_remove = remove_variable_from_model(model, "k", validate=False)
    assert r_remove.success and "k" not in r_remove.modified_object.variables
