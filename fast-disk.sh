#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fast-disk.sh — keep every stack's config/ (its settings and databases) on a
# faster disk than the one this checkout is on, at the same paths.
#
#   sudo ./fast-disk.sh apply DIR   move each <stack>/config onto DIR and
#                                   bind-mount it back in place (setup.sh
#                                   does this when you pick a disk there)
#   ./fast-disk.sh status           where each <stack>/config lives now
#   sudo ./fast-disk.sh release     undo: copy everything back into the
#                                   checkout and remove the mounts
#
# Why: a checkout on a big, slow disk (a USB or SMR drive, typically, which is
# where the media wants to be) makes every database here wait on that disk —
# Home Assistant's history, Plex, the *arrs, Pi-hole. Their config/ folders are
# small; the media in downloads/ is not, and it stays where it is.
#
# How: DIR/<stack>/config holds the data, and is bind-mounted over
# <checkout>/<stack>/config — so every path, in compose files and in your
# shell, stays exactly as it was. Each mount is in /etc/fstab, and Docker is
# made to wait for all of them at boot, so no container ever starts against
# the stale copy underneath.
#
# `apply` is safe to re-run, and only touches a stack whose config/ is not on
# DIR yet (a stack added since, say). The copy underneath the mount is left as
# it was at the moment of the move: `release` brings everything back up to
# date first, so the checkout is self-contained again — do that before you
# delete or re-clone it, or `rm -rf` would reach through into DIR.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Overridable for testing only.
FSTAB=${IRABELLE_FSTAB:-/etc/fstab}
DROPIN=${IRABELLE_DROPIN:-/etc/systemd/system/docker.service.d/irabelle-stack-fast-disk.conf}
TAG="# irabelle-stack fast-disk: $REPO_DIR"

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '4,11p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# Every stack's config/, as it would be listed by setup.sh: any directory here
# with a compose.yml.
targets() {
  local d
  for d in "$REPO_DIR"/*/; do
    d=${d%/}
    [ -f "$d/compose.yml" ] && [ -d "$d/config" ] && printf '%s\n' "$d/config"
  done
}

is_mount() { findmnt -rn --mountpoint "$1" >/dev/null 2>&1; }

# rsync exit 24 = files vanished mid-copy: a live database's -wal/-shm files.
# Harmless in the first, live pass; the second runs with the apps stopped.
copy() {
  local rc=0
  rsync -aHAX --numeric-ids --delete "$1/" "$2/" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 24 ] || die "rsync failed ($rc) copying $1"
}

# Running containers that use anything at, inside or above one of the given
# paths (above: Dockhand mounts the whole checkout). They are stopped while
# the data moves, and started again after: docker resolves bind sources at
# container start, so that is also what makes them see the new mounts.
users_of() {
  local c src t
  command -v docker >/dev/null 2>&1 || return 0
  for c in $(docker ps -q 2>/dev/null); do
    for src in $(docker inspect "$c" -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}'); do
      src=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")
      for t in "$@"; do
        case "$src/" in "$t/"*) ;; *) case "$t/" in "$src/"*) ;; *) continue ;; esac ;; esac
        docker inspect "$c" -f '{{.Name}}' | sed 's#^/##'
        continue 3
      done
    done
  done | sort -u
}

mount_of() { findmnt -rn -o TARGET --target "$1" | head -n1; }

write_dropin() {
  local list
  list=$({ grep -F "$TAG" "$FSTAB" 2>/dev/null || true; } | awk '{print $2}' | tr '\n' ' ')
  if [ -z "$list" ]; then
    rm -f "$DROPIN"
  else
    mkdir -p "$(dirname "$DROPIN")"
    printf '[Unit]\n# Written by %s: never start containers against the stale\n# copy underneath these fast-disk mounts.\nRequiresMountsFor=%s\n' \
      "$REPO_DIR/fast-disk.sh" "$list" >"$DROPIN"
  fi
  [ -n "${IRABELLE_NO_SYSTEMCTL:-}" ] || systemctl daemon-reload
}

cmd_status() {
  local t where
  while IFS= read -r t; do
    if is_mount "$t"; then
      where=$(findmnt -rn -o SOURCE --mountpoint "$t")
    else
      where="in the checkout ($(findmnt -rn -o SOURCE --target "$t" | head -n1))"
    fi
    printf '    %-24s %s\n' "${t#"$REPO_DIR"/}" "$where"
  done < <(targets)
}

cmd_apply() {
  local dir=${1:-}
  [ -n "$dir" ] || die "usage: sudo $0 apply DIR"
  [ "$(id -u)" = 0 ] || die "run it with sudo"
  command -v rsync >/dev/null 2>&1 || die "rsync is required (sudo apt install rsync)"
  local owner
  owner=$(stat -c '%u:%g' "$REPO_DIR")
  mkdir -p "$dir"
  dir=$(CDPATH= cd -- "$dir" && pwd)
  case "$dir/" in "$REPO_DIR/"*) die "$dir is inside the checkout — pick a directory on the other disk" ;; esac
  chown "$owner" "$dir"

  local pending=() t
  while IFS= read -r t; do
    is_mount "$t" && continue
    pending+=("$t")
  done < <(targets)
  if [ ${#pending[@]} -eq 0 ]; then
    note "every stack's config/ is already on $dir"
    write_dropin
    return 0
  fi

  local need free
  need=$(du -sk "${pending[@]}" | awk '{s+=$1} END{print s+0}')
  free=$(df -Pk "$dir" | awk 'NR==2{print $4}')
  note "to move: $((need / 1024)) MB, $((free / 1024 / 1024)) GB free on $dir"
  # Keep 5 GB spare: a full disk is worse for a database than a slow one.
  [ $((free - need)) -gt $((5 * 1024 * 1024)) ] || die "not enough room on $dir (keeping 5 GB spare)"

  # Pass 1, live: the slow part, while everything keeps running.
  for t in "${pending[@]}"; do
    local dst="$dir/${t#"$REPO_DIR"/}"
    mkdir -p "$dst"
    copy "$t" "$dst"
  done

  # Pass 2: one short stop for everything affected, then the switch.
  local users=()
  mapfile -t users < <(users_of "${pending[@]}")
  [ ${#users[@]} -eq 0 ] || { note "stopping: ${users[*]}"; docker stop "${users[@]}" >/dev/null; }
  local opts
  opts="bind,nofail,x-systemd.requires-mounts-for=$(mount_of "$dir"),x-systemd.requires-mounts-for=$(mount_of "$REPO_DIR")"
  for t in "${pending[@]}"; do
    local dst="$dir/${t#"$REPO_DIR"/}"
    copy "$t" "$dst"
    mount --bind "$dst" "$t"
    grep -qF " $t none " "$FSTAB" 2>/dev/null \
      || printf '%s %s none %s 0 0 %s\n' "$dst" "$t" "$opts" "$TAG" >>"$FSTAB"
    note "${t#"$REPO_DIR"/} -> $dst"
  done
  write_dropin
  [ ${#users[@]} -eq 0 ] || { docker start "${users[@]}" >/dev/null; note "started again: ${users[*]}"; }
}

cmd_release() {
  [ "$(id -u)" = 0 ] || die "run it with sudo"
  local mounted=() t
  while IFS= read -r t; do is_mount "$t" && mounted+=("$t"); done < <(targets)
  if [ ${#mounted[@]} -eq 0 ]; then note "nothing is on a fast disk"; else
    local users=() src
    mapfile -t users < <(users_of "${mounted[@]}")
    [ ${#users[@]} -eq 0 ] || { note "stopping: ${users[*]}"; docker stop "${users[@]}" >/dev/null; }
    for t in "${mounted[@]}"; do
      src=$(findmnt -rn -o SOURCE --mountpoint "$t")
      # The fast copy, seen through a second bind mount, so the checkout's own
      # copy underneath can be brought up to date once the mount is gone.
      local tmp
      tmp=$(mktemp -d)
      mount --bind "$t" "$tmp"
      umount "$t"
      copy "$tmp" "$t"
      umount "$tmp" && rmdir "$tmp"
      note "${t#"$REPO_DIR"/}: back in the checkout (the copy on the fast disk is kept)"
    done
    [ ${#users[@]} -eq 0 ] || { docker start "${users[@]}" >/dev/null; note "started again: ${users[*]}"; }
  fi
  if [ -f "$FSTAB" ]; then
    grep -vF "$TAG" "$FSTAB" >"$FSTAB.irabelle.tmp" || true
    cat "$FSTAB.irabelle.tmp" >"$FSTAB" && rm -f "$FSTAB.irabelle.tmp"
  fi
  write_dropin
  note "fstab and the Docker boot-order drop-in are cleaned up"
}

case "${1:-}" in
  apply)   shift; cmd_apply "$@" ;;
  status)  cmd_status ;;
  release) cmd_release ;;
  -h|--help|"") usage 0 ;;
  *) usage 2 ;;
esac
