# The COMPILED backend: direct StableHLO emission from the compiled tree-walk IR
# (ext/reactant_direct/), against the interpreter.
#
# OPT-IN, like every reactant_*_test.jl: included only under `ESM_TEST_REACTANT=1`.
# Standalone, from an environment with Reactant + JSON3:
#
#     ESM_TEST_REACTANT=1 julia --project=<env> \
#       -e 'cd("pkg/EarthSciAST.jl/test"); include("reactant_direct_emit_test.jl")'
#
# Set `ESM_DIRECT_EMIT_DUMP_DIR=<dir>` to also write the raw (`optimize=false`)
# StableHLO modules of both backends to `<dir>/<fixture>.{direct,traced}.mlir`.
#
# WHAT IS ASSERTED.
#
#   NUMERICAL AGREEMENT with the in-place interpreter `f!` (and with the
#   out-of-place `f`, which is bit-identical to it), at the fixture's `u0` and at
#   deterministic perturbations of `u` and `t`, to `rtol = 1e-12`. NOT `==`: the
#   tolerance classes of tests/conformance/compiled_rhs/README.md are the
#   contract, XLA is free to reassociate, and `stablehlo.power` is not Julia's
#   `^`. Six shapes are covered — the conformance fixture, a reaction–diffusion
#   model (state, parameters, literal-exponent `^`, ghost-boundary kernels), a
#   LIVE FORCING model through the buffers argument, a template SUB-KERNEL model,
#   a closed `interp.linear` function, and the `datetime.*` calendar beside
#   `log10`.
#
#   THE CALENDAR IS PINNED EXACTLY, not to `rtol`. Eight of the nine
#   `datetime.*` fields are integers and the emitted program must return the
#   interpreter's integer, bit for bit, at every probe time — including negative
#   times, both signs of a leap day, a year boundary, a sub-second remainder and
#   `t` on and just below a day boundary. `julian_day`, the one continuous
#   member, is pinned to 1 ulp.
#
#   THE HARD-ERROR PATH. A model the emitter cannot lower raises
#   `DirectEmitError`, and the message names the construct AND the rule it came
#   from. Three refusals are pinned: an operator with no StableHLO form, the
#   three-argument call on a live-forcing model, and a host (untraced) call.
#
#   THE OP CENSUS of the emitted module is printed for the report and, for the
#   two structural fixtures, asserted where the assertion is about the IR ("one
#   constant per distinct literal", "no `dynamic_update_slice`") rather than
#   about XLA.

using Test
using EarthSciAST
using Reactant
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const ESM_DE = EarthSciAST
const RX_DE = Reactant
const EXT_DE = Base.get_extension(EarthSciAST, :EarthSciASTReactantExt)
@assert EXT_DE !== nothing "the Reactant extension did not load"

# ---- document builders -------------------------------------------------------

_de_Dt(v) = Dict{String,Any}("op" => "D", "args" => Any[v], "wrt" => "t")
_de_ix(v, i...) = Dict{String,Any}("op" => "index", "args" => Any[v, i...])
_de_o(o, a...) = Dict{String,Any}("op" => o, "args" => Any[a...])
_de_cst(v) = Dict{String,Any}("op" => "const", "value" => v)
_de_fnop(nm, a...) = Dict{String,Any}("op" => "fn", "name" => nm, "args" => Any[a...])
_de_ao(e) = Dict{String,Any}("op" => "faq", "output_idx" => Any["i"],
    "ranges" => Dict{String,Any}("i" => Dict{String,Any}("from" => "n")),
    "args" => Any[], "expr" => e)
_de_doc(name, vars, eqs; index_sets = nothing) = begin
    d = Dict{String,Any}(
        "esm" => "0.5.0", "metadata" => Dict{String,Any}("name" => name),
        "models" => Dict{String,Any}("M" => Dict{String,Any}(
            "variables" => vars, "equations" => eqs)))
    index_sets === nothing || (d["index_sets"] = index_sets)
    d
end
_de_nset(N) = Dict{String,Any}("n" => Dict{String,Any}("kind" => "interval", "size" => N))
_de_state(; kw...) = Dict{String,Any}("type" => "unknown",
                                      (String(k) => v for (k, v) in kw)...)
_de_param(v) = Dict{String,Any}("type" => "parameter", "default" => v)

# 1-D reaction–diffusion: the stencil GATHER, a boundary const vector, the
# hoisted invariant `exp(-Ea/T)`, the literal-exponent `c[i]^2`, and the
# degenerate single-cell boundary kernels.
function _de_rd(N)
    stencil = _de_o("+", _de_o("-", _de_ix("c", _de_o("-", "i", 1.0)),
                               _de_o("*", 2.0, _de_ix("c", "i"))),
                    _de_ix("c", _de_o("+", "i", 1.0)))
    rate = _de_o("*", "k_rxn", _de_o("exp", _de_o("neg", _de_o("/", "Ea", "T"))))
    _de_doc("RD",
        Dict{String,Any}("c" => _de_state(shape = Any["n"]), "k_diff" => _de_param(0.1),
                         "k_rxn" => _de_param(0.3), "Ea" => _de_param(50.0),
                         "T" => _de_param(300.0)),
        Any[Dict{String,Any}("lhs" => _de_ao(_de_Dt(_de_ix("c", "i"))),
            "rhs" => _de_ao(_de_o("-", _de_o("*", "k_diff", stencil),
                                  _de_o("*", rate, _de_o("^", _de_ix("c", "i"), 2.0)))))];
        index_sets = _de_nset(N))
end

# `D(c[i]) = -k*c[i] + wind[i]`, `wind` a LIVE forcing buffer bound by reference
# through `param_arrays` — the discrete-cadence loader channel.
function _de_forced(N)
    body = _de_o("+", _de_o("*", -1.0, _de_o("*", "k", _de_ix("c", "i"))),
                 _de_ix("wind", "i"))
    _de_doc("F", Dict{String,Any}("c" => _de_state(shape = Any["n"]),
                                  "k" => _de_param(0.5)),
        Any[Dict{String,Any}("lhs" => _de_ao(_de_Dt(_de_ix("c", "i"))),
                             "rhs" => _de_ao(body))];
        index_sets = _de_nset(N))
end

# A closed `interp.linear` over a frozen table, the query being the state.
function _de_interpdoc()
    table = Any[0.0, 1.0, 4.0, 9.0, 16.0]
    axis = Any[0.0, 1.0, 2.0, 3.0, 4.0]
    _de_doc("IT", Dict{String,Any}("y" => _de_state(default = 1.5),
                                   "k" => _de_param(2.0)),
        Any[Dict{String,Any}("lhs" => _de_Dt("y"),
            "rhs" => _de_o("*", "k",
                           _de_fnop("interp.linear", _de_cst(table), _de_cst(axis), "y")))])
end

# The hard-error fixture. It used to be `log10`, which the ladder now lowers as
# `log(x)/ln(10)` — and with that there is no REGISTRY OPERATOR left for this
# fixture to use: the ladder covers the whole closed evaluable-core scalar set
# (esm-spec §4.2), so a well-formed document cannot reach `_de_op`'s
# fallthrough any more. That is the intended state and not a gap in this test,
# so the fixture moves to the refusal a malformed node still reaches: `/` is
# binary in the IR, and a three-argument one is refused by BOTH ladders — the
# interpreter's `_expect_arity_n` at evaluation, this emitter's arity arm at
# emission. What the test is about is unchanged: the message must name the
# construct in the IR's own vocabulary AND the rule it came from.
function _de_unsupported_op()
    _de_doc("U", Dict{String,Any}("y" => _de_state(default = 2.0)),
        Any[Dict{String,Any}("lhs" => _de_Dt("y"),
                             "rhs" => _de_o("neg", _de_o("/", "y", 2.0, 3.0)))])
