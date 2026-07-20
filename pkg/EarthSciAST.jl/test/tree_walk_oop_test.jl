# The out-of-place RHS emitter (src/tree_walk/oop.jl).
#
# `build_evaluator(doc; form = :oop)` emits `f(u, p, t) -> du` from the SAME compiled
# IR as the default in-place `f!`. Two properties are worth having tests for, and they
# pull in opposite directions:
#
#   1. IDENTITY — at Float64 the two emitters must agree BIT FOR BIT, on every node
#      kind. That is what lets `:oop` be trusted as "the same model, differentiable":
#      any divergence would silently mean the gradients describe a different function
#      than the one being solved. Asserted with `==`, never `isapprox`.
#
#   2. GENERICITY — the whole point of the second emitter. ForwardDiff must work
#      through it BOTH over the state (Jacobians for stiff/implicit solvers) and over
#      the parameters (sensitivities), and the derivatives are checked against central
#      differences taken on the trusted in-place `f!`.
#
# The parameter case is not a redundant variation of the state case: there `u` stays
# `Vector{Float64}` and only the parameter VALUES become `Dual`, so an output buffer
# sized from `eltype(u)` compiles fine and then throws `Float64(::Dual)` on the first
# store. It is the bug that a state-only test cannot see.
#
# Also pinned here: the `x^2`-with-negative-x trap (a literal exponent must not be
# lifted into the differentiable type — see `_oop_pow`), interp tables differentiated
# on a state, and a ladder-coverage gate so `_oop_op` cannot drift away from the two
# ladders it mirrors.
#
# Enzyme reverse mode also works on this RHS, but only with
# `Enzyme.API.strictAliasing!(false)` — see the oop.jl header for why. Enzyme is a
# heavy dependency and is deliberately NOT a test dep; that path is verified
# out-of-band.

using Test
using EarthSciAST
using ForwardDiff

include("testutils.jl")

const ESM = EarthSciAST

_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_cst(v) = Dict{String,Any}("op" => "const", "value" => v)
_fnop(nm, a...) = Dict{String,Any}("op" => "fn", "name" => nm, "args" => Any[a...])
_ao(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)

_doc(name, vars, eqs; index_sets = nothing) = begin
    d = Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => name),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => vars, "equations" => eqs)))
    index_sets === nothing || (d["index_sets"] = index_sets)
    d
end
_nset(N) = Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => N))

_state(; kw...) = Dict{String,Any}("type" => "state",
                                   (String(k) => v for (k, v) in kw)...)
_param(v) = Dict{String,Any}("type" => "parameter", "default" => v)

# ---- The model battery -------------------------------------------------------
# Chosen to cover every `_VecNode` kind the emitter can meet: GATHER + boundary
# CONSTVEC (stencil), INVARIANT (a hoisted `exp(-Ea/T)`), REDUCE (a contraction),
# FN (an interp table), STATE/PARAM/TIME/LITERAL, plus the scalar `_Node` path with a
# live CSE prelude.

# 1-D reaction–diffusion. `exp(-Ea/T)` inside the arrayop hoists to `_VK_INVARIANT`;
# the end cells gather ghosts and form their own kernels; `c[i]^2` is the literal-
# exponent case. The state is seeded with NEGATIVE cells on purpose.
function _rd(N)
    stencil = _o("+", _o("-", _ix("c", _o("-", "i", 1.0)), _o("*", 2.0, _ix("c", "i"))),
                 _ix("c", _o("+", "i", 1.0)))
    rate = _o("*", "k_rxn", _o("exp", _o("neg", _o("/", "Ea", "T"))))
    _doc("RD",
        Dict{String,Any}("c" => _state(shape = Any["n"]), "k_diff" => _param(0.1),
                         "k_rxn" => _param(0.3), "Ea" => _param(50.0), "T" => _param(300.0)),
        Any[Dict{String,Any}("lhs" => _ao(_Dt(_ix("c", "i"))),
            "rhs" => _ao(_o("-", _o("*", "k_diff", stencil),
                            _o("*", rate, _o("^", _ix("c", "i"), 2.0)))))];
        index_sets = _nset(N))
end

