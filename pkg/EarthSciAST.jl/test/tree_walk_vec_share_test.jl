# Lane-VARYING vector CSE — sharing a whole N-lane vector within and across the
# vectorized array kernels (`tree_walk/vec_share.jl`, EarthSciSerialization-cp5).
#
# The sibling pass (invariant_share.jl) shares lane-INVARIANT subtrees, and everything
# it shares is a SCALAR. Nothing shared a VECTOR: a repeated lane-VARYING subexpression
# — `u[i]+w[i]` under both a `sin` and a `cos`, or a reaction flux `k*A[i]*B[i]` written
# into two species' balances — was lowered once per occurrence, each copy owning its own
# N-lane buffer and re-evaluated on every RHS call.
#
# `_share_lane_vectors!` value-numbers every `_VecNode` on its LANE DATA, hash-conses
# the templates into a DAG, and lifts every node with in-degree ≥ 2 into a VEC PRELUDE
# of defs evaluated once per call; each occurrence becomes a `_VK_VCACHED` ref that just
# reads the def's buffer.
#
# What these tests pin, in the order the risk runs:
#
#   1. NUMERIC IDENTITY. Sharing must never move a number. Every value assertion here
#      is against an INDEPENDENT hand-written oracle (or the cross-binding scalar
#      contract `evaluate_closed_function`), with `==` — bit-for-bit, never `isapprox`.
#   2. THE PASS FIRES — intra-kernel, cross-kernel, and through a `_VK_VCACHED` def that
#      references another def. Without this, (1) would pass vacuously forever.
#   3. IT DECLINES WHEN IT MUST. This is the correctness core, because a bad merge here
#      produces silently WRONG numbers, not a crash: two gathers over different slot
#      vectors, two kernels of different `len`, two `interp.*` calls over different
#      const tables, two `_VK_PGATHER`s over different live forcing buffers, and two
#      `_VK_INVARIANT`s over different parameters must each keep their own identity.
#   4. THE HOIST POLICY. `_vk_hoistable` must refuse the pass-through op forms (1-ary
#      `+`/`*`, `Pre`): `_eval_vec_op` returns their CHILD's buffer and never writes
#      their own, so a `_VK_VCACHED` ref to one would read an unwritten buffer.
#   5. The properties the pass must not cost: zero allocations, `:inplace` ≡ `:oop`
#      bit-for-bit, ForwardDiff through a shared def (state AND parameter axes,
#      including the `^`-with-literal-exponent-over-negative-lanes trap), a live
#      forcing refresh showing through a shared `_VK_PGATHER` def, and N-independence
#      of the compiled node counts.

using Test
using EarthSciAST
using ForwardDiff

include("testutils.jl")  # builder quartet + zero_alloc_harness.jl

const ESM = EarthSciAST

# ---------------------------------------------------------------------------
# Helpers. All `_vs_`-prefixed so they cannot collide with the other tree-walk
# test files, which share one `Main` under runtests.jl.
# ---------------------------------------------------------------------------

_vs_prelude(f!) = getfield(f!, :vec_prelude)
_vs_kernels(f!) = getfield(f!, :vec_kernels)

# Every `_VecNode` of one template, by TREE walk. A `_VK_VCACHED` ref has no children
# (its def hangs off `payload`), so the walk stops AT the ref and never descends into
# the def — which is exactly what "the nodes this template still owns" means.
function _vs_nodes(n::ESM._VecNode)
    out = ESM._VecNode[]
    walk(x) = (push!(out, x); foreach(walk, x.children))
    walk(n)
    return out
end

_vs_refs(n::ESM._VecNode) = [x for x in _vs_nodes(n) if x.kind === ESM._VK_VCACHED]

# Kind histogram over the KERNEL templates (not the prelude defs).
function _vs_kind_hist(f!)
    h = Dict{UInt8,Int}()
    for vk in _vs_kernels(f!), x in _vs_nodes(vk.template)
        h[x.kind] = get(h, x.kind, 0) + 1
    end
    return h
end
_vs_nkind(f!, k) = get(_vs_kind_hist(f!), k, 0)

# `_VK_VCACHED` occurrence sites, counted over the kernels AND the prelude defs (a def
# may reference a lower def).
_vs_n_refs(f!) = sum(length(_vs_refs(vk.template)) for vk in _vs_kernels(f!); init = 0) +
                 sum(length(_vs_refs(d)) for d in _vs_prelude(f!); init = 0)

# Gather-slot vectors of the prelude defs, for the "these did NOT merge" assertions.
_vs_def_slots(f!) = [d.slots for d in _vs_prelude(f!)]

# `f!` writes only the slots it has equations for, so hand it a ZEROED du (which is what
# an integrator does).
_vs_du(f!, u, p, t) = (du = zero(u); f!(du, u, p, t); du)

_vs_state(n) = (n => ModelVariable(StateVariable))
_vs_param(n, v) = (n => ModelVariable(ParameterVariable; default = v))

# ---- The IR invariants every built model must satisfy ------------------------
#
# Checked on EVERY model this file builds (see the battery at the bottom), because each
# one is a way the pass could be silently wrong rather than loudly broken:
#
#   * a `_VK_VCACHED` must name a real slot AND carry that very def as its `payload`
#     (`_eval_vec` reads the payload; the `:oop` emitter indexes by `idx` — if the two
#     disagreed, the two emitters would read DIFFERENT vectors);
#   * every def must be `_vk_hoistable` (a ref to a pass-through op would read a buffer
#     nothing ever wrote);
#   * the prelude must be TOPOLOGICALLY ordered — a def may only reference defs BELOW
#     it, since `f!` runs the prelude front to back and `_make_rhs_oop`'s `vcache[s]` is
#     not filled until slot `s` runs;
#   * LANE LENGTHS must agree: every node a kernel of `len` L still owns has `_vk_len ==
#     L`, and every def it refs holds an L-lane vector. This is the assertion that
#     catches a key which dropped `len` — two structurally identical leaves in a 100-lane
#     and a 50-lane kernel would canonicalize onto ONE buffer.
_vs_ref_ok(x::ESM._VecNode, pre) =
    1 <= x.idx <= length(pre) && x.payload === pre[x.idx] && isempty(x.children)

function _vs_len_ok(n::ESM._VecNode, L::Int, pre)
    for x in _vs_nodes(n)
        if x.kind === ESM._VK_VCACHED
            ESM._vk_len(pre[x.idx]::ESM._VecNode) == L || return false
        else
            ESM._vk_len(x) == L || return false
        end
    end
    return true
end

function _vs_check_ir(f!, diag)
    pre = _vs_prelude(f!)
    ks = _vs_kernels(f!)
    allrefs = vcat(ESM._VecNode[], (_vs_refs(vk.template) for vk in ks)...,
                   (_vs_refs(d) for d in pre)...)

    @test diag.n_vec_slots == length(pre)
    @test diag.n_vec_prelude_nodes == sum(ESM._count_vecnodes(d) for d in pre; init = 0)
    # Each def has in-degree ≥ 2 by construction, so the collapsed-site count can never
    # be less than twice the slot count.
    @test diag.n_vec_shared >= 2 * diag.n_vec_slots
    @test all(x -> _vs_ref_ok(x, pre), allrefs)
    @test all(ESM._vk_hoistable, pre)
    @test all(d -> d.kind !== ESM._VK_VCACHED, pre)          # a def is a BODY, not a ref
    @test allunique(objectid(d) for d in pre)                # ...and each is distinct
    @test all(s -> all(x -> x.idx < s, _vs_refs(pre[s])), eachindex(pre))   # topological
    @test all(vk -> _vs_len_ok(vk.template, vk.len, pre), ks)
    @test all(s -> _vs_len_ok(pre[s], ESM._vk_len(pre[s]), pre), eachindex(pre))
    return nothing
