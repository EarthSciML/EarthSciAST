# promote_downstream_shapes: consumer-side gathers for newly promoted variables.
#
# The hole (found downstream, in the ReSEACT operator-split runner's
# `index_promoted_refs_by_loop!` workaround): `promote_downstream_shapes` lifts a
# scalar-authored physics chain fed by array sources (Fast-JX j-rates fed by
# [lon,lat,lev] met fields) into the grid shape and rewrites each promoted
# variable's OWN defining equation into an `arrayop` — but it left its CONSUMERS
# alone. A pointwise-lifted species ODE indexes only the operands that carried a
# shape AT FLATTEN TIME, so the later-promoted variable survives as a bare
# scalar name inside the per-cell `aggregate` body, and the evaluator fails to
# bind it (E_TREEWALK_UNBOUND_VARIABLE) — which is why `EarthSciAST.simulate`
# could not mount Fast-JX. The post-discretize `index_promoted_refs!` companion
# cannot close it either: it takes ONE `spatial_loops` list while each consumer
# equation iterates its OWN loop names.
#
# The fix: `promote_downstream_shapes` now rewrites bare references to newly
# promoted variables inside loop-carrying aggregate/arrayop bodies into
# `index(var, <loops>)` gathers bound in the body's own scope (name-aligned
# against the ranges' index sets; positional over the producer's `output_idx`
# as fallback). `index_consumer_refs=false` restores the pre-fix behaviour and
# pins the old symptom below.
using Test
import EarthSciAST as ESS
const E = ESS

op(o, a...) = Dict{String,Any}("op"=>o, "args"=>collect(Any, a))
ix(a...)    = Dict{String,Any}("op"=>"index", "args"=>collect(Any, a))
isref(n)    = Dict{String,Any}("from"=>n)
agg(oi, ranges, body) = Dict{String,Any}("op"=>"aggregate",
    "semiring"=>"sum_product", "output_idx"=>oi, "ranges"=>ranges,
    "args"=>Any[], "expr"=>body)

roundtrip(d) = E.flatten(ESS.coerce_esm_file(ESS.JSON3.read(ESS.JSON3.write(d))))

# The distilled Fast-JX structural pattern: an array source f[c], a
# scalar-authored rate j = f*2 (promoted to [c] only by
# promote_downstream_shapes), and a pre-lifted per-cell species ODE — the shape
# a §10.5 pointwise lift produces — whose aggregate body references `j` BARE:
#   aggregate[i∈c]( D(s[i],t) ) = aggregate[i∈c]( j * s[i] )
function lifted_consumer_doc()
    lhs = agg(Any["i"], Dict{String,Any}("i"=>isref("c")),
              Dict{String,Any}("op"=>"D", "args"=>Any[ix("s","i")], "wrt"=>"t"))
    rhs = agg(Any["i"], Dict{String,Any}("i"=>isref("c")),
              op("*", "j", ix("s","i")))
    Dict{String,Any}("esm"=>"0.5.0", "metadata"=>Dict("name"=>"P"),
      "index_sets"=>Dict{String,Any}("c"=>Dict{String,Any}("kind"=>"interval","size"=>3)),
      "models"=>Dict{String,Any}("M"=>Dict{String,Any}(
        "variables"=>Dict{String,Any}(
          "f"=>Dict{String,Any}("type"=>"parameter","shape"=>Any["c"]),
          "j"=>Dict{String,Any}("type"=>"observed","expression"=>op("*","f",2)),
          "s"=>Dict{String,Any}("type"=>"state","shape"=>Any["c"])),
        "equations"=>Any[Dict{String,Any}("lhs"=>lhs, "rhs"=>rhs)])))
end

# First aggregate RHS among the equations (the lifted species ODE).
consumer_rhs(sys) = only(eq for eq in sys.equations
                         if eq.rhs isa E.OpExpr && eq.rhs.op == "aggregate").rhs

