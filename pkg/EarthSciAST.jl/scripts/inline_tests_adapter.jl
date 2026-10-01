# Julia adapter for the INLINE-TEST conformance tiers (CONFORMANCE_SPEC.md §5.45).
#
# The REFERENCE binding. For every fixture in the manifest it runs the
# document's own esm-spec §6.6 `tests` blocks through `run_inline_tests` under
# the compiler named on the command line, and reports, per assertion, whether
# this binding's §6.6.3 predicate passed and what the ACTUAL reduction value
# was. The runner gates both: `passed` against the document's authored
# expectation, `actual` against the committed Julia-`interpreter` golden.
#
# The contract (manifest schema, CLI, output JSON, the outcomes, the golden
# format) is each tier's README.md; the normative text is CONFORMANCE_SPEC.md
# §5.45.
#
#   julia pkg/EarthSciAST.jl/scripts/inline_tests_adapter.jl \
#         --manifest <manifest.json> --output <out.json> --compiler <value>
#
# ONE ADAPTER, EVERY COMPILER. `--compiler` is required and takes one member of
# API_SPEC §5.8's closed vocabulary. Its value is passed STRAIGHT to
# `run_inline_tests`, which hands it to `esm_problem`, and is never interpreted
# here: an adapter that read the value and chose a build itself would be
# reimplementing the thing under test.
#
# THE THREE OUTCOMES THIS ADAPTER DECIDES:
#
#   refused      this compiler cannot evaluate this document, and says which
#                coded diagnostic it refused with. Two shapes reach it — a
#                `compiler_refused_rule` thrown out of the build, and a run in
#                which EVERY assertion failed carrying ONE coded diagnostic (an
#                operator with no evaluation rule refuses at evaluation rather
#                than at build, and answering "every assertion failed" for it
#                would report a wrong ANSWER where the binding actually declined
#                to answer at all). Per fixture; the run continues.
#   unavailable  a `compiler_unavailable`: this compiler does not exist in this
#                binding, or its runtime is not configured here. A fact about
#                the BINDING, so it is the whole output and no fixture is
#                reported. `run_inline_tests` catches a build failure per
#                assertion, so the answer never arrives as an exception here:
#                it is asked for UP FRONT (`compiler_unavailable_reason`), and a
#                fixture whose every assertion failed on `compiler_unavailable`
#                alone reaches the same whole-output answer — the rule the Rust
#                adapter applies.
#   error        anything else the load, the build or the run threw. Per
#                fixture, and RED whatever the fixture's `required` map says.
#
# A refusal is never a fallback: nothing here retries a refused fixture under
# another compiler, and nothing here weakens an assertion to make one pass.

# Self-contained environment bootstrap, the shape compiler_agreement_adapter.jl
# uses. This adapter reuses THAT tier's project rather than adding a third:
# it needs exactly the same four packages (EarthSciAST, JSON3, Tsit5 for the
# ordinary arm and Rosenbrock for a document whose §2.2 `solver` block declares
# `stiffness: "high"`), and a second env carrying the same list would be one
# more Manifest to keep alive for no coverage.
import Pkg
let env = normpath(joinpath(@__DIR__, "compiler_agreement_env")),
    manifest = joinpath(env, "Manifest.toml")
    bootstrap() = begin
        Pkg.activate(env; io=devnull)
        isfile(manifest) ||
            Pkg.develop(path=normpath(joinpath(@__DIR__, "..")); io=devnull)
        Pkg.instantiate(; io=devnull)
    end
    try
        bootstrap()
    catch err
        # A Manifest.toml is a machine-local CACHE that can lag a Project.toml
        # that has moved on and then contradict it; one that cannot instantiate
        # has no value, so rebuild rather than fail the gate.
        @warn "compiler_agreement_env did not instantiate; rebuilding Manifest.toml" exception = (err, catch_backtrace())
        rm(manifest; force=true)
        bootstrap()
    end
end

using EarthSciAST
using JSON3
import OrdinaryDiffEqTsit5
import OrdinaryDiffEqRosenbrock

