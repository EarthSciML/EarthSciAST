# A prefix scan as a `makearray` region value, and as an operand of whole-array
# arithmetic, under compiler=:native (issue #533).
#
# EarthSciDiscretizations lowers `integral(f, lev, z_sfc, lev_nodes)` to a
# two-region `makearray` over the interfaces: the exclusive prefix scan of
# `f·dz` on interfaces 1..N and the rank-0 column total on N+1. Its centre form
# is `prefix_scan + 0.5·f·dz`, whole-array arithmetic over the aggregate. Both
# used to reach the array-equation cascade with the aggregate hidden inside a
# gather, where only the per-cell build takes it, and a strict compiler refused
# them. The build now fills the makearray one region at a time and lifts the
# filtered operand to its own observed (build.jl `_materialized_fill_equations`,
# hoist.jl `_hoist_operand_walk`), so the scans take the O(N) scan fold (a
# reverse one descending, esm-spec §4.3.1).
#
# Pinned here: native builds each shape, the scan fold fired for the forward
# scans, the right-hand side is bit-identical to the interpreter's on inputs of
# catastrophic magnitude (a reassociated fold would not reproduce them), and it
# allocates nothing on a steady call.
using Test
include("testutils.jl")

using EarthSciAST
using ForwardDiff
const ESM_MSR = EarthSciAST

_msr_val(k) = (1.0 - 2.0 * (k % 2)) * 10.0^(((k * 7) % 17) - 8)

_msr_set(n) = ESM_MSR.IndexSetRef(n)

_msr_agg(body, rng::Pair...) = ESM_MSR.OpExpr("faq", ESM_MSR.ASTExpr[];
    output_idx=Any[first(r) for r in rng],
    ranges=Dict{String,Any}(first(r) => _msr_set(last(r)) for r in rng),
    expr_body=body)

# ⊕_{j ⋚ k} u[cols…, j]·dz[j], over `lev`, with the output indices `out` (the
# leading column index first when there is one).
function _msr_scan(filt, out::Vector{String}, cols::Vector{String})
    rng = Dict{String,Any}("j" => _msr_set("lev"))
    for c in cols
        rng[c] = _msr_set("col")
    end
    "k" in out && (rng["k"] = _msr_set("lev"))
    body = _op("*", _idx("u", (_v(c) for c in cols)..., _v("j")), _idx("dz", _v("j")))
    ESM_MSR.OpExpr("faq", ESM_MSR.ASTExpr[]; output_idx=Any[out...], ranges=rng,
        expr_body=body, reduce="+",
        filter=filt === nothing ? nothing : _op(filt, _v("j"), _v("k")))
end

# The interface field `F` of a column (`ncol == 0`) or of `ncol` columns, as a
# two-region makearray: `scan` on interfaces 1..N, `top` on N+1. `w` integrates
# it, so the right-hand side reads every cell of `F`.
function _msr_nodes_model(n::Int, ncol::Int; filt="<", top=:total)
    cols = ncol == 0 ? String[] : ["c"]
    lead = ncol == 0 ? Vector{Any}[] : Vector{Any}[Any[1, ncol]]
    lo_reg = Vector{Any}[lead..., Any[1, n]]
    hi_reg = Vector{Any}[lead..., Any[n + 1, n + 1]]
    topv = top === :total ? _msr_scan(nothing, cols, cols) : _n(0.0)
    F = ESM_MSR.OpExpr("makearray", ESM_MSR.ASTExpr[];
        regions=[lo_reg, hi_reg],
        values=ESM_MSR.ASTExpr[_msr_scan(filt, [cols; "k"], cols), topv])
    cshape = ncol == 0 ? String[] : ["col"]
    vars = Dict(
        "u" => ESM_MSR.ModelVariable(ESM_MSR.UnknownVariable; shape=[cshape; "lev"]),
        "dz" => ESM_MSR.ModelVariable(ESM_MSR.UnknownVariable; shape=["lev"]),
        "F" => ESM_MSR.ModelVariable(ESM_MSR.UnknownVariable; shape=[cshape; "lev_nodes"]),
        "w" => ESM_MSR.ModelVariable(ESM_MSR.UnknownVariable; shape=[cshape; "lev_nodes"]))
    ci = ncol == 0 ? Pair[] : Pair["c" => "col"]
    cv = ncol == 0 ? ESM_MSR.ASTExpr[] : ESM_MSR.ASTExpr[_v("c")]
    eqs = [
        ESM_MSR.Equation(_v("dz"),
            _msr_agg(_op("+", _n(0.5), _op("*", _n(0.25), _v("k"))), "k" => "lev")),
        ESM_MSR.Equation(_v("F"), F),
        ESM_MSR.Equation(_msr_agg(_Didx("w", cv..., _v("i")), ci..., "i" => "lev_nodes"),
                         _msr_agg(_idx("F", cv..., _v("i")), ci..., "i" => "lev_nodes")),
        ESM_MSR.Equation(_msr_agg(_Didx("u", cv..., _v("i")), ci..., "i" => "lev"),
                         _msr_agg(_n(0.0), ci..., "i" => "lev")),
    ]
    isets = Dict("lev" => ESM_MSR.IndexSet("interval"; size=n),
                 "lev_nodes" => ESM_MSR.IndexSet("interval"; size=n + 1))
    ncol == 0 || (isets["col"] = ESM_MSR.IndexSet("interval"; size=ncol))
    return ESM_MSR.Model(vars, eqs), isets
