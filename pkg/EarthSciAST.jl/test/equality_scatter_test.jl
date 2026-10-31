# One-pass scatter for an equality filter on an output index (scatter.jl,
# esm-spec §4.3.1).
#
# A `faq` whose filter pins an output index by equality (`j == i + 1`) admits
# each contracted point into one output cell. `compiler = :native` folds it as
# one pass over the contracted box (a build-time TABLE when every key is static,
# a generated pass when a key reads a run-time value); `compiler = :interpreter`
# keeps the naive guarded fold over the whole output × contracted box. A key
# that is a ±1 shift of its own contracted index takes the SHIFT form instead:
# the equation is split into pieces the cascade takes as ordinary equations. What is
# pinned here:
#
#   * BIT-IDENTITY of native against the interpreter, on data whose sum changes
#     with the association (`[1e16, 1, -1e16, 1]`), under +, *, max and min
#     (with a NaN in a window), for every shape the rule names;
#   * that the scatter actually FIRED (`:equality_scatter_shift`,
#     `:equality_scatter_table` or `:equality_scatter_pass` in the cascade
#     tally) — a silent decline would make every comparison pass trivially;
#   * that the run-time call allocates nothing and the cost grows linearly.

using Test
using EarthSciAST
using ForwardDiff
using JSON3

const ESX = EarthSciAST

_sx(op, args...; kw...) = Dict{String, Any}(
    "op" => op, "args" => Any[args...],
    (String(k) => v for (k, v) in kw)...
)
_sxi(v, is...) = _sx("index", v, is...)
_sxk(arr) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => arr)
_sxD(v, is...) = _sx("D", _sxi(v, is...); wrt = "t")

# The left-hand side `D(v[is…])` over the index sets `sets`.
_sx_lhs(v, is, sets) = _sx(
    "faq"; output_idx = Any[is...], expr = _sxD(v, is...),
    ranges = Dict{String, Any}(i => Dict("from" => s) for (i, s) in zip(is, sets))
)

# A document with the state `u` (shape `ushape`, held fixed), an optional
# key state `s` (shape `[length(s_vals)]`, held fixed), and `c` over the output
# sets with `D(c[outs…]) = rhs`. `zp` is a scalar parameter with default 0.0
# that a key adds to make itself a run-time key.
function _sx_doc(
        rhs; outs::Vector{String}, osizes::Vector{Int}, ushape::Vector{Int},
        nkeys::Int = 0, rhs_is_whole::Bool = false
    )
    isets = Dict{String, Any}()
    osets = String["O$(d)" for d in eachindex(outs)]
    for (s, n) in zip(osets, osizes)
        isets[s] = Dict("kind" => "interval", "size" => n)
    end
    usets = String["U$(d)" for d in eachindex(ushape)]
    for (s, n) in zip(usets, ushape)
        isets[s] = Dict("kind" => "interval", "size" => n)
    end
    uis = String["a$(d)" for d in eachindex(ushape)]
    zero_u = _sx(
        "faq"; output_idx = Any[uis...], expr = 0.0,
        ranges = Dict{String, Any}(i => Dict("from" => s) for (i, s) in zip(uis, usets))
    )
    vars = Dict{String, Any}(
        "u" => Dict("type" => "unknown", "shape" => usets, "default" => 0.0),
        "c" => Dict("type" => "unknown", "shape" => osets, "default" => 0.0),
        "zp" => Dict("type" => "parameter", "default" => 0.0)
    )
    eqs = Any[
        Dict("lhs" => _sx_lhs("u", uis, usets), "rhs" => zero_u),
        Dict(
            "lhs" => rhs_is_whole ? _sx("D", "c"; wrt = "t") : _sx_lhs("c", outs, osets),
            "rhs" => rhs
        ),
    ]
    if nkeys > 0
        isets["K"] = Dict("kind" => "interval", "size" => nkeys)
        vars["s"] = Dict("type" => "unknown", "shape" => ["K"], "default" => 0.0)
        push!(
            eqs, Dict(
                "lhs" => _sx_lhs("s", ["q"], ["K"]),
                "rhs" => _sx("faq"; output_idx = Any["q"], expr = 0.0, ranges = Dict("q" => Dict("from" => "K")))
            )
        )
    end
    return Dict{String, Any}(
        "esm" => "1.2.0", "metadata" => Dict("name" => "sx"),
        "index_sets" => isets,
        "models" => Dict("M" => Dict{String, Any}("variables" => vars, "equations" => eqs))
    )
