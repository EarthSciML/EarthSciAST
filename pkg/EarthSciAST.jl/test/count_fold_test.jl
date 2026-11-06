# The indicator sum emitted as a count (#588).
#
# A contraction loop folding `ifelse(a[k] <= x, 1, 0)` (or the mirrored
# `x >= a[k]`) from +0.0 is the number of entries of `a` at or below `x` — the
# bracket of a table interpolation written in the format's own operators. The
# emitter writes it as an integer count (`:count_fold_linear`), and as a binary
# search when `a` is an ascending 1-D constant array read at the counter
# (`:count_fold_search`). This pins:
#
#   * BIT-IDENTITY, `===` per element, against `compiler = :interpreter` (which
#     unrolls the indicator sum term by term) and against native with the
#     rewrite off, at N = 59 and N = 200, for a constant axis, a state axis, an
#     unsorted or NaN-holding constant axis, both comparison spellings, inside
#     the whole-array nest and in a scalar equation. The queries hit the axis
#     entries exactly, their neighbouring floats, ±0.0, ±Inf, NaN and both ends;
#   * every near miss — another reducer, other branch values, a strict or
#     reversed comparison, a query that reads the counter, a filter, a short
#     range — keeps the fold: the rewrite never fires and the answer is the
#     interpreter's;
#   * zero allocation per call, and ForwardDiff through the count.

using Test
using ForwardDiff
include("testutils.jl")
include("zero_alloc_harness.jl")

const _CF = EarthSciAST

_cf_idx(a, s...) = Dict{String, Any}("op" => "index", "args" => Any[a, s...])
_cf_op(o, a...) = Dict{String, Any}("op" => o, "args" => Any[a...])
_cf_const(v) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => v)
_cf_faq1(i, n, body) = Dict{String, Any}(
    "op" => "faq", "output_idx" => Any[i], "args" => Any[],
    "ranges" => Dict(i => Any[1, n]), "expr" => body
)

# Exact in binary64 and holding 0.0 (k = 3), so ±0.0 queries meet an entry.
_cf_axis(n) = [(k - 3) / 2 for k in 1:n]

# The body of the count: `a` is the axis read at `k`, `x` the query.
_cf_le(a, x) = _cf_op("ifelse", _cf_op("<=", a, x), 1, 0)
_cf_ge(a, x) = _cf_op("ifelse", _cf_op(">=", x, a), 1, 0)

function _cf_count(n, body; reduce = "+", filter = nothing)
    c = Dict{String, Any}(
        "op" => "faq", "output_idx" => Any[], "reduce" => reduce,
        "args" => Any[], "ranges" => Dict("k" => Any[1, n]), "expr" => body
    )
    filter === nothing || (c["filter"] = filter)
    return c
end

# D(q[i]) = Σ_k body(axis[k], q[i]): the query is the state itself, so every
# call recomputes the count. `axis` is `:const` (an inline constant array),
# `:state` (an ODE state with zero tendency) or a vector (an inline constant
# array with those entries).
function _cf_doc(n; axis = :const, body = _cf_le, kw...)
    av = axis isa AbstractVector ? _cf_const(axis) :
        axis === :const ? _cf_const(_cf_axis(n)) : "zax"
    vars = Dict{String, Any}("q" => Dict("type" => "unknown", "shape" => Any["lev"]))
    eqs = Any[]
    if axis === :state
        vars["zax"] = Dict("type" => "unknown", "shape" => Any["lev"])
        push!(
            eqs, Dict(
                "lhs" => _cf_faq1("lev", n, Dict("op" => "D", "args" => Any[_cf_idx("zax", "lev")], "wrt" => "t")),
                "rhs" => _cf_faq1("lev", n, 0.0)
            )
        )
    end
    cnt = _cf_count(n, body(_cf_idx(av, "k"), _cf_idx("q", "lev")); kw...)
    push!(
        eqs, Dict(
            "lhs" => _cf_faq1("lev", n, Dict("op" => "D", "args" => Any[_cf_idx("q", "lev")], "wrt" => "t")),
            "rhs" => _cf_faq1("lev", n, cnt)
        )
    )
    return Dict{String, Any}(
        "esm" => "1.1.0", "metadata" => Dict("name" => "count_fold"),
        "models" => Dict("M" => Dict{String, Any}("variables" => vars, "equations" => eqs))
    )
end

