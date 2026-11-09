use adblock::resources::resource_assembler::assemble_web_accessible_resources;
use std::{collections::BTreeMap, env, fs, path::Path};

fn main() {
    let args: Vec<String> = env::args().collect();
    assert_eq!(args.len(), 4, "usage: driver WEB_ACCESSIBLE_RESOURCES REDIRECT_INDEX OUTPUT");
    let assembled = assemble_web_accessible_resources(Path::new(&args[1]), Path::new(&args[2]));
    let mut counts = BTreeMap::new();
    for resource in &assembled {
        *counts.entry(format!("{:?}", resource.kind)).or_insert(0usize) += 1;
    }
    let total = assembled.len();
    let mut resources: Vec<_> = assembled.into_iter().filter(|r| r.kind.supports_redirect()).collect();
    resources.sort_by(|a, b| a.name.cmp(&b.name));
    assert!(!resources.is_empty(), "assembler produced no redirect resources");
    for (kind, count) in counts {
        eprintln!("assembled ResourceType::{kind}={count}");
    }
    let mut kept = BTreeMap::new();
    for resource in &resources {
        *kept.entry(format!("{:?}", resource.kind)).or_insert(0usize) += 1;
    }
    for (kind, count) in kept {
        eprintln!("kept ResourceType::{kind}={count}");
    }
    eprintln!("resources kept={} dropped={} (Template=0, Mime(FnJavascript)=0 kept)", resources.len(), total - resources.len());
    // Serialize the crate's Vec<Resource> directly. Do not translate its schema.
    let json = serde_json::to_vec(&resources).expect("serialize resources");
    fs::write(&args[3], json).expect("write resources");
}
