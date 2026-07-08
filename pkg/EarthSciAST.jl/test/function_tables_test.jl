# Roundtrip tests for the v0.4.0 function_tables block + table_lookup AST op
# (esm-spec §9.5).

using Test
using EarthSciAST
using JSON3

const FUNCTION_TABLES_FIXTURE = """
{
  "esm": "0.4.0",
  "metadata": {"name": "ft_smoke", "authors": ["test"]},
  "function_tables": {
    "sigma_O3": {
      "description": "1-D linear table",
      "axes": [
        {"name": "lambda_idx", "values": [1, 2, 3, 4]}
      ],
      "interpolation": "linear",
      "out_of_bounds": "clamp",
      "data": [1.1e-17, 1.0e-17, 9.5e-18, 8.7e-18]
    },
    "F_actinic": {
      "axes": [
        {"name": "P", "units": "Pa", "values": [10, 100, 1000]},
        {"name": "cos_sza", "values": [0.1, 0.5, 1.0]}
      ],
      "interpolation": "bilinear",
      "outputs": ["NO2", "O3"],
      "data": [
        [[1.0, 1.5, 2.0], [1.1, 1.6, 2.1], [1.2, 1.7, 2.2]],
        [[2.0, 2.5, 3.0], [2.1, 2.6, 3.1], [2.2, 2.7, 3.2]]
      ]
    }
  },
  "models": {
    "M": {
      "variables": {
        "k_O3":   {"type": "state",     "default": 0.0},
        "j_NO2":  {"type": "state",     "default": 0.0},
        "P_atm":  {"type": "parameter", "default": 101325.0},
        "cos_sza":{"type": "parameter", "default": 0.5}
      },
      "equations": [
        {"lhs": {"op": "D", "args": ["k_O3"], "wrt": "t"}, "rhs": {
          "op": "table_lookup",
          "table": "sigma_O3",
          "axes": {"lambda_idx": 2},
          "args": []
        }},
        {"lhs": {"op": "D", "args": ["j_NO2"], "wrt": "t"}, "rhs": {
          "op": "table_lookup",
          "table": "F_actinic",
          "axes": {"P": "P_atm", "cos_sza": "cos_sza"},
          "output": "NO2",
          "args": []
        }}
      ]
    }
  }
}
"""

@testset "function_tables block + table_lookup AST op (esm-spec §9.5)" begin
    file = EarthSciAST.load(IOBuffer(FUNCTION_TABLES_FIXTURE))

    @testset "function_tables typed map" begin
        @test file.function_tables !== nothing
        @test sort(collect(keys(file.function_tables))) == ["F_actinic", "sigma_O3"]

        sig = file.function_tables["sigma_O3"]
        @test sig isa FunctionTable
        @test length(sig.axes) == 1
        @test sig.axes[1] isa FunctionTableAxis
        @test sig.axes[1].name == "lambda_idx"
        @test sig.axes[1].values == [1.0, 2.0, 3.0, 4.0]
        @test sig.interpolation == "linear"
        @test sig.out_of_bounds == "clamp"

        fa = file.function_tables["F_actinic"]
        @test length(fa.axes) == 2
        @test fa.axes[1].units == "Pa"
        @test fa.outputs == ["NO2", "O3"]
        @test fa.interpolation == "bilinear"
    end

    @testset "table_lookup AST nodes survive parse" begin
        eqs = file.models["M"].equations
        @test length(eqs) == 2
        rhs0 = eqs[1].rhs
        @test rhs0 isa OpExpr
        @test rhs0.op == "table_lookup"
        @test rhs0.table == "sigma_O3"
        @test rhs0.table_axes !== nothing
        @test haskey(rhs0.table_axes, "lambda_idx")
        @test isempty(rhs0.args)
        rhs1 = eqs[2].rhs
        @test rhs1.op == "table_lookup"
        @test rhs1.table == "F_actinic"
        @test rhs1.output == "NO2"
        @test sort(collect(keys(rhs1.table_axes))) == ["P", "cos_sza"]
    end

    @testset "round-trip preserves both blocks" begin
        out = sprint(io -> EarthSciAST.save(file, io))
        reloaded = JSON3.read(out)
        @test sort(collect(keys(reloaded.function_tables))) == [:F_actinic, :sigma_O3]
        @test reloaded.function_tables.F_actinic.outputs == ["NO2", "O3"]
        rhs0 = reloaded.models.M.equations[1].rhs
        @test rhs0.op == "table_lookup"
        @test rhs0.table == "sigma_O3"
        @test rhs0.axes.lambda_idx == 2
        rhs1 = reloaded.models.M.equations[2].rhs
        @test rhs1.op == "table_lookup"
        @test rhs1.output == "NO2"

        # Round-trip is a fixed point: re-load and re-save yields the same bytes
        # (modulo JSON3 ordering — compare structurally).
        file2 = EarthSciAST.load(IOBuffer(out))
        out2 = sprint(io -> EarthSciAST.save(file2, io))
        @test JSON3.read(out2) == JSON3.read(out)
    end
end
