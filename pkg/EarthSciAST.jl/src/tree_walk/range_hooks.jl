# ========================================================================
# tree_walk/range_hooks.jl — the build's seams for a range-restricted
# program (API_SPEC §5.8, `restrict` / `lanes`; src/range_restricted.jl).
#
# A restricted build runs the ordinary pipeline under a task-local range spec.
# Without one (every other build) each hook below is the identity, so the
# build is unchanged.
# ========================================================================

const _RANGE_SPEC_KEY = :earthsci_range_spec

_range_spec_now() = get(task_local_storage(), _RANGE_SPEC_KEY, nothing)
_with_range_spec(f, spec) = task_local_storage(f, _RANGE_SPEC_KEY, spec)

# The equation stream after the ODE partition, clipped to the needed cells.
_range_restrict_parts(::Nothing, model, cls, parts, index_sets, const_arrays,
                      param_arrays) = parts

# Each array state's block, rebased onto the cells the program stores.
_range_state_boxes!(::Nothing, array_var_info) = array_var_info

# A materialized array observed's buffer block over its full extent `dims`, or
# `nothing` to leave the observed inlined.
_range_observed_box(::Nothing, name, dims) = (ones(Int, length(dims)), copy(dims))

# The fill equations of a materialized array observed over its block `box`.
_range_fill_equations(::Nothing, name, def, dims, box) =
    _materialized_fill_equations(name, def, dims)

# The build's forcing epoch (tree_walk/cadence_stamp.jl), which a lane
# program bumps when it rewrites its live lane buffers.
_range_build_epoch(::Nothing, epoch) = nothing

# The document and build keywords the AbstractDict front door hands the typed
# build, recorded so a restriction re-lowers without re-reading the document.
_range_front_door_done(::Nothing, file, model_name, kwd) = nothing

# ---- What a program build records for its workspaces (src/rhs_program.jl) ----
#
# A program's workspace is a private instance of its compiled right-hand side.
# The instance needs, by identity, the arrays through which the build reads
# each live buffer (its `_PGatherArray`s) and every array generated code
# writes at run time besides `du` and the per-call state types (a build
# registers each as scratch where it allocates it). A build with no capture
# open records nothing.
struct _WsCapture
    pgathers::Vector{Any}
    scratch::IdDict{Any,Nothing}
end
_WsCapture() = _WsCapture(Any[], IdDict{Any,Nothing}())

const _WS_CAPTURE_KEY = :earthsci_ws_capture

_ws_capture_now() = get(task_local_storage(), _WS_CAPTURE_KEY, nothing)
_with_ws_capture(f, c::_WsCapture) = task_local_storage(f, _WS_CAPTURE_KEY, c)

function _ws_note_pgather!(pgather)
    c = _ws_capture_now()
    c === nothing || push!(c.pgathers, pgather)
    return nothing
end

# Mark `x`, an array generated code writes at run time, as per-instance scratch.
function _ws_scratch!(x)
    c = _ws_capture_now()
    c === nothing || (c.scratch[x] = nothing)
    return x
end
