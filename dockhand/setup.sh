#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dockhand/setup.sh — the Dockhand stack's part of ./setup.sh.
#
# Sourced by ./setup.sh once the base stacks are up, and runnable on its own:
#
#   ./dockhand/setup.sh
#
# It starts Dockhand, restores the baseline a fresh (gitignored) database
# needs, and registers authentik as its OIDC provider. It reads $REPO_DIR,
# $TMP, $DOCKHAND_PORT and authentik/.env the way setup.sh leaves them, and
# leaves AK_USER/AK_PASS behind for the summary setup.sh prints afterwards.
# ---------------------------------------------------------------------------
set -euo pipefail
REPO_DIR=${REPO_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
. "$REPO_DIR/lib/host.sh"
cd "$REPO_DIR"
TMP=${TMP:-$(mktemp -d)}
DOCKHAND_PORT=${DOCKHAND_PORT:-3000}
AK_ENV=${AK_ENV:-authentik/.env}
ROOT_TLD=${ROOT_TLD:-$(env_tld "$REPO_DIR/.env")}
ROOT_TLD=${ROOT_TLD:-smart}

say "Dockhand"
# --force-recreate because a re-cloned checkout is a *new* directory: a running
# container keeps the old mount, which now points at a deleted inode, so it
# would never see the fresh files.
( cd dockhand && docker compose up -d --force-recreate )

printf '    waiting for the API'
any=0
for _ in $(seq 1 40); do
  if curl -fsS -m 3 "http://127.0.0.1:$DOCKHAND_PORT/api/health" >/dev/null 2>&1; then
    any=1
    break
  fi
  printf '.'
  sleep 1
done
printf '\n'
if [ "$any" = 1 ]; then
  note "responding on port $DOCKHAND_PORT"
else
  warn "no answer on port $DOCKHAND_PORT after 40s — check: docker logs dockhand"
fi

# --- Dockhand baseline -------------------------------------------------------
# Dockhand's own database lives in its data directory, which is not in git. A
# fresh clone therefore starts with an empty one: no environment, no configured
# paths. Restore just enough that ./update.sh works and the Import dialog can
# see this checkout — so "clone, ./setup.sh" is all a new box needs, and
# re-cloning while you iterate does not leave you with a dead UI.
#
# Once single sign-on has switched Dockhand's authentication on (below), every
# call needs a token: DH_TOKEN_FILE holds the one this script minted for itself
# and for update.sh. Gitignored, and readable by you only.
DH_TOKEN_FILE="$REPO_DIR/dockhand/.api-token"
DH_TOKEN=$(cat "$DH_TOKEN_FILE" 2>/dev/null || true)

api() {
  local method=$1 path=$2 body=${3:-}
  local auth=()
  [ -n "$DH_TOKEN" ] && auth=(-H "Authorization: Bearer $DH_TOKEN")
  if [ -n "$body" ]; then
    curl -fsS -m 20 -X "$method" "http://127.0.0.1:$DOCKHAND_PORT$path" "${auth[@]}" \
      -H 'Content-Type: application/json' --data-binary "$body"
  else
    curl -fsS -m 20 -X "$method" "http://127.0.0.1:$DOCKHAND_PORT$path" "${auth[@]}"
  fi
}

# The login from authentik/.env, which is also the local Dockhand user.
AK_USER=$(env_var "$AK_ENV" ADMIN_USERNAME)
AK_PASS=$(env_var "$AK_ENV" ADMIN_PASSWORD)

# Dockhand only hands out API tokens to a *session*, and asks a local user
# for their password again when it does — so log in as that user first. JSON
# is built by python from the environment, not by the shell: a password with
# a quote in it stays a password, and it never shows up in `ps`.
mint_dockhand_token() {
  local jar="$TMP/dockhand.cookies" token
  [ -n "$AK_USER" ] && [ -n "$AK_PASS" ] || return 1
  AK_USER=$AK_USER AK_PASS=$AK_PASS python3 -c '
import json, os, sys
u, p = os.environ["AK_USER"], os.environ["AK_PASS"]
json.dump({"username": u, "password": p}, open(sys.argv[1], "w"))
json.dump({"name": "irabelle-stack (setup.sh, update.sh)", "password": p}, open(sys.argv[2], "w"))
' "$TMP/login.json" "$TMP/token-req.json"
  curl -fsS -m 20 -c "$jar" -H 'Content-Type: application/json' \
    --data-binary @"$TMP/login.json" "http://127.0.0.1:$DOCKHAND_PORT/api/auth/login" >/dev/null 2>&1 \
    || return 1
  curl -fsS -m 20 -b "$jar" -H 'Content-Type: application/json' \
    --data-binary @"$TMP/token-req.json" "http://127.0.0.1:$DOCKHAND_PORT/api/auth/tokens" \
    >"$TMP/token.json" 2>/dev/null || return 1
  rm -f "$TMP/login.json" "$TMP/token-req.json" "$jar"
  token=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("token",""))' "$TMP/token.json" 2>/dev/null || true)
  [ -n "$token" ] || return 1
  ( umask 077 && printf '%s\n' "$token" >"$DH_TOKEN_FILE" )
  DH_TOKEN=$token
}

