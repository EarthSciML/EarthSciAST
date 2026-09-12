# SSA-style class-to-class references in the `:oop` emitter (ess-oop-ssa).
#
# `ESS_OOP_SSA=1` (read at BUILD time; default OFF) makes a consuming access
# kernel reference its producer kernels' RESULT VALUES — the whole value, or a
# few slices of it — instead of gathering the flat extended vector `ue` that the
# producers scattered into, and skips a producer's scatter entirely when static
# accounting shows nothing still reads its block of `ue`. The buffer traffic is
# an implementation artifact (the RHS returns only `du`), so removing it must be
# INVISIBLE in values:
#
#   1. BIT-IDENTITY. A Float64 `:oop` build with the flag on must equal the
#      flag-off build AND the in-place `f!` — `==`, not a tolerance — across
#      fixtures covering each redirect tier: whole-block direct references,
#      sliced sub-block references (state-prefix and shifted-window reads),
#      and a multi-producer slice+concat reference across a split kernel.
#   2. ENGAGEMENT. `oop_ssa_stats` must show redirected edges and skipped
#      scatters actually happened — a fast path that silently degraded to the
#      gather everywhere would still pass (1).
#   3. AD. ForwardDiff over the flag-on build must match the flag-off build
#      exactly: redirects change where operands COME FROM, never what is
#      computed, so Duals ride through untouched.
#
# The trace-side effect (fewer gathers / dynamic_update_slices in the emitted
# module) is asserted in reactant_oop_ssa_test.jl.
using Test
using EarthSciAST
using ForwardDiff
using JSON3

const ESMs = EarthSciAST

_s_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_s_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_s_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_s_ao(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)

function _s_doc(name, vars, eqs, N)
    Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => name),
        "index_sets" => Dict{String,Any}(
            "n" => Dict{String,Any}("kind" => "interval", "size" => N)),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => vars, "equations" => eqs)))
end
_s_state(; kw...) = Dict{String,Any}("type" => "unknown",
                                     (String(k) => v for (k, v) in kw)...)
_s_param(v) = Dict{String,Any}("type" => "parameter", "default" => v)

# A two-level observed chain: g feeds h, h feeds the state. `h`'s `g[i+1]`
# read runs off the end; the BUILD resolves that ghost by splitting `h` into an
# interior kernel (two overlapping affine windows of `g` — tier-2 slices at
# offsets 1 and 2) and a single-cell boundary kernel, so the final `h` read
# spans TWO producers and exercises the multi-segment slice+concat form.
function _s_chain(N)
    _s_doc("SSACHAIN",
        Dict{String,Any}("u" => _s_state(shape = Any["n"]),
                         "g" => _s_state(shape = Any["n"]),
                         "h" => _s_state(shape = Any["n"]),
                         "k" => _s_param(0.25)),
        Any[Dict{String,Any}("lhs" => "g",
                "rhs" => _s_ao(_s_o("+", _s_o("*", 2.0, _s_ix("u", "i")), 1.0))),
            Dict{String,Any}("lhs" => "h",
                "rhs" => _s_ao(_s_o("+", _s_ix("g", "i"),
                                    _s_ix("g", _s_o("+", "i", 1.0))))),
            Dict{String,Any}("lhs" => _s_ao(_s_Dt(_s_ix("u", "i"))),
                "rhs" => _s_ao(_s_o("-", _s_o("*", "k", _s_ix("h", "i")),
                                    _s_ix("u", "i"))))],
        N)
end

# The fan: two materialized observeds read whole-block by several structurally
# DISTINCT consumer classes (congruent ones would be folded into one kernel by
# the class merge and leave fewer edges to redirect). Every `g`/`v` edge is a
# tier-1 whole-block reference; every `c*` state read is a tier-2 slice of `u`.
const _S_BODIES = [
    (g, v) -> _s_o("+", g, v),
    (g, v) -> _s_o("*", g, v),
    (g, v) -> _s_o("+", _s_o("exp", _s_o("neg", g)), v),
    (g, v) -> _s_o("*", _s_o("sqrt", _s_o("abs", g)), _s_o("+", v, 1.0)),
]
function _s_fan(N, M)
    vars = Dict{String,Any}(
        "g" => _s_state(shape = Any["n"]), "v" => _s_state(shape = Any["n"]),
        "k" => _s_param(0.25))
    eqs = Any[
        Dict{String,Any}("lhs" => "g",
            "rhs" => _s_ao(_s_o("+", _s_o("*", 2.0, _s_ix("c1", "i")), 1.0))),
        Dict{String,Any}("lhs" => "v",
            "rhs" => _s_ao(_s_o("*", _s_ix("c1", "i"), _s_ix("c1", "i")))),
    ]
    for m in 1:M
        nm = "c$m"
        vars[nm] = _s_state(shape = Any["n"])
        push!(eqs, Dict{String,Any}(
            "lhs" => _s_ao(_s_Dt(_s_ix(nm, "i"))),
            "rhs" => _s_ao(_s_o("*", "k",
                _S_BODIES[m](_s_ix("g", "i"), _s_ix("v", "i"))))))
    end
    _s_doc("SSAFAN", vars, eqs, N)
