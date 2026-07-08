# Atmospheric Chemistry Example

This example demonstrates a realistic atmospheric chemistry model with multiple species, photolysis reactions, and gas-phase kinetics. It shows how ESM format handles complex chemical systems.

## The Model

This model simulates basic ozone chemistry in the atmosphere:

```
O3 + hν → O2 + O        (photolysis)
O + O2 + M → O3 + M     (three-body recombination)
O3 + NO → NO2 + O2      (ozone consumption)
NO2 + hν → NO + O       (photolysis)
```

Save this as `atmospheric_chemistry.esm`:

```json
{
  "esm": "0.1.0",
  "metadata": {
    "name": "Atmospheric Chemistry Model",
    "description": "Basic ozone photochemistry with NOx cycling",
    "author": "ESM Documentation Team",
    "created": "2026-02-15",
    "version": "1.0.0",
    "references": [
      "Seinfeld, J. H., & Pandis, S. N. (2016). Atmospheric chemistry and physics.",
      "Jacob, D. J. (1999). Introduction to atmospheric chemistry."
    ]
  },
  "models": {
    "gas_phase_chemistry": {
      "name": "gas_phase_chemistry",
      "description": "Gas-phase photochemical reactions",
      "variables": [
        {
          "name": "O3",
          "type": "state",
          "units": "molec/cm^3",
          "description": "Ozone concentration",
          "initial_value": "1e12"
        },
        {
          "name": "O2",
          "type": "state",
          "units": "molec/cm^3",
          "description": "Oxygen concentration",
          "initial_value": "5e18"
        },
        {
          "name": "O",
          "type": "state",
          "units": "molec/cm^3",
          "description": "Atomic oxygen concentration",
          "initial_value": "1e6"
        },
        {
          "name": "NO",
          "type": "state",
          "units": "molec/cm^3",
          "description": "Nitric oxide concentration",
          "initial_value": "1e10"
        },
        {
          "name": "NO2",
          "type": "state",
          "units": "molec/cm^3",
          "description": "Nitrogen dioxide concentration",
          "initial_value": "5e10"
        },
        {
          "name": "M",
          "type": "algebraic",
          "units": "molec/cm^3",
          "description": "Third body concentration (air density)",
          "expression": "2.5e19"
        }
      ],
      "parameters": [
        {
          "name": "j_O3",
          "value": "1.2e-4",
          "units": "1/s",
          "description": "Ozone photolysis rate coefficient"
        },
        {
          "name": "j_NO2",
          "value": "8.0e-3",
          "units": "1/s",
          "description": "NO2 photolysis rate coefficient"
        },
        {
          "name": "k_O_O2_M",
          "value": "6.0e-34",
          "units": "cm^6/(molec^2*s)",
          "description": "Three-body recombination rate coefficient",
          "temperature_dependence": {
            "type": "arrhenius",
            "A": "6.0e-34",
            "n": "-2.4",
            "Ea": "0.0"
          }
        },
        {
          "name": "k_O3_NO",
          "value": "2.0e-14",
          "units": "cm^3/(molec*s)",
          "description": "Ozone + NO reaction rate coefficient",
          "temperature_dependence": {
            "type": "arrhenius",
            "A": "2.0e-14",
            "n": "0.0",
            "Ea": "-1400.0"
          }
        },
        {
          "name": "T",
          "value": "298.15",
          "units": "K",
          "description": "Temperature"
        }
      ],
      "equations": [
        {
          "lhs": "O3",
          "rhs": {
            "op": "+",
            "args": [
              {
                "op": "*",
                "args": [
                  {
                    "op": "-",
                    "args": ["j_O3"]
                  },
                  "O3"
                ]
              },
              {
                "op": "*",
                "args": ["k_O_O2_M", "O", "O2", "M"]
              },
              {
                "op": "*",
                "args": [
                  {
                    "op": "-",
                    "args": ["k_O3_NO"]
                  },
                  "O3",
                  "NO"
                ]
              }
            ]
          },
          "description": "Ozone production and loss: photolysis + formation - reaction with NO"
        },
        {
          "lhs": "O2",
          "rhs": {
            "op": "+",
            "args": [
              {
                "op": "*",
                "args": ["j_O3", "O3"]
              },
              {
                "op": "*",
                "args": ["k_O3_NO", "O3", "NO"]
              },
              {
                "op": "*",
                "args": [
                  {
                    "op": "-",
                    "args": ["k_O_O2_M"]
                  },
                  "O",
                  "O2",
                  "M"
                ]
              }
            ]
          },
          "description": "O2 production from photolysis and reaction - loss to recombination"
        },
        {
          "lhs": "O",
          "rhs": {
            "op": "+",
            "args": [
              {
                "op": "*",
                "args": ["j_O3", "O3"]
              },
              {
                "op": "*",
                "args": ["j_NO2", "NO2"]
              },
              {
                "op": "*",
                "args": [
                  {
                    "op": "-",
                    "args": ["k_O_O2_M"]
                  },
                  "O",
                  "O2",
                  "M"
                ]
              }
            ]
          },
          "description": "Atomic oxygen from photolysis - loss to recombination"
        },
        {
          "lhs": "NO",
          "rhs": {
            "op": "+",
            "args": [
              {
                "op": "*",
                "args": [
                  {
                    "op": "-",
                    "args": ["k_O3_NO"]
                  },
                  "O3",
                  "NO"
                ]
              },
              {
                "op": "*",
                "args": ["j_NO2", "NO2"]
              }
            ]
          },
          "description": "NO loss to ozone reaction + production from NO2 photolysis"
        },
        {
          "lhs": "NO2",
          "rhs": {
            "op": "+",
            "args": [
              {
                "op": "*",
                "args": ["k_O3_NO", "O3", "NO"]
              },
              {
                "op": "*",
                "args": [
                  {
                    "op": "-",
                    "args": ["j_NO2"]
                  },
                  "NO2"
                ]
              }
            ]
          },
          "description": "NO2 production from ozone reaction - loss from photolysis"
        }
      ]
    }
  },
  "domain": {
    "type": "temporal",
    "time": {
      "start": 0.0,
      "end": 86400.0,
      "units": "s"
    }
  },
  "solver": {
    "type": "ode",
    "strategy": "adaptive_runge_kutta",
    "config": {
      "algorithm": "Tsit5",
      "relative_tolerance": 1e-6,
      "absolute_tolerance": 1e-8
    }
  }
}
```

