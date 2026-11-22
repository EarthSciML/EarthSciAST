# Julia classification conformance check (esm-spec §6.3.1).
#
# esm 1.0.0 declares TWO variable types, `unknown` and `parameter`, and derives
# everything else a solver needs. `tests/conformance/classification/` pins one
# answer for every binding, and this file is Julia's side of that comparison.
#
# For each fixture it loads the document through the ordinary front door
# (`EarthSciAST.load`) and, for every model NODE — a top-level model and each of
# its subsystems under the dot-path the golden keys by — records the three
# unknown sets, the four parameter sets, the derived `system_kind`, and the
# model's declared `system_kind` (or `nothing`, also for a deprecated "pde"). Every list is sorted
# lexicographically so the comparison is order-independent across languages.
#
# `test/classification_test.jl` includes this file and asserts the result
# against the goldens. The cross-language runner has no classification stage,
# so there is no command-line entry.

module ClassificationConformanceAdapter

using EarthSciAST

"""
    classify_model(model::Model) -> Dict{String,Any}

The §6.3.1 report for one model node: the three unknown sets, the four
parameter sets, the derived `system_kind`, and the declared field.

The partition property is ASSERTED rather than assumed — the spec states it
normatively, and a binding whose sets silently overlap would still match a
golden that happened not to exercise the overlap.
"""
function classify_model(model::Model)
    assert_classification_partitions(model)
    return Dict{String, Any}(
        "ode_states" => ode_states(model),
        "observed_unknowns" => observed_unknowns(model),
        "algebraic_unknowns" => algebraic_unknowns(model),
        "brownian_parameters" => brownian_parameters(model),
        "discrete_parameters" => discrete_parameters(model),
        "sampled_parameters" => sampled_parameters(model),
        "constant_parameters" => constant_parameters(model),
        "system_kind" => system_kind(model),
        "declared_system_kind" => declared_system_kind(model),
    )
end

"""
    classify_document(file::EsmFile) -> Dict{String,Any}

Every model NODE of `file`, keyed by its dot-path from the document root, so a
subsystem is `"Parent.Child"` and the names inside each list stay LOCAL to that
node. Classification is per model node, not per document: a binding that
flattens first and classifies once returns one merged answer where the golden
expects two scoped ones.
"""
function classify_document(file::EsmFile)
    models = Dict{String, Any}()
    file.models === nothing && return models
    function walk(name::String, m::Model)
        models[name] = classify_model(m)
        for (sub_name, sub) in m.subsystems
            sub isa Model && walk("$(name).$(sub_name)", sub)
        end
        return
    end
    for (mname, m) in file.models
        m isa Model && walk(String(mname), m)
    end
    return models
end

classify_fixture(path::AbstractString) =
    Dict{String, Any}("models" => classify_document(EarthSciAST.load_path(String(path))))

end # module ClassificationConformanceAdapter
