# Mathematical Correctness Verification Module

The `earthsci_ast.verification` module provides comprehensive mathematical correctness verification for Earth System Model serialization and computational validation.

## Overview

This module implements algorithms and verification methods essential for ensuring the mathematical integrity of Earth system models, including:

- **Dimensional Analysis**: Unit consistency checking across equations
- **Conservation Law Verification**: Mass, energy, and charge conservation validation
- **Stoichiometric Balance**: Automated constraint generation and validation for reaction systems
- **System Solvability**: Equation count vs. variable count analysis
- **Numerical Stability**: Precision and stability analysis for numerical computations
- **Cross-Reference Validation**: Ensuring all variables and parameters are properly defined

## Core Classes

### `MathematicalVerifier`

The main verification class providing comprehensive mathematical correctness checking.

```python
from earthsci_ast.verification import MathematicalVerifier

verifier = MathematicalVerifier(tolerance=1e-10)
report = verifier.verify_reaction_system(reaction_system)
```

**Key Methods:**
- `verify_reaction_system(reaction_system)`: Complete verification of reaction systems
- `verify_model(model)`: Complete verification of mathematical models
- `compute_stoichiometric_matrix(reaction_system)`: Calculate stoichiometric matrices
- `verify_mass_balance(reaction, species_masses)`: Check mass conservation for reactions
- `analyze_conservation_laws(stoich_matrix, mass_vector)`: Analyze conserved quantities

### `VerificationReport`

Container for verification results with summary statistics.

```python
# Check if all verifications passed
if report.passed():
    print("All verifications successful")

# Access summary statistics
print(f"Passed: {report.summary['pass']}")
print(f"Failed: {report.summary['fail']}")
print(f"Warnings: {report.summary['warning']}")

# Iterate through individual results
for result in report.results:
    print(f"{result.status.value}: {result.message}")
```

### `VerificationResult`

Individual verification result with status, message, and detailed information.

**Status Types:**
- `PASS`: Verification succeeded
- `FAIL`: Critical verification failure
- `WARNING`: Non-critical issue detected
- `SKIP`: Verification skipped due to missing data

## Mathematical Verification Algorithms

### 1. Stoichiometric Matrix Computation

Computes the stoichiometric matrix S where S[i,j] represents the stoichiometric coefficient of species i in reaction j.

```python
# For reaction: A + B → C
# Matrix: [[-1], [-1], [1]]  (species A, B, C)

matrix = verifier.compute_stoichiometric_matrix(reaction_system)
```

**Algorithm:**
- Negative coefficients for reactants (consumed)
- Positive coefficients for products (produced)
- Matrix dimensions: (n_species × n_reactions)

### 2. Mass Conservation Verification

Validates mass balance for chemical reactions using molecular weights.

```python
# Verify individual reaction
is_conserved = verifier.verify_mass_balance(reaction, species_masses)

# Full system verification
conservation_analysis = verifier.analyze_conservation_laws(stoich_matrix, mass_vector)
```

**Mathematical Basis:**
- Reactant mass = Product mass (within numerical tolerance)
- Conservation matrix: M^T × S = 0 (where M is mass vector, S is stoichiometric matrix)

### 3. Conservation Law Analysis

Analyzes conserved quantities using null space decomposition.

```python
analysis = verifier.analyze_conservation_laws(stoich_matrix, mass_vector)
print(f"Conserved quantities: {analysis['conserved_quantities']}")
print(f"Matrix rank: {analysis['rank']}")
```

**Theory:**
- Uses Singular Value Decomposition (SVD) to find null space
- Number of conserved quantities = n_species - rank(S)
- Identifies linearly independent conservation laws

### 4. Numerical Stability Analysis

Checks numerical conditioning and stability properties.

```python
stability = verifier.check_numerical_stability(matrix)
print(f"Condition number: {stability['condition_number']}")
print(f"Well-conditioned: {stability['is_well_conditioned']}")
```

**Metrics:**
- **Condition Number**: κ(A) = σ_max/σ_min (ratio of largest to smallest singular values)
- **Well-conditioned threshold**: κ(A) < 10^12
- **Matrix rank** using SVD with tolerance cutoff

### 5. Dimensional Analysis Framework

Validates dimensional consistency of equations (SymPy integration).

```python
dim_results = verifier.verify_dimensional_consistency(equations)
```

**Features:**
- Expression parsing using SymPy
- Unit consistency checking
- Dimensional equation validation

## Usage Examples

### Basic Reaction System Verification

```python
from earthsci_ast.types import Species, Reaction, ReactionSystem
from earthsci_ast.verification import verify_reaction_system

# Define species with masses
species = [
    Species(name="CH4", mass=16.04),
    Species(name="O2", mass=31.998),
    Species(name="CO2", mass=44.01),
    Species(name="H2O", mass=18.015)
]

# Define combustion reaction: CH4 + 2O2 → CO2 + 2H2O
reaction = Reaction(
    name="methane_combustion",
    reactants={"CH4": 1, "O2": 2},
    products={"CO2": 1, "H2O": 2}
)

reaction_system = ReactionSystem("combustion", species=species, reactions=[reaction])

# Comprehensive verification
report = verify_reaction_system(reaction_system, tolerance=1e-4)

if report.passed():
    print("✓ All verifications passed")
else:
    print("✗ Verification failures detected")
    for result in report.results:
        if result.status.value == "fail":
            print(f"  FAIL: {result.message}")
```

