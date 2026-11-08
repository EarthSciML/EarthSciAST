# The pure-AST interpolation templates under strict `compiler = :native`
# (closed-AST phase 2, #660).
#
# `searchsorted`, `linear` and `bilinear` written as expression templates
# (CONTRACT_P2: the bracket is a comparison count, `i` written out at each of
# its uses) must build under strict native and give the bits of the
# interpreter and of the `fn interp.*` form they replace, serial and threaded,
# for a scalar query and for a per-cell query inside a `faq` over an index
# set (`faq_l linear(table, axis, ix(q, l), n)`, the shape #660's array-valued
# query is rewritten to). Two emitter rewrites carry the speed and are pinned
# here on those shapes:
#
#   * the comparison count (`count_fold`, array_contraction.jl) fires on the
#     templates' counts — `ifelse(ix(axis, k) <= x, 1, 0)` inside min/max
#     clamps, and searchsorted's swapped form `ifelse(ix(xs, k) >= x, 0, 1)`;
#   * a repeated sub-tree is computed once per region (`share_subtrees`): the
#     six copies of `linear`'s bracket index run one count, not six. Near
#     misses — copies that differ in a literal, or sit only under lazy
#     branches — are emitted where they stand.
#
# Each rewrite switched off gives the same bits.

using Test
include("testutils.jl")

const _TI = EarthSciAST

_ti_op(o, a...; kw...) = Dict{String, Any}("op" => o, "args" => Any[a...], (String(k) => v for (k, v) in kw)...)
_ti_ix(a, s...) = _ti_op("index", a, s...)
_ti_const(v) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => v)
_ti_apply(name; b...) = Dict{String, Any}(
    "op" => "apply_expression_template", "args" => Any[], "name" => name,
    "bindings" => Dict{String, Any}(String(k) => v for (k, v) in b)
)
_ti_count(k, n, cond, arrays; yes = 1, no = 0) = Dict{String, Any}(
    "op" => "faq", "output_idx" => Any[], "reduce" => "+", "args" => Any[arrays...],
    "ranges" => Dict(k => Any[1, n]), "expr" => _ti_op("ifelse", cond, yes, no)
)
_ti_lev(e) = Dict{String, Any}(
    "op" => "faq", "args" => Any[], "output_idx" => Any["l"],
    "ranges" => Dict("l" => Dict("from" => "lev")), "expr" => e
)
_ti_dl(v) = _ti_lev(_ti_op("D", _ti_ix(v, "l"); wrt = "t"))
_ti_clamp_i(k, axis, x, n) =
    _ti_op("min", _ti_op("max", _ti_count(k, n, _ti_op("<=", _ti_ix(axis, k), x), [axis]), 1), _ti_op("-", n, 1))

# The three templates exactly as CONTRACT_P2 writes them.
function _ti_templates()
    i = _ti_clamp_i("k_lin", "axis", "x", "n")
    ip1 = _ti_op("+", i, 1)
    w = _ti_op("/", _ti_op("-", "x", _ti_ix("axis", i)), _ti_op("-", _ti_ix("axis", ip1), _ti_ix("axis", i)))
    mid = _ti_op("+", _ti_ix("table", i), _ti_op("*", w, _ti_op("-", _ti_ix("table", ip1), _ti_ix("table", i))))
    lin = _ti_op(
        "ifelse", _ti_op("<=", "x", _ti_ix("axis", 1)), _ti_ix("table", 1),
        _ti_op("ifelse", _ti_op(">=", "x", _ti_ix("axis", "n")), _ti_ix("table", "n"), mid)
    )
    ss = _ti_op("+", 1, _ti_count("k_ss", "n", _ti_op(">=", _ti_ix("xs", "k_ss"), "x"), ["xs"]; yes = 0, no = 1))
    q(v, ax, nn) = _ti_op(
        "ifelse", _ti_op("<=", v, _ti_ix(ax, 1)), _ti_ix(ax, 1),
        _ti_op("ifelse", _ti_op(">=", v, _ti_ix(ax, nn)), _ti_ix(ax, nn), v)
    )
    xq, yq = q("x", "axis_x", "nx"), q("y", "axis_y", "ny")
    bi = _ti_clamp_i("k_bx", "axis_x", xq, "nx")
    bj = _ti_clamp_i("k_by", "axis_y", yq, "ny")
    bi1, bj1 = _ti_op("+", bi, 1), _ti_op("+", bj, 1)
    wx = _ti_op("/", _ti_op("-", xq, _ti_ix("axis_x", bi)), _ti_op("-", _ti_ix("axis_x", bi1), _ti_ix("axis_x", bi)))
    wy = _ti_op("/", _ti_op("-", yq, _ti_ix("axis_y", bj)), _ti_op("-", _ti_ix("axis_y", bj1), _ti_ix("axis_y", bj)))
    row(j) = _ti_op(
        "+", _ti_ix("table", bi, j),
        _ti_op("*", wx, _ti_op("-", _ti_ix("table", bi1, j), _ti_ix("table", bi, j)))
    )
    rj, rj1 = row(bj), row(bj1)
    bil = _ti_op("+", rj, _ti_op("*", wy, _ti_op("-", rj1, rj)))
    return Dict{String, Any}(
        "searchsorted" => Dict("params" => ["x", "xs", "n"], "body" => ss),
        "linear" => Dict("params" => ["table", "axis", "x", "n"], "body" => lin),
        "bilinear" => Dict("params" => ["table", "axis_x", "axis_y", "x", "y", "nx", "ny"], "body" => bil),
    )
