# A lifted whole-array equation whose terms gather a `makearray` (found by
# EarthSciIntegrator PR #34 on its `reseact_shaped` fixture). An operator's
# derived document writes a whole-array equation as
#
#     D(u) = faq_i( index(makearray(regions, values), i) )
#
# and the tree walk lifts it to `index(faq_i(...), _lp0)`: the makearray is
# gathered at the lifted faq's OWN index `i`, never at the equation's loop
# `_lp0`. Under `compiler = :native` this used to go wrong two ways:
#
#   * SILENTLY WRONG. The affine tier keys each cell by the regions it selects
#     and builds one template per key. Its region-select walk pruned the faq's
#     body through a cache filled before `i` was a loop index, so every cell
#     keyed alike and took the FIRST cell's template: the face region's value
#     (often 0) everywhere. And the cut harvest that finds mid-domain region
#     boundaries only knew a makearray gathered at a bare loop index, so a
#     boundary reached through the faq's index, an offset (`i + 1`), or an
#     elementwise sum of makearrays was never cut: a box spanning two regions
#     computed one of them.
#   * REFUSED. A contracting `faq` (a column sum) in a region value was outside
#     the affine tier, and the region split did not see through the lifting.
#
# Each document below must agree with `compiler = :interpreter` bit for bit
# (`===` per element) on the right-hand side and its ForwardDiff Jacobian, on
# compile-once tiers only — or, for the one shape no box cut describes (a
# region chosen by a subscript of two loop indices), be refused by name.

using Test
using ForwardDiff
include("testutils.jl")

const _NLM = EarthSciAST

_nlm_idx(a, i...) = Dict{String, Any}("op" => "index", "args" => Any[a, i...])
_nlm_op(o, a...) = Dict{String, Any}("op" => o, "args" => Any[a...])
_nlm_faq(expr, out, ranges) = Dict{String, Any}(
    "op" => "faq", "args" => Any[],
    "output_idx" => Any[out...], "ranges" => Dict{String, Any}(ranges), "expr" => expr
)
_nlm_ma(regions, values) = Dict{String, Any}(
    "op" => "makearray", "args" => Any[],
    "regions" => Any[Any[Any[r...] for r in reg] for reg in regions], "values" => Any[values...]
)

# One model `M` with array state `u` over `sets` (name => size), `D(u) = rhs`.
function _nlm_doc(sets::Vector{Pair{String, Int}}, rhs)
    return Dict{String, Any}(
        "esm" => "1.1.0", "metadata" => Dict("name" => "NativeLifted"),
        "index_sets" => Dict{String, Any}(
            n => Dict("kind" => "interval", "size" => s)
                for (n, s) in sets
        ),
        "models" => Dict{String, Any}(
            "M" => Dict{String, Any}(
                "variables" => Dict{String, Any}(
                    "u" => Dict(
                        "type" => "unknown", "shape" => Any[first.(sets)...],
                        "default" => 1.0
                    ),
                    "rate" => Dict("type" => "parameter", "default" => 1.5)
                ),
                "equations" => Any[
                    Dict(
                        "lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"),
                        "rhs" => rhs
                    ),
                ]
            )
        )
    )
end

# The lifted form: `faq` over the state's index sets of `body`.
_nlm_lifted(body, names, sets) =
    _nlm_faq(body, names, [n => Dict("from" => s) for (n, s) in zip(names, sets)])

function _nlm_build(doc, c)
    _NLM._reset_cascade_tally!()
    prob = _NLM.esm_problem(doc, (0.0, 1.0); compiler = c)
    return prob, copy(_NLM._CASCADE_TALLY)
end

# A state with no two elements equal, keyed by element name.
_nlm_state(prob) = Dict(String(k) => 0.7 + 0.37 * v + 0.01 * sin(1.3 * v) for (k, v) in prob.var_map)

function _nlm_agree(doc)
    pn, tally = _nlm_build(doc, :native)
    pi_, _ = _nlm_build(doc, :interpreter)
    s = _nlm_state(pi_)
    lay(p) = (
        u = similar(p.u0); for (k, j) in p.var_map
            u[j] = s[String(k)]
        end; u
    )
    un, ui = lay(pn), lay(pi_)
    f(p) = (d, u) -> p.f!(d, u, p.p, 0.3)
    dn = fill(NaN, length(un)); f(pn)(dn, un)
    di = fill(NaN, length(ui)); f(pi_)(di, ui)
    same = all(dn[pn.var_map[k]] === di[j] for (k, j) in pi_.var_map)
    Jn = ForwardDiff.jacobian(f(pn), similar(un), un)
    Ji = ForwardDiff.jacobian(f(pi_), similar(ui), ui)
    jsame = all(
        isequal(Jn[pn.var_map[a], pn.var_map[b]], Ji[ia, ib])
            for (a, ia) in pi_.var_map for (b, ib) in pi_.var_map
    )
    tiers = Dict(_NLM.tier_histogram(_NLM.compiler_report(pn)))
    return (; same, jsame, tally, tiers, nonzero = any(!iszero, di))
