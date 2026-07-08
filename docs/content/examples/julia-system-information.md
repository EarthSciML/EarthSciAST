# System Information (Julia)

**Source:** `/home/ctessum/EarthSciAST/pkg/EarthSciAST.jl/test/compat_test.jl`

```julia
println("\n=== System Information ===")
        println("Julia version: ", VERSION)
        println("OS: ", Sys.KERNEL)
        println("Architecture: ", Sys.ARCH)
        println("CPU threads: ", Sys.CPU_THREADS)
        println("Memory: ", round(Sys.total_memory() / 1024^3, digits=2), " GB")

        # Print package versions
        println("\n=== Package Versions ===")
        for (uuid, pkg) in Pkg.dep
```

