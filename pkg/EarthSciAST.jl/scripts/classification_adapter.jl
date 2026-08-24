#!/usr/bin/env julia
# Julia classification conformance adapter (esm-spec §6.3.1).
#
# esm 1.0.0 declares TWO variable types, `unknown` and `parameter`, and derives
# everything else a solver needs. Five bindings deriving it independently is
# five chances to disagree, so `tests/conformance/classification/` pins one
# answer and this adapter is Julia's side of that comparison.
#
# Usage (mirrors the cadence adapter):
#
#     <adapter> --manifest <manifest.json> --output <result.json>
#
# For each fixture it loads the document through the ordinary front door
# (`EarthSciAST.load`) and, for every model NODE — a top-level model and each of
# its subsystems under the dot-path the golden keys by — records the three
# unknown sets, the four parameter sets, the derived `system_kind`, and the
# model's declared `system_kind` field (or `nothing`). Every list is sorted
# lexicographically so the comparison is order-independent across languages.
#
# `test/classification_test.jl` includes this file and asserts the result
# against the goldens; the `PROGRAM_FILE` guard below keeps the CLI entry from
# firing under that include.

module ClassificationConformanceAdapter

using EarthSciAST
import JSON3

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
    return Dict{String,Any}(
        "ode_states" => ode_states(model),
        "observed_unknowns" => observed_unknowns(model),
        "algebraic_unknowns" => algebraic_unknowns(model),
        "brownian_parameters" => brownian_parameters(model),
        "discrete_parameters" => discrete_parameters(model),
        "sampled_parameters" => sampled_parameters(model),
        "constant_parameters" => constant_parameters(model),
        "system_kind" => system_kind(model),
        "declared_system_kind" => model.system_kind,
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
    models = Dict{String,Any}()
    file.models === nothing && return models
    function walk(name::String, m::Model)
        models[name] = classify_model(m)
        for (sub_name, sub) in m.subsystems
            sub isa Model && walk("$(name).$(sub_name)", sub)
        end
    end
    for (mname, m) in file.models
        m isa Model && walk(String(mname), m)
    end
    return models
end

classify_fixture(path::AbstractString) =
    Dict{String,Any}("models" => classify_document(EarthSciAST.load_path(String(path))))

function parse_args(argv)
    manifest_path = nothing
    output_path = nothing
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--manifest"
            manifest_path = argv[i + 1]; i += 2
        elseif a == "--output"
            output_path = argv[i + 1]; i += 2
        else
            error("classification_adapter: unrecognised argument $(repr(a))")
        end
    end
    (manifest_path === nothing || output_path === nothing) &&
        error("classification_adapter: --manifest and --output are both required")
    return manifest_path, output_path
end

# The manifest's fixture paths are relative to the REPO ROOT, which is the
# manifest's own tests/conformance/classification/ grandparent.
repo_root_of(manifest_path) =
    normpath(joinpath(dirname(abspath(manifest_path)), "..", "..", ".."))

function main(argv)
    manifest_path, output_path = parse_args(argv)
    manifest = JSON3.read(read(manifest_path, String))
    base = dirname(abspath(manifest_path))

    fixtures = Dict{String,Any}()
    for fx in manifest["fixtures"]
        # A fixture path is written relative to the manifest's directory
        # ("fixtures/<id>.esm"); fall back to the repo root for an
        # absolute-from-root spelling.
        rel = String(fx["fixture"])
        path = isfile(joinpath(base, rel)) ? joinpath(base, rel) :
               joinpath(repo_root_of(manifest_path), rel)
        fixtures[String(fx["id"])] = classify_fixture(path)
    end

    result = Dict{String,Any}("binding" => "julia", "fixtures" => fixtures)
    mkpath(dirname(abspath(output_path)))
    open(output_path, "w") do io
        JSON3.write(io, result)
        write(io, "\n")
    end
    return 0
end

end # module ClassificationConformanceAdapter

if abspath(PROGRAM_FILE) == @__FILE__
    exit(ClassificationConformanceAdapter.main(ARGS))
end
