# The template instantiation cache (src/lower_expression_templates.jl
# `_TplSkel`): a call site is instantiated from its template's skeleton, built
# once per expansion with a sentinel per parameter, instead of being serialized,
# substituted and re-parsed level by level. The direct route (`memo = nothing`)
# is the reference: the cached expansion must be structurally identical to it,
# record the same compile-once site roots, fall back to it for a template whose
# parameters land where the skeleton cannot place them, and leave every
# diagnostic at the call site that caused it.

using Test
using EarthSciAST
using JSON3

include("testutils.jl")
const ESM = EarthSciAST

_tic_json(e) = ESM._stable_json(ESM.serialize_expression(e))

# Expand every model of `file` both ways; compare equation trees and site roots.
function _tic_agree(file)
    ct = file.component_templates
    (ct === nothing || file.models === nothing) && return 0
    n = 0
    for (mname, model) in file.models
        reg = get(ct, "models.$mname", nothing)
        reg === nothing && continue
        a = ESM._expansion_copy(model)
        sa = IdDict{ESM.OpExpr, ESM.OpExpr}()
        ESM._expand_model_refs!(a, reg; sites = sa)
        b = ESM._expansion_copy(model)
        sb = IdDict{ESM.OpExpr, ESM.OpExpr}()
        ESM._expand_model_refs!(b, reg; sites = sb, memo = nothing)
        for (ea, eb) in zip(
                vcat(a.equations, a.initialization_equations),
                vcat(b.equations, b.initialization_equations)
            )
            ja, jb = _tic_json(ea.rhs), _tic_json(eb.rhs)
            @test ja == jb
            @test !occursin("esm-template-param", ja)
            @test _tic_json(ea.lhs) == _tic_json(eb.lhs)
        end
        @test Set(_tic_json(k) for k in keys(sa)) == Set(_tic_json(k) for k in keys(sb))
        n += 1
    end
    return n
end

_tic_op(o, args...; kw...) = Dict{String, Any}("op" => o, "args" => Any[args...], (string(k) => v for (k, v) in kw)...)
_tic_apply(name; b...) = Dict{String, Any}(
    "op" => "apply_expression_template", "args" => Any[], "name" => name,
    "bindings" => Dict{String, Any}(string(k) => v for (k, v) in b)
)
_tic_const(v) = Dict{String, Any}("op" => "const", "args" => Any[], "value" => v)

function _tic_doc(model; index_sets = Dict{String, Any}())
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "tic", "description" => "template instantiation cache test"),
        "index_sets" => index_sets,
        "models" => Dict("M" => model),
    )
end

function _tic_load(doc)
    dir = mktempdir()
    path = joinpath(dir, "doc.esm")
    write(path, JSON3.write(doc))
    return path
end

# Several linear and bilinear sites from the standard library, each reading the
# state through a different expression.
function _tic_interp_doc(; xs = nothing)
    vars = Dict{String, Any}("u" => Dict("type" => "unknown", "default" => 0.25), "acc" => Dict("type" => "unknown"))
    eqs = Any[]
    sites = Any[]
    axis = [0.0, 0.5, 1.25, 2.0, 3.5]
    for i in 1:3
        x = xs === nothing ? _tic_op("+", "u", 0.125 * i) : xs[i]
        r = "r$i"
        vars[r] = Dict("type" => "unknown")
        push!(eqs, Dict("lhs" => r, "rhs" => _tic_apply("linear"; table = _tic_const([1.0 * i, 2.0, -1.0, 0.5, 3.0]), axis = _tic_const(axis), x = x, n = 5)))
        push!(sites, r)
    end
    for i in 1:2
        r = "b$i"
        vars[r] = Dict("type" => "unknown")
        tab = [[0.25 * (i + j + k) + 0.125 * j * k for k in 1:3] for j in 1:3]
        push!(
            eqs, Dict(
                "lhs" => r, "rhs" => _tic_apply(
                    "bilinear"; table = _tic_const(tab), axis_x = _tic_const([0.0, 1.0, 2.0]),
                    axis_y = _tic_const([0.0, 0.5, 1.5]), x = _tic_op("+", "u", 0.5 * i),
                    y = _tic_op("*", "u", 1.5), nx = 3, ny = 3
                )
            )
        )
        push!(sites, r)
    end
    push!(eqs, Dict("lhs" => "acc", "rhs" => _tic_op("+", sites...)))
    push!(eqs, Dict("lhs" => _tic_op("D", "u"; wrt = "t"), "rhs" => _tic_op("-", _tic_op("*", 0.01, "acc"), "u")))
    return _tic_doc(
        Dict(
            "variables" => vars, "equations" => eqs,
            "expression_template_imports" => Any[Dict("ref" => "esm:std/interp.esm", "only" => ["linear", "bilinear"])],
        )
    )
end

