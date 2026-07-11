# Round-trip regression tests (audit fixes):
#
# 1. OpExpr field ↔ wire-key exhaustiveness: `fieldnames(OpExpr)` must be
#    exactly covered by the parse-side key table (`OPEXPR_WIRE_KEYS`), the
#    `reconstruct(::OpExpr)` kwargs, and `serialize_expression`'s emitted
#    keys — adding a struct field without updating every site fails here.
# 2. Schema `functional_affect` handler descriptors round-trip verbatim
#    (they previously degraded into a bogus `{lhs: handler_id, rhs: 0.0}`
#    affect equation).
# 3. Non-string categorical `index_sets` members round-trip with their
#    original JSON types (previously re-emitted stringified).

using Test
using JSON3
using EarthSciAST
const ESM = EarthSciAST

@testset "OpExpr wire contract exhaustiveness" begin
    wire = ESM.OPEXPR_WIRE_KEYS
    fields = Set(fieldnames(OpExpr))

    # `join_gates` is the single internal (never-serialized) field; everything
    # else must appear in the wire-key table.
    @test Set(keys(wire)) == setdiff(fields, Set([:join_gates]))

    # reconstruct(::OpExpr) must offer a kwarg for EVERY field (including the
    # internal join_gates) so structural rewrites can't silently drop one.
    m = only(methods(ESM.reconstruct, (OpExpr,)))
    kwnames = Set(filter(n -> !occursin("#", String(n)), Base.kwarg_decl(m)))
    @test kwnames == fields

    # Per-field parse + serialize coverage. Each spec is
    # (field, json, expected-parsed-value, construction op/args/kwargs).
    # The spec list itself must cover every wire field (op/args are structural
    # and always present; join_gates is internal).
    E(x...) = ESM.ASTExpr[x...]
    specs = [
        (field = :wrt,
         json = """{"op":"D","args":["x"],"wrt":"t"}""",
         expected = "t",
         cop = "D", cargs = E(VarExpr("x")), kw = (wrt = "t",)),
        (field = :dim,
         json = """{"op":"grad","args":["u"],"dim":"x"}""",
         expected = "x",
         cop = "grad", cargs = E(VarExpr("u")), kw = (dim = "x",)),
        (field = :int_var,
         json = """{"op":"integral","args":["f"],"var":"s","lower":0.5,"upper":1.5}""",
         expected = "s",
         cop = "integral", cargs = E(VarExpr("f")), kw = (int_var = "s",)),
        (field = :lower,
         json = """{"op":"integral","args":["f"],"var":"s","lower":0.5,"upper":1.5}""",
         expected = NumExpr(0.5),
         cop = "integral", cargs = E(VarExpr("f")), kw = (lower = NumExpr(0.5),)),
        (field = :upper,
         json = """{"op":"integral","args":["f"],"var":"s","lower":0.5,"upper":1.5}""",
         expected = NumExpr(1.5),
         cop = "integral", cargs = E(VarExpr("f")), kw = (upper = NumExpr(1.5),)),
        (field = :output_idx,
         json = """{"op":"arrayop","args":[],"output_idx":["i",1]}""",
         expected = Any["i", 1],
         cop = "arrayop", cargs = E(), kw = (output_idx = Any["i", 1],)),
        (field = :expr_body,
         json = """{"op":"arrayop","args":[],"expr":2.5}""",
         expected = NumExpr(2.5),
         cop = "arrayop", cargs = E(), kw = (expr_body = NumExpr(2.5),)),
        (field = :reduce,
         json = """{"op":"aggregate","args":[],"reduce":"max"}""",
         expected = "max",
         cop = "aggregate", cargs = E(), kw = (reduce = "max",)),
        (field = :semiring,
         json = """{"op":"aggregate","args":[],"semiring":"max_product"}""",
         expected = "max_product",
         cop = "aggregate", cargs = E(), kw = (semiring = "max_product",)),
        (field = :ranges,
         json = """{"op":"arrayop","args":[],"ranges":{"i":[1,4]}}""",
         expected = Dict{String,Any}("i" => Any[1, 4]),
         cop = "arrayop", cargs = E(),
         kw = (ranges = Dict{String,Any}("i" => Any[1, 4]),)),
        (field = :regions,
         json = """{"op":"makearray","args":[],"regions":[[[1,2]]]}""",
         expected = [[[1, 2]]],
         cop = "makearray", cargs = E(),
         kw = (regions = Vector{Vector{Vector{Int}}}([[[1, 2]]]),)),
        (field = :values,
         json = """{"op":"makearray","args":[],"values":[1.5]}""",
         expected = E(NumExpr(1.5)),
         cop = "makearray", cargs = E(), kw = (values = E(NumExpr(1.5)),)),
        (field = :shape,
         json = """{"op":"reshape","args":["u"],"shape":[2,"n"]}""",
         expected = Any[2, "n"],
         cop = "reshape", cargs = E(VarExpr("u")), kw = (shape = Any[2, "n"],)),
        (field = :perm,
         json = """{"op":"transpose","args":["u"],"perm":[1,0]}""",
         expected = [1, 0],
         cop = "transpose", cargs = E(VarExpr("u")), kw = (perm = [1, 0],)),
        (field = :axis,
         json = """{"op":"concat","args":["u","v"],"axis":0}""",
         expected = 0,
         cop = "concat", cargs = E(VarExpr("u"), VarExpr("v")), kw = (axis = 0,)),
        (field = :fn,
         json = """{"op":"broadcast","args":["u"],"fn":"exp"}""",
         expected = "exp",
         cop = "broadcast", cargs = E(VarExpr("u")), kw = (fn = "exp",)),
        (field = :name,
         json = """{"op":"fn","args":[1.5],"name":"interp.linear"}""",
         expected = "interp.linear",
         cop = "fn", cargs = E(NumExpr(1.5)), kw = (name = "interp.linear",)),
        (field = :value,
         json = """{"op":"const","args":[],"value":[1,2]}""",
         expected = Any[1, 2],
         cop = "const", cargs = E(), kw = (value = Any[1, 2],)),
        (field = :table,
         json = """{"op":"table_lookup","args":[],"table":"T","axes":{"x":2.5}}""",
         expected = "T",
         cop = "table_lookup", cargs = E(), kw = (table = "T",)),
        (field = :table_axes,
         json = """{"op":"table_lookup","args":[],"table":"T","axes":{"x":2.5}}""",
         expected = Dict{String,ESM.ASTExpr}("x" => NumExpr(2.5)),
         cop = "table_lookup", cargs = E(),
         kw = (table_axes = Dict{String,ESM.ASTExpr}("x" => NumExpr(2.5)),)),
        (field = :output,
         json = """{"op":"table_lookup","args":[],"table":"T","axes":{"x":2.5},"output":"a"}""",
         expected = "a",
         cop = "table_lookup", cargs = E(), kw = (output = "a",)),
        (field = :join,
         json = """{"op":"aggregate","args":[],"join":[{"on":[["a","b"]]}]}""",
         expected = Any[[("a", "b")]],
         cop = "aggregate", cargs = E(), kw = (join = Any[[("a", "b")]],)),
        (field = :filter,
         json = """{"op":"aggregate","args":[],"filter":{"op":">","args":["i",1]}}""",
         expected = OpExpr(">", E(VarExpr("i"), IntExpr(1))),
         cop = "aggregate", cargs = E(),
         kw = (filter = OpExpr(">", E(VarExpr("i"), IntExpr(1))),)),
        (field = :id,
         json = """{"op":"aggregate","args":[],"id":"n1"}""",
         expected = "n1",
         cop = "aggregate", cargs = E(), kw = (id = "n1",)),
        (field = :manifold,
         json = """{"op":"intersect_polygon","args":[],"manifold":"planar"}""",
         expected = "planar",
         cop = "intersect_polygon", cargs = E(), kw = (manifold = "planar",)),
        (field = :distinct,
         json = """{"op":"aggregate","args":[],"distinct":true}""",
         expected = true,
         cop = "aggregate", cargs = E(), kw = (distinct = true,)),
        (field = :key,
         json = """{"op":"aggregate","args":[],"key":{"op":"skolem","args":["i"]}}""",
         expected = OpExpr("skolem", E(VarExpr("i"))),
         cop = "aggregate", cargs = E(),
         kw = (key = OpExpr("skolem", E(VarExpr("i"))),)),
        (field = :arg,
         json = """{"op":"argmin","args":[],"arg":"g"}""",
         expected = "g",
         cop = "argmin", cargs = E(), kw = (arg = "g",)),
        (field = :bindings,
         json = """{"op":"aggregate","args":[],"bindings":{"f":"u"}}""",
         expected = Dict{String,ESM.ASTExpr}("f" => VarExpr("u")),
         cop = "aggregate", cargs = E(),
         kw = (bindings = Dict{String,ESM.ASTExpr}("f" => VarExpr("u")),)),
    ]

    # The spec list must cover every field except op/args (structural) and
    # join_gates (internal). A newly added OpExpr field fails this until a
    # spec — i.e. real parse + serialize behavior — exists for it.
    @test Set(s.field for s in specs) == setdiff(fields, Set([:op, :args, :join_gates]))

    # Structural expression equality (OpExpr has no field-wise `==`; compare
    # via the serialized wire form, which the specs above pin field-by-field).
    exprs_equal(a, b) = ESM.serialize_expression(a) == ESM.serialize_expression(b)

    for s in specs
        @testset "$(s.field)" begin
            raw = JSON3.read(s.json)

            # Parse side: the field is recovered from the wire key — via BOTH
            # dict-like carriers (JSON3.Object and native Dict).
            for carrier in (raw, ESM._to_native_json(raw))
                parsed = parse_expression(carrier)
                got = getfield(parsed, s.field)
                if s.expected isa ESM.ASTExpr
                    @test got isa ESM.ASTExpr && exprs_equal(got, s.expected)
                elseif s.expected isa AbstractDict &&
                       !isempty(s.expected) && first(values(s.expected)) isa ESM.ASTExpr
                    @test got isa AbstractDict && keys(got) == keys(s.expected)
                    @test all(exprs_equal(got[k], s.expected[k]) for k in keys(s.expected))
                elseif s.expected isa AbstractVector && !isempty(s.expected) &&
                       first(s.expected) isa ESM.ASTExpr
                    @test length(got) == length(s.expected)
                    @test all(exprs_equal(g, e) for (g, e) in zip(got, s.expected))
                else
                    @test got == s.expected
                end
            end

            # Serialize side: constructing an OpExpr with ONLY this field set
            # emits exactly {op, args, <wire key>}.
            node = OpExpr(s.cop, s.cargs; NamedTuple{keys(s.kw)}(values(s.kw))...)
            emitted = ESM.serialize_expression(node)
            @test Set(keys(emitted)) == Set(["op", "args", string(getproperty(wire, s.field))])

            # Full wire round trip: parse(json) → serialize == the original
            # JSON value (all keys, not just this field).
            @test ESM.serialize_expression(parse_expression(raw)) == ESM._to_native_json(raw)
        end
    end
