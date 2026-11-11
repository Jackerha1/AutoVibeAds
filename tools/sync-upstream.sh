#!/bin/bash
# AutoVibe filter sync: mirrors the upstream filter payload, re-signs it with
# our Ed25519 key, deploys it to Cloudflare Pages (autovibe.biz/filters) and
# records the new payload in git. Runs unattended from launchd
# (tools/biz.autovibe.filter-sync.plist) and is safe to run by hand.
#
# Failure model: nothing is swapped into site/filters until the download passes
# validation, nothing is deployed until the manifest is rebuilt and signed, and
# nothing is committed until the live site serves the new manifest
# byte-for-byte. Devices additionally keep their last good payload, so a failed
# sync can never break the app.
set -euo pipefail

export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/opt/node@24/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export GIT_TERMINAL_PROMPT=0 WRANGLER_SEND_METRICS=false

# Cloudflare account for unattended wrangler, which needs a scoped API token
# (not the interactive `wrangler login`) because a launchd job has no terminal.
export CLOUDFLARE_ACCOUNT_ID="dee492a69616e5dd114bebe866c5bc29"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTERS="$REPO/site/filters"
# Signing key and Cloudflare token live in a `keys` directory beside the repo,
# so this runs unchanged from the manual checkout under ~/Documents and from the
# launchd working copy under ~/Library (which macOS lets a background job read).
KEYS_DIR="$(cd "$REPO/.." && pwd)/keys"
KEY="$KEYS_DIR/autovibe-filters-signing.key"
CF_TOKEN_FILE="$KEYS_DIR/cloudflare-pages.token"
UPSTREAM="https://dashtvfilters.everinfinite.co"
LIVE="https://autovibe.biz/filters"
PAGES_PROJECT="autovibe"
# The token is resolved by git at push time, inside single quotes on purpose.
CRED_HELPER='!f() { echo username=Jackerha1; echo "password=$(gh auth token --user Jackerha1)"; }; f'

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
notify() { osascript -e "display notification \"$1\" with title \"AutoVibe filter sync\"" >/dev/null 2>&1 || true; }
fail() { log "FAIL: $1"; notify "$1"; exit 1; }

# A unique query string misses Cloudflare's edge cache (whose max-age on
# /filters is longer than our verify window) and forces a fresh origin read, so
# this reflects what the deploy actually published rather than a stale copy.
live_matches() {
    curl --proto '=https' -fsS --max-time 30 \
        -o "$WORK/live-index.json" "$LIVE/index.json?nocache=$$-$(date +%s)" 2>/dev/null \
        && cmp -s "$WORK/live-index.json" "$FILTERS/index.json"
}

deploy_and_verify() {
    log "deploying site to Cloudflare Pages"
    (cd "$REPO" && wrangler pages deploy site --project-name "$PAGES_PROJECT" \
        --branch main --commit-dirty=true) >"$WORK/deploy.log" 2>&1 \
        || { tail -5 "$WORK/deploy.log" || true; fail "wrangler deploy failed (check the Cloudflare API token)"; }
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if live_matches; then log "live site serves the new manifest"; return 0; fi
        sleep 10
    done
    fail "deployed, but the live manifest is still stale after 2 minutes"
}

# Commits whatever changed under site/filters. Push failure is downgraded to a
# notification because the deploy already succeeded; the next run retries it.
commit_if_dirty() {
    cd "$REPO"
    [ -n "$(git status --porcelain -- site/filters)" ] || return 0
    git add site/filters
    git commit -m "${1:-chore: republish filter payload}" >/dev/null
    if printf 'y\n' | git -c credential.helper= -c "credential.helper=$CRED_HELPER" \
            push origin main >/dev/null 2>&1; then
        log "payload committed and pushed"
    else
        log "git push failed (deploy succeeded); next sync retries the push"
        notify "Payload deployed but git push failed; next sync retries."
    fi
}

LOCKDIR="${TMPDIR:-/tmp}/autovibe-filter-sync.lock"
mkdir "$LOCKDIR" 2>/dev/null || { log "another sync is already running; skipping"; exit 0; }
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; rmdir "$LOCKDIR" 2>/dev/null || true; }
trap cleanup EXIT