const BINDING = "julia"

# API_SPEC §5.8's closed vocabulary, checked here as well as in the runner. A
# value outside it is a broken invocation rather than a compiler this binding
# happens not to have, and the two must not arrive at the same answer.
const COMPILER_VOCABULARY = ("interpreter", "native", "xla", "mtk", "sympy")

# The coded diagnostics a refusal can carry. A message naming one of these is
# this binding declining to evaluate the document, which the tier records as a
# NAMED EXCLUSION under the fixture's ledger — never as a wrong answer, and
# never as a silent skip. Anything else is an ordinary assertion failure.
const REFUSAL_CODES = ("compiler_refused_rule", "compiler_unavailable",
                       "unevaluable_operator", "unlowered_operator",
                       "unsupported_construct")

function parse_args(args)
    manifest = nothing
    output = nothing
    compiler = nothing
    i = 1
    while i <= length(args)
        if args[i] == "--manifest"
            manifest = args[i + 1]; i += 2
        elseif args[i] == "--output"
            output = args[i + 1]; i += 2
        elseif args[i] == "--compiler"
            compiler = args[i + 1]; i += 2
        else
            i += 1
        end
    end
    manifest === nothing && error("--manifest is required")
    output === nothing && error("--output is required")
    compiler === nothing && error("--compiler is required")
    compiler in COMPILER_VOCABULARY ||
        error("--compiler must be one of " * join(COMPILER_VOCABULARY, ", ") *
              ", got '$compiler'")
    (manifest, output, compiler)
end

# Manifest `path` resolves against the manifest's OWN directory first (a
# document the tier authored) and then against the repository's `tests/`
# directory (a document another tier already owns). The same two-step rule the
# runner applies, so a tier is free to reference rather than copy.
function tests_root(manifest_path)
    d = dirname(abspath(manifest_path))
    while true
        basename(d) == "tests" && return d
        parent = dirname(d)
        parent == d && return dirname(abspath(manifest_path))
        d = parent
    end
end

function fixture_path(manifest_path, fx)
    rel = String(fx.path)
    local_path = normpath(joinpath(dirname(abspath(manifest_path)), rel))
    isfile(local_path) && return local_path
    return normpath(joinpath(tests_root(manifest_path), rel))
end

# The code a message names, or nothing. Matched against the closed list above
# plus the `E_TREEWALK_*` family, so an ordinary numeric failure — whose message
# names no code — can never be mistaken for a refusal.
function refusal_code(message::AbstractString)
    for code in REFUSAL_CODES
        occursin(code, message) && return code
    end
    m = match(r"\bE_TREEWALK_[A-Z0-9_]+", message)
    m === nothing || return m.match
    return nothing
end

# The algorithm this fixture integrates with. esm-spec §2.2's `solver` block is
# the document's declaration about ITSELF, and `stiffness: "high"` selects the
# stiff family; the TOLERANCES are the manifest's, because a conformance tier
# has an opinion about the integrator's error and states it per tier.
function solver_alg(file)
    blk = file.solver
    if blk !== nothing && getproperty(blk, :stiffness) == "high"
        return OrdinaryDiffEqRosenbrock.Rodas5P()
    end
    return OrdinaryDiffEqTsit5.Tsit5()
end

# Why this binding cannot answer for `compiler` at all, or `nothing` if it can.
# The question goes to the library's own first step — `esm_problem` resolves
# the compiler's plan before it loads anything — so the adapter never decides
# availability itself, and a compiler that is unavailable here is reported once
# rather than once per assertion of every fixture.
function compiler_unavailable_reason(compiler)
    try
        EarthSciAST._plan_for(Symbol(compiler))
    catch err
        err isa SimulateError && err.code == ERROR_CODES.COMPILER_UNAVAILABLE &&
            return sprint(showerror, err)
        rethrow()
    end
    return nothing
end

# The whole-output `unavailable` answer.
unavailable_payload(compiler, reason) = Dict{String,Any}(
    "binding" => BINDING, "compiler" => compiler,
    "status" => "unavailable", "reason" => first(reason, 400))

