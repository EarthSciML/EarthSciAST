# Python API Reference

Complete API reference for the ESM Format Python library.

## Functions

### Process

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:33`

```python
def Process():
```

---

### add_component_time

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:104`

```python
def add_component_time(self, component: str, duration: float):
```

Add timing for a component.

---

### add_component_time

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:560`

```python
def add_component_time(self, component, duration):
```

---

### add_constraint

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/initial_conditions_setup.py:88`

```python
def add_constraint(self, constraint: FieldConstraint):
```

Add a field constraint.

---

### add_error

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:206`

```python
def add_error(self, error: ESMError):
```

Add an error to the collection.

---

### add_iteration_time

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:110`

```python
def add_iteration_time(self, duration: float):
```

Add timing for an iteration.

---

### add_iteration_time

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:565`

```python
def add_iteration_time(self, duration):
```

---

### add_memory_usage

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:568`

```python
def add_memory_usage(self, usage_mb):
```

---

### add_recovery_attempt

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:85`

```python
def add_recovery_attempt(self, strategy: RecoveryStrategy, success: bool, details: str):
```

Record a recovery attempt.

---

### add_variable_change_listener

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/dynamic_scope_resolution.py:580`

```python
def add_variable_change_listener(self, listener: Callable):
```

Add a listener for variable change events.

---

### append

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:51`

```python
def append(arr, value):
```

---

### array

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:23`

```python
def array(data):
```

---

### assign_task_dynamic

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:444`

```python
def assign_task_dynamic(self, task_name, estimated_cost=1.0):
```

---

### assign_task_round_robin

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:439`

```python
def assign_task_round_robin(self, task_name):
```

---

### begin_transaction

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:930`

```python
def begin_transaction(self):
```

Begin a database transaction.

        Note: This creates a connection that should be used with execute_transaction_query
        and closed with commit_transaction or rollback_transaction.

---

### build_structure

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1268`

```python
def build_structure(name, obj):
```

---

### build_structure_pytables

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1295`

```python
def build_structure_pytables(node, current_dict, path=""):
```

---

### cleanup

**File:** `pkg/earthsci-ast-py/examples/data_loader_registry_example.py:225`

```python
def cleanup():
```

Clean up sample files.

---

### clear

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:304`

```python
def clear(self):
```

Clear cache.

---

### clear_cache

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_dispatch.py:347`

```python
def clear_cache(self):
```

Clear the dispatch cache.

---

### close

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:242`

```python
def close(self):
```

Close the dataset and free resources.

---

### close

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1016`

```python
def close(self):
```

Close database connections and clean up resources.

---

### close

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1512`

```python
def close(self):
```

Close the HDF5 file and free resources.

---

### close

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1862`

```python
def close(self):
```

Close the dataset and free resources.

---

### close

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:2401`

```python
def close(self):
```

Clean up resources.

---

### collect_dataset_info

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1345`

```python
def collect_dataset_info(name, obj):
```

---

### collect_dataset_info_pytables

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1364`

```python
def collect_dataset_info_pytables(node, path=""):
```

---

### commit_transaction

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:944`

```python
def commit_transaction(self):
```

Commit the current transaction and close the connection.

---

### create_atmospheric_chemistry_system

**File:** `pkg/earthsci-ast-py/examples/atmospheric_chemistry_simulation.py:17`

```python
def create_atmospheric_chemistry_system():
```

Create a simple atmospheric chemistry system with O3-NOx reactions.

    Reactions:
    1. NO2 + hv -> NO + O     (photolysis)
    2. O + O2 + M -> O3 + M   (ozone formation, simplified as O -> O3)
    3. NO + O3 -> NO2 + O2    (ozone depletion)

---

### create_demo_coupling_function

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:25`

```python
def create_demo_coupling_function(component_name: str = None):
```

Create a demo coupling function that simulates Earth system component coupling.

---

### create_demo_esm

**File:** `pkg/earthsci-ast-py/examples/dynamic_scope_demo.py:21`

```python
def create_demo_esm():
```

Create a demo ESM file for the demonstration.

---

### create_demo_esm_file

**File:** `pkg/earthsci-ast-py/examples/coupling_dependency_resolution_demo.py:14`

```python
def create_demo_esm_file():
```

Create a demonstration ESM file with hierarchical components.

---

### create_example_models

**File:** `pkg/earthsci-ast-py/examples/coupling_variable_matching_demo.py:16`

```python
def create_example_models():
```

Create example models for demonstration.

---

### create_sample_database

**File:** `pkg/earthsci-ast-py/examples/database_loader_example.py:19`

```python
def create_sample_database():
```

Create a sample SQLite database with atmospheric chemistry data.

---

### create_sample_netcdf

**File:** `pkg/earthsci-ast-py/examples/netcdf_data_loading_example.py:23`

```python
def create_sample_netcdf():
```

Create a sample NetCDF file with atmospheric data.

---

### demo_advanced_operations

**File:** `pkg/earthsci-ast-py/demo_sympy_bridge.py:65`

```python
def demo_advanced_operations():
```

Demonstrate advanced operations.

---

### demo_basic_error_recovery

**File:** `pkg/earthsci-ast-py/examples/coupling_error_handling_demo.py:244`

```python
def demo_basic_error_recovery():
```

Demonstrate basic error recovery capabilities.

---

### demo_basic_functionality

**File:** `pkg/earthsci-ast-py/examples/dynamic_scope_demo.py:55`

```python
def demo_basic_functionality():
```

Demonstrate basic dynamic scope functionality.

---

### demo_basic_mapping

**File:** `pkg/earthsci-ast-py/demo_sympy_bridge.py:30`

```python
def demo_basic_mapping():
```

Demonstrate basic expression mapping.

---

### demo_basic_performance_optimization

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:137`

```python
def demo_basic_performance_optimization():
```

Demonstrate basic performance optimization setup and usage.

---

### demo_basic_synchronization

**File:** `pkg/earthsci-ast-py/examples/time_synchronization_demo.py:24`

```python
def demo_basic_synchronization():
```

Demonstrate basic time synchronization between two components.

---

### demo_caching_optimization

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:322`

```python
def demo_caching_optimization():
```

Demonstrate caching optimization benefits.

---

### demo_complete_coupling_pipeline

**File:** `pkg/earthsci-ast-py/examples/coupling_data_transformation_demo.py:315`

```python
def demo_complete_coupling_pipeline():
```

Demonstrate a complete coupling transformation pipeline.

---

### demo_context_switching

**File:** `pkg/earthsci-ast-py/examples/dynamic_scope_demo.py:103`

```python
def demo_context_switching():
```

Demonstrate context switching capabilities.

---

### demo_coordinate_transformation

**File:** `pkg/earthsci-ast-py/examples/coupling_data_transformation_demo.py:161`

```python
def demo_coordinate_transformation():
```

Demonstrate coordinate system transformations.

---

### demo_cost_estimation

**File:** `pkg/earthsci-ast-py/examples/coupling_data_transformation_demo.py:415`

```python
def demo_cost_estimation():
```

Demonstrate transformation cost estimation for performance planning.

---

### demo_coupled_system

**File:** `pkg/earthsci-ast-py/examples/time_synchronization_demo.py:153`

```python
def demo_coupled_system():
```

Demonstrate full coupled system simulation.

---

### demo_error_cases

**File:** `pkg/earthsci-ast-py/examples/coupling_dependency_resolution_demo.py:175`

```python
def demo_error_cases():
```

Demonstrate error handling for invalid references.

---

