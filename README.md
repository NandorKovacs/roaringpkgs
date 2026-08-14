# pkgs — personal Arch repository tooling

aurutils is the engine that builds and maintains the repo; these scripts
just automate the two things worth automating (unattended sync, and the
sign+publish step) and add the one wrapper removal genuinely needs. Packages
build unsigned into a staging repo on the desktop — under a dedicated
unprivileged build account, driven by a system timer — then get manually
signed by you and rsynced to an always-on LAN server that serves them as a
dumb static mirror. This git repo holds only the tooling — scripts, systemd units, and
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
  pkgs-sync.service / pkgs-sync.timer     system units, run as the build user
pkgs.conf.example                          template for /etc/pkgs/pkgs.conf
ignore.example                             template for the build user's
                                           ~/.config/aurutils/sync/ignore
```

### The build user

Unattended chroot builds need passwordless `sudo` for
`mkarchroot`/`arch-nspawn`/`makechrootpkg`, which is root-equivalent. So the
timer doesn't run as you: it's a **system** unit running as a dedicated
account, `pkgsbuild`, and that account gets the NOPASSWD rule. Your login
keeps ordinary password-prompting `sudo`.

Both accounts belong to a shared group, `pkgs`, and every directory they
share — staging, publish, and the custom PKGBUILD dirs — is group-owned and
group-writable. So you keep working exactly as before: `aur sync -c foo`,
`pkgs-remove`, `pkgs-publish` all run as you.

### Two repos, two names

The staging repo and the published repo are **separate pacman repositories
with different names**, and both are declared on the builder desktop. They
have to be: pacman derives a repo's database filename from its
`pacman.conf` section name, so two sections cannot share one name and still
find their dbs. Staging is an internal build detail that only aurutils and
the build container ever see, so the published repo — the one you and every
other client install from — gets the good name:

| | config key | example | who sees it |
|---|---|---|---|
| staging | `REPO_NAME` | `roaring-staging` | aurutils (`-d`), the build chroot |
| published | `PUBLISH_NAME` | `roaring` | you, and every client |

Examples below use those two values; rename freely in your own `pkgs.conf`
— every script takes both from there. `PUBLISH_NAME` defaults to
`REPO_NAME` if you leave it unset, which is only useful if the desktop
never consumes its own published repo.

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

2. **Create the shared group and the build user.** The build account is a
   system account nobody logs into; it needs a home only because aurutils
   keeps its AUR clones (`$AURDEST`) and its ignore file there.

   ```sh
   sudo groupadd pkgs
   sudo useradd --system --gid pkgs --create-home \
       --home-dir /var/lib/pkgsbuild --shell /usr/bin/bash pkgsbuild
   sudo usermod -aG pkgs "$USER"
   sudo chmod 750 /var/lib/pkgsbuild    # group-readable, so you can look inside
   ```

   Log out and back in (or `newgrp pkgs`) before the group membership takes
   effect in your session; `id -nG` is the check. Rename either the group or
   the account freely — they appear in the sudoers file, the unit's
   `User=`/`Group=`, and the commands below, but nowhere in the scripts.

3. **Create the staging, publish, and custom dirs and an empty staging db**
   (proposal §2). All three are group-owned and group-writable, setgid so
   that everything created inside keeps the `pkgs` group:

   ```sh
   sudo install -d -o pkgsbuild -g pkgs -m 2775 \
       /srv/pkgrepo/staging /srv/pkgrepo/publish /srv/pkgrepo/custom
   (umask 002; repo-add /srv/pkgrepo/staging/roaring-staging.db.tar.gz)
   ```

   Both accounts write all three: the timer builds into staging and rebuilds
   VCS packages in place in the custom dirs, while you add packages, remove
   them, and publish. Creating and deleting files is governed by the
   directory's permissions, not the files', so it doesn't matter which
   account owns any given file. Use `umask 002` when you work in these dirs
   (the unit sets it for the timer) so what you create stays group-writable.

   The db filename is what gives the staging repo its name — `repo-add`
   takes it from there, and so does pacman. Nothing inside the db records
   it, which is why renaming a repo later is just a matter of renaming
   these files (see "Renaming an existing repo" below).

   Any other location works just as well — these paths are only the
   defaults in `pkgs.conf.example`; set `STAGING_DIR`/`PUBLISH_DIR`/
   `CUSTOM_DIRS` to whatever you used. One constraint is real, though:
   nothing the build user needs may live **inside your home directory**,
   which Arch creates mode `0700` (`HOME_MODE` in `/etc/login.defs`) and
   which the build user therefore cannot even traverse.

4. **Declare the staging repo in `/etc/pacman.conf`**, so aurutils can find
   it and resolve dependencies against it — but *not* so your desktop
   installs from it:

   ```ini
   [roaring-staging]
   SigLevel = Optional TrustAll
   Usage = Sync
   Server = file:///srv/pkgrepo/staging
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

   - An explicit `pacman -S roaring-staging/foo` **still works**, because
     `pacman.conf(5)` notes that "an enabled repository can be operated on
     explicitly, regardless of the Usage level set." `Usage` removes staging
     from automatic resolution; it is not a lock. Making it truly invisible
     means omitting it here and passing
     `--pacman-conf /etc/aurutils/pacman-roaring-staging.conf` to `aur
     sync`/`aur build` — at the cost that host-side dependency resolution
     can no longer see your repo (`aur depends` has no config option), so a
     package depending on another of your packages gets rebuilt from the
     AUR, or fails outright if that dependency is custom and not in the AUR.
   - This section is *not* how you consume your own packages on the
     desktop. For that you declare the signed published repo as a second
     section, `[roaring]` (see Clients below) — which is exactly why
     staging is named `roaring-staging` and not `roaring`.

