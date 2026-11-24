//! `package` for the units whose Mojo port is a shared library called from another runtime: npm
//! (the Node-API addon per platform, and one package holding the wasm module), RubyGems (a gem
//! per platform and a pure-Ruby gem with the original), Go (a module with the libraries under
//! `lib/<platform>/`), C (the header, the libraries and a pkg-config file) and Maven (a jar
//! holding the FFM wrappers and the libraries, extracted on first load).
//!
//! Each package holds this machine's build in its platform's place; the workflow written beside
//! it builds the other platforms. None carries the Mojo runtime (`DECISIONS.md` P1): the libraries
//! find it on the library path (`LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`).

use std::path::Path;

use anyhow::{Context, Result, bail};
use serde_json::json;

use crate::bridge::Manifest;
use crate::package::{
    Content, Generated, PLATFORMS, Platform, Unit, host_platform, platform_list, relocatable,
    repo_relative,
};

/// The platform this machine builds for, or an error naming the supported ones.
fn host() -> Result<&'static Platform> {
    host_platform().with_context(|| {
        format!(
            "this machine ({} {}) is not a platform Mojo builds for: {}",
            std::env::consts::OS,
            std::env::consts::ARCH,
            platform_list()
        )
    })
}

/// A built file the package copies, or an error asking for `build`.
fn built(path: &Path, unit: &Unit) -> Result<()> {
    if !path.is_file() {
        bail!(
            "no built {} (run `mojo-anything build {}` first)",
            path.display(),
            unit.dir.display()
        );
    }
    if crate::harness_mojo_py::sources_newer_than(unit.dir, path) {
        bail!(
            "{} is older than the unit's Mojo sources; run `mojo-anything build {}` first",
            path.display(),
            unit.dir.display()
        );
    }
    Ok(())
}

fn pretty(value: &serde_json::Value) -> String {
    format!(
        "{}\n",
        serde_json::to_string_pretty(value).unwrap_or_default()
    )
}

/// A folder name for a package name: `@scope/name` is `scope-name`.
fn folder(name: &str) -> String {
    name.trim_start_matches('@').replace('/', "-")
}

fn runtime_note() -> String {
    format!(
        "The libraries need the Mojo {} runtime ({}) on the library path (LD_LIBRARY_PATH, \
         DYLD_LIBRARY_PATH on macOS): the lib folder of a pixi or conda environment with \
         mojo-compiler, or of the mojo-compiler wheel. No package carries it (DECISIONS.md P1).",
        crate::mojo::MOJO_VERSION,
        crate::package::MOJO_RUNTIME.join(", ")
    )
}

fn workflow_note(file: &str) -> String {
    format!(
        "{file} builds {} (move it into your repository's .github/workflows). Nothing was \
         published.",
        platform_list()
    )
}

/// The matrix lines of a workflow job, one per platform.
fn matrix() -> String {
    PLATFORMS
        .iter()
        .map(|p| {
            format!(
                "          - platform: {}\n            runner: {}\n            ext: {}\n",
                p.name, p.runner, p.lib_ext
            )
        })
        .collect()
}

/// A workflow whose `build` job runs `steps` on every platform's runner and uploads `upload`.
fn workflow(unit: &Unit, what: &str, steps: &str, upload: &str) -> String {
    let unit_dir = repo_relative(&unit.manifest.root, unit.dir);
    let out = repo_relative(&unit.manifest.root, unit.out);
    format!(
        "# Builds the {what} of {name} on {platforms}, written by mojo-anything `package`.\n\
         # Move it into the repository's .github/workflows. It builds and uploads artifacts; it\n\
         # publishes nothing. Paths are relative to the repository root: the unit is {unit_dir},\n\
         # the package {out}.\n\
         name: {name} {what}\n\
         on:\n  workflow_dispatch:\n  push:\n    tags: [\"v*\"]\n\
         env:\n  UNIT: {unit_dir}\n  PACKAGE: {out}\n\
         jobs:\n  build:\n    strategy:\n      fail-fast: false\n      matrix:\n        include:\n\
         {matrix}\
         \x20   runs-on: ${{{{ matrix.runner }}}}\n\
         \x20   steps:\n\
         \x20     - uses: actions/checkout@v4\n\
         \x20     - uses: prefix-dev/setup-pixi@v0.8.1\n\
         \x20       with:\n          manifest-path: ${{{{ env.UNIT }}}}/pixi.toml\n\
         {steps}\
         \x20     - uses: actions/upload-artifact@v4\n\
         \x20       with:\n          name: {name}-${{{{ matrix.platform }}}}\n          path: {upload}\n",
        name = unit.name,
        platforms = platform_list(),
        matrix = matrix(),
    )
}

/// The workflow step building the unit's Mojo library (`source`) into `target`.
fn mojo_step(source: &str, target: &str) -> String {
    format!(
        "\x20     - name: Build the Mojo library\n\
         \x20       working-directory: ${{{{ env.UNIT }}}}\n\
         \x20       run: |\n\
         \x20         mkdir -p \"$(dirname \"$GITHUB_WORKSPACE/{target}\")\"\n\
         \x20         pixi run mojo build --Werror {source} --emit shared-lib -o \"$GITHUB_WORKSPACE/{target}\"\n"
    )
}