@testset "template instantiation cache" begin
    @testset "agrees with the direct route on the template conformance tiers" begin
        root = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance")
        n = 0
        for tier in ("interp_templates", "datetime_templates", "relational_templates", "geometry_templates", "expression_templates")
            for (d, _, fs) in walkdir(joinpath(root, tier)), f in fs
                endswith(f, ".esm") || continue
                file = try
                    load_path(joinpath(d, f))
                catch
                    continue        # invalid fixtures are the loader's business
                end
                n += _tic_agree(file)
            end
        end
        @test n > 20
    end

    @testset "library templates take the cached route" begin
        file = load_path(_tic_load(_tic_interp_doc()))
        reg = file.component_templates["models.M"]
        cache = ESM._ExpandCache()
        for name in ("linear", "bilinear")
            @test ESM._tpl_skeleton(name, reg, cache) isa ESM._TplSkel
        end
        @test _tic_agree(file) == 1
        # And the program is the interpreter's, bit for bit.
        path = _tic_load(_tic_interp_doc())
        pn = esm_problem(path, (0.0, 1.0); compiler = :native)
        pi = esm_problem(path, (0.0, 1.0); compiler = :interpreter)
        for (t, u) in ((0.0, 0.25), (0.7, -0.4), (2.0, 1.9))
            dn, di = [0.0], [0.0]
            pn.f!(dn, [u], pn.p, t)
            pi.f!(di, [u], pi.p, t)
            @test dn == di
        end
    end

    @testset "parameters in a scalar field fall back to the direct route" begin
        # `m` lands in `manifold` and `nm` in a `fn` name: neither is an
        # expression, a range bound or an output index, so the template is
        # ineligible and every site is expanded directly.
        tpl = Dict{String, Any}(
            "scaled" => Dict("params" => ["a", "k"], "body" => _tic_op("*", "a", _tic_op("+", "k", 1))),
            "named" => Dict("params" => ["a", "nm"], "body" => _tic_op("fn", "a"; name = "nm")),
            "summed" => Dict(
                "params" => ["v", "n", "i"],
                "body" => Dict(
                    "op" => "faq", "args" => Any[], "output_idx" => Any[], "expr" => _tic_op("index", "v", "i"),
                    "ranges" => Dict("i" => Any[1, "n"]), "reduce" => "+"
                ),
            ),
        )
        vars = Dict{String, Any}(
            "u" => Dict("type" => "unknown", "default" => 1.0),
            "w" => Dict("type" => "unknown", "shape" => ["s"]),
            "p" => Dict("type" => "parameter", "default" => 2.0),
            "q" => Dict("type" => "unknown"), "y" => Dict("type" => "unknown"),
        )
        eqs = Any[
            Dict("lhs" => _tic_op("index", "w", "j"), "rhs" => Dict("op" => "faq", "args" => Any[], "output_idx" => ["j"], "ranges" => Dict("j" => Dict("from" => "s")), "expr" => _tic_op("*", "j", "u"))),
            Dict("lhs" => "q", "rhs" => _tic_op("+", _tic_apply("scaled"; a = "u", k = "p"), _tic_apply("scaled"; a = _tic_op("*", "u", "u"), k = 3))),
            Dict("lhs" => "y", "rhs" => _tic_op("+", _tic_apply("summed"; v = "w", n = 4, i = "kk"), _tic_apply("summed"; v = "w", n = 2, i = "m"))),
            Dict("lhs" => _tic_op("D", "u"; wrt = "t"), "rhs" => _tic_op("-", _tic_op("*", 0.01, _tic_op("+", "q", "y")), "u")),
        ]
        doc = _tic_doc(
            Dict("variables" => vars, "equations" => eqs, "expression_templates" => tpl);
            index_sets = Dict("s" => Dict("kind" => "interval", "size" => 4))
        )
        file = load_path(_tic_load(doc))
        reg = file.component_templates["models.M"]
        cache = ESM._ExpandCache()
        @test ESM._tpl_skeleton("scaled", reg, cache) isa ESM._TplSkel
        @test ESM._tpl_skeleton("summed", reg, cache) isa ESM._TplSkel   # `n` is a range bound
        @test ESM._tpl_skeleton("named", reg, cache) === nothing         # `nm` is a fn name
        @test _tic_agree(file) == 1
        # A site whose bindings name something other than the params goes direct.
        site = ESM.OpExpr(
            "apply_expression_template", ESM.ASTExpr[]; name = "scaled",
            bindings = Dict{String, ESM.ASTExpr}("a" => ESM.VarExpr("u"))
        )
        @test ESM._tpl_instantiate(site, "scaled", Dict{String, Any}("a" => "u"), reg, nothing, cache) === nothing
    end

    @testset "a bad binding is reported at its own call site" begin
        xs = Any[_tic_op("+", "u", 0.1), _tic_op("+", "nope", 0.2), _tic_op("+", "u", 0.3)]
        file = load_path(_tic_load(_tic_interp_doc(; xs = xs)))
        res = ESM.validate(file)
        @test !res.is_valid
        bad = filter(e -> occursin("nope", e.message) || occursin("nope", string(e.details)), res.structural_errors)
        @test !isempty(bad)
        # The second linear site is the second equation.
        @test all(e -> startswith(e.path, "/models/M/equations/1/"), bad)

        # An unknown template inside one site's binding raises the stable
        # diagnostic from that site's expansion.
        xs2 = Any[_tic_op("+", "u", 0.1), _tic_op("+", "u", 0.2), _tic_apply("no_such_template"; z = "u")]
        doc = _tic_interp_doc(; xs = xs2)
        err = try
            load_path(_tic_load(doc))
            nothing
        catch e
            e
        end
        @test err !== nothing
        @test occursin("no_such_template", sprint(showerror, err))
    end
end
