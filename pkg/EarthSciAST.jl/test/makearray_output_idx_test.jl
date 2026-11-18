# A `makearray` carrying `output_idx` binds those loop symbols to the cell it
# assembles (esm-spec §4.3, "Shadowing"); the pointwise lift tags its operator
# makearray this way (esm-libraries-spec §4.7.5). So:
#
#   * every scoping helper treats the symbols as bound: `_bound_symbols`, the
#     substitution's `_binds_any`, and `free_variables` agree;
#   * a substitution for an outer variable of the same name stops at the
#     makearray;
#   * read at `index(M, k…)`, each region value sees the symbols at `k…`, under
#     every compiler, whether the read subscript is the symbol itself, another
#     loop's symbol, or an expression of it.

using Test
include("testutils.jl")

const _MOI = EarthSciAST


# makearray(output_idx = [sym]): cell 1 holds 10·u[1], cells 2..N hold
# u[sym] - u[sym - 1].
_moi_ma(N, sym) = Dict{String, Any}(
    "op" => "makearray", "args" => Any[], "output_idx" => Any[sym],
    "regions" => Any[Any[Any[1, 1]], Any[Any[2, N]]],
    "values" => Any[
        jop("*", 10, jidx("u", sym)),
        jop("-", jidx("u", sym), jidx("u", jop("-", sym, 1))),
    ],
)

# D(J) = faq_i index(M, sub(i)), with u held constant.
function _moi_doc(N, rhs_body)
    faq(body) = Dict{String, Any}(
        "op" => "faq", "args" => Any[], "output_idx" => Any["i"],
        "ranges" => Dict{String, Any}("i" => Any[1, N]), "expr" => body
    )
    return Dict{String, Any}(
        "esm" => "2.0.0", "metadata" => Dict("name" => "MakearrayOutputIdx"),
        "index_sets" => Dict("x" => Dict("kind" => "interval", "size" => N)),
        "models" => Dict(
            "M" => Dict{String, Any}(
                "variables" => Dict(
                    "u" => Dict("type" => "unknown", "shape" => Any["x"], "default" => 0.0),
                    "J" => Dict("type" => "unknown", "shape" => Any["x"], "default" => 0.0)
                ),
                "equations" => Any[
                    Dict("lhs" => Dict("op" => "D", "args" => Any["u"], "wrt" => "t"), "rhs" => faq(0.0)),
                    Dict("lhs" => Dict("op" => "D", "args" => Any["J"], "wrt" => "t"), "rhs" => faq(rhs_body)),
                ]
            )
        )
    )
end

_moi_u(k) = Float64(k^2)

function _moi_du(doc, N; compiler)
    ics = merge(
        Dict{String, Any}("M.u[$k]" => _moi_u(k) for k in 1:N),
        Dict{String, Any}("M.J[$k]" => 0.0 for k in 1:N)
    )
    f!, u0, p, _, vm = _MOI.Internal.build(doc; initial_conditions = ics, compiler = compiler)
    du = similar(u0)
    f!(du, u0, p, 0.0)
    return [du[vm["M.J[$i]"]] for i in 1:N]
end

# The value the makearray holds at cell c.
_moi_cell(c) = c == 1 ? 10 * _moi_u(1) : _moi_u(c) - _moi_u(c - 1)

@testset "makearray output_idx binds its loop symbols" begin
    @testset "scoping helpers agree" begin
        ma = _MOI.expression_from_json(_moi_ma(4, "k"))
        @test _MOI._bound_symbols(ma) == ["k"]
        @test _MOI._binds_any(ma, Dict{String, _MOI.ASTExpr}("k" => _MOI.IntExpr(2)))
        @test !_MOI._binds_any(ma, Dict{String, _MOI.ASTExpr}("u" => _MOI.IntExpr(2)))
        @test !("k" in _MOI.free_variables(ma))
        @test "u" in _MOI.free_variables(ma)
        # A substitution for an outer `k` does not reach the region values.
        @test _MOI._sub_preserving(ma, Dict{String, _MOI.ASTExpr}("k" => _MOI.IntExpr(2))) === ma
    end

    N = 5
    cases = (
        # The lift's form: read at the makearray's own symbols.
        ("read at its own symbol", jidx(_moi_ma(N, "i"), "i"), i -> _moi_cell(i)),
        # Another loop's symbol: `k` is bound by the makearray alone.
        ("read at another loop's symbol", jidx(_moi_ma(N, "k"), "i"), i -> _moi_cell(i)),
        # Read in reverse: inside the makearray `i` is the cell N + 1 - i, not
        # the outer `i`.
        (
            "read at an expression of the outer symbol",
            jidx(_moi_ma(N, "i"), jop("-", N + 1, "i")), i -> _moi_cell(N + 1 - i),
        ),
    )
    @testset "$name ($compiler)" for (name, body, want) in cases,
            compiler in (:native, :interpreter)
        @test _moi_du(_moi_doc(N, body), N; compiler = compiler) == [want(i) for i in 1:N]
    end
end
