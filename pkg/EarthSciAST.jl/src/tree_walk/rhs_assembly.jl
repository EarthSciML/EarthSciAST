# tree_walk/rhs_assembly.jl — the in-place right-hand side of a build: one typed
# value (`_Rhs`) holding its stages, and the one function that runs a stage.
#
# A stage (`_RhsStage`) is what one level of the right-hand side computes, in
# this order:
#   1. its scalars: for the state equations the scalar prelude and equations
#      (`_StateScalars`), for an observed fill level the walked `(slot, node)`
#      entries;
#   2. its access kernels, as one generated section (codegen_kernel.jl), which
#      may read the prelude cache filled in step 1 at the same value type;
#   3. its prefix scans, which read back the terms step 2 wrote;
#   4. its whole-array contractions, each over its own slots;
#   5. its recurrence sweeps (observed levels only), each one ordered pass over
#      its own buffer.
# The state equations are one stage; the materialized array observeds are a
# tuple of stages per cadence, run before it (`_RhsObserved`).
#
# Every field is concretely typed through the struct parameters and the levels
# are tuples walked by tail recursion, so each call is statically dispatched
# and the right-hand side allocates nothing in steady state. It is not
# reentrant (it writes the build's scratch): one instance per integrator.

# ---- One stage --------------------------------------------------------------

struct _RhsStage{S, K, SC, AC, RS}
    scalars::S
    kernels::K
    scans::SC
    contractions::AC
    sweeps::RS
end

# `ue` is the slot space a stage reads (`u`) and `due` the one it writes
# (`du`): one full-length vector, or two views sharing the observed buffer
# (`_ObsSplitVec`). An observed stage writes only its own observed slots,
# except a fused scan that also computes a state equation from each value it
# folds (scan_fused.jl), which writes that equation's `du` slots.
@inline function _run_stage!(st::_RhsStage, due, ue, p, t, ::Type{T}) where {T}
    _run_scalars!(st.scalars, due, ue, p, t, T)
    st.kernels(due, ue, p, t, T)
    isempty(st.scans) || _apply_scan_folds!(due, ue, p, t, st.scans)
    isempty(st.contractions) || _apply_array_contractions!(due, ue, p, t, st.contractions, T)
    _run_recurrence_sweeps!(st.sweeps, ue, p, t, T)
    return nothing
end

# An observed level's scalars: walked entries.
@inline function _run_scalars!(
        ents::AbstractVector{Tuple{Int, _Node}}, due, ue, p, t, ::Type{T}
    ) where {T}
    @inbounds for k in eachindex(ents)
        e = ents[k]
        due[e[1]] = _eval_node(e[2], ue, p, t, T)
    end
    return nothing
end

# One in-place fill level, the kernels class-merged first. The kernel
# section's emission refuses what it cannot generate, naming the rule open at
# the time; `section_label` (a function of the build, `f -> …`) opens the right
# one around it.
function _inplace_fill_level(
        scalars, kernels, scans, contractions, recurrences;
        nst::Int = 0, section_label = f -> f()
    )
    merged, _ = _merge_acc_kernel_classes(kernels)
    section = section_label(() -> _make_kernel_section(merged; nst = nst))
    return _RhsStage(
        scalars, section, scans, _make_contraction_section(contractions), Tuple(recurrences)
    )
end

# A tuple of stages, in dependency order: a stage reads the state and lower
# stages only.
@inline _fill_obs_levels!(levels::Tuple, ue, p, t, ::Type{T}) where {T} =
    _fill_obs_levels!(levels, ue, ue, p, t, T)
@inline _fill_obs_levels!(::Tuple{}, due, ue, p, t, ::Type{T}) where {T} = nothing
@inline function _fill_obs_levels!(levels::Tuple, due, ue, p, t, ::Type{T}) where {T}
    _run_stage!(levels[1], due, ue, p, t, T)
    return _fill_obs_levels!(Base.tail(levels), due, ue, p, t, T)
end