end

# ---------------------------------------------------------------------------
# The model battery. Every one of these is re-run below through the IR-invariant
# checker, the `:inplace` ≡ `:oop` comparison and (where it is a production shape) the
# zero-allocation harness — so a model added here is automatically covered by all three.
# ---------------------------------------------------------------------------

const _VS_TBL_A = [10.0, 20.0, 40.0, 80.0, 160.0]
const _VS_TBL_B = [-1.0, -2.0, -4.0, -8.0, -16.0]
const _VS_AX = [0.0, 1.0, 2.0, 3.0, 4.0]

_vs_interp(tbl, q) = _op("fn", _const(tbl), _const(_VS_AX), q; name = "interp.linear")
_vs_interp_val(tbl, x) =
    Float64(ESM.evaluate_closed_function("interp.linear", Any[tbl, _VS_AX, x]))

_vs_eq(name, N, body) = ESM.Equation(_ao1(_Didx(name, _v("i")), "i", 1, N),
                                     _ao1(body, "i", 1, N))

# (1) sin(u[i]+w[i]) + cos(u[i]+w[i]) — one repeated LANE-VARYING subexpression.
function _vs_m_intra(N)
    s = _op("+", _idx("u", _v("i")), _idx("w", _v("i")))
    ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("u"), _vs_state("w")),
              [_vs_eq("u", N, _op("+", _op("sin", s), _op("cos", s))),
               _vs_eq("w", N, _n(0.0))])
end
_vs_ics_intra(N) = merge(Dict("u[$k]" => 0.3 + 0.11k for k in 1:N),
                         Dict("w[$k]" => -0.2 + 0.07k for k in 1:N))

# (2) a reaction flux `k*A[i]*B[i]` in three species' balances (three kernels), each
#     under a DIFFERENT stoichiometric wrapper so the flux is a shared CHILD rather than
#     a whole shared template.
function _vs_m_flux(N)
    flux = _op("*", _v("k"), _op("*", _idx("A", _v("i")), _idx("B", _v("i"))))
    ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("A"), _vs_state("B"),
                                             _vs_state("C"), _vs_param("k", 0.7)),
              [_vs_eq("A", N, _op("neg", flux)),
               _vs_eq("B", N, _op("*", _n(2.0), flux)),
               _vs_eq("C", N, _op("*", _n(3.0), flux))])
end
_vs_ics_flux(N) = merge(Dict("A[$k]" => 0.5 + 0.1k for k in 1:N),
                        Dict("B[$k]" => 1.5 - 0.05k for k in 1:N),
                        Dict("C[$k]" => 0.0 for k in 1:N))

# (3) a def that references another def: `s = a[i]+b[i]` and `sin(s)` are BOTH shared.
function _vs_m_nested(N)
    s = _op("+", _idx("a", _v("i")), _idx("b", _v("i")))
    ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b"),
                                             _vs_state("x"), _vs_state("y")),
              [_vs_eq("x", N, _op("+", _op("sin", s), _op("cos", s))),
               _vs_eq("y", N, _op("*", _op("sin", s), _n(2.0)))])
end
_vs_ics_nested(N) = merge(Dict("a[$k]" => 0.2 + 0.09k for k in 1:N),
                          Dict("b[$k]" => -0.4 + 0.13k for k in 1:N),
                          Dict("x[$k]" => 0.0 for k in 1:N),
                          Dict("y[$k]" => 0.0 for k in 1:N))

# (4) `u[i]^2 + 3*u[i]^2` — the shared node is a `^` with a LITERAL exponent, and the
#     state is seeded NEGATIVE so the Dual-exponent trap is armed.
function _vs_m_pow(N)
    sq = _op("^", _idx("u", _v("i")), _n(2.0))
    ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("u")),
              [_vs_eq("u", N, _op("+", sq, _op("*", _n(3.0), sq)))])
end
_vs_ics_pow(N) = Dict("u[$k]" => 0.6sin(0.7k) - 0.15 for k in 1:N)

# (5) a shared `_VK_PGATHER`: both balances read the SAME live forcing buffer.
function _vs_m_pgather(N)
    ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b"),
                  "F" => ModelVariable(ParameterVariable; shape = ["n"])),
              [_vs_eq("a", N, _op("*", _idx("F", _v("i")), _idx("a", _v("i")))),
               _vs_eq("b", N, _op("+", _idx("F", _v("i")), _idx("b", _v("i"))))])
end
_vs_ics_pgather(N) = merge(Dict("a[$k]" => 0.5k for k in 1:N),
                           Dict("b[$k]" => 2.0k for k in 1:N))
_vs_forcing(N) = [1.0 + 0.25k for k in 1:N]

# (6) a shared `_VK_FN`: two kernels calling `interp.linear` over the SAME table with
#     the SAME per-cell query.
function _vs_m_fn(N)
    q = _idx("a", _v("i"))
    ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b")),
              [_vs_eq("a", N, _vs_interp(_VS_TBL_A, q)),
               _vs_eq("b", N, _op("*", _n(2.0), _vs_interp(_VS_TBL_A, q)))])
end
_vs_ics_fn(N) = merge(Dict("a[$k]" => 0.05k for k in 1:N),
                      Dict("b[$k]" => 0.0 for k in 1:N))

# (7) `sin(k*u[i]) + cos(k*u[i])` — the shared def depends on a PARAMETER, which is what
#     the parameter-axis AD test differentiates through.
function _vs_m_kpar(N)
    ku = _op("*", _v("k"), _idx("u", _v("i")))
    ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("u"), _vs_param("k", 0.7)),
              [_vs_eq("u", N, _op("+", _op("sin", ku), _op("cos", ku)))])
end
_vs_ics_kpar(N) = Dict("u[$k]" => 0.4k - 0.3 for k in 1:N)

# (8) a 3-point stencil whose neighbour SUM is repeated: the interior kernel shares it,
#     the two single-lane ghost/boundary kernels are a different `len` and share nothing.
function _vs_m_stencil(N)
    nb = _op("+", _idx("c", _op("-", _v("i"), _i(1))), _idx("c", _op("+", _v("i"), _i(1))))
    ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("c")),
              [_vs_eq("c", N, _op("+", _op("sin", nb), _op("cos", nb)))])
end
_vs_ics_stencil(N) = Dict("c[$k]" => 0.2k for k in 1:N)

# (9) NOTHING to share: two kernels over different states, no repeated subexpression.
function _vs_m_noshare(N)
    ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b")),
              [_vs_eq("a", N, _op("sin", _idx("a", _v("i")))),
               _vs_eq("b", N, _op("cos", _idx("b", _v("i"))))])
end
_vs_ics_noshare(N) = merge(Dict("a[$k]" => 0.1k for k in 1:N),
                           Dict("b[$k]" => 0.3k for k in 1:N))

# The battery, as `(name, model, build-kwargs)`. `N` is small so the `==` oracles stay
# readable; the size-sensitive properties (allocation, N-independence) re-build at scale.
function _vs_battery(N = 6)
    return [
        ("intra-kernel share",   _vs_m_intra(N),   (; initial_conditions = _vs_ics_intra(N))),
        ("cross-kernel flux",    _vs_m_flux(N),    (; initial_conditions = _vs_ics_flux(N))),
        ("def referencing def",  _vs_m_nested(N),  (; initial_conditions = _vs_ics_nested(N))),
        ("shared ^ literal exp", _vs_m_pow(N),     (; initial_conditions = _vs_ics_pow(N))),
        ("shared PGATHER",       _vs_m_pgather(N), (; initial_conditions = _vs_ics_pgather(N),
                                                     param_arrays = Dict("F" => _vs_forcing(N)))),
        ("shared interp FN",     _vs_m_fn(N),      (; initial_conditions = _vs_ics_fn(N))),
        ("shared k*u[i]",        _vs_m_kpar(N),    (; initial_conditions = _vs_ics_kpar(N))),
        ("stencil (mixed len)",  _vs_m_stencil(N), (; initial_conditions = _vs_ics_stencil(N))),
        ("nothing to share",     _vs_m_noshare(N), (; initial_conditions = _vs_ics_noshare(N))),
    ]