### demo_execution_strategies

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:221`

```python
def demo_execution_strategies():
```

Demonstrate different execution strategies.

---

### demo_fault_tolerant_simulation

**File:** `pkg/earthsci-ast-py/examples/coupling_error_handling_demo.py:339`

```python
def demo_fault_tolerant_simulation():
```

Demonstrate fault-tolerant simulation for production use.

---

### demo_grid_interpolation

**File:** `pkg/earthsci-ast-py/examples/coupling_data_transformation_demo.py:82`

```python
def demo_grid_interpolation():
```

Demonstrate grid interpolation between different spatial resolutions.

---

### demo_interpolation

**File:** `pkg/earthsci-ast-py/examples/time_synchronization_demo.py:63`

```python
def demo_interpolation():
```

Demonstrate time interpolation capabilities.

---

### demo_load_balancing

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:424`

```python
def demo_load_balancing():
```

Demonstrate load balancing optimization.

---

### demo_partial_execution_resilience

**File:** `pkg/earthsci-ast-py/examples/coupling_error_handling_demo.py:423`

```python
def demo_partial_execution_resilience():
```

Demonstrate partial execution when some components fail.

---

### demo_performance_analysis

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:542`

```python
def demo_performance_analysis():
```

Demonstrate performance analysis and reporting.

---

### demo_round_trip

**File:** `pkg/earthsci-ast-py/demo_sympy_bridge.py:95`

```python
def demo_round_trip():
```

Demonstrate round-trip conversion.

---

### demo_runtime_statistics

**File:** `pkg/earthsci-ast-py/examples/dynamic_scope_demo.py:196`

```python
def demo_runtime_statistics():
```

Show runtime statistics and monitoring.

---

### demo_scoped_reference_resolution

**File:** `pkg/earthsci-ast-py/examples/coupling_dependency_resolution_demo.py:91`

```python
def demo_scoped_reference_resolution():
```

Demonstrate scoped reference resolution capabilities.

---

### demo_state_variable_functions

**File:** `pkg/earthsci-ast-py/demo_sympy_bridge.py:182`

```python
def demo_state_variable_functions():
```

Demonstrate state variables as functions of time.

---

### demo_subcycling

**File:** `pkg/earthsci-ast-py/examples/time_synchronization_demo.py:119`

```python
def demo_subcycling():
```

Demonstrate subcycling between fast and slow components.

---

### demo_symbolic_jacobian

**File:** `pkg/earthsci-ast-py/demo_sympy_bridge.py:124`

```python
def demo_symbolic_jacobian():
```

Demonstrate symbolic Jacobian computation.

---

### demo_temporary_contexts

**File:** `pkg/earthsci-ast-py/examples/dynamic_scope_demo.py:157`

```python
def demo_temporary_contexts():
```

Demonstrate temporary context usage.

---

### demo_unit_conversion

**File:** `pkg/earthsci-ast-py/examples/coupling_data_transformation_demo.py:26`

```python
def demo_unit_conversion():
```

Demonstrate unit conversion between different measurement systems.

---

### demo_variable_transformations

**File:** `pkg/earthsci-ast-py/examples/coupling_data_transformation_demo.py:241`

```python
def demo_variable_transformations():
```

Demonstrate ESM variable transformation semantics.

---

### demonstrate_auto_detection

**File:** `pkg/earthsci-ast-py/examples/data_loader_registry_example.py:93`

```python
def demonstrate_auto_detection():
```

Demonstrate automatic loader type detection and creation.

---

### demonstrate_basic_dispatch

**File:** `pkg/earthsci-ast-py/examples/operator_overloading_demo.py:24`

```python
def demonstrate_basic_dispatch():
```

Demonstrate basic operator dispatch with built-in overloads.

---

### demonstrate_builtin_loaders

**File:** `pkg/earthsci-ast-py/examples/data_loader_registry_example.py:77`

```python
def demonstrate_builtin_loaders():
```

Show the built-in loaders registered by default.

---

### demonstrate_circular_dependency_protection

**File:** `pkg/earthsci-ast-py/examples/precedence_dependency_demo.py:124`

```python
def demonstrate_circular_dependency_protection():
```

Demonstrate circular dependency detection.

---

### demonstrate_custom_loader

**File:** `pkg/earthsci-ast-py/examples/data_loader_registry_example.py:123`

```python
def demonstrate_custom_loader():
```

Show how to register a custom loader.

---

### demonstrate_custom_overloads

**File:** `pkg/earthsci-ast-py/examples/operator_overloading_demo.py:53`

```python
def demonstrate_custom_overloads():
```

Demonstrate registering custom operator overloads.

---

### demonstrate_dependencies

**File:** `pkg/earthsci-ast-py/examples/precedence_dependency_demo.py:68`

```python
def demonstrate_dependencies():
```

Demonstrate operator dependency system.

---

### demonstrate_dispatch_introspection

**File:** `pkg/earthsci-ast-py/examples/operator_overloading_demo.py:223`

```python
def demonstrate_dispatch_introspection():
```

Demonstrate introspection of dispatch decisions.

---

### demonstrate_error_handling

**File:** `pkg/earthsci-ast-py/examples/hdf5_loader_example.py:429`

```python
def demonstrate_error_handling():
```

Demonstrate error handling capabilities.

---

### demonstrate_error_handling

**File:** `pkg/earthsci-ast-py/examples/netcdf_data_loading_example.py:216`

```python
def demonstrate_error_handling():
```

Demonstrate error handling in NetCDF loading.

---

### demonstrate_fallback_mechanisms

**File:** `pkg/earthsci-ast-py/examples/operator_overloading_demo.py:165`

```python
def demonstrate_fallback_mechanisms():
```

Demonstrate fallback mechanisms.

---

### demonstrate_full_validation

**File:** `pkg/earthsci-ast-py/examples/coupling_variable_matching_demo.py:195`

```python
def demonstrate_full_validation():
```

Demonstrate full coupling graph validation.

---

### demonstrate_hdf5_loading

**File:** `pkg/earthsci-ast-py/examples/hdf5_loader_example.py:241`

```python
def demonstrate_hdf5_loading():
```

Demonstrate various HDF5 loading capabilities.

---

### demonstrate_loader_chains

**File:** `pkg/earthsci-ast-py/examples/data_loader_registry_example.py:172`

```python
def demonstrate_loader_chains():
```

Show loader chain functionality.

---

### demonstrate_mathematical_expression

**File:** `pkg/earthsci-ast-py/examples/precedence_dependency_demo.py:147`

```python
def demonstrate_mathematical_expression():
```

Demonstrate precedence in mathematical expression context.

---

### demonstrate_netcdf_loading

**File:** `pkg/earthsci-ast-py/examples/netcdf_data_loading_example.py:123`

```python
def demonstrate_netcdf_loading():
```

Demonstrate NetCDF data loading with ESM Format.

---

### demonstrate_performance_characteristics

**File:** `pkg/earthsci-ast-py/examples/operator_overloading_demo.py:247`

```python
def demonstrate_performance_characteristics():
```

Demonstrate performance characteristics of the dispatch system.

---

### demonstrate_polymorphism

**File:** `pkg/earthsci-ast-py/examples/operator_overloading_demo.py:107`

```python
def demonstrate_polymorphism():
```

Demonstrate polymorphism with different implementations.

---

### demonstrate_precedence

**File:** `pkg/earthsci-ast-py/examples/precedence_dependency_demo.py:27`

```python
def demonstrate_precedence():
```

Demonstrate operator precedence system.

---

### demonstrate_registry_inspection

**File:** `pkg/earthsci-ast-py/examples/data_loader_registry_example.py:192`

```python
def demonstrate_registry_inspection():
```

Show registry inspection capabilities.

---

### demonstrate_variable_matching

**File:** `pkg/earthsci-ast-py/examples/coupling_variable_matching_demo.py:93`

```python
def demonstrate_variable_matching():
```

Demonstrate various variable matching scenarios.

---

### differentiate

**File:** `pkg/earthsci-ast-py/examples/operator_registry_example.py:74`

```python
def differentiate(self, x_values, y_values):
```

Forward difference implementation.

---

### evaluate_expr_dict

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/initial_conditions_setup.py:34`

```python
def evaluate_expr_dict(expr, variables):
```

---

