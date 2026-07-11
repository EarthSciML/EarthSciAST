#!/usr/bin/env julia

"""
Julia conformance test runner for ESM Format cross-language testing.

This script runs the Julia EarthSciAST.jl implementation against test fixtures
and generates standardized outputs for comparison with other language implementations.
"""

using Pkg

# Ensure we're in the right environment. Activate the package by absolute
# path WITHOUT cd-ing into it, so caller-supplied relative paths (notably
# the output dir in ARGS) keep resolving against the caller's cwd.
project_dir = dirname(dirname(@__FILE__))
julia_package = joinpath(project_dir, "pkg", "EarthSciAST.jl")
Pkg.activate(julia_package)

using EarthSciAST
using JSON3
using Printf
using Dates

struct ConformanceResults
    language::String
    timestamp::String
    validation_results::Dict{String, Any}
    display_results::Dict{String, Any}
    substitution_results::Dict{String, Any}
    graph_results::Dict{String, Any}
    mathematical_correctness_results::Dict{String, Any}
    errors::Vector{String}
end

function write_results(output_dir::String, results::ConformanceResults)
    mkpath(output_dir)

    # Write main results file
    results_file = joinpath(output_dir, "results.json")
    open(results_file, "w") do f
        JSON3.pretty(f, results)
    end

    println("Julia conformance results written to: $results_file")
end

"""
    run_validation_dir(dir; expect_error=false)

Load + validate every `.esm` file in `dir`, returning a per-file record
Dict. With `expect_error=true` (invalid fixtures) a parse failure is
annotated as the expected outcome.
"""
function run_validation_dir(dir::String; expect_error::Bool=false)
    results = Dict{String, Any}()
    for filename in filter(f -> endswith(f, ".esm"), readdir(dir))
        filepath = joinpath(dir, filename)
        try
            esm_data = EarthSciAST.load(filepath)
            result = EarthSciAST.validate(esm_data)

            results[filename] = Dict(
                "is_valid" => result.is_valid,
                "schema_errors" => result.schema_errors,
                "structural_errors" => result.structural_errors,
                "parsed_successfully" => true
            )
        catch e
            record = Dict{String, Any}(
                "parsed_successfully" => false,
                "error" => string(e),
                "error_type" => string(typeof(e))
            )
            expect_error && (record["is_expected_error"] = true)
            results[filename] = record
        end
    end
    return results
end

"Test schema and structural validation on valid and invalid ESM files."
function run_validation_tests(tests_dir::String)
    validation_results = Dict{String, Any}()

    valid_dir = joinpath(tests_dir, "valid")
    if isdir(valid_dir)
        validation_results["valid"] = run_validation_dir(valid_dir)
    end

    invalid_dir = joinpath(tests_dir, "invalid")
    if isdir(invalid_dir)
        validation_results["invalid"] =
            run_validation_dir(invalid_dir; expect_error=true)
    end

    return validation_results
end

"""
    for_each_json_fixture(f, dir) -> Dict{String, Any}

Shared fixture-directory skeleton for the display / substitution suites:
parse every `*.json` fixture in `dir` (a missing directory yields an empty
result) and record `f(test_data)` under the fixture's filename. A fixture
whose read / parse / processing throws is recorded as an
`{"error", "success" => false}` entry instead of aborting the sweep.
"""
function for_each_json_fixture(f, dir::String)
    results = Dict{String, Any}()
    isdir(dir) || return results
    for filename in filter(n -> endswith(n, ".json"), readdir(dir))
        filepath = joinpath(dir, filename)
        try
            test_data = JSON3.read(read(filepath, String))
            results[filename] = f(test_data)
        catch e
            results[filename] = Dict(
                "error" => string(e),
                "success" => false
            )
        end
    end
    return results
end

