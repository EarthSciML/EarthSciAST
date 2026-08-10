# fn-spec CONTENT keying in the per-kernel value numbering (ess-affine).
# `_compile_fn_node` mints a fresh spec object per SOURCE `fn` node, so two
# `interp.*` calls over content-equal const tables used to carry object-DISTINCT
# payloads, and `_acc_vn_key`'s objectid keying gave them different value numbers —
# no per-cell CSE slot, no invariant-hoist dedup, ever. `_acc_fn_pay_key` now keys
# the payload on spec CONTENT (the merge guard's `_fn_spec_hash` /
# `_fn_spec_content_equal` pair, confirmed via Dict `isequal` — collision-proof),
# so equal tables SHARE and one-element-different tables do NOT (and never throw:
# a split key is a recompute, not an error).
#
# Asserts, per model: sharing observable in the diag counters (`n_acc_cse_slots` /
# `n_acc_inv_slots`) exactly where content matches; affine (ESS_AFFINE=1) ≡
# per-cell (ESS_STENCIL_DISABLE=1) reference BIT-IDENTICALLY throughout — the
# shared slot evaluates the SAME op on the SAME inputs, just once.
using Test
using EarthSciAST
include("testutils.jl")
const ESM = EarthSciAST

function _fnk_build(model, ics; affine::Bool)
    envs = affine ? ("ESS_AFFINE" => "1", "ESS_STENCIL_DISABLE" => nothing) :
                    ("ESS_AFFINE" => nothing, "ESS_STENCIL_DISABLE" => "1")
    withenv(envs...) do
        f!, u0, p, _tspan, vm, diag =
            ESM._build_evaluator_impl(model; initial_conditions=ics, form=:inplace)
        (f!, u0, p, diag)
    end
end
_fnk_du(f!, u0, p, t) = (du = zero(u0); f!(du, u0, p, t); du)

const _FNK_T = [10.0, 20.0, 40.0, 80.0, 160.0]
const _FNK_A = [0.0, 1.0, 2.0, 3.0, 4.0]
# The twin table/axis, INT-typed. The AST interner (src/intern.jl) deliberately
# never merges an Int-valued `const` with its Float twin (`_plain_hash` seeds Int64
# and Float64 differently — value semantics would be a lie at the AST tier), while
# `_coerce_f64_vec` lowers both to BIT-IDENTICAL `Vector{Float64}` spec content. So
# these two spellings are guaranteed to reach `_build_acc_cse` as two DISTINCT spec
# objects with content-equal payloads even in the default (interned) build — the
# exact case the old objectid keying could never share. (A plain `copy` of the
# Float table does NOT exercise this: the interner collapses the two structurally
# identical `fn` nodes into one, and sharing falls out of node identity.)
_fnk_ti(perturb::Int) = Int64[10, 20, 40, 80, 160 + perturb]
_fnk_ai() = Int64[0, 1, 2, 3, 4]

# D(u[i]) = interp(T,A,u[i+1]) + interp(Tᵢ,Aᵢ,u[i+1]) + u[i-1].  T Float-typed,
# Tᵢ/Aᵢ the Int spelling above (content-equal after coercion, object-distinct
# specs); `perturb` bumps one element of Tᵢ so the same shape becomes the
# MUST-NOT-share control. The interp query is cell-varying (a neighbour gather),
# so sharing lands in the per-cell CSE tier: one fn value number occurring twice
# ⇒ a recipe slot per kernel, where the split key yields two singletons ⇒ zero.
function _fnk_twin_model(N; perturb::Int=0)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    x = _idx("u", _op("+", _v("i"), _i(1)))
    itp1 = _op("fn", _const(copy(_FNK_T)), _const(copy(_FNK_A)), x; name="interp.linear")
    itp2 = _op("fn", _const(_fnk_ti(perturb)), _const(_fnk_ai()), x; name="interp.linear")
    body = _op("+", itp1, itp2, _idx("u", _op("-", _v("i"), _i(1))))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

# D(u[i]) = (interp(T,A,g/h) + interp(Tᵢ,Aᵢ,g/h))·u[i] — the interp query is a
# parameter expression, so both fn nodes are CELL-INVARIANT and land in the hoist
# tier, which mints a slot per invariant OP vn REGARDLESS of count: content-equal
# tables collapse two fn vns into one, so the twin build carries exactly one inv
# slot FEWER than the perturbed build (same spine shape otherwise).
function _fnk_inv_model(N; perturb::Int=0)
    vars = Dict{String,ESM.ModelVariable}(
        "u" => ESM.ModelVariable(ESM.StateVariable),
        "g" => ESM.ModelVariable(ESM.ParameterVariable; default=3.0),
        "h" => ESM.ModelVariable(ESM.ParameterVariable; default=7.0))
    q = _op("/", _v("g"), _v("h"))
    itp1 = _op("fn", _const(copy(_FNK_T)), _const(copy(_FNK_A)), q; name="interp.linear")
    itp2 = _op("fn", _const(_fnk_ti(perturb)), _const(_fnk_ai()), q; name="interp.linear")
    body = _op("*", _op("+", itp1, itp2), _idx("u", _v("i")))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