end

@testset "functional_affect handler descriptor round trip" begin
    doc = """
    {
      "esm": "0.8.0",
      "metadata": { "name": "fa_round_trip" },
      "models": {
        "M": {
          "variables": {
            "x": { "type": "state", "default": 1.5 },
            "K": { "type": "parameter", "default": 2.5 }
          },
          "equations": [
            { "lhs": { "op": "D", "args": ["x"], "wrt": "t" },
              "rhs": { "op": "*", "args": [-0.5, "x"] } }
          ],
          "discrete_events": [
            {
              "trigger": { "type": "periodic", "interval": 3600.5 },
              "functional_affect": {
                "handler_id": "hourly_update",
                "read_vars": ["x"],
                "read_params": ["K"],
                "modified_params": ["K"],
                "config": { "factor": 1.5 }
              }
            },
            {
              "trigger": { "type": "preset_times", "times": [1.5, 2.5] },
              "affects": [ { "lhs": "x", "rhs": 0.5 } ]
            }
          ]
        }
      }
    }
    """
    file = load(IOBuffer(doc))
    events = file.models["M"].discrete_events
    @test length(events) == 2

    # The handler descriptor is preserved verbatim on the typed event, and no
    # placeholder affect equation is invented for it.
    fa_event = events[1]
    @test isempty(fa_event.affects)
    @test fa_event.functional_affect isa Dict{String,Any}
    @test fa_event.functional_affect["handler_id"] == "hourly_update"
    @test fa_event.functional_affect["read_vars"] == ["x"]
    @test fa_event.functional_affect["read_params"] == ["K"]
    @test fa_event.functional_affect["modified_params"] == ["K"]
    @test fa_event.functional_affect["config"]["factor"] == 1.5

    # A symbolic-affect event has no descriptor.
    @test events[2].functional_affect === nothing
    @test length(events[2].affects) == 1

    # Serialize: the handler event re-emits `functional_affect` (and no bogus
    # {lhs: handler_id, rhs: 0.0} affects); the symbolic event emits affects.
    buf = IOBuffer()
    save(file, buf)
    first_bytes = String(take!(buf))
    out = JSON3.read(first_bytes)
    ev1, ev2 = out.models.M.discrete_events
    @test !haskey(ev1, :affects)
    @test ev1.functional_affect.handler_id == "hourly_update"
    @test ev1.functional_affect.config.factor == 1.5
    @test !haskey(ev2, :functional_affect)
    @test ev2.affects[1].lhs == "x"

    # Idempotence: the saved form reloads and re-saves byte-equivalently
    # (parsed-JSON equality, matching the conformance round-trip contract).
    reloaded = load(IOBuffer(first_bytes))
    buf2 = IOBuffer()
    save(reloaded, buf2)
    @test JSON3.read(String(take!(buf2))) == out

    # A hand-built event carrying BOTH affects and a descriptor violates the
    # schema oneOf and is refused at serialize time.
    bad = DiscreteEvent(
        PeriodicTrigger(1.5),
        [FunctionalAffect("x", NumExpr(0.5))];
        functional_affect = Dict{String,Any}("handler_id" => "h",
                                             "read_vars" => Any[],
                                             "read_params" => Any[]),
    )
    @test_throws ArgumentError ESM.serialize_discrete_event(bad)