// ------------------------------------------------------------------ npm (Node-API addon)

/// The main package's loader: the platform package for this machine, else the original.
const NPM_LOADER: &str = r#"'use strict'
// Written by mojo-anything `package`: loads the Mojo build of @NAME@ for this platform from its
// optional dependency, or the original package when there is none.
const PLATFORMS = @PLATFORMS@
const FALLBACK = @FALLBACK@

function load () {
  const key = `${process.platform}-${process.arch}`
  const pkg = PLATFORMS[key]
  let missing
  if (pkg) {
    try {
      return require(pkg)
    } catch (e) {
      if (e.code !== 'MODULE_NOT_FOUND' || !String(e.message).includes(pkg)) throw e
      missing = `${pkg} is not installed`
    }
  } else {
    missing = `there is no Mojo build for ${key}`
  }
  if (FALLBACK) return require(FALLBACK)
  throw new Error(`@NAME@: ${missing}; its Mojo builds are for @LIST@ only, and it names no original package to fall back to`)
}

module.exports = load()
"#;

/// The original's npm package name (the nearest `package.json` above the unit), when it has one
/// and it is not the package being written.
pub(crate) fn original_package(m: &Manifest, name: &str) -> Option<String> {
    let unit = m.root.join(m.unit.trim_end_matches('/'));
    let mut dir = unit.parent()?.to_path_buf();
    loop {
        if let Ok(text) = std::fs::read_to_string(dir.join("package.json"))
            && let Ok(value) = serde_json::from_str::<serde_json::Value>(&text)
        {
            return value["name"]
                .as_str()
                .filter(|n| !n.is_empty() && *n != name)
                .map(str::to_string);
        }
        if dir == m.root || !dir.pop() || !dir.starts_with(&m.root) {
            return None;
        }
    }
}

/// `mojo-node`: the main package (loader and `optionalDependencies`, the original as an
/// optional peer to fall back to) and this machine's platform package (`index.cjs`, the addon
/// and the Mojo library).
pub(crate) fn npm_packages(unit: &Unit, fallback: Option<&str>) -> Result<Generated> {
    let m = unit.manifest;
    let host = host()?;
    let lib = m.lib_name();
    let addon = crate::harness_mojo_node::addon_path(unit.dir, m);
    built(&addon, unit)?;
    let library = unit.dir.join(format!("lib{lib}.{}", host.lib_ext));
    built(&library, unit)?;
    let index = std::fs::read_to_string(unit.dir.join("index.cjs"))
        .context("reading the unit's index.cjs")?;
    let name = unit.name;
    let platform_name = |p: &Platform| format!("{name}-{}", p.name);
    let platforms: serde_json::Map<String, serde_json::Value> = PLATFORMS
        .iter()
        .map(|p| (p.name.to_string(), json!(platform_name(p))))
        .collect();
    let optional: serde_json::Map<String, serde_json::Value> = PLATFORMS
        .iter()
        .map(|p| (platform_name(p), json!(unit.version)))
        .collect();
    let main_dir = format!("npm/{}", folder(name));
    let mut main = json!({
        "name": name,
        "version": unit.version,
        "description": format!("Mojo port of {}, made by mojo-anything", m.unit),
        "main": "index.cjs",
        "files": ["index.cjs"],
        "optionalDependencies": optional,
    });
    if let Some(original) = fallback {
        main["peerDependencies"] = json!({ original: "*" });
        main["peerDependenciesMeta"] = json!({ original: { "optional": true } });
    }
    let loader = NPM_LOADER
        .replace("@NAME@", name)
        .replace("@LIST@", &platform_list())
        .replace(
            "@PLATFORMS@",
            &serde_json::to_string_pretty(&platforms).unwrap_or_default(),
        )
        .replace(
            "@FALLBACK@",
            &fallback.map_or("null".to_string(), |f| json!(f).to_string()),
        );
    let plat_dir = format!("npm/{}", folder(&platform_name(host)));
    let node_file = format!("{lib}.node");
    let lib_file = format!("lib{lib}.{}", host.lib_ext);
    let plat = json!({
        "name": platform_name(host),
        "version": unit.version,
        "description": format!("The {} Mojo build of {name}", host.name),
        "os": [host.os],
        "cpu": [host.node_arch],
        "main": "index.cjs",
        "files": ["index.cjs", node_file, lib_file],
    });
    let files = vec![
        (
            format!("{main_dir}/package.json"),
            Content::Text(pretty(&main)),
        ),
        (format!("{main_dir}/index.cjs"), Content::Text(loader)),
        (
            format!("{plat_dir}/package.json"),
            Content::Text(pretty(&plat)),
        ),
        (format!("{plat_dir}/index.cjs"), Content::Text(index)),
        (
            format!("{plat_dir}/{node_file}"),
            Content::Binary(relocatable(&addon)?),
        ),
        (
            format!("{plat_dir}/{lib_file}"),
            Content::Binary(relocatable(&library)?),
        ),
        (
            ".github/workflows/npm.yml".into(),
            Content::Text(npm_workflow(unit, &lib)),
        ),
    ];
    let mut notes = vec![
        format!(
            "Pack with `npm pack` in each folder under {}; the main package picks \
             {name}-<platform> from its optionalDependencies.",
            unit.out.join("npm").display()
        ),
        match fallback {
            Some(f) => format!(
                "Where no platform package fits, the main package loads `{f}` (the original), an \
                 optional peer dependency."
            ),
            None => "The original has no npm name, so where no platform package fits the main \
                     package throws an error naming the supported platforms."
                .into(),
        },
        runtime_note(),
    ];
    notes.push(workflow_note(".github/workflows/npm.yml"));
    Ok(Generated {
        files,
        module: None,
        notes,
    })
}

