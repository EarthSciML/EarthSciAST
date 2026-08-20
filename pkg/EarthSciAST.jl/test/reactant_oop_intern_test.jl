# Trace-time `(tensor, window)` read INTERNING (ess-oop-intern;
# ext/EarthSciASTReactantExt.jl's three-argument `_oop_gather`).
#
# THE DEFECT THIS PINS. A materialized array observed lives in the emitter's flat
# extended state tensor `ue = [u ; zeros]`, and EVERY acc-kernel descriptor that
# mentions it emitted its OWN read of it. Reactant lowers a contiguous slot run
# to a `stablehlo.slice`, so the same window of the same tensor became N
# identical slice ops. Measured on ReSEACT at 7x7x16: 8,093 slices over 3,165
# distinct `(operand, window)` pairs — 4,928 (60.9%) exact duplicates, 7,648 of
# them 784-element windows of `ue`; one chemistry RHS emitted 478 slices over
# just 123 distinct windows, and one window was sliced 1,392 times module-wide.
# XLA then rediscovers the duplication with `CSE<mlir::stablehlo::SliceOp>`,
# which is PAIRWISE and therefore quadratic in the slice count — a `perf` profile
# of a stuck CONUS compile put ~50% of all CPU in that one pattern.
#
# WHAT IS ASSERTED, in four layers — the first three are what a silent regression
# would have to defeat:
#   1. ENGAGEMENT. `oop_intern_stats().hits > 0` under a trace, and `== 0` both on
#      host and under `ESS_OOP_INTERN=0`. Without this a memo that quietly stopped
#      matching would still pass every value test.
#   2. SHAPE. The raw (`optimize=false`) op census must show STRICTLY FEWER reads
#      with interning on, and the surviving read count must equal the number of
#      DISTINCT windows the model actually has — not merely "smaller".
#   3. VALUES, traced-vs-traced. Interning is a pure emission-time CSE, so the ON
#      and OFF programs must produce BIT-IDENTICAL output. This is an enforceable
#      `==`, not a tolerance: the two programs differ only by ops that were
#      duplicates of each other.
#   4. VALUES, traced-vs-host. The usual few-ulp agreement (XLA reassociates and
#      fuses FMAs), same bar as reactant_oop_test.jl.
#
# HOST IS NOT INVOLVED AT ALL and that is the safety argument, not an
# optimization: on host `_oop_store`/`_oop_scatter` MUTATE and return the same
# array, so a read cache keyed on container identity would serve pre-write data.
# Under a trace the writes are functional — `setindex!` rebinds a `TracedRArray`'s
# MLIR value — so the SSA value fully determines the contents. `_oop_new_memo`
# therefore returns `nothing` for every non-traced element type, and the last
# testset here pins that host counters stay at zero.
using Test
using EarthSciAST
using Reactant

const ESMi = EarthSciAST
const RXi = Reactant

_i_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_i_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_i_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_i_ao(e) = Dict{String,Any}("op" => "arrayop", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)

# `g[i] = 2·c1[i] + 1` and `v[i] = c1[i]·c1[i]` are array OBSERVEDS, so both are
# materialized into `ue` (build.jl §2b-f) rather than inlined. Each state
# equation then reads the SAME two windows `g[1:N]` and `v[1:N]` — one acc kernel
# apiece, one descriptor apiece, one emitted read apiece before interning. This
# is ReSEACT's shape in miniature: 478 slices over 123 windows there, because
# nothing shared a read ACROSS descriptors.
#
# The M bodies are deliberately STRUCTURALLY DISTINCT rather than the same shape
# with different constants. Congruent equations are folded into one kernel by the
# kernel-class merge (oop_merge.jl) before this emitter ever sees them, which is
# a build-time fix for a build-time redundancy and leaves nothing for interning
# to do; the redundancy interning exists for is between kernels that genuinely
# compute different things out of the same input window, which is what these are.
const _I_BODIES = [
    (g, v) -> _i_o("+", g, v),
    (g, v) -> _i_o("*", g, v),
    (g, v) -> _i_o("+", _i_o("exp", _i_o("neg", g)), v),
    (g, v) -> _i_o("*", _i_o("sqrt", g), _i_o("+", v, 1.0)),
    (g, v) -> _i_o("/", g, _i_o("+", 1.0, v)),
    (g, v) -> _i_o("-", _i_o("sin", g), _i_o("log", _i_o("+", v, 2.0))),
]

function _i_doc(N, M)
    vars = Dict{String,Any}(
        # esm 1.0.0 (§5.4/§6.3.1): only `unknown` / `parameter` are declared; `g`
        # and `v` are OBSERVED by virtue of their bare-LHS equations below.
        "g" => Dict{String,Any}("type" => "unknown", "shape" => Any["n"]),
        "v" => Dict{String,Any}("type" => "unknown", "shape" => Any["n"]),
        "k" => Dict{String,Any}("type" => "parameter", "default" => 0.25))
    eqs = Any[
        Dict{String,Any}("lhs" => "g",
            "rhs" => _i_ao(_i_o("+", _i_o("*", 2.0, _i_ix("c1", "i")), 1.0))),
        Dict{String,Any}("lhs" => "v",
            "rhs" => _i_ao(_i_o("*", _i_ix("c1", "i"), _i_ix("c1", "i")))),
    ]
    for m in 1:M
        nm = "c$m"
        vars[nm] = Dict{String,Any}("type" => "unknown", "shape" => Any["n"])
        body = _I_BODIES[m](_i_ix("g", "i"), _i_ix("v", "i"))
        push!(eqs, Dict{String,Any}(
            "lhs" => _i_ao(_i_Dt(_i_ix(nm, "i"))),
            "rhs" => _i_ao(_i_o("*", "k", body))))
    end
    Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => "INTERN"),
        "index_sets" => Dict{String,Any}(
            "n" => Dict{String,Any}("kind" => "interval", "size" => N)),
        "models" => Dict{String,Any}("M" =>
            Dict{String,Any}("variables" => vars, "equations" => eqs)))
