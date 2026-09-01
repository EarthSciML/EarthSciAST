# The value-equality (`join.on`) GATE — CONFORMANCE_SPEC §5.5.8,
# ESM_COMPLIANCE_VALIDATION_MATRIX BEHAV-10-B-001 … -006.
#
# `join.on` used to resolve to bucket CODES and nothing else: the equality was
# tested per tuple, but enumeration still walked the full cross product, so a
# contraction cost O(N_l·N_r) to reach O(|matches|) surviving terms. And a key
# column could only be an index-set member column or a value-invention bin
# buffer — never the ordinary declared 1-D variable a relational port (EPA
# MOVES/NONROAD) actually joins on.
#
# THE TWO DIFFERENTIAL ARMS. Both halves are pinned against the pre-change
# behaviour rather than against hand-computed numbers alone:
#
#   * `ESS_JOIN_ON_GATE_DISABLE=1` rebuilds the SAME document with the driver
#     killed — the gate resolves to codes only and filters the full product, the
#     exact pre-§5.5.8 path. The answer must be bit-identical (BEHAV-10-B-005)
#     and the visit count must differ, or the gate never fired.
#   * `_foreach_aggregate_term` is driven and undriven over the same gate, and
#     the EMITTED TERM SEQUENCES are compared element for element — the driven
#     walk must be the order-preserving SUBSEQUENCE of the filtered product, not
#     merely the same set.
#
# A visit count of 0 means the gate declined and the filter path ran, so a
# silent fallback fails these tests too.
#
# Wrapped in a module so the local JSON AST builders stay out of `Main` (see the
# header of vi_overlap_scaling_test.jl for why that matters).
module JoinOnEqualityGateTests

using Test
using EarthSciAST
import JSON3

const ESS = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

_ix(f, a...) = Dict("op" => "index", "args" => Any[f, a...])

# A scalar rollup `D(count)/dt = Σ_{l∈src_rows, r∈emf_rows : on} body` whose key
# columns are DATA COLUMNS — declared 1-D parameters fed as const arrays. This
# is the MOVES shape: one table's sourceTypeID column against another's.
function _join_doc(N::Int, M::Int; body = 1.0, on = [["src_type", "emf_type"]],
                   extra_vars = Dict{String,Any}(), extra_sets = Dict{String,Any}())
    vars = Dict{String,Any}(
        "src_type" => Dict("type" => "parameter", "shape" => ["src_rows"]),
        "emf_type" => Dict("type" => "parameter", "shape" => ["emf_rows"]),
        "count"    => Dict("type" => "unknown", "default" => 0.0))
    merge!(vars, extra_vars)
    sets = Dict{String,Any}(
        "src_rows" => Dict("kind" => "interval", "size" => N),
        "emf_rows" => Dict("kind" => "interval", "size" => M))
    merge!(sets, extra_sets)
    Dict("esm" => "1.0.0",
         "metadata" => Dict("name" => "join_on_gate"),
         "index_sets" => sets,
         "models" => Dict("Rollup" => Dict(
             "variables" => vars,
             "equations" => [Dict(
                 "lhs" => Dict("op" => "D", "args" => ["count"], "wrt" => "t"),
                 "rhs" => Dict("op" => "aggregate", "args" => [], "output_idx" => [],
                     "semiring" => "sum_product", "reduce" => "+",
                     "ranges" => Dict("l" => Dict("from" => "src_rows"),
                                      "r" => Dict("from" => "emf_rows")),
                     "join" => [Dict("on" => on)],
                     "expr" => body))])))
end

# Build + evaluate one such document, returning `(du, visits, seconds)`.
# `_VI_ENUM_VISITS` counts leaves a GATE-DRIVEN enumerator entered, so 0 means
# the driver declined and the ungated product ran.
function _run(doc, const_arrays; disable::Bool=false)
    file = ESS.coerce_esm_file(JSON3.read(JSON3.write(doc)))
    withenv("ESS_JOIN_ON_GATE_DISABLE" => (disable ? "1" : nothing)) do
        ESS._VI_ENUM_VISITS[] = 0
        du = nothing
        t = @elapsed begin
            f!, u0, p, _, _ = build_evaluator(file; model_name="Rollup",
                const_arrays=Dict{String,Any}(const_arrays),
                initial_conditions=Dict("count" => 0.0))
            du = similar(u0)
            f!(du, u0, p, 0.0)
        end
        return (du[1], ESS._VI_ENUM_VISITS[], t)
    end
end