fn npm_workflow(unit: &Unit, lib: &str) -> String {
    let target = format!(
        "${{{{ env.PACKAGE }}}}/npm/{}-${{{{ matrix.platform }}}}",
        folder(unit.name)
    );
    let steps = format!(
        "{mojo}\
         \x20     - uses: actions/setup-node@v4\n\
         \x20       with:\n          node-version: \"24\"\n\
         \x20     - name: Build the Node-API addon\n\
         \x20       working-directory: ${{{{ env.UNIT }}}}\n\
         \x20       run: |\n\
         \x20         flags=$([ \"$RUNNER_OS\" = macOS ] && echo \"-undefined dynamic_lookup\" || echo \"-ldl\")\n\
         \x20         cc -shared -fPIC -O2 -Wall -Werror -I \"$(dirname \"$(dirname \"$(which node)\")\")/include/node\" -DNODE_GYP_MODULE_NAME={lib} node_shim.c -o \"$GITHUB_WORKSPACE/{target}/{lib}.node\" $flags\n\
         \x20         cp index.cjs \"$GITHUB_WORKSPACE/{target}/\"\n\
         \x20     - name: Pack\n\
         \x20       working-directory: {target}\n\
         \x20       run: npm pack\n",
        mojo = mojo_step(
            "dispatcher.mojo",
            &format!("{target}/lib{lib}.${{{{ matrix.ext }}}}")
        ),
    );
    workflow(unit, "npm packages", &steps, &format!("{target}/*.tgz"))
}

// ------------------------------------------------------------------ npm (wasm)

/// `mojo-wasm`: one package for every platform, with `index.cjs`, the wasm64 module and
/// `"engines": {"node": ">=24"}`; loading on an older Node throws an error naming Node 24.
pub(crate) fn npm_wasm_package(unit: &Unit) -> Result<Generated> {
    let m = unit.manifest;
    let lib = m.lib_name();
    let wasm = crate::harness_mojo_wasm::wasm_path(unit.dir, m);
    built(&wasm, unit)?;
    let index = std::fs::read_to_string(unit.dir.join("index.cjs"))
        .context("reading the unit's index.cjs")?;
    let name = unit.name;
    let guard = format!(
        "'use strict'\n\
         // Written by mojo-anything `package`: the module is wasm64 (memory64), which Node runs\n\
         // from version 24.\n\
         if (!(Number(process.versions.node.split('.')[0]) >= 24)) {{\n\
         \x20 throw new Error(`{name} needs Node 24 or later: its Mojo build is a wasm64 (memory64) module, and this is Node ${{process.versions.node}}`)\n\
         }}\n"
    );
    let wasm_file = format!("{lib}.wasm");
    let package = json!({
        "name": name,
        "version": unit.version,
        "description": format!("Mojo port of {}, made by mojo-anything (WebAssembly)", m.unit),
        "main": "index.cjs",
        "files": ["index.cjs", wasm_file],
        "engines": { "node": ">=24" },
    });
    let dir = format!("npm/{}", folder(name));
    let workflow_text = format!(
        "# Packs the wasm package of {name}, written by mojo-anything `package`. The module is the\n\
         # same on every platform, so it is built once, by `mojo-anything build`, and committed\n\
         # with the package; this job packs it. It publishes nothing.\n\
         name: {name} npm package\n\
         on:\n  workflow_dispatch:\n  push:\n    tags: [\"v*\"]\n\
         jobs:\n  pack:\n    runs-on: ubuntu-24.04\n    steps:\n\
         \x20     - uses: actions/checkout@v4\n\
         \x20     - uses: actions/setup-node@v4\n\
         \x20       with:\n          node-version: \"24\"\n\
         \x20     - name: Pack\n\
         \x20       working-directory: {out}/{dir}\n\
         \x20       run: npm pack\n\
         \x20     - uses: actions/upload-artifact@v4\n\
         \x20       with:\n          name: {name}\n          path: {out}/{dir}/*.tgz\n",
        out = repo_relative(&m.root, unit.out),
    );
    Ok(Generated {
        files: vec![
            (
                format!("{dir}/package.json"),
                Content::Text(pretty(&package)),
            ),
            (
                format!("{dir}/index.cjs"),
                Content::Text(format!("{guard}{index}")),
            ),
            (
                format!("{dir}/{wasm_file}"),
                Content::Binary(std::fs::read(&wasm)?),
            ),
            (
                ".github/workflows/npm.yml".into(),
                Content::Text(workflow_text),
            ),
        ],
        module: None,
        notes: vec![
            format!(
                "Pack with `npm pack` in {}: one package for every platform, Node 24 or later.",
                unit.out.join(&dir).display()
            ),
            "The wasm module needs no Mojo runtime.".into(),
        ],
    })
}

