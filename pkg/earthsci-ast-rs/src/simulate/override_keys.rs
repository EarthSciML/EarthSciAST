use super::*;

// ============================================================================
// Caller override-key canonicalization (esm-spec §6.6.2)
// ============================================================================

/// Why a caller-supplied override key designates no single build-resolved name,
/// or why two of them designate the same one.
///
/// The three cases are kept apart deliberately, because the author's remedy
/// differs: an UNKNOWN key names nothing at all (a typo, a renamed parameter);
/// an AMBIGUOUS one names a local variable that two mounted components both
/// carry, so it must be qualified; a COLLISION is two keys designating the one
/// name, so one of them must be dropped.
#[derive(Debug, Clone)]
pub(crate) enum OverrideKeyError {
    /// The key matches no name under any of the §6.6.2 rules.
    Unknown(String),
    /// A bare key that is the local name of two or more qualified names.
    Ambiguous {
        /// The ambiguous local name as the caller spelled it.
        key: String,
        /// The qualified names that carry it, sorted.
        candidates: Vec<String>,
    },
    /// Two or more NON-EXACT keys designate one build-resolved name.
    Collision {
        /// The build-resolved name the keys all designate.
        name: String,
        /// The colliding keys, sorted.
        keys: Vec<String>,
    },
}

/// The trailing (local) segment of a possibly dot-qualified name.
fn bare_name(name: &str) -> &str {
    name.rsplit('.').next().unwrap_or(name)
}

/// The COMPONENT / SUBSYSTEM names a rule-2 override key may name in its
/// leading segments (esm-spec §6.6.2 rule 2, §4.6).
///
/// Every non-final dotted segment of a build-resolved name is a namespace the
/// build itself carries (`Left.gain` ⇒ `Left`, `M.sub.A` ⇒ `M`, `sub`), and
/// `extra` supplies the namespaces the NAMES cannot show: the enclosing model's
/// own name on a single-model build, whose variables it does not qualify at all
/// (`ArrayCompiled::namespace`), and the contributing component names of a
/// flattened one (`FlattenMetadata::source_systems`).
pub(crate) fn namespace_scope<'a>(
    names: impl IntoIterator<Item = &'a str>,
    extra: impl IntoIterator<Item = &'a str>,
) -> HashSet<String> {
    let mut out: HashSet<String> = extra.into_iter().map(|s| s.to_string()).collect();
    for n in names {
        let mut rest = n;
        while let Some((head, tail)) = rest.split_once('.') {
            out.insert(head.to_string());
            rest = tail;
        }
    }
    out
}

