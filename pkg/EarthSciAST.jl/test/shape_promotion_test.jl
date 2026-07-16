# M2-1: promote_downstream_shapes — a scalar physics chain fed by an array source
# is promoted to the array shape, its equations rewritten to arrayops, and a real
# reduction (aggregate) stays a promotion BOUNDARY (scalar). Evaluates per-cell.
using Test
import EarthSciAST as ESS
const E = ESS

op(o, a...) = Dict{String,Any}("op"=>o, "args"=>collect(Any, a))
ix(a...)    = Dict{String,Any}("op"=>"index", "args"=>collect(Any, a))

# index set c (size 3); f[c] array param; a=f*2, b=a+f scalar-authored; s = Σ_c b.
function syn()
    agg = Dict{String,Any}("op"=>"aggregate","semiring"=>"sum_product","output_idx"=>Any[],
        "ranges"=>Dict{String,Any}("k"=>Dict{String,Any}("from"=>"c")),
        "args"=>Any[], "expr"=>ix("b","k"))
    Dict{String,Any}("esm"=>"0.5.0","metadata"=>Dict("name"=>"P"),
      # esm-spec v0.8.0: index_sets is a single document-scoped registry.
      "index_sets"=>Dict{String,Any}("c"=>Dict{String,Any}("kind"=>"interval","size"=>3)),
      "models"=>Dict{String,Any}("M"=>Dict{String,Any}(
        "variables"=>Dict{String,Any}(
            "f"=>Dict{String,Any}("type"=>"parameter","shape"=>Any["c"]),
            "a"=>Dict{String,Any}("type"=>"observed","expression"=>op("*","f",2)),
            "b"=>Dict{String,Any}("type"=>"observed","expression"=>op("+","a","f")),
            "s"=>Dict{String,Any}("type"=>"state")),
        "equations"=>Any[Dict{String,Any}(
            "lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["s"],"wrt"=>"t"),"rhs"=>agg)])))
end

@testset "M2-1: promote_downstream_shapes" begin
    flat = E.flatten(ESS.coerce_esm_file(ESS.JSON3.read(ESS.JSON3.write(syn()))))
    prom = E.promote_downstream_shapes(flat)

    @testset "shape inference: scalar chain promoted, reduction stays scalar" begin
        sh(n) = (v = get(prom.observed_variables, n, get(prom.state_variables, n, nothing));
                 v === nothing ? :absent : (v.shape === nothing ? String[] : v.shape))
        @test sh("M.a") == ["c"]              # promoted (downstream of array f); c is document-scoped
        @test sh("M.b") == ["c"]              # promoted
        @test sh("M.s") == String[]           # reduction boundary — stays scalar
    end

    @testset "equations rewritten to arrayops; evaluates per-cell" begin
        doc = E.flattened_to_esm(prom)
        f!, u0, p, _t, vmap = E.build_evaluator(doc;
            const_arrays=Dict("M.f"=>[1.0,2.0,3.0]), initial_conditions=Dict("M.s"=>0.0))
        du = similar(u0); f!(du, u0, p, 0.0)
        # f=[1,2,3] → a=[2,4,6], b=[3,6,9], s=Σb=18
        @test du[vmap["M.s"]] ≈ 18.0
        println("  D(M.s) = ", du[vmap["M.s"]], "  (expected 18 = Σ(2a... b=a+f))")
    end

    @testset "transform is a no-op for an all-scalar system" begin
        sc = Dict{String,Any}("esm"=>"0.5.0","metadata"=>Dict("name"=>"S"),
            "models"=>Dict{String,Any}("M"=>Dict{String,Any}("variables"=>Dict{String,Any}(
                "x"=>Dict{String,Any}("type"=>"parameter","default"=>2.0),
                "y"=>Dict{String,Any}("type"=>"observed","expression"=>op("*","x",3)),
                "z"=>Dict{String,Any}("type"=>"state")),
              "equations"=>Any[Dict{String,Any}("lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["z"],"wrt"=>"t"),"rhs"=>"y")])))
        f2 = E.flatten(ESS.coerce_esm_file(ESS.JSON3.read(ESS.JSON3.write(sc))))
        p2 = E.promote_downstream_shapes(f2)
        @test all(v -> v.shape === nothing || isempty(v.shape), values(p2.observed_variables))
        f!, u0, p, _t, vmap = E.build_evaluator(E.flattened_to_esm(p2); initial_conditions=Dict("M.z"=>0.0))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["M.z"]] ≈ 6.0           # y = x*3 = 6, unchanged
    end

    @testset "algebraic_states_to_observeds reclassifies bare-eq states" begin
        # `a` is a STATE defined by a bare algebraic eq (a = x*2); `z` is a real ODE
        # state (D(z,t)=a). Reclassify `a` → observed; leave `z` a state.
        d = Dict{String,Any}("esm"=>"0.5.0","metadata"=>Dict("name"=>"S"),
            "models"=>Dict{String,Any}("M"=>Dict{String,Any}("variables"=>Dict{String,Any}(
                "x"=>Dict{String,Any}("type"=>"parameter","default"=>3.0),
                "a"=>Dict{String,Any}("type"=>"state"),
                "z"=>Dict{String,Any}("type"=>"state")),
              "equations"=>Any[
                Dict{String,Any}("lhs"=>"a","rhs"=>op("*","x",2)),
                Dict{String,Any}("lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["z"],"wrt"=>"t"),"rhs"=>"a")])))
        flat = E.flatten(ESS.coerce_esm_file(ESS.JSON3.read(ESS.JSON3.write(d))))
        norm = E.algebraic_states_to_observeds(flat)
        @test haskey(norm.observed_variables, "M.a")    # algebraic state → observed
        @test !haskey(norm.state_variables, "M.a")
        @test haskey(norm.state_variables, "M.z")        # ODE state preserved
        # runs: a = x*2 = 6, D(z) = a = 6
        f!, u0, p, _t, vmap = E.build_evaluator(E.flattened_to_esm(norm); initial_conditions=Dict("M.z"=>0.0))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["M.z"]] ≈ 6.0
    end
end

@testset "inline_elementwise_array_observeds" begin
    # An ARRAY observed defined by a bare ELEMENTWISE equation (not arrayop/aggregate)
    # is folded into the equations that read it and dropped — the library form of the
    # level-set fold. a = f+1, b = a*2 (both [c]); D(s) = f - b. After inlining, a and b
    # vanish and D(s)'s RHS references only f.
    d = Dict{String,Any}("esm"=>"0.5.0","metadata"=>Dict("name"=>"P"),
      # esm-spec v0.8.0: index_sets is a single document-scoped registry.
      "index_sets"=>Dict{String,Any}("c"=>Dict{String,Any}("kind"=>"interval","size"=>3)),
      "models"=>Dict{String,Any}("M"=>Dict{String,Any}(
        "variables"=>Dict{String,Any}(
          "f"=>Dict{String,Any}("type"=>"parameter","shape"=>Any["c"]),
          "a"=>Dict{String,Any}("type"=>"observed","shape"=>Any["c"],"expression"=>op("+","f",1)),
          "b"=>Dict{String,Any}("type"=>"observed","shape"=>Any["c"],"expression"=>op("*","a",2)),
          "s"=>Dict{String,Any}("type"=>"state","shape"=>Any["c"])),
        "equations"=>Any[Dict{String,Any}(
          "lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["s"],"wrt"=>"t"),
          "rhs"=>op("-","f","b"))])))
    flat = E.flatten(ESS.coerce_esm_file(ESS.JSON3.read(ESS.JSON3.write(d))))
    @test haskey(flat.observed_variables, "M.a")
    @test haskey(flat.observed_variables, "M.b")

    inl = E.inline_elementwise_array_observeds(flat)
    @test !haskey(inl.observed_variables, "M.a")     # elementwise array observeds folded away
    @test !haskey(inl.observed_variables, "M.b")
    deq = only(filter(eq -> eq.lhs isa E.OpExpr && eq.lhs.op == "D", inl.equations))
    fv = E.free_variables(deq.rhs)
    @test "M.f" in fv
    @test !("M.a" in fv) && !("M.b" in fv)           # no dangling refs to the folded vars

    # No elementwise array observed ⇒ a no-op: the scalar observed survives untouched.
    sc = Dict{String,Any}("esm"=>"0.5.0","metadata"=>Dict("name"=>"S"),
      "models"=>Dict{String,Any}("M"=>Dict{String,Any}("variables"=>Dict{String,Any}(
        "x"=>Dict{String,Any}("type"=>"parameter","default"=>2.0),
        "y"=>Dict{String,Any}("type"=>"observed","expression"=>op("*","x",3)),
        "z"=>Dict{String,Any}("type"=>"state")),
        "equations"=>Any[Dict{String,Any}("lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["z"],"wrt"=>"t"),"rhs"=>"y")])))
    f2 = E.flatten(ESS.coerce_esm_file(ESS.JSON3.read(ESS.JSON3.write(sc))))
    n2 = E.inline_elementwise_array_observeds(f2)
    @test haskey(n2.observed_variables, "M.y")       # scalar observed untouched
    @test length(n2.equations) == length(f2.equations)
end

@testset "build_evaluator folds elementwise array observeds (WS4)" begin
    # A spatial state psi[c] fed by a chain of ELEMENTWISE array observeds
    # (a = psi + 1, b = a * 2, both shape [c]) with D(psi,t) = -b. This is the
    # readable PDE-leaf decomposition the level-set uses (`grad_safe`, `U_n`,
    # `S_n`, …). Without `_fold_elementwise_array_observeds`, build_evaluator
    # rejects a, b as E_TREEWALK_UNSUPPORTED_SHAPE; the fold inlines them so the
    # state RHS carries `-((psi+1)*2)` and evaluates per cell.
    d = Dict{String,Any}("esm"=>"0.5.0","metadata"=>Dict("name"=>"P"),
      "index_sets"=>Dict{String,Any}("c"=>Dict{String,Any}("kind"=>"interval","size"=>3)),
      "models"=>Dict{String,Any}("M"=>Dict{String,Any}(
        "variables"=>Dict{String,Any}(
          "psi"=>Dict{String,Any}("type"=>"state","shape"=>Any["c"]),
          "a"=>Dict{String,Any}("type"=>"observed","shape"=>Any["c"],"expression"=>op("+","psi",1)),
          "b"=>Dict{String,Any}("type"=>"observed","shape"=>Any["c"],"expression"=>op("*","a",2))),
        "equations"=>Any[Dict{String,Any}(
          "lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["psi"],"wrt"=>"t"),
          "rhs"=>op("-","b"))])))
    f!, u0, p, _t, vmap = E.build_evaluator(d;
        initial_conditions=Dict("psi[1]"=>1.0, "psi[2]"=>2.0, "psi[3]"=>3.0))
    # The elementwise array observeds are gone from the ODE partition (folded).
    @test !any(k -> occursin(r"^[ab]\[", k), keys(vmap))
    du = similar(u0); f!(du, u0, p, 0.0)
    for (i, expect) in zip(1:3, (-4.0, -6.0, -8.0))   # -b = -((psi+1)*2)
        @test du[vmap["psi[$i]"]] ≈ expect
    end
end

@testset "shape promotion errors use the typed flatten taxonomy" begin
    # Conflicting operand shapes -> DimensionPromotionError (was ArgumentError).
    d = Dict{String,Any}("esm"=>"0.8.0","metadata"=>Dict("name"=>"X"),
      "index_sets"=>Dict{String,Any}(
        "c"=>Dict{String,Any}("kind"=>"interval","size"=>3),
        "d"=>Dict{String,Any}("kind"=>"interval","size"=>4)),
      "models"=>Dict{String,Any}("M"=>Dict{String,Any}(
        "variables"=>Dict{String,Any}(
          "f"=>Dict{String,Any}("type"=>"parameter","shape"=>Any["c"]),
          "g"=>Dict{String,Any}("type"=>"parameter","shape"=>Any["d"]),
          "a"=>Dict{String,Any}("type"=>"observed","expression"=>op("+","f","g")),
          "s"=>Dict{String,Any}("type"=>"state")),
        "equations"=>Any[Dict{String,Any}(
          "lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["s"],"wrt"=>"t"),"rhs"=>"a")])))
    flat = E.flatten(ESS.coerce_esm_file(ESS.JSON3.read(ESS.JSON3.write(d))))
    @test_throws E.DimensionPromotionError E.promote_downstream_shapes(flat)
end

# `_pointwise_lifted_species` must consider ONLY still-scalar states.
#
# Regression: it swept in ANY state whose RHS carries a spatial makearray —
# including one the author already gave a grid shape. The motivating case is a
# prognostic air-mass `D(m,t) = -(D(Mx,lon) + …)` sharing a document with a
# pointwise-lifted chemistry mechanism (ReSEACT 3-D): `m` is already spatial, its
# equation is ALREADY an aggregate over the grid, and lifting it again would wrap a
# second aggregate around it. It cannot be lifted even in principle —
# `_pointwise_lift_loops` recovers a species' loop variables by finding it INSIDE
# its own makearray, and `m` never appears inside a flux divergence over `Mx` — so
# it died with "could not determine the spatial loop variables for species 'm'",
# which reads as a defect in the author's model rather than a state that simply
# needed no lifting.
@testset "pointwise lift considers only still-scalar states" begin
    ma = E.OpExpr("makearray", E.ASTExpr[E.VarExpr("Mx")];
                  regions=[[[1, 4]]], values=E.ASTExpr[E.VarExpr("Mx")])
    # Two states with a makearray RHS: one scalar (a 0-D species), one already spatial.
    eqs = E.Equation[
        E.Equation(E.OpExpr("D", E.ASTExpr[E.VarExpr("O3")]; wrt="t"), ma),
        E.Equation(E.OpExpr("D", E.ASTExpr[E.VarExpr("m")]; wrt="t"), ma),
    ]
    states = E.OrderedDict{String,E.ModelVariable}(
        "O3" => E.ModelVariable(E.StateVariable),                      # scalar ⇒ liftable
        "m"  => E.ModelVariable(E.StateVariable; shape=["lon"]),       # already spatial ⇒ not
    )
    lifted = E._pointwise_lifted_species(eqs, states)
    @test "O3" in lifted
    @test !("m" in lifted)

    # A state with no makearray in its RHS is not a lift candidate either.
    eqs2 = E.Equation[E.Equation(E.OpExpr("D", E.ASTExpr[E.VarExpr("x")]; wrt="t"),
                                 E.NumExpr(0.0))]
    states2 = E.OrderedDict{String,E.ModelVariable}("x" => E.ModelVariable(E.StateVariable))
    @test isempty(E._pointwise_lifted_species(eqs2, states2))
end
