using EarthSciAST
using Documenter

DocMeta.setdocmeta!(EarthSciAST, :DocTestSetup, :(using EarthSciAST); recursive=true)

makedocs(;
    modules=[EarthSciAST],
    authors="Chris Tessum with Claude <noreply@anthropic.com> and contributors",
    sitename="EarthSciAST.jl",
    format=Documenter.HTML(;
        canonical="https://earthsciml.github.io/EarthSciAST/pkg/EarthSciAST.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting-started.md",
        "Simulation Runners" => "simulation-runners.md",
        "API Reference" => [
            "Types" => "api/types.md",
            "Parsing & Serialization" => "api/io.md",
            "Validation" => "api/validation.md",
            "Expressions" => "api/expressions.md",
            "Model Composition" => "api/composition.md",
            "MTK Integration" => "api/mtk.md",
            "Catalyst Integration" => "api/catalyst.md",
            "Units & Dimensions" => "api/units.md",
            "Graph Analysis" => "api/graphs.md",
        ],
        "Examples" => [
            "Basic Usage" => "examples/basic.md",
            "Model Coupling" => "examples/coupling.md",
            "Reaction Networks" => "examples/reactions.md",
            "Unit Validation" => "examples/units.md",
        ],
        "Developer Guide" => "developer.md",
    ],
    warnonly=true,
)

deploydocs(;
    repo="github.com/EarthSciML/EarthSciAST.git",
    devbranch="main",
    dirname="pkg/EarthSciAST.jl",
)