end

# ===========================================================================
# These pin the VEC-path lane-vector CSE pass (vec_share.jl), which is now the
# FALLBACK path — the affine path is the default and carries its own per-cell CSE
# (covered by stencil_affine_cse_test). Force the per-cell/vec path for this file so
# it keeps exercising the vec sharing implementation, restoring the environment
# afterward.
_PREV_ESD_VS = get(ENV, "ESS_STENCIL_DISABLE", nothing)
ENV["ESS_STENCIL_DISABLE"] = "1"
@testset "lane-varying vector CSE (vec_share.jl)" begin

# ---------------------------------------------------------------------------
# 1. INTRA-KERNEL. `sin(u[i]+w[i]) + cos(u[i]+w[i])`: `u[i]+w[i]` was lowered TWICE,
#    each copy owning its own N-lane buffer and evaluated on every call.
# ---------------------------------------------------------------------------
@testset "intra-kernel: one repeated lane vector → one slot, two refs" begin
    N = 6
    model = _vs_m_intra(N)
    ics = _vs_ics_intra(N)
    f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

    @test diag.n_vec_slots == 1
    @test diag.n_vec_shared == 2              # exactly two occurrence sites collapsed
    @test _vs_n_refs(f!) == 2
    # The def is the `u[i]+w[i]` add, over the two gathers — not one of them.
    def = _vs_prelude(f!)[1]
    @test def.kind === ESM._VK_OP && def.op === :+
    @test length(def.children) == 2
    @test all(c -> c.kind === ESM._VK_GATHER, def.children)
    # ...and the two gathers UNDERNEATH it stay inline: once `u[i]+w[i]` is one node,
    # each gather has in-degree 1. (A count taken on the original TREES would have seen
    # two copies of each and minted pointless slots for them.)
    @test diag.n_vec_slots == 1

    # NUMERIC IDENTITY, against a hand-written oracle — bit-for-bit.
    du = _vs_du(f!, u0, p, 0.0)
    for k in 1:N
        s = u0[vm["u[$k]"]] + u0[vm["w[$k]"]]
        @test du[vm["u[$k]"]] == sin(s) + cos(s)
        @test du[vm["w[$k]"]] == 0.0
    end
    _vs_check_ir(f!, diag)
end

# ---------------------------------------------------------------------------
# 2. CROSS-KERNEL — the shape that matters in practice. A reaction flux written into
#    several species' balances used to be recomputed once per balance.
# ---------------------------------------------------------------------------
@testset "cross-kernel: a shared flux collapses three species' templates" begin
    N = 6
    model = _vs_m_flux(N)
    ics = _vs_ics_flux(N)
    f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

    @test diag.n_vec_kernels == 3
    @test diag.n_vec_slots == 1                       # ONE lane vector for the flux
    @test diag.n_vec_shared == 3                      # three balances read it
    @test _vs_n_refs(f!) == 3
    # The def IS `k*A[i]*B[i]`; every gather it needs lives inside it.
    def = _vs_prelude(f!)[1]
    @test def.kind === ESM._VK_OP && def.op === :*
    @test count(x -> x.kind === ESM._VK_GATHER, _vs_nodes(def)) == 2
    # No kernel still owns a gather — the whole flux moved into the prelude, and each
    # balance is now its stoichiometric wrapper over one buffer read.
    @test _vs_nkind(f!, ESM._VK_GATHER) == 0
    @test _vs_nkind(f!, ESM._VK_VCACHED) == 3

    du = _vs_du(f!, u0, p, 0.0)
    for k in 1:N
        flux = 0.7 * (u0[vm["A[$k]"]] * u0[vm["B[$k]"]])
        @test du[vm["A[$k]"]] == -flux
        @test du[vm["B[$k]"]] == 2.0 * flux
        @test du[vm["C[$k]"]] == 3.0 * flux
    end
    _vs_check_ir(f!, diag)
end

@testset "cross-kernel: a shared flux under a shared SIGN gives a def-over-def" begin
    # `D(A) = D(B) = -k·A·B` and `D(C) = 2·k·A·B`: the NEGATED flux is shared by two
    # balances and the bare flux by the negation and the third balance, so the pass
    # naturally produces a two-level prelude with no help from the model author.
    N = 5
    flux = _op("*", _v("k"), _op("*", _idx("A", _v("i")), _idx("B", _v("i"))))
    model = ESM.Model(
        Dict{String,ESM.ModelVariable}(_vs_state("A"), _vs_state("B"), _vs_state("C"),
                                       _vs_param("k", 0.7)),
        [_vs_eq("A", N, _op("neg", flux)), _vs_eq("B", N, _op("neg", flux)),
         _vs_eq("C", N, _op("*", _n(2.0), flux))])
    ics = _vs_ics_flux(N)
    f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

    @test diag.n_vec_slots == 2
    @test diag.n_vec_shared == 4          # flux read 2× (the neg + C's `*`), neg read 2×
    pre = _vs_prelude(f!)
    @test pre[1].op === :*                # the flux itself...
    @test pre[2].op === :neg              # ...and the negation OF it, strictly above
    @test length(_vs_refs(pre[2])) == 1 && _vs_refs(pre[2])[1].idx == 1

    du = _vs_du(f!, u0, p, 0.0)
    for k in 1:N
        flux_k = 0.7 * (u0[vm["A[$k]"]] * u0[vm["B[$k]"]])
        @test du[vm["A[$k]"]] == -flux_k
        @test du[vm["B[$k]"]] == -flux_k
        @test du[vm["C[$k]"]] == 2.0 * flux_k
    end
    _vs_check_ir(f!, diag)
end

@testset "cross-kernel: two IDENTICAL templates both collapse to a bare ref" begin
    # `D(A[i]) = D(B[i]) = -k*A[i]*B[i]` — the two kernels' whole templates are the same
    # value. Each kernel ROOT contributes an edge, so the root itself hoists and BOTH
    # templates become a single `_VK_VCACHED` node.
    N = 5
    flux = _op("*", _v("k"), _op("*", _idx("A", _v("i")), _idx("B", _v("i"))))
    model = ESM.Model(
        Dict{String,ESM.ModelVariable}(_vs_state("A"), _vs_state("B"), _vs_param("k", 0.9)),
        [_vs_eq("A", N, _op("neg", flux)), _vs_eq("B", N, _op("neg", flux))])
    ics = merge(Dict("A[$k]" => 1.0 + 0.2k for k in 1:N),
                Dict("B[$k]" => 2.0 - 0.3k for k in 1:N))
    f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

    @test diag.n_vec_kernels == 2
    @test diag.n_vec_slots == 1
    @test diag.n_vec_shared == 2
    @test all(vk -> vk.template.kind === ESM._VK_VCACHED, _vs_kernels(f!))
    @test diag.template_node_count == 2      # both templates are now ONE node each

    du = _vs_du(f!, u0, p, 0.0)
    for k in 1:N
        want = -(0.9 * (u0[vm["A[$k]"]] * u0[vm["B[$k]"]]))
        @test du[vm["A[$k]"]] == want
        @test du[vm["B[$k]"]] == want
    end
    _vs_check_ir(f!, diag)
end

