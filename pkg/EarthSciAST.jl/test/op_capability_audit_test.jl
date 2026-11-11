# Cross-tier op/payload capability audit.
#
# The tree-walk engine evaluates the same spine through two tiers —
# the scalar interpreter (`_eval_acc`, access_kernel.jl) and the B1 codegen
# tier (`_cg_emit_op`, codegen_kernel.jl) — plus the xcse cost gate.
# Capability drift between them is never an ERROR at runtime (the codegen
# tier declines and falls back), which is exactly why it goes unnoticed: an op
# added to one tier but not the other silently forfeits the faster tier.
#
# This file makes that drift LOUD. Every deliberate capability gap is pinned
# in an explicit expected-decline manifest below, each entry with its reason;
# an unlisted gap (or a stale manifest entry) fails a test whose testset name
# says which manifest to update.

using Test
using EarthSciAST

const ESM = EarthSciAST

@testset "op capability audit" begin

    # Every registered op name, as Symbols (spine node ops are Symbols).
    regops = Set{Symbol}(Symbol(name) for name in keys(ESM._OP_INDEX))

    # The four registry-derived mechanical ladder tables, with the arity each
    # tier is probed at (a representative legal arity per table).
    ladder_tables = [
        ("_UNARY_ELEMENTWISE_OPS", ESM._UNARY_ELEMENTWISE_OPS, 1),
        ("_BINARY_ELEMENTWISE_OPS", ESM._BINARY_ELEMENTWISE_OPS, 2),
        ("_COMPARISON_ELEMENTWISE_OPS", ESM._COMPARISON_ELEMENTWISE_OPS, 2),
        ("_NARY_MINMAX_OPS", ESM._NARY_MINMAX_OPS, 2),
    ]

    # ---- Expected-decline manifests (ops) -----------------------------------
    # op => one-line reason. EMPTY today: the codegen
    # dicts map every op in all four registry tables (they consume the tables
    # directly). If a future registry op is DELIBERATELY unsupported by the
    # tier, list it here with the reason; an unlisted gap fails below.
    CG_UNARY_DECLINES = Dict{Symbol, String}()
    CG_BINARY_DECLINES = Dict{Symbol, String}()
    CG_CMP_DECLINES = Dict{Symbol, String}()
    CG_MINMAX_DECLINES = Dict{Symbol, String}()

    @testset "codegen dicts map every registry ladder op (else add to CG_*_DECLINES)" begin
        for (tname, table, dict, manifest) in [
                ("_UNARY_ELEMENTWISE_OPS", ESM._UNARY_ELEMENTWISE_OPS, ESM._CG_UNARY_FN, CG_UNARY_DECLINES),
                ("_BINARY_ELEMENTWISE_OPS", ESM._BINARY_ELEMENTWISE_OPS, ESM._CG_BINARY_FN, CG_BINARY_DECLINES),
                ("_COMPARISON_ELEMENTWISE_OPS", ESM._COMPARISON_ELEMENTWISE_OPS, ESM._CG_CMP_FN, CG_CMP_DECLINES),
                ("_NARY_MINMAX_OPS", ESM._NARY_MINMAX_OPS, ESM._CG_MINMAX_FN, CG_MINMAX_DECLINES),
            ]
            gaps = Symbol[
                row.sym for row in table
                    if !haskey(dict, row.sym) && !haskey(manifest, row.sym)
            ]
            @testset "$tname" begin
                @test gaps == Symbol[]
            end
        end
    end

    @testset "_XCSE_EXPENSIVE_OPS ⊆ registry ops (dead cost-gate entries are forbidden)" begin
        # Derived via _ops_with(:xcse_expensive), so containment holds by
        # construction — this pins that it STAYS derived (a hand re-list that
        # re-grows expm1/log2/log1p/cbrt-style dead spellings fails here).
        @test setdiff(ESM._XCSE_EXPENSIVE_OPS, regops) == Set{Symbol}()
        # Membership pin (the pre-registry hand list minus its four dead
        # entries — expm1/log2/log1p/cbrt had no registry row, so they could
        # never match a spine op; dropping them changed no behavior).
        @test ESM._XCSE_EXPENSIVE_OPS == Set{Symbol}(
            [
                :exp, :log, :log10,
                :sin, :cos, :tan, :asin, :acos, :atan, :atan2,
                :sinh, :cosh, :tanh, :asinh, :acosh, :atanh,
                :sqrt, :^, :pow,
            ]
        )
    end
end
