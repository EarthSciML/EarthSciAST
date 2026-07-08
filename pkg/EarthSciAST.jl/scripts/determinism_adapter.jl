#!/usr/bin/env julia
# Julia determinism-conformance adapter (CONFORMANCE_SPEC.md §5.5.4). The thin
# bridge the cross-binding determinism harness (scripts/run-determinism-conformance.py)
# invokes to exercise the REAL Julia value-invention primitives
# (EarthSciAST.Relational: skolem / distinct / rank + group-by) over the
# shared golden fixtures in tests/conformance/determinism/manifest.json. The runner
# discovers it via $EARTHSCI_DETERMINISM_ADAPTER_JULIA or as
# earthsci-determinism-adapter-julia on PATH, and calls:
#
#     <adapter> --manifest <manifest.json> --output <result.json>
#
# For each fixture it runs the primitives over inputs.canonical AND every
# adversarial inputs.variants payload, writing the canonical serialized index set,
# its index_set, and the dense-ID array in Julia's NATIVE 1-based emission base
# (the runner normalizes via rank_base_pin: julia=1). Keep this thin — the contract
# lives in src/relational.jl, not here.

using EarthSciAST
const R = EarthSciAST.Relational
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
            error("determinism_adapter: unknown argument $(repr(a))")
        end
    end
    (manifest === nothing || output === nothing) &&
        error("determinism_adapter: --manifest and --output are required")
    return manifest, output
end

# Recursively convert JSON3 values to native Dict/Vector so the relational
# primitives see plain Julia Int/String/Bool (not lazy JSON3 views).
to_native(x::JSON3.Object) = Dict{String,Any}(string(k) => to_native(v) for (k, v) in x)
to_native(x::JSON3.Array) = Any[to_native(v) for v in x]
to_native(x) = x

# Directed component lists for one payload: faces (consecutive vertices with
# wraparound) or pre-built tuples — mirrors the runner's reference shaping.
function edges_from_payload(payload)
    if haskey(payload, "faces")
        edges = Vector{Any}[]
        for face in payload["faces"]
            n = length(face)
            for i in 1:n
                push!(edges, Any[face[i], face[mod1(i + 1, n)]])
            end
        end
        return edges
    elseif haskey(payload, "tuples")
        return Vector{Any}[collect(Any, t) for t in payload["tuples"]]
    else
        error("payload needs 'faces' or 'tuples'")
    end
end

function compute_payload(fx, payload)
    primitive = fx["primitive"]
    if primitive == "skolem_distinct_rank"
        mode = fx["skolem"]
        edges = edges_from_payload(payload)
        keys = if mode == "undirected"
            [R.skolem_edge(e[1], e[2]) for e in edges]
        elseif mode == "directed"
            [R.skolem(Tuple(e)) for e in edges]
        else
            error("unknown skolem mode $(repr(mode))")
        end
        index_set = R.distinct(keys)
        serialized = R.canonical_index_set_json(keys)
        ranking = R.rank(keys)                       # native 1-based
        dense = [ranking.id[t] for t in index_set]
        return Dict{String,Any}(
            "index_set" => [collect(t) for t in index_set],
            "serialized" => serialized,
            "dense_ids_canonical" => dense,
        )
    elseif primitive == "group_by_sum"
        rows = payload["rows"]
        pairs = R.group_aggregate(rows; key = r -> r[1], value = r -> r[2], op = +)
        # Serialize the (key,sum) pairs in canonical form. Sums here are exact
        # integers, so reusing the index-set serializer over (k,v) tuples is
        # byte-correct (and keys are unique ⇒ no reorder/dedup).
        serialized = R.canonical_index_set_json([(first(p), last(p)) for p in pairs])
        return Dict{String,Any}(
            "index_set" => [[first(p), last(p)] for p in pairs],
            "serialized" => serialized,
            "dense_ids_canonical" => collect(1:length(pairs)),   # native 1-based
        )
    else
        error("unknown primitive $(repr(primitive))")
    end
end

function compute_fixture(fx)
    record = compute_payload(fx, fx["inputs"]["canonical"])
    variants = get(fx["inputs"], "variants", Dict{String,Any}())
    if !isempty(variants)
        record["variants"] = Dict{String,Any}(
            vname => compute_payload(fx, vpayload) for (vname, vpayload) in variants
        )
    end
    return record
end

function main(argv)
    manifest_path, output_path = parse_args(argv)
    manifest = to_native(JSON3.read(read(manifest_path, String)))

    fixtures = Dict{String,Any}()
    for fx in manifest["fixtures"]
        fixtures[fx["id"]] = compute_fixture(fx)
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
