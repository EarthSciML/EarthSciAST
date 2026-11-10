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
_scg_D(n) = OpExpr("D", ESM.ASTExpr[VarExpr(n)]; wrt = "t")

# B boxes of three species each, plus one scalar state reading box 1.
function _scg_model(B::Int)
    vars = Dict{String, ESM.ModelVariable}(
        "k1" => ESM.ModelVariable(ESM.ParameterVariable; default = 0.7),
        "k2" => ESM.ModelVariable(ESM.ParameterVariable; default = 1.3),
        "Ea" => ESM.ModelVariable(ESM.ParameterVariable; default = 2.0),
        "kt" => ESM.ModelVariable(ESM.ParameterVariable; default = 0.4),
        "Z" => ESM.ModelVariable(ESM.UnknownVariable; default = 0.2)
    )
    eqs = ESM.Equation[]
    rate2() = _scg_op("*", _scg_v("k2"), _scg_op("exp", _scg_op("neg", _scg_v("Ea"))))
    photo() = _scg_op("*", _scg_op("sin", _scg_op("*", _scg_n(0.3), _scg_v("t"))), _scg_v("kt"))
    for b in 1:B
        a, bb, c = "A_$b", "B_$b", "C_$b"
        vars[a] = ESM.ModelVariable(ESM.UnknownVariable; default = 0.5 + 0.1b)
        vars[bb] = ESM.ModelVariable(ESM.UnknownVariable; default = 0.3 + 0.05b)
        vars[c] = ESM.ModelVariable(ESM.UnknownVariable; default = 0.1 + 0.02b)
        r1() = _scg_op("*", _scg_v("k1"), _scg_v(a), _scg_v(bb))
        push!(
            eqs, ESM.Equation(
                _scg_D(a),
                _scg_op(
                    "+", _scg_op("neg", r1()), _scg_op("*", rate2(), _scg_v(c)),
                    _scg_op(
                        "ifelse", _scg_op(">", _scg_v(a), _scg_n(0.6)),
                        _scg_op("*", _scg_n(-0.1), _scg_v(a)), _scg_n(0.0)
                    )
                )
            )
        )
        push!(
            eqs, ESM.Equation(
                _scg_D(bb),
                _scg_op("+", _scg_op("neg", r1()), _scg_op("*", photo(), _scg_v(c)))
            )
        )
        push!(
            eqs, ESM.Equation(
                _scg_D(c),
                _scg_op(
                    "-", _scg_op(
                        "+", r1(), _scg_op(
                            "/", _scg_op("^", _scg_v(a), _scg_n(2.0)),
                            _scg_op("+", _scg_n(1.0), _scg_v(bb))
                        )
                    ),
                    _scg_op(
                        "+", _scg_op("*", rate2(), _scg_v(c)),
                        _scg_op("*", photo(), _scg_v(c))
                    )
                )
            )
        )
    end
    push!(
        eqs, ESM.Equation(
            _scg_D("Z"),
            _scg_op("+", _scg_op("*", _scg_n(-0.1), _scg_v("Z")), _scg_v("A_1"))
        )
    )
    return ESM.Model(vars, eqs)
end

function _scg_build(model; compiler = :native)
    insp = ESM.BuildInspection()
    f!, u0, p, _t, vm, diag = ESM._build_evaluator_impl(
        model; compiler = compiler,
        inspect = insp
    )
    return (; f!, u0, p, diag, report = insp.compiler_report)
end

_scg_du(f!, u, p, t) = (d = zeros(eltype(u), length(u)); f!(d, u, p, t); d)
_scg_bitsame(a, b) = size(a) == size(b) && all(a .=== b)
_scg_probe(n, k) = Float64[0.4 + 0.3 * sin(1.7i + 0.9k) * cos(0.23i * k) for i in 1:n]
_scg_pmod(p) = map(x -> x isa Float64 ? 1.01x + 1.0e-3 : x, p)

function _scg_agree(bn, bi)
    n = length(bn.u0)
    for (k, t, pp) in (
            (1, 0.0, bn.p), (2, 0.8, bn.p), (3, 0.8, _scg_pmod(bn.p)),
            (4, 2.5, _scg_pmod(bn.p)), (5, 2.5, bn.p),
        )
        u = _scg_probe(n, k)
        _scg_bitsame(_scg_du(bn.f!, u, pp, t), _scg_du(bi.f!, u, pp, t)) || return false
    end
    return true
