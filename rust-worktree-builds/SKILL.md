---
name: rust-worktree-builds
description: Cut CPU and disk use of Rust builds when many git worktrees or parallel agents build one Cargo workspace on one machine, and speed up Rust CI and slow tests. Sets up a machine-wide sccache with basedirs, measures before and after, finds what fills target/, adds agent rules for tests, checks and benchmarks GitHub Actions caching, and profiles slow tests. Use when Rust builds are slow across worktrees, target/ folders fill the disk, the user asks to share a build cache between checkouts, Rust CI is slow, or tests take seconds each.
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

**Before you add the rule, check that CI really runs the tests** (step 7.1). In one project, CI had been
switched to manual runs ("temporarily") two months earlier, and 3 test files no longer compiled. The rule
"CI runs the full suite" is false until CI runs on each PR and its result blocks the merge.

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

## 7. CI (GitHub Actions)

### 7.1 Check that CI runs, and what fills its cache

```bash
grep -n -A6 '^on:' .github/workflows/*.yml                 # workflow_dispatch only = no automatic runs
gh api "repos/<owner>/<repo>/actions/workflows/<ci>.yml/runs?per_page=5" \
  --jq '.workflow_runs[] | "\(.event) \(.conclusion) \(.created_at)"'   # last run date
git log --format='%h %ad %s' --date=short -5 -- .github/workflows/<ci>.yml   # who turned it off, and why
gh api repos/<owner>/<repo>/actions/cache/usage
gh api --paginate "repos/<owner>/<repo>/actions/caches?per_page=100" \
  --jq '.actions_caches[] | "\(.key|split("-")[0]|split("/")[0]) \(.size_in_bytes)"' |
  awk '{s[$1]+=$2; n[$1]++} END{for (k in s) printf "%s %.2fGB n=%d\n", k, s[k]/1e9, n[k]}'
```

- A cancelled run of another workflow (for example the image build) is not a CI run. Check the CI workflow itself.
- The Actions cache is 10 GB per repo by default (admins can raise it, and the extra is billed). GitHub deletes
  the oldest entries when the cache is full. A Docker `cache-to: type=gha,mode=max` can fill all of it
  (`buildkit-blob` entries), so the Rust cache never survives. Move the Docker cache to a registry:
  `cache-to: type=registry,ref=ghcr.io/<owner>/<image>:buildcache,mode=max` and the same `cache-from`.
- Public repos get standard runners for free (4 vCPU, 16 GB), so more parallel jobs cost nothing. Private repos
  get 2 vCPU and pay per minute.
- A full test build can be 20–30 GB; that is near the free disk of a hosted runner.

### 7.2 Cache options

| Option | Notes |
|---|---|
| `CARGO_INCREMENTAL=0`, `CARGO_PROFILE_DEV_DEBUG=0`, `CARGO_PROFILE_TEST_DEBUG=0` | CI builds once: incremental data and debug info only cost disk, cache size and link time |
| `Swatinem/rust-cache@v2` with `save-if: ${{ github.ref == 'refs/heads/main' }}` | Caches dependencies (`target/` without workspace crates) and the registry. PRs read, only main writes, so branches do not fill the cache. It saves only when the job succeeds. |
| `mozilla-actions/sccache-action` + `SCCACHE_GHA_ENABLED=true` + `RUSTC_WRAPPER=sccache` | One cache entry per compiled crate. With incremental off, it also caches **workspace crates**, so an unchanged commit builds almost only links. Since January 2026, GitHub limits cache uploads to 200 per minute per repo; check `Cache errors` in `sccache --show-stats` on a cold run. |

Results of one trial (10 test files, 4-vCPU runner, the build step only):

| Setup | Cold | Warm (same commit) |
|---|---|---|
| No cache | 258 s | 258 s |
| rust-cache | 198 s | 134 s (−48%) |
| sccache | 352 s (uploads cost time) | 51 s (−80%) |

The warm sccache number is a best case: the same commit again. A PR changes workspace crates, so measure a run
after a code change too. With a warm cache, the test run itself (5–7 min) cost more than the build.

### 7.3 Trial workflow before you change the real CI

Use [`scripts/ci-trial.yml`](scripts/ci-trial.yml): a matrix of `none`, `rust-cache` and `sccache` that
builds about 10 test files once and runs them (add a database service if the tests need one).