@testset "a kernel ROOT that is also a SUBTREE of another kernel hoists like any node" begin
    # `D(a[i]) = a[i]*b[i]` and `D(b[i]) = 2*(a[i]*b[i])`: kernel 1's whole template is a
    # child of kernel 2's. Its in-degree is 1 (its own root edge) + 1 (kernel 2's `*`).
    N = 4
    prod = _op("*", _idx("a", _v("i")), _idx("b", _v("i")))
    model = ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b")),
                      [_vs_eq("a", N, prod), _vs_eq("b", N, _op("*", _n(2.0), prod))])
    ics = merge(Dict("a[$k]" => 1.0k for k in 1:N), Dict("b[$k]" => 3.0k for k in 1:N))
    f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

    @test diag.n_vec_slots == 1
    @test diag.n_vec_shared == 2
    @test _vs_kernels(f!)[1].template.kind === ESM._VK_VCACHED

    du = _vs_du(f!, u0, p, 0.0)
    for k in 1:N
        @test du[vm["a[$k]"]] == (1.0k) * (3.0k)
        @test du[vm["b[$k]"]] == 2.0 * ((1.0k) * (3.0k))
    end
    _vs_check_ir(f!, diag)
end

@testset "a REDUCE (contraction) shares like any other O(len) node" begin
    # D(y[i]) = D(z[i]) = Σ_k A[i,k]·x[k]. `_VK_REDUCE` is a hoist candidate (an axis
    # fold is O(len) work), so both kernels collapse onto one def.
    A = [1.0 2.0 3.0; 4.0 5.0 6.0]
    body = _op("*", _idx("A", _v("i"), _v("k")), _idx("x", _v("k")))
    rhs() = EarthSciAST.OpExpr("arrayop", ESM.ASTExpr[]; output_idx = Any["i"],
                               expr_body = body, ranges = Dict("i" => [1, 2], "k" => [1, 3]),
                               reduce = "+")
    model = ESM.Model(
        Dict{String,ESM.ModelVariable}(_vs_state("y"), _vs_state("z"), _vs_state("x")),
        [ESM.Equation(_ao1(_Didx("y", _v("i")), "i", 1, 2), rhs()),
         ESM.Equation(_ao1(_Didx("z", _v("i")), "i", 1, 2), rhs())])
    ics = Dict("y[1]" => 0.0, "y[2]" => 0.0, "z[1]" => 0.0, "z[2]" => 0.0,
               "x[1]" => 1.0, "x[2]" => 2.0, "x[3]" => 3.0)
    f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics,
                                                       const_arrays = Dict("A" => A))
    @test diag.n_vec_slots == 1
    @test _vs_prelude(f!)[1].kind === ESM._VK_REDUCE
    @test diag.n_vec_shared == 2

    x = [u0[vm["x[$k]"]] for k in 1:3]
    du = _vs_du(f!, u0, p, 0.0)
    for i in 1:2
        want = sum(A[i, k] * x[k] for k in 1:3)
        @test du[vm["y[$i]"]] ≈ want rtol = 1e-14
        @test du[vm["z[$i]"]] == du[vm["y[$i]"]]      # the same buffer, read twice
    end
    _vs_check_ir(f!, diag)
end

