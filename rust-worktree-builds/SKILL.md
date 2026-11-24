---
name: rust-worktree-builds
description: Cut CPU and disk use of Rust builds when many git worktrees or parallel agents build one Cargo workspace on one machine. Sets up a machine-wide sccache with basedirs, measures before and after, finds what fills target/, and adds agent rules for tests. Use when Rust builds are slow across worktrees, target/ folders fill the disk, or the user asks to share a build cache between checkouts.
---

# Rust builds across many worktrees

Many worktrees of one Rust workspace each compile the same dependencies again, and each keeps its own
`target/` of 4–30 GB. This skill reduces the CPU cost, finds what uses the disk, and stops agents from
building more than they need.

Measure before you change a global setting, and report the numbers. The gains depend on the project.

## 1. Diagnose

```bash
nproc; free -g; df -h /; findmnt -no FSTYPE /          # cores, RAM, disk, filesystem (ext4 = no reflinks)
git worktree list
for w in $(git worktree list --porcelain | awk '/^worktree/{print $2}'); do
  [ -d "$w/target" ] && du -sh "$w/target"; done | sort -h
cat ~/.cargo/config.toml; echo "RUSTC_WRAPPER=$RUSTC_WRAPPER"
cargo tree -e normal,build --prefix none | sort -u | wc -l   # number of crates
ls <crate>/tests/*.rs | wc -l                                # integration test files
du -sh target/debug/{deps,incremental,build}
```

Find the critical path of a fresh build:

```bash
cargo build -p <main-crate> --timings   # open target/cargo-timings/cargo-timing.html
```

If one workspace crate takes most of the wall time on one rustc process, no cache makes a fresh worktree much
faster. Only a split of that crate into smaller crates does.

## 2. What helps and what does not

| Option | Effect | Verdict |
|---|---|---|
| sccache 0.20+ with `basedirs` | Dependency compiles hit the cache from every checkout (≈99% hits measured). Total CPU of a fresh worktree build −40% in one project. Wall time only −10 to −15% when one workspace crate is the critical path. | **Use** |
| sccache without `basedirs` (old distro packages, e.g. Debian 0.10) | Hits only for crates whose paths are the same in every checkout (registry crates): ≈77% | Use the latest release |
| `SCCACHE_ALLOW_INCREMENTAL=cache` | Workspace crates miss anyway when a `build.rs` or macro bakes in absolute paths | Measure; usually skip |
| mold | Rust ≥ 1.90 links with LLD on x86_64 Linux by default; relinks were the same speed | Skip on new Rust |
| One shared `CARGO_TARGET_DIR` | Cargo locks the whole dir, so parallel builds wait; concurrent writes can break artifacts; `build.rs` paths point to the wrong checkout | **Do not use** |
| mbx (cargo wrapper with hard-linked store) | In one test it used more disk (store + target), had few hits across checkouts, and the edit loop was 3.5× slower. It cannot cache together with sccache. | Measure before you adopt |
| Cargo's built-in cross-workspace cache | 2026 project goal, nightly, simple crates only | Wait |

sccache does **not** make `target/` smaller. A hit unpacks a full copy into each `target/`. The largest parts
of `target/` cannot be cached at all: incremental data of workspace crates and linked binaries (one per
integration test file). See step 5 for disk.

## 3. Benchmark before you change anything global

Do not touch existing worktrees. Make 2 copies of `HEAD` under a folder that the wrapper will treat as a
checkout root (step 4), and copy any untracked build inputs (for example an embedded frontend `dist/`).

```bash
for c in bench-a bench-b; do mkdir ~/src/$c; git archive HEAD | tar -x -C ~/src/$c; done
cargo fetch    # and read the registry once, so the first run is not slowed by cold disk cache
```

For each run: `rm -rf target`, then
`/usr/bin/time -f "%e %U %S" cargo build -p <crate>` (and, if agents build tests,
`cargo test -p <crate> --no-run`).

- Run the baseline twice without a wrapper (`RUSTC_WRAPPER=` and no `build.rustc-wrapper`).
- Then: empty cache in copy A, then a new checkout (copy B) with a warm cache, then one edit in a base crate.
- **Count the CPU of the sccache server.** sccache runs rustc as children of its server, so `time` on cargo
  misses most of it. Start a private server (`SCCACHE_SERVER_PORT=4227 SCCACHE_DIR=/tmp/sc`), and read
  fields 14–17 of `/proc/<server pid>/stat` (utime, stime, cutime, cstime) before and after each run.
- Record hits with `sccache --zero-stats` before and `sccache --show-stats` after.
- Record the load average. Other builds on the machine change the times; repeat a run when the load differs.
- For disk, `du -sch` the cache and both `target/` folders together (hard links then count once).

Use [`scripts/bench.sh`](scripts/bench.sh) for this. Delete the copies and caches after the benchmark.

## 4. Set up sccache machine-wide

Install the latest release binary, not the distro package (it may lack `basedirs`). Verify the checksum.

