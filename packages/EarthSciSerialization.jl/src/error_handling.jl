"""
Comprehensive error handling and diagnostics system for EarthSciSerialization.jl.

This module provides:
1. Standardized error codes and messages
2. User-friendly error reporting with fix suggestions
3. Debugging aids for complex coupling issues
4. Performance profiling tools
5. Interactive error exploration helpers
"""

using JSON3

# Standardized error codes for consistent error handling
@enum ErrorCode begin
    # Schema and Parsing Errors (1000-1999)
    JSON_PARSE_ERROR = 1001
    SCHEMA_VALIDATION_ERROR = 1002
    UNSUPPORTED_VERSION = 1003
    MISSING_REQUIRED_FIELD = 1004
    INVALID_FIELD_TYPE = 1005

    # Structural Validation Errors (2000-2999)
    EQUATION_UNKNOWN_IMBALANCE = 2001
    UNDEFINED_REFERENCE = 2002
    INVALID_SCOPE_PATH = 2003
    CIRCULAR_DEPENDENCY = 2004
    MISSING_COUPLING_TARGET = 2005
    INVALID_REACTION_STOICHIOMETRY = 2006
    UNDECLARED_SPECIES = 2007
    UNDECLARED_PARAMETER = 2008
    NULL_NULL_REACTION = 2009

    # Expression and Mathematical Errors (3000-3999)
    EXPRESSION_PARSE_ERROR = 3001
    UNDEFINED_VARIABLE = 3002
    TYPE_MISMATCH = 3003
    DIVISION_BY_ZERO = 3004
    MATHEMATICAL_INCONSISTENCY = 3005
    UNIT_MISMATCH = 3006
    DIMENSION_ERROR = 3007

    # Coupling and System Integration Errors (4000-4999)
    COUPLING_RESOLUTION_ERROR = 4001
    SCOPE_BOUNDARY_VIOLATION = 4002
    VARIABLE_SHADOWING = 4003
    DEEP_NESTING_WARNING = 4004
    UNUSED_VARIABLE = 4005
    COUPLING_GRAPH_CYCLE = 4006
    INCOMPATIBLE_DOMAINS = 4007

    # Simulation and Runtime Errors (5000-5999)
    SIMULATION_CONVERGENCE_ERROR = 5001
    SOLVER_CONFIGURATION_ERROR = 5002
    BOUNDARY_CONDITION_ERROR = 5003
    TIME_SYNCHRONIZATION_ERROR = 5004
    DATA_LOADER_ERROR = 5005
    OPERATOR_EXECUTION_ERROR = 5006

    # Performance and Resource Errors (6000-6999)
    MEMORY_LIMIT_EXCEEDED = 6001
    COMPUTATION_TIMEOUT = 6002
    LARGE_SYSTEM_WARNING = 6003
    INEFFICIENT_COUPLING = 6004

    # User Interface and Interactive Errors (7000-7999)
    EDITOR_STATE_ERROR = 7001
    INVALID_USER_INPUT = 7002
    DISPLAY_RENDERING_ERROR = 7003
end

# Error severity levels. The error level is named SEV_ERROR (not ERROR)
# because the module also defines the exported AssertionStatus member ERROR
# (src/run_tests.jl); two enums in one module cannot share a member name.
@enum Severity begin
    CRITICAL
    SEV_ERROR
    WARNING
    INFO
    DEBUG
end

"""
    ErrorContext

Additional context information for errors.
"""
struct ErrorContext
    file_path::Union{String, Nothing}
    line_number::Union{Int, Nothing}
    column::Union{Int, Nothing}
    component_name::Union{String, Nothing}
    operation::Union{String, Nothing}
    performance_metrics::Dict{String, Float64}
    system_state::Dict{String, Any}

    # Constructor with defaults
    ErrorContext(;
        file_path=nothing,
        line_number=nothing,
        column=nothing,
        component_name=nothing,
        operation=nothing,
        performance_metrics=Dict{String, Float64}(),
        system_state=Dict{String, Any}()
    ) = new(file_path, line_number, column, component_name, operation, performance_metrics, system_state)