end

# The merged-class shape (the ReSEACT chemistry layout): g1/g2 are CONGRUENT
# observed equations, so the kernel-class merge folds them into ONE producer
# whose out slots are the two member runs concatenated. The consumer reads
# g1[i] and g2[i] separately — each a slice at that member's offset inside the
# merged producer's single result value.
function _s_merged(N)
    _s_doc("SSAMERGE",
        Dict{String,Any}("u" => _s_state(shape = Any["n"]),
                         "g1" => _s_state(shape = Any["n"]),
                         "g2" => _s_state(shape = Any["n"]),
                         "k" => _s_param(0.25)),
        Any[Dict{String,Any}("lhs" => "g1",
                "rhs" => _s_ao(_s_o("*", 1.5, _s_ix("u", "i")))),
            Dict{String,Any}("lhs" => "g2",
                "rhs" => _s_ao(_s_o("*", -0.75, _s_ix("u", "i")))),
            Dict{String,Any}("lhs" => _s_ao(_s_Dt(_s_ix("u", "i"))),
                "rhs" => _s_ao(_s_o("+", _s_ix("g1", "i"),
                                    _s_o("*", "k", _s_ix("g2", "i")))))],
        N)
end

# No materialized observeds at all: the only redirects are state-PREFIX reads
# (producer 1 = `u` itself), and there is no scatter to skip.
function _s_nomat(N)
    stencil = _s_o("+", _s_o("-", _s_ix("c", _s_o("-", "i", 1.0)),
                             _s_o("*", 2.0, _s_ix("c", "i"))),
                   _s_ix("c", _s_o("+", "i", 1.0)))
    _s_doc("SSARD",
        Dict{String,Any}("c" => _s_state(shape = Any["n"]),
                         "k" => _s_param(0.1)),
        Any[Dict{String,Any}("lhs" => _s_ao(_s_Dt(_s_ix("c", "i"))),
            "rhs" => _s_ao(_s_o("*", "k", stencil)))],
        N)
end

_s_seed(n) = Float64[0.6 * sin(0.7k) + 1.2 for k in 1:n]

# Both arms pin the flag explicitly, so this file also runs correctly under a
# corpus-wide `ESS_OOP_SSA=1` sweep (the "off" build must really be off).
function _s_build_both(doc)
    off = withenv("ESS_OOP_SSA" => nothing) do
        ESMs.build_evaluator(doc; form = :oop)
    end
    on = withenv("ESS_OOP_SSA" => "1") do
        ESMs.build_evaluator(doc; form = :oop)
    end
    ip = ESMs.build_evaluator(doc)
    return on, off, ip
end

_s_ip(f!, u, p, t) = (du = zero(u); f!(du, u, p, t); du)

