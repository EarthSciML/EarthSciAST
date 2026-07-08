# ESM Format Documentation

**EarthSciML Serialization Format — Complete Documentation**

Welcome to the comprehensive documentation for the ESM format and its implementation libraries. This documentation will guide you through everything from basic usage to advanced model authoring techniques.

## 📚 Table of Contents

### Getting Started
- [**Installation & Setup**](getting-started/installation.md) — Install ESM libraries for your language
- [**Quick Start Guide**](getting-started/quick-start.md) — Your first ESM file in 5 minutes
- [**Language-Specific Guides**](getting-started/) — Choose your language:
  - [Julia](getting-started/julia.md) — ModelingToolkit integration & simulation
  - [TypeScript/JavaScript](getting-started/typescript.md) — Web applications & interactive tools
  - [Python](getting-started/python.md) — Scientific computing & data analysis
  - [Rust](getting-started/rust.md) — High-performance CLI tools & WASM

### Tutorial Series
- [**Understanding ESM Format**](tutorial/esm-format-overview.md) — Core concepts and structure
- [**Building Your First Model**](tutorial/first-model.md) — Step-by-step atmospheric chemistry example
- [**Advanced Model Composition**](tutorial/model-composition.md) — Coupling multiple components
- [**Working with Expressions**](tutorial/expressions.md) — Mathematical notation and manipulation

### Real-World Examples
- [**Minimal Example**](examples/minimal.md) — The simplest valid ESM file
- [**Atmospheric Chemistry**](examples/atmospheric-chemistry.md) — Gas-phase reactions with species transport
- [**Biogeochemical Cycling**](examples/biogeochemistry.md) — Land-atmosphere carbon exchange
- [**Multi-Component System**](examples/multi-component.md) — Coupled atmosphere-ocean-land model
- [**Advanced Features**](examples/advanced/) — Constraint equations, algebraic variables, and more

### Best Practices & Guides
- [**Model Authoring Guidelines**](guides/authoring-best-practices.md) — Write maintainable, reusable models
- [**Version Migration Guide**](guides/migration.md) — Upgrade between ESM format versions
- [**Performance Optimization**](guides/performance.md) — Speed up parsing, validation, and simulation
- [**Validation Strategies**](guides/validation.md) — Ensure model correctness
- [**Coupling Patterns**](guides/coupling-patterns.md) — Common model composition techniques

### Troubleshooting & Support
- [**Common Validation Errors**](troubleshooting/validation-errors.md) — Fix schema and structural issues
- [**Expression Parsing Issues**](troubleshooting/expression-issues.md) — Debug mathematical expressions
- [**Performance Problems**](troubleshooting/performance.md) — Diagnose slow loading or validation
- [**Language-Specific Issues**](troubleshooting/language-specific.md) — Platform and runtime problems

## 🚀 Quick Navigation

### I want to...
- **Get started immediately** → [Quick Start Guide](getting-started/quick-start.md)
- **Understand the format** → [ESM Format Overview](tutorial/esm-format-overview.md)
- **See working examples** → [Examples Directory](examples/)
- **Solve a specific problem** → [Troubleshooting Guide](troubleshooting/)
- **Learn best practices** → [Authoring Guidelines](guides/authoring-best-practices.md)

### I'm working in...
- **Julia** → [Julia Getting Started](getting-started/julia.md)
- **Web/TypeScript** → [TypeScript Getting Started](getting-started/typescript.md)
- **Python** → [Python Getting Started](getting-started/python.md)
- **Rust/CLI** → [Rust Getting Started](getting-started/rust.md)

## 📖 Format Specification

The authoritative format specification is available in the repository root:
- [**ESM Format Specification**](../esm-spec.md) — Complete format definition
- [**Library Specification**](../esm-libraries-spec.md) — Implementation requirements
- [**JSON Schema**](../esm-schema.json) — Machine-readable format definition

## 🤝 Contributing

Found an error or want to improve the documentation? Please see our [contributing guidelines](../CONTRIBUTING.md).

## 🆘 Need Help?

- **Documentation Issues** — File an issue in our [GitHub repository](https://github.com/EarthSciML/EarthSciAST)
- **Format Questions** — Check the [troubleshooting guide](troubleshooting/) first
- **Implementation Bugs** — Report in the appropriate package repository

---

*This documentation covers ESM Format version 0.1.0. Last updated: February 2026.*