# The queries, cycled over the cells: each axis entry exactly and its two
# neighbouring floats, the midpoints, ±0.0, ±Inf, NaN and far outside.
function _cf_queries(n)
    z = _cf_axis(n)
    pool = Float64[-0.0, 0.0, NaN, Inf, -Inf, -1.0e9, 1.0e9]
    for v in z
        push!(pool, v, prevfloat(v), nextfloat(v), v + 0.25)
    end
    return [pool[mod1(7i, length(pool))] for i in 1:n]
end

function _cf_ics(n; axis = :const)
    ics = Dict{String, Any}("q[$i]" => x for (i, x) in enumerate(_cf_queries(n)))
    axis === :state && merge!(ics, Dict{String, Any}("zax[$i]" => z for (i, z) in enumerate(_cf_axis(n))))
    return ics
end

const _CF_NOFOLD = _CF._plan_with(_CF._compiler_plan(:native); count_fold = false)

# `(f!, u0, p, vmap, tally)` under `compiler` (a vocabulary value or a plan).
function _cf_build(doc, ics, compiler)
    _CF._reset_cascade_tally!()
    f!, u0, p, _, vm = compiler isa Symbol ?
        EarthSciAST._build_evaluator(doc; initial_conditions = ics, compiler = compiler) :
        _CF._with_compiler_plan(compiler) do
            _CF._build_evaluator_dict(doc; initial_conditions = ics, compiler = compiler)
    end
    return (f!, u0, p, vm, copy(_CF._CASCADE_TALLY))
end

# `du` at the initial state, keyed by variable name so builds compare by name.
function _cf_du(doc, ics, compiler)
    f!, u0, p, vm, tally = _cf_build(doc, ics, compiler)
    du = similar(u0); f!(du, u0, p, 0.0)
    return (Dict(k => du[v] for (k, v) in vm), tally)
end

_cf_fired(t) = get(t, :count_fold_search, 0) + get(t, :count_fold_linear, 0)
_cf_same(a, b) = keys(a) == keys(b) && all(a[k] === b[k] for k in keys(a))

# Native (with and without the rewrite) against the interpreter; returns the
# native tally.
function _cf_agree(doc, ics)
    dn, tn = _cf_du(doc, ics, :native)
    df, tf = _cf_du(doc, ics, _CF_NOFOLD)
    di, ti = _cf_du(doc, ics, :interpreter)
    @test _cf_same(dn, di)
    @test _cf_same(df, di)
    @test _cf_fired(tf) == 0
    @test _cf_fired(ti) == 0
    return (tn, dn)
end

