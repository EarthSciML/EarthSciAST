# The rank lookup of lib/relational.esm under strict `native` (closed-AST
# phase 4): `rank_of_set(edge_key(...), members, S)` over a derived edge set,
# the template form of the `skolem` / `rank` edge enumeration.
#
#   * A state-free array observed holding the indicator sum is a build-once
#     table: the setup sweep fills it (`_is_setup_count_reduction`), the count
#     as a binary search over a sorted copy of the entries (`:count_fold_setup`,
#     `_geo_count_node`). It gives the interpreter's bits (the interpreter
#     keeps it an observed and folds every term) and the op form's, on the
#     right-hand side and through a gather by the looked-up rank.
#   * The count at setup over constant keys of any content: unsorted, NaN
#     entries, ±0.0, repeated entries, NaN / ±0.0 / ±Inf queries, all four
#     relations with the entry on either side, the swapped branches.
#   * Near misses keep the fold (the table is still filled at setup when the
#     observed holds another count shape, never with the rewrite).
#   * A producer's key and filter over interval ranges are compiled once
#     (`_vi_producer_compiled`): the same members as the reference walk, and a
#     NaN key is still `value_invention_key_out_of_range`.

using Test
include("testutils.jl")

const _RC = EarthSciAST
const _RC_LIB = joinpath(TESTUTILS_REPO_ROOT, "lib")

_rc_op(o, a...; kw...) = Dict{String, Any}("op" => o, "args" => Any[a...], (String(k) => v for (k, v) in kw)...)
_rc_ix(a, s...) = _rc_op("index", a, s...)
_rc_const(v) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => v)
_rc_apply(name; b...) = Dict{String, Any}(
    "op" => "apply_expression_template", "args" => Any[], "name" => name,
    "bindings" => Dict{String, Any}(String(k) => v for (k, v) in b)
)
_rc_faq(e, out, ranges; kw...) = Dict{String, Any}(
    "op" => "faq", "args" => Any[], "output_idx" => Any[out...], "ranges" => ranges,
    "expr" => e, (String(k) => v for (k, v) in kw)...
)
_rc_dlhs(v, out, ranges) = _rc_faq(_rc_op("D", _rc_ix(v, out...); wrt = "t"), out, ranges)

const _RC_NOFOLD = _RC._plan_with(_RC._compiler_plan(:native); count_fold = false)
const _RC_NOCOMPILE = _RC._plan_with(_RC._compiler_plan(:native); setup_map_compile_once = false)

# The lib/relational.esm templates `names`, inlined into a model (the
# in-memory build takes a model's own `expression_templates`).
_rc_templates(names...) = begin
    lib = JSON3.read(read(joinpath(_RC_LIB, "relational.esm"), String), Dict{String, Any})
    Dict{String, Any}(n => lib["expression_templates"][n] for n in names)
end

_rc_same(a, b) = keys(a) == keys(b) && all(a[k] === b[k] for k in keys(a))

# `du` by state name at the initial state, and the build's tally, from an
# in-memory document (whose constants may hold NaN and Inf, which JSON cannot).
function _rc_du_doc(doc, compiler)
    _RC._reset_cascade_tally!()
    f!, u0, p, _, vm = compiler isa Symbol ?
        _RC._build_evaluator(doc; compiler = compiler) :
        _RC._with_compiler_plan(compiler) do
            _RC._build_evaluator_dict(doc; compiler = compiler)
    end
    tally = copy(_RC._CASCADE_TALLY)
    du = similar(u0); fill!(du, NaN)
    f!(du, u0, p, 0.3)
    return (Dict(k => du[v] for (k, v) in vm), tally)
end

# The same through the document front door (a written file, so its
# metaparameters fold at load).
function _rc_du_file(doc, compiler::Symbol)
    path = joinpath(mktempdir(), "doc.esm")
    write(path, JSON3.write(doc))
    _RC._reset_cascade_tally!()
    prob = _RC.esm_problem(path, (0.0, 1.0); compiler = compiler)
    tally = copy(_RC._CASCADE_TALLY)
    du = similar(prob.u0); fill!(du, NaN)
    prob.f!(du, prob.u0, prob.p, 0.3)
    return (Dict(k => du[v] for (k, v) in prob.var_map), tally)