# ---- The state equations' scalars ------------------------------------------
# The scalar prelude and scalar equations of the state stage. It computes in
# `T`, a compile-time constant per specialization, so at `T === Float64` the
# scratch lookups are field loads; handed dual-number state or parameters, the
# same value evaluates in that type on buffers created on its first such call.
#   1. const tier: the prelude slots that are a pure function of `p`
#      (const_tier.jl), refilled only when `p` moved (`_cse_const_stale`). Not
#      folded at build time: `p` changes under `remake`, and its values are
#      dual numbers under a parameter sensitivity.
#   2. time tier: the slots that are a pure function of `p`, `t` and the
#      contents of the live forcing buffers they gather, refilled when `p`, `t`
#      or the build's forcing epoch moved (`_cse_t_stale`). A Jacobian's columns
#      at one `t` evaluate it once; revisiting a `t` after a rejected step
#      recomputes the same values, since the slots carry no history.
#   3. dynamic slots and scalar equations, every call: the generated units,
#      then whatever the section left on the walker. Every slot is evaluated
#      before any equation, which is safe because `_cse_compile_scalar` never
#      makes a slot whose every occurrence is under a lazy `ifelse`/`and`/`or`
#      arm (scalar_cse.jl).
# A tier the scalar section emitted runs as generated code, otherwise it is
# walked (`_walk_prelude_slots!`). The walked prelude is held only when
# something is still walked, so a fully emitted build carries no tree.
struct _StateScalars{CP, TP, DP, W}
    cse_cache::_CSECache
    constp::CP
    timep::TP
    dynp::DP
    const_walk::Vector{Int}
    time_walk::Vector{Int}
    resid_dyn::Vector{Int}
    resid_rhs::Vector{Tuple{Int, _Node}}
    cse_prelude::Vector{_Node}
    walk::W
    has_const::Bool
    has_time::Bool
end

function _StateScalars(
        sec::_ScalarSection, full_prelude::AbstractVector{_Node}, cse_cache::_CSECache,
        const_slots::AbstractVector{Int}, time_slots::AbstractVector{Int}
    )
    walks_prelude = (sec.constp === nothing && !isempty(const_slots)) ||
        (sec.timep === nothing && !isempty(time_slots)) || !isempty(sec.resid_dyn)
    return _StateScalars(
        cse_cache, sec.constp, sec.timep, sec.dynp,
        sec.constp === nothing ? collect(Int, const_slots) : Int[],
        sec.timep === nothing ? collect(Int, time_slots) : Int[],
        sec.resid_dyn, sec.resid_rhs,
        walks_prelude ? collect(_Node, full_prelude) : _Node[],
        sec.walk, !isempty(const_slots), !isempty(time_slots)
    )
end

@inline function _run_scalars!(s::_StateScalars, du, u, p, t, ::Type{T}) where {T}
    cse_cache = s.cse_cache
    cache = _cse_buf(cse_cache, T)
    if s.has_const && _cse_const_stale(cse_cache, T, p)
        if s.constp === nothing
            _walk_prelude_slots!(s.walk, cache, s.const_walk, s.cse_prelude, u, p, t, T)
        else
            s.constp(du, u, p, t, cache, T)
        end
        _cse_mark_const!(cse_cache, T, p)
    end
    if s.has_time && _cse_t_stale(cse_cache, T, p, t)
        if s.timep === nothing
            _walk_prelude_slots!(s.walk, cache, s.time_walk, s.cse_prelude, u, p, t, T)
        else
            s.timep(du, u, p, t, cache, T)
        end
        _cse_mark_t!(cse_cache, T, p, t)
    end
    s.dynp(du, u, p, t, cache, T)
    _walk_prelude_slots!(s.walk, cache, s.resid_dyn, s.cse_prelude, u, p, t, T)
    _walk_scalar_rhs!(s.walk, du, s.resid_rhs, u, p, t, T)
    return nothing
end

# ---- The materialized array observeds --------------------------------------
# Each materialized array observed owns a block of slots above the state in one
# extended slot space (obs_buffers.jl). `const_levels` hold the const-cadence
# observeds, which read no `levels` entry; they run first, and only when the
# buffer's const stamp says `p` moved or the buffer is new. `forcing_levels`
# hold the forcing-cadence ones, which read a live buffer but neither `t` nor
# the state (a regridded emission field); they read only const ones and each
# other, and run next, only when `p` or the build's forcing epoch moved, so a
# value derived from forcing data alone is computed once per forcing refresh;
# when not every writer of the build's buffers announces (`announced`,
# cadence_stamp.jl) they also run whenever `t` moved, as the time ones do.
# `time_levels` hold the time-cadence ones, which read only the tiers above and
# each other; they run next, and only when `(p, t, the build's forcing epoch)`
# moved, so the columns of a Jacobian, all at one `t`, fill them once. `levels`
# run on every call.
struct _RhsObserved{L, CL, FL, TL}
    ext::_ObsExtVec
    n_states::Int
    levels::L
    const_levels::CL
    forcing_levels::FL
    time_levels::TL
