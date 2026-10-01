# Lane-batched grouping of the per-cell scalar surface (ess-oop-batch).
#
# `rhs_list` entries a state equation lowers to when it declines the kernel path
# (a runtime contraction loop routes there by design), and the per-column
# `scalars` of a materialized-observed fill level, are one entry PER CELL. A
# compiled backend that emitted them one at a time would emit a program whose
# SIZE follows the grid. So the build buckets them by structural congruence
# (`_oop_batch_sig`), lowers each bucket ONCE to a lane-batched tree
# (`_oop_batch_lower`), and hands the result out on the compiled IR as
# `rhs_batches` / `mat_batches` — which is what a backend emits over a lane axis.
#
# The grouping is BUILD-TIME, so this file is host-only and asserts the build:
#
#   * groups form, with the lane counts the fixture's congruence implies, and
#     `rest` holds exactly the entries no group took;
#   * the signature pins what it must and wildcards what it must — a different
#     operator, a different parameter symbol or a different pow exponent
#     separates two entries; a different CELL (a different state slot, a
#     different value-position literal) does not, which is the whole point;
#   * with the grouping off (`compiler=:interpreter`) every entry stays in
#     `rest` and there are no groups at all.
#
# The emitted program the groups become is pinned in
# test/reactant_direct_emit_test.jl ("the lane-batched scalar surface"), under
# ESM_TEST_REACTANT=1.
using Test
include("testutils.jl")

using EarthSciAST
const _SB_ESS = EarthSciAST

# Lane batching is a property of the PER-CELL contraction loop's `rhs_list`
# entries, so every fixture here has to actually reach that tier. The whole-array
# contraction nest (ess-array-contraction) sits above it and takes any reduction
# that clears its floor for the whole equation at once — leaving no per-cell
# entries to batch. These reductions are far under the shipped floor, but the
# floor is named rather than inherited so the routing under test is a fact of the
# fixture and not of the ambient environment.
_sb_env() = ("ESS_CONTRACTION_LOOP_MIN" => "8",
             "ESS_ARRAY_CONTRACTION_MIN" => "1024")
_sb_compiler(batch::Bool) = batch ? :native : :interpreter

# The compiled IR behind an out-of-place build.
_sb_ir(fo) = getfield(fo, :rhs)

# ── rhs_list: the state-source halo tent from contraction_loop_test.jl ────────
# Per output cell, ONE `_NK_CONTRACTION_LOOP` whose body reads state at a
# loop-var-dependent slot (`_NK_STATE_GATHER`) and a per-cell const weight
# (`_NK_CONST_GATHER`) — the shape a mass-weighted column integral lowers to.
# All 4 output cells are congruent, so one group of 4 lanes.
function _sb_halo(M::Int)
    NI, NJ = 2, 2
    NQ = max(NI, NJ) + M - 1
    W = [ [ [ [ Float64((i+2j+3k+5l) % 7) for l in 1:M ] for k in 1:M ] for j in 1:NJ ] for i in 1:NI ]
    donor(a, b) = Dict("op"=>"-","args"=>Any[Dict("op"=>"+","args"=>Any[a,b]),1])
    agg = Dict{String,Any}("op"=>"faq","semiring"=>"sum_product","args"=>Any[],
        "output_idx"=>Any["i","j"],
        "ranges"=>Dict("i"=>Any[1,NI],"j"=>Any[1,NJ],"k"=>Any[1,M],"l"=>Any[1,M]),
        "expr"=>Dict("op"=>"*","args"=>Any[
            Dict("op"=>"index","args"=>Any[Dict("op"=>"const","args"=>Any[],"value"=>W),"i","j","k","l"]),
            Dict("op"=>"index","args"=>Any["q", donor("i","k"), donor("j","l")])]))
    doc = Dict{String,Any}("esm"=>"1.1.0","metadata"=>Dict("name"=>"sb_halo"),
      "models"=>Dict("R"=>Dict{String,Any}(
        "variables"=>Dict("q"=>Dict("type"=>"unknown","shape"=>Any["a","b"]),
                          "out"=>Dict("type"=>"unknown","shape"=>Any["i","j"])),
        "equations"=>Any[
          Dict("lhs"=>Dict("op"=>"faq","args"=>Any[],"output_idx"=>Any["a","b"],
                 "ranges"=>Dict("a"=>Any[1,NQ],"b"=>Any[1,NQ]),
                 "expr"=>Dict("op"=>"D","args"=>Any[Dict("op"=>"index","args"=>Any["q","a","b"])],"wrt"=>"t")),
               "rhs"=>Dict("op"=>"faq","args"=>Any[],"output_idx"=>Any["a","b"],
                 "ranges"=>Dict("a"=>Any[1,NQ],"b"=>Any[1,NQ]),"expr"=>0.0)),
          Dict("lhs"=>Dict("op"=>"faq","args"=>Any[],"output_idx"=>Any["i","j"],
                 "ranges"=>Dict("i"=>Any[1,NI],"j"=>Any[1,NJ]),
                 "expr"=>Dict("op"=>"D","args"=>Any[Dict("op"=>"index","args"=>Any["out","i","j"])],"wrt"=>"t")),
               "rhs"=>agg)])))
    ics = Dict{String,Any}("out[1,1]"=>0.0,"out[1,2]"=>0.0,"out[2,1]"=>0.0,"out[2,2]"=>0.0)
    for a in 1:NQ, b in 1:NQ; ics["q[$a,$b]"] = Float64(10a + b); end
    (doc, ics, NI, NJ)