end

# A stretched axis of exact integers, three tables on it, a 2-D table on
# (axis, ya).
_ti_z(n) = Float64[(k - 1) * (100 + (k - 1)) for k in 1:n]
_ti_tabs(n) = (
    Float64[(10.0 + 0.5 * k) - 0.002 * k * k for k in 1:n],
    Float64[2.0 - 0.05 * k for k in 1:n],
    Float64[290.0 + 0.004 * z for z in _ti_z(n)],
)
const _TI_NY = 9
_ti_ya() = Float64[0.5 * j for j in 1:_TI_NY]
_ti_t2(n) = [_ti_tabs(n)[1][i] + 0.25 * j for i in 1:n, j in 1:_TI_NY]
_ti_rows(m) = Any[Any[m[i, j] for j in axes(m, 2)] for i in axes(m, 1)]

# One model, per `shape`, in the template (`tpl = true`) or the `fn`
# spelling. `scalar`: three relaxations toward `linear` at one moving query;
# `cell`: the same per level, the query `xq[l]`; `bil`: `bilinear` per level
# at (`xq[l]`, a scalar `yq`); `ss`: `searchsorted` per level.
function _ti_doc(shape::Symbol, n::Int; tpl::Bool)
    z = _ti_z(n)
    tabs = _ti_tabs(n)
    zt = 0.5 * z[end]
    vars = Dict{String, Any}()
    eqs = Any[]
    sv(shape = nothing, d = nothing) = (
        v = Dict{String, Any}("type" => "unknown");
        shape === nothing || (v["shape"] = shape); d === nothing || (v["default"] = d); v
    )
    lookup(t, x) = tpl ?
        _ti_apply("linear"; table = _ti_const(t), axis = _ti_const(z), x = x, n = n) :
        _ti_op("fn", _ti_const(t), _ti_const(z), x; name = "interp.linear")
    # The query moves with t and passes below the axis, through every knot
    # interval and above it, so every branch of the template is taken.
    sweep = _ti_op("+", zt, _ti_op("*", 1.3 * zt, _ti_op("sin", _ti_op("*", 0.3, "t"))))
    if shape === :scalar
        vars["xs"] = sv()
        push!(eqs, Dict("lhs" => "xs", "rhs" => sweep))
        for (s, t) in zip(("u", "v", "th"), tabs)
            vars[s] = sv(nothing, t[1])
            push!(eqs, Dict("lhs" => _ti_op("D", s; wrt = "t"), "rhs" => _ti_op("-", lookup(t, "xs"), s)))
        end
    else
        vars["xq"] = sv(["lev"])
        lq = _ti_op("+", _ti_op("*", _ti_op("-", "l", 1), z[end] / (n - 1)), _ti_op("*", 0.7 * zt, _ti_op("sin", _ti_op("*", 0.3, "t"))))
        push!(eqs, Dict("lhs" => "xq", "rhs" => _ti_lev(lq)))
        if shape === :cell
            for (s, t) in zip(("u", "v", "th"), tabs)
                vars[s] = sv(["lev"], t[1])
                push!(eqs, Dict("lhs" => _ti_dl(s), "rhs" => _ti_lev(_ti_op("-", lookup(t, _ti_ix("xq", "l")), _ti_ix(s, "l")))))
            end
        elseif shape === :ss
            vars["u"] = sv(["lev"], 0.0)
            look = tpl ? _ti_apply("searchsorted"; x = _ti_ix("xq", "l"), xs = _ti_const(z), n = n) :
                _ti_op("fn", _ti_ix("xq", "l"), _ti_const(z); name = "interp.searchsorted")
            push!(eqs, Dict("lhs" => _ti_dl("u"), "rhs" => _ti_lev(_ti_op("-", look, _ti_ix("u", "l")))))
        else
            vars["yq"] = sv()
            push!(eqs, Dict("lhs" => "yq", "rhs" => _ti_op("+", 2.25, _ti_op("*", 2.5, _ti_op("sin", _ti_op("*", 0.2, "t"))))))
            vars["u"] = sv(["lev"], 10.0)
            t2, ya = _ti_rows(_ti_t2(n)), _ti_ya()
            look = tpl ?
                _ti_apply(
                    "bilinear"; table = _ti_const(t2), axis_x = _ti_const(z), axis_y = _ti_const(ya),
                    x = _ti_ix("xq", "l"), y = "yq", nx = n, ny = _TI_NY
                ) :
                _ti_op("fn", _ti_const(t2), _ti_const(z), _ti_const(ya), _ti_ix("xq", "l"), "yq"; name = "interp.bilinear")
            push!(eqs, Dict("lhs" => _ti_dl("u"), "rhs" => _ti_lev(_ti_op("-", look, _ti_ix("u", "l")))))
        end
    end
    model = Dict{String, Any}("variables" => vars, "equations" => eqs)
    tpl && (model["expression_templates"] = _ti_templates())
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict("name" => "closed_interp_$(shape)_$(tpl)"),
        "index_sets" => Dict("lev" => Dict("kind" => "interval", "size" => n)),
        "models" => Dict("Column" => model)
    )
end

