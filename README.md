# AutoVibeAds

Self-hosted content-blocker filter source for the AutoVibe iOS app, served via
GitHub Pages at `https://jackerha1.github.io/AutoVibeAds/`.

## Layout

| File | Purpose |
|---|---|
| `index.json` | Signed manifest: rule list files, scriptlets file, `built` timestamp (monotonic, anti-rollback), per-file rule `counts` and `sha256` |
| `index.json.sig` | Ed25519 signature (base64) over the exact bytes of `index.json` |
| `rules-*.json` | WebKit content-blocker rule lists (JSON arrays) |
| `scriptlets.json` | JSON object `host → javascript`, injected per-site by the app |
| `tools/build-payload.swift` | Rebuilds and re-signs the manifest after editing payload files |

The app pins this host, verifies the signature against an embedded public key
(`St3ONGRN0D73/hNxYFll3Xxe4l+j8P95GhPKzLxaZLI=`), rejects any payload whose
`built` is older than the one it already has, checks every file against its
`sha256`, and lets WebKit's rule compiler validate rule content. Lists removed
from the manifest are removed from the app's rule store on the next update.

## Updating the payload

1. Edit or replace `rules-*.json` / `scriptlets.json`.
2. From the repo root: `swift tools/build-payload.swift build <private-key-file>`
3. Commit and push. Pages serves the new build within a few minutes.

The private signing key lives **outside this repository** and must never be
committed. Losing it means shipping a new app build with a new public key;
leaking it means anyone can sign payloads, so rotate immediately if that happens.

## Provenance

Rule lists are converted from Brave's content-blocking lists (which derive from
EasyList/EasyPrivacy and related community lists); scriptlets are uBlock Origin
scriptlets assembled per host. Those upstream projects are licensed under
GPLv3 / CC BY-SA and this repository redistributes their converted output.