### Model Verification

```python
from earthsci_ast.types import Model, ModelVariable, Equation
from earthsci_ast.verification import verify_model

# Define model variables
variables = {
    "x": ModelVariable(type="state", units="m"),
    "v": ModelVariable(type="state", units="m/s"),
    "a": ModelVariable(type="parameter", units="m/s^2", default=-9.8)
}

# Define equations of motion
equations = [
    Equation(lhs="dx_dt", rhs="v"),
    Equation(lhs="dv_dt", rhs="a")
]

model = Model(name="falling_object", variables=variables, equations=equations)

# Verify model consistency
report = verify_model(model)

print(f"Results: {len(report.results)} checks performed")
print(f"Status: {report.summary}")
```

### Advanced Conservation Analysis

```python
from earthsci_ast.verification import MathematicalVerifier
import numpy as np

verifier = MathematicalVerifier()

# Compute stoichiometric matrix
S = verifier.compute_stoichiometric_matrix(reaction_system)

# Define mass vector
masses = np.array([[16.04], [31.998], [44.01], [18.015]])  # CH4, O2, CO2, H2O

# Analyze conservation laws
analysis = verifier.analyze_conservation_laws(S, masses)

print(f"Matrix rank: {analysis['rank']}")
print(f"Conserved quantities: {analysis['conserved_quantities']}")
print(f"Mass conserved: {analysis['mass_conserved']}")
print(f"Singular values: {analysis['singular_values']}")
```

## Error Handling and Tolerance

### Numerical Tolerance

The verification module uses configurable numerical tolerance for floating-point comparisons:

```python
# High precision for exact calculations
verifier = MathematicalVerifier(tolerance=1e-12)

# Standard precision for molecular weight calculations
verifier = MathematicalVerifier(tolerance=1e-4)

# Relaxed precision for noisy experimental data
verifier = MathematicalVerifier(tolerance=1e-2)
```

### Common Issues and Solutions

**1. Mass Balance Failures**
- *Cause*: Incorrect molecular weights or stoichiometric coefficients
- *Solution*: Verify species masses and reaction stoichiometry
- *Tolerance*: Use appropriate precision (1e-4 for molecular weights)

**2. Matrix Conditioning Warnings**
- *Cause*: Nearly singular or ill-conditioned matrices
- *Solution*: Check for redundant reactions or linear dependencies
- *Diagnosis*: Use `check_numerical_stability()` for detailed analysis

**3. Variable-Equation Mismatches**
- *Cause*: Undefined variables in equations or unused variable definitions
- *Solution*: Ensure all equation variables are defined in the model
- *Status*: Generates `FAIL` for undefined variables, `WARNING` for unused variables

## Integration with ESM Format

The verification module integrates seamlessly with the ESM format type system:

```python
from earthsci_ast import load, verify_reaction_system

# Load ESM file
esm_data = load("model.json")

# Verify each reaction system
for rs in esm_data.reaction_systems:
    report = verify_reaction_system(rs)
    print(f"System '{rs.name}': {'PASS' if report.passed() else 'FAIL'}")

# Verify each model
for model in esm_data.models:
    report = verify_model(model)
    print(f"Model '{model.name}': {'PASS' if report.passed() else 'FAIL'}")
```

## Performance Considerations

### Computational Complexity

- **Stoichiometric Matrix**: O(n_species × n_reactions)
- **SVD Decomposition**: O(min(m,n)³) for m×n matrix
- **Mass Balance**: O(n_reactions × n_species)
- **Conservation Analysis**: O(n_species³) for SVD

### Memory Usage

- Stoichiometric matrices: 8 × n_species × n_reactions bytes (float64)
- Large systems (>1000 species): Consider sparse matrix representations
- Batch processing recommended for multiple systems

### Optimization Tips

```python
# Pre-compute stoichiometric matrix for multiple analyses
verifier = MathematicalVerifier()
S = verifier.compute_stoichiometric_matrix(reaction_system)

# Reuse for different mass vectors
for mass_vector in mass_scenarios:
    analysis = verifier.analyze_conservation_laws(S, mass_vector)
```

## Future Extensions

Planned enhancements for the verification module:

1. **Energy Conservation**: Thermodynamic consistency checking
2. **Charge Conservation**: Ionic balance verification for electrochemical systems
3. **Unit System Integration**: Full dimensional analysis with Pint integration
4. **Symbolic Verification**: Enhanced SymPy integration for symbolic math
5. **Performance Optimization**: Sparse matrix support for large systems
6. **Interactive Diagnostics**: Detailed error reporting with suggested fixes

## Mathematical Background

### Conservation Laws in Chemical Systems

For a reaction system with stoichiometric matrix S, conservation laws are represented by vectors c such that:

```
c^T × S = 0
```

The number of independent conservation laws equals the nullity of S (n_species - rank(S)).

### Mass Conservation Matrix

For mass conservation, the mass-weighted balance must hold:

```
M^T × S = 0
```

where M is the vector of species molecular weights.

### Numerical Stability Theory

A matrix A is well-conditioned if its condition number κ(A) is small:

```
κ(A) = ||A|| × ||A^(-1)|| = σ_max / σ_min
```

Large condition numbers indicate numerical instability and potential accuracy loss in computations.