/// Rewrite each caller override key onto the build-resolved name it designates
/// (esm-spec §6.6.2 "Unrecognized override keys"), or report why it designates
/// none. `known` is the build's own name -> slot table — flattening-qualified
/// parameters (`M.A`) or state elements (`M.u`, `M.u[1]`); only its KEYS are
/// consulted. `namespaces` is the component / subsystem scope rule 2 validates
/// a key's leading segments against ([`namespace_scope`]).
///
/// Precedence, matching the Julia tree-walk `_canonicalize_override_keys` and
/// Python's `canonicalize_override_keys`:
///   1. an exact hit wins;
///   2. else a DOTTED key whose LONGEST dotted suffix is itself a name resolves
///      to it (`M.A` against a bare-named single-model system — the case the
///      old `normalize_override_keys` handled by stripping the `<namespace>.`
///      prefix — and `M.sub.A` against a single-model build whose mounted
///      subsystem parameter is `sub.A`: the §4.6 fully-qualified spelling of a
///      name the build carries in a shorter form). The suffixes are tried
///      longest first, so the most-qualified name wins; the trailing segment
///      is the last one tried. EVERY leading segment dropped along the way MUST
///      name a component or subsystem in `namespaces`, so a typo'd
///      `Missng.M.pert_amp` is reported rather than silently suffix-matched
///      onto `M.pert_amp`;
///   3. else a BARE key that is the trailing segment of exactly ONE name
///      resolves to it (`A` against the flattened `M.A`);
///   4. else a BARE key carried by two or more names is `Ambiguous`;
///   5. else it is `Unknown`.
///
/// Two NON-EXACT keys designating ONE name — `solo` (rule 3) and
/// `Doc.Left.solo` (rule 2) both landing on `Left.solo`, or `A.M.g` and `B.M.g`
/// both landing on `M.g` — is a document authoring error, reported as
/// `Collision` naming the resolved name and every colliding key. Picking a
/// winner among them would be a wrong answer rather than a missing one, and no
/// ranking of the rules can be right: the caller wrote two overrides and only
/// one of them can take effect. An EXACT hit is never part of a collision —
/// rule 1 identifies its name outright, so it wins over any suffix or bare
/// claim on that name and those claims are discarded.
///
/// Errors are reported for the lexicographically first offending key so the
/// diagnostic does not depend on `HashMap` iteration order.
pub(crate) fn canonicalize_override_keys(
    known: &HashMap<String, usize>,
    namespaces: &HashSet<String>,
    overrides: &HashMap<String, f64>,
    renames: &HashMap<String, String>,
) -> Result<HashMap<String, f64>, OverrideKeyError> {
    if overrides.is_empty() {
        return Ok(HashMap::new());
    }
    // Rule 0, ahead of everything: a key naming a state an `operator_compose`
    // renaming match DELETED (esm-libraries-spec §4.7.1 step 4) addresses a
    // quantity that MOVED, not one that never existed. `renames` is the map
    // flatten recorded, carried here on the compiled artifact; resolving through
    // it first is what keeps a document that merges `B.x` onto `A.x` addressable
    // by either spelling (issue #230). An EXPLICIT key for the survivor wins:
    // the caller who names the surviving state has said what they mean.
    let resolved;
    let overrides = if renames.is_empty() {
        overrides
    } else {
        resolved = resolve_merged_renames(overrides, renames);
        &resolved
    };
    // Local name -> every qualified name carrying it.
    let mut groups: HashMap<&str, Vec<&str>> = HashMap::new();
    for n in known.keys() {
        let b = bare_name(n);
        if b != n.as_str() {
            groups.entry(b).or_default().push(n.as_str());
        }
    }

    // Which key(s) CLAIMED each resolved name. An exact hit (rule 1) is
    // recorded separately from the non-exact claims (rules 2 and 3) because it
    // WINS rather than collides.
    let mut out: HashMap<&str, f64> = HashMap::new();
    let mut exact: HashSet<&str> = HashSet::new();
    let mut claims: HashMap<&str, Vec<(&str, f64)>> = HashMap::new();
    let mut failures: Vec<OverrideKeyError> = Vec::new();
    for (k, v) in overrides {
        if let Some((n, _)) = known.get_key_value(k.as_str()) {
            exact.insert(n.as_str()); // rule 1: exact hit
            out.insert(n.as_str(), *v);
            continue;
        }
        let name: &str = if let Some(suffix) = dotted_suffix_hit(known, namespaces, k) {
            suffix // rule 2: longest known dotted suffix under a real namespace
        } else if let Some(cands) = groups.get(k.as_str()) {
            if cands.len() == 1 {
                cands[0] // rule 3: unique bare alias
            } else {
                let mut candidates: Vec<String> = cands.iter().map(|s| (*s).to_string()).collect();
                candidates.sort();
                failures.push(OverrideKeyError::Ambiguous {
                    key: k.clone(),
                    candidates,
                }); // rule 4
                continue;
            }
        } else {
            failures.push(OverrideKeyError::Unknown(k.clone())); // rule 5
            continue;
        };
        claims.entry(name).or_default().push((k.as_str(), *v));
    }
    for (name, mut cs) in claims {
        if exact.contains(name) {
            continue; // rule 1 already identified this name outright
        }
        if cs.len() > 1 {
            let mut keys: Vec<String> = cs.iter().map(|(k, _)| (*k).to_string()).collect();
            keys.sort();
            failures.push(OverrideKeyError::Collision {
                name: name.to_string(),
                keys,
            });
            continue;
        }
        out.insert(name, cs.pop().expect("one claim").1);
    }
    if !failures.is_empty() {
        failures.sort_by(|a, b| override_key_of(a).cmp(override_key_of(b)));
        return Err(failures.swap_remove(0));
    }
    Ok(out.into_iter().map(|(n, v)| (n.to_string(), v)).collect())
}

/// Rule 2: the LONGEST dotted suffix of a dotted key `k` — every `<segment>.`
/// prefix dropped in turn, most-qualified first — that is itself a known name,
/// PROVIDED every segment dropped along the way names a component or subsystem
/// in `namespaces`. `None` for a bare key, when no suffix is known, or when a
/// leading segment names nothing: `M.sub.A` tries `sub.A` then `A` when `M` and
/// `sub` are real, a bare `A` tries nothing (rules 3–5 handle it), and
/// `Doc.Left.solo` in a build with no component `Doc` is rejected rather than
/// re-pointed at `Left.solo`.
fn dotted_suffix_hit<'a>(
    known: &'a HashMap<String, usize>,
    namespaces: &HashSet<String>,
    k: &str,
) -> Option<&'a str> {
    let mut rest = k;
    while let Some((head, tail)) = rest.split_once('.') {
        if !namespaces.contains(head) {
            return None;
        }
        if let Some((name, _)) = known.get_key_value(tail) {
            return Some(name.as_str());
        }
        rest = tail;
    }
    None
}

