#!/usr/bin/env julia
"""
Round-trip validator CLI — Phase 1 migration acceptance gate (gt-dod2).

Usage:
    julia --project=. pkg/EarthSciAST.jl/scripts/roundtrip.jl \\
        <path-to-mtk-module>.jl [--tol rel=1e-6] [--name SystemName]

Behavior:
1. `include`s the MTK module file.
2. Extracts a `System` object. By convention the module exports a
   `system` or `default_system` binding; if absent, the CLI falls back to
   the first `ModelingToolkit.AbstractSystem` binding declared at module
   scope. An explicit `--name` flag overrides the discovery.
3. Calls `mtk2esm(sys)` → in-memory Dict → writes to a tempfile `.esm`.
4. Loads the `.esm` back through `esm2mtk` (i.e.
   `ModelingToolkit.System(load(tempfile).models[name])`).
5. Simulates both the original and the round-tripped system over the
   declared default timespan and compares trajectories at a dense sample
   of points within the declared tolerance.
6. Exits 0 on pass, non-zero on fail. Prints a per-variable diff summary
   on failure.

Exit codes:
    0  — round-trip passed within tolerance
    1  — round-trip failed (trajectory diff exceeded tolerance)
    2  — usage / loading error
    3  — simulation failed
"""

using Pkg
Pkg.activate(dirname(@__DIR__))

using EarthSciAST
using ModelingToolkit
using OrdinaryDiffEqTsit5
using Symbolics
using JSON3

const ESM = EarthSciAST
const MTK = ModelingToolkit

# -------------------------------------------------------------------
# Argument parsing
# -------------------------------------------------------------------

struct CliArgs
    module_path::String
    rel_tol::Float64
    abs_tol::Float64
    system_name::Union{String,Nothing}
    tspan::Union{Tuple{Float64,Float64},Nothing}
    n_samples::Int
end

function parse_args(argv)
    if isempty(argv) || argv[1] in ("-h", "--help")
        println(@doc(Main))  # will be empty but harmless
        println("Usage: roundtrip.jl <path-to-mtk-module>.jl [--tol rel=1e-6] " *
                "[--atol 1e-9] [--name SystemName] [--tspan 0.0,10.0] " *
                "[--samples 50]")
        exit(2)
    end

    module_path = argv[1]
    rel_tol = 1e-6
    abs_tol = 1e-9
    name = nothing
    tspan = nothing
    n_samples = 50

    i = 2
    while i <= length(argv)
        flag = argv[i]
        if flag == "--tol"
            i += 1
            spec = argv[i]
            m = match(r"^rel=([0-9eE.+\-]+)$", spec)
            if m !== nothing
                rel_tol = parse(Float64, m.captures[1])
            else
                rel_tol = parse(Float64, spec)
            end
        elseif flag == "--atol"
            i += 1
            abs_tol = parse(Float64, argv[i])
        elseif flag == "--name"
            i += 1
            name = argv[i]
        elseif flag == "--tspan"
            i += 1
            parts = split(argv[i], ",")
            length(parts) == 2 || error("--tspan requires 'start,stop'")
            tspan = (parse(Float64, parts[1]), parse(Float64, parts[2]))
        elseif flag == "--samples"
            i += 1
            n_samples = parse(Int, argv[i])
        else
            error("unknown flag: $flag")
        end
        i += 1
    end

    return CliArgs(module_path, rel_tol, abs_tol, name, tspan, n_samples)
end

# -------------------------------------------------------------------
# System discovery
# -------------------------------------------------------------------

function discover_system(mod::Module, explicit_name::Union{String,Nothing})
    if explicit_name !== nothing
        sym = Symbol(explicit_name)
        isdefined(mod, sym) || error("system binding '$explicit_name' not " *
            "defined in module $(mod)")
        return getfield(mod, sym), explicit_name
    end

    for candidate in (:system, :default_system)
        if isdefined(mod, candidate)
            val = getfield(mod, candidate)
            if val isa MTK.AbstractSystem
                return val, String(candidate)
            end
        end
    end

    # Fallback: first AbstractSystem-valued binding
    for n in names(mod; all=true)
        n in (:eval, :include) && continue
        try
            val = getfield(mod, n)
            if val isa MTK.AbstractSystem
                return val, String(n)
            end
        catch
        end
    end

    error("no ModelingToolkit.AbstractSystem binding found in $mod; " *
          "define `system` or pass --name")
end

# -------------------------------------------------------------------
# Round-trip core
# -------------------------------------------------------------------