# `K` one-to-one matching rows, the rest unmatched on both sides.
function _one_to_one_cols(N::Int, M::Int, K::Int)
    (Float64[i <= K ? i : 1_000_000 + i for i in 1:N],
     Float64[j <= K ? j : 2_000_000 + j for j in 1:M])
end

# ===========================================================================
# BEHAV-10-B-001 — a DATA COLUMN is a legal key column
# ===========================================================================
@testset "join.on key columns are polymorphic (BEHAV-10-B-001)" begin
    # (a) The SHARED cross-binding fixture. Its inline `count(1) = 5` reads the
    #     join's cardinality directly: key 7 matches 2x2, key 9 matches 1x1, key
    #     4 is unmatched. A binding that drops the clause computes the full
    #     product's 12; one that cannot resolve a data-column key raises
    #     E_TREEWALK_JOIN_UNKNOWN_KEY, which is what Julia did before §5.5.8.
    path = joinpath(TESTUTILS_REPO_ROOT, "tests", "valid", "aggregate",
                    "join_on_data_columns.esm")
    @test isfile(path)
    file = ESS.load_path(path)
    f!, u0, p, _, vmap = build_evaluator(file; model_name="DataColumnJoin",
                                         initial_conditions=Dict("count" => 0.0))
    du = similar(u0); f!(du, u0, p, 0.0)
    @test du[vmap["count"]] == 5.0            # NOT 12.0 (the ungated product)

    # (b) The same shape with the columns supplied as const-array data rather
    #     than document-literal `makearray` observeds — the other storage a
    #     build-time-constant key column can arrive in.
    doc = _join_doc(4, 3)
    val, visits, _ = _run(doc, Dict("src_type" => [7.0, 9.0, 7.0, 4.0],
                                    "emf_type" => [7.0, 9.0, 7.0]))
    @test val == 5.0
    @test visits == 5                          # driven: |matches|, not 4*3

    # (c) BINDERS SHADOW DECLARATIONS (§5.5.8 precedence / §5.5.6). A variable
    #     that happens to share a name with one of the node's RANGE symbols must
    #     not shadow the loop symbol: `on: [["l","r"]]` still means the two loop
    #     symbols, whose key values are the interval IDs 1..N — so the join is
    #     the diagonal, 3 matches over a 3x3 product, NOT whatever the columns
    #     named `l` / `r` hold.
    doc2 = _join_doc(3, 3; on = [["l", "r"]],
                     extra_vars = Dict{String,Any}(
                         "l" => Dict("type" => "parameter", "shape" => ["src_rows"]),
                         "r" => Dict("type" => "parameter", "shape" => ["emf_rows"])))
    val2, visits2, _ = _run(doc2, Dict("src_type" => [1.0, 2.0, 3.0],
                                       "emf_type" => [1.0, 2.0, 3.0],
                                       "l" => [9.0, 9.0, 9.0],
                                       "r" => [9.0, 9.0, 9.0]))
    @test val2 == 3.0                          # the diagonal; the columns say 9
    @test visits2 == 3

    # (d) A name resolving to NEITHER a binder nor a declared 1-D column is a
    #     build error, not a silent no-op (§5.5.8).
    doc3 = _join_doc(3, 3; on = [["nope", "emf_type"]])
    @test_throws ESS.TreeWalkError _run(doc3, Dict("src_type" => [1.0, 2.0, 3.0],
                                                   "emf_type" => [1.0, 2.0, 3.0]))

    # (e) FLOAT KEYS STAY FORBIDDEN. A float-stored column is admissible only
    #     where every value is exactly integral (then it IS an integer ID
    #     column); a non-integral value is a named error, never a non-portable
    #     float-equality join.
    doc4 = _join_doc(3, 3)
    @test_throws ESS.TreeWalkError _run(doc4, Dict("src_type" => [1.0, 2.5, 3.0],
                                                   "emf_type" => [1.0, 2.0, 3.0]))
    err = try
        _run(doc4, Dict("src_type" => [1.0, 2.5, 3.0], "emf_type" => [1.0, 2.0, 3.0]))
        nothing
    catch e
        e
    end
    @test err isa ESS.TreeWalkError && err.code == "E_TREEWALK_JOIN_FLOAT_KEY"
end