### event_function

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/simulation.py:253`

```python
def event_function(t, y, condition_func=condition_func, var_names=var_names):
```

---

### example_authenticated_api

**File:** `pkg/earthsci-ast-py/examples/remote_loader_example.py:101`

```python
def example_authenticated_api():
```

Example: Authenticated API access.

---

### example_basic_auth

**File:** `pkg/earthsci-ast-py/examples/remote_loader_example.py:132`

```python
def example_basic_auth():
```

Example: Basic authentication.

---

### example_basic_http

**File:** `pkg/earthsci-ast-py/examples/remote_loader_example.py:36`

```python
def example_basic_http():
```

Example: Basic HTTP data loading.

---

### example_basic_loading

**File:** `pkg/earthsci-ast-py/examples/database_loader_example.py:95`

```python
def example_basic_loading():
```

Demonstrate basic database loading functionality.

---

### example_cache_management

**File:** `pkg/earthsci-ast-py/examples/remote_loader_example.py:186`

```python
def example_cache_management():
```

Example: Cache management.

---

### example_cloud_storage_urls

**File:** `pkg/earthsci-ast-py/examples/remote_loader_example.py:255`

```python
def example_cloud_storage_urls():
```

Example: Cloud storage URL detection.

---

### example_connection_resilience

**File:** `pkg/earthsci-ast-py/examples/streaming_loader_example.py:206`

```python
def example_connection_resilience():
```

Demonstrate connection resilience features.

---

### example_custom_queries

**File:** `pkg/earthsci-ast-py/examples/database_loader_example.py:139`

```python
def example_custom_queries():
```

Demonstrate custom query execution.

---

### example_error_handling

**File:** `pkg/earthsci-ast-py/examples/remote_loader_example.py:227`

```python
def example_error_handling():
```

Example: Error handling and retries.

---

### example_http_streaming

**File:** `pkg/earthsci-ast-py/examples/streaming_loader_example.py:71`

```python
def example_http_streaming():
```

Demonstrate HTTP streaming data loader.

---

### example_message_queue_streaming

**File:** `pkg/earthsci-ast-py/examples/streaming_loader_example.py:121`

```python
def example_message_queue_streaming():
```

Demonstrate message queue streaming data loader.

---

### example_progress_tracking

**File:** `pkg/earthsci-ast-py/examples/remote_loader_example.py:159`

```python
def example_progress_tracking():
```

Example: Download with progress tracking.

---

### example_registry_integration

**File:** `pkg/earthsci-ast-py/examples/database_loader_example.py:269`

```python
def example_registry_integration():
```

Demonstrate integration with the data loader registry.

---

### example_tcp_streaming

**File:** `pkg/earthsci-ast-py/examples/streaming_loader_example.py:164`

```python
def example_tcp_streaming():
```

Demonstrate TCP streaming data loader.

---

### example_transactions

**File:** `pkg/earthsci-ast-py/examples/database_loader_example.py:198`

```python
def example_transactions():
```

Demonstrate transaction handling.

---

### example_websocket_streaming

**File:** `pkg/earthsci-ast-py/examples/streaming_loader_example.py:15`

```python
def example_websocket_streaming():
```

Demonstrate WebSocket streaming data loader.

---

### eye

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:34`

```python
def eye(n):
```

---

### generate_report

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:575`

```python
def generate_report(self):
```

---

### get

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:336`

```python
def get(self, key):
```

---

### get_hit_rate

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:347`

```python
def get_hit_rate(self):
```

---

### get_load_balance_factor

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:472`

```python
def get_load_balance_factor(self):
```

---

### get_stats

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:351`

```python
def get_stats(self):
```

---

### get_stats

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:484`

```python
def get_stats(self):
```

---

### has_cycle

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/time_synchronization.py:627`

```python
def has_cycle(node, visited, rec_stack):
```

---

### interpolate

**File:** `pkg/earthsci-ast-py/examples/operator_registry_example.py:32`

```python
def interpolate(self, x_values, y_values, x_new):
```

Simple linear interpolation implementation.

---

### interpolate

**File:** `pkg/earthsci-ast-py/examples/operator_registry_example.py:54`

```python
def interpolate(self, x_values, y_values, x_new):
```

Spline interpolation implementation.

---

### load

**File:** `pkg/earthsci-ast-py/examples/data_loader_registry_example.py:137`

```python
def load(self):
```

Load CSV data (simplified implementation).

---

### lstsq

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:56`

```python
def lstsq(A, b, rcond=None):
```

---

### main

**File:** `pkg/earthsci-ast-py/examples/math_operators_example.py:20`

```python
def main():
```

Demonstrate mathematical operators functionality.

---

### main

**File:** `pkg/earthsci-ast-py/examples/coupling_error_handling_demo.py:512`

```python
def main():
```

Run all coupling error handling demonstrations.

---

### main

**File:** `pkg/earthsci-ast-py/examples/precedence_dependency_demo.py:177`

```python
def main():
```

Main demonstration function.

---

### main

**File:** `pkg/earthsci-ast-py/examples/data_loader_registry_example.py:24`

```python
def main():
```

Demonstrate data loader registry functionality.

---

### main

**File:** `pkg/earthsci-ast-py/examples/remote_loader_example.py:281`

```python
def main():
```

Run all examples.

---

### main

**File:** `pkg/earthsci-ast-py/examples/operator_overloading_demo.py:294`

```python
def main():
```

Run all demonstrations.

---

### main

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:713`

```python
def main():
```

Run all performance optimization demos.

---

### main

**File:** `pkg/earthsci-ast-py/examples/operator_registry_example.py:86`

```python
def main():
```

Demonstrate operator registry functionality.

---

### main

**File:** `pkg/earthsci-ast-py/examples/coupling_data_transformation_demo.py:496`

```python
def main():
```

Run all demonstrations.

---

### main

**File:** `pkg/earthsci-ast-py/examples/json_loader_demo.py:20`

```python
def main():
```

Demonstrate JSON loader functionality.

---

### main

**File:** `pkg/earthsci-ast-py/examples/database_loader_example.py:307`

```python
def main():
```

Run all database loader examples.

---

### mean

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:43`

```python
def mean(data):
```

---

### memory_info

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:35`

```python
def memory_info(self):
```

---

### photostationary_equilibrium

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/atmospheric_verification.py:142`

```python
def photostationary_equilibrium(k1, j_NO2, NO_total, O3_excess):
```

Analytical solution for photostationary equilibrium.

---

### plot

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/simulation.py:45`

```python
def plot(self, variables: Optional[List[str]] = None, **kwargs):
```

Plot simulation results using matplotlib.

        Args:
            variables: Optional list of variable names to plot. If None, plots all.
            **kwargs: Additional arguments passed to matplotlib.pyplot

---

### print_structure

**File:** `pkg/earthsci-ast-py/examples/hdf5_loader_example.py:332`

```python
def print_structure(struct, indent=0):
```

Recursively print structure.

---

### production_coupling_function

**File:** `pkg/earthsci-ast-py/examples/coupling_error_handling_demo.py:377`

```python
def production_coupling_function(variables, **kwargs):
```

---

### progress_callback

**File:** `pkg/earthsci-ast-py/examples/remote_loader_example.py:24`

```python
def progress_callback(progress, downloaded, total):
```

Progress callback for download tracking.

---

### put

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:272`

```python
def put(self, key: str, value: Any):
```

Put value in cache.

---

### put

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:344`

```python
def put(self, key, value):
```

---

### register_builtin

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_registry.py:179`

```python
def register_builtin(name, operator_type, operator_class, version="1.0"):
```

---

### register_fallback_chain

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_dispatch.py:218`

```python
def register_fallback_chain(self, operator_name: str, fallback_operators: List[str]):
```

Register a fallback chain for an operator.

        Args:
            operator_name: Primary operator name
            fallback_operators: List of fallback operators to try in order

---

### remove_variable_change_listener

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/dynamic_scope_resolution.py:584`