# D(u[i]) = (doy(t) − doy(t))·u[i], the two `datetime.day_of_year` calls built as
# SEPARATE AST nodes — the `Tuple{String,Nothing}` payload family, whose content
# is the name alone. Post-change the two fn nodes share one vn deterministically
# (pre-change that depended on accidental tuple/string egality), so the invariant
# tier holds exactly two slots: the shared fn, and the `-` above it.
function _fnk_dt_model(N)
    vars = Dict("u" => ESM.ModelVariable(ESM.StateVariable))
    d1 = _op("fn", _v("t"); name="datetime.day_of_year")
    d2 = _op("fn", _v("t"); name="datetime.day_of_year")
    body = _op("*", _op("-", d1, d2), _idx("u", _v("i")))
    ESM.Model(vars, [ESM.Equation(_ao1(_Didx("u", _v("i")), "i", 1, N),
                                  _ao1(body, "i", 1, N))])
end

@testset "fn spec content keying in per-kernel CSE (ess-affine)" begin
    @testset "content-equal tables share a per-cell slot (N=$N)" for N in (8, 32)
        ics = Dict("u[$k]" => 2.0 + sin(0.3k) for k in 1:N)
        fa, u0, pa, d = _fnk_build(_fnk_twin_model(N), ics; affine=true)
        fr, ur, pr, _ = _fnk_build(_fnk_twin_model(N), ics; affine=false)
        @test d.n_acc_kernels >= 1          # affine path fired
        @test d.n_acc_cse_slots >= 1        # the twin fn calls SHARED
        @test _fnk_du(fa, u0, pa, 0.0) == _fnk_du(fr, ur, pr, 0.0)   # bit-identical
    end

    @testset "one-element table difference must NOT share (and not throw)" begin
        N = 16
        ics = Dict("u[$k]" => 2.0 + sin(0.3k) for k in 1:N)
        fa, u0, pa, d = _fnk_build(_fnk_twin_model(N; perturb=1), ics; affine=true)
        fr, ur, pr, _ = _fnk_build(_fnk_twin_model(N; perturb=1), ics; affine=false)
        @test d.n_acc_cse_slots == 0        # split key ⇒ two singleton vns ⇒ no slot
        @test _fnk_du(fa, u0, pa, 0.0) == _fnk_du(fr, ur, pr, 0.0)
    end

    @testset "invariant tier: shared fn vn ⇒ one slot fewer than perturbed" begin
        N = 16
        ics = Dict("u[$k]" => 0.5 + 0.1k for k in 1:N)
        fa, u0, pa, dt = _fnk_build(_fnk_inv_model(N), ics; affine=true)
        fr, ur, pr, _  = _fnk_build(_fnk_inv_model(N), ics; affine=false)
        _,  _,  _,  dp = _fnk_build(_fnk_inv_model(N; perturb=1), ics; affine=true)
        @test dt.n_acc_inv_slots >= 1                       # hoist fired at all
        @test dt.n_acc_inv_slots == dp.n_acc_inv_slots - 1  # twin fns fused ONE vn
        @test _fnk_du(fa, u0, pa, 0.0) == _fnk_du(fr, ur, pr, 0.0)
    end

    @testset "boxed datetime payload (Tuple{String,Nothing}) keys on the name" begin
        N = 8
        ics = Dict("u[$k]" => 1.0 + 0.1k for k in 1:N)
        fa, u0, pa, d = _fnk_build(_fnk_dt_model(N), ics; affine=true)
        fr, ur, pr, _ = _fnk_build(_fnk_dt_model(N), ics; affine=false)
        @test d.n_acc_inv_slots == 2        # shared doy vn + the `-` above it
        for t in (0.0, 86_400.0 * 200.5)
            @test _fnk_du(fa, u0, pa, t) == _fnk_du(fr, ur, pr, t)
        end
    end

    @testset "slot counts are N-independent" begin
        counts = map((8, 32, 128)) do N
            ics = Dict("u[$k]" => 2.0 + 0.01k for k in 1:N)
            _fnk_build(_fnk_twin_model(N), ics; affine=true)[4].n_acc_cse_slots
        end
        @test all(==(counts[1]), counts)
        @test counts[1] >= 1
    end
end
