# sites-cli

Drive a GXB tenant site from the shell. Three surfaces in one binary:

1. **Runner commands** (`list`/`show`/`open`/`create`) -- `bin/rails runner` in
   `SITES_ROOT`, or `kamal-cli runner` with `--prod`. Staff credentials.
2. **v2 tools** for versioned sites (`plans/30-agent-first-sites.md` in
   `~/projects/sites`). Each subcommand posts the same-named MCP tool to
   `POST /api/v1/tools` with the site token and prints the raw `{ok, data}`
   envelope. The shell is the transport, not a second contract.
3. **Legacy file tools** for sites still on the file API
   (`plans/24-agent-sites.md`). Unchanged.

Two tools have no site to be bound to, so they have their own door and their
own credential: `list_sites` and `create_site` post to
`POST /api/v1/platform/tools` with a **personal token** (`sk_user_...`, minted
at `https://sites.gxb.vc/profile`, GXB staff only). A site token there is a 403.

A site is on exactly one contract. Calling the other one's write tool is a 409
naming the tool to use instead (`upgrade_required` / `not_versioned`).

## Subcommand -> tool -> capability

| Subcommand | MCP tool | Capability | Contract |
|---|---|---|---|
| `describe SLUG [PATH] [--branch B]` | `describe_site` | `read` | both (the server answers in the site's own shape) |
| `read SLUG KIND [KEY]` | `read` | `read` | v2 |
| `read SLUG asset --keys a,b` | `read` (batch `{key => digest}`) | `read` | v2 |
| `save SLUG --changes FILE` | `save` | `draft` | v2 |
| `create-branch SLUG NAME` | `create_branch` | `draft` | v2 |
| `archive-branch SLUG NAME` | `archive_branch` | `draft` | v2 |
| `diff SLUG` | `diff` | `read` | v2 |
| `publish SLUG --review T\|last` | `publish` | `publish` | v2 |
| `publish SLUG --expected T --keys ...` | `publish` | `publish` | v2 |
| `merge-live SLUG --expected-live ID` | `merge_live` | `draft` | v2 |
| `resolve-merge SLUG --proposal T` | `resolve_merge` | `draft` | v2 |
| `history SLUG` | `history` | `read` | v2 |
| `revoke-preview SLUG URL_OR_TOKEN` | `revoke_preview` | `draft` | v2 |
| `wait-preview SLUG` | `describe_site` (polled) | `read` | v2 |
| `list-submissions SLUG` | `list_submissions` | `read_submissions` | both |
| `analytics SLUG` | `get_analytics` | `read` | both |
| `list-sites` | `list_sites` (platform door) | `read` | platform |
| `list-sites SLUG` | `list_sites` (site door) | `read` | both |
| `create-site SLUG --name N` | `create_site` (platform door) | `draft` + GXB staff | platform |
| `platform-tools` | -- (`GET /api/v1/platform/tools`) | none | platform |
| `upload SLUG FILE...` | -- (`POST /api/v1/media/uploads`) | `draft` | v2 |
| `push SLUG DIR` | one batch `read` + `upload` x N + one `save` | `draft` | v2 |
| `push SLUG DIR --dry-run` | one `describe_site` | `read` | v2 |
| `fragment FILE` | -- (local) | none | none |
| `check URL` | -- (`agent-browser`) | none | none |
| `describe_site` / `list_files` / `read_file` / `write_file` / `edit_file` / `publish SLUG PATH` | same names | `read` / `draft` / `publish` | legacy |
| `list` / `show` / `open` / `create` | -- (`rails runner`) | staff | both |

Every argument name here is the one `Mcp::ToolRegistry::TOOLS` declares. That
registry is the contract; this table is a map of which shell word posts which
tool.

**What the server has.** Slice D (builds, preview hostnames, real
`preview_status`, `revoke_preview`) is deployed. Slice E (`publish` both forms,
`merge_live`, `resolve_merge`, `history`, `read {at:}`, the batch asset `read`,
`archive_branch`) and slice F (`POST /api/v1/platform/tools`, personal tokens,
`read_submissions` as its own capability) are on `main` and deploy after
review; until that deploy a production server answers `unknown tool` for the
new names and 404 at the platform path, and the CLI prints that verbatim. The
`*.gxbsites.com` wildcard certificate is **not** installed yet, so a finished
build reports `provisioning` rather than `ready` and its preview hostname
cannot complete a TLS handshake. That is a host state, not something to wait
out -- see `wait-preview` below.

## Ergonomics

- `--expected` defaults to the last branch head token this CLI saw for that
  slug+branch. Every 2xx `describe`/`read`/`save`/`create-branch`/`diff`/
  `merge-live`/`resolve-merge` response writes it. A `save` that was never
  preceded by a `describe`/`read` of that branch fails locally (`NO_EXPECTED`)
  with no request.
- **A 409 `branch_changed` is never retried and never updates the cache.** It
  prints `{ok:false, error, code, status, body}` with the server's full body
  (including the current `expected`) and exits 1. Rerun `describe`, look at
  what moved, then save again. Learning the new token from the conflict body
  is how "never retried" turns into a silent overwrite one command later.
- **`read --at` never updates the cache either.** A historical read answers
  with the snapshot token it read, under the same `branch` and `expected` keys
  a head read uses; caching it would hand the next `save` a token for a
  snapshot the branch is not on.
- **`--review` never defaults.** A review is a binding to one exact candidate,
  so it is remembered under its own key and only `--review last` spends it.
  `publish --review last` with nothing remembered fails locally (`NO_REVIEW`)
  with no request. A `save` whose build is not ready answers `review: null`,
  which drops the remembered one rather than leaving `last` pointed at a
  candidate that no longer describes the branch.
- `--idempotency-key` defaults to a fresh UUID.
- Every tool subcommand also takes `--json FILE` or `--json -` (stdin) to
  supply the whole arguments object; explicit flags override individual keys.
- An unknown `--flag` is refused before any request goes out.
- **stdout is one JSON object, always.** Every note, warning, change list and
  next step goes to stderr, so `sites-cli <anything> | jq` works. The one
  deliberate exception is `upload`, which prints one JSON line per file.
- Nothing ever prints a bearer token.

## Tokens: which one, where

| Credential | Where it lives | What it opens |
|---|---|---|
| Personal token `sk_user_<id>_...` | `SITES_CLI_TOKEN`, or `tokens.json` under `_platform` | everything the person can reach: `POST /api/v1/platform/tools` (`list_sites`, `create_site`), and every site door and upload for a site they can read |
| Site token `sk_site_<slug>_...` | `tokens.json` under the slug | `POST /api/v1/tools`, `/api/v1/media/uploads` for that one site |
| Staff credentials | the Rails app itself | `list` / `show` / `open` / `create` through the runner |

**One personal credential opens both doors.** A site token is for handing a
single site to someone else. A slug with no entry in `tokens.json` falls back
to the personal token, and then every request carries `"site": "<slug>"` --
the same field Chat sends. The server resolves it through that person's
viewable sites and checks their capabilities on it, so a site they cannot read
is a 404 (never 403: "no such site" and "a site you cannot read" have to read
the same), and a capability they do not hold is 403 `capability_denied` naming
it. A slug with a site token is sent exactly as it always was, with no `site`
field at all.

A site token presented at the platform door is 403 `capability_denied`, printed
verbatim -- it is one tenant's credential at the platform endpoint, not "almost
right". A site token that names some *other* site is the same 403: a token
bound to one tenant cannot reach another by naming it.

A personal token's scopes are a ceiling **on top of** the person's
capabilities, so the smaller of the two wins. A read-only personal token
cannot draft on a site its owner administers, and `describe_site` reports the
intersection rather than the person's full set.

A token's scopes **are** the six capabilities, and they are fixed when it is
minted. `read` no longer contains `read_submissions`: reading a site's source
is not reading the contact details people typed into its forms. So
`list-submissions` on a token minted before that split is a 403 naming
`read_submissions`, and the recovery is a new token with the box ticked on the
site's admin page, not a retry. The CLI says so on stderr when it sees that
exact 403.

## State and token files

Both live in `~/.config/sites-cli` (`SITES_CLI_CONFIG_DIR`), outside this git
checkout. The CLI tightens each to mode 600 on every read.

`tokens.json`:

```json
{ "onyx": "sk_site_...", "acme": "sk_site_...", "_platform": "sk_user_..." }
```

`_platform` (or `SITES_CLI_TOKEN`, which wins) is the personal bearer for
`list-sites`, `create-site` and `platform-tools`, and the fallback for any slug
with no entry of its own. `state.json` is one flat map with two key shapes:

| Key | Value | Written by |
|---|---|---|
| `expected:<slug>:<branch>` | branch head CAS token (`snap_...`) | every 2xx v2 response carrying `branch`+`expected`, and every `branches[]` entry in `describe`. Never a `read --at` response, never a 409 body |
| `last_review:<slug>:<branch>` | the last `review` this CLI printed for that branch | every 2xx response carrying `branch`+`review` (`describe`, `save`, `create-branch`, `merge-live`, `resolve-merge`, `publish --keys`, `wait-preview`). An explicit `review: null` deletes it; so does a `publish --review` that spends it |
| `<slug>/<path>` | legacy file version | `read_file`, `write_file`, `edit_file`, `write_file --file` |

A review is never written under an `expected:` key and is never sent unless
the caller named it.

## Uploads

`upload SLUG FILE [FILE...]` runs the authorize -> PUT -> complete -> poll
flow for each file, four at a time, and prints one JSON line per file:

```json
{"path":"public/assets/app.js","digest":"9932...","url":"https://cdn.gxbsites.com/blobs/9932.../asset.js","media_type":"text/javascript","byte_size":19542,"status":"ready"}
```

Exit 1 if any file failed. On a versioned site `label` and `expected_version`
are omitted and `filename` + a `digest` hint are sent instead: bytes are bound
to a logical path later, by `save`. Content type comes from the extension:
`js mjs css svg glb woff woff2 json txt png jpg jpeg webp gif mp4`, plus an
extensionless `LICENSE`/`LICENCE`/`NOTICE`/`COPYING`/`COPYRIGHT`/`AUTHORS`/
`PATENTS` as `text/plain`, so a vendored bundle's notice can sit next to the
code it covers. `.mjs` uploads as `text/javascript` and the server delivers it
as `asset.js` -- the suffix comes from the validated type, never the filename.

The platform types bytes from **content**, not from the name, so a file called
`.png` that holds JPEG bytes is stored and served as `image/jpeg`. `push`
prints that on stderr when it happens; otherwise it appears nowhere short of a
browser's network log.

`push SLUG DIR [--branch B] [--prefix assets/] [--dry-run] [--offline]` walks
`DIR` with `Dir.glob` (never `find`), skipping dotfiles and dot directories,
then:

1. one `read {kind:"asset", keys:[...]}` (1000 keys per call) asking which of
   those logical paths the branch already binds, and to what digest;
2. uploads only the files whose local sha256 differs from what came back, four
   at a time -- identical bytes anywhere in the tree are still one upload;
3. emits **one** `save` with a `put {kind:"asset", key, digest}` per *changed*
   file. A tree where nothing moved makes no `save` at all and prints
   `{"saved":false,"unchanged":n}`.

The skip count goes to stderr (`push: 12 of 30 file(s) already bound at the
same digest`) so stdout stays one JSON envelope. The `read` in step 1 is also
the freshest look at the branch head there is, so its `expected` is what the
`save` uses unless `--expected` named one. A server with no batch asset read
(404/422) falls back to uploading everything; slice D's digest hint still
short-circuits bytes the platform already has, so the cost is a round trip per
file, not a wrong answer. Any other error (401, 403, or the 409 a legacy site
answers) stops the push.

A relative path that already starts with the prefix is not prefixed twice, so
`push onyx ./public` on a tree containing `assets/app.js` produces the key
`assets/app.js`, not `assets/assets/app.js`.

`--dry-run` prints the full change list (with real local sha256 digests and
each file's declared `media_type`) and makes **one** request: the
`describe_site` that says which contract this site is on. A rehearsal that asks
nothing cannot tell you the thing most worth knowing -- that the site is still
on the file API and the real call would be a 409. So a dry run on a legacy site
is `NOT_VERSIONED` naming `write_file`, a dry run on a branch the site does not
have is `NO_BRANCH` naming `create-branch`, and a dry run that passes reports
the real `expected` and `preview_status`. Nothing is uploaded and nothing is
saved either way. `--offline` is the pure-local form: no token needed, no
request at all, `contract: "unchecked"`.

Legacy sites keep `write_file SLUG assets/hero.jpg --file ./hero.jpg`:
authorize -> stage -> complete -> poll against a labeled asset. jpg/png/webp/
gif is one presigned PUT streamed straight from disk (`body_stream`, never
buffered). mp4 is multipart: sliced per the server's part size, four parts in
flight, each part retried with a fresh presign, and an unrecoverable part
aborts the whole upload (`DELETE .../uploads/:id`, releasing the quota
reservation).

## fragment, and `save --page --html`

A versioned page is a JSON document whose `body` is a **fragment**: the shell
owns `<!doctype>`, `<html>`, `<head>`, `<title>`, `<meta>`, the one import map
and `<main id="main">`, and every asset reference is a `{{ asset:path }}` tag
rather than a URL. A page authored as a standalone HTML file has to be taken
apart before it can be saved, and doing that by hand is how a site ends up with
a duplicated `id="main"` or a stylesheet nothing loads.

`fragment FILE|- [--prefix assets/]` does the conversion and prints it:

```json
{"ok":true,"data":{"format":"html","metadata":{...},"body":"...","css":"...",
 "config":{"stylesheets":[...],"modules":[...],"imports":{...},"favicon":{"url":"..."}},
 "assets":[...],"changes":[...],"warnings":[...]}}
```

| Source | Becomes |
|---|---|
| `<!doctype>`, `<html>`, `<head>`, `<body>` | dropped |
| `<title>` | `metadata.title` (entity-decoded) |
| `<meta name="description">`, `<meta name="robots" content="noindex">` | `metadata.description`, `metadata.noindex` |
| `<link rel="stylesheet" href="assets/x.css">` | `config.stylesheets` |
| `<link rel="icon" href="assets/x">` | `config.favicon.url` |
| `<script type="importmap">` | `config.imports` -- the shell emits the one import map |
| `<script type="module" src="assets/x.js">` | `config.modules` |
| `<style>` (head or body) | the page document's `css` |
| `<a href="#main">` | dropped -- the shell emits its own skip link |
| `<main id="main" class="x">` ... `</main>` | `<div class="x">` ... `</div>` |
| `src`/`href`/`data-asset`/`poster`/`data-src` = `assets/x`, `./assets/x`, `/assets/x` | `{{ asset:assets/x }}` |

Everything else is left alone, including the page's own inline `<script>`.
Every line above is reported on stderr, and warnings name the four things that
only break later: an external stylesheet `config.stylesheets` cannot hold, an
`srcset` that was not rewritten, a declared **SVG favicon** (a hard 415 on
every page -- the platform routes `favicon.url` through a Cloudflare image
transform, and those refuse SVG input), and a page that binds its own `submit`
handler on a `/f/` form without `stopPropagation()` (the platform injects
`/platform/forms-1.js`, which binds a document-level `submit` listener too, so
one click posts twice).

`save SLUG --page KEY --html FILE [--config FILE] [--title T] [--metadata FILE]`
runs the same conversion and builds the changes JSON from it: a `put config`
first, then a `put page`. A `--config` document gets the stylesheets, modules
and imports the conversion found, but only for keys it does not declare at all
-- an explicit `"stylesheets": []` is a declaration and wins. `--title` (or
`--metadata`) overrides what the `<title>` said; a document with neither is
refused locally, because the server requires `metadata.title`. `--changes` and
`--html`/`--config` in the same command is a usage error: one of them would
have to win.

## publish is two calls

`publish SLUG --expected T --keys page:/about,asset:assets/x.js` **proposes** a
candidate: live plus those keys plus the assets they reach. It answers a 200
carrying `published: false`, its own `review`, `included`, `left_on_branch` and
a `preview_url`. Live is untouched and the branch never moves.

`published: false` is a successful request and exits 0 -- the CLI did what it
was asked. It is never "shipped". The CLI prints the envelope on stdout and,
on stderr:

```
published: false -- live is unchanged. 2 key(s) in the candidate, 3 left on draft.
next: preview it, then `sites-cli publish onyx --review last` (or --review "<token>") to flip live.
```

`publish SLUG --review TOKEN` is the call that swaps live to the exact
candidate that review binds. `--review last` spends the review this CLI last
printed for that slug+branch and then forgets it, because a spent review
publishes nothing the second time (409 `upstream_changed`). A review from
`save` covers the whole branch delta, so passing it with a narrower `--keys`
list is 422 `review_mismatch`.

## wait-preview

Polls `describe_site` until the branch's build settles, then stops. What each
`preview_status` does:

| Status | wait-preview | Exit |
|---|---|---|
| `queued`, `building` | keep polling until `--timeout` | 0 / 1 on timeout |
| `ready` | print the payload | 0 |
| `provisioning` | terminal: the build is good, but the hostname cannot be opened until the `*.gxbsites.com` wildcard certificate is installed on the host. The payload carries that as `message` | 0 |
| `invalid` | terminal: source diagnostics say what to fix; it cannot be published | 1 |
| `failed` | terminal: infrastructure fault, being retried | 1 |
| `revoked` | terminal: every preview of this snapshot was withdrawn; `save` again for a new one | 1 |
| `unavailable` | terminal: the snapshot predates builds | 1 |
| absent / anything else | error (`PREVIEW_MISSING` / `PREVIEW_UNKNOWN`) | 1 |

`provisioning` is the state production is in today, so a successful
`wait-preview` today usually means "built and good, not openable yet". Nothing
polls that away.

A preview URL is read access to that exact snapshot for whoever holds it.
Never paste one into a ticket, a Slack thread or an email; `revoke-preview`
withdraws one that got out.

## check

`check URL [--width 1440] [--height 900] [--screenshot PATH] [--ignore SUBSTR]
[--no-probe]` opens the URL in a fresh `agent-browser` session, waits for
`networkidle`, and prints:

```json
{"status":200,"console_errors":[],"failed_requests":[{"url":"...","status":404}],"title":"Onyx","url":"...","screenshot":"/abs/path.png"}
```

Exit 1 on any console error or failed request. `console_errors` merges
`agent-browser console` (messages of type `error`) with `agent-browser errors`
(uncaught page errors) -- that pair is its nearest equivalent to a single
console-error stream. `failed_requests` is every request with no status or a
status >= 400, so a site with no favicon shows `/favicon.ico` 404; drop it with
`--ignore favicon`. The session is always closed, including on failure: every
orphan is a full Chrome that lives until reboot.

**A blocked subresource and a missing one look identical in a browser**: an
entry with no status, and nothing in the console. So for every cross-origin
failure with no status (at most 10 per run), `check` asks the object for itself
from outside the browser, with an `Origin` header and `Range: bytes=0-0`, and
adds what it found:

| `diagnosis` | What it means |
|---|---|
| `cors_blocked` | The object is there (`probe.status` 2xx) and sends no `access-control-allow-origin`. Bucket CORS, not a missing file |
| `http_error` | The object itself answers 4xx/5xx |
| `cors_ok` | The object is there and allows this origin, so the block is something else |
| `unreachable` | The probe could not fetch it either |

The browser's own failure text (`net::ERR_FAILED`, `ERR_BLOCKED_BY_RESPONSE`)
rides along as `error`, and the diagnosis is repeated in prose on stderr.
`--no-probe` turns the whole thing off.

A preview hostname that resolves but cannot finish a TLS handshake is
`PREVIEW_TLS` rather than a bare browser error: that is the missing
`*.gxbsites.com` wildcard certificate, and the build itself is fine.

## Commands

```bash
# runner (staff)
sites-cli list [--prod]
sites-cli show SLUG [--prod]
sites-cli open SLUG [--prod]
sites-cli create SLUG [--name NAME] [--team TEAM] [--prod]

# v2
sites-cli describe SLUG [--branch B]
sites-cli read SLUG KIND [KEY] [--branch B] [--fields metadata,body] [--lines 1,40] [--at SNAPSHOT]
sites-cli read SLUG asset --keys assets/a.js,assets/b.css [--branch B]
sites-cli save SLUG --changes FILE|- [--branch B] [--expected TOKEN] [--message M] [--idempotency-key K]
sites-cli save SLUG --page KEY --html FILE [--config FILE] [--title T] [--metadata FILE] [--prefix assets/]
sites-cli fragment FILE|- [--prefix assets/]
sites-cli create-branch SLUG NAME [--from live|BRANCH]
sites-cli archive-branch SLUG NAME
sites-cli diff SLUG [--branch B] [--against live|BRANCH]
sites-cli publish SLUG --review TOKEN|last [--idempotency-key K]
sites-cli publish SLUG --expected TOKEN --keys page:/about,asset:assets/x.js
sites-cli merge-live SLUG [--branch B] --expected TOKEN --expected-live ID
sites-cli resolve-merge SLUG --proposal TOKEN --resolutions FILE
sites-cli history SLUG [--branch B] [--limit N]
sites-cli revoke-preview SLUG URL_OR_TOKEN
sites-cli wait-preview SLUG [--branch B] [--timeout 120]
sites-cli list-submissions SLUG [--form F] [--since ISO] [--limit N]
sites-cli analytics SLUG [--period today|yesterday|7d|30d|all]
sites-cli upload SLUG FILE [FILE...]
sites-cli push SLUG DIR [--branch B] [--prefix assets/] [--dry-run] [--offline]
sites-cli check URL [--width 1440] [--screenshot PATH] [--ignore SUBSTR] [--no-probe]

# platform tools (a personal token: SITES_CLI_TOKEN or tokens.json "_platform")
sites-cli list-sites                  # every site you can read
sites-cli list-sites SLUG             # through that site's door, not the platform one
sites-cli create-site SLUG --name N   # GXB staff only
sites-cli platform-tools              # the two schemas, from the server

# legacy file API
sites-cli list_files SLUG [--prefix _posts/]        # alias: list SLUG
sites-cli read_file SLUG about.md [--view live]
sites-cli write_file SLUG about.md --content "$(cat about.md)" [--expected-version V]
sites-cli write_file SLUG assets/hero.jpg --file ./hero.jpg
sites-cli edit_file SLUG about.md --edits-file edits.json [--expected-version V]
sites-cli publish SLUG about.md [--expected-version V]
```

`sites-cli list SLUG` lists that site's files. `sites-cli list` with no slug
lists every tenant site through the runner. `sites-cli list-sites` asks the
platform tool instead, and answers for whoever the personal token belongs to.

`create-site` posts `create_site` to `POST /api/v1/platform/tools` with a
personal bearer and returns the new site's `draft` branch and its first
`expected` token, which this CLI remembers -- so the very next call really is a
`save`, `push` or `upload` on the same credential, with no token step in
between. Minting the site's own token is optional now, and is for handing that
one site to someone else (`Admin::ApiTokensController` on its admin page, then
`tokens.json` under the slug). `create-site` still sets no form recipient. The
runner command `sites-cli create SLUG --name NAME` also works and needs no
token at all.

## Worked example: an Onyx-shaped site

Seven commands and one credential, from nothing to live. Given a directory
holding `index.html`, `assets/`, and a `config.json` with the site's `name`,
`runtime` and `business`, and a personal token in `SITES_CLI_TOKEN`:

```bash
# 0. the site itself. Nothing else is needed: no admin page, no site token.
sites-cli create-site onyx --name "Onyx"      # remembers the new draft head

# 1. the public tree: contract checked, unchanged files skipped, the rest
#    uploaded and bound in one save
sites-cli push onyx ./public --dry-run        # one describe_site: right contract? right branch?
sites-cli push onyx ./public                  # batch read + uploads + one save

# 2. the homepage and the config, converted and saved in one command. The
#    document shell is dropped, <title>/<meta> become metadata, the head's
#    stylesheet/module/import map join config.json, and every assets/
#    reference becomes {{ asset: }}. What it did goes to stderr.
sites-cli save onyx --page / --html ./public/index.html --config ./config.json \
  --message "onyx homepage"

# 3. wait for the build, then look at the preview in a real browser
sites-cli wait-preview onyx                   # 1 on invalid/failed/revoked;
                                              # 0 on provisioning, which cannot be opened yet
sites-cli check https://<token>-onyx.gxbsites.com --screenshot /tmp/onyx.png

# 4. publish. describe_site only offers a review once a ready build exists for
#    that head, so this is the token that publishes the whole branch delta.
sites-cli describe onyx                       # remembers branches[].review
sites-cli publish onyx --review last
```

To see the conversion before committing to it, `sites-cli fragment
./public/index.html` prints exactly what `save --html` would send and makes no
request. To ship one page and its assets first, publish is two calls, not one:

```bash
sites-cli publish onyx --keys page:/about     # 200 published:false + its own review
sites-cli wait-preview onyx                   # the candidate has its own build
sites-cli publish onyx --review last          # this is what flips live
```

Every command above ran on the one personal token, which is why step 0 sits in
the same block as the rest. To hand this site to someone who should have only
it, mint its own token on its admin page and add it to `tokens.json` under the
slug; this CLI then prefers that token for this slug and sends no `site` field.

A missing static dependency (`BufferGeometryUtils.js`) makes the `save`
succeed and `wait-preview` exit 1 with `preview_status: "invalid"` and a
diagnostic naming the importer and the specifier. Upload it, `save` the asset
put, and take the new review. No silent rewrite.

Selecting a page whose layout is still unpublished is 422
`unpublished_dependency` naming the exact keys to add, and a review minted
before somebody else published is 409 `upstream_changed` pointing at
`merge-live`. Neither is retried; both name the next call.

## Environment

| Variable | Default | What |
|---|---|---|
| `SITES_ROOT` | `~/projects/sites` | the sites Rails app, for the runner commands |
| `SITES_CLI_HOST` | `https://sites.gxb.vc` | the site-token gateway |
| `SITES_CLI_CONFIG_DIR` | `~/.config/sites-cli` | tokens.json + state.json |
| `SITES_CLI_TOKEN` | -- | personal bearer (`sk_user_...`): the platform tools, and the fallback for any slug with no site token |
| `SITES_CLI_BROWSER` | `agent-browser` | the browser binary `check` drives |

`--prod` on a runner command requires `kamal-cli` on PATH.

## Testing

```bash
ruby test_sites_cli.rb
```

A stub WEBrick server plays the Sites API in-process and drives the real CLI
binary against it (111 checks): token/site binding, the nonzero 409 exit with
no automatic retry or reread and no cache poisoning from the conflict body or
from a `read --at`, expected-token persistence, review caching and forgetting,
every v2 subcommand's request shape against `Mcp::ToolRegistry`, each terminal
`preview_status`, byte-for-byte streamed binary uploads (single PUT and
multipart), upload content types and bounded parallelism, push change-list
generation, dedup, the batch-read skip and its fallback, the platform door
(personal bearer, a site token's 403 printed verbatim, the remembered new-site
head), the personal token at the site doors (the `site` field on every tools,
upload and status request, none on a site token's, create-site straight into a
save, and `NO_TOKEN` naming both ways out),
`list_submissions` and its `read_submissions` 403, `get_analytics`, the
`fragment` conversion and every warning it raises, `save --page --html
--config` and its config merge, the dry-run contract check, the `check`
wrapper against a stub browser including the CORS probe and the preview-TLS
hint, that stdout is one JSON object per command, and that no bearer token
reaches stdout or state.json.
