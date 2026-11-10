# Template rewrites of the skolem / rank / gated-argmin fixtures against the op
# forms (tests/conformance/relational_templates/rewrites/manifest.json).
#
# Each rewrite replaces the value-invention ops with lib/relational.esm
# templates (`pair_key` / `edge_key` keys, per-component join columns, the loop
# index for a set's own rank, `argmin_where` for a gated arg-witness). Both forms
# are built with the same caller data and must agree: the derived set's members
# (the op's tuples against the template's integer keys, decoded), its extent,
# the 1-based dense IDs, the arg-witness buffers, and the right-hand side at the
# initial state, bit for bit, with the template built under the interpreter and
# strict native. Both forms are also checked against the expected values the
# manifest's `golden` files hold (computed from the op form by the reference
# binding, rewrites/goldens.py). A `value_invention_key_out_of_range` refusal
# names the column.

using Test
using JSON3
using EarthSciAST
import OrdinaryDiffEqTsit5  # the solver `run_inline_tests` picks

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const _RR_ROOT = TESTUTILS_REPO_ROOT
const _RR_DIR = joinpath(_RR_ROOT, "tests", "conformance", "relational_templates", "rewrites")
const _RR_LIB = joinpath(_RR_ROOT, "lib", "relational.esm")
const _RR_MANIFEST = JSON3.read(read(joinpath(_RR_DIR, "manifest.json"), String)).rewrites
const _RR_GOLDEN = Dict(
    String(e.id) => JSON3.read(read(joinpath(_RR_DIR, String(e.golden)), String))
        for e in _RR_MANIFEST if haskey(e, :golden)
)
_rr_bits(v) = reinterpret(UInt64, Float64.(collect(v)))

_rr_path(e) = haskey(e, :out) ? joinpath(_RR_ROOT, String(e.out)) : joinpath(_RR_DIR, "$(e.id).esm")
_rr_native(path) = EarthSciAST.Cadence.to_native(JSON3.read(read(path, String)))
_rr_floats(v) = Float64.(
    v isa AbstractVector && !isempty(v) && first(v) isa AbstractVector ?
        permutedims(reduce(hcat, [Float64.(r) for r in v])) : collect(v)
)
_rr_data(case) = Dict{String, Any}(String(k) => _rr_floats(v) for (k, v) in case.const_arrays)
_rr_params(case) = Dict{String, Float64}(String(k) => Float64(v) for (k, v) in case.params)

# The `D` targets of `model` (each state the harness gives a start of 1.0).
function _rr_ode_states(doc, model)
    function target(lhs)
        lhs isa AbstractDict || return nothing
        if lhs["op"] == "D"
            a = lhs["args"][1]
            return a isa AbstractString ? String(a) : String(a["args"][1])
        end
        lhs["op"] == "faq" && return target(lhs["expr"])
        return nothing
    end
    return String[t for t in (target(eq["lhs"]) for eq in doc["models"][model]["equations"]) if t !== nothing]
end

# One form of `path` (its single `model`) built with the case's caller data.
function _rr_build(path, case, compiler, model)
    doc = _rr_native(path)
    doc["models"] = Dict{String, Any}(model => doc["models"][model])
    ca = Dict{String, Any}("$model.$k" => v for (k, v) in _rr_data(case))
    u0 = Dict{String, Float64}("$model.$s" => 1.0 for s in _rr_ode_states(doc, model))
    haskey(case, :u0) && for (k, v) in case.u0
        u0["$model.$k"] = Float64(v)
    end
    return esm_problem(
        doc, (0.0, 1.0); p = _rr_params(case), u0,
        const_arrays = ca, compiler, base_path = dirname(path)
    )
end

# Value invention over `path`'s typed `model`, with the build front door's
# derived binning coordinates and `const`-op array observeds as factors.
function _rr_vi(path, case, model)
    file = load_path(path)
    m = EarthSciAST.expanded_model(file, model)
    ca = _rr_data(case)
    params = _rr_params(case)
    merge!(
        ca, EarthSciAST._derive_binning_coords(
            m, file.index_sets, ca, params, EarthSciAST._vi_skolem_index_targets(m)
        )
    )
    for (n, defn) in EarthSciAST.observed_definitions(m)
        defn isa EarthSciAST.OpExpr && defn.op == "const" && defn.value isa AbstractVector &&
            !haskey(ca, n) && (ca[n] = EarthSciAST._const_op_to_array(defn.value))
    end
    return EarthSciAST.materialize_value_invention(m, file.index_sets, ca, params)
end

_rr_decode(k, lo, n_b) = (div(k, n_b) + lo[1], mod(k, n_b) + lo[2])