@testset "SSA class-to-class references (ESS_OOP_SSA)" begin

    @testset "bit-identity across the fixtures" begin
        for (name, doc) in ["two-level chain, split producer" => _s_chain(9),
                            "fan over two observeds" => _s_fan(7, length(_S_BODIES)),
                            "merged-class producer" => _s_merged(6),
                            "no materialized observeds" => _s_nomat(16)]
            @testset "$name" begin
                (fon, u0, p, _, _), (foff, _, _, _, _), (fip, _, _, _, _) =
                    _s_build_both(doc)
                for probe in (u0, _s_seed(length(u0))), t in (0.0, 0.37)
                    a = fon(probe, p, t)
                    @test a == foff(probe, p, t)          # flag on ≡ flag off
                    @test a == _s_ip(fip, probe, p, t)    # ≡ in-place `f!`
                end
            end
        end
    end

    @testset "engagement: redirects and skipped scatters really happened" begin
        (fon, _, _, _, _), (foff, _, _, _, _), _ = _s_build_both(_s_fan(7, 4))
        s = ESMs.oop_ssa_stats(fon)
        @test s.enabled
        # Each consumer class reads g and v whole-block (2·M edges) plus its own
        # state block; every one of them is redirectable in this fixture.
        @test s.n_fast == s.n_edges > 0
        @test s.elems_fast == s.elems_edges
        # g and v are read ONLY through redirected edges, so neither producer
        # needs its scatter into `ue`.
        @test s.n_producers == 2
        @test s.n_skipped_scatters == 2
        @test !s.dynamic
        @test ESMs.oop_ssa_stats(foff).enabled == false

        # The chain: g, h-interior and h-boundary are all producers, every edge
        # (including the two overlapping windows of g and the two-producer `h`
        # read) redirects, and every fill scatter into `ue` is dead.
        (con, _, _, _, _), _, _ = _s_build_both(_s_chain(9))
        c = ESMs.oop_ssa_stats(con)
        @test c.enabled && c.n_fast == c.n_edges > 0
        @test c.n_producers == 3
        @test c.n_skipped_scatters == 3

        # The merged-class shape: if the class merge folded g1/g2 into one
        # producer, the consumer's two member reads are slices at different
        # offsets of ONE producer value and that producer's scatter is dead.
        (mon, _, _, _, _), _, _ = _s_build_both(_s_merged(6))
        m = ESMs.oop_ssa_stats(mon)
        @test m.enabled && m.n_fast == m.n_edges > 0
        @test m.n_skipped_scatters == m.n_producers
    end

    @testset "ForwardDiff sees identical derivatives" begin
        doc = _s_chain(9)
        (fon, u0, p, _, _), (foff, _, _, _, _), _ = _s_build_both(doc)
        u = _s_seed(length(u0))
        Jon = ForwardDiff.jacobian(uu -> fon(uu, p, 0.2), u)
        Joff = ForwardDiff.jacobian(uu -> foff(uu, p, 0.2), u)
        @test Jon == Joff
    end
end

# ---------------------------------------------------------------------------
# The three arms added after the spike (`SSA_SPIKE.md` "What blocks the rest"):
# ghost-masked table gathers (#1), template sub-kernel descriptor tables (#2),
# and tier 2b — the single-producer VALUE gather that fragmented mappings (#5)
# take instead of the flat-buffer fallback. Each has a bisect knob
# (`ESS_OOP_SSA_GHOST` / `_SUB` / `_PGATHER`, all default on), so every
# engagement assertion below is paired with a NEGATIVE CONTROL: the same build
# with that one arm declined must show the coverage gone.
# ---------------------------------------------------------------------------

# One producer occupying slots 5:8 at level 1, the state at slots 1:4 (level 0).
const _SX_PID = Int32[1, 1, 1, 1, 2, 2, 2, 2]
const _SX_POS = Int32[1, 2, 3, 4, 1, 2, 3, 4]
const _SX_LVL = Int[0, 1]
const _SX_LEN = Int[4, 4]
_sx_owners(g, m = Bool[]; lvl = 2, pid = _SX_PID, pos = _SX_POS) =
    ESMs._ssa_lane_owners(g, m, pid, pos, _SX_LVL, _SX_LEN, lvl)

