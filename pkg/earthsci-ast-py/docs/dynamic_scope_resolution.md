# Dynamic Scope Resolution for Runtime Contexts

This document describes the dynamic scope resolution system that extends the ESM Format library's hierarchical scope resolution with runtime capabilities.

## Overview

The `DynamicScopeResolver` extends the existing `HierarchicalScopeResolver` to support:

1. **Parameter Injection**: Dynamically inject parameters into existing scopes at runtime
2. **Context Switching**: Switch between different runtime contexts with isolated state
3. **Dynamic Scope Creation**: Create new scopes at runtime that weren't in the original ESM file
4. **Variable Overrides**: Temporarily override variable values without modifying the base ESM structure
5. **Context Isolation**: Maintain separate runtime contexts that don't interfere with each other

## Key Classes

### `DynamicScopeResolver`

The main class that provides dynamic scope resolution capabilities.

```python
from earthsci_ast import DynamicScopeResolver, EsmFile

resolver = DynamicScopeResolver(esm_file)
```

### `RuntimeContext`

Represents a runtime execution context with its own injected parameters, overrides, and dynamic scopes.

### `RuntimeVariable`

Represents a variable with runtime context information, including injection metadata.

### `ContextSwitchResult`

Result object returned when switching between contexts.

## Usage Examples

### Basic Parameter Injection

```python
# Inject a parameter at runtime
resolver.inject_parameter(
    "AtmosphereModel",           # scope path
    "humidity",                  # variable name
    65.0,                       # value
    units="percent",            # optional units
    injector_id="simulation"    # optional injector ID
)

# Resolve the injected parameter
result = resolver.resolve_variable_dynamic("AtmosphereModel.humidity")
print(f"Humidity: {result.resolved_value} ({result.resolution_type})")
```

### Variable Overrides

```python
# Override an existing variable
resolver.override_variable("AtmosphereModel", "temperature", 305.0)

# The override takes precedence over the original value
result = resolver.resolve_variable_dynamic("AtmosphereModel.temperature")
print(f"Temperature: {result.resolved_value} K")  # 305.0
```

### Context Management

```python
# Create different runtime contexts
winter_ctx = resolver.create_runtime_context("Winter Conditions")
summer_ctx = resolver.create_runtime_context("Summer Conditions")

# Configure winter context
resolver.switch_context(winter_ctx)
resolver.override_variable("AtmosphereModel", "temperature", 273.15)
resolver.inject_parameter("AtmosphereModel", "snow_depth", 0.5)

# Configure summer context
resolver.switch_context(summer_ctx)
resolver.override_variable("AtmosphereModel", "temperature", 308.15)
resolver.inject_parameter("AtmosphereModel", "solar_radiation", 800.0)

# Switch between contexts as needed
resolver.switch_context(winter_ctx)
temp = resolver.resolve_variable_dynamic("AtmosphereModel.temperature")
print(f"Winter temperature: {temp.resolved_value} K")  # 273.15
```

### Temporary Context Usage

```python
# Use a context temporarily with automatic cleanup
with resolver.temporary_context(summer_ctx) as ctx:
    result = resolver.resolve_variable_dynamic("AtmosphereModel.solar_radiation")
    print(f"Solar radiation: {result.resolved_value} W/m^2")
# Automatically returns to previous context
```

### Dynamic Scope Creation

```python
# Create a new scope at runtime
resolver.create_dynamic_scope(
    "AtmosphereModel",           # parent scope
    "RuntimeDiagnostics",        # new scope name
    variables={                  # initial variables
        "cpu_usage": {"type": "parameter", "value": 25.5},
        "memory_usage": {"type": "parameter", "value": 1024.0}
    }
)

# Use variables from the dynamic scope
result = resolver.resolve_variable_dynamic("AtmosphereModel.RuntimeDiagnostics.cpu_usage")
print(f"CPU usage: {result.resolved_value}%")
```

## Resolution Priority Order

The dynamic resolver follows this priority order when resolving variables:

