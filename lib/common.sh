# shellcheck shell=bash
# Shared helpers for pkgs-* scripts. Sourced, never executed.
#
# Provides: logging (msg/warn/die), config loading (pkgs_load_conf,
# pkgs_require), staging lock (pkgs_lock), failure aggregation
# (pkgs_fail/pkgs_fail_report), and repo path helpers (pkgs_db).

# Script name used to prefix every diagnostic. Callers may override.
: "${PKGS_PROG:=${0##*/}}"

msg() { printf '%s: %s\n' "$PKGS_PROG" "$*" >&2; }
warn() { printf '%s: warning: %s\n' "$PKGS_PROG" "$*" >&2; }
die() {
    printf '%s: %s\n' "$PKGS_PROG" "$*" >&2
    exit 1
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
        flock -n 9 || exit 0
    else
        flock 9 || die "cannot acquire lock: $STAGING_DIR/.lock"
    fi
}

# Failure aggregation: never die on the first broken package.
PKGS_FAILURES=()
pkgs_fail() {
    PKGS_FAILURES+=("$1")
    warn "$1"
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
