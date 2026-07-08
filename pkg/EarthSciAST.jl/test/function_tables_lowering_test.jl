# Bit-equivalent table_lookup → interp.* lowering harness (esm-lhm).
#
# For each conformance fixture under tests/conformance/function_tables/,
# load the file, walk the model equations, lower every table_lookup node
# to the structurally-equivalent inline-`const` interp.linear / interp.bilinear
# invocation prescribed by esm-spec §9.5.3, and assert IEEE-754 binary64
# agreement with the equivalent hand-written inline-`const` lookup at the
# §9.2 tolerance contract (abs: 0, rel: 0, non-FMA reference path).
#
# Both arms drive the same `evaluate_closed_function`; the harness catches
# lowering-side mistakes (wrong output slice, swapped axis order, dropped
# input expression) by computing the reference value from the raw
# `function_tables` block independently of the parsed table_lookup node.

using Test
using EarthSciAST
using EarthSciAST: evaluate_closed_function, OpExpr, NumExpr,
    IntExpr, VarExpr

const FUNCTION_TABLES_FIXTURES_ROOT = abspath(joinpath(@__DIR__, "..", "..", "..",
    "tests", "conformance", "function_tables"))

bit_eq(a::Float64, b::Float64)::Bool = reinterpret(UInt64, a) == reinterpret(UInt64, b)

resolve_axis_value(e::NumExpr, vars) = Float64(e.value)
resolve_axis_value(e::IntExpr, vars) = Float64(e.value)
function resolve_axis_value(e::VarExpr, vars)
    var = vars[e.name]
    @assert var.default !== nothing "variable $(e.name) has no default"
    Float64(var.default)
end
resolve_axis_value(e::OpExpr, _) =
    error("complex axis input expression not exercised: $(e.op)")

function resolve_output_index(node::OpExpr, outputs)
    out = node.output
    out === nothing && return 1  # 1-based for Julia
    if out isa Integer
        return Int(out) + 1  # convert 0-based wire index to 1-based
    elseif out isa AbstractString
        @assert outputs !== nothing "string output requires table.outputs"
        idx = findfirst(==(String(out)), outputs)
        @assert idx !== nothing "output name $out not in $outputs"
        return idx
    end
    error("table_lookup.output must be int or string, got $(typeof(out))")
end

slice_1d(data, idx, has_outputs) =
    Float64.(has_outputs ? data[idx] : data)

slice_2d(data, idx, has_outputs) =
    [Float64.(row) for row in (has_outputs ? data[idx] : data)]

function lower_and_evaluate(node::OpExpr, file, vars)
    @test node.op == "table_lookup"
    @test isempty(node.args)
    table = file.function_tables[node.table]
    kind = something(table.interpolation, "linear")
    out_idx = resolve_output_index(node, table.outputs)
    has_outputs = table.outputs !== nothing
    axes_map = node.table_axes::Dict{String,<:Any}

    if kind == "linear" && length(table.axes) == 1
        axis = table.axes[1]
        slice = slice_1d(table.data, out_idx, has_outputs)
        x = resolve_axis_value(axes_map[axis.name], vars)
        return Float64(evaluate_closed_function("interp.linear",
            Any[slice, Float64.(axis.values), x]))
    elseif kind == "bilinear" && length(table.axes) == 2
        ax = table.axes[1]; ay = table.axes[2]
        slice = slice_2d(table.data, out_idx, has_outputs)
        x = resolve_axis_value(axes_map[ax.name], vars)
        y = resolve_axis_value(axes_map[ay.name], vars)
        return Float64(evaluate_closed_function("interp.bilinear",
            Any[slice, Float64.(ax.values), Float64.(ay.values), x, y]))
    end
    error("unsupported lowering: kind=$kind axes=$(length(table.axes))")
end

