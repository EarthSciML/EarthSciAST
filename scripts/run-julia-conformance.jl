#!/usr/bin/env julia

"""
Julia conformance producer for ESM Format cross-language testing.

Reads the shared CORPUS MANIFEST (`scripts/conformance_corpus.py`) and emits a
record for every entry in it. The producer does NOT enumerate the corpus itself:
each producer used to walk `tests/valid` / `tests/invalid` NON-recursively and
all four skipped the same 69 fixtures — the entire `aggregate` and
`template_imports` corpora — plus `lib/**`, which nothing swept at all
(audit 2026-07-14, F5; CONFORMANCE_SPEC §2.2.1).

Every validation entry runs the full **load → resolve → validate** pipeline.
`EarthSciAST.load(path)` resolves §4.7 subsystem refs against the file's own
directory; `validate()` does no file I/O in any binding, so without that phase a
`{ref}` stub reads as unresolved and `tests/valid/lib_*_subsystem_inclusion.esm`
and `tests/invalid/subsystem_ref_not_found.esm` could not both be satisfied.

See `scripts/run-python-conformance.py` for the emitted wire shape; every
producer emits the same one.
"""

using Pkg

project_dir = dirname(dirname(@__FILE__))
julia_package = joinpath(project_dir, "pkg", "EarthSciAST.jl")
Pkg.activate(julia_package)

using EarthSciAST
using JSON3
using Dates

# --- error normalisation ----------------------------------------------------

# Julia spells a structural error's code `error_type`; the wire shape (and every
# other binding) spells it `code`. Normalise here rather than letting the
# comparator special-case one language.
_schema_error_dict(e) = Dict{String, Any}(
    "path" => getfield(e, :path),
    "message" => getfield(e, :message),
    "keyword" => hasproperty(e, :keyword) ? getfield(e, :keyword) : "",
    "code" => hasproperty(e, :keyword) ? getfield(e, :keyword) : "",
    "details" => Dict{String, Any}(),
)

function _structural_error_dict(e)
    code = hasproperty(e, :code) ? getfield(e, :code) :
           hasproperty(e, :error_type) ? getfield(e, :error_type) : ""
    details = hasproperty(e, :details) ? getfield(e, :details) : Dict{String, Any}()
    return Dict{String, Any}(
        "path" => getfield(e, :path),
        "message" => getfield(e, :message),
        "code" => code,
        "keyword" => code,
        "details" => details,
    )
end

"""
    run_validation(manifest) -> Dict

load → resolve → validate every manifest entry.

When the load/resolve phase REJECTS a document, `validate` is still attempted on
the raw document, so a binding that raises early still gets to enumerate its
structured `(code, path)` findings for the pin check instead of reporting an
opaque exception string.
"""
function run_validation(manifest, project_root::String)
    results = Dict{String, Any}()

    for entry in manifest["validation_files"]
        id = String(entry["id"])
        path = joinpath(project_root, String(entry["path"]))
        record = Dict{String, Any}(
            "schema_errors" => Any[],
            "structural_errors" => Any[],
        )

        # SCHEMA judges the document AS WRITTEN, so it runs on the raw JSON and
        # runs even when the load phase rejects the file — otherwise a
        # schema-invalid fixture could never have its pinned `(keyword, path)`
        # findings checked, because the binding would have thrown before
        # enumerating them.
        try
            raw = JSON3.read(read(path, String), Dict{String, Any})
            record["schema_errors"] =
                [_schema_error_dict(e) for e in EarthSciAST.validate_schema(raw)]
        catch e
            record["error"] = string(e)
            record["error_type"] = string(typeof(e))
        end

        # LOAD + RESOLVE: the only phase that does file I/O.
        esm_data = nothing
        try
            esm_data = EarthSciAST.load(path)
            record["resolve_ok"] = true
        catch e
            record["resolve_ok"] = false
            haskey(record, "error") || (record["error"] = string(e))
            haskey(record, "error_type") || (record["error_type"] = string(typeof(e)))
        end

        # STRUCTURAL judges the RESOLVED form (§4.7 refs spliced in).
        if esm_data !== nothing
            try
                result = EarthSciAST.validate(esm_data)
                record["structural_errors"] =
                    [_structural_error_dict(e) for e in result.structural_errors]
                record["phase"] = "validate"
            catch e
                record["phase"] = "validate"
                haskey(record, "error") || (record["error"] = string(e))
                haskey(record, "error_type") || (record["error_type"] = string(typeof(e)))
            end
        else
            record["phase"] = "load"
        end

        # The verdict is "did this binding accept the document", regardless of
        # WHICH phase answered. A rejection at resolve is still a rejection.
        record["is_valid"] = record["resolve_ok"] === true &&
                             isempty(record["schema_errors"]) &&
                             isempty(record["structural_errors"])
        record["outcome"] = record["is_valid"] ? "valid" : "invalid"
        results[id] = record
    end

    return results
end