# ---------------------------------------------------------------------------
# 3. THE CORRECTNESS CORE — SHARING MUST DECLINE. A merge of two nodes holding
#    DIFFERENT vectors does not crash; it silently computes the wrong model. Each of
#    these pairs is structurally identical and differs only in the LANE DATA, which is
#    precisely what `_struct_sig!` (the grouping key one level down) throws away.
# ---------------------------------------------------------------------------
@testset "sharing declines when the lane data differs" begin

    @testset "two GATHERs over different slot vectors (different arrays)" begin
        # `sin(a[i]) + cos(a[i])` and `sin(b[i]) + cos(b[i])` — identical trees, different
        # gather slots. Each kernel shares its OWN gather; they must not share each other's.
        N = 5
        f(x) = _op("+", _op("sin", _idx(x, _v("i"))), _op("cos", _idx(x, _v("i"))))
        model = ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b")),
                          [_vs_eq("a", N, f("a")), _vs_eq("b", N, f("b"))])
        ics = merge(Dict("a[$k]" => 0.1k for k in 1:N), Dict("b[$k]" => 0.5k for k in 1:N))
        f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

        @test diag.n_vec_slots == 2                     # TWO defs, not one
        @test all(d -> d.kind === ESM._VK_GATHER, _vs_prelude(f!))
        s1, s2 = _vs_def_slots(f!)
        @test s1 != s2                                  # ...over disjoint slot vectors
        @test isempty(intersect(s1, s2))

        du = _vs_du(f!, u0, p, 0.0)
        for k in 1:N
            a, b = 0.1k, 0.5k
            @test du[vm["a[$k]"]] == sin(a) + cos(a)
            @test du[vm["b[$k]"]] == sin(b) + cos(b)    # NOT sin(a)+cos(a)
        end
        _vs_check_ir(f!, diag)
    end

    @testset "two GATHERs over different CELLS of the same array" begin
        # `a[i]` vs `a[i+1]` — the SAME array, shifted. The slot vectors differ by one, so
        # a key that hashed the array (rather than the slots) would merge them.
        N = 6
        sh(off) = _idx("a", _op("+", _v("i"), _i(off)))
        f(e) = _op("+", _op("sin", e), _op("cos", e))
        model = ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b")),
                          [_vs_eq("b", N - 1, f(sh(1))), _vs_eq("a", N - 1, f(sh(0)))])
        ics = merge(Dict("a[$k]" => 0.13k for k in 1:N), Dict("b[$k]" => 0.0 for k in 1:N))
        f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

        @test diag.n_vec_slots == 2
        s1, s2 = _vs_def_slots(f!)
        @test s1 != s2

        du = _vs_du(f!, u0, p, 0.0)
        for k in 1:(N - 1)
            here, nxt = 0.13k, 0.13 * (k + 1)
            @test du[vm["a[$k]"]] == sin(here) + cos(here)
            @test du[vm["b[$k]"]] == sin(nxt) + cos(nxt)   # the SHIFTED vector
        end
        _vs_check_ir(f!, diag)
    end

    @testset "different `len`: a 5-lane and a 3-lane kernel never merge a leaf" begin
        # `len` is in the key for exactly this: two `_VK_LITERAL`s (or `_VK_INVARIANT`s)
        # in kernels of different lane counts are structurally identical but hold
        # different-LENGTH vectors. Merging them would hand a 5-lane buffer to a 3-lane
        # broadcast. `_vs_check_ir`'s lane-length invariant is the direct assertion; the
        # values below are the consequence.
        NA, NB = 5, 3
        lin(x) = _op("+", _op("*", _n(2.0), _idx(x, _v("i"))), _n(2.0))
        expk(x) = _op("*", _op("exp", _v("k")), _idx(x, _v("i")))
        model = ESM.Model(
            Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b"),
                                           _vs_state("c"), _vs_state("d"),
                                           _vs_param("k", 0.3)),
            [_vs_eq("a", NA, lin("a")), _vs_eq("b", NB, lin("b")),
             _vs_eq("c", NA, expk("c")), _vs_eq("d", NB, expk("d"))])
        ics = merge(Dict("a[$k]" => 1.0k for k in 1:NA), Dict("b[$k]" => 2.0k for k in 1:NB),
                    Dict("c[$k]" => 0.5k for k in 1:NA), Dict("d[$k]" => 1.5k for k in 1:NB))
        f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

        @test diag.n_vec_kernels == 4
        lens = sort([vk.len for vk in _vs_kernels(f!)])
        @test lens == [3, 3, 5, 5]                      # both lane counts really are present
        # The `exp(k)` invariant is one VALUE but two different-length vectors, so it
        # stays TWO `_VK_INVARIANT` nodes (they share a scalar cache slot instead).
        @test _vs_nkind(f!, ESM._VK_INVARIANT) == 2

        e = exp(0.3)
        du = _vs_du(f!, u0, p, 0.0)
        for k in 1:NA
            @test du[vm["a[$k]"]] == 2.0 * (1.0k) + 2.0
            @test du[vm["c[$k]"]] == e * (0.5k)
        end
        for k in 1:NB
            @test du[vm["b[$k]"]] == 2.0 * (2.0k) + 2.0
            @test du[vm["d[$k]"]] == e * (1.5k)
        end
        _vs_check_ir(f!, diag)
    end

    @testset "two `interp.*` calls over DIFFERENT const tables (content-keyed spec)" begin
        # Same function, same per-cell QUERY (so the children value-number identically) and
        # the same lane count — the ONLY difference is the const table, which lives in the
        # typed spec, not in `children`. `_struct_sig!` splits these into separate kernels;
        # this key must keep them apart too, or every lane would read table A.
        N = 5
        q = _idx("a", _v("i"))
        model = ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b")),
                          [_vs_eq("a", N, _vs_interp(_VS_TBL_A, q)),
                           _vs_eq("b", N, _vs_interp(_VS_TBL_B, q))])
        ics = merge(Dict("a[$k]" => 0.4k for k in 1:N), Dict("b[$k]" => 0.0 for k in 1:N))
        f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

        @test diag.n_vec_kernels == 2
        # The shared QUERY (`a[i]`) IS lifted — one gather for both kernels...
        @test diag.n_vec_slots == 1
        @test _vs_prelude(f!)[1].kind === ESM._VK_GATHER
        # ...while the two `_VK_FN`s stay in their own kernels: they did NOT merge.
        @test _vs_nkind(f!, ESM._VK_FN) == 2

        du = _vs_du(f!, u0, p, 0.0)
        for k in 1:N
            x = 0.4k
            rA = _vs_interp_val(_VS_TBL_A, x)
            rB = _vs_interp_val(_VS_TBL_B, x)
            @test rA != rB                              # the trap is armed
            @test du[vm["a[$k]"]] == rA
            @test du[vm["b[$k]"]] == rB                 # NOT rA
        end
        _vs_check_ir(f!, diag)
    end

    @testset "two PGATHERs over DIFFERENT forcing buffers (identity-keyed)" begin
        # Same slots, same length, same everything except WHICH live buffer they alias.
        N = 4
        F = [1.0, 2.0, 3.0, 4.0]
        G = [100.0, 200.0, 300.0, 400.0]
        model = ESM.Model(
            Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b"),
                "F" => ModelVariable(ParameterVariable; shape = ["n"]),
                "G" => ModelVariable(ParameterVariable; shape = ["n"])),
            [_vs_eq("a", N, _op("*", _idx("F", _v("i")), _idx("a", _v("i")))),
             _vs_eq("b", N, _op("*", _idx("G", _v("i")), _idx("a", _v("i"))))])
        ics = merge(Dict("a[$k]" => 1.0k for k in 1:N), Dict("b[$k]" => 0.0 for k in 1:N))
        f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics,
            param_arrays = Dict("F" => F, "G" => G))

        # The shared gather `a[i]` lifts; the two PGATHERs do NOT merge.
        @test _vs_nkind(f!, ESM._VK_PGATHER) == 2
        pgs = [x for vk in _vs_kernels(f!) for x in _vs_nodes(vk.template)
               if x.kind === ESM._VK_PGATHER]
        @test pgs[1].slots == pgs[2].slots                  # identical slot vectors...
        @test pgs[1].payload !== pgs[2].payload             # ...different buffer OBJECTS

        du = _vs_du(f!, u0, p, 0.0)
        for k in 1:N
            @test du[vm["a[$k]"]] == F[k] * (1.0k)
            @test du[vm["b[$k]"]] == G[k] * (1.0k)          # NOT F[k]
        end
        _vs_check_ir(f!, diag)
    end

    @testset "two BOXED `fn`s with different NAMES never collide" begin
        # The all-scalar `datetime.*` path carries a `(fname, nothing)` payload and no
        # typed spec, so its content key is the NAME. Two boxed `fn`s over the SAME
        # per-cell query differ in nothing else — the key had better see the name.
        N = 4
        q = _idx("a", _v("i"))
        doy(x) = _op("fn", x; name = "datetime.day_of_year")
        hr(x) = _op("fn", x; name = "datetime.hour")
        model = ESM.Model(
            Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b"), _vs_state("c")),
            [_vs_eq("a", N, _op("+", doy(q), doy(q))),      # SAME fn twice ⇒ shared
             _vs_eq("b", N, doy(q)),                        # ...and again, cross-kernel
             _vs_eq("c", N, hr(q))])                        # a DIFFERENT fn ⇒ its own node
        secs = k -> 86400.0 * (37k) + 3600.0 * k
        ics = merge(Dict("a[$k]" => secs(k) for k in 1:N),
                    Dict("b[$k]" => 0.0 for k in 1:N), Dict("c[$k]" => 0.0 for k in 1:N))
        f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

        # One def for `day_of_year(a[i])` (read 3×) — and `hour(a[i])` is NOT it.
        boxed = [d for d in _vs_prelude(f!) if d.kind === ESM._VK_FN]
        @test length(boxed) == 1
        @test (boxed[1].payload::Tuple{String,Any})[1] == "datetime.day_of_year"
        @test _vs_nkind(f!, ESM._VK_FN) == 1            # the `hour` map, still in kernel 3

        du = _vs_du(f!, u0, p, 0.0)
        for k in 1:N
            d = Float64(ESM.evaluate_closed_function("datetime.day_of_year", Any[secs(k)]))
            h = Float64(ESM.evaluate_closed_function("datetime.hour", Any[secs(k)]))
            @test du[vm["a[$k]"]] == d + d
            @test du[vm["b[$k]"]] == d
            @test du[vm["c[$k]"]] == h                 # NOT the day-of-year value
        end
        _vs_check_ir(f!, diag)
    end

    @testset "two INVARIANTs over different PARAMETERS never collide" begin
        # A `_VK_INVARIANT` is keyed by the SCALAR value number of its `_Node` payload.
        # `exp(k1)*a[i]` and `exp(k2)*a[i]` are one tree shape with two values.
        N = 4
        fac(k, x) = _op("*", _op("exp", _v(k)), _idx(x, _v("i")))
        e2(k, x) = _op("+", _op("sin", fac(k, x)), _op("cos", fac(k, x)))
        model = ESM.Model(
            Dict{String,ESM.ModelVariable}(_vs_state("a"), _vs_state("b"),
                                           _vs_param("k1", 0.3), _vs_param("k2", 1.7)),
            [_vs_eq("a", N, e2("k1", "a")), _vs_eq("b", N, e2("k2", "a"))])
        ics = merge(Dict("a[$k]" => 0.25k for k in 1:N), Dict("b[$k]" => 0.0 for k in 1:N))
        f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

        # Each kernel's `exp(k)*a[i]` is shared WITHIN the kernel (a `sin` and a `cos` read
        # it), so there are TWO invariant-bearing defs — one per parameter — and never one.
        # (The query gather `a[i]` is common to both and lifts to a third def; that one IS
        # the same vector, so sharing it is right.)
        @test diag.n_vec_slots == 3
        @test diag.n_vec_shared == 6
        pre = _vs_prelude(f!)
        @test count(d -> any(x -> x.kind === ESM._VK_INVARIANT, _vs_nodes(d)), pre) == 2
        @test count(d -> d.kind === ESM._VK_GATHER, pre) == 1

        du = _vs_du(f!, u0, p, 0.0)
        for k in 1:N
            x = 0.25k
            va = exp(0.3) * x
            vb = exp(1.7) * x
            @test va != vb
            @test du[vm["a[$k]"]] == sin(va) + cos(va)
            @test du[vm["b[$k]"]] == sin(vb) + cos(vb)   # NOT the k1 value
        end
        _vs_check_ir(f!, diag)
    end