end

"""
    FixSuggestion

Actionable suggestion for fixing an error.
"""
struct FixSuggestion
    description::String
    code_example::Union{String, Nothing}
    documentation_link::Union{String, Nothing}
    priority::Int  # 1 = highest priority

    FixSuggestion(description; code_example=nothing, documentation_link=nothing, priority=1) =
        new(description, code_example, documentation_link, priority)
end

"""
    ESMError

Comprehensive error representation with diagnostics and suggestions.
"""
struct ESMError
    code::ErrorCode
    message::String
    severity::Severity
    path::String
    context::Union{ErrorContext, Nothing}
    fix_suggestions::Vector{FixSuggestion}
    related_errors::Vector{ESMError}
    timestamp::Float64
    debug_info::Dict{String, Any}

    # Constructor with defaults
    ESMError(code, message, severity;
        path="",
        context=nothing,
        fix_suggestions=FixSuggestion[],
        related_errors=ESMError[],
        timestamp=time(),
        debug_info=Dict{String, Any}()
    ) = new(code, message, severity, path, context, fix_suggestions, related_errors, timestamp, debug_info)
end

"""
    ErrorCollector

Collects and manages errors during ESM processing.
"""
mutable struct ErrorCollector
    errors::Vector{ESMError}
    warnings::Vector{ESMError}
    performance_data::Dict{String, Float64}

    ErrorCollector() = new(ESMError[], ESMError[], Dict{String, Float64}())
end

"""
    add_error!(collector, error)

Add an error to the collection.
"""
function add_error!(collector::ErrorCollector, error::ESMError)
    if error.severity in [CRITICAL, SEV_ERROR]
        push!(collector.errors, error)
    else
        push!(collector.warnings, error)
    end
end

"""
    has_errors(collector)

Check if there are any critical errors or errors.
"""
has_errors(collector::ErrorCollector) = !isempty(collector.errors)

"""
    has_warnings(collector)

Check if there are any warnings.
"""
has_warnings(collector::ErrorCollector) = !isempty(collector.warnings)

"""
    get_summary(collector)

Get a summary of all collected errors and warnings.
"""
function get_summary(collector::ErrorCollector)
    if isempty(collector.errors) && isempty(collector.warnings)
        return "✅ No errors or warnings"
    end

    parts = String[]
    if !isempty(collector.errors)
        push!(parts, "❌ $(length(collector.errors)) error(s)")
    end
    if !isempty(collector.warnings)
        push!(parts, "⚠️  $(length(collector.warnings)) warning(s)")
    end

    return join(parts, ", ")
end

"""
    format_user_friendly(error)

Format error message for end users.
"""
function format_user_friendly(error::ESMError)
    lines = String[]

    # Header with severity and code
    severity_icons = Dict(
        CRITICAL => "🚫",
        SEV_ERROR => "❌",
        WARNING => "⚠️",
        INFO => "ℹ️",
        DEBUG => "🔍"
    )

    icon = get(severity_icons, error.severity, "•")
    severity_label = error.severity == SEV_ERROR ? "ERROR" : uppercase(string(error.severity))
    push!(lines, "$(icon) $(severity_label) [ESM$(Int(error.code))]")
    push!(lines, "   $(error.message)")

    if !isempty(error.path)
        push!(lines, "   Location: $(error.path)")
    end

    if error.context !== nothing
        context_parts = String[]
        if error.context.file_path !== nothing
            push!(context_parts, error.context.file_path)
        end
        if error.context.line_number !== nothing
            push!(context_parts, "line $(error.context.line_number)")
        end
        if error.context.column !== nothing
            push!(context_parts, "col $(error.context.column)")
        end
        if !isempty(context_parts)
            push!(lines, "   File: $(join(context_parts, ":"))")
        end
    end

    # Fix suggestions
    if !isempty(error.fix_suggestions)
        push!(lines, "")
        push!(lines, "💡 Suggested fixes:")
        sorted_suggestions = sort(error.fix_suggestions, by=s->s.priority)
        for (i, suggestion) in enumerate(sorted_suggestions)
            push!(lines, "   $i. $(suggestion.description)")
            if suggestion.code_example !== nothing
                push!(lines, "      Example: $(suggestion.code_example)")
            end
            if suggestion.documentation_link !== nothing
                push!(lines, "      Docs: $(suggestion.documentation_link)")
            end
        end
    end

    return join(lines, "\n")