```bash
v=$(gh api repos/mozilla/sccache/releases/latest --jq .tag_name)   # e.g. v0.20.0
n=sccache-$v-x86_64-unknown-linux-musl
d=$(mktemp -d); cd "$d"
curl -sSLO https://github.com/mozilla/sccache/releases/download/$v/$n.tar.gz
curl -sSLO https://github.com/mozilla/sccache/releases/download/$v/$n.tar.gz.sha256
echo "$(cut -d' ' -f1 $n.tar.gz.sha256)  $n.tar.gz" | sha256sum -c -
tar -xzf $n.tar.gz && sudo install -m755 $n/sccache /usr/local/bin/sccache; cd /; rm -rf "$d"
```

`basedirs` must list every checkout root. sccache reads it only when its server starts, so use a wrapper that
builds the list on each call: [`scripts/sccache-wrap`](scripts/sccache-wrap). Install it and set it globally:

```bash
install -m755 scripts/sccache-wrap ~/.local/bin/sccache-wrap
# edit SCCACHE_WRAP_ROOTS in the script (globs of checkout roots), then:
cat >> ~/.cargo/config.toml <<EOF

[build]
rustc-wrapper = "$HOME/.local/bin/sccache-wrap"
EOF
```

The wrapper also sets `SCCACHE_BASEDIRS_VERBATIM_ENV_DEPS=CARGO_MANIFEST_DIR,CARGO_MANIFEST_PATH`, so crates
that bake `env!("CARGO_MANIFEST_DIR")` into output are not shared between checkouts with a wrong path.

Caveats to tell the user:
- A worktree created while the server runs gets path-stripped hits only after the server restarts (the
  wrapper sets a 300 s idle timeout).
- A proc macro that reads files with `std::fs` (for example `include_dir!`) may not be tracked; check such
  crates if a build uses stale embedded files.
- Debug info in dependencies costs disk and link time. A good machine-wide default:
  `[profile.dev] debug = "line-tables-only"` and `[profile.dev.package."*"] debug = false`.

Then run the benchmark again with only the global setting, and report before/after in one table
(wall, CPU incl. server, hits, disk).

## 5. Disk: find what fills target/

Typical findings in one project (ext4, 15 worktrees, 610 dependencies):

| Part of `target/` | Size | Can it be shared? |
|---|---|---|
| Main binary only | ≈4 GB | Dependencies only, and only as copies |
| + one binary per file in `tests/` (105 files) | ≈28 GB | No: each binary links the full crate and all dependencies (150–400 MB each) |
| Incremental data | about half of the rest | No, private to the checkout |

Options, best first:

1. **Agents build only the tests they need** (step 6). Biggest win, no code change.
2. **Fewer test binaries.** Each file in `tests/` is its own binary. Merge small files into a few groups
   (`tests/<group>/main.rs` with `mod file;` lines) and share one fixture module. Costs: merge conflicts with
   open branches, a forgotten `mod` line silently skips tests, one crate recompiles all its tests on an edit,
   tests from different files run in one process. Measure the edit-loop time before and after.
3. **Clean idle `target/` folders** (cron, by last build time). With sccache the rebuild is cheap.
4. **Move benchmarks out of `tests/`** (to `benches/`); an `#[ignore]` benchmark still builds a binary.
5. **btrfs with `compress=zstd`** (+ `bees`/`duperemove` for dedup) only if the disk is still too full: it
   needs a filesystem change. ext4 and Cargo/sccache cannot share files between checkouts.

Before you delete any `target/`, list the running binaries from it (`ps -eo pid,args | grep target/`). Running
processes keep working; they rebuild on the next start.

## 6. Agent rules for tests (AGENTS.md / CLAUDE.md)

Keep the tests: they check what manual testing on a dev server does not (authorization between tenants,
other database backends, security edge cases). Check this claim in the repo: in one project, 169 commits
added 140k test lines and changed only 1.4% of old ones (median 2 lines per commit). But a test that never runs
has no value: CI must run the full suite on each PR and block the merge.

Add this section to the project's agent instructions, with the project's crate and folder names:

```markdown
## Tests: build only the tests you need

Each file in `<crate>/tests/` becomes its own test binary of 150–400 MB, so the full suite uses about
<N> GB of `target/` and much CPU in each worktree. Many worktrees build on one disk at the same time. CI runs the
full suite.

- In a worktree, do not run the full Rust suite: no `cargo test --workspace`, or `cargo test -p <crate>`
  without `--test` (and no recipe that wraps them, such as `just test` / `just check`).
- Run only the test files that cover your change: `cargo test -p <crate> --test <name>` (one `--test` for each
  file; find them with a search in `<crate>/tests/` for the route, function or table you changed). For another
  crate, use `cargo test -p <crate> --lib`.
- When you change a signature that other code calls, run `cargo check -p <crate> --tests`. It compiles all test
  files without linking test binaries, so it finds broken callers in tests for little disk and CPU.
- Run the full suite only when the user asks for it.
```

Also add a one-line pointer next to any doc that lists the full-suite commands ("these are for CI").

`cargo check -p <crate> --tests` is the key check: in one project it took 76 s and 2.8 GB, against about 28 GB
for building all test binaries, and it found 3 test files that had not compiled since a signature change.

## Report

End with one table: before/after wall and CPU (incl. the sccache server), cache hits, `target/` size per
worktree, disk free, every global file changed (`~/.cargo/config.toml`, wrapper path, binary path), and how to
undo it (remove `build.rustc-wrapper`, `rm ~/.local/bin/sccache-wrap /usr/local/bin/sccache`,
`rm -rf ~/.cache/sccache`).