5. **Chroot pacman config**, at `/etc/aurutils/pacman-roaring-staging.conf`
   (`aur build -c -d roaring-staging` / `aur sync -c` look this up by repo
   name, falling back to devtools' defaults if absent — so the filename has
   to track `REPO_NAME`). Copy the devtools template and append a
   `[roaring-staging]` section — **without** the `Usage` line from step 4:

   ```sh
   sudo install -Dm644 /usr/share/devtools/pacman.conf.d/extra.conf \
       /etc/aurutils/pacman-roaring-staging.conf
   ```

   ```ini
   # appended to /etc/aurutils/pacman-roaring-staging.conf
   [roaring-staging]
   SigLevel = Optional TrustAll
   Server = file:///srv/pkgrepo/staging
   ```

   This file configures pacman *inside the build container*, and there the
   repo must stay fully usable (`Usage` defaults to `All`): installing
   dependencies from staging is exactly what it's for. Do not copy step
   4's `Usage = Sync` here — that would stop your packages from being able
   to depend on each other, and builds would fail on a missing dependency
   that is plainly sitting in the repo.

   The separation is the point: the container installs from staging freely,
   while your actual system doesn't. `file://` repos listed in this config
   get bind-mounted straight into the container (proposal §4). The chroot
   itself lives under `/var/lib/aurbuild/x86_64/`, created on first use;
   deleting it is always safe.

6. **Sudoers for the chroot helpers — granted to the build account, not to
   you.** devtools has no rootless mode: `mkarchroot`, `arch-nspawn`, and
   `makechrootpkg` need root, and an unattended timer cannot answer a
   password prompt.

   ```
   # /etc/sudoers.d/pkgs   (install with: sudo visudo -f /etc/sudoers.d/pkgs)
   pkgsbuild ALL=(root) NOPASSWD: /usr/bin/mkarchroot, /usr/bin/arch-nspawn, /usr/bin/makechrootpkg
   ```

   **Caveat, stated honestly (proposal §4):** NOPASSWD on
   `arch-nspawn`/`makechrootpkg` is effectively root-equivalent — both can
   be used to run arbitrary commands as root outside the container with the
   right arguments. Putting it on a dedicated account doesn't change that;
   it changes who has it. Only something already running as `pkgsbuild` can
   reach the rule, not every process under your login. Don't widen the list
   beyond these three binaries, and don't add your own user back to it.

   Your own `sudo` keeps prompting for a password — building a package by
   hand just asks for it, the way it always did.

7. **Install the shared config.** It lives in `/etc` because both accounts
   read it — the build user under the timer, you everywhere else:

   ```sh
   sudo install -Dm644 pkgs.conf.example /etc/pkgs/pkgs.conf
   sudoedit /etc/pkgs/pkgs.conf   # set REPO_NAME, PUBLISH_NAME, STAGING_DIR,
                                  # PUBLISH_DIR, CUSTOM_DIRS, GPG_KEY, REMOTE
   ```

   Use absolute paths only: `$HOME` would expand to `/var/lib/pkgsbuild`
   under the timer and to your home everywhere else. A
   `~/.config/pkgs/pkgs.conf` still wins for whoever owns it, and
   `$PKGS_CONF` beats both — that's what the throwaway-repo tests use.