const _TI_NOFOLD = _TI._plan_with(_TI._compiler_plan(:native); count_fold = false)
const _TI_NOSHARE = _TI._plan_with(_TI._compiler_plan(:native); share_subtrees = false)
const _TI_TIMES = (0.0, 0.7, 3.1, 6.0, 10.0, 17.5)

# `du` keyed by variable name at each of `_TI_TIMES`, and the build's tally,
# under `compiler` (a vocabulary value or a plan).
function _ti_eval(doc, compiler; times = _TI_TIMES)
    _TI._reset_cascade_tally!()
    f!, u0, p, _, vm = compiler isa Symbol ?
        _TI._build_evaluator(doc; compiler = compiler) :
        _TI._with_compiler_plan(() -> _TI._build_evaluator_dict(doc; compiler = compiler), compiler)
    tally = copy(_TI._CASCADE_TALLY)
    out = Dict{String, Vector{Float64}}()
    for t in times
        du = similar(u0); fill!(du, NaN)
        f!(du, u0, p, t)
        for (k, v) in vm
            push!(get!(() -> Float64[], out, k), du[v])
        end
    end
    return out, tally, (f!, u0, p)
end

_ti_same(a, b) = keys(a) == keys(b) && all(all(a[k] .=== b[k]) for k in keys(a))
_ti_count_fired(t) = get(t, :count_fold_search, 0) + get(t, :count_fold_linear, 0)

@testset "pure-AST interpolation templates under strict native (closed-AST phase 2)" begin
    # The templates built here are the library's, sub-tree for sub-tree.
    @testset "same templates as lib/interp.esm" begin
        lib = JSON3.read(read(joinpath(TESTUTILS_REPO_ROOT, "lib", "interp.esm"), String), Dict{String, Any})
        norm(x) = x isa AbstractDict ? Dict{String, Any}(String(k) => norm(v) for (k, v) in x if k != "description") :
            x isa AbstractVector ? Any[norm(v) for v in x] : x
        mine = _ti_templates()
        @test Set(keys(lib["expression_templates"])) == Set(keys(mine))
        for (name, t) in mine
            @test norm(lib["expression_templates"][name]) == norm(t)
        end
    end

    n = 59
    @testset "$shape" for shape in (:scalar, :cell, :ss, :bil)
        doc = _ti_doc(shape, n; tpl = true)
        dn, tn, _ = _ti_eval(doc, :native)
        di, ti, _ = _ti_eval(doc, :interpreter; times = _TI_TIMES[1:3])
        dfn, _, _ = _ti_eval(_ti_doc(shape, n; tpl = false), :native)
        # The interpreter's bits, at the times it ran.
        @test _ti_same(Dict(k => v[1:3] for (k, v) in dn), di)
        # The `fn` form's bits, every time.
        @test _ti_same(dn, dfn)
        @test _ti_count_fired(tn) >= 1
        @test _ti_count_fired(ti) == 0
        # `searchsorted` has one count and nothing to share.
        shape === :ss || @test get(tn, :share_subtrees, 0) >= 1
        shape === :ss && @test get(tn, :count_fold_search, 0) >= 1
        # Each rewrite off: the same bits, and the rewrite gone.
        df, tf, _ = _ti_eval(doc, _TI_NOFOLD)
        @test _ti_same(df, dn)
        @test _ti_count_fired(tf) == 0
        ds, ts, _ = _ti_eval(doc, _TI_NOSHARE)
        @test _ti_same(ds, dn)
        @test get(ts, :share_subtrees, 0) == 0
    end

    # One bracket index per lookup: `linear` writes it six times, and every
    # copy sits in its innermost branch, so that branch computes it once and
    # the count is emitted once per lookup (three lookups).
    @testset "the bracket index runs once per lookup" begin
        doc = _ti_doc(:cell, n; tpl = true)
        _, tn, _ = _ti_eval(doc, :native; times = (0.0,))
        _, ts, _ = _ti_eval(doc, _TI_NOSHARE; times = (0.0,))
        @test get(ts, :count_fold_search, 0) == 6 * get(tn, :count_fold_search, 0)
        @test get(tn, :count_fold_search, 0) == 3
    end

    @testset "N = 200 against the fn form" for shape in (:scalar, :cell, :ss, :bil)
        dn, tn, _ = _ti_eval(_ti_doc(shape, 200; tpl = true), :native)
        dfn, _, _ = _ti_eval(_ti_doc(shape, 200; tpl = false), :native)
        @test _ti_same(dn, dfn)
        @test _ti_count_fired(tn) >= 1
    end

    # Threaded: every section chunked (work floor 1) gives the serial bits.
    if Threads.nthreads() > 1
        @testset "threaded = serial ($shape)" for shape in (:cell, :ss, :bil)
            doc = _ti_doc(shape, n; tpl = true)
            ser, _, _ = withenv(() -> _ti_eval(doc, :native), "ESS_THREADS_MIN_WORK" => "1000000000")
            empty!(_TI._THREAD_TALLY)
            thr, _, _ = withenv(() -> _ti_eval(doc, :native), "ESS_THREADS_MIN_WORK" => "1")
            @test get(_TI._THREAD_TALLY, :cg_threaded, 0) >= 1
            @test _ti_same(ser, thr)
        end
    end

    if VERSION >= v"1.12"
        @testset "zero allocation per call ($shape)" for shape in (:scalar, :cell, :bil)
            _, _, (f!, u0, p) = _ti_eval(_ti_doc(shape, n; tpl = true), :native; times = (0.0,))
            du = similar(u0)
            f!(du, u0, p, 0.3)
            @test (@allocated f!(du, u0, p, 0.4)) == 0
        end
    end
