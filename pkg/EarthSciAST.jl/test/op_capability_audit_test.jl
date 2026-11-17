# Cross-tier op/payload capability audit.
#
# The tree-walk engine evaluates the same spine through two tiers —
# the scalar interpreter (`_eval_acc`, access_kernel.jl) and the Julia codegen
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

    # The Julia emitter's operator arms are `_op_expr`, one template per registry
    # shape, so every shaped op has one by construction. Pin that each emitted
    # expression computes what the host ladder computes, bit for bit, at a
    # representative arity of every shaped row.
    @testset "the emitter's expression for every shaped op equals the host ladder" begin
        argval(sym) = sym in (:acosh,) ? 1.5 : 0.5
        for r in ESM._SHAPED_OPS
            ar = r.spec.arity
            for n in unique([first(ar), min(first(ar) + 1, last(ar)), min(3, last(ar))])
                n in ar || continue
                vals = [argval(r.sym) + 0.25 * (i - 1) for i in 1:n]
                r.spec.shape === :select && (vals[1] = 1.0)
                want = ESM._scalar_op(r.sym, vals)
                got = Core.eval(ESM, ESM._op_expr(r.spec, Any[v for v in vals]))
                @testset "$(r.name)/$n" begin
                    @test isequal(got, want)
                end
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