end

@testset "lane-batched grouping of the per-cell scalar surface (ess-oop-batch)" begin

    @testset "rhs_list contraction loops: one group, every lane in it" begin
        doc, ics, NI, NJ = _sb_halo(8)
        fo, _, _, _, _ = withenv(_sb_env()...) do
            EarthSciAST._build_evaluator(doc; initial_conditions = ics, form = :oop)
        end
        ir = _sb_ir(fo)
        # The fixture must actually reach the per-cell tier, or every assertion
        # below is vacuous.
        @test length(getfield(ir, :rhs_list)) == NI * NJ

        rb = getfield(ir, :rhs_batches)
        @test length(rb.groups) == 1                  # one congruence class
        @test length(rb.groups[1].slots) == NI * NJ   # carrying every cell
        @test rb.n_batched == NI * NJ
        @test isempty(rb.rest)                        # nothing left per-entry
        # The group's slots are the rhs_list slots, each exactly once: a group
        # that dropped or doubled a cell would still satisfy the counts above.
        @test sort(rb.groups[1].slots) == sort(first.(getfield(ir, :rhs_list)))
        # …and the lowered tree really carries the batched contraction loop.
        root = rb.groups[1].root
        @test root.kind == _SB_ESS._NK_CONTRACTION_LOOP ||
              any(c -> c.kind == _SB_ESS._NK_CONTRACTION_LOOP, root.children)

        # Grouping off: every entry stays single, `rest` is the whole surface.
        fn, _, _, _, _ = withenv(_sb_env()...) do
            EarthSciAST._build_evaluator(doc; initial_conditions = ics, form = :oop,
                            compiler = :interpreter)
        end
        rn = getfield(_sb_ir(fn), :rhs_batches)
        @test isempty(rn.groups)
        @test rn.n_batched == 0
        # With the contraction loop off too, the reduction unrolls into many
        # more scalar entries — `rest` is whatever the surface is, entry for
        # entry, which is the claim.
        @test length(rn.rest) == length(getfield(_sb_ir(fn), :rhs_list))
        @test sort(first.(rn.rest)) == sort(first.(getfield(_sb_ir(fn), :rhs_list)))
    end

    # ── Materialized-observed fills: S[i] = Σ_k W[k]·q[i,k], read by D(v[i]) ──
    # The observed's fill compiles per COLUMN into `mat_levels` scalars, each
    # carrying one contraction loop over k. All N columns are congruent, so one
    # group of N lanes at that level. `mat_batches` is tuple-aligned with
    # `mat_levels`, which is the alignment a backend walks them by.
    @testset "materialized fill levels group per column" begin
        N, M = 6, 12                      # M ≥ the contraction-loop floor
        W = collect(1.0:Float64(M))
        isets = Dict("x" => _SB_ESS.IndexSet("interval"; size = N),
                     "y" => _SB_ESS.IndexSet("interval"; size = M))
        vars = Dict(
            "q" => _SB_ESS.ModelVariable(_SB_ESS.UnknownVariable; shape = ["x", "y"]),
            "v" => _SB_ESS.ModelVariable(_SB_ESS.UnknownVariable; shape = ["x"]),
            # esm 1.0.0 (§5.4/§6.3.1): `S` is a plain `unknown`; the `S ~ Sdef`
            # equation below is what makes it OBSERVED.
            "S" => _SB_ESS.ModelVariable(_SB_ESS.UnknownVariable; shape = ["x"]),
        )
        rng_i  = Dict{String,Any}("i" => _SB_ESS.IndexSetRef("x"))
        rng_ik = Dict{String,Any}("i" => _SB_ESS.IndexSetRef("x"),
                                  "k" => _SB_ESS.IndexSetRef("y"))
        rng_ab = Dict{String,Any}("a" => _SB_ESS.IndexSetRef("x"),
                                  "b" => _SB_ESS.IndexSetRef("y"))
        Sdef = _op("faq"; output_idx = Any["i"], ranges = rng_ik,
                   semiring = "sum_product",
                   expr_body = _op("*", _op("index", _const(W), _v("k")),
                                   _idx("q", _v("i"), _v("k"))))
        eqs = [
            _SB_ESS.Equation(_v("S"), Sdef),
            _SB_ESS.Equation(
                _op("faq"; output_idx = Any["a", "b"], ranges = rng_ab,
                    expr_body = _Didx("q", _v("a"), _v("b"))),
                _op("faq"; output_idx = Any["a", "b"], ranges = rng_ab,
                    expr_body = _n(0.0))),
            _SB_ESS.Equation(
                _op("faq"; output_idx = Any["i"], ranges = rng_i,
                    expr_body = _Didx("v", _v("i"))),
                _op("faq"; output_idx = Any["i"], ranges = rng_i,
                    expr_body = _idx("S", _v("i")))),
        ]
        model = _SB_ESS.Model(vars, eqs)
        ics = Dict{String,Any}("v[$j]" => 0.0 for j in 1:N)
        for j in 1:N, k in 1:M; ics["q[$j,$k]"] = Float64(3j + k); end
        bld(batch) = withenv(_sb_env()...) do
            EarthSciAST._build_evaluator(model; index_sets = isets, initial_conditions = ics,
                            form = :oop, compiler = _sb_compiler(batch))[1]
        end

        ir = _sb_ir(bld(true))
        mat = getfield(ir, :mat_levels)
        mb = getfield(ir, :mat_batches)
        @test length(mb) == length(mat)          # tuple-aligned with the levels
        @test length(mat) >= 1
        lvl = findfirst(sb -> !isempty(sb.groups), collect(mb))
        @test lvl !== nothing
        sb = mb[lvl]
        @test length(sb.groups) == 1
        @test length(sb.groups[1].slots) == N
        @test sb.n_batched == N
        @test isempty(sb.rest)
        # Its slots are that level's own scalar slots — the fill writes exactly
        # the columns the level declared.
        @test sort(sb.groups[1].slots) == sort(first.(mat[lvl][1]))

        # Kill switch leaves every level's fills on the per-column path.
        mn = getfield(_sb_ir(bld(false)), :mat_batches)
        @test all(s -> isempty(s.groups), mn)
        @test all(i -> length(mn[i].rest) == length(mat[i][1]), eachindex(mn))
    end

    # ── Non-congruent entries stay out ───────────────────────────────────────
    # Same-structure entries with the SAME literal exponent group; a DIFFERENT
    # exponent gets a different key and stays in `rest`. That pinning is what
    # keeps a group from blending the power rule under a Dual walk.
    @testset "a differing pow exponent is not taken into the group" begin
        doc = Dict{String,Any}("esm"=>"0.8.0","metadata"=>Dict("name"=>"sb_pow"),
          "models"=>Dict("P"=>Dict{String,Any}(
            "variables"=>Dict("x"=>Dict("type"=>"unknown"),"y"=>Dict("type"=>"unknown"),
                              "a"=>Dict("type"=>"unknown"),"b"=>Dict("type"=>"unknown"),
                              "c"=>Dict("type"=>"unknown")),
            "equations"=>Any[
              Dict("lhs"=>Dict("op"=>"D","args"=>Any["x"],"wrt"=>"t"),"rhs"=>0.0),
              Dict("lhs"=>Dict("op"=>"D","args"=>Any["y"],"wrt"=>"t"),"rhs"=>0.0),
              Dict("lhs"=>Dict("op"=>"D","args"=>Any["a"],"wrt"=>"t"),
                   "rhs"=>Dict("op"=>"^","args"=>Any["x",2.0])),
              Dict("lhs"=>Dict("op"=>"D","args"=>Any["b"],"wrt"=>"t"),
                   "rhs"=>Dict("op"=>"^","args"=>Any["y",2.0])),
              Dict("lhs"=>Dict("op"=>"D","args"=>Any["c"],"wrt"=>"t"),
                   "rhs"=>Dict("op"=>"^","args"=>Any["x",3.0])),
            ])))
        ics = Dict("x"=>1.5,"y"=>-2.5,"a"=>0.0,"b"=>0.0,"c"=>0.0)
        fo, _, _, _, vm = EarthSciAST._build_evaluator(doc; initial_conditions=ics, form=:oop)
        rb = getfield(_sb_ir(fo), :rhs_batches)
        pow = [g for g in rb.groups if g.root.kind == _SB_ESS._NK_OP &&
               (g.root.op === :^ || g.root.op === :pow)]
        @test length(pow) == 1                 # the two `^2` entries, and only those
        @test sort(pow[1].slots) == sort([vm["a"], vm["b"]])
        # The exponent is PINNED in the lowered tree: a shared literal, not a
        # per-lane column, so the group cannot have blended 2 with 3.
        e = pow[1].root.children[2]
        @test e.kind == _SB_ESS._NK_LITERAL && isempty(e.lanes_f) && e.literal == 2.0
        # …and `^3` is in `rest`, not in any group.
        @test vm["c"] in first.(rb.rest)
        @test !any(g -> vm["c"] in g.slots, rb.groups)
    end

    # ── The signature itself, on hand-built nodes ────────────────────────────
    # `_oop_batch_sig` decides the buckets, so what it pins and what it
    # wildcards IS the grouping rule. Checked directly, because a model fixture
    # can only ever show one corner of it at a time.
    @testset "the signature pins the shape and wildcards the cell" begin
        lit(x) = _SB_ESS._mknode(kind = _SB_ESS._NK_LITERAL, literal = x)
        st(i)  = _SB_ESS._mknode(kind = _SB_ESS._NK_STATE, idx = i)
        par(s) = _SB_ESS._mknode(kind = _SB_ESS._NK_PARAM, sym = s)
        op(o, cs...) = _SB_ESS._mknode(kind = _SB_ESS._NK_OP, op = o,
                                       children = _SB_ESS._Node[cs...])
        sig = _SB_ESS._oop_batch_sig

        # WILDCARDED — this is what makes two CELLS of one equation congruent.
        @test sig(op(:*, st(3), par(:k))) == sig(op(:*, st(9), par(:k)))
        @test sig(op(:*, st(3), lit(1.5))) == sig(op(:*, st(3), lit(-40.0)))

        # PINNED — a different equation must not be pulled into the group.
        @test sig(op(:*, st(3), par(:k))) != sig(op(:+, st(3), par(:k)))
        @test sig(op(:*, st(3), par(:k))) != sig(op(:*, st(3), par(:j)))
        @test sig(op(:^, st(3), lit(2.0))) != sig(op(:^, st(3), lit(3.0)))
        # Tree SHAPE, not just the node at the root.
        @test sig(op(:*, st(3), op(:+, st(4), par(:k)))) !=
              sig(op(:*, st(3), op(:-, st(4), par(:k))))
        @test sig(op(:*, st(3), par(:k))) != sig(op(:*, st(3), par(:k), par(:k)))
    end

    # ── The bucketing, on a hand-built surface ───────────────────────────────
    # `_oop_batch_scalars` is what a build calls; driving it directly pins the
    # partition (which entries group, which fall to `rest`) without a fixture
    # that has to route through a particular tier to show it.
    @testset "the surface partitions into groups and a remainder" begin
        st(i)  = _SB_ESS._mknode(kind = _SB_ESS._NK_STATE, idx = i)
        par(s) = _SB_ESS._mknode(kind = _SB_ESS._NK_PARAM, sym = s)
        op(o, cs...) = _SB_ESS._mknode(kind = _SB_ESS._NK_OP, op = o,
                                       children = _SB_ESS._Node[cs...])
        # Three cells of `k * u[i]`, two cells of `k + u[i]`, one lone `j * u[i]`.
        entries = Tuple{Int,_SB_ESS._Node}[
            (11, op(:*, par(:k), st(1))),
            (12, op(:*, par(:k), st(2))),
            (13, op(:*, par(:k), st(3))),
            (21, op(:+, par(:k), st(4))),
            (22, op(:+, par(:k), st(5))),
            (31, op(:*, par(:j), st(6))),
        ]
        sb = _SB_ESS._oop_batch_scalars(entries)
        @test sort(length.(getfield.(sb.groups, :slots))) == [2, 3]
        @test sb.n_batched == 5
        @test first.(sb.rest) == [31]          # the lone one, order preserved
        # Groups keep first-appearance order, and each group's lanes keep the
        # entries' original order — a backend's scatter is aligned by position.
        @test sb.groups[1].slots == [11, 12, 13]
        @test sb.groups[2].slots == [21, 22]

        # Grouping off: no groups, and `rest` is the surface verbatim.
        off = _SB_ESS._with_compiler_plan(
            _SB_ESS._compiler_plan(:interpreter)) do
            _SB_ESS._oop_batch_scalars(entries)
        end
        @test isempty(off.groups)
        @test off.n_batched == 0
        @test first.(off.rest) == first.(entries)

        # A one-entry surface has nothing to group, and says so the same way.
        one = _SB_ESS._oop_batch_scalars(entries[1:1])
        @test isempty(one.groups) && one.n_batched == 0 && length(one.rest) == 1
    end
end