## Model Components Explained

### Chemical Species

The model tracks five chemical species:

1. **O₃ (Ozone)** - Primary pollutant and UV shield
2. **O₂ (Oxygen)** - Background atmospheric component
3. **O (Atomic Oxygen)** - Highly reactive intermediate
4. **NO (Nitric Oxide)** - Emitted from combustion sources
5. **NO₂ (Nitrogen Dioxide)** - Secondary pollutant, brown gas

### Reaction Mechanisms

1. **Ozone Photolysis**: `O₃ + hν → O₂ + O`
   - Rate: `j_O3 * [O3]`
   - Produces reactive atomic oxygen

2. **Three-body Recombination**: `O + O₂ + M → O₃ + M`
   - Rate: `k_O_O2_M * [O] * [O2] * [M]`
   - Reforms ozone, requires third body (M)

3. **Ozone-NO Reaction**: `O₃ + NO → NO₂ + O₂`
   - Rate: `k_O3_NO * [O3] * [NO]`
   - Key ozone loss process in polluted air

4. **NO₂ Photolysis**: `NO₂ + hν → NO + O`
   - Rate: `j_NO2 * [NO2]`
   - Regenerates NO and produces O atoms

### Temperature-Dependent Kinetics

Several rate coefficients follow Arrhenius temperature dependence:

```
k(T) = A * (T/300)^n * exp(-Ea/(RT))
```

This is captured in the `temperature_dependence` field for parameters.

## Working with the Atmospheric Chemistry Model

### Julia Implementation

```julia
using EarthSciAST, ModelingToolkit, DifferentialEquations, Plots

# Load the atmospheric chemistry model
esm_file = load_esm("atmospheric_chemistry.esm")
println("Loaded: ", esm_file.metadata.name)

# Convert to ModelingToolkit system
@named mtk_system = to_mtk(esm_file)

# Set up the problem with initial conditions
initial_conditions = [
    mtk_system.O3 => 1e12,    # molec/cm³
    mtk_system.O2 => 5e18,    # molec/cm³
    mtk_system.O => 1e6,      # molec/cm³
    mtk_system.NO => 1e10,    # molec/cm³
    mtk_system.NO2 => 5e10    # molec/cm³
]

# Solve for 24 hours
tspan = (0.0, 86400.0)  # seconds
prob = ODEProblem(mtk_system, initial_conditions, tspan)
sol = solve(prob, Tsit5(), reltol=1e-6)

# Plot results
time_hours = sol.t ./ 3600  # Convert to hours

plot(time_hours, sol[mtk_system.O3] ./ 1e9, label="O₃",
     xlabel="Time (hours)", ylabel="Concentration (ppb)",
     title="Atmospheric Chemistry Evolution")
plot!(time_hours, sol[mtk_system.NO] ./ 1e9, label="NO")
plot!(time_hours, sol[mtk_system.NO2] ./ 1e9, label="NO₂")
plot!(time_hours, sol[mtk_system.O] ./ 1e6, label="O (×10⁻³)")

# Calculate photostationary state ratio
steady_state_ratio = (sol[mtk_system.NO2] .* esm_file.models.gas_phase_chemistry.parameters["j_NO2"]) ./
                    (sol[mtk_system.NO] .* sol[mtk_system.O3] .* esm_file.models.gas_phase_chemistry.parameters["k_O3_NO"])

plot!(time_hours, steady_state_ratio, label="PSS Ratio", linestyle=:dash)
```