# 0-D, with a subexpression shared across two equations → a non-empty CSE prelude,
# so `_NK_CACHED` is actually exercised (it is the node whose `Vector{Float64}` cache
# is exactly what blocks AD on the in-place path).
function _zerod()
    shared = _o("*", _o("exp", _o("neg", _o("/", "Ea", "T"))), _o("*", "x", "y"))
    _doc("Z",
        Dict{String,Any}("x" => _state(default = 0.7), "y" => _state(default = 0.4),
                         "Ea" => _param(50.0), "T" => _param(300.0), "k" => _param(1.3)),
        Any[Dict{String,Any}("lhs" => _Dt("x"), "rhs" => _o("neg", _o("*", "k", shared))),
            Dict{String,Any}("lhs" => _Dt("y"), "rhs" => shared)])
end

# Time-varying and trig/comparison/ifelse ops, so the shared ladder is walked over
# more than arithmetic. `sin(2t)` is lane-invariant but NOT constant — it must be
# re-evaluated every call, which a build-time fold would silently break.
function _tv(N)
    body = _o("*", _o("ifelse", _o(">", _ix("c", "i"), 0.0), _o("sin", _o("*", 2.0, "t")),
                      _o("cos", "t")),
              _o("+", _ix("c", "i"), _o("sqrt", _o("abs", _ix("c", "i")))))
    _doc("TV", Dict{String,Any}("c" => _state(shape = Any["n"])),
        Any[Dict{String,Any}("lhs" => _ao(_Dt(_ix("c", "i"))), "rhs" => _ao(body))];
        index_sets = _nset(N))
end

# interp.linear with a STATE query — the table is differentiated through.
function _interp()
    table = Any[0.0, 1.0, 4.0, 9.0, 16.0]
    axis = Any[0.0, 1.0, 2.0, 3.0, 4.0]
    _doc("IT", Dict{String,Any}("y" => _state(default = 1.5), "k" => _param(2.0)),
        Any[Dict{String,Any}("lhs" => _Dt("y"),
            "rhs" => _o("*", "k", _fnop("interp.linear", _cst(table), _cst(axis), "y")))])
end

# A state with no `D(...)` equation must keep du = 0, as under `f!`.
function _nod()
    _doc("ND", Dict{String,Any}("a" => _state(default = 2.0), "b" => _state(default = 5.0)),
        Any[Dict{String,Any}("lhs" => _Dt("a"), "rhs" => _o("*", -1.0, "a"))])
end

# Deliberately signed, so `c[i]^2` sits on a negative base.
_seed(n) = [0.6sin(0.7k) - 0.15 for k in 1:n]

# A state vector that REFUSES scalar reads but serves whole-array gathers — the
# access profile of a traced array (Reactant rejects `u[i]`, accepts `u[slots]`).
# Running `form = :oop` on it proves, on host, that the vectorized acc form
# touches the state only through whole-array ops.
struct _GatherOnlyVec <: AbstractVector{Float64}
    v::Vector{Float64}
end
Base.size(g::_GatherOnlyVec) = size(g.v)
Base.getindex(::_GatherOnlyVec, ::Int) =
    error("scalar indexing of the state — the access XLA rejects")
Base.getindex(g::_GatherOnlyVec, I::AbstractVector{<:Integer}) = g.v[I]
Base.similar(g::_GatherOnlyVec, ::Type{T}, dims::Dims) where {T} = similar(g.v, T, dims)

# `f!` writes only the slots it has equations for: a state with no `D(...)` equation is
# left UNTOUCHED, so `f!` is only correct when handed an already-zeroed `du` (which is
# what an integrator does). Zero it here too, or the comparison below would be against
# uninitialized memory. The out-of-place form has no such precondition — it zero-fills
# `du` itself — so the two agree exactly when `f!` is called the way it must be.
_ip(f!, u, p, t) = (du = zero(u); f!(du, u, p, t); du)

function _both(doc)
    fi, u0, p, _, vm = ESM.build_evaluator(doc)
    fo, _, _, _, _ = ESM.build_evaluator(doc; form = :oop)
    return fi, fo, u0, p, vm
end