end

# The nine `datetime.*` closed functions, one equation each, plus the two shapes
# the family actually wears in a model: an argument that is an EXPRESSION rather
# than the bare time, whose integer result then flows into ordinary Float64
# arithmetic (`hour(t + tz) + lon/15` — a local solar hour), and `log10` beside
# them so the two gaps this file grew for are exercised in one program.
const _DE_DT_FNS = ("year", "month", "day", "hour", "minute", "second",
                    "day_of_year", "julian_day", "is_leap_year")

function _de_dtdoc()
    vars = Dict{String,Any}("tz" => _de_param(3600.0), "lon" => _de_param(-88.2),
                            "k_log" => _de_param(2.0),
                            "local_hour" => _de_state(default = 0.0),
                            "lg" => _de_state(default = 5.0))
    eqs = Any[]
    for f in _DE_DT_FNS
        vars["c_$f"] = _de_state(default = 0.0)
        push!(eqs, Dict{String,Any}("lhs" => _de_Dt("c_$f"),
                                    "rhs" => _de_fnop("datetime.$f", "t")))
    end
    push!(eqs, Dict{String,Any}("lhs" => _de_Dt("local_hour"),
        "rhs" => _de_o("+", _de_fnop("datetime.hour", _de_o("+", "t", "tz")),
                       _de_o("/", "lon", 15.0))))
    push!(eqs, Dict{String,Any}("lhs" => _de_Dt("lg"),
                                "rhs" => _de_o("*", "k_log", _de_o("log10", "lg"))))
    _de_doc("DT", vars, eqs)
end

# The times a calendar gets wrong, which is the only reason to test one:
# the epoch (a day AND a year boundary), negative times whole and fractional
# (FLOORED division, not truncated), a leap day on each side of the epoch, a
# year boundary half a second short (the family truncates to whole
# milliseconds), and `t` just below and exactly on a day boundary. The same
# eight times the `datetime_log10` conformance fixture probes.
const _DE_DT_TIMES = [0.0, -1.0, -0.5, -58039200.0, 1582979696.0,
                      1704067199.5, 86399.75, 86400.0]

# The flat slot of an element, whether or not the evaluator's map spells it with
# the model namespace.
function _de_slot(vmap, name::AbstractString)
    haskey(vmap, name) && return vmap[name]
    for (k, v) in vmap
        endswith(String(k), "." * name) && return v
    end
    error("no flat slot named $name in $(collect(keys(vmap)))")
end

# ---- harness -----------------------------------------------------------------

_de_dev(p::NamedTuple) = NamedTuple{keys(p)}(map(RX_DE.ConcreteRNumber, values(p)))
_de_dev(::Nothing) = nothing

_de_ip(f!, u, p, t) = (du = zero(u); f!(du, u, p, t); du)

# `@compile` runs the emission inside its own machinery, which may wrap what the
# trace threw. Dig the `DirectEmitError` out of whatever came back, so a test can
# assert on its FIELDS (construct, rule) and not on a rendered string.
function _de_unwrap(e)
    e isa EarthSciAST.DirectEmitError && return e
    for f in (:error, :ex, :exception, :task, :captured)
        if hasproperty(e, f)
            inner = getproperty(e, f)
            inner === e && continue
            r = _de_unwrap(inner)
            r === nothing || return r
        end
    end
    if e isa CompositeException || e isa AbstractVector
        for x in e
            r = _de_unwrap(x)
            r === nothing || return r
        end
    end
    return nothing
end
_de_seed(n) = [0.6sin(0.7k) - 0.15 for k in 1:n]

# Count `stablehlo.<op>` / `chlo.<op>` occurrences in a printed module.
function _de_census(modstr::AbstractString)
    c = Dict{String,Int}()
    for m in eachmatch(r"\b(?:stablehlo|chlo)\.([a-z_0-9]+)", modstr)
        k = m.captures[1]
        c[k] = get(c, k, 0) + 1
    end
    return c
end

function _de_print_census(label, c)
    println("  op census — ", label, " (", sum(values(c)), " ops):")
    for k in sort!(collect(keys(c)))
        println("    ", rpad(k, 24), c[k])
    end
end

_de_dumpdir() = get(ENV, "ESM_DIRECT_EMIT_DUMP_DIR", "")

function _de_dump(name, which, modstr)
    d = _de_dumpdir()
    isempty(d) && return
    mkpath(d)
    write(joinpath(d, "$(name).$(which).mlir"), modstr)
end

# Compare direct emission against the interpreter at a list of (u, t) samples.
# `buffers === nothing` uses the three-argument form; otherwise the explicit
# buffers form, with the SAME host buffers the interpreter reads.
function _de_compare(name, fo, fi!, p, samples; buffers = nothing, rtol = 1e-12,
                     census = true)
    d = EXT_DE.direct_rhs(fo)
    callee = buffers === nothing ? d : EXT_DE.direct_rhs_with_buffers(d)
    pr = _de_dev(p)
    u1, t1 = samples[1]
    ur = RX_DE.ConcreteRArray(copy(u1))
    tr = RX_DE.ConcreteRNumber(t1)
    compiled = buffers === nothing ?
        (RX_DE.@compile sync = true callee(ur, pr, tr)) :
        (RX_DE.@compile sync = true callee(ur, pr, tr, buffers))
    println("  direct-emission tallies (", name, "): ", d.stats)
    rows = Tuple{String,Float64,Float64,Float64}[]
    for (u, t) in samples
        du_i = _de_ip(fi!, u, p, t)
        uu = RX_DE.ConcreteRArray(copy(u)); tt = RX_DE.ConcreteRNumber(t)
        du_d = Array(buffers === nothing ? compiled(uu, pr, tt) :
                                           compiled(uu, pr, tt, buffers))
        aerr = maximum(abs.(du_d .- du_i))
        rerr = maximum(abs.(du_d .- du_i) ./ max.(abs.(du_i), 1e-300))
        # The sample LABEL, not the sample: a 343-cell state printed in full is
        # three screens of log for one row.
        head = repr(round.(u[1:min(end, 4)]; sigdigits = 3))
        push!(rows, (string("t=", t, " u[1:", min(length(u), 4), "]=", head,
                            length(u) > 4 ? " …($(length(u)))" : ""),
                     aerr, rerr, maximum(abs.(du_i))))
        @test isapprox(du_d, du_i; rtol = rtol, atol = 0.0)
    end
    println("  numerical comparison (", name, "):")
    println("    ", rpad("sample", 44), rpad("max |Δ|", 14), rpad("max rel", 14),
            "max |ref|")
    for (s, a, r, m) in rows
        println("    ", rpad(s, 44), rpad(string(a), 14), rpad(string(r), 14), m)
    end
    census || return (d, Dict{String,Int}())
    # The raw module census. INFORMATIONAL — printed so a change in emitted shape
    # is visible in the log, never a gate.
    mod_direct = buffers === nothing ?
        repr(RX_DE.@code_hlo optimize = false callee(ur, pr, tr)) :
        repr(RX_DE.@code_hlo optimize = false callee(ur, pr, tr, buffers))
    _de_dump(name, "direct", mod_direct)
    cd_ = _de_census(mod_direct)
    _de_print_census("direct (raw)", cd_)
    return (d, cd_)
end

