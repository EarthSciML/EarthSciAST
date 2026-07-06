#!/usr/bin/env julia

"""
EarthSciSerialization.jl Package Setup and Integration Script

This script sets up the complete package registration infrastructure including:
- Documentation generation
- CI/CD configuration
- Compatibility testing
- Registry submission preparation

Usage:
    julia scripts/setup_package.jl [--docs] [--test] [--all]

Options:
    --docs    Generate documentation
    --test    Run compatibility tests
    --all     Run all setup steps
"""

using Pkg

function print_header()
    println("="^70)
    println("   EarthSciSerialization.jl Package Integration & Registration Setup")
    println("="^70)
    println()
end

function setup_documentation()
    println("📚 Setting up documentation...")

    # Activate docs environment
    Pkg.activate("docs")

    # Add dependencies
    try
        Pkg.develop(PackageSpec(path=pwd()))
        Pkg.instantiate()
        println("✅ Documentation environment configured")
    catch e
        println("❌ Failed to setup docs environment: $e")
        return false
    end

    # Generate documentation
    try
        include("docs/make.jl")
        println("✅ Documentation generated successfully")
        return true
    catch e
        println("❌ Documentation generation failed: $e")
        return false
    end
end

function run_compatibility_tests()
    println("🧪 Running package test suite...")

    # Activate main environment
    Pkg.activate(".")

    try
        Pkg.test()
        return true
    catch e
        println("❌ Package tests failed: $e")
        return false
    end
end

function validate_package_structure()
    println("🔍 Validating package structure...")

    required_files = [
        "Project.toml" => "Package configuration",
        "src/EarthSciSerialization.jl" => "Main module file",
        "test/runtests.jl" => "Test suite",
        "README.md" => "Package documentation",
        ".github/workflows/CI.yml" => "Continuous Integration",
        "docs/make.jl" => "Documentation generator",
        "scripts/register.jl" => "Registration script",
    ]

    all_present = true
    for (file, description) in required_files
        if isfile(file)
            println("✅ $file - $description")
        else
            println("❌ $file - $description (MISSING)")
            all_present = false
        end
    end

    return all_present
end

function check_registry_readiness()
    println("📋 Checking registry readiness...")

    # Run the registration validation script
    try
        include("scripts/register.jl")
        return true
    catch e
        println("❌ Registry readiness check failed: $e")
        return false
    end
end

function generate_summary_report()
    println()
    println("="^50)
    println("   PACKAGE REGISTRATION SUMMARY")
    println("="^50)

    project = TOML.parsefile("Project.toml")

    println("Package Name: ", project["name"])
    println("Version: ", project["version"])
    println("UUID: ", project["uuid"])
    println("Authors: ", join(project["authors"], ", "))

    println()
    println("✅ Package structure validated")
    println("✅ Documentation configured")
    println("✅ CI/CD pipeline ready")
    println("✅ Compatibility tests created")
    println("✅ Registration script available")

    println()
    println("🚀 Ready for registration!")
    println()
    println("Next steps:")
    println("1. Run: julia scripts/register.jl --check-only")
    println("2. Fix any validation issues")
    println("3. Commit and push all changes")
    println("4. Create a GitHub release")
    println("5. Run: julia scripts/register.jl")
    println("6. Follow the registration instructions")
    println()
end

function main()
    args = ARGS
    run_docs = "--docs" in args || "--all" in args
    run_tests = "--test" in args || "--all" in args
    run_all = "--all" in args || (isempty(args))  # Default to all if no args

    print_header()

    success = true

    # Always validate structure
    success &= validate_package_structure()

    if run_docs || run_all
        # Return to main directory for docs setup
        cd(dirname(dirname(@__FILE__)))
        success &= setup_documentation()
        # Reactivate main environment
        Pkg.activate(".")
    end

    if run_tests || run_all
        success &= run_compatibility_tests()
    end

    if run_all
        success &= check_registry_readiness()
    end

    if success
        generate_summary_report()
    else
        println()
        println("❌ Setup completed with errors. Please review the output above.")
        exit(1)
    end
end

# Import TOML for project parsing
using TOML

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end