"""
Test pretty-printing and display format generation.

All three output fields (`output_unicode` / `output_latex` / `output_ascii`)
are ACTUAL renderer output from this package — never the fixture's own
expectations echoed back — so the cross-language comparator can detect
genuine Julia divergence.
"""
function run_display_tests(tests_dir::String)
    return for_each_json_fixture(joinpath(tests_dir, "display")) do test_data
        test_results = Dict{String, Any}()

        # Test chemical formula rendering
        if haskey(test_data, "chemical_formulas")
            formula_results = []
            for formula_test in test_data["chemical_formulas"]
                if haskey(formula_test, "input")
                    input_formula = String(formula_test["input"])
                    try
                        unicode_result = EarthSciAST.render_chemical_formula(input_formula)
                        # Actual renderer output for latex/ascii too
                        # (previously the fixture's own expected_latex
                        # and the raw input were echoed back, so the
                        # comparator could never see Julia diverge).
                        latex_result = EarthSciAST.format_chemical_subscripts(
                            input_formula, :latex)
                        ascii_result = EarthSciAST.format_chemical_subscripts(
                            input_formula, :ascii)

                        push!(formula_results, Dict(
                            "input" => input_formula,
                            "output_unicode" => unicode_result,
                            "output_latex" => latex_result,
                            "output_ascii" => ascii_result,
                            "success" => true
                        ))
                    catch e
                        push!(formula_results, Dict(
                            "input" => input_formula,
                            "error" => string(e),
                            "success" => false
                        ))
                    end
                end
            end
            test_results["chemical_formulas"] = formula_results
        end

        # Test expression rendering
        if haskey(test_data, "expressions")
            expression_results = []
            for expr_test in test_data["expressions"]
                if haskey(expr_test, "input")
                    input_expr = expr_test["input"]
                    try
                        expr = EarthSciAST.parse_expression(input_expr)
                        # Real renderer output (the previously called
                        # `pretty_print` does not exist in this package,
                        # so every expression test recorded an error).
                        unicode_result = EarthSciAST.format_expression(expr, :unicode)
                        latex_result = EarthSciAST.format_expression(expr, :latex)
                        ascii_result = EarthSciAST.format_expression_ascii(expr)

                        push!(expression_results, Dict(
                            "input" => input_expr,
                            "output_unicode" => unicode_result,
                            "output_latex" => latex_result,
                            "output_ascii" => ascii_result,
                            "success" => true
                        ))
                    catch e
                        push!(expression_results, Dict(
                            "input" => input_expr,
                            "error" => string(e),
                            "success" => false
                        ))
                    end
                end
            end
            test_results["expressions"] = expression_results
        end

        return test_results
    end
end

"Test expression substitution functionality."
function run_substitution_tests(tests_dir::String)
    return for_each_json_fixture(joinpath(tests_dir, "substitution")) do test_data
        test_results = []

        if haskey(test_data, "tests")
            for test_case in test_data["tests"]
                if haskey(test_case, "expression") && haskey(test_case, "substitutions")
                    try
                        expr = EarthSciAST.parse_expression(test_case["expression"])
                        substitutions = Dict(
                            k => EarthSciAST.parse_expression(v)
                            for (k, v) in test_case["substitutions"]
                        )

                        result_expr = EarthSciAST.substitute(expr, substitutions)
                        # ASCII rendering: deterministic and the most
                        # portable cross-language comparison format
                        # (`pretty_print` does not exist in this package).
                        result_str = EarthSciAST.to_ascii(result_expr)

                        push!(test_results, Dict(
                            "input" => test_case["expression"],
                            "substitutions" => test_case["substitutions"],
                            "result" => result_str,
                            "success" => true
                        ))
                    catch e
                        push!(test_results, Dict(
                            "input" => get(test_case, "expression", ""),
                            "error" => string(e),
                            "success" => false
                        ))
                    end
                end
            end
        end

        return test_results
    end
end

