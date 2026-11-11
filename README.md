# AutoVibeAds

Self-hosted website and content-blocker filter source for the AutoVibe iOS app.

The `site/` folder is deployed to **Cloudflare Pages** (project `autovibe`) and
served at **`https://autovibe.biz`**:

| Path | Purpose |
|---|---|
| `/` `/support/` `/privacy/` | Marketing landing page plus the App Store Support and Privacy Policy URLs |
| `/filters/` | The signed filter payload the app downloads |
| `/assets/`, `_headers` | Static assets and HTTP headers (strict CSP, 5-minute cache on `/filters/`) |

The root-level `rules-*.json` / `index.json` are a legacy copy from the original
GitHub Pages host (`jackerha1.github.io/AutoVibeAds`), kept only as a fallback
until the custom domain is verified end-to-end on device. The canonical payload
is `site/filters/`.

## Filter payload

| File (under `site/filters/`) | Purpose |
|---|---|
| `index.json` | Signed manifest: rule list files, scriptlets file, `built` timestamp (monotonic, anti-rollback), per-file rule `counts` and `sha256` |
| `index.json.sig` | Ed25519 signature (base64) over the exact bytes of `index.json` |
| `rules-*.json` | WebKit content-blocker rule lists (JSON arrays) |
| `scriptlets.json` | JSON object `host → javascript`, injected per-site by the app |

The app pins this host, verifies the signature against an embedded public key
(`St3ONGRN0D73/hNxYFll3Xxe4l+j8P95GhPKzLxaZLI=`), rejects any payload whose
`built` is older than the one it already has, checks every file against its
`sha256`, and lets WebKit's rule compiler validate rule content. Lists removed
from the manifest are removed from the app's rule store on the next update.

The private signing key lives **outside this repository** at
`~/Documents/build_app/car-video/keys/autovibe-filters-signing.key` and must
never be committed. Losing it means shipping a new app build with a new public
key; leaking it means anyone can sign payloads, so rotate immediately if that
happens.

## Filter sync (automated, every 7 hours)

`tools/sync-upstream.sh` mirrors the upstream filter source, re-signs the
payload with our own key, deploys it, and records it in git. It is driven by the
launchd agent `tools/biz.autovibe.filter-sync.plist`.

What one run does, in order, stopping safely at the first failure:

1. Fetch and validate the upstream manifest (`tools/validate-upstream.py`:
   size caps, file-name charset, no path traversal, ≤16 lists).
2. Download the rule lists and `scriptlets.json`, and validate their shapes and
   size caps the same way the app does.
3. If nothing changed from what we publish, redeploy only when the live site is
   stale, otherwise stop.
4. Swap the new files into `site/filters/`, dropping any list upstream removed.
5. Rebuild and re-sign `index.json` with our key (`build-payload.swift`).
6. Deploy `site/` to Cloudflare Pages and poll `https://autovibe.biz/filters/index.json`
   until it serves the new manifest byte-for-byte.
7. Commit and push the changed payload to this repo.

Nothing is deployed until the download passes validation, and nothing is
committed until the live site confirms the new manifest. A failed sync leaves
the published payload untouched, and devices keep their last good payload
regardless, so a bad or missing upstream can never break the app.

### One-time setup

Unattended `wrangler` has no terminal, so it cannot use the interactive
`wrangler login` token — it needs a scoped **API token**:

1. Cloudflare dashboard → **My Profile → API Tokens → Create Token → Create
   Custom Token**.
2. Permission: **Account → Cloudflare Pages → Edit** (nothing else). Scope it to
   the one account.
3. Save the token string to
   `~/Documents/build_app/car-video/keys/cloudflare-pages.token`
   (`chmod 600`, outside every repo, like the signing key).

Install / control the schedule:

```sh
cp tools/biz.autovibe.filter-sync.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/biz.autovibe.filter-sync.plist
launchctl kickstart -k gui/$(id -u)/biz.autovibe.filter-sync   # run once now
launchctl bootout gui/$(id -u)/biz.autovibe.filter-sync        # stop the schedule
```

Logs: `~/Library/Logs/autovibe-filter-sync.log`. Run by hand any time with
`bash tools/sync-upstream.sh`.

## Provenance

Rule lists are converted from Brave's content-blocking lists (which derive from
EasyList/EasyPrivacy and related community lists); scriptlets are uBlock Origin
scriptlets assembled per host. Those upstream projects are licensed under
GPLv3 / CC BY-SA and this repository redistributes their converted output.