### Python Implementation

```python
import numpy as np
import matplotlib.pyplot as plt
from scipy.integrate import odeint
from earthsci_ast import load_esm, to_unicode

# Load model
esm_file = load_esm('atmospheric_chemistry.esm')
print(f"Loaded: {esm_file.metadata.name}")

# Extract parameters
model = esm_file.models['gas_phase_chemistry']
params = {p.name: float(p.value) for p in model.parameters}

# Define the system of ODEs
def atmospheric_chemistry_odes(y, t, params):
    O3, O2, O, NO, NO2 = y
    M = 2.5e19  # Air density

    # Rate calculations
    j_O3 = params['j_O3']
    j_NO2 = params['j_NO2']
    k_O_O2_M = params['k_O_O2_M']
    k_O3_NO = params['k_O3_NO']

    # ODEs (matching the ESM equations)
    dO3_dt = (-j_O3 * O3 +
              k_O_O2_M * O * O2 * M -
              k_O3_NO * O3 * NO)

    dO2_dt = (j_O3 * O3 +
              k_O3_NO * O3 * NO -
              k_O_O2_M * O * O2 * M)

    dO_dt = (j_O3 * O3 +
             j_NO2 * NO2 -
             k_O_O2_M * O * O2 * M)

    dNO_dt = (-k_O3_NO * O3 * NO +
              j_NO2 * NO2)

    dNO2_dt = (k_O3_NO * O3 * NO -
               j_NO2 * NO2)

    return [dO3_dt, dO2_dt, dO_dt, dNO_dt, dNO2_dt]

# Initial conditions
y0 = [1e12, 5e18, 1e6, 1e10, 5e10]  # molec/cm³
t = np.linspace(0, 86400, 1000)      # 24 hours in seconds

# Solve the system
solution = odeint(atmospheric_chemistry_odes, y0, t, args=(params,))

# Plot results
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 10))

# Main species concentrations
time_hours = t / 3600
ax1.plot(time_hours, solution[:, 0] / 1e9, label='O₃', linewidth=2)
ax1.plot(time_hours, solution[:, 3] / 1e9, label='NO', linewidth=2)
ax1.plot(time_hours, solution[:, 4] / 1e9, label='NO₂', linewidth=2)
ax1.set_xlabel('Time (hours)')
ax1.set_ylabel('Concentration (ppb)')
ax1.set_title('Atmospheric Chemistry: Major Species')
ax1.legend()
ax1.grid(True, alpha=0.3)

# Atomic oxygen (different scale)
ax2.plot(time_hours, solution[:, 2], label='O', color='red', linewidth=2)
ax2.set_xlabel('Time (hours)')
ax2.set_ylabel('O Concentration (molec/cm³)')
ax2.set_title('Atomic Oxygen Evolution')
ax2.legend()
ax2.grid(True, alpha=0.3)
ax2.set_yscale('log')

plt.tight_layout()
plt.savefig('atmospheric_chemistry_evolution.png', dpi=300)
plt.show()

# Calculate and display photostationary state
final_NO = solution[-1, 3]
final_NO2 = solution[-1, 4]
final_O3 = solution[-1, 0]

pss_ratio = (final_NO2 * params['j_NO2']) / (final_NO * final_O3 * params['k_O3_NO'])
print(f"\nPhotostationary State Analysis:")
print(f"Final [NO]: {final_NO/1e9:.2f} ppb")
print(f"Final [NO₂]: {final_NO2/1e9:.2f} ppb")
print(f"Final [O₃]: {final_O3/1e9:.2f} ppb")
print(f"PSS Ratio (should ≈ 1): {pss_ratio:.3f}")
```

### TypeScript Visualization

