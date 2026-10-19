module github.com/EarthSciML/EarthSciAST/docs/api/examples/go

go 1.22

// The examples document the package in this checkout, not a published release.
// go.work adds the package to the workspace, so its own go.mod and go.sum pin
// every dependency and this module lists none of its own.
replace github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go => ../../../../pkg/earthsci-ast-go

require github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go v0.0.0-00010101000000-000000000000
