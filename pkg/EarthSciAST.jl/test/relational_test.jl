using Test
using EarthSciAST
const R = EarthSciAST.Relational

# Build-time relational engine — the value-invention primitives and the
# cross-binding determinism contract (CONFORMANCE_SPEC.md §5.5 = RFC
# `semiring-faq-unified-ir` §5.7). Golden values are the DuckDB throwaway oracle
# (`SELECT DISTINCT … ORDER BY …`, `dense_rank() OVER (ORDER BY …)`) — DuckDB.jl
# is NOT a dependency (RFC §A.3); the expected outputs are what that oracle would
# return, hand-encoded.

@testset "Relational engine (RFC §5.5 / CONFORMANCE_SPEC §5.5)" begin

    @testset "distinct — sorted set semantics (rules 1, 2)" begin
        @test R.distinct([3, 1, 2, 1, 3]) == [1, 2, 3]
        # output IS sorted order, never first-seen
        @test R.distinct([9, 9, 4, 7, 4]) == [4, 7, 9]
        # tuples lexicographic
        @test R.distinct([(2, 1), (1, 2), (2, 1)]) == [(1, 2), (2, 1)]
        # strings by Unicode code-point / UTF-8 byte order: "B" < "Z" < "a"
        @test R.distinct(["a", "Z", "B", "a"]) == ["B", "Z", "a"]
        @test R.distinct(Int[]) == Int[]
    end

    @testset "equijoin — emit sorted by canonical key (rule 5)" begin
        # connectivity inversion: edges (eid, cell) ⋈ cells (cell, name)
        edges = [(101, 1), (102, 1), (103, 2)]
        cells = [(1, "A"), (2, "B")]
        got = R.equijoin(edges, cells; on_left = e -> e[2], on_right = c -> c[1])
        @test got == [
            ((101, 1), (1, "A")),
            ((102, 1), (1, "A")),
            ((103, 2), (2, "B")),
        ]
        # output independent of input order (permute both sides → same result)
        got2 = R.equijoin(reverse(edges), reverse(cells); on_left = e -> e[2], on_right = c -> c[1])
        @test got2 == got
        # unmatched key drops the row
        @test isempty(R.equijoin([(1, 99)], cells; on_left = e -> e[2], on_right = c -> c[1]))
    end

    @testset "group_aggregate — semiring ⊕, sorted by key (rule 5)" begin
        rows = [(:b, 3), (:a, 1), (:b, 4), (:a, 10), (:c, 5)]
        k(r) = r[1]; v(r) = r[2]
        @test R.group_aggregate(rows; key = k, value = v, op = +) == [:a => 11, :b => 7, :c => 5]
        @test R.group_aggregate(rows; key = k, value = v, op = max) == [:a => 10, :b => 4, :c => 5]
        @test R.group_aggregate(rows; key = k, value = v, op = min) == [:a => 1, :b => 3, :c => 5]
        # order-independent (assoc + comm ⊕)
        @test R.group_aggregate(reverse(rows); key = k, value = v, op = +) ==
            R.group_aggregate(rows; key = k, value = v, op = +)
    end

    @testset "float VALUES allowed, reduced in canonical order (rule 5)" begin
        # keys integer, values float: permuted inputs give the identical float sum
        rows1 = [(1, 0.1), (1, 0.2), (1, 0.3)]
        rows2 = [(1, 0.3), (1, 0.1), (1, 0.2)]   # permuted
        g1 = R.group_aggregate(rows1; key = r -> r[1], value = r -> r[2], op = +)
        g2 = R.group_aggregate(rows2; key = r -> r[1], value = r -> r[2], op = +)
        @test g1 == g2
        # reduce is sequential in canonical (sorted) value order: ((0.1+0.2)+0.3)
        @test g1[1] == (1 => ((0.1 + 0.2) + 0.3))
    end

    @testset "mesh-edge enumeration vs DuckDB oracle + adversarial collapse (§5.5.4)" begin
        # Two triangles sharing edge (2,3); faces → vertex triples.
        faces = [(1, 2, 3), (2, 4, 3)]
        # Undirected edges of a face list as canonical (min, max) tuples.
        ue(a, b) = a <= b ? (a, b) : (b, a)
        edges_of(fs) = reduce(vcat, [[ue(a, b), ue(b, c), ue(c, a)] for (a, b, c) in fs])

        # Golden = DuckDB throwaway oracle output:
        #   SELECT DISTINCT e ORDER BY e
        golden_set = [(1, 2), (1, 3), (2, 3), (2, 4), (3, 4)]
        golden_json = "[[1,2],[1,3],[2,3],[2,4],[3,4]]"

        base = edges_of(faces)
        @test R.distinct(base) == golden_set
        @test R.canonical_index_set_json(base) == golden_json

        # Adversarial variants — all must collapse to the identical canonical output.
        variants = [
            "duplicate edges" => vcat(base, base),
            "reversed faces" => edges_of([(c, b, a) for (a, b, c) in faces]),
            "permuted input" => reverse(base),
            "permuted faces" => edges_of(reverse(faces)),
        ]
        for (name, variant) in variants
            @testset "$name" begin
                @test R.distinct(variant) == golden_set
                @test R.canonical_index_set_json(variant) == golden_json
            end
        end
    end

    @testset "canonical_index_set_json — compact JSON, sorted, escaped (§5.5.3)" begin
        @test R.canonical_index_set_json([3, 1, 2, 1]) == "[1,2,3]"
        @test R.canonical_index_set_json([(2, 1), (1, 2)]) == "[[1,2],[2,1]]"
        @test R.canonical_index_set_json(["a", "B"]) == "[\"B\",\"a\"]"   # codepoint order + JSON-escape
        @test R.canonical_index_set_json(Tuple{Int, Int}[]) == "[]"
    end

    @testset "negative controls (§5.5.4): float keys rejected (rule 1)" begin
        @test_throws R.FloatKeyError R.distinct([1.0, 2.0])
        @test_throws R.FloatKeyError R.distinct([(1, 2.5)])
        @test_throws R.FloatKeyError R.equijoin([(1.0,)], [(1.0,)]; on_left = x -> x[1], on_right = x -> x[1])
        @test_throws R.FloatKeyError R.group_aggregate([(1.5, 2)]; key = r -> r[1], value = r -> r[2], op = +)
        # Bool keys ARE allowed (Bool <: Integer): boolean-or-style grouping
        @test R.group_aggregate(
            [(true, 1), (false, 2), (true, 3)];
            key = r -> r[1], value = r -> r[2], op = +
        ) == [false => 2, true => 4]
    end

end
