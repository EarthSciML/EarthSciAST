"""
`validate_schema` walks the schema itself (`_schema_walk!` in src/validate.jl)
rather than calling JSONSchema.jl's whole-subschema `_validate`, and decides
every `oneOf`/`anyOf`/`if` branch with that walk. These tests pin the walk's
match verdict to the library's, so a change on either side that makes them
disagree fails here rather than as a shifted branch choice downstream.
"""

using Test
using EarthSciAST
using JSON3

include("testutils.jl")

const _EA = EarthSciAST
const _JS = EarthSciAST.JSONSchema

_library_verdict(x, schema) = _JS._validate(x, schema, _EA._jsonschema_root_path()) === nothing
_walk_verdict(x, node) = _EA._schema_matches(x, node, _EA._jsonschema_root_path())

# Every value in a JSON tree, the root included.
function _json_values!(out, x)
    push!(out, x)
    x isa AbstractDict && foreach(v -> _json_values!(out, v), values(x))
    x isa AbstractVector && foreach(v -> _json_values!(out, v), x)
    return out
end

@testset "Schema walk matches JSONSchema.jl" begin

    @testset "fixture corpus, whole documents and every \$defs entry" begin
        schema = _EA.ESM_SCHEMA.data
        root = _EA._compiled_schema(schema)
        defs = schema["\$defs"]
        seen = IdDict{Any, _EA._SchemaNode}()
        def_nodes = [(name, defs[name], _EA._compile_schema(defs[name], seen)) for name in sort!(collect(keys(defs)))]

        files = String[]
        for dir in ("valid", "invalid"), (d, _, fs) in walkdir(joinpath(TESTUTILS_REPO_ROOT, "tests", dir))
            append!(files, joinpath(d, f) for f in fs if endswith(f, ".esm") || endswith(f, ".json"))
        end
        sort!(files)
        @test !isempty(files)

        ndocs = 0
        npairs = 0
        mismatches = String[]
        for f in files
            raw = try
                _EA._to_native_json(JSON3.read(read(f, String)))
            catch
                continue    # not JSON at all: nothing for a schema to judge
            end
            ndocs += 1
            lib = _library_verdict(raw, schema)
            _walk_verdict(raw, root) == lib || push!(mismatches, "$f: document")
            isempty(validate_schema(raw)) == lib || push!(mismatches, "$f: validate_schema")
            # Every sub-value against every definition: the same (instance,
            # subschema) pairs a combinator branch is decided on, failing ones
            # included. A spread of at most 40 values per file keeps it quick.
            vals = _json_values!(Any[], raw)
            step = max(1, length(vals) ÷ 40)
            for y in vals[1:step:end], (name, def, node) in def_nodes
                npairs += 1
                _walk_verdict(y, node) == _library_verdict(y, def) ||
                    push!(mismatches, "$f: \$defs/$name on $(repr(y)[1:min(end, 80)])")
            end
        end
        @test ndocs > 300
        @test npairs > 100_000
        @test isempty(mismatches)
        isempty(mismatches) || foreach(m -> @info(m), first(mismatches, 20))
    end

    # Applicators the walk handles that the ESM schema uses rarely or not at
    # all, each against instances that pass and fail it.
    @testset "applicator semantics" begin
        cases = [
            (
                """{"patternProperties": {"^x_": {"type": "number"}}, "additionalProperties": {"type": "string"}, "properties": {"id": {"type": "boolean"}}}""",
                [Dict("x_a" => 1, "b" => "s", "id" => true), Dict("x_a" => "no"), Dict("b" => 2), Dict("id" => 1), Dict{String, Any}()],
            ),
            (
                """{"properties": {"a": {}}, "patternProperties": {"^p": true}, "additionalProperties": false}""",
                [Dict("a" => 1, "pq" => 2), Dict("a" => 1, "z" => 2), Dict{String, Any}(), 3],
            ),
            (
                """{"propertyNames": {"pattern": "^[a-z]+\$", "maxLength": 3}}""",
                [Dict("abc" => 1), Dict("abcd" => 1), Dict("A" => 1), "not an object"],
            ),
            (
                """{"contains": {"type": "string"}}""",
                [Any[1, "a"], Any[1, 2], Any[], "x"],
            ),
            (
                """{"if": {"type": "number"}, "then": {"minimum": 0}, "else": {"type": "string"}}""",
                [1, -1, "s", true],
            ),
            (
                """{"if": {"type": "number"}, "else": {"type": "string"}}""",
                [-1, "s", true],
            ),
            (
                """{"anyOf": [{"type": "number"}, {"type": "string"}], "not": {"const": 3}}""",
                [1, 3, "s", nothing],
            ),
            (
                """{"oneOf": [{"type": "number"}, {"type": "integer"}, {"type": "string"}]}""",
                [1.5, 1, "s", nothing],
            ),
            (
                """{"items": {"type": "integer"}, "allOf": [{"minItems": 1}, {"maxItems": 2}]}""",
                [Any[1], Any[1, 2, 3], Any[1.5], Any[]],
            ),
            (
                """{"items": [{"type": "integer"}], "additionalItems": false}""",
                [Any[1], Any[1, 2], Any["a"]],
            ),
            (
                """{"\$defs": {"T": {"type": "object", "properties": {"next": {"\$ref": "#/\$defs/T"}}}}, "\$ref": "#/\$defs/T"}""",
                [Dict("next" => Dict("next" => Dict{String, Any}())), Dict("next" => Dict("next" => 1))],
            ),
            (
                "false",
                [1, Dict{String, Any}()],
            ),
        ]
        for (text, instances) in cases
            schema = _JS.Schema(text).data
            node = _EA._compile_schema(schema, IdDict{Any, _EA._SchemaNode}())
            for x in instances
                @test _walk_verdict(x, node) == _library_verdict(x, schema)
            end
        end
    end

    # A `pattern` is compiled when a string is first checked against it, as
    # the library compiles it, so one PCRE rejects only fails where the
    # library's would.
    @testset "pattern compiled on first use" begin
        schema = _JS.Schema("""{"pattern": "(unclosed"}""").data
        node = _EA._compile_schema(schema, IdDict{Any, _EA._SchemaNode}())
        @test _walk_verdict(1, node) == _library_verdict(1, schema) == true
        @test_throws ErrorException _walk_verdict("s", node)
        @test_throws ErrorException _library_verdict("s", schema)
    end
end
