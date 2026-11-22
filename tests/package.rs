//! `package`: npm packages of Mojo ports are not built yet, and say so before writing anything.

use std::path::PathBuf;

use mojo_anything::bridge::{self, Kind};
use mojo_anything::package::{self, Options};

fn project(name: &str, files: &[(&str, &str)]) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-package-{name}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    for (path, text) in files {
        let path = root.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
    root
}

#[test]
fn mojo_node_package_is_not_yet() {
    let root = project(
        "mojo-node",
        &[
            ("package.json", r#"{"name":"shout","version":"1.2.3"}"#),
            (
                "src/shout.ts",
                "export function shout(text: string): string {\n  return text + \"!\";\n}\n",
            ),
        ],
    );
    let dir = root.join("port");
    bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/shout.ts",
        kind: Some(Kind::MojoNode),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    let err = package::package(&Options {
        crate_dir: &dir,
        name: None,
        version: None,
        out: None,
        dry_run: false,
    })
    .unwrap_err();
    let shown = format!("{err:#}");
    assert!(shown.starts_with("not yet:"), "{shown}");
    assert!(shown.contains("packaging plan"), "{shown}");
    assert!(
        !dir.join("package").exists(),
        "a refused package writes nothing"
    );
    std::fs::remove_dir_all(&root).unwrap();
}
