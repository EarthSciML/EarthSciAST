//! The threaded hand loops' fork-join: a fixed set of worker threads that
//! wait for each call by spinning briefly, then parking, with the calling
//! thread running chunk 0 itself. This is the low-overhead loop a person
//! tuning a right-hand side would write: a solver calls it back to back, so
//! a call costs one wake-up of already-running threads rather than queueing
//! a job on a general-purpose pool (rayon's `install` from outside its pool
//! sleeps and wakes both sides, several microseconds a call).

use std::cell::UnsafeCell;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::thread::JoinHandle;

/// A call's job, with its borrow's lifetime erased while it is published.
type Job = dyn Fn(usize) + Sync + 'static;

/// Spin iterations a waiting worker makes before it parks.
const SPIN: u32 = 1 << 14;

struct Shared {
    epoch: AtomicU64,
    /// Written only by the calling thread between calls (every worker has
    /// finished the previous one); read by a worker after it saw the epoch
    /// that published it.
    job: UnsafeCell<*const Job>,
    pending: AtomicUsize,
    stop: AtomicBool,
}

// SAFETY: `job` is accessed only under the protocol documented on it.
unsafe impl Sync for Shared {}
unsafe impl Send for Shared {}

pub struct ForkJoin {
    shared: Arc<Shared>,
    workers: Vec<JoinHandle<()>>,
}

impl ForkJoin {
    /// A fork-join over `threads` threads: the caller and `threads - 1`
    /// workers.
    pub fn new(threads: usize) -> Self {
        let shared = Arc::new(Shared {
            epoch: AtomicU64::new(0),
            job: UnsafeCell::new(std::ptr::null::<fn(usize)>() as *const Job),
            pending: AtomicUsize::new(0),
            stop: AtomicBool::new(false),
        });
        let workers = (1..threads.max(1))
            .map(|share| {
                let sh = Arc::clone(&shared);
                std::thread::spawn(move || worker(&sh, share))
            })
            .collect();
        ForkJoin { shared, workers }
    }

    /// Threads a call runs on.
    pub fn threads(&self) -> usize {
        self.workers.len() + 1
    }

    /// Run `job(0)`, ..., `job(threads - 1)` and return when all have.
    pub fn run(&self, job: &(dyn Fn(usize) + Sync)) {
        let sh = &*self.shared;
        // SAFETY: every worker finished the previous call (`pending` reached
        // 0 before it returned), so none reads the cell; this call waits for
        // every share before the borrow ends.
        unsafe {
            *sh.job.get() = std::mem::transmute::<&(dyn Fn(usize) + Sync), *const Job>(job);
        }
        sh.pending.store(self.workers.len(), Ordering::Relaxed);
        sh.epoch.fetch_add(1, Ordering::Release);
        for w in &self.workers {
            w.thread().unpark();
        }
        job(0);
        while sh.pending.load(Ordering::Acquire) != 0 {
            std::hint::spin_loop();
        }
    }
}

impl Drop for ForkJoin {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        self.shared.epoch.fetch_add(1, Ordering::Release);
        for w in self.workers.drain(..) {
            w.thread().unpark();
            let _ = w.join();
        }
    }
}

fn worker(sh: &Shared, share: usize) {
    let mut seen = 0u64;
    loop {
        let mut spins = 0u32;
        loop {
            let e = sh.epoch.load(Ordering::Acquire);
            if e != seen {
                seen = e;
                break;
            }
            if spins < SPIN {
                spins += 1;
                std::hint::spin_loop();
            } else {
                std::thread::park();
            }
        }
        if sh.stop.load(Ordering::Acquire) {
            return;
        }
        // SAFETY: the epoch this worker saw published the job, which the
        // caller keeps alive until `pending` reaches 0.
        let job = unsafe { &**sh.job.get() };
        job(share);
        sh.pending.fetch_sub(1, Ordering::Release);
    }
}