function roundtrip_one(original::MTK.AbstractSystem, name::AbstractString;
                       tspan::Tuple{Float64,Float64}, rel_tol::Float64,
                       abs_tol::Float64, n_samples::Int)
    # 1. Forward: mtk2esm → tempfile
    esm_dict = mtk2esm(original; metadata=(; name=name))
    tmpfile = tempname() * ".esm"
    open(tmpfile, "w") do io
        write(io, JSON3.write(esm_dict; indent=2))
    end
    println("✓ Wrote round-trip file: $tmpfile")

    # 2. Reverse: load + esm2mtk
    esm_file = ESM.load(tmpfile)

    name_key = String(name)
    roundtripped = if esm_file.models !== nothing && haskey(esm_file.models, name_key)
        MTK.System(esm_file.models[name_key]; name=Symbol(name_key))
    elseif esm_file.reaction_systems !== nothing &&
           haskey(esm_file.reaction_systems, name_key)
        error("reaction_systems round-trip requires Catalyst; call " *
              "roundtrip_catalyst directly")
    else
        error("round-tripped file has no entry under name '$name_key'")
    end

    # 3. Simulate both
    sol_orig = _simulate(original, tspan)
    sol_rt = _simulate(roundtripped, tspan)

    # 4. Compare trajectories
    return _compare_trajectories(sol_orig, sol_rt, original, roundtripped;
        tspan=tspan, rel_tol=rel_tol, abs_tol=abs_tol, n_samples=n_samples)
end

function _simulate(sys::MTK.AbstractSystem, tspan::Tuple{Float64,Float64})
    simp = MTK.mtkcompile(sys)
    prob = MTK.ODEProblem(simp, Dict{Any,Any}(), tspan)
    sol = OrdinaryDiffEqTsit5.solve(prob, OrdinaryDiffEqTsit5.Tsit5();
        reltol=1e-9, abstol=1e-12)
    return sol, simp
end

"""
Find the unknown in `simp` whose sanitized name suffix matches `state_name`.
Names like `SysName_x` compare against `x`; bare `x` names match directly.
"""
function _find_unknown(simp, state_name::AbstractString)
    target = String(state_name)
    for u in MTK.unknowns(simp)
        nm = string(MTK.getname(u))
        nm == target && return u
        endswith(nm, "_" * target) && return u
    end
    return nothing
end

function _compare_trajectories((sol_a, simp_a), (sol_b, simp_b),
                               orig_sys, rt_sys;
                               tspan, rel_tol, abs_tol, n_samples)
    # Collect state names from the original compiled system
    orig_names = [_last_segment(string(MTK.getname(u)))
                  for u in MTK.unknowns(simp_a)]

    sample_times = collect(range(tspan[1], tspan[2]; length=n_samples))
    per_var_maxerr = Dict{String,Float64}()
    failures = Tuple{String,Float64,Float64,Float64,Float64}[]

    for state in orig_names
        u_a = _find_unknown(simp_a, state)
        u_b = _find_unknown(simp_b, state)
        (u_a === nothing || u_b === nothing) && continue
        max_err = 0.0
        for t in sample_times
            va = sol_a(t, idxs=u_a)
            vb = sol_b(t, idxs=u_b)
            err = abs(va - vb)
            ref = max(abs(va), abs(vb))
            allowed = max(abs_tol, rel_tol * ref)
            if err > allowed
                push!(failures, (state, t, va, vb, err))
            end
            max_err = max(max_err, err)
        end
        per_var_maxerr[state] = max_err
    end

    println("Round-trip diff summary (max abs error per state):")
    for (k, v) in per_var_maxerr
        println("  $k: $(@sprintf "%.3e" v)")
    end

    if !isempty(failures)
        println("\n✗ FAIL — $(length(failures)) sample(s) exceeded tolerance " *
                "(rel=$rel_tol, abs=$abs_tol):")
        for (s, t, va, vb, err) in first(failures, 10)
            println("  $s @ t=$t: orig=$va vs rt=$vb (err=$err)")
        end
        length(failures) > 10 && println("  ... and $(length(failures)-10) more")
        return false
    end

    println("\n✓ PASS — trajectories match within rel=$rel_tol, abs=$abs_tol")
    return true
end

_last_segment(s) = (i = findlast('_', s); i === nothing ? s : s[i+1:end])

# -------------------------------------------------------------------
# Entry point
# -------------------------------------------------------------------

function main(argv)
    args = parse_args(argv)

    # Load the module in a fresh anonymous Module so the user's file's
    # top-level bindings don't clobber our namespace.
    sandbox = Module(:__mtk_roundtrip_sandbox__)
    try
        Base.include(sandbox, args.module_path)
    catch e
        println(stderr, "✗ Failed to include $(args.module_path): " *
                sprint(showerror, e))
        exit(2)
    end

    sys, name = try
        discover_system(sandbox, args.system_name)
    catch e
        println(stderr, "✗ System discovery failed: " * sprint(showerror, e))
        exit(2)
    end

    tspan = args.tspan === nothing ? (0.0, 10.0) : args.tspan
    println("System: $name ($(typeof(sys)))")
    println("tspan: $tspan   rel_tol: $(args.rel_tol)   abs_tol: $(args.abs_tol)")

    ok = try
        roundtrip_one(sys, name; tspan=tspan, rel_tol=args.rel_tol,
            abs_tol=args.abs_tol, n_samples=args.n_samples)
    catch e
        println(stderr, "✗ Simulation / round-trip error: " *
                sprint(showerror, e))
        exit(3)
    end

    exit(ok ? 0 : 1)
end

using Printf

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