end

"""
    PerformanceProfiler

Performance profiling tool for ESM operations.
"""
mutable struct PerformanceProfiler
    timings::Dict{String, Vector{Float64}}
    memory_usage::Dict{String, Vector{Float64}}
    active_timers::Dict{String, Float64}

    PerformanceProfiler() = new(
        Dict{String, Vector{Float64}}(),
        Dict{String, Vector{Float64}}(),
        Dict{String, Float64}()
    )
end

# Global profiler instance
const _GLOBAL_PROFILER = PerformanceProfiler()

"""
    get_profiler()

Get the global performance profiler instance.
"""
get_profiler() = _GLOBAL_PROFILER

"""
    start_timer!(profiler, operation)

Start timing an operation.
"""
function start_timer!(profiler::PerformanceProfiler, operation::String)
    profiler.active_timers[operation] = time()
end

"""
    end_timer!(profiler, operation)

End timing an operation and return duration.
"""
function end_timer!(profiler::PerformanceProfiler, operation::String)
    if !haskey(profiler.active_timers, operation)
        return 0.0
    end

    duration = time() - profiler.active_timers[operation]
    delete!(profiler.active_timers, operation)

    if !haskey(profiler.timings, operation)
        profiler.timings[operation] = Float64[]
    end
    push!(profiler.timings[operation], duration)

    return duration
end

"""
    get_performance_report(profiler)

Get performance report.
"""
function get_performance_report(profiler::PerformanceProfiler)
    report = Dict{String, Dict{String, Float64}}()
    for (operation, times) in profiler.timings
        report[operation] = Dict(
            "count" => length(times),
            "total_time" => sum(times),
            "average_time" => isempty(times) ? 0.0 : sum(times) / length(times),
            "min_time" => isempty(times) ? 0.0 : minimum(times),
            "max_time" => isempty(times) ? 0.0 : maximum(times)
        )
    end
    return report
end

"""
    ESMErrorFactory

Factory for creating standardized ESM errors with helpful suggestions.
"""
module ESMErrorFactory

import ..ErrorCode, ..Severity, ..ESMError, ..ErrorContext, ..FixSuggestion,
       ..JSON_PARSE_ERROR, ..EQUATION_UNKNOWN_IMBALANCE, ..UNDEFINED_REFERENCE, ..LARGE_SYSTEM_WARNING,
       ..CRITICAL, ..SEV_ERROR, ..WARNING

"""
    create_json_parse_error(message, file_path="", line_number=nothing)

Create a JSON parse error with fix suggestions.
"""
function create_json_parse_error(message::String, file_path::String="", line_number::Union{Int, Nothing}=nothing)
    context = ErrorContext(
        file_path=file_path,
        line_number=line_number,
        operation="json_parsing"
    )

    suggestions = [
        FixSuggestion(
            "Check for missing commas, quotes, or brackets";
            code_example="""{"valid": "json", "array": [1, 2, 3]}""",
            priority=1
        ),
        FixSuggestion(
            "Validate JSON syntax using an online JSON validator";
            documentation_link="https://jsonlint.com/",
            priority=2
        )
    ]

    return ESMError(
        JSON_PARSE_ERROR,
        "Failed to parse JSON: $message",
        SEV_ERROR;
        path=file_path,
        context=context,
        fix_suggestions=suggestions
    )