end

# A small triangulated mesh (n x n vertices, shuffled ids, two triangles per
# square), like the mesh_rank workload of bench/closed_templates/generate.py: the edges of each
# face as (lo, hi) vertex pairs and the sorted unique edges.
function _rc_mesh(n)
    perm = [mod1(5k + 3, n * n) for k in 1:(n * n)]    # a fixed permutation of 1..n² (n² coprime to 5)
    @assert sort(perm) == 1:(n * n)
    v(i, j) = perm[i * n + j + 1]
    lo, hi = Vector{Vector{Int}}(), Vector{Vector{Int}}()
    for i in 0:(n - 2), j in 0:(n - 2)
        a, b, c, d = v(i, j), v(i + 1, j), v(i + 1, j + 1), v(i, j + 1)
        for tri in ((a, b, c), (a, c, d))
            push!(lo, [min(tri[k], tri[mod1(k + 1, 3)]) for k in 1:3])
            push!(hi, [max(tri[k], tri[mod1(k + 1, 3)]) for k in 1:3])
        end
    end
    edges = sort!(unique([(lo[f][k], hi[f][k]) for f in eachindex(lo) for k in 1:3]))
    return lo, hi, edges
end

# The mesh_rank document: `spelling` :op (skolem key, rank, the looked-up ranks
# as a constant) or :tpl (edge_key, the loop index, rank_of_set).
function _rc_mesh_doc(n, spelling)
    lo, hi, edges = _rc_mesh(n)
    F, Ne, nv = length(lo), length(edges), n * n
    rank = Dict(e => r for (r, e) in enumerate(edges))
    FL = Dict("f" => Dict("from" => "faces"), "le" => Dict("from" => "local_edges"))
    lof, hif = _rc_ix("edge_lo", "f", "le"), _rc_ix("edge_hi", "f", "le")
    key = spelling === :op ? _rc_op("skolem", lof, hif; label = "edge") :
        _rc_apply("edge_key"; u = lof, v = hif, lo = 1, n = nv)
    vars = Dict{String, Any}(
        "edge_lo" => Dict("type" => "unknown", "shape" => Any["faces", "local_edges"]),
        "edge_hi" => Dict("type" => "unknown", "shape" => Any["faces", "local_edges"]),
        "edge_exists" => Dict("type" => "unknown", "shape" => Any["edges"]),
        "edge_dense_id" => Dict("type" => "unknown", "shape" => Any["edges"]),
        "face_edge_rank" => Dict("type" => "unknown", "shape" => Any["faces", "local_edges"]),
        "q" => Dict("type" => "unknown", "shape" => Any["edge_ids"], "default" => 1.0),
        "c" => Dict("type" => "unknown", "shape" => Any["faces"], "default" => 0.0),
        "n_edges" => Dict("type" => "unknown", "default" => 0.0),
    )
    E_ = Dict("e" => Dict("from" => "edge_ids"))
    F_ = Dict("f" => Dict("from" => "faces"))
    eqs = Any[
        Dict("lhs" => "edge_lo", "rhs" => _rc_const(lo)),
        Dict("lhs" => "edge_hi", "rhs" => _rc_const(hi)),
        Dict(
            "lhs" => _rc_ix("edge_exists", "e"),
            "rhs" => _rc_faq(
                _rc_op("true"), ["e"], FL; id = "edge_set", semiring = "bool_and_or",
                distinct = true, key = key, filter = _rc_op("true")
            )
        ),
        Dict(
            "lhs" => _rc_ix("edge_dense_id", "e"),
            "rhs" => _rc_faq(spelling === :op ? _rc_op("rank", "edges") : "e", ["e"], Dict("e" => Dict("from" => "edges")); semiring = "sum_product")
        ),
        Dict("lhs" => _rc_dlhs("q", ["e"], E_), "rhs" => _rc_faq(_rc_op("-", _rc_ix("q", "e")), ["e"], E_)),
        Dict(
            "lhs" => _rc_dlhs("c", ["f"], F_),
            "rhs" => _rc_faq(_rc_ix("q", _rc_ix("face_edge_rank", "f", "le")), ["f"], FL; semiring = "sum_product")
        ),
        Dict(
            "lhs" => _rc_op("D", "n_edges"; wrt = "t"),
            "rhs" => _rc_faq(1.0, [], Dict("e" => Dict("from" => "edges")); semiring = "sum_product")
        ),
    ]
    edges_set = Dict{String, Any}("kind" => "derived", "from_faq" => "edge_set")
    model = Dict{String, Any}("variables" => vars, "equations" => eqs)
    if spelling === :op
        push!(eqs, Dict("lhs" => "face_edge_rank", "rhs" => _rc_const([[rank[(lo[f][k], hi[f][k])] for k in 1:3] for f in 1:F])))
    else
        vars["edge_members"] = Dict("type" => "parameter", "shape" => Any["edges"], "default" => 0.0)
        edges_set["member_factor"] = "edge_members"
        push!(
            eqs, Dict(
                "lhs" => _rc_ix("face_edge_rank", "f", "le"),
                "rhs" => _rc_faq(
                    _rc_apply("rank_of_set"; x = _rc_apply("edge_key"; u = lof, v = hif, lo = 1, n = nv), members = "edge_members", S = "edges"),
                    ["f", "le"], FL
                )
            )
        )
        model["expression_templates"] = _rc_templates("edge_key", "rank_of_set")
    end
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict("name" => "mesh_rank_$(spelling)"),
        "index_sets" => Dict(
            "faces" => Dict("kind" => "interval", "size" => F),
            "local_edges" => Dict("kind" => "interval", "size" => 3),
            "edge_ids" => Dict("kind" => "interval", "size" => Ne),
            "edges" => edges_set,
        ),
        "models" => Dict("MeshRank" => model)
    )
