#!/usr/bin/env julia
# Julia cadence-partition conformance adapter (CONFORMANCE_SPEC.md §5.7, bead
# ess-my4.3.7). The bridge the cross-binding cadence harness
# (scripts/run-cadence-conformance.py) invokes to exercise the Julia
# partition pass over the shared §6.1 fixtures.
# The runner discovers it via $EARTHSCI_CADENCE_ADAPTER_JULIA or as
# earthsci-cadence-adapter-julia on PATH, and calls:
#
#     <adapter> --manifest <manifest.json> --output <result.json>
#
# For each fixture it runs the partition pass over the .esm model (class summary,
# materialization frontier, guards) and the CONST-fold kernels over the
# manifest's value inputs (the fixtures are value-free), then writes the class
# map, materialization-point threshold set, and byte-identical CONST-folded
# buffers.
#
# The CLASSIFIER (classify / seed_leaf / the checked guards) lives in
# src/cadence.jl — the conformance-only raw-JSON half of the §5.7 contract.
# The PASS DRIVER (`partition_model`, `run_guards`) and the CONST-fold kernels
# (`compute_fold`, `canonical_serialize`, `fold_*`) live HERE: they are
# consumed only by this adapter and test/cadence_test.jl (which `include`s this
# file — the `PROGRAM_FILE` guard at the bottom keeps the CLI entry from firing
# under an include). The production build path classifies on the typed IR
# (value_invention.jl) and never touches any of this.

module CadenceConformanceAdapter

using EarthSciAST
using EarthSciAST.Relational: skolem_edge, distinct
const C = EarthSciAST.Cadence
import JSON3

# ── The §5.7 pass (moved from src/cadence.jl) ───────────────────────────────

"""Yield every equation-RHS root expression (the computations the partition
classifies; the LHS is the output target)."""
function model_nodes(model)
    out = Any[]
    for eq in get(model, "equations", Any[])
        rhs = get(eq, "rhs", nothing)
        isa(rhs, AbstractDict) && push!(out, rhs)
    end
    return out
end

"""
    partition_model(model::AbstractDict) -> NamedTuple

Run the §5.7 partition over one model (a raw-JSON model dict). Returns:

- `class_summary::Dict{String,Int}` — annotated nodes by derived class.
- `materialization_points::Vector` — the frontier: expr-edge cuts (a
  lower-cadence sub-DAG feeding a higher-cadence parent) plus one
  `output_buffer` per equation whose RHS folds out of the hot path entirely
  (class `⊏ continuous` → `const`/`discrete`→`artifact`).
- `hot_tree_empty::Bool` — no `continuous` per-step work (a pure-topology rule).
- `event_handler_empty::Bool` — no `discrete` per-event materialization.
- `problems::Vector{String}` — `expect_cadence` disagreements (guard 3).

This is the classification half. The relational guards
(`assert_no_continuous_relational`, `assert_acyclic_index_sets`)
are applied separately by [`run_guards`](@ref).
"""
function partition_model(model::AbstractDict)
    counts = Dict("const" => 0, "discrete" => 0, "continuous" => 0)
    problems = String[]
    points = Any[]
    rhss = model_nodes(model)
    # One shared memo across every walker: each node's class is derived once
    # per pass (see Cadence.ClassMemo).
    memo = C.ClassMemo()
    for rhs in rhss
        C.check_expect_cadence!(rhs, model, problems, memo)
        C.tally_classes!(rhs, model, counts, memo)
        C.materialization_frontier!(rhs, model, points, memo)
        # Output-buffer cut: an equation whose RHS classifies below `continuous`
        # folds out of the per-step hot path entirely (the observed-variable
        # elimination) — into the artifact (`const`) or the per-event handler
        # (`discrete`). That whole RHS is a materialization point.
        rc = C.classify(rhs, model, memo)
        if C.CLASS_RANK[rc] < C.CLASS_RANK["continuous"]
            push!(points, Dict{String,Any}(
                "threshold" => "$(rc)->artifact",
                "kind" => "output_buffer"))
        end
    end
    hot_tree_empty = !any(C.has_continuous(rhs, model, memo) for rhs in rhss)
    event_handler_empty = !any(startswith(p["threshold"], "discrete") for p in points)
    return (class_summary=counts, materialization_points=points,
        hot_tree_empty=hot_tree_empty, event_handler_empty=event_handler_empty,
        problems=problems)
end