end

"""
    create_equation_imbalance_error(model_name, num_equations, num_unknowns, state_variables)

Create equation-unknown imbalance error with detailed suggestions.
"""
function create_equation_imbalance_error(model_name::String, num_equations::Int, num_unknowns::Int,
                                       state_variables::Vector{String})
    context = ErrorContext(
        component_name=model_name,
        operation="structural_validation"
    )

    suggestions = FixSuggestion[]
    if num_equations < num_unknowns
        diff = num_unknowns - num_equations
        push!(suggestions, FixSuggestion(
            "Add $diff more equation(s) to balance the system";
            code_example="""equations = [Equation(:d$(state_variables[1])dt, :(expression))]""",
            priority=1
        ))
    else
        diff = num_equations - num_unknowns
        push!(suggestions, FixSuggestion(
            "Remove $diff equation(s) or add $diff more state variable(s)";
            priority=1
        ))
    end

    push!(suggestions, FixSuggestion(
        "Review the mathematical model to ensure proper formulation";
        documentation_link="https://docs.earthsciml.org/esm-format/models/#equation-balance",
        priority=2
    ))

    message = "Model '$model_name' has $num_equations equations but $num_unknowns unknowns (state variables: $(join(state_variables, ", ")))"

    return ESMError(
        EQUATION_UNKNOWN_IMBALANCE,
        message,
        SEV_ERROR;
        path="/models[name='$model_name']",
        context=context,
        fix_suggestions=suggestions
    )
end

"""
    create_undefined_reference_error(reference, available_variables=String[], scope_path="")

Create undefined reference error with smart suggestions.
"""
function create_undefined_reference_error(reference::String, available_variables::Vector{String}=String[],
                                        scope_path::String="")
    context = ErrorContext(operation="reference_resolution")

    suggestions = FixSuggestion[]

    # Smart suggestions based on available variables
    if !isempty(available_variables)
        # Find close matches using simple string similarity
        close_matches = String[]
        ref_lower = lowercase(reference)
        for var in available_variables
            if occursin(lowercase(var), ref_lower) || occursin(ref_lower, lowercase(var))
                push!(close_matches, var)
            end
        end

        if !isempty(close_matches)
            push!(suggestions, FixSuggestion(
                "Did you mean: $(join(close_matches[1:min(3, end)], ", "))?";
                code_example="reference = \"$(close_matches[1])\"",
                priority=1
            ))
        end
    end

    push!(suggestions, FixSuggestion(
        "Check variable names and scopes for typos";
        priority=2
    ))
    push!(suggestions, FixSuggestion(
        "Ensure the variable is declared in the correct scope";
        documentation_link="https://docs.earthsciml.org/esm-format/scoping/",
        priority=3
    ))

    debug_info = Dict{String, Any}(
        "reference" => reference,
        "scope_path" => scope_path,
        "available_variables" => available_variables
    )

    return ESMError(
        UNDEFINED_REFERENCE,
        "Reference '$reference' is not defined in the current scope",
        SEV_ERROR;
        path=scope_path,
        context=context,
        fix_suggestions=suggestions,
        debug_info=debug_info
    )
end

"""
    create_performance_warning(operation, duration, threshold=1.0)

Create performance warning with optimization suggestions.
"""
function create_performance_warning(operation::String, duration::Float64, threshold::Float64=1.0)
    context = ErrorContext(
        operation=operation,
        performance_metrics=Dict("duration_seconds" => duration, "threshold_seconds" => threshold)
    )

    suggestions = [
        FixSuggestion(
            "Consider simplifying complex expressions";
            priority=1
        ),
        FixSuggestion(
            "Check for inefficient coupling patterns";
            documentation_link="https://docs.earthsciml.org/esm-format/performance/",
            priority=2
        ),
        FixSuggestion(
            "Use performance profiling tools to identify bottlenecks";
            code_example="using EarthSciSerialization: get_profiler, start_timer!, end_timer!",
            priority=3
        )
    ]

    return ESMError(
        LARGE_SYSTEM_WARNING,
        "Operation '$operation' took $(round(duration, digits=2))s (threshold: $(round(threshold, digits=2))s)",
        WARNING;
        context=context,
        fix_suggestions=suggestions
    )