end

# The sharing rule on its own shapes, in a scalar equation and in the
# whole-array nest. `cnt(x)` is a count over a constant axis (a loop),
# `cnt5(x)` one short enough to be unrolled; the queries hit knots, gaps, both
# ends and NaN.
@testset "repeated sub-trees computed once: matches and near misses" begin
    n = 23
    ax = Float64[(k - 3) / 2 for k in 1:n]
    cnt(x; lit = 1) = _ti_count("k", n, _ti_op("<=", _ti_ix(_ti_const(ax), "k"), x), []; yes = lit)
    # Below the contraction-loop floor: the count is unrolled into a fold.
    cnt5(x) = _ti_count("k", 5, _ti_op("<=", _ti_ix(_ti_const(ax[1:5]), "k"), x), [])
    function doc(rhs_of)
        vars = Dict{String, Any}(
            "q" => Dict("type" => "unknown", "shape" => Any["lev"]),
            "s" => Dict("type" => "unknown", "default" => 0.0),
        )
        eqs = Any[
            Dict("lhs" => _ti_op("D", "s"; wrt = "t"), "rhs" => rhs_of(_ti_op("*", 6.0, _ti_op("sin", "t")))),
            Dict("lhs" => _ti_dl("q"), "rhs" => _ti_lev(rhs_of(_ti_ix("q", "l")))),
        ]
        return Dict{String, Any}(
            "esm" => "1.2.0", "metadata" => Dict("name" => "share"),
            "index_sets" => Dict("lev" => Dict("kind" => "interval", "size" => n)),
            "models" => Dict("M" => Dict{String, Any}("variables" => vars, "equations" => eqs))
        )
    end
    qs = vcat(Any[NaN, -Inf, Inf, -0.0], Any[ax[k] for k in 1:2:n], Any[ax[k] + 0.25 for k in 2:2:n])
    function agree(d)
        ics = Dict{String, Any}("q[$i]" => qs[mod1(i, length(qs))] for i in 1:n)
        r = Dict{Any, Any}()
        for c in (:native, _TI_NOSHARE, :interpreter)
            _TI._reset_cascade_tally!()
            f!, u0, p, _, vm = c isa Symbol ?
                _TI._build_evaluator(d; initial_conditions = ics, compiler = c) :
                _TI._with_compiler_plan(() -> _TI._build_evaluator_dict(d; initial_conditions = ics, compiler = c), c)
            out = Dict{String, Vector{Float64}}()
            for t in (0.0, 0.4, 2.0, 4.4)
                du = similar(u0); f!(du, u0, p, t)
                for (k, v) in vm
                    push!(get!(() -> Float64[], out, k), du[v])
                end
            end
            r[c] = (out, copy(_TI._CASCADE_TALLY))
        end
        @test _ti_same(r[:native][1], r[:interpreter][1])
        @test _ti_same(r[_TI_NOSHARE][1], r[:interpreter][1])
        @test get(r[_TI_NOSHARE][2], :share_subtrees, 0) == 0
        return get(r[:native][2], :share_subtrees, 0)
    end
    # Shared: two copies side by side; copies under a strict operand and
    # inside a lazy branch (the strict one pays for both); a copy nested in a
    # larger repeated sub-tree.
    @test agree(doc(x -> _ti_op("+", cnt(x), _ti_op("*", 2, cnt(x))))) >= 2
    @test agree(doc(x -> _ti_op("ifelse", _ti_op(">", cnt(x), 4), cnt(x), 0.5))) >= 2
    @test agree(doc(x -> _ti_op("-", _ti_op("*", cnt(x), _ti_op("+", cnt(x), 1)), _ti_op("+", cnt(x), 1)))) >= 2
    # An unrolled count: the scalar prelude's and the per-cell kernels' own
    # shared-subexpression passes take it before these emitters see it; the
    # same bits either way.
    agree(doc(x -> _ti_op("*", cnt5(x), _ti_op("+", cnt5(x), 0.5))))
    # Near misses, emitted where they stand: copies that differ in a branch
    # literal; copies only in two different lazy branches; one copy.
    @test agree(doc(x -> _ti_op("+", cnt(x), cnt(x; lit = 2)))) == 0
    @test agree(doc(x -> _ti_op("ifelse", _ti_op(">", x, 1.0), cnt(x), _ti_op("*", 3, cnt(x))))) == 0
    @test agree(doc(x -> _ti_op("+", cnt(x), x))) == 0
    # Copies in ONE lazy branch are shared inside that branch.
    @test agree(doc(x -> _ti_op("ifelse", _ti_op(">", x, 1.0), _ti_op("+", cnt(x), cnt(x)), x))) >= 2
end

