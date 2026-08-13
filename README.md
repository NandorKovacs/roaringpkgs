# pkgs — personal Arch repository tooling

aurutils is the engine that builds and maintains the repo; these scripts
just automate the two things worth automating (unattended sync, and the
sign+publish step) and add the one wrapper removal genuinely needs. Packages
build unsigned into a staging repo on the desktop, then get manually signed
and rsynced to an always-on LAN server that serves them as a dumb static
mirror. This git repo holds only the tooling — scripts, systemd units, and
config templates — never machine paths, package sources, or built packages.

Full design rationale: `proposalaurutils.md` (authoritative; `spec.md`, if
present, is a superseded design — do not implement from it).

## Repo layout

```
bin/
  pkgs-sync       timer entry point: aur sync -u -c, then a VCS srcver pass
  pkgs-publish    manual: sign staged packages, rebuild signed db, rsync
  pkgs-remove     repo-remove + delete matching package files from staging
lib/
  common.sh       shared helpers (config loading, locking, logging) — sourced,
                  never executed directly
systemd/
  pkgs-sync.service / pkgs-sync.timer     user-level units (Persistent=true)
pkgs.conf.example                          template for ~/.config/pkgs/pkgs.conf
ignore.example                             template for ~/.config/aurutils/sync/ignore
```

Examples below use `REPO_NAME=roaring`; rename freely in your own
`pkgs.conf` — every script takes it from there.

## One-time setup

Do this once, by hand, on the desktop that builds packages. Nothing here is
performed by the scripts themselves.

1. **Install aurutils and devtools.**

   ```sh
   sudo pacman -S devtools
   # aurutils isn't in the official repos; get it from the AUR by hand once:
   git clone https://aur.archlinux.org/aurutils.git
   cd aurutils && makepkg -si
   ```

2. **Create the staging and publish dirs and an empty staging db**
   (proposal §2). Both must be owned by *your* user, not root: the timer
   runs as you (`systemctl --user`), and everything that writes there —
   `aur sync`/`repo-add` adding packages, the `.lock` file the scripts
   flock, and `pkgs-publish` creating and filling the publish dir — runs
   unprivileged. Only the `/srv` parent needs root to create.

   ```sh
   sudo install -d -o "$USER" -g "$(id -gn)" \
       /srv/pkgrepo/staging/roaring /srv/pkgrepo/publish/roaring
   repo-add /srv/pkgrepo/staging/roaring/roaring.db.tar.gz
   ```

   (Run `repo-add` as your user, so the db it creates is yours too.) Any
   other location works just as well — these paths are only the defaults in
   `pkgs.conf.example`; set `STAGING_DIR`/`PUBLISH_DIR` to whatever you
   used.

3. **Declare the staging repo in `/etc/pacman.conf`**, so aurutils can find
   it and resolve dependencies against it — but *not* so your desktop
   installs from it:

   ```ini
   [roaring]
   SigLevel = Optional TrustAll
   Usage = Sync
   Server = file:///srv/pkgrepo/staging/roaring
   ```

   Then `sudo pacman -Syu`.

   **`Usage` is the important line.** It defaults to `All` when omitted,
   which would make staging — unsigned, built unattended from unreviewed
   PKGBUILDs — a normal upgrade source for the whole system. `Usage = Sync`
   keeps the database refreshed (so `aur sync`'s dependency resolution can
   see what your repo already provides) while withholding `Install` and
   `Upgrade`, so `pacman -Syu` never pulls from it and `pacman -S foo` never
   resolves to it. Add `Search` too if you want `pacman -Ss` to list your
   packages.

   `SigLevel = Optional TrustAll` is *not* the control here — it only says
   unsigned packages are acceptable in this repo, which they have to be,
   since staging is deliberately never signed. It is `Usage` that decides
   whether anything gets installed.

   Two caveats, stated plainly:

   - An explicit `pacman -S roaring/foo` **still works**, because
     `pacman.conf(5)` notes that "an enabled repository can be operated on
     explicitly, regardless of the Usage level set." `Usage` removes staging
     from automatic resolution; it is not a lock. Making it truly invisible
     means omitting it here and passing
     `--pacman-conf /etc/aurutils/pacman-roaring.conf` to `aur sync`/`aur
     build` — at the cost that host-side dependency resolution can no longer
     see your repo (`aur depends` has no config option), so a package
     depending on another of your packages gets rebuilt from the AUR, or
     fails outright if that dependency is custom and not in the AUR.
   - To *consume* your own packages on the desktop, point it at the signed
     published repo under a different section name (see Clients below) —
     you can't have two `[roaring]` sections, and aurutils resolves
     `-d roaring` to this one.