# Resolve an `input_file` reference inside a graphs/ fixture. Per
# tests/graphs convention these are bare filenames living in tests/valid/.
function _resolve_graph_input_file(tests_dir::String, fixture_path::String, ref::AbstractString)
    candidates = [
        joinpath(dirname(fixture_path), ref),
        joinpath(tests_dir, "valid", ref),
        joinpath(tests_dir, ref),
    ]
    for c in candidates
        isfile(c) && return c
    end
    return nothing
end

# Load an ESM source — either from a file path on disk or an inline JSON dict
# (the comprehensive_graph_generation_fixtures family encodes the full ESM
# document inline under the "esm_file" key).
function _load_esm_source(tests_dir::String, fixture_path::String, source)
    if source isa AbstractString
        path = _resolve_graph_input_file(tests_dir, fixture_path, source)
        path === nothing && throw(ErrorException("ESM file not found: $source"))
        return EarthSciAST.load(path)
    else
        json_str = JSON3.write(source)
        return EarthSciAST.load(IOBuffer(json_str))
    end
end

# Walk an ESM file through the validation + graph-construction pipeline and
# emit a comparison-friendly summary (validity, component/expression graph
# sizes). Failures are caught and recorded so a single broken fixture does
# not abort the whole run.
function _exercise_graph_fixture(esm_data)
    record = Dict{String, Any}("loaded" => true)

    try
        result = EarthSciAST.validate(esm_data)
        record["validation"] = Dict(
            "is_valid" => result.is_valid,
            "schema_error_count" => length(result.schema_errors),
            "structural_error_count" => length(result.structural_errors),
        )
    catch e
        record["validation"] = Dict("error" => string(e))
    end

    try
        cg = EarthSciAST.component_graph(esm_data)
        record["component_graph"] = Dict(
            "nodes" => length(cg.nodes),
            "edges" => length(cg.edges),
        )
    catch e
        record["component_graph"] = Dict("error" => string(e))
    end

    try
        eg = EarthSciAST.expression_graph(esm_data)
        record["expression_graph"] = Dict(
            "nodes" => length(eg.nodes),
            "edges" => length(eg.edges),
        )
    catch e
        record["expression_graph"] = Dict("error" => string(e))
    end

    return record
end

"""
Drive each tests/graphs fixture through the load + validate +
component_graph + expression_graph pipeline. Captures node/edge counts
so the cross-language comparator can flag size divergence.

Handles three fixture shapes:
  1. Dict with `input_file` (bare filename in tests/valid/).
  2. Dict with `esm_file` (legacy key, may be path or inline dict).
  3. List of test cases each carrying its own `name` + `esm_file`.
Pure expression-only fixtures (no top-level ESM document) are skipped.
"""
function run_graph_tests(tests_dir::String)
    graph_results = Dict{String, Any}()

    graphs_dir = joinpath(tests_dir, "graphs")
    isdir(graphs_dir) || return graph_results

    for filename in filter(f -> endswith(f, ".json"), readdir(graphs_dir))
        filepath = joinpath(graphs_dir, filename)
        try
            test_data = JSON3.read(read(filepath, String))

            if test_data isa AbstractVector
                cases = Dict{String, Any}()
                for (i, case) in enumerate(test_data)
                    name = case isa AbstractDict && haskey(case, "name") ?
                        String(case["name"]) : "case_$i"
                    src = nothing
                    if case isa AbstractDict
                        src = get(case, "esm_file", nothing)
                        src === nothing && (src = get(case, "input_file", nothing))
                    end
                    if src === nothing
                        cases[name] = Dict("skipped" => "no esm_file/input_file")
                        continue
                    end
                    try
                        esm_data = _load_esm_source(tests_dir, filepath, src)
                        cases[name] = _exercise_graph_fixture(esm_data)
                    catch e
                        cases[name] = Dict("loaded" => false, "error" => string(e))
                    end
                end
                graph_results[filename] = Dict("test_cases" => cases)
            else
                src = get(test_data, "input_file", nothing)
                src === nothing && (src = get(test_data, "esm_file", nothing))
                if src === nothing
                    graph_results[filename] = Dict("skipped" => "no input_file/esm_file")
                    continue
                end
                try
                    esm_data = _load_esm_source(tests_dir, filepath, src)
                    record = _exercise_graph_fixture(esm_data)
                    record["input_file"] = src isa AbstractString ? String(src) : "<inline>"
                    graph_results[filename] = record
                catch e
                    graph_results[filename] = Dict(
                        "loaded" => false,
                        "error" => string(e),
                        "input_file" => src isa AbstractString ? String(src) : "<inline>",
                    )
                end
            end
        catch e
            graph_results[filename] = Dict(
                "error" => string(e),
                "loaded" => false,
            )
        end
    end

    return graph_results