# ---- staggered prefix-scan fixtures -----------------------------------------
# `c` on the n+1 nodes, terms on the n centres. `u` is held fixed so the
# equation under test owns `c` alone, and the fold lands on `du`.
function _de_scan_stag(n::Int; reduce = "+")
    vars = Dict("u" => ESM_DE.ModelVariable(ESM_DE.UnknownVariable),
                "c" => ESM_DE.ModelVariable(ESM_DE.UnknownVariable))
    rhs = ESM_DE.OpExpr("faq", ESM_DE.ASTExpr[]; output_idx = Any["i"],
        expr_body = _idx("u", _v("j")),
        ranges = Dict("i" => [1, n + 1], "j" => [1, n]), reduce = reduce,
        filter = _op("<", _v("j"), _v("i")))
    ESM_DE.Model(vars, [
        ESM_DE.Equation(_ao1(_Didx("c", _v("i")), "i", 1, n + 1), rhs),
        ESM_DE.Equation(_ao1(_Didx("u", _v("i")), "i", 1, n),
                        _ao1(_n(0.0), "i", 1, n)),
    ])
end

# The same staggered scan as a MATERIALIZED ARRAY OBSERVED's fill, which is
# the shape ReSEACT actually carries: `Mz` is an array observed, so its
# aggregate is evaluated once per call into a buffer above the ODE state
# (`_unwrap_identity_gather` lifts the fill's identity gather so the scan is
# detected), and the uncovered node is a slot of the EXTENDED map rather
# than of `du`. `D(u[i]) = Mz[i+1] - Mz[i]` reads the buffer at two distinct
# index expressions, which is what keeps `Mz` materialized.
function _de_scan_stag_obs(n::Int)
    isets = Dict("lev" => ESM_DE.IndexSet("interval"; size = n),
                 "levn" => ESM_DE.IndexSet("interval"; size = n + 1))
    agg_lev(body) = ESM_DE.OpExpr("faq", ESM_DE.ASTExpr[];
        output_idx = Any["i"], expr_body = body,
        ranges = Dict{String,Any}("i" => ESM_DE.IndexSetRef("lev")))
    mz = ESM_DE.OpExpr("faq", ESM_DE.ASTExpr[]; output_idx = Any["ke"],
        expr_body = _op("*", _v("w"), _idx("u", _v("k"))),
        ranges = Dict{String,Any}("ke" => ESM_DE.IndexSetRef("levn"),
                                  "k" => ESM_DE.IndexSetRef("lev")),
        reduce = "+", filter = _op("<", _v("k"), _v("ke")))
    vars = Dict(
        "u" => ESM_DE.ModelVariable(ESM_DE.UnknownVariable; shape = ["lev"]),
        "Mz" => ESM_DE.ModelVariable(ESM_DE.UnknownVariable; shape = ["levn"]),
        "w" => ESM_DE.ModelVariable(ESM_DE.ParameterVariable; default = 0.75))
    eqs = [
        ESM_DE.Equation(_v("Mz"), mz),
        ESM_DE.Equation(agg_lev(_Didx("u", _v("i"))),
                        agg_lev(_op("-", _idx("Mz", _op("+", _v("i"), _i(1))),
                                    _idx("Mz", _v("i"))))),
    ]
    return ESM_DE.Model(vars, eqs), isets
end

# ---- the lane-batched scalar surface (ess-oop-batch) -------------------------
#
# The shape that surface exists for: a mass-weighted halo tent. Per OUTPUT CELL one `_NK_CONTRACTION_LOOP` whose body
# reads the state at a loop-var-dependent slot (`_NK_STATE_GATHER`) times a
# per-cell frozen weight (`_NK_CONST_GATHER`). Every output cell is congruent,
# so the whole surface is ONE group of `NI*NJ` lanes — and each of the tent's
# `M*M` iterations is one whole-lane read instead of one one-element slice per
# cell. `NI = NJ = 6` because the read cost model wants at least eight pieces
# before it prefers a gather: at four lanes there is nothing to decide.
function _de_halo(; NI = 6, NJ = 6, M = 3)
    NQ = max(NI, NJ) + M - 1
    W = [[[[Float64((i + 2j + 3k + 5l) % 7) for l in 1:M] for k in 1:M]
          for j in 1:NJ] for i in 1:NI]
    donor(a, b) = Dict{String,Any}("op" => "-",
        "args" => Any[Dict{String,Any}("op" => "+", "args" => Any[a, b]), 1])
    agg = Dict{String,Any}("op" => "faq", "semiring" => "sum_product", "args" => Any[],
        "output_idx" => Any["i", "j"],
        "ranges" => Dict{String,Any}("i" => Any[1, NI], "j" => Any[1, NJ],
                                     "k" => Any[1, M], "l" => Any[1, M]),
        "expr" => Dict{String,Any}("op" => "*", "args" => Any[
            Dict{String,Any}("op" => "index", "args" => Any[
                Dict{String,Any}("op" => "const", "args" => Any[], "value" => W),
                "i", "j", "k", "l"]),
            Dict{String,Any}("op" => "index",
                             "args" => Any["q", donor("i", "k"), donor("j", "l")])]))
    zero_rhs = Dict{String,Any}("op" => "faq", "args" => Any[],
        "output_idx" => Any["a", "b"],
        "ranges" => Dict{String,Any}("a" => Any[1, NQ], "b" => Any[1, NQ]), "expr" => 0.0)
    q_lhs = Dict{String,Any}("op" => "faq", "args" => Any[],
        "output_idx" => Any["a", "b"],
        "ranges" => Dict{String,Any}("a" => Any[1, NQ], "b" => Any[1, NQ]),
        "expr" => _de_Dt(_de_ix("q", "a", "b")))
    out_lhs = Dict{String,Any}("op" => "faq", "args" => Any[],
        "output_idx" => Any["i", "j"],
        "ranges" => Dict{String,Any}("i" => Any[1, NI], "j" => Any[1, NJ]),
        "expr" => _de_Dt(_de_ix("out", "i", "j")))
    doc = Dict{String,Any}("esm" => "1.1.0",
        "metadata" => Dict{String,Any}("name" => "de_halo"),
        "models" => Dict{String,Any}("R" => Dict{String,Any}(
            "variables" => Dict{String,Any}(
                "q" => _de_state(shape = Any["a", "b"]),
                "out" => _de_state(shape = Any["i", "j"])),
            "equations" => Any[
                Dict{String,Any}("lhs" => q_lhs, "rhs" => zero_rhs),
                Dict{String,Any}("lhs" => out_lhs, "rhs" => agg)])))
    ics = Dict{String,Any}()
    for i in 1:NI, j in 1:NJ
        ics["out[$i,$j]"] = 0.0
    end
    for a in 1:NQ, b in 1:NQ
        ics["q[$a,$b]"] = Float64(10a + b)
    end
    return (doc, ics, NI, NJ, M)
end

# The routing this fixture depends on is named rather than inherited: the
# contraction loop tier has to take the reduction (so there ARE per-cell
# `rhs_list` entries to batch) and the whole-array contraction tier must not
# take it first.
_de_halo_build(doc, ics; form = :oop, batch = true) =
    withenv("ESS_CONTRACTION_LOOP" => "1", "ESS_CONTRACTION_LOOP_MIN" => "8",
            "ESS_ARRAY_CONTRACTION_MIN" => "1024",
            "ESS_OOP_BATCH" => (batch ? "1" : "0")) do
        build_evaluator(doc; initial_conditions = ics, form = form)
    end

