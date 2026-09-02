# A relation joined to ITSELF: two `aggregate` ranges over ONE index set
# (CONFORMANCE_SPEC §5.5.8 "Two ranges over one index set").
#
# Two ranges over one index set is already the documented spelling of a prefix
# reduction (esm-spec §4.3.1, `filter: j <= i`). What could not be spelled was
# the same shape with a value-equality GATE instead of an inequality filter:
# resolving an `on` key column to a loop symbol goes through the column's AXIS,
# and an axis drawn by two range symbols named neither, so Julia raised
# `E_TREEWALK_JOIN_AMBIGUOUS_KEY` ("names an index set bound by multiple range
# symbols … reference the range symbol directly") — advice a DATA-COLUMN key
# cannot take, because the pair has nowhere to put the symbol.
#
# Every assertion below is a SPECIFIC value and a SPECIFIC row count. A
# self-join is exactly the construct where a wrong side assignment returns a
# plausible number — the NEXT row's payload instead of the PREVIOUS row's — so
# "it built" and "the shape is right" prove nothing. The transposed answer is
# asserted too, as the thing the default must NOT produce.
#
# Wrapped in a module so the local JSON builders stay out of `Main` (see
# join_on_equality_gate_test.jl's header).
module JoinOnSelfJoinTests

using Test
using EarthSciAST
import JSON3

const ESS = EarthSciAST

include("testutils.jl")  # TESTUTILS_REPO_ROOT

_ix(f, a...) = Dict("op" => "index", "args" => Any[f, a...])

# `payload[i] = 7i + 4` for i = 1…n, distinct enough that no wrong pairing
# coincides with the right one.
_payload(n) = Float64[7 * i + 4 for i in 1:n]
_ids(n) = Float64[i for i in 1:n]
_shifted(n, by) = Float64[i - by for i in 1:n]

# `out[a] = Σ_b payload[b]` over the pairs where `<key_col>[a] == row_id[b]`,
# with `a` and `b` BOTH drawing the one index set `rows`. That is the point:
# the two sides of the join are two ranges over one relation.
#
# `syms` (or `nothing`), and `ranges` naming however many symbols the case wants.
function _self_join_doc(n::Int; key_col = "row_prior", syms = nothing,
                        range_syms = ["a", "b"], out_sym = "a")
    clause = Dict{String,Any}("on" => [[key_col, "row_id"]])
    syms === nothing || (clause["syms"] = syms)
    Dict("esm" => "1.0.0",
         "metadata" => Dict("name" => "self_join"),
         "index_sets" => Dict("rows" => Dict("kind" => "interval", "size" => n)),
         "models" => Dict("S" => Dict(
             "variables" => Dict{String,Any}(
                 "row_id"    => Dict("type" => "parameter", "shape" => ["rows"]),
                 "row_prior" => Dict("type" => "parameter", "shape" => ["rows"]),
                 "row_back"  => Dict("type" => "parameter", "shape" => ["rows"]),
                 "payload"   => Dict("type" => "parameter", "shape" => ["rows"]),
                 "out"       => Dict("type" => "unknown", "shape" => ["rows"],
                                     "default" => 0.0)),
             "equations" => [Dict(
                 "lhs" => Dict("op" => "D", "args" => ["out"], "wrt" => "t"),
                 "rhs" => Dict("op" => "aggregate", "args" => [],
                     "output_idx" => [out_sym], "semiring" => "sum_product",
                     "reduce" => "+",
                     "ranges" => Dict(s => Dict("from" => "rows") for s in range_syms),
                     "join" => [clause],
                     "expr" => _ix("payload", "b" in range_syms ? "b" : range_syms[end])))])))
end

const BACK = 3

# Build + evaluate, returning `(out::Vector{Float64}, driven leaf visits)`.
function _run(doc, n::Int; disable::Bool = false)
    file = ESS.coerce_esm_file(JSON3.read(JSON3.write(doc)))
    ca = Dict{String,Any}("row_id" => _ids(n), "row_prior" => _shifted(n, 1),
                          "row_back" => _shifted(n, BACK), "payload" => _payload(n))
    withenv("ESS_JOIN_ON_GATE_DISABLE" => (disable ? "1" : nothing)) do
        ESS._VI_ENUM_VISITS[] = 0
        f!, u0, p, _, _ = build_evaluator(file; model_name = "S", const_arrays = ca,
                                          initial_conditions = Dict("out" => zeros(n)))
        du = similar(u0)
        f!(du, u0, p, 0.0)
        return (Float64[du[i] for i in 1:n], ESS._VI_ENUM_VISITS[])
    end
end

# Independent oracles, so a shared mistake cannot pass.
_prior_oracle(n) = Float64[i == 1 ? 0.0 : _payload(n)[i-1] for i in 1:n]
_back_oracle(n) = Float64[i <= BACK ? 0.0 : _payload(n)[i-BACK] for i in 1:n]
_next_oracle(n) = Float64[i == n ? 0.0 : _payload(n)[i+1] for i in 1:n]

# ===========================================================================
# The value, and the specific wrong value it must not be
# ===========================================================================
@testset "the default side assignment reads the PREVIOUS row" begin
    n = 9
    out, visits = _run(_self_join_doc(n), n)

    @test length(out) == n
    @test out == _prior_oracle(n)
    # Named explicitly, because these ARE the numbers: payload[i] = 7i + 4.
    @test out[1] == 0.0          # no predecessor: the inner join's 0-bar
    @test out[2] == 11.0         # payload[1] = 11
    @test out[9] == 60.0         # payload[8] = 60
    # …and NOT the transposed reading, which would have been just as plausible.
    @test out != _next_oracle(n)
    @test visits == n - 1        # the 8 matched pairs, not the 81-pair product