8. **Optional: pinning file**, only needed once you actually pin something.
   It goes in the build user's home, because the timer's `aur sync -u` is
   what reads it:

   ```sh
   sudo -u pkgsbuild mkdir -p /var/lib/pkgsbuild/.config/aurutils/sync
   sudo install -o pkgsbuild -g pkgs -m 664 ignore.example \
       /var/lib/pkgsbuild/.config/aurutils/sync/ignore
   ```

   Mode `664` and group `pkgs` are what let you edit it later without
   `sudo`.

9. **Install the tooling and enable the timer.** The checkout has to be
   readable by the build user, so it can't live in your home (`0700`):

   ```sh
   sudo install -d -o "$USER" -g pkgs -m 2775 /opt/pkgs
   git clone <this-repo-url> /opt/pkgs

   sudo systemctl link /opt/pkgs/systemd/pkgs-sync.service
   sudo systemctl enable --now /opt/pkgs/systemd/pkgs-sync.timer
   ```

   `systemctl link` symlinks the units out of the checkout, so `git pull`
   updates them in place (`sudo systemctl daemon-reload` afterwards). For a
   checkout somewhere else, override the one path that hardcodes it with
   `sudo systemctl edit pkgs-sync.service`:

   ```ini
   [Service]
   ExecStart=
   ExecStart=/your/path/bin/pkgs-sync
   ```

   These are **system** units (`sudo systemctl`, not `systemctl --user`), so
   no `enable-linger` is needed — the timer fires whether or not anyone is
   logged in. Verify:

   ```sh
   systemctl list-timers pkgs-sync.timer
   sudo systemctl start pkgs-sync.service   # first run, on demand
   journalctl -u pkgs-sync.service -f
   ```

## Day-to-day use

All of this runs as **you**, not as the build user: the shared `pkgs` group
gives you write access to the repos, and `sudo` prompting for a password is
fine when you're sitting at the terminal.

**Add an AUR package** (fetches, shows the diff for review, resolves AUR
deps, chroot-builds, repo-adds):

```sh
aur sync -c foo
```

**Add a custom / non-AUR VCS package.** Put a PKGBUILD in a subdirectory of
one of your `CUSTOM_DIRS` entries, then:

```sh
cd /srv/pkgrepo/custom/somefork-git
aur build -c -d roaring-staging
```

Being in a configured `CUSTOM_DIRS` subdirectory *is* the provenance —
nothing else is tracked. The timer rebuilds VCS packages in these same
directories, which is why they're group-writable.

**Add a prebuilt / pinned package** (your own build, an old version you
want to keep around):

```sh
cp foo-1.2-1-x86_64.pkg.tar.zst "$STAGING_DIR"/
repo-add -R "$STAGING_DIR/roaring-staging.db.tar.gz" \
    "$STAGING_DIR"/foo-1.2-1-x86_64.pkg.tar.zst
```

**Pin an old version of a package that *also* exists in the AUR** (the only
case that needs bookkeeping — `aur sync -u` otherwise skips anything not in
the AUR automatically): add a line to the build user's ignore file,
`/var/lib/pkgsbuild/.config/aurutils/sync/ignore`, e.g.
`roaring-staging/electron25`. A repo-qualified entry names the staging repo
— that is what `aur sync -u` operates on. It has to be that copy, in the
build user's home: the timer's `aur sync` reads the build user's config, not
yours.

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
then one rsync. This stays yours alone: the build user has no signing key
and no ssh credentials, and the timer never invokes gpg. It's also the
natural moment to review what the timer built:

**Inspect the repo:**

```sh
aur repo -d roaring-staging --list
```

### What the timer does, and what it deliberately doesn't

`pkgs-sync` runs as `pkgsbuild` from the system timer. It runs
`aur sync -u -c` for AUR release packages, then a VCS pass
modelled on aurutils' shipped `examples/sync-devel`: it lists the repo, keeps
the `-git`/`-hg`/`-svn`/`-bzr`/`-cvs`/`-darcs` members, runs `aur srcver` to
compute each one's current upstream version, and compares that against the
repo with `aur vercmp`. Only packages that actually moved get rebuilt, so a
quiet day costs nothing but the version checks.

Two consequences worth knowing:

- **The repo database is the membership list.** The timer refreshes what is
  already in the repo; it never adds anything. A brand-new package — AUR or
  custom — has to be built once by hand (`aur sync -c foo`, or
  `aur build -c -d roaring-staging` in its directory). After that the timer
  keeps it current.