# `rank_of(x, members, n)` from lib/relational.esm, as the derivative of a state.
function _rr_rank_of(x, members)
    doc = Dict{String, Any}(
        "esm" => "1.1.0",
        "metadata" => Dict{String, Any}("name" => "rank_of_probe", "authors" => Any["t"]),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "expression_template_imports" => Any[Dict{String, Any}("ref" => _RR_LIB)],
                "variables" => Dict{String, Any}(
                    "r" => Dict{String, Any}("type" => "unknown", "units" => "1", "default" => 0.0)
                ),
                "equations" => Any[
                    Dict{String, Any}(
                        "lhs" => Dict{String, Any}("op" => "D", "args" => Any["r"], "wrt" => "t"),
                        "rhs" => Dict{String, Any}(
                            "op" => "apply_expression_template", "args" => Any[], "name" => "rank_of",
                            "bindings" => Dict{String, Any}(
                                "x" => x,
                                "members" => Dict{String, Any}(
                                    "op" => "const", "args" => Any[], "value" => members
                                ),
                                "n" => length(members)
                            )
                        )
                    ),
                ]
            )
        )
    )
    f!, u0, p, _, vm = EarthSciAST._build_evaluator(load_string(JSON3.write(doc)); compiler = :interpreter)
    du = similar(u0)
    f!(du, u0, p, 0.0)
    return du[vm["r"]]
end

# The right-hand side at the initial state, keyed by state-element name.
function _rr_rhs(prob)
    du = similar(prob.u0)
    prob.f!(du, copy(prob.u0), prob.p, 0.0)
    return Dict(n => du[i] for (n, i) in prob.var_map)
end

# A state element's golden key: `Model.var[1, 2]` -> `var[1,2]`.
_rr_key(n, model) = replace(startswith(n, model * ".") ? n[(length(model) + 2):end] : n, " " => "")

# The right-hand side at the golden probe state, keyed like it.
function _rr_rhs_at(prob, model, state)
    st = Dict{String, Float64}(String(k) => Float64(v) for (k, v) in state)
    names = Dict(_rr_key(String(n), model) => i for (n, i) in prob.var_map)
    @assert Set(keys(names)) == Set(keys(st)) "state elements $(sort(collect(keys(names)))) vs $(sort(collect(keys(st))))"
    u = similar(prob.u0)
    for (n, i) in names
        u[i] = st[n]
    end
    du = similar(u)
    prob.f!(du, u, prob.p, 0.0)
    return Dict(n => du[i] for (n, i) in names)
end

const _RR_CASES = [
    (e, i, case) for e in _RR_MANIFEST for (i, case) in enumerate(e.cases)
        if !haskey(e.compare, :tier)
]

