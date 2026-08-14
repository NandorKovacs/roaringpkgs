# CLAUDE.md — pkgs (personal Arch repository tooling)

## What this is

Tooling for a single personal pacman repository (working name: `roaring`).
Packages are built on a desktop into an **unsigned staging repo**, then
manually **signed and rsynced** to an always-on LAN server that serves it
as a dumb static mirror. Full design: `proposal-aurutils.md` (authoritative);
`spec.md` is the superseded v0.5 paru-based design, kept for history — do
not implement from it.

## Cardinal rule

**aurutils is the engine; use it, never wrap it.** No adapter layers, no
generated pacman/paru contexts, no provenance databases, no manifest
reconciliation — aurutils commands are called directly and their flags are
the interface. (The superseded spec.md went the other way and grew into a
package manager; that's why it was dropped.)

## Layout and contracts

```
bin/pkgs-sync       # timer entry point: aur sync -u -c, then VCS srcver pass
bin/pkgs-publish    # manual: sign staged pkgs, rebuild signed db, rsync to server
bin/pkgs-remove     # repo-remove + delete pkg files from staging
lib/common.sh       # sourced helpers: config, lock, logging, failure aggregation
systemd/            # SYSTEM pkgs-sync.service + .timer, User=pkgsbuild
pkgs.conf.example   # template for /etc/pkgs/pkgs.conf
ignore.example      # template for the build user's aurutils sync/ignore
```

- Scripts are bash, `set -euo pipefail`. Shared helpers (config loading,
  locking, logging) can live in a sourced `lib/common.sh` if duplication
  warrants it.
- Every script sources the first config that exists out of `$PKGS_CONF`,
  `$XDG_CONFIG_HOME/pkgs/pkgs.conf`, `/etc/pkgs/pkgs.conf` — the system
  path is the real one, because two accounts read it (build user, you).
  Config values must be absolute: `$HOME` expands differently per account.
  Scripts take ALL machine paths from it: `REPO_NAME`, `PUBLISH_NAME`,
  `STAGING_DIR`, `PUBLISH_DIR`, `CUSTOM_DIRS` (array of dirs whose subdirs
  hold PKGBUILDs), `GPG_KEY`, `REMOTE`. Never hardcode paths; never write
  machine paths, package sources, or built packages into this git repo
  (`pkgs.conf` itself is gitignored).
- Staging and published are two differently-named pacman repos, because
  pacman derives a repo's db filename from its `pacman.conf` section name
  and the builder desktop declares both. `REPO_NAME` (e.g.
  `roaring-staging`) is the build side — aurutils `-d`, the chroot conf
  filename, the staging db filename. `PUBLISH_NAME` (e.g. `roaring`) is
  what clients see and the only name `pkgs-publish` writes. Do not collapse
  them; do not use `REPO_NAME` for anything under `PUBLISH_DIR`.
- All mutating operations flock `$STAGING_DIR/.lock` (non-blocking in the
  timer path: `flock -n 9 || exit 0`).
- All builds use chroots: `aur sync -c` / `aur build -c -d $REPO_NAME`.
  Chroot config lives at `/etc/aurutils/pacman-$REPO_NAME.conf` (system
  file, documented in README, not managed by this repo).

## Invariants (do not break)

- Staging is NEVER signed; `GPG_KEY` is read by `pkgs-publish` only. The
  timer path must never touch gpg or require the key.
- Repo membership's source of truth is the staging db — no package lists
  are reconciled. `pkgs-sync` refreshes what exists; it never adds or
  removes members.
- `pkgs-sync` must be idempotent and safe unattended: `--no-view
  --noconfirm`, aggregate per-package failures (report at exit; never die
  on the first broken package).
- Prebuilt/manual packages need no bookkeeping: `aur sync -u` skips
  anything not in the AUR. Pinned old versions of AUR-named packages go in
  the aurutils ignore file — do not invent another mechanism.
- `pkgs-publish` postcondition: publish dir content-identical to staging,
  every package has a valid detached sig, db rebuilt from scratch with
  `repo-add -s -v -k $GPG_KEY`. Copy-on-content-difference (`cmp`), because
  VCS rebuilds reuse filenames. Prune before rebuilding the db. rsync
  (`-a --delete`) is the last step.
- VCS rebuild detection = `aur srcver` vs `aur vercmp -d $REPO_NAME`
  (aurutils' shipped sync-devel pattern). No stored HEAD state.

## Environment assumptions

Arch Linux; `aurutils`, `devtools`, `pacman`, `git`, `gnupg`, `rsync`,
`flock` installed.

Privilege split — the timer is a **system** unit (`systemctl`, not
`--user`) running as a dedicated unprivileged account, `pkgsbuild`:

- Sudoers NOPASSWD for `mkarchroot`, `arch-nspawn`, `makechrootpkg` is
  granted to `pkgsbuild`, never to a human login (root-equivalent —
  documented caveat, don't widen it, don't hand it back to the user).
- Both accounts are in group `pkgs`, and `STAGING_DIR`, `PUBLISH_DIR` and
  the `CUSTOM_DIRS` trees are group-owned, setgid group-writable (`2775`).
  Manual commands (`aur sync`, `aur build`, `pkgs-remove`, `pkgs-publish`)
  run as the user, with ordinary password-prompting sudo; only the timer
  runs as `pkgsbuild`. The unit sets `UMask=0002`.
- The gpg key and the ssh credentials stay with the user: `pkgsbuild` has
  neither, and the timer path never invokes gpg.
- Nothing the build user needs may live under a home directory (`0700` on
  Arch): checkout at `/opt/pkgs`, config at `/etc/pkgs/pkgs.conf`, repos
  under `/srv`. The aurutils ignore file is the exception — it must be the
  build user's own copy, since the timer's `aur sync -u` reads it.
- Locks are opened read-only when the lock file exists, so a
  differently-owned lock never blocks another account.

## Testing changes

There is no CI. Test on the real machine, in this order, before committing:

1. `bash -n` and `shellcheck` on every touched script.
2. Dry-run friendly: prefer echoing destructive commands under a `-n` flag
   when adding new behavior to pkgs-publish/pkgs-remove.
3. Exercise against a throwaway repo: point `PKGS_CONF` at a temp config
   with `STAGING_DIR`/`PUBLISH_DIR` under `/tmp`, `repo-add` an empty db,
   and run the script for real. Never test against the live staging dir.
4. For pkgs-sync changes, a single cheap AUR package in the throwaway repo
   is the fixture; check both the "up to date" and "rebuild needed" paths.

## Style

- Error messages to stderr, one line, prefixed with the script name.
- README documents one-time system setup (pacman.conf section, chroot conf,
  sudoers, timer enablement); scripts must not attempt to perform it.
