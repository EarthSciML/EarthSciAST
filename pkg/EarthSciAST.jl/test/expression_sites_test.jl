# The expression sites of a typed document (src/expression_sites.jl):
# `foreach_expression` reports every site with its pointer and kind,
# `map_expressions!` rewrites them, and the site list is complete.

using Test
using EarthSciAST
using EarthSciAST: ASTExpr, OpExpr, VarExpr, NumExpr, Equation, AffectEquation,
    ModelVariable, Model, ReactionSystem, Reaction, Species, Parameter,
    StoichiometryEntry, ParameterUpdate, DataSourceBinding, ConditionTrigger,
    ContinuousEvent, DiscreteEvent, InlineTest, Assertion, TimeSpan,
    CouplingVariableMap, CouplingEvent, CouplingCouple, EsmFile, Metadata,
    foreach_expression, map_expressions!, map_expressions, EXPRESSION_SITE_KINDS

# A document with an expression at every kind of site. Each site holds
# `x + <tag>`, so a visit can be told apart by its tag.
_site(tag) = OpExpr("+", ASTExpr[VarExpr("x"), VarExpr(tag)])

function _all_sites_file()
    D(v) = OpExpr("D", ASTExpr[VarExpr(v)]; wrt = "t")
    sub = Model(
        Dict("y" => ModelVariable(EarthSciAST.UnknownVariable)),
        Equation[Equation(D("y"), _site("sub_rhs"))]
    )
    model = Model(
        EarthSciAST.OrderedDict(
            "p" => ModelVariable(
                EarthSciAST.ParameterVariable; default = 1.0,
                update = ParameterUpdate[
                    ParameterUpdate("condition"; when = _site("when"), expression = _site("expr")),
                    ParameterUpdate(
                        "data"; source = "S",
                        from = DataSourceBinding("f"; unit_conversion = _site("uc"))
                    ),
                ]
            ),
            "x" => ModelVariable(
                EarthSciAST.UnknownVariable; lb = _site("lb"), ub = _site("ub")
            ),
        ),
        Equation[Equation(D("x"), _site("rhs"))];
        continuous_events = ContinuousEvent[
            ContinuousEvent(
                ASTExpr[_site("cond")], AffectEquation[AffectEquation("x", _site("aff"))];
                affect_neg = AffectEquation[AffectEquation("x", _site("neg"))]
            ),
        ],
        discrete_events = DiscreteEvent[
            DiscreteEvent(
                ConditionTrigger(_site("trig")), AffectEquation[AffectEquation("x", _site("daff"))]
            ),
        ],
        tests = InlineTest[
            InlineTest(
                "t1", TimeSpan(0.0, 1.0),
                Assertion[Assertion("x", 1.0, 0.0; reduce = "L2_error", reference = _site("ref"))]
            ),
        ],
        initialization_equations = Equation[Equation(VarExpr("x"), _site("init"))],
        guesses = Dict{String, Union{Float64, ASTExpr}}("x" => _site("guess"), "z" => 1.0),
        subsystems = Dict("S" => sub)
    )
    rsub = ReactionSystem(
        [Species("B")],
        [Reaction("r2", [StoichiometryEntry("B", 1)], nothing, _site("sub_rate"))]
    )
    rs = ReactionSystem(
        [Species("A")],
        [Reaction("r1", [StoichiometryEntry("A", 1)], nothing, _site("rate"))];
        parameters = [
            Parameter(
                "k", 1.0;
                update = ParameterUpdate("condition"; when = _site("kwhen"), expression = _site("kexpr"))
            ),
        ],
        constraint_equations = Equation[Equation(VarExpr("A"), _site("con"))],
        discrete_events = DiscreteEvent[
            DiscreteEvent(
                ConditionTrigger(_site("rtrig")), AffectEquation[AffectEquation("A", _site("raff"))]
            ),
        ],
        subsystems = Dict("Sub" => rsub)
    )
    coupling = EarthSciAST.CouplingEntry[
        CouplingVariableMap("M.x", "R.k", _site("transform")),
        CouplingEvent(
            "continuous", AffectEquation[AffectEquation("M.x", _site("caff"))];
            conditions = ASTExpr[_site("ccond")],
            affect_neg = AffectEquation[AffectEquation("M.x", _site("cneg"))]
        ),
        CouplingEvent(
            "discrete", AffectEquation[AffectEquation("M.x", _site("cdaff"))];
            trigger = ConditionTrigger(_site("ctrig"))
        ),
        CouplingCouple(
            ["M", "R"],
            Dict{String, Any}(
                "equations" => Any[
                    Dict{String, Any}("from" => "M.x", "to" => "R.A", "expression" => _site("conn")),
                ]
            )
        ),
    ]
    return EsmFile(
        "2.0.0", Metadata("Sites");
        models = Dict("M" => model), reaction_systems = Dict("R" => rs), coupling = coupling
    )
end

