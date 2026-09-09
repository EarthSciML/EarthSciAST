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
# SCALAR read surfaces (`SSA_SPIKE.md` blocker #4): the scalar `_Node` walker
# (`_oop_eval` — a `_NK_STATE` pin, a `_NK_STATE_GATHER` slot table) and its
# lane-batched twin (`_oop_eval_batch`, ess-oop-batch). Neither reads through a
# consumer DESCRIPTOR, so neither could use the per-kernel redirect table; both
# went through the flat `ue` and held their producers' scatters alive wherever
# they landed. They redirect through the same slot→(producer, position) map the
# descriptor arm resolves, published per surface as a consumer LEVEL
# (`_OopSSAOwn` + `_OopSSASCtx`).
#
# THE ARM IS DEFAULT OFF — it MEASURED SLOWER (4.3% on the CONUS 4x5 transport
# reverse; see the knob's note in oop.jl) — so `ESS_OOP_SSA_SCALAR=1` opts in
# and every build below spells its intent. Three `:oop` builds are compared
# throughout: the arm opted IN, the SHIPPED DEFAULT (`ESS_OOP_SSA=1` alone,
# which must be indistinguishable from the explicit `=0` control — that is the
# assertion that the default path is untouched), and the feature off entirely.
#
# Measured on the ReSEACT transport RHS at 6x6x8 (the campaign's steering
# instrument, `oop_ssa_stats().blockers_only`): these reads were the SOLE
# blocker on 2 of the 4 surviving producers, both of them level-3/4 per-column
# fills reading a lower level's kernel output through a `_NK_STATE_GATHER`.
# ---------------------------------------------------------------------------

# One producer owning slots 5:8 at level 1 (`_SX_*` above), a second at 9:12.
const _SC_PID = Int32[1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3]
const _SC_POS = Int32[1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4]
const _SC_OWN = ESMs._OopSSAOwn(_SC_PID, _SC_POS, Int[0, 1, 2])

@testset "scalar surface map (the redirect predicate)" begin
    own = _SC_OWN
    # a producer that strictly precedes the surface redirects; one at the same
    # level or later does not (a fill level's own scalars run BEFORE its
    # kernels, so `cons == producer level` must refuse)
    @test ESMs._ssa_owner_pid(own, 5, 2) == 2
    @test ESMs._ssa_owner_pid(own, 5, 1) == 0
    @test ESMs._ssa_owner_pid(own, 9, 2) == 0
    @test ESMs._ssa_owner_pid(own, 9, 3) == 3
    # the raw state prefix is producer 1 at level 0, so it redirects everywhere
    @test ESMs._ssa_owner_pid(own, 1, 1) == 1
    # a disowned slot (a later writer took it, or a level scalar / scan fold
    # rewrites it) and an out-of-range slot are both refused, never read
    dis = ESMs._OopSSAOwn(Int32[1, 0, 1], Int32[1, 0, 3], Int[0])
    @test ESMs._ssa_owner_pid(dis, 2, 1) == 0
    @test ESMs._ssa_owner_pid(own, 99, 9) == 0
    @test ESMs._ssa_owner_pid(own, 0, 9) == 0
    # `cons == 0` is the OFF surface: nothing redirects, whatever the map says
    @test ESMs._ssa_owner_pid(own, 5, 0) == 0
    # …and the OFF singleton answers 0 for every slot
    @test ESMs._ssa_owner_pid(ESMs._OOP_SSA_OWN_OFF, 5, 9) == 0
    # the (pid, pos) form agrees with it and carries the producer-local position
    sc = ESMs._OopSSASCtx(own, 2, Any[])
    @test ESMs._oop_ssa_owner(sc, 7) == (2, 3)
    @test ESMs._oop_ssa_owner(ESMs._OOP_SSA_SCTX_OFF, 7) == (0, 0)
end