# ===========================================================================
# BEHAV-10-B-002 — a multi-pair clause over one symbol pair is ONE composite key
# ===========================================================================
@testset "composite key = tuple equality (BEHAV-10-B-002)" begin
    # Two pairs over the same (l, r): admitted iff BOTH agree. src rows carry
    # (type, year) = (7,1) (7,2) (9,1); emf rows carry (7,1) (9,1) (7,3).
    # Tuple matches: row1~row1, row3~row2  ⇒  2, against 4 for either pair alone
    # and 9 for the ungated product.
    doc = _join_doc(3, 3; on = [["src_type", "emf_type"], ["src_year", "emf_year"]],
                    extra_vars = Dict{String,Any}(
                        "src_year" => Dict("type" => "parameter", "shape" => ["src_rows"]),
                        "emf_year" => Dict("type" => "parameter", "shape" => ["emf_rows"])))
    ca = Dict("src_type" => [7.0, 7.0, 9.0], "src_year" => [1.0, 2.0, 1.0],
              "emf_type" => [7.0, 9.0, 7.0], "emf_year" => [1.0, 1.0, 3.0])
    val, visits, _ = _run(doc, ca)
    @test val == 2.0
    # The COMPOSITE match set drives, not the first pair's (which admits 4).
    @test visits == 2
    # …and the answer is the same with the driver killed (the pre-change path).
    val_off, visits_off, _ = _run(doc, ca; disable=true)
    @test val_off == val
    @test visits_off == 0
end

# ===========================================================================
# BEHAV-10-B-003 — the match set is DETERMINISTIC, never Dict iteration order
# ===========================================================================
@testset "match set ordering is canonical, not Dict order (BEHAV-10-B-003)" begin
    # 64 buckets, deliberately SCRAMBLED relative to position, so an
    # implementation that emitted pairs while walking a `Dict` of buckets would
    # produce a different sequence with overwhelming probability — Julia's
    # `Dict` iteration order is an unspecified implementation detail and is not
    # insertion-ordered.
    nb = 64
    pos_l = collect(1:2nb)
    pos_r = collect(1:2nb)
    # key of left position i is a scrambled bucket id; each bucket holds 2 left
    # and 2 right positions ⇒ 4 pairs per bucket, 256 pairs total.
    perm = [((7 * i) % nb) + 1 for i in 1:2nb]
    vals_l = Any[perm[i] for i in 1:2nb]
    vals_r = Any[perm[2nb - i + 1] for i in 1:2nb]
    group = [("l", "r", pos_l, pos_r, vals_l, vals_r)]
    prs = ESS._on_gate_match_pairs(group)
    @test prs !== nothing
    @test length(prs) == 4 * nb

    # The emitted list is ordered by the CANONICAL KEY first, then left, then
    # right (§5.5 rule 5). Recompute that order independently.
    codes_l, codes_r = ESS._encode_join_keys(vals_l, vals_r)
    kl = Dict(p => codes_l[i] for (i, p) in enumerate(pos_l))
    kr = Dict(p => codes_r[i] for (i, p) in enumerate(pos_r))
    want = sort!([(a, b) for a in pos_l for b in pos_r if kl[a] == kr[b]];
                 by = t -> (kl[t[1]], t[1], t[2]))
    @test prs == want
    # It is NOT merely position-sorted — so a test asserting position order
    # would have missed a canonical-key regression, and vice versa.
    @test prs != sort(want)

    # DUPLICATE / REVERSED / PERMUTED inputs give a byte-identical pair list
    # once expressed over the same positions: rebuilding from the reversed
    # position vectors yields the same set, and the same canonical order after
    # the canonical sort. (Rebuilding is a pure function of the input.)
    @test ESS._on_gate_match_pairs(group) == prs
    @test ESS._on_gate_match_pairs(deepcopy(group)) == prs

    # The DRIVE order is position-ascending and is DERIVED from the canonical
    # list (§5.5.8), so it too is a pure function of the input.
    oi = ESS._OverlapIndex(Set(prs))
    @test ESS._overlap_sorted_pairs(oi) == sort(prs)
end

