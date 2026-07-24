module EarthSciASTPolyesterExt

# Activated when the user loads Polyester alongside EarthSciAST. Loading Polyester
# IS the opt-in for the threaded lane-tape RHS tier: this extension supplies the
# only Polyester-dependent piece — a static `@batch` over the pre-partitioned
# chunk bodies — and installs it via `EarthSciAST._set_batch_runner!`. Without
# Polyester loaded, `_BATCH_RUNNER[]` stays null and every plan runs the serial
# path (see access_kernel.jl, "Threaded cell axis"). `ESS_THREADS_DISABLE=1` still
# forces serial even with Polyester loaded.
#
# The partition, per-chunk scratch clones, and output-disjointness check all live
# in the core package; `chunkbody(c)` runs one static chunk with its private
# scratch, so `@batch` here only dispatches the chunks and barriers at the end.

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