end

# The layer-centre form: F = scan + 0.5·u·dz, whole-array arithmetic.
function _msr_centre_model(n::Int; filt="<")
    vars = Dict(
        "u" => ESM_MSR.ModelVariable(ESM_MSR.UnknownVariable; shape=["lev"]),
        "dz" => ESM_MSR.ModelVariable(ESM_MSR.UnknownVariable; shape=["lev"]),
        "F" => ESM_MSR.ModelVariable(ESM_MSR.UnknownVariable; shape=["lev"]),
        "w" => ESM_MSR.ModelVariable(ESM_MSR.UnknownVariable; shape=["lev"]))
    eqs = [
        ESM_MSR.Equation(_v("dz"),
            _msr_agg(_op("+", _n(0.5), _op("*", _n(0.25), _v("k"))), "k" => "lev")),
        ESM_MSR.Equation(_v("F"), _op("+", _msr_scan(filt, ["k"], String[]),
                                      _op("*", _n(0.5), _v("u"), _v("dz")))),
        ESM_MSR.Equation(_msr_agg(_Didx("w", _v("i")), "i" => "lev"),
                         _msr_agg(_idx("F", _v("i")), "i" => "lev")),
        ESM_MSR.Equation(_msr_agg(_Didx("u", _v("i")), "i" => "lev"),
                         _msr_agg(_n(0.0), "i" => "lev")),
    ]
    return ESM_MSR.Model(vars, eqs), Dict("lev" => ESM_MSR.IndexSet("interval"; size=n))
end

# The scaling families' shape: `ncol` columns of `n` layers, a two-region
# makearray of a scan over the interfaces (from the surface: the strict scan
# and its total; to the top: the inclusive reverse scan and a zero lid), and a
# flux divergence of it as the state's right-hand side,
# D(u[c,l]) = -0.001 (F[c,l+1] - F[c,l]) / dz[l].
function _msr_divergence_model(n::Int, ncol::Int; top::Bool=false)
    cv = ESM_MSR.ASTExpr[_v("c")]
    lo_reg = Vector{Any}[Any[1, ncol], Any[1, n]]
    hi_reg = Vector{Any}[Any[1, ncol], Any[n + 1, n + 1]]
    F = ESM_MSR.OpExpr("makearray", ESM_MSR.ASTExpr[];
        regions=[lo_reg, hi_reg],
        values=ESM_MSR.ASTExpr[_msr_scan(top ? ">=" : "<", ["c", "k"], ["c"]),
                               top ? _n(0.0) : _msr_scan(nothing, ["c"], ["c"])])
    vars = Dict(
        "u" => ESM_MSR.ModelVariable(ESM_MSR.UnknownVariable; shape=["col", "lev"]),
        "dz" => ESM_MSR.ModelVariable(ESM_MSR.UnknownVariable; shape=["lev"]),
        "F" => ESM_MSR.ModelVariable(ESM_MSR.UnknownVariable; shape=["col", "lev_nodes"]))
    div = _op("/", _op("*", _n(-0.001),
                       _op("-", _idx("F", cv..., _op("+", _v("i"), _i(1))),
                                _idx("F", cv..., _v("i")))),
              _idx("dz", _v("i")))
    eqs = [
        ESM_MSR.Equation(_v("dz"),
            _msr_agg(_op("+", _n(0.5), _op("*", _n(0.25), _v("k"))), "k" => "lev")),
        ESM_MSR.Equation(_v("F"), F),
        ESM_MSR.Equation(_msr_agg(_Didx("u", cv..., _v("i")), "c" => "col", "i" => "lev"),
                         _msr_agg(div, "c" => "col", "i" => "lev")),
    ]
    isets = Dict("lev" => ESM_MSR.IndexSet("interval"; size=n),
                 "lev_nodes" => ESM_MSR.IndexSet("interval"; size=n + 1),
                 "col" => ESM_MSR.IndexSet("interval"; size=ncol))
    return ESM_MSR.Model(vars, eqs), isets