- **A VCS package's PKGBUILD is looked up in `CUSTOM_DIRS` first**, and only
  then in aurutils' own clone directory (`$AURDEST`, which for the timer
  means the build user's `/var/lib/pkgsbuild/.cache/aurutils/sync`). Being in a custom dir is what marks a package as
  locally maintained, so it is refreshed from your working copy and never
  fetched from the AUR. Non-VCS custom packages are never rebuilt
  automatically — rebuild them yourself when you change them.

## Server and client setup

**Server** (any static file server; nginx shown):

```nginx
server {
    listen 80;
    root /srv/roaring;      # whatever REMOTE rsyncs into
    autoindex on;
}
```

`root` is the directory `pkgs-publish` rsyncs `PUBLISH_DIR` into, so
`roaring.db` sits directly at the vhost root — which is what the client
`Server` line below points at.

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
Server = http://server.lan
```

The section name must equal `PUBLISH_NAME`, because pacman fetches
`<Server>/<section>.db` — it derives the db filename from the section name,
not the other way round. `Server` is the **directory** holding the db, not
the db file itself; writing `Server = http://server.lan/roaring.db` makes
pacman request `roaring.db/roaring.db` and fail.

**The builder desktop uses this exact same section**, unchanged. That is
the whole reason staging is called `roaring-staging`: the two repos coexist
in one `pacman.conf`, staging under its own name for aurutils' bookkeeping
and the build container, published under the good name for everything you
actually install. Put `[roaring]` above `[roaring-staging]` so upgrade
resolution reaches the signed copy first — `Usage = Sync` on staging
already keeps it out, but the ordering makes the intent obvious.

### Renaming an existing repo

Cheap, at any time: a repo's name lives **only** in its database filename.
The `.pkg.tar.zst` files don't record it, and neither does anything inside
the db (it's a tarball of `pkgname-pkgver/desc` entries). So renaming
staging from `roaring` to `roaring-staging` moves no packages:

```sh
cd "$STAGING_DIR"
mv roaring.db.tar.gz    roaring-staging.db.tar.gz
mv roaring.files.tar.gz roaring-staging.files.tar.gz
rm -f roaring.db roaring.files roaring.db.tar.gz.old roaring.files.tar.gz.old
ln -s roaring-staging.db.tar.gz    roaring-staging.db
ln -s roaring-staging.files.tar.gz roaring-staging.files
```

The `rm` of the bare `.db`/`.files` is required — `repo-add` creates those
as symlinks to the tarballs, and the `mv` would leave them dangling.

Do **not** rebuild with `repo-add roaring-staging.db.tar.gz *.pkg.tar.zst`
instead. If staging holds more than one version of a package, a glob
rebuild resolves the duplicate by glob order rather than by version, and
glob order is lexical: `2.1.10` sorts before `2.1.9`. The `mv` preserves
the db exactly as aurutils built it.

Then update `/etc/pacman.conf` (step 4), rename
`/etc/aurutils/pacman-<old>.conf` and its section (step 5), any
repo-qualified lines in the aurutils ignore file, and `REPO_NAME` in
`pkgs.conf`. Finally clear the stale sync db before refreshing, since the
old name now belongs to the published repo:

```sh
sudo rm -f /var/lib/pacman/sync/roaring.db /var/lib/pacman/sync/roaring.files
sudo pacman -Sy
aur repo -d roaring-staging --list      # verify: all members still there
```

`PUBLISH_DIR` and the server need no changes at all — they already carry
the published name.

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
- The timer builds as `pkgsbuild`, an account with no signing key, no ssh
  key and no access to your home. It does hold the NOPASSWD chroot rule,
  which is root-equivalent (setup step 6), so this is a smaller blast
  radius, not a sandbox — what it buys is that nothing running under your
  login inherits passwordless root.
- `Usage = Sync` on the staging repo (setup step 4) keeps unsigned,
  unattended-built packages out of the builder desktop's own `pacman -Syu`.
  It is a guard against *accident*, not against a determined operator: an
  explicit `pacman -S roaring-staging/foo` still installs from staging.

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
   live staging dir.** `$PKGS_CONF` outranks both `/etc/pkgs/pkgs.conf` and
   any per-user config, so a throwaway run as yourself needs no root and
   cannot reach the real repo.
4. For `pkgs-sync` changes, use one cheap AUR package in the throwaway repo
   as a fixture, plus one VCS (`-git`) package to exercise the
   srcver/vercmp path; check both the "up to date" and "rebuild needed"
   outcomes.
5. For `pkgs-publish` changes, point `REMOTE` at a local directory first and
   inspect the result before aiming it at the server.
