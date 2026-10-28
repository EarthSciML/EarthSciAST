# esm-spec §9.5.5 load-time table checks in their pinned order, driven from the
# shared ledger `tests/conformance/function_tables/load_errors/cases.json`.
#
# Each case is one function table (id `T`) and one `table_lookup` node. The
# table is built IN MEMORY (the ledger's strings "NaN", "Inf" and "-Inf" are
# binary64 non-finite values, which JSON cannot carry, and the schema would
# refuse the one-value and empty axes). The table goes through the SAME
# load-time table check load and `validate()` run on every `function_tables`
# entry (`_check_function_tables`, esm-spec §9.5.5 "When the table checks run"),
# and the lookup — parsed by the binding's own expression parser — through the
# real §9.5.3 lowering; both `TableLookupError` codes are compared with
# `expected_error_code` (`nothing` = the table passes and the lookup lowers).
# The cases a document can carry are `tests/invalid/function_table_*.esm`
# (`function_tables_invalid_fixtures_test` in closed_functions_test.jl). Julia's
# table `data` is a nested `Vector{Any}` of numbers, which holds a NaN, so no
# case is skipped.

using Test
using EarthSciAST
using JSON3

const _FTLE_LEDGER = abspath(joinpath(@__DIR__, "..", "..", "..",
    "tests", "conformance", "function_tables", "load_errors", "cases.json"))

_ftle_num(v) = v isa AbstractString ?
    (v == "NaN" ? NaN : v == "Inf" ? Inf : v == "-Inf" ? -Inf :
     error("unrecognized string leaf `$(v)` in the ledger")) : v
_ftle_nested(v) = v isa AbstractVector ? Any[_ftle_nested(x) for x in v] : _ftle_num(v)

function _ftle_table(t)
    axes = EarthSciAST.FunctionTableAxis[
        EarthSciAST.FunctionTableAxis(String(ax.name),
            Float64[Float64(_ftle_num(v)) for v in ax.values]) for ax in t.axes]
    get_or(k) = haskey(t, k) ? t[k] : nothing
    outputs = get_or(:outputs)
    shape = get_or(:shape)
    return EarthSciAST.FunctionTable(axes, _ftle_nested(t.data);
        interpolation=(get_or(:interpolation) === nothing ? nothing :
                       String(t.interpolation)),
        out_of_bounds=(get_or(:out_of_bounds) === nothing ? nothing :
                       String(t.out_of_bounds)),
        outputs=(outputs === nothing ? nothing : String[String(o) for o in outputs]),
        shape=(shape === nothing ? nothing : Int[Int(s) for s in shape]))
end

@testset "function_tables load-time checks, pinned order (esm-spec §9.5.5)" begin
    ledger = JSON3.read(read(_FTLE_LEDGER, String))
    cases = ledger.cases
    # A missing or empty ledger is a failure, not a vacuous pass.
    @test !isempty(cases)
    table_id = String(ledger.table_id)
    seen = Set{String}()
    for c in cases
        name = String(c.name)
        push!(seen, name)
        @testset "$(name)" begin
            tables = Dict{String,EarthSciAST.FunctionTable}(table_id => _ftle_table(c.table))
            # The parser refuses a non-empty `args` on its own (a document
            # reaches it only past the schema's `maxItems`), so the node is
            # parsed without them and they are put back in memory — the shape a
            # node built in memory has.
            raw = JSON3.read(JSON3.write(c.lookup), Dict{String,Any})
            raw_args = get(raw, "args", Any[])
            raw["args"] = Any[]
            node = EarthSciAST.expression_from_json(raw)
            append!(node.args, EarthSciAST.ASTExpr[EarthSciAST.expression_from_json(a)
                                                    for a in raw_args])
            code = try
                EarthSciAST._lower_expr_table_lookups(node, tables)
                nothing
            catch err
                err isa EarthSciAST.TableLookupError || rethrow()
                err.code
            end
            findings = EarthSciAST._check_function_tables(tables,
                EarthSciAST._LoadCheckFinding[])
            # Load runs the table checks on every table first, then the
            # lookup's own load-time checks (ruling Q-112).
            load_code = if !isempty(findings)
                findings[1][2].code
            else
                try
                    EarthSciAST._check_table_lookup_node(node, tables)
                    nothing
                catch err
                    err isa EarthSciAST.TableLookupError || rethrow()
                    err.code
                end
            end
            expected = c.expected_error_code === nothing ? nothing :
                       String(c.expected_error_code)
            @test load_code == expected
            @test code == expected
        end
    end
    # Every pinned rule is exercised by at least one case — here, or by one of
    # the documents the ledger moved to tests/invalid (whose pinned codes the
    # tests/invalid sweep in closed_functions_test.jl asserts).
    @test length(seen) == length(cases)
    codes = Set(String(c.expected_error_code) for c in cases
                if c.expected_error_code !== nothing)
    pins = JSON3.read(read(joinpath(dirname(_FTLE_LEDGER), "..", "..", "..", "invalid",
                                    "expected_errors.json"), String))
    for (_, f) in pairs(ledger.moved_to_tests_invalid)
        push!(codes, String(pins[Symbol(f)].resolver_error_code))
    end
    for rule in ledger.order
        @test first(split(String(rule), " ")) in codes
    end
end

# esm-spec §9.5.5 "Order of the lookup checks" (ruling Q-107): the table
# reference, then the named table's ten checks, then the lookup's own `args`,
# axis keys and output — so a broken table outranks every fault of the lookup.
@testset "lookup checks follow the table checks (esm-spec §9.5.5, ruling Q-107)" begin
    good = EarthSciAST.FunctionTable(
        [EarthSciAST.FunctionTableAxis("x", [0.0, 1.0])], Any[1.0, 2.0])
    bad = EarthSciAST.FunctionTable(
        [EarthSciAST.FunctionTableAxis("x", [1.0, 0.0])], Any[1.0, 2.0])
    tables = Dict("G" => good, "B" => bad)
    code(node) = try
        EarthSciAST._lower_expr_table_lookups(node, tables); nothing
    catch err
        err isa EarthSciAST.TableLookupError || rethrow()
        err.code
    end
    lk(id; args=EarthSciAST.ASTExpr[], key="x", output=nothing) =
        EarthSciAST.OpExpr("table_lookup", args; table=id, output=output,
            table_axes=Dict{String,EarthSciAST.ASTExpr}(key => EarthSciAST.VarExpr("q")))
    nonempty = EarthSciAST.ASTExpr[EarthSciAST.VarExpr("q")]
    @test code(lk("nope"; args=nonempty)) == "table_lookup_unknown_table"
    @test code(lk("B"; args=nonempty, key="y", output=5)) == "table_axis_non_monotonic"
    @test code(lk("G"; args=nonempty, key="y", output=5)) == "table_lookup_args_nonempty"
    @test code(lk("G"; key="y", output=5)) == "table_lookup_axis_name_mismatch"
    @test code(lk("G"; output=5)) == "table_lookup_output_out_of_range"
    @test code(lk("G")) === nothing
end
