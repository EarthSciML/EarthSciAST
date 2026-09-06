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
/// Two DIFFERENT keys may designate one name — `solo` (rule 3) and
/// `Doc.Left.solo` (rule 2) both bind `Left.solo`. The rule that applies to the
/// key ranks the claim (exact 0, bare 1, longer dotted 2) and the smallest
/// `(rank, key)` wins, so the outcome is the same in every binding and in every
/// process, not whichever key `HashMap` iteration happened to reach last.
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

    // Which key CLAIMED each resolved name, as `(rank, key)`. Two distinct keys
    // can designate one name — `solo` (rule 3) and `Doc.Left.solo` (rule 2) both
    // bind `Left.solo`, and `A.M.g` and `B.M.g` both bind `M.g` — and picking by
    // `HashMap` iteration order would make the run depend on this process's hash
    // seed. The claim with the SMALLEST `(rank, key)` wins, where rank is 0 for
    // an exact hit, 1 for the bare local spelling and 2 for a longer dotted key:
    // the same precedence Python's `_resolve_override` reads with (exact name,
    // then the bare segment, then the lexicographically first more-qualified
    // key) and the same one Julia's `_canonicalize_override_keys` applies.
    let mut claim: HashMap<&str, (u8, &str)> = HashMap::new();
    let mut out: HashMap<String, f64> = HashMap::new();
    let mut failures: Vec<OverrideKeyError> = Vec::new();
    for (k, v) in overrides {
        let (name, rank): (&str, u8) = if let Some((n, _)) = known.get_key_value(k.as_str()) {
            (n.as_str(), 0) // rule 1: exact hit
        } else if let Some(suffix) = dotted_suffix_hit(known, k) {
            (suffix, 2) // rule 2: longest known dotted suffix
        } else if let Some(cands) = groups.get(k.as_str()) {
            if cands.len() == 1 {
                (cands[0], 1) // rule 3: unique bare alias
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
        let bid = (rank, k.as_str());
        if claim.get(name).is_none_or(|prev| bid < *prev) {
            claim.insert(name, bid);
            out.insert(name.to_string(), *v);
        }
    }
    if !failures.is_empty() {
        failures.sort_by(|a, b| override_key_of(a).cmp(override_key_of(b)));
        return Err(failures.swap_remove(0));
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

    /// Two keys designating ONE name resolve the same way every run and in
    /// every binding: exact beats bare beats a longer dotted key, and two keys
    /// of the same rank are settled lexicographically. Before rule 2 was
    /// widened, `Doc.Left.solo` was Unknown and this collision was unreachable;
    /// a `HashMap`-iteration-order winner would make the run depend on the
    /// process hash seed and disagree with Python's `_resolve_override`.
    #[test]
    fn two_keys_designating_one_name_resolve_deterministically() {
        let k = known(&["Left.solo"]);
        let pick = |pairs: &[(&str, f64)]| -> f64 {
            let over: HashMap<String, f64> =
                pairs.iter().map(|(n, v)| ((*n).to_string(), *v)).collect();
            *canonicalize_override_keys(&k, &over)
                .expect("resolves")
                .get("Left.solo")
                .expect("bound")
        };
        // Rule 1 (exact) beats rule 3 (bare) beats rule 2 (longer dotted).
        assert_eq!(
            pick(&[("Left.solo", 1.0), ("solo", 2.0), ("Doc.Left.solo", 9.0)]),
            1.0
        );
        assert_eq!(pick(&[("solo", 2.0), ("Doc.Left.solo", 9.0)]), 2.0);
        // Same rank: the lexicographically first key, whichever order the map
        // is built in.
        assert_eq!(pick(&[("A.Left.solo", 1.0), ("B.Left.solo", 2.0)]), 1.0);
        assert_eq!(pick(&[("B.Left.solo", 2.0), ("A.Left.solo", 1.0)]), 1.0);
    }
}
