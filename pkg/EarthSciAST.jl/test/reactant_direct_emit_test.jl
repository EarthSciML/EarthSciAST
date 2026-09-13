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
#   `^`. Five shapes are covered — the conformance fixture, a reaction–diffusion
#   model (state, parameters, literal-exponent `^`, ghost-boundary kernels), a
#   LIVE FORCING model through the buffers argument, a template SUB-KERNEL model,
#   and a closed `interp.linear` function.
#
#   THE HARD-ERROR PATH. A model the emitter cannot lower raises
#   `DirectEmitError`, and the message names the construct AND the rule it came
#   from. Three refusals are pinned: an operator with no StableHLO form, the
#   three-argument call on a live-forcing model, and a host (untraced) call.
#
#   THE OP CENSUS against the traced emitter is printed for the report and, for
#   the two structural fixtures, asserted where the assertion is about the IR
#   ("one constant per distinct literal", "no `dynamic_update_slice`") rather
#   than about XLA. It is never a gate on the traced backend's totals.

using Test
using EarthSciAST
using Reactant
using JSON3

include("testutils.jl")  # TESTUTILS_REPO_ROOT

const ESM_DE = EarthSciAST
const RX_DE = Reactant
const EXT_DE = Base.get_extension(EarthSciAST, :EarthSciASTReactantExt)
@assert EXT_DE !== nothing "the Reactant extension did not load"

# ---- document builders (the same shapes test/reactant_oop_test.jl uses) ------

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

# `log10` is in the operator registry and in the interpreter's ladder, and has no
# StableHLO or CHLO op — the emitter refuses it rather than substitute
# `log(x)/log(10)`, which is a different number in the last bits. That makes it
# the hard-error fixture: the refusal must name the operator AND the rule.
function _de_unsupported_op()
    _de_doc("U", Dict{String,Any}("y" => _de_state(default = 2.0)),
        Any[Dict{String,Any}("lhs" => _de_Dt("y"),
                             "rhs" => _de_o("neg", _de_o("log10", "y")))])
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
        du_o = fo(u, p, t)
        uu = RX_DE.ConcreteRArray(copy(u)); tt = RX_DE.ConcreteRNumber(t)
        du_d = Array(buffers === nothing ? compiled(uu, pr, tt) :
                                           compiled(uu, pr, tt, buffers))
        @test du_o == du_i             # the two interpreters are bit-identical
        aerr = maximum(abs.(du_d .- du_i))
        rerr = maximum(abs.(du_d .- du_i) ./ max.(abs.(du_i), 1e-300))
        push!(rows, (string("t=", t, " u=", repr(round.(u; sigdigits = 3))), aerr, rerr,
                     maximum(abs.(du_i))))
        @test isapprox(du_d, du_i; rtol = rtol, atol = 0.0)
    end
    println("  numerical comparison (", name, "):")
    println("    ", rpad("sample", 44), rpad("max |Δ|", 14), rpad("max rel", 14),
            "max |ref|")
    for (s, a, r, m) in rows
        println("    ", rpad(s, 44), rpad(string(a), 14), rpad(string(r), 14), m)
    end
    census || return (d, Dict{String,Int}(), Dict{String,Int}())
    # Raw module censuses for both backends. INFORMATIONAL — the traced emitter
    # is an oracle here, never a gate.
    mod_direct = buffers === nothing ?
        repr(RX_DE.@code_hlo optimize = false callee(ur, pr, tr)) :
        repr(RX_DE.@code_hlo optimize = false callee(ur, pr, tr, buffers))
    traced = buffers === nothing ? fo : ESM_DE.rhs_with_buffers(fo)
    mod_traced = buffers === nothing ?
        repr(RX_DE.@code_hlo optimize = false traced(ur, pr, tr)) :
        repr(RX_DE.@code_hlo optimize = false traced(ur, pr, tr, buffers))
    _de_dump(name, "direct", mod_direct)
    _de_dump(name, "traced", mod_traced)
    cd_ = _de_census(mod_direct)
    ct_ = _de_census(mod_traced)
    _de_print_census("direct (raw)", cd_)
    _de_print_census("traced (raw)", ct_)
    return (d, cd_, ct_)
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
        d, cd_, ct_ = _de_compare("elementwise_gather", fo, fi!, p, samples)

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
        d, cd_, ct_ = _de_compare("reaction_diffusion", fo, fi!, p, samples)
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
        d, cd_, ct_ = _de_compare("forcing_buffers", fo, fi!, p, samples; buffers = dev)
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
        d, _, _ = _de_compare("template_subkernels", fo, fi!, p,
                              [(u1, 0.0), (u2, 0.75)]; census = false)
        @test get(d.stats, :subcall, 0) >= 1
    end

    @testset "a closed `interp.linear` function" begin
        fo, u0, p, _, _ = build_evaluator(_de_interpdoc(); form = :oop)
        fi!, _, _, _, _ = build_evaluator(_de_interpdoc())
        # In range, on a knot, and both clamps.
        samples = [([1.5], 0.0), ([2.0], 0.0), ([-1.0], 0.0), ([9.0], 0.0),
                   ([3.25], 1.0)]
        d, cd_, ct_ = _de_compare("interp_linear", fo, fi!, p, samples)
        @test get(d.stats, :interp_linear, 0) == 1
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
        # the construct: the operator, in the IR's own vocabulary
        @test occursin("log10", de.construct)
        # the rule: the state equation it came from, named by the var_map
        @test occursin("state equation", de.rule)
        @test occursin("y", de.rule)
        msg = sprint(showerror, de)
        @test occursin("E_DIRECT_EMIT_UNSUPPORTED", msg)
        @test occursin("log10", msg)
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
end