@testset "lib/relational.esm rewrites of the skolem / rank / gated-argmin fixtures" begin
    @testset "relational template rewrites agree with the op forms" begin
        @testset "$(e.id) case $i [$(compiler)]" for (e, i, case) in _RR_CASES,
                compiler in (:interpreter, :native)
            cmp = e.compare
            model = String(e.models[1])
            src = joinpath(_RR_ROOT, String(e.source))
            tpl = _rr_path(e)
            gold = _RR_GOLDEN[String(e.id)].cases[i]
            # Derived sets: members and extents, from value invention on each form.
            if haskey(cmp, :sets)
                op_vi = _rr_vi(src, case, model)
                tp_vi = _rr_vi(tpl, case, model)
                for s in cmp.sets
                    faq = String(s.faq)
                    tp_members = tp_vi.members[faq]
                    @test all(m -> m isa Integer, tp_members)
                    @test tp_members == sort(unique(tp_members))
                    decoded = [_rr_decode(m, s.decode.lo, Int(s.decode.n_b)) for m in tp_members]
                    @test decoded == [Tuple(m) for m in op_vi.members[faq]]
                    @test tp_vi.extents[faq] == op_vi.extents[faq]
                    gs = gold.sets[Symbol(faq)]
                    want = [Tuple(Int.(m)) for m in gs.members]
                    @test [Tuple(m) for m in op_vi.members[faq]] == want   # op form vs golden
                    @test decoded == want                                  # template vs golden
                    @test tp_vi.extents[faq] == gs.extent
                end
            end
            get(cmp, :vi_only, false) && continue
            op_prob = _rr_build(src, case, :interpreter, model)
            tp_prob = _rr_build(tpl, case, compiler, model)
            if haskey(cmp, :rank)
                faq = String(cmp.rank.faq)
                op_members = [Tuple(m) for m in _rr_vi(src, case, model).members[faq]]
                ids = EarthSciAST.Relational.rank(op_members; base = 0)
                want = Float64[ids.id[m] + 1 for m in op_members]   # the 0 -> 1 base shift
                rvar = String(cmp.rank.variable)
                @test vec(observed_field(tp_prob, rvar)) == want
                @test _rr_bits(want) == _rr_bits(gold.rank.values)
                @test _rr_bits(vec(observed_field(tp_prob, rvar))) == _rr_bits(gold.rank.values)
                tp_members = _rr_vi(tpl, case, model).members[faq]
                @test [_rr_rank_of(m, tp_members) for m in tp_members] == want
            end
            if haskey(cmp, :rank_lookup)
                # A rank looked up against the derived set (rank_of_set over
                # its members): the op set's 0-based rank of each row's tuple, + 1.
                rl = cmp.rank_lookup
                op_members = [Tuple(m) for m in _rr_vi(src, case, model).members[String(rl.faq)]]
                ids = EarthSciAST.Relational.rank(op_members; base = 0)
                cols = [reduce(vcat, permutedims.(Vector{Float64}.(case.const_arrays[Symbol(c)]))) for c in rl.columns]
                want = map(CartesianIndices(cols[1])) do I
                    t = Tuple(sort([Int(c[I]) for c in cols]))
                    Float64(ids.id[t] + 1)
                end
                # The field is flat, rows outermost (the order of the case's nested arrays).
                got = Float64.(vec(observed_field(tp_prob, String(rl.variable))))
                @test reinterpret(UInt64, got) == reinterpret(UInt64, vec(permutedims(want)))
                @test _rr_bits(vec(permutedims(want))) == _rr_bits(gold.rank_lookup.values)
                @test _rr_bits(got) == _rr_bits(gold.rank_lookup.values)
            end
            for a in get(cmp, :assignments, [])
                op_buf = Float64.(_rr_vi(src, case, model).assignments[String(a.op)])
                tp_buf = Float64.(vec(observed_field(tp_prob, String(a.template))))
                @test tp_buf == op_buf
                @test reinterpret(UInt64, tp_buf) == reinterpret(UInt64, op_buf)
                @test _rr_bits(op_buf) == _rr_bits(gold.assignments[Symbol(a.template)])
            end
            if get(cmp, :rhs, false)
                dy_op, dy_tp = _rr_rhs(op_prob), _rr_rhs(tp_prob)
                @test Set(keys(dy_tp)) == Set(keys(dy_op))
                @test all(n -> dy_tp[n] === dy_op[n], keys(dy_op))
                want = Dict(String(k) => Float64(v) for (k, v) in gold.rhs.dy)
                for prob in (op_prob, tp_prob)
                    got = _rr_rhs_at(prob, model, gold.rhs.state)
                    @test Set(keys(got)) == Set(keys(want))
                    @test all(n -> got[n] === want[n], keys(want))
                end
            end
        end
    end

    @testset "rewrites load, and run their inline tests like the op form" begin
        @testset "$(e.id)" for e in _RR_MANIFEST
            cmp = e.compare
            (get(cmp, :inline_tests, false) || get(cmp, :load_only, false)) || continue
            path = _rr_path(e)
            @test load_path(path) isa EsmFile
            if get(cmp, :inline_tests, false)
                op = run_inline_tests(joinpath(_RR_ROOT, String(e.source)); compiler = :interpreter)
                tp = run_inline_tests(path; compiler = :interpreter)
                @test [r.actual for r in tp] == [r.actual for r in op]
                # Integrator outputs: within each assertion's tolerance, not bit for bit.
                gold = _RR_GOLDEN[String(e.id)].inline_tests
                for res in (op, tp)
                    @test length(res) == length(gold)
                    @test all(zip(res, gold)) do (r, g)
                        abs(r.actual - g.actual) <= max(g.atol, g.rtol * abs(g.actual))
                    end
                end
            end
        end
    end

    @testset "relational_templates tier rewrites pass their inline tests" begin
        @testset "$(fx) [$(compiler)]" for fx in ("edge_enumeration_ode.esm", "bin_skolem_count_ode.esm"),
                compiler in (:interpreter, :native)
            results = run_inline_tests(joinpath(_RR_DIR, fx); compiler)
            @test !isempty(results)
            @test all(r -> r.status == EarthSciAST.PASS, results)
        end
    end

    @testset "an out-of-range key component is refused, naming the column" begin
        e = only(x for x in _RR_MANIFEST if x.id == "bin_skolem_spatial_join")
        doc = _rr_native(_rr_path(e))
        model = doc["models"]["BinSkolemSpatialJoin"]
        for eq in model["equations"]
            rhs = eq["rhs"]
            rhs isa AbstractDict && get(rhs, "distinct", false) === true &&
                (rhs["key"]["bindings"]["n_b"] = 2)   # j = 3, 4 fall outside [1, 3)
        end
        for ref in model["expression_template_imports"]
            ref["ref"] = _RR_LIB
        end
        case = e.cases[1]
        err = try
            esm_problem(
                doc, (0.0, 1.0); p = _rr_params(case), const_arrays = _rr_data(case),
                compiler = :interpreter
            )
            nothing
        catch ex
            ex
        end
        @test err isa EarthSciAST.TreeWalkError
        @test err isa EarthSciAST.TreeWalkError &&
            err.code == EarthSciAST.ERROR_CODES.VALUE_INVENTION_KEY_OUT_OF_RANGE
        @test occursin("candidate_set", sprint(showerror, err))
    end
end
