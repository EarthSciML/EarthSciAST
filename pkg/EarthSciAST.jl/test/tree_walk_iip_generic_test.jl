# The IN-PLACE RHS `f!(du, u, p, t)` under a non-Float64 value type
# (src/tree_walk/vectorize.jl `_vbuf` / `_make_rhs`, src/tree_walk/compile.jl
# `_rhs_value_type` / `_CSECache`).
#
# `f!` is the production evaluator: type-stable, zero-allocation, called every
# Runge–Kutta stage. It used to be Float64-ONLY, not because it mutates — ForwardDiff
# is perfectly happy with in-place functions — but because its scratch was
# eltype-hardwired at BUILD time: a `Vector{Float64}` per `_VecNode` and one for the
# CSE prelude. A `Dual` cannot be stored in either, so a Jacobian through `f!` threw.
#
# It is now generic in `T = _rhs_value_type(u, p, t)` while keeping BOTH properties
# that made it worth having. The tests below are organised around exactly that pair,
# because a change that wins one by losing the other is not a fix:
#
#   1. NOTHING MOVED AT Float64. Same bits, still zero allocations, still zero after
#      the Dual buffers have been created (the lazy alt-buffer must not leak into the
#      Float64 path). Bit-identity is asserted with `==` against the `form = :oop`
#      emitter, which is independently pinned bit-identical to the pre-change `f!`.
#
#   2. FORWARDDIFF WORKS THROUGH IT, on BOTH axes. The parameter axis is not a
#      variation of the state axis but a separate failure mode: there `u` stays
#      `Vector{Float64}` and only the parameter VALUES are `Dual`, so scratch sized
#      from `eltype(u)` alone compiles fine and then throws `Float64(::Dual)` on its
#      first store. Derivatives are checked against central differences.
#
# The `^` trap has its own testset and its own reason to exist: `^` is the only op
# whose derivative w.r.t. an operand needs a function with a smaller domain than the
# op itself (∂(x^y)/∂y = x^y·log(x)). Lift a literal exponent into the Dual type and
# `c[i]^2` at NEGATIVE c yields log(negative) = NaN — poisoning the gradient while the
# primal values still look perfect. Every state seeded here therefore has negative
# cells; a test with an all-positive state would pass while the bug shipped.

using Test
using EarthSciAST
using ForwardDiff
using SciMLBase: ODEProblem, ReturnCode
import OrdinaryDiffEqRosenbrock

include("testutils.jl")

const ESM = EarthSciAST

# Locally-prefixed doc builders (every tree-walk test file is `include`d into the same
# namespace, so shared short names would clobber each other).
_gi_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_gi_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_gi_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_gi_cst(v) = Dict{String,Any}("op" => "const", "value" => v)
_gi_fn(nm, a...) = Dict{String,Any}("op" => "fn", "name" => nm, "args" => Any[a...])
_gi_ao(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)
_gi_state(; kw...) = Dict{String,Any}("type" => "state",
                                      (String(k) => v for (k, v) in kw)...)
_gi_param(v) = Dict{String,Any}("type" => "parameter", "default" => v)

function _gi_doc(name, vars, eqs; index_sets = nothing)
    d = Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => name),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => vars, "equations" => eqs)))
    index_sets === nothing ||
        (d["index_sets"] = Dict{String,Any}("n" => Dict{String,Any}(
            "kind" => "interval", "size" => index_sets)))
    d
end

# ---- The model battery -------------------------------------------------------
# Chosen so every `_VecNode` kind that OWNS a buffer is walked at a Dual value type:
# GATHER + ghost CONSTVEC (the stencil), INVARIANT (the hoisted `exp(-Ea/T)`), FN (an
# interp table), STATE/PARAM/TIME/LITERAL, plus the scalar `_Node` path with a live
# CSE prelude (`_NK_CACHED` — the other eltype-hardwired buffer).