[ -f "$KEY" ] || fail "signing key missing at $KEY"
[ -d "$FILTERS" ] || fail "payload directory missing at $FILTERS"
[ -f "$CF_TOKEN_FILE" ] || fail "Cloudflare API token missing at $CF_TOKEN_FILE (see README.md, 'Filter sync')"
CLOUDFLARE_API_TOKEN="$(tr -d ' \t\r\n' < "$CF_TOKEN_FILE")"
export CLOUDFLARE_API_TOKEN
[ -n "$CLOUDFLARE_API_TOKEN" ] || fail "Cloudflare API token file is empty: $CF_TOKEN_FILE"

# Keep this working copy current with the remote without clobbering local edits,
# so the launchd clone and a manual checkout do not drift. Best-effort only.
if [ -z "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    git -C "$REPO" fetch --quiet origin main 2>/dev/null \
        && git -C "$REPO" merge --ff-only --quiet origin/main 2>/dev/null || true
fi

# 1. Upstream manifest. Plain unreachability is the quiet offline case.
if ! curl --proto '=https' -fsS --retry 2 --max-time 60 --max-filesize 65536 \
        -o "$WORK/upstream-index.json" "$UPSTREAM/index.json"; then
    log "upstream unreachable; will retry next interval"
    exit 0
fi

FILES="$(python3 "$REPO/tools/validate-upstream.py" index "$WORK/upstream-index.json")" \
    || fail "upstream manifest failed validation"
UPSTREAM_BUILT="$(python3 -c "import json;print(json.load(open('$WORK/upstream-index.json'))['built'])")"
UPSTREAM_UBLOCK="$(python3 -c "import json;print(json.load(open('$WORK/upstream-index.json')).get('ublock','unknown'))")"

# 2. Download and validate the payload files named by the manifest.
while IFS= read -r f; do
    curl --proto '=https' -fsS --retry 2 --max-time 300 --max-filesize 25165824 \
        -o "$WORK/$f" "$UPSTREAM/$f" || fail "download failed: $f"
done <<< "$FILES"
python3 "$REPO/tools/validate-upstream.py" files "$WORK" "$WORK/upstream-index.json" \
    || fail "downloaded payload failed validation"

# 3. Compare with what we currently publish.
changed=0
while IFS= read -r f; do
    if [ ! -f "$FILTERS/$f" ] || ! cmp -s "$WORK/$f" "$FILTERS/$f"; then changed=1; fi
done <<< "$FILES"
for existing in "$FILTERS"/rules-*.json; do
    [ -e "$existing" ] || continue
    grep -qxF "$(basename "$existing")" <<< "$FILES" || changed=1
done

if [ "$changed" -eq 0 ]; then
    if live_matches; then
        log "up to date (upstream built $UPSTREAM_BUILT); nothing to do"
    else
        log "payload unchanged but live site is stale; redeploying"
        deploy_and_verify
    fi
    commit_if_dirty "chore: sync filter payload (upstream built $UPSTREAM_BUILT, uBlock $UPSTREAM_UBLOCK)"
    exit 0
fi

log "upstream changed (built $UPSTREAM_BUILT, uBlock $UPSTREAM_UBLOCK); updating payload"

# 4. Swap in the new payload; drop rule lists upstream removed.
for existing in "$FILTERS"/rules-*.json; do
    [ -e "$existing" ] || continue
    name="$(basename "$existing")"
    grep -qxF "$name" <<< "$FILES" || { log "removing dropped list $name"; rm "$existing"; }
done
while IFS= read -r f; do
    cp "$WORK/$f" "$FILTERS/$f"
done <<< "$FILES"

# 5. Rebuild the manifest and sign it with our key.
(cd "$FILTERS" && swift "$REPO/tools/build-payload.swift" build "$KEY") \
    || fail "manifest build/sign failed"

deploy_and_verify
commit_if_dirty "chore: sync filter payload (upstream built $UPSTREAM_BUILT, uBlock $UPSTREAM_UBLOCK)"
log "sync complete"
