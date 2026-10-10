//! The fork-join pool a split call runs on (native targets only).
//!
//! One process-wide set of worker threads, started on first use and grown
//! when a call asks for more. A dispatch writes the job and bumps an epoch;
//! the calling thread runs share 0 itself and waits for the rest. Nothing on
//! that path allocates, whichever thread calls, which is why this is not
//! rayon: a rayon fork-join entered from outside its pool queues the job on
//! a list that allocates a block every few dozen entries, and the solver
//! calls the right-hand side from the caller's own thread.
//!
//! Workers spin briefly after each job (consecutive calls of a solve come
//! close together), then park. One split runs at a time: a call that finds
//! the pool busy (another thread's solve) runs its shares itself, serially,
//! with the same result.

use std::cell::UnsafeCell;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::thread::Thread;

/// A dispatch's job, with its borrow's lifetime erased while it is published.
type Job = dyn Fn(usize) + Sync + 'static;

/// Spin iterations a waiting worker makes before it parks.
const SPIN: u32 = 1 << 12;

/// Bits of the control word that hold the share count.
const WAYS_BITS: u32 = 16;

struct Pool {
    /// `epoch << WAYS_BITS | ways`: one word, so a worker never pairs one
    /// dispatch's epoch with another's share count.
    word: AtomicU64,
    /// The current dispatch's job. Written only by the dispatching thread
    /// while it holds `busy` and every worker of the previous dispatch has
    /// finished; read by a worker only after it saw the epoch that
    /// published it.
    job: UnsafeCell<*const Job>,
    /// Shares of the current dispatch still running on workers.
    pending: AtomicUsize,
    panicked: AtomicBool,
    busy: AtomicBool,
    /// Worker `k` (share `k + 1`). Touched only by the thread holding `busy`.
    workers: UnsafeCell<Vec<Thread>>,
}

// SAFETY: the cells are only accessed under the protocol documented on them.
unsafe impl Sync for Pool {}
unsafe impl Send for Pool {}

static POOL: OnceLock<Pool> = OnceLock::new();

fn pool() -> &'static Pool {
    POOL.get_or_init(|| Pool {
        word: AtomicU64::new(0),
        job: UnsafeCell::new(std::ptr::null::<fn(usize)>() as *const Job),
        pending: AtomicUsize::new(0),
        panicked: AtomicBool::new(false),
        busy: AtomicBool::new(false),
        workers: UnsafeCell::new(Vec::new()),
    })
}

fn worker(pool: &'static Pool, share: usize, mut seen: u64) {
    loop {
        let mut spins = 0u32;
        let word = loop {
            let w = pool.word.load(Ordering::Acquire);
            if w >> WAYS_BITS != seen {
                break w;
            }
            if spins < SPIN {
                spins += 1;
                std::hint::spin_loop();
            } else {
                std::thread::park();
            }
        };
        seen = word >> WAYS_BITS;
        if share < (word & ((1 << WAYS_BITS) - 1)) as usize {
            // SAFETY: this dispatch counts this worker in `pending`, so the
            // job outlives the call below.
            let job = unsafe { &**pool.job.get() };
            if catch_unwind(AssertUnwindSafe(|| job(share))).is_err() {
                pool.panicked.store(true, Ordering::Relaxed);
            }
            pool.pending.fetch_sub(1, Ordering::Release);
        }
    }
}

/// Run `job(0)`, ..., `job(ways - 1)`, each share on its own thread when the
/// pool is free (share 0 on the calling thread), and return when all have.
/// Shares beyond the threads the pool has run on the calling thread after its
/// own, so every share runs whatever the pool could spawn.
pub(super) fn run(ways: usize, job: &(dyn Fn(usize) + Sync)) {
    let want = ways;
    let ways = ways.min((1 << WAYS_BITS) - 1);
    if want <= 1 {
        job(0);
        return;
    }
    #[cfg(test)]
    DISPATCHES.fetch_add(1, Ordering::Relaxed);
    let pool = pool();
    let serial = || (0..want).for_each(job);
    if pool.busy.swap(true, Ordering::Acquire) {
        serial();
        return;
    }
    // SAFETY: we hold `busy`.
    let workers = unsafe { &mut *pool.workers.get() };
    let epoch = pool.word.load(Ordering::Relaxed) >> WAYS_BITS;
    while workers.len() < ways - 1 {
        let share = workers.len() + 1;
        let spawned = std::thread::Builder::new()
            .name(format!("earthsci-tape-{share}"))
            .spawn(move || worker(pool, share, epoch));
        match spawned {
            Ok(h) => workers.push(h.thread().clone()),
            Err(_) => break,
        }
    }
    let ways = ways.min(workers.len() + 1);
    if ways <= 1 {
        pool.busy.store(false, Ordering::Release);
        serial();
        return;
    }
    // SAFETY: we hold `busy` and the previous dispatch has drained, so no
    // worker reads the cell; the lifetime is erased only for the duration of
    // this call, which waits for every share before returning.
    unsafe {
        *pool.job.get() = std::mem::transmute::<&(dyn Fn(usize) + Sync), *const Job>(job);
    }
    pool.pending.store(ways - 1, Ordering::Relaxed);
    pool.word
        .store((epoch + 1) << WAYS_BITS | ways as u64, Ordering::Release);
    for t in &workers[..ways - 1] {
        t.unpark();
    }
    let own = catch_unwind(AssertUnwindSafe(|| {
        job(0);
        (ways..want).for_each(job);
    }));
    let mut spins = 0u32;
    while pool.pending.load(Ordering::Acquire) != 0 {
        if spins < SPIN {
            spins += 1;
            std::hint::spin_loop();
        } else {
            std::thread::yield_now();
        }
    }
    let panicked = pool.panicked.swap(false, Ordering::Relaxed);
    pool.busy.store(false, Ordering::Release);
    if let Err(p) = own {
        resume_unwind(p);
    }
    assert!(
        !panicked,
        "a worker of a split right-hand-side call panicked"
    );
}

/// Test hook: dispatches of more than one share so far, process-wide.
#[cfg(test)]
pub(crate) static DISPATCHES: AtomicUsize = AtomicUsize::new(0);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_share_runs_exactly_once() {
        for ways in [1, 2, 3, 5, 9] {
            let hits: Vec<AtomicUsize> = (0..ways).map(|_| AtomicUsize::new(0)).collect();
            run(ways, &|s| {
                hits[s].fetch_add(1, Ordering::Relaxed);
            });
            assert!(
                hits.iter().all(|h| h.load(Ordering::Relaxed) == 1),
                "ways = {ways}"
            );
        }
    }
}