# A build-CONSTANT observed through the templates: the template.esm fixtures
# (tests/closed_functions/interp/) with every query parameter replaced by its
# literal value, so the bracket index is a `faq` count over constants in a
# constant subscript. Reading the observed in an inline test resolves that
# subscript at build time; it is evaluated in floating point and only its
# value rounded to the subscript, and every assertion gives the expected bits.
import OrdinaryDiffEqTsit5   # the solver `run_inline_tests` picks
@testset "literal query: build-constant template observeds read by inline tests" begin
    lib = joinpath(TESTUTILS_REPO_ROOT, "lib", "interp.esm")
    dir = mktempdir()
    @testset "$fname, $c" for fname in ("linear", "bilinear"), c in (:interpreter, :native)
        src = joinpath(TESTUTILS_REPO_ROOT, "tests", "closed_functions", "interp", fname, "template.esm")
        doc = JSON3.read(read(src, String), Dict{String, Any})
        model = first(values(doc["models"]))
        model["expression_template_imports"] = Any[Dict{String, Any}("ref" => lib)]
        vars = model["variables"]
        lits = Dict{String, Any}(k => v["default"] for (k, v) in vars if v["type"] == "parameter")
        @test !isempty(lits)
        sub(e) = e isa AbstractString ? get(lits, e, e) :
            e isa AbstractDict ? Dict{String, Any}(String(k) => sub(v) for (k, v) in e) :
            e isa AbstractVector ? Any[sub(v) for v in e] : e
        model["equations"] = sub(model["equations"])
        foreach(k -> delete!(vars, k), keys(lits))
        path = joinpath(dir, "$(fname)_literal.esm")
        write(path, JSON3.write(doc))
        results = run_inline_tests(path; compiler = c)
        @test !isempty(results)
        for r in results
            @test r.status == EarthSciAST.PASS
            @test r.actual !== nothing && isequal(r.actual, r.expected)
        end
    end
end

# A gather subscript past the first is evaluated only when the ones before it
# are: a state gather reads none past one out of its axis (a ghost read, 0̄),
# a const gather none past one its boundary policy throws on. A repeated
# sub-tree that occurs only in such subscripts is not computed ahead of the
# gather. Here `c[k + s]` (an inline `const`, `error` boundary, read at a
# subscript holding the state `s = 2`, so it is read per call) is out of
# range exactly where both state reads' first subscript is out of `q`'s axis,
# so the interpreter never evaluates it there; computing the shared copy at
# the start of the whole-array nest's term would throw.
@testset "repeated sub-tree only in later gather subscripts stays lazy" begin
    M = 24
    c = Float64[mod1(5m, M) for m in 1:M]
    cg = _ti_ix(_ti_const(c), _ti_op("+", "k", "s"))
    body = _ti_op(
        "+", _ti_ix("q", _ti_op("+", "k", "i", 1), cg),
        _ti_op("*", 2.0, _ti_ix("q", _ti_op("+", "k", "i", 2), cg))
    )
    fq(out, ranges, e; kw...) = Dict{String, Any}(
        "op" => "faq", "args" => Any[], "output_idx" => Any[out...],
        "ranges" => ranges, "expr" => e, (String(k) => v for (k, v) in kw)...
    )
    qr = Dict("a" => Any[1, M], "b" => Any[1, M])
    doc = Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict("name" => "lazy_gather_subscript"),
        "models" => Dict(
            "M" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "q" => Dict("type" => "unknown", "shape" => Any["a", "b"]),
                    "out" => Dict("type" => "unknown", "shape" => Any["i"]),
                    "s" => Dict("type" => "unknown", "default" => 2.0),
                ),
                "equations" => Any[
                    Dict("lhs" => _ti_op("D", "s"; wrt = "t"), "rhs" => 0.0),
                    Dict(
                        "lhs" => fq(("a", "b"), qr, _ti_op("D", _ti_ix("q", "a", "b"); wrt = "t")),
                        "rhs" => fq(("a", "b"), qr, 0.0),
                    ),
                    Dict(
                        "lhs" => fq(("i",), Dict("i" => Any[1, 2]), _ti_op("D", _ti_ix("out", "i"); wrt = "t")),
                        "rhs" => fq(("i",), Dict("i" => Any[1, 2], "k" => Any[1, M]), body; reduce = "+"),
                    ),
                ],
            )
        )
    )
    ics = Dict{String, Any}("out[$i]" => 0.0 for i in 1:2)
    ics["s"] = 2.0
    qv(a, b) = 10.0 * a + b / 64
    for a in 1:M, b in 1:M
        ics["q[$a,$b]"] = qv(a, b)
    end
    # Exact sums of the reads in range (every one an exact binary fraction).
    rd(a, k) = a <= M ? qv(a, c[k + 2]) : 0.0
    expect = [sum(rd(k + i + 1, k) + 2.0 * rd(k + i + 2, k) for k in 1:M) for i in 1:2]
    r = Dict{Any, Any}()
    for comp in (:native, _TI_NOSHARE, :interpreter)
        _TI._reset_cascade_tally!()
        f!, u0, p, _, vm = comp isa Symbol ?
            _TI._build_evaluator(doc; initial_conditions = ics, compiler = comp) :
            _TI._with_compiler_plan(() -> _TI._build_evaluator_dict(doc; initial_conditions = ics, compiler = comp), comp)
        comp === :native && @test get(_TI._CASCADE_TALLY, :array_contraction_codegen, 0) >= 1
        du = similar(u0)
        f!(du, u0, p, 0.0)
        r[comp] = Float64[du[vm["out[$i]"]] for i in 1:2]
    end
    @test r[:interpreter] == expect
    @test all(r[:native] .=== r[:interpreter])
    @test all(r[_TI_NOSHARE] .=== r[:interpreter])
end

