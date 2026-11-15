//! What the Rust readers bound that the Lean model leaves unbounded.
//!
//! The Lean model's numbers, exponents and recursion are unbounded. The Rust
//! readers refuse, with `parse_error`, a document past one of these bounds,
//! rather than read it as something else or run out of stack:
//!
//! * **Nesting.** At most [`MAX_NESTING`] constructs open at once across the
//!   recursive-descent readers: math sub-expressions (a bracket, a fraction,
//!   a prefix `-` or `\lnot`, a `cases` row, a JSON value in an escape node),
//!   Typst values, YAML blocks and flow collections. Each holds a [`Nest`]
//!   while it reads its contents. The bound keeps the reader's stack small
//!   enough for the Typst plugin, whose wasm stack is far smaller than a
//!   native thread's.
//! * **Depth.** A document read from Markdown or Typst nests at most
//!   [`MAX_JSON_DEPTH`] arrays and objects, the depth `serde_json` reads, so
//!   whatever the readers return can be written as JSON and read back. A
//!   left-nested chain (`a - b - c - …`, LaTeX `a / b / c`, Typst
//!   `a / b / c`) is checked as it grows, since it deepens the value without
//!   nesting the reader.
//! * **Numbers.** A decimal beyond the binary64 range (`1.0e400`) has no
//!   value a JSON document can hold ([`super::json::jnum_to_serde`]); a
//!   decimal exponent outside `i64` is not a number token
//!   ([`super::number::mk_dec`]).
//!
//! The readers stay ports of the Lean functions, which return `None` for every
//! refusal; [`reading`] collects what a read ran into, so the refusal can say
//! which bound it hit, and which removed operator its math names.

use std::cell::Cell;

use super::json::Json;

/// The most constructs a reader holds open at once.
pub const MAX_NESTING: usize = 128;

/// The deepest nesting of arrays and objects in a document: the most
/// `serde_json` reads (its recursion limit of 128 counts the outermost value
/// too).
pub const MAX_JSON_DEPTH: usize = 127;

#[derive(Clone, Copy, Default)]
struct State {
    depth: usize,
    too_deep: bool,
    removed_op: Option<&'static str>,
}

thread_local! {
    static STATE: Cell<State> = const {
        Cell::new(State {
            depth: 0,
            too_deep: false,
            removed_op: None,
        })
    };
}

/// What one read ran into, besides its result.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Findings {
    /// A construct nested past [`MAX_NESTING`], or a value deeper than
    /// [`MAX_JSON_DEPTH`].
    pub too_deep: bool,
    /// The first removed operator (esm-spec §4.2) the math parser met in a
    /// call or escape form.
    pub removed_op: Option<&'static str>,
}

/// Run one read and collect its [`Findings`].
pub fn reading<T>(f: impl FnOnce() -> T) -> (T, Findings) {
    let saved = STATE.replace(State::default());
    let out = f();
    let st = STATE.replace(saved);
    (
        out,
        Findings {
            too_deep: st.too_deep,
            removed_op: st.removed_op,
        },
    )
}

fn update(f: impl FnOnce(&mut State)) {
    STATE.with(|c| {
        let mut st = c.get();
        f(&mut st);
        c.set(st);
    });
}

/// Record that the read went past a bound.
pub fn too_deep() {
    update(|st| st.too_deep = true);
}

/// Record a removed operator the math names (the first one is kept).
pub fn removed_op(op: &'static str) {
    update(|st| {
        st.removed_op.get_or_insert(op);
    });
}

/// One open construct; dropping it closes it.
#[must_use]
pub struct Nest(());

impl Nest {
    /// Open a construct: `None`, recorded as [`too_deep`], when
    /// [`MAX_NESTING`] are open already.
    pub fn enter() -> Option<Nest> {
        let mut ok = false;
        update(|st| {
            if st.depth < MAX_NESTING {
                st.depth += 1;
                ok = true;
            } else {
                st.too_deep = true;
            }
        });
        // Not `then_some`: that would build, and so drop, a `Nest` that was
        // never counted.
        if ok { Some(Nest(())) } else { None }
    }
}

impl Drop for Nest {
    fn drop(&mut self) {
        update(|st| st.depth -= 1);
    }
}

/// The nesting depth of arrays and objects in a value (`0` for a scalar),
/// found without recursion.
pub fn json_depth(j: &Json) -> usize {
    let mut max = 0;
    let mut stack = vec![(j, 0usize)];
    while let Some((v, d)) = stack.pop() {
        match v {
            Json::Arr(xs) => {
                max = max.max(d + 1);
                stack.extend(xs.iter().map(|x| (x, d + 1)));
            }
            Json::Obj(kvs) => {
                max = max.max(d + 1);
                stack.extend(kvs.iter().map(|(_, x)| (x, d + 1)));
            }
            _ => {}
        }
    }
    max
}

/// `Some(j)` when `j` is no deeper than [`MAX_JSON_DEPTH`]; otherwise `None`,
/// recorded as [`too_deep`].
pub fn shallow(j: Json) -> Option<Json> {
    if json_depth(&j) <= MAX_JSON_DEPTH {
        Some(j)
    } else {
        too_deep();
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nested(depth: usize) -> String {
        format!("{}{}", "[".repeat(depth), "]".repeat(depth))
    }

    #[test]
    fn the_depth_bound_is_serde_jsons() {
        assert!(serde_json::from_str::<serde_json::Value>(&nested(MAX_JSON_DEPTH)).is_ok());
        assert!(serde_json::from_str::<serde_json::Value>(&nested(MAX_JSON_DEPTH + 1)).is_err());
        let mut j = Json::Null;
        for _ in 0..MAX_JSON_DEPTH {
            j = Json::Arr(vec![j]);
        }
        assert_eq!(json_depth(&j), MAX_JSON_DEPTH);
    }

    #[test]
    fn nests_are_counted_and_released() {
        let ((), found) = reading(|| {
            let held: Vec<Nest> = (0..MAX_NESTING).map(|_| Nest::enter().unwrap()).collect();
            assert!(Nest::enter().is_none());
            drop(held);
            assert!(Nest::enter().is_some());
        });
        assert!(found.too_deep);
        let ((), found) = reading(|| drop(Nest::enter()));
        assert_eq!(found, Findings::default());
    }
}