end

# ---------------------------------------------------------------------------
# 4. THE HOIST POLICY (`_vk_hoistable`). Two independent bars: the node must OWN the
#    buffer it returns, and it must cost more than the O(1) buffer read that replaces it.
# ---------------------------------------------------------------------------
@testset "_vk_hoistable admits exactly the O(len) buffer-owning nodes" begin
    ga = ESM._mkvnode(kind = ESM._VK_GATHER, slots = [1, 2, 3], buf = zeros(3))

    # (a) The broadcast-fill leaves are O(1)-or-fill: lifting one trades a `fill!` for a
    #     `fill!` plus a slot. `_VK_CONSTVEC` is already O(1) (`_eval_vec` returns `vals`).
    @test !ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_LITERAL, literal = 2.0, buf = zeros(3)))
    @test !ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_CONSTVEC, vals = [1.0, 2.0, 3.0]))
    @test !ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_STATE, idx = 1, buf = zeros(3)))
    @test !ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_PARAM, sym = :k, buf = zeros(3)))
    @test !ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_TIME, buf = zeros(3)))
    @test !ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_INVARIANT, buf = zeros(3),
              payload = ESM._mknode(kind = ESM._NK_LITERAL, literal = 1.0)))

    # (b) GATHER and PGATHER are LEAVES but are O(len) index loops — sharing those IS a
    #     win, which is why the line is drawn on COST, not on arity.
    @test ESM._vk_hoistable(ga)
    @test ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_PGATHER, payload = [1.0, 2.0, 3.0],
                                         slots = [1, 2, 3], buf = zeros(3)))
    @test ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_REDUCE, op = :+, children = [ga],
                                         buf = zeros(3)))
    @test ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_FN, op = :fn, children = [ga],
                                         buf = zeros(3)))
    @test ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_OP, op = :+, children = [ga, ga],
                                         buf = zeros(3)))

    # (c) THE SUBTLE ONE. `_eval_vec_op`'s pass-through arms — 1-ary `+`, 1-ary `*`, `Pre`
    #     — return their CHILD's buffer and never write their own. A `_VK_VCACHED` ref to
    #     one would read a buffer NOTHING EVER WROTE (`_vk_cached_buf` hands back
    #     `_vbuf(def, T)`, which for these is uninitialized scratch). They must never lift.
    @test !ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_OP, op = :+, children = [ga],
                                          buf = zeros(3)))
    @test !ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_OP, op = :*, children = [ga],
                                          buf = zeros(3)))
    @test !ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_OP, op = :Pre, children = [ga],
                                          buf = zeros(3)))
    # ...but the 2-ary forms of the same ops are ordinary interior nodes.
    @test ESM._vk_hoistable(ESM._mkvnode(kind = ESM._VK_OP, op = :*, children = [ga, ga],
                                         buf = zeros(3)))
end

@testset "a SHARED pass-through op is never lifted (it would read an unwritten buffer)" begin
    # `sin(+(u[i]+w[i])) + cos(+(u[i]+w[i]))` — the 1-ary `+` wrapper is a genuine
    # `_VK_OP` with in-degree 2, so ONLY the `_vk_hoistable` policy stops it being lifted.
    # If it were, both `sin` and `cos` would broadcast over the wrapper's own `buf`, which
    # `_eval_vec_op` never writes: the RHS would silently be built from uninitialized
    # memory. The value assertion is against the hand-written oracle, so an unwritten
    # buffer cannot slip past as "some number".
    N = 6
    w1 = _op("+", _op("+", _idx("u", _v("i")), _idx("w", _v("i"))))   # 1-ary + of (u+w)
    model = ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("u"), _vs_state("w")),
                      [_vs_eq("u", N, _op("+", _op("sin", w1), _op("cos", w1))),
                       _vs_eq("w", N, _n(0.0))])
    ics = _vs_ics_intra(N)
    f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

    # The wrapper really is present, and really is shared...
    onearys = [x for vk in _vs_kernels(f!) for x in _vs_nodes(vk.template)
               if x.kind === ESM._VK_OP && x.op === :+ && length(x.children) == 1]
    @test !isempty(onearys)
    # ...and NOTHING was lifted: the wrapper is unhoistable, and its child then has
    # in-degree 1 (its single parent is the one canonical wrapper), so it stays inline too.
    @test diag.n_vec_slots == 0
    @test isempty(_vs_prelude(f!))
    @test _vs_nkind(f!, ESM._VK_VCACHED) == 0

    du = _vs_du(f!, u0, p, 0.0)
    for k in 1:N
        s = u0[vm["u[$k]"]] + u0[vm["w[$k]"]]
        @test du[vm["u[$k]"]] == sin(s) + cos(s)
    end
    _vs_check_ir(f!, diag)

    # Both emitters, since `_oop_eval_vec` has its own pass-through arms.
    fo, _, po, _, _ = ESM.build_evaluator(model; initial_conditions = ics, form = :oop)
    @test fo(u0, po, 0.0) == du
end

# ---------------------------------------------------------------------------
# 5. `x*x` — in-degree 2 from a SINGLE parent. `_eval_vec_op` evaluates `c[1]` and `c[2]`
#    separately and would walk the gather twice, so counting per parent EDGE (not per
#    parent) is what makes this a hoist.
# ---------------------------------------------------------------------------
@testset "x*x: one node used TWICE by ONE parent is lifted" begin
    N = 5
    model = ESM.Model(Dict{String,ESM.ModelVariable}(_vs_state("u")),
                      [_vs_eq("u", N, _op("*", _idx("u", _v("i")), _idx("u", _v("i"))))])
    ics = Dict("u[$k]" => 1.0k - 2.0 for k in 1:N)
    f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

    @test diag.n_vec_slots == 1
    @test diag.n_vec_shared == 2                       # both operand edges collapsed
    @test _vs_prelude(f!)[1].kind === ESM._VK_GATHER
    tmpl = _vs_kernels(f!)[1].template
    @test tmpl.kind === ESM._VK_OP && tmpl.op === :*
    @test all(c -> c.kind === ESM._VK_VCACHED, tmpl.children)
    @test tmpl.children[1] === tmpl.children[2]        # ONE ref object serves both edges

    du = _vs_du(f!, u0, p, 0.0)
    for k in 1:N
        x = 1.0k - 2.0
        @test du[vm["u[$k]"]] == x * x
    end
    _vs_check_ir(f!, diag)
end

# ---------------------------------------------------------------------------
# 6. ZERO ALLOCATION. The whole point of the buffer discipline: a `_VK_VCACHED` read is a
#    field load into a build-time buffer, so a shared lane vector must cost nothing per
#    call. Covered at scale, including a shared PGATHER def and a shared interp-FN def.
# ---------------------------------------------------------------------------
@testset "a shared lane vector keeps the RHS allocation-free" begin
    for N in (64, 512)
        @test built_rhs_alloc_bytes(_vs_m_intra(N);
                                    initial_conditions = _vs_ics_intra(N)) == 0
        @test built_rhs_alloc_bytes(_vs_m_flux(N);
                                    initial_conditions = _vs_ics_flux(N)) == 0
        @test built_rhs_alloc_bytes(_vs_m_nested(N);
                                    initial_conditions = _vs_ics_nested(N)) == 0
        # A shared `_VK_PGATHER` def — the live-forcing gather stays `Vector{Float64}`
        # and writes `buf`, so the ref reads `buf` too (never a widened `altbuf`).
        @test built_rhs_alloc_bytes(_vs_m_pgather(N);
                                    initial_conditions = _vs_ics_pgather(N),
                                    param_arrays = Dict("F" => _vs_forcing(N))) == 0
        # A shared `_VK_FN` def — the zero-box `interp.*` whole-array kernel.
        @test built_rhs_alloc_bytes(_vs_m_fn(N); initial_conditions = _vs_ics_fn(N)) == 0
    end
