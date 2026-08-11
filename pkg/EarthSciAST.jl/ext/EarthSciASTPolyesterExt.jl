module EarthSciASTPolyesterExt

# Activated when the user loads Polyester alongside EarthSciAST. Loading
# Polyester IS the opt-in for the threaded RHS tier — the codegen tier's
# chunked generated sections (codegen_kernel.jl, "Threaded cell axis for the
# codegen tier"): this extension supplies the one Polyester-dependent piece —
# a static `@batch` over pre-partitioned chunk bodies — and installs it via
# `EarthSciAST._set_batch_runner!`. Without Polyester loaded, `_BATCH_RUNNER[]`
# stays null and everything runs the serial path. `ESS_THREADS_DISABLE=1` still
# forces serial even with Polyester loaded (and `ESS_CG_THREADS_DISABLE=1`
# forces just the codegen tier serial — today they gate the same tier).
#
# The partition and output-disjointness checks live in the core package;
# `chunkbody(c)` runs one static chunk, so `@batch` here only dispatches the
# chunks and barriers at the end.

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
