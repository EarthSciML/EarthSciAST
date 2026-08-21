//! Ad-hoc Step 4 diagnostic: fused-group shape statistics for a model.
use earthsci_ast::load_path_with_options;
use std::collections::BTreeMap;

fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let path = args.next().ok_or("usage: fuse_stats <model.esm>")?;
    let mut mp: BTreeMap<String, i64> = BTreeMap::new();
    for kv in args {
        let (k, v) = kv.split_once('=').ok_or("KEY=VALUE")?;
        mp.insert(k.to_string(), v.parse().map_err(|e| format!("{e}"))?);
    }
    let file = load_path_with_options(std::path::Path::new(&path), &mp)
        .map_err(|e| format!("load: {e:?}"))?;
    let compiled = earthsci_ast::compile_array(file).map_err(|e| format!("compile: {e:?}"))?;
    compiled.debug_dump_fuse_stats();
    Ok(())
}
