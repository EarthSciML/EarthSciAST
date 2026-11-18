# esm-spec §9.6.3 constraint 6 — the rewrite-target gate is a WALK, not a
# reachability test: "before a component is EVALUATED or COMPILED for
# simulation, its expression trees are walked; any node whose `op` is not in the
# evaluable-core set (§4.2) … is rejected with diagnostic `unlowered_operator`".
#
# The tree-walk compiler already refuses an unlowered op in every tree it
# COMPILES. What it never sees is a tree the build discards first: a DEAD
# observed (one nothing reads) is not compiled, and an elementwise array observed
# is folded into its readers and dropped. A rewrite-target op sitting in one of
# those must still be refused, as Python and Rust refuse the same document.
# These tests pin the gate at the document, ahead of any build pass.
#
# The gate is deliberately narrow: it refuses a rewrite-target OP no rule
# lowered, not a dead observed. A dead observed whose body is fully lowered still
# builds (CONFORMANCE_SPEC §5.27.3).

using Test
include("testutils.jl")
using EarthSciAST

const _UW = EarthSciAST

_uw_var(; shape = nothing, default = nothing) = begin
    v = Dict{String, Any}("type" => "unknown", "units" => "1")
    shape === nothing || (v["shape"] = shape)
    default === nothing || (v["default"] = default)
    v
end

# A 0-D box: `c` is a state with a trivial tendency, `extra` an observed nothing
# reads, defined by `extra_rhs`.
function _uw_box(extra_rhs; shaped = false)
    shape = shaped ? ["lev"] : nothing
    doc = Dict{String, Any}(
        "esm" => "2.0.0",
        "metadata" => Dict{String, Any}("name" => "UnloweredWalk", "authors" => ["test"]),
        "models" => Dict{String, Any}(
            "Box" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "c" => _uw_var(; shape = shape, default = 1.0),
                    "extra" => _uw_var(; shape = shape)
                ),
                "equations" => Any[
                    Dict{String, Any}(
                        "lhs" => Dict{String, Any}("op" => "D", "args" => ["c"], "wrt" => "t"),
                        "rhs" => 1.0
                    ),
                    Dict{String, Any}("lhs" => "extra", "rhs" => extra_rhs),
                ]
            )
        )
    )
    shaped && (
        doc["index_sets"] = Dict{String, Any}(
            "lev" => Dict{String, Any}("kind" => "interval", "size" => 4)
        )
    )
    return doc
end

# An unlowered spatial derivative, `D(arg, wrt: x)`.
_uw_dx(arg) = Dict{String, Any}("op" => "D", "args" => Any[arg], "wrt" => "x")

function _uw_error(f)
    try
        f()
        return nothing
    catch e
        return e
    end
end

@testset "§9.6.3 constraint 6: unlowered ops in trees the build discards" begin
    @testset "a dead observed carrying $(name) is refused" for (name, node, needle) in (
            ("a spatial D", _uw_dx("c"), "wrt=x"),
            ("godunov_hamiltonian", jop("godunov_hamiltonian", "c"), "godunov_hamiltonian"),
        )
        err = _uw_error(() -> esm_problem(_uw_box(node), (0.0, 1.0)))
        @test err isa _UW.TreeWalkError
        @test err isa _UW.TreeWalkError && err.code == "unlowered_operator"
        @test err isa _UW.TreeWalkError && occursin(needle, err.detail)
    end

    @testset "a dead elementwise array observed, folded away by the build, is refused" begin
        doc = _uw_box(jop("+", _uw_dx("c"), 1.0); shaped = true)
        err = _uw_error(() -> esm_problem(doc, (0.0, 1.0)))
        @test err isa _UW.TreeWalkError && err.code == "unlowered_operator"
        @test err isa _UW.TreeWalkError && occursin("wrt=x", err.detail)
    end

    @testset "a dead array observed reports unlowered_operator, not a shape error" begin
        doc = _uw_box(_uw_dx("c"); shaped = true)
        err = _uw_error(() -> esm_problem(doc, (0.0, 1.0)))
        @test err isa _UW.TreeWalkError && err.code == "unlowered_operator"
    end

    @testset "an unlowered op in an initial condition is refused" begin
        doc = _uw_box(1.0)
        push!(
            doc["models"]["Box"]["equations"], Dict{String, Any}(
                "lhs" => jop("ic", "c"), "rhs" => jop("godunov_hamiltonian", 2.0)
            )
        )
        err = _uw_error(() -> esm_problem(doc, (0.0, 1.0)))
        @test err isa _UW.TreeWalkError && err.code == "unlowered_operator"
        @test err isa _UW.TreeWalkError && occursin("godunov_hamiltonian", err.detail)
    end

    @testset "the internal build entry refuses it too" begin
        err = _uw_error(() -> EarthSciAST.Internal.build(_uw_box(_uw_dx(_uw_dx("c")))))
        @test err isa _UW.TreeWalkError && err.code == "unlowered_operator"
        @test err isa _UW.TreeWalkError && occursin("wrt=x", err.detail)
    end

    @testset "a dead but fully lowered observed still builds" begin
        prob = esm_problem(_uw_box(jop("*", "c", 2.0)), (0.0, 1.0))
        @test prob !== nothing
    end

    @testset "a structural time D under an equation-LHS faq is still core" begin
        doc = Dict{String, Any}(
            "esm" => "2.0.0",
            "metadata" => Dict{String, Any}("name" => "FaqLhsD", "authors" => ["test"]),
            "index_sets" => Dict{String, Any}("lev" => Dict{String, Any}("kind" => "interval", "size" => 4)),
            "models" => Dict{String, Any}(
                "Column" => Dict{String, Any}(
                    "variables" => Dict{String, Any}("theta" => _uw_var(; shape = ["lev"], default = 1.0)),
                    "equations" => Any[
                        Dict{String, Any}(
                            "lhs" => Dict{String, Any}(
                                "op" => "faq", "args" => Any[], "output_idx" => ["k"],
                                "expr" => Dict{String, Any}(
                                    "op" => "D", "wrt" => "t",
                                    "args" => Any[jop("index", "theta", "k")]
                                ),
                                "ranges" => Dict{String, Any}("k" => Dict{String, Any}("from" => "lev"))
                            ),
                            "rhs" => Dict{String, Any}(
                                "op" => "faq", "args" => Any[], "output_idx" => ["k"],
                                "expr" => 1.0,
                                "ranges" => Dict{String, Any}("k" => Dict{String, Any}("from" => "lev"))
                            )
                        ),
                    ]
                )
            )
        )
        prob = esm_problem(doc, (0.0, 1.0))
        @test prob !== nothing
    end
end