// ------------------------------------------------------------------ RubyGems

/// RubyGems' platform for a supported platform.
fn ruby_platform(p: &Platform) -> String {
    let os = if p.os == "darwin" { "darwin" } else { "linux" };
    format!("{}-{os}", p.machine)
}

/// The library lookup of `<lib>_native.rb` in a gem: `lib/<lib>/native/<platform>/`, or a
/// `LoadError` naming the supported platforms.
fn gem_library_lookup(name: &str, lib: &str) -> String {
    format!(
        "  HOST_OS = RbConfig::CONFIG[\"host_os\"]\n\
         \x20 HOST_CPU = RbConfig::CONFIG[\"host_cpu\"]\n\
         \x20 PLATFORM = if HOST_OS.include?(\"linux\") && %w[x86_64 amd64].include?(HOST_CPU) then \"linux-x64\"\n\
         \x20            elsif HOST_OS.include?(\"linux\") && %w[aarch64 arm64].include?(HOST_CPU) then \"linux-arm64\"\n\
         \x20            elsif HOST_OS.include?(\"darwin\") && %w[arm64 aarch64].include?(HOST_CPU) then \"darwin-arm64\"\n\
         \x20            end\n\
         \x20 LIBRARY = PLATFORM && File.expand_path(\n\
         \x20   \"{lib}/native/#{{PLATFORM}}/lib{lib}.#{{HOST_OS.include?(\"darwin\") ? \"dylib\" : \"so\"}}\", __dir__\n\
         \x20 )\n\
         \x20 unless LIBRARY && File.exist?(LIBRARY)\n\
         \x20   raise LoadError, \"{name} has no Mojo build for #{{HOST_OS}} #{{HOST_CPU}}: its platform gems are \" \\\n\
         \x20                    \"for {list} only (the pure-Ruby gem runs the original)\"\n\
         \x20 end\n\
         \x20 HANDLE = Fiddle.dlopen(LIBRARY)\n",
        list = platform_list(),
    )
}