"""
    run_guards(model)

Apply the §5.7.6 checked guards over a model: the `expect_cadence` assertion
(guard 3), no-continuous-relational (guard 2), and index-set acyclicity (guard
1). Throws `Cadence.CadenceError` on the first violation.
"""
function run_guards(model)
    problems = String[]
    memo = C.ClassMemo()
    for rhs in model_nodes(model)
        C.check_expect_cadence!(rhs, model, problems, memo)
        C.assert_no_continuous_relational(rhs, model, memo)
    end
    isempty(problems) || throw(C.CadenceError(first(problems)))
    C.assert_acyclic_index_sets(model)
    return
end

# ── CONST-fold kernels (§5.7.4; moved from src/cadence.jl) ───────────────────
#
# The buffers the frontier cut folds out of the hot path. Topology folds
# (edge enumeration, dense ranking) reuse the `Relational` engine so the bytes
# match the §5.5 determinism contract; the array reshapes are local.

"""
    canonical_serialize(value) -> String

Canonical byte form of a folded buffer: compact JSON (`,`/`:` separators, no
spaces), integers as bare digits, nested arrays/tuples as JSON arrays — the same
canonical-JSON discipline §5.5.3 and the round-trip / determinism contracts
require. Compared byte-for-byte across bindings.
"""
canonical_serialize(x::Bool) = x ? "true" : "false"
canonical_serialize(x::Integer) = string(x)
canonical_serialize(v::AbstractVector) = "[" * join((canonical_serialize(e) for e in v), ",") * "]"
canonical_serialize(t::Tuple) = "[" * join((canonical_serialize(e) for e in t), ",") * "]"

fold_to_zero_based(arr) = [[x - 1 for x in row] for row in arr]
fold_identity(arr) = arr

"""Enumerate the unique edges from the (lo, hi) endpoint tables: `skolem_edge`
canonicalises each pair (undirected → sorted), `distinct` sorts by the total
order and drops adjacent duplicates (§5.5 rules 2 & 4). Identical to the
determinism `edge_enumeration` reference."""
function fold_edge_enumeration(face_lo, face_hi, mode)
    pairs = Tuple[]
    for (flo, fhi) in zip(face_lo, face_hi)
        for (lo, hi) in zip(flo, fhi)
            (isa(lo, AbstractFloat) || isa(hi, AbstractFloat)) &&
                throw(C.CadenceError("float component forbidden in a topology key (§5.5 rule 1)"))
            push!(pairs, mode == "undirected" ? skolem_edge(lo, hi) : (lo, hi))
        end
    end
    return distinct(pairs)
end

"""Dense 0-based ids over the enumerated edge set (the array-backend index)."""
function fold_rank(face_lo, face_hi, mode)
    edges = fold_edge_enumeration(face_lo, face_hi, mode)
    return collect(0:(length(edges)-1))
end

"""
    compute_fold(label, spec, inputs) -> value

Apply the named `const`-fold kernel (`spec["fold"]`) over the concrete `inputs`
(the manifest's `const_fold.inputs` — the fixtures themselves are value-free).
Returns the folded value; pass it through [`canonical_serialize`](@ref) for the
byte form the golden pins.
"""
function compute_fold(label, spec, inputs)
    kind = get(spec, "fold", nothing)
    if kind == "to_zero_based"
        return fold_to_zero_based(inputs[get(spec, "array", label)])
    elseif kind == "identity"
        return fold_identity(inputs[get(spec, "array", label)])
    elseif kind == "edge_enumeration"
        return fold_edge_enumeration(inputs["face_lo"], inputs["face_hi"],
            get(inputs, "skolem", "undirected"))
    elseif kind == "rank"
        return fold_rank(inputs["face_lo"], inputs["face_hi"],
            get(inputs, "skolem", "undirected"))
    end
    throw(C.CadenceError("buffer $(repr(label)): unknown fold kind $(repr(kind))"))
end

# ── CLI entry (the harness bridge) ──────────────────────────────────────────

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
    run_guards(model)

    r = partition_model(model)
    isempty(r.problems) || error("cadence_adapter [$(fx["id"])]: " * join(r.problems, "; "))

    # CONST-fold buffers from the manifest's value inputs (fixtures are value-free).
    buffers = Dict{String,Any}()
    cf = get(fx, "const_fold", Dict{String,Any}())
    inputs = get(cf, "inputs", Dict{String,Any}())
    for (label, spec) in get(cf, "expected", Dict{String,Any}())
        buffers[label] = canonical_serialize(compute_fold(label, spec, inputs))
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

end # module CadenceConformanceAdapter

# Run the CLI only when invoked as a script (the harness path); an `include`
# from cadence_test.jl gets the module's functions without the exit.
if abspath(PROGRAM_FILE) == @__FILE__
    exit(CadenceConformanceAdapter.main(ARGS))
end