@testset "SSA reference forms (lane owners + tier choice)" begin

    @testset "run decomposition and the level/ownership refusals" begin
        o = _sx_owners([5, 6, 7, 8])
        @test o !== nothing
        r = ESMs._ssa_pack_ref(o[1], o[2], true)
        @test r.pid == 0 && r.segs == [ESMs._OopSSASeg(2, 1, 4)]
        # a producer that does NOT strictly precede the consumer is refused
        @test _sx_owners([5, 6, 7, 8]; lvl = 1) === nothing
        # so is a slot nothing owns (a later writer disowned it)
        dis = copy(_SX_PID); dis[6] = 0
        @test _sx_owners([5, 6, 7, 8]; pid = dis) === nothing
        # out-of-range slots are refused rather than read
        @test _sx_owners([5, 6, 7, 99]) === nothing
    end

    @testset "ghost mask: a wildcard lane takes whatever continues the run" begin
        # A MIDDLE ghost (its safe-index gather read slot 1) is filled from its
        # left neighbour and the whole descriptor collapses to ONE slice.
        o = _sx_owners([5, 1, 7, 8], Bool[false, true, false, false])
        @test o !== nothing
        @test o[1] == [2, 2, 2, 2] && o[2] == [1, 2, 3, 4]
        @test ESMs._ssa_pack_ref(o[1], o[2], true).segs == [ESMs._OopSSASeg(2, 1, 4)]
        # A LEADING ghost cannot back-extend past position 1, so it takes the
        # placeholder segment (the state's slot 1) and the rest is one slice.
        o = _sx_owners([1, 5, 6, 7], Bool[true, false, false, false])
        @test o !== nothing
        @test o[1] == [1, 2, 2, 2] && o[2] == [1, 1, 2, 3]
        @test ESMs._ssa_pack_ref(o[1], o[2], true).segs ==
              [ESMs._OopSSASeg(1, 1, 1), ESMs._OopSSASeg(2, 1, 3)]
        # A leading ghost that CAN back-extend does, and the run stays single.
        o = _sx_owners([1, 6, 7, 8], Bool[true, false, false, false])
        @test o[1] == [2, 2, 2, 2] && o[2] == [1, 2, 3, 4]
        # Every invented position stays inside its producer's value, whichever
        # lanes the mask covers.
        raw = [5, 6, 7, 8]
        for bits in 1:14                      # every mask but none-set / all-set
            msk = Bool[(bits >> (l - 1)) & 1 == 1 for l in 1:4]
            o = _sx_owners(Int[msk[l] ? 1 : raw[l] for l in 1:4], msk)
            @test o !== nothing
            for l in 1:4
                @test 1 <= o[2][l] <= _SX_LEN[o[1][l]]
            end
        end
        # An ALL-ghost descriptor is declined (it is a constant zero vector).
        @test _sx_owners([1, 1, 1, 1], Bool[true, true, true, true]) === nothing
    end

    @testset "tier 2b: a fragmented SINGLE-producer mapping gathers the value" begin
        pid = fill(Int32(2), 40)
        pos = Int32.(1:40)
        lvl = Int[0, 1]
        len = Int[40, 40]
        g = collect(40:-1:1)                      # reversed ⇒ 40 runs of length 1
        o = ESMs._ssa_lane_owners(g, Bool[], pid, pos, lvl, len, 2)
        @test o !== nothing
        r = ESMs._ssa_pack_ref(o[1], o[2], true)
        @test r.pid == 2 && r.pos == g && isempty(r.segs)
        # NEGATIVE CONTROL: with tier 2b declined the mapping is too fragmented
        # for slices and falls back to the flat buffer.
        @test ESMs._ssa_pack_ref(o[1], o[2], false) === ESMs._OOP_SSA_NOREF
        # A fragmented MULTI-producer mapping has no one-op form either way.
        pid2 = Int32[i <= 20 ? 2 : 3 for i in 1:40]
        pos2 = Int32[i <= 20 ? i : i - 20 for i in 1:40]
        o2 = ESMs._ssa_lane_owners(g, Bool[], pid2, pos2, Int[0, 1, 1], Int[40, 20, 20], 2)
        @test o2 !== nothing
        @test ESMs._ssa_pack_ref(o2[1], o2[2], true) === ESMs._OOP_SSA_NOREF
    end
end

# A REVERSED read of a materialized observed: `g[N+1-i]` is not `out .+ delta`,
# so the build lowers it to a per-box slot table whose lanes descend — L runs of
# length 1, past the slice worthwhileness bound. Tier 2b turns it into one
# gather of `g`'s value; without tier 2b it is the dense `ue` gather, and `g`'s
# scatter has to stay.
function _s_rev(N)
    _s_doc("SSAREV",
        Dict{String,Any}("u" => _s_state(shape = Any["n"]),
                         "g" => _s_state(shape = Any["n"]),
                         "k" => _s_param(0.25)),
        Any[Dict{String,Any}("lhs" => "g",
                "rhs" => _s_ao(_s_o("+", _s_o("*", 2.0, _s_ix("u", "i")), 1.0))),
            Dict{String,Any}("lhs" => _s_ao(_s_Dt(_s_ix("u", "i"))),
                "rhs" => _s_ao(_s_o("-", _s_o("*", "k",
                                    _s_ix("g", _s_o("-", Float64(N + 1), "i"))),
                                    _s_ix("u", "i"))))],
        N)
end

_s_build_env(doc, env...) = withenv("ESS_OOP_SSA" => "1", env...) do
    ESMs.build_evaluator(doc; form = :oop)
end