/// `ffi` (Ruby): the platform gem for this machine (the wrapper, `<lib>_native.rb` finding the
/// library under `lib/<lib>/native/<platform>/`) and a pure-Ruby gem whose `<lib>.rb` loads the
/// original.
pub(crate) fn gem(unit: &Unit) -> Result<Generated> {
    let m = unit.manifest;
    let host = host()?;
    let lib = m.lib_name();
    let library = crate::harness_mojo_c::library_path(unit.dir, m, false);
    built(&library, unit)?;
    let wrapper = std::fs::read_to_string(unit.dir.join(crate::harness_ruby::wrapper_path(m)))
        .context("reading the Ruby wrapper")?;
    let native_path = unit.dir.join(format!("ruby/{lib}_native.rb"));
    let native = std::fs::read_to_string(&native_path)
        .with_context(|| format!("reading {}", native_path.display()))?;
    let start = native
        .find("  LIBRARY = File.expand_path(")
        .context("the Ruby native module has no LIBRARY line")?;
    let open = "  HANDLE = Fiddle.dlopen(LIBRARY)\n";
    let end = native[start..]
        .find(open)
        .map(|i| start + i + open.len())
        .context("the Ruby native module has no Fiddle.dlopen line")?;
    let native = format!(
        "{}{}{}",
        &native[..start],
        gem_library_lookup(unit.name, &lib),
        &native[end..]
    );
    let name = unit.name;
    let summary = format!("Mojo port of {}, made by mojo-anything", m.unit);
    let platforms: String = PLATFORMS
        .iter()
        .map(|p| format!("  \"{}\" => \"{}\",\n", p.name, ruby_platform(p)))
        .collect();
    let gemspec = format!(
        "# Written by mojo-anything `package`: the platform gem of {name}, for the one platform\n\
         # whose library is under lib/{lib}/native/ (the wheels of each runner in the workflow).\n\
         platforms = {{\n{platforms}}}\n\
         built = platforms.keys.select {{ |p| Dir.exist?(File.join(__dir__, \"lib/{lib}/native\", p)) }}\n\
         raise \"lib/{lib}/native/ must hold exactly one platform, not #{{built.inspect}}\" unless built.size == 1\n\n\
         Gem::Specification.new do |s|\n\
         \x20 s.name = {name_lit}\n\
         \x20 s.version = {version}\n\
         \x20 s.summary = {summary_lit}\n\
         \x20 s.authors = [\"The {name} authors\"]\n\
         \x20 s.platform = Gem::Platform.new(platforms[built.first])\n\
         \x20 s.required_ruby_version = \">= 3.0\"\n\
         \x20 s.files = Dir.chdir(__dir__) {{ Dir[\"lib/**/*\"] }}\n\
         end\n",
        name_lit = json!(name),
        version = json!(unit.version),
        summary_lit = json!(summary),
    );
    // The pure-Ruby gem: the original's files and a `<lib>.rb` that requires them.
    let mut originals: Vec<&str> = m
        .exports
        .iter()
        .map(|f| f.file.as_str())
        .chain(m.js_only.iter().map(|j| j.file.as_str()))
        .collect();
    originals.sort_unstable();
    originals.dedup();
    let mut files = vec![
        (format!("gem/{name}.gemspec"), Content::Text(gemspec)),
        (format!("gem/lib/{lib}.rb"), Content::Text(wrapper)),
        (format!("gem/lib/{lib}_native.rb"), Content::Text(native)),
        (
            format!(
                "gem/lib/{lib}/native/{}/lib{lib}.{}",
                host.name, host.lib_ext
            ),
            Content::Binary(relocatable(&library)?),
        ),
    ];
    let mut requires = String::new();
    for file in &originals {
        let text = std::fs::read(m.root.join(file))
            .with_context(|| format!("reading the original {file}"))?;
        files.push((
            format!("gem/pure/lib/{lib}/original/{file}"),
            Content::Binary(text),
        ));
        requires.push_str(&format!("require_relative \"{lib}/original/{file}\"\n"));
    }
    files.push((
        format!("gem/pure/lib/{lib}.rb"),
        Content::Text(format!(
            "# frozen_string_literal: true\n\n\
             # Written by mojo-anything `package`: the pure-Ruby gem of {name}, for platforms with\n\
             # no Mojo build. It runs the original.\n{requires}"
        )),
    ));
    files.push((
        format!("gem/pure/{name}.gemspec"),
        Content::Text(format!(
            "# Written by mojo-anything `package`: the pure-Ruby gem of {name} (the original).\n\
             Gem::Specification.new do |s|\n\
             \x20 s.name = {name_lit}\n\
             \x20 s.version = {version}\n\
             \x20 s.summary = {summary_lit}\n\
             \x20 s.authors = [\"The {name} authors\"]\n\
             \x20 s.required_ruby_version = \">= 3.0\"\n\
             \x20 s.files = Dir.chdir(__dir__) {{ Dir[\"lib/**/*\"] }}\n\
             end\n",
            name_lit = json!(name),
            version = json!(unit.version),
            summary_lit = json!(summary),
        )),
    ));
    let target = format!(
        "${{{{ env.PACKAGE }}}}/gem/lib/{lib}/native/${{{{ matrix.platform }}}}/lib{lib}.${{{{ matrix.ext }}}}"
    );
    let steps = format!(
        "{}\
         \x20     - uses: ruby/setup-ruby@v1\n\
         \x20       with:\n          ruby-version: \"3.3\"\n\
         \x20     - name: Build the platform gem\n\
         \x20       working-directory: ${{{{ env.PACKAGE }}}}/gem\n\
         \x20       run: gem build {name}.gemspec\n",
        mojo_step("dispatcher.mojo", &target)
    );
    files.push((
        ".github/workflows/gem.yml".into(),
        Content::Text(workflow(
            unit,
            "gems",
            &steps,
            "${{ env.PACKAGE }}/gem/*.gem",
        )),
    ));
    Ok(Generated {
        files,
        module: None,
        notes: vec![
            format!(
                "Build the platform gem with `gem build {name}.gemspec` in {}, and the pure-Ruby \
                 gem in its pure/ folder (it copies the original's {} only, not files they \
                 require).",
                unit.out.join("gem").display(),
                originals.join(", ")
            ),
            runtime_note(),
            workflow_note(".github/workflows/gem.yml"),
        ],
    })
}

// ------------------------------------------------------------------ Go

