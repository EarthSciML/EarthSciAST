# ========================================================================
# tree_walk/errors.jl — part of the tree-walk evaluator (gt-e8yw).
# Included by src/tree_walk.jl; see that file for the full layout and
# include order. Section 1: the TreeWalkError type and its E_TREEWALK_* codes.
# ========================================================================

# ============================================================
# 1. Error type
# ============================================================

"""
    TreeWalkError

Raised when the walker encounters an operator or construct it cannot
evaluate. `code` is one of two families:

* an `E_TREEWALK_*` code from the bead's acceptance criterion — this
  evaluator's own build/eval failures; or
* the bare `unlowered_operator` code (esm-spec §4.2 / §9.6.8), thrown by
  `_compile_op` when a rewrite-target operator (an RHS-position `D`, or
  `grad`/`div`/`laplacian`) reaches evaluation without a discretization
  rule having lowered it. That code is DELIBERATELY not `E_TREEWALK_*`:
  it is the uniform cross-binding wire code every implementation surfaces
  for this pipeline violation, so it must not be renamed to match the
  local convention.

`detail` carries op name or variable name for diagnostics.
"""
struct TreeWalkError <: EarthSciASTError
    code::String
    detail::String
end

Base.showerror(io::IO, e::TreeWalkError) =
    print(io, "$(e.code): $(e.detail)")

# ============================================================
# 2. Direct StableHLO emission (ext/reactant_direct/)
# ============================================================

"""
    E_DIRECT_EMIT_UNSUPPORTED

The one diagnostic code the direct StableHLO emitter raises (the compiled
backend in `ext/reactant_direct/`, reached through `direct_rhs`).

It lives HERE, beside [`TreeWalkError`](@ref)'s `E_TREEWALK_*` family, and NOT
in `ERROR_CODES` (src/error_codes.jl), for the reason that file states: the
registry is a CROSS-BINDING wire contract whose values every binding must be
able to emit. This one is a Julia-local backend diagnostic — Rust's compiled
lane refuses through its own vocabulary — so registering it would put a code in
the shared contract that four bindings can never raise. Same reading, and the
same placement, as `E_TREEWALK_XLA_LIVE_FORCING`.
"""
const E_DIRECT_EMIT_UNSUPPORTED = "E_DIRECT_EMIT_UNSUPPORTED"

"""
    DirectEmitError <: EarthSciASTError

Raised when the direct StableHLO emitter meets a node kind, access-kernel
descriptor or kernel SHAPE it cannot lower.

It is a HARD error by design (the compiled-backends ruling of 2026-09-13):
there is no fallback to the interpreter and no fallback to the traced emitter,
because a compiled lane that silently answered with a different evaluator would
make the `compiled_rhs` conformance tier report agreement between the
interpreter and itself.

Fields:

* `code` — always [`E_DIRECT_EMIT_UNSUPPORTED`](@ref).
* `construct` — WHAT could not be lowered, in the IR's own vocabulary: the node
  kind (`_NK_SUBCALL`), the access descriptor kind (`_AK_ARR_TBL_BOX`), the
  operator (`` `op `atan2`` ``) or the kernel shape ("per-cell fallback
  kernel"). This is the string a test asserts on.
* `rule` — WHERE it came from: the state equation, materialized-observed fill
  level or access kernel being emitted, named by variable when the caller
  passed a `var_map` to [`direct_rhs`](@ref) and by flat slot otherwise.
* `detail` — plain words: why it cannot be lowered, and what would change that.

`rule` and `construct` are what the `compiled_rhs` adapter reports as a
fixture's `refused` outcome, so keep both short and specific.
"""
struct DirectEmitError <: EarthSciASTError
    code::String
    construct::String
    rule::String
    detail::String
end

DirectEmitError(construct::AbstractString, rule::AbstractString, detail::AbstractString) =
    DirectEmitError(E_DIRECT_EMIT_UNSUPPORTED, String(construct), String(rule),
                    String(detail))

Base.showerror(io::IO, e::DirectEmitError) =
    print(io, e.code, ": direct StableHLO emission cannot lower ", e.construct,
          " (from ", e.rule, "): ", e.detail)