end

"""
Drive each .esm file under tests/mathematical_correctness/ through
load + validate. The fixtures encode conservation laws, dimensional
analysis, and numerical-correctness scenarios — parsing them in every
binding catches schema/structural drift that the conformance harness
would otherwise miss (esm-rs7 / audit esm-rv3 §3.1).
"""
function run_mathematical_correctness_tests(tests_dir::String)
    results = Dict{String, Any}()

    math_dir = joinpath(tests_dir, "mathematical_correctness")
    isdir(math_dir) || return results

    for filename in filter(f -> endswith(f, ".esm"), readdir(math_dir))
        filepath = joinpath(math_dir, filename)
        try
            esm_data = EarthSciAST.load(filepath)
            try
                result = EarthSciAST.validate(esm_data)
                results[filename] = Dict(
                    "loaded" => true,
                    "is_valid" => result.is_valid,
                    "schema_error_count" => length(result.schema_errors),
                    "structural_error_count" => length(result.structural_errors),
                )
            catch e
                results[filename] = Dict(
                    "loaded" => true,
                    "validation_error" => string(e),
                )
            end
        catch e
            results[filename] = Dict(
                "loaded" => false,
                "error" => string(e),
                "error_type" => string(typeof(e)),
            )
        end
    end

    return results
end

function main()
    if length(ARGS) != 1
        println("Usage: julia run-julia-conformance.jl <output_dir>")
        exit(1)
    end

    # abspath so the output location is stable regardless of any later cwd
    # changes (and unambiguous in the log lines below).
    output_dir = abspath(ARGS[1])
    project_root = dirname(dirname(@__FILE__))
    tests_dir = joinpath(project_root, "tests")

    println("Running Julia conformance tests...")
    println("Tests directory: $tests_dir")
    println("Output directory: $output_dir")

    errors = String[]

    # Run all test categories through one (label, runner) loop — a category
    # failure is recorded in `errors` (its results left empty) without
    # aborting the others. The printed lines and error strings are
    # byte-identical to the historical five copy-pasted try/catch blocks.
    # Order matters: it matches the ConformanceResults field order.
    categories = [
        ("Validation tests", run_validation_tests),
        ("Display tests", run_display_tests),
        ("Substitution tests", run_substitution_tests),
        ("Graph tests", run_graph_tests),
        ("Mathematical-correctness tests", run_mathematical_correctness_tests),
    ]
    category_results = Dict{String, Any}[]
    for (label, runner) in categories
        result = Dict{String, Any}()
        try
            result = runner(tests_dir)
            println("✓ $(label) completed")
        catch e
            push!(errors, "$(label) failed: $(string(e))")
            println("✗ $(label) failed: $e")
        end
        push!(category_results, result)
    end
    (validation_results, display_results, substitution_results, graph_results,
        math_results) = category_results

    # Compile results
    results = ConformanceResults(
        "julia",
        string(now()),
        validation_results,
        display_results,
        substitution_results,
        graph_results,
        math_results,
        errors
    )

    # Write results to file
    write_results(output_dir, results)

    if isempty(errors)
        println("Julia conformance testing completed successfully!")
        exit(0)
    else
        println("Julia conformance testing completed with $(length(errors)) errors")
        exit(1)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end