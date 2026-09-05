use super::*;

// ============================================================================
// Caller override-key canonicalization (esm-spec §6.6.2)
// ============================================================================

/// Why a caller-supplied override key designates no single build-resolved name.
///
/// The two cases are kept apart deliberately: an UNKNOWN key names nothing at
/// all (a typo, a renamed parameter), while an AMBIGUOUS one names a local
/// variable that two mounted components both carry — the fix for the first is
/// to correct the name, for the second to qualify it.
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
}

/// The trailing (local) segment of a possibly dot-qualified name.
fn bare_name(name: &str) -> &str {
    name.rsplit('.').next().unwrap_or(name)
}

/// Rewrite each caller override key onto the build-resolved name it designates
/// (esm-spec §6.6.2 "Unrecognized override keys"), or report why it designates
/// none. `known` is the build's own name -> slot table — flattening-qualified
/// parameters (`M.A`) or state elements (`M.u`, `M.u[1]`); only its KEYS are
/// consulted.
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
///      is the last one tried;
///   3. else a BARE key that is the trailing segment of exactly ONE name
///      resolves to it (`A` against the flattened `M.A`);
///   4. else a BARE key carried by two or more names is `Ambiguous`;
///   5. else it is `Unknown`.
///
/// Errors are reported for the lexicographically first offending key so the
/// diagnostic does not depend on `HashMap` iteration order.
pub(crate) fn canonicalize_override_keys(
    known: &HashMap<String, usize>,
    overrides: &HashMap<String, f64>,
) -> Result<HashMap<String, f64>, OverrideKeyError> {
    if overrides.is_empty() {
        return Ok(HashMap::new());
    }
    // Local name -> every qualified name carrying it.
    let mut groups: HashMap<&str, Vec<&str>> = HashMap::new();
    for n in known.keys() {
        let b = bare_name(n);
        if b != n.as_str() {
            groups.entry(b).or_default().push(n.as_str());
        }
    }

    let mut out: HashMap<String, f64> = HashMap::new();
    let mut failures: Vec<OverrideKeyError> = Vec::new();
    // Two passes so precedence is DETERMINISTIC when a caller supplies both
    // spellings of one name (`A` and `M.A`): alias-resolved keys land first,
    // exact-name keys overwrite them.
    for (k, v) in overrides {
        if known.contains_key(k.as_str()) {
            continue; // rule 1, applied below
        }
        if let Some(suffix) = dotted_suffix_hit(known, k) {
            out.insert(suffix.to_string(), *v); // rule 2
        } else if let Some(cands) = groups.get(k.as_str()) {
            if cands.len() == 1 {
                out.insert(cands[0].to_string(), *v); // rule 3
            } else {
                let mut candidates: Vec<String> = cands.iter().map(|s| (*s).to_string()).collect();
                candidates.sort();
                failures.push(OverrideKeyError::Ambiguous {
                    key: k.clone(),
                    candidates,
                }); // rule 4
            }
        } else {
            failures.push(OverrideKeyError::Unknown(k.clone())); // rule 5
        }
    }
    if !failures.is_empty() {
        failures.sort_by(|a, b| override_key_of(a).cmp(override_key_of(b)));
        return Err(failures.swap_remove(0));
    }
    for (k, v) in overrides {
        if known.contains_key(k.as_str()) {
            out.insert(k.clone(), *v); // rule 1
        }
    }
    Ok(out)
}

/// Rule 2: the LONGEST dotted suffix of a dotted key `k` — every `<segment>.`
/// prefix dropped in turn, most-qualified first — that is itself a known name.
/// `None` for a bare key or when no suffix is known. `M.sub.A` tries `sub.A`
/// then `A`; a bare `A` tries nothing (rules 3–5 handle it).
fn dotted_suffix_hit<'a>(known: &'a HashMap<String, usize>, k: &str) -> Option<&'a str> {
    let mut rest = k;
    while let Some((_, tail)) = rest.split_once('.') {
        if let Some((name, _)) = known.get_key_value(tail) {
            return Some(name.as_str());
        }
        rest = tail;
    }
    None
}

fn override_key_of(e: &OverrideKeyError) -> &str {
    match e {
        OverrideKeyError::Unknown(k) => k,
        OverrideKeyError::Ambiguous { key, .. } => key,
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn known(names: &[&str]) -> HashMap<String, usize> {
        names.iter().enumerate().map(|(i, n)| (n.to_string(), i)).collect()
    }

    /// esm-spec §6.6.2 rule 2: the LONGEST dotted suffix that is a name wins;
    /// a bare key never enters rule 2; a dotted key none of whose suffixes is
    /// a name is unknown, so `Missing.solo` is never re-pointed at `Left.solo`.
    #[test]
    fn dotted_suffix_binds_the_longest_known_suffix() {
        let k = known(&["sub.g", "g", "Left.solo"]);
        assert_eq!(dotted_suffix_hit(&k, "P.sub.g"), Some("sub.g"));
        assert_eq!(dotted_suffix_hit(&k, "P.g"), Some("g"));
        assert_eq!(dotted_suffix_hit(&k, "Doc.Left.solo"), Some("Left.solo"));
        assert_eq!(dotted_suffix_hit(&k, "Missing.solo"), None);
        assert_eq!(dotted_suffix_hit(&k, "g"), None);
        let over: HashMap<String, f64> = [("P.sub.g".to_string(), 1.5)].into_iter().collect();
        let out = canonicalize_override_keys(&k, &over).expect("resolves");
        assert_eq!(out.get("sub.g"), Some(&1.5));
        let bad: HashMap<String, f64> = [("Missing.solo".to_string(), 1.0)].into_iter().collect();
        assert!(matches!(
            canonicalize_override_keys(&k, &bad),
            Err(OverrideKeyError::Unknown(ref n)) if n == "Missing.solo"
        ));
    }
}