if [ "$any" = 1 ]; then
  # A re-run after authentication was switched on: without a working token
  # every call below would just fail. Get one back if the token file is gone
  # (a re-clone) or was revoked in Dockhand.
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
    ${DH_TOKEN:+-H "Authorization: Bearer $DH_TOKEN"} \
    "http://127.0.0.1:$DOCKHAND_PORT/api/environments" 2>/dev/null || true)
  if [ "$code" = 401 ]; then
    if mint_dockhand_token; then
      note "Dockhand authentication is on — new API token saved to ${DH_TOKEN_FILE#"$REPO_DIR"/}"
    else
      warn "Dockhand authentication is on, and logging in as '${AK_USER:-?}' failed."
      warn "Create an API token in Dockhand (your profile -> API tokens), save it"
      warn "to ${DH_TOKEN_FILE#"$REPO_DIR"/} and re-run — until then the Dockhand steps fail."
    fi
  fi

  say "Dockhand baseline"

  if api GET /api/environments >"$TMP/envs.json" 2>/dev/null; then
    ENV_COUNT=$(python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1]))))
except Exception: print(0)' "$TMP/envs.json")
    if [ "$ENV_COUNT" = 0 ]; then
      ENV_NAME=${DOCKHAND_ENV_NAME:-Irabelle}
      ENV_TZ=$(env_var .env TZ)
      if api POST /api/environments \
           "{\"name\":\"$ENV_NAME\",\"connectionType\":\"socket\",\"socketPath\":\"/var/run/docker.sock\"}" \
           >"$TMP/env.json" 2>/dev/null; then
        note "created the '$ENV_NAME' environment (local Docker socket)"
        ENV_ID=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["id"])