/// Rewrite each override key that names a merged-away state onto its survivor.
///
/// Separate from [`canonicalize_override_keys`] so the same resolution is
/// reachable for a caller that does not go through the §6.6.2 rules.
pub(crate) fn resolve_merged_renames(
    overrides: &HashMap<String, f64>,
    renames: &HashMap<String, String>,
) -> HashMap<String, f64> {
    let mut out = HashMap::with_capacity(overrides.len());
    for (k, v) in overrides {
        match renames.get(k.as_str()) {
            // An explicit override for the survivor beats the dead alias.
            Some(survivor) if !overrides.contains_key(survivor.as_str()) => {
                out.insert(survivor.clone(), *v);
            }
            Some(_) => {}
            None => {
                out.insert(k.clone(), *v);
            }
        }
    }
    out
}

fn override_key_of(e: &OverrideKeyError) -> &str {
    match e {
        OverrideKeyError::Unknown(k) => k,
        OverrideKeyError::Ambiguous { key, .. } => key,
        // A collision has no single offending key; order by the first of them,
        // which is what the diagnostic leads with.
        OverrideKeyError::Collision { keys, .. } => keys.first().map(String::as_str).unwrap_or(""),
    }
}

/// Map an override-key failure onto the `parameter_overrides` error surface.
pub(crate) fn param_key_error(e: OverrideKeyError) -> SimulateError {
    match e {
        OverrideKeyError::Unknown(name) => SimulateError::InvalidParameter { name },
        OverrideKeyError::Ambiguous { key, candidates } => SimulateError::AmbiguousParameter {
            name: key,
            candidates,
        },
        OverrideKeyError::Collision { name, keys } => {
            SimulateError::CollidingParameterKeys { name, keys }
        }
    }
}

