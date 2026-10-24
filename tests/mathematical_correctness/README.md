# Mathematical Correctness Verification Test Fixtures

This directory contains comprehensive test fixtures for mathematical correctness verification across all Earth System Model (ESM) operations. These fixtures ensure scientific accuracy, numerical stability, and mathematical consistency across all language implementations.

## Overview

The mathematical correctness verification test fixtures provide:

- **100+ comprehensive test cases** covering all mathematical operations
- **Expected results with precise tolerance specifications**
- **Performance benchmarks for verification algorithms**
- **Cross-language consistency requirements**
- **Mathematical background documentation**

## Test Categories

### 1. Conservation Laws Tests (`conservation_laws.esm`)
**24 test cases** covering fundamental conservation principles:

#### Mass Conservation
- Simple reactions (A + B → C)
- Complex combustion (CH₄ + 2O₂ → CO₂ + 2H₂O)
- Multi-step reaction chains
- Catalytic cycles with catalyst conservation

#### Charge Conservation
- Ionic reactions (Ag⁺ + Cl⁻ → AgCl)
- Electrochemical reactions (Zn + Cu²⁺ → Zn²⁺ + Cu)
- Redox balance verification

#### Energy Conservation
- Thermodynamic reactions with enthalpy tracking
- Phase transitions (H₂O(l) ⇌ H₂O(g))
- Photochemical reactions with photon energy

#### Momentum and Angular Momentum
- Fluid reaction systems
- Rotational molecular systems
- Vector conservation verification

#### Specialized Conservation
- Nuclear decay with mass-energy equivalence
- Complex reaction networks with multiple conservation laws

### 2. Dimensional Analysis Tests (`dimensional_analysis.esm`)
**52 test cases** covering dimensional consistency verification:

#### Fundamental Physical Laws
- Newton's second law: F = ma
- Kinetic energy: E = ½mv²
- Ideal gas law: PV = nRT
- Maxwell's equations

#### Fluid Mechanics
- Navier-Stokes equations
- Continuity equation
- Reynolds number and other dimensionless groups

#### Heat Transfer
- Fourier's law: q = -k∇T
- Heat equation: ∂T/∂t = α∇²T
- Stefan-Boltzmann law

#### Chemical Systems
- Arrhenius equation: k = A exp(-Ea/RT)
- Reaction rate laws
- Michaelis-Menten kinetics

#### Quantum and Relativistic
- Schrödinger equation
- Einstein mass-energy: E = mc²
- Planck's blackbody formula

#### Error Cases
- Dimensional mismatches in addition
- Non-dimensionless exponential arguments
- Mixed unit system inconsistencies

### 3. Numerical Correctness Tests (`numerical_correctness.esm`)
**28 test cases** covering numerical accuracy and stability:

#### Floating-Point Precision
- Machine epsilon verification
- Catastrophic cancellation detection
- Round-off error accumulation

#### Iterative Method Convergence
- Newton-Raphson method
- Bisection method
- Fixed-point iteration

#### Stiff System Stability
- Fast-slow dynamical systems
- Van der Pol oscillator
- Explicit vs. implicit method stability

#### Ill-Conditioned Systems
- Hilbert matrices
- Vandermonde matrices
- Condition number analysis

#### Special Function Accuracy
- Exponential and logarithmic functions
- Trigonometric functions
- Gamma function

#### Integration and ODE Solving
- Numerical integration accuracy
- ODE solver verification
- Conservation in Hamiltonian systems

#### Linear Algebra Verification
- Matrix inversion accuracy
- Eigenvalue computation
- Linear system solving

### 4. Algebraic Verification Tests (`algebraic_verification.esm`)
**32 test cases** covering symbolic mathematics:

#### Expression Simplification
- Polynomial expansion and factoring
- Rational expression simplification
- Trigonometric identities
- Logarithmic and exponential simplification

#### Equation Solving
- Linear systems
- Quadratic equations
- Higher-order polynomials
- Transcendental equations

#### Symbolic Calculus
- Differentiation rules (power, product, chain, implicit)
- Integration techniques (substitution, by parts)
- Series expansions

#### Matrix Algebra
- Matrix operations verification
- Determinant calculation
- Eigenvalue/eigenvector computation

#### Complex Number Algebra
- Arithmetic operations
- Polar form conversions
- De Moivre's theorem

## Tolerance Specifications

### Precision Requirements
- **Exact algebraic operations**: 1e-15 (machine precision)
- **Floating-point arithmetic**: 1e-12 to 1e-15
- **Molecular weight calculations**: 1e-8 to 1e-10
- **Thermodynamic properties**: 1e-6 to 1e-8
- **Iterative convergence**: User-specified tolerance
- **Statistical computations**: 1e-3 to 1e-6

### Tolerance Categories
```json
{
  "machine_precision": 1e-15,
  "numerical_precision": 1e-12,
  "physical_constants": 1e-10,
  "molecular_weights": 1e-8,
  "thermodynamic": 1e-6,
  "experimental_data": 1e-3
}
```