end

_scg_tiers(rep) = Dict(ESM.tier_histogram(rep))

# S scalar template call sites over per-site constant tables, summed into one
# observed `acc` that `D(u)` reads (a second state `w` reads site 1 alone).
# `odd`: the aliasing, non-ascending and repeated axes of the per-member testset.
_scg_jop(o, a...; kw...) = Dict{String, Any}("op" => o, "args" => Any[a...], (String(k) => v for (k, v) in kw)...)
_scg_jconst(v) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => v)
function _scg_sites_doc(S::Int; odd::Bool = false)
    vars = Dict{String, Any}(
        "u" => Dict("type" => "unknown", "default" => 0.0),
        "w" => Dict("type" => "unknown", "default" => 0.5),
        "acc" => Dict("type" => "unknown")
    )
    eqs = Any[]
    sites = Any[]
    for i in 1:S
        x = _scg_jop("+", _scg_jop("+", "u", 0.001 * i), _scg_jop("*", 0.001, "t"))
        ax = [0.5 * k + 0.01 * i for k in 1:8]
        tab = [sin(0.7k + i) for k in 1:8]
        if odd && (i == 1 || i == 5)
            tab = copy(ax)
        elseif odd && i == 7
            ax[3], ax[6] = ax[6], ax[3]
        elseif odd && i == 9
            ax[4] = ax[5]
        end
        site = if i % 3 == 0
            ay = [0.25 * k + 0.02 * i for k in 1:8]
            tb = [[cos(0.3k + 0.11j + i) for j in 1:8] for k in 1:8]
            Dict{String, Any}(
                "op" => "apply_expression_template", "args" => Any[], "name" => "bilinear",
                "bindings" => Dict{String, Any}(
                    "table" => _scg_jconst(tb), "axis_x" => _scg_jconst(ax),
                    "axis_y" => _scg_jconst(ay), "x" => _scg_jop("+", 2.5, x),
                    "y" => _scg_jop("+", 1.25, x), "nx" => 8, "ny" => 8
                )
            )
        else
            Dict{String, Any}(
                "op" => "apply_expression_template", "args" => Any[], "name" => "linear",
                "bindings" => Dict{String, Any}(
                    "table" => _scg_jconst(tab), "axis" => _scg_jconst(ax),
                    "x" => _scg_jop("+", 2.0 + 0.37 * (i % 5), x), "n" => 8
                )
            )
        end
        vars["r$i"] = Dict("type" => "unknown")
        push!(eqs, Dict("lhs" => "r$i", "rhs" => site))
        push!(sites, "r$i")
    end
    push!(eqs, Dict("lhs" => "acc", "rhs" => length(sites) == 1 ? sites[1] : _scg_jop("+", sites...)))
    push!(eqs, Dict("lhs" => _scg_jop("D", "u"; wrt = "t"), "rhs" => _scg_jop("-", _scg_jop("*", 1.0e-3, "acc"), "u")))
    push!(eqs, Dict("lhs" => _scg_jop("D", "w"; wrt = "t"), "rhs" => _scg_jop("-", "r1", "w")))
    imports = Any[
        Dict("ref" => joinpath(TESTUTILS_REPO_ROOT, "lib", "interp.esm"), "only" => Any["linear", "bilinear"]),
    ]
    model = Dict{String, Any}("variables" => vars, "equations" => eqs, "expression_template_imports" => imports)
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict("name" => "sites_$S", "description" => "scalar template sites"),
        "models" => Dict("M" => model)
    )
end
function _scg_sites_build(S::Int; odd::Bool = false, compiler = :native)
    path = joinpath(mktempdir(), "sites.esm")
    write(path, JSON3.write(_scg_sites_doc(S; odd = odd)))
    prob = ESM.esm_problem(path, (0.0, 1.0); compiler = compiler)
    return (; f! = prob.f!, u0 = prob.u0, p = prob.p)
end
function _scg_sites_agree(bn, bi)
    for (k, t) in ((1, 0.0), (2, 0.7), (3, 1.3), (4, 1800.0))
        u = bn.u0 .+ 0.37k .* sin.(0.3 .* (1:length(bn.u0)) .+ k)
        _scg_bitsame(_scg_du(bn.f!, u, bn.p, t), _scg_du(bi.f!, u, bi.p, t)) || return false
    end
    return true
