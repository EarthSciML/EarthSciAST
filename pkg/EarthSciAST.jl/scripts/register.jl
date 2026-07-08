#!/usr/bin/env julia

"""
Package registration script for EarthSciAST.jl

This script automates the process of registering EarthSciAST.jl with the Julia General Registry.
It performs pre-registration checks, validates the package, and guides through the registration process.

Usage:
    julia scripts/register.jl [--check-only] [--force]

Options:
    --check-only    Only run validation checks without attempting registration
    --force        Skip some validation checks (use with caution)
"""

using Pkg
using TOML

function print_banner()
    println("="^60)
    println("   EarthSciAST.jl Package Registration Tool")
    println("="^60)
    println()
end

function check_project_structure()
    println("🔍 Checking project structure...")

    required_files = [
        "Project.toml",
        "src/EarthSciAST.jl",
        "test/runtests.jl",
        "README.md"
    ]

    missing_files = []
    for file in required_files
        if !isfile(file)
            push!(missing_files, file)
        end
    end

    if !isempty(missing_files)
        println("❌ Missing required files:")
        for file in missing_files
            println("   - $file")
        end
        return false
    end

    println("✅ All required files present")
    return true
end

function check_project_toml()
    println("📋 Validating Project.toml...")

    project = TOML.parsefile("Project.toml")

    required_fields = ["name", "uuid", "version", "authors"]
    missing_fields = []

    for field in required_fields
        if !haskey(project, field)
            push!(missing_fields, field)
        end
    end

    if !isempty(missing_fields)
        println("❌ Missing required Project.toml fields:")
        for field in missing_fields
            println("   - $field")
        end
        return false
    end

    # Validate version format
    version_str = project["version"]
    try
        version = VersionNumber(version_str)
        if version < v"0.1.0"
            println("⚠️  Version $version_str is below 0.1.0, consider if this is intentional")
        else
            println("✅ Version: $version_str")
        end
    catch e
        println("❌ Invalid version format: $version_str")
        return false
    end

    # Check UUID format
    uuid_str = project["uuid"]
    uuid_pattern = r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    if !occursin(uuid_pattern, uuid_str)
        println("❌ Invalid UUID format: $uuid_str")
        return false
    end

    println("✅ Project.toml is valid")
    return true
end

function run_tests()
    println("🧪 Running package tests...")

    try
        # Activate the local project environment
        Pkg.activate(".")

        # Run tests
        Pkg.test()

        println("✅ All tests passed")
        return true
    catch e
        println("❌ Tests failed: $e")
        return false
    end
end

function check_documentation()
    println("📚 Checking documentation...")

    if !isdir("docs")
        println("⚠️  No docs/ directory found")
        return false
    end

    required_docs = [
        "docs/Project.toml",
        "docs/make.jl",
        "docs/src/index.md"
    ]

    missing_docs = []
    for doc in required_docs
        if !isfile(doc)
            push!(missing_docs, doc)
        end
    end

    if !isempty(missing_docs)
        println("❌ Missing documentation files:")
        for doc in missing_docs
            println("   - $doc")
        end
        return false
    end

    println("✅ Documentation structure looks good")
    return true
end

function check_license()
    println("⚖️  Checking license...")

    license_files = ["LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING"]

    for license_file in license_files
        if isfile(license_file)
            println("✅ License file found: $license_file")
            return true
        end
    end

    # Check if license is specified in Project.toml
    project = TOML.parsefile("Project.toml")
    if haskey(project, "license")
        println("✅ License specified in Project.toml: $(project["license"])")
        return true
    end

    println("⚠️  No license file found - consider adding one")
    return false
end

function print_registration_instructions()
    project = TOML.parsefile("Project.toml")
    pkg_name = project["name"]

    println()
    println("📦 Package Registration Instructions")
    println("="^40)
    println()
    println("To register $pkg_name with the Julia General Registry:")
    println()
    println("1. Ensure all code is committed and pushed to GitHub")
    println("2. Create a GitHub release/tag for the version you want to register")
    println("3. Use one of these methods:")
    println()
    println("   Method A - Registrator.jl (GitHub comment):")
    println("   - Go to your repository on GitHub")
    println("   - Create an issue or comment on a commit")
    println("   - Write: @JuliaRegistrator register")
    println()
    println("   Method B - PkgDev.jl:")
    println("   - julia> using PkgDev")
    println("   - julia> PkgDev.register(\"$pkg_name\")")
    println()
    println("   Method C - Registrator web interface:")
    println("   - Visit: https://juliahub.com/ui/Packages")
    println("   - Follow the registration instructions")
    println()
    println("4. Wait for the registration pull request to be merged")
    println("5. Once merged, users can install with: Pkg.add(\"$pkg_name\")")
    println()
end

function main()
    args = ARGS
    check_only = "--check-only" in args
    force = "--force" in args

    print_banner()

    # Run validation checks
    checks_passed = true

    checks_passed &= check_project_structure()
    checks_passed &= check_project_toml()
    checks_passed &= check_documentation()
    checks_passed &= check_license()

    if !force
        checks_passed &= run_tests()
    else
        println("⚠️  Skipping tests due to --force flag")
    end

    println()

    if checks_passed
        println("🎉 All validation checks passed!")

        if !check_only
            print_registration_instructions()
        end
    else
        println("❌ Some validation checks failed.")
        println("   Please fix the issues above before registering.")
        exit(1)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end