end

# ---------------------------------------------------------------------------
# 7. `:inplace` ≡ `:oop`, BITWISE. The two emitters read the same defs through DIFFERENT
#    machinery — `f!` through `_vk_cached_buf(payload)`, `f` through `vcache[idx]` — so a
#    ref whose `payload` and `idx` disagreed would show up here and nowhere else.
# ---------------------------------------------------------------------------
@testset ":inplace and :oop agree bit-for-bit on every shared-vector model" begin
    for (name, model, kw) in _vs_battery()
        @testset "$name" begin
            fi, u0, p, _, _ = ESM.build_evaluator(model; kw...)
            fo, _, po, _, _ = ESM.build_evaluator(model; kw..., form = :oop)
            for t in (0.0, 0.37, -1.9)
                @test fo(u0, po, t) == _vs_du(fi, u0, p, t)
            end
        end
    end
end

@testset "the IR invariants hold for every model in the battery" begin
    for (name, model, kw) in _vs_battery()
        @testset "$name" begin
            f!, _, _, _, _, diag = ESM._build_evaluator_impl(model; kw...)
            _vs_check_ir(f!, diag)
        end
    end
end

# ---------------------------------------------------------------------------
# 8. AD THROUGH A SHARED DEF. A def is evaluated once and read N times; if the ref
#    handed back the wrong buffer under a Dual value type the PRIMAL could still look
#    perfect while every partial was zero (or NaN).
# ---------------------------------------------------------------------------
@testset "ForwardDiff through a shared lane vector" begin

    @testset "Jacobian w.r.t. the STATE, against the analytic oracle" begin
        # D(u[i]) = sin(k·u[i]) + cos(k·u[i]) with `k·u[i]` shared ⇒ the Jacobian is
        # DIAGONAL with entries k·(cos(k·u) − sin(k·u)).
        N = 5
        model, ics = _vs_m_kpar(N), _vs_ics_kpar(N)
        fi, u0, p, _, vm = ESM.build_evaluator(model; initial_conditions = ics)
        fo, _, po, _, _ = ESM.build_evaluator(model; initial_conditions = ics, form = :oop)

        Jo = ForwardDiff.jacobian(uu -> fo(uu, po, 0.0), u0)
        Ji = ForwardDiff.jacobian((d, uu) -> fi(d, uu, p, 0.0), zeros(N), copy(u0))
        @test Ji == Jo                                    # both emitters, same Jacobian
        for i in 1:N, j in 1:N
            want = i == j ? 0.7 * (cos(0.7 * u0[i]) - sin(0.7 * u0[i])) : 0.0
            @test Jo[i, j] ≈ want rtol = 1e-12 atol = 1e-14
        end
        @test all(Jo[i, j] == 0.0 for i in 1:N, j in 1:N if i != j)   # exactly zero
    end

    @testset "derivative w.r.t. a PARAMETER, through the shared def" begin
        # `u` stays `Vector{Float64}` and only the parameter VALUE goes Dual — the axis a
        # state-only test cannot exercise. d/dk Σ_i [sin(k·u_i) + cos(k·u_i)]
        #                                    = Σ_i u_i·[cos(k·u_i) − sin(k·u_i)].
        N = 5
        model, ics = _vs_m_kpar(N), _vs_ics_kpar(N)
        fi, u0, p, _, _ = ESM.build_evaluator(model; initial_conditions = ics)
        fo, _, _, _, _ = ESM.build_evaluator(model; initial_conditions = ics, form = :oop)

        g = ForwardDiff.gradient(v -> sum(fo(u0, (; k = v[1]), 0.0)), [0.7])
        @test eltype(g) === Float64
        want = sum(u0[i] * (cos(0.7 * u0[i]) - sin(0.7 * u0[i])) for i in 1:N)
        @test g[1] ≈ want rtol = 1e-12

        # ...and a central difference on the TRUSTED in-place evaluator agrees.
        h = 1e-6
        fd = (sum(_vs_du(fi, u0, (; k = 0.7 + h), 0.0)) -
              sum(_vs_du(fi, u0, (; k = 0.7 - h), 0.0))) / 2h
        @test isapprox(g[1], fd; rtol = 1e-5, atol = 1e-8)
    end

    @testset "a shared `^` keeps its literal exponent out of the Dual type" begin
        # `u[i]^2 + 3*u[i]^2` over NEGATIVE cells. The `^` node is what gets shared, so its
        # `_VK_LITERAL` exponent now lives inside a PRELUDE DEF. If the shared base widened
        # the exponent to a Dual, ForwardDiff would evaluate ∂(x^y)/∂y = x^y·log(x) and
        # log(negative) would NaN the whole gradient while the primal still looked fine.
        # (`_vk_hoistable` refuses a `_VK_LITERAL`, so the exponent can never hide behind a
        # `_VK_VCACHED` and defeat `_oop_eval_vec`'s `e.kind === _VK_LITERAL` test.)
        N = 8
        model, ics = _vs_m_pow(N), _vs_ics_pow(N)
        fi, u0, p, _, _ = ESM.build_evaluator(model; initial_conditions = ics)
        fo, _, po, _, _ = ESM.build_evaluator(model; initial_conditions = ics, form = :oop)
        _, _, _, _, _, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

        @test any(<(0), u0)                                # the trap is armed
        @test diag.n_vec_slots == 1                        # the `^` really is shared
        @test _vs_prelude(fi)[1].op === :^

        du = _vs_du(fi, u0, p, 0.0)
        for i in 1:N
            @test du[i] == u0[i]^2 + 3.0 * u0[i]^2         # bit-for-bit
        end

        for J in (ForwardDiff.jacobian(uu -> fo(uu, po, 0.0), u0),
                  ForwardDiff.jacobian((d, uu) -> fi(d, uu, p, 0.0), zeros(N), copy(u0)))
            @test !any(isnan, J)
            @test all(isfinite, J)
            for i in 1:N
                @test J[i, i] ≈ 8 * u0[i] rtol = 1e-12 atol = 1e-14   # d/du (4u²) = 8u
            end
        end
    end

    @testset "a shared interp FN differentiates through its per-cell query" begin
        N = 5
        model, ics = _vs_m_fn(N), _vs_ics_fn(N)
        fi, u0, p, _, vm = ESM.build_evaluator(model; initial_conditions = ics)
        fo, _, po, _, _ = ESM.build_evaluator(model; initial_conditions = ics, form = :oop)
        J = ForwardDiff.jacobian(uu -> fo(uu, po, 0.0), u0)
        @test all(isfinite, J)
        # `b`'s row is exactly 2× `a`'s row: the SAME shared def feeds both.
        for k in 1:N
            ra, rb = vm["a[$k]"], vm["b[$k]"]
            ca = vm["a[$k]"]
            @test J[rb, ca] ≈ 2 * J[ra, ca] rtol = 1e-12
        end
        # ...and the slope is the table's own secant on [0,1] (queries 0.05..0.25 all land
        # in the first interval), which the cross-binding contract confirms.
        secant = (_vs_interp_val(_VS_TBL_A, 1.0) - _vs_interp_val(_VS_TBL_A, 0.0)) / 1.0
        for k in 1:N
            @test J[vm["a[$k]"], vm["a[$k]"]] ≈ secant rtol = 1e-10
        end
    end
end