```python
def remove_variable_change_listener(self, listener: Callable):
```

Remove a variable change listener.

---

### rollback_transaction

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:956`

```python
def rollback_transaction(self):
```

Rollback the current transaction and close the connection.

---

### run_atmospheric_simulation

**File:** `pkg/earthsci-ast-py/examples/atmospheric_chemistry_simulation.py:68`

```python
def run_atmospheric_simulation():
```

Run the atmospheric chemistry simulation.

---

### safe_coupling_function

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:353`

```python
def safe_coupling_function(vars_dict: Dict[str, float], **func_kwargs):
```

---

### safe_function

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:534`

```python
def safe_function(variables: Dict[str, float], **kwargs):
```

---

### setup_error_logging

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:559`

```python
def setup_error_logging(log_file: Optional[str] = None, level: str = "INFO"):
```

Setup logging for ESM error handling.

---

### setup_sample_files

**File:** `pkg/earthsci-ast-py/examples/data_loader_registry_example.py:48`

```python
def setup_sample_files():
```

Create sample data files for demonstration.

---

### show_graph

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/display.py:719`

```python
def show_graph(self, format_type: str = "mermaid"):
```

Display the component graph in the specified format.

---

### show_models

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/display.py:675`

```python
def show_models(self):
```

Display detailed information about models.

---

### show_reactions

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/display.py:694`

```python
def show_reactions(self):
```

Display detailed information about reaction systems.

---

### simplified_coupling

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:378`

```python
def simplified_coupling(vars_dict: Dict[str, float], **func_kwargs):
```

---

### solve

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:61`

```python
def solve(A, b):
```

---

### sqrt

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:47`

```python
def sqrt(x):
```

---

### start_timer

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:417`

```python
def start_timer(self, operation: str):
```

Start timing an operation.

---

### strongconnect

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_graph.py:168`

```python
def strongconnect(node_id: str):
```

---

### temporary_context

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/dynamic_scope_resolution.py:208`

```python
def temporary_context(self, context_id: str):
```

Context manager for temporarily switching contexts.

        Args:
            context_id: ID of the context to switch to temporarily

        Yields:
            The temporary context

        Example:
            with resolver.temporary_context("simulation_ctx") as ctx:
                result = resolver.resolve_variable_dynamic("model.temperature")

---

### tracked_coupling_function

**File:** `pkg/earthsci-ast-py/examples/coupling_error_handling_demo.py:303`

```python
def tracked_coupling_function(variables, **kwargs):
```

---

### update_cache_stats

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:571`

```python
def update_cache_stats(self, hits, misses):
```

---

### update_patterns

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:181`

```python
def update_patterns(self, error: CouplingError):
```

Update error pattern tracking.

---

### update_profile

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:152`

```python
def update_profile(self, execution_time: float, memory_mb: float, success: bool):
```

Update profile based on recent execution.

---

### update_worker_performance

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:382`

```python
def update_worker_performance(self, worker_id: int, task_duration: float, task_cost: float = 1.0):
```

Update worker performance based on completed task.

---

### update_worker_performance

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:461`

```python
def update_worker_performance(self, worker_id, task_duration, task_cost=1.0):
```

---

### virtual_memory

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:40`

```python
def virtual_memory():
```

---

### visit_func

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1152`

```python
def visit_func(name, obj):
```

---

### visit_nodes

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1186`

```python
def visit_nodes(node, path=""):
```

---

### zeros

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:27`

```python
def zeros(shape):
```

---

## Types

### AccelerationConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:151`

```python
class AccelerationConfig:
```

Configuration for convergence acceleration.

---

### AccelerationController

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:413`

```python
class AccelerationController:
```

Controls convergence acceleration methods.

---

### AccelerationMethod

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:97`

```python
class AccelerationMethod:
```

Convergence acceleration methods.

---

### AddOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/math_operators.py:230`

```python
class AddOperator:
```

Addition operator with broadcasting and precision handling.

---

### AffectEquation

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:34`

```python
class AffectEquation:
```

Equation that affects a variable (assignment-like).

---

### AndOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:249`

```python
class AndOperator:
```

Logical AND operator with short-circuit evaluation.

---

### ArithmeticOperatorConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/math_operators.py:108`

```python
class ArithmeticOperatorConfig:
```

Configuration for arithmetic operators.

---

### Associativity

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_registry.py:19`

```python
class Associativity:
```

Operator associativity rules.

---

### AtmosphericChemistryScenario

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/atmospheric_verification.py:25`

```python
class AtmosphericChemistryScenario:
```

Atmospheric chemistry test scenario with verification criteria.

---

### AtmosphericChemistryVerifier

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/atmospheric_verification.py:52`

```python
class AtmosphericChemistryVerifier:
```

Main verification framework for atmospheric chemistry simulations.

---

### BaseArithmeticOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/math_operators.py:119`

```python
class BaseArithmeticOperator:
```

Base class for arithmetic operators.

    Provides common functionality for type checking, broadcasting,
    and precision handling.

---

### BaseComparisonOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:381`

```python
class BaseComparisonOperator:
```

Base class for comparison operators.

    Provides common functionality for type coercion and comparison handling.

---

### BaseInterpolationOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/interpolation_operators.py:39`

```python
class BaseInterpolationOperator:
```

Base class for interpolation operators.

    Provides common functionality for input validation, coordinate handling,
    and result formatting.

---

### BaseLogicalOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:171`

```python
class BaseLogicalOperator:
```

Base class for logical operators.

    Provides common functionality for type coercion, boolean conversion,
    and configuration management.

---

### BaseSpatialOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/spatial_operators.py:99`

```python
class BaseSpatialOperator:
```

Base class for spatial differential operators.

    Provides common functionality for grid operations, boundary conditions,
    and coordinate system handling.

---

### BaseStatisticalOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/statistical_operators.py:104`

```python
class BaseStatisticalOperator:
```

Base class for statistical operators.

    Provides common functionality for input validation, axis handling,
    and NaN processing.

---

### BaseTemporalOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/temporal_operators.py:122`

```python
class BaseTemporalOperator:
```

Base class for temporal operators.

    Provides common functionality for time-based operations including
    finite difference schemes, integration methods, and boundary treatment.

---

### BinaryLoader

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1871`

```python
class BinaryLoader:
```

Binary data loader supporting custom binary formats with struct unpacking and endianness handling.

    Provides comprehensive support for legacy scientific data formats with configurable
    binary layouts, data type specifications, endianness control, and struct unpacking.
    Essential for ingesting data from older instruments and simulation outputs.

---

### BoundaryCondition

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:263`

```python
class BoundaryCondition:
```

Boundary condition specification.

---

### BoundaryConditionProcessor

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/boundary_conditions.py:84`

```python
class BoundaryConditionProcessor:
```

Comprehensive boundary condition processor and validator.

    Handles processing of boundary conditions including:
    - Validation against domain geometry
    - Spatial and temporal interpolation
    - Robin boundary condition support
    - Efficient boundary application

---

### BoundaryConditionType

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:252`

```python
class BoundaryConditionType:
```

Types of boundary conditions.

---

### BoundaryConstraint

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/boundary_conditions.py:39`

```python
class BoundaryConstraint:
```

Enhanced boundary constraint supporting spatial/temporal variation.

    Extends basic BoundaryCondition with support for:
    - Spatial variation across boundary
    - Temporal variation over time
    - Robin boundary conditions

---

### BoundaryLocationError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/boundary_conditions.py:26`

```python
class BoundaryLocationError:
```

Raised when boundary location is invalid for domain geometry.

---

### BoundaryProcessorConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/boundary_conditions.py:66`

```python
class BoundaryProcessorConfig:
```

Configuration for boundary condition processor.

---

### BoundaryValueError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/boundary_conditions.py:31`

```python
class BoundaryValueError:
```

