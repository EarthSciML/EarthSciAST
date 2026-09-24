//! The scaling tier's hand-written reference loops, one per family
//! (tests/conformance/scaling/README.md).
//!
//! Each computes the same `dy` as its document, on the tier's canonical state
//! order, in the plain loop a person would write: no SIMD intrinsics, no
//! reassociation. Where the document's fold order is known the loop follows
//! it, so the stencil, scan, contraction and scalar-box loops reproduce the
//! compiler's `dy` bit for bit. The serial loop and the threaded one are the
//! same body; the threaded run splits the family's outermost index into one
//! contiguous chunk per thread.

use super::pollu_box::{NSPEC, box_rhs};
use rayon::prelude::*;

/// The output slice, shared across the chunks of a threaded run. Every chunk
/// writes only the elements of its own outer-index range, so the writes are
/// disjoint.
#[derive(Clone, Copy)]
struct Out(*mut f64, usize);
unsafe impl Send for Out {}
unsafe impl Sync for Out {}

impl Out {
    #[inline(always)]
    fn set(self, i: usize, v: f64) {
        assert!(i < self.1);
        // SAFETY: in bounds (checked above); each chunk owns the indices it
        // writes, and the slice outlives the call that created `Out`.
        unsafe { *self.0.add(i) = v }
    }
}

/// One family's reference loop, with the data it needs prepared at build.
pub enum HandLoop {
    /// Rank-`rank` diffusion on a `side^rank` grid, zero ghost.
    Stencil {
        rank: usize,
        side: usize,
        kappa: f64,
    },
    /// The five-class limited transport benchmark on a `side^3` grid.
    Transport { side: usize },
    /// Pollu on each cell of an `nlon x nlat` grid plus lon advection;
    /// species-major state.
    ChemistryGrid {
        nlon: usize,
        nlat: usize,
        u_wind: f64,
        dx: f64,
    },
    /// `dy[i] = -0.001 * sum_{j <= i} u[j] * dz[j]`.
    PrefixScan { dz: Vec<f64> },
    /// `dc[i] = sum_j k[i, j] e[j]`, `de[j] = -kd e[j]`.
    SourceReceptor { n: usize, k: Vec<f64>, kd: f64 },
    /// `dF_src[i] = -kd F_src[i]`, `dF_tgt[j] = sum_i w[i, j] F_src[i] - F_tgt[j]`
    /// over each target's overlapping sources in source order.
    Regrid {
        kd: f64,
        weights: Vec<Vec<(usize, f64)>>,
    },
    /// `du[c] = sum_k kappa (u[nbr[c, k]] - u[c])`.
    Unstructured { kappa: f64, nbr: Vec<[usize; 4]> },
    /// Independent Pollu boxes, box-major state.
    ScalarChemistry { boxes: usize },
}

impl HandLoop {
    /// The length of the outermost index the threaded run splits.
    fn outer(&self) -> usize {
        match self {
            HandLoop::Stencil { side, .. } | HandLoop::Transport { side } => *side,
            HandLoop::ChemistryGrid { nlon, .. } => *nlon,
            HandLoop::PrefixScan { dz } => dz.len(),
            HandLoop::SourceReceptor { n, .. } => *n,
            HandLoop::Regrid { weights, .. } => weights.len(),
            HandLoop::Unstructured { nbr, .. } => nbr.len(),
            HandLoop::ScalarChemistry { boxes } => *boxes,
        }
    }

    /// How many threads a run with `threads` requested actually uses. A
    /// prefix scan's running sum is sequential in its outer index, and
    /// splitting it would reassociate the fold, so its threaded reference is
    /// the serial loop.
    pub fn threads_used(&self, threads: usize) -> usize {
        match self {
            HandLoop::PrefixScan { .. } => 1,
            _ => threads.max(1).min(self.outer().max(1)),
        }
    }

    /// `du = f(u)` on the canonical order. `pool` is the threaded run's pool,
    /// or `None` for the serial loop.
    pub fn run(&self, u: &[f64], du: &mut [f64], pool: Option<&rayon::ThreadPool>) {
        let out = Out(du.as_mut_ptr(), du.len());
        let outer = self.outer();
        let chunks = pool.map_or(1, |p| self.threads_used(p.current_num_threads()));
        if chunks <= 1 {
            self.chunk(u, out, 0, outer);
            return;
        }
        let pool = pool.expect("chunks > 1 only with a pool");
        pool.install(|| {
            (0..chunks).into_par_iter().for_each(|t| {
                let lo = outer * t / chunks;
                let hi = outer * (t + 1) / chunks;
                self.chunk(u, out, lo, hi);
            })
        });
    }

