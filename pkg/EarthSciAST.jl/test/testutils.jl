# Shared test prelude for the EarthSciAST.jl suite.
#
# Every test file that needs the shared repo root, the canonical
# expression-builder helpers, the JSON-normalization helper, or the fixture
# check does `include("testutils.jl")` near its top. runtests.jl runs each file
# in a module of its own, and so does a standalone run
# (`julia --project -e 'include("test/<file>")'`), so each gets its own copy.
# The guard is per including module (`@__MODULE__`), which makes a second
# include from the same file (or a `module` it wraps itself in) harmless.
if !isdefined(@__MODULE__, :ESM_TESTUTILS_LOADED)

    const ESM_TESTUTILS_LOADED = true

    using Test
    using JSON3
    using EarthSciAST

    # Absolute path of the repository root (the directory containing the shared
    # `tests/` fixture tree, `esm-schema.json`, `esm-spec.md`, ...).
    const TESTUTILS_REPO_ROOT = normpath(joinpath(@__DIR__, "..", "..", ".."))

    # The EarthSciModels checkout a test reads a real component from:
    # `ESM_EARTHSCIMODELS` when set (CI checks the repository out inside the
    # workspace and sets it), else the sibling of this repository's root.
    earthscimodels_root() = normpath(
        get(ENV, "ESM_EARTHSCIMODELS", joinpath(TESTUTILS_REPO_ROOT, "..", "EarthSciModels"))
    )

    # The runner's default pool stays single-threaded. Only independent fixture
    # work goes to the optional interactive pool, and its results stay in corpus
    # order so callers can record assertions on the test task.
    function map_corpus(f, inputs)
        workers = min(length(inputs), Threads.nthreads(:interactive))
        workers < 2 && return map(f, inputs)
        tasks = @sync map(1:workers) do worker
            Threads.@spawn :interactive map(f, inputs[worker:workers:end])
        end
        chunks = fetch.(tasks)
        return [chunks[mod1(i, workers)][cld(i, workers)] for i in eachindex(inputs)]
    end

    # ---------------------------------------------------------------------------
    # Canonical expression-builder quartet (+ the `index` shorthand built on it).
    # These keep hand-built AST fixtures readable.
    # ---------------------------------------------------------------------------
    _n(x) = EarthSciAST.NumExpr(Float64(x))
    _i(x) = EarthSciAST.IntExpr(Int64(x))
    _v(n) = EarthSciAST.VarExpr(String(n))
    _op(op, args...; kw...) =
        EarthSciAST.OpExpr(String(op), EarthSciAST.ASTExpr[args...]; kw...)
    _idx(v, is...) = _op("index", _v(v), is...)

    # Derived shorthands shared by the tree-walk / data-refresh test files.
    # `_D_idx` / `_faq1d` are second spellings of `_Didx` / `_ao1`.
    _D(v) = _op("D", _v(v); wrt = "t")
    _Didx(v, is...) = _op("D", _idx(v, is...); wrt = "t")
    _D_idx(v, is...) = _Didx(v, is...)
    _ao1(body, idx, lo, hi) = EarthSciAST.OpExpr(
        "faq",
        EarthSciAST.ASTExpr[];
        output_idx = Any[idx], expr_body = body, ranges = Dict(idx => [lo, hi])
    )
    _faq1d(body, idx, lo, hi) = _ao1(body, idx, lo, hi)
    _const(val) = EarthSciAST.OpExpr(
        "const",
        EarthSciAST.ASTExpr[]; value = val
    )

    # ---------------------------------------------------------------------------
    # The raw-JSON (`Dict`) spelling of the same nodes, for a document built as
    # a native `Dict` and handed to `esm_problem` / `Internal.build`.
    # ---------------------------------------------------------------------------
    jop(o, args...; kw...) = Dict{String, Any}(
        "op" => String(o), "args" => Any[args...],
        (String(k) => v for (k, v) in kw)...
    )
    jidx(v, is...) = jop("index", v, is...)
    jD(v; wrt = "t") = jop("D", v; wrt = wrt)
    jconst(value) = jop("const"; value = value)
    # A `faq` node: `body` summed (or folded by `semiring`) over `ranges`
    # (index name => `Dict("from" => set)` or `[lo, hi]`), keeping `output_idx`.
    function jfaq(
            body, output_idx, ranges::AbstractDict; filter = nothing,
            semiring = "sum_product", args = Any[]
        )
        d = Dict{String, Any}(
            "op" => "faq", "semiring" => semiring, "output_idx" => Any[output_idx...],
            "ranges" => Dict{String, Any}(String(k) => v for (k, v) in ranges),
            "args" => Any[args...], "expr" => body
        )
        filter === nothing || (d["filter"] = filter)
        return d
    end
    # A one-model document in the current schema version.
    function jdoc(
            variables::AbstractDict, equations::AbstractVector; name = "M",
            index_sets = nothing, extra...
        )
        model = Dict{String, Any}("variables" => variables, "equations" => Any[equations...])
        for (k, v) in extra
            model[String(k)] = v
        end
        doc = Dict{String, Any}(
            "esm" => EarthSciAST.SCHEMA_VERSION,
            "metadata" => Dict{String, Any}("name" => String(name)),
            "models" => Dict{String, Any}(String(name) => model)
        )
        index_sets === nothing || (doc["index_sets"] = index_sets)
        return doc
    end

    # Bit equality of two arrays (`===` per element, so `-0.0 !== 0.0`).
    bitsame(a, b) = size(a) == size(b) && all(a .=== b)
    # The right-hand side `f!` writes at `(u, p, t)`, into a zeroed `du`.
    rhs_du(f!, u, p, t) = (du = zero(u); f!(du, u, p, t); du)
    # The exception `f()` throws, or `nothing`.
    caught(f) = try
        f()
        nothing
    catch err
        err
    end

    # ---------------------------------------------------------------------------
    # Stub data providers (the provider protocol of providers.jl).
    # ---------------------------------------------------------------------------
    # The same sample at every time and no refresh times: a CONST source.
    struct ConstProvider{T}
        value::T
    end
    EarthSciAST.provider_refresh_times(::ConstProvider) = Float64[]
    EarthSciAST.provider_sample(p::ConstProvider, ::Real; selection = nothing) = p.value

    # A sample per refresh time (`time => sample`), refreshing at each of them.
    struct SeriesProvider{T}
        fields::Dict{Float64, T}
    end
    SeriesProvider(fields::AbstractDict) =
        SeriesProvider(Dict(Float64(t) => v for (t, v) in fields))
    EarthSciAST.provider_refresh_times(p::SeriesProvider) = sort!(collect(keys(p.fields)))
    EarthSciAST.provider_sample(p::SeriesProvider, t::Real; selection = nothing) =
        p.fields[Float64(t)]

    # ---------------------------------------------------------------------------
    # Expressions from math text, and expressions compared as canonical JSON.
    # ---------------------------------------------------------------------------
    # A typed expression (or `Equation`) read from Typst math under the names it
    # uses (`parse_math`).
    function typst_expr(text::AbstractString, names)
        v = parse_math(text, names, :typst)
        if v isa AbstractDict && haskey(v, "lhs") && haskey(v, "rhs")
            return EarthSciAST.Equation(
                EarthSciAST.expression_from_json(v["lhs"]),
                EarthSciAST.expression_from_json(v["rhs"])
            )
        end
        return EarthSciAST.expression_from_json(v)
    end

    # An expression or equation in the form `canonicalize_document` writes
    # (API_SPEC §5.4), numbers in their canonical kind (CONFORMANCE §5.5.3.1),
    # as compact JSON with sorted keys: two expressions are the same exactly
    # when these strings are equal, so an integer `1` and a float `1.0` differ. Takes a typed expression or equation, or a decoded JSON value.
    function canonical_expr_json(x)
        v = x isa EarthSciAST.Equation ?
            Dict{String, Any}(
                "lhs" => EarthSciAST.serialize_expression(x.lhs),
                "rhs" => EarthSciAST.serialize_expression(x.rhs)
            ) :
            x isa EarthSciAST.ASTExpr ? EarthSciAST.serialize_expression(x) : x
        return _sorted_json(
            EarthSciAST._canonical_document_numbers(
                EarthSciAST._canonicalize_document_value(v, false)
            )
        )
    end
    function _sorted_json(v)
        if v isa AbstractDict
            ks = sort!([String(k) for k in keys(v)])
            return "{" * join(["$(JSON3.write(k)):$(_sorted_json(v[k]))" for k in ks], ",") * "}"
        end
        v isa AbstractVector && return "[" * join([_sorted_json(x) for x in v], ",") * "]"
        return JSON3.write(v)
    end

    # 1-D second-difference stencil faq over the FULL range, so the two end
    # cells gather an out-of-range (ghost) neighbour and form their own boundary
    # kernels — the canonical "interior kernel + boundary kernels" decomposition.
    # Shared by tree_walk_vectorized_test.jl and tree_walk_allocation_test.jl.
    function _stencil_model(N)
        vars = Dict(
            "u" => EarthSciAST.ModelVariable(
                EarthSciAST.UnknownVariable
            )
        )
        body = _op(
            "+",
            _idx("u", _op("-", _v("i"), _i(1))),
            _op("*", _n(-2.0), _idx("u", _v("i"))),
            _idx("u", _op("+", _v("i"), _i(1)))
        )
        return EarthSciAST.Model(
            vars, [
                EarthSciAST.Equation(
                    _ao1(_Didx("u", _v("i")), "i", 1, N), _ao1(body, "i", 1, N)
                ),
            ]
        )
    end

    # ---------------------------------------------------------------------------
    # JSON normalization: recursively convert any JSON3.Object / AbstractDict /
    # JSON3.Array / AbstractVector tree into plain Dict{String,Any} / Any[]
    # so structurally-equal payloads compare `==` regardless of container type.
    # ---------------------------------------------------------------------------
    _normj(x) =
        (x isa AbstractDict || x isa JSON3.Object) ?
        Dict{String, Any}(string(k) => _normj(v) for (k, v) in pairs(x)) :
        (x isa AbstractVector || x isa JSON3.Array) ?
        Any[_normj(v) for v in x] : x

    """
        corpus_is_resource_error(e) -> Bool

    Errors a fixture-corpus sweep must never swallow. Those sweeps tolerate a model
    that cannot build standalone by catching everything and skipping it — which
    also catches the process running out of memory or stack. Resource exhaustion
    then reads as an ordinary skip and the run stays green having tested nothing,
    which is exactly how a fixture whose grid exhausted the allocator sat in the
    corpus unnoticed. Rethrow these; skip on the rest.

    This is a BACKSTOP, not the primary defence. The library is expected to deliver
    these three unwrapped — `EarthSciAST._is_resource_error` marks the same set,
    and every speculative-evaluation `catch` in `src/` that would otherwise decline
    or rebrand consults it first — precisely so a resource error never reaches a
    sweep disguised as a `TreeWalkError`, which this predicate could not recognise.
    Keep the backstop anyway: it costs nothing and it is what catches the next
    `catch` site that forgets.
    """
    corpus_is_resource_error(e) =
        e isa OutOfMemoryError || e isa StackOverflowError || e isa InterruptException

    """
        _require_fixture(path) -> Bool

    Return `true` when the fixture file (or directory) at `path` exists. Every
    fixture lives in this repository, so a missing one is a FAILED test in the
    enclosing testset, not a skip, and the function returns `false` so the
    caller does not go on to read it. Use as:

        if _require_fixture(fixture_path)
            ... tests that consume the fixture ...
        end
    """
    function _require_fixture(path::AbstractString)
        ispath(path) && return true
        @test ispath(path)
        return false
    end

    # Zero-allocation harness (rhs_alloc_bytes / built_rhs_alloc_bytes) — shared
    # by the tree-walk allocation and data-refresh tests. It carries its own
    # include guard, so a direct `include("zero_alloc_harness.jl")` elsewhere
    # stays harmless.
    include("zero_alloc_harness.jl")

    # A `u0` giving 0.0 to every ODE state (a `D` target on some equation's LHS)
    # of `doc` — a path, JSON text or a parsed `Dict` — that declares no `default`.
    # Several corpus documents leave their states' starting values to the harness;
    # built without one they are refused (`E_TREEWALK_MISSING_INITIAL_VALUE`,
    # esm-spec §11.4). Keys are `Model.var`, which `esm_problem` broadcasts over an
    # array state's cells.
    function harness_u0(doc)
        d = doc isa AbstractString ?
            JSON3.read(isfile(doc) ? read(doc, String) : doc, Dict{String, Any}) : doc
        d_target(lhs) = if lhs isa AbstractDict && get(lhs, "op", nothing) == "D"
            a = lhs["args"][1]
            a isa AbstractString ? a :
                (a isa AbstractDict && get(a, "op", nothing) == "index" ? a["args"][1] : nothing)
        elseif lhs isa AbstractDict && get(lhs, "op", nothing) == "faq"
            d_target(lhs["expr"])
        else
            nothing
        end
        out = Dict{String, Float64}()
        for (mname, m) in get(d, "models", Dict{String, Any}())
            m isa AbstractDict || continue
            vars = get(m, "variables", Dict{String, Any}())
            for eq in get(m, "equations", Any[])
                t = d_target(get(eq, "lhs", nothing))
                t isa AbstractString || continue
                v = get(vars, t, nothing)
                v isa AbstractDict && !haskey(v, "default") && (out["$mname.$t"] = 0.0)
            end
        end
        return out
    end

    # tests/bench/transport_3axis_7cubed_fullrank.esm with its equation spelled per
    # cell, `D(q[i,j,k]) = -(D_x(q)[i,j,k] + D_y(q)[i,j,k] + D_z(q)[i,j,k])`,
    # written to a temporary file. The fixture's whole-array spelling has its three
    # derivative `makearray`s lifted into observeds (tree_walk/hoist.jl), so no
    # cross product of their regions reaches the compile-once template tier; this
    # spelling's `index` operands are not lifted, so it still does.
    function fullrank_per_cell_fixture()
        fix = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench", "transport_3axis_7cubed_fullrank.esm")
        doc = JSON3.read(read(fix, String), Dict{String, Any})
        ix(e) = Dict("op" => "index", "args" => Any[e, "i", "j", "k"])
        D(w) = Dict("op" => "D", "args" => Any["q"], "wrt" => w)
        faq(e) = Dict(
            "op" => "faq", "args" => Any[], "output_idx" => Any["i", "j", "k"],
            "ranges" => Dict(
                "i" => Dict("from" => "x"), "j" => Dict("from" => "y"),
                "k" => Dict("from" => "z")
            ),
            "expr" => e
        )
        doc["models"]["Transport"]["equations"] = Any[
            Dict(
                "lhs" => faq(Dict("op" => "D", "args" => Any[ix("q")], "wrt" => "t")),
                "rhs" => faq(
                    Dict(
                        "op" => "-", "args" => Any[
                            Dict(
                                "op" => "+",
                                "args" => Any[ix(D("x")), ix(D("y")), ix(D("z"))]
                            ),
                        ]
                    )
                )
            ),
        ]
        path = joinpath(mktempdir(), "transport_3axis_7cubed_fullrank_per_cell.esm")
        open(io -> JSON3.write(io, doc), path, "w")
        return path
    end

    # ---------------------------------------------------------------------------
    # Manifest-driven conformance categories (tests/conformance/<category>/)
    # ---------------------------------------------------------------------------

    """
        conformance_manifest(category; bindings = ("julia", "python", "rust"))
            -> (dir, manifest)

    The category's directory and parsed `manifest.json`, checked: the file
    exists, names this category, and lists each of `bindings` as required.
    """
    function conformance_manifest(
            category::AbstractString;
            bindings = ("julia", "python", "rust")
        )
        dir = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance", category)
        path = joinpath(dir, "manifest.json")
        @test isfile(path)
        manifest = JSON3.read(read(path, String))
        @test manifest.category == category
        for b in bindings
            @test b in manifest.bindings_required
        end
        return dir, manifest
    end

    """
        check_inline_golden(category, alg; by_test = false, solver_from_manifest = false,
                            compiler = :native, extra = nothing) -> Dict{String,Dict}

    Run every fixture of an inline-test conformance category through
    `run_inline_tests` with `alg` (and `compiler`, named rather than inherited)
    and require each golden assertion to pass and to reproduce the golden actual
    within the manifest's assertion tolerances. Results are matched to the
    golden by `assertion_idx`, or by `(test_id, assertion_idx)` with
    `by_test = true`. Tolerances of the solve are the manifest's
    `integrators.julia` with `solver_from_manifest = true`, else
    `reltol = 1e-12, abstol = 1e-14`. A golden assertion that names its
    `variable` must name the same one.

    `extra(fixture, by_key, tol)` runs inside each fixture's testset for a
    category's own assertions (`tol = (rtol, atol)`). Returns fixture id →
    the results keyed as matched.
    """
    function check_inline_golden(
            category::AbstractString, alg; by_test::Bool = false,
            solver_from_manifest::Bool = false, compiler::Symbol = :native,
            extra = nothing
        )
        dir, manifest = conformance_manifest(category)
        @test !isempty(manifest.fixtures)
        rtol = Float64(manifest.tolerances.assertion_rtol)
        atol = Float64(manifest.tolerances.assertion_atol)
        reltol, abstol = 1.0e-12, 1.0e-14
        if solver_from_manifest
            integ = manifest.integrators.julia
            @test String(integ.algorithm) == "Tsit5"
            reltol, abstol = Float64(integ.reltol), Float64(integ.abstol)
        end
        out = Dict{String, Dict}()
        for fixture in manifest.fixtures
            id = String(fixture.id)
            @testset "$(id)" begin
                esm_path = joinpath(dir, String(fixture.path))
                golden_path = joinpath(dir, String(fixture.golden))
                @test isfile(esm_path)
                @test isfile(golden_path)
                golden = JSON3.read(read(golden_path, String))
                @test String(golden.reference_binding) == "julia"
                results = run_inline_tests(
                    esm_path; model_name = String(fixture.model), alg = alg,
                    reltol = reltol, abstol = abstol, compiler = compiler
                )
                @test length(results) == length(golden.assertions)
                key(r) = by_test ? (r.test_id, r.assertion_idx) : r.assertion_idx
                gkey(g) = by_test ? (String(g.test_id), Int(g.assertion_idx)) :
                    Int(g.assertion_idx)
                by_key = Dict(key(r) => r for r in results)
                for g in golden.assertions
                    k = gkey(g)
                    @test haskey(by_key, k)
                    r = by_key[k]
                    @test r.passed
                    @test r.actual !== nothing
                    haskey(g, :variable) && @test r.variable == String(g.variable)
                    @test isapprox(r.actual, Float64(g.actual); rtol = rtol, atol = atol)
                end
                extra === nothing || extra(fixture, by_key, (rtol, atol))
                out[id] = by_key
            end
        end
        return out
    end

    # ---------------------------------------------------------------------------
    # Workspace purity (API_SPEC §5.8): every object reachable from `f`.
    # ---------------------------------------------------------------------------
    function reachable_objects(f)
        seen = IdDict{Any, Nothing}()
        function walk(x)
            isbits(x) && return
            x isa Union{String, Symbol, Expr, Module, DataType, UnionAll, Core.TypeName, Method} &&
                return
            haskey(seen, x) && return
            seen[x] = nothing
            if x isa Array
                isbitstype(eltype(x)) && return
                foreach(i -> isassigned(x, i) && walk(x[i]), eachindex(x))
                return
            end
            return foreach(i -> isdefined(x, i) && walk(getfield(x, i)), 1:nfields(x))
        end
        walk(f)
        return seen
    end

    # Whether calls on two workspaces of `prog` leave every numeric array both
    # instances reach as it was: a call writing an array the build did not
    # register as scratch would give the two workspaces one buffer.
    # `call(ws)` evaluates on workspace `ws`.
    function workspace_shared_arrays_unchanged(prog, call)
        w1, w2 = EarthSciAST.rhs_workspace(prog), EarthSciAST.rhs_workspace(prog)
        o1, o2 = reachable_objects(w1.f!), reachable_objects(w2.f!)
        shared = [
            x for x in keys(o1)
                if haskey(o2, x) && x isa Array && isbitstype(eltype(x)) && !isempty(x)
        ]
        snap = map(copy, shared)
        call(w1)
        call(w2)
        return all(isequal.(shared, snap))
    end

end # ESM_TESTUTILS_LOADED guard