@testset "scalar surface: lane vectors take ONE producer or nothing" begin
    own = _SC_OWN
    # BUILD-time verdict and RUN-time resolution are the same function of the
    # same data — asserted here side by side, because a disagreement is exactly
    # what would let a scatter be skipped under a live reader.
    lanes(slots, mask = Bool[]; cons = 2) = begin
        pos = Vector{Int}(undef, length(slots))
        pid = ESMs._oop_ssa_lane_pid!(pos, ESMs._OopSSASCtx(own, cons, Any[]),
                                      slots, mask)
        (pid, pid == 0 ? Int[] : pos)
    end
    # one producer, in any order: redirected at producer-local positions
    @test lanes([5, 6, 7, 8]) == (2, [1, 2, 3, 4])
    @test lanes([8, 5, 8]) == (2, [4, 1, 4])
    @test ESMs._ssa_lane_common_pid([8, 5, 8], own, 2) == 2
    # TWO producers in one lane vector: no single-op form, so the `ue` gather
    # stays (and the build marks both blocks residual)
    @test lanes([5, 9]; cons = 3)[1] == 0
    @test ESMs._ssa_lane_common_pid([5, 9], own, 3) == 0
    # an unowned or not-yet-written lane refuses the whole vector
    @test lanes([5, 6, 7, 8]; cons = 1)[1] == 0
    @test ESMs._ssa_lane_common_pid([5, 6, 7, 8], own, 1) == 0
    # GHOST lanes are wildcards (the caller's select overwrites them with 0),
    # so they take position 1 instead of breaking the single-producer form
    @test lanes([1, 6, 7, 1], Bool[true, false, false, true]) == (2, [1, 2, 3, 1])
    # an ALL-ghost vector has no producer to name and declines
    @test lanes([1, 1], Bool[true, true])[1] == 0
    # the OFF surface never redirects
    @test ESMs._oop_ssa_lane_pid!(zeros(Int, 4), ESMs._OOP_SSA_SCTX_OFF,
                                  [5, 6, 7, 8], Bool[]) == 0
end

# `g` is a materialized array observed read BOTH by an array kernel (which the
# descriptor arm already redirects) and by `M` SCALAR state equations. With
# M == 1 that read is a leftover single on `_oop_eval`; with M > 1 the congruent
# entries form ONE lane-batched group and the read becomes a `_NK_STATE` slot
# VECTOR on `_oop_eval_batch` — the two scalar surfaces, same fixture.
function _s_scalread(N, M)
    vars = Dict{String,Any}("u" => _s_state(shape = Any["n"]),
                            "g" => _s_state(shape = Any["n"]),
                            "k" => _s_param(0.25))
    eqs = Any[
        Dict{String,Any}("lhs" => "g",
            "rhs" => _s_ao(_s_o("+", _s_o("*", 2.0, _s_ix("u", "i")), 1.0))),
        Dict{String,Any}("lhs" => _s_ao(_s_Dt(_s_ix("u", "i"))),
            "rhs" => _s_ao(_s_o("-", _s_o("*", "k", _s_ix("g", "i")),
                                _s_ix("u", "i")))),
    ]
    for m in 1:M
        nm = "w$m"
        vars[nm] = _s_state()
        push!(eqs, Dict{String,Any}("lhs" => _s_Dt(nm),
            "rhs" => _s_o("-", _s_ix("g", Float64(m)), nm)))
    end
    _s_doc("SSASCAL", vars, eqs, N)
end

