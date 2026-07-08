# End-to-End Coupled System Simulation Test Fixtures

This directory contains comprehensive end-to-end test fixtures that exercise the complete workflow from ESM file to simulation results. These fixtures validate the entire Earth system model behavior including all coupling types, system assembly verification, cross-system variable flow validation, and operator composition results.

## Test Fixtures

### 1. Coupled Atmospheric System (`coupled_atmospheric_system.esm`)

**Domain**: Atmospheric chemistry with transport, deposition, emissions, and meteorology
**Duration**: 48 hours
**Spatial Domain**: 167×167×150 grid cells (12km horizontal, 100m vertical)
**Key Features**:
- NOx-O3-VOC photochemistry with temperature-dependent kinetics
- 3D advection-diffusion transport
- Bidirectional air-surface exchange (dry deposition)
- Time-varying anthropogenic and biogenic emissions
- All 6 coupling types demonstrated
- Cross-system events (ozone exceedance, emission control)

**Coupling Types Tested**:
- `operator_compose`: Chemistry + Transport via `_var` placeholder
- `couple`: Chemistry ↔ Surface Exchange via connector equations
- `variable_map`: Meteorology → Chemistry, Emissions → Sources (8 mappings)
- `operator_apply`: Dry deposition, turbulent mixing, photolysis (3 operators)
- `callback`: Biogenic emission scaling, weekday/weekend factors (2 callbacks)
- `event`: High ozone control, weekend reduction, PBL collapse (3 events)

### 2. Ocean-Atmosphere Biogeochemistry (`ocean_atmosphere_biogeochemistry.esm`)

**Domain**: Ocean-atmosphere carbon and oxygen cycles with marine ecosystem
**Duration**: 1 year
**Spatial Domain**: 180×90×100 grid cells (2° horizontal, 50m vertical)
**Key Features**:
- Atmospheric CO2 and O2 with air-sea gas exchange
- Ocean carbonate chemistry (DIC, alkalinity, pH)
- NPZD marine ecosystem model
- Seasonal cycles and biogeochemical feedbacks
- Climate forcing from CESM2

**Coupling Types Tested**:
- `couple`: Air-sea gas exchange (CO2, O2) and ocean-ecosystem coupling (4 connector equations)
- `variable_map`: Climate forcing → all systems (4 mappings)
- `operator_apply`: Carbonate chemistry, gas transfer, biological pump (3 operators)
- `callback`: Seasonal light and mixed layer depth cycles (2 callbacks)
- `event`: Bloom dynamics, acidification response, nutrient upwelling (3 events)

### 3. Land-Atmosphere Hydrology (`land_atmosphere_hydrology.esm`)

**Domain**: Land-atmosphere water and energy cycles with vegetation dynamics
**Duration**: 1 year
**Spatial Domain**: 720×360 grid cells (0.5° resolution)
**Key Features**:
- Atmospheric boundary layer with temperature, humidity, momentum
- Multi-layer soil hydrology and thermal dynamics
- Dynamic vegetation with LAI, biomass, and phenology
- Surface energy balance with sensible and latent heat fluxes
- Seasonal cycles and eco-hydrological feedbacks

**Coupling Types Tested**:
- `couple`: Atmosphere-surface energy exchange, surface-soil heat transfer, vegetation-soil water coupling (3 couplers)
- `variable_map`: Meteorological forcing + soil properties (9 mappings)
- `operator_apply`: Surface albedo, stomatal conductance, soil thermal properties (3 operators)
- `callback`: Precipitation infiltration, seasonal phenology (2 callbacks)
- `event`: Drought stress, soil saturation, leaf senescence (3 events)

## Expected Simulation Results

Each ESM file has a corresponding `*_results.json` file containing:

### Coupling Verification
- Verification that all coupling types are properly assembled
- System assembly verification (total variables, equations, conservation laws)
- Cross-system variable flow validation
- Mass and energy balance closure requirements

