#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dsh/setup.sh — the DeepSeek Harness stack's part of ./setup.sh.
#
# Sourced by ./setup.sh, and runnable on its own:
#
#   ./dsh/setup.sh          asks (or reads DSH_INSTALL from host.env)
#   ./setup.sh --dsh        answer yes without being asked
#
# Installing dsh is opt-in: it is a host systemd *user* service rather than a
# container, and it needs Node.js, so this asks once and remembers the answer
# in host.env. dsh/install.sh does the actual work, and dsh/uninstall.sh undoes
# it. Removing the dsh/ directory removes the question with it.
# ---------------------------------------------------------------------------
set -euo pipefail
REPO_DIR=${REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
. "$REPO_DIR/lib/host.sh"
cd "$REPO_DIR"
DSH_OPT=${DSH_OPT:-}
ROOT_TLD=${ROOT_TLD:-$(env_tld "$REPO_DIR/.env")}
ROOT_TLD=${ROOT_TLD:-smart}
TMP=${TMP:-$(mktemp -d)}

# dsh is deliberately not a container: `dsh web` refuses to bind anything but
# loopback, so dsh/install.sh runs a systemd *user* service whose bridge Traefik
# dials through host.docker.internal, and renders the dsh.$TLD route into
# Traefik's file provider. Its authentik login is a forward-auth provider in the
# blueprint, applied with the rest of authentik above. It needs Node.js on this
# host; without it install.sh explains what to install and exits, which must not
# fail the rest of setup.
#
# It is opt-in. A container costs this host nothing to skip; a user service and
# a Node.js dependency are a real choice, so setup.sh asks once and keeps the
# answer in host.env (--dsh / --no-dsh set it without asking). An install that
# already exists is simply refreshed — and update.sh only ever refreshes, never
# creates, so nothing installs dsh behind your back.
DSH_UNIT="$HOME/.config/systemd/user/dsh-web.service"
[ -n "$DSH_OPT" ] && host_env_set DSH_INSTALL "$DSH_OPT"
DSH_INSTALL=$(host_env_get DSH_INSTALL)

dsh_install=no
case "$DSH_INSTALL" in
  yes)
    dsh_install=yes
    note "DeepSeek Harness: installing (DSH_INSTALL=yes in host.env)"
    ;;
  no)
    note "DeepSeek Harness: skipped (DSH_INSTALL=no in host.env) — ./setup.sh --dsh adds it"
    ;;
  *)
    if [ -f "$DSH_UNIT" ]; then
      dsh_install=yes
      note "DeepSeek Harness: already installed — refreshing"
    elif [ -t 0 ]; then
      dsh_answer=
      while :; do
        read -r -p "    also install the DeepSeek Harness at dsh.${ROOT_TLD:-smart}? [y/N] " dsh_answer || true
        case "${dsh_answer:-}" in
          ""|[nN]|[nN][oO]) dsh_install=no; break ;;
          [yY]|[yY][eE][sS]) dsh_install=yes; break ;;
          *) warn "answer y or n" ;;
        esac
      done
      host_env_set DSH_INSTALL "$dsh_install"
      if [ "$dsh_install" = no ]; then
        note "DeepSeek Harness: not installed — ./setup.sh --dsh adds it later"
      fi
    else
      note "no terminal to ask on — the DeepSeek Harness is skipped"
      note "add it with ./setup.sh --dsh (or ./dsh/install.sh)"
    fi
    ;;
esac

if [ -x "$REPO_DIR/dsh/install.sh" ] && [ "$dsh_install" = yes ]; then
  "$REPO_DIR/dsh/install.sh" \
    || warn "dsh is not fully set up — see the message above, then: ./dsh/install.sh"
fi