    /// The loop body over outer indices `lo..hi`.
    fn chunk(&self, u: &[f64], du: Out, lo: usize, hi: usize) {
        match self {
            HandLoop::Stencil { rank, side, kappa } => stencil(*rank, *side, *kappa, u, du, lo, hi),
            HandLoop::Transport { side } => transport(*side, u, du, lo, hi),
            HandLoop::ChemistryGrid {
                nlon,
                nlat,
                u_wind,
                dx,
            } => chemistry_grid(*nlon, *nlat, *u_wind, *dx, u, du, lo, hi),
            HandLoop::PrefixScan { dz } => {
                let mut acc = 0.0f64;
                for i in lo..hi {
                    acc += u[i] * dz[i];
                    du.set(i, -0.001 * acc);
                }
            }
            HandLoop::SourceReceptor { n, k, kd } => {
                let n = *n;
                let e = &u[n..2 * n];
                for i in lo..hi {
                    let row = &k[i * n..(i + 1) * n];
                    let mut acc = 0.0f64;
                    for j in 0..n {
                        acc += row[j] * e[j];
                    }
                    du.set(i, acc);
                }
                for (j, ej) in e.iter().enumerate().take(hi).skip(lo) {
                    du.set(n + j, -kd * ej);
                }
            }
            HandLoop::Regrid { kd, weights } => {
                let n = weights.len();
                for (i, ui) in u.iter().enumerate().take(hi).skip(lo) {
                    du.set(i, -kd * ui);
                }
                for (j, w) in weights.iter().enumerate().take(hi).skip(lo) {
                    let mut acc = 0.0f64;
                    for &(i, wij) in w {
                        acc += wij * u[i];
                    }
                    du.set(n + j, acc - u[n + j]);
                }
            }
            HandLoop::Unstructured { kappa, nbr } => {
                for c in lo..hi {
                    let uc = u[c];
                    let mut acc = 0.0f64;
                    for &m in &nbr[c] {
                        acc += kappa * (u[m] - uc);
                    }
                    du.set(c, acc);
                }
            }
            HandLoop::ScalarChemistry { .. } => {
                let mut d = [0.0f64; NSPEC];
                for b in lo..hi {
                    let c: &[f64; NSPEC] = u[b * NSPEC..(b + 1) * NSPEC].try_into().unwrap();
                    box_rhs(c, &mut d);
                    for (s, v) in d.iter().enumerate() {
                        du.set(b * NSPEC + s, *v);
                    }
                }
            }
        }
    }
}

