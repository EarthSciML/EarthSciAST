# ============================================================
# Deprecations — names that have left the public surface and are kept, for ONE
# minor version, so a downstream package keeps running while it migrates.
# ============================================================
#
# Everything here is scheduled for deletion. Each entry says what replaced it,
# what the caller has to change, and which release removes it. Nothing inside
# the package calls anything in this file: the in-tree callers were migrated
# when the name was retired, so a warning from here always names a caller
# outside it.

"""
    build_evaluator(input; kwargs...) -> (f!, u0, p, tspan, var_map)

**Deprecated (API_SPEC §8 item 23, §10).** Removed in the next minor version.
Use [`esm_problem`](@ref).

`build_evaluator` was the extension seam under the runners, never stable API,
and a caller had to reassemble a run out of its five-tuple by hand. The Problem
absorbs the whole pipeline — load → flatten → shape transforms → value
invention → gated fetch → compile → seed → callbacks — and hangs what used to
come off the evaluator on itself instead:

| was | is |
|---|---|
| `f!, u0, p, tspan, var_map = build_evaluator(doc)` | `prob = esm_problem(doc, tspan)`, then `prob.f!`, `prob.u0`, `prob.p`, `prob.tspan`, `prob.var_map` |
| `build_evaluator(doc; form = :oop)` + a compiled backend | `esm_problem(doc, tspan; compiler = :xla)` — the Problem's `f!` IS the compiled StableHLO program |
| `forcing_buffers(f)` / `forcing_buffer_index(f)` | [`forcing_buffers`](@ref)`(prob)` / [`forcing_buffer_index`](@ref)`(prob)` |
| `insp = BuildInspection(); build_evaluator(doc; inspect = insp); insp.compiler_report` | [`compiler_report`](@ref)`(prob)` |

The keyword arguments are unchanged, so a call that cannot yet move — one that
builds from a bare `Model`, or one that wants the out-of-place compiled
intermediate representation to lower itself — keeps working through this alias
in the meantime.
"""
function build_evaluator(input, args...; kwargs...)
    @warn """
          `build_evaluator` is deprecated and will be removed in the next minor \
          version: it was the extension seam under the runners, not stable API \
          (API_SPEC §8 item 23). Build an `esm_problem(input, tspan; …)` and \
          read `prob.f!` / `prob.u0` / `prob.p` / `prob.var_map` off it; for \
          the compiled StableHLO right-hand side that `form = :oop` used to \
          hand a backend, build with `compiler = :xla`. `forcing_buffers`, \
          `forcing_buffer_index` and `compiler_report` all take the Problem \
          now.""" maxlog = 1
    return _build_evaluator(input, args...; kwargs...)
end