@testset "tier 2b end to end (reversed observed read)" begin
    N = 24
    doc = _s_rev(N)
    (fon, u0, p, _, _) = _s_build_env(doc)
    (fno, _, _, _, _) = _s_build_env(doc, "ESS_OOP_SSA_PGATHER" => "0")
    foff, = withenv("ESS_OOP_SSA" => nothing) do
        ESMs.build_evaluator(doc; form = :oop)
    end
    fip, = ESMs.build_evaluator(doc)
    for probe in (u0, _s_seed(length(u0))), t in (0.0, 0.41)
        a = fon(probe, p, t)
        @test a == foff(probe, p, t)
        @test a == fno(probe, p, t)
        @test a == _s_ip(fip, probe, p, t)
    end
    son = ESMs.oop_ssa_stats(fon)
    sno = ESMs.oop_ssa_stats(fno)
    # ENGAGEMENT + NEGATIVE CONTROL: the reversed edge redirects only with the
    # arm on, and it is the last reader keeping `g`'s scatter alive.
    @test son.n_fast > sno.n_fast
    @test son.n_skipped_scatters > sno.n_skipped_scatters
    @test son.n_producers == 1 && son.n_skipped_scatters == 1
    Jon = ForwardDiff.jacobian(uu -> fon(uu, p, 0.2), _s_seed(N))
    Joff = ForwardDiff.jacobian(uu -> foff(uu, p, 0.2), _s_seed(N))
    @test Jon == Joff
end

# ---------------------------------------------------------------------------
# Template SUB-KERNEL descriptor tables (`SSA_SPIKE.md` blocker #2). A sub is
# evaluated at the PARENT's lanes and `_build_oop_desc_vectors` resolves its
# descriptors against that same enumeration, so its gathers are ordinary slot
# vectors into `ue` — but they index `S.acc`, not `K.acc`, which is why the
# spike's per-kernel table could not carry them and every one of them held its
# producers' scatters alive. Measured on the ReSEACT transport RHS at 6x6x8,
# these are 885 of the 985 candidate descriptors and 1.07 M of the 1.11 M read
# elements, so they are the read surface that matters.
#
# The fixture is the duo-rule shape from codegen_subcall_fn_test.jl — a
# makearray whose region value applies an aggregate-bodied template whose expr
# holds more applies as arithmetic OPERANDS — because that is what mints
# `_NK_SUBCALL`s at all.
function _s_sub_fixture(dir, N)
    ix(f, i, j) = Dict("op" => "index", "args" => Any[f, i, j])
    ap(a, b) = Dict("op" => "apply_expression_template", "args" => Any[],
                    "name" => "leaf", "bindings" => Dict("a" => a, "b" => b))
    leaf_terms = Any[]
    for k in 1:12
        push!(leaf_terms, Dict("op" => "*", "args" => Any[0.5 + 0.01k,
            Dict("op" => "+", "args" => Any[
                Dict("op" => "*", "args" => Any["a", "a"]),
                Dict("op" => "*", "args" => Any["b", 0.3 + 0.02k])])]))
    end
    leaf = Dict("params" => Any["a", "b"],
                "body" => Dict("op" => "+", "args" => leaf_terms))
    inner_expr = Dict("op" => "+", "args" => Any[
        Dict("op" => "*", "args" => Any[0.25, ap(ix("f", "i", "j"), ix("f", "i", "j"))]),
        ap(ix("f", "i", "j"), ix("f", "j", "i")),
        Dict("op" => "*", "args" => Any[ap(ix("f", "i", "j"), ix("f", "i", "j")), 0.125])])
    inner = Dict("params" => Any["f"],
                 "body" => Dict("op" => "aggregate", "output_idx" => Any["i", "j"],
                                "args" => Any["f"],
                                "ranges" => Dict("i" => Dict("from" => "x"),
                                                 "j" => Dict("from" => "y")),
                                "expr" => inner_expr))
    rhs = Dict("op" => "makearray", "args" => Any[],
               "regions" => Any[Any[Any[1, "N"], Any[1, "N"]]],
               "values" => Any[Dict("op" => "apply_expression_template",
                                    "args" => Any[], "name" => "inner",
                                    "bindings" => Dict("f" => "u"))])
    doc = Dict("esm" => "1.0.0",
        "metadata" => Dict("name" => "ssa_subcall_fixture",
                           "description" => "generated by tree_walk_oop_ssa_test.jl: sub-kernel redirect"),
        "metaparameters" => Dict("N" => Dict("type" => "integer", "default" => N)),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => "N"),
                             "y" => Dict("kind" => "interval", "size" => "N")),
        "models" => Dict("M" => Dict(
            "expression_templates" => Dict("leaf" => leaf, "inner" => inner),
            "variables" => Dict("u" => Dict("type" => "unknown", "units" => "1",
                                            "shape" => Any["x", "y"], "default" => 1.0)),
            "equations" => Any[Dict(
                "lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
                "rhs" => rhs)])))
    path = joinpath(dir, "ssa_subcall_fixture.esm")
    open(path, "w") do io
        JSON3.write(io, doc)
    end
    return path