# Every site of `_all_sites_file`, in visiting order: (tag, pointer, kind).
const _ALL_SITES = [
    ("rhs", "/models/M/equations/0/rhs", :equation_rhs),
    ("init", "/models/M/initialization_equations/0/rhs", :initialization_rhs),
    ("guess", "/models/M/guesses/x", :guess),
    ("when", "/models/M/variables/p/update/0/when", :update_when),
    ("expr", "/models/M/variables/p/update/0/expression", :update_expression),
    ("uc", "/models/M/variables/p/update/1/from/unit_conversion", :update_unit_conversion),
    ("lb", "/models/M/variables/x/lb", :lower_bound),
    ("ub", "/models/M/variables/x/ub", :upper_bound),
    ("cond", "/models/M/continuous_events/0/conditions/0", :event_condition),
    ("aff", "/models/M/continuous_events/0/affects/0/rhs", :affect),
    ("neg", "/models/M/continuous_events/0/affect_neg/0/rhs", :affect_neg),
    ("trig", "/models/M/discrete_events/0/trigger/expression", :event_trigger),
    ("daff", "/models/M/discrete_events/0/affects/0/rhs", :affect),
    ("ref", "/models/M/tests/0/assertions/0/reference", :test_reference),
    ("sub_rhs", "/models/M/subsystems/S/equations/0/rhs", :equation_rhs),
    ("rate", "/reaction_systems/R/reactions/0/rate", :rate),
    ("kwhen", "/reaction_systems/R/parameters/k/update/when", :update_when),
    ("kexpr", "/reaction_systems/R/parameters/k/update/expression", :update_expression),
    ("con", "/reaction_systems/R/constraint_equations/0/rhs", :constraint_rhs),
    ("rtrig", "/reaction_systems/R/discrete_events/0/trigger/expression", :event_trigger),
    ("raff", "/reaction_systems/R/discrete_events/0/affects/0/rhs", :affect),
    ("sub_rate", "/reaction_systems/R/subsystems/Sub/reactions/0/rate", :rate),
    ("transform", "/coupling/0/transform", :variable_map_transform),
    ("ccond", "/coupling/1/conditions/0", :event_condition),
    ("caff", "/coupling/1/affects/0/rhs", :affect),
    ("cneg", "/coupling/1/affect_neg/0/rhs", :affect_neg),
    ("ctrig", "/coupling/2/trigger/expression", :event_trigger),
    ("cdaff", "/coupling/2/affects/0/rhs", :affect),
    ("conn", "/coupling/3/connector/equations/0/expression", :connector_expression),
]

_tag(e) = e isa OpExpr && e.op == "+" && e.args[2] isa VarExpr ? e.args[2].name : nothing