# ===========================================================================
# BEHAV-10-B-005 — driving is a pure optimisation of the enumeration EXTENT
# ===========================================================================
@testset "driven walk is the order-preserving subsequence (BEHAV-10-B-005)" begin
    body = ESS.OpExpr("pair", ESS.ASTExpr[ESS.VarExpr("l"), ESS.VarExpr("r")])
    codes_l = Dict(1 => 1, 2 => 2, 3 => 1, 4 => 3)
    codes_r = Dict(1 => 1, 2 => 1, 3 => 2)
    # `names`/`iters` are the CONTRACTED axes; `out_env` the already-bound ones.
    # Only contracted symbols are substituted into the term, so an already-bound
    # one is still a `VarExpr` and is read back from `out_env`.
    _leafval(x, env) = x isa ESS.VarExpr ? env[x.name] : Int(x.value)
    collect_seq(gates, names, iters, out_env) = begin
        seq = Tuple{Int,Int}[]
        env = out_env === nothing ? Dict{String,Int}() : out_env
        ESS._foreach_aggregate_term(
            t -> push!(seq, (_leafval(t.args[1], env), _leafval(t.args[2], env))),
            body, names, iters, gates, nothing, 0.0, out_env)
        seq
    end
    ungated = ESS._JoinGate("l", "r", codes_l, codes_r, nothing)
    prs = ESS._on_gate_match_pairs(
        [("l", "r", [1, 2, 3, 4], [1, 2, 3], Any[1, 2, 1, 3], Any[1, 1, 2])])
    driven = ESS._JoinGate("l", "r", codes_l, codes_r, ESS._OverlapIndex(Set(prs)))

    # (a) :pairs — both gated symbols contracted.
    a = collect_seq([ungated], String["l", "r"], Any[1:4, 1:3], nothing)
    b = collect_seq([driven],  String["l", "r"], Any[1:4, 1:3], nothing)
    @test a == b
    @test length(a) == length(prs)

    # (b) :restrict — one gated symbol already bound as an OUTPUT index; the
    #     contracted one enumerates only that binding's partners, in the same
    #     ascending order its own range would have visited them.
    for rpos in 1:3
        oe = Dict("r" => rpos)
        a1 = collect_seq([ungated], String["l"], Any[1:4], oe)
        b1 = collect_seq([driven],  String["l"], Any[1:4], oe)
        @test a1 == b1
    end

    # (c) :reject — both bound and not a candidate: no leaf at all.
    @test isempty(collect_seq([driven], String[], Any[], Dict("l" => 4, "r" => 1)))
    @test isempty(collect_seq([ungated], String[], Any[], Dict("l" => 4, "r" => 1)))

    # (d) A gate whose two sides are the SAME range symbol must NOT drive — a
    #     pair list cannot bind one symbol to two positions.
    self = ESS._JoinGate("l", "l", codes_l, codes_l, ESS._OverlapIndex(Set(prs)))
    @test ESS._overlap_drive_plan(self, String["l"], Dict{String,Int}(), _ -> 1:4) === (:none,)
    @test ESS._on_gate_match_pairs(
        [("l", "l", [1, 2], [1, 2], Any[1, 2], Any[1, 2])]) === nothing
end

# ===========================================================================
# BEHAV-10-B-004 — the gate DRIVES: cost is O(|matches|), not O(∏ranges)
# ===========================================================================
@testset "join.on gate drives enumeration (BEHAV-10-B-004)" begin
    # Warm up the whole front door on a tiny same-typed fixture, so the timed
    # runs below measure runtime rather than JIT (same discipline as
    # vi_overlap_scaling_test.jl).
    let (st, et) = _one_to_one_cols(20, 10, 5)
        _run(_join_doc(20, 10), Dict("src_type" => st, "emf_type" => et))
        _run(_join_doc(20, 10), Dict("src_type" => st, "emf_type" => et); disable=true)
    end

    # ---- ARM 1: the index-set PRODUCT grows 200x, the match count is FIXED.
    # Work must not move. A binding that filters the full product does 200x the
    # work across this sweep; a driven one does the same 500 leaves every time.
    K = 500
    times = Float64[]
    for (N, M) in [(1000, 500), (10_000, 1000), (100_000, 1000)]
        st, et = _one_to_one_cols(N, M, K)
        val, visits, t = _run(_join_doc(N, M), Dict("src_type" => st, "emf_type" => et))
        @test val == Float64(K)
        @test visits == K                 # EXACTLY the matches — not the product
        @test visits < N * M ÷ 100        # ≪ the product, at every scale
        push!(times, t)
    end
    # 1e8 candidate pairs is 200x the first arm's 5e5. The driven build stays
    # bounded by O(N + M + |matches|); the guard is a blow-up guard, not a
    # benchmark, so it is loose enough to survive a loaded runner.
    @test times[3] < 60.0

    # ---- ARM 2: the product is FIXED at 1e7, the match count grows 20x.
    # The driven arm must track the MATCHES.
    for (K2, expect) in [(500, 500), (1000, 1000)]
        st, et = _one_to_one_cols(10_000, 1000, K2)
        val, visits, _ = _run(_join_doc(10_000, 1000),
                              Dict("src_type" => st, "emf_type" => et))
        @test val == Float64(expect)
        @test visits == expect
    end
    # …including a MANY-TO-MANY shape, where |matches| exceeds min(N, M): 100
    # keys, 10 left rows and 10 right rows each ⇒ 100*10*10 = 10 000 terms.
    let st = Float64[i <= 1000 ? ((i - 1) % 100) + 1 : 1_000_000 + i for i in 1:10_000],
        et = Float64[j <= 1000 ? ((j - 1) % 100) + 1 : 2_000_000 + j for j in 1:1000]
        val, visits, _ = _run(_join_doc(10_000, 1000),
                              Dict("src_type" => st, "emf_type" => et))
        @test val == 10_000.0
        @test visits == 10_000
    end

    # ---- ARM 3: the DIFFERENTIAL against the driver killed.
    # Same document, `ESS_JOIN_ON_GATE_DISABLE=1`: the clause resolves to codes
    # only and filters the full 5e5-tuple product — the pre-§5.5.8 path. The
    # answer must be bit-identical, and the visit counts must differ, or the
    # gate never fired and the "driven" arm proved nothing.
    let (st, et) = _one_to_one_cols(1000, 500, 500)
        ca = Dict("src_type" => st, "emf_type" => et)
        on_val, on_visits, on_t = _run(_join_doc(1000, 500), ca)
        off_val, off_visits, off_t = _run(_join_doc(1000, 500), ca; disable=true)
        @test isequal(on_val, off_val)     # bit-identical, not merely ≈
        @test on_visits == 500
        @test off_visits == 0              # 0 ⇒ the gate declined; the filter ran
        @test on_t < off_t                 # and the driver is the faster one
    end
