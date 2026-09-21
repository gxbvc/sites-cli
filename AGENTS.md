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

A site is on exactly one contract. Calling the other one's write tool is a 409
naming the tool to use instead (`upgrade_required` / `not_versioned`).

## Subcommand -> tool -> capability

| Subcommand | MCP tool | Capability | Contract |
|---|---|---|---|
| `describe SLUG [PATH] [--branch B]` | `describe_site` | `read` | both (the server answers in the site's own shape) |
| `read SLUG KIND [KEY]` | `read` | `read` | v2 |
| `save SLUG --changes FILE` | `save` | `draft` | v2 |
| `create-branch SLUG NAME` | `create_branch` | `draft` | v2 |
| `diff SLUG` | `diff` | `read` | v2 |
| `publish SLUG --review T` | `publish` | `publish` | v2 |
| `publish SLUG --expected T --keys ...` | `publish` | `publish` | v2 |
| `merge-live SLUG --expected-live ID` | `merge_live` | `draft` | v2 |
| `resolve-merge SLUG --proposal T` | `resolve_merge` | `draft` | v2 |
| `history SLUG` | `history` | `read` | v2 |
| `revoke-preview SLUG URL_OR_TOKEN` | `revoke_preview` | `draft` | v2 |
| `wait-preview SLUG` | `describe_site` (polled) | `read` | v2 |
| `list-sites [SLUG]` | `list_sites` | `read` | platform |
| `create-site SLUG --name N` | `create_site` | `create_site` (staff) | platform |
| `upload SLUG FILE...` | -- (`POST /api/v1/media/uploads`) | `draft` | v2 |
| `push SLUG DIR` | `upload` x N + one `save` | `draft` | v2 |
| `check URL` | -- (`agent-browser`) | none | none |
| `describe_site` / `list_files` / `read_file` / `write_file` / `edit_file` / `publish SLUG PATH` | same names | `read` / `draft` / `publish` | legacy |
| `list` / `show` / `open` / `create` | -- (`rails runner`) | staff | both |

**Pending server support.** `publish --review` / `--keys`, `merge-live`,
`resolve-merge`, `history`, `revoke-preview` and `wait-preview`'s
`preview_status` are built to the slice D and E specs
(`plans/reviews/30/WORKER_D_PROMPT.md`, `WORKER_E_PROMPT.md`), which are not
merged yet. Until they land the server answers `unknown tool` or
`preview_status: "unavailable"`; the CLI prints that verbatim rather than
pretending. Everything else (`describe`, `read`, `save`, `create-branch`,
`diff`, `upload`, `push`, `check`, `list-sites`) is live now.

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
- `--idempotency-key` defaults to a fresh UUID.
- Every tool subcommand also takes `--json FILE` or `--json -` (stdin) to
  supply the whole arguments object; explicit flags override individual keys.
- An unknown `--flag` is refused before any request goes out.
- Nothing ever prints a bearer token.

## State and token files

Both live in `~/.config/sites-cli` (`SITES_CLI_CONFIG_DIR`), outside this git
checkout. The CLI tightens each to mode 600 on every read.

`tokens.json`:

```json
{ "onyx": "sk_site_...", "acme": "sk_site_...", "_platform": "sk_..." }
```

`_platform` (or `SITES_CLI_TOKEN`) is the bearer for `list-sites` and
`create-site`. `state.json` is one flat map with two key shapes:

| Key | Value | Written by |
|---|---|---|
| `expected:<slug>:<branch>` | branch head CAS token (`snap_...`) | every 2xx v2 response carrying `branch`+`expected`, and every `branches[]` entry in `describe` |
| `<slug>/<path>` | legacy file version | `read_file`, `write_file`, `edit_file`, `write_file --file` |

## Uploads

`upload SLUG FILE [FILE...]` runs the authorize -> PUT -> complete -> poll
flow for each file, four at a time, and prints one JSON line per file:

```json
{"path":"public/assets/app.js","digest":"9932...","url":"https://cdn.gxbsites.com/blobs/9932.../asset.js","media_type":"text/javascript","byte_size":19542,"status":"ready"}
```

Exit 1 if any file failed. On a versioned site `label` and `expected_version`
are omitted and `filename` + a `digest` hint are sent instead: bytes are bound
to a logical path later, by `save`. Content type comes from the extension:
`js mjs css svg glb woff woff2 json txt png jpg jpeg webp gif mp4`. `.mjs`
uploads as `text/javascript` and the server delivers it as `asset.js` -- the
suffix comes from the validated type, never the filename.

`push SLUG DIR [--branch B] [--prefix assets/] [--dry-run]` walks `DIR` with
`Dir.glob` (never `find`), skipping dotfiles and dot directories, uploads every
file, then emits **one** `save` with a `put {kind:"asset", key, digest}` per
file using the current `expected`. Identical bytes anywhere in the tree are one
upload. A relative path that already starts with the prefix is not prefixed
twice, so `push onyx ./public` on a tree containing `assets/app.js` produces
the key `assets/app.js`, not `assets/assets/app.js`. `--dry-run` prints the
change list (with real local sha256 digests) and makes no request at all.

Legacy sites keep `write_file SLUG assets/hero.jpg --file ./hero.jpg`:
authorize -> stage -> complete -> poll against a labeled asset. jpg/png/webp/
gif is one presigned PUT streamed straight from disk (`body_stream`, never
buffered). mp4 is multipart: sliced per the server's part size, four parts in
flight, each part retried with a fresh presign, and an unrecoverable part
aborts the whole upload (`DELETE .../uploads/:id`, releasing the quota
reservation).

## check

`check URL [--width 1440] [--height 900] [--screenshot PATH] [--ignore SUBSTR]`
opens the URL in a fresh `agent-browser` session, waits for `networkidle`, and
prints:

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
sites-cli save SLUG --changes FILE|- [--branch B] [--expected TOKEN] [--message M] [--idempotency-key K]
sites-cli create-branch SLUG NAME [--from live|BRANCH]
sites-cli diff SLUG [--branch B] [--against live|BRANCH]
sites-cli publish SLUG --review TOKEN [--idempotency-key K]
sites-cli publish SLUG --expected TOKEN --keys page:/about,asset:assets/x.js
sites-cli merge-live SLUG [--branch B] --expected TOKEN --expected-live ID
sites-cli resolve-merge SLUG --proposal TOKEN --resolutions FILE
sites-cli history SLUG [--branch B] [--limit N]
sites-cli revoke-preview SLUG URL_OR_TOKEN
sites-cli wait-preview SLUG [--branch B] [--timeout 120]
sites-cli list-sites [SLUG]
sites-cli upload SLUG FILE [FILE...]
sites-cli push SLUG DIR [--branch B] [--prefix assets/] [--dry-run]
sites-cli check URL [--width 1440] [--screenshot PATH] [--ignore SUBSTR]

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
platform tool instead.

`create-site` posts the platform `create_site` tool, but `/api/v1/tools` only
authenticates site-bound tokens and `Agent::Session#create_site` answers 403
`capability_denied` for those, so it always fails there. Use the runner
command `sites-cli create SLUG --name NAME`, then mint an API token
(`Admin::ApiTokensController` on the site's admin page) and set a form
recipient -- neither happens automatically.

## Worked example: an Onyx-shaped site

```bash
# 1. the public tree: every asset uploaded and bound in one save
sites-cli describe onyx                       # remembers the draft head
sites-cli push onyx ./public --dry-run        # read the change list first
sites-cli push onyx ./public                  # uploads + one save

# 2. config and the homepage, in one more save
cat > /tmp/changes.json <<'JSON'
[
  {"op":"put","kind":"config","document":{
     "runtime":{"turbo":false,"alpine":false},
     "modules":["assets/onyx-core-motion.js"],
     "imports":{"three":"assets/vendor/three/three.module.js"},
     "stylesheets":["assets/stealth.css"]}},
  {"op":"put","kind":"page","key":"/","document":{
     "format":"html",
     "metadata":{"title":"Onyx","layout":"default"},
     "body":"<div data-asset=\"{{ asset:assets/onyx-motion-studies.glb }}\"></div>"}}
]
JSON
sites-cli save onyx --changes /tmp/changes.json --message "onyx homepage"

# 3. wait for the build, then look at the preview in a real browser
sites-cli wait-preview onyx                   # exits 1 on invalid/failed
sites-cli check https://<token>-onyx.gxbsites.com --screenshot /tmp/onyx.png

# 4. publish the reviewed candidate
sites-cli publish onyx --review "$(sites-cli describe onyx | jq -r '.data.branches[0].review')"
```

A missing static dependency (`BufferGeometryUtils.js`) makes the `save`
succeed and `wait-preview` exit 1 with `preview_status: "invalid"` and a
diagnostic naming the importer and the specifier. Upload it, `save` the asset
put, and take the new review. No silent rewrite.

## Environment

| Variable | Default | What |
|---|---|---|
| `SITES_ROOT` | `~/projects/sites` | the sites Rails app, for the runner commands |
| `SITES_CLI_HOST` | `https://sites.gxb.vc` | the site-token gateway |
| `SITES_CLI_CONFIG_DIR` | `~/.config/sites-cli` | tokens.json + state.json |
| `SITES_CLI_TOKEN` | -- | bearer for the platform tools |
| `SITES_CLI_BROWSER` | `agent-browser` | the browser binary `check` drives |

`--prod` on a runner command requires `kamal-cli` on PATH.

## Testing

```bash
ruby test_sites_cli.rb
```

A stub WEBrick server plays the Sites API in-process and drives the real CLI
binary against it: token/site binding, the nonzero 409 exit with no automatic
retry or reread and no cache poisoning from the conflict body, expected-token
persistence, every v2 subcommand's request shape, byte-for-byte streamed
binary uploads (single PUT and multipart), upload content types and bounded
parallelism, push change-list generation and dedup, the `check` wrapper
against a stub browser, and that no bearer token reaches stdout or state.json.