@testset "consumer refs to promoted vars are gathered in-loop" begin
    flat = lifted_consumer_doc() |> roundtrip
    pre  = E.algebraic_states_to_observeds(flat)

    @testset "kill switch pins the pre-fix symptom" begin
        broken = E.promote_downstream_shapes(pre; index_consumer_refs=false)
        # `M.j` IS promoted to [c] …
        @test broken.observed_variables["M.j"].shape == ["c"]
        # … but its consumer still references it bare inside the lift body,
        # so the build/eval fails to bind the (now-array) scalar name.
        body = consumer_rhs(broken).expr_body
        @test E.VarExpr("M.j") in E.child_exprs(body)
        # The exact downstream symptom (reseact saw it as
        # "E_TREEWALK_UNBOUND_VARIABLE: FastJX.j_NO2"):
        err = try
            f!, u0, p, _t, vmap = E.build_evaluator(E.flattened_to_esm(broken);
                const_arrays=Dict("M.f"=>[1.0,2.0,3.0]),
                initial_conditions=Dict("M.s[$i]"=>1.0 for i in 1:3))
            du = similar(u0); f!(du, u0, p, 0.0)
            nothing
        catch e
            e
        end
        @test err isa E.TreeWalkError
        @test occursin("E_TREEWALK_UNBOUND_VARIABLE", sprint(showerror, err))
        @test occursin("M.j", sprint(showerror, err))
    end

    @testset "with the fix: bare ref becomes an in-scope gather, evaluates" begin
        prom = E.promote_downstream_shapes(pre)
        @test prom.observed_variables["M.j"].shape == ["c"]
        body = consumer_rhs(prom).expr_body
        # j is gathered at the lift's OWN loop (`i`), not left bare.
        gathers = [c for c in E.child_exprs(body)
                   if c isa E.OpExpr && c.op == "index" &&
                      c.args[1] == E.VarExpr("M.j")]
        @test length(gathers) == 1
        @test gathers[1].args[2:end] == E.ASTExpr[E.VarExpr("i")]
        f!, u0, p, _t, vmap = E.build_evaluator(E.flattened_to_esm(prom);
            const_arrays=Dict("M.f"=>[1.0,2.0,3.0]),
            initial_conditions=Dict("M.s[$i]"=>1.0 for i in 1:3))
        du = similar(u0); f!(du, u0, p, 0.0)
        # f=[1,2,3] → j=[2,4,6]; s≡1 → D(s[i]) = j[i]·s[i] = j[i]
        for (i, expect) in zip(1:3, (2.0, 4.0, 6.0))
            @test du[vmap["M.s[$i]"]] ≈ expect
        end
    end
end

@testset "contracted-loop consumer: env binds ranges, not just output_idx" begin
    # A SCALAR reduction consuming the promoted var bare: D(z,t) = Σ_{k∈c} j.
    # The loop `k` is CONTRACTED (empty output_idx) — the case the downstream
    # per-equation workaround skipped and the ranges-scoped env closes.
    red = agg(Any[], Dict{String,Any}("k"=>isref("c")), "j")
    d = Dict{String,Any}("esm"=>"0.5.0", "metadata"=>Dict("name"=>"P"),
      "index_sets"=>Dict{String,Any}("c"=>Dict{String,Any}("kind"=>"interval","size"=>3)),
      "models"=>Dict{String,Any}("M"=>Dict{String,Any}(
        "variables"=>Dict{String,Any}(
          "f"=>Dict{String,Any}("type"=>"parameter","shape"=>Any["c"]),
          "j"=>Dict{String,Any}("type"=>"observed","expression"=>op("*","f",2)),
          "z"=>Dict{String,Any}("type"=>"state")),
        "equations"=>Any[Dict{String,Any}(
          "lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["z"],"wrt"=>"t"),
          "rhs"=>red)])))
    prom = E.promote_downstream_shapes(roundtrip(d))
    body = consumer_rhs(prom).expr_body
    @test body isa E.OpExpr && body.op == "index" &&
          body.args == E.ASTExpr[E.VarExpr("M.j"), E.VarExpr("k")]
    f!, u0, p, _t, vmap = E.build_evaluator(E.flattened_to_esm(prom);
        const_arrays=Dict("M.f"=>[1.0,2.0,3.0]), initial_conditions=Dict("M.z"=>0.0))
    du = similar(u0); f!(du, u0, p, 0.0)
    @test du[vmap["M.z"]] ≈ 12.0                     # Σ 2f = 2+4+6
end