1. **Variable Overrides** (highest priority)
2. **Injected Parameters**
3. **Dynamic Scope Variables**
4. **Base Hierarchical Resolution** (lowest priority)

This ensures that runtime modifications take precedence over static definitions while preserving the base model structure.

## Context Inheritance

Child contexts can inherit from parent contexts:

```python
# Create parent context with shared settings
parent_ctx = resolver.create_runtime_context("Base Configuration")
resolver.inject_parameter("AtmosphereModel", "base_pressure", 101325.0, context_id=parent_ctx)

# Create child context that inherits parent state
child_ctx = resolver.create_runtime_context(
    "Specialized Configuration",
    parent_context_id=parent_ctx
)

# Child automatically has access to parent's injections
resolver.switch_context(child_ctx)
result = resolver.resolve_variable_dynamic("AtmosphereModel.base_pressure")
print(f"Inherited pressure: {result.resolved_value} Pa")  # 101325.0
```

## Runtime Statistics and Monitoring

```python
# Get runtime statistics
stats = resolver.get_runtime_statistics()
print(f"Total contexts: {stats['total_contexts']}")
print(f"Total injections: {stats['total_injections']}")
print(f"Total overrides: {stats['total_overrides']}")

# List all contexts
for ctx_id, name, is_current in resolver.list_contexts():
    status = "(current)" if is_current else ""
    print(f"{ctx_id}: {name} {status}")
```

## Variable Change Listeners

Monitor runtime changes with listeners:

```python
def change_listener(change_type, scope_path, variable_name, new_value, context_id):
    print(f"Variable {scope_path}.{variable_name} {change_type}: {new_value}")

resolver.add_variable_change_listener(change_listener)

# Now any injections or overrides will trigger the listener
resolver.inject_parameter("AtmosphereModel", "test_var", 42.0)
# Output: Variable AtmosphereModel.test_var parameter_injected: 42.0
```

## Error Handling

The dynamic resolver provides enhanced error messages that include context information:

```python
try:
    result = resolver.resolve_variable_dynamic("AtmosphereModel.nonexistent_var")
except ValueError as e:
    print(e)
    # Output includes context ID and available injected/overridden variables
```

## Integration with Existing Code

The dynamic resolver is fully compatible with existing ESM Format code. It extends the base `HierarchicalScopeResolver` without breaking existing functionality:

```python
# Still works with base resolution
base_result = resolver.base_resolver.resolve_variable("AtmosphereModel.temperature")

# Enhanced resolution with runtime context
dynamic_result = resolver.resolve_variable_dynamic("AtmosphereModel.temperature")

# Both methods work together seamlessly
```

## Best Practices

1. **Use contexts for logical groupings**: Create contexts for different simulation scenarios, time periods, or parameter sets
2. **Prefer parameter injection over variable overrides**: Injection is for new runtime parameters; overrides are for changing existing values
3. **Clean up contexts when done**: Use `clear_context_injections()` or create new contexts as needed
4. **Use temporary contexts for short-term changes**: The `temporary_context()` context manager automatically restores the previous context
5. **Monitor with listeners**: Use variable change listeners for debugging and logging runtime modifications

## Performance Considerations

- Context switching is lightweight - only metadata is changed
- Variable resolution has minimal overhead over base resolution
- Dynamic scopes are stored in memory - consider cleanup for long-running simulations
- Context inheritance uses shallow copying - modifications in child contexts don't affect parents

## Integration with Simulation Loops

The dynamic scope resolution is designed to work seamlessly with simulation loops:

```python
# Simulation loop with dynamic contexts
for time_step in simulation_time_steps:
    # Create context for this time step
    step_ctx = resolver.create_runtime_context(f"TimeStep_{time_step}")

    with resolver.temporary_context(step_ctx):
        # Inject time-specific parameters
        resolver.inject_parameter("AtmosphereModel", "current_time", time_step)

        # Run simulation step with context-specific parameters
        run_simulation_step(resolver, time_step)

        # Context automatically cleaned up after each iteration
```

This design allows for flexible, runtime-configurable model execution while maintaining the integrity and structure of the original ESM specification.