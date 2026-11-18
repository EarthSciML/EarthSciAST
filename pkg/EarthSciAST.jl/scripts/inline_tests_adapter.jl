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
#         --manifest <manifest.json> --output <out.json> [--manifest ... --output ...] \
#         --compiler <value>
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

# The environment is compiler_agreement_adapter.jl's: this adapter needs exactly
# the same four packages (EarthSciAST, JSON3, Tsit5 for the ordinary arm and
# Rosenbrock for a document whose §2.2 `solver` block declares
# `stiffness: "high"`), and a second env carrying the same list would be one
# more Manifest to keep alive for no coverage.
include(joinpath(@__DIR__, "adapter_support.jl"))
activate_adapter_env(normpath(joinpath(@__DIR__, "compiler_agreement_env")))

using EarthSciAST
using JSON3
import OrdinaryDiffEqTsit5
import OrdinaryDiffEqRosenbrock

const BINDING = "julia"

# `--manifest <m> --output <o>` may repeat: each `--output` belongs to the
# `--manifest` before it, and every pair is run in this ONE process under the
# one `--compiler`. Most of a launch is compiling the build-and-solve path on
# first call, which a second process pays all over again, so
# `scripts/test-conformance.sh` hands every tier to one launch per compiler
# (CONFORMANCE_SPEC.md §5.45.5).
# The value after the flag at `args[i]`; a flag at the end of the line has none.
_flag_value(args, i) =
    i < length(args) ? args[i + 1] : error("$(PROGRAM_FILE): $(args[i]) needs a value")

function parse_args(args)
    pairs = Vector{Vector{Union{Nothing, String}}}()
    compiler = nothing
    i = 1
    while i <= length(args)
        if args[i] == "--manifest"
            push!(pairs, [_flag_value(args, i), nothing]); i += 2
        elseif args[i] == "--output"
            isempty(pairs) && error("--output must follow the --manifest it belongs to")
            pairs[end][2] === nothing ||
                error("--manifest $(pairs[end][1]) was given two --output paths")
            pairs[end][2] = _flag_value(args, i); i += 2
        elseif args[i] == "--compiler"
            compiler = _flag_value(args, i); i += 2
        else
            error("$(PROGRAM_FILE): unrecognised argument $(repr(args[i]))")
        end
    end
    isempty(pairs) && error("--manifest is required")
    for (m, o) in pairs
        o === nothing && error("--output is required (for --manifest $m)")
    end
    compiler === nothing && error("--compiler is required")
    check_compiler(compiler, EarthSciAST.COMPILER_VOCABULARY)
    return ([(String(m), String(o)) for (m, o) in pairs], compiler)
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
    return
end

function fixture_path(manifest_path, fx)
    rel = String(fx.path)
    local_path = normpath(joinpath(dirname(abspath(manifest_path)), rel))
    isfile(local_path) && return local_path
    return normpath(joinpath(tests_root(manifest_path), rel))
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
unavailable_payload(compiler, reason) = Dict{String, Any}(
    "binding" => BINDING, "compiler" => compiler,
    "status" => "unavailable", "reason" => first(reason, 400)
)

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
    results = run_inline_tests(
        file;
        model_name = String(fx.model),
        alg = solver_alg(file),
        reltol = Float64(integ.reltol),
        abstol = Float64(integ.abstol),
        base_dir = dirname(path),
        compiler = Symbol(compiler)
    )
    isempty(results) && error(
        "the document declares no inline assertions for model " *
            String(fx.model)
    )

    entries = [
        Dict{String, Any}(
            "test_id" => r.test_id,
            "assertion_idx" => r.assertion_idx,
            "variable" => r.variable,
            "passed" => r.passed,
            "actual" => r.actual === nothing ? nothing : Float64(r.actual),
            "message" => r.message,
        ) for r in results
    ]

    # A run in which EVERY assertion failed carrying ONE refusal code (the
    # result's `code`, read off the error) is this compiler declining the
    # document, not this compiler getting every number wrong. Reporting it as
    # failures would put a refusal in the same bucket as a numeric defect, which
    # is the one conflation §5.45.3 forbids.
    codes = [r.code for r in results if !r.passed]
    if length(codes) == length(results) && !isempty(codes) &&
            all(c -> c == "compiler_unavailable" || is_refusal_code(c), codes) &&
            length(unique(codes)) == 1
        codes[1] == "compiler_unavailable" &&
            throw(CompilerUnavailable(results[1].message))
        return Dict{String, Any}(
            "status" => "refused",
            "code" => codes[1],
            "reason" => first(results[1].message, 400),
        )
    end
    return Dict{String, Any}("assertions" => entries)
end

write_payload(output_path, payload) = write_report(output_path, JSON3.write(payload))

function main(argv)
    pairs, compiler = parse_args(argv)
    rc = 0
    for (manifest_path, output_path) in pairs
        # One tier's failure to even start (an unreadable manifest) must not
        # cost the others their reports: it writes none, which the runner
        # grades as `no_output` for THAT tier.
        this_rc = try
            run_manifest(manifest_path, output_path, compiler)
        catch err
            println(stderr, "inline_tests_adapter: $manifest_path: ", sprint(showerror, err))
            1
        end
        rc = max(rc, this_rc)
    end
    return rc
end

function run_manifest(manifest_path, output_path, compiler)
    manifest = JSON3.read(read(manifest_path, String))

    reason = compiler_unavailable_reason(compiler)
    if reason !== nothing
        write_payload(output_path, unavailable_payload(compiler, reason))
        return 0
    end

    fixtures = Dict{String, Any}()
    failed = String[]
    for fx in manifest.fixtures
        id = String(fx.id)
        entry = try
            run_fixture(manifest, fx, manifest_path, compiler)
        catch err
            o = outcome(err)
            if err isa CompilerUnavailable || o.kind === :unavailable
                # A fact about the BINDING, not about a document: it is the
                # whole output and the remaining fixtures are not attempted.
                why = err isa CompilerUnavailable ? err.reason : sprint(showerror, err)
                write_payload(output_path, unavailable_payload(compiler, why))
                return 0
            end
            msg = sprint(showerror, err)
            if o.kind === :refused
                Dict{String, Any}(
                    "status" => "refused", "code" => o.code,
                    "reason" => first(msg, 400)
                )
            else
                push!(failed, id)
                Dict{String, Any}("error" => first(msg, 800))
            end
        end
        fixtures[id] = entry
    end

    write_payload(
        output_path, Dict{String, Any}(
            "binding" => BINDING, "compiler" => compiler,
            "fixtures" => fixtures
        )
    )
    # A non-zero exit WITH a parsable report is legal and is how a run that
    # broke on one fixture still hands the runner the rest.
    isempty(failed) && return 0
    println(
        stderr, "inline_tests_adapter: $(length(failed)) fixture(s) errored: " *
            join(failed, ", ")
    )
    return 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