@testset "out-of-place RHS emitter (form = :oop)" begin

    @testset "bit-identical to f! at Float64" begin
        cases = ["reaction-diffusion N=16" => _rd(16),
                 "reaction-diffusion N=257" => _rd(257),
                 "0-D with a CSE prelude" => _zerod(),
                 "time-varying + ifelse/trig" => _tv(64),
                 "interp.linear on a state" => _interp(),
                 "state with no D() equation" => _nod()]
        for (name, doc) in cases
            @testset "$name" begin
                fi, fo, u0, p, _ = _both(doc)
                u = length(u0) == 1 ? [1.5] : _seed(length(u0))
                for t in (0.0, 0.37, 1.9)
                    @test _ip(fi, u, p, t) == fo(u, p, t)   # bit-for-bit
                end
            end
        end
    end

    @testset "the emitters are wired to the SAME IR" begin
        # If `:oop` silently rebuilt the model (or dropped a phase) the identity test
        # above could still pass while the two ran different code. Pin the phases the
        # RD/0-D models are supposed to exercise, so a future refactor that empties one
        # of them makes the identity assertions fail loudly instead of vacuously.
        f_rd, = ESM.build_evaluator(_rd(64))
        # array kernels present — the unified access-kernel IR owns every array
        # equation, so a non-empty acc list proves the array phase ran.
        @test !isempty(getfield(f_rd, :acc_kernels))
        f_z, = ESM.build_evaluator(_zerod())
        @test !isempty(getfield(f_z, :cse_prelude))          # CSE prelude non-empty
        @test !isempty(getfield(f_z, :rhs_list))             # scalar equations present
    end

    @testset "du is zero for a state with no D() equation" begin
        # The ONE place the two emitters deliberately differ. `f!` writes only the slots
        # it has equations for, so `b`'s slot keeps whatever the caller's `du` held; the
        # out-of-place form allocates `du` itself and zero-fills it, so `b` is 0 with no
        # precondition on the caller. Pin both halves — the guarantee here, and the fact
        # that `f!` does NOT make it — so a future change to either is a visible one.
        fi, fo, u0, p, vm = _both(_nod())
        du = fo([2.0, 5.0], p, 0.0)
        @test du[vm["a"]] == -2.0
        @test du[vm["b"]] == 0.0

        dirty = fill(999.0, 2)
        fi(dirty, [2.0, 5.0], p, 0.0)
        @test dirty[vm["a"]] == -2.0
        @test dirty[vm["b"]] == 999.0     # untouched: f! requires a zeroed du
    end

    @testset "an unknown form is rejected" begin
        @test_throws ESM.TreeWalkError ESM.build_evaluator(_zerod(); form = :vectorized)
    end

    # ---- The point of the exercise: AD ---------------------------------------

    @testset "ForwardDiff: Jacobian w.r.t. the state" begin
        doc = _rd(24)
        fi, fo, u0, p, _ = _both(doc)
        u = _seed(length(u0))
        J = ForwardDiff.jacobian(uu -> fo(uu, p, 0.0), u)

        # Central differences on the TRUSTED in-place evaluator.
        h = 1e-6
        n = length(u)
        Jfd = zeros(n, n)
        for j in 1:n
            up = copy(u); up[j] += h
            um = copy(u); um[j] -= h
            Jfd[:, j] = (_ip(fi, up, p, 0.0) .- _ip(fi, um, p, 0.0)) ./ 2h
        end
        @test maximum(abs, J .- Jfd) < 1e-6 * max(1.0, maximum(abs, Jfd))

        # A 1-D three-point stencil can only couple neighbours: anything outside the
        # tridiagonal band must be exactly zero, not merely small.
        @test all(J[i, j] == 0.0 for i in 1:n, j in 1:n if abs(i - j) > 1)
    end

    @testset "ForwardDiff: gradient w.r.t. the PARAMETERS" begin
        # `u` stays Vector{Float64} while the parameter values go Dual. An output
        # buffer sized from `eltype(u)` would throw `Float64(::Dual)` on the first
        # store — the failure a state-only AD test cannot produce.
        doc = _rd(24)
        fi, fo, u0, p, _ = _both(doc)
        u = _seed(length(u0))
        syms = keys(p)
        pv = collect(values(p))
        mk(v) = NamedTuple{syms}(Tuple(v))

        g = ForwardDiff.gradient(v -> sum(fo(u, mk(v), 0.0)), pv)
        @test eltype(g) === Float64
        @test length(g) == length(pv)

        h = 1e-6
        for i in eachindex(pv)
            up = copy(pv); up[i] += h
            um = copy(pv); um[i] -= h
            fd = (sum(_ip(fi, u, mk(up), 0.0)) - sum(_ip(fi, u, mk(um), 0.0))) / 2h
            @test isapprox(g[i], fd; rtol = 1e-5, atol = 1e-7)
        end
    end

    @testset "a literal exponent is not lifted into the Dual type" begin
        # `c[i]^2` at NEGATIVE c. Lift the literal 2.0 to a Dual and ForwardDiff must
        # evaluate ∂(x^y)/∂y = x^y·log(x), so log(negative) makes the whole gradient
        # NaN — while the value itself still looks fine. Guard the derivative, not
        # just the primal.
        doc = _rd(16)
        _, fo, u0, p, _ = _both(doc)
        u = _seed(length(u0))
        @test any(<(0), u)                       # the trap is armed
        J = ForwardDiff.jacobian(uu -> fo(uu, p, 0.0), u)
        @test all(isfinite, J)
        @test !any(isnan, J)
    end

    @testset "interp tables differentiate, and clamp to zero slope outside" begin
        fi, fo, u0, p, _ = _both(_interp())
        # table = x² on axis 0:4, scaled by k = 2 ⇒ d/dy = 2 × (secant slope).
        for (y, want) in ((1.5, 2 * 3.0),    # between knots (1,1) and (2,4): slope 3
                          (2.5, 2 * 5.0),    # between knots (2,4) and (3,9): slope 5
                          (-1.0, 0.0),       # below the table: flat extrapolation
                          (9.9, 0.0))        # above the table: flat extrapolation
            @test _ip(fi, [y], p, 0.0) == fo([y], p, 0.0)          # still bit-identical
            d = ForwardDiff.derivative(yy -> fo([yy], p, 0.0)[1], y)
            @test d ≈ want
        end
    end

    # ---- Anti-drift ----------------------------------------------------------

    @testset "the shared ladder covers every op the scalar ladder does" begin
        # `_oop_op` is a THIRD op ladder beside `_eval_node_op` and `_eval_vec_op`.
        # Pin it to the scalar one by differential test: same op, same args, same
        # value — bit for bit. A registry op added without an `_oop_op` arm fails here
        # rather than at some user's first `form = :oop` build.
        u = [0.3, -0.8]
        p = (a = 1.7,)
        t = 0.5
        cache = Float64[]
        lit(x) = ESM._mknode(kind = ESM._NK_LITERAL, literal = x)
        scalar(op, vals) = ESM._eval_node(
            ESM._mknode(kind = ESM._NK_OP, op = op,
                        children = ESM._Node[lit(v) for v in vals]), u, p, t, )

        # Every mechanical unary op, straight from the registry that generates the arm.
        for row in ESM._UNARY_ELEMENTWISE_OPS
            x = row.sym in (:sqrt, :log, :log10, :acosh) ? 1.7 :
                row.sym in (:asin, :acos, :atanh) ? 0.4 : 0.6
            @test ESM._oop_op(row.sym, [x], Float64) == scalar(row.sym, [x])
        end

        # The structurally distinct arms, including every arity that has its own path.
        cases = Any[
            (:+, [1.5]), (:+, [1.5, 2.25]), (:+, [1.5, 2.25, -0.5]),
            (:*, [1.5]), (:*, [1.5, 2.25]), (:*, [1.5, 2.25, -0.5]),
            (:-, [1.5]), (:-, [1.5, 2.25]),
            (:neg, [1.5]), (:/, [1.5, 2.0]), (:^, [1.5, 3.0]), (:pow, [1.5, 3.0]),
            (:<, [1.0, 2.0]), (:<, [2.0, 1.0]),
            (Symbol("<="), [2.0, 2.0]), (:>, [1.0, 2.0]), (Symbol(">="), [2.0, 2.0]),
            (Symbol("=="), [2.0, 2.0]), (Symbol("!="), [2.0, 2.0]),
            (:and, [1.0, 0.0]), (:and, [1.0, 3.0]), (:or, [0.0, 0.0]), (:or, [0.0, 2.0]),
            (:not, [0.0]), (:not, [1.0]),
            (:ifelse, [1.0, 7.0, 9.0]), (:ifelse, [0.0, 7.0, 9.0]),
            (:atan, [0.7]), (:atan, [0.7, 1.3]), (:atan2, [0.7, 1.3]),
            (:min, [3.0, 1.0]), (:min, [3.0, 1.0, 2.0]),
            (:max, [3.0, 1.0]), (:max, [3.0, 1.0, 2.0]),
            (:pi, Float64[]), (:e, Float64[]), (:Pre, [4.25]),
        ]
        for (op, vals) in cases
            @test ESM._oop_op(op, vals, Float64) == scalar(op, vals)
        end
    end

    @testset "value type is derived from u, p AND t" begin
        D = ForwardDiff.Dual{Nothing,Float64,1}
        @test ESM._oop_value_type(Float64[1.0], (a = 1.0,), 0.0) === Float64
        @test ESM._oop_value_type(D[D(1.0)], (a = 1.0,), 0.0) === D    # state is Dual
        @test ESM._oop_value_type(Float64[1.0], (a = D(1.0),), 0.0) === D  # params are
        @test ESM._oop_value_type(Float64[1.0], nothing, 0.0) === Float64  # no params
    end

    # ---- The de-scalarized (traceable) acc form ------------------------------

    @testset "a DEFAULT (affine) build takes the vectorized acc form" begin
        # The refusal this replaced (`E_TREEWALK_ACC_XLA_UNSUPPORTED`) meant the
        # flagship tracing feature only worked with ESS_STENCIL_DISABLE=1. Pin
        # the fix structurally: the default build of a stencil model produces acc
        # kernels, EVERY one of them plans vectorizable for `:oop`, and the
        # in-place build carries a lane tape for each — so neither emitter walks
        # cells one at a time on the default path.
        fi, _, _, _, _ = ESM.build_evaluator(_rd(64))
        fo, _, _, _, _ = ESM.build_evaluator(_rd(64); form = :oop)
        @test !isempty(getfield(fi, :acc_kernels))
        @test all(P -> P !== nothing, getfield(fi, :acc_plans))
        # `fo` is the `_OopRHS` wrapper (B2); the walk closure — and its captured
        # lane plans — is the explicit-buffers form behind `rhs_with_buffers`.
        oplans = getfield(ESM.rhs_with_buffers(fo), :acc_plans)
        @test !isempty(oplans) && all(P -> P.vectorizable, oplans)
    end

    @testset "the vectorized acc form never scalar-indexes the state" begin
        # The property XLA actually rejects. A minimal state wrapper that THROWS
        # on scalar reads but serves whole-array gathers: `form = :oop` on a
        # default affine build must evaluate through it — proof, on host, that
        # every state access is a whole-array op (the traceability contract),
        # with no Reactant in the loop.
        fo, u0, p, _, _ = ESM.build_evaluator(_rd(24); form = :oop)
        u = _seed(length(u0))
        want = fo(u, p, 0.4)
        got = fo(_GatherOnlyVec(u), p, 0.4)
        @test got == want
    end

    @testset "ghost-bearing state table vectorizes (gather-then-select)" begin
        # A `_AK_STATE_TBL_BOX` whose table holds a ghost slot (0) — read as 0.0
        # by the in-place tape — used to keep the per-cell oop fallback. It now
        # vectorizes (gordian total-vectorize): gather at a SAFE index, then
        # select 0.0 on the ghost lanes against a host mask. Must be bit-identical
        # to the in-place tape, evaluate WITHOUT scalar-indexing the state, and
        # differentiate correctly (ghost lanes carry zero state-derivative).
        N = 40
        u = _seed(N)
        conn = Int[ i % 4 == 0 ? 0 : ((i + 7) % N) + 1  for i in 1:N ]  # every 4th ghost
        @assert any(==(0), conn) && any(!=(0), conn)
        acc = ESM._AccDesc[ESM._AccStateTblBox(conn, 1, 0, 0, 1)]       # boxaddr = i
        spine = ESM._aop(:+, ESM._acc(1), ESM._aop(:*, ESM._alit(2.0), ESM._acc(1)))
        K = ESM._AccKernel(ESM._CellSet([1], UnitRange{Int}[1:N], 0), spine, acc,
                           ESM._FixedBound(0), 0.0)

        # in-place tape reference (handles the ghost via _TC_GATHER_STATE_TBL)
        ref = zeros(N)
        ESM._run_acc_plan!(ref, u, nothing, 0.0, K, ESM._build_acc_plan(K; tile=8))
        man = [ conn[i] == 0 ? 0.0 : 3.0*u[conn[i]] for i in 1:N ]
        @test ref == man

        op = ESM._build_oop_acc_plan(K)
        @test op.vectorizable                                          # no more fallback
        du_o = ESM._oop_run_acc_vec(zeros(N), u, nothing, 0.0, K, op, Float64)
        @test du_o == ref                                             # bit-identical

        # whole-array only: evaluate through a state that throws on scalar reads
        du_g = ESM._oop_run_acc_vec(zeros(N), _GatherOnlyVec(u), nothing, 0.0, K, op, Float64)
        @test du_g == ref

        # AD: ghost lanes → zero derivative, else ∂/∂u[conn[i]] == 3.0
        J = ForwardDiff.jacobian(
            uu -> ESM._oop_run_acc_vec(zeros(eltype(uu), N), uu, nothing, 0.0, K,
                                       ESM._build_oop_acc_plan(K), eltype(uu)), u)
        @test all(isfinite, J)
        for i in 1:N
            if conn[i] == 0
                @test all(==(0.0), @view J[i, :])
            else
                @test J[i, conn[i]] == 3.0
            end
        end
    end

    @testset "variable-valence reduction vectorizes (CSR segment fold)" begin
        # A `_NK_REDUCE` + `_VarBound` unstructured FV divergence — indirect
        # neighbour gather (`_AK_STATE_INDIRECT`), per-edge const (`_AK_CONST_EDGE`),
        # self (`_AK_STATE_AFFINE`), per-cell area (`_AK_CONST_CELL`) — used to keep
        # the per-cell oop fallback (a padded rectangular reduce would reorder the
        # seeded ⊕-fold). It now vectorizes (gordian reduce-vectorize): the body is
        # ONE flat CSR gather, folded per segment in child order — bit-identical to
        # the scalar seeded sum, whole-array only, and differentiable.
        #   D(q[c]) = ( Σ_{n=1}^{val[c]} efl[c,n]*0.5*(q[c]+q[noc[c,n]]) ) / area[c]
        Nc = 300; maxval = 8
        rng = 987654321
        nextr() = (rng = (1103515245*rng + 12345) & 0x7fffffff; rng)
        val = Vector{Int}(undef, Nc); noc = zeros(Int, Nc*maxval); efl = zeros(Nc*maxval)
        for c in 1:Nc
            v = 3 + nextr() % (maxval-2); val[c] = v
            for n in 1:v
                noc[(c-1)*maxval+n] = 1 + nextr() % Nc
                efl[(c-1)*maxval+n] = 0.5 + (nextr() % 100)/100
            end
        end
        area = Float64[1.0 + (c % 7)/3 for c in 1:Nc]
        u = Float64[sin(0.11c) + 0.2cos(0.007c^2) for c in 1:Nc]

        acc = ESM._AccDesc[
            ESM._AccStateAffine(0),                 # q[c]
            ESM._AccStateIndirect(noc, maxval),     # q[noc[c,n]]
            ESM._AccConstEdge(efl, maxval),         # efl[c,n]
            ESM._AccConstCell(area),                # area[c]
        ]
        qc = ESM._acc(1); qn = ESM._acc(2); e = ESM._acc(3); ar = ESM._acc(4)
        body = ESM._aop(:*, ESM._aop(:*, e, ESM._alit(0.5)), ESM._aop(:+, qc, qn))
        spine = ESM._aop(:/, ESM._areduce(body), ar)
        K = ESM._AccKernel(ESM._contig_cells(Nc), spine, acc, ESM._VarBound(val), 0.0)

        # scalar reference (the seeded child-order fold)
        ref = zeros(Nc); ESM._run_acc_kernel!(ref, u, nothing, 0.0, K)

        op = ESM._build_oop_acc_plan(K)
        @test op.vectorizable                       # no more per-cell fallback
        du_o = ESM._oop_run_acc_vec(zeros(Nc), u, nothing, 0.0, K, op, Float64)
        @test du_o == ref                           # bit-identical to the scalar fold

        # whole-array only: a state that throws on scalar reads still evaluates
        du_g = ESM._oop_run_acc_vec(zeros(Nc), _GatherOnlyVec(u), nothing, 0.0, K, op, Float64)
        @test du_g == ref

        # AD: ∂D(q[c])/∂q[k] finite; the fold differentiates through the gather.
        J = ForwardDiff.jacobian(
            uu -> ESM._oop_run_acc_vec(zeros(eltype(uu), Nc), uu, nothing, 0.0, K,
                                       ESM._build_oop_acc_plan(K), eltype(uu)), u)
        @test all(isfinite, J)
        @test any(!=(0.0), J)
    end

    @testset "interp.* inside an arrayop: lanes ≡ scalar cores, and AD" begin
        # The acc `:fn` arm evaluates locate→gather→blend over whole lanes (the
        # form a tracer needs). It must be BIT-identical to the branchy scalar
        # cores — pinned both through the emitters and directly, over a dense
        # query sweep hitting in-range, every knot, both clamps, and NaN.
        table = Any[10.0, 20.0, 40.0, 80.0, 160.0]
        axis = Any[0.0, 1.0, 2.0, 3.0, 4.0]
        body = _o("+", _fnop("interp.linear", _cst(table), _cst(axis), _ix("c", "i")),
                  _o("*", -0.5, _ix("c", "i")))
        doc = _doc("FNAO", Dict{String,Any}("c" => _state(shape = Any["n"])),
            Any[Dict{String,Any}("lhs" => _ao(_Dt(_ix("c", "i"))), "rhs" => _ao(body))];
            index_sets = _nset(48))
        fi, fo, u0, p, _ = _both(doc)
        u = [4.4 * (k - 1) / 47 - 0.2 for k in 1:48]   # spans both clamps
        for t in (0.0, 1.1)
            @test _ip(fi, u, p, t) == fo(u, p, t)      # bit-for-bit
        end
        J = ForwardDiff.jacobian(uu -> fo(uu, p, 0.0), u)
        @test all(isfinite, J)

        # Direct dense sweeps against the cores (isequal: NaN pins as NaN).
        lspec = ESM._InterpLinearSpec([10.0, 20.0, 40.0, 80.0, 160.0],
                                      [0.0, 1.0, 2.0, 3.0, 4.0])
        qs = vcat(collect(-1.0:0.037:5.0), [0.0, 1.0, 2.0, 3.0, 4.0, NaN, -0.0])
        @test all(isequal(a, b) for (a, b) in zip(
            ESM._oop_interp_linear_lanes(lspec, qs, Float64),
            [ESM._interp_linear_core(lspec.table, lspec.axis, q) for q in qs]))
        sspec = ESM._InterpSearchsortedSpec([1.0, 2.0, 2.0, 3.0, 4.0])  # duplicate knot
        @test all(isequal(a, b) for (a, b) in zip(
            ESM._oop_interp_searchsorted_lanes(sspec, qs, Float64),
            [Float64(ESM._interp_searchsorted_core("interp.searchsorted", q, sspec.xs))
             for q in qs]))
        bspec = ESM._InterpBilinearSpec([[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]],
                                        [0.0, 1.0, 2.0], [0.0, 1.0, 2.0])
        xs = vcat(collect(-0.5:0.13:2.5), [0.0, 1.0, 2.0, NaN, 0.7])
        ys = reverse(vcat(collect(-0.5:0.13:2.5), [1.0, NaN, 0.0, 2.0, 1.3]))
        @test all(isequal(a, b) for (a, b) in zip(
            ESM._oop_interp_bilinear_lanes(bspec, xs, ys, Float64),
            [ESM._interp_bilinear_core(bspec.table, bspec.axis_x, bspec.axis_y, x, y)
             for (x, y) in zip(xs, ys)]))
    end
end