# The structural numbers of a loop body whose nodes are shared by reference —
# a diamond `x_{j+1} = sin(x_j) + cos(x_j)`, 2^40 paths from the top to the
# counter — are found once per node, not once per path.
@testset "repeated sub-tree keys are linear in a shared loop body" begin
    function diamond(ref, depth)
        x = _TI._mknode(kind = _TI._NK_LOOPVAR, payload = ref)
        levels = _TI._Node[x]
        for _ in 1:depth
            s = _TI._mknode(kind = _TI._NK_OP, op = :sin, children = _TI._Node[x])
            co = _TI._mknode(kind = _TI._NK_OP, op = :cos, children = _TI._Node[x])
            x = _TI._mknode(kind = _TI._NK_OP, op = :+, children = _TI._Node[s, co])
            push!(levels, x)
        end
        loop = _TI._mknode(
            kind = _TI._NK_CONTRACTION_LOOP, op = :+, literal = 0.0,
            payload = _TI._ContractLoop(ref, 1, 30, 1), children = _TI._Node[x]
        )
        return loop, levels
    end
    ref = Ref(0)
    loop, levels = diamond(ref, 40)
    two = _TI._mknode(kind = _TI._NK_OP, op = :*, children = _TI._Node[loop, loop])
    root = _TI._mknode(kind = _TI._NK_OP, op = :+, children = _TI._Node[two, two])
    kc = _TI._CGScalarCtx()
    local g, gb
    t = @elapsed begin
        # The enclosing region keys the loop, and so its body under the loop's
        # binder; then the body as its own region, the counter bound outside.
        g = _TI._cg_share_groups(kc, root)
        kc.loops[ref] = :kv
        gb = _TI._cg_share_groups(kc, levels[end])
        delete!(kc.loops, ref)
    end
    @test t < 30
    # The enclosing region repeats the loop (opaque to it) and `two`, in that
    # order; in the body every level below the top is reached on two paths.
    @test g == [_TI._Node[loop], _TI._Node[two]]
    @test gb !== nothing && issubset(levels[2:(end - 1)], Set(n for grp in gb for n in grp))
    # A structurally equal loop built apart has the same number.
    loop2, _ = diamond(Ref(0), 40)
    @test _TI._cg_share_key!(kc.share, kc, loop, Any[]) == _TI._cg_share_key!(kc.share, kc, loop2, Any[])
end

# A build-constant subscript holding a `faq` keeps integer arithmetic outside
# the `faq`: `/` is `div` there, as in the subscript without one, and a `faq`
# whose value is not an integer is refused as that value written by hand is.
@testset "build-constant subscript with a faq: integer arithmetic" begin
    axis = _op("const"; value = Any[1.0, 2.0, 3.0, 4.0])
    # The number of axis entries <= 1.5: one.
    cnt = _op(
        "faq"; output_idx = Any[], reduce = "+", ranges = Dict{String, Any}("k" => Any[1, 4]),
        expr_body = _op("ifelse", _op("<=", _op("index", axis, _v("k")), _n(1.5)), _i(1), _i(0))
    )
    ca = Dict{String, Any}()
    # 5/2 + 1 is 3 in integer arithmetic (3.5, rounded to 4, in floating point).
    sub = _op("+", _op("/", _i(5), _i(2)), cnt)
    @test _TI._const_subscript_int(sub, ca) == 3
    @test _TI._const_subscript_int(sub, ca) ==
        _TI._eval_const_int(_op("+", _op("/", _i(5), _i(2)), _i(1)), _TI._EMPTY_IDX_ENV, ca)
    # A `faq` worth 1.5: 2 + 1.5 is no subscript.
    half = _op("faq"; output_idx = Any[], reduce = "+", ranges = Dict{String, Any}("k" => Any[1, 3]), expr_body = _n(0.5))
    err(f) = try
        f()
        nothing
    catch e
        e
    end
    e_faq = err(() -> _TI._const_subscript_int(_op("+", _i(2), half), ca))
    e_lit = err(() -> _TI._const_subscript_int(_op("+", _i(2), _n(1.5)), ca))
    @test e_lit !== nothing
    @test e_faq !== nothing && typeof(e_faq) === typeof(e_lit)
end

# Closed-AST phase 4: what the interpolation templates' cells cost around the
# count.
#
#   * A table read whose subscript is an integer on the axis at every
#     evaluation — the bracket `min(max(count, 1), n - 1)` and its `+ 1` —
#     reads the element directly (`:gather_in_range`), without `round` and the
#     boundary policy; a subscript that could leave the axis, or that reads a
#     non-integer literal or a parameter, keeps them.
#   * The nest's cell loop with a state consumer steps its odometer rather than
#     dividing the cell ordinal per output dimension (two dimensions here).
#   * A contraction section with more contractions than inference unrolls is a
#     tree of short tuples: no allocation, no dynamic dispatch.
# Each against the interpreter, bit for bit.