Raised when boundary value specification is invalid.

---

### CacheManager

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:228`

```python
class CacheManager:
```

Manages caching of coupling computations.

---

### CachingStrategy

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:81`

```python
class CachingStrategy:
```

Strategies for caching coupling computations.

---

### Circle

**File:** `pkg/earthsci-ast-py/examples/operator_overloading_demo.py:123`

```python
class Circle:
```

---

### CircularReferenceError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/placeholder_expansion.py:12`

```python
class CircularReferenceError:
```

Exception raised when circular references are detected in placeholder expansion.

---

### ComponentNode

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/graph.py:59`

```python
class ComponentNode:
```

A component node representing models or reaction systems.

---

### ComponentProfile

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:139`

```python
class ComponentProfile:
```

Performance profile for a coupling component.

---

### ComponentTimeState

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/time_synchronization.py:107`

```python
class ComponentTimeState:
```

Tracks the temporal state of a coupled component.

---

### ConstraintOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/initial_conditions_setup.py:39`

```python
class ConstraintOperator:
```

Constraint enforcement strategies.

---

### ContextSwitchResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/dynamic_scope_resolution.py:61`

```python
class ContextSwitchResult:
```

Result of a context switch operation.

---

### ContinuousEvent

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:115`

```python
class ContinuousEvent:
```

An event that occurs when a condition becomes true during continuous evolution.

---

### ConvergenceChecker

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:210`

```python
class ConvergenceChecker:
```

Abstract base class for convergence checking algorithms.

---

### ConvergenceConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:106`

```python
class ConvergenceConfig:
```

Configuration for convergence checking.

---

### ConvergenceMethod

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:81`

```python
class ConvergenceMethod:
```

Convergence checking methods.

---

### CoordinateTransform

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:229`

```python
class CoordinateTransform:
```

Coordinate transformation specification.

---

### CoordinateTransformation

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_transformation.py:379`

```python
class CoordinateTransformation:
```

Coordinate system transformations.

---

### CouplingEdge

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_graph.py:45`

```python
class CouplingEdge:
```

An edge in the coupling graph.

---

### CouplingEdge

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/graph.py:83`

```python
class CouplingEdge:
```

An edge representing coupling between components.

---

### CouplingEntry

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:197`

```python
class CouplingEntry:
```

Entry describing how model components are coupled.

---

### CouplingError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:78`

```python
class CouplingError:
```

Specialized error for coupling failures.

---

### CouplingErrorAnalyzer

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:140`

```python
class CouplingErrorAnalyzer:
```

Analyzes coupling errors to provide insights and recommendations.

---

### CouplingErrorContext

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:66`

```python
class CouplingErrorContext:
```

Extended context for coupling-specific errors.

---

### CouplingErrorType

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:35`

```python
class CouplingErrorType:
```

Types of coupling errors that can occur.

---

### CouplingGraph

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_graph.py:82`

```python
class CouplingGraph:
```

A coupling graph representing dependencies between model components.

    The graph consists of nodes representing models, reaction systems, and variables,
    and edges representing coupling relationships between them.

---

### CouplingIterator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:607`

```python
class CouplingIterator:
```

Main coupling iteration controller.

    Manages the iterative coupling process between multiple Earth system components
    with convergence checking, relaxation, and acceleration.

---

### CouplingNode

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_graph.py:35`

```python
class CouplingNode:
```

A node in the coupling graph.

---

### CouplingRecoveryManager

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:193`

```python
class CouplingRecoveryManager:
```

Manages recovery strategies for coupling failures.

---

### CouplingResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:189`

```python
class CouplingResult:
```

Result of coupling iteration.

---

### CouplingType

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:188`

```python
class CouplingType:
```

Types of coupling between model components.

---

### CubicInterpolationOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/interpolation_operators.py:237`

```python
class CubicInterpolationOperator:
```

Cubic spline interpolation operator using scipy.interpolate.CubicSpline.

---

### DataDescriptor

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_transformation.py:77`

```python
class DataDescriptor:
```

Description of data characteristics for transformation validation.

---

### DataLoader

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:157`

```python
class DataLoader:
```

Configuration for loading external data.

---

### DataLoaderRegistry

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loader_registry.py:21`

```python
class DataLoaderRegistry:
```

Registry for data loader implementations.

    Manages loader registration, discovery, and selection based on various criteria
    including file extensions, MIME types, and explicit loader types.

---

### DataLoaderType

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:143`

```python
class DataLoaderType:
```

Types of data loaders.

---

### DataTransformation

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_transformation.py:101`

```python
class DataTransformation:
```

Abstract base class for data transformation operations.

---

### DataTransformationPipeline

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_transformation.py:580`

```python
class DataTransformationPipeline:
```

Pipeline for chaining multiple data transformations.

---

### DatabaseLoader

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:558`

```python
class DatabaseLoader:
```

Database data loader supporting SQLite and PostgreSQL.

    Provides connection pooling, query optimization, transaction handling,
    and support for both local SQLite databases and remote PostgreSQL instances.
    Essential for persistent data storage integration.

---

### DemoCacheManager

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:330`

```python
class DemoCacheManager:
```

---

### DemoLoadBalancer

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:432`

```python
class DemoLoadBalancer:
```

---

### DemoOperator

**File:** `pkg/earthsci-ast-py/examples/precedence_dependency_demo.py:20`

```python
class DemoOperator:
```

Demo operator for examples.

---

### DependencyEdge

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/graph.py:90`

```python
class DependencyEdge:
```

An edge representing mathematical dependencies.

---

### DependencyInfo

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_graph.py:56`

```python
class DependencyInfo:
```

Information about dependencies between components.

---

### DerivativeOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/temporal_operators.py:187`

```python
class DerivativeOperator:
```

Temporal derivative operator using finite difference schemes.

    Supports various finite difference schemes including forward, backward,
    and central differences with configurable order of accuracy.

---

### DiagnosticReport

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:113`

```python
class DiagnosticReport:
```

Comprehensive diagnostic report for coupling failures.

---

### DiscreteEvent

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:131`

```python
class DiscreteEvent:
```

An event that occurs at discrete time points.

---

### DiscreteEventTrigger

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:124`

```python
class DiscreteEventTrigger:
```

Trigger condition for a discrete event.

---

### DivergenceOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/spatial_operators.py:271`

```python
class DivergenceOperator:
```

Divergence operator for vector fields with finite difference implementation.

---

### DivideOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/math_operators.py:347`

```python
class DivideOperator:
```

Division operator with broadcasting, precision, and divide-by-zero handling.

---

### Domain

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:276`

```python
class Domain:
```

Comprehensive computational domain specification.

---

### DynamicScopeResolver

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/dynamic_scope_resolution.py:72`

```python
class DynamicScopeResolver:
```

Dynamic scope resolver with runtime context support.

    This resolver extends HierarchicalScopeResolver to support runtime
    modifications including parameter injection, context switching,
    and dynamic scope creation.

---

### ESMEditor

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/edit.py:45`

```python
class ESMEditor:
```

Editor for ESM format structures with validation and safety checks.

---

### ESMError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:114`

```python
class ESMError:
```

Comprehensive error representation with diagnostics and suggestions.

---

### ESMErrorFactory

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:246`

```python
class ESMErrorFactory:
```

Factory for creating standardized ESM errors with helpful suggestions.

---

### ESMExplorer

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/display.py:525`

```python
class ESMExplorer:
```

Interactive explorer widget for ESM files in Jupyter notebooks.

---

### EditOperation

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/edit.py:26`

```python
class EditOperation:
```

Represents an editing operation that can be applied to an ESM structure.

---

### EditResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/edit.py:36`

```python
class EditResult:
```

Result of an editing operation.

---

### EndToEndVerificationSuite

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/end_to_end_verification.py:33`

```python
class EndToEndVerificationSuite:
```

Complete end-to-end verification suite for atmospheric chemistry.

---

### EqualOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:410`

