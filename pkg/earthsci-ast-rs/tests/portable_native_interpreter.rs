//! The host run of the wasm suite's native-against-interpreter checks
//! (`tests/portable/mod.rs`): the same documents, the same comparisons, on the
//! machine `cargo test` runs on. Bit-identity is per target, so this and the
//! wasm32 run each compare native with their own interpreter.

#![cfg(all(not(target_arch = "wasm32"), feature = "solve"))]

mod portable;

macro_rules! scaling_family {
    ($name:ident) => {
        #[test]
        fn $name() {
            let family = stringify!($name);
            let mut seen = 0;
            for (f, n, text) in portable::SCALING_FIXTURES {
                if *f == family {
                    portable::check_scaling_fixture(f, *n, text);
                    seen += 1;
                }
            }
            assert!(seen > 0, "no committed fixture for {family}");
        }
    };
}

scaling_family!(stencil_1d);
scaling_family!(stencil_2d);
scaling_family!(stencil_3d);
scaling_family!(stencil_4d);
scaling_family!(transport_3d);
scaling_family!(chemistry_grid);
scaling_family!(prefix_scan);
scaling_family!(source_receptor);
scaling_family!(regrid);
scaling_family!(unstructured_gather);
scaling_family!(scalar_chemistry);

#[test]
fn inline_test_tier_documents() {
    for (id, model, text) in portable::INLINE_TIER_DOCS {
        portable::check_inline_tier_doc(id, model, text);
    }
}