/// `ffi` (Go): the wrapper module with one cgo file per platform (`//go:build` constraints)
/// linking `lib/<platform>/`, a file that stops the build elsewhere with the supported platforms
/// in the error, and this machine's library.
pub(crate) fn go_module(unit: &Unit) -> Result<Generated> {
    let m = unit.manifest;
    let host = host()?;
    let lib = m.lib_name();
    let library = crate::harness_mojo_c::library_path(unit.dir, m, false);
    built(&library, unit)?;
    let pkg = crate::codegen_go::package_name(m);
    let flags = format!(
        "#cgo LDFLAGS: -L${{SRCDIR}}/../{build} -l{lib} -Wl,-rpath,${{SRCDIR}}/../{build}\n",
        build = crate::harness_mojo_c::BUILD_DIR
    );
    let mut files = Vec::new();
    let go_dir = unit.dir.join("go");
    let mut entries: Vec<_> = std::fs::read_dir(&go_dir)
        .with_context(|| format!("reading {}", go_dir.display()))?
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .collect();
    entries.sort_by_key(|e| e.file_name());
    let mut linked = false;
    for entry in entries {
        let file = entry.file_name().to_string_lossy().into_owned();
        if !(file.ends_with(".go") || file == "go.mod" || file == "go.sum") {
            continue;
        }
        let text = std::fs::read_to_string(entry.path())?;
        let text = if text.contains(&flags) {
            linked = true;
            text.replace(&flags, "")
        } else {
            text
        };
        files.push((format!("go/{file}"), Content::Text(text)));
    }
    if !linked {
        bail!(
            "the Go wrapper in {} has no cgo LDFLAGS line to move",
            go_dir.display()
        );
    }
    let mut constraints = Vec::new();
    for p in PLATFORMS {
        let constraint = format!("{} && {}", p.os, p.go_arch);
        constraints.push(format!("({constraint})"));
        files.push((
            format!("go/cgo_{}_{}.go", p.os, p.go_arch),
            Content::Text(format!(
                "// Written by mojo-anything `package`: links the {name} Mojo library for {plat}.\n\n\
                 //go:build {constraint}\n\n\
                 package {pkg}\n\n\
                 /*\n#cgo LDFLAGS: -L${{SRCDIR}}/lib/{plat} -l{lib} -Wl,-rpath,${{SRCDIR}}/lib/{plat}\n*/\n\
                 import \"C\"\n",
                name = unit.name,
                plat = p.name,
            )),
        ));
    }
    files.push((
        "go/unsupported.go".into(),
        Content::Text(format!(
            "// Written by mojo-anything `package`: there is no Mojo build for this platform.\n\n\
             //go:build !({})\n\n\
             package {pkg}\n\n\
             const _ int = \"{name} has Mojo builds for {list} only\"\n",
            constraints.join(" || "),
            name = unit.name,
            list = platform_list(),
        )),
    ));
    files.push((
        format!("go/lib/{}/lib{lib}.{}", host.name, host.lib_ext),
        Content::Binary(relocatable(&library)?),
    ));
    let target = format!(
        "${{{{ env.PACKAGE }}}}/go/lib/${{{{ matrix.platform }}}}/lib{lib}.${{{{ matrix.ext }}}}"
    );
    files.push((
        ".github/workflows/go.yml".into(),
        Content::Text(workflow(
            unit,
            "Go libraries",
            &mojo_step(crate::codegen_go::EXPORTS, &target),
            "${{ env.PACKAGE }}/go/lib/${{ matrix.platform }}",
        )),
    ));
    Ok(Generated {
        files,
        module: None,
        notes: vec![
            format!(
                "{} is the Go module: commit every platform's lib/<platform>/ folder (the \
                 workflow builds them) and import it in place of the original package.",
                unit.out.join("go").display()
            ),
            runtime_note(),
            workflow_note(".github/workflows/go.yml"),
        ],
    })
}

// ------------------------------------------------------------------ C

/// `c-abi`: `include/<lib>.h`, `lib/<platform>/lib<lib>.{so,dylib}` and a pkg-config file whose
/// `platform` variable picks the folder.
pub(crate) fn c_archive(unit: &Unit) -> Result<Generated> {
    let m = unit.manifest;
    let host = host()?;
    let lib = m.lib_name();
    let library = crate::harness_mojo_c::library_path(unit.dir, m, false);
    built(&library, unit)?;
    let header_path = unit.dir.join(format!("include/{lib}.h"));
    let header = std::fs::read_to_string(&header_path)
        .with_context(|| format!("reading {}", header_path.display()))?;
    let pc = format!(
        "# Written by mojo-anything `package`. Another platform: pkg-config --define-variable=platform=<{}>\n\
         prefix=${{pcfiledir}}/../..\n\
         platform={}\n\n\
         Name: {}\n\
         Description: Mojo port of {}, made by mojo-anything (needs the Mojo {} runtime on the library path)\n\
         Version: {}\n\
         Cflags: -I${{prefix}}/include\n\
         Libs: -L${{prefix}}/lib/${{platform}} -l{lib} -Wl,-rpath,${{prefix}}/lib/${{platform}}\n",
        PLATFORMS
            .iter()
            .map(|p| p.name)
            .collect::<Vec<_>>()
            .join("|"),
        host.name,
        unit.name,
        m.unit,
        crate::mojo::MOJO_VERSION,
        unit.version,
    );
    let target = format!(
        "${{{{ env.PACKAGE }}}}/c/lib/${{{{ matrix.platform }}}}/lib{lib}.${{{{ matrix.ext }}}}"
    );
    let steps = format!(
        "{}\
         \x20     - name: Archive\n\
         \x20       working-directory: ${{{{ env.PACKAGE }}}}\n\
         \x20       run: tar -czf {name}-{version}-${{{{ matrix.platform }}}}.tar.gz c/include c/lib/pkgconfig c/lib/${{{{ matrix.platform }}}}\n",
        mojo_step(crate::harness_mojo_c::EXPORTS, &target),
        name = unit.name,
        version = unit.version,
    );
    Ok(Generated {
        files: vec![
            (format!("c/include/{lib}.h"), Content::Text(header)),
            (
                format!("c/lib/{}/lib{lib}.{}", host.name, host.lib_ext),
                Content::Binary(relocatable(&library)?),
            ),
            (format!("c/lib/pkgconfig/{lib}.pc"), Content::Text(pc)),
            (
                ".github/workflows/c.yml".into(),
                Content::Text(workflow(
                    unit,
                    "C archives",
                    &steps,
                    "${{ env.PACKAGE }}/*.tar.gz",
                )),
            ),
        ],
        module: None,
        notes: vec![
            format!(
                "Compile against {} with `pkg-config --cflags --libs {lib}` \
                 (PKG_CONFIG_PATH={}).",
                unit.out.join("c").display(),
                unit.out.join("c/lib/pkgconfig").display()
            ),
            runtime_note(),
            workflow_note(".github/workflows/c.yml"),
        ],
    })
}

