# tree_walk/memory.jl — zero-filled buffers (`_zeros_f64`) and the huge-page hint.

# A zero-filled `Array{Float64}` of size `dims`. A large one comes from
# `calloc`, whose pages the kernel hands out already zero, so a buffer that is
# mostly left zero, or filled later by the right-hand side, costs the build
# nothing per element; the array owns the memory and frees it when collected.
#
# `sparse = true` is for a buffer the build writes at a few scattered elements
# and leaves zero elsewhere (a declared-dense geometry array filled only at its
# admitted pairs). Under Linux's transparent huge pages a first write zeroes a
# whole 2 MiB page, so scattered writes would zero most of the buffer: the
# buffer is marked `MADV_NOHUGEPAGE` so a write zeroes only its 4 KiB page.
function _zeros_f64(dims::Int...; sparse::Bool = false)
    n = prod(dims; init = 1)
    n < 1 << 16 && return zeros(Float64, dims...)
    ptr = Libc.calloc(n, sizeof(Float64))
    ptr == C_NULL && throw(OutOfMemoryError())
    sparse && _no_huge_pages(ptr, n * sizeof(Float64))
    return unsafe_wrap(Array, Ptr{Float64}(ptr), dims; own = true)
end

# Advise the kernel not to back the whole pages inside `[ptr, ptr + nbytes)`
# with transparent huge pages. Advice only: a failure leaves the memory as it
# was, and other systems skip it.
function _no_huge_pages(ptr::Ptr{Cvoid}, nbytes::Int)
    Sys.islinux() || return nothing
    pg = UInt(4096)
    lo = (UInt(ptr) + pg - 1) & ~(pg - 1)
    hi = (UInt(ptr) + UInt(nbytes)) & ~(pg - 1)
    hi > lo && ccall(
        :madvise, Cint, (Ptr{Cvoid}, Csize_t, Cint),
        Ptr{Cvoid}(lo), hi - lo, 15
    )   # MADV_NOHUGEPAGE
    return nothing
end