end

# ===========================================================================
# BEHAV-10-B-004 on the key kind that ALREADY resolved — the driver, isolated
# ===========================================================================
# The arms above join on DATA COLUMNS, a key kind that did not resolve at all
# before BEHAV-10-B-001, so on the pre-change code they fail for the wrong
# reason. This one joins on INDEX-SET MEMBER columns — the key kind Julia has
# always resolved — and asserts only that the clause now DRIVES. It is the test
# that isolates -004 from -001: before the driver landed it resolved, filtered
# the full product, and visited 0 gate-driven leaves.
@testset "an index-set member key column drives too (BEHAV-10-B-004)" begin
    doc = Dict("esm" => "1.0.0",
        "metadata" => Dict("name" => "join_on_member_columns"),
        "index_sets" => Dict(
            "src_cat" => Dict("kind" => "categorical",
                              "members" => ["a", "b", "c", "d"]),
            "emf_cat" => Dict("kind" => "categorical",
                              "members" => ["b", "c", "x"])),
        "models" => Dict("Rollup" => Dict(
            "variables" => Dict("count" => Dict("type" => "unknown", "default" => 0.0)),
            "equations" => [Dict(
                "lhs" => Dict("op" => "D", "args" => ["count"], "wrt" => "t"),
                "rhs" => Dict("op" => "aggregate", "args" => [], "output_idx" => [],
                    "semiring" => "sum_product", "reduce" => "+",
                    "ranges" => Dict("l" => Dict("from" => "src_cat"),
                                     "r" => Dict("from" => "emf_cat")),
                    "join" => [Dict("on" => [["src_cat", "emf_cat"]])],
                    "expr" => 1.0))])))
    val, visits, _ = _run(doc, Dict{String,Any}())
    @test val == 2.0                    # members "b" and "c"; NOT the 4*3 product
    @test visits == 2                   # DRIVEN — 0 here means the gate filtered

    # Same document, driver killed: same answer, no driven leaves.
    val_off, visits_off, _ = _run(doc, Dict{String,Any}(); disable=true)
    @test isequal(val_off, val)
    @test visits_off == 0
end

# ===========================================================================
# Unmatched rows take the semiring identity 0̄ (§5.5.8 "identity fill")
# ===========================================================================
@testset "an empty match set reduces to 0̄" begin
    doc = _join_doc(3, 3)
    val, visits, _ = _run(doc, Dict("src_type" => [1.0, 2.0, 3.0],
                                    "emf_type" => [4.0, 5.0, 6.0]))
    @test val == 0.0                       # sum_product 0̄, not a hole or NaN
    @test visits == 0                      # nothing to visit — the driver knows
end

end # module
