# An overlap-gated conservative regrid whose SOURCE FIELD is a live forcing
# array (`param_arrays`), with the gate's envelope factors the single-name RING
# form (CONFORMANCE_SPEC §5.5.6: one `[pos, verts, coord]` factor per side) that
# every shipped `conservative_overlap_*_gated` template uses.
#
# With the source field build-time data (a default, `const_arrays`, a const
# provider) the whole regrid materializes at setup, where the ring form has
# always been read. A live field keeps the APPLY aggregate in the right-hand
# side, and its gate is then resolved by `_resolve_join_gates_for`, which used
# to (1) insist on a 1-D envelope factor (`E_TREEWALK_JOIN_OVERLAP: … must be a
# 1-D buffer …`) and (2) look the factor up only among the const arrays and
# const-op observeds, not among the setup-geometry arrays a ring built from
# parameters lands in.

module OverlapGateLiveForcingTests

using Test
using EarthSciAST
const EA = EarthSciAST

_op(o, args...) = Dict{String, Any}("op" => o, "args" => Any[args...])
_ix(f, args...) = _op("index", f, args...)
_faq(out, ranges, expr; kw...) = merge(
    Dict{String, Any}(
        "op" => "faq", "semiring" => "sum_product", "args" => Any[],
        "output_idx" => collect(out),
        "ranges" => Dict{String, Any}(k => Dict{String, Any}("from" => v) for (k, v) in ranges),
        "expr" => expr
    ),
    Dict{String, Any}(String(k) => v for (k, v) in kw)
)
const GATE = Any[Dict("overlap" => Dict("src_env" => ["src_poly"], "tgt_env" => ["tgt_poly"], "eps" => 1.0e-9))]
const IJ = ("i" => "src_cells", "j" => "tgt_cells")
const SLIVER = _op(">", _ix("A_ij", "i", "j"), "atol")

