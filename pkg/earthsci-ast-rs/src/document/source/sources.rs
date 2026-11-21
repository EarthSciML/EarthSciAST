//! Where each construct of a document's source is, and what it reads as.
//!
//! Not in Lean: the readers here are the Lean readers ([`super::markdown_doc`],
//! [`super::typst_doc`]) with the range of each construct kept through the
//! lexer ([`Spanned`]) and the number of entries each math text reads as kept
//! through cooking ([`cook_doc_counted`]). The pointer of a construct follows
//! from where `unitems` puts it and where `of_doc` writes it: a component's
//! math entries of one field are that field's list in order, and a field
//! with entries cannot also have a block (`math_kv` refuses the pair).

use std::ops::Range;

use super::items::{Counts, RItem, Spanned, cook_doc_blocks, cook_doc_counted, unitems};
use super::keys::Kvs;
use super::lines::{decode_text, first_crlf};
use super::skeleton::{Comp, Kind, MC, MR, Mx, decl_field, of_doc};
use crate::document::json::Json;
use crate::document::math::Sym;

/// A document read with its constructs: their JSON pointers and byte ranges.
pub type Sourced = (Json, Vec<(String, Range<usize>)>);

/// A document lexer with each construct's range (`lex_doc_spanned`).
pub type LexDoc = fn(&[char]) -> Option<(Kvs, Vec<Spanned>)>;

/// A JSON pointer reference token.
fn token(s: &str) -> String {
    s.replace('~', "~0").replace('/', "~1")
}

/// The text as the readers see it (`decodeText`), and the byte offset in
/// `text` of each of its characters, with `text.len()` after the last.
fn decode_with_offsets(text: &str) -> (Vec<char>, Vec<usize>) {
    let all: Vec<(usize, char)> = text.char_indices().collect();
    let body = match all.first() {
        Some((_, '\u{FEFF}')) => &all[1..],
        _ => &all[..],
    };
    let chars: Vec<char> = body.iter().map(|&(_, c)| c).collect();
    let crlf = first_crlf(&chars);
    let mut out = Vec::with_capacity(chars.len());
    let mut offsets = Vec::with_capacity(chars.len() + 1);
    for (i, &(b, c)) in body.iter().enumerate() {
        if crlf && c == '\r' && chars.get(i + 1) == Some(&'\n') {
            continue;
        }
        out.push(c);
        offsets.push(b);
    }
    offsets.push(text.len());
    (out, offsets)
}

fn comp_field(k: Kind) -> &'static str {
    match k {
        Kind::Model => "models",
        Kind::Rs => "reaction_systems",
    }
}

/// The pointer, under `base`, of each entry of a math list as `of_doc`
/// writes it.
fn entry_pointers(base: &str, math: &[MC]) -> Vec<String> {
    let mut seen: Vec<(&str, usize)> = Vec::new();
    math.iter()
        .map(|m| match m {
            Mx::Tm(t) => format!("{base}/expression_templates/{}", token(&t.name)),
            _ => {
                let f = m.field();
                let i = match seen.iter_mut().find(|(g, _)| *g == f) {
                    Some((_, n)) => {
                        *n += 1;
                        *n - 1
                    }
                    None => {
                        seen.push((f, 1));
                        0
                    }
                };
                format!("{base}/{f}/{i}")
            }
        })
        .collect()
}

/// The pointers of the `j`-th math text of a list, given how many entries
/// each text read as.
fn of_text(ptrs: &[String], counts: &[usize], j: usize) -> Vec<String> {
    let from: usize = counts[..j].iter().sum();
    ptrs[from..from + counts[j]].to_vec()
}

/// Read a document as `lex_doc`, `ck_r` (the math leaves of path blocks,
/// `cook_doc_blocks`) and `ck` read it, with the pointer and the
/// byte range of every construct. A construct that reads as several entries
/// (a display of several equations, a container) has one pointer for each,
/// all with its range.
pub fn read_sourced(
    text: &str,
    lex_doc: LexDoc,
    ck_r: &dyn Fn(&Sym, &str) -> Option<Json>,
    ck: &dyn Fn(&Sym, &MR) -> Option<Vec<MC>>,
) -> Option<Sourced> {
    let (chars, offsets) = decode_with_offsets(text);
    debug_assert_eq!(
        chars,
        decode_text(&text.chars().collect::<Vec<_>>()),
        "the offsets follow decodeText"
    );
    let (front, spanned) = lex_doc(&chars)?;
    let raw = unitems(front, spanned.iter().map(|(it, _)| it.clone()).collect())?;
    let raw = cook_doc_blocks(ck_r, &raw)?;
    let (doc, Counts { top, comps }) = cook_doc_counted(ck, &raw)?;
    let json = of_doc(&doc)?;

    let bases: Vec<String> = doc
        .comps
        .iter()
        .map(|c: &Comp<MC>| format!("/{}/{}", comp_field(c.kind), token(&c.name)))
        .collect();
    let comp_ptrs: Vec<Vec<String>> = doc
        .comps
        .iter()
        .zip(&bases)
        .map(|(c, b)| entry_pointers(b, &c.math))
        .collect();
    let top_ptrs = entry_pointers("", &doc.math);

    let mut out = Vec::new();
    // The component being read (an index into `doc.comps`), and how many math
    // texts of it, or of the top level, have been read.
    let mut cur: Option<usize> = None;
    let mut texts = vec![0usize; doc.comps.len()];
    let mut top_texts = 0usize;
    for (it, at) in &spanned {
        let bytes = offsets[at.start]..offsets[at.end];
        let math_text = matches!(
            it,
            RItem::Eqn(_) | RItem::Eqx(..) | RItem::Rxn(_) | RItem::Plot(_) | RItem::Tm(_)
        );
        if let RItem::Comp(..) = it {
            let ci = cur.map_or(0, |c| c + 1);
            cur = Some(ci);
            out.push((bases[ci].clone(), bytes));
            continue;
        }
        let ptrs = match cur {
            Some(ci) => {
                let base = &bases[ci];
                match it {
                    RItem::Desc(_) => vec![format!("{base}/description")],
                    RItem::Block(k, _) => vec![format!("{base}/{}", token(k))],
                    RItem::Decl(d) => decl_field(doc.comps[ci].kind, d.kind)
                        .map(|f| format!("{base}/{f}/{}", token(&d.name)))
                        .into_iter()
                        .collect(),
                    _ if math_text => {
                        texts[ci] += 1;
                        of_text(&comp_ptrs[ci], &comps[ci], texts[ci] - 1)
                    }
                    _ => vec![],
                }
            }
            None => match it {
                RItem::Desc(_) => vec!["/metadata/description".to_string()],
                RItem::Block(k, _) => vec![format!("/{}", token(k))],
                RItem::Tm(_) => {
                    top_texts += 1;
                    of_text(&top_ptrs, &top, top_texts - 1)
                }
                _ => vec![],
            },
        };
        out.extend(ptrs.into_iter().map(|p| (p, bytes.clone())));
    }
    Some((json, out))
}