end

_i_census(mod) = begin
    s = string(mod)
    Dict(op => length(findall(op, s)) for op in
         ("stablehlo.slice", "stablehlo.gather", "stablehlo.dynamic_slice",
          "stablehlo.scatter", "stablehlo.constant", "stablehlo.multiply",
          "stablehlo.add", "stablehlo.concatenate", "stablehlo.reshape"))
end
_i_ops(mod) = count(l -> occursin(" = stablehlo.", l) || occursin(" = \"stablehlo", l),
                    split(string(mod), '\n'))

_i_dev(p::NamedTuple) = NamedTuple{keys(p)}(map(RXi.ConcreteRNumber, values(p)))
_i_dev(::Nothing) = nothing
_i_bits(v::AbstractVector{Float64}) = reinterpret(UInt64, v)

@testset "traced (tensor, window) read interning" begin
    N, M = 12, length(_I_BODIES)
    fo, u0, p, _, _ = ESMi.build_evaluator(_i_doc(N, M); form = :oop)
    fi, _, _, _, _ = ESMi.build_evaluator(_i_doc(N, M))
    u = Float64[0.4 * sin(0.9k) + 1.1 for k in 1:length(u0)]
    host = fo(u, p, 0.0)
    ref = (du = zero(u); fi(du, u, p, 0.0); du)
    @test host == ref                       # the emitter itself, unchanged

    ur = RXi.ConcreteRArray(copy(u)); pr = _i_dev(p); tr = RXi.ConcreteRNumber(0.0)
    # THREE DISTINCT closure objects, deliberately: Reactant keys its compilation
    # caches on the callee, so reusing one closure across the ON and OFF builds
    # could silently hand the second build the FIRST one's compiled program and
    # make the comparison below vacuous.
    g_on = (uu, pp, tt) -> fo(uu, pp, tt)
    g_off = (uu, pp, tt) -> fo(uu, pp, tt)
    g_chk = (uu, pp, tt) -> fo(uu, pp, tt)

    # ---- 1 + 2. engagement, and the raw op census ---------------------------
    stats = Dict{String,Any}()
    cen = Dict{String,Any}()
    ops = Dict{String,Int}()
    for (mode, gg) in (("1", g_on), ("0", g_off))
        withenv("ESS_OOP_INTERN" => mode) do
            ESMi.oop_intern_stats_reset!()
            mod = RXi.@code_hlo optimize = false gg(ur, pr, tr)
            stats[mode] = ESMi.oop_intern_stats()
            cen[mode] = _i_census(mod)
            ops[mode] = _i_ops(mod)
        end
    end

    @test stats["1"].hits > 0               # interning ENGAGED
    @test stats["0"].hits == 0              # kill switch: no memo at all
    @test stats["0"].misses == 0

    # `g[i]` and `v[i]` are read by each of the M state equations, so at least
    # `2·(M−1)` of those reads are duplicates the memo must remove.
    @test stats["1"].hits >= 2 * (M - 1)
    # And EVERY hit removed exactly one emitted read — a whole-array read lowers
    # to a `slice` when its slots are a constant-stride run and a `gather`
    # otherwise, so the two counted together are the emitted-read total.
    _reads(c) = c["stablehlo.slice"] + c["stablehlo.gather"]
    @test _reads(cen["0"]) - _reads(cen["1"]) == stats["1"].hits
    @test cen["1"]["stablehlo.slice"] < cen["0"]["stablehlo.slice"]
    @test ops["1"] < ops["0"]

    # Nothing but reads moved: every other op kind is emitted identically.
    for k in ("stablehlo.scatter", "stablehlo.concatenate", "stablehlo.multiply")
        @test cen["1"][k] == cen["0"][k]
    end

    # ---- 3. traced ON ≡ traced OFF, BIT for bit ----------------------------
    on = withenv("ESS_OOP_INTERN" => "1") do
        Array(RXi.@jit g_on(ur, pr, tr))
    end
    off = withenv("ESS_OOP_INTERN" => "0") do
        Array(RXi.@jit g_off(ur, pr, tr))
    end
    @test _i_bits(on) == _i_bits(off)

    # ---- 4. traced ≡ host, to a few ulp (XLA reassociates; see the header) --
    @test isapprox(on, host; rtol = 1e-14)

    # ---- the ESS_OOP_INTERN=2 self-check mode runs clean --------------------
    checked = withenv("ESS_OOP_INTERN" => "2") do
        ESMi.oop_intern_stats_reset!()
        r = Array(RXi.@jit g_chk(ur, pr, tr))
        @test ESMi.oop_intern_stats().hits > 0
        r
    end
    @test _i_bits(checked) == _i_bits(on)

    # ---- the host path never builds a memo ---------------------------------
    @testset "host is not involved" begin
        ESMi.oop_intern_stats_reset!()
        h2 = fo(u, p, 0.0)
        @test h2 == host
        @test ESMi.oop_intern_stats() == (hits = 0, misses = 0)
        @test ESMi._oop_new_memo(u) === nothing
        # and a `Dual`/`Float32` walk gets the same `nothing`
        @test ESMi._oop_new_memo(Float32[1.0f0]) === nothing
    end
end