end

@testset "sub-kernel descriptor tables redirect (blocker #2)" begin
    mktempdir() do dir
        F = _s_sub_fixture(dir, 5)
        build(env...) = withenv(env...) do
            ESMs.build_evaluator(ESMs.flatten(ESMs.load_path(F)); form = :oop)
        end
        # The nested-boundary tier is what mints the `_NK_SUBCALL`s.
        nested = "ESS_NESTED_TEMPLATE_BOUNDARY" => "1"
        (fon, u0, p, _, _) = build(nested, "ESS_OOP_SSA" => "1")
        (fno, _, _, _, _) = build(nested, "ESS_OOP_SSA" => "1",
                                  "ESS_OOP_SSA_SUB" => "0")
        (foff, _, _, _, _) = build(nested, "ESS_OOP_SSA" => nothing)
        fip, ui, pi_, _, _ = withenv(nested) do
            ESMs.build_evaluator(ESMs.flatten(ESMs.load_path(F)))
        end

        son = ESMs.oop_ssa_stats(fon)
        sno = ESMs.oop_ssa_stats(fno)
        # ENGAGEMENT: the sub tables are where this fixture's reads live at all,
        # and every one of them redirects.
        @test son.n_sub_edges > 0
        @test son.n_sub_fast == son.n_sub_edges
        # NEGATIVE CONTROL: with the arm declined not one of them redirects.
        @test sno.n_sub_edges == son.n_sub_edges
        @test sno.n_sub_fast == 0

        # BIT-IDENTITY across all three builds and the in-place `f!`.
        for probe in (u0, _s_seed(length(u0))), t in (0.0, 0.63)
            a = fon(probe, p, t)
            @test a == foff(probe, p, t)
            @test a == fno(probe, p, t)
            @test a == _s_ip(fip, probe, pi_, t)
        end
        u = _s_seed(length(u0))
        @test ForwardDiff.jacobian(uu -> fon(uu, p, 0.3), u) ==
              ForwardDiff.jacobian(uu -> foff(uu, p, 0.3), u)
    end
end

# ---------------------------------------------------------------------------
# The SCATTER-SKIP GATE (ess-oop-ssa-gate).
#
# Static skippability says a producer's scatter into `ue` is REDUNDANT. It does
# not say dropping it is CHEAPER — a `dynamic_update_slice` aliases its operand
# in the forward, so keeping it can be nearly free while dropping it makes the
# producer's value a buffer of its own. The gate prices that, and these tests
# pin the two things a price may never change:
#
#   * VALUES. Every gate setting is bit-identical to flag-off and to
#     `:inplace`, and ForwardDiff agrees exactly. Declining a skip emits a
#     write nothing reads — the flag-off behaviour — so this is the same
#     contract the spike has, asserted across the whole knob group.
#   * THE READ GRAPH. The gate decides only whether a scatter is EMITTED; the
#     redirect tables and the static `n_skippable_scatters` are the same in
#     every arm. A gate that also suppressed redirects would show up here.
#
# Each knob has a negative control, so the arm can be bisected: the master
# `ESS_OOP_SSA_SKIP=0`, the ungated `ESS_OOP_SSA_SKIP_GATE=0` (what #283
# shipped), the two thresholds, and the per-producer `ESS_OOP_SSA_SKIP_PIDS`
# bisect the discriminator was found with.
_s_build_gate(doc, env...) = withenv("ESS_OOP_SSA" => "1", env...) do
    ESMs.build_evaluator(doc; form = :oop)
end