@testset "scalar-walker reads redirect (blocker #4)" begin
    @testset "$(M == 1 ? "leftover single" : "lane-batched group") (M = $M)" for M in (1, 4)
        doc = _s_scalread(9, M)
        (fon, u0, p, _, _) = _s_build_env(doc, "ESS_OOP_SSA_SCALAR" => "1")
        (fno, _, _, _, _) = _s_build_env(doc, "ESS_OOP_SSA_SCALAR" => "0")
        (fdef, _, _, _, _) = _s_build_env(doc)     # the SHIPPED default
        foff, = withenv("ESS_OOP_SSA" => nothing) do
            ESMs.build_evaluator(doc; form = :oop)
        end
        fip, = ESMs.build_evaluator(doc)

        # BIT-IDENTITY across all four `:oop` builds and the in-place `f!`.
        for probe in (u0, _s_seed(length(u0))), t in (0.0, 0.53)
            a = fon(probe, p, t)
            @test a == foff(probe, p, t)
            @test a == fno(probe, p, t)
            @test a == fdef(probe, p, t)
            @test a == _s_ip(fip, probe, p, t)
        end

        son = ESMs.oop_ssa_stats(fon)
        sno = ESMs.oop_ssa_stats(fno)
        # The surface really is the one under test: with M > 1 the entries
        # batched (one lane vector), with M == 1 they did not.
        rhs = getfield(fon, :rhs)
        rb = getfield(rhs, :rhs_batches)
        @test (M > 1) == !isempty(rb.groups)
        # ENGAGEMENT: every scalar read site redirected, at full element volume.
        @test son.n_scalar_edges > 0
        @test son.n_scalar_fast == son.n_scalar_edges
        @test son.elems_scalar_fast == son.elems_scalar_edges > 0
        # …and it was the LAST reader keeping `g`'s scatter into `ue` alive.
        @test son.n_producers == 1
        @test son.n_skipped_scatters == 1
        @test son.blockers_only.scalar == 0

        # NEGATIVE CONTROL: with the arm declined the sites are still counted
        # (the tally is the steering instrument), none of them redirects, and
        # `g` scatters again — blamed on this surface by name.
        @test sno.n_scalar_edges == son.n_scalar_edges
        @test sno.n_scalar_fast == 0
        @test sno.elems_scalar_fast == 0
        @test sno.n_skipped_scatters == 0
        @test sno.blockers_only.scalar == 1
        # SHIPPED DEFAULT: `ESS_OOP_SSA=1` alone must be the control, column for
        # column — the arm is opt-in, so merging it may not move any build that
        # does not ask for it.
        @test ESMs.oop_ssa_stats(fdef) == sno
        # the DESCRIPTOR arm is untouched either way (this is one arm, alone)
        @test sno.n_fast == son.n_fast
        @test sno.n_edges == son.n_edges

        # AD: a redirect changes where an operand comes from, never the value.
        u = _s_seed(length(u0))
        @test ForwardDiff.jacobian(uu -> fon(uu, p, 0.35), u) ==
              ForwardDiff.jacobian(uu -> foff(uu, p, 0.35), u)
    end
end

# The surface that actually held ReSEACT's two producers: a per-column
# materialized fill whose body is a runtime CONTRACTION LOOP, so its state read
# is a `_NK_STATE_GATHER` at a loop-counter subscript — a slot resolved per
# iteration out of a static table. Here `q` is itself a materialized array
# observed (a level-1 kernel producer) and `S[i] = Σ_k q[i,k]` fragments into
# per-column scalars at level 2, which batch into ONE lane group: exactly the
# ReSEACT transport shape (level-3/4 per-column fills over a level-1/2 kernel's
# output). Built through the typed AST because a runtime contraction loop needs
# an `aggregate` with an inner range, which the JSON helpers above do not spell.
include("testutils.jl")