```typescript
import { load, validate, toUnicode, toLatex } from '@earthsciml/ast';
import * as d3 from 'd3';

// Load and validate model
const esmData = await fetch('atmospheric_chemistry.esm').then(r => r.text());
const esmFile = load(esmData);

console.log('Loaded:', esmFile.metadata.name);

// Create interactive visualization
function createChemistryDashboard(esmFile: EsmFile) {
  const model = esmFile.models.gas_phase_chemistry;

  // Display reaction equations in readable form
  const equationsDiv = d3.select('#equations');
  model.equations.forEach((eq, i) => {
    const equationDiv = equationsDiv.append('div')
      .attr('class', 'equation');

    equationDiv.append('span')
      .attr('class', 'equation-number')
      .text(`(${i + 1})`);

    equationDiv.append('span')
      .attr('class', 'equation-text')
      .html(`d[${eq.lhs}]/dt = ${toUnicode(eq.rhs)}`);

    equationDiv.append('p')
      .attr('class', 'equation-description')
      .text(eq.description);
  });

  // Create parameter controls
  const controlsDiv = d3.select('#controls');
  model.parameters.forEach(param => {
    const control = controlsDiv.append('div')
      .attr('class', 'parameter-control');

    control.append('label')
      .text(`${param.name} (${param.units})`);

    const slider = control.append('input')
      .attr('type', 'range')
      .attr('min', parseFloat(param.value) * 0.1)
      .attr('max', parseFloat(param.value) * 10)
      .attr('step', parseFloat(param.value) * 0.01)
      .attr('value', param.value);

    const display = control.append('span')
      .text(param.value);

    slider.on('input', function() {
      const value = (this as HTMLInputElement).value;
      display.text(value);
      // Trigger model recalculation
      updateSimulation(esmFile, getParameterValues());
    });
  });
}

// Simulate and update plots
function updateSimulation(esmFile: EsmFile, parameters: Record<string, number>) {
  // This would integrate with a numerical ODE solver
  // For demo purposes, we'll show the structure

  const results = runSimulation(esmFile, parameters);
  updatePlots(results);
}

createChemistryDashboard(esmFile);
```

### Rust CLI Analysis

```bash
# Validate the atmospheric chemistry model
esm validate atmospheric_chemistry.esm

# Show detailed model information
esm info atmospheric_chemistry.esm

# Analyze model complexity
esm analyze complexity atmospheric_chemistry.esm

# Pretty-print all equations in LaTeX for publication
esm pretty-print atmospheric_chemistry.esm -f latex -o chemistry_equations.tex

# Extract just the gas-phase chemistry model
esm extract atmospheric_chemistry.esm --model gas_phase_chemistry -o gas_phase_only.esm
```

## Key Chemical Insights

### Photostationary State

In steady-state conditions, the NO-NO₂-O₃ system reaches a photostationary equilibrium:

```
j_NO2 * [NO2] = k_O3_NO * [O3] * [NO]
```

This relationship is fundamental to understanding urban air pollution chemistry.

### Ozone Formation vs. Destruction

The model shows the competing processes:
- **Formation**: Three-body recombination of O + O₂
- **Destruction**: Photolysis and reaction with NO

The balance determines whether ozone accumulates or depletes.

### NOₓ Cycling

The rapid cycling between NO and NO₂:
- **NO → NO₂**: Reaction with O₃
- **NO₂ → NO**: Photolysis

This cycling is much faster than NOₓ removal processes.

## Model Extensions

### Adding More Species

```json
{
  "name": "HO2",
  "type": "state",
  "units": "molec/cm^3",
  "description": "Hydroperoxy radical"
},
{
  "name": "OH",
  "type": "state",
  "units": "molec/cm^3",
  "description": "Hydroxyl radical"
}
```

### Diurnal Variations

```json
{
  "name": "j_O3",
  "type": "time_dependent",
  "expression": {
    "op": "*",
    "args": [
      "1.2e-4",
      {
        "op": "cos_zenith",
        "args": ["solar_zenith_angle"]
      }
    ]
  }
}
```

### Emissions

```json
{
  "name": "NO_emission",
  "type": "emission",
  "rate": "1e8",
  "units": "molec/(cm^3*s)",
  "description": "Surface NO emissions"
}
```

## Next Steps

1. **Extend the Model** — Add VOC chemistry, aerosol interactions
2. **Spatial Dimensions** — Convert to 3D atmospheric model
3. **Reference** — Browse the [Standard Library](../standard_library/) for shipped subsystems

This atmospheric chemistry example demonstrates how ESM format handles:
- ✅ Complex multi-species chemical kinetics
- ✅ Temperature-dependent rate coefficients
- ✅ Algebraic constraints (photostationary state)
- ✅ Cross-language simulation compatibility
- ✅ Self-documenting model structure

Ready for more complex systems? Browse the other [examples](../) for additional patterns.