except Exception: pass' "$TMP/env.json" 2>/dev/null || true)
        if [ -n "$ENV_ID" ]; then
          # These are this install's defaults, applied once at first bootstrap
          # only — a later change made in Dockhand's own UI is never overridden
          # by re-running setup.sh, the same as an existing .env is left alone.
          if [ -n "$ENV_TZ" ]; then
            api POST "/api/environments/$ENV_ID/timezone" \
              "{\"timezone\":\"$ENV_TZ\"}" >/dev/null 2>&1 \
              && note "  timezone: $ENV_TZ" \
              || warn "  could not set the environment timezone"
          fi
          api POST "/api/environments/$ENV_ID/update-check" \
            '{"enabled":true,"cron":"0 4 * * *","autoUpdate":true,"vulnerabilityCriteria":"never"}' \
            >/dev/null 2>&1 \
            && note "  scheduled updates: on, applied automatically" \
            || warn "  could not enable scheduled updates"
          api POST "/api/environments/$ENV_ID/image-prune" \
            '{"enabled":true,"cronExpression":"0 3 * * 0","pruneMode":"dangling"}' \
            >/dev/null 2>&1 \
            && note "  automatic image pruning: on" \
            || warn "  could not enable automatic image pruning"
          api POST /api/settings/semver \
            '{"enabled":true,"maxBump":"major","matchFlavor":true,"includePrerelease":false}' \
            >/dev/null 2>&1 \
            && note "  check for newer version tags: on" \
            || warn "  could not enable version-tag checks"
          # useSelfhstIcons is not true by default on a fresh Dockhand install
          # (confirmed on an actual from-scratch run), so it needs setting
          # explicitly, not just defaultTimezone.
          GENERAL_BODY='{"useSelfhstIcons":true'
          [ -n "$ENV_TZ" ] && GENERAL_BODY="$GENERAL_BODY,\"defaultTimezone\":\"$ENV_TZ\""
          GENERAL_BODY="$GENERAL_BODY}"
          api POST /api/settings/general "$GENERAL_BODY" >/dev/null 2>&1 \
            && note "  selfh.st icons: on${ENV_TZ:+; default scheduling timezone: $ENV_TZ}" \
            || warn "  could not update general settings"
        fi
      else
        warn "could not create an environment — add one in Dockhand: Settings -> Environments"
      fi
    else
      note "$ENV_COUNT environment(s) already configured"
    fi
  else
    warn "could not read the environment list from Dockhand"
  fi

  # Make the checkout a place the Import dialog can scan without browsing.
  if api GET /api/settings/general >"$TMP/general.json" 2>/dev/null; then
    PATHS=$(python3 - "$TMP/general.json" "$REPO_DIR" <<'PY'
import json, sys
try:
    cur = json.load(open(sys.argv[1])).get("externalStackPaths") or []
except Exception:
    cur = []
if isinstance(cur, str):
    cur = [p for p in cur.splitlines() if p]
if sys.argv[2] in cur:
    raise SystemExit(0)
cur.append(sys.argv[2])
print(json.dumps(cur))
PY
) || true
    if [ -n "${PATHS:-}" ]; then
      if api POST /api/settings/general "{\"externalStackPaths\":$PATHS}" >/dev/null 2>&1; then
        note "added $REPO_DIR to Dockhand's external stack paths"
      else
        warn "could not add $REPO_DIR to the external stack paths"
      fi
    else
      note "external stack paths already include this checkout"
    fi
  fi

  # Adopt any stack found here right away — otherwise Dockhand only shows raw
  # containers it noticed via the Docker socket ("Untracked"), not the proper
  # *Internal* stacks .env-driven config expects, until update.sh's cron job
  # happens to run (up to 12h later). update.sh does the actual scan+adopt via
  # Dockhand's Import API; --no-pull because this is about registering what's
  # already on disk, not about touching git.
  if [ -x "$REPO_DIR/update.sh" ]; then
    # --no-integrations: this script runs integrations.py itself, after the
    # single sign-on step below, which the OIDC apps need first.
    "$REPO_DIR/update.sh" --no-pull --no-integrations \
      || warn "could not adopt stacks automatically — run it by hand: ./update.sh --no-pull"
  fi

  # --- 6. single sign-on -------------------------------------------------------
  # authentik's side (the admin user, the Dockhand OIDC client) is its
  # blueprint's job; this is Dockhand's side. Each piece is only added when it
  # is missing, so a re-run changes nothing, and a provider or setting you
  # edit in Dockhand's own UI afterward is left alone — the same deal as the
  # baseline above.
  if [ -f "$AK_ENV" ] && [ -n "$ROOT_TLD" ]; then
    say "Single sign-on (authentik)"
    AK_SECRET=$(env_var "$AK_ENV" DOCKHAND_OIDC_CLIENT_SECRET)
    SSO_OK=yes

    if [ -z "$AK_USER" ] || [ -z "$AK_PASS" ] || [ -z "$AK_SECRET" ]; then
      warn "$AK_ENV is missing ADMIN_USERNAME, ADMIN_PASSWORD or"
      warn "DOCKHAND_OIDC_CLIENT_SECRET — Dockhand login left as it is"
      SSO_OK=no
    fi

    # The local Dockhand user: the way in when authentik is down, and what
    # the authentik login attaches to — Dockhand matches an OIDC login to an
    # existing user by name. Dockhand only lets this be created without
    # logging in while authentication is still off.
    if [ "$SSO_OK" = yes ] && api GET /api/users >"$TMP/users.json" 2>/dev/null; then
      if python3 -c 'import json,sys
