# Cross-tier op/payload capability audit.
#
# The tree-walk engine evaluates the same spine through up to three tiers —
# the scalar interpreter (`_eval_acc`, access_kernel.jl), the lane tape
# (`_plan_emit!`/`_plan_op_supported`, access_kernel.jl), and the B1 codegen
# tier (`_cg_emit_op`/`_cg_emit_fn`, codegen_kernel.jl) — plus the hand-written
# guard-sanitizer table and the xcse cost gate. Capability drift between them
# is never an ERROR at runtime (the tape and codegen tiers decline and fall
# back), which is exactly why it goes unnoticed: an op or fn-payload shape
# added to one tier but not the others silently forfeits the faster tiers.
#
# This file makes that drift LOUD. Every deliberate capability gap is pinned
# in an explicit expected-decline manifest below, each entry with its reason;
# an unlisted gap (or a stale manifest entry) fails a test whose testset name
# says which manifest to update. Acceptance is probed BEHAVIORALLY where a
# tier expresses it only as an isa/if ladder, so the audit tracks the code,
# not a parallel hand copy of it.

using Test
using EarthSciAST

const ESM = EarthSciAST

@testset "op capability audit" begin

    # Every registered op name, as Symbols (spine node ops are Symbols).
    regops = Set{Symbol}(Symbol(name) for name in keys(ESM._OP_INDEX))

    # The four registry-derived mechanical ladder tables, with the arity each
    # tier is probed at (a representative legal arity per table).
    ladder_tables = [
        ("_UNARY_ELEMENTWISE_OPS",      ESM._UNARY_ELEMENTWISE_OPS,      1),
        ("_BINARY_ELEMENTWISE_OPS",     ESM._BINARY_ELEMENTWISE_OPS,     2),
        ("_COMPARISON_ELEMENTWISE_OPS", ESM._COMPARISON_ELEMENTWISE_OPS, 2),
        ("_NARY_MINMAX_OPS",            ESM._NARY_MINMAX_OPS,            2),
    ]

    # ---- Expected-decline manifests (ops) -----------------------------------
    # op => one-line reason. EMPTY today: the lane tape admits, and the codegen
    # dicts map, every op in all four registry tables (both consume the tables
    # directly). If a future registry op is DELIBERATELY unsupported by a tier,
    # list it here with the reason; an unlisted gap fails below.
    TAPE_OP_DECLINES    = Dict{Symbol,String}()
    CG_UNARY_DECLINES   = Dict{Symbol,String}()
    CG_BINARY_DECLINES  = Dict{Symbol,String}()
    CG_CMP_DECLINES     = Dict{Symbol,String}()
    CG_MINMAX_DECLINES  = Dict{Symbol,String}()

    @testset "lane tape admits every registry ladder op (else add to TAPE_OP_DECLINES)" begin
        for (tname, table, nargs) in ladder_tables
            gaps = Symbol[row.sym for row in table
                          if !ESM._plan_op_supported(row.sym, nargs) &&
                             !haskey(TAPE_OP_DECLINES, row.sym)]
            @testset "$tname" begin
                @test gaps == Symbol[]
            end
        end
        # Stale-entry sweep: a manifest op that IS supported (or left the
        # registry) means the manifest lags the code — prune it.
        stale = Symbol[op for op in keys(TAPE_OP_DECLINES)
                       if !(op in regops)]
        @test stale == Symbol[]
    end

    @testset "codegen dicts map every registry ladder op (else add to CG_*_DECLINES)" begin
        for (tname, table, dict, manifest) in [
            ("_UNARY_ELEMENTWISE_OPS",      ESM._UNARY_ELEMENTWISE_OPS,      ESM._CG_UNARY_FN,  CG_UNARY_DECLINES),
            ("_BINARY_ELEMENTWISE_OPS",     ESM._BINARY_ELEMENTWISE_OPS,     ESM._CG_BINARY_FN, CG_BINARY_DECLINES),
            ("_COMPARISON_ELEMENTWISE_OPS", ESM._COMPARISON_ELEMENTWISE_OPS, ESM._CG_CMP_FN,    CG_CMP_DECLINES),
            ("_NARY_MINMAX_OPS",            ESM._NARY_MINMAX_OPS,            ESM._CG_MINMAX_FN, CG_MINMAX_DECLINES),
        ]
            gaps = Symbol[row.sym for row in table
                          if !haskey(dict, row.sym) && !haskey(manifest, row.sym)]
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
        @test ESM._XCSE_EXPENSIVE_OPS == Set{Symbol}([
            :fn,
            :exp, :log, :log10,
            :sin, :cos, :tan, :asin, :acos, :atan, :atan2,
            :sinh, :cosh, :tanh, :asinh, :acosh, :atanh,
            :sqrt, :^, :pow,
        ])
    end

    @testset "_ACC_GUARD_SAFE keys vs registry (else update GUARD_SAFE_UNREGISTERED)" begin
        # op => reason it is in the guard-safe table without a registry row.
        # Empty: every sanitizer entry is a registered op (the former :log2 /
        # :log1p entries were dead — no registry op mints those symbols). An
        # entry belongs here only with a reason, never silently.
        GUARD_SAFE_UNREGISTERED = Dict{Symbol,String}()
        @test setdiff(Set(keys(ESM._ACC_GUARD_SAFE)), regops) ==
              Set(keys(GUARD_SAFE_UNREGISTERED))
    end

    # ---- fn-payload shape parity across the three tiers ---------------------
    #
    # Acceptance of a `:fn` node's payload is expressed as an isa-ladder in
    # each tier, so it is probed BEHAVIORALLY: build a real `:fn` node around
    # a real spec object and observe accept vs. the tier's decline signal
    # (interpreter: E_TREEWALK_UNKNOWN_CLOSED_FUNCTION; tape: _AccPlanDecline;
    # codegen: _CodegenDecline). Any other exception is a probe bug and
    # rethrows.

    lin  = ESM._InterpLinearSpec([0.0, 1.0], [0.0, 1.0])
    bil  = ESM._InterpBilinearSpec([[0.0, 1.0], [1.0, 2.0]], [0.0, 1.0], [0.0, 1.0])
    ss   = ESM._InterpSearchsortedSpec([0.0, 1.0])
    # Lane-spec boxes with degenerate addressing (s=0, off=1): every midx
    # resolves to lane 1, so the scalar probe below is well-defined.
    linL = ESM._InterpLinearLaneSpec([lin], 0, 0, 0, 1)
    bilL = ESM._InterpBilinearLaneSpec([bil], 0, 0, 0, 1)
    ssL  = ESM._InterpSearchsortedLaneSpec([ss], 0, 0, 0, 1)

    # The payload-shape universe: everything ANY tier accepts today, keyed for
    # the manifests below. (name, payload, nargs) — nargs matches the interp
    # kernel's query arity so the interpreter probe really evaluates.
    # Typed-core rider (ess-dtcore): what `_compile_fn_node` now mints for a
    # registry-declared all-scalar fn (`datetime.*`). The `:boxed` shape stays
    # in the universe as the fallback contract for UNDECLARED all-scalar fns —
    # unminted by the compiler for the v0.3.0 set, but every tier must keep
    # accepting it (it is what a declaration-less future fn compiles to).
    tcore = ESM._fn_typed_core_spec("datetime.hour")
    @test tcore isa ESM._FnTypedCoreSpec   # datetime.* must be declared
    shapes = [
        (:linear,            ("interp.linear",       lin),     1),
        (:bilinear,          ("interp.bilinear",     bil),     2),
        (:searchsorted,      ("interp.searchsorted", ss),      1),
        (:linear_lane,       ("interp.linear",       linL),    1),
        (:bilinear_lane,     ("interp.bilinear",     bilL),    2),
        (:searchsorted_lane, ("interp.searchsorted", ssL),     1),
        (:boxed,             ("datetime.hour",       nothing), 1),
        (:typed_core,        ("datetime.hour",       tcore),   1),
    ]
    ALL_SHAPES = Set(first.(shapes))

    # ---- Expected-acceptance manifests (fn payloads) ------------------------
    # The interpreter is the widest tier and MUST accept every shape — it is
    # the fallback the other tiers decline to. The tape matches it. The
    # codegen tier is the interpreter minus CG_FN_PAYLOAD_GAP.
    INTERP_FN_ACCEPTS = ALL_SHAPES
    TAPE_FN_ACCEPTS   = ALL_SHAPES
    # No known gaps: `_cg_emit_fn` covers the per-lane spec boxes too, so a
    # kernel the class merge produced stays on the compiled tier. A shape
    # added to one tier but not the others belongs here, one line per shape,
    # with the reason — not silently dropped from ALL_SHAPES.
    CG_FN_PAYLOAD_GAP = Set(Symbol[])
    CG_FN_ACCEPTS = setdiff(ALL_SHAPES, CG_FN_PAYLOAD_GAP)

    fnnode(payload, nargs) = ESM._mknode(kind=ESM._NK_OP, op=:fn,
        children=ESM._Node[ESM._alit(0.5) for _ in 1:nargs],
        payload=payload)

    # Minimal kernel context: literal-only children never touch the descriptor
    # table, bound, or CSE scratch, so the empty kernel is sufficient.
    K = ESM._AccKernel(ESM._contig_cells(1), ESM._alit(0.0), ESM._AccDesc[],
                       ESM._FixedBound(0), 0.0)

    function interp_accepts(payload, nargs)
        nd = fnnode(payload, nargs)
        try
            ESM._eval_acc(nd, Float64[], (;), 0.0, 1, 0, 1, (1, 1, 1), K, Float64)
            return true
        catch err
            (err isa ESM.TreeWalkError &&
             err.code == "E_TREEWALK_UNKNOWN_CLOSED_FUNCTION") && return false
            rethrow()
        end
    end

    function tape_accepts(payload, nargs)
        B = ESM._AccPlanBuilder(8)
        nd = fnnode(payload, nargs)
        try
            ESM._plan_emit_fn!(B, nd, K)
            return true
        catch err
            err isa ESM._AccPlanDecline && return false
            rethrow()
        end
    end

    function cg_accepts(payload, nargs)
        ctx = ESM._CGCtx(10_000)
        kc = ESM._CGKernCtx(K, :c, :n, :oln, 1, 1, 1, Symbol[], Symbol[])
        nd = fnnode(payload, nargs)
        try
            ESM._cg_emit_fn(ctx, kc, nd)
            return true
        catch err
            err isa ESM._CodegenDecline && return false
            rethrow()
        end
    end

    @testset "probes distinguish accept from decline" begin
        # A fabricated payload shape no tier knows: every probe must observe
        # a DECLINE, or the acceptance comparisons below prove nothing.
        bogus = ("interp.linear", :not_a_spec)
        @test !interp_accepts(bogus, 1)
        @test !tape_accepts(bogus, 1)
        @test !cg_accepts(bogus, 1)
    end

    @testset "interpreter fn-payload shapes (else update INTERP_FN_ACCEPTS/shapes)" begin
        @test Set(k for (k, pl, n) in shapes if interp_accepts(pl, n)) ==
              INTERP_FN_ACCEPTS
    end

    @testset "lane-tape fn-payload shapes (else update TAPE_FN_ACCEPTS/shapes)" begin
        @test Set(k for (k, pl, n) in shapes if tape_accepts(pl, n)) ==
              TAPE_FN_ACCEPTS
    end

    @testset "codegen fn-payload shapes (else update CG_FN_PAYLOAD_GAP/shapes)" begin
        @test Set(k for (k, pl, n) in shapes if cg_accepts(pl, n)) ==
              CG_FN_ACCEPTS
    end
end