# ---------------------------------------------------------------------------
# 9. LIVE FORCING. A `_VK_PGATHER` def captures the forcing BUFFER, not its contents —
#    a def frozen at build time would silently pin the model to the first bracket's met.
# ---------------------------------------------------------------------------
@testset "an in-place forcing refresh shows through a SHARED PGATHER def" begin
    N = 5
    F = _vs_forcing(N)
    model, ics = _vs_m_pgather(N), _vs_ics_pgather(N)
    f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics,
                                                       param_arrays = Dict("F" => F))
    # The PGATHER really is the shared def (both balances read it).
    @test diag.n_vec_slots == 1
    @test _vs_prelude(f!)[1].kind === ESM._VK_PGATHER
    @test diag.n_vec_shared == 2

    du = _vs_du(f!, u0, p, 0.0)
    for k in 1:N
        @test du[vm["a[$k]"]] == F[k] * u0[vm["a[$k]"]]
        @test du[vm["b[$k]"]] == F[k] + u0[vm["b[$k]"]]
    end

    # The refresh callback's in-place write must be visible on the NEXT call, through the
    # shared def — for BOTH readers, not just the one whose kernel happened to own it.
    F .= [10.0 * k for k in 1:N]
    du2 = _vs_du(f!, u0, p, 0.0)
    for k in 1:N
        @test du2[vm["a[$k]"]] == (10.0k) * u0[vm["a[$k]"]]
        @test du2[vm["b[$k]"]] == (10.0k) + u0[vm["b[$k]"]]
    end
    @test du2 != du                              # ...and it really did move
    _vs_check_ir(f!, diag)
end

# ---------------------------------------------------------------------------
# 10. TOPOLOGICAL ORDER. `f!` runs the vec prelude front to back and `_make_rhs_oop`
#     fills `vcache[s]` in ascending slot order, so a def that references a HIGHER slot
#     would read an unwritten buffer (`f!`) or an `#undef` box (`f`).
# ---------------------------------------------------------------------------
@testset "the vec prelude is topologically ordered (a def refs only defs below it)" begin
    N = 6
    model, ics = _vs_m_nested(N), _vs_ics_nested(N)
    f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)
    pre = _vs_prelude(f!)

    # The case really is nested: `s = a[i]+b[i]` (used by `sin` and `cos`) AND `sin(s)`
    # (used by both kernels) are both shared, so one def REFERENCES the other.
    @test diag.n_vec_slots == 2
    @test diag.n_vec_shared == 4
    nested = [s for s in eachindex(pre) if !isempty(_vs_refs(pre[s]))]
    @test !isempty(nested)                       # a def really does reference a def
    @test pre[nested[1]].op === :sin

    # Every `_VK_VCACHED` inside `pre[s]` points STRICTLY BELOW `s`.
    for s in eachindex(pre), x in _vs_refs(pre[s])
        @test x.idx < s
        @test x.payload === pre[x.idx]
    end

    du = _vs_du(f!, u0, p, 0.0)
    for k in 1:N
        s = u0[vm["a[$k]"]] + u0[vm["b[$k]"]]
        @test du[vm["x[$k]"]] == sin(s) + cos(s)
        @test du[vm["y[$k]"]] == sin(s) * 2.0
    end
    _vs_check_ir(f!, diag)
end

# ---------------------------------------------------------------------------
# 11. N-INDEPENDENCE, preserved. Sharing MOVES nodes from the templates into the prelude,
#     so `template_node_count` alone is no longer the whole picture — all three counts
#     must be invariant across grid sizes, and only the embedded slot/value vectors grow.
# ---------------------------------------------------------------------------
@testset "the compiled node counts stay N-independent" begin
    for (name, mk, mkics) in (("intra-kernel", _vs_m_intra, _vs_ics_intra),
                              ("cross-kernel flux", _vs_m_flux, _vs_ics_flux),
                              ("def referencing def", _vs_m_nested, _vs_ics_nested))
        @testset "$name" begin
            ds = [ESM._build_evaluator_impl(mk(N); initial_conditions = mkics(N))[6]
                  for N in (10, 100)]
            @test ds[1].n_vec_kernels == ds[2].n_vec_kernels
            @test ds[1].n_vec_slots == ds[2].n_vec_slots
            @test ds[1].n_vec_shared == ds[2].n_vec_shared
            @test ds[1].n_vec_prelude_nodes == ds[2].n_vec_prelude_nodes
            @test ds[1].template_node_count == ds[2].template_node_count
            @test ds[1].n_vec_slots >= 1          # ...and the pass actually fired
        end
    end

    # Only the embedded lane vectors grow: the def's gather `slots` is the one thing
    # whose length tracks N.
    f10, = ESM.build_evaluator(_vs_m_intra(10); initial_conditions = _vs_ics_intra(10))
    f100, = ESM.build_evaluator(_vs_m_intra(100); initial_conditions = _vs_ics_intra(100))
    g10 = [x for x in _vs_nodes(_vs_prelude(f10)[1]) if x.kind === ESM._VK_GATHER]
    g100 = [x for x in _vs_nodes(_vs_prelude(f100)[1]) if x.kind === ESM._VK_GATHER]
    @test length(g10) == length(g100) == 2
    @test all(x -> length(x.slots) == 10, g10)
    @test all(x -> length(x.slots) == 100, g100)
end

# ---------------------------------------------------------------------------
# 12. A MODEL WITH NOTHING TO SHARE IS COMPLETELY UNTOUCHED. The pass is an optimization;
#     a document it cannot help must compile to the evaluator it always did.
# ---------------------------------------------------------------------------
@testset "a model the pass cannot help is left alone" begin

    @testset "no array kernels at all: the pass returns immediately" begin
        model = ESM.Model(
            Dict{String,ESM.ModelVariable}(_vs_state("x"), _vs_state("y"), _vs_param("k", 0.5)),
            [ESM.Equation(_op("D", _v("x"); wrt = "t"), _op("*", _v("k"), _v("x"))),
             ESM.Equation(_op("D", _v("y"); wrt = "t"), _op("*", _v("k"), _v("y")))])
        ics = Dict("x" => 2.0, "y" => 3.0)
        f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

        @test diag.n_vec_kernels == 0
        @test diag.n_vec_slots == 0
        @test diag.n_vec_shared == 0
        @test diag.n_vec_prelude_nodes == 0
        @test isempty(_vs_prelude(f!))

        du = _vs_du(f!, u0, p, 0.0)
        @test du[vm["x"]] == 0.5 * 2.0
        @test du[vm["y"]] == 0.5 * 3.0
    end

    @testset "array kernels but nothing repeated: no slots, no refs, same numbers" begin
        N = 8
        model, ics = _vs_m_noshare(N), _vs_ics_noshare(N)
        f!, u0, p, _, vm, diag = ESM._build_evaluator_impl(model; initial_conditions = ics)

        @test diag.n_vec_kernels == 2
        @test diag.n_vec_slots == 0
        @test diag.n_vec_shared == 0
        @test diag.n_vec_prelude_nodes == 0
        @test isempty(_vs_prelude(f!))
        @test _vs_nkind(f!, ESM._VK_VCACHED) == 0     # no node was rewritten at all
        @test diag.template_node_count == 4           # sin(gather) + cos(gather)

        du = _vs_du(f!, u0, p, 0.0)
        for k in 1:N
            @test du[vm["a[$k]"]] == sin(0.1k)
            @test du[vm["b[$k]"]] == cos(0.3k)
        end
        _vs_check_ir(f!, diag)

        # And the RHS is still allocation-free, i.e. the pass added no per-call work.
        @test built_rhs_alloc_bytes(_vs_m_noshare(256);
                                    initial_conditions = _vs_ics_noshare(256)) == 0
    end
end

end # @testset "lane-varying vector CSE (vec_share.jl)"
_PREV_ESD_VS === nothing ? delete!(ENV, "ESS_STENCIL_DISABLE") :
    (ENV["ESS_STENCIL_DISABLE"] = _PREV_ESD_VS)
