"""Load, validate, inspect, display and edit an EarthSciAST document."""

import json
import tempfile
from pathlib import Path

import earthsci_ast
from earthsci_ast import Equation, ExprNode, ModelVariable

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"


# region: load ops=load_path,load_string
doc = earthsci_ast.load_path(FIXTURES / "decay.esm")
assert list(doc.models) == ["Decay"]

text = (FIXTURES / "decay.esm").read_text()
same = earthsci_ast.load_string(text)
assert list(same.models["Decay"].variables) == ["N", "lambda", "half_life"]
# endregion


# region: load_document ops=load_document
raw = json.loads(text)
from_dict = earthsci_ast.load_document(raw)
assert from_dict.metadata.name == "Decay"
# endregion


# region: version_constants ops=schema_version,library_version
print("format version:", earthsci_ast.SCHEMA_VERSION)
print("library version:", earthsci_ast.LIBRARY_VERSION)
assert earthsci_ast.SCHEMA_VERSION.count(".") == 2
# endregion


# region: validate ops=validate,validate_path,validation_result,validation_error,schema_validation_error
result = earthsci_ast.validate(doc)
assert result.is_valid
assert result.schema_errors == [] and result.structural_errors == []

# validate_path reports problems in the result; it does not raise.
bad = earthsci_ast.validate_path(FIXTURES / "invalid.esm")
assert not bad.is_valid
error = bad.structural_errors[0]
print(error.code, error.path, error.message)
assert error.code == "undefined_variable"
assert "'k'" in error.message

# Loading the same file raises, because loading validates too.
try:
    earthsci_ast.load_path(FIXTURES / "invalid.esm")
except earthsci_ast.SchemaValidationError as exc:
    assert "'k'" in str(exc)
else:
    raise AssertionError("loading invalid.esm should fail")
# endregion


# region: validate_text ops=validate_text
bad_text = (FIXTURES / "invalid.esm").read_text()
report = earthsci_ast.validate_text(bad_text)
assert [e.code for e in report.structural_errors] == ["undefined_variable"]
# endregion


# region: inspect ops=esm_file,model,model_variable,ode_states,observed_unknowns,algebraic_unknowns,constant_parameters,unknowns
model = doc.models["Decay"]
for name, var in model.variables.items():
    print(f"{name}: {var.type} [{var.units}]")
assert {n: v.type for n, v in model.variables.items()} == {
    "N": "unknown",
    "lambda": "parameter",
    "half_life": "unknown",
}

# The file declares only "unknown" and "parameter"; the finer classes are derived.
assert earthsci_ast.ode_states(model) == ["N"]
assert earthsci_ast.observed_unknowns(model) == ["half_life"]
assert earthsci_ast.algebraic_unknowns(model) == []
assert earthsci_ast.constant_parameters(model) == ["lambda"]
assert earthsci_ast.unknowns(model) == ["N", "half_life"]
# endregion


# region: system_kind ops=system_kind,is_ode_state,observed_definitions
assert earthsci_ast.system_kind(model) == "ode"
assert earthsci_ast.is_ode_state(model, "N")
assert not earthsci_ast.is_ode_state(model, "half_life")

definitions = earthsci_ast.observed_definitions(model)
assert earthsci_ast.to_ascii(definitions["half_life"]) == "log(2) / lambda"
# endregion


# region: display ops=to_unicode,to_latex,to_ascii
decay_eq, half_life_eq = model.equations
print(earthsci_ast.to_unicode(decay_eq))
print(earthsci_ast.to_latex(decay_eq))
print(earthsci_ast.to_ascii(half_life_eq))
assert earthsci_ast.to_unicode(decay_eq) == "∂N/∂t = (−λ)·N"
assert earthsci_ast.to_latex(decay_eq) == r"\frac{\partial N}{\partial t} = (-\lambda) \cdot N"
assert earthsci_ast.to_ascii(half_life_eq) == "half_life = log(2) / lambda"

# A whole model renders as a one-line summary.
assert earthsci_ast.to_unicode(model) == "Model: Decay (1 state, 1 parameter, 1 observed, 2 equations)"
# endregion


# region: edit ops=add_variable,add_equation,equation,expr_node,to_json,write_path
# Edits return a new model in `modified_object`; the input is left unchanged.
edited = earthsci_ast.add_variable(
    model, "N0", ModelVariable(type="parameter", units="mol", default=100.0)
).modified_object
edited = earthsci_ast.add_variable(
    edited, "fraction", ModelVariable(type="unknown", units="1")
).modified_object
step = earthsci_ast.add_equation(
    edited, Equation(lhs="fraction", rhs=ExprNode(op="/", args=["N", "N0"]))
)
assert step.success, step.errors
doc.models["Decay"] = step.modified_object
assert "fraction" not in model.variables  # the original model is untouched

assert earthsci_ast.validate(doc).is_valid
assert earthsci_ast.observed_unknowns(doc.models["Decay"]) == ["fraction", "half_life"]

text = earthsci_ast.to_json(doc)
assert json.loads(text)["models"]["Decay"]["equations"][-1] == {
    "lhs": "fraction",
    "rhs": {"op": "/", "args": ["N", "N0"]},
}

with tempfile.TemporaryDirectory() as tmp:
    out = Path(tmp) / "decay_edited.esm"
    earthsci_ast.write_path(doc, out)
    reread = earthsci_ast.load_path(out)
assert list(reread.models["Decay"].variables) == ["N", "lambda", "half_life", "N0", "fraction"]
# endregion


# region: to_json_compact ops=to_json_compact
compact = earthsci_ast.to_json_compact(doc)
assert "\n" not in compact and compact.startswith('{"esm":')
assert json.loads(compact) == json.loads(earthsci_ast.to_json(doc))
# endregion


# region: rename_variable ops=rename_variable,remove_variable
renamed = earthsci_ast.rename_variable(doc.models["Decay"], "lambda", "k").modified_object
assert "k" in renamed.variables and "lambda" not in renamed.variables
assert earthsci_ast.to_ascii(renamed.equations[1]) == "half_life = log(2) / k"

trimmed = earthsci_ast.remove_variable(renamed, "N0")
assert "N0" not in trimmed.modified_object.variables
# endregion