# Thrown out of `run_fixture` when a fixture's run says the COMPILER is
# unavailable, so `main` can replace the whole output.
struct CompilerUnavailable <: Exception
    reason::String
end

# One fixture's answer. Throws `CompilerUnavailable` for a run in which the
# compiler, not the document, was what failed.
function run_fixture(manifest, fx, manifest_path, compiler)
    path = fixture_path(manifest_path, fx)
    isfile(path) || error("fixture document not found at $path")
    file = load_path(path)
    integ = manifest.integrators.julia
    results = run_inline_tests(file;
                               model_name=String(fx.model),
                               alg=solver_alg(file),
                               reltol=Float64(integ.reltol),
                               abstol=Float64(integ.abstol),
                               base_dir=dirname(path),
                               compiler=Symbol(compiler))
    isempty(results) && error("the document declares no inline assertions for model " *
                              String(fx.model))

    entries = [Dict{String,Any}(
                   "test_id" => r.test_id,
                   "assertion_idx" => r.assertion_idx,
                   "variable" => r.variable,
                   "passed" => r.passed,
                   "actual" => r.actual === nothing ? nothing : Float64(r.actual),
                   "message" => r.message,
               ) for r in results]

    # A run in which EVERY assertion failed carrying ONE coded diagnostic is
    # this compiler declining the document, not this compiler getting every
    # number wrong. Reporting it as failures would put a refusal in the same
    # bucket as a numeric defect, which is the one conflation §5.45.3 forbids.
    codes = [refusal_code(r.message) for r in results if !r.passed]
    if length(codes) == length(results) && !isempty(codes) &&
       all(c -> c !== nothing, codes) && length(unique(codes)) == 1
        codes[1] == "compiler_unavailable" &&
            throw(CompilerUnavailable(results[1].message))
        return Dict{String,Any}(
            "status" => "refused",
            "code" => codes[1],
            "reason" => first(results[1].message, 400),
        )
    end
    return Dict{String,Any}("assertions" => entries)
end

function write_payload(output_path, payload)
    mkpath(dirname(abspath(output_path)))
    open(output_path, "w") do io
        JSON3.write(io, payload)
        write(io, "\n")
    end
end

function main(argv)
    manifest_path, output_path, compiler = parse_args(argv)
    manifest = JSON3.read(read(manifest_path, String))

    reason = compiler_unavailable_reason(compiler)
    if reason !== nothing
        write_payload(output_path, unavailable_payload(compiler, reason))
        return 0
    end

    fixtures = Dict{String,Any}()
    failed = String[]
    for fx in manifest.fixtures
        id = String(fx.id)
        entry = try
            run_fixture(manifest, fx, manifest_path, compiler)
        catch err
            if err isa CompilerUnavailable ||
               (err isa SimulateError && err.code == ERROR_CODES.COMPILER_UNAVAILABLE)
                # A fact about the BINDING, not about a document: it is the
                # whole output and the remaining fixtures are not attempted.
                why = err isa CompilerUnavailable ? err.reason : sprint(showerror, err)
                write_payload(output_path, unavailable_payload(compiler, why))
                return 0
            end
            msg = sprint(showerror, err)
            code = refusal_code(msg)
            if code !== nothing
                Dict{String,Any}("status" => "refused", "code" => code,
                                 "reason" => first(msg, 400))
            else
                push!(failed, id)
                Dict{String,Any}("error" => first(msg, 800))
            end
        end
        fixtures[id] = entry
    end

    write_payload(output_path, Dict{String,Any}("binding" => BINDING, "compiler" => compiler,
                                                "fixtures" => fixtures))
    # A non-zero exit WITH a parsable report is legal and is how a run that
    # broke on one fixture still hands the runner the rest.
    isempty(failed) && return 0
    println(stderr, "inline_tests_adapter: $(length(failed)) fixture(s) errored: " *
                    join(failed, ", "))
    return 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