@testset "direct StableHLO emission from the compiled IR" begin
    @testset "elementwise_gather conformance fixture" begin
        fixture = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                           "elementwise_observed_gather", "fixtures",
                           "elementwise_gather.esm")
        golden_path = joinpath(TESTUTILS_REPO_ROOT, "tests", "conformance",
                               "elementwise_observed_gather", "golden",
                               "elementwise_gather.json")
        @test isfile(fixture)
        file = ESM_DE.load_path(fixture)
        fo, u0, p, tspan, vmap = build_evaluator(file; model_name = "Column", form = :oop)
        fi!, u0i, _, _, _ = build_evaluator(file; model_name = "Column")
        @test u0 == u0i
        n = length(u0)
        samples = [(copy(u0), 0.0),
                   (collect(1.0:n), 0.37),
                   (sin.(1.0:n) .* 3.0, 1.0),
                   (fill(-2.5, n), 0.5)]
        d, cd_ = _de_compare("elementwise_gather", fo, fi!, p, samples)

        # The RHS of this fixture is state-independent and u0 = 0 over a unit
        # span, so du at t = 0 IS the golden solution at t = 1.
        dd = EXT_DE.direct_rhs(fo; var_map = vmap)
        ur = RX_DE.ConcreteRArray(copy(u0)); tr = RX_DE.ConcreteRNumber(0.0)
        du_d = Array((RX_DE.@compile sync = true dd(ur, nothing, tr))(ur, nothing, tr))
        golden = JSON3.read(read(golden_path, String))
        for a in golden.assertions
            a.reduce === nothing || continue
            idx = a.assertion_idx
            # assertion order in the fixture: u[lev=1], u[lev=3], max, min, s
            slot = idx == 1 ? vmap["u[1]"] : idx == 2 ? vmap["u[3]"] : vmap["s"]
            @test abs(du_d[slot] - a.actual) <= 1e-11
        end

        # What the IR asked for, and nothing else. The `total` contraction is a
        # literal-only subtree, so the host const-fold takes it at emission and
        # only the fill kernel's ONE lane `cosine` survives; the spike, which had
        # no const-fold, emitted five.
        @test get(cd_, "cosine", 0) == 1
        @test get(cd_, "dynamic_update_slice", 0) == 0
        @test get(cd_, "gather", 0) == 0
        @test get(cd_, "concatenate", 0) >= 1
        # One constant per distinct literal, nothing per USE.
        @test get(cd_, "constant", 0) <= 8
    end

    @testset "reaction–diffusion: state, parameters, pow, boundary kernels" begin
        N = 8
        fo, u0, p, _, _ = build_evaluator(_de_rd(N); form = :oop)
        fi!, _, _, _, _ = build_evaluator(_de_rd(N))
        u1 = collect(range(0.2, 1.7; length = N))
        samples = [(u1, 0.0), (u1 .^ 2 .- 0.5, 2.0), (reverse(u1) .* 1.3, 10.0)]
        d, cd_ = _de_compare("reaction_diffusion", fo, fi!, p, samples)
        @test get(cd_, "dynamic_update_slice", 0) == 0
        @test get(cd_, "gather", 0) == 0
    end

    @testset "live forcing buffers are program INPUTS, refreshed in place" begin
        # The gap that made every ReSEACT-class model refuse. `wind` is bound by
        # reference; under direct emission it must arrive through the ARGUMENT
        # list, so an in-place refresh is seen by the already-compiled program.
        N = 8
        wind = fill(1.0, N)
        pa = Dict("wind" => wind)
        fi!, _, p, _, _ = build_evaluator(_de_forced(N); param_arrays = pa)
        fo, _, _, _, _ = build_evaluator(_de_forced(N); form = :oop, param_arrays = pa)
        host = ESM_DE.forcing_buffers(fo)
        @test keys(host) == (:wind,)
        @test host.wind === wind                      # aliased, not copied
        dev = map(RX_DE.ConcreteRArray, host)

        u = _de_seed(N)
        samples = [(u, 0.0), (u .* 2.0 .+ 0.3, 1.5)]
        d, cd_ = _de_compare("forcing_buffers", fo, fi!, p, samples; buffers = dev)
        @test get(d.stats, :forcing_input, 0) >= 1    # read as an input, not baked

        # THE POINT: a host refresh mirrored into the SAME device arrays is seen
        # by the compiled program, with no recompile.
        db = EXT_DE.direct_rhs_with_buffers(fo)
        pr = _de_dev(p)
        ur = RX_DE.ConcreteRArray(copy(u)); tr = RX_DE.ConcreteRNumber(0.0)
        xla = RX_DE.@compile sync = true db(ur, pr, tr, dev)
        before = _de_ip(fi!, u, p, 0.0)
        @test isapprox(Array(xla(ur, pr, tr, dev)), before; rtol = 1e-12)
        wind .= 100.0                                  # the in-place host refresh
        ESM_DE.sync_forcing!(dev, host)                # the post_refresh hook
        fresh = _de_ip(fi!, u, p, 0.0)
        @test maximum(abs, fresh .- before) ≈ 99.0 rtol = 1e-12   # it really changed
        @test isapprox(Array(xla(ur, pr, tr, dev)), fresh; rtol = 1e-12)

        # And the THREE-argument form refuses this model by name, rather than
        # baking the host buffer in as a constant.
        d3 = EXT_DE.direct_rhs(fo)
        err = nothing
        try
            RX_DE.@compile sync = true d3(ur, pr, tr)
        catch e
            err = e
        end
        de = _de_unwrap(err)
        @test de isa ESM_DE.DirectEmitError
        @test de.code == ESM_DE.E_DIRECT_EMIT_UNSUPPORTED
        @test occursin("wind", de.detail)
        @test occursin("direct_rhs_with_buffers", de.detail)
    end

    @testset "template sub-kernels (`_NK_SUBCALL`)" begin
        fix = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench",
                       "transport_3axis_7cubed_fullrank.esm")
        @test isfile(fix)
        flat = ESM_DE.flatten(ESM_DE.load_path(fix))
        fo, u0, p, _, _ = build_evaluator(flat; form = :oop)
        fi!, _, _, _, _ = build_evaluator(flat)
        # The plan really does carry sub-kernels — otherwise this fixture would
        # be testing the ordinary kernel path under a different name.
        plans = getfield(fo.rhs, :acc_plans)
        @test any(pl -> !isempty(pl.subs), plans)
        n = length(u0)
        u1 = Float64[sin(0.1 * i) + 1.5 for i in 1:n]
        u2 = Float64[0.5 + 0.01 * i + cos(0.3 * i)^2 for i in 1:n]
        d, _ = _de_compare("template_subkernels", fo, fi!, p,
                              [(u1, 0.0), (u2, 0.75)]; census = false)
        @test get(d.stats, :subcall, 0) >= 1
    end

    @testset "the read cost model: slices per run, or one cross-producer gather" begin
        # The DECISION is pure arithmetic and needs no MLIR context.
        # `runs` is the negative control: the pre-2026-09-15 shape, never gathers.
        withenv("ESM_DIRECT_EMIT_READ" => "runs") do
            @test !EXT_DE._de_gather_is_cheaper(400, 1104)
            @test !EXT_DE._de_gather_is_cheaper(600, 1000)
        end
        # The DEFAULT is the cost model, with nothing set.
        withenv("ESM_DIRECT_EMIT_READ" => nothing) do
            @test EXT_DE._de_gather_is_cheaper(400, 1104)
            @test !EXT_DE._de_gather_is_cheaper(6, 216)
        end
        withenv("ESM_DIRECT_EMIT_READ" => "gather") do
            # 400 runs over 1,104 positions: average run 2.8, shorter than the
            # break-even 4, so one gather is the cheaper program. The rule this
            # replaced asked `400 > 1104 ÷ 2` and said no.
            @test EXT_DE._de_gather_is_cheaper(400, 1104)
            @test EXT_DE._de_gather_is_cheaper(8, 24)
            # Long affine runs stay on slices, which is what the slice path is for.
            @test !EXT_DE._de_gather_is_cheaper(6, 216)      # avg 36
            @test !EXT_DE._de_gather_is_cheaper(7, 20)       # below the piece floor
        end
        # `always` is the measurement lever: gather anything with more than one
        # run, and no budget on the base.
        withenv("ESM_DIRECT_EMIT_READ" => "always") do
            @test EXT_DE._de_gather_is_cheaper(2, 10_000)
            @test !EXT_DE._de_gather_is_cheaper(1, 216)
            @test EXT_DE._de_gather_base_fits(4, false, 10_000_000)
        end

        # THE BASE BUDGET, the other half of the decision and the one that
        # decided ReSEACT's transport half. Wanting the gather is not enough:
        # a cross-producer gather also needs the producers concatenated, and
        # that concatenate is what the budget bounds.
        withenv("ESM_DIRECT_EMIT_READ" => nothing,
                "ESM_DIRECT_GATHER_BASE_MAX" => nothing) do
            # One producer, no structural zero: `_de_concat` of a single piece
            # IS that piece, so there is no copy to charge and no size at which
            # to decline.
            @test EXT_DE._de_gather_base_fits(1, false, 476_928)
            # The shape that matters: ReSEACT's stencil reads 432 positions out
            # of the 3744-slot extended state beside a 2304-slot buffer. The
            # per-read rule this replaced compared 6048 against `max(8*432,
            # 4096)` and declined; the copy is 6048 elements, paid once for all
            # 240 reads that share the producer set.
            @test EXT_DE._de_gather_base_fits(2, false, 3744 + 2304)
            # A base whose copy is larger than the budget still declines.
            @test !EXT_DE._de_gather_base_fits(2, false, (1 << 16) + 1)
            @test EXT_DE._de_gather_base_fits(2, false, 1 << 16)
            # And a structural zero makes even a single producer a concatenate.
            @test !EXT_DE._de_gather_base_fits(1, true, 476_928)
        end
        # The override reproduces the per-read rule's effect on this model, and
        # is how the negative control in reseact.esm's COMPILE_COST.md was run.
        withenv("ESM_DIRECT_GATHER_BASE_MAX" => "4096") do
            @test !EXT_DE._de_gather_base_fits(2, false, 3744 + 2304)
            @test EXT_DE._de_gather_base_fits(1, false, 476_928)
        end

        # And the two read forms are the SAME PROGRAM numerically. A 3-axis
        # stencil over 343 cells is the shape that shatters: its reads span two
        # producers and run two to four positions at a time.
        fix = joinpath(TESTUTILS_REPO_ROOT, "tests", "bench",
                       "transport_3axis_7cubed_fullrank.esm")
        @test isfile(fix)
        flat = ESM_DE.flatten(ESM_DE.load_path(fix))
        fo, u0, p, _, _ = build_evaluator(flat; form = :oop)
        fi!, _, _, _, _ = build_evaluator(flat)
        n = length(u0)
        u1 = Float64[sin(0.1 * i) + 1.5 for i in 1:n]
        ref = _de_ip(fi!, u1, p, 0.4)
        pr = _de_dev(p)
        ur = RX_DE.ConcreteRArray(copy(u1)); tr = RX_DE.ConcreteRNumber(0.4)
        tallies = Dict{String,Dict{Symbol,Int}}()
        for mode in ("runs", "gather", "always")
            withenv("ESM_DIRECT_EMIT_READ" => mode) do
                d = EXT_DE.direct_rhs(fo)
                xla = RX_DE.@compile sync = true d(ur, pr, tr)
                @test isapprox(Array(xla(ur, pr, tr)), ref; rtol = 1e-12, atol = 0.0)
                tallies[mode] = copy(d.stats)
            end
        end
        # And the budget is a SHAPE decision, not a numerical one: the same
        # model emitted with the per-read budget the default replaces has to
        # agree to the last bit.
        withenv("ESM_DIRECT_GATHER_BASE_MAX" => "64") do
            d = EXT_DE.direct_rhs(fo)
            xla = RX_DE.@compile sync = true d(ur, pr, tr)
            @test isapprox(Array(xla(ur, pr, tr)), ref; rtol = 1e-12, atol = 0.0)
            tallies["base64"] = copy(d.stats)
        end
        for (k, v) in sort!(collect(tallies); by = first)
            println("  read-form tally ", rpad(k, 7), " ", v)
        end
        # The point of the mode: fewer slices, and the gathers that replace them.
        @test get(tallies["gather"], :slice, 0) < get(tallies["runs"], :slice, 0)
        @test get(tallies["gather"], :gather, 0) > get(tallies["runs"], :gather, 0)
        # THE BUDGET, ON THIS FIXTURE, IS THE OUTPUT ASSEMBLY'S. None of the
        # fixture's DESCRIPTOR reads can exercise it — every one of them lies in
        # ONE producer (a single-tracer model with no second buffer), and a
        # one-producer base is not a concatenate at all, so there is no copy to
        # charge. The ASSEMBLY of `du` is the cross-producer read in this
        # program: it reads every kernel result value at once, so its base IS a
        # concatenate and a 64-element budget declines it. That is the whole
        # visible difference — the assembly falls back to slices per run, the
        # descriptor reads are emitted identically, and the numbers agree to the
        # last bit either way (the `isapprox` above).
        for k in (:kernels, :subcall, :arith, :broadcast_in_dim,
                  Symbol("sliceN@kernel.runs"), Symbol("gather@kernel.x"),
                  Symbol("concat@kernel.x"))
            @test get(tallies["base64"], k, 0) == get(tallies["gather"], k, 0)
        end
        @test get(tallies["gather"], Symbol("gather@assemble.x"), 0) == 1
        @test get(tallies["base64"], Symbol("gather@assemble.x"), 0) == 0
        @test get(tallies["base64"], Symbol("slice1@assemble.runs"), 0) > 0
        # `always` gathers everything with more than one run, so it is the floor
        # on slices and the ceiling on gathers.
        @test get(tallies["always"], :slice, 0) <= get(tallies["gather"], :slice, 0)
        @test get(tallies["always"], :gather, 0) >= get(tallies["gather"], :gather, 0)
    end

    @testset "the lane-batched scalar surface: one whole-lane read per group" begin
        doc, ics, NI, NJ, M = _de_halo()
        fo, u0, p, _, vmap = _de_halo_build(doc, ics)
        fi!, u0i, _, _, _ = _de_halo_build(doc, ics; form = :inplace)
        @test u0 == u0i

        # WITNESS, on the BUILD: the surface really is one group of NI*NJ
        # congruent lanes with nothing left on the per-entry path. A silent
        # decline back to singles would make every assertion below vacuous.
        rhsf = getfield(fo, :rhs)
        rb = getfield(rhsf, :rhs_batches)
        @test length(rb.groups) == 1
        @test rb.n_batched == NI * NJ
        @test isempty(rb.rest)

        n = length(u0)
        samples = [(copy(u0), 0.0),
                   (Float64[u0[k] + 0.25sin(0.3k) for k in 1:n], 1.0),
                   (Float64[u0[k] * (1 + 0.1cos(0.7k)) for k in 1:n], -2.0)]
        d, _ = _de_compare("halo (lane-batched)", fo, fi!, p, samples)

        # The GROUP was emitted as a group, once.
        @test get(d.stats, :scalar_batch, 0) == 1

        # And against the SAME build with the grouping disabled — the pre-batch
        # emitter, entry by entry — which is the only comparison that says what
        # the batched surface changed. Same numbers, and a program whose size
        # no longer follows the cell count.
        fn, u0n, pn, _, _ = _de_halo_build(doc, ics; batch = false)
        @test isempty(getfield(getfield(fn, :rhs), :rhs_batches).groups)
        dn, _ = _de_compare("halo (per-entry, ESS_OOP_BATCH=0)", fn, fi!, pn,
                               samples; census = false)
        println("  batched tally:   ", d.stats)
        println("  per-entry tally: ", dn.stats)
        @test get(dn.stats, :scalar_batch, 0) == 0

        # ONE WHOLE-LANE READ PER TENT POSITION, and not one per cell. The
        # per-entry walk reads the state one element at a time
        # (`slice1@rhs_scalar.stategather`); the batched surface reads all
        # `NI*NJ` lanes at once, so the site tally carries NO single-position
        # read at all and exactly `M*M` whole-lane reads — one per position of
        # the tent, whatever form the cost model gives each one.
        rd1 = Symbol("slice1@rhs_scalar.stategather")
        @test get(dn.stats, rd1, 0) > 0
        @test get(d.stats, rd1, 0) == 0
        @test get(d.stats, Symbol("concat@rhs_scalar.x"), 0) +
              get(d.stats, Symbol("gather@rhs_scalar.x"), 0) == M * M

        # WHY THAT IS NOT SPELLED "one gather". This fixture's whole-lane read
        # is AFFINE — lane `(i,j)` reads donor slot `(i+k-1, j+l-1)`, so the
        # lanes land on the state in arithmetic order and the read decomposes
        # into a handful of long runs. The cost model then correctly prefers
        # strided slices to a gather with its O(L) index constant, which is the
        # decision `_de_gather_is_cheaper` exists to make. Force the other side
        # of it and the whole-lane read IS one gather per tent position, with
        # the same numbers.
        withenv("ESM_DIRECT_EMIT_READ" => "always") do
            da, _ = _de_compare("halo (lane-batched, gather)", fo, fi!, p,
                                   samples; census = false)
            println("  batched tally (always): ", da.stats)
            @test get(da.stats, Symbol("gather@rhs_scalar.x"), 0) == M * M
            @test get(da.stats, rd1, 0) == 0
        end

        # And the emitted program stops following the cell count: the group's
        # arithmetic is emitted ONCE over the lane axis rather than once per
        # cell.
        @test get(d.stats, :arith, 0) * 4 < get(dn.stats, :arith, 0)
        @test get(d.stats, :slice, 0) < get(dn.stats, :slice, 0)
    end

    @testset "a closed `interp.linear` function" begin
        fo, u0, p, _, _ = build_evaluator(_de_interpdoc(); form = :oop)
        fi!, _, _, _, _ = build_evaluator(_de_interpdoc())
        # In range, on a knot, and both clamps.
        samples = [([1.5], 0.0), ([2.0], 0.0), ([-1.0], 0.0), ([9.0], 0.0),
                   ([3.25], 1.0)]
        # `_de_fn` routes a scalar-spine `interp.*` through the BRANCH-FREE lane
        # evaluators, so every query position the scalar `_interp_linear_core`
        # would branch on — in range, on a knot, and both clamps — lowers as the
        # same straight-line program.
        d, cd_ = _de_compare("interp_linear", fo, fi!, p, samples)
        @test get(d.stats, :interp_linear, 0) == 1
        @test get(cd_, "gather", 0) >= 1     # knot addressing, not a select ladder
    end

    @testset "the `datetime.*` calendar and `log10`" begin
        fo, u0, p, _, vmap = build_evaluator(_de_dtdoc(); form = :oop)
        fi!, _, _, _, _ = build_evaluator(_de_dtdoc())
        samples = [(copy(u0), t) for t in _DE_DT_TIMES]
        d, cd_ = _de_compare("datetime_log10", fo, fi!, p, samples)
        # Ten `:fn` calls lowered — the nine fields plus the offset `hour`.
        @test get(d.stats, :closed_scalar, 0) >= 10
        # `log10` is a `log` and a `divide`, never a `log10` op (there is none).
        @test get(cd_, "log", 0) >= 1

        # THE EXACTNESS CLAIM, which `_de_compare`'s rtol cannot make: eight of
        # the nine fields are integers and must come back BIT-IDENTICAL to the
        # interpreter's at every one of the eight times. An hour that is one out
        # is a difference of 1.0, so rtol would catch that too — what the `===`
        # adds is that nothing in the decomposition is allowed to be
        # approximately right.
        #
        # THE THREE THAT MAY MOVE, and exactly why each does:
        #   * `julian_day`   — one rounded divide onto a ~2.4e6 day number; ≤ 1 ulp.
        #   * `lg`           — `log10` synthesized as `log(x)/ln(10)`.
        #   * `local_hour`   — an exact integer hour PLUS `lon/15`, and a divide
        #     by a constant is not a divide by the time XLA is done with it (it
        #     rewrites `x/c` to `x * fl(1/c)`; see `_cdiv`'s note in
        #     src/registered_functions.jl, which is the same rewrite biting the
        #     calendar itself). The two agree bit-for-bit at THIS `lon`, but
        #     pinning that would pin an accident of one constant rather than
        #     anything about the calendar, so the hour's correctness is pinned by
        #     `c_hour` above — same times, same kernel — and this one carries the
        #     tolerance.
        dd = EXT_DE.direct_rhs(fo; var_map = vmap)
        pr = _de_dev(p)
        ur = RX_DE.ConcreteRArray(copy(u0))
        xla = RX_DE.@compile sync = true dd(ur, pr, RX_DE.ConcreteRNumber(0.0))
        exact = String["c_$f" for f in _DE_DT_FNS if f != "julian_day"]
        for t in _DE_DT_TIMES
            du_i = _de_ip(fi!, u0, p, t)
            du_d = Array(xla(RX_DE.ConcreteRArray(copy(u0)), pr,
                             RX_DE.ConcreteRNumber(t)))
            for nm in exact
                sl = _de_slot(vmap, nm)
                @test du_d[sl] === du_i[sl]
            end
            sj = _de_slot(vmap, "c_julian_day")
            @test abs(du_d[sj] - du_i[sj]) <= eps(du_i[sj])
            for nm in ("lg", "local_hour")
                sl = _de_slot(vmap, nm)
                @test isapprox(du_d[sl], du_i[sl]; rtol = 1e-12, atol = 0.0)
            end
        end

        # And the decomposition really did run: the eight times are not all the
        # same date, so a program that ignored `t` would pass everything above.
        yrs = Float64[]
        for t in _DE_DT_TIMES
            du_d = Array(xla(RX_DE.ConcreteRArray(copy(u0)), pr,
                             RX_DE.ConcreteRNumber(t)))
            push!(yrs, du_d[_de_slot(vmap, "c_year")])
        end
        @test sort!(unique(yrs)) == [1968.0, 1969.0, 1970.0, 2020.0, 2023.0]
    end

    # ---- prefix scans over slots the term build does not cover ---------------
    #
    # A STAGGERED strict prefix reduction — `c[i] = ⊕_{j < i} u[j]` with `i` over
    # the n+1 NODES of an axis and `j` over its n CENTRES — is how a cumulative
    # flux is spelled on a staggered grid (ReSEACT's diagnosed vertical air-mass
    # flux). `_scan_term_iters` (build.jl) admits it and, by design, leaves the
    # LAST node uncovered by the term build: the fold writes every node but only
    # ever reads a slot into an accumulator it then discards, so nothing the
    # uncovered slot holds can reach an output.
    #
    # The emitter keeps a slot MAP, not a zeroed buffer, so that read arrives as
    # "nothing has written this slot". It used to be an unconditional refusal.
    # It is not a refusal: the interpreter reads the zero its freshly allocated
    # vector supplies, and the emitter must supply the same zero. What IS still
    # a refusal is a slot a LATER section writes, which is a mis-ordered level
    # plan — pinned below on the write plan itself.

    @testset "a staggered prefix scan over `du`'s uncovered last node" begin
        n = 12
        m = _de_scan_stag(n)
        foS, u0S, pS, _, vmS, dgS = ESM_DE._build_evaluator_impl(m; form = :oop)
        fiS!, _, _, _, _, _ = ESM_DE._build_evaluator_impl(m; form = :inplace)
        # The rewrite fired, and the fold is over the STATE equations (`du`).
        @test dgS.n_scan_folds == 1
        @test length(getfield(getfield(foS, :rhs), :scan_folds)) == 1
        @test getfield(getfield(foS, :rhs), :n_total) ==
              getfield(getfield(foS, :rhs), :n_states)   # nothing materialized
        u = _de_seed(length(u0S))
        samples = [(copy(u), 0.0), (u .* 1.5 .- 0.05, 3.25)]
        _de_compare("scan_staggered_du", foS, fiS!, pS, samples; census = false)
        # The last node really is the running total of every centre — a program
        # that stopped one step short, or that refused, would not get here.
        d = EXT_DE.direct_rhs(foS; var_map = vmS)
        xla = RX_DE.@compile sync = true d(RX_DE.ConcreteRArray(copy(u)),
                                           _de_dev(pS), RX_DE.ConcreteRNumber(0.0))
        du = Array(xla(RX_DE.ConcreteRArray(copy(u)), _de_dev(pS),
                       RX_DE.ConcreteRNumber(0.0)))
        terms = Float64[u[vmS["u[$j]"]] for j in 1:n]
        @test du[vmS["c[1]"]] == 0.0
        @test du[vmS["c[$(n + 1)]"]] ≈ sum(terms) rtol = 1e-13
    end

    @testset "a staggered prefix scan over a materialized observed's buffer" begin
        n = 9
        m, isets = _de_scan_stag_obs(n)
        ics = Dict("u[$j]" => 0.4 * j - 1.3 for j in 1:n)
        foO, u0O, pO, _, vmO, dgO = ESM_DE._build_evaluator_impl(m;
            index_sets = isets, initial_conditions = ics, form = :oop)
        fiO!, _, _, _, _, _ = ESM_DE._build_evaluator_impl(m;
            index_sets = isets, initial_conditions = ics, form = :inplace)
        rO = getfield(foO, :rhs)
        # `Mz` is materialized, its fill carries the fold, and the fold's slots
        # are in the EXTENDED map — the ReSEACT shape, not the `du` one.
        @test dgO.n_mat_array_obs == 1
        @test dgO.n_mat_array_cells == n + 1
        @test dgO.n_scan_folds == 1
        @test isempty(getfield(rO, :scan_folds))
        matO = getfield(rO, :mat_levels)
        @test sum(length(lvl[4]) for lvl in matO) == 1
        # The uncovered slot: the fold's last position in its (single) lane, and
        # no fill kernel of the level lists it as an output.
        SO = first(lvl for lvl in matO if !isempty(lvl[4]))[4][1]
        @test SO.len == n + 1 && length(SO.slots) == n + 1 && !SO.inclusive
        lastslot = SO.slots[end]
        @test lastslot > getfield(rO, :n_states)
        @test !any(lastslot in pl.out_slots for lvl in matO for pl in lvl[3])
        samples = [(copy(u0O), 0.0), (u0O .* 0.7 .+ 0.11, 9.5)]
        _de_compare("scan_staggered_obs", foO, fiO!, pO, samples; census = false)
    end

    @testset "the write plan: a zero this section may take, a later level refused" begin
        # `_de_unwritten` is the whole decision, and it needs no MLIR context.
        M = EXT_DE._DEMap(6)
        EXT_DE._de_mark!(M, (2, 3), Int32(2))      # written at level 2
        EXT_DE._de_mark!(M, (5,), Int32(7))        # written at level 7
        EXT_DE._DE_SECTIONS[] = ["materialization level $k" for k in 1:8]
        # Nothing writes slot 1: a zero, whatever section is reading.
        @test EXT_DE._de_unwritten(M, 1, Int32(1), "x") === nothing
        @test EXT_DE._de_unwritten(M, 1, Int32(8), "x") === nothing
        # Slot 2's writer is THIS section, still running (the in-place scan).
        @test EXT_DE._de_unwritten(M, 2, Int32(2), "x") === nothing
        # Slot 5 is written at level 7: from level 2 that is a later section.
        err = nothing
        try
            EXT_DE._de_unwritten(M, 5, Int32(2), "Mz[10]")
        catch e
            err = e
        end
        @test err isa ESM_DE.DirectEmitError
        @test occursin("read-before-write", err.construct)
        @test occursin("Mz[10]", err.detail)
        @test occursin("materialization level 7", err.detail)   # names the writer
        @test occursin("materialization level 2", err.detail)   # and the reader
        # From level 7 itself, and from anything after it, the same slot is a zero.
        @test EXT_DE._de_unwritten(M, 5, Int32(7), "Mz[10]") === nothing
        @test EXT_DE._de_unwritten(M, 5, Int32(8), "Mz[10]") === nothing
    end

    @testset "the hard-error path names the construct and the rule" begin
        fo, u0, p, _, vmap = build_evaluator(_de_unsupported_op(); form = :oop)
        d = EXT_DE.direct_rhs(fo; var_map = vmap)
        ur = RX_DE.ConcreteRArray(copy(u0))
        tr = RX_DE.ConcreteRNumber(0.0)
        pr = _de_dev(p)
        err = nothing
        try
            RX_DE.@compile sync = true d(ur, pr, tr)
        catch e
            err = e
        end
        de = _de_unwrap(err)
        @test de isa ESM_DE.DirectEmitError
        @test de.code == ESM_DE.E_DIRECT_EMIT_UNSUPPORTED
        # the construct: the operator and its arity, in the IR's own vocabulary
        @test occursin("`/`", de.construct)
        @test occursin("3 arguments", de.construct)
        # the rule: the state equation it came from, named by the var_map
        @test occursin("state equation", de.rule)
        @test occursin("y", de.rule)
        msg = sprint(showerror, de)
        @test occursin("E_DIRECT_EMIT_UNSUPPORTED", msg)
        @test occursin("`/`", msg)
        @test occursin("y", msg)
        println("  refusal message: ", msg)

        # WITHOUT a var_map the rule still names the slot, so the refusal is
        # never anonymous.
        d2 = EXT_DE.direct_rhs(fo)
        err2 = nothing
        try
            RX_DE.@compile sync = true d2(ur, pr, tr)
        catch e
            err2 = e
        end
        de2 = _de_unwrap(err2)
        @test de2 isa ESM_DE.DirectEmitError
        @test occursin("flat slot", de2.rule)

        # And a HOST call says so rather than failing somewhere in MLIR.
        @test_throws ESM_DE.DirectEmitError d(copy(u0), p, 0.0)
    end

    # ---- reverse-mode autodiff, and `p` as a real program input -------------
    #
    # An adjoint step needs BOTH vector-Jacobian products of the right-hand side:
    # ∂/∂u (the state VJP) and ∂/∂p (the parameter one). Both are asserted here
    # against CENTRAL DIFFERENCES on `f!`, the evaluator, at the same point.
    #
    # Finite differences rather than host ForwardDiff for two reasons: this file
    # runs standalone from the adapter's Reactant environment, which carries no
    # AD package (see CONTRIBUTING.md); and a reference computed by a DIFFERENT
    # method than the thing under test is the stronger check. The ForwardDiff
    # half of the chain is pinned host-side in test/parameter_gradient_test.jl,
    # against these same central differences.
    #
    # THE TOLERANCE IS 1e-6, which is what central differences at
    # h = 1e-6·max(|θ|,1) are worth on this model (~1e-9 truncation), and is a
    # real assertion about the VALUE rather than a rounding allowance. XLA also
    # reassociates sums and contracts multiply-adds into FMAs — both
    # value-changing, both the point of compiling — and differentiating amplifies
    # that, so equality would be asserting that XLA did not optimize.
    #
    # Enzyme is a dependency OF Reactant, not of this environment, so it is
    # reached through `Reactant.Enzyme`.
    @testset "reverse-mode ∂/∂p and ∂/∂u agree with the host" begin
        EZ = RX_DE.Enzyme
        N = 12
        fo, u0, p, _, _ = build_evaluator(_de_rd(N); form = :oop)
        fi!, _, _, _, _ = build_evaluator(_de_rd(N))
        syms = keys(p)
        pv0 = collect(Float64, values(p))
        u = Float64[0.6sin(0.7k) + 1.2 for k in 1:N]
        t = 0.37
        # A non-uniform weight, so the functional is not `sum`: a plain sum can
        # hide a per-cell sign or ordering error by cancellation.
        w = Float64[1.0 + 0.05k for k in 1:N]

        # The host answers, by central differences on `f!`.
        hobj(uu, q) = sum(w .* _de_ip(fi!, uu, q, t))
        function _cdiff(f, x0)
            g = similar(x0)
            for k in eachindex(x0)
                h = 1e-6 * max(abs(x0[k]), 1.0)
                hi = copy(x0); hi[k] += h
                lo = copy(x0); lo[k] -= h
                g[k] = (f(hi) - f(lo)) / (2h)
            end
            g
        end
        g_p = _cdiff(θ -> hobj(u, NamedTuple{syms}(Tuple(θ))), pv0)
        g_u = _cdiff(uu -> hobj(uu, p), u)
        # Teeth: a build that froze the parameters would return zeros here and
        # still satisfy every agreement test below.
        @test all(isfinite, g_p) && all(!iszero, g_p)
        @test all(isfinite, g_u) && all(!iszero, g_u)

        d = EXT_DE.direct_rhs(fo)
        obj(uu, q, tt) = sum(w .* d(uu, q, tt))
        ur = RX_DE.ConcreteRArray(copy(u))
        pr = _de_dev(p)
        tr = RX_DE.ConcreteRNumber(t)

        gp = (uu, q, tt) -> EZ.gradient(EZ.Reverse, obj, EZ.Const(uu), q,
                                        EZ.Const(tt))[2]
        xp = RX_DE.@compile sync = true gp(ur, pr, tr)
        got_p = [Float64(getfield(xp(ur, pr, tr), sym)) for sym in syms]
        @test isapprox(got_p, g_p; rtol = 1e-6)

        gu = (uu, q, tt) -> EZ.gradient(EZ.Reverse, obj, uu, EZ.Const(q),
                                        EZ.Const(tt))[1]
        xu = RX_DE.@compile sync = true gu(ur, pr, tr)
        @test isapprox(Array(xu(ur, pr, tr)), g_u; rtol = 1e-6)
    end

    @testset "`p` is a REAL program input, not a baked-in constant" begin
        # The silent-staleness trap for parameters, and the reason a sweep costs
        # ONE compile: `_de_param` folds a host `Real` but keeps a
        # `ConcreteRNumber` as an input (emit.jl). Compile once, then hand the
        # SAME program different values and check the answer follows — pinned in
        # BOTH directions, the way `t` is, since a baked-in `p` returns the same
        # plausible numbers for ever with no error.
        N = 12
        fo, u0, p, _, _ = build_evaluator(_de_rd(N); form = :oop)
        fi!, _, _, _, _ = build_evaluator(_de_rd(N))
        syms = keys(p)
        pv0 = collect(Float64, values(p))
        nt(pv) = NamedTuple{syms}(Tuple(pv))
        u = Float64[0.6sin(0.7k) + 1.2 for k in 1:N]
        ur = RX_DE.ConcreteRArray(copy(u))
        tr = RX_DE.ConcreteRNumber(0.25)

        d = EXT_DE.direct_rhs(fo)
        xla = RX_DE.@compile sync = true d(ur, _de_dev(p), tr)
        a = Array(xla(ur, _de_dev(p), tr))
        @test isapprox(a, _de_ip(fi!, u, p, 0.25); rtol = 1e-12, atol = 0.0)

        pv2 = copy(pv0)
        pv2[findfirst(==(:k_diff), collect(syms))] *= 2.0
        b = Array(xla(ur, _de_dev(nt(pv2)), tr))           # no recompile
        # It MOVED (so it was not frozen) …
        @test !isapprox(a, b; rtol = 1e-12)
        @test maximum(abs, b .- a) > 1e-6
        # … to the right place …
        @test isapprox(b, _de_ip(fi!, u, nt(pv2), 0.25); rtol = 1e-12, atol = 0.0)
        # … and back again: no hysteresis in the compiled program.
        @test Array(xla(ur, _de_dev(p), tr)) == a
    end

    @testset "reverse mode through a `@trace while` region (BROKEN upstream)" begin
        # An upstream tripwire, kept from the retired traced-emitter suite
        # (Reactant.jl #3218 / Enzyme-JAX #2939's neighbourhood; see
        # UPSTREAM_ISSUES.md). NOT an EarthSciAST loop — the smallest possible
        # `Reactant.@trace while`, a FIXED trip count, no adaptivity, no model.
        # It is reduced this far precisely so that when it flips green there is
        # no doubt what got fixed.
        EZ = RX_DE.Enzyme
        H, NSTEP, k0 = 0.01, 20, 0.7
        u = Float64[0.6sin(0.7k) + 1.2 for k in 1:12]
        # `u ← u(1 + kH)` NSTEP times, so the loop computes
        # `Σu·(1+kH)^NSTEP` and its k-derivative is closed form — no AD package
        # needed for the reference, and no truncation error in it either.
        gref = sum(u) * NSTEP * H * (1 + k0 * H)^(NSTEP - 1)

        function traced(uu, k, nlim)
            i = zero(k)
            RX_DE.@trace while i < nlim
                uu = uu .+ k .* uu .* H
                i = i + one(k)
            end
            return sum(uu)
        end

        ur = RX_DE.ConcreteRArray(copy(u))
        kr = RX_DE.ConcreteRNumber(k0)
        nr = RX_DE.ConcreteRNumber(Float64(NSTEP))

        # FORWARD mode crosses it exactly — a real, passing test, and the reason
        # the `@test_broken` below is about REVERSE mode rather than about
        # `@trace while` being untraceable.
        fwd = (uu, k, n) -> EZ.autodiff(EZ.Forward, traced, EZ.Const(uu),
                                        EZ.Duplicated(k, one(k)), EZ.Const(n))[1]
        xf = RX_DE.@compile sync = true fwd(ur, kr, nr)
        @test isapprox(Float64(xf(ur, kr, nr)), gref; rtol = 1e-8)

        # REVERSE mode does not.
        rev = (uu, k, n) -> EZ.gradient(EZ.Reverse, traced, EZ.Const(uu), k,
                                        EZ.Const(n))[2]
        @test_broken begin
            xg = RX_DE.@compile sync = true rev(ur, kr, nr)
            isapprox(Float64(xg(ur, kr, nr)), gref; rtol = 1e-8)
        end
    end
end