@testset "scatter-skip gate (ESS_OOP_SSA_SKIP*)" begin
    doc = _s_fan(7, 4)
    (fdef, u0, p, _, _) = _s_build_gate(doc)
    (fung, _, _, _, _) = _s_build_gate(doc, "ESS_OOP_SSA_SKIP_GATE" => "0")
    (fno,  _, _, _, _) = _s_build_gate(doc, "ESS_OOP_SSA_SKIP" => "0")
    (flen, _, _, _, _) = _s_build_gate(doc, "ESS_OOP_SSA_SKIP_MAXLEN" => "1")
    (frat, _, _, _, _) = _s_build_gate(doc, "ESS_OOP_SSA_SKIP_MINRATIO" => "1e9")
    (fpid, _, _, _, _) = _s_build_gate(doc, "ESS_OOP_SSA_SKIP_PIDS" => "!2")
    (funl, _, _, _, _) = _s_build_gate(doc, "ESS_OOP_SSA_SKIP_MAXLEN" => "-1",
                                       "ESS_OOP_SSA_SKIP_MINRATIO" => "0")
    (foff, _, _, _, _) = withenv("ESS_OOP_SSA" => nothing) do
        ESMs.build_evaluator(doc; form = :oop)
    end
    (fip, _, _, _, _) = ESMs.build_evaluator(doc)
    ARMS = (fdef, fung, fno, flen, frat, fpid, funl)
    st(f) = ESMs.oop_ssa_stats(f)

    @testset "the gate moves ONLY the skip verdict" begin
        base = st(fung)
        @test base.n_skippable_scatters == base.n_skipped_scatters == 2
        for f in ARMS
            s = st(f)
            @test s.n_skippable_scatters == 2      # a read-graph fact
            @test s.n_fast == base.n_fast > 0      # redirects untouched
            @test s.elems_fast == base.elems_fast
            @test s.n_sub_fast == base.n_sub_fast
            @test s.n_skipped_scatters + s.n_gate_declined == 2
            @test s.n_skipped_scatters <= s.n_skippable_scatters
        end
    end

    @testset "each knob declines what it says it declines" begin
        @test st(fung).n_skipped_scatters == 2      # #283, ungated
        @test st(funl).n_skipped_scatters == 2      # both bounds released
        @test st(fno).n_skipped_scatters == 0       # master off
        @test st(fno).n_gate_declined == 2
        @test st(flen).n_skipped_scatters == 0      # every producer is 7 > 1
        @test st(frat).n_skipped_scatters == 0      # no producer reads 7e9 elems
        @test st(fpid).n_skipped_scatters == 1      # producer 2 excluded by hand
        # … and it is producer 2's scatter, not the other one, that survived
        @test [q.pid for q in ESMs.oop_ssa_producers(fpid) if !q.skip] == [2]
        @test [q.pid for q in ESMs.oop_ssa_producers(fpid) if q.skip] == [3]
        # the default ships a gate that is not degenerate on these fixtures
        @test st(fdef).n_skipped_scatters == 2
    end

    @testset "values and derivatives are identical in every arm" begin
        for probe in (u0, _s_seed(length(u0))), t in (0.0, 0.37)
            a = foff(probe, p, t)
            @test a == _s_ip(fip, probe, p, t)
            for f in ARMS
                @test f(probe, p, t) == a
            end
        end
        u = _s_seed(length(u0))
        J = ForwardDiff.jacobian(uu -> foff(uu, p, 0.2), u)
        for f in ARMS
            @test ForwardDiff.jacobian(uu -> f(uu, p, 0.2), u) == J
        end
    end
end

@testset "oop_ssa_producers: the gate's evidence table" begin
    # The table is what the discriminator was chosen from, so its columns are
    # asserted against shapes whose read structure is known by construction.
    @testset "fan-out: two producers, every consumer reads both whole" begin
        (f, _, _, _, _) = _s_build_gate(_s_fan(7, 4))
        pr = ESMs.oop_ssa_producers(f)
        @test length(pr) == 2
        @test [q.pid for q in pr] == [2, 3]
        @test all(q -> q.len == 7, pr)
        # each of the 4 consumer classes reads g and v as a WHOLE block, so
        # every read of every producer is a tier-1 reference
        @test all(q -> q.nread == 4, pr)
        @test all(q -> q.nwhole == 4, pr)
        @test all(q -> q.elread == 28, pr)
        @test all(q -> q.skippable && q.skip, pr)
        @test all(q -> isempty(q.why), pr)
        @test all(q -> q.level == 1, pr)
    end

    @testset "merged class: one producer, member reads are slices" begin
        (f, _, _, _, _) = _s_build_gate(_s_merged(6))
        pr = ESMs.oop_ssa_producers(f)
        @test length(pr) == ESMs.oop_ssa_stats(f).n_producers
        # g1/g2 merge into ONE 12-slot producer read by two 6-element slices,
        # so nothing takes the whole value and the read volume equals it
        q = only(filter(q -> q.len == 12, pr))
        @test q.nwhole == 0
        @test q.nread == 2
        @test q.elread == 12
        @test q.skippable && q.skip
    end

    @testset "empty with the flag off" begin
        (f, _, _, _, _) = withenv("ESS_OOP_SSA" => nothing) do
            ESMs.build_evaluator(_s_fan(7, 4); form = :oop)
        end
        @test isempty(ESMs.oop_ssa_producers(f))
        @test ESMs.oop_ssa_stats(f).enabled == false
    end