1. Push it to its own branch (`ci-trial`), never to the default branch: a push there can deploy. To push
   without a checkout change, commit with plumbing:
   ```bash
   export GIT_INDEX_FILE=$(mktemp -u); git read-tree HEAD
   git update-index --add --cacheinfo 100644,$(git hash-object -w ci-trial.yml),.github/workflows/ci-trial.yml
   c=$(git commit-tree $(git write-tree) -p HEAD -m "ci: trial cache workflow"); unset GIT_INDEX_FILE
   git push origin $c:refs/heads/ci-trial
   ```
2. Run 1 is cold. Re-run it (`gh run rerun <id>`) for warm numbers. Then push a small change to a workspace
   crate for a realistic PR number.
3. Read the step times from the API:
   ```bash
   gh run view <id> --json jobs --jq '.jobs[] | .name as $n | .steps[] |
     "\($n) | \(.name) | \(((.completedAt|fromdate)-(.startedAt|fromdate)))s"'
   ```
4. A test build can need generated files (for example a frontend build that the server embeds and checks at
   start). Build them for real; a stub can compile and then fail at run time.
5. Delete the branch and its caches when you are done.

## 8. Slow tests

### 8.1 Find the cost

Divide the time of each test binary by its test count (from the `test result: ok. N passed … finished in Xs`
lines). If even small tests take seconds, the cost is a fixed setup cost in each test, not the test logic.

Then profile one test binary on one thread:

```bash
bin=$(ls -t target/debug/deps/<test_file>-* | grep -v '\.d$' | head -1)
perf record -F 999 -g -o /tmp/perf.data -- "$bin" --test-threads=1
perf report -i /tmp/perf.data --no-children --sort sym --stdio -g none | grep -E '^ +[0-9.]+%' |
  awk '{p=$1; sub("%","",p); g="other";
        if ($0 ~ /argon2|blake2|bcrypt|scrypt|pbkdf2/) g="password hashing";
        else if ($0 ~ /sqlite3|yy_|keywordCode|Vdbe|btree|pager/) g="sqlite engine";
        else if ($0 ~ /malloc|free|memcpy|memmove/) g="memory";
        t[g]+=p} END{for (k in t) printf "%6.1f%%  %s\n", t[k], k}' | sort -rn
```

Common causes in one project (each SQLite test took 2–3 s, Postgres 1–3 s):
- **Migrations for each test.** Each test made a new database and ran 123 migrations (1,062 schema
  statements). SQLite parses the whole schema again after each schema change. Even the optimized `sqlite3` CLI
  needed 0.35 s for it, and the bundled SQLite in a debug build is much slower. Postgres runs migrations in its
  own optimized server, so it was faster.
- **Password hashing in debug mode.** Argon2/bcrypt are slow on purpose, and unoptimized code is many times
  slower.

### 8.2 Fixes

1. **Optimize heavy dependencies in debug builds** (workspace `Cargo.toml`). Dependencies build at
   `opt-level = 0` by default, and that includes bundled C code:
   ```toml
   [profile.dev.package.libsqlite3-sys]
   opt-level = 3
   [profile.dev.package.argon2]
   opt-level = 3
   [profile.dev.package.blake2]
   opt-level = 3
   ```
   Pick the crates that the profile shows (also compression, image or crypto crates). Measured in one project:
   −52% for a test file, and password hashing fell from 23% to 2% of the time. Try it first without a file
   change: `cargo test … --config 'profile.dev.package.<crate>.opt-level=3'`.
2. **Template database.** Migrate one database for each test binary, then copy it for each test (SQLite: copy
   the file; Postgres: `CREATE DATABASE … TEMPLATE <template>`). This needs one shared test helper.
3. **cargo-nextest** runs tests from all binaries at the same time, so all cores stay busy. It does not reduce
   CPU work.

## Report

End with one table: before/after wall and CPU (incl. the sccache server), cache hits, `target/` size per
worktree, disk free, CI step times, test time per test, every global file changed (`~/.cargo/config.toml`,
wrapper path, binary path), and how to undo it (remove `build.rustc-wrapper`,
`rm ~/.local/bin/sccache-wrap /usr/local/bin/sccache`, `rm -rf ~/.cache/sccache`).