@testset "name alignment transposes a permuted-shape operand" begin
    # g[d,c] seeds jj with shape [d,c]; the consumer body iterates [i∈c, k∈d]
    # (the PERMUTED order). The gather must follow jj's DECLARED axis order —
    # index(jj, k, i) — not the loop order, or c≠d would mis-shape / transpose.
    lhs = agg(Any["i","k"],
              Dict{String,Any}("i"=>isref("c"), "k"=>isref("d")),
              Dict{String,Any}("op"=>"D", "args"=>Any[ix("s2","i","k")], "wrt"=>"t"))
    rhs = agg(Any["i","k"],
              Dict{String,Any}("i"=>isref("c"), "k"=>isref("d")),
              op("*", "jj", ix("s2","i","k")))
    d = Dict{String,Any}("esm"=>"0.5.0", "metadata"=>Dict("name"=>"P"),
      "index_sets"=>Dict{String,Any}(
        "c"=>Dict{String,Any}("kind"=>"interval","size"=>3),
        "d"=>Dict{String,Any}("kind"=>"interval","size"=>2)),
      "models"=>Dict{String,Any}("M"=>Dict{String,Any}(
        "variables"=>Dict{String,Any}(
          "g"=>Dict{String,Any}("type"=>"parameter","shape"=>Any["d","c"]),
          "jj"=>Dict{String,Any}("type"=>"observed","expression"=>op("*","g",2)),
          "s2"=>Dict{String,Any}("type"=>"state","shape"=>Any["c","d"])),
        "equations"=>Any[Dict{String,Any}("lhs"=>lhs, "rhs"=>rhs)])))
    prom = E.promote_downstream_shapes(roundtrip(d))
    @test prom.observed_variables["M.jj"].shape == ["d","c"]
    body = consumer_rhs(prom).expr_body
    gathers = [c for c in E.child_exprs(body)
               if c isa E.OpExpr && c.op == "index" && c.args[1] == E.VarExpr("M.jj")]
    @test length(gathers) == 1
    # Declared-axis order [d,c] → loops (k, i), NOT the body's (i, k).
    @test gathers[1].args[2:end] == E.ASTExpr[E.VarExpr("k"), E.VarExpr("i")]
end

@testset "scalar-position refs stay bare (post-discretize contract)" begin
    # The wildfire/level-set path: an un-discretized spatial state equation
    # references the promoted chain in SCALAR position. Its loops do not exist
    # yet; `index_promoted_refs!` closes it after `discretize`, so the promote
    # pass must leave it bare.
    d = Dict{String,Any}("esm"=>"0.5.0", "metadata"=>Dict("name"=>"P"),
      "index_sets"=>Dict{String,Any}("c"=>Dict{String,Any}("kind"=>"interval","size"=>3)),
      "models"=>Dict{String,Any}("M"=>Dict{String,Any}(
        "variables"=>Dict{String,Any}(
          "f"=>Dict{String,Any}("type"=>"parameter","shape"=>Any["c"]),
          "j"=>Dict{String,Any}("type"=>"observed","expression"=>op("*","f",2)),
          "psi"=>Dict{String,Any}("type"=>"state","shape"=>Any["c"])),
        "equations"=>Any[Dict{String,Any}(
          "lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["psi"],"wrt"=>"t"),
          "rhs"=>op("-","j"))])))
    prom = E.promote_downstream_shapes(roundtrip(d))
    deq = only(eq for eq in prom.equations
               if eq.lhs isa E.OpExpr && eq.lhs.op == "D")
    @test deq.rhs isa E.OpExpr && deq.rhs.args == E.ASTExpr[E.VarExpr("M.j")]
end

@testset "explicitly indexed consumers are untouched (M2-1 contract)" begin
    # The original M2-1 fixture indexes the promoted chain EXPLICITLY
    # (`index(b,k)`); the consumer pass must not rewrap it — behaviour and
    # numbers identical to the pre-fix pass.
    aggd = agg(Any[], Dict{String,Any}("k"=>isref("c")), ix("b","k"))
    d = Dict{String,Any}("esm"=>"0.5.0","metadata"=>Dict("name"=>"P"),
      "index_sets"=>Dict{String,Any}("c"=>Dict{String,Any}("kind"=>"interval","size"=>3)),
      "models"=>Dict{String,Any}("M"=>Dict{String,Any}(
        "variables"=>Dict{String,Any}(
            "f"=>Dict{String,Any}("type"=>"parameter","shape"=>Any["c"]),
            "a"=>Dict{String,Any}("type"=>"observed","expression"=>op("*","f",2)),
            "b"=>Dict{String,Any}("type"=>"observed","expression"=>op("+","a","f")),
            "s"=>Dict{String,Any}("type"=>"state")),
        "equations"=>Any[Dict{String,Any}(
            "lhs"=>Dict{String,Any}("op"=>"D","args"=>Any["s"],"wrt"=>"t"),"rhs"=>aggd)])))
    flat = roundtrip(d)
    prom_on  = E.promote_downstream_shapes(flat)
    prom_off = E.promote_downstream_shapes(flat; index_consumer_refs=false)
    for prom in (prom_on, prom_off)
        f!, u0, p, _t, vmap = E.build_evaluator(E.flattened_to_esm(prom);
            const_arrays=Dict("M.f"=>[1.0,2.0,3.0]), initial_conditions=Dict("M.s"=>0.0))
        du = similar(u0); f!(du, u0, p, 0.0)
        @test du[vmap["M.s"]] ≈ 18.0
    end
end