# 1-D reaction–diffusion. `c[i]^2` is the literal-exponent case, and `exp(-Ea/T)`
# hoists to a `_VK_INVARIANT` whose scalar subtree is walked once per call.
function _gi_rd(N)
    stencil = _gi_o("+", _gi_o("-", _gi_ix("c", _gi_o("-", "i", 1.0)),
                               _gi_o("*", 2.0, _gi_ix("c", "i"))),
                    _gi_ix("c", _gi_o("+", "i", 1.0)))
    rate = _gi_o("*", "k_rxn", _gi_o("exp", _gi_o("neg", _gi_o("/", "Ea", "T"))))
    _gi_doc("RDG",
        Dict{String,Any}("c" => _gi_state(shape = Any["n"]), "k_diff" => _gi_param(0.1),
                         "k_rxn" => _gi_param(0.3), "Ea" => _gi_param(50.0),
                         "T" => _gi_param(300.0)),
        Any[Dict{String,Any}("lhs" => _gi_ao(_gi_Dt(_gi_ix("c", "i"))),
            "rhs" => _gi_ao(_gi_o("-", _gi_o("*", "k_diff", stencil),
                                  _gi_o("*", rate, _gi_o("^", _gi_ix("c", "i"), 2.0)))))];
        index_sets = N)
end

# 0-D with a subexpression shared across two equations → a non-empty CSE prelude, so
# `_NK_CACHED` (which reads the OTHER eltype-hardwired buffer) is actually exercised.
function _gi_zerod()
    shared = _gi_o("*", _gi_o("exp", _gi_o("neg", _gi_o("/", "Ea", "T"))),
                   _gi_o("*", "x", "y"))
    _gi_doc("ZG",
        Dict{String,Any}("x" => _gi_state(default = 0.7), "y" => _gi_state(default = 0.4),
                         "Ea" => _gi_param(50.0), "T" => _gi_param(300.0),
                         "k" => _gi_param(1.3)),
        Any[Dict{String,Any}("lhs" => _gi_Dt("x"),
                             "rhs" => _gi_o("neg", _gi_o("*", "k", shared))),
            Dict{String,Any}("lhs" => _gi_Dt("y"), "rhs" => shared)])
end

# Time + trig + comparison/ifelse: the comparison arms produce plain `1.0`/`0.0`
# Float64 constants that must promote into a Dual buffer on store.
function _gi_tv(N)
    body = _gi_o("*",
        _gi_o("ifelse", _gi_o(">", _gi_ix("c", "i"), 0.0),
              _gi_o("sin", _gi_o("*", 2.0, "t")), _gi_o("cos", "t")),
        _gi_o("+", _gi_ix("c", "i"), _gi_o("sqrt", _gi_o("abs", _gi_ix("c", "i")))))
    _gi_doc("TVG", Dict{String,Any}("c" => _gi_state(shape = Any["n"])),
        Any[Dict{String,Any}("lhs" => _gi_ao(_gi_Dt(_gi_ix("c", "i"))),
                             "rhs" => _gi_ao(body))]; index_sets = N)
end

# interp.linear with a STATE query — the table (`Vector{Float64}` DATA that must NOT
# be widened) is differentiated through.
function _gi_interp()
    table = Any[0.0, 1.0, 4.0, 9.0, 16.0]
    axis = Any[0.0, 1.0, 2.0, 3.0, 4.0]
    _gi_doc("ITG",
        Dict{String,Any}("y" => _gi_state(default = 1.5), "k" => _gi_param(2.0)),
        Any[Dict{String,Any}("lhs" => _gi_Dt("y"),
            "rhs" => _gi_o("*", "k",
                           _gi_fn("interp.linear", _gi_cst(table), _gi_cst(axis), "y")))])
end

# Deliberately SIGNED: `c[i]^2` must sit on a negative base or the `^` trap is unarmed.
_gi_seed(n) = [0.6sin(0.7k) - 0.15 for k in 1:n]

# `f!` writes only the slots it has equations for, so it is only correct when handed a
# zeroed `du` (which is what an integrator does).
_gi_call(f!, u, p, t) = (du = zero(u); f!(du, u, p, t); du)

# The PARAMETER axis needs its own caller: `u` must stay `Vector{Float64}` (that is the
# whole failure mode), so `du` cannot be sized from it — it is sized from the promoted
# value type instead, exactly as an out-of-place emitter or a sensitivity driver would.
_gi_pcall(f!, u, p, t, ::Type{V}) where {V} =
    (du = zeros(V, length(u)); f!(du, u, p, t); du)

_gi_both(doc) = (ESM.build_evaluator(doc)[1], ESM.build_evaluator(doc; form = :oop)[1])

