# =============================================================================
# Wall #2 — Phase E ENGAGEMENT proof (low memory; no MTK / no build_evaluator).
#
# Verifies the Phase C compile-once fast path ENGAGES on the REAL ISRM deathsK
# observed STRUCTURE (transcribed from isrm_pushdown.esm), reproducing it
# bit-identically vs the per-cell path with ZERO fallback. This is the structural
# gate for the full-oracle run: if the fast path fell back on this shape, the
# 52,411-cell run would revert to the O(N_cells·N_src) per-cell blowup.
#
# Real structure (isrm_pushdown.esm ISRM variables):
#   conc_p[rcv]    = Σ_s SR_p[s,rcv]·E_p[s]                    (contracting aggregate)
#   TotalPM25[rcv] = fact·Σ_p conc_p[rcv]                       (NON-contracting agg over
#                                                               nested contracting aggs)
#   deathsK[rcv]   = (exp(log(rrK)/10·TotalPM25[rcv])−1)·TotalPop[rcv]·psc
#                    ·(Mort[rcv]/1e5)·msc
# Exercises the three features not covered by the phase C/D synthetic tests:
#   (1) NESTED aggregates, (2) a NON-CONTRACTING outer aggregate over rcv,
#   (3) OUTPUT-INDEXED const gathers (TotalPop[rcv], MortalityRate[rcv]).
#
# This is a STRUCTURAL replica with tiny synthetic data — it proves the machinery
# handles the real shape. The definitive full-scale oracle number
# (sum(deathsK)=7524.918845602511) through the real build_evaluator is a separate,
# memory-heavy run deferred to a larger machine (this box is 8 GB).
# =============================================================================
using EarthSciAST
const ESM = EarthSciAST
using Test

_v(n)   = VarExpr(String(n))
_num(x) = NumExpr(Float64(x))
_op(o, a...; kw...) = OpExpr(String(o), ESM.ASTExpr[a...]; kw...)
_ix(base, subs...) = _op("index", (base isa ESM.ASTExpr ? base : _v(base)),
                         [s isa String ? _v(s) : _num(s) for s in subs]...)

const NS = 8
const NR = 6
const PATHS = ["SOA","pNO3","pNH4","pSO4","PrimaryPM25"]
const FACT=28766.639; const RRK=1.06; const PSC=1.0465819687408728; const MSC=1.025229357798165

conc(p) = _op("aggregate"; output_idx=Any["rcv"], semiring="sum_product",
    ranges=Dict{String,Any}("s"=>Any[1,NS], "rcv"=>Any[1,NR]),
    expr_body=_op("*", _ix("SR_$p","s","rcv"), _ix("E_$p","s")))
tpm() = _op("*", _num(FACT), _op("+", [_ix(conc(p), "rcv") for p in PATHS]...))
tpm_as_agg() = _op("aggregate"; output_idx=Any["rcv"],
    ranges=Dict{String,Any}("rcv"=>Any[1,NR]), expr_body=tpm())
deaths_body(rr) = _op("*",
    _op("*",
        _op("*",
            _op("-", _op("exp", _op("*", _op("/", _op("log", _num(rr)), _num(10.0)), tpm())), _num(1.0)),
            _op("*", _ix("TotalPop","rcv"), _num(PSC))),
        _op("/", _ix("MortalityRate","rcv"), _num(1e5))),
    _num(MSC))
deathsK() = _op("aggregate"; output_idx=Any["rcv"],
    ranges=Dict{String,Any}("rcv"=>Any[1,NR]), expr_body=deaths_body(RRK))

function make_ca()
    ca = Dict{String,Any}()
    for (pi,p) in enumerate(PATHS)
        ca["SR_$p"] = [0.001*(s + 0.3*rcv + 2*pi) for s in 1:NS, rcv in 1:NR]
        ca["E_$p"]  = Float64[0.5*s + pi for s in 1:NS]
    end
    ca["TotalPop"]      = Float64[100.0*rcv + 50 for rcv in 1:NR]
    ca["MortalityRate"] = Float64[800.0 + rcv for rcv in 1:NR]
    return ca
end

const REG = Dict{String,Function}()
const NOP = Dict{String,Float64}()
const CELLS = [[r] for r in 1:NR]

@testset "wall2 Phase E — engagement on real deathsK structure" begin
    ca = make_ca()

    # (1) DIRECT engagement: the fast path must return a non-nothing evaluator.
    @test ESM._cellwise_compile_once(conc("SOA"), 1, ca, REG, NOP) !== nothing
    @test ESM._cellwise_compile_once(tpm_as_agg(), 1, ca, REG, NOP) !== nothing
    @test ESM._cellwise_compile_once(deathsK(), 1, ca, REG, NOP) !== nothing

    # (2) bit-identity + NO fallback (deathsK — the full nested structure).
    ESM._CELLWISE_FASTPATH_HITS[] = 0; ESM._CELLWISE_FASTPATH_MISS[] = 0
    dk = deathsK()
    fast = ESM.evaluate_cellwise(dk, CELLS; const_arrays=ca)
    ref  = Float64[ESM._eval_cellwise(dk, [r]; const_arrays=ca) for r in 1:NR]
    @test fast == ref                              # bit-identical
    @test ESM._CELLWISE_FASTPATH_MISS[] == 0       # nothing fell back
    @test ESM._CELLWISE_FASTPATH_HITS[] >= 1

    # (3) TotalPM25 (non-contracting over nested contractions).
    tp_fast = ESM.evaluate_cellwise(tpm_as_agg(), CELLS; const_arrays=ca)
    tp_ref  = Float64[ESM._eval_cellwise(tpm_as_agg(), [r]; const_arrays=ca) for r in 1:NR]
    @test tp_fast == tp_ref
end