@testset "indicator sum emitted as a count (#588)" begin

    @testset "constant ascending axis: binary search, N=$N, $rel" for N in (59, 200),
            (rel, body) in (("<=", _cf_le), (">=", _cf_ge))
        doc, ics = _cf_doc(N; body = body), _cf_ics(N)
        tn, dn = _cf_agree(doc, ics)
        @test get(tn, :count_fold_search, 0) >= 1
        @test get(tn, :count_fold_linear, 0) == 0
        # Anchored on the count itself, so the builds could not agree on a
        # wrong answer.
        z = _cf_axis(N)
        @test all(
            dn["q[$i]"] === Float64(count(<=(x), z))
                for (i, x) in enumerate(_cf_queries(N))
        )
    end

    @testset "state axis: linear count, N=$N, $rel" for N in (59, 200),
            (rel, body) in (("<=", _cf_le), (">=", _cf_ge))
        doc, ics = _cf_doc(N; axis = :state, body = body), _cf_ics(N; axis = :state)
        tn, _ = _cf_agree(doc, ics)
        @test get(tn, :count_fold_linear, 0) >= 1
        @test get(tn, :count_fold_search, 0) == 0
    end

    # A constant axis that does not ascend is counted entry by entry, and one
    # that ascends only under `<=` (a -0.0 after a 0.0) is searched: the count
    # is exact for any content, so either agrees.
    @testset "constant axis of any content ($what)" for (what, ax) in (
            ("unsorted", reverse(_cf_axis(59))),
            ("NaN entry", [k == 30 ? NaN : (k - 3) / 2 for k in 1:59]),
            ("-0.0 after 0.0", [k == 4 ? -0.0 : (k - 3) / 2 for k in 1:59]),
        )
        doc, ics = _cf_doc(59; axis = ax), _cf_ics(59)
        tn, dn = _cf_agree(doc, ics)
        @test _cf_fired(tn) >= 1
        @test all(
            dn["q[$i]"] === Float64(count(<=(x), ax))
                for (i, x) in enumerate(_cf_queries(59))
        )
    end

    # Equal entries ascend too (`a[k] <= a[k+1]`), and the predicate still
    # holds on a prefix.
    @testset "constant axis with repeated entries: binary search" begin
        ax = [floor((k - 3) / 4) for k in 1:59]
        doc, ics = _cf_doc(59; axis = ax), _cf_ics(59)
        tn, dn = _cf_agree(doc, ics)
        @test get(tn, :count_fold_search, 0) >= 1
        @test all(
            dn["q[$i]"] === Float64(count(<=(x), ax))
                for (i, x) in enumerate(_cf_queries(59))
        )
    end

    # The same shape in a scalar equation, which the scalar codegen tier emits.
    @testset "scalar equation, $what axis" for what in (:const, :unsorted)
        N = 59
        ax = what === :const ? _cf_axis(N) : reverse(_cf_axis(N))
        qs = _cf_queries(N)[1:6]
        vars = Dict{String, Any}("s$j" => Dict("type" => "unknown") for j in 1:6)
        eqs = Any[
            Dict(
                "lhs" => Dict("op" => "D", "args" => Any["s$j"], "wrt" => "t"),
                "rhs" => _cf_count(N, _cf_le(_cf_idx(_cf_const(ax), "k"), "s$j"))
            ) for j in 1:6
        ]
        doc = Dict{String, Any}(
            "esm" => "1.1.0", "metadata" => Dict("name" => "count_fold_scalar"),
            "models" => Dict("M" => Dict{String, Any}("variables" => vars, "equations" => eqs))
        )
        ics = Dict{String, Any}("s$j" => qs[j] for j in 1:6)
        tn, dn = _cf_agree(doc, ics)
        @test _cf_fired(tn) >= 1
        @test all(dn["s$j"] === Float64(count(<=(qs[j]), ax)) for j in 1:6)
    end

    # Every near miss keeps the fold: the rewrite does not fire, and the answer
    # is still the interpreter's.
    near = (
        ("branch values 2/0", (a, x) -> _cf_op("ifelse", _cf_op("<=", a, x), 2, 0), (;)),
        ("branches swapped", (a, x) -> _cf_op("ifelse", _cf_op("<=", a, x), 0, 1), (;)),
        ("strict <", (a, x) -> _cf_op("ifelse", _cf_op("<", a, x), 1, 0), (;)),
        ("x <= a[k]", (a, x) -> _cf_op("ifelse", _cf_op("<=", x, a), 1, 0), (;)),
        ("a[k] >= x", (a, x) -> _cf_op("ifelse", _cf_op(">=", a, x), 1, 0), (;)),
        ("query reads k", (a, x) -> _cf_le(a, _cf_op("+", x, "k")), (;)),
        ("bare comparison", (a, x) -> _cf_op("<=", a, x), (;)),
        ("max reducer", _cf_le, (; reduce = "max")),
        ("filter", _cf_le, (; filter = _cf_op(">=", "k", 2))),
    )
    @testset "near miss declines: $what" for (what, body, kw) in near
        doc, ics = _cf_doc(59; body = body, kw...), _cf_ics(59)
        tn, _ = _cf_agree(doc, ics)
        @test _cf_fired(tn) == 0
    end

    @testset "near miss declines: range below the loop floor" begin
        doc, ics = _cf_doc(5), _cf_ics(5)
        tn, _ = _cf_agree(doc, ics)
        @test _cf_fired(tn) == 0
    end

    if VERSION >= v"1.12"
        @testset "zero allocation per call ($axis axis)" for axis in (:const, :state)
            doc, ics = _cf_doc(59; axis = axis), _cf_ics(59; axis = axis)
            f!, u0, p, _, _ = _cf_build(doc, ics, :native)
            du = similar(u0)
            @test rhs_alloc_bytes(f!, du, u0, p, 0.0) == 0
        end
    end

    # The count carries no partials, as the fold of 0.0/1.0 literals does not;
    # the Jacobian through it matches the fold's bit for bit. Finite queries
    # away from the entries, so the derivative exists.
    @testset "ForwardDiff through the count ($axis axis)" for axis in (:const, :state)
        N = 59
        doc = _cf_doc(N; axis = axis)
        ics = _cf_ics(N; axis = axis)
        for i in 1:N
            ics["q[$i]"] = (i - 3) / 2 + 0.3
        end
        jac(c) = begin
            f!, u0, p, vm, _ = _cf_build(doc, ics, c)
            g(u) = (d = similar(u, eltype(u)); f!(d, u, p, 0.0); d)
            (ForwardDiff.jacobian(g, u0), g(u0))
        end
        Jn, vn = jac(:native)
        Jf, vf = jac(_CF_NOFOLD)
        @test all(Jn .=== Jf)
        @test all(vn .=== vf)
    end
end