# Central-difference Jacobian of the TRUSTED Float64 `f!` w.r.t. the state.
function _gi_fd_state_jac(f!, u, p, t; h = 1e-6)
    n = length(u)
    J = zeros(n, n)
    for j in 1:n
        up = copy(u); up[j] += h
        um = copy(u); um[j] -= h
        J[:, j] = (_gi_call(f!, up, p, t) .- _gi_call(f!, um, p, t)) ./ 2h
    end
    J
end

@testset "in-place RHS: eltype-generic AND still zero-alloc at Float64" begin

    # ---- 1. Nothing moved at Float64 ----------------------------------------

    @testset "bit-identical at Float64 to the :oop emitter" begin
        # The oracle: `form = :oop` is independently pinned bit-identical to the
        # pre-change `f!` (tree_walk_oop_test.jl), so agreeing with it `==` means the
        # genericity refactor changed no Float64 bit. `==`, never `isapprox`.
        cases = ["reaction-diffusion N=16" => _gi_rd(16),
                 "reaction-diffusion N=129" => _gi_rd(129),
                 "0-D with a CSE prelude" => _gi_zerod(),
                 "time-varying + ifelse/trig" => _gi_tv(64),
                 "interp.linear on a state" => _gi_interp()]
        for (name, doc) in cases
            @testset "$name" begin
                fi, fo = _gi_both(doc)
                _, u0, p, _, _ = ESM.build_evaluator(doc)
                u = length(u0) == 1 ? [1.5] : _gi_seed(length(u0))
                for t in (0.0, 0.37, 1.9)
                    @test _gi_call(fi, u, p, t) == fo(u, p, t)
                end
            end
        end
    end

    @testset "still zero-allocation at Float64" begin
        # Guards the whole point of choosing a lazy per-node alt-buffer over widening
        # `buf` to a type parameter: `_vbuf(n, Float64)` IS `n.buf`, so the production
        # path allocates nothing. (tree_walk_allocation_test.jl pins this across a
        # wider model battery; here it is re-pinned on models that ALSO go Dual below,
        # so the two properties are asserted of the same evaluator object.)
        for doc in (_gi_rd(64), _gi_zerod(), _gi_tv(64), _gi_interp())
            f!, u0, p, _, _ = ESM.build_evaluator(doc)
            u = length(u0) == 1 ? [1.5] : _gi_seed(length(u0))
            du = zero(u)
            @test rhs_alloc_bytes(f!, du, u, p, 0.0) == 0
        end
    end

    @testset "the Float64 path survives having been driven with Duals" begin
        # The alt buffers are lazily created and cached ON THE NODES. A Dual call must
        # therefore leave no trace on the Float64 path — not in its values, and not in
        # its allocation count (a `Union`-typed buffer or a devirtualization failure
        # would show up as bytes here).
        doc = _gi_rd(32)
        fi, fo = _gi_both(doc)
        _, u0, p, _, _ = ESM.build_evaluator(doc)
        u = _gi_seed(length(u0))
        want = fo(u, p, 0.0)

        du = zero(u)
        @test rhs_alloc_bytes(fi, du, u, p, 0.0) == 0
        ForwardDiff.jacobian(uu -> (d = similar(uu); fill!(d, 0); fi(d, uu, p, 0.0); d), u)
        @test _gi_call(fi, u, p, 0.0) == want          # same bits after the Dual run
        @test rhs_alloc_bytes(fi, du, u, p, 0.0) == 0  # and still no allocations
    end

    # ---- 2. ForwardDiff, both axes ------------------------------------------

    @testset "ForwardDiff: Jacobian w.r.t. the STATE" begin
        doc = _gi_rd(24)
        f!, u0, p, _, _ = ESM.build_evaluator(doc)
        u = _gi_seed(length(u0))
        @test any(<(0), u)                              # the `^` trap is armed

        J = ForwardDiff.jacobian((d, uu) -> f!(d, uu, p, 0.0), zeros(length(u)), u)
        Jfd = _gi_fd_state_jac(f!, u, p, 0.0)
        @test maximum(abs, J .- Jfd) < 1e-6 * max(1.0, maximum(abs, Jfd))

        # A 1-D three-point stencil can only couple neighbours: everything outside the
        # tridiagonal band must be EXACTLY zero, not merely small.
        n = length(u)
        @test all(J[i, j] == 0.0 for i in 1:n, j in 1:n if abs(i - j) > 1)

        # And it must agree with the out-of-place emitter's Jacobian bit for bit —
        # the two walk the same IR, so a divergence means one of them is lying.
        fo = ESM.build_evaluator(doc; form = :oop)[1]
        @test J == ForwardDiff.jacobian(uu -> fo(uu, p, 0.0), u)
    end

    @testset "ForwardDiff: Jacobian w.r.t. the STATE, through the CSE prelude" begin
        # `_NK_CACHED` reads the CSE scratch, the second of the two eltype-hardwired
        # buffers. A model with an empty prelude cannot exercise it.
        doc = _gi_zerod()
        f!, u0, p, _, _ = ESM.build_evaluator(doc)
        @test !isempty(getfield(f!, :cse_prelude))      # the prelude is real
        u = [0.7, -0.4]

        J = ForwardDiff.jacobian((d, uu) -> f!(d, uu, p, 0.0), zeros(2), u)
        @test maximum(abs, J .- _gi_fd_state_jac(f!, u, p, 0.0)) < 1e-6
    end

    @testset "ForwardDiff: sensitivity w.r.t. the PARAMETERS" begin
        # A SEPARATE failure mode, not a variation on the state axis: `u` stays
        # `Vector{Float64}` and only the parameter values go Dual, so any buffer sized
        # from `eltype(u)` alone compiles and then throws `Float64(::Dual)` on store.
        for doc in (_gi_rd(24), _gi_zerod())
            f!, u0, p, _, _ = ESM.build_evaluator(doc)
            u = length(u0) == 2 ? [0.7, -0.4] : _gi_seed(length(u0))
            syms = keys(p)
            pv = collect(Float64, values(p))
            mk(v) = NamedTuple{syms}(Tuple(v))

            g = ForwardDiff.gradient(
                v -> sum(_gi_pcall(f!, u, mk(v), 0.0, eltype(v))), pv)
            @test eltype(g) === Float64
            @test all(isfinite, g)

            h = 1e-6
            for i in eachindex(pv)
                up = copy(pv); up[i] += h
                um = copy(pv); um[i] -= h
                fd = (sum(_gi_call(f!, u, mk(up), 0.0)) -
                      sum(_gi_call(f!, u, mk(um), 0.0))) / 2h
                @test isapprox(g[i], fd; rtol = 1e-5, atol = 1e-7)
            end
        end
    end

    @testset "parameter AD with a Float64 du/u: only `p` is Dual" begin
        # The narrowest form of the parameter trap, asserted directly rather than via
        # ForwardDiff's own buffer plumbing: hand `f!` a Float64 `u` and a Dual `du`,
        # with only the parameter NamedTuple carrying Duals. Every internal buffer must
        # be sized from the PROMOTED type or this throws.
        doc = _gi_rd(16)
        f!, u0, p, _, _ = ESM.build_evaluator(doc)
        u = _gi_seed(length(u0))
        D = ForwardDiff.Dual{Nothing,Float64,1}
        pd = NamedTuple{keys(p)}(Tuple(ForwardDiff.Dual{Nothing}(v, 1.0)
                                       for v in values(p)))
        du = zeros(D, length(u))
        f!(du, u, pd, 0.0)                              # Float64 u, Dual p, Dual du
        @test eltype(u) === Float64                     # u was NOT promoted
        @test all(isfinite ∘ ForwardDiff.value, du)
        @test ForwardDiff.value.(du) == _gi_call(f!, u, p, 0.0)   # primal unchanged
        @test any(!iszero, ForwardDiff.partials.(du, 1))          # and it moved
    end

    # ---- 3. The `^` trap ----------------------------------------------------

    @testset "a literal exponent is not lifted into the Dual type" begin
        # `c[i]^2` at NEGATIVE c. Lift the literal 2.0 into the Dual type and
        # ForwardDiff evaluates ∂(x^y)/∂y = x^y·log(x) even though the exponent's
        # partials are all zero — so log(negative) makes the entire gradient NaN while
        # the primal values still look perfect. Assert on the DERIVATIVE, and assert
        # the trap is armed, or this testset silently tests nothing.
        for N in (16, 33)
            doc = _gi_rd(N)
            f!, u0, p, _, _ = ESM.build_evaluator(doc)
            u = _gi_seed(length(u0))
            @test any(<(0), u)                          # the trap is ARMED
            J = ForwardDiff.jacobian((d, uu) -> f!(d, uu, p, 0.0), zeros(length(u)), u)
            @test all(isfinite, J)
            @test !any(isnan, J)
        end

        # The same hazard on the SCALAR (`_Node`) path, which has its own `^` arm.
        doc = _gi_doc("PW",
            Dict{String,Any}("x" => _gi_state(default = -1.3), "k" => _gi_param(2.0)),
            Any[Dict{String,Any}("lhs" => _gi_Dt("x"),
                                 "rhs" => _gi_o("*", "k", _gi_o("^", "x", 2.0)))])
        f!, _, p, _, _ = ESM.build_evaluator(doc)
        d = ForwardDiff.derivative(x -> _gi_call(f!, [x], p, 0.0)[1], -1.3)
        @test !isnan(d)
        @test d ≈ 2 * 2 * (-1.3)                        # d/dx (k·x²) = 2kx
    end

    @testset "interp tables differentiate, and clamp to zero slope outside" begin
        # The table/axis are `Vector{Float64}` DATA and stay so; only the QUERY is Dual.
        f!, _, p, _, _ = ESM.build_evaluator(_gi_interp())
        for (y, want) in ((1.5, 2 * 3.0),    # between knots (1,1) and (2,4): slope 3
                          (2.5, 2 * 5.0),    # between knots (2,4) and (3,9): slope 5
                          (-1.0, 0.0),       # below the table: flat extrapolation
                          (9.9, 0.0))        # above the table: flat extrapolation
            d = ForwardDiff.derivative(yy -> _gi_call(f!, [yy], p, 0.0)[1], y)
            @test d ≈ want
        end
    end

    # ---- 4. What it is FOR: a stiff solve on the AD Jacobian ------------------

    @testset "Rosenbrock23 solves through f! with an autodiff Jacobian" begin
        # The end-to-end reason for the change. Rosenbrock23 is implicit: it needs
        # ∂f/∂u every step. `autodiff = AutoForwardDiff()` (SciML's default) drives
        # the SAME `f!` with Dual state, which is exactly what used to throw
        # `MethodError: Float64(::Dual)` and forced a finite-difference fallback.
        doc = _gi_rd(24)
        f!, u0, p, _, _ = ESM.build_evaluator(doc)
        u = _gi_seed(length(u0))
        prob = ODEProblem(f!, u, (0.0, 2.0), p)

        sol = OrdinaryDiffEqRosenbrock.solve(prob, OrdinaryDiffEqRosenbrock.Rosenbrock23();
                                             abstol = 1e-10, reltol = 1e-10)
        @test sol.retcode == ReturnCode.Success
        @test all(isfinite, sol.u[end])

        # Against the same problem solved through the allocating out-of-place emitter
        # (a different evaluator, same IR): the two trajectories must agree.
        fo = ESM.build_evaluator(doc; form = :oop)[1]
        solo = OrdinaryDiffEqRosenbrock.solve(
            ODEProblem(fo, u, (0.0, 2.0), p), OrdinaryDiffEqRosenbrock.Rosenbrock23();
            abstol = 1e-10, reltol = 1e-10)
        @test maximum(abs, sol.u[end] .- solo.u[end]) < 1e-6
    end

    # ---- 5. The value-type rule ----------------------------------------------

    @testset "the value type is derived from u, p AND t" begin
        # Deriving it from `eltype(u)` alone is the parameter-AD bug in one line.
        D = ForwardDiff.Dual{Nothing,Float64,1}
        @test ESM._rhs_value_type(Float64[1.0], (a = 1.0,), 0.0) === Float64
        @test ESM._rhs_value_type(D[D(1.0)], (a = 1.0,), 0.0) === D       # state Dual
        @test ESM._rhs_value_type(Float64[1.0], (a = D(1.0),), 0.0) === D # params Dual
        @test ESM._rhs_value_type(Float64[1.0], nothing, 0.0) === Float64 # no params
        @test ESM._rhs_value_type(Float64[1.0], (a = 1.0,), D(0.0)) === D # time Dual
        # A parameter-free model carries `nothing`, not an empty NamedTuple.
        @test ESM._rhs_value_type(D[D(1.0)], nothing, 0.0) === D
    end
end