end

# The scattering faq itself.
_sx_faq(; outs, osizes, cr, filt, body, reduce = "+") = _sx(
    "faq"; output_idx = Any[outs...], expr = body, reduce = reduce, filter = filt,
    ranges = merge(
        Dict{String, Any}(o => Dict("from" => "O$(d)") for (d, o) in enumerate(outs)),
        Dict{String, Any}(k => Any[v...] for (k, v) in cr)
    )
)

# Initial conditions: `u` from `uval(idx...)`, `s` from `svals`.
function _sx_ics(ushape, uval; svals = Float64[])
    ics = Dict{String, Any}()
    for I in CartesianIndices(Tuple(ushape))
        t = Tuple(I)
        ics["u[" * join(t, ",") * "]"] = Float64(uval(t...))
    end
    for (q, v) in enumerate(svals)
        ics["s[$q]"] = v
    end
    return ics
end

function _sx_run(doc, ics; compiler = :native)
    ESX._reset_cascade_tally!()
    f!, u0, p, _t, vm = ESX._build_evaluator(doc; initial_conditions = ics, compiler = compiler)
    tally = copy(ESX._CASCADE_TALLY)
    du = fill(NaN, length(u0))
    f!(du, u0, p, 0.0)
    names = sort!(String[k for k in keys(vm) if startswith(k, "c[")])
    return (
        du = Float64[du[vm[k]] for k in names], names = names, tally = tally,
        f! = f!, u0 = u0, p = p, vm = vm,
    )
end

_sx_bits(v) = reinterpret(UInt64, v)
_sx_fired(t) = get(t, :equality_scatter_table, 0) + get(t, :equality_scatter_pass, 0) +
    get(t, :equality_scatter_shift, 0)

# native ≡ interpreter bit for bit, with the scatter fired (`form` = :table or
# :pass, or `nothing` to only require one of them).
function _sx_check(doc, ics; form = nothing, nfired = 1)
    a = _sx_run(doc, ics)
    b = _sx_run(doc, ics; compiler = :interpreter)
    @test a.names == b.names
    @test _sx_bits(a.du) == _sx_bits(b.du)
    if form === :shift
        @test get(a.tally, :equality_scatter_shift, 0) == nfired
    elseif form === :table
        @test get(a.tally, :equality_scatter_table, 0) == nfired
    elseif form === :pass
        @test get(a.tally, :equality_scatter_pass, 0) == nfired
    else
        @test _sx_fired(a.tally) == nfired
    end
    @test _sx_fired(b.tally) == 0
    return a, b
end

# A static key `e`, and the same key read through the parameter `zp`
# (default 0.0), which makes it a run-time key.
_sx_rt(e) = _sx("+", e, "zp")

const _SX_CANCEL = (1.0e16, 1.0, -1.0e16, 1.0)