end

function _nlm_refusal(doc)
    try
        _nlm_build(doc, :native)
    catch err
        return err
    end
    return nothing
end

const _NLM_U = "M.u"

# ── documents ────────────────────────────────────────────────────────────────

# Upwind stencil over the interior [2,N], a zero inflow face at [1,1].
_nlm_upwind(N) = _nlm_doc(
    ["x" => N], _nlm_lifted(
        _nlm_idx(
            _nlm_ma(
                [[(2, N)], [(1, 1)]],
                [
                    _nlm_faq(
                        _nlm_op(
                            "*", _nlm_op("-", "M.rate"),
                            _nlm_op("-", _nlm_idx(_NLM_U, "i"), _nlm_idx(_NLM_U, _nlm_op("-", "i", 1)))
                        ),
                        ["i"], ["i" => Any[2, N]]
                    ),
                    0,
                ]
            ), "i"
        ), ["i"], ["x"]
    )
)

# Rank 2, with a reduced-rank face value (an faq over `j` alone at i = 1).
_nlm_face2d() = _nlm_doc(
    ["x" => 4, "y" => 3], _nlm_lifted(
        _nlm_idx(
            _nlm_ma(
                [[(2, 4), (1, 3)], [(1, 1), (1, 3)]],
                [
                    _nlm_faq(
                        _nlm_op("-", _nlm_idx(_NLM_U, "i", "j"), _nlm_idx(_NLM_U, _nlm_op("-", "i", 1), "j")),
                        ["i", "j"], ["i" => Any[2, 4], "j" => Any[1, 3]]
                    ),
                    _nlm_faq(
                        _nlm_op("-", _nlm_idx(_NLM_U, 1, "j"), _nlm_idx(_NLM_U, 4, "j")),
                        ["j"], ["j" => Any[1, 3]]
                    ),
                ]
            ), "i", "j"
        ), ["i", "j"], ["x", "y"]
    )
)

# A region boundary in the middle of a 40-cell axis, far from both ends, so the
# edge scans never reach it: only the cut harvest can.
const _NLM_N = 40
_nlm_halves(v1, v2) = _nlm_ma([[(1, 20)], [(21, 40)]], [v1, v2])
_nlm_mid_faq_values() = _nlm_doc(
    ["x" => _NLM_N], _nlm_lifted(
        _nlm_idx(
            _nlm_halves(
                _nlm_faq(_nlm_op("*", 2, _nlm_idx(_NLM_U, "i")), ["i"], ["i" => Any[1, 20]]),
                _nlm_faq(_nlm_op("*", 3, _nlm_idx(_NLM_U, "i")), ["i"], ["i" => Any[21, 40]])
            ), "i"
        ),
        ["i"], ["x"]
    )
)
_nlm_mid_scalar_values() = _nlm_doc(
    ["x" => _NLM_N], _nlm_lifted(
        _nlm_op("*", _nlm_idx(_NLM_U, "i"), _nlm_idx(_nlm_halves(2, 3), "i")), ["i"], ["x"]
    )
)
# Gathered at an offset: the boundary falls at cell 20, not 21.
_nlm_mid_offset() = _nlm_doc(
    ["x" => _NLM_N], _nlm_lifted(
        _nlm_op(
            "*", _nlm_idx(_NLM_U, "i"),
            _nlm_idx(_nlm_ma([[(1, 21)], [(22, 41)]], [2, 3]), _nlm_op("+", "i", 1))
        ),
        ["i"], ["x"]
    )
)
# A clamp: a function of one loop index that is not `i + c`.
_nlm_mid_clamp() = _nlm_doc(
    ["x" => _NLM_N], _nlm_lifted(
        _nlm_op(
            "*", _nlm_idx(_NLM_U, "i"),
            _nlm_idx(_nlm_halves(2, 3), _nlm_op("min", _nlm_op("+", "i", 1), _NLM_N))
        ),
        ["i"], ["x"]
    )
)
# Through an elementwise sum of two makearrays (`_stencilize_index` pushes the
# gather into the operands).
_nlm_mid_sum() = _nlm_doc(
    ["x" => _NLM_N], _nlm_lifted(
        _nlm_op(
            "*", _nlm_idx(_NLM_U, "i"),
            _nlm_idx(
                _nlm_op("+", _nlm_halves(2, 3), _nlm_ma([[(1, 10)], [(11, 40)]], [1, 0])),
                "i"
            )
        ),
        ["i"], ["x"]
    )
)
# Chosen by `i + j`: a diagonal no box cut describes.
_nlm_diagonal() = _nlm_doc(
    ["x" => 20, "y" => 20], _nlm_lifted(
        _nlm_op(
            "*", _nlm_idx(_NLM_U, "i", "j"),
            _nlm_idx(_nlm_halves(2, 3), _nlm_op("+", "i", "j"))
        ),
        ["i", "j"], ["x", "y"]
    )
)