end

# r[i] = Σ_k body(keys[k], x[i]) over constant keys and queries, every cell's
# count a table entry. `body(a, x)` builds the
# summand; `kw` goes to the count's faq (another reduce, a filter). D(s[i]) = r[i].
function _rc_count_doc(keys, queries, body; kw...)
    n, m = length(keys), length(queries)
    I = Dict("i" => Dict("from" => "cells"))
    cnt = Dict{String, Any}(
        "op" => "faq", "args" => Any[], "output_idx" => Any[],
        "ranges" => Dict("k" => Dict("from" => "keys")),
        "expr" => body(_rc_ix("kv", "k"), _rc_ix("xq", "i")), (String(k) => v for (k, v) in kw)...
    )
    vars = Dict{String, Any}(
        "kv" => Dict("type" => "unknown", "shape" => Any["keys"]),
        "xq" => Dict("type" => "unknown", "shape" => Any["cells"]),
        "r" => Dict("type" => "unknown", "shape" => Any["cells"]),
        "s" => Dict("type" => "unknown", "shape" => Any["cells"], "default" => 0.0),
    )
    eqs = Any[
        Dict("lhs" => "kv", "rhs" => _rc_const(keys)),
        Dict("lhs" => "xq", "rhs" => _rc_const(queries)),
        Dict("lhs" => _rc_ix("r", "i"), "rhs" => _rc_faq(_rc_op("+", 1, cnt), ["i"], I; args = Any["kv", "xq"])),
        Dict("lhs" => _rc_dlhs("s", ["i"], I), "rhs" => _rc_faq(_rc_ix("r", "i"), ["i"], I)),
    ]
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict("name" => "rank_count"),
        "index_sets" => Dict("keys" => Dict("kind" => "interval", "size" => n), "cells" => Dict("kind" => "interval", "size" => m)),
        "models" => Dict("M" => Dict{String, Any}("variables" => vars, "equations" => eqs))
    )
end