"""
Render every manifest display case in all three formats.

A bare-string input is a CHEMICAL FORMULA; a dict input is an Expression. The
manifest tags which, so no producer has to re-derive it (and get it wrong: this
producer used to look for a top-level `chemical_formulas` key that NO fixture in
`tests/display/` has, so it emitted nothing at all and the comparator scored the
empty intersection as 100% consistent — audit C2).
"""
function run_display(manifest)
    results = Dict{String, Any}()

    for case in manifest["display_cases"]
        id = String(case["id"])
        # A "formula" case is a bare chemical-formula STRING ("O3" → "O₃"); an
        # "expression" case is a dict-form Expression that has to be parsed into
        # this binding's AST first. Julia's `to_unicode` dispatches on the type,
        # so handing it the raw dict would throw.
        is_formula = String(case["kind"]) == "formula"
        record = Dict{String, Any}()
        errors = Dict{String, Any}()

        target = nothing
        parse_failure = nothing
        try
            target = is_formula ? String(case["input"]) :
                     EarthSciAST.parse_expression(case["input"])
        catch e
            parse_failure = string(e)
        end

        for (fmt, renderer) in (
            ("unicode", EarthSciAST.to_unicode),
            ("latex", EarthSciAST.to_latex),
            ("ascii", EarthSciAST.to_ascii),
        )
            if parse_failure !== nothing
                record[fmt] = nothing
                errors[fmt] = parse_failure
                continue
            end
            try
                record[fmt] = renderer(target)
            catch e
                record[fmt] = nothing
                errors[fmt] = string(e)
            end
        end

        isempty(errors) || (record["errors"] = errors)
        results[id] = record
    end

    return results
end

"""
Apply `substitute` to every manifest substitution case.

The result is serialized back to the dict-form Expression the corpus and the
other bindings speak, so the comparator can demand byte-equality on the AST
rather than on each binding's pretty-printed rendering of it.
"""
function run_substitution(manifest)
    results = Dict{String, Any}()

    for case in manifest["substitution_cases"]
        id = String(case["id"])
        try
            expr = EarthSciAST.parse_expression(case["input"])
            bindings = Dict{String, EarthSciAST.ASTExpr}(
                String(k) => EarthSciAST.parse_expression(v)
                for (k, v) in case["bindings"]
            )
            result = EarthSciAST.substitute(expr, bindings)
            results[id] = Dict{String, Any}(
                "result" => EarthSciAST.serialize_expression(result))
        catch e
            results[id] = Dict{String, Any}("result" => nothing, "error" => string(e))
        end
    end

    return results
end

"""
The manifest path is passed by the harness; there is no fallback sweep. A
producer that invents its own corpus when the manifest is missing is a producer
that can silently under-report coverage. Fail instead.
"""
function load_manifest(output_dir::String)
    manifest_path = if length(ARGS) >= 2
        ARGS[2]
    elseif haskey(ENV, "ESM_CONFORMANCE_MANIFEST")
        ENV["ESM_CONFORMANCE_MANIFEST"]
    else
        joinpath(dirname(output_dir), "corpus_manifest.json")
    end

    if !isfile(manifest_path)
        println(stderr, "Corpus manifest not found: $manifest_path")
        println(stderr,
            "Generate it with: python3 scripts/conformance_corpus.py --output <path>")
        exit(2)
    end
    return JSON3.read(read(manifest_path, String), Dict{String, Any})
end

function main()
    if length(ARGS) < 1
        println("Usage: julia run-julia-conformance.jl <output_dir> [<corpus_manifest.json>]")
        exit(1)
    end

    output_dir = abspath(ARGS[1])
    project_root = dirname(dirname(@__FILE__))
    manifest = load_manifest(output_dir)

    println("Running Julia conformance producer...")
    println("Output directory: $output_dir")

    errors = String[]
    validation_results = Dict{String, Any}()
    display_results = Dict{String, Any}()
    substitution_results = Dict{String, Any}()

    try
        validation_results = run_validation(manifest, project_root)
        println("✓ Validation sweep completed ($(length(validation_results)) files)")
    catch e
        push!(errors, "Validation sweep crashed: $(string(e))")
        println("✗ Validation sweep crashed: $e")
    end

    try
        display_results = run_display(manifest)
        println("✓ Display sweep completed ($(length(display_results)) cases)")
    catch e
        push!(errors, "Display sweep crashed: $(string(e))")
        println("✗ Display sweep crashed: $e")
    end

    try
        substitution_results = run_substitution(manifest)
        println("✓ Substitution sweep completed ($(length(substitution_results)) cases)")
    catch e
        push!(errors, "Substitution sweep crashed: $(string(e))")
        println("✗ Substitution sweep crashed: $e")
    end

    mkpath(output_dir)
    results_file = joinpath(output_dir, "results.json")
    open(results_file, "w") do f
        JSON3.pretty(f, Dict{String, Any}(
            "language" => "julia",
            "timestamp" => string(now()),
            "validation_results" => validation_results,
            "display_results" => display_results,
            "substitution_results" => substitution_results,
            "errors" => errors,
        ))
    end
    println("Julia conformance results written to: $results_file")

    # A producer CRASH is fatal; a fixture-level divergence is not the producer's
    # verdict to make — the comparator owns that judgement, and it needs every
    # binding's results.json to make it.
    exit(isempty(errors) ? 0 : 1)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