// ------------------------------------------------------------------ Maven

/// The method added to the FFM native class: the jar's library for this platform, copied to a
/// cache folder (`$XDG_CACHE_HOME`, else `~/.cache`, `mojo-anything/<name>-<version>/<platform>`).
const JAR_LOADER: &str = r#"    private static final String PLATFORMS = "@LIST@";

    /** The jar's library for this platform, extracted to a cache folder; an error elsewhere. */
    private static Path packagedLibrary() {
        String os = System.getProperty("os.name", "").toLowerCase(java.util.Locale.ROOT);
        String arch = System.getProperty("os.arch", "").toLowerCase(java.util.Locale.ROOT);
        String platform = null;
        if (os.contains("linux") && (arch.equals("amd64") || arch.equals("x86_64"))) {
            platform = "linux-x64";
        } else if (os.contains("linux") && (arch.equals("aarch64") || arch.equals("arm64"))) {
            platform = "linux-arm64";
        } else if (os.contains("mac") && (arch.equals("aarch64") || arch.equals("arm64"))) {
            platform = "darwin-arm64";
        }
        String name = System.mapLibraryName("@LIB@");
        java.io.InputStream in = platform == null
            ? null
            : @CLASS@.class.getResourceAsStream("/native/" + platform + "/" + name);
        if (in == null) {
            throw new IllegalStateException("@NAME@: this jar has no Mojo library for " + os + " " + arch
                + (platform == null ? "" : " (" + platform + ")") + "; it holds builds for " + PLATFORMS + " only");
        }
        String cache = System.getenv("XDG_CACHE_HOME");
        Path base = cache != null && !cache.isEmpty()
            ? Paths.get(cache)
            : Paths.get(System.getProperty("user.home"), ".cache");
        Path dir = base.resolve("mojo-anything").resolve("@NAME@-@VERSION@").resolve(platform);
        try (java.io.InputStream source = in) {
            Files.createDirectories(dir);
            Path target = dir.resolve(name);
            Path part = Files.createTempFile(dir, name, ".part");
            Files.copy(source, part, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            Files.move(part, target, java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                java.nio.file.StandardCopyOption.ATOMIC_MOVE);
            return target;
        } catch (java.io.IOException e) {
            throw new IllegalStateException("@NAME@: cannot extract its Mojo library to " + dir + ": " + e.getMessage(), e);
        }
    }

"#;

/// The Java files under `dir`, by path relative to it.
fn java_tree(dir: &Path) -> Result<Vec<(String, std::path::PathBuf)>> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for entry in std::fs::read_dir(&d)?.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|e| e == "java") {
                let rel = path
                    .strip_prefix(dir)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .replace('\\', "/");
                out.push((rel, path));
            }
        }
    }
    out.sort();
    Ok(out)
}

/// The native class with the jar's loader: the library from the system property or
/// `MOJO_ANYTHING_LIB` as before, else the jar's own for this platform.
fn jar_native_class(text: &str, unit: &Unit, lib: &str) -> Result<String> {
    let class = text
        .lines()
        .find_map(|l| l.strip_prefix("public final class "))
        .and_then(|r| r.split_whitespace().next())
        .context("the native class has no `public final class` line")?;
    let anchor = format!("        String name = System.mapLibraryName(\"{lib}\");\n");
    if !text.contains(&anchor) {
        bail!("the native class has no `System.mapLibraryName` line to replace");
    }
    let body = "        return packagedLibrary();\n    }\n\n    @SuppressWarnings(\"unused\")\n    private static Path besideTheClasses() {\n";
    let marker = "    /** A NUL-terminated UTF-8 copy";
    if !text.contains(marker) {
        bail!("the native class has no cString helper to insert the loader before");
    }
    let loader = JAR_LOADER
        .replace("@LIST@", &platform_list())
        .replace("@LIB@", lib)
        .replace("@CLASS@", class)
        .replace("@NAME@", unit.name)
        .replace("@VERSION@", unit.version);
    Ok(text
        .replacen(&anchor, &format!("{body}{anchor}"), 1)
        .replacen(marker, &format!("{loader}{marker}"), 1))
}

