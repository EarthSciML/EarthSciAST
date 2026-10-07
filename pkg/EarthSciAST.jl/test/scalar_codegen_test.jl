# The scalar equations and the prelude as generated code (scalar_codegen.jl).
#
# Under `compiler = :native` the scalar equation list and the three cadence
# tiers of the shared-subexpression prelude run as RuntimeGeneratedFunctions,
# emitted by structure: a box model's boxes are one class of units, emitted once
# as a loop over a per-box table. Pinned here, on a box model whose prelude has
# all three tiers (a parameter-only rate, a time-dependent photolysis-like
# factor, and a per-box product shared by three equations):
#   1. BIT-IDENTITY with `compiler = :interpreter`: du `===` per element on
#      several (u, t, p) probes, the state Jacobian through ForwardDiff, and a
#      chunked call (as threads run it) against the serial one.
#   2. CODE FLAT IN N: the generated functions are the same size at 3 and 7
#      boxes; only the tables grow.
#   3. THE REPORT: every scalar equation lands on `:scalar_codegen`; with the
#      node budget at 0 they stay on the walker and say `:scalar`.
#   4. A unit larger than the per-function node cap keeps its slots in the
#      cache and is split across functions, still bit-identical.
#   5. A warmed Float64 call allocates nothing.
using Test
using EarthSciAST
using ForwardDiff
include("testutils.jl")
const ESM = EarthSciAST

_scg_n(x) = NumExpr(Float64(x))
_scg_v(n) = VarExpr(n)
_scg_op(op, args...) = OpExpr(op, ESM.ASTExpr[args...])
_scg_D(n) = OpExpr("D", ESM.ASTExpr[VarExpr(n)]; wrt="t")

# B boxes of three species each, plus one scalar state reading box 1.
function _scg_model(B::Int)
    vars = Dict{String,ESM.ModelVariable}(
        "k1" => ESM.ModelVariable(ESM.ParameterVariable; default=0.7),
        "k2" => ESM.ModelVariable(ESM.ParameterVariable; default=1.3),
        "Ea" => ESM.ModelVariable(ESM.ParameterVariable; default=2.0),
        "kt" => ESM.ModelVariable(ESM.ParameterVariable; default=0.4),
        "Z" => ESM.ModelVariable(ESM.UnknownVariable; default=0.2))
    eqs = ESM.Equation[]
    rate2() = _scg_op("*", _scg_v("k2"), _scg_op("exp", _scg_op("neg", _scg_v("Ea"))))
    photo() = _scg_op("*", _scg_op("sin", _scg_op("*", _scg_n(0.3), _scg_v("t"))), _scg_v("kt"))
    for b in 1:B
        a, bb, c = "A_$b", "B_$b", "C_$b"
        vars[a] = ESM.ModelVariable(ESM.UnknownVariable; default=0.5 + 0.1b)
        vars[bb] = ESM.ModelVariable(ESM.UnknownVariable; default=0.3 + 0.05b)
        vars[c] = ESM.ModelVariable(ESM.UnknownVariable; default=0.1 + 0.02b)
        r1() = _scg_op("*", _scg_v("k1"), _scg_v(a), _scg_v(bb))
        push!(eqs, ESM.Equation(_scg_D(a),
            _scg_op("+", _scg_op("neg", r1()), _scg_op("*", rate2(), _scg_v(c)),
                    _scg_op("ifelse", _scg_op(">", _scg_v(a), _scg_n(0.6)),
                            _scg_op("*", _scg_n(-0.1), _scg_v(a)), _scg_n(0.0)))))
        push!(eqs, ESM.Equation(_scg_D(bb),
            _scg_op("+", _scg_op("neg", r1()), _scg_op("*", photo(), _scg_v(c)))))
        push!(eqs, ESM.Equation(_scg_D(c),
            _scg_op("-", _scg_op("+", r1(), _scg_op("/", _scg_op("^", _scg_v(a), _scg_n(2.0)),
                                                    _scg_op("+", _scg_n(1.0), _scg_v(bb)))),
                    _scg_op("+", _scg_op("*", rate2(), _scg_v(c)),
                            _scg_op("*", photo(), _scg_v(c))))))
    end
    push!(eqs, ESM.Equation(_scg_D("Z"),
        _scg_op("+", _scg_op("*", _scg_n(-0.1), _scg_v("Z")), _scg_v("A_1"))))
    return ESM.Model(vars, eqs)
end

function _scg_build(model; compiler::Symbol=:native)
    insp = ESM.BuildInspection()
    f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(model; compiler=compiler,
                                                        inspect=insp)
    return (; f!, u0, p, diag, report=insp.compiler_report)
end

_scg_du(f!, u, p, t) = (d = zeros(eltype(u), length(u)); f!(d, u, p, t); d)
_scg_bitsame(a, b) = size(a) == size(b) && all(a .=== b)
_scg_probe(n, k) = Float64[0.4 + 0.3 * sin(1.7i + 0.9k) * cos(0.23i * k) for i in 1:n]
_scg_pmod(p) = map(x -> x isa Float64 ? 1.01x + 1e-3 : x, p)