function reference_inline_const(table_id::String, output, output_idx_int,
                                axis_inputs::Vector, file, vars)
    table = file.function_tables[table_id]
    has_outputs = table.outputs !== nothing
    if output !== nothing
        idx = findfirst(==(output), table.outputs)
        @assert idx !== nothing
    elseif output_idx_int !== nothing
        idx = output_idx_int + 1
    else
        idx = 1
    end
    kind = something(table.interpolation, "linear")
    if kind == "linear"
        axis = table.axes[1]
        ax_name, var_name = axis_inputs[1]
        @test ax_name == axis.name
        slice = slice_1d(table.data, idx, has_outputs)
        x = Float64(vars[var_name].default)
        return Float64(evaluate_closed_function("interp.linear",
            Any[slice, Float64.(axis.values), x]))
    elseif kind == "bilinear"
        ax = table.axes[1]; ay = table.axes[2]
        (axn0, vn0), (axn1, vn1) = axis_inputs[1], axis_inputs[2]
        @test axn0 == ax.name
        @test axn1 == ay.name
        slice = slice_2d(table.data, idx, has_outputs)
        return Float64(evaluate_closed_function("interp.bilinear",
            Any[slice, Float64.(ax.values), Float64.(ay.values),
                Float64(vars[vn0].default), Float64(vars[vn1].default)]))
    end
    error("unsupported reference kind: $kind")
end

@testset "table_lookup → interp.* lowering bit-equivalence (esm-spec §9.5.3)" begin
    @testset "linear fixture" begin
        path = joinpath(FUNCTION_TABLES_FIXTURES_ROOT, "linear", "fixture.esm")
        file = EarthSciAST.load(path)
        model = file.models["M"]
        vars = model.variables

        node = model.equations[1].rhs::OpExpr
        lowered = lower_and_evaluate(node, file, vars)
        reference = reference_inline_const("sigma_O3_298", nothing, nothing,
            [("lambda_idx", "lambda")], file, vars)
        @test bit_eq(lowered, reference)

        # Sanity: lambda=4.5 → interval [4,5], w=0.5
        expected = 8.7e-18 + 0.5 * (7.9e-18 - 8.7e-18)
        @test bit_eq(lowered, expected)
    end

    @testset "bilinear fixture" begin
        path = joinpath(FUNCTION_TABLES_FIXTURES_ROOT, "bilinear", "fixture.esm")
        file = EarthSciAST.load(path)
        model = file.models["M"]
        vars = model.variables

        node0 = model.equations[1].rhs::OpExpr
        lowered0 = lower_and_evaluate(node0, file, vars)
        reference0 = reference_inline_const("F_actinic", "NO2", nothing,
            [("P", "P_atm"), ("cos_sza", "cos_sza")], file, vars)
        @test bit_eq(lowered0, reference0)

        node1 = model.equations[2].rhs::OpExpr
        lowered1 = lower_and_evaluate(node1, file, vars)
        reference1 = reference_inline_const("F_actinic", nothing, 1,
            [("P", "P_atm"), ("cos_sza", "cos_sza")], file, vars)
        @test bit_eq(lowered1, reference1)

        @test lowered0 == 1.6
        @test lowered1 == 2.6
    end

    @testset "roundtrip fixture (table_lookup vs. inline-const companion)" begin
        path = joinpath(FUNCTION_TABLES_FIXTURES_ROOT, "roundtrip", "fixture.esm")
        file = EarthSciAST.load(path)
        model = file.models["M"]
        vars = model.variables

        node = model.equations[1].rhs::OpExpr
        lowered = lower_and_evaluate(node, file, vars)

        inline = model.equations[2].rhs::OpExpr
        @test inline.op == "fn"
        @test inline.name == "interp.linear"
        table_arg = inline.args[1]::OpExpr
        axis_arg = inline.args[2]::OpExpr
        @test table_arg.op == "const"
        @test axis_arg.op == "const"
        x = resolve_axis_value(inline.args[3], vars)
        inline_val = Float64(evaluate_closed_function("interp.linear",
            Any[Float64.(table_arg.value), Float64.(axis_arg.value), x]))
        @test bit_eq(lowered, inline_val)
    end
end
