# Tests for M2 value-equality joins + filter predicates (ess-my4.2.2).
#
# `join.on` (RFC semiring-faq-unified-ir §5.3) is an inner equi-join that gates
# which (output × contracted) index combinations of an aggregate contribute a
# ⊗-product term: a term contributes iff every key-column pair of every clause
# holds the same key value. `filter` (§7.2) shares the gate as a runtime boolean
# predicate. Both resolve at build time — the join into a structural drop of
# non-matching terms, the filter into an `ifelse(pred, term, 0̄)` guard — so the
# compiled `_Node` for a degenerate / positional join is byte-identical to the
# join-free node.
#
# Semantics (FIXED, §5.3): inner-only; many-to-many = m·n terms; key types
# int / categorical only (floats / nulls rejected at build); unmatched → 0̄;
# output in DECLARED index order (permutation-invariant value). These mirror the
# Python reference suite tests/test_numpy_interpreter_join.py (ess-my4.2.4) so the
# two bindings agree value-for-value.
#
# RFC: docs/content/rfcs/semiring-faq-unified-ir.md §5.3 / §5.7 / §7.2.

using Test
using EarthSciAST
using JSON3

const ESMJ = EarthSciAST

@testset "tree_walk join.on + filter (ess-my4.2.2)" begin
    # ---- Helpers (scoped to this testset) -----------------------------------
    _v(n)  = VarExpr(String(n))
    _n(x)  = NumExpr(Float64(x))
    _i(x)  = IntExpr(Int64(x))
    _op(op, args...; kw...) = OpExpr(String(op), ESMJ.Expr[args...]; kw...)
    _idx(var, ix...)  = _op("index", _v(var), [_v(String(s)) for s in ix]...)
    _Didx(var, ix...) = _op("D", _idx(var, ix...); wrt="t")
    _R(s) = ESMJ.IndexSetRef(String(s))

    # A scalar aggregate `D(u) = aggregate(...)`; returns du[u] given index sets
    # and keyed-factor const arrays.
    function scalar_du(; semiring=nothing, reduce=nothing, body, ranges,
                       join=nothing, filter=nothing, index_sets, const_arrays=Dict{String,Vector{Float64}}())
        rhs = _op("aggregate"; output_idx=Any[], semiring=semiring, reduce=reduce,
                  expr_body=body, ranges=ranges, join=join, filter=filter)
        model = ESMJ.Model(Dict("u" => ModelVariable(StateVariable)),
                           [ESMJ.Equation(_op("D", _v("u"); wrt="t"), rhs)])
        f!, u0, p, _, vmap = build_evaluator(model; index_sets=index_sets,
                                             const_arrays=const_arrays)
        du = similar(u0); f!(du, u0, p, 0.0)
        return du[vmap["u"]]
    end

    # ---- Degenerate / positional join → byte-identical to the join-free node --
    @testset "degenerate join is byte-identical to no-join" begin
        isets = Dict("sourceType" => ESMJ.IndexSet("categorical"; members=["onroad", "nonroad"]))
        body  = _op("*", _idx("activity", "src"), _idx("base_rate", "src"))
        ca    = Dict("activity" => [10.0, 20.0], "base_rate" => [3.0, 5.0])
        no_join  = scalar_du(; semiring="sum_product", body=body,
                             ranges=Dict("src" => _R("sourceType")),
                             index_sets=isets, const_arrays=ca)
        deg_join = scalar_du(; semiring="sum_product", body=body,
                             ranges=Dict("src" => _R("sourceType")),
                             join=Any[[("src", "sourceType")]],
                             index_sets=isets, const_arrays=ca)
        @test deg_join == 10.0 * 3.0 + 20.0 * 5.0
        # Same float bit-pattern — the degenerate join keeps every term in order.
        @test reinterpret(UInt64, deg_join) == reinterpret(UInt64, no_join)
    end

    @testset "join key may name the index set or the symbol" begin
        ca = Dict("w" => [1.0 2.0; 3.0 4.0])
        # Symbol form: both symbols draw from `county`, joined i==j → diagonal.
        by_sym = scalar_du(; semiring="sum_product", body=_idx("w", "i", "j"),
                           ranges=Dict("i" => _R("county"), "j" => _R("county")),
                           join=Any[[("i", "j")]],
                           index_sets=Dict("county" => ESMJ.IndexSet("categorical"; members=["A", "B"])),
                           const_arrays=ca)
        @test by_sym == 1.0 + 4.0
        # Set form: each set is bound by exactly one symbol, so naming the set is
        # sugar for naming its symbol — `[["L","Rt"]]` ≡ `[["i","j"]]`.
        isets2 = Dict("L"  => ESMJ.IndexSet("categorical"; members=["A", "B"]),
                      "Rt" => ESMJ.IndexSet("categorical"; members=["A", "B"]))
        by_set = scalar_du(; semiring="sum_product", body=_idx("w", "i", "j"),
                           ranges=Dict("i" => _R("L"), "j" => _R("Rt")),
                           join=Any[[("L", "Rt")]], index_sets=isets2, const_arrays=ca)
        by_symr = scalar_du(; semiring="sum_product", body=_idx("w", "i", "j"),
                            ranges=Dict("i" => _R("L"), "j" => _R("Rt")),
                            join=Any[[("i", "j")]], index_sets=isets2, const_arrays=ca)
        @test by_set == by_symr == 1.0 + 4.0
    end

    # ---- Inner equi-join semantics + cardinality (m·n) ----------------------
    @testset "inner equi-join is diagonal over shared keys" begin
        isets = Dict("county" => ESMJ.IndexSet("categorical"; members=["A", "B", "C"]))
        w = [1.0 9.0 9.0; 9.0 2.0 9.0; 9.0 9.0 3.0]
        @test scalar_du(; semiring="sum_product", body=_idx("w", "i", "j"),
                        ranges=Dict("i" => _R("county"), "j" => _R("county")),
                        join=Any[[("i", "j")]], index_sets=isets,
                        const_arrays=Dict("w" => w)) == 6.0
    end

    @testset "many-to-many cardinality is defined (m·n terms)" begin
        isets = Dict("A" => ESMJ.IndexSet("categorical"; members=["x", "y", "y"]),
                     "B" => ESMJ.IndexSet("categorical"; members=["y", "y"]))
        # 'y' matches 'y': 2 (left) × 2 (right) = 4 unit terms; 'x' matches nothing.
        @test scalar_du(; reduce="+", body=_idx("one", "i", "j"),
                        ranges=Dict("i" => _R("A"), "j" => _R("B")),
                        join=Any[[("i", "j")]], index_sets=isets,
                        const_arrays=Dict("one" => ones(3, 2))) == 4.0
    end

    @testset "multiple clauses and pairs are all ANDed" begin
        isets = Dict("s" => ESMJ.IndexSet("categorical"; members=["p", "q"]),
                     "f" => ESMJ.IndexSet("categorical"; members=["p", "q"]))
        # {i==j} ∩ {k==l} = 2·2 = 4 (an OR would admit 12 of 16).
        @test scalar_du(; reduce="+", body=_n(1.0),
                        ranges=Dict("i" => _R("s"), "j" => _R("s"),
                                    "k" => _R("f"), "l" => _R("f")),
                        join=Any[[("i", "j")], [("k", "l")]],
                        index_sets=isets) == 4.0
    end

    @testset "join across two distinct categorical sets matches by value" begin
        isets = Dict("left"  => ESMJ.IndexSet("categorical"; members=["a", "b", "c"]),
                     "right" => ESMJ.IndexSet("categorical"; members=["b", "c", "d"]))
        # matches are (b,b) and (c,c) → 2 terms.
        @test scalar_du(; reduce="+", body=_idx("one", "i", "j"),
                        ranges=Dict("i" => _R("left"), "j" => _R("right")),
                        join=Any[[("i", "j")]], index_sets=isets,
                        const_arrays=Dict("one" => ones(3, 3))) == 2.0
    end

    # ---- Unmatched → additive identity 0̄ (per semiring) ---------------------
    @testset "no match contributes the semiring identity 0̄" begin
        isets = Dict("A" => ESMJ.IndexSet("categorical"; members=["x"]),
                     "B" => ESMJ.IndexSet("categorical"; members=["y"]))
        for (sr, expected) in (("sum_product", 0.0), ("max_product", -Inf),
                               ("min_sum", Inf), ("max_sum", -Inf))
            @test scalar_du(; semiring=sr, body=_idx("one", "i", "j"),
                            ranges=Dict("i" => _R("A"), "j" => _R("B")),
                            join=Any[[("i", "j")]], index_sets=isets,
                            const_arrays=Dict("one" => ones(1, 1))) == expected
        end
    end

    @testset "partial match leaves unmatched output cells at identity (array output)" begin
        # out[i] = Σ_k v[i,k] where member(i)==member(k). i=A matches k=A; i=B none.
        isets = Dict("out" => ESMJ.IndexSet("categorical"; members=["A", "B"]),
                     "k"   => ESMJ.IndexSet("categorical"; members=["A", "C"]))
        lhs = _op("aggregate"; output_idx=Any["i"], expr_body=_Didx("o", "i"),
                  ranges=Dict("i" => _R("out")))
        rhs = _op("aggregate"; output_idx=Any["i"], semiring="sum_product",
                  expr_body=_idx("v", "i", "k"),
                  ranges=Dict("i" => _R("out"), "k" => _R("k")),
                  join=Any[[("i", "k")]])
        model = ESMJ.Model(Dict("o" => ModelVariable(StateVariable)),
                           [ESMJ.Equation(lhs, rhs)])
        f!, u0, p, _, vmap = build_evaluator(model; index_sets=isets,
                                             const_arrays=Dict("v" => [5.0 7.0; 8.0 9.0]))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["o[1]"]] == 5.0
        @test du[vmap["o[2]"]] == 0.0
    end

    @testset "interval index sets equi-join on their integer index value" begin
        isets = Dict("n" => ESMJ.IndexSet("interval"; size=3))
        w = [1.0 0.0 0.0; 0.0 2.0 0.0; 0.0 0.0 3.0]
        @test scalar_du(; semiring="sum_product", body=_idx("w", "i", "j"),
                        ranges=Dict("i" => _R("n"), "j" => _R("n")),
                        join=Any[[("i", "j")]], index_sets=isets,
                        const_arrays=Dict("w" => w)) == 6.0
    end

    # ---- Key-type rejection (build-time errors) -----------------------------
    @testset "float join key is rejected" begin
        isets = Dict("A" => ESMJ.IndexSet("categorical";
                     members=["1.5", "2.5"], members_raw=Any[1.5, 2.5]))
        @test_throws ESMJ.TreeWalkError scalar_du(; semiring="sum_product",
            body=_idx("a", "i"), ranges=Dict("i" => _R("A"), "j" => _R("A")),
            join=Any[[("i", "j")]], index_sets=isets, const_arrays=Dict("a" => [1.0, 2.0]))
    end

    @testset "null member in a join key column is rejected" begin
        isets = Dict("A" => ESMJ.IndexSet("categorical";
                     members=["x", "nothing"], members_raw=Any["x", nothing]))
        @test_throws ESMJ.TreeWalkError scalar_du(; semiring="sum_product",
            body=_idx("a", "i"), ranges=Dict("i" => _R("A"), "j" => _R("A")),
            join=Any[[("i", "j")]], index_sets=isets, const_arrays=Dict("a" => [1.0, 2.0]))
    end

    @testset "incompatible key types (int vs string) are rejected" begin
        isets = Dict("ints" => ESMJ.IndexSet("interval"; size=2),
                     "strs" => ESMJ.IndexSet("categorical"; members=["a", "b"]))
        @test_throws ESMJ.TreeWalkError scalar_du(; semiring="sum_product",
            body=_idx("one", "i", "j"), ranges=Dict("i" => _R("ints"), "j" => _R("strs")),
            join=Any[[("i", "j")]], index_sets=isets, const_arrays=Dict("one" => ones(2, 2)))
    end

    @testset "ambiguous index-set key (set bound by >1 symbol) is rejected" begin
        isets = Dict("county" => ESMJ.IndexSet("categorical"; members=["A", "B"]))
        @test_throws ESMJ.TreeWalkError scalar_du(; semiring="sum_product",
            body=_idx("w", "i", "j"), ranges=Dict("i" => _R("county"), "j" => _R("county")),
            join=Any[[("county", "i")]], index_sets=isets, const_arrays=Dict("w" => ones(2, 2)))
    end

    @testset "unknown join key (neither symbol nor bound set) is rejected" begin
        isets = Dict("county" => ESMJ.IndexSet("categorical"; members=["A", "B"]))
        @test_throws ESMJ.TreeWalkError scalar_du(; semiring="sum_product",
            body=_idx("w", "i", "j"), ranges=Dict("i" => _R("county"), "j" => _R("county")),
            join=Any[[("i", "nope")]], index_sets=isets, const_arrays=Dict("w" => ones(2, 2)))
    end

    # ---- Determinism — output is order-independent (§5.7 rule 5) -------------
    @testset "join value is independent of declared member order" begin
        diag = Dict("A" => 1.0, "B" => 2.0, "C" => 3.0)
        function diagonal_sum(order)
            n = length(order)
            w = fill(99.0, n, n)
            for (p, m) in enumerate(order); w[p, p] = diag[m]; end
            scalar_du(; semiring="sum_product", body=_idx("w", "i", "j"),
                      ranges=Dict("i" => _R("county"), "j" => _R("county")),
                      join=Any[[("i", "j")]],
                      index_sets=Dict("county" => ESMJ.IndexSet("categorical"; members=order)),
                      const_arrays=Dict("w" => w))
        end
        base = diagonal_sum(["A", "B", "C"])
        @test base == 6.0
        for perm in (["C", "A", "B"], ["B", "C", "A"], ["C", "B", "A"])
            @test diagonal_sum(perm) == base
        end
    end

    @testset "cross-set join value is permutation-invariant" begin
        function matched_count(left, right)
            scalar_du(; reduce="+", body=_idx("one", "i", "j"),
                      ranges=Dict("i" => _R("L"), "j" => _R("R")),
                      join=Any[[("i", "j")]],
                      index_sets=Dict("L" => ESMJ.IndexSet("categorical"; members=left),
                                      "R" => ESMJ.IndexSet("categorical"; members=right)),
                      const_arrays=Dict("one" => ones(length(left), length(right))))
        end
        base = matched_count(["a", "b", "c"], ["b", "c", "d"])
        @test base == 2.0
        @test matched_count(["c", "a", "b"], ["d", "c", "b"]) == base
        @test matched_count(["b", "c", "a"], ["c", "b", "d"]) == base
    end

    # ---- Filter predicates (§7.2) — share the gating machinery --------------
    @testset "filter drops combinations where the predicate is false" begin
        isets = Dict("sourceType" => ESMJ.IndexSet("categorical"; members=["onroad", "nonroad"]))
        body  = _op("*", _idx("activity", "src"), _idx("base_rate", "src"))
        filt  = _op(">", _idx("base_rate", "src"), _i(0))
        # src=2 (base_rate<0) dropped → only 10·3 contributes.
        @test scalar_du(; semiring="sum_product", body=body,
                        ranges=Dict("src" => _R("sourceType")), filter=filt,
                        index_sets=isets,
                        const_arrays=Dict("activity" => [10.0, 20.0], "base_rate" => [3.0, -1.0])) == 30.0
    end

    @testset "filter rejecting every combination returns 0̄" begin
        isets = Dict("c" => ESMJ.IndexSet("interval"; size=3))
        filt  = _op(">", _idx("a", "i"), _n(100.0))
        @test scalar_du(; semiring="sum_product", body=_idx("a", "i"),
                        ranges=Dict("i" => _R("c")), filter=filt, index_sets=isets,
                        const_arrays=Dict("a" => [1.0, 2.0, 3.0])) == 0.0
    end

    @testset "a node may carry both a join and a filter; both gates apply" begin
        isets = Dict("county" => ESMJ.IndexSet("categorical"; members=["A", "B"]))
        body  = _idx("w", "i", "j")
        filt  = _op(">", body, _i(1))
        # diagonal = {1, 5}; filter>1 keeps only 5.
        @test scalar_du(; semiring="sum_product", body=body,
                        ranges=Dict("i" => _R("county"), "j" => _R("county")),
                        join=Any[[("i", "j")]], filter=filt, index_sets=isets,
                        const_arrays=Dict("w" => [1.0 0.0; 0.0 5.0])) == 5.0
    end

    # ---- arrayop alias + the canonical ESI fixture --------------------------
    @testset "the deprecated arrayop tag resolves joins identically" begin
        isets = Dict("county" => ESMJ.IndexSet("categorical"; members=["A", "B"]))
        ca    = Dict("w" => [1.0 2.0; 3.0 4.0])
        common = (; output_idx=Any[], semiring="sum_product", expr_body=_idx("w", "i", "j"),
                  ranges=Dict("i" => _R("county"), "j" => _R("county")), join=Any[[("i", "j")]])
        mk(tag) = ESMJ.Model(Dict("u" => ModelVariable(StateVariable)),
                             [ESMJ.Equation(_op("D", _v("u"); wrt="t"), _op(tag; common...))])
        run1(m) = (r = build_evaluator(m; index_sets=isets, const_arrays=ca); du = similar(r[2]); r[1](du, r[2], r[3], 0.0); du[r[5]["u"]])
        @test run1(mk("arrayop")) == run1(mk("aggregate")) == 1.0 + 4.0
    end

    @testset "canonical join_filter.esm fixture (ESI MOVES contraction) evaluates" begin
        path = joinpath(@__DIR__, "..", "..", "..", "tests", "valid", "aggregate", "join_filter.esm")
        doc  = JSON3.read(read(path, String))
        f!, u0, p, _, vmap = build_evaluator(doc; model_name="EmissionsAggregate",
            const_arrays=Dict("activity" => [10.0, 20.0], "base_rate" => [3.0, 5.0]))
        du = similar(u0); f!(du, u0, p, 0.0)
        k = first(key for key in keys(vmap) if endswith(String(key), "emissions"))
        # Σ_src Σ_fuel activity[src]·base_rate[src] (filter base_rate>0 admits both);
        # the inner fuel sum repeats the src term over fuelType's 2 members.
        @test du[vmap[k]] == (10.0 * 3.0 + 20.0 * 5.0) * 2
    end

    # ---- Round-trip: join / filter survive parse ↔ serialize ----------------
    @testset "join + filter round-trip through parse ↔ serialize" begin
        raw = Dict("op" => "aggregate", "output_idx" => [], "reduce" => "+",
                   "ranges" => Dict("i" => Dict("from" => "s"), "j" => Dict("from" => "s")),
                   "expr" => Dict("op" => "index", "args" => ["w", "i", "j"]),
                   "join" => [Dict("on" => [["i", "j"]])],
                   "filter" => Dict("op" => ">", "args" => [Dict("op" => "index", "args" => ["w", "i", "j"]), 0]))
        parsed = ESMJ.parse_expression(raw)
        @test parsed.join == Any[[("i", "j")]]
        @test parsed.filter !== nothing
        @test parsed.join_gates === nothing   # resolution is a build-path artifact
        ser = ESMJ.serialize_expression(parsed)
        @test ser["join"] == [Dict("on" => [["i", "j"]])]
        @test haskey(ser, "filter")
        # Re-parse the serialized form → structurally identical.
        @test ESMJ.parse_expression(ser).join == parsed.join
    end
end