end

@testset "a bounded lookback is just another key column" begin
    # The three-second-lookback half of the downstream need, with no new
    # feature: a second shifted key column, same clause shape. The two sides'
    # key EXPRESSIONS differ; the format learns nothing about time series.
    n = 9
    out, visits = _run(_self_join_doc(n; key_col = "row_back"), n)
    @test length(out) == n
    @test out == _back_oracle(n)
    @test out[1:3] == [0.0, 0.0, 0.0]
    @test out[4] == 11.0         # payload[1] = 11
    @test out[9] == 46.0         # payload[6] = 46
    @test visits == n - BACK
end

@testset "explicit `syms` choose the orientation" begin
    n = 9
    # `[a, b]` restates the default and must not change the answer.
    same, _ = _run(_self_join_doc(n; syms = ["a", "b"]), n)
    @test same == _prior_oracle(n)

    # `[b, a]` reads the key at the CONTRACTED symbol instead: the row whose
    # predecessor is `a`, i.e. the NEXT row. A different, specific answer —
    # which is the proof `syms` is consulted rather than ignored.
    flipped, visits = _run(_self_join_doc(n; syms = ["b", "a"]), n)
    @test flipped == _next_oracle(n)
    @test flipped[1] == 18.0     # payload[2] = 18
    @test flipped[9] == 0.0      # no successor
    @test visits == n - 1
end

# ===========================================================================
# Differential correctness: driven against undriven, bit for bit
# ===========================================================================
@testset "driving is bit-identical to the undriven full product" begin
    # The driver changes the enumeration EXTENT, never an answer. Same document,
    # same data, driver killed — the equality codes then filter the full 40x40
    # product, which is the pre-§5.5.8 path.
    n = 40
    driven, dv = _run(_self_join_doc(n), n)
    undriven, uv = _run(_self_join_doc(n), n; disable = true)
    @test driven == undriven
    @test driven == _prior_oracle(n)
    @test dv == n - 1
    @test uv == 0                # the undriven arm never enters the driver
end

# ===========================================================================
# Cost — the reason the default rule had to keep the gate, not just the codes
# ===========================================================================
@testset "work tracks the match count, not the squared row count" begin
    # A self-join's product is N² and its match set is N − 1, so the ratio grows
    # without bound: this is where a fallback shows up first. Grow N 10x — driven
    # work must grow 10x (with the matches), not 100x (with the product).
    small, vs = _run(_self_join_doc(50), 50)
    large, vl = _run(_self_join_doc(500), 500)
    @test small == _prior_oracle(50)
    @test large == _prior_oracle(500)
    @test vs == 49
    @test vl == 499
    @test vl * 100 < 500 * 500   # 499 visits against a 250 000 product
end

# ===========================================================================
# The refusals: what the format cannot determine, it must not guess
# ===========================================================================
@testset "three ranges over one index set are refused by name" begin
    doc = _self_join_doc(6; range_syms = ["a", "b", "c"])
    err = try
        _run(doc, 6); nothing
    catch e
        e
    end
    @test err !== nothing
    msg = sprint(showerror, err)
    @test occursin("drawn by 3 range symbols", msg)
    @test occursin("join.syms", msg)
    @test occursin("\"a\"", msg) && occursin("\"b\"", msg) && occursin("\"c\"", msg)
end

@testset "three ranges are spellable with explicit `syms`" begin
    # Once the two sides are named, the third range is an ordinary ungated axis:
    # the gated pair is unchanged and the answer is multiplied by its extent,
    # exactly as the join-free reduction would be.
    n = 6
    out, _ = _run(_self_join_doc(n; range_syms = ["a", "b", "c"], syms = ["a", "b"]), n)
    @test length(out) == n
    @test out == _prior_oracle(n) .* n
    @test out[2] == 66.0         # payload[1] = 11, times the 6-wide free axis
end

@testset "`syms` naming a symbol the node does not bind is refused" begin
    err = try
        _run(_self_join_doc(5; syms = ["a", "zzz"]), 5); nothing
    catch e
        e
    end
    @test err !== nothing
    msg = sprint(showerror, err)
    @test occursin("zzz", msg) && occursin("join.syms", msg)
end

# ===========================================================================
# Wire form: `syms` survives the round trip
# ===========================================================================
@testset "`syms` round-trips through parse and emit" begin
    doc = _self_join_doc(5; syms = ["b", "a"])
    file = ESS.coerce_esm_file(JSON3.read(JSON3.write(doc)))
    emitted = JSON3.read(JSON3.write(ESS.serialize_esm_file(file)))
    clause = emitted[:models][:S][:equations][1][:rhs][:join][1]
    @test [String(x) for x in clause[:syms]] == ["b", "a"]
    @test [[String(p[1]), String(p[2])] for p in clause[:on]] == [["row_prior", "row_id"]]

    # A clause with no `syms` must not grow one.
    plain = ESS.coerce_esm_file(JSON3.read(JSON3.write(_self_join_doc(5))))
    pe = JSON3.read(JSON3.write(ESS.serialize_esm_file(plain)))
    @test !haskey(pe[:models][:S][:equations][1][:rhs][:join][1], :syms)
end

end # module