# Source cells: unit squares [0,1], [1.5,2.5], [3,4] (× [0,1]) — a RING STACK
# built from the parameter `pitch` by a faq, so it is setup geometry, not a
# const-op observed. Targets: [0,2] and [3.5,4.5] (× [0,1]). Surviving overlaps:
# (1,1) = 1, (2,1) = 0.5, (3,2) = 0.5; the other three pairs are pruned by the
# gate. So F_tgt = [(F1 + 0.5 F2) / 1.5, F3].
function document()
    ring = _op(
        "ifelse", _op("<", "k", 2),
        _op(
            "+", _op("*", _op("-", "c", 1), "pitch"),
            _op("ifelse", _op("<", "v", 2), 0.0, _op("ifelse", _op("<", "v", 4), 1.0, 0.0))
        ),
        _op("ifelse", _op("<", "v", 3), 0.0, 1.0)
    )
    return Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "overlap_gate_live_forcing"),
        "index_sets" => Dict(
            "src_cells" => Dict("kind" => "interval", "size" => 3),
            "tgt_cells" => Dict("kind" => "interval", "size" => 2),
            "verts" => Dict("kind" => "interval", "size" => 4),
            "coord" => Dict("kind" => "interval", "size" => 2)
        ),
        "data_sources" => Dict("Src" => Dict("kind" => "static", "source" => Dict("url_template" => "{unused_placeholder}"))),
        "models" => Dict(
            "M" => Dict(
                "variables" => Dict(
                    "pitch" => Dict("type" => "parameter", "units" => "1", "default" => 1.5),
                    "atol" => Dict("type" => "parameter", "units" => "1", "default" => 1.0e-12),
                    "F" => Dict(
                        "type" => "parameter", "units" => "1", "default" => 1.0, "shape" => ["src_cells"],
                        "update" => Dict("kind" => "data", "source" => "Src", "from" => Dict("file_variable" => "F"))
                    ),
                    "src_poly" => Dict("type" => "unknown", "units" => "1", "shape" => ["src_cells", "verts", "coord"]),
                    "tgt_poly" => Dict("type" => "unknown", "units" => "1", "shape" => ["tgt_cells", "verts", "coord"]),
                    "A_ij" => Dict("type" => "unknown", "units" => "1", "shape" => ["src_cells", "tgt_cells"]),
                    "A_j" => Dict("type" => "unknown", "units" => "1", "shape" => ["tgt_cells"]),
                    "F_tgt" => Dict("type" => "unknown", "units" => "1", "shape" => ["tgt_cells"]),
                    "u" => Dict("type" => "unknown", "units" => "1", "shape" => ["tgt_cells"], "default" => 0.0)
                ),
                "equations" => Any[
                    Dict("lhs" => "src_poly", "rhs" => _faq(("c", "v", "k"), ("c" => "src_cells", "v" => "verts", "k" => "coord"), ring)),
                    Dict(
                        "lhs" => "tgt_poly", "rhs" => Dict(
                            "op" => "const", "args" => Any[],
                            "value" => [[[0, 0], [2, 0], [2, 1], [0, 1]], [[3.5, 0], [4.5, 0], [4.5, 1], [3.5, 1]]]
                        )
                    ),
                    Dict(
                        "lhs" => "A_ij", "rhs" => _faq(
                            ("i", "j"), IJ, Dict(
                                "op" => "polygon_intersection_area", "manifold" => "planar",
                                "args" => Any[_ix("src_poly", "i"), _ix("tgt_poly", "j")]
                            ); join = GATE
                        )
                    ),
                    Dict("lhs" => "A_j", "rhs" => _faq(("j",), IJ, _ix("A_ij", "i", "j"); join = GATE, filter = SLIVER)),
                    Dict(
                        "lhs" => "F_tgt", "rhs" => _faq(
                            ("j",), IJ,
                            _op("/", _op("*", _ix("A_ij", "i", "j"), _ix("F", "i")), _ix("A_j", "j"));
                            join = GATE, filter = SLIVER
                        )
                    ),
                    Dict(
                        "lhs" => Dict("op" => "D", "args" => ["u"], "wrt" => "t"),
                        "rhs" => _faq(("j",), ("j" => "tgt_cells",), _ix("F_tgt", "j"))
                    ),
                ]
            )
        )
    )
end

function rhs(prob)
    du = similar(prob.u0)
    prob.f!(du, prob.u0, prob.p, 0.0)
    return du
end
expected(F) = [(F[1] + 0.5 * F[2]) / 1.5, F[3]]

@testset "overlap gate: ring envelope factors under a live forcing field" begin
    F = [1.0, 2.0, 3.0]
    # Build-time source field: the regrid materializes at setup (always worked).
    ref = EA.esm_problem(document(), (0.0, 1.0); const_arrays = Dict{String, Any}("M.F" => copy(F)))
    @test rhs(ref) ≈ expected(F)

    # Live source field: the gated apply stays in the right-hand side.
    for F2 in (F, [2.0, -4.0, 6.0])
        prob = EA.esm_problem(
            document(), (0.0, 1.0); compiler = :interpreter,
            param_arrays = Dict{String, Any}("M.F" => copy(F2))
        )
        @test rhs(prob) ≈ expected(F2)
    end
    # The same through a flattened system, as a planner builds it.
    flat = EA.flatten(EA.load_document(document()))
    prob = EA.esm_problem(flat, (0.0, 1.0); compiler = :interpreter, param_arrays = Dict{String, Any}("M.F" => copy(F)))
    @test rhs(prob) ≈ expected(F)

    # The native compiler's whole-array contraction tier does not yet lower a
    # gather from a live forcing buffer at a loop-variable subscript, which a
    # join-gated contraction needs, so it refuses the gated apply by name. Only
    # that refusal counts as the known break; any other error fails the test.
    native_ok = try
        rhs(EA.esm_problem(document(), (0.0, 1.0); param_arrays = Dict{String, Any}("M.F" => copy(F)))) ≈ expected(F)
    catch err
        (err isa EA.TreeWalkError && err.code == EA.ERROR_CODES.COMPILER_REFUSED_RULE) || rethrow()
        false
    end
    @test_broken native_ok
