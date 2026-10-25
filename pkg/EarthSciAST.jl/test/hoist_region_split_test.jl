# Region-split operands lifted to their own observeds (tree_walk/hoist.jl,
# "REGION-SPLIT OPERANDS"): two `makearray`s whose regions split different axes,
# combined elementwise on a whole-array right-hand side, are each filled once
# per call instead of reaching the affine tier as one expression cut by the
# product of their region cuts. The lift changes which kernels exist, never a
# value: `:native` agrees bitwise with `:interpreter`, which lifts nothing.

using Test
using EarthSciAST

const HRS = EarthSciAST

# A region of a `makearray` as a rule writes it: a `faq` over `[lo, hi]` on the
# split axis and the whole set on the other.
function _hrs_region(axis::Int, lo::Int, hi::Int, body)
    rng = axis == 1 ?
        Dict{String,Any}("i" => Any[lo, hi], "j" => Dict("from" => "y")) :
        Dict{String,Any}("i" => Dict("from" => "x"), "j" => Any[lo, hi])
    return Dict("op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
                "ranges" => rng, "expr" => body)
end

# A one-sided-face, centred-interior difference of `f` along `axis` over the
# `nx × ny` grid.
function _hrs_diff(f::String, axis::Int, nx::Int, ny::Int)
    n = axis == 1 ? nx : ny
    at(di) = axis == 1 ?
        Dict("op" => "index", "args" => Any[f, di == 0 ? "i" :
            Dict("op" => di > 0 ? "+" : "-", "args" => Any["i", abs(di)]), "j"]) :
        Dict("op" => "index", "args" => Any[f, "i", di == 0 ? "j" :
            Dict("op" => di > 0 ? "+" : "-", "args" => Any["j", abs(di)])])
    sub(a, b) = Dict("op" => "-", "args" => Any[a, b])
    bound(r) = axis == 1 ? Any[r, Any[1, ny]] : Any[Any[1, nx], r]
    return Dict("op" => "makearray", "args" => Any[],
        "regions" => Any[bound(Any[2, n - 1]), bound(Any[1, 1]), bound(Any[n, n])],
        "values" => Any[
            _hrs_region(axis, 2, n - 1, Dict("op" => "*", "args" => Any[0.5, sub(at(1), at(-1))])),
            _hrs_region(axis, 1, 1, sub(at(1), at(0))),
            _hrs_region(axis, n, n, sub(at(0), at(-1)))])
end

# `D(u) = -(Dx(u·c) + Dy(u·c))` and `D(v) = Dx(u·c) - 0.5·Dy(u·c)`, the second
# reading the first's two terms.
function _hrs_doc(nx::Int, ny::Int)
    Dx, Dy = _hrs_diff("w", 1, nx, ny), _hrs_diff("w", 2, nx, ny)
    D(v) = Dict("op" => "D", "args" => Any[v], "wrt" => "t")
    w = Dict("op" => "faq", "args" => Any[], "output_idx" => Any["i", "j"],
             "ranges" => Dict("i" => Dict("from" => "x"), "j" => Dict("from" => "y")),
             "expr" => Dict("op" => "*", "args" => Any[
                 Dict("op" => "index", "args" => Any["u", "i", "j"]),
                 Dict("op" => "+", "args" => Any[1.0,
                     Dict("op" => "*", "args" => Any[0.1, "i", "j"])])]))
    return Dict{String,Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "hrs"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => nx),
                             "y" => Dict("kind" => "interval", "size" => ny)),
        "models" => Dict("M" => Dict(
            "variables" => Dict(
                "u" => Dict("type" => "unknown", "shape" => ["x", "y"], "default" => 1.0),
                "v" => Dict("type" => "unknown", "shape" => ["x", "y"], "default" => 0.0),
                "w" => Dict("type" => "unknown", "shape" => ["x", "y"])),
            "equations" => Any[
                Dict("lhs" => "w", "rhs" => w),
                Dict("lhs" => D("u"), "rhs" => Dict("op" => "-", "args" => Any[
                    Dict("op" => "+", "args" => Any[Dx, Dy])])),
                Dict("lhs" => D("v"), "rhs" => Dict("op" => "-", "args" => Any[
                    Dx, Dict("op" => "*", "args" => Any[0.5, Dy])]))])))
end

