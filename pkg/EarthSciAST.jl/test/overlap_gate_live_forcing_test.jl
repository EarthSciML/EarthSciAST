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
    # join-gated contraction needs, so it refuses the gated apply by name.
    @test_broken try
        rhs(EA.esm_problem(document(), (0.0, 1.0); param_arrays = Dict{String, Any}("M.F" => copy(F)))) ≈ expected(F)
    catch
        false
    end
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
end

end # module
