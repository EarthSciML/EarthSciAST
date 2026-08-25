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
    ],
    warnonly=true,
)

deploydocs(;
    repo="github.com/EarthSciML/EarthSciAST.git",
    devbranch="main",
    dirname="pkg/EarthSciAST.jl",
)