@testset "region-split operands are lifted (hoist.jl)" begin
    @testset "native ≡ interpreter, bitwise" begin
        nx, ny = 7, 5
        doc = _hrs_doc(nx, ny)
        ics = Dict{String,Any}()
        for i in 1:nx, j in 1:ny
            ics["u[$i,$j]"] = 1.0 + 0.3 * sin(i + 2.0 * j)
            ics["v[$i,$j]"] = 0.0
        end
        dus = map((:native, :interpreter)) do c
            f!, u0, p, _t, vm = HRS._build_evaluator(doc; initial_conditions = ics,
                                                     compiler = c)
            du = fill(NaN, length(u0))
            f!(du, u0, p, 0.0)
            [du[vm["$s[$i,$j]"]] for s in ("u", "v") for i in 1:nx for j in 1:ny]
        end
        @test reinterpret(UInt64, dus[1]) == reinterpret(UInt64, dus[2])
        @test !any(isnan, dus[1]) && any(!iszero, dus[1])
        insp = BuildInspection()
        HRS._build_evaluator(doc; initial_conditions = ics, compiler = :native,
                             inspect = insp)
        @test any(r -> occursin("hoisted region term", r.rule), insp.compiler_report.rules)
    end

    # The lift on the typed model: which operands qualify, and the sharing.
    v(n) = HRS.VarExpr(n)
    op(o, a...) = HRS.OpExpr(o, HRS.ASTExpr[a...])
    ma(regions) = HRS.OpExpr("makearray", HRS.ASTExpr[]; regions = regions,
                             values = HRS.ASTExpr[HRS.NumExpr(Float64(k)) for k in eachindex(regions)])
    Dt(n) = HRS.OpExpr("D", HRS.ASTExpr[v(n)]; wrt = "t")
    isets = Dict("x" => HRS.IndexSet("interval"; size = 6),
                 "y" => HRS.IndexSet("interval"; size = 4))
    vars = Dict{String,HRS.ModelVariable}(
        n => HRS.ModelVariable(HRS.UnknownVariable; shape = ["x", "y"]) for n in ("u", "v"))
    lift(eqs) = HRS._hoist_nested_reductions(HRS.Model(vars, eqs), isets)
    ax = ma([[[2, 5], [1, 4]], [[1, 1], [1, 4]], [[6, 6], [1, 4]]])
    ay = ma([[[1, 6], [2, 3]], [[1, 6], [1, 1]], [[1, 6], [4, 4]]])

    @testset "two split operands, shared by two equations" begin
        m, _, owner = lift([HRS.Equation(Dt("u"), op("+", ax, ay)),
                            HRS.Equation(Dt("v"), op("-", ax, op("*", HRS.NumExpr(0.5), ay)))])
        @test length(m.equations) == 4
        lifted = [eq.lhs::HRS.VarExpr for eq in m.equations[3:4]]
        @test all(l -> HRS._is_hoisted_name(l.name), lifted)
        @test m.equations[3].rhs === ax && m.equations[4].rhs === ay
        @test all(l -> m.variables[l.name].shape == ["x", "y"], lifted)
        @test sort(collect(values(owner))) == ["u", "u"]
        r1, r2 = m.equations[1].rhs::HRS.OpExpr, m.equations[2].rhs::HRS.OpExpr
        @test r1.args == HRS.ASTExpr[lifted...]
        @test r2.args[1] == lifted[1] && (r2.args[2]::HRS.OpExpr).args[2] == lifted[2]
    end

    @testset "what does not qualify" begin
        # One split operand: no product of cuts to avoid.
        m, _, _ = lift([HRS.Equation(Dt("u"), op("+", ax, v("v")))])
        @test length(m.equations) == 1
        # Regions that leave a cell uncovered (x = 6 here).
        gap = ma([[[2, 5], [1, 4]], [[1, 1], [1, 4]]])
        m, _, _ = lift([HRS.Equation(Dt("u"), op("+", gap, ay))])
        @test length(m.equations) == 1
        # A region past its set.
        past = ma([[[1, 7], [1, 4]], [[1, 1], [1, 4]]])
        m, _, _ = lift([HRS.Equation(Dt("u"), op("+", past, ay))])
        @test length(m.equations) == 1
        # Behind a lazily evaluated operand.
        m, _, _ = lift([HRS.Equation(Dt("u"),
                                     op("ifelse", v("c"), op("+", ax, ay), HRS.NumExpr(0.0)))])
        @test length(m.equations) == 1
    end
end
