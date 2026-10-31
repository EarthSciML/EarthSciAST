# Editing a model, then writing the document back out.
using EarthSciAST

const FIXTURES = joinpath(@__DIR__, "..", "fixtures")

# region: edit ops=add_variable,add_equation,model_variable,to_json,write_path
doc = load_path(joinpath(FIXTURES, "decay.esm"))
model = doc.models["Decay"]

# Edits return a new Model; the original is left alone.
decayed = ModelVariable(
    UnknownVariable; default = 0.0, units = "mol",
    description = "Amount that has decayed"
)
edited = add_variable(model, "decayed", decayed)
edited = add_equation(edited, parse_equation("D(decayed, t) = lambda * N"))
@assert ode_states(model) == ["N"]
@assert ode_states(edited) == ["N", "decayed"]

doc.models["Decay"] = edited
@assert validate(doc).is_valid

json = to_json(doc)
@assert occursin("\"decayed\"", json)

path = joinpath(mktempdir(), "decay_edited.esm")
write_path(doc, path)
reloaded = load_path(path)
@assert sort(ode_states(reloaded.models["Decay"])) == ["N", "decayed"]
# endregion

# region: rename_variable ops=rename_variable,remove_equation,remove_variable,edit_error
renamed = rename_variable(model, "lambda", "k")
@assert parameters(renamed) == ["k"]
@assert to_ascii(renamed.equations[1]) == "D(N)/Dt = (-k) * N"

# Drop the half_life equation, then the variable it defined.
trimmed = remove_variable(remove_equation(model, 2), "half_life")
@assert unknowns(trimmed) == ["N"]
@assert length(trimmed.equations) == 1

# Editing a variable that does not exist raises an EditError.
try
    rename_variable(model, "nope", "k")
    error("expected an EditError")
catch e
    @assert e isa EditError
end
# endregion
