# ========================================================================
# ext/reactant_direct/options.jl — the direct emitter's tuning switches,
# read and validated once, then carried by the emission context.
# Included first by reactant_direct/mod.jl.
# ========================================================================

"""
    DirectEmitOptions(; read = :gather, gather_max_pieces = 8,
                      gather_base_max = nothing, gather_index_bits = 32,
                      reduce_min = 32, locate = :auto, locate_ladder_max = 8,
                      calls = :functions)
    DirectEmitOptions(env::AbstractDict)

The direct emitter's tuning switches. None of them changes what the program
computes except `reduce_min` (see below); they change the program's SHAPE, and
they exist as measurement levers and negative controls.

- `read`: how a read of many positions is emitted. `:gather` (the cost model:
  one gather when the read shatters, slices per run otherwise), `:runs` (always
  slices per run; the negative control), `:always` (gather every multi-run read
  and lift the base budget; a measurement lever).
- `gather_max_pieces`: the piece cap past which a read is one gather.
- `gather_base_max`: the element budget for the concatenate a cross-producer
  gather reads from; `nothing` sizes it from the model (`_de_gather_base_max`).
- `gather_index_bits`: 32 or 64, the gather index element type. 32 widens to 64
  on its own for a base a 32-bit index cannot address.
- `reduce_min`: the fold length at which a chain of binary ops becomes one
  `stablehlo.reduce`. Below it a fold is bit-identical to the interpreter's left
  fold; at or above it XLA may reassociate.
- `locate`, `locate_ladder_max`: the comparison-count lowering under a trace
  (`:auto`, `:reduce`, `:ladder`, `:affine`) and the ladder/affine cut; see
  ext/reactant_knot_count.jl.
- `calls`: how a template reference is emitted. `:functions` (the default)
  emits each template instance once as a private `func.func` per argument
  shape and a `func.call` at every use; `:inline` places the body at every use
  (the measurement baseline). XLA's own pipeline may inline the calls while it
  compiles; the emitted module keeps them.

`DirectEmitOptions(env)` reads `ESM_DIRECT_EMIT_READ`,
`ESM_DIRECT_GATHER_INDEX_BITS`, `ESS_RX_LOCATE` and `ESS_RX_LOCATE_LADDER_MAX`
from `env` (normally `ENV`); an unset variable keeps the default, and the other
fields take their defaults. This is the only place the emitter reads the environment. A value
that does not parse, or names no mode, raises `DirectEmitError`.
"""
Base.@kwdef struct DirectEmitOptions
    read::Symbol = :gather
    gather_max_pieces::Int = 8
    gather_base_max::Union{Nothing, Int} = nothing
    gather_index_bits::Int = 32
    reduce_min::Int = 32
    locate::Symbol = :auto
    locate_ladder_max::Int = 8
    calls::Symbol = :functions
    function DirectEmitOptions(
            read, gather_max_pieces, gather_base_max, gather_index_bits,
            reduce_min, locate, locate_ladder_max, calls
        )
        read in (:gather, :runs, :always) || _de_bad_option(
            "read", read, "`:gather`, `:runs` or `:always`"
        )
        gather_index_bits in (32, 64) || _de_bad_option(
            "gather_index_bits", gather_index_bits,
            "32 or 64; a gather's start indices are emitted as 32- or 64-bit " *
                "integers and as nothing else"
        )
        locate in (:auto, :reduce, :ladder, :affine) || _de_bad_option(
            "locate", locate, "`:auto`, `:reduce`, `:ladder` or `:affine`"
        )
        calls in (:functions, :inline) || _de_bad_option(
            "calls", calls, "`:functions` or `:inline`"
        )
        return new(
            read, gather_max_pieces, gather_base_max, gather_index_bits,
            reduce_min, locate, locate_ladder_max, calls
        )
    end
end

_de_bad_option(name, value, expected) = throw(
    _E.DirectEmitError(
        "a direct-emit option `$name = $(repr(value))`",
        "the direct emitter's options",
        "`$name` must be $expected."
    )
)

function _de_env_int(env, var::String, name::String)
    v = get(env, var, "")
    isempty(v) && return nothing
    w = tryparse(Int, v)
    w === nothing && _de_bad_option(name, v, "an integer (from $var)")
    return w
end

_de_env_sym(env, var::String) =
    (v = get(env, var, ""); isempty(v) ? nothing : Symbol(v))

function DirectEmitOptions(env::AbstractDict)
    d = DirectEmitOptions()
    return DirectEmitOptions(;
        read = something(_de_env_sym(env, "ESM_DIRECT_EMIT_READ"), d.read),
        gather_index_bits = something(
            _de_env_int(env, "ESM_DIRECT_GATHER_INDEX_BITS", "gather_index_bits"),
            d.gather_index_bits
        ),
        locate = something(_de_env_sym(env, "ESS_RX_LOCATE"), d.locate),
        locate_ladder_max = something(
            _de_env_int(env, "ESS_RX_LOCATE_LADDER_MAX", "locate_ladder_max"),
            d.locate_ladder_max
        ),
    )
end