```python
class EqualOperator:
```

Equality comparison operator.

---

### Equation

**File:** `pkg/earthsci-ast-py/display_test.py:18`

```python
class Equation:
```

Mathematical equation with left and right hand sides.

---

### Equation

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:27`

```python
class Equation:
```

Mathematical equation with left and right hand sides.

---

### ErrorCode

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:22`

```python
class ErrorCode:
```

Standardized error codes for consistent error handling across all libraries.

---

### ErrorCollector

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:198`

```python
class ErrorCollector:
```

Collects and manages errors during ESM processing.

---

### ErrorContext

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:91`

```python
class ErrorContext:
```

Additional context information for errors.

---

### EsmFile

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:342`

```python
class EsmFile:
```

Root container for an ESM format file.

---

### ExecutionMode

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:57`

```python
class ExecutionMode:
```

Modes for handling partial execution.

---

### ExecutionStrategy

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:63`

```python
class ExecutionStrategy:
```

Strategies for parallel execution of coupling components.

---

### ExpansionContext

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/placeholder_expansion.py:24`

```python
class ExpansionContext:
```

Context manager for placeholder expansion operations.

    Tracks expansion state, detects circular references, and manages
    the expansion process across nested expressions.

---

### ExprNode

**File:** `pkg/earthsci-ast-py/display_test.py:10`

```python
class ExprNode:
```

A node in an expression tree.

---

### ExprNode

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:14`

```python
class ExprNode:
```

A node in an expression tree.

---

### FieldConstraint

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/initial_conditions_setup.py:47`

```python
class FieldConstraint:
```

Constraint specification for a field.

---

### FixSuggestion

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:104`

```python
class FixSuggestion:
```

Actionable suggestion for fixing an error.

---

### ForwardDifferenceOperator

**File:** `pkg/earthsci-ast-py/examples/operator_registry_example.py:66`

```python
class ForwardDifferenceOperator:
```

Example differentiation operator.

---

### FunctionalAffect

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:107`

```python
class FunctionalAffect:
```

A functional effect applied during an event.

---

### GRIBLoader

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1522`

```python
class GRIBLoader:
```

GRIB data loader supporting GRIB1 and GRIB2 meteorological data formats.

    Provides comprehensive support for GRIB files including parameter tables,
    grid definitions, ensemble data handling, and metadata extraction. Essential
    for weather and climate model data ingestion.

---

### GradientOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/spatial_operators.py:196`

```python
class GradientOperator:
```

Gradient operator with grid-aware finite difference implementation.

---

### Graph

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/graph.py:97`

```python
class Graph:
```

Generic graph representation with nodes and edges.

---

### GraphEdge

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/graph.py:73`

```python
class GraphEdge:
```

An edge in a graph representation.

---

### GraphNode

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/graph.py:50`

```python
class GraphNode:
```

A node in a graph representation.

---

### GreaterThanOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:550`

```python
class GreaterThanOperator:
```

Greater-than comparison operator.

---

### GreaterThanOrEqualOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:587`

```python
class GreaterThanOrEqualOperator:
```

Greater-than-or-equal comparison operator.

---

### GridInterpolationOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/interpolation_operators.py:373`

```python
class GridInterpolationOperator:
```

Grid-based interpolation operator for multi-dimensional data.

    Supports nearest-neighbor, linear, and cubic interpolation on regular grids.
    Useful for regridding and coordinate transformations.

---

### GridInterpolationTransformation

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_transformation.py:252`

```python
class GridInterpolationTransformation:
```

Grid interpolation and remapping using SciPy.

---

### HDF5Loader

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:1035`

```python
class HDF5Loader:
```

HDF5 data loader supporting hierarchical data structures with h5py/pytables integration.

    Provides comprehensive support for HDF5 files including group navigation, dataset chunking,
    compression handling, and metadata extraction. Essential for large-scale scientific
    dataset ingestion with hierarchical organization.

---

### HierarchicalScopeResolver

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/hierarchical_scope_resolution.py:48`

```python
class HierarchicalScopeResolver:
```

Enhanced hierarchical scope resolver with shadowing and inheritance.

    This resolver builds a complete scope hierarchy tree and implements
    sophisticated variable resolution with proper shadowing semantics.

---

### InitialCondition

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:244`

```python
class InitialCondition:
```

Initial condition specification.

---

### InitialConditionConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/initial_conditions_setup.py:58`

```python
class InitialConditionConfig:
```

Configuration for initial condition processing.

---

### InitialConditionProcessor

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/initial_conditions_setup.py:73`

```python
class InitialConditionProcessor:
```

Comprehensive initial condition processor and validator.

    This class handles:
    - Field initialization from constant, function, or data sources
    - Validation against model variable definitions
    - Constraint enforcement (bounds, units)
    - Compatibility checking with governing equations

---

### InitialConditionSetupError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/initial_conditions_setup.py:67`

```python
class InitialConditionSetupError:
```

Error during initial condition setup.

---

### InitialConditionType

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:236`

```python
class InitialConditionType:
```

Types of initial conditions.

---

### IntegralOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/temporal_operators.py:284`

```python
class IntegralOperator:
```

Temporal integral operator using various numerical integration methods.

    Supports rectangular rule, trapezoidal rule, Simpson's rule, and adaptive
    integration schemes for computing definite integrals over time.

---

### IntegrationMethod

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/temporal_operators.py:28`

```python
class IntegrationMethod:
```

Methods for temporal integration.

---

### InteractiveErrorExplorer

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:449`

```python
class InteractiveErrorExplorer:
```

Interactive tools for exploring and understanding errors.

---

### InterpolationConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/interpolation_operators.py:25`

```python
class InterpolationConfig:
```

Configuration for interpolation operators.

---

### IterationState

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:169`

```python
class IterationState:
```

State information for a coupling iteration.

---

### JSONLoader

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:251`

```python
class JSONLoader:
```

JSON data loader with JSONSchema validation and type coercion.

    Supports nested object handling, schema validation, and type coercion capabilities.
    Essential for configuration files and structured metadata ingestion.

---

### JuliaIntegrator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/julia_integration.py:57`

```python
class JuliaIntegrator:
```

Interface for Julia ModelingToolkit/Catalyst integration.

---

### JuliaPerformanceMetrics

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/julia_integration.py:38`

```python
class JuliaPerformanceMetrics:
```

Performance metrics from Julia simulation.

---

### JuliaSimulationConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/julia_integration.py:21`

```python
class JuliaSimulationConfig:
```

Configuration for Julia simulation backend.

---

### JuliaSimulationError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/julia_integration.py:52`

```python
class JuliaSimulationError:
```

Exception raised during Julia simulation.

---

### LaplacianOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/spatial_operators.py:330`

```python
class LaplacianOperator:
```

Laplacian operator (∇²) with finite difference implementation.

---

### LessThanOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:476`

```python
class LessThanOperator:
```

Less-than comparison operator.

---

### LessThanOrEqualOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:513`

```python
class LessThanOrEqualOperator:
```

Less-than-or-equal comparison operator.

---

### LinAlgError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:65`

```python
class LinAlgError:
```

---

### LinearInterpolationOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/interpolation_operators.py:183`

```python
class LinearInterpolationOperator:
```

Linear interpolation operator using scipy.interpolate.interp1d.

---

### LinearInterpolationOperator

**File:** `pkg/earthsci-ast-py/examples/operator_registry_example.py:24`

```python
class LinearInterpolationOperator:
```

Example linear interpolation operator.

---

### LoadBalancer

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:313`

```python
class LoadBalancer:
```

Balances computational load across available resources.

---

### LoadBalancingMethod

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:72`

```python
class LoadBalancingMethod:
```

Methods for balancing computational load across resources.

---

### LogicalOperatorConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:162`

```python
class LogicalOperatorConfig:
```

Configuration for logical operators.

---