sys.exit(0 if any(u.get("username")==sys.argv[2] for u in json.load(open(sys.argv[1]))) else 1)' \
           "$TMP/users.json" "$AK_USER"; then
        note "Dockhand user '$AK_USER' exists"
      elif AK_USER=$AK_USER AK_PASS=$AK_PASS python3 -c 'import json,os,sys
json.dump({"username":os.environ["AK_USER"],"password":os.environ["AK_PASS"],"displayName":os.environ["AK_USER"]},open(sys.argv[1],"w"))' \
             "$TMP/user.json" \
           && api POST /api/users @"$TMP/user.json" >/dev/null 2>&1; then
        note "created the Dockhand user '$AK_USER' (same password as authentik)"
      else
        warn "could not create the Dockhand user '$AK_USER' — Dockhand login left as it is"
        SSO_OK=no
      fi
      rm -f "$TMP/user.json"
    elif [ "$SSO_OK" = yes ]; then
      warn "could not read Dockhand's users — Dockhand login left as it is"
      SSO_OK=no
    fi

    # authentik as an OIDC provider. The issuer is authentik's public URL on
    # purpose: the browser is sent there, and the issuer inside the tokens
    # has to match it. Dockhand reaches the same name server-side through
    # Traefik's app-bridge alias, trusting our CA (see dockhand/compose.yml).
    OIDC_ID=
    OIDC_ISSUER="https://authentik.$ROOT_TLD/application/o/dockhand/"
    OIDC_REDIRECT="https://dockhand.$ROOT_TLD/api/auth/oidc/callback"
    if [ "$SSO_OK" = yes ] && api GET /api/auth/oidc >"$TMP/oidc.json" 2>/dev/null; then
      # "id issuer redirect" of the provider this script added, if it is there.
      read -r OIDC_ID OIDC_CUR_ISSUER OIDC_CUR_REDIRECT < <(python3 -c 'import json,sys
for p in json.load(open(sys.argv[1])):
    if p.get("clientId") == "dockhand" and "/application/o/dockhand/" in (p.get("issuerUrl") or ""):
        print(p["id"], p.get("issuerUrl") or "-", p.get("redirectUri") or "-"); break' "$TMP/oidc.json" 2>/dev/null) || true
      if [ -n "$OIDC_ID" ] && [ "$OIDC_CUR_ISSUER" = "$OIDC_ISSUER" ] && [ "$OIDC_CUR_REDIRECT" = "$OIDC_REDIRECT" ]; then
        note "authentik is already an OIDC provider in Dockhand"
      elif [ -n "$OIDC_ID" ]; then
        # The TLD was renamed since: the blueprint follows on its own, this
        # copy of the URLs in Dockhand does not.
        if api PUT "/api/auth/oidc/$OIDC_ID" \
             "{\"issuerUrl\":\"$OIDC_ISSUER\",\"redirectUri\":\"$OIDC_REDIRECT\"}" >/dev/null 2>&1; then
          note "Dockhand's authentik provider: URLs moved to .$ROOT_TLD"
        else
          warn "could not move Dockhand's authentik provider to .$ROOT_TLD — edit it in Dockhand"
        fi
      else
        AK_SECRET=$AK_SECRET OIDC_ISSUER=$OIDC_ISSUER OIDC_REDIRECT=$OIDC_REDIRECT python3 -c 'import json,os,sys
json.dump({
    "name": "authentik",
    "enabled": True,
    "issuerUrl": os.environ["OIDC_ISSUER"],
    "clientId": "dockhand",
    "clientSecret": os.environ["AK_SECRET"],
    "redirectUri": os.environ["OIDC_REDIRECT"],
    "scopes": "openid profile email",
    "usernameClaim": "preferred_username",
    "emailClaim": "email",
    "displayNameClaim": "name",
}, open(sys.argv[1], "w"))' "$TMP/oidc-new.json"
        if api POST /api/auth/oidc @"$TMP/oidc-new.json" >"$TMP/oidc-created.json" 2>/dev/null; then
          OIDC_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$TMP/oidc-created.json" 2>/dev/null || true)
          note "added authentik as Dockhand's OIDC provider (https://authentik.$ROOT_TLD)"
        else
          warn "could not add authentik as an OIDC provider in Dockhand"
        fi
        rm -f "$TMP/oidc-new.json"
      fi
    fi

    # Authentication on, with authentik as the default button on the login
    # page. Then the token for update.sh — Dockhand only issues those once
    # authentication is on.
    if [ "$SSO_OK" = yes ] && api GET /api/auth/settings >"$TMP/auth.json" 2>/dev/null; then
      if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("authEnabled") else 1)' "$TMP/auth.json"; then
        note "Dockhand authentication is already on"
      else
        AUTH_BODY='{"authEnabled":true'
        [ -n "$OIDC_ID" ] && AUTH_BODY="$AUTH_BODY,\"defaultProvider\":\"oidc:$OIDC_ID\""
        AUTH_BODY="$AUTH_BODY}"
        if api PUT /api/auth/settings "$AUTH_BODY" >/dev/null 2>&1; then
          note "Dockhand authentication: on${OIDC_ID:+ (authentik is the default login)}"
        else
          warn "could not switch Dockhand authentication on"
          SSO_OK=no
        fi
      fi
    fi
    if [ "$SSO_OK" = yes ] && [ -z "$DH_TOKEN" ]; then
      if mint_dockhand_token; then
        note "API token for update.sh saved to ${DH_TOKEN_FILE#"$REPO_DIR"/}"
      else
        warn "could not create an API token — update.sh cannot reach Dockhand until"
        warn "one is saved to ${DH_TOKEN_FILE#"$REPO_DIR"/} (your profile -> API tokens)"
      fi
    fi

    # Dockhand can only *check* the provider once authentik is up and its
    # certificate issued — both of which take a minute on a fresh install. A
    # failure here is expected then; it is not a failed setup.
    if [ -n "$OIDC_ID" ]; then
      printf '    waiting for authentik'
      for _ in $(seq 1 36); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' authentik 2>/dev/null)" = healthy ] && break
        printf '.'
        sleep 5
      done
      printf '\n'
      # Issue authentik.$TLD's certificate now instead of waiting for the
      # watcher, which is only (re)started further down.
      "$REPO_DIR/traefik/generate_certificates/cert-watcher.sh" --once >/dev/null 2>&1 || true
      # Asked from inside the dockhand container, with Node's own fetch: the
      # same DNS, CA and TLS stack Dockhand's login uses. (Dockhand's own
      # "Test" button wants a browser session, not the API token.)
      if OIDC_ERR=$(docker exec dockhand node -e '
fetch(process.argv[1])
  .then(r => r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status)))
  .then(d => { if (!d.issuer) throw new Error("no issuer in the discovery document"); })
  .catch(e => { console.log((e.cause && (e.cause.code || e.cause.message)) || e.message); process.exit(1); })' \
           "https://authentik.$ROOT_TLD/application/o/dockhand/.well-known/openid-configuration" 2>&1); then
        note "Dockhand reaches authentik: sign-in with authentik works"
      else
        # The reason matters: ENOTFOUND/EAI_AGAIN is DNS, a certificate code
        # (UNABLE_TO_VERIFY_LEAF_SIGNATURE, ...) is the CA or a cert not yet
        # issued, HTTP 404 is authentik still starting or its router missing.
        note "Dockhand cannot reach authentik yet (${OIDC_ERR:-no answer}) — normal on"
        note "a first run, until authentik has started and https://authentik.$ROOT_TLD"
        note "has its certificate."
        note "Dockhand's authentication settings can re-run the check (Test) later."
        note "The local login ($AK_USER) works in the meantime."
      fi
    fi
  fi
fi