/// `mojo-jvm` (Java and Kotlin): a Maven project whose jar holds the FFM wrappers and
/// `native/<platform>/` libraries; the native class extracts this platform's library on first
/// load. The manifest sets `Automatic-Module-Name` and `Enable-Native-Access: ALL-UNNAMED`.
pub(crate) fn jar(unit: &Unit) -> Result<Generated> {
    let m = unit.manifest;
    let host = host()?;
    let lib = m.lib_name();
    let library = crate::harness_mojo_jvm::library_path(unit.dir, m);
    built(&library, unit)?;
    let java_dir = unit.dir.join("java");
    let sources = java_tree(&java_dir)?;
    let mut files = Vec::new();
    let mut native_found = false;
    let mut group = None;
    for (rel, path) in &sources {
        let mut text = std::fs::read_to_string(path)?;
        if text.contains("SymbolLookup.libraryLookup") && text.contains("System.mapLibraryName") {
            text = jar_native_class(&text, unit, &lib)?;
            native_found = true;
        } else if group.is_none() && !rel.starts_with("mojoanything/") {
            group = rel.rsplit_once('/').map(|(dir, _)| dir.replace('/', "."));
        }
        files.push((format!("java/src/main/java/{rel}"), Content::Text(text)));
    }
    if !native_found {
        bail!("no FFM native class in {}", java_dir.display());
    }
    let group = group.unwrap_or_else(|| "mojoanything".into());
    let artifact = unit.name;
    files.push((
        format!(
            "java/src/main/resources/native/{}/{}",
            host.name,
            library
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default()
        ),
        Content::Binary(relocatable(&library)?),
    ));
    files.push((
        "java/MANIFEST.MF".into(),
        Content::Text(format!(
            "Manifest-Version: 1.0\nAutomatic-Module-Name: {group}\nEnable-Native-Access: ALL-UNNAMED\nCreated-By: mojo-anything\n"
        )),
    ));
    files.push((
        "java/pom.xml".into(),
        Content::Text(format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <!-- Written by mojo-anything `package`: the Mojo port of {unit_path}. `mvn package` builds\n\
             \x20    the jar with the libraries under src/main/resources/native/<platform>/. -->\n\
             <project xmlns=\"http://maven.apache.org/POM/4.0.0\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"\n\
             \x20        xsi:schemaLocation=\"http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd\">\n\
             \x20 <modelVersion>4.0.0</modelVersion>\n\
             \x20 <groupId>{group}</groupId>\n\
             \x20 <artifactId>{artifact}</artifactId>\n\
             \x20 <version>{version}</version>\n\
             \x20 <packaging>jar</packaging>\n\
             \x20 <properties>\n\
             \x20   <maven.compiler.release>22</maven.compiler.release>\n\
             \x20   <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>\n\
             \x20 </properties>\n\
             \x20 <build>\n\
             \x20   <plugins>\n\
             \x20     <plugin>\n\
             \x20       <groupId>org.apache.maven.plugins</groupId>\n\
             \x20       <artifactId>maven-jar-plugin</artifactId>\n\
             \x20       <version>3.4.2</version>\n\
             \x20       <configuration>\n\
             \x20         <archive>\n\
             \x20           <manifestFile>MANIFEST.MF</manifestFile>\n\
             \x20         </archive>\n\
             \x20       </configuration>\n\
             \x20     </plugin>\n\
             \x20   </plugins>\n\
             \x20 </build>\n\
             </project>\n",
            unit_path = m.unit,
            version = unit.version,
        )),
    ));
    let file_name = library
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let stem = file_name
        .rsplit_once('.')
        .map_or(file_name.as_str(), |(s, _)| s);
    let target = format!(
        "${{{{ env.PACKAGE }}}}/java/src/main/resources/native/${{{{ matrix.platform }}}}/{stem}.${{{{ matrix.ext }}}}"
    );
    let out = repo_relative(&m.root, unit.out);
    let jar_job = format!(
        "  jar:\n    needs: build\n    runs-on: ubuntu-24.04\n    steps:\n\
         \x20     - uses: actions/checkout@v4\n\
         \x20     - uses: actions/download-artifact@v4\n\
         \x20       with:\n          path: natives\n\
         \x20     - name: Put every platform's library in the jar\n\
         \x20       run: |\n\
         \x20         for d in natives/*; do p=${{d#natives/{artifact}-}}; mkdir -p {out}/java/src/main/resources/native/$p; cp $d/* {out}/java/src/main/resources/native/$p/; done\n\
         \x20     - uses: actions/setup-java@v4\n\
         \x20       with:\n          distribution: temurin\n          java-version: \"22\"\n\
         \x20     - name: Build the jar\n\
         \x20       working-directory: {out}/java\n\
         \x20       run: mvn -B package\n\
         \x20     - uses: actions/upload-artifact@v4\n\
         \x20       with:\n          name: {artifact}-jar\n          path: {out}/java/target/*.jar\n"
    );
    let workflow_text = format!(
        "{}{jar_job}",
        workflow(
            unit,
            "jar",
            &mojo_step(crate::codegen_ffi::DISPATCHER, &target),
            "${{ env.PACKAGE }}/java/src/main/resources/native/${{ matrix.platform }}",
        )
    );
    files.push((
        ".github/workflows/jar.yml".into(),
        Content::Text(workflow_text),
    ));
    Ok(Generated {
        files,
        module: None,
        notes: vec![
            format!(
                "Build the jar with `mvn package` in {} (Java 22 or later; run with \
                 --enable-native-access=ALL-UNNAMED). It extracts its library to \
                 ~/.cache/mojo-anything on first load.",
                unit.out.join("java").display()
            ),
            runtime_note(),
            workflow_note(".github/workflows/jar.yml"),
        ],
    })
}