@testset "state-gather fill levels redirect (blocker #4, the ReSEACT shape)" begin
    N, M = 6, 12                       # M ≥ the contraction-loop floor
    isets = Dict("x" => ESMs.IndexSet("interval"; size = N),
                 "y" => ESMs.IndexSet("interval"; size = M))
    vars = Dict("u" => ESMs.ModelVariable(ESMs.UnknownVariable; shape = ["x"]),
                "q" => ESMs.ModelVariable(ESMs.UnknownVariable; shape = ["x", "y"]),
                "S" => ESMs.ModelVariable(ESMs.UnknownVariable; shape = ["x"]))
    rng_i = Dict{String,Any}("i" => ESMs.IndexSetRef("x"))
    rng_ik = Dict{String,Any}("i" => ESMs.IndexSetRef("x"),
                              "k" => ESMs.IndexSetRef("y"))
    rng_ab = Dict{String,Any}("a" => ESMs.IndexSetRef("x"),
                              "b" => ESMs.IndexSetRef("y"))
    eqs = [
        ESMs.Equation(_v("q"), _op("aggregate"; output_idx = Any["a", "b"],
            ranges = rng_ab,
            expr_body = _op("+", _op("*", _n(2.0), _idx("u", _v("a"))), _n(1.0)))),
        ESMs.Equation(_v("S"), _op("aggregate"; output_idx = Any["i"],
            ranges = rng_ik, semiring = "sum_product",
            expr_body = _idx("q", _v("i"), _v("k")))),
        ESMs.Equation(_op("aggregate"; output_idx = Any["i"], ranges = rng_i,
                          expr_body = _Didx("u", _v("i"))),
                      _op("aggregate"; output_idx = Any["i"], ranges = rng_i,
                          expr_body = _op("-", _idx("S", _v("i")),
                                          _idx("u", _v("i"))))),
    ]
    model = ESMs.Model(vars, eqs)
    ics = Dict{String,Any}("u[$j]" => 0.3 * j for j in 1:N)
    bld(env = (); form = :oop) = withenv("ESS_CONTRACTION_LOOP" => "1",
            "ESS_CONTRACTION_LOOP_MIN" => "8", env...) do
        ESMs.build_evaluator(model; index_sets = isets, initial_conditions = ics,
                             form = form)
    end
    fon, u0, p, _, _ = bld(("ESS_OOP_SSA" => "1", "ESS_OOP_SSA_SCALAR" => "1"))
    fno, = bld(("ESS_OOP_SSA" => "1", "ESS_OOP_SSA_SCALAR" => "0"))
    fdef, = bld(("ESS_OOP_SSA" => "1",))            # the SHIPPED default
    foff, = bld(("ESS_OOP_SSA" => nothing,))
    fip, ui, pi_, = bld((); form = :inplace)

    # The fixture really is the shape under test: `q` is a level-1 kernel
    # producer and `S`'s fill fragmented into per-column scalars that batched.
    rhs = getfield(fon, :rhs)
    ml = getfield(rhs, :mat_levels)
    @test length(ml) == 2
    @test length(ml[1][2]) == 1 && isempty(ml[1][1])   # level 1: one kernel
    @test length(ml[2][1]) == N && isempty(ml[2][2])   # level 2: N scalars
    @test length(getfield(rhs, :mat_batches)[2].groups) == 1

    # BIT-IDENTITY across all four `:oop` builds and the in-place `f!`.
    for t in (0.0, 0.29)
        a = fon(u0, p, t)
        @test a == foff(u0, p, t)
        @test a == fno(u0, p, t)
        @test a == fdef(u0, p, t)
        @test a == _s_ip(fip, ui, pi_, t)
    end

    son = ESMs.oop_ssa_stats(fon)
    sno = ESMs.oop_ssa_stats(fno)
    # ENGAGEMENT: the state-gather site redirected at full element volume, and
    # it was the only reader keeping `q`'s scatter into `ue` alive.
    @test son.n_scalar_edges == sno.n_scalar_edges > 0
    @test son.n_scalar_fast == son.n_scalar_edges
    @test son.elems_scalar_fast == son.elems_scalar_edges > 0
    @test son.n_producers == 1 && son.n_skipped_scatters == 1
    @test son.blockers_only.scalar == 0
    # NEGATIVE CONTROL, and the SHIPPED DEFAULT is that control exactly.
    @test sno.n_scalar_fast == 0 && sno.elems_scalar_fast == 0
    @test sno.n_skipped_scatters == 0
    @test sno.blockers_only.scalar == 1
    @test ESMs.oop_ssa_stats(fdef) == sno

    @test ForwardDiff.jacobian(uu -> fon(uu, p, 0.17), u0) ==
          ForwardDiff.jacobian(uu -> foff(uu, p, 0.17), u0)
end