/// Zero-ghost diffusion. Per axis in declaration order the +1 neighbour then
/// the -1 neighbour, summed left to right, as the document writes it.
fn stencil(rank: usize, s: usize, kappa: f64, u: &[f64], du: Out, lo: usize, hi: usize) {
    let centre = (2 * rank) as f64;
    match rank {
        1 => {
            for i in lo..hi {
                let xp = if i + 1 < s { u[i + 1] } else { 0.0 };
                let xm = if i > 0 { u[i - 1] } else { 0.0 };
                du.set(i, kappa * ((xp + xm) - centre * u[i]));
            }
        }
        2 => {
            for i in lo..hi {
                for j in 0..s {
                    let c = i * s + j;
                    let xp = if i + 1 < s { u[c + s] } else { 0.0 };
                    let xm = if i > 0 { u[c - s] } else { 0.0 };
                    let yp = if j + 1 < s { u[c + 1] } else { 0.0 };
                    let ym = if j > 0 { u[c - 1] } else { 0.0 };
                    du.set(c, kappa * ((xp + xm + yp + ym) - centre * u[c]));
                }
            }
        }
        3 => {
            let ss = s * s;
            for i in lo..hi {
                for j in 0..s {
                    for k in 0..s {
                        let c = i * ss + j * s + k;
                        let xp = if i + 1 < s { u[c + ss] } else { 0.0 };
                        let xm = if i > 0 { u[c - ss] } else { 0.0 };
                        let yp = if j + 1 < s { u[c + s] } else { 0.0 };
                        let ym = if j > 0 { u[c - s] } else { 0.0 };
                        let zp = if k + 1 < s { u[c + 1] } else { 0.0 };
                        let zm = if k > 0 { u[c - 1] } else { 0.0 };
                        du.set(c, kappa * ((xp + xm + yp + ym + zp + zm) - centre * u[c]));
                    }
                }
            }
        }
        4 => {
            let ss = s * s;
            let sss = ss * s;
            for i in lo..hi {
                for j in 0..s {
                    for k in 0..s {
                        for l in 0..s {
                            let c = i * sss + j * ss + k * s + l;
                            let wp = if i + 1 < s { u[c + sss] } else { 0.0 };
                            let wm = if i > 0 { u[c - sss] } else { 0.0 };
                            let xp = if j + 1 < s { u[c + ss] } else { 0.0 };
                            let xm = if j > 0 { u[c - ss] } else { 0.0 };
                            let yp = if k + 1 < s { u[c + s] } else { 0.0 };
                            let ym = if k > 0 { u[c - s] } else { 0.0 };
                            let zp = if l + 1 < s { u[c + 1] } else { 0.0 };
                            let zm = if l > 0 { u[c - 1] } else { 0.0 };
                            let sum = wp + wm + xp + xm + yp + ym + zp + zm;
                            du.set(c, kappa * (sum - centre * u[c]));
                        }
                    }
                }
            }
        }
        _ => unreachable!("the tier's stencils are rank 1 to 4"),
    }
}

/// One axis's derivative at 1-based position `p` of `s`, for the element at
/// flat index `c` with stride `st` along the axis: the five boundary classes
/// of the transport benchmark.
#[inline(always)]
fn transport_axis(q: &[f64], c: usize, p: usize, s: usize, st: usize) -> f64 {
    // `at(m)` reads the element at 1-based position `m` along this axis.
    let at = |m: usize| q[c + m * st - p * st];
    if p == 1 {
        1.5 * (at(2) - at(1)) - 0.5 * (at(3) - at(2))
    } else if p == 2 {
        0.5 * (at(3) - at(1))
    } else if p == s - 1 {
        0.5 * (at(s) - at(s - 2))
    } else if p == s {
        1.5 * (at(s) - at(s - 1)) - 0.5 * (at(s - 1) - at(s - 2))
    } else {
        let (m2, m1, c0, p1, p2) = (q[c - 2 * st], q[c - st], q[c], q[c + st], q[c + 2 * st]);
        0.6666666666666666 * (p1 - m1)
            + -0.08333333333333333 * (p2 - m2)
            + 0.05 * (p1.min(c0) - m1.max(c0))
            + 0.025 * (p2.min(p1) - m2.max(m1))
    }
}

fn transport(s: usize, q: &[f64], du: Out, lo: usize, hi: usize) {
    let ss = s * s;
    for i in lo..hi {
        for j in 0..s {
            for k in 0..s {
                let c = i * ss + j * s + k;
                let dx = transport_axis(q, c, i + 1, s, ss);
                let dy = transport_axis(q, c, j + 1, s, s);
                let dz = transport_axis(q, c, k + 1, s, 1);
                du.set(c, -(dx + dy + dz));
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn chemistry_grid(
    nlon: usize,
    nlat: usize,
    u_wind: f64,
    dx: f64,
    y: &[f64],
    du: Out,
    lo: usize,
    hi: usize,
) {
    let cells = nlon * nlat;
    let mut c = [0.0f64; NSPEC];
    let mut d = [0.0f64; NSPEC];
    for i in lo..hi {
        for j in 0..nlat {
            let cell = i * nlat + j;
            for s in 0..NSPEC {
                c[s] = y[s * cells + cell];
            }
            box_rhs(&c, &mut d);
            for s in 0..NSPEC {
                let f = &y[s * cells..(s + 1) * cells];
                let grad = if i == 0 {
                    (f[cell + nlat] - f[cell]) / dx
                } else if i + 1 == nlon {
                    (f[cell] - f[cell - nlat]) / dx
                } else {
                    (f[cell + nlat] - f[cell - nlat]) / (2.0 * dx)
                };
                du.set(s * cells + cell, d[s] + -u_wind * grad);
            }
        }
    }
}