end

# The same regrid with the SOURCE RING itself fed by a data source. An envelope
# factor must be build-time data (§5.5.6), so this is refused with the gate's
# own diagnostic rather than a bare `KeyError` from the broad phase.
@testset "overlap gate: a live envelope factor is refused by name" begin
    doc = document()
    vars = doc["models"]["M"]["variables"]
    vars["src_poly"] = Dict(
        "type" => "parameter", "units" => "1", "default" => 0.0,
        "shape" => ["src_cells", "verts", "coord"],
        "update" => Dict("kind" => "data", "source" => "Src", "from" => Dict("file_variable" => "src_poly"))
    )
    eqs = doc["models"]["M"]["equations"]
    deleteat!(eqs, findfirst(e -> e["lhs"] == "src_poly", eqs))
    rings = zeros(3, 4, 2)
    for c in 1:3, v in 1:4
        rings[c, v, 1] = (c - 1) * 1.5 + (v == 2 || v == 3 ? 1.0 : 0.0)
        rings[c, v, 2] = v >= 3 ? 1.0 : 0.0
    end
    err = try
        EA.esm_problem(
            doc, (0.0, 1.0); compiler = :interpreter,
            param_arrays = Dict{String, Any}("M.F" => [1.0, 2.0, 3.0], "M.src_poly" => rings)
        )
        nothing
    catch e
        e
    end
    @test err isa EA.TreeWalkError
    @test err.code == "E_TREEWALK_JOIN_OVERLAP"
    @test occursin("not build-time data", err.detail)
end

@testset "_overlap_env_sym: the single-name ring form" begin
    ranges = Dict{String, Any}("i" => EA.IndexSetRef("S"), "j" => EA.IndexSetRef("T"))
    s2s = Dict("i" => "S", "j" => "T")
    shapes = Dict{String, Vector{String}}(
        "ring" => ["S", "V", "C"], "W" => ["T"], "S" => ["T"], "E" => ["T"], "N" => ["T"]
    )
    @test EA._overlap_env_sym(["ring"], ranges, s2s, shapes, :left) == "i"
    @test EA._overlap_env_sym(["W", "S", "E", "N"], ranges, s2s, shapes, :right) == "j"
    # A ring stack is one factor; named among several it is still an error.
    @test_throws EA.TreeWalkError EA._overlap_env_sym(["ring", "ring"], ranges, s2s, shapes, :left)
    # A single name that is a 1-D column has no envelope to read (the broad
    # phase reads one name as a ring stack).
    @test_throws EA.TreeWalkError EA._overlap_env_sym(["W"], ranges, s2s, shapes, :right)
    # A list length with no envelope reading is the gate's own error, not the
    # broad phase's `ArgumentError`.
    for names in (["W", "S", "E"], ["W", "S", "E", "N", "W"])
        err = try
            EA._overlap_env_sym(names, ranges, s2s, shapes, :right)
        catch e
            e
        end
        @test err isa EA.TreeWalkError && err.code == "E_TREEWALK_JOIN_OVERLAP"
    end
    # Every factor is checked, not only the first.
    @test_throws EA.TreeWalkError EA._overlap_env_sym(["W", "ring"], ranges, s2s, shapes, :right)
    # A factor absent from build-time storage is refused by name.
    err = try
        EA._require_build_time_env(["ring"], Dict{String, Any}())
    catch e
        e
    end
    @test err isa EA.TreeWalkError && err.code == "E_TREEWALK_JOIN_OVERLAP"
end

# The overlap-gate rank rule every resolver reads.
@testset "_overlap_env_rank" begin
    @test EA._overlap_env_rank(1) == 3
    @test EA._overlap_env_rank(2) == 1
    @test EA._overlap_env_rank(4) == 1
    for n in (0, 3, 5)
        @test EA._overlap_env_rank(n) === nothing
    end