### Expected Numerical Results
- Temporal evolution (seasonal and diurnal cycles)
- Spatial patterns and gradients
- Event triggering and responses
- Process interactions and feedbacks

### Validation Requirements
- Tolerance specifications for different variable types
- Conservation law closure requirements
- Process coupling consistency tests
- Performance benchmarks for different simulation backends

## Testing Requirements by Language/Framework

### Julia + ModelingToolkit.jl
- Parse ESM → ODESystem with correct number of state variables and equations
- Parse coupling rules → CoupledSystem assembly
- Generate appropriate SymbolicContinuousCallback/SymbolicDiscreteCallback for events
- Simulate with appropriate solver (QNDF for stiff, Vern7 for non-stiff)
- Verify mass/energy conservation within specified tolerances
- Compare trajectories against expected results

### Python + SciPy
- Parse ESM → callable RHS function
- Generate Jacobian for stiff solvers (BDF method)
- Implement event detection and handling
- Verify conservation laws and flux calculations
- Cross-validate results with Julia MTK simulation
- Test operator composition by comparing component vs full system

### TypeScript/JavaScript
- Parse and validate ESM schema compliance
- Generate expression graphs for visualization
- Create coupling graph representation
- Export interactive editor formats
- Support parameter and initial condition editing

## File Organization

```
end_to_end/
├── README.md                                          # This file
├── coupled_atmospheric_system.esm                     # Atmospheric chemistry test
├── coupled_atmospheric_system_results.json            # Expected results & validation
├── ocean_atmosphere_biogeochemistry.esm              # Biogeochemical cycles test
├── ocean_atmosphere_biogeochemistry_results.json     # Expected results & validation
├── land_atmosphere_hydrology.esm                     # Land-atmosphere coupling test
└── land_atmosphere_hydrology_results.json            # Expected results & validation
```

## Integration with Test Suite

These end-to-end fixtures should be integrated into the language-specific test suites:

1. **Schema Validation**: All ESM files must pass JSON schema validation
2. **Parsing Tests**: Each backend must successfully parse all ESM files
3. **Assembly Tests**: Verify correct coupling and system assembly
4. **Simulation Tests**: Run full simulations and validate against expected results
5. **Performance Tests**: Benchmark assembly and simulation times
6. **Cross-Validation**: Compare results between different backends (Julia vs Python)

## Usage Examples

### Julia Example
```julia
using EarthSciAST

# Load and parse the ESM file
esm = load_esm("coupled_atmospheric_system.esm")

# Convert to ModelingToolkit ODESystem
ode_sys = esm_to_odesystem(esm)

# Set up and solve the ODE problem
prob = ODEProblem(ode_sys, u0, tspan, p)
sol = solve(prob, QNDF())

# Validate against expected results
validate_simulation_results(sol, "coupled_atmospheric_system_results.json")
```

### Python Example
```python
import earthsci_ast

# Load and parse the ESM file
esm = earthsci_ast.load_esm("ocean_atmosphere_biogeochemistry.esm")

# Convert to callable function
rhs_func, jacobian = earthsci_ast.to_scipy_function(esm)

# Solve with BDF method
from scipy.integrate import solve_ivp
sol = solve_ivp(rhs_func, t_span, y0, method='BDF', jac=jacobian)

# Validate results
earthsci_ast.validate_results(sol, "ocean_atmosphere_biogeochemistry_results.json")
```

## Contributing

When adding new end-to-end test fixtures:

1. **Complete Coverage**: Ensure all 6 coupling types are represented
2. **Realistic Physics**: Use physically meaningful parameter values and equations
3. **Clear Documentation**: Provide detailed descriptions of system behavior
4. **Expected Results**: Include comprehensive expected results with tolerances
5. **Multiple Scales**: Cover different temporal and spatial scales
6. **Cross-Validation**: Design tests that can be validated across different backends

These fixtures provide the gold standard for validating complete Earth system model implementations in different programming languages and simulation frameworks.