_ti_sub_doc(sub; n = 9, nl = 23) = begin
    z = _ti_z(n)
    tab = _ti_tabs(n)[1]
    # Every query inside (z[1], z[n]): the count is 1 … n - 1.
    # The query moves with t, so the lookup is not folded at build.
    xq = _ti_lev(
        _ti_op(
            "+", _ti_op("+", z[1] + 0.5, _ti_op("*", _ti_op("-", "l", 1), (z[n] - z[1] - 1.0) / (nl - 1))),
            _ti_op("*", 0.25, _ti_op("sin", "t"))
        )
    )
    cnt = _ti_count("k", n, _ti_op("<=", _ti_ix("axis", "k"), _ti_ix("xq", "l")), ["axis"])
    vars = Dict{String, Any}(
        "xq" => Dict{String, Any}("type" => "unknown", "shape" => ["lev"]),
        "r" => Dict{String, Any}("type" => "unknown", "shape" => ["lev"]),
        "u" => Dict{String, Any}("type" => "unknown", "shape" => ["lev"], "default" => 0.0),
        "axis" => Dict{String, Any}("type" => "unknown", "shape" => ["kk"]),
        "tab" => Dict{String, Any}("type" => "unknown", "shape" => ["kk"]),
        "pn" => Dict{String, Any}("type" => "parameter", "default" => Float64(n - 1)),
    )
    eqs = Any[
        Dict("lhs" => "axis", "rhs" => _ti_const(z)),
        Dict("lhs" => "tab", "rhs" => _ti_const(tab)),
        Dict("lhs" => "xq", "rhs" => xq),
        Dict("lhs" => "r", "rhs" => _ti_lev(_ti_ix("tab", sub(cnt, n)))),
        Dict("lhs" => _ti_dl("u"), "rhs" => _ti_lev(_ti_op("-", _ti_ix("r", "l"), _ti_ix("u", "l")))),
    ]
    Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict("name" => "gather_span"),
        "index_sets" => Dict(
            "lev" => Dict("kind" => "interval", "size" => nl),
            "kk" => Dict("kind" => "interval", "size" => n)
        ),
        "models" => Dict("M" => Dict{String, Any}("variables" => vars, "equations" => eqs))
    )
end

# Every `_ContractionSection` the right-hand side holds, by a walk of `f!`.
function _ti_sections(x, out = Any[], seen = Base.IdSet{Any}())
    x isa _TI._ContractionSection && (push!(out, x); return out)
    (x isa Module || x isa DataType || x isa Number || x isa AbstractString || x isa Symbol) && return out
    isbitstype(typeof(x)) && return out
    x in seen && return out
    push!(seen, x)
    x isa AbstractArray && return out
    for i in 1:nfields(x)
        isdefined(x, i) && _ti_sections(getfield(x, i), out, seen)
    end
    return out
end
_ti_widest(g::Tuple) = isempty(g) ? 0 : max(length(g), maximum(_ti_widest, g))
_ti_widest(_) = 0
_ti_ngens(g::Tuple) = sum(_ti_ngens, g; init = 0)
_ti_ngens(_) = 1

