module EarthSciASTPolyesterExt

# Activated when the user loads Polyester alongside EarthSciAST. Loading Polyester
# IS the opt-in for BOTH threaded RHS tiers — the lane tape's per-kernel cell
# axis (access_kernel.jl, "Threaded cell axis") and the codegen tier's chunked
# generated sections (codegen_kernel.jl, "Threaded cell axis for the codegen
# tier"): this extension supplies the one Polyester-dependent piece they share —
# a static `@batch` over pre-partitioned chunk bodies — and installs it via
# `EarthSciAST._set_batch_runner!`. Without Polyester loaded, `_BATCH_RUNNER[]`
# stays null and everything runs the serial path. `ESS_THREADS_DISABLE=1` still
# forces serial even with Polyester loaded (and `ESS_CG_THREADS_DISABLE=1`
# forces just the codegen tier serial).
#
# The partition, per-chunk scratch clones, and output-disjointness checks all
# live in the core package; `chunkbody(c)` runs one static chunk with its
# private state, so `@batch` here only dispatches the chunks and barriers at
# the end.

using EarthSciAST
using Polyester: @batch

function _batch_run!(chunkbody, nchunks::Int)
    @batch for c in 1:nchunks
        chunkbody(c)
    end
    return nothing
end

__init__() = EarthSciAST._set_batch_runner!(_batch_run!)

end # module EarthSciASTPolyesterExt