_rc_rel(op, flip, yes = 1, no = 0) = (a, x) -> _rc_op("ifelse", flip ? _rc_op(op, x, a) : _rc_op(op, a, x), yes, no)

@testset "rank lookup under strict native (closed-AST phase 4)" begin
    @testset "mesh rank lookup, n = $n" for n in (4, 7)
        tp = _rc_mesh_doc(n, :tpl)
        op = _rc_mesh_doc(n, :op)
        dn, tn = _rc_du_doc(tp, :native)
        di, ti = _rc_du_doc(tp, :interpreter)
        dop, _ = _rc_du_doc(op, :native)
        @test _rc_same(dn, di)
        @test _rc_same(dn, dop)
        # The rank table is filled at setup with the count as a search, and
        # nothing of it is left in the right-hand side.
        @test get(tn, :count_fold_setup, 0) >= 1
        @test get(tn, :count_fold_search, 0) + get(tn, :count_fold_sorted, 0) + get(tn, :count_fold_linear, 0) == 0
        @test get(ti, :count_fold_setup, 0) == 0
        # Without the count rewrite the lookup stays in the right-hand side.
        df, tf = _rc_du_doc(tp, _RC_NOFOLD)
        @test _rc_same(df, dn)
        @test get(tf, :count_fold_setup, 0) == 0
        # The producer walked instead of compiled: the same members.
        dw, _ = _rc_du_doc(tp, _RC_NOCOMPILE)
        @test _rc_same(dw, dn)
        dwo, _ = _rc_du_doc(op, _RC_NOCOMPILE)
        @test _rc_same(dwo, dn)
    end

    keysets = (
        ("ascending", [0.5, 1.0, 1.5, 2.0, 2.0, 3.25, 4.0]),
        ("unsorted", [3.25, 0.5, 2.0, 4.0, 1.0, 2.0, 1.5]),
        ("NaN entries", [3.25, NaN, 2.0, 0.5, NaN, 1.0]),
        ("signed zeros", [0.0, -1.0, -0.0, 2.0, 0.0, -0.0, 1.0]),
        ("repeated", [2.0, 2.0, 2.0, 1.0, 1.0, 3.0]),
        ("one entry", [1.0]),
    )
    queries = [-0.0, 0.0, NaN, Inf, -Inf, 0.5, 1.0, nextfloat(1.0), prevfloat(2.0), 2.0, 3.25, 4.0, 5.0, -1.0]
    rels = (
        ("a <= x", "<=", false, <=), ("a < x", "<", false, <),
        ("a >= x", ">=", false, >=), ("a > x", ">", false, >),
        ("x >= a", ">=", true, <=), ("x < a", "<", true, >),
    )
    @testset "count at setup: $kname keys, $what, branches $yes/$no" for (kname, ks) in keysets,
            (what, op, flip, f) in rels, (yes, no) in ((1, 0), (0, 1))
        doc = _rc_count_doc(ks, queries, _rc_rel(op, flip, yes, no))
        dn, tn = _rc_du_doc(doc, :native)
        di, _ = _rc_du_doc(doc, :interpreter)
        @test _rc_same(dn, di)
        @test get(tn, :count_fold_setup, 0) >= 1
        # Anchored on the count itself.
        want = [1.0 + count(v -> (yes == 1) == f(v, x), ks) for x in queries]
        @test all(dn["s[$i]"] === want[i] for i in eachindex(queries))
    end

    near = (
        ("branch values 2/0", _rc_rel("<=", false, 2, 0), (;)),
        ("branch values 1/1", _rc_rel("<=", false, 1, 1), (;)),
        ("equality", (a, x) -> _rc_op("ifelse", _rc_op("==", a, x), 1, 0), (;)),
        ("query reads k", (a, x) -> _rc_op("ifelse", _rc_op("<=", a, _rc_op("+", x, "k")), 1, 0), (;)),
        ("max reducer", _rc_rel("<=", false), (; reduce = "max")),
        ("filter", _rc_rel("<=", false), (; filter = _rc_op(">=", "k", 2))),
        ("key reads the outer index", (a, x) -> _rc_op("ifelse", _rc_op("<=", _rc_op("+", a, _rc_ix("xq", "i")), x), 1, 0), (;)),
        ("key read at k + 0 * k", (a, x) -> _rc_op("ifelse", _rc_op("<=", _rc_ix("kv", _rc_op("+", "k", _rc_op("*", 0, "k"))), x), 1, 0), (;)),
    )
    @testset "near miss keeps the fold: $what" for (what, body, kw) in near
        doc = _rc_count_doc([3.25, 0.5, 2.0, 4.0, 1.0], queries, body; kw...)
        dn, tn = _rc_du_doc(doc, :native)
        di, _ = _rc_du_doc(doc, :interpreter)
        @test _rc_same(dn, di)
        @test get(tn, :count_fold_setup, 0) == 0
    end

    # `rank_of(x, members, n)` with `n` a metaparameter (a `ranges` bound
    # admits an integer or a metaparameter, esm-spec §9.6.1): a constant query
    # is a setup table and a state query a search per call.
    @testset "rank_of with n a metaparameter ($what query)" for what in (:const, :state)
        I = Dict("i" => Dict("from" => "cells"))
        members = [mod(17k, 23) / 4 for k in 1:40]     # unsorted, repeated
        xs = [0.25, 1.0, 2.0, 2.5, 3.0, 7.0]
        x = what === :const ? _rc_ix("xq", "i") : _rc_ix("s", "i")
        vars = Dict{String, Any}(
            "mv" => Dict("type" => "unknown", "shape" => Any["mem"]),
            "xq" => Dict("type" => "unknown", "shape" => Any["cells"]),
            "r" => Dict("type" => "unknown", "shape" => Any["cells"]),
            "s" => Dict("type" => "unknown", "shape" => Any["cells"], "default" => 1.3),
        )
        eqs = Any[
            Dict("lhs" => "mv", "rhs" => _rc_const(members)),
            Dict("lhs" => "xq", "rhs" => _rc_const(xs)),
            Dict("lhs" => _rc_ix("r", "i"), "rhs" => _rc_faq(_rc_apply("rank_of"; x = x, members = "mv", n = "nm"), ["i"], I)),
            Dict("lhs" => _rc_dlhs("s", ["i"], I), "rhs" => _rc_faq(_rc_ix("r", "i"), ["i"], I)),
        ]
        doc = Dict{String, Any}(
            "esm" => "1.2.0", "metadata" => Dict("name" => "rank_of_param"),
            "metaparameters" => Dict("nm" => Dict("type" => "integer", "default" => 37)),
            "index_sets" => Dict("cells" => Dict("kind" => "interval", "size" => 6), "mem" => Dict("kind" => "interval", "size" => 40)),
            "models" => Dict(
                "M" => Dict{String, Any}(
                    "variables" => vars, "equations" => eqs,
                    "expression_templates" => _rc_templates("rank_of")
                )
            )
        )
        dn, tn = _rc_du_file(doc, :native)
        di, _ = _rc_du_file(doc, :interpreter)
        @test _rc_same(dn, di)
        q = what === :const ? xs : fill(1.3, 6)
        sv(i) = only(v for (k, v) in dn if endswith(k, "s[$i]"))
        @test all(sv(i) === 1.0 + count(<(q[i]), members[1:37]) for i in 1:6)
        @test get(tn, what === :const ? :count_fold_setup : :count_fold_sorted, 0) >= 1
    end

    @testset "compiled producer key: a NaN key is still refused" begin
        doc = _rc_mesh_doc(4, :tpl)
        # n = 3 puts vertex ids above 3 out of edge_key's range: a NaN key.
        doc["models"]["MeshRank"]["equations"][3]["rhs"]["key"]["bindings"]["n"] = 3
        for c in (:native, _RC_NOCOMPILE)
            err = try
                _rc_du_doc(doc, c)
                nothing
            catch e
                e
            end
            @test err !== nothing
            @test occursin("value_invention_key_out_of_range", sprint(showerror, err))
        end
    end
end