@testset "expression sites" begin
    @testset "foreach_expression reports every site with its pointer and kind" begin
        file = _all_sites_file()
        seen = Tuple{Union{String, Nothing}, String, Symbol}[]
        foreach_expression(file) do e, p, k
            push!(seen, (_tag(e), p, k))
        end
        # The left-hand sides carry no tag; check them by pointer and kind.
        lhs = [(p, k) for (t, p, k) in seen if t === nothing]
        @test lhs == [
            ("/models/M/equations/0/lhs", :equation_lhs),
            ("/models/M/initialization_equations/0/lhs", :initialization_lhs),
            ("/models/M/subsystems/S/equations/0/lhs", :equation_lhs),
            ("/reaction_systems/R/constraint_equations/0/lhs", :constraint_lhs),
        ]
        @test [s for s in seen if s[1] !== nothing] == _ALL_SITES
        # Every kind is reported, and the kinds the field table names are the kinds.
        @test Set(k for (_, _, k) in seen) == Set(EXPRESSION_SITE_KINDS)
        @test Set(Iterators.flatten(values(EarthSciAST._EXPRESSION_SITE_FIELDS))) ==
            Set(EXPRESSION_SITE_KINDS)
    end

    @testset "subsystems = false stops at the component" begin
        model = _all_sites_file().models["M"]
        ps = String[]
        foreach_expression((e, p, k) -> push!(ps, p), model, "/models/M"; subsystems = false)
        @test !any(p -> occursin("/subsystems/", p), ps)
        @test "/models/M/equations/0/rhs" in ps
    end

    @testset "map_expressions! rewrites every site and keeps identity otherwise" begin
        file = _all_sites_file()
        # An identity map changes no object.
        before = Any[]
        foreach_expression((e, _, _) -> push!(before, e), file)
        model = file.models["M"]
        xvar, ev, coupling1 = model.variables["x"], model.continuous_events[1], file.coupling[2]
        @test map_expressions!(identity, file) === file
        @test model.variables["x"] === xvar
        @test model.continuous_events[1] === ev
        @test file.coupling[2] === coupling1
        after = Any[]
        foreach_expression((e, _, _) -> push!(after, e), file)
        @test all(splat(===), zip(before, after))

        # Tag every site's root; every site reports the tag afterwards.
        mark(e) = OpExpr("*", ASTExpr[e, VarExpr("marked")])
        copy_ = map_expressions(mark, file)
        n = Ref(0)
        foreach_expression(copy_) do e, _, _
            @test e isa OpExpr && e.op == "*" && e.args[2] == VarExpr("marked")
            n[] += 1
        end
        @test n[] == length(before)
        # `map_expressions` left the original alone.
        foreach_expression(file) do e, _, _
            @test !(e isa OpExpr && e.op == "*")
        end
        # Non-expression fields survive a rebuild.
        @test copy_.models["M"].variables["p"].update[2].source == "S"
        @test copy_.models["M"].continuous_events[1].affect_neg[1].lhs == "x"
        @test copy_.coupling[1].from == "M.x"
        @test copy_.models["M"].guesses["z"] == 1.0
    end

    @testset "reconstruct(::ParameterUpdate) copies every field" begin
        r = ParameterUpdate("crossing"; when = VarExpr("x"), direction = "up", expression = NumExpr(1.0))
        r2 = EarthSciAST.reconstruct(r; expression = NumExpr(2.0))
        @test r2.kind == "crossing" && r2.direction == "up" && r2.when === r.when
        @test r2.expression == NumExpr(2.0)
        @test_throws MethodError EarthSciAST.reconstruct(r; nonsense = 1)
    end

    @testset "reconstruct exists for every document record type and copies every field" begin
        M = EarthSciAST
        for spec in M.RECORD_FIELD_TABLES
            T = getfield(M, spec.T)
            @test hasmethod(M.reconstruct, Tuple{T})
            # Every field is a keyword of the generated method.
            @test issubset(fieldnames(T), Base.kwarg_decl(only(methods(M.reconstruct, Tuple{T}))))
        end
        # Every EsmFile field, set to a value other than its default, survives a
        # copy that changes one other field.
        f = M.EsmFile(
            "2.3.0", M.Metadata("m"); models = Dict("M" => M.Model(Dict{String, M.ModelVariable}(), M.Equation[])),
            reaction_systems = Dict("R" => M.ReactionSystem(M.Species[], M.Reaction[])),
            data_sources = Dict{String, M.DataSource}(), domain = M.Domain(),
            enums = Dict("e" => Dict("a" => 1)),
            index_sets = Dict("i" => M.IndexSet("interval"; size = 2)),
            expression_templates = Dict{String, Any}("t" => 1),
            metaparameters = Dict{String, Any}("n" => 1),
            component_templates = Dict{String, Any}("models.M" => 1),
            coordinates = Dict{String, Any}("c" => 1),
            coupling_roles = Dict{String, Any}("r" => 1), solver = M.Solver(stiffness = "stiff"),
            document_base = "/d", coupling_import_base = "/b"
        )
        g = M.reconstruct(f; esm = "2.2.0")
        @test g.esm == "2.2.0"
        for k in fieldnames(M.EsmFile)
            k === :esm && continue
            @test getfield(g, k) == getfield(f, k)
        end
    end

    # Every field of a document struct whose declared type holds an `ASTExpr`
    # must be in the walk's field table. A field typed `Any` (an assertion's
    # `reference`, a `couple` connector) is not found this way: a new one has to
    # be added to the table and the walk by hand.
    @testset "the site table covers every expression-typed field" begin
        M = EarthSciAST
        alltypes = [
            getfield(M, n) for n in names(M; all = true)
                if isdefined(M, n) && getfield(M, n) isa Type
        ]
        holds(T) = T isa Union ? any(holds, Base.uniontypes(T)) :
            !(T isa DataType) ? false :
            T <: ASTExpr ? true :
            (T <: AbstractArray || T <: AbstractDict) ?
            any(p -> p isa Type && holds(p), T.parameters) : false
        structs = Set{DataType}()
        function visit(T)
            if T isa Union
                foreach(visit, Base.uniontypes(T))
                return
            end
            T isa DataType || return
            T <: ASTExpr && return
            if T <: AbstractArray || T <: AbstractDict
                foreach(p -> p isa Type && visit(p), T.parameters)
                return
            end
            parentmodule(T) === M || return
            if isabstracttype(T)
                foreach(visit, [S for S in alltypes if S isa DataType && S !== T && S <: T])
                return
            end
            T in structs && return
            push!(structs, T)
            foreach(i -> visit(fieldtype(T, i)), 1:fieldcount(T))
            return
        end
        visit(EsmFile)
        found = Set{Tuple{DataType, Symbol}}(
            (T, fieldname(T, i)) for T in structs for i in 1:fieldcount(T)
                if holds(fieldtype(T, i))
        )
        table = Set(keys(M._EXPRESSION_SITE_FIELDS))
        @test found == Set(k for k in table if holds(fieldtype(k...)))
        # The rest of the table is the `Any`-typed fields listed by hand.
        @test all(
            k -> !holds(fieldtype(k...)) && (
                Any <: fieldtype(k...) ||
                    fieldtype(k...) <: AbstractDict{String, Any}
            ), setdiff(table, found)
        )
    end
end