4. **Chroot pacman config**, at `/etc/aurutils/pacman-roaring.conf`
   (`aur build -c -d roaring` / `aur sync -c` look this up by repo name,
   falling back to devtools' defaults if absent). Copy the devtools
   template and append a `[roaring]` section — **without** the `Usage` line
   from step 3:

   ```sh
   sudo install -Dm644 /usr/share/devtools/pacman.conf.d/extra.conf \
       /etc/aurutils/pacman-roaring.conf
   ```

   ```ini
   # appended to /etc/aurutils/pacman-roaring.conf
   [roaring]
   SigLevel = Optional TrustAll
   Server = file:///srv/pkgrepo/staging/roaring
   ```

   This file configures pacman *inside the build container*, and there the
   repo must stay fully usable (`Usage` defaults to `All`): installing
   dependencies from `roaring` is exactly what it's for. Do not copy step
   3's `Usage = Sync` here — that would stop your packages from being able
   to depend on each other, and builds would fail on a missing dependency
   that is plainly sitting in the repo.

   The separation is the point: the container installs from staging freely,
   while your actual system doesn't. `file://` repos listed in this config
   get bind-mounted straight into the container (proposal §4). The chroot
   itself lives under `/var/lib/aurbuild/x86_64/`, created on first use;
   deleting it is always safe.

5. **Sudoers for the chroot helpers.** devtools has no rootless mode:
   `mkarchroot`, `arch-nspawn`, and `makechrootpkg` need root. The
   unattended timer needs these passwordless:

   ```
   # /etc/sudoers.d/pkgs
   yourusername ALL=(root) NOPASSWD: /usr/bin/mkarchroot, /usr/bin/arch-nspawn, /usr/bin/makechrootpkg
   ```

   **Caveat, stated honestly (proposal §4):** NOPASSWD on
   `arch-nspawn`/`makechrootpkg` is effectively root-equivalent — both can
   be used to run arbitrary commands as root outside the container with the
   right arguments. This limits *accident* surface (typos, runaway scripts),
   not a malicious-user threat model. That's an acceptable tradeoff for your
   own account on your own desktop; don't widen the NOPASSWD list beyond
   these three binaries.

6. **Install the config:**

   ```sh
   mkdir -p ~/.config/pkgs
   cp pkgs.conf.example ~/.config/pkgs/pkgs.conf
   $EDITOR ~/.config/pkgs/pkgs.conf   # set REPO_NAME, STAGING_DIR, PUBLISH_DIR,
                                      # CUSTOM_DIRS, GPG_KEY, REMOTE
   ```

7. **Optional: pinning file**, only needed once you actually pin something:

   ```sh
   mkdir -p ~/.config/aurutils/sync
   cp ignore.example ~/.config/aurutils/sync/ignore
   ```

8. **Enable the timer.** Check out this repo at `~/pkgs` (the shipped unit
   uses `%h/pkgs/bin/pkgs-sync`), symlink or copy the units into your user
   systemd dir, then enable:

   ```sh
   git clone <this-repo-url> ~/pkgs
   mkdir -p ~/.config/systemd/user
   ln -s ~/pkgs/systemd/pkgs-sync.service ~/pkgs/systemd/pkgs-sync.timer \
       ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now pkgs-sync.timer
   loginctl enable-linger "$USER"   # run the timer with no session open
   ```

## Day-to-day use

**Add an AUR package** (fetches, shows the diff for review, resolves AUR
deps, chroot-builds, repo-adds):

```sh
aur sync -c foo
```

**Add a custom / non-AUR VCS package.** Put a PKGBUILD in a subdirectory of
one of your `CUSTOM_DIRS` entries, then:

```sh
cd ~/pkgwork/custom/somefork-git
aur build -c -d roaring
```

Being in a configured `CUSTOM_DIRS` subdirectory *is* the provenance —
nothing else is tracked.

**Add a prebuilt / pinned package** (your own build, an old version you
want to keep around):

```sh
cp foo-1.2-1-x86_64.pkg.tar.zst "$STAGING_DIR"/
repo-add -R "$STAGING_DIR/roaring.db.tar.gz" \
    "$STAGING_DIR"/foo-1.2-1-x86_64.pkg.tar.zst
```

**Pin an old version of a package that *also* exists in the AUR** (the only
case that needs bookkeeping — `aur sync -u` otherwise skips anything not in
the AUR automatically): add a line to
`~/.config/aurutils/sync/ignore`, e.g. `roaring/electron25`.

**Remove a package:**

```sh
bin/pkgs-remove foo          # repo-remove + delete its files from staging
bin/pkgs-remove -n foo       # dry run first if unsure
```

If `foo` was a custom package, also delete its source directory under
`CUSTOM_DIRS` by hand — `pkgs-remove` only touches the staging repo.

**Publish** (sign staged packages, rebuild the signed db, rsync to the
server):

```sh
bin/pkgs-publish
```

One gpg passphrase prompt (gpg-agent caches it for the rest of the run),
then one rsync. This is also the natural moment to review what the timer
built:

**Inspect the repo:**

```sh
aur repo -d roaring --list
```

### What the timer does, and what it deliberately doesn't

`pkgs-sync` runs `aur sync -u -c` for AUR release packages, then a VCS pass
modelled on aurutils' shipped `examples/sync-devel`: it lists the repo, keeps
the `-git`/`-hg`/`-svn`/`-bzr`/`-cvs`/`-darcs` members, runs `aur srcver` to
compute each one's current upstream version, and compares that against the
repo with `aur vercmp`. Only packages that actually moved get rebuilt, so a
quiet day costs nothing but the version checks.

Two consequences worth knowing:

- **The repo database is the membership list.** The timer refreshes what is
  already in the repo; it never adds anything. A brand-new package — AUR or
  custom — has to be built once by hand (`aur sync -c foo`, or
  `aur build -c -d roaring` in its directory). After that the timer keeps it
  current.
- **A VCS package's PKGBUILD is looked up in `CUSTOM_DIRS` first**, and only
  then in aurutils' own clone directory (`$AURDEST`, default
  `~/.cache/aurutils/sync`). Being in a custom dir is what marks a package as
  locally maintained, so it is refreshed from your working copy and never
  fetched from the AUR. Non-VCS custom packages are never rebuilt
  automatically — rebuild them yourself when you change them.