end

@testset "scalar equations and prelude as generated code" begin
    @testset "bit-identical with the interpreter ($B boxes)" for B in (1, 3, 7)
        bn = _scg_build(_scg_model(B))
        bi = _scg_build(_scg_model(B); compiler = :interpreter)
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
        exprs(f!) = [
            ESM.RuntimeGeneratedFunctions.get_expression(g.f)
                for g in getfield(f!, :dynp).gens
        ]
        e3 = exprs(_scg_build(_scg_model(3)).f!)
        e7 = exprs(_scg_build(_scg_model(7)).f!)
        @test length(e3) == length(e7)
        # The same code, node for node: the only difference is the slots a
        # one-member class (here `Z`, laid out after the boxes) bakes in.
        @test map(ESM._cg_expr_size, e3) == map(ESM._cg_expr_size, e7)
    end

    @testset "node budget 0: native refuses the walker by name" begin
        # Past the emitted-node budget every class stays on the scalar walker,
        # which is the interpreter's: strict native refuses the document,
        # naming the first walked equation's state, and the interpreter runs it.
        withenv("ESS_CODEGEN_NODE_BUDGET" => "0") do
            err = try
                _scg_build(_scg_model(3)); nothing
            catch e
                e
            end
            @test err isa ESM.TreeWalkError
            @test err.code == ESM.ERROR_CODES.COMPILER_REFUSED_RULE
            @test occursin("compiler=:native refuses 'A_1'", err.detail)
            @test occursin("could not be modelled by the scalar code generator", err.detail)
            @test occursin("scalar equation", err.detail)
            bi = _scg_build(_scg_model(3); compiler = :interpreter)
            @test all(isfinite, _scg_du(bi.f!, bi.u0, bi.p, 0.8))
            # A non-strict native keeps the walker, says so in its report, and
            # agrees with the interpreter bit for bit.
            lax = ESM._plan_with(ESM._compiler_plan(:native); strict = false)
            bl = _scg_build(_scg_model(3); compiler = lax)
            @test _scg_tiers(bl.report) == Dict(:scalar => 10)
            @test !isempty(getfield(bl.f!, :cse_prelude))
            @test _scg_agree(bl, bi)
        end
    end

    @testset "a unit past the node cap is split, slots through the cache" begin
        withenv("ESS_CODEGEN_FN_NODE_CAP" => "12") do
            bn = _scg_build(_scg_model(3))
            bi = _scg_build(_scg_model(3); compiler = :interpreter)
            @test _scg_tiers(bn.report) == Dict(:scalar_codegen => 10)
            @test length(getfield(bn.f!, :dynp).gens) > 1
            @test _scg_agree(bn, bi)
            u = _scg_probe(length(bn.u0), 7)
            J(f!, p) = ForwardDiff.jacobian(
                (d, uu) -> f!(d, uu, p, 0.8),
                zeros(length(u)), u
            )
            @test _scg_bitsame(J(bn.f!, bn.p), J(bi.f!, bi.p))
        end
    end

    @testset "a 10^4-term scalar sum compiles, and keeps its order" begin
        # One scalar equation whose right-hand side is a single 10 000-term
        # `+`: emitted as a nested call it is 10^4 levels deep, past what
        # Julia's lowering takes, so the fold is emitted as an accumulation.
        nx, nt = 7, 10_000
        vars = Dict{String, ESM.ModelVariable}(
            "S" => ESM.ModelVariable(ESM.UnknownVariable; default = 0.0),
            "kx" => ESM.ModelVariable(ESM.ParameterVariable; default = -0.5)
        )
        eqs = ESM.Equation[]
        for k in 1:nx
            vars["X_$k"] = ESM.ModelVariable(ESM.UnknownVariable; default = 0.1k)
            push!(eqs, ESM.Equation(_scg_D("X_$k"), _scg_op("*", _scg_v("kx"), _scg_v("X_$k"))))
        end
        # Catastrophic magnitudes with sign flips: a reassociated sum would not
        # reproduce these bit for bit.
        terms = ESM.ASTExpr[
            _scg_op(
                "*", _scg_n((isodd(j) ? 1.0 : -1.0) * 10.0^((j * 7) % 17 - 8)),
                _scg_v("X_$(1 + j % nx)")
            ) for j in 1:nt
        ]
        push!(eqs, ESM.Equation(_scg_D("S"), OpExpr("+", terms)))
        m = ESM.Model(vars, eqs)
        bn = _scg_build(m)
        bi = _scg_build(m; compiler = :interpreter)
        @test _scg_tiers(bn.report)[:scalar_codegen] == nx + 1
        @test _scg_agree(bn, bi)
    end

    if VERSION >= v"1.12"
        @testset "zero allocations per steady call" begin
            bn = _scg_build(_scg_model(5))
            @test rhs_alloc_bytes(bn.f!, zeros(length(bn.u0)), bn.u0, bn.p, 0.8) == 0
        end
    end

    @testset "one sum of many large alike terms is cut into a class of terms" begin
        # S template call sites (`linear`, and `bilinear` for every third),
        # each its own observed over per-site constant tables, summed into
        # one observed that one equation reads: one unit of ~S large terms.
        # Cut at the large slots, the terms of each template are one class
        # whose tables are per-member holes, and the sum runs a level later.
        tiny = _scg_sites_build(1)
        @test getfield(tiny.f!, :dynp) isa ESM._ScalarProgram     # small: not cut
        for S in (12, 24)
            bn = _scg_sites_build(S)
            bi = _scg_sites_build(S; compiler = :interpreter)
            @test getfield(bn.f!, :dynp) isa ESM._ScalarLevels
            @test _scg_sites_agree(bn, bi)
            u = bn.u0 .+ 0.25
            J(b) = ForwardDiff.jacobian((d, uu) -> b.f!(d, uu, b.p, 0.8), zeros(length(u)), u)
            @test _scg_bitsame(J(bn), J(bi))
            # Each level chunked as the threaded path runs it.
            cache = ESM._cse_buf(getfield(bn.f!, :cse_cache), Float64)
            d1 = zeros(length(u)); d3 = zeros(length(u))
            bn.f!(d1, u, bn.p, 0.8)
            for P in getfield(bn.f!, :dynp).progs
                ESM._run_scgens!(P.gens, d1, u, bn.p, 0.8, cache, 1, 1)
            end
            for P in getfield(bn.f!, :dynp).progs, c in 1:3
                ESM._run_scgens!(P.gens, d3, u, bn.p, 0.8, cache, c, 3)
            end
            @test _scg_bitsame(d1, d3)
        end
        # The terms' code is the same at 12 and 24 sites (only the tables
        # grow); the sum reads each term, so it grows with them.
        sz(b) = [
            [ESM._cg_expr_size(ESM.RuntimeGeneratedFunctions.get_expression(g.f)) for g in P.gens]
                for P in getfield(b.f!, :dynp).progs
        ]
        # A site reads each of its tables at many subscripts; the reads of one
        # table are one per-member array (two tables per `linear` site, three
        # per `bilinear` one), so the repeated reads in a body still share.
        b12 = _scg_sites_build(12)
        code = join(
            string(ESM.RuntimeGeneratedFunctions.get_expression(g.f))
                for g in getfield(b12.f!, :dynp).progs[1].gens
        )
        @test length(unique(m.match for m in eachmatch(r"_cgot\d+", code))) <= 5
        s12, s24 = sz(b12), sz(_scg_sites_build(24))
        @test length(s12) == length(s24) >= 2
        @test s12[1] == s24[1]
        @test sum(sum, s12[2:end]) < sum(s12[1])
        if VERSION >= v"1.12"
            b = _scg_sites_build(12)
            @test rhs_alloc_bytes(b.f!, zeros(length(b.u0)), b.u0, b.p, 0.8) == 0
        end
    end

    @testset "per-member tables: aliasing, unsorted and repeated axes" begin
        # Sites 1 (the class representative) and 5 read equal arrays as their
        # table and their axis (equal reads in them, not in the others), site 7's
        # axis does not ascend (the counted bracket searches a sorted copy,
        # per member) and site 9's repeats an entry.
        for S in (12, 13)
            bn = _scg_sites_build(S; odd = true)
            bi = _scg_sites_build(S; odd = true, compiler = :interpreter)
            @test _scg_sites_agree(bn, bi)
        end
    end
end
