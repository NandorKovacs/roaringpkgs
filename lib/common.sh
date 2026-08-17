# shellcheck shell=bash
# Shared helpers for pkgs-* scripts. Sourced, never executed.
#
# Provides: logging (msg/warn/die), the audit log (pkgs_log_open/pkgs_log/
# pkgs_log_run), config loading (pkgs_load_conf, pkgs_require), staging lock
# (pkgs_lock), failure aggregation (pkgs_fail/pkgs_fail_report), and repo
# path helpers (pkgs_db, pkgs_pkgid).

# Script name used to prefix every diagnostic. Callers may override.
: "${PKGS_PROG:=${0##*/}}"

msg() { printf '%s: %s\n' "$PKGS_PROG" "$*" >&2; }
warn() { printf '%s: warning: %s\n' "$PKGS_PROG" "$*" >&2; }
die() {
    printf '%s: %s\n' "$PKGS_PROG" "$*" >&2
    exit 1
}

# --- Audit log ---------------------------------------------------------
#
# A durable, append-only record of every mutating action, in pacman's own
# log format (/var/log/pacman.log):
#
#   [2026-08-17T22:04:02+0000] [pkgs-publish] Running 'pkgs-publish' as nandor
#   [2026-08-17T22:04:11+0000] [pkgs-publish] signed foo (1.2.3-1)
#   [2026-08-17T22:04:18+0000] [pkgs-publish] transaction completed (...)
#
# Attribution follows pacman as well: one "Running" line per run, then plain
# action lines — a change is attributed by scanning back to the nearest
# header. pacman itself never needs this (it only ever runs as root); we have
# two accounts writing one file.
#
# This is the "what changed" channel and is deliberately separate from the
# diagnostic one: build output still goes to stderr, and for the timer, on
# to the journal.
#
# An empty PKGS_LOG means logging is off, which makes every helper below a
# no-op. That is how the -n dry-run paths stay silent without a conditional
# at each call site, and how a log that cannot be written degrades instead of
# taking the run down with it.
PKGS_LOG=

# pkgs_log_open — resolve LOG_FILE and make sure we can append to it.
#
# Best effort by design: a log that cannot be written must never abort a
# build (the timer has to be safe unattended), so every failure path here
# warns once and leaves PKGS_LOG empty. Under `set -e` a non-zero return
# would kill the caller, so this always returns 0.
#
# The file is created 0664 explicitly rather than left to the umask. Both
# accounts append to it and whichever runs first owns it: your login's usual
# umask 022 would otherwise leave a 0644 file that the timer cannot write,
# and it would fail silently, because logging never fails loudly.
pkgs_log_open() {
    local f=${LOG_FILE-}
    if [[ -z $f ]]; then
        if [[ -z ${STAGING_DIR-} ]]; then
            warn "neither LOG_FILE nor STAGING_DIR is set; continuing without an audit log"
            return 0
        fi
        f=$STAGING_DIR/pkgs.log
    fi

    if [[ ! -e $f ]]; then
        # 2>/dev/null comes first: redirections are applied left to right, so
        # the other order lets the shell's own "No such file or directory"
        # reach the real stderr before it is silenced.
        if : 2>/dev/null >"$f"; then
            chmod 0664 "$f" 2>/dev/null || true
        else
            warn "cannot create audit log, continuing without it: $f"
            return 0
        fi
    fi

    if [[ ! -w $f ]]; then
        warn "audit log is not writable, continuing without it: $f"
        return 0
    fi

    PKGS_LOG=$f
    return 0
}

# pkgs_log MESSAGE... — append one record. Never fatal.
pkgs_log() {
    [[ -n $PKGS_LOG ]] || return 0
    local ts
    # Bash's own strftime: no fork per line, and it produces the same
    # ISO-8601-with-numeric-offset stamp pacman writes.
    printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
    # 2>/dev/null first, so a failing append is reported by us and not by the
    # shell (redirections are applied left to right).
    if ! printf '[%s] [%s] %s\n' "$ts" "$PKGS_PROG" "$*" 2>/dev/null >>"$PKGS_LOG"; then
        warn "audit log write failed, continuing without it: $PKGS_LOG"
        PKGS_LOG=
    fi
    return 0
}

# pkgs_log_run ARGV... — pacman's "Running '...'" header line, plus the
# account, which pacman has no reason to record and we do.
pkgs_log_run() {
    pkgs_log "Running '$PKGS_PROG${*:+ $*}' as $(id -un)"
}

# pkgs_load_conf — source the machine config. All paths come from here.
#
# Lookup order: $PKGS_CONF, the calling account's own config dir, then the
# system config. The system path is what lets one config serve two
# accounts: pkgs-sync runs as the dedicated build user (timer), while
# pkgs-publish runs as you, and both must agree on REPO_NAME/STAGING_DIR.
# A per-user file still wins, so a throwaway test config needs no root.
pkgs_load_conf() {
    local conf candidates
    if [[ -n ${PKGS_CONF-} ]]; then
        candidates=("$PKGS_CONF")
    else
        candidates=("${XDG_CONFIG_HOME:-${HOME-}/.config}/pkgs/pkgs.conf" /etc/pkgs/pkgs.conf)
    fi
    for conf in "${candidates[@]}"; do
        [[ -f $conf ]] || continue
        # shellcheck disable=SC1090
        . "$conf" || die "failed to source config: $conf"
        PKGS_CONF_PATH=$conf
        return 0
    done
    die "config not found: ${candidates[*]}"
}