## Server and client setup

**Server** (any static file server; nginx shown):

```nginx
server {
    listen 80;
    root /srv/pkgrepo;
    autoindex on;
}
```

The server never builds, signs, or mutates anything — it's a dumb mirror of
whatever `pkgs-publish` rsynced in, which is exactly why it's safe to leave
always-on.

**Clients** (laptop, the server itself, or the desktop):

```sh
pacman-key --recv-keys <KEYID>     # or: pacman-key --add pubkey.asc
pacman-key --lsign-key <KEYID>
```

```ini
[roaring]
SigLevel = Required DatabaseRequired TrustedOnly
Server = http://server.lan/roaring
```

**On the builder desktop, name this section something else** —
`[roaring-signed]`, say. Two sections can't share a name, and aurutils
resolves `-d roaring` to the staging entry from setup step 3, so renaming
that one would send builds to the wrong place. With both declared, the
desktop ends up in the same position as every other client: everything it
actually installs is signature-verified, and staging is present only for
aurutils' bookkeeping and for the build container.

## Security posture

Stated honestly (proposal §8), not glossed over:

- The timer runs `aur sync -u -c --no-view --noconfirm`: **unreviewed AUR
  PKGBUILD code executes at build time**, unattended.
- Manual signing in `pkgs-publish` is a *publication* gate, not a *review*
  gate — by the time you sign, the code has already run.
- The chroot (`-c`, always on) contains build-time execution to the
  container. That's real protection against a build polluting the host, but
  a malicious package would still ship to clients once signed — the chroot
  doesn't inspect what a package *does* once installed.
- `Usage = Sync` on the staging repo (setup step 3) keeps unsigned,
  unattended-built packages out of the builder desktop's own `pacman -Syu`.
  It is a guard against *accident*, not against a determined operator: an
  explicit `pacman -S roaring/foo` still installs from staging.

Mitigations, in increasing order of effort:

1. Review diffs at `aur sync` add-time (the default, interactive path —
   keep doing this for anything new).
2. Pin anything sensitive via the ignore file and update it interactively
   instead of letting the timer auto-rebuild it.
3. Drop `-u` from the timer entirely, so it only fetches; build everything
   interactively.

For a personal repo of packages you already chose to install, accepting the
default (chroot + unattended `-u`, review at add-time) is a reasonable
tradeoff — it's the standard aurutils posture, not a weakened one.

## Testing changes

No CI; test on the real machine, in this order, before committing:

1. `bash -n` and `shellcheck` on every touched script.
2. Prefer a `-n` dry-run flag for new destructive behaviour in
   `pkgs-publish`/`pkgs-remove`; echo the commands instead of running them.
3. Exercise against a throwaway repo: point `PKGS_CONF` at a temp config
   under `/tmp` (`STAGING_DIR`/`PUBLISH_DIR` also under `/tmp`), `repo-add`
   an empty db there, and run the script for real. **Never test against the
   live staging dir.**
4. For `pkgs-sync` changes, use one cheap AUR package in the throwaway repo
   as a fixture, plus one VCS (`-git`) package to exercise the
   srcver/vercmp path; check both the "up to date" and "rebuild needed"
   outcomes.
5. For `pkgs-publish` changes, point `REMOTE` at a local directory first and
   inspect the result before aiming it at the server.
