//! Objects in canonical form: sorting entries, and splitting an object between
//! surfaces.
//!
//! Port of `formal/Esm/Document/Source/Keys.lean`. (`Json.beq` is the derived
//! `PartialEq` of [`Json`].)

use crate::document::json::Json;

/// An object's entries.
pub type Kvs = Vec<(String, Json)>;

/// `Source.sortKeys`: the entries ordered by key (a stable sort).
pub fn sort_keys(mut l: Kvs) -> Kvs {
    l.sort_by(|a, b| a.0.cmp(&b.0));
    l
}

/// `Source.at_`: the entries of `l` with key `k`.
pub fn at_(k: &str, l: &[(String, Json)]) -> Kvs {
    l.iter().filter(|kv| kv.0 == k).cloned().collect()
}

/// `Source.splitField`: the entries of an object-valued field that `pick`
/// takes, and the residue (`None` when every entry was taken and there was at
/// least one).
pub fn split_field<B>(pick: impl Fn(&str, &Json) -> Option<B>, v: &Json) -> (Vec<B>, Option<Json>) {
    match v {
        Json::Obj(kvs) => {
            let mut ps = Vec::new();
            let mut rs = Vec::new();
            for (k, x) in kvs {
                match pick(k, x) {
                    Some(p) => ps.push(p),
                    None => rs.push((k.clone(), x.clone())),
                }
            }
            let r = if !ps.is_empty() && rs.is_empty() {
                None
            } else {
                Some(Json::Obj(rs))
            };
            (ps, r)
        }
        v => (vec![], Some(v.clone())),
    }
}

/// `Source.splitOpt`: `splitField` of a field that may be absent.
pub fn split_opt<B>(
    pick: impl Fn(&str, &Json) -> Option<B>,
    v: Option<&Json>,
) -> (Vec<B>, Option<Json>) {
    match v {
        Some(v) => split_field(pick, v),
        None => (vec![], None),
    }
}

/// `Source.joinField`: the field rebuilt from its pieces and its residue:
/// `None` when they do not fit together, `Some(None)` when the field is
/// absent.
pub fn join_field<B>(
    back: impl Fn(&B) -> Option<(String, Json)>,
    ps: &[B],
    r: Option<Json>,
) -> Option<Option<Json>> {
    if ps.is_empty() {
        return Some(r);
    }
    let es: Option<Kvs> = ps.iter().map(back).collect();
    match (es, r) {
        (Some(es), None) => Some(Some(Json::Obj(sort_keys(es)))),
        (Some(mut es), Some(Json::Obj(rs))) => {
            es.extend(rs);
            Some(Some(Json::Obj(sort_keys(es))))
        }
        _ => None,
    }
}

/// `Source.pickOne`: the value of key `k`, when it occurs at most once.
pub fn pick_one(k: &str, l: &[(String, Json)]) -> Option<Option<Json>> {
    let mut it = l.iter().filter(|kv| kv.0 == k);
    match (it.next(), it.next()) {
        (None, _) => Some(None),
        (Some((_, v)), None) => Some(Some(v.clone())),
        _ => None,
    }
}
