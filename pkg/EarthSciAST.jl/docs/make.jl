using EarthSciAST
using Documenter

DocMeta.setdocmeta!(EarthSciAST, :DocTestSetup, :(using EarthSciAST); recursive = true)

# Local build and doctest check only. The published documentation is built by
# earthsci.dev (https://earthsci.dev/ast/); nothing deploys from here.
makedocs(;
    modules = [EarthSciAST],
    authors = "Chris Tessum with Claude <noreply@anthropic.com> and contributors",
    sitename = "EarthSciAST.jl",
    format = Documenter.HTML(;
        edit_link = "main",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting-started.md",
        "Simulation Runners" => "simulation-runners.md",
        "Compiled Backend Devices" => "compiled-backend-devices.md",
    ],
    warnonly = true,
)