end

function _msr_check(model, isets; scans::Int)
    nat = ESM_MSR._build_evaluator_impl(model; index_sets=isets)
    ref = ESM_MSR._build_evaluator_impl(model; index_sets=isets, compiler=:interpreter)
    @test nat[6].n_scan_folds == scans
    f!, u0, p = nat
    g!, _, q = ref
    @test length(u0) == length(ref[2])
    for probe in (Float64[_msr_val(k) for k in eachindex(u0)],
                  Float64[_msr_val(3k + 1) for k in eachindex(u0)])
        a = zero(probe); b = zero(probe)
        f!(a, probe, p, 0.0)
        g!(b, probe, q, 0.0)
        @test reinterpret(UInt64, a) == reinterpret(UInt64, b)
    end
    if VERSION >= v"1.12"
        du = zero(u0)
        f!(du, u0, p, 0.0)
        f!(du, u0, p, 0.0)
        @test (@allocated f!(du, u0, p, 0.0)) == 0
    end
    return nat
end

@testset "prefix scan as a makearray region (#533)" begin
    @testset "column, from the surface: scan + rank-0 total" begin
        m, is = _msr_nodes_model(16, 0)
        _msr_check(m, is; scans=1)
    end
    @testset "column, to the top: reverse scan + constant" begin
        # A reverse scan folds from the top (esm-spec §4.3.1), as one
        # descending scan fold.
        m, is = _msr_nodes_model(16, 0; filt=">=", top=:zero)
        _msr_check(m, is; scans=1)
        m, is = _msr_nodes_model(12, 7; filt=">=", top=:zero)
        _msr_check(m, is; scans=1)
    end
    @testset "inclusive forward scan region" begin
        m, is = _msr_nodes_model(9, 0; filt="<=")
        _msr_check(m, is; scans=1)
    end
    @testset "many columns: rank-2 scan region + per-column total" begin
        m, is = _msr_nodes_model(12, 7)
        _msr_check(m, is; scans=1)
    end
    @testset "layer centres: scan as an operand of whole-array arithmetic" begin
        m, is = _msr_centre_model(16)
        _msr_check(m, is; scans=1)
        m, is = _msr_centre_model(16; filt=">=")
        _msr_check(m, is; scans=1)
    end
    @testset "a scan's flux divergence is one pass over the columns" begin
        # The column scan (scan_fused.jl): term, fold and the divergence that
        # reads the interfaces below and above each layer, in one nest over the
        # columns of each level. Bit-identical to the interpreter, and through
        # ForwardDiff, where the nest runs column by column.
        for top in (false, true), ncol in (3, 40)
            m, is = _msr_divergence_model(10, ncol; top=top)
            ESM_MSR._reset_cascade_tally!()
            nat = ESM_MSR._build_evaluator_impl(m; index_sets=is)
            tally = copy(ESM_MSR._CASCADE_TALLY)
            @test get(tally, :scan_colscan, 0) == 1
            @test get(tally, :scan_colscan_consumer, 0) == 1
            _msr_check(m, is; scans=1)
            ref = ESM_MSR._build_evaluator_impl(m; index_sets=is, compiler=:interpreter)
            u = Float64[_msr_val(k) for k in eachindex(nat[2])]
            seed = Float64[isodd(k) ? 1.0 : -0.5 for k in eachindex(u)]
            jd(f, p) = ForwardDiff.derivative(
                x -> (du = zeros(typeof(x), length(u)); f(du, u .+ x .* seed, p, 0.0); du), 0.0)
            @test reinterpret(UInt64, jd(nat[1], nat[3])) == reinterpret(UInt64, jd(ref[1], ref[3]))
        end
    end

    @testset "a long column builds natively" begin
        m, is = _msr_nodes_model(4096, 0)
        nat = ESM_MSR._build_evaluator_impl(m; index_sets=is)
        @test nat[6].n_scan_folds == 1
    end

    @testset "scan + total regions are one staggered scan" begin
        # From the surface: one equation over the whole box, the scan's range
        # extended by the total's cell. To the top (a reverse scan beside a
        # constant) stays two regions.
        fdef(m, is) = ESM_MSR._resolve_isr(only(e for e in m.equations
            if e.lhs isa ESM_MSR.VarExpr && e.lhs.name == "F").rhs, is)
        for ncol in (0, 7)
            m, is = _msr_nodes_model(12, ncol)
            dims = ncol == 0 ? [13] : [7, 13]
            @test length(ESM_MSR._materialized_fill_equations("F", fdef(m, is), dims)) == 1
        end
        m, is = _msr_nodes_model(12, 0; filt=">=", top=:zero)
        @test length(ESM_MSR._materialized_fill_equations("F", fdef(m, is), [13])) == 2
        m, is = _msr_nodes_model(12, 0; filt="<=")
        @test length(ESM_MSR._materialized_fill_equations("F", fdef(m, is), [13])) == 2
    end

    @testset "a strided fold equals the lane-by-lane fold" begin
        # Lanes fastest, levels `nc` apart: the level-by-level walk must give
        # every slot the bits the lane walk gives it, for each ⊕ and window.
        # A reverse scan's lanes run down the axis (`kstride < 0`).
        nc, nk = 9, 6
        for down in (false, true),
            (op, z) in ((:+, 0.0), (:*, 1.0), (:max, -Inf), (:min, Inf)), inc in (true, false)
            ks = down ? (nk:-1:1) : (1:nk)
            slots = Int[c + (k - 1) * nc for c in 1:nc for k in ks]
            S = ESM_MSR._ScanFold(slots, nk, op, z, inc)
            @test (S.lstride, S.kstride) == (1, down ? -nc : nc)
            x = Float64[_msr_val(k) for k in 1:(nc * nk)]
            ref = copy(x)
            f = op === :+ ? (+) : op === :* ? (*) : op === :max ? max : min
            for c in 1:nc
                acc = z
                for k in ks
                    s = c + (k - 1) * nc
                    t = ref[s]
                    if inc
                        acc = f(acc, t); ref[s] = acc
                    else
                        ref[s] = acc; acc = f(acc, t)
                    end
                end
            end
            ESM_MSR._apply_scan_fold!(x, S)
            @test reinterpret(UInt64, x) == reinterpret(UInt64, ref)
        end
    end

    @testset "regions that overlap or leave a gap are not split" begin
        scan = _msr_scan("<", ["k"], String[])
        ma(regs) = ESM_MSR.OpExpr("makearray", ESM_MSR.ASTExpr[];
            regions=Vector{Vector{Vector{Any}}}([Vector{Vector{Any}}(r) for r in regs]), values=ESM_MSR.ASTExpr[scan, _n(1.0)])
        @test length(ESM_MSR._makearray_region_fills("F",
            ma([Any[Any[1, 4]], Any[Any[5, 5]]]), [5])) == 2
        @test ESM_MSR._makearray_region_fills("F",
            ma([Any[Any[1, 4]], Any[Any[4, 5]]]), [5]) === nothing
        @test ESM_MSR._makearray_region_fills("F",
            ma([Any[Any[1, 3]], Any[Any[5, 5]]]), [5]) === nothing
        # No filtered or gated region value: the single gather equation.
        plain = ESM_MSR.OpExpr("makearray", ESM_MSR.ASTExpr[];
            regions=[Vector{Any}[Any[1, 4]], Vector{Any}[Any[5, 5]]],
            values=ESM_MSR.ASTExpr[_n(2.0), _n(1.0)])
        @test ESM_MSR._makearray_region_fills("F", plain, [5]) === nothing
    end
end
