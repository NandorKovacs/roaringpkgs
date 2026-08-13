# Personal Arch repository — proposal v2.1 (aurutils-based)

*Response to spec.md v0.5 ("roaringpkgs"). Written 2026-08-13.*
*v2.1: custom PKGBUILDs live outside the git repo in configurable working
dirs; chroot builds (`-c`) are the default.*

## 1. Verdict on the v0.5 spec

The spec is rigorous, and several of its decisions are exactly right and kept
here: the unsigned **staging** / signed **published** split, signing kept
entirely off the timer's privilege path, the repo database as the source of
truth for membership (no manifests), the flock serialization, clean chroot
builds, and the publish algorithm in §6.4 (content-compare, prune, rebuild
db from scratch).

The problem is scope and foundation:

- **It became a package manager.** Multi-repo, per-repo generated paru
  contexts, profiles assembled from config fragments, a provenance state
  machine (git clones + `manual.list` + exclusion sets), export/import.
  Your actual requirement is one repo on one desktop.
- **paru is the wrong engine — your instinct is correct.** paru's
  `LocalRepo`/`Chroot` mode works, but paru is an interactive AUR helper
  first; its options drift between releases. The spec knows this: the entire
  `lib/paru.sh` adapter with a `paru --version` assertion exists to absorb
  that instability. When a spec needs an anti-corruption layer around its
  own engine, the engine is wrong.
- The spec's own history points at the answer: v0.2 was aurutils-based.
  **aurutils** is purpose-built for exactly this job — maintaining a local
  pacman repository from AUR and local PKGBUILDs — with small, composable,
  scriptable commands (`aur sync`, `aur build`, `aur repo`, `aur srcver`,
  `aur vercmp`, `aur chroot`) and stable flags. The v0.2→v0.3 move wrapped
  a less suitable tool to regain what aurutils already did. The remaining
  mistake in v0.2 was wrapping at all: aurutils should be *used*, not
  abstracted.

So: keep the architecture ideas, throw away the software project. What
remains is aurutils + two short scripts + two systemd units in a git repo,
pointed at unversioned working directories by a small config file, and a
couple of deliberately manual steps.

## 2. Shape of the system

```
DESKTOP (builder, not always on)                SERVER (always on, same LAN)
┌──────────────────────────────────┐            ┌─────────────────────────┐
│ ~/pkgs (git): scripts, units,    │            │ nginx (or any static    │
│   config example, ignore file    │            │ file server)            │
│ working dirs (config, no git):   │            │                         │
│   custom PKGBUILDs, staging,     │   rsync    │                         │
│   publish                        │──(manual,──▶ /srv/pkgrepo/roaring/   │
│                                  │   signed)  │   signed db + pkgs+sigs │
│ /var/lib/aurbuild: build chroot  │            │                         │
│ timer: aur sync -u -c + VCS pass │            │ clients (incl. desktop  │
│ manual: pkgs-publish (gpg+rsync) │            │ if you like) point here │
└──────────────────────────────────┘            └─────────────────────────┘
```

One repo (`roaring` below — rename freely). One architecture. No profiles,
no generated pacman/paru contexts: the staging repo is declared once in the
desktop's real `/etc/pacman.conf`, which is also how aurutils discovers it:

```ini
# /etc/pacman.conf on the desktop
[roaring]
SigLevel = Optional TrustAll
Server = file:///srv/pkgrepo/staging/roaring
```

Initialize once:

```sh
install -d /srv/pkgrepo/staging/roaring
repo-add /srv/pkgrepo/staging/roaring/roaring.db.tar.gz
sudo pacman -Syu
```

### The git repo (`~/pkgs`) — scripts only

```
pkgs/
├── README.md
├── pkgs.conf.example        # template for ~/.config/pkgs/pkgs.conf
├── bin/
│   ├── pkgs-sync            # timer entry point (§4)
│   ├── pkgs-publish         # sign + rsync (§5)
│   └── pkgs-remove          # repo-remove + delete files (~10 lines)
├── systemd/
│   ├── pkgs-sync.service
│   └── pkgs-sync.timer
└── ignore.example           # pinned packages, template for
                             # ~/.config/aurutils/sync/ignore
```

No package sources, no built packages, no machine paths in git — only the
tooling. Everything location-specific lives in one sourced config file:

```sh
# ~/.config/pkgs/pkgs.conf        (scripts: . "${PKGS_CONF:-$XDG_CONFIG_HOME/pkgs/pkgs.conf}")
REPO_NAME=roaring
STAGING_DIR=/srv/pkgrepo/staging/$REPO_NAME
PUBLISH_DIR=/srv/pkgrepo/publish/$REPO_NAME
CUSTOM_DIRS=(
    "$HOME/pkgwork/custom"       # dirs whose subdirs each hold a PKGBUILD;
)                                # one or more entries
GPG_KEY=0xDEADBEEF...            # read by pkgs-publish only
REMOTE=server.lan:/srv/pkgrepo/$REPO_NAME
```