end

# `nothing` when nothing is materialized.
function _rhs_observed(
        n_total::Int, n_states::Int, levels::Tuple, const_levels::Tuple = (),
        forcing_levels::Tuple = (), time_levels::Tuple = (),
        epoch::_ForcingEpoch = _new_forcing_epoch()
    )
    isempty(levels) && isempty(const_levels) && isempty(forcing_levels) &&
        isempty(time_levels) && return nothing
    return _RhsObserved(
        _ObsExtVec(n_total - n_states, epoch), n_states, levels, const_levels,
        forcing_levels, time_levels
    )
end

# ---- The right-hand side ----------------------------------------------------
# `refill` brings the discrete caches up to the call's `p` first
# (`_DiscreteRefill`, obs_buffers.jl), or is `nothing`.
struct _Rhs{ST, O, D} <: Function
    state::ST
    observed::O
    refill::D
end

function (f::_Rhs)(du, u, p, t)
    f.refill === nothing || f.refill(p)
    _reject_float32_state(u)
    T = _rhs_value_type(u, p, t)
    obs = f.observed
    if obs === nothing
        _run_stage!(f.state, du, u, p, t, T)
    else
        ext = obs.ext
        o = _obsext_buf(ext, T)
        uv = _ObsSplitVec(_obsext_state(ext, u, T), o, obs.n_states)
        duv = _ObsSplitVec(du, o, obs.n_states)
        if !isempty(obs.const_levels) && _obsext_const_stale(ext, T, p)
            _fill_obs_levels!(obs.const_levels, duv, uv, p, t, T)
            _obsext_mark_const!(ext, T, p)
        end
        if !isempty(obs.forcing_levels) || !isempty(obs.time_levels)
            tstale = _obsext_t_stale(ext, T, p, t)
            # Unless every writer of the build's buffers announces its writes,
            # a new `t` refills the forcing tier too (cadence_stamp.jl).
            if !isempty(obs.forcing_levels) && (
                    _obsext_forcing_stale(ext, T, p) || (tstale && !ext.epoch.announced)
                )
                _fill_obs_levels!(obs.forcing_levels, duv, uv, p, t, T)
                _obsext_mark_forcing!(ext, T, p)
            end
            if tstale
                _fill_obs_levels!(obs.time_levels, duv, uv, p, t, T)
                _obsext_mark_t!(ext, T, p, t)
            end
        end
        _fill_obs_levels!(obs.levels, duv, uv, p, t, T)
        _run_stage!(f.state, du, uv, p, t, T)
    end
    return nothing
end

# The in-place right-hand side over the build's sections. With a scalar
# section the scalar equations and the prelude run as generated code and only
# what it left behind is walked; without one every prelude slot and scalar
# equation is walked.
function _make_rhs(
        rhs_list::AbstractVector{Tuple{Int, _Node}},
        cse_prelude::AbstractVector{_Node},
        cse_cache::_CSECache,
        acc_kernels::AbstractVector{_AccKernel},
        const_slots::AbstractVector{Int},
        time_slots::AbstractVector{Int},
        dyn_slots::AbstractVector{Int},
        scan_folds::AbstractVector{_ScanFold} = _ScanFold[],
        array_contractions = _make_contraction_section(_ArrayContraction[]);
        scalar = nothing, fused_scans::Tuple = (), nst::Int = 0,
        observed = nothing, refill = nothing
    )
    sec = scalar === nothing ?
        _walked_scalar_section(rhs_list, cse_prelude, const_slots, time_slots, dyn_slots) :
        scalar
    state = _RhsStage(
        _StateScalars(sec, cse_prelude, cse_cache, const_slots, time_slots),
        _make_kernel_section(acc_kernels; shared_cache = cse_cache, nst = nst),
        _make_scan_section(scan_folds, fused_scans), array_contractions, (),
    )
    return _Rhs(state, observed, refill)
end