@testset "one-pass equality scatter (scatter.jl)" begin

    @testset "+ on cancelling data keeps the visit order" begin
        # Cell j receives the points (i = j, k = 1..4): `((1e16 + 1) - 1e16) + 1`
        # is 1.0 in the naive order and something else in any other.
        for key in ("i", _sx("+", _sx("-", "i", 1), 1)), rt in (false, true)
            e = rt ? _sx_rt(key) : key
            rhs = _sx_faq(
                outs = ["j"], osizes = [4], cr = Dict("i" => [1, 4], "k" => [1, 4]),
                filt = _sx("==", "j", e), body = _sxi("u", "i", "k")
            )
            doc = _sx_doc(rhs; outs = ["j"], osizes = [4], ushape = [4, 4])
            a, _ = _sx_check(doc, _sx_ics([4, 4], (i, k) -> _SX_CANCEL[k]); form = rt ? :pass : :shift)
            @test all(==(1.0), a.du)
        end
        # Pinned by the SLOW contracted index (k), the terms of a cell run along
        # the fast one.
        rhs = _sx_faq(
            outs = ["j"], osizes = [4], cr = Dict("i" => [1, 4], "k" => [1, 4]),
            filt = _sx("==", "k", "j"), body = _sxi("u", "i", "k")
        )
        doc = _sx_doc(rhs; outs = ["j"], osizes = [4], ushape = [4, 4])
        a, _ = _sx_check(doc, _sx_ics([4, 4], (i, k) -> _SX_CANCEL[i]); form = :shift)
        @test all(==(1.0), a.du)
        # Many points to one cell through a `const` gather (a static key the
        # build evaluates through the compiled node, not an affine form).
        map8 = [1, 1, 1, 1, 2, 2, 2, 2]
        for rt in (false, true)
            e = _sxi(_sxk(map8), "i")
            rhs = _sx_faq(
                outs = ["j"], osizes = [3], cr = Dict("i" => [1, 8]),
                filt = _sx("==", rt ? _sx_rt(e) : e, "j"), body = _sxi("u", "i")
            )
            doc = _sx_doc(rhs; outs = ["j"], osizes = [3], ushape = [8])
            a, _ = _sx_check(doc, _sx_ics([8], i -> _SX_CANCEL[mod1(i, 4)]); form = rt ? :pass : :table)
            @test a.du == [1.0, 1.0, 0.0]
        end
    end

    @testset "⊕ ∈ {+, *, max, min}, NaN in a window" begin
        map8 = [2, 2, 2, 1, 1, 3, 3, 3]
        vals = [1.0, NaN, 3.0, -2.0, 5.0, 0.5, -0.0, 4.0]
        for red in ("+", "*", "max", "min"), rt in (false, true)
            e = _sxi(_sxk(map8), "i")
            rhs = _sx_faq(
                outs = ["j"], osizes = [4], cr = Dict("i" => [1, 8]), reduce = red,
                filt = _sx("==", "j", rt ? _sx_rt(e) : e),
                body = _sx("*", _sxi("u", "i"), 1.5)
            )
            doc = _sx_doc(rhs; outs = ["j"], osizes = [4], ushape = [8])
            _sx_check(doc, _sx_ics([8], i -> vals[i]); form = rt ? :pass : :table)
        end
    end

    @testset "2-D output, both indices pinned" begin
        for rt in (false, true)
            e1 = _sx("+", "i", 1)
            rhs = _sx_faq(
                outs = ["j1", "j2"], osizes = [5, 4], cr = Dict("i" => [1, 4], "k" => [1, 4]),
                filt = _sx("and", _sx("==", "j1", rt ? _sx_rt(e1) : e1), _sx("==", "k", "j2")),
                body = _sx("*", _sxi("u", "i", "k"), _sx("+", "j1", _sx("*", 0.25, "j2")))
            )
            doc = _sx_doc(rhs; outs = ["j1", "j2"], osizes = [5, 4], ushape = [4, 4])
            _sx_check(doc, _sx_ics([4, 4], (i, k) -> 0.1 * i - 0.3 * k); form = rt ? :pass : :shift)
        end
        # Two pinned keys mapping several points onto each cell, cancelling.
        rhs = _sx_faq(
            outs = ["j1", "j2"], osizes = [2, 2], cr = Dict("i" => [1, 4], "k" => [1, 4]),
            filt = _sx(
                "and", _sx("==", "j1", _sxi(_sxk([1, 1, 2, 2]), "k")),
                _sx("==", "j2", _sxi(_sxk([2, 1, 2, 1]), "i"))
            ),
            body = _sxi("u", "i", "k")
        )
        doc = _sx_doc(rhs; outs = ["j1", "j2"], osizes = [2, 2], ushape = [4, 4])
        _sx_check(doc, _sx_ics([4, 4], (i, k) -> _SX_CANCEL[i] * k); form = :table)
    end

    @testset "a free output index stays an outer loop" begin
        for rt in (false, true), red in ("+", "max")
            e = _sx("+", "i", 1)
            rhs = _sx_faq(
                outs = ["j", "m"], osizes = [5, 3], cr = Dict("i" => [1, 4]), reduce = red,
                filt = _sx("==", "j", rt ? _sx_rt(e) : e),
                body = _sx("*", _sxi("u", "i", "m"), _sx("+", "m", 0.5))
            )
            doc = _sx_doc(rhs; outs = ["j", "m"], osizes = [5, 3], ushape = [4, 3])
            _sx_check(doc, _sx_ics([4, 3], (i, m) -> _SX_CANCEL[i] + m); form = rt ? :pass : :shift)
        end
        # The free index read by a remaining conjunct.
        rhs = _sx_faq(
            outs = ["m", "j"], osizes = [3, 4], cr = Dict("i" => [1, 4], "k" => [1, 3]),
            filt = _sx("and", _sx("<=", "k", "m"), _sx("==", "j", "i")),
            body = _sxi("u", "i", "k")
        )
        doc = _sx_doc(rhs; outs = ["m", "j"], osizes = [3, 4], ushape = [4, 3])
        _sx_check(doc, _sx_ics([4, 3], (i, k) -> _SX_CANCEL[mod1(i + k, 4)]); form = :shift)
    end

    @testset "a key outside the range, or not an integer, is skipped" begin
        for key in (
                    _sx("+", "i", 3), _sx("-", "i", 3), _sx("/", "i", 2),
                    _sx("*", "i", 0.5), _sx("-", 0, "i"),
                ),
                rt in (false, true)
            rhs = _sx_faq(
                outs = ["j"], osizes = [4], cr = Dict("i" => [1, 6]),
                filt = _sx("==", "j", rt ? _sx_rt(key) : key),
                body = _sx("+", _sxi("u", "i"), 1.0)
            )
            doc = _sx_doc(rhs; outs = ["j"], osizes = [4], ushape = [6])
            _sx_check(doc, _sx_ics([6], i -> 10.0 * i); form = rt ? :pass : nothing)
        end
        # Run-time keys read from a state: in range, out of range, non-integer,
        # NaN, negative.
        svals = [2.0, 7.0, 2.5, 1.0, NaN, -1.0, 4.0, 2.0]
        for red in ("+", "min")
            rhs = _sx_faq(
                outs = ["j"], osizes = [4], cr = Dict("i" => [1, 8]), reduce = red,
                filt = _sx("==", _sxi("s", "i"), "j"), body = _sxi("u", "i")
            )
            doc = _sx_doc(rhs; outs = ["j"], osizes = [4], ushape = [8], nkeys = 8)
            a, _ = _sx_check(doc, _sx_ics([8], i -> _SX_CANCEL[mod1(i, 4)] * i; svals = svals); form = :pass)
        end
    end

    @testset "equality together with an ordering conjunct folds ascending" begin
        for rt in (false, true)
            e = "k"
            rhs = _sx_faq(
                outs = ["j"], osizes = [4], cr = Dict("i" => [1, 4], "k" => [1, 4]),
                filt = _sx("and", _sx("==", "j", rt ? _sx_rt(e) : e), _sx("<=", "j", "i")),
                body = _sxi("u", "i", "k")
            )
            doc = _sx_doc(rhs; outs = ["j"], osizes = [4], ushape = [4, 4])
            _sx_check(doc, _sx_ics([4, 4], (i, k) -> _SX_CANCEL[i]); form = rt ? :pass : :table)
        end
        # `i >= j` with an equality: not a reverse scan (the filter is a
        # conjunction), so it folds ascending too.
        rhs = _sx_faq(
            outs = ["j"], osizes = [3], cr = Dict("i" => [1, 8]),
            filt = _sx("and", _sx(">=", "i", "j"), _sx("==", "j", _sxi(_sxk([1, 1, 2, 2, 1, 1, 3, 3]), "i"))),
            body = _sxi("u", "i")
        )
        doc = _sx_doc(rhs; outs = ["j"], osizes = [3], ushape = [8])
        _sx_check(doc, _sx_ics([8], i -> _SX_CANCEL[mod1(i, 4)]); form = :table)
    end

    @testset "one output index pinned twice" begin
        for rt in (false, true)
            rhs = _sx_faq(
                outs = ["j"], osizes = [4], cr = Dict("i" => [1, 4], "k" => [1, 4]),
                filt = _sx("and", _sx("==", "j", rt ? _sx_rt("k") : "k"), _sx("==", "j", _sx("-", 5, "i"))),
                body = _sx("+", _sxi("u", "i", "k"), 0.5)
            )
            doc = _sx_doc(rhs; outs = ["j"], osizes = [4], ushape = [4, 4])
            _sx_check(doc, _sx_ics([4, 4], (i, k) -> 3.0 * i + k); form = rt ? :pass : :shift, nfired = rt ? 1 : 2)
        end
    end

    @testset "a step range on the pinned axis" begin
        # The output axis is the even cells 2, 4, …, 10 of a [2, 2, 10] range.
        for rt in (false, true)
            rhs = _sx(
                "faq"; output_idx = Any["j"], expr = _sxi("u", "i"),
                filter = _sx("==", "j", rt ? _sx_rt(_sx("+", "i", 1)) : _sx("+", "i", 1)),
                ranges = Dict{String, Any}("j" => Any[2, 2, 10], "i" => Any[1, 10])
            )
            doc = _sx_doc(rhs; outs = ["j"], osizes = [5], ushape = [10])
            doc["models"]["M"]["equations"][2]["lhs"] = _sx(
                "faq"; output_idx = Any["j"], expr = _sxD("c", _sx("/", "j", 2)),
                ranges = Dict{String, Any}("j" => Any[2, 2, 10])
            )
            _sx_check(doc, _sx_ics([10], i -> 1.5 * i); form = rt ? :pass : :table)
        end
    end

    @testset "dual numbers take the same fold" begin
        for rt in (false, true)
            e = _sxi(_sxk([1, 1, 1, 1, 2, 2, 2, 2]), "i")
            rhs = _sx_faq(
                outs = ["j"], osizes = [2], cr = Dict("i" => [1, 8]),
                filt = _sx("==", "j", rt ? _sx_rt(e) : e),
                body = _sx("*", _sxi("u", "i"), _sxi("u", "i"))
            )
            doc = _sx_doc(rhs; outs = ["j"], osizes = [2], ushape = [8])
            ics = _sx_ics([8], i -> (-1.0)^i * 10.0^(i - 4))
            a = _sx_run(doc, ics)
            b = _sx_run(doc, ics; compiler = :interpreter)
            seed = Float64[isodd(k) ? 1.0 : -0.5 for k in 1:length(a.u0)]
            jd(r) = ForwardDiff.derivative(
                s -> (du = zeros(typeof(s), length(r.u0)); r.f!(du, r.u0 .+ s .* seed, r.p, 0.0); du), 0.0
            )
            # The two builds lay the state out identically here (same names).
            @test sort(collect(a.vm)) == sort(collect(b.vm))
            @test _sx_bits(jd(a)) == _sx_bits(jd(b))
        end
    end

    @testset "inside an expression: lifted, then scattered" begin
        # The band-transpose shape: `D(c[j]) = -(Σ_{i+1=j} a[i]u[i] +
        # Σ_{i-1=j} b[i]u[i] + c[j]u[j])`, the two sums nested rank-0
        # reductions over the whole set.
        n = 9
        coef(lbl) = _sx("+", 1.0, _sx("*", lbl, _sx("sin", "i")))
        nest(shift, lbl) = _sx(
            "faq"; output_idx = Any[], expr = _sx("*", coef(lbl), _sxi("u", "i")),
            ranges = Dict{String, Any}("i" => Dict("from" => "U1")),
            filter = _sx("==", _sx("+", "i", shift), "j")
        )
        body = _sx(
            "-", _sx(
                "+", nest(1, 0.3), nest(-1, 0.7),
                _sx("*", _sx("+", 2.0, _sx("cos", "j")), _sxi("u", "j"))
            )
        )
        rhs = _sx("faq"; output_idx = Any["j"], expr = body, ranges = Dict("j" => Dict("from" => "O1")))
        doc = _sx_doc(rhs; outs = ["j"], osizes = [n], ushape = [n])
        doc["index_sets"]["O1"] = doc["index_sets"]["U1"]   # one axis
        rhs["ranges"]["j"] = Dict("from" => "U1")
        doc["models"]["M"]["equations"][2]["lhs"] = _sx_lhs("c", ["j"], ["U1"])
        doc["models"]["M"]["variables"]["c"]["shape"] = ["U1"]
        _sx_check(doc, _sx_ics([n], i -> _SX_CANCEL[mod1(i, 4)] * i); nfired = 2)
        # The same with whole-array arithmetic over two array producers.
        prod(shift, lbl) = _sx(
            "faq"; output_idx = Any["j"], expr = _sx("*", coef(lbl), _sxi("u", "i")),
            ranges = Dict{String, Any}("j" => Dict("from" => "U1"), "i" => Dict("from" => "U1")),
            filter = _sx("==", _sx("+", "i", shift), "j")
        )
        whole = _sx("-", _sx("+", prod(1, 0.3), prod(-1, 0.7)))
        doc2 = deepcopy(doc)
        doc2["models"]["M"]["equations"][2] = Dict("lhs" => _sx("D", "c"; wrt = "t"), "rhs" => whole)
        _sx_check(doc2, _sx_ics([n], i -> _SX_CANCEL[mod1(i, 4)] * i); nfired = 2)
    end

    @testset "a makearray region value" begin
        n = 8
        scat = _sx(
            "faq"; output_idx = Any["j"], expr = _sxi("u", "i"),
            ranges = Dict{String, Any}("j" => Any[1, n - 1], "i" => Any[1, n]),
            filter = _sx("==", "j", _sx("-", "i", 1))
        )
        tail = _sx("faq"; output_idx = Any["j"], expr = 7.0, ranges = Dict{String, Any}("j" => Any[n, n]))
        # `D(c) = makearray(…)`: the region holding the scatter becomes its own
        # equation (`_makearray_region_equations`), which the scatter takes.
        ma = _sx("makearray"; regions = Any[Any[Any[1, n - 1]], Any[Any[n, n]]], values = Any[scat, tail])
        doc = _sx_doc(ma; outs = ["j"], osizes = [n], ushape = [n], rhs_is_whole = true)
        _sx_check(doc, _sx_ics([n], i -> _SX_CANCEL[mod1(i, 4)] * i); form = :shift)
    end

    @testset "a ragged range whose parent is contracted is left to the nest" begin
        # `pm[j] = Σ_{r, k ∈ row r : j == block(rowMem[r,k])}`: `k`'s range reads
        # the contracted `r`, so the terms are a nest (parent outer), not the
        # product the scatter walks. The scatter declines it and the nest's
        # table form takes it, equal to the interpreter.
        path = joinpath(
            @__DIR__, "..", "..", "..", "tests", "conformance", "faq_equality_scatter",
            "fixtures", "ragged_contracted_parent.esm"
        )
        doc = JSON3.read(read(path, String), Dict{String, Any})
        dus = map((:native, :interpreter)) do c
            ESX._reset_cascade_tally!()
            f!, u0, p, _t, vm = ESX._build_evaluator(doc; model_name = "Scatter", compiler = c)
            tally = copy(ESX._CASCADE_TALLY)
            du = fill(NaN, length(u0))
            f!(du, u0, p, 0.0)
            names = sort!(collect(keys(vm)))
            (Float64[du[vm[nm]] for nm in names], tally)
        end
        @test _sx_bits(dus[1][1]) == _sx_bits(dus[2][1])
        @test _sx_fired(dus[1][2]) == 0
    end

    @testset "EarthSciASTDiff product documents" begin
        # Copied from EarthSciASTDiff's tests/goldens (68fe059): Jᵀλ and hvp
        # products spelled as whole-array sums of equality-filtered faqs over
        # integer output bounds. Native refused every one of these before the
        # scatter; now it builds them and agrees with the interpreter at a
        # state of mixed 1e8 magnitudes.
        dir = joinpath(@__DIR__, "fixtures", "equality_scatter")
        for f in sort(readdir(dir))
            doc = JSON3.read(read(joinpath(dir, f), String), Dict{String, Any})
            model = String(first(keys(doc["models"])))
            dus = map((:native, :interpreter)) do c
                ESX._reset_cascade_tally!()
                f!, u0, p, _t, vm = ESX._build_evaluator(doc; model_name = model, compiler = c)
                tally = copy(ESX._CASCADE_TALLY)
                names = sort!(collect(keys(vm)))
                u = copy(u0)
                for (r, nm) in enumerate(names)
                    u[vm[nm]] = (isodd(r) ? 1.0e8 : -0.5) * (0.5 + 0.3 * sin(1.7 * r))
                end
                du = fill(NaN, length(u0))
                f!(du, u, p, 0.0)
                (Float64[du[vm[nm]] for nm in names], tally)
            end
            @test _sx_bits(dus[1][1]) == _sx_bits(dus[2][1])
            @test _sx_fired(dus[1][2]) >= 1
            @test _sx_fired(dus[2][2]) == 0
        end
    end

    @testset "the call allocates nothing and scales linearly" begin
        band(n; rt = false) = begin
            sh(s) = rt ? _sx_rt(_sx("+", "i", s)) : _sx("+", "i", s)
            prod(shift, lbl) = _sx(
                "faq"; output_idx = Any["j"],
                expr = _sx("*", _sx("+", 1.0, _sx("*", lbl, _sx("sin", "i"))), _sxi("u", "i")),
                ranges = Dict{String, Any}("j" => Dict("from" => "U1"), "i" => Dict("from" => "U1")),
                filter = _sx("==", sh(shift), "j")
            )
            d = _sx_doc(_sx("-", _sx("+", prod(1, 0.3), prod(-1, 0.7))); outs = ["j"], osizes = [n], ushape = [n], rhs_is_whole = true)
            d["models"]["M"]["variables"]["c"]["shape"] = ["U1"]
            d
        end
        for rt in (false, true)
            times = Float64[]
            for n in (100_000, 1_000_000)
                ESX._reset_cascade_tally!()
                bt = @elapsed (f!, u0, p, _t, vm) = ESX._build_evaluator(band(n; rt = rt); compiler = :native)
                t = copy(ESX._CASCADE_TALLY)
                @test _sx_fired(t) == 2
                du = similar(u0)
                f!(du, u0, p, 0.0)
                f!(du, u0, p, 0.0)
                @test (@allocated f!(du, u0, p, 0.0)) == 0
                push!(times, minimum(@elapsed(f!(du, u0, p, 0.0)) for _ in 1:5))
                @test bt < 120.0
            end
            # Ten times the cells: far from the hundredfold a dense fold costs.
            @test times[2] / times[1] < 30.0
        end
    end
end