`CUSTOM_DIRS` is where your own and non-AUR VCS PKGBUILDs live — plain
working directories, not versioned here. (Nothing stops you from making a
custom dir its own private git repo later; the scripts don't know or care.)

Repo membership stays machine state (the staging db) — the one v0.4 idea
worth keeping wholesale.

## 3. The three package sources, and add/remove

**AUR packages** — aurutils native, built in the chroot:

```sh
aur sync -c foo         # fetch, review diff, resolve AUR deps, chroot build, repo-add
```

**Custom / non-AUR VCS packages** — a PKGBUILD directory under one of your
`CUSTOM_DIRS`:

```sh
cd ~/pkgwork/custom/somefork-git
aur build -c -d roaring
```

`aur build` builds the current directory into the local repo. No provenance
database needed: *being in a configured custom dir is the provenance.*

**Prebuilt / pinned packages** (your own `.pkg.tar.zst`, old versions):

```sh
cp foo-1.2-1-x86_64.pkg.tar.zst "$STAGING_DIR"/
repo-add -R "$STAGING_DIR/roaring.db.tar.gz" \
    "$STAGING_DIR"/foo-1.2-1-x86_64.pkg.tar.zst
```

No `manual.list`, no exclusion set. `aur sync -u` consults the AUR RPC for
what's in the repo: a package that doesn't exist in the AUR is simply
skipped (with a warning). The only case needing action is a **pinned old
version of a package that *does* exist in the AUR** — and aurutils has a
built-in mechanism for exactly that, the ignore file:

```
# ~/.config/aurutils/sync/ignore
roaring/electron25
```

**Remove** — `bin/pkgs-remove`, the one wrapper that earns its existence,
because removal genuinely takes two coordinated steps:

```sh
#!/bin/bash -e
. "${PKGS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/pkgs/pkgs.conf}"
repo-remove "$STAGING_DIR/$REPO_NAME.db.tar.gz" "$@"
for p in "$@"; do rm -f "$STAGING_DIR/$p"-*.pkg.tar.zst{,.sig}; done
```

(Plus, if it was a custom package: delete its directory from the custom
dir.)

## 4. Chroot builds

Every build — interactive or timer — runs in a devtools nspawn container
via `-c`. One-time setup:

**Chroot pacman.conf** — `aur build -c -d roaring` looks up
`/etc/aurutils/pacman-roaring.conf` (falling back to the devtools
defaults). Create it once: copy `/usr/share/devtools/pacman.conf.d/extra.conf`
and append the local repo section:

```ini
[roaring]
SigLevel = Optional TrustAll
Server = file:///srv/pkgrepo/staging/roaring
```

`file://` repos in this config are bind-mounted into the container
automatically, so packages in the repo can depend on each other. The chroot
itself lives at `/var/lib/aurbuild/x86_64/` and is created on first use;
deleting it is always safe.

**Privileges** — devtools has no rootless mode: `mkarchroot`,
`arch-nspawn`, and `makechrootpkg` run via sudo (aurutils honors
`AUR_PACMAN_AUTH` if you use something else). For the unattended timer,
grant NOPASSWD on exactly those three:

```
# /etc/sudoers.d/pkgs
nandor ALL=(root) NOPASSWD: /usr/bin/mkarchroot, /usr/bin/arch-nspawn, /usr/bin/makechrootpkg
```

Caveat (inherited verbatim from spec §8, still true): NOPASSWD on
`arch-nspawn`/`makechrootpkg` is effectively root-equivalent. These rules
limit accident surface, not a malicious-user threat model — fine for your
own account on your own desktop.

What the chroot buys: builds can't pollute the host, missing dependencies
are caught (host-installed packages don't leak in), and the unreviewed code
the timer runs at build time (§7) is at least contained.

## 5. Automated update + build (`pkgs-sync`, systemd timer)

Two passes, both idempotent, whole thing under `flock`:

```sh
#!/bin/bash
set -euo pipefail
. "${PKGS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/pkgs/pkgs.conf}"
exec 9>"$STAGING_DIR/.lock"; flock -n 9 || exit 0

## Pass 1: AUR updates (release packages), chroot builds
aur sync -u -c -d "$REPO_NAME" --no-view --noconfirm

## Pass 2: VCS packages — rebuild only if upstream HEAD moved
# (adapted from aurutils' shipped examples/sync-devel)
aur repo -d "$REPO_NAME" --list | cut -f1 \
  | grep -E -- '-(git|hg|svn|bzr|cvs)$' > "$tmp" || true
if [[ -s $tmp ]]; then
    xargs -a "$tmp" aur fetch -S 2>/dev/null || true
    # aur srcver runs pkgver() against latest upstream; vercmp against the db
    xargs -a "$tmp" aur srcver 2>/dev/null \
      | aur vercmp -d "$REPO_NAME" -p - \
      | cut -d: -f1 \
      | while read -r pkg; do
            aur build -c -d "$REPO_NAME" --noconfirm \
                <path-resolution: AUR clone dir, or $pkg under a CUSTOM_DIRS entry>
        done
fi

## Pass 3: VCS dirs under CUSTOM_DIRS not in the AUR — same srcver/vercmp
## check per directory. Non-VCS custom packages are never rebuilt here.
```

(Sketch, not final code — the real script resolves whether a VCS pkgbase
lives in aurutils' clone dir or under `CUSTOM_DIRS`, and aggregates
failures instead of dying on the first one. Still well under 100 lines
total.)

Units — user-level (`systemctl --user`), sudo only inside the chroot helpers:

```ini
# pkgs-sync.service
[Unit]
Description=Refresh staging repo
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=%h/pkgs/bin/pkgs-sync
Nice=10
IOSchedulingClass=idle

# pkgs-sync.timer
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true          # desktop is not always on: catch up after boot
[Install]
WantedBy=timers.target
```

`systemctl --user enable --now pkgs-sync.timer` (plus
`loginctl enable-linger` so it runs without an open session). `Persistent=`
covers the "desktop was off at trigger time" case.

## 6. Manual sign + publish (`pkgs-publish`)

Keep spec §6.4 essentially verbatim — it was the best part. Staging is never
signed; the timer never sees the key; publishing is a conscious act:

1. For each staged `*.pkg.tar.zst` absent from `$PUBLISH_DIR` **or
   differing in content** (`cmp` — catches VCS rebuilds reusing a
   filename): copy it over, drop any stale `.sig`, then
   `gpg --detach-sign -u $GPG_KEY` anything missing one.
2. Prune published packages (+ `.sig`) no longer in staging.
3. Rebuild the publish db from directory contents:
   `repo-add -s -v -k $GPG_KEY roaring.db.tar.gz *.pkg.tar.zst`
   (`-v` verifies every package signature, `-s` signs the db).
4. `rsync -a --delete "$PUBLISH_DIR"/ "$REMOTE"/`

One passphrase prompt (gpg-agent caches for the rest), one rsync. Steps 1–3
before rsync mean the server only ever sees complete, signed states; if you
want atomicity on the server too, rsync into `roaring.new/` and `mv`-swap.

## 7. Server and clients

Server: any static file server over the LAN.
`nginx` with `root /srv/pkgrepo; autoindex on;` is plenty. Nothing on the
server ever builds, signs, or mutates the repo — it is a dumb mirror, which
is exactly why it's safe for it to be always-on.

Clients (laptop, server itself, the desktop too if you want to consume the
published rather than staging repo):

```sh
pacman-key --recv-keys <KEYID>   # or pacman-key --add pubkey.asc
pacman-key --lsign-key <KEYID>
```

```ini
[roaring]
SigLevel = Required DatabaseRequired TrustedOnly
Server = http://server.lan/roaring
```

## 8. Security posture (unchanged from spec, stated honestly)

The timer builds AUR PKGBUILDs with `--no-view`: unreviewed code runs at
build time. Manual signing is a *publication* gate, not a *review* gate —
by signing time the code has already executed. The chroot contains
build-time execution to the container (that's half the reason `-c` is the
default here), but a malicious package would still ship to clients once
signed. Mitigations, in increasing order of effort: review diffs at
`aur sync` time when adding (the default, keep it); pin anything sensitive
via the ignore file and update it interactively; or drop `-u` from the
timer and let it only *fetch*, building interactively. I'd accept the risk
as the spec did — for a personal repo of packages you chose, this is the
standard aurutils posture.

## 9. What is deliberately manual, and why that's fine

- **Adding/removing packages** — interactive by nature; you want the
  PKGBUILD review.
- **Signing + publishing** — the whole point of the staging split; also the
  natural moment to eyeball `aur repo -d roaring --list` and see what the
  timer built.
- **Pinning** — one line in the aurutils ignore file.
- **Bootstrap** — install `aurutils` and `devtools` once by hand
  (`makepkg -si` for aurutils); afterwards aurutils lives in your own repo
  and updates itself via the timer.

## 10. What was dropped from v0.5, explicitly

| v0.5 | here | why |
|---|---|---|
| paru engine + `lib/paru.sh` adapter | aurutils, used directly | stable scriptable CLI; no adapter needed |
| multi-repo, profiles, generated contexts | one repo in `/etc/pacman.conf`, one chroot conf in `/etc/aurutils/` | it's one desktop; re-introduce only if a second repo ever materializes |
| provenance state (`git/`, `manual.list`, exclusion set) | `CUSTOM_DIRS` working dirs + built-in ignore file | `aur sync -u` can't touch what isn't in the AUR; only pinned AUR-name packages need ignoring |
| `repo-create` / `repo-pkg` CLI surface | plain aurutils commands + 2 scripts | commands you type twice a month don't need a porcelain |
| export/import snapshots | occasional `aur repo --list > pkglist.txt` if you want one | good enough, zero machinery |
| Devel tracking via paru `devel.json` | `aur srcver` + `aur vercmp` (shipped sync-devel pattern) | same result, no hidden state |
| PKGBUILDs versioned alongside tooling | config-pointed working dirs, unversioned | tooling repo stays machine-independent; package sources are working data |

Kept: staging/publish split, unsigned staging, key off the timer path,
db-as-membership, flock, chroot builds via devtools (+ the scoped sudoers
rules and their root-equivalence caveat), publish algorithm, timer design
(now user-level).