### MathematicalVerifier

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/verification.py:69`

```python
class MathematicalVerifier:
```

Main verification class for mathematical correctness.

---

### MeanOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/statistical_operators.py:179`

```python
class MeanOperator:
```

Mean (average) operator for statistical aggregation.

---

### MedianOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/statistical_operators.py:364`

```python
class MedianOperator:
```

Median operator (50th percentile).

---

### MemoryOptimizer

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:175`

```python
class MemoryOptimizer:
```

Optimizes memory usage during coupling execution.

---

### Metadata

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:328`

```python
class Metadata:
```

Metadata about the model or dataset.

---

### MixedConvergenceChecker

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:234`

```python
class MixedConvergenceChecker:
```

Mixed convergence checker using absolute, relative, and residual criteria.

---

### Model

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:55`

```python
class Model:
```

A mathematical model containing variables and equations.

---

### ModelVariable

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:45`

```python
class ModelVariable:
```

A variable in a mathematical model.

---

### MultiplyOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/math_operators.py:308`

```python
class MultiplyOperator:
```

Multiplication operator with broadcasting and precision handling.

---

### NetCDFLoader

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:59`

```python
class NetCDFLoader:
```

NetCDF data loader using xarray for multidimensional scientific data.

    Supports CF conventions, coordinate system validation, and proper metadata extraction.
    Essential for atmospheric and climate data ingestion.

---

### NodeType

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_graph.py:27`

```python
class NodeType:
```

Types of nodes in a coupling graph.

---

### NotEqualOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:443`

```python
class NotEqualOperator:
```

Not-equal comparison operator.

---

### NotOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:347`

```python
class NotOperator:
```

Logical NOT operator.

---

### Operator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:179`

```python
class Operator:
```

Mathematical operator applied to data or expressions.

---

### OperatorDispatcher

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_dispatch.py:89`

```python
class OperatorDispatcher:
```

Central dispatcher for operator overloading and polymorphism.

    Manages multiple implementations of operators based on input types,
    provides automatic dispatch, and handles fallback mechanisms.

---

### OperatorOverload

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_dispatch.py:78`

```python
class OperatorOverload:
```

Represents a specific operator implementation for given types.

---

### OperatorPrecedence

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_registry.py:26`

```python
class OperatorPrecedence:
```

Operator precedence and associativity information.

---

### OperatorRegistry

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_registry.py:53`

```python
class OperatorRegistry:
```

Registry for operator implementations.

    Manages operator registration, discovery, and selection based on various criteria
    including operator name, type, and signature.

---

### OperatorRequirements

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_validation.py:36`

```python
class OperatorRequirements:
```

Requirements for operator implementations.

---

### OperatorType

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:166`

```python
class OperatorType:
```

Types of mathematical operators.

---

### OperatorValidator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_validation.py:47`

```python
class OperatorValidator:
```

Validator for operator implementations.

    Validates that custom operators meet interface requirements,
    have proper documentation, and support runtime type checking.

---

### OptimizationConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:124`

```python
class OptimizationConfig:
```

Configuration for coupling performance optimization.

---

### OrOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/logical_operators.py:298`

```python
class OrOperator:
```

Logical OR operator with short-circuit evaluation.

---

### ParallelExecutionEngine

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:417`

```python
class ParallelExecutionEngine:
```

Manages parallel execution of coupling components.

---

### Parameter

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:74`

```python
class Parameter:
```

A parameter for reaction systems.

---

### PercentileOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/statistical_operators.py:257`

```python
class PercentileOperator:
```

Percentile operator for distribution analysis.

---

### PerformanceMetrics

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:91`

```python
class PerformanceMetrics:
```

Metrics for tracking coupling performance.

---

### PerformanceOptimizedCouplingIterator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:610`

```python
class PerformanceOptimizedCouplingIterator:
```

Coupling iterator with comprehensive performance optimizations.

    This class extends the standard coupling iteration with:
    - Parallel execution of independent components
    - Load balancing across computational resources
    - Memory optimization and monitoring
    - Intelligent caching of computations
    - Adaptive optimization strategies

---

### PerformanceProfiler

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:409`

```python
class PerformanceProfiler:
```

Performance profiling tool for ESM operations.

---

### PerformanceTracker

**File:** `pkg/earthsci-ast-py/examples/coupling_performance_optimization_demo.py:553`

```python
class PerformanceTracker:
```

---

### PlaceholderExpansionError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/placeholder_expansion.py:17`

```python
class PlaceholderExpansionError:
```

Exception raised when placeholder expansion fails.

---

### Reaction

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:84`

```python
class Reaction:
```

A chemical reaction.

---

### ReactionSystem

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:94`

```python
class ReactionSystem:
```

A system of chemical reactions.

---

### RecoveryConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:96`

```python
class RecoveryConfig:
```

Configuration for coupling error recovery.

---

### RecoveryStrategy

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:47`

```python
class RecoveryStrategy:
```

Strategies for recovering from coupling failures.

---

### Rectangle

**File:** `pkg/earthsci-ast-py/examples/operator_overloading_demo.py:117`

```python
class Rectangle:
```

---

### Reference

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:317`

```python
class Reference:
```

Bibliographic reference.

---

### RelaxationConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:133`

```python
class RelaxationConfig:
```

Configuration for relaxation methods.

---

### RelaxationController

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:295`

```python
class RelaxationController:
```

Controls relaxation parameters during coupling iteration.

---

### RelaxationMethod

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:89`

```python
class RelaxationMethod:
```

Relaxation methods for coupling iteration.

---

### RemoteLoader

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:2650`

```python
class RemoteLoader:
```

Remote data loader for HTTP, FTP, and cloud storage access.

    Supports authentication, caching, retry logic, and progress tracking for
    remote data sources including HTTP/HTTPS, FTP/SFTP, and cloud storage
    services like S3, Azure Blob Storage, and Google Cloud Storage.

---

### RobustCouplingIterator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_error_handling.py:427`

```python
class RobustCouplingIterator:
```

Coupling iterator with comprehensive error handling and recovery.

    This class wraps the standard CouplingIterator with robust error handling,
    recovery strategies, and diagnostic capabilities.

---

### RuntimeContext

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/dynamic_scope_resolution.py:40`

```python
class RuntimeContext:
```

A runtime execution context with injected parameters and overrides.

---

### RuntimeVariable

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/dynamic_scope_resolution.py:27`

```python
class RuntimeVariable:
```

A variable with runtime context information.

---

### SchemaValidationError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/parse.py:28`

```python
class SchemaValidationError:
```

Exception raised when schema validation fails.

---

### ScopeInfo

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/hierarchical_scope_resolution.py:24`

```python
class ScopeInfo:
```

Information about a scope in the hierarchy.

---

### ScopeValidationError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/validation.py:624`

```python
class ScopeValidationError:
```

Represents a scope validation error with detailed information.

---

### ScopeValidationResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/validation.py:650`

```python
class ScopeValidationResult:
```

Result of comprehensive scope validation.

---

### ScopeValidator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/validation.py:672`

```python
class ScopeValidator:
```

Comprehensive scope validation system with detailed error reporting.

    This validator provides:
    1. Undefined reference detection
    2. Scope boundary violation detection
    3. Resolution path tracking
    4. Shadowing analysis
    5. Hierarchy consistency validation

---

### ScopedReference

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_graph.py:945`

```python
class ScopedReference:
```

A resolved scoped reference containing the path and target information.

    A scoped reference like 'AtmosphereModel.Chemistry.temperature' is resolved into:
    - path: ['AtmosphereModel', 'Chemistry'] (the hierarchy path)
    - target: 'temperature' (the final variable/system name)
    - resolved_component: The actual component object
    - resolved_variable: The actual variable object (if applicable)

---

### ScopedReferenceResolver

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_graph.py:963`

```python
class ScopedReferenceResolver:
```