function _scg_agree(bn, bi)
    n = length(bn.u0)
    for (k, t, pp) in ((1, 0.0, bn.p), (2, 0.8, bn.p), (3, 0.8, _scg_pmod(bn.p)),
                       (4, 2.5, _scg_pmod(bn.p)), (5, 2.5, bn.p))
        u = _scg_probe(n, k)
        _scg_bitsame(_scg_du(bn.f!, u, pp, t), _scg_du(bi.f!, u, pp, t)) || return false
    end
    return true
end

_scg_tiers(rep) = Dict(ESM.tier_histogram(rep))

@testset "scalar equations and prelude as generated code" begin
    @testset "bit-identical with the interpreter ($B boxes)" for B in (1, 3, 7)
        bn = _scg_build(_scg_model(B))
        bi = _scg_build(_scg_model(B); compiler=:interpreter)
        # The fixture exercises every prelude tier.
        @test bn.diag.n_const_slots > 0
        @test bn.diag.n_time_slots > 0
        @test bn.diag.n_dynamic_slots > 0
        @test _scg_agree(bn, bi)
        @test _scg_tiers(bn.report) == Dict(:scalar_codegen => 3B + 1)
        @test _scg_tiers(bi.report) == Dict(:scalar => 3B + 1)
        # A fully emitted build walks no tree.
        @test isempty(getfield(bn.f!, :cse_prelude))
        @test isempty(getfield(bn.f!, :resid_rhs))

        # The state Jacobian: the same generated code at `Dual`.
        u = _scg_probe(length(bn.u0), 6)
        J(f!, p) = ForwardDiff.jacobian((d, uu) -> f!(d, uu, p, 0.8), zeros(length(u)), u)
        @test _scg_bitsame(J(bn.f!, bn.p), J(bi.f!, bi.p))

        # Chunked as the threaded path runs it: chunk c of every generated
        # function, in order, for c in 1:nc, is the serial call.
        dynp = getfield(bn.f!, :dynp)
        cache = ESM._cse_buf(getfield(bn.f!, :cse_cache), Float64)
        d1 = zeros(length(u)); d3 = zeros(length(u))
        bn.f!(d1, u, bn.p, 0.8)                 # fills the const/time tiers
        ESM._run_scgens!(dynp.gens, d1, u, bn.p, 0.8, cache, 1, 1)
        for c in 1:3
            ESM._run_scgens!(dynp.gens, d3, u, bn.p, 0.8, cache, c, 3)
        end
        # Every equation is in the dynamic program, so it writes all of `du`.
        @test _scg_bitsame(d1, d3)
    end

    @testset "the generated code does not grow with the number of boxes" begin
        exprs(f!) = [ESM.RuntimeGeneratedFunctions.get_expression(g.f)
                     for g in getfield(f!, :dynp).gens]
        e3 = exprs(_scg_build(_scg_model(3)).f!)
        e7 = exprs(_scg_build(_scg_model(7)).f!)
        @test length(e3) == length(e7)
        # The same code, node for node: the only difference is the slots a
        # one-member class (here `Z`, laid out after the boxes) bakes in.
        @test map(ESM._cg_expr_size, e3) == map(ESM._cg_expr_size, e7)
    end

    @testset "node budget 0 keeps the walker, and says so" begin
        withenv("ESS_CODEGEN_NODE_BUDGET" => "0") do
            bn = _scg_build(_scg_model(3))
            bi = _scg_build(_scg_model(3); compiler=:interpreter)
            @test _scg_tiers(bn.report) == Dict(:scalar => 10)
            @test !isempty(getfield(bn.f!, :cse_prelude))
            @test _scg_agree(bn, bi)
        end
    end

    @testset "a unit past the node cap is split, slots through the cache" begin
        withenv("ESS_CODEGEN_FN_NODE_CAP" => "12") do
            bn = _scg_build(_scg_model(3))
            bi = _scg_build(_scg_model(3); compiler=:interpreter)
            @test _scg_tiers(bn.report) == Dict(:scalar_codegen => 10)
            @test length(getfield(bn.f!, :dynp).gens) > 1
            @test _scg_agree(bn, bi)
            u = _scg_probe(length(bn.u0), 7)
            J(f!, p) = ForwardDiff.jacobian((d, uu) -> f!(d, uu, p, 0.8),
                                            zeros(length(u)), u)
            @test _scg_bitsame(J(bn.f!, bn.p), J(bi.f!, bi.p))
        end
    end

    if VERSION >= v"1.12"
        @testset "zero allocations per steady call" begin
            bn = _scg_build(_scg_model(5))
            @test rhs_alloc_bytes(bn.f!, zeros(length(bn.u0)), bn.u0, bn.p, 0.8) == 0
        end
    end
end
