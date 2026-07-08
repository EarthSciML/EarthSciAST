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

## Usage Examples

### Conservation Law Verification
```python
from earthsci_ast.verification import verify_reaction_system
from earthsci_ast.types import ReactionSystem

# Load test case
system = load_test_case("conservation_laws.esm", "mass_conservation_combustion")

# Verify conservation
report = verify_reaction_system(system, tolerance=1e-10)

# Check results
assert report.passed()
assert report.summary["pass"] > 0
assert report.summary["fail"] == 0
```

### Dimensional Analysis
```python
from earthsci_ast.verification import verify_dimensional_consistency

# Load dimensional test
equation = load_test_case("dimensional_analysis.esm", "newton_second_law")

# Verify dimensions
results = verify_dimensional_consistency([equation])

# Validate consistency
assert all(r.status == VerificationStatus.PASS for r in results)
```

### Numerical Precision Testing
```python
from earthsci_ast.verification import check_numerical_stability

# Test matrix conditioning
matrix = load_test_matrix("numerical_correctness.esm", "hilbert_matrix")

# Analyze stability
stability = check_numerical_stability(matrix)

# Verify within acceptable bounds
assert stability["condition_number"] < 1e12
assert stability["is_well_conditioned"]
```

## Test Execution

### Running All Tests
```bash
# Python implementation
cd pkg/earthsci-ast-py
source venv/bin/activate
python -m pytest tests/test_mathematical_verification.py -v

# Julia implementation
cd pkg/EarthSciAST.jl
julia --project=. -e 'using Pkg; Pkg.test()'

# TypeScript implementation
cd pkg/earthsci-ast-ts
npm test
```

### Individual Test Categories
```bash
# Conservation laws only
python -m pytest tests/test_mathematical_verification.py::TestMassConservationVerification -v

# Dimensional analysis only
python -m pytest tests/test_mathematical_verification.py::TestDimensionalAnalysisVerification -v

# Numerical precision only
python -m pytest tests/test_mathematical_verification.py::TestNumericalStabilityVerification -v
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

### Continuous Integration
All test fixtures are automatically verified in CI/CD pipelines across all supported languages, ensuring:
- **Consistency**: Identical results across implementations
- **Accuracy**: Mathematical correctness maintained
- **Performance**: Computational efficiency preserved
- **Reliability**: Robust error handling

## References

1. Golub, G.H. & Van Loan, C.F. (2012). *Matrix Computations*. 4th ed.
2. Hairer, E. & Wanner, G. (2010). *Solving Ordinary Differential Equations II: Stiff and Differential-Algebraic Problems*.
3. Press, W.H. et al. (2007). *Numerical Recipes: The Art of Scientific Computing*. 3rd ed.
4. Atkinson, K.E. (1989). *An Introduction to Numerical Analysis*. 2nd ed.
5. Nocedal, J. & Wright, S.J. (2006). *Numerical Optimization*. 2nd ed.