# pkgs_require VAR... — fail unless each named variable is set and non-empty.
# Array variables count as set when they have at least one element.
pkgs_require() {
    local var decl
    for var in "$@"; do
        decl=$(declare -p "$var" 2>/dev/null) \
            || die "$var is not set in ${PKGS_CONF_PATH:-config}"
        local -n ref=$var
        if [[ $decl == 'declare -a'* || $decl == 'declare -A'* ]]; then
            ((${#ref[@]})) || die "$var is empty in ${PKGS_CONF_PATH:-config}"
        else
            [[ -n $ref ]] || die "$var is empty in ${PKGS_CONF_PATH:-config}"
        fi
        unset -n ref
    done
}

# pkgs_db — path to the staging repo database.
pkgs_db() { printf '%s/%s.db.tar.gz\n' "$STAGING_DIR" "$REPO_NAME"; }

# pkgs_pkgid FILENAME — "name (version-rel)" for an audit log line, or the
# filename unchanged if it does not parse.
#
# A package file is NAME-VERSION-REL-ARCH.pkg.tar.EXT and none of VERSION,
# REL or ARCH may contain a hyphen, so matching greedily from the left
# assigns the longest possible NAME — the only correct reading, since
# "foo-bar-1.0-1-any" is package foo-bar and never package foo. REL is
# digit-led (pkgrel is a number); VERSION is not, because VCS packages carry
# versions like "r120.abcdef1". pkgs-prune repeats this reading inline
# because it needs the components separately, not a display string.
pkgs_pkgid() {
    local stem=${1##*/}
    stem=${stem%.pkg.tar.*}
    if [[ $stem =~ ^(.+)-([^-]+)-([0-9][^-]*)-([^-]+)$ ]]; then
        printf '%s (%s-%s)\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    else
        printf '%s\n' "${1##*/}"
    fi
}

# pkgs_lock [-n] — serialize mutating operations on the staging dir.
# -n: non-blocking; exit 0 (silently) if another run holds the lock.
# The lock fd (9) stays open for the lifetime of the process.
#
# An existing lock file is opened read-only: the staging repo belongs to the
# build user, pkgs-publish runs as you, and flock(2) needs no write access.
# Opening it for writing would make the publish path depend on the lock
# file's mode, which nothing else here depends on.
pkgs_lock() {
    local nonblock=0
    [[ ${1-} == -n ]] && nonblock=1
    [[ -d $STAGING_DIR ]] || die "staging dir does not exist: $STAGING_DIR"
    if [[ -e $STAGING_DIR/.lock ]]; then
        exec 9<"$STAGING_DIR/.lock" || die "cannot open lock: $STAGING_DIR/.lock"
    else
        exec 9>"$STAGING_DIR/.lock" || die "cannot create lock: $STAGING_DIR/.lock"
    fi
    if ((nonblock)); then
        # A skipped timer tick is otherwise invisible: the unit runs, does
        # nothing, and says nothing. Record it so a run missing from the
        # audit log means a genuine failure, not a collision with a manual
        # publish. No-op when the caller has not opened the log.
        flock -n 9 || {
            pkgs_log "skipped (staging lock held)"
            exit 0
        }
    else
        flock 9 || die "cannot acquire lock: $STAGING_DIR/.lock"
    fi
}

# Failure aggregation: never die on the first broken package.
PKGS_FAILURES=()
pkgs_fail() {
    PKGS_FAILURES+=("$1")
    warn "$1"
    # Routing every failure through here puts all four scripts' failures in
    # the audit log without a call site of their own.
    pkgs_log "warning: $1"
}

# pkgs_fail_report — print collected failures; return 1 if any.
pkgs_fail_report() {
    ((${#PKGS_FAILURES[@]})) || return 0
    local f
    msg "${#PKGS_FAILURES[@]} failure(s):"
    for f in "${PKGS_FAILURES[@]}"; do
        printf '%s:   %s\n' "$PKGS_PROG" "$f" >&2
    done
    return 1
}

# pkgs_need_staging_write — fail early unless this account may write the
# staging repo. Ownership is the build user's; your login gets there through
# the shared group. Without this check a wrong-account run dies somewhere
# deep inside aurutils or repo-remove instead of on line one.
pkgs_need_staging_write() {
    [[ -w $STAGING_DIR ]] \
        || die "$STAGING_DIR is not writable by $(id -un): run this as the build user (see README)"
}

# pkgs_need_cmd CMD... — fail unless each command is on PATH.
pkgs_need_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null || die "required command not found: $c"
    done
}