end

# A value-invention producer gated by the single-name ring form, which its
# resolver used to refuse as "must be a 1-D buffer". Source rings are the unit
# squares at x ∈ [0,1], [1.5,2.5], [3,4]; target cells are [0,2] and [5,6]
# (× [0,1]). Only cell 1 overlaps a source, and with no narrow phase the gate
# alone decides, so the producer's members are exactly [1].
@testset "value invention: overlap gate with a ring envelope factor" begin
    doc = Dict{String, Any}(
        "esm" => "1.2.0",
        "metadata" => Dict("name" => "vi_overlap_ring"),
        "index_sets" => Dict(
            "src_cells" => Dict("kind" => "interval", "size" => 3),
            "verts" => Dict("kind" => "interval", "size" => 4),
            "coord" => Dict("kind" => "interval", "size" => 2),
            "cells" => Dict("kind" => "interval", "size" => 2),
            "present_cells" => Dict("kind" => "derived", "from_faq" => "ring_producer")
        ),
        "models" => Dict(
            "V" => Dict(
                "variables" => Dict(
                    "ring" => Dict("type" => "parameter", "shape" => ["src_cells", "verts", "coord"]),
                    "W" => Dict("type" => "parameter", "shape" => ["cells"]),
                    "S" => Dict("type" => "parameter", "shape" => ["cells"]),
                    "E" => Dict("type" => "parameter", "shape" => ["cells"]),
                    "N" => Dict("type" => "parameter", "shape" => ["cells"]),
                    "cell_present" => Dict("type" => "unknown", "shape" => ["present_cells"])
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => _ix("cell_present", "m"),
                        "rhs" => Dict(
                            "op" => "faq", "id" => "ring_producer",
                            "semiring" => "bool_and_or", "distinct" => true,
                            "output_idx" => ["m"],
                            "ranges" => Dict("i" => Dict("from" => "src_cells"), "j" => Dict("from" => "cells")),
                            "join" => Any[
                                Dict(
                                    "overlap" => Dict(
                                        "src_env" => ["ring"], "tgt_env" => ["W", "S", "E", "N"], "eps" => 0.0
                                    )
                                ),
                            ],
                            "args" => ["ring", "W", "S", "E", "N"],
                            "key" => Dict("op" => "skolem", "label" => "cell", "args" => ["j"]),
                            "expr" => Dict("op" => "true", "args" => [])
                        )
                    ),
                ]
            )
        )
    )
    rings = zeros(3, 4, 2)
    for c in 1:3, v in 1:4
        rings[c, v, 1] = (c - 1) * 1.5 + (v == 2 || v == 3 ? 1.0 : 0.0)
        rings[c, v, 2] = v >= 3 ? 1.0 : 0.0
    end
    consts = Dict{String, Any}(
        "ring" => rings, "W" => [0.0, 5.0], "S" => [0.0, 0.0], "E" => [2.0, 6.0], "N" => [1.0, 1.0]
    )
    file = EA.coerce_esm_file(EA.JSON3.read(EA.JSON3.write(doc)))
    model = EA._select_model(file, "V")
    vi = EA.materialize_value_invention(model, file.index_sets, consts, Dict{String, Any}())
    @test sort(collect(vi.members["ring_producer"])) == [1]
    @test vi.extents["ring_producer"] == 1
    # Without the ring in the const arrays the producer is refused by name (the
    # gate's error, wrapped by the derived index set it was sizing).
    delete!(consts, "ring")
    err = try
        EA.materialize_value_invention(model, file.index_sets, consts, Dict{String, Any}())
        nothing
    catch e
        e
    end
    @test err !== nothing
    @test occursin("E_TREEWALK_VI_JOIN", sprint(showerror, err))
    @test occursin("'ring' is not a const array", sprint(showerror, err))
end

end # module