@testset "interpolation template cells around the count (closed-AST phase 4)" begin
    @testset "bracket table reads skip the boundary policy ($shape)" for shape in (:cell, :bil, :scalar)
        doc = _ti_doc(shape, 59; tpl = true)
        dn, tn, _ = _ti_eval(doc, :native)
        di, _, _ = _ti_eval(doc, :interpreter; times = _TI_TIMES[1:3])
        @test _ti_same(Dict(k => v[1:3] for (k, v) in dn), di)
        @test get(tn, :gather_in_range, 0) >= 1
    end

    bracket(c, n) = _ti_op("min", _ti_op("max", c, 1), _ti_op("-", n, 1))
    @testset "subscript $what" for (what, sub, fires) in (
            ("the bracket", bracket, true),
            ("the bracket + 1", (c, n) -> _ti_op("+", bracket(c, n), 1), true),
            ("an unrolled count", nothing, true),
            ("the bare count (can be 0)", (c, n) -> c, false),
            ("past the axis (bracket of n, + 1)",
                (c, n) -> _ti_op("+", _ti_op("min", _ti_op("max", c, 1), n), 1), false),
            ("with a non-integer literal", (c, n) -> _ti_op("+", bracket(c, n), 0.25), false),
            ("clamped by a parameter", (c, n) -> _ti_op("min", _ti_op("max", c, 1), "pn"), false),
        )
        # A count shorter than the loop floor is unrolled into a seeded sum.
        doc = sub === nothing ? _ti_sub_doc(bracket; n = 5) : _ti_sub_doc(sub)
        dn, tn, _ = _ti_eval(doc, :native)
        di, _, _ = _ti_eval(doc, :interpreter; times = _TI_TIMES[1:3])
        @test _ti_same(Dict(k => v[1:3] for (k, v) in dn), di)
        @test (get(tn, :gather_in_range, 0) >= 1) == fires
    end

    @testset "two-dimensional nest with a state consumer" begin
        n, ni, nj = 9, 7, 5
        z = _ti_z(n)
        tab = _ti_tabs(n)[2]
        ij(e) = Dict{String, Any}(
            "op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
            "ranges" => Dict("i" => Dict("from" => "ii"), "j" => Dict("from" => "jj")), "expr" => e
        )
        # The query reads the state, so the lookup is recomputed every call.
        x = _ti_op(
            "+", _ti_op("*", _ti_op("+", "i", _ti_op("*", 3, "j")), z[n] / (ni + 3 * nj)),
            _ti_op("*", 50.0, _ti_ix("u", "i", "j"))
        )
        look = _ti_apply("linear"; table = _ti_const(tab), axis = _ti_const(z), x = x, n = n)
        doc = Dict{String, Any}(
            "esm" => "1.2.0", "metadata" => Dict("name" => "nest_2d_consumer"),
            "index_sets" => Dict(
                "ii" => Dict("kind" => "interval", "size" => ni),
                "jj" => Dict("kind" => "interval", "size" => nj)
            ),
            "models" => Dict(
                "M" => Dict{String, Any}(
                    "variables" => Dict{String, Any}(
                        "r" => Dict{String, Any}("type" => "unknown", "shape" => ["ii", "jj"]),
                        "u" => Dict{String, Any}("type" => "unknown", "shape" => ["ii", "jj"], "default" => 1.0),
                    ),
                    "equations" => Any[
                        Dict("lhs" => "r", "rhs" => ij(look)),
                        Dict(
                            "lhs" => ij(_ti_op("D", _ti_ix("u", "i", "j"); wrt = "t")),
                            "rhs" => ij(_ti_op("-", _ti_ix("r", "i", "j"), _ti_ix("u", "i", "j")))
                        ),
                    ],
                    "expression_templates" => _ti_templates(),
                )
            )
        )
        dn, tn, _ = _ti_eval(doc, :native)
        di, _, _ = _ti_eval(doc, :interpreter)
        @test _ti_same(dn, di)
        @test get(tn, :array_contraction_consumer, 0) >= 1
    end

    @testset "a section of more contractions than inference unrolls" begin
        n, nl, m = 5, 17, 24
        z = _ti_z(n)
        vars = Dict{String, Any}(
            "xq" => Dict{String, Any}("type" => "unknown", "shape" => ["lev"]),
            "u" => Dict{String, Any}("type" => "unknown", "shape" => ["lev"], "default" => 0.0),
        )
        eqs = Any[Dict("lhs" => "xq", "rhs" => _ti_lev(_ti_op("+", _ti_op("*", "l", z[n] / nl), _ti_op("*", 30.0, _ti_op("sin", "t")))))]
        terms = Any[]
        for j in 1:m
            vars["r$j"] = Dict{String, Any}("type" => "unknown", "shape" => ["lev"])
            tab = Float64[j + 0.125 * k * k for k in 1:n]
            push!(eqs, Dict("lhs" => "r$j", "rhs" => _ti_lev(_ti_apply("linear"; table = _ti_const(tab), axis = _ti_const(z), x = _ti_ix("xq", "l"), n = n))))
            push!(terms, _ti_ix("r$j", "l"))
        end
        push!(eqs, Dict("lhs" => _ti_dl("u"), "rhs" => _ti_lev(_ti_op("-", _ti_op("+", terms...), _ti_ix("u", "l")))))
        doc = Dict{String, Any}(
            "esm" => "1.2.0", "metadata" => Dict("name" => "many_contractions"),
            "index_sets" => Dict("lev" => Dict("kind" => "interval", "size" => nl)),
            "models" => Dict("M" => Dict{String, Any}("variables" => vars, "equations" => eqs, "expression_templates" => _ti_templates()))
        )
        dn, tn, (f!, u0, p) = _ti_eval(doc, :native)
        di, _, _ = _ti_eval(doc, :interpreter)
        @test _ti_same(dn, di)
        @test get(tn, :array_contraction_codegen, 0) >= m
        secs = _ti_sections(f!)
        @test sum(s -> _ti_ngens(s.gens), secs) >= m
        @test all(s -> _ti_widest(s.gens) <= _TI._SECTION_TUPLE_WIDTH, secs)
        if VERSION >= v"1.12"
            du = similar(u0)
            f!(du, u0, p, 0.3)
            @test (@allocated f!(du, u0, p, 0.4)) == 0
        end
    end
end

# A scalar program whose class is split through the cache stores slots and
# reads them back inside one generated function. A scalar site whose queries
# read the state and t, at node caps small enough to split it: each read-back
# sees this call's store, against the interpreter, bit for bit.
@testset "scalar program split through the cache reads back its stores (cap $cap)" for cap in (100, 300, 1000)
    n = 9
    z = _ti_z(n)
    t2, ya = _ti_rows(_ti_t2(n)), _ti_ya()
    x = _ti_op("+", 0.5 * z[end], _ti_op("+", _ti_op("*", 100.0, "u"), _ti_op("*", 30.0, "t")))
    y = _ti_op("+", 2.25, _ti_op("+", "u", _ti_op("*", 0.001, "t")))
    look = _ti_apply(
        "bilinear"; table = _ti_const(t2), axis_x = _ti_const(z), axis_y = _ti_const(ya),
        x = x, y = y, nx = n, ny = _TI_NY
    )
    model = Dict{String, Any}(
        "variables" => Dict{String, Any}("u" => Dict{String, Any}("type" => "unknown", "default" => 0.0)),
        "equations" => Any[
            Dict("lhs" => _ti_op("D", "u"; wrt = "t"), "rhs" => _ti_op("-", _ti_op("*", 1.0e-6, look), "u")),
        ],
        "expression_templates" => _ti_templates(),
    )
    doc = Dict{String, Any}("esm" => "1.2.0", "metadata" => Dict("name" => "site"), "models" => Dict("M" => model))
    withenv("ESS_CODEGEN_FN_NODE_CAP" => string(cap)) do
        dn, _, _ = _ti_eval(doc, :native)
        di, _, _ = _ti_eval(doc, :interpreter)
        @test _ti_same(dn, di)
    end
end
