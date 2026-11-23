//! What the Rust walk (`walk::builder`, `walk::ignored_files`) returns on the tree in
//! `tool/tests/data/walk_tree.txt`, kept in `tool/tests/data/walk_expected.txt` for the Mojo walk
//! (`tool/tests/test_walk.mojo`) to match. `MOJO_ANYTHING_BLESS=1` rewrites the file.

use std::path::{Path, PathBuf};

fn repo() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

fn build_tree(dest: &Path) {
    let spec = std::fs::read_to_string(repo().join("tool/tests/data/walk_tree.txt")).unwrap();
    for line in spec.lines() {
        if line.is_empty() || line.starts_with("# ") {
            continue;
        }
        let (path, content) = line.split_once('\t').unwrap_or((line, ""));
        let target = dest.join(path);
        if path.ends_with('/') {
            std::fs::create_dir_all(&target).unwrap();
            continue;
        }
        std::fs::create_dir_all(target.parent().unwrap()).unwrap();
        std::fs::write(&target, content.replace("\\n", "\n")).unwrap();
    }
}

fn files(root: &Path, require_git: bool) -> Vec<String> {
    let mut out: Vec<String> = mojo_anything::walk::builder(root)
        .hidden(true)
        .require_git(require_git)
        .build()
        .flatten()
        .filter(|e| e.file_type().is_some_and(|t| t.is_file()))
        .map(|e| {
            e.path()
                .strip_prefix(root)
                .unwrap()
                .to_string_lossy()
                .into_owned()
        })
        .collect();
    out.sort();
    out
}

fn expected_text(tree: &Path) -> String {
    let mut out = String::new();
    for (label, root, require_git) in [
        ("root", tree.to_path_buf(), true),
        ("root without require_git", tree.to_path_buf(), false),
        ("lib", tree.join("lib"), true),
        ("lib without require_git", tree.join("lib"), false),
        ("doc", tree.join("doc"), true),
    ] {
        out += &format!("## {label}\n");
        for f in files(&root, require_git) {
            out += &f;
            out += "\n";
        }
    }
    let ignored =
        mojo_anything::walk::ignored_files(tree, &["py", "log", "tmp", "txt", "md", "mojo"]);
    out += &format!("## ignored py log tmp txt md mojo\n{ignored}\n");
    // The same tree outside any repository: no .git anywhere.
    let bare = tree.with_extension("bare");
    let _ = std::fs::remove_dir_all(&bare);
    build_tree(&bare);
    std::fs::remove_dir_all(bare.join(".git")).unwrap();
    for (label, require_git) in [("no git", true), ("no git without require_git", false)] {
        out += &format!("## {label}\n");
        for f in files(&bare, require_git) {
            out += &f;
            out += "\n";
        }
    }
    let ignored =
        mojo_anything::walk::ignored_files(&bare, &["py", "log", "tmp", "txt", "md", "mojo"]);
    out += &format!("## no git ignored py log tmp txt md mojo\n{ignored}\n");
    std::fs::remove_dir_all(&bare).unwrap();
    out
}

#[test]
fn walk_expected_matches_rust() {
    let tree: PathBuf = std::env::temp_dir().join(format!("walk-expected-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tree);
    build_tree(&tree);
    let actual = expected_text(&tree);
    std::fs::remove_dir_all(&tree).unwrap();
    let path = repo().join("tool/tests/data/walk_expected.txt");
    if std::env::var_os("MOJO_ANYTHING_BLESS").is_some() {
        std::fs::write(&path, &actual).unwrap();
    }
    let expected = std::fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(
        expected, actual,
        "the Rust walk changed: rerun with MOJO_ANYTHING_BLESS=1"
    );
}
