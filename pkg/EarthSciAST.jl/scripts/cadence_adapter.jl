#!/usr/bin/env julia
# Julia cadence-partition conformance adapter (CONFORMANCE_SPEC.md §5.7). The
# cross-binding harness (scripts/run-cadence-conformance.py at the repository
# root) finds it through $EARTHSCI_CADENCE_ADAPTER_JULIA or as
# earthsci-cadence-adapter-julia on PATH, and calls:
#
#     <adapter> --manifest <manifest.json> --output <result.json>
#
# Each fixture is loaded through `load_path` like any other document and
# classified by the package's cadence classifier (src/cadence.jl), the one the
# build's value-invention guard uses. This file holds only what the conformance
# report needs on top of it: the partition summary (class counts of annotated
# nodes, the materialization frontier) and the CONST-fold kernels over the
# manifest's value inputs (the fixtures are value-free).
#
# test/cadence_test.jl includes this file; the `PROGRAM_FILE` guard at the
# bottom keeps the command-line entry from running under an include.

module CadenceConformanceAdapter

    include(joinpath(@__DIR__, "adapter_support.jl"))

    using EarthSciAST
    using EarthSciAST: CadenceClass, CadenceConst, CadenceContinuous, cadence_class,
        cadence_name, cadence_seeds, check_expect_cadence, continuous_relational_nodes,
        derived_index_set_cycle, child_exprs
    using EarthSciAST.Relational: distinct
    import JSON3

    # One fixture's model with its seeds; `memo` is shared by every walk over it.
    struct Partition
        model::Model
        file::EsmFile
        seeds::Dict{String, CadenceClass}
        memo::IdDict{OpExpr, CadenceClass}
    end

    function load_partition(path::AbstractString, model_name::AbstractString)
        file = load_path(path)
        haskey(file.models, model_name) || error("$path: model $(repr(model_name)) not found")
        model = file.models[model_name]
        seeds = cadence_seeds(model; data_sources = file.data_sources)
        return Partition(model, file, seeds, IdDict{OpExpr, CadenceClass}())
    end

    class(p::Partition, e::ASTExpr) = cadence_class(e, p.seeds, p.memo)

    # Every equation right-hand side that is an operator node: the computations
    # the partition classifies (the left-hand side is the output target).
    rhs_nodes(p::Partition) = OpExpr[eq.rhs for eq in p.model.equations if eq.rhs isa OpExpr]

    """
        definition_nodes(p) -> IdSet of the right-hand sides that define a scalar observed

    An observed unknown's definition is classified (its `expect_cadence`
    annotations are checked and counted) but is not an output-buffer
    materialization point: its value folds into whatever reads it, which is what
    its leaf seed expresses.

    Only the bare-variable left-hand side `y ~ …` counts here, narrower than the
    seed rule, which reads a definition at any rank (esm-spec §6.3.1). The seed
    rule asks which unknown an equation defines; this asks which definition is
    inlined into its readers rather than written to a buffer. An arrayed
    definition (`y[i] ~ …`, `faq{i}(y[i]) ~ …`) materializes into a buffer its
    consumers index, so it keeps its output-buffer point. Python's
    `inlined_unknowns` draws the same line.
    """
    function definition_nodes(p::Partition)
        out = Base.IdSet{OpExpr}()
        for eq in p.model.equations
            (eq.lhs isa VarExpr && eq.rhs isa OpExpr) || continue
            v = get(p.model.variables, eq.lhs.name, nothing)
            (v !== nothing && v.type == UnknownVariable) && push!(out, eq.rhs)
        end
        return out
    end

    # Annotated nodes (those carrying `expect_cadence`) by derived class: the
    # golden `class_summary`.
    function tally_classes!(counts::Dict{String, Int}, p::Partition, e::ASTExpr)
        EarthSciAST.foreach_subexpr(e) do node
            (node isa OpExpr && node.expect_cadence !== nothing) || return
            c = cadence_name(class(p, node))
            counts[c] = get(counts, c, 0) + 1
        end
        return counts
    end

    # The expression-edge materialization frontier (§5.7.4): an operator child
    # whose class is strictly lower than its parent's is a cut, recorded without
    # descending into it. A literal or variable leaf is not a buffer.
    function materialization_frontier!(out::Vector{Any}, p::Partition, node::OpExpr)
        parent = class(p, node)
        for c in child_exprs(node)
            c isa OpExpr || continue
            cc = class(p, c)
            if cc < parent
                push!(
                    out, Dict{String, Any}(
                        "threshold" => "$(cadence_name(cc))->$(cadence_name(parent))",
                        "kind" => "expr_edge",
                        "op" => c.op
                    )
                )
            else
                materialization_frontier!(out, p, c)
            end
        end
        return out
    end

    """
        partition_model(p::Partition) -> NamedTuple

    The §5.7 partition of one model:

    - `class_summary::Dict{String,Int}`: annotated nodes by derived class.
    - `materialization_points::Vector`: the expression-edge cuts plus one
      `output_buffer` per equation whose right-hand side classifies below
      `continuous` (it folds out of the hot path into the artifact or the
      per-event handler).
    - `hot_tree_empty::Bool`: no `continuous` per-step work.
    - `event_handler_empty::Bool`: no `discrete` per-event materialization.
    - `problems::Vector{String}`: `expect_cadence` disagreements (guard 3).

    The relational guards are [`run_guards`](@ref)'s.
    """
    function partition_model(p::Partition)
        counts = Dict("const" => 0, "discrete" => 0, "continuous" => 0)
        problems = String[]
        points = Any[]
        rhss = rhs_nodes(p)
        definitions = definition_nodes(p)
        for rhs in rhss
            append!(problems, check_expect_cadence(rhs, p.seeds, p.memo))
            tally_classes!(counts, p, rhs)
            materialization_frontier!(points, p, rhs)
            rhs in definitions && continue
            rc = class(p, rhs)
            rc < CadenceContinuous && push!(
                points, Dict{String, Any}(
                    "threshold" => "$(cadence_name(rc))->artifact",
                    "kind" => "output_buffer"
                )
            )
        end
        return (
            class_summary = counts, materialization_points = points,
            hot_tree_empty = !any(rhs -> class(p, rhs) === CadenceContinuous, rhss),
            event_handler_empty = !any(x -> startswith(x["threshold"], "discrete"), points),
            problems = problems,
        )
    end

    """
        run_guards(p::Partition)

    The §5.7.6 checked guards: the `expect_cadence` assertion (guard 3), no
    `continuous` relational node (guard 2) and acyclic derived index sets
    (guard 1). Throws `ErrorException` naming the first violation.
    """
    function run_guards(p::Partition)
        for rhs in rhs_nodes(p)
            problems = check_expect_cadence(rhs, p.seeds, p.memo)
            isempty(problems) || error(first(problems))
            for node in continuous_relational_nodes(rhs, p.seeds, p.memo)
                error(
                    "relational node op=$(repr(node.op)) classifies continuous: it may " *
                        "not run on the per-step hot path (§5.7 guard 2)"
                )
            end
        end
        cycle = derived_index_set_cycle(values(p.file.models), p.file.index_sets)
        cycle === nothing || error(
            "cycle among derived index sets (an implicit solve, §5.7 guard 1): " *
                join(cycle, " -> ")
        )
        return
    end

    # ── CONST-fold kernels (§5.7.4) ─────────────────────────────────────────────
    #
    # The buffers the frontier cut folds out of the hot path. The topology folds
    # (edge enumeration, dense ranking) run through `Relational.distinct`, so the
    # bytes follow the §5.5 determinism contract; the array reshapes are local.

    """
        canonical_serialize(value) -> String

    Canonical byte form of a folded buffer: compact JSON, integers as bare
    digits, nested arrays and tuples as JSON arrays (the §5.5.3 discipline).
    Compared byte for byte across bindings.
    """
    canonical_serialize(x::Bool) = x ? "true" : "false"
    canonical_serialize(x::Integer) = string(x)
    canonical_serialize(v::AbstractVector) = "[" * join((canonical_serialize(e) for e in v), ",") * "]"
    canonical_serialize(t::Tuple) = "[" * join((canonical_serialize(e) for e in t), ",") * "]"

    fold_to_zero_based(arr) = [[x - 1 for x in row] for row in arr]
    fold_identity(arr) = arr

    """The unique edges of the (lo, hi) endpoint tables: each pair canonicalised
    (undirected → sorted), then `distinct` sorts by the total order and drops
    adjacent duplicates (§5.5 rules 2 and 4); a float component is refused
    (`FloatKeyError`, §5.5 rule 1)."""
    function fold_edge_enumeration(face_lo, face_hi, mode)
        pairs = Tuple[]
        for (flo, fhi) in zip(face_lo, face_hi), (lo, hi) in zip(flo, fhi)
            push!(pairs, mode == "undirected" && hi < lo ? (hi, lo) : (lo, hi))
        end
        return distinct(pairs)
    end

    """Dense 0-based ids over the enumerated edge set."""
    fold_rank(face_lo, face_hi, mode) =
        collect(0:(length(fold_edge_enumeration(face_lo, face_hi, mode)) - 1))

    """
        compute_fold(label, spec, inputs) -> value

    The named `const`-fold kernel (`spec["fold"]`) over the manifest's concrete
    `const_fold.inputs`; [`canonical_serialize`](@ref) gives the bytes the
    golden pins.
    """
    function compute_fold(label, spec, inputs)
        kind = get(spec, "fold", nothing)
        kind == "to_zero_based" && return fold_to_zero_based(inputs[get(spec, "array", label)])
        kind == "identity" && return fold_identity(inputs[get(spec, "array", label)])
        mode = get(inputs, "skolem", "undirected")
        kind == "edge_enumeration" &&
            return fold_edge_enumeration(inputs["face_lo"], inputs["face_hi"], mode)
        kind == "rank" && return fold_rank(inputs["face_lo"], inputs["face_hi"], mode)
        return error("buffer $(repr(label)): unknown fold kind $(repr(kind))")
    end

    # ── Command-line entry ──────────────────────────────────────────────────────

    # Fixture paths in the manifest are relative to the repository root, three
    # directories above <root>/tests/conformance/cadence/manifest.json.
    repo_root_of(manifest_path) =
        normpath(joinpath(dirname(abspath(manifest_path)), "..", "..", ".."))

    function partition_fixture(fx, repo_root)
        p = load_partition(joinpath(repo_root, fx["fixture"]), fx["model"])
        # Guards must hold on a valid fixture; a violation is a real failure.
        run_guards(p)
        r = partition_model(p)
        isempty(r.problems) || error("cadence_adapter [$(fx["id"])]: " * join(r.problems, "; "))
        buffers = Dict{String, Any}()
        cf = get(fx, "const_fold", Dict{String, Any}())
        inputs = get(cf, "inputs", Dict{String, Any}())
        for (label, spec) in get(cf, "expected", Dict{String, Any}())
            buffers[label] = canonical_serialize(compute_fold(label, spec, inputs))
        end
        return Dict{String, Any}(
            "class_summary" => r.class_summary,
            "materialization_points" => r.materialization_points,
            "const_fold_buffers" => buffers,
        )
    end

    function main(argv)
        args = parse_cli(argv; required = ("--manifest", "--output"))
        manifest = to_native(JSON3.read(read(args["--manifest"], String)))
        repo_root = repo_root_of(args["--manifest"])
        fixtures = Dict{String, Any}()
        for fx in manifest["fixtures"]
            fixtures[fx["id"]] = partition_fixture(fx, repo_root)
        end
        write_report(
            args["--output"],
            JSON3.write(Dict{String, Any}("binding" => "julia", "fixtures" => fixtures))
        )
        return 0
    end

end # module CadenceConformanceAdapter

if abspath(PROGRAM_FILE) == @__FILE__
    exit(CadenceConformanceAdapter.main(ARGS))
end