end

# ---------------------------------------------------------------------------
# `ESS_OOP_SSA_SKIP_WHOLE`, the measured discriminator: the skip is
# ALL-OR-NOTHING per build. With even one producer still scattering, `ue` is
# assembled anyway, so a partial skip pays for the flat buffer AND for the
# skipped producers' own values; only a build where every producer can go
# actually retires the buffer.
#
# The fixture needs a build with TWO producers where one can be blocked ON
# DEMAND, which `ESS_OOP_SSA_PGATHER=0` does: `v` is read REVERSED (L runs of
# length 1, past the slice bound), so without tier 2b that read stays on the
# dense `ue` gather and holds `v`'s scatter alive, while `g`'s whole-block read
# redirects either way.
function _s_mixed(N)
    _s_doc("SSAMIX",
        Dict{String,Any}("u" => _s_state(shape = Any["n"]),
                         "g" => _s_state(shape = Any["n"]),
                         "v" => _s_state(shape = Any["n"]),
                         "k" => _s_param(0.25)),
        Any[Dict{String,Any}("lhs" => "g",
                "rhs" => _s_ao(_s_o("+", _s_o("*", 2.0, _s_ix("u", "i")), 1.0))),
            Dict{String,Any}("lhs" => "v",
                "rhs" => _s_ao(_s_o("*", _s_ix("u", "i"), _s_ix("u", "i")))),
            Dict{String,Any}("lhs" => _s_ao(_s_Dt(_s_ix("u", "i"))),
                "rhs" => _s_ao(_s_o("-",
                    _s_o("*", "k", _s_o("+", _s_ix("g", "i"),
                         _s_ix("v", _s_o("-", Float64(N + 1), "i")))),
                    _s_ix("u", "i"))))],
        N)
end

@testset "the skip is all-or-nothing (ESS_OOP_SSA_SKIP_WHOLE)" begin
    N = 24
    doc = _s_mixed(N)
    # both producers redirectable ⇒ the whole gate is satisfied either way
    (fall, u0, p, _, _) = _s_build_gate(doc)
    (fallp, _, _, _, _) = _s_build_gate(doc, "ESS_OOP_SSA_SKIP_WHOLE" => "0")
    # tier 2b off ⇒ `v` keeps its scatter, so the build is only PARTIALLY
    # skippable: the whole gate then declines every skip, and `=0` restores the
    # partial one (#283's behaviour)
    (fpart, _, _, _, _) = _s_build_gate(doc, "ESS_OOP_SSA_PGATHER" => "0")
    (fpartp, _, _, _, _) = _s_build_gate(doc, "ESS_OOP_SSA_PGATHER" => "0",
                                         "ESS_OOP_SSA_SKIP_WHOLE" => "0")
    (foff, _, _, _, _) = withenv("ESS_OOP_SSA" => nothing) do
        ESMs.build_evaluator(doc; form = :oop)
    end
    (fip, _, _, _, _) = ESMs.build_evaluator(doc)
    st(f) = ESMs.oop_ssa_stats(f)

    @test st(fall).n_producers == 2
    @test st(fall).n_skippable_scatters == 2
    @test st(fall).n_skipped_scatters == 2          # nothing to gate
    @test st(fallp).n_skipped_scatters == 2
    # the negative control: one producer blocked ⇒
    @test st(fpart).n_skippable_scatters == 1       # … static verdict unmoved
    @test st(fpart).n_skipped_scatters == 0         # … and the gate declines it
    @test st(fpart).n_gate_declined == 1
    @test st(fpartp).n_skipped_scatters == 1        # … which `=0` undoes
    @test [q.pid for q in ESMs.oop_ssa_producers(fpartp) if q.skip] ==
          [q.pid for q in ESMs.oop_ssa_producers(fpart) if q.skippable]
    # the gate is a cost decision, so it may not move a number
    for probe in (u0, _s_seed(length(u0))), t in (0.0, 0.41)
        a = foff(probe, p, t)
        @test a == _s_ip(fip, probe, p, t)
        for f in (fall, fallp, fpart, fpartp)
            @test f(probe, p, t) == a
        end
    end
    J = ForwardDiff.jacobian(uu -> foff(uu, p, 0.2), _s_seed(N))
    for f in (fall, fallp, fpart, fpartp)
        @test ForwardDiff.jacobian(uu -> f(uu, p, 0.2), _s_seed(N)) == J
    end
end
