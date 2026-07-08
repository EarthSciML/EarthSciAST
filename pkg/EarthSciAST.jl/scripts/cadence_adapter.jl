#!/usr/bin/env julia
# Julia cadence-partition conformance adapter (CONFORMANCE_SPEC.md §5.7, bead
# ess-my4.3.7). The thin bridge the cross-binding cadence harness
# (scripts/run-cadence-conformance.py) invokes to exercise the REAL Julia
# partition pass (EarthSciAST.Cadence) over the shared §6.1 fixtures.
# The runner discovers it via $EARTHSCI_CADENCE_ADAPTER_JULIA or as
# earthsci-cadence-adapter-julia on PATH, and calls:
#
#     <adapter> --manifest <manifest.json> --output <result.json>
#
# For each fixture it runs the partition pass over the .esm model (class summary,
# materialization frontier, guards) and the CONST-fold kernels over the
# manifest's value inputs (the fixtures are value-free), then writes the class
# map, materialization-point threshold set, and byte-identical CONST-folded
# buffers. Keep this thin — the contract lives in src/cadence.jl, not here.

using EarthSciAST
const C = EarthSciAST.Cadence
import JSON3

function parse_args(argv)
    manifest = nothing
    output = nothing
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--manifest"
            manifest = argv[i+1]; i += 2
        elseif a == "--output"
            output = argv[i+1]; i += 2
        else
            error("cadence_adapter: unknown argument $(repr(a))")
        end
    end
    (manifest === nothing || output === nothing) &&
        error("cadence_adapter: --manifest and --output are required")
    return manifest, output
end

# A fixture path in the manifest is repo-root-relative; the manifest lives at
# <root>/tests/conformance/cadence/manifest.json, so the root is three dirs up.
repo_root_of(manifest_path) =
    normpath(joinpath(dirname(abspath(manifest_path)), "..", "..", ".."))

function partition_fixture(fx, repo_root)
    model = C.load_model_json(joinpath(repo_root, fx["fixture"]), fx["model"])

    # Guards must hold on a valid fixture; a violation is a real failure.
    C.run_guards(model)

    r = C.partition_model(model)
    isempty(r.problems) || error("cadence_adapter [$(fx["id"])]: " * join(r.problems, "; "))

    # CONST-fold buffers from the manifest's value inputs (fixtures are value-free).
    buffers = Dict{String,Any}()
    cf = get(fx, "const_fold", Dict{String,Any}())
    inputs = get(cf, "inputs", Dict{String,Any}())
    for (label, spec) in get(cf, "expected", Dict{String,Any}())
        buffers[label] = C.canonical_serialize(C.compute_fold(label, spec, inputs))
    end

    return Dict{String,Any}(
        "class_summary" => r.class_summary,
        "materialization_points" => r.materialization_points,
        "const_fold_buffers" => buffers,
    )
end

function main(argv)
    manifest_path, output_path = parse_args(argv)
    manifest = C.to_native(JSON3.read(read(manifest_path, String)))
    repo_root = repo_root_of(manifest_path)

    fixtures = Dict{String,Any}()
    for fx in manifest["fixtures"]
        fixtures[fx["id"]] = partition_fixture(fx, repo_root)
    end

    result = Dict{String,Any}("binding" => "julia", "fixtures" => fixtures)
    mkpath(dirname(abspath(output_path)))
    open(output_path, "w") do io
        JSON3.write(io, result)
        write(io, "\n")
    end
    return 0
end

exit(main(ARGS))