Resolver for hierarchical scoped references in ESM format.

    Implements the hierarchical dot notation resolution algorithm from Section 4.3:
    Given 'A.B.C.var', splits on '.' → [A, B, C, var]
    Final segment 'var' is variable name
    Path [A, B, C] walks subsystem hierarchy

---

### Severity

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:81`

```python
class Severity:
```

Error severity levels.

---

### Shape

**File:** `pkg/earthsci-ast-py/examples/operator_overloading_demo.py:113`

```python
class Shape:
```

---

### SimpleCSVLoader

**File:** `pkg/earthsci-ast-py/examples/data_loader_registry_example.py:129`

```python
class SimpleCSVLoader:
```

Simple CSV loader for demonstration.

---

### SimulationError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/simulation.py:105`

```python
class SimulationError:
```

Exception raised during simulation.

---

### SimulationResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/simulation.py:31`

```python
class SimulationResult:
```

Result of a simulation run.

---

### Solver

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:303`

```python
class Solver:
```

Numerical solver configuration.

---

### SolverType

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:293`

```python
class SolverType:
```

Types of numerical solvers.

---

### SpatialDimension

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:220`

```python
class SpatialDimension:
```

Spatial dimension specification.

---

### SpatialOperatorConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/spatial_operators.py:87`

```python
class SpatialOperatorConfig:
```

Configuration for spatial differential operators.

---

### Species

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:64`

```python
class Species:
```

A chemical species in a reaction system.

---

### SplineInterpolationOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/interpolation_operators.py:287`

```python
class SplineInterpolationOperator:
```

General spline interpolation operator with configurable order.

---

### SplineInterpolationOperator

**File:** `pkg/earthsci-ast-py/examples/operator_registry_example.py:46`

```python
class SplineInterpolationOperator:
```

Example spline interpolation operator (newer version).

---

### StandardDeviationOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/statistical_operators.py:325`

```python
class StandardDeviationOperator:
```

Standard deviation operator (square root of variance).

---

### StatisticalOperatorConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/statistical_operators.py:94`

```python
class StatisticalOperatorConfig:
```

Configuration for statistical operators.

---

### StreamingLoader

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_loaders.py:2409`

```python
class StreamingLoader:
```

Streaming data loader supporting real-time data ingestion from multiple sources.

    Provides comprehensive support for message queues, websockets, and streaming APIs
    with buffering, backpressure handling, and connection resilience. Essential for
    real-time data ingestion and processing in scientific workflows.

---

### SubtractOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/math_operators.py:269`

```python
class SubtractOperator:
```

Subtraction operator with broadcasting and precision handling.

---

### TemporalAveragingOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/temporal_operators.py:395`

```python
class TemporalAveragingOperator:
```

Temporal averaging operator for computing time-averaged quantities.

    Supports moving averages, exponential smoothing, and other temporal
    filtering operations commonly used in atmospheric and climate modeling.

---

### TemporalDomain

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/types.py:212`

```python
class TemporalDomain:
```

Temporal domain specification.

---

### TemporalOperatorConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/temporal_operators.py:38`

```python
class TemporalOperatorConfig:
```

Configuration for temporal operators.

---

### TemporalScheme

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/temporal_operators.py:17`

```python
class TemporalScheme:
```

Time-stepping and discretization schemes.

---

### TimeAlignmentStrategy

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/time_synchronization.py:38`

```python
class TimeAlignmentStrategy:
```

Strategies for aligning time between components.

---

### TimeExtrapolationMethod

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/time_synchronization.py:30`

```python
class TimeExtrapolationMethod:
```

Methods for time extrapolation.

---

### TimeInterpolationMethod

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/time_synchronization.py:22`

```python
class TimeInterpolationMethod:
```

Methods for time interpolation.

---

### TimePoint

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/time_synchronization.py:73`

```python
class TimePoint:
```

Represents a point in time with associated data.

---

### TimeSeries

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/time_synchronization.py:81`

```python
class TimeSeries:
```

A time series of data points.

---

### TimeStep

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/time_synchronization.py:47`

```python
class TimeStep:
```

Represents a time step with value and units.

---

### TimeSteppingOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/temporal_operators.py:474`

```python
class TimeSteppingOperator:
```

Time-stepping operator for advancing model states in time.

    Implements various time-stepping schemes like Runge-Kutta methods,
    Euler schemes, and predictor-corrector methods for temporal evolution.

---

### TimeSynchronizer

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/time_synchronization.py:132`

```python
class TimeSynchronizer:
```

Main class for synchronizing time between coupled components.

    This class manages the temporal coordination of multiple components
    with potentially different time steps, handling data interpolation
    and extrapolation as needed for coupling.

---

### TransformationConfig

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_transformation.py:69`

```python
class TransformationConfig:
```

Configuration for a single transformation operation.

---

### TransformationResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_transformation.py:90`

```python
class TransformationResult:
```

Result of a data transformation operation.

---

### TransformationType

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_transformation.py:44`

```python
class TransformationType:
```

Types of data transformations supported in coupling pipeline.

---

### TypeSignature

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_dispatch.py:20`

```python
class TypeSignature:
```

Type signature for operator dispatch.

---

### UnitConversionResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/units.py:45`

```python
class UnitConversionResult:
```

Result of unit conversion operation.

---

### UnitConversionTransformation

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_transformation.py:152`

```python
class UnitConversionTransformation:
```

Unit conversion using Pint library.

---

### UnitValidationResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/units.py:35`

```python
class UnitValidationResult:
```

Result of unit validation check.

---

### UnitValidator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/units.py:53`

```python
class UnitValidator:
```

Validator for dimensional consistency in ESM format structures.

---

### UnitWarning

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/validation.py:38`

```python
class UnitWarning:
```

Represents a unit validation warning.

---

### UnsupportedVersionError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/parse.py:33`

```python
class UnsupportedVersionError:
```

Exception raised when ESM version is not supported.

---

### ValidationError

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/validation.py:25`

```python
class ValidationError:
```

Represents a single validation error.

---

### ValidationLevel

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_validation.py:19`

```python
class ValidationLevel:
```

Validation strictness levels.

---

### ValidationResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/validation.py:52`

```python
class ValidationResult:
```

Represents the result of validation.

---

### ValidationResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/operator_validation.py:27`

```python
class ValidationResult:
```

Result of operator validation.

---

### VariableMatchResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_graph.py:65`

```python
class VariableMatchResult:
```

Result of variable matching between source and target variables.

---

### VariableNode

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/graph.py:66`

```python
class VariableNode:
```

A variable node representing mathematical variables or expressions.

---

### VariableResolution

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/hierarchical_scope_resolution.py:36`

```python
class VariableResolution:
```

Result of variable resolution with scope information.

---

### VariableTransformation

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/data_transformation.py:485`

```python
class VariableTransformation:
```

ESM variable transformations (additive, multiplicative, etc.).

---

### VarianceOperator

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/statistical_operators.py:218`

```python
class VarianceOperator:
```

Variance operator for statistical analysis.

---

### VerificationReport

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/verification.py:48`

```python
class VerificationReport:
```

Comprehensive verification report.

---

### VerificationResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/verification.py:35`

```python
class VerificationResult:
```

Result of a verification check.

---

### VerificationResult

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/atmospheric_verification.py:39`

```python
class VerificationResult:
```

Result of atmospheric chemistry verification.

---

### VerificationStatus

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/verification.py:26`

```python
class VerificationStatus:
```

Status of verification results.

---

### linalg

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:54`

```python
class linalg:
```

---

### np_fallback

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_iteration.py:21`

```python
class np_fallback:
```

---

### profile_operation

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/error_handling.py:537`

```python
class profile_operation:
```

Context manager for profiling ESM operations.

---

### psutil_fallback

**File:** `pkg/earthsci-ast-py/src/earthsci_ast/coupling_performance.py:31`

```python
class psutil_fallback:
```

---

