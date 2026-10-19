# Reading, validating, inspecting and displaying a document.
using EarthSciAST

const FIXTURES = joinpath(@__DIR__, "..", "fixtures")

# region: load ops=load_path,load_string,esm_file
doc = load_path(joinpath(FIXTURES, "decay.esm"))
@assert doc isa EsmFile
@assert collect(keys(doc.models)) == ["Decay"]

# The same document from a JSON string already in memory.
json = read(joinpath(FIXTURES, "decay.esm"), String)
from_string = load_string(json)
@assert collect(keys(from_string.models)) == ["Decay"]
# endregion

# region: validate ops=validate,validate_path,validation_result
result = validate(doc)
@assert result isa ValidationResult
@assert result.is_valid

# A document that loads fine but uses a variable it never declares. Validation
# reports the problem in the result rather than throwing.
bad = validate_path(joinpath(FIXTURES, "invalid.esm"))
@assert !bad.is_valid
err = only(bad.structural_errors)
println(err.path, ": ", err.message)
@assert err.message == "Variable 'k' referenced in equation is not declared"
@assert err.path == "/models/Broken/equations/0/rhs"
# endregion

# region: load_errors ops=load_string,parse_error,schema_validation_error
# Text that is not JSON at all raises a ParseError...
try
    load_string("{not json")
    error("expected a ParseError")
catch e
    @assert e isa ParseError
    println(sprint(showerror, e))
end

# ...and JSON that breaks the schema raises a SchemaValidationError, whose
# `errors` field lists each failure.
try
    load_string("""{"esm": "1.0.0"}""")
    error("expected a SchemaValidationError")
catch e
    @assert e isa SchemaValidationError
    @assert !isempty(e.errors)
    println(sprint(showerror, e))
end
# endregion

# region: inspect ops=model,unknowns,parameters,ode_states,algebraic_unknowns,observed_unknowns,observed_definitions
model = doc.models["Decay"]
@assert sort(collect(keys(model.variables))) == ["N", "half_life", "lambda"]

# The two declared kinds...
@assert unknowns(model) == ["N", "half_life"]
@assert parameters(model) == ["lambda"]

# ...and what each unknown is, derived from the equations.
@assert ode_states(model) == ["N"]                 # has a D(N)/dt equation
@assert observed_unknowns(model) == ["half_life"]  # defined explicitly
@assert algebraic_unknowns(model) == String[]      # none solved implicitly

defs = observed_definitions(model)
@assert to_ascii(defs["half_life"]) == "log(2) / lambda"
# endregion

# region: display ops=to_unicode,to_latex,to_ascii
decay_eq = model.equations[1]
println(to_unicode(decay_eq))
@assert to_unicode(decay_eq) == "∂N/∂t = (−λ)·N"
@assert to_latex(decay_eq) == raw"\frac{\partial N}{\partial t} = (-\lambda) \cdot N"
@assert to_ascii(decay_eq) == "D(N)/Dt = (-lambda) * N"

# Expressions display the same way.
@assert to_unicode(model.equations[2].rhs) == "ln(2)/λ"
# endregion
