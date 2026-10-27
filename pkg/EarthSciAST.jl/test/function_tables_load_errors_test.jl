# esm-spec §9.5.5 load-time table checks in their pinned order, driven from the
# shared ledger `tests/conformance/function_tables/load_errors/cases.json`.
#
# Each case is one function table (id `T`) and one `table_lookup` node. The
# table is built IN MEMORY (the ledger's string "NaN" is a binary64 NaN; JSON
# cannot carry one, and the schema would refuse the one-value and empty axes),
# the lookup is parsed by the binding's own expression parser and lowered
# through the real §9.5.3 lowering, and the `TableLookupError` code is compared
# with `expected_error_code` (`nothing` = the lookup lowers). Julia's table
# `data` is a nested `Vector{Any}` of numbers, which holds a NaN, so no case is
# skipped.

using Test
using EarthSciAST
using JSON3

const _FTLE_LEDGER = abspath(joinpath(@__DIR__, "..", "..", "..",
    "tests", "conformance", "function_tables", "load_errors", "cases.json"))

_ftle_num(v) = v isa AbstractString ?
    (v == "NaN" ? NaN : error("unrecognized string leaf `$(v)` in the ledger")) : v
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
            node = EarthSciAST.expression_from_json(
                JSON3.read(JSON3.write(c.lookup), Dict{String,Any}))
            code = try
                EarthSciAST._lower_expr_table_lookups(node, tables)
                nothing
            catch err
                err isa EarthSciAST.TableLookupError || rethrow()
                err.code
            end
            expected = c.expected_error_code === nothing ? nothing :
                       String(c.expected_error_code)
            @test code == expected
        end
    end
    # Every pinned rule is exercised by at least one case.
    @test length(seen) == length(cases)
    codes = Set(String(c.expected_error_code) for c in cases
                if c.expected_error_code !== nothing)
    for rule in ledger.order
        @test first(split(String(rule), " ")) in codes
    end
end