end

end # module ESMErrorFactory

"""
    ProfiledOperation

Macro for profiling ESM operations.
"""
macro profile_operation(operation_name, expr)
    quote
        local profiler = get_profiler()
        start_timer!(profiler, $operation_name)
        local result = try
            $expr
        finally
            duration = end_timer!(profiler, $operation_name)
            # Create performance warning if operation is slow
            if duration > 1.0  # 1 second threshold
                warning = ESMErrorFactory.create_performance_warning($operation_name, duration, 1.0)
                # Could emit warning to global error collector if needed
                @warn format_user_friendly(warning)
            end
        end
        result
    end
end

"""
    InteractiveErrorExplorer

Interactive tools for exploring and understanding errors.
"""
module InteractiveErrorExplorer

"""
    analyze_coupling_issues(esm_file, error_collector)

Analyze coupling-related issues and provide debugging info.
"""
function analyze_coupling_issues(esm_file, error_collector)
    analysis = Dict{String, Any}(
        "coupling_graph_valid" => true,
        "circular_dependencies" => String[],
        "orphaned_components" => String[],
        "complex_coupling_paths" => String[],
        "suggestions" => String[]
    )

    try
        # Check for orphaned components
        all_components = Set{String}()
        coupled_components = Set{String}()

        for model in esm_file.models
            push!(all_components, model.name)
        end
        for rs in esm_file.reaction_systems
            push!(all_components, rs.name)
        end

        for coupling in esm_file.couplings
            push!(coupled_components, coupling.source_model)
            push!(coupled_components, coupling.target_model)
        end

        orphaned = setdiff(all_components, coupled_components)
        if !isempty(orphaned)
            analysis["orphaned_components"] = collect(orphaned)
            push!(analysis["suggestions"], "Consider adding coupling entries for isolated components")
        end

    catch e
        analysis["coupling_graph_valid"] = false
        analysis["error"] = string(e)
    end

    return analysis
end

"""
    suggest_model_improvements(esm_file, errors)

Suggest improvements based on error patterns.
"""
function suggest_model_improvements(esm_file, errors)
    suggestions = String[]

    # Analyze error patterns
    error_codes = [error.code for error in errors]

    if EQUATION_UNKNOWN_IMBALANCE in error_codes
        push!(suggestions, "Review mathematical formulation - ensure ODEs are properly balanced")
    end

    if UNDEFINED_REFERENCE in error_codes
        push!(suggestions, "Check variable scoping and naming conventions")
    end

    if UNIT_MISMATCH in error_codes
        push!(suggestions, "Ensure dimensional consistency across equations")
    end

    # Check for complexity indicators
    total_equations = sum(length(model.equations) for model in esm_file.models)
    total_variables = sum(length(model.variables) for model in esm_file.models)

    if total_equations > 100
        push!(suggestions, "Consider modularizing large models into smaller components")
    end

    if length(esm_file.couplings) > 20
        push!(suggestions, "Review coupling architecture for potential simplification")
    end

    return suggestions
end

end # module InteractiveErrorExplorer

# Export main components
export ErrorCode, Severity, ErrorContext, FixSuggestion, ESMError,
       ErrorCollector, add_error!, has_errors, has_warnings, get_summary,
       format_user_friendly, PerformanceProfiler, get_profiler,
       start_timer!, end_timer!, get_performance_report,
       ESMErrorFactory, @profile_operation, InteractiveErrorExplorer