end

@testset "index_sets non-string members round trip (members_raw)" begin
    doc = """
    {
      "esm": "0.8.0",
      "metadata": { "name": "members_raw_round_trip" },
      "index_sets": {
        "fips": { "kind": "categorical", "members": [8031, 8005, 8059] },
        "fuel": { "kind": "categorical", "members": ["grass", "shrub"] }
      },
      "models": {
        "M": {
          "variables": { "x": { "type": "state", "default": 1.5 } },
          "equations": [
            { "lhs": { "op": "D", "args": ["x"], "wrt": "t" }, "rhs": 0.5 }
          ]
        }
      }
    }
    """
    file = load(IOBuffer(doc))

    fips = file.index_sets["fips"]
    @test fips.members == ["8031", "8005", "8059"]  # stringified convenience view
    @test fips.members_raw == Any[8031, 8005, 8059]  # original types retained

    fuel = file.index_sets["fuel"]
    @test fuel.members == ["grass", "shrub"]
    @test fuel.members_raw === nothing  # string-only sets stay as before

    # Serialize: integer members re-emit as integers, not strings.
    out = ESM.serialize_esm_file(file)
    @test out["index_sets"]["fips"]["members"] == Any[8031, 8005, 8059]
    @test out["index_sets"]["fuel"]["members"] == ["grass", "shrub"]

    # Full save → load: the reloaded registry deep-equals the original
    # (this previously failed: members came back as strings).
    buf = IOBuffer()
    save(file, buf)
    reloaded = load(IOBuffer(String(take!(buf))))
    @test reloaded.index_sets["fips"].members_raw == Any[8031, 8005, 8059]
    @test ESM._index_set_deep_equal(reloaded.index_sets["fips"], fips)
    @test ESM._index_set_deep_equal(reloaded.index_sets["fuel"], fuel)
end