# The column relaxation c·(Σ_kk u[i,kk]/L − u[i,k]) as a makearray region value.
_nlm_column_value(NX, L; klo = 1, khi = L) =
    _nlm_faq(
    _nlm_op(
        "*", "M.rate", _nlm_op(
            "-",
            _nlm_op("/", _nlm_faq(_nlm_idx(_NLM_U, "i", "kk"), String[], ["kk" => Any[1, L]]), L),
            _nlm_idx(_NLM_U, "i", "k")
        )
    ),
    ["i", "k"], ["i" => Any[1, NX], "k" => Any[klo, khi]]
)
_nlm_column(NX, L) = _nlm_doc(
    ["x" => NX, "z" => L], _nlm_lifted(
        _nlm_idx(
            _nlm_ma([[(1, NX), (1, L)]], [_nlm_column_value(NX, L)]), "i", "k"
        ),
        ["i", "k"], ["x", "z"]
    )
)
# The column next to a stencil region.
_nlm_column_beside_stencil() = _nlm_doc(
    ["x" => 3, "z" => 4], _nlm_lifted(
        _nlm_idx(
            _nlm_ma(
                [[(1, 3), (1, 2)], [(1, 3), (3, 4)]],
                [
                    _nlm_column_value(3, 4; khi = 2),
                    _nlm_faq(
                        _nlm_op("-", _nlm_idx(_NLM_U, "i", "k"), _nlm_idx(_NLM_U, "i", _nlm_op("-", "k", 1))),
                        ["i", "k"], ["i" => Any[1, 3], "k" => Any[3, 4]]
                    ),
                ]
            ), "i", "k"
        ),
        ["i", "k"], ["x", "z"]
    )
)
# A flattened model's form: the stencil gather and the column gather summed in
# one lifted equation.
_nlm_column_plus_stencil() = _nlm_doc(
    ["x" => 6, "z" => 4], _nlm_lifted(
        _nlm_op(
            "+",
            _nlm_idx(
                _nlm_ma(
                    [[(2, 6), (1, 4)], [(1, 1), (1, 4)]],
                    [
                        _nlm_faq(
                            _nlm_op("-", _nlm_idx(_NLM_U, "i", "k"), _nlm_idx(_NLM_U, _nlm_op("-", "i", 1), "k")),
                            ["i", "k"], ["i" => Any[2, 6], "k" => Any[1, 4]]
                        ),
                        0,
                    ]
                ), "i", "k"
            ),
            _nlm_idx(_nlm_ma([[(1, 6), (1, 4)]], [_nlm_column_value(6, 4)]), "i", "k")
        ),
        ["i", "k"], ["x", "z"]
    )
)

const _NLM_COMPILE_ONCE = (:affine, :scan, :array_contraction_codegen)

@testset "native: makearray gathered in a lifted equation" begin
    @testset "$name" for (name, doc) in (
            ("upwind stencil, zero face", _nlm_upwind(6)),
            ("rank 2, reduced-rank face", _nlm_face2d()),
            ("mid-domain boundary, faq region values", _nlm_mid_faq_values()),
            ("mid-domain boundary, scalar region values", _nlm_mid_scalar_values()),
            ("mid-domain boundary, offset subscript", _nlm_mid_offset()),
            ("mid-domain boundary, clamped subscript", _nlm_mid_clamp()),
            ("mid-domain boundary, sum of makearrays", _nlm_mid_sum()),
            ("short column contraction", _nlm_column(3, 4)),
            ("long column contraction", _nlm_column(3, 12)),
            ("column beside a stencil", _nlm_column_beside_stencil()),
            ("column plus stencil, one equation", _nlm_column_plus_stencil()),
        )
        r = _nlm_agree(doc)
        @test r.nonzero
        @test r.same
        @test r.jsame
        @test isempty(setdiff(keys(r.tiers), _NLM_COMPILE_ONCE))
        @test get(r.tally, :percell_acc, 0) == 0
    end

    # The long column is beyond the affine tier's unroll floor: it is split by
    # region and its column sum kept a loop by the whole-array nest.
    @testset "a long column takes the nest" begin
        r = _nlm_agree(_nlm_column(3, 12))
        @test get(r.tiers, :array_contraction_codegen, 0) >= 1
    end

    @testset "a region chosen by two loop indices is refused by name" begin
        err = _nlm_refusal(_nlm_diagonal())
        @test err isa _NLM.TreeWalkError
        @test err.code == _NLM.ERROR_CODES.COMPILER_REFUSED_RULE
        @test occursin("several loop indices", err.detail)
        # The interpreter runs it.
        p, _ = _nlm_build(_nlm_diagonal(), :interpreter)
        @test length(p.u0) == 400
    end
end
