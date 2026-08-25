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