## Performance Benchmarks

### Computational Complexity Targets

#### Stoichiometric Matrix Operations
- Small systems (10 species, 5 reactions): < 1 ms
- Medium systems (100 species, 50 reactions): < 50 ms
- Large systems (1000 species, 500 reactions): < 2000 ms

#### Conservation Analysis
- SVD decomposition (100×100): < 10 ms
- Null space computation (500×500): < 100 ms

#### Dimensional Verification
- Simple equation (3 variables): < 0.1 ms
- Complex equation (10 variables): < 1 ms
- System verification (100 equations): < 100 ms

#### Numerical Algorithms
- ODE solver (10000 steps): < 500 ms
- Matrix operations (1000×1000): < 1000 ms
- Optimization (1000 evaluations): < 100 ms

## Cross-Language Consistency Requirements

### Identical Results Requirement
All language implementations must produce **identical results** within specified tolerances for:

1. **Stoichiometric matrix computation**
2. **Mass balance verification**
3. **Conservation law analysis**
4. **Dimensional consistency checking**
5. **Numerical precision verification**

### Language-Specific Considerations

#### Julia
- Native arbitrary-precision arithmetic
- Excellent linear algebra performance
- Symbolic computation via SymPy.jl

#### Python
- NumPy for numerical operations
- SymPy for symbolic mathematics
- SciPy for advanced algorithms

#### TypeScript/JavaScript
- Limited precision (64-bit floats)
- Decimal.js for extended precision
- Math.js for advanced operations

#### Rust
- High performance numerical computing
- Precise control over floating-point behavior
- Safety guarantees

#### Go
- Standard library math functions
- Third-party libraries for advanced operations
- Consistent floating-point behavior

## Mathematical Background

### Conservation Laws Theory
Conservation laws arise from fundamental symmetries in physical systems (Noether's theorem):
- **Mass conservation**: Continuity equation
- **Energy conservation**: First law of thermodynamics
- **Momentum conservation**: Newton's laws
- **Charge conservation**: Electromagnetic field equations

### Dimensional Analysis Principles
Dimensional analysis ensures physical equations are consistent:
- **Homogeneity**: All terms must have same dimensions
- **Dimensionless groups**: Reynolds, Prandtl, Nusselt numbers
- **Scaling laws**: Relationship between variables

### Numerical Stability Theory
Stability analysis for computational algorithms:
- **Condition numbers**: Measure of problem sensitivity
- **Stiffness**: Multiple time scales in ODEs
- **Error propagation**: Accumulated computational errors

### Symbolic Mathematics Foundations
Algebraic manipulation rules and verification:
- **Equivalence checking**: Symbolic expression comparison
- **Identity verification**: Mathematical identities
- **Domain restrictions**: Function validity regions

## How these files are used

These documents are fixtures, not a test suite of their own. Today the only
code that reads them is the Rust round-trip test
(`pkg/earthsci-ast-rs/tests/round_trip.rs`,
`test_mathematical_correctness_round_trip`), which loads
`conservation_laws.esm` and `dimensional_analysis.esm` and checks that they
serialize back unchanged. No binding checks the conservation, dimensional,
numerical or algebraic claims described above against these files; the
categories record what each file is meant to exercise.

The executable mathematical-correctness case is
`tests/validation/mathematical_correctness.esm`, whose inline tests the Python
and Rust suites run (`test_reaction_system_inline_tests.py`,
`rhs_time_derivative.rs`).

```bash
cd pkg/earthsci-ast-rs && cargo test --test round_trip test_mathematical_correctness_round_trip
```

## Extending the Test Suite

### Adding New Test Cases
1. Define test case in appropriate `.esm` file
2. Specify expected results and tolerances
3. Include mathematical background
4. Add performance benchmarks
5. Verify cross-language consistency

### Test Case Format
```json
{
  "name": "test_case_name",
  "description": "Mathematical description",
  "test_data": {
    "input": "...",
    "expected_output": "...",
    "tolerance": 1e-12
  },
  "verification_method": "algorithm_name",
  "mathematical_background": "theory_reference"
}
```

## Quality Assurance

### Verification Checklist
- [ ] Mathematical correctness verified analytically
- [ ] Numerical precision within specified tolerances
- [ ] Cross-language consistency confirmed
- [ ] Performance benchmarks met
- [ ] Edge cases and error conditions covered
- [ ] Documentation complete and accurate

## References

1. Golub, G.H. & Van Loan, C.F. (2012). *Matrix Computations*. 4th ed.
2. Hairer, E. & Wanner, G. (2010). *Solving Ordinary Differential Equations II: Stiff and Differential-Algebraic Problems*.
3. Press, W.H. et al. (2007). *Numerical Recipes: The Art of Scientific Computing*. 3rd ed.
4. Atkinson, K.E. (1989). *An Introduction to Numerical Analysis*. 2nd ed.
5. Nocedal, J. & Wright, S.J. (2006). *Numerical Optimization*. 2nd ed.