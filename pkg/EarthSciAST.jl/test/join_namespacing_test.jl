# CROSS-BINDING conformance for §5.5.6 join-name namespacing under flattening.
#
# A relational `join` carries its references as plain STRINGS — an `on` key
# column, and an `overlap` clause's `src_env` / `tgt_env` envelope factors —
# rather than as `VarExpr` children. That is an ENCODING choice, not a scoping
# one: the value-invention materialiser resolves every one of those names
# against the variable registry (`_vi_join_index_sym` → `ctx.variables`,
# `_vi_env_vectors` → `ctx.const_arrays`), and after flattening that registry is
# the dot-namespaced one.
#
# Julia has ALWAYS namespaced them (`namespacing.jl::_namespace_join`), so these
# cases pass before and after the cross-binding alignment. They are the
# REFERENCE the Rust `tests/join_namespacing.rs` and Python
# `tests/test_join_namespacing.py` cases were written against — Rust and Python
# both left `join` bare, so the same document flattened by the three bindings
# produced join clauses that disagreed.
#
# The gate is the component's declared LOCAL names: a key column naming a loop
# symbol or a document-scoped index set is not a local variable and is left
# alone, which is what lets one rule serve `on` and `overlap` alike.

module JoinNamespacingTests

using Test
using EarthSciAST
import JSON3

const ESS = EarthSciAST

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))
const OVERLAP_FIXTURE = joinpath(REPO_ROOT, "pkg", "earthsci-ast-rs", "tests",
                                      "fixtures", "pushdown",
                                      "overlap_gate_point_in_rect.esm")
const JOIN_FILTER_FIXTURE = joinpath(REPO_ROOT, "tests", "valid", "aggregate",
                                     "join_filter.esm")

# The one flattened equation whose RHS carries a `join`.
function producer(flat)
    for eq in flat.equations
        r = eq.rhs
        if r isa ESS.OpExpr && r.join !== nothing && !isempty(r.join)
            return r
        end
    end
    error("no join-bearing equation in the flattened system")
end

@testset "join namespacing under flattening (§5.5.6)" begin

    @testset "overlap envelope factors follow the variable registry" begin
        flat = ESS.flatten(ESS.load(OVERLAP_FIXTURE))
        node = producer(flat)
        clause = node.join[1]
        @test clause isa ESS._OverlapJoinSpec
        @test clause.src_env == ["ISRM.X", "ISRM.Y"]
        @test clause.tgt_env == ["ISRM.W", "ISRM.S", "ISRM.E", "ISRM.N"]

        # The SAME six factors also appear as expression children in `args`, so
        # the two spellings inside one node must agree — the sharpest statement
        # of why these are references and not opaque metadata.
        argnames = sort([a.name for a in node.args if a isa ESS.VarExpr])
        @test argnames == sort(vcat(clause.src_env, clause.tgt_env))

        # ...and that is the registry they must resolve in.
        for n in vcat(clause.src_env, clause.tgt_env)
            @test haskey(flat.parameters, n)
        end
    end

    @testset "the flattened producer materialises the golden support set" begin
        flat = ESS.flatten(ESS.load(OVERLAP_FIXTURE))
        # The ISRM L1 geometry, keyed by the FLATTENED names.
        ca = Dict{String, Any}(
            "ISRM.W" => [0.0, 2.0, 4.0, 0.0, 2.0, 4.0, 0.0, 2.0, 4.0],
            "ISRM.E" => [2.0, 4.0, 6.0, 2.0, 4.0, 6.0, 2.0, 4.0, 6.0],
            "ISRM.S" => [0.0, 0.0, 0.0, 2.0, 2.0, 2.0, 4.0, 4.0, 4.0],
            "ISRM.N" => [2.0, 2.0, 2.0, 4.0, 4.0, 4.0, 6.0, 6.0, 6.0],
            "ISRM.X" => [1.0, 3.0, 1.0, 5.0, 1.5],
            "ISRM.Y" => [1.0, 1.0, 3.0, 5.0, 1.5],
        )
        # Round-trip the flattened system back into a document (the front door
        # the value-invention engine consumes) and materialise it.
        reconstituted = ESS.load(ESS.flattened_to_esm(flat))
        model = first(values(reconstituted.models))
        vi = ESS.materialize_value_invention(model, reconstituted.index_sets, ca,
                                             Dict{String, Float64}())
        @test vi.members["emis_src_cells_faq"] == [1, 2, 4, 9]
    end

    @testset "loop symbols and index sets are NOT namespaced" begin
        # The committed M2 fixture joins two LOOP SYMBOLS (`src`/`fuel`, keys of
        # `ranges`) against two DOCUMENT-scoped index sets. Neither kind is a
        # component-local variable, so the declared-local gate leaves all four
        # alone — the case that makes "namespace every bare string" wrong.
        flat = ESS.flatten(ESS.load(JOIN_FILTER_FIXTURE))
        node = producer(flat)
        @test node.join[1] == [("src", "sourceType"), ("fuel", "fuelType")]
    end

    @testset "a key column naming a local buffer IS namespaced" begin
        d = JSON3.read(read(JOIN_FILTER_FIXTURE, String), Dict{String, Any})
        m = d["models"]["EmissionsAggregate"]
        m["variables"]["src_bin"] = Dict("type" => "parameter")
        m["variables"]["tgt_bin"] = Dict("type" => "parameter")
        m["equations"][1]["rhs"]["join"] = Any[Dict("on" => Any[
            Any["src_bin", "tgt_bin"], Any["src", "sourceType"]])]
        node = producer(ESS.flatten(ESS.load(d)))
        @test node.join[1] == [
            ("EmissionsAggregate.src_bin", "EmissionsAggregate.tgt_bin"),
            ("src", "sourceType"),
        ]
    end

    @testset "variable_map removal carries the join names with it" begin
        # `param_to_var` REMOVES the mapped parameter, so a join still naming it
        # points at a variable the flattened system no longer declares
        # (`_rename_join_names`).
        d = JSON3.read(read(OVERLAP_FIXTURE, String), Dict{String, Any})
        d["models"]["EDGE"] = Dict(
            "variables" => Dict("src_W" => Dict("type" => "parameter",
                                                "shape" => Any["pop_cells"])),
            "equations" => Any[],
        )
        d["coupling"] = Any[Dict("type" => "variable_map",
                                 "from" => "EDGE.src_W",
                                 "to" => "ISRM.W",
                                 "transform" => "param_to_var")]
        flat = ESS.flatten(ESS.load(d))
        @test !haskey(flat.parameters, "ISRM.W")
        clause = producer(flat).join[1]
        @test clause.tgt_env[1] == "EDGE.src_W"
    end

end

end # module