/// Map an override-key failure onto the `initial_conditions` error surface.
pub(crate) fn ic_key_error(e: OverrideKeyError) -> SimulateError {
    match e {
        OverrideKeyError::Unknown(name) => SimulateError::InvalidInitialCondition { name },
        OverrideKeyError::Ambiguous { key, candidates } => {
            SimulateError::AmbiguousInitialCondition {
                name: key,
                candidates,
            }
        }
        OverrideKeyError::Collision { name, keys } => {
            SimulateError::CollidingInitialConditionKeys { name, keys }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The rule-0 merge map, empty: these cases exercise the §6.6.2 rules on a
    /// document with no renaming `operator_compose` merge.
    fn no_renames() -> HashMap<String, String> {
        HashMap::new()
    }

    fn known(names: &[&str]) -> HashMap<String, usize> {
        names
            .iter()
            .enumerate()
            .map(|(i, n)| (n.to_string(), i))
            .collect()
    }

    /// esm-spec §6.6.2 rule 2: the LONGEST dotted suffix that is a name wins;
    /// a bare key never enters rule 2; a dotted key none of whose suffixes is
    /// a name is unknown, so `Missing.solo` is never re-pointed at `Left.solo`.
    #[test]
    fn dotted_suffix_binds_the_longest_known_suffix() {
        let k = known(&["sub.g", "g", "Left.solo"]);
        let ns = namespace_scope(k.keys().map(String::as_str), ["P"]);
        assert_eq!(dotted_suffix_hit(&k, &ns, "P.sub.g"), Some("sub.g"));
        assert_eq!(dotted_suffix_hit(&k, &ns, "P.g"), Some("g"));
        assert_eq!(dotted_suffix_hit(&k, &ns, "Left.solo"), None);
        assert_eq!(dotted_suffix_hit(&k, &ns, "Missing.solo"), None);
        assert_eq!(dotted_suffix_hit(&k, &ns, "g"), None);
        let over: HashMap<String, f64> = [("P.sub.g".to_string(), 1.5)].into_iter().collect();
        let out = canonicalize_override_keys(&k, &ns, &over, &no_renames()).expect("resolves");
        assert_eq!(out.get("sub.g"), Some(&1.5));
        let bad: HashMap<String, f64> = [("Missing.solo".to_string(), 1.0)].into_iter().collect();
        assert!(matches!(
            canonicalize_override_keys(&k, &ns, &bad, &no_renames()),
            Err(OverrideKeyError::Unknown(ref n)) if n == "Missing.solo"
        ));
    }

    /// esm-spec §6.6.2 rule 2 validates the LEADING SEGMENTS: they must name a
    /// component or subsystem the build actually carries. Without the check a
    /// typo'd qualifier is silently discarded and the key binds the name it
    /// happens to suffix-match — `Doc.Left.solo` driving `Left.solo` where no
    /// component `Doc` exists, `Missng.M.pert_amp` driving `M.pert_amp`.
    #[test]
    fn rule_2_rejects_a_leading_segment_that_names_nothing() {
        let k = known(&["Left.gain", "Left.solo", "Right.gain"]);
        // `namespace_scope` reads the namespaces off the build's own names.
        let ns = namespace_scope(k.keys().map(String::as_str), []);
        assert!(ns.contains("Left") && ns.contains("Right") && !ns.contains("Doc"));
        let bad: HashMap<String, f64> = [("Doc.Left.solo".to_string(), 9.0)].into_iter().collect();
        assert!(matches!(
            canonicalize_override_keys(&k, &ns, &bad, &no_renames()),
            Err(OverrideKeyError::Unknown(ref n)) if n == "Doc.Left.solo"
        ));
        // A REAL leading segment still resolves.
        let sub = known(&["sub.g"]);
        let real = namespace_scope(sub.keys().map(String::as_str), ["P"]);
        let over: HashMap<String, f64> = [("P.sub.g".to_string(), 1.5)].into_iter().collect();
        assert_eq!(
            canonicalize_override_keys(&sub, &real, &over, &no_renames())
                .expect("resolves")
                .get("sub.g"),
            Some(&1.5)
        );
    }

    /// Two NON-EXACT keys designating ONE name is a document authoring error,
    /// not a race to be settled by a ranking: the caller wrote two overrides
    /// and only one can take effect, so the run is rejected naming the resolved
    /// name and every colliding key. An EXACT hit is never part of a collision.
    #[test]
    fn two_keys_designating_one_name_are_ambiguous() {
        let k = known(&["Left.solo"]);
        let ns = namespace_scope(k.keys().map(String::as_str), ["A", "B", "Doc"]);
        let run = |pairs: &[(&str, f64)]| {
            let over: HashMap<String, f64> =
                pairs.iter().map(|(n, v)| ((*n).to_string(), *v)).collect();
            canonicalize_override_keys(&k, &ns, &over, &no_renames())
        };
        // Rule 3 (bare) + rule 2 (longer dotted) on one name: a collision.
        match run(&[("solo", 2.0), ("Doc.Left.solo", 9.0)]) {
            Err(OverrideKeyError::Collision { name, keys }) => {
                assert_eq!(name, "Left.solo");
                assert_eq!(keys, vec!["Doc.Left.solo", "solo"]);
            }
            other => panic!("expected a collision, got {other:?}"),
        }
        // Two rule-2 keys on one name: likewise, in either build order.
        for pairs in [
            [("B.Left.solo", 2.0), ("A.Left.solo", 1.0)],
            [("A.Left.solo", 1.0), ("B.Left.solo", 2.0)],
        ] {
            match run(&pairs) {
                Err(OverrideKeyError::Collision { name, keys }) => {
                    assert_eq!(name, "Left.solo");
                    assert_eq!(keys, vec!["A.Left.solo", "B.Left.solo"]);
                }
                other => panic!("expected a collision, got {other:?}"),
            }
        }
        // The diagnostic is worded identically in Julia
        // (`_override_collision_message`) and Python (`_collision_message`) —
        // pinned verbatim here so the three cannot drift.
        let err = param_key_error(run(&[("solo", 2.0), ("Doc.Left.solo", 9.0)]).unwrap_err());
        assert_eq!(
            err.to_string(),
            "parameter_overrides: 2 keys designate the parameter 'Left.solo' \
             (Doc.Left.solo, solo). Supply exactly one override key per name \
             (esm-spec \u{a7}6.6.2)."
        );
        let err = ic_key_error(run(&[("solo", 2.0), ("Doc.Left.solo", 9.0)]).unwrap_err());
        assert_eq!(
            err.to_string(),
            "initial_conditions: 2 keys designate the state 'Left.solo' \
             (Doc.Left.solo, solo). Supply exactly one override key per name \
             (esm-spec \u{a7}6.6.2)."
        );
        // An EXACT hit wins outright over a competing suffix claim, and the
        // discarded claims are not reported as a collision.
        let out = run(&[("Left.solo", 1.0), ("Doc.Left.solo", 9.0)]).expect("exact wins");
        assert_eq!(out.get("Left.solo"), Some(&1.0));
        let out =
            run(&[("Left.solo", 1.0), ("solo", 2.0), ("Doc.Left.solo", 9.0)]).expect("exact wins");
        assert_eq!(out.get("Left.solo"), Some(&1.0));
        // One claim on each of two names is not a collision.
        let two = known(&["Left.solo", "Right.gain"]);
        let ns2 = namespace_scope(two.keys().map(String::as_str), []);
        let over: HashMap<String, f64> = [("solo".to_string(), 2.0), ("gain".to_string(), 3.0)]
            .into_iter()
            .collect();
        let out = canonicalize_override_keys(&two, &ns2, &over, &no_renames()).expect("both resolve");
        assert_eq!(out.get("Left.solo"), Some(&2.0));
        assert_eq!(out.get("Right.gain"), Some(&3.0));
    }
}
