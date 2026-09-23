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

Do not edit this table by hand. It is the output of `sites-cli manual`, which
prints the `SUBCOMMANDS` table in the binary; a test fails if a row and a
`when` clause disagree. Regenerate it with `sites-cli manual` and paste.

<!-- sites-cli manual -->
| Subcommand | Tool | Capability | Contract |
|---|---|---|---|
| `describe SLUG [PATH] [--branch B]` (alias: `describe_site`) | `describe_site` | read | both |
| `read SLUG KIND [KEY] [--branch B] [--fields f] [--lines a,b] [--at SNAP] [--keys a,b]` | `read` | read | v2 |
| `schema SLUG [config\|page\|collection\|redirect\|changes]` | `read {kind: schema}` | read | v2 |
| `list-pages SLUG [--branch B]` | `describe_site + read xN` | read | v2 |
| `guide SLUG [TOPIC] [--format text\|json]` | `read {kind: guide}` | read | v2 |
| `heads SLUG ROUTE... [--branch B]` | `read {kind: prepared, keys}` | read | v2 |
| `save SLUG --changes FILE \| --page KEY --html FILE ... [--dry-run]` | `save` | draft | v2 |
| `create-branch SLUG NAME [--from live\|BRANCH]` | `create_branch` | draft | v2 |
| `archive-branch SLUG NAME` | `archive_branch` | draft | v2 |
| `diff SLUG [--branch B] [--against live\|BRANCH]` | `diff` | read | v2 |
| `publish SLUG --review T\|last \| --expected T --keys ... \| PATH` | `publish` | publish | both |
| `merge-live SLUG [--branch B] --expected T --expected-live ID` | `merge_live` | draft | v2 |
| `resolve-merge SLUG --proposal T --resolutions FILE` | `resolve_merge` | draft | v2 |
| `history SLUG [--branch B] [--limit N]` | `history` | read | v2 |
| `revoke-preview SLUG URL_OR_TOKEN` | `revoke_preview` | draft | v2 |
| `wait-preview SLUG [--branch B] [--timeout 120]` | `describe_site (polled)` | read | v2 |
| `list-domains SLUG` | `list_domains` | read | v2 |
| `connect-domain SLUG HOST [--no-primary]` | `connect_domain` | manage_domains | v2 |
| `verify-domain SLUG HOST` | `verify_domain` | manage_domains | v2 |
| `disconnect-domain SLUG HOST` | `disconnect_domain` | manage_domains | v2 |
| `list-submissions SLUG [--form F] [--since ISO] [--limit N]` | `list_submissions` | read_submissions | both |
| `delete-submission SLUG ID` | `delete_submission` | read_submissions | both |
| `analytics SLUG [--period today\|yesterday\|7d\|30d\|all]` | `get_analytics` | read | both |
| `list-sites [SLUG] [--search QUERY]` | `list_sites` | read | platform, or a site door with SLUG |
| `users [--search QUERY] [--cursor ID]` | `search_users` | manage_access + GXB staff | platform |
| `members SLUG` | `list_members` | manage_access | both |
| `grant SLUG --email EMAIL\|--auth-user-id ID --role viewer\|editor\|admin [--read-submissions]` | `grant_access` | manage_access | both |
| `revoke SLUG --email EMAIL\|--auth-user-id ID --yes` | `revoke_access` | manage_access | both |
| `create-site SLUG --name NAME` | `create_site` | draft + GXB staff | platform |
| `platform-tools` | `GET /api/v1/platform/tools` | none | platform |
| `tools SLUG` | `GET /api/v1/tools` | none | both |
| `upload SLUG FILE [FILE...]` | `POST /api/v1/media/uploads` | draft | v2 |
| `push SLUG DIR [--branch B] [--prefix P] [--dry-run] [--offline]` | `read + upload xN + save` | draft | v2 |
| `fragment FILE\|- [--page KEY] [--append-changes FILE] [--wrap-body] [--lift-json-ld]` | -- | none | none |
| `validate-config FILE --site SLUG` | `read {kind: schema}` | read | v2 |
| `check URL [--against URL] [--screenshot PATH] [--viewport] [--ignore S] [--no-probe]` | -- | none | none |
| `manual` | -- | none | none |
| `list [SLUG] [--prod]` | `rails runner, or list_files with SLUG` | staff / read | both |
| `show SLUG [--prod]` | `rails runner` | staff | both |
| `open SLUG [--prod]` | `rails runner` | staff | both |
| `create SLUG [--name N] [--team T] [--prod]` | `rails runner` | staff | legacy |
| `list_files SLUG [--prefix P]` | `list_files` | read | legacy |
| `read_file SLUG PATH [--view live]` | `read_file` | read | legacy |
| `write_file SLUG PATH --content C \| --file FILE` (alias: `write`) | `write_file` | draft | legacy |
| `edit_file SLUG PATH --edits-file FILE` (alias: `edit`) | `edit_file` | draft | legacy |
<!-- /sites-cli manual -->

Every argument name here is the one `Mcp::ToolRegistry::TOOLS` declares. That
registry is the contract; this table is a map of which shell word posts which
tool.

**What the server has: ask it.** `sites-cli tools SLUG` prints the server's own
tool index for that site and `sites-cli schema SLUG` prints the document
schemas. A paragraph in this file cannot stay true across a deploy and twice
has told people a working feature was broken; those two commands can.

## People and site access

```sh
sites-cli users --search "Dirk"
sites-cli list-sites --search "tap"
sites-cli grant tap --email dperritt@mdhealthpathways.com --role editor
sites-cli members tap
# Removal requires explicit confirmation:
sites-cli revoke tap --email dperritt@mdhealthpathways.com --yes
```

`users` searches active Auth users by name or email. Without `--search`, it
lists them, 50 per page. Pass `next_cursor` back with `--cursor` for the next
page. It requires a staff personal token with `manage_access`. Sites uses its
existing OAuth credential to call Auth; the Auth application must have
`directory_access` enabled. No Auth credential reaches the CLI.

Grants accept one exact `--email` or `--auth-user-id` (Auth UUID, not Sites'
integer user ID). Fuzzy names are search inputs only. Staff grants resolve
Auth identity before writing. Client site admins can invite an exact email
without access to the global directory. An email not yet in Auth can receive
an invitation record; no prior Sites login is required. No email is sent.

New `viewer` grants mean `read`; `editor` means `read,draft`. Add
`--read-submissions` explicitly to include inquiries. `admin` includes all
capabilities. Existing members keep their stored capabilities. Grants add
rights, never reduce them, and repeated identical grants report
`changed:false`. Use `revoke` to remove the explicit membership on one site.
It refuses self-removal, the last manager on a restricted site, and implicit
GXB staff access. `members` reports both granted and effective capabilities.
All three access commands need `manage_access` and use the same tools as Chat.

## Ergonomics

- **The version handshake is reactive, not a probe.** There is no
  `server_version` field to poll, and polling for one before every command
  would be a second request ahead of the one actually asked for. So instead:
  the first `read {kind: "guide"}` (from `guide`, or from anything that hits
  it) against a server still on the previous deploy 422s naming its kind enum
  without `"guide"` in it, and that 422 *is* the version check -- the CLI
  turns it into one stderr line naming what will not work yet (`guide`,
  `heads`, `list-pages`, the still-possibly-present save change cap, same-key
  ops that may still conflict) instead of the three unrelated-looking 422s
  three different new subcommands used to give three different agents
  (`pc_e26c86d1`). `heads` gets the same treatment when the response comes
  back shaped like the old single-route `prepared` read instead of the new
  `keys` list (one entry per requested route, each carrying its own `key`,
  or `{key, missing: true}`). Printed at most once per run either way.
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
  snapshot the branch is not on. Nor does `save --dry-run`: a rehearsal makes
  no snapshot, so it leaves no local state.
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
  next step goes to stderr, so `sites-cli <anything> | jq` works. The
  deliberate exceptions are `upload`, which prints one JSON line per file,
  `manual`, which prints a markdown table, and `guide`, which prints Markdown
  text when `--format text` is given or stdout is a TTY (JSON otherwise).
- **Nothing ever prints a Ruby backtrace.** A server answer nobody expected is
  a structured error with the body attached, and a worker thread that raises
  fails one file rather than the command.
- Nothing ever prints a bearer token.

## Tokens: which one, where

| Credential | Where it lives | What it opens |
|---|---|---|
| Personal token `sk_user_<id>_...` | `SITES_CLI_TOKEN`, or `tokens.json` under `_platform` | everything the person can reach: `POST /api/v1/platform/tools` (`list_sites`, `create_site`), and every site door and upload for a site they can read |
| Site token `sk_site_<slug>_...` | `tokens.json` under the slug | `POST /api/v1/tools`, `/api/v1/media/uploads` for that one site |
| Staff credentials | the Rails app itself | `list` / `show` / `open` / `create` through the runner |

**One personal credential opens both doors**, and this is deployed. A site
token is for handing a single site to someone else. A slug with no entry in
`tokens.json` falls back to the personal token, and then every request carries
`"site": "<slug>"` -- the same field Chat sends. The server resolves it through
that person's viewable sites and checks their capabilities on it, so a site
they cannot read is a 404 (never 403: "no such site" and "a site you cannot
read" have to read the same), and a capability they do not hold is 403
`capability_denied` naming it. A slug with a site token is sent exactly as it
always was, with no `site` field at all.

A site token presented at the platform door is 403 `capability_denied`, printed
verbatim -- it is one tenant's credential at the platform endpoint, not "almost
right". A site token that names some *other* site is the same 403: a token
bound to one tenant cannot reach another by naming it.

A personal token's scopes are a ceiling **on top of** the person's
capabilities, so the smaller of the two wins. A read-only personal token
cannot draft on a site its owner administers, and `describe_site` reports the
intersection rather than the person's full set.

A token's scopes **are** the capabilities, and they are fixed when it is
minted. `read` no longer contains `read_submissions`: reading a site's source
is not reading the contact details people typed into its forms. So
`list-submissions` on a token minted before that split is a 403 naming
`read_submissions`, and the recovery is a new token with the box ticked on the
site's admin page, not a retry. The CLI says so on stderr when it sees that
exact 403. `manage_domains` is its own capability the same way.

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
| `expected:<slug>:<branch>` | branch head CAS token (`snap_...`) | every 2xx v2 response carrying `branch`+`expected`, and every `branches[]` entry in `describe`. Never a `read --at` response, never a `save --dry-run`, never a 409 body |
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
to a logical path later, by `save`.

**Bytes the platform already holds are the cheap case.** Authorize answers
`status: "ready"` with the blob URL and no `upload_url`, and that line comes
back with `"deduplicated": true` and no PUT, no complete and no poll. This is
the fast path global content addressing exists for -- a file another tenant
published is already there -- and it used to hand `nil` to `URI()` and print a
thread backtrace with nothing on stdout.

**Any content type.** The extension table
(`js mjs css svg glb woff woff2 json txt png jpg jpeg webp gif mp4`, plus an
extensionless `LICENSE`/`LICENCE`/`NOTICE`/`COPYING`/`COPYRIGHT`/`AUTHORS`/
`PATENTS` as `text/plain`) is a hint for the types the platform has opinions
about. Anything it does not name is typed by extension through Marcel, or
`mime-types`, or finally `application/octet-stream`. The one refusal left is
the server's: `text/html`, `application/xhtml+xml` and anything that sniffs as
HTML, because a page served as a blob on `cdn.gxbsites.com` would be phishing
on our own origin. That 422 is printed verbatim; the CLI does not guess it
locally, but `push` says on stderr that an HTML file belongs in a page
document. Single PUT up to 25 MB; above that the server asks for the multipart
transport whatever the type is, and the CLI follows `multipart` in the
authorize response.

`.mjs` uploads as `text/javascript` and the server delivers it as `asset.js` --
the suffix comes from the validated type, never the filename. The platform
types bytes from **content**, not from the name, so a file called `.png` that
holds JPEG bytes is stored and served as `image/jpeg`. `push` prints that on
stderr when it happens; otherwise it appears nowhere short of a browser's
network log.

**Derivatives come from the CDN, not from a second upload.** An image blob is
resizable in place through the Cloudflare transform prefix:

```
https://cdn.gxbsites.com/cdn-cgi/image/width=400,format=auto/blobs/<digest>/asset.jpg
```

**Assets are cross-origin.** They are served from `cdn.gxbsites.com` and the
page is not, so a canvas or WebGL texture needs `crossOrigin = "anonymous"` on
the image (or `{ crossOrigin: 'anonymous' }` on a three.js loader) or the
canvas is tainted and `readPixels`/`toDataURL` throws.

### push

`push SLUG DIR [--branch B] [--prefix assets/] [--dry-run] [--offline]` walks
`DIR` with `Dir.glob` (never `find`), skipping dotfiles and dot directories,
then:

1. one `read {kind:"asset", keys:[...]}` (1000 keys per call) asking which of
   those logical paths the branch already binds, and to what digest;
2. uploads only the files whose local sha256 differs from what came back, four
   at a time -- identical bytes anywhere in the tree are still one upload, and
   bytes the platform already holds cost an authorize and nothing else;
3. emits **one** `save` with a `put {kind:"asset", key, digest}` per *changed*
   file. A tree where nothing moved makes no `save` at all and prints
   `{"saved":false,"unchanged":n}`.

The skip count and the dedup count go to stderr so stdout stays one JSON
envelope. The `read` in step 1 is also the freshest look at the branch head
there is, so its `expected` is what the `save` uses unless `--expected` named
one. A server with no batch asset read (404/422) falls back to uploading
everything; the digest hint still short-circuits bytes the platform already
has, so the cost is a round trip per file, not a wrong answer. Any other error
(401, 403, or the 409 a legacy site answers) stops the push.

A relative path that already starts with the prefix is not prefixed twice, so
`push onyx ./public` on a tree containing `assets/app.js` produces the key
`assets/app.js`, not `assets/assets/app.js`.

**An empty tree is a site, not a mistake.** A site whose pages reference no
images, fonts or scripts pushes `{"saved":false,"unchanged":0,"files":0}` and
exits 0, after the same contract check a dry run makes, so `push && save` needs
no special case.

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

## The documents: config, page, changes

`sites-cli schema SLUG` prints the JSON Schema for all of them, generated on
the server from the same tables its validator uses, and every property carries
a one-line description of what the shell emits for it. `sites-cli
validate-config FILE --site SLUG` fetches that schema and runs it locally --
unknown keys with the allowed set beside them, types, enums and missing
required keys, all in one pass, before any write. `sites-cli save SLUG
--config FILE --dry-run` is the server's own answer to the same question.

A 422 `invalid_document` carries `path`, `keys`, `allowed` and `schema: true`,
and reports every problem in the document at once rather than the first.

### config

`name` is required. `title_template` takes two placeholders: `{title}` is the
page's own title and `{site}` is `config.name`, so `"{title} | {site}"` is the
common one and a template with no `{title}` is a 422 that says so. A page whose
own title already names the site sets `metadata.title_is_full: true` rather
than fighting the template.

`business` is the public NAP/identity projection the JSON-LD and the Markdown
alternates are built from. **The public URL is not in here.** `business.url`
used to be accepted and emit nothing; it is a rejection now that names
`connect_domain`. See "Domains" below.

### page

`{format, metadata, body, css}`. `format` is `html` or `markdown`. The body is
a **fragment** -- see the next section. `metadata.title` is required.
`metadata.schema` is an array of JSON-LD nodes (at most 20, 32 KB) merged into
the shell's own `@graph`: objects only, no `@context` (the graph has one), and
no `@id` that collides with a shell node. That is where a page-specific
`FAQPage` or `Article` belongs; a hand-placed `<script type="application/ld+json">`
in the body works but the build reports it as `json_ld_in_body`.

### changes, the op vocabulary

`save` takes an array of change objects. `op` is one of `put`,
`patch_metadata`, `edit_body`, `delete`; `kind` is one of `page`, `layout`,
`include`, `collection`, `redirect`, `config`, `asset`.

| Change | Shape |
|---|---|
| put a page | `{op:"put", kind:"page", key:"/about", document:{format, metadata, body, css}}` |
| put the config | `{op:"put", kind:"config", document:{...}}` -- no `key`, and a put **replaces** the whole document rather than merging |
| put a redirect | `{op:"put", kind:"redirect", key:"/old", document:{to:"/new", status:301}}` (301, 302, 307 or 308) |
| put a collection | `{op:"put", kind:"collection", key:"blog", document:{name, path_prefix, layout, description, order, position}}` |
| bind an asset | `{op:"put", kind:"asset", key:"assets/app.js", digest:"<sha256>"}` -- any site's digest works; one nobody has published is 422 `unknown_asset` |
| **delete** | `{op:"delete", kind:"page", key:"/gone"}` -- destroys the row rather than moving live; repeating it is a 404, not a no-op |
| patch metadata | `{op:"patch_metadata", kind:"page", key:"/", set:{...}, unset:[...]}` -- a shallow merge; `set.custom` replaces the whole custom map |
| edit the body | `{op:"edit_body", kind:"page", key:"/", edits:[{old_text, new_text}]}` -- each `old_text` must match exactly once |

`save SLUG` builds that array for you: see "One save, many documents".

**`put` merges what it omits, clears what it nulls.** A `put page` that omits
`css` keeps the page's existing stylesheet; a `put page` with `css: null`
removes it. Same rule for `metadata`: omitted keeps what the page already has,
`null` clears it. `body` and `format` stay required on every `put page`
either way -- there is no partial put of those two. This is the fix for a
put silently dropping a page's `css` when a caller only meant to touch the
body (`pc_a6905fc1`, a blocker: save ok, build ready, diagnostics unchanged,
`<style>` just gone).

**Ops on one key apply in order, and there is no item cap.** A
`patch_metadata` followed by an `edit_body` on the same key in one `save`
applies both, in the order they appear in `changes` -- they used to be
`overlapping_changes`, so a metadata-plus-body edit could not be one call.
`overlapping_changes` is still the answer for a genuinely conflicting pair on
one key (a `delete` followed by anything, or two `put`s). The old 100-item
cap on `changes` is gone (`pc_0e77d2e1`): a 350-page rebuild is one `save`,
one snapshot, one build, bounded only by the request body -- large enough now
that a real site's worth of pages fits in one call; `push`/`save` do not
batch on the CLI side either.

### list-pages

There is no dedicated route-listing tool, so `sites-cli list-pages SLUG
[--branch B]` composes one from what already exists: `describe_site`'s own
`pending.changes` (the same diff against live that `diff` reports) names
every page and collection key that differs from live, and one `read` per key
fills in `format`, `title` and `digest`. **A route identical to live -- already
published, nothing pending -- has no listing primitive yet and will not
appear here**; that gap is named on stderr rather than hidden (`pc_4ab84e17`:
"I recovered them from build diagnostics"). `read SLUG page` with no `KEY`
points here instead of a bare 422.

### read kinds

`page`, `layout`, `include`, `collection`, `redirect`, `config`, `asset`, plus
two that are not documents anybody authors:

- **`prepared`** returns the HTML and Markdown a ready build already stored for
  one route (`key`, default `/`) on a branch head or on the candidate a review
  binds, with `subject` naming which. Those are the same bytes the preview
  hostname serves, so it is how you read what shipped without a browser. A
  build that is not ready is 409 `build_not_ready`. `keys` reads many routes
  at once -- `sites-cli heads SLUG ROUTE...` is the shell for it -- answering
  per route the same head summary `head_preview` computes for `/`: title,
  description, canonical, robots, lang, which `og` fields are present,
  `json_ld_types`, hreflang alternates, integrations, byte size and the
  artifact digest. A route with no build answers `{key, missing: true}`
  instead of failing the whole batch. This replaced opening a browser once per
  route to diff a head (`pc_8ecfd09c`).
- **`schema`** returns the JSON Schemas above.
- **`guide`** returns prose, not a document: `key` names a topic (`forms`,
  `conventions`, ...) and a missing `key` lists the topics there are.
  `sites-cli guide SLUG [TOPIC]` is the shell for it, generated from one Ruby
  constant on the server so this file and the server's own text cannot drift
  the way the old hand-copied forms contract did.

### forms

A page posts to `/f/<name>`, and `<name>` has to be declared in
`config.forms` -- an undeclared name is a 404 `unknown_form` on a versioned
site, and the build refuses to publish a page that posts to one
(`undeclared_form`). The full contract -- markup, both response modes, the
honeypot field, rate limits and worked examples -- lives on the server now:
`sites-cli guide SLUG forms` prints it, generated from one Ruby constant
rather than kept in sync by hand here.

**No script is required.** The platform used to inject `/platform/forms-1.js`
to write the answer into a `[data-form-result]` element, which was silently
inert because the script never removed the `hidden` attribute it told agents
to author (`pc_8781d8fc`) -- a submission that worked server-side left the
visitor looking at a button that stayed disabled. That script is gone. A
plain `<form action="/f/<name>" method="post">` with no JavaScript at all
renders a full success or error page from the server on submit; a site that
wants an inline result writes its own `fetch` against the JSON contract
instead. `sites-cli fragment` no longer inserts or warns about a result
element -- `--add-form-result` is gone with it.

`config.forms.<name>.redirect_to` names a route in this site; when set, a
successful plain-HTML POST is a 303 there instead of the platform's own
success page (the JSON contract for a `fetch` caller is unchanged either way).
The build warns `redirect_missing_page` when the snapshot has no such route.

A submission whose scalar fields are all blank is rejected (422, not stored,
not mailed) with an error naming what to fill in -- it used to go through
silently. On a preview host, a POST runs the same validation and answers the
same shapes with `preview: true`, storing and mailing nothing, so a form can
be exercised on a preview without putting a real row in anyone's inbox. To do
the same thing deliberately on a **live** host, fill the hidden `website`
honeypot field: the endpoint answers with the form's ordinary success response
and stores nothing and mails nobody. A submission you made on purpose with the
honeypot empty is a real row, and `sites-cli delete-submission SLUG ID` is how
it comes back out.

## Domains: the site's public URL

The canonical link, `og:url`, the sitemap, `llms.txt` and every JSON-LD `@id`
are baked from the site's **primary domain**. No config key sets it. Every
hosted site has `<slug>.gxbsites.com` and that always works; a real hostname is
four commands:

```bash
sites-cli list-domains onyx                    # canonical_url, every claim, what is verified
sites-cli connect-domain onyx onyxmodular.com  # creates the claim, prints the record to publish
# publish that TXT record at the registrar, wait for DNS
sites-cli verify-domain onyx onyxmodular.com   # 200 {verified:true}, or 200 {verified:false, checked:[...]}
sites-cli publish onyx --review last           # republish: the artifact is built for a host
```

`connect-domain` prints one copyable line on stderr:

```
TXT _gxbsites-verify.onyxmodular.com "gxbsites-verify=0123456789abcdef0123456789abcdef"
```

A host that already resolves to us (CNAME to `sites.gxb.vc`, or A to the
server IP) counts as proof too. **A `verified: false` is a 200 and exit 0**:
the request was fine, the record is not published yet, and a person has to go
and publish it. The CLI prints what was looked up and what came back.

Unverified claims may coexist across sites; a host another site holds
*verified* is a 409 `domain_taken`. An unverified claim gets no certificate and
serves no content. `disconnect-domain` removes a claim and refuses to remove
the last hosted one.

`describe_site` carries `canonical_url` and, when the live artifact was
prepared for a different host than the current canonical, `live_prepared_for`
and a `next` saying to wait for the rebuild and republish.

## The reserved /404 page

`/404` is a route a site may author like any other page (`put page key:"/404"`),
and it goes through the same build and the same site layout as every other
page. An unknown route on a tenant host serves those prepared bytes with HTTP
status 404, on live and on a preview alike, no-store. A site that never
authors `/404` still gets one: the build prepares a generic page in the site's
own layout (the site name, one line, a link home), so every versioned site has
a prepared 404 artifact whether or not it wrote one. `/404` is excluded from
the sitemap and `llms.txt` and carries `robots: noindex` on its own. Requesting
`/favicon.ico` with no matching asset is a 302 to the config favicon's 32x32
transform when one is declared, or to the prepared 404 otherwise -- not the
raw platform 404 page a crawler used to get back for a request that was never
for HTML in the first place (`pc_0a5d13b9`). A 500 stays the platform's own
generic page; only 404 is a site's to author.

## Bilingual sites

Ghost's model is the one used here: one collection per language on its own
path prefix, explicit paths, never `Accept-Language` negotiation (prepared
bytes are static and cannot vary by request header).

- `config.locales: {default: "en", others: ["es"]}` -- BCP 47 tags. The old
  single-locale `config.locale` still works and means `locales.default`; nothing
  that only ever set `config.locale` has to change.
- A page's `metadata.lang` names a tag from `locales`; `metadata.translation_of`
  names the route of the page it translates, which must exist in the same
  snapshot and must itself carry the default language.
- The shell emits `<html lang>` per page, `og:locale` per page, `<link
  rel=alternate hreflang>` for every translation pair (including the page
  itself) plus `x-default` pointing at the default-language page, and sitemap
  `xhtml:link` alternates. `llms.txt` lists translations under their source
  page. A page's own `translation_of` is the only pairing needed -- the reverse
  listing on the source page is derived at build time, not authored by hand.
- 126 Spanish routes of one real client site could not be represented before
  this existed (`pc_eede8112`); this is that decision, recorded.

## fragment, and save --page --html

A versioned page is a JSON document whose `body` is a **fragment**: the shell
owns `<!doctype>`, `<html>`, `<head>`, `<title>`, `<meta>`, the one import map
and `<main id="main">`, and every asset reference is a `{{ asset:path }}` tag
rather than a URL. A page authored as a standalone HTML file has to be taken
apart before it can be saved, and doing that by hand is how a site ends up with
a duplicated `id="main"` or a stylesheet nothing loads.

`fragment FILE|- [--prefix assets/] [--page KEY] [--title T]
[--append-changes FILE] [--wrap-body] [--lift-json-ld]`
does the conversion and prints it:

```json
{"ok":true,"data":{"format":"html","metadata":{...},"body":"...","css":"...",
 "config":{"stylesheets":[...],"scripts":[...],"imports":{...},"favicon":{"url":"..."}},
 "assets":[...],"changes":[...],"notes":[...],"warnings":[...]}}
```

`changes` is the real ops array `save` takes -- one `put page` when `--page KEY`
is given, and empty without it. The English sentences are under `notes` and
also go to stderr. `--append-changes FILE` appends to a JSON array on disk, so
a loop over twelve documents produces one file and one `save`:

```bash
for page in home about contact; do
  sites-cli fragment "./build/$page.html" --page "/$page" --append-changes /tmp/changes.json
done
sites-cli save onyx --changes /tmp/changes.json --message "twelve pages, one snapshot"
```

| Source | Becomes |
|---|---|
| `<!doctype>`, `<html>`, `<head>`, `<body>` | dropped |
| `<title>` | `metadata.title` (entity-decoded) |
| `<meta name="description">`, `<meta name="robots" content="noindex">` | `metadata.description`, `metadata.noindex` |
| `<link rel="stylesheet" href="assets/x.css">` | `config.stylesheets` |
| `<link rel="stylesheet" href="https://fonts.googleapis.com/...">` | `metadata.font_stylesheet` -- the one font host the shell links |
| `<link rel="icon" href="assets/x">` | `config.favicon.url` |
| `<script type="importmap">` | `config.imports` -- the shell emits the one import map |
| `<script type="module" src="assets/x.js">` | `config.scripts` as a bare path (a module) |
| `<script src="assets/x.js" defer>` in `<head>` | `config.scripts` as `{path, mode: "classic", defer}` -- a body one stays in the body |
| `<script type="application/ld+json">` in `<head>` | `metadata.schema`, with `@context` stripped and `@graph` splatted |
| `<script src="...analytics.gxb.vc...">` | dropped -- the shell emits the site's own |
| `<style>` (head or body) | the page document's `css` |
| `<a href="#main">` | dropped -- the shell emits its own skip link |
| `<main id="main" class="x">` ... `</main>` | `<div class="x">` ... `</div>` |
| `src`/`href`/`data-asset`/`poster`/`data-src` = `assets/x`, `./assets/x`, `/assets/x` | `{{ asset:assets/x }}` |

Everything else is left alone, including the page's own inline `<script>`.
Every line above is reported on stderr. **The warnings are the things that
shipped clean through twenty-four browser checks and empty build diagnostics:**

| Warning | Why it matters | Flag |
|---|---|---|
| the `<body>` carried attributes | a fragment has no `<body>`. Losing `class="bg-sand-50 text-ink antialiased"` changed font smoothing, the page background and the default text colour on twelve pages, and only a pixel diff caught it | `--wrap-body` re-wraps in a `<div>` carrying them. A background utility on a wrapper paints over a descendant at a negative `z-index`, which `<body>` did not -- for decorative layers, put the background on the body element through the page's `css` instead |
| a JSON-LD script in the body | page structured data belongs in `metadata.schema` | `--lift-json-ld` |
| a third-party stylesheet `config.stylesheets` cannot hold | it is dropped, so the page ships without it | upload it |
| third-party scripts, in the head or left in the body | the head's went with the head; the body's load from someone else's origin on every view | -- |
| a declared **SVG favicon** | linked as it stands and not resizable, so the site ships no apple-touch-icon and no raster sizes (`favicon_svg_unresizable`) | rasterize and declare the `.png` |
| an `srcset` that was not rewritten | bind each candidate by hand, or use one `src` | -- |

A `/f/<name>` form needs no result element and no submit-handler care any
more: the platform no longer ships a document-level submit listener, so a
page's own handler on the form does not double-fire, and a plain POST renders
its own response page. See "forms" above and `sites-cli guide SLUG forms`.

## One save, many documents

Every document flag below repeats, keeps its order, and ends up in **one**
`changes` array, one snapshot and one build. Twelve pages used to be twelve
commands and twelve builds.

```bash
sites-cli save onyx --config ./config.json \
  --page /        --html ./build/index.html \
  --page /about   --html ./build/about.html   --title "About Onyx" \
  --page /contact --html ./build/contact.html \
  --page /blog/first --markdown ./posts/first.md \
  --collection blog ./collections/blog.json \
  --redirect /old-about /about \
  --delete page /retired \
  --asset assets/app.js ./build/assets/app.js \
  --message "onyx, one snapshot"
```

| Flag | Becomes |
|---|---|
| `--page KEY` | opens a page; the next `--html`/`--markdown`/`--title`/`--metadata` belong to it |
| `--html FILE` | the conversion above, as a `put page` |
| `--markdown FILE` | a `put page` with `format: "markdown"`; the title is `--title` or the file's first `# ` heading |
| `--title T`, `--metadata FILE` | merged into that page's metadata; `--title` wins |
| `--config FILE` | a `put config`, always first in the array |
| `--collection KEY FILE` | a `put collection` |
| `--redirect FROM TO` | a `put redirect` |
| `--delete KIND KEY` | a `delete` |
| `--asset KEY FILE-or-DIGEST` | a `put asset`. A file is hashed locally; `save` binds digests and uploads nothing, so `upload` or `push` the bytes first |

`--changes FILE` still takes a raw array, and `--changes` together with the
document flags is a usage error: one of them would have to win. `--dry-run`
sends `dry_run: true`, which validates the whole array, resolves the digests
and answers `{would_change_keys, diagnostics}` without creating a snapshot or a
build; it leaves the remembered head alone.

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

Polls `describe_site` until the branch's build settles, then stops, and prints
the whole branch payload: `preview_status`, `preview_url`, `diagnostics`,
`head_preview` (the title, description, theme_color, canonical, robots,
favicon, json_ld_types and manifest_name the build stored), `integrations` and
`canonical_url`. There is nothing left to run a second `describe` for.

| Status | wait-preview | Exit |
|---|---|---|
| `queued`, `building` | keep polling until `--timeout` | 0 / 1 on timeout |
| `ready` | print the payload | 0 |
| `provisioning` | terminal: the build is good, and the host has not finished provisioning the hostname, so it may not open yet | 0 |
| `invalid` | terminal: source diagnostics say what to fix; it cannot be published | 1 |
| `failed` | terminal: infrastructure fault, being retried | 1 |
| `revoked` | terminal: every preview of this snapshot was withdrawn; `save` again for a new one | 1 |
| `unavailable` | terminal: the snapshot predates builds | 1 |
| absent / anything else | error (`PREVIEW_MISSING` / `PREVIEW_UNKNOWN`) | 1 |

A preview hostname is `<token>--<slug>.gxbsites.com` -- **two** dashes. Grants
minted before 2026-09-22 use one and still resolve. The `*.gxbsites.com`
wildcard certificate is installed, so a finished build normally settles
`ready` with an openable URL.

A preview URL is read access to that exact snapshot for whoever holds it.
Never paste one into a ticket, a Slack thread or an email; `revoke-preview`
withdraws one that got out.

## check

`check URL [--against URL2] [--width 1440] [--height 900] [--screenshot PATH]
[--viewport] [--ignore SUBSTR] [--no-probe]` opens the URL in a fresh
`agent-browser` session, waits for `networkidle`, and prints:

```json
{"status":200,"console_errors":[],"failed_requests":[{"url":"...","status":404}],"title":"Onyx","url":"..."}
```

Exit 1 on any console error or failed request. `console_errors` merges
`agent-browser console` (messages of type `error`) with `agent-browser errors`
(uncaught page errors) -- that pair is its nearest equivalent to a single
console-error stream. `failed_requests` is every request with no status or a
status >= 400, so a site with no favicon shows `/favicon.ico` 404; drop it with
`--ignore favicon`. The session is always closed, **by name, never
`close --all`**: seven of these run at once and `--all` is a cross-agent kill.

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
`--no-probe` turns the whole thing off. A preview hostname that resolves but
cannot finish a TLS handshake is `PREVIEW_TLS` rather than a bare browser
error: that is the host's certificate, and the build itself is fine.

### --against: is the rebuild the same page?

`check URL --against URL2` opens both in the one session and compares:

- **the head**: `title`, `description`, `canonical`, `robots`, `theme-color`,
  `og:image`, `twitter:card`, `favicon`, and the JSON-LD `@type` list;
- **the counts**: images, scripts, stylesheets;
- **the visible text**, normalised -- tags stripped, block boundaries kept as
  line breaks, curly quotes and dashes folded to ASCII, whitespace collapsed.

It prints `differences` (one line per head or count field that moved) and
`text_diff` (a unified diff) in the payload and in prose on stderr, and exits 1
on any difference `--ignore` does not cover. `--ignore canonical` is the usual
one while a rebuild is still on a staging hostname.

### screenshots

`--screenshot PATH` captures the **full page** by default; `--viewport` is the
old behaviour. After the capture, `check` reads the PNG header and refuses to
call a blank image a success: a full-page capture under 6 KB, or any capture
whose bytes-per-pixel says it is one flat colour, sets `screenshot_blank` with
the reason and exits 1. That is a heuristic, not a decoder, and it catches the
real case -- a page that paints from an inline script fires `networkidle`
before first paint, and a 4.9 KB all-background PNG used to be reported as a
clean check.

## Worked example: a three-page site

One personal token in `SITES_CLI_TOKEN`, a directory holding `index.html`,
`about.html`, `contact.html`, `assets/`, and a `config.json`:

```bash
# 0. the site. Nothing else is needed: no admin page, no site token.
sites-cli create-site onyx --name "Onyx"      # remembers the new draft head

# 1. the public tree: contract checked, unchanged files skipped, bytes the
#    platform already holds not sent at all
sites-cli push onyx ./public --dry-run        # one describe_site: right contract? right branch?
sites-cli push onyx ./public                  # batch read + uploads + one save

# 2. the config, checked against the server's own schema before any write
sites-cli validate-config ./config.json --site onyx

# 3. all three pages and the config in ONE save: one snapshot, one build
sites-cli save onyx --config ./config.json \
  --page /        --html ./public/index.html \
  --page /about   --html ./public/about.html \
  --page /contact --html ./public/contact.html \
  --message "onyx, three pages"

# 4. wait for the build (head_preview and integrations come back with it),
#    then look at it in a real browser
sites-cli wait-preview onyx
sites-cli check https://<token>--onyx.gxbsites.com --screenshot /tmp/onyx.png

# 5. publish the whole branch delta
sites-cli describe onyx                       # remembers branches[].review
sites-cli publish onyx --review last

# 6. the public URL
sites-cli connect-domain onyx onyxmodular.com # prints the TXT record to publish
sites-cli verify-domain onyx onyxmodular.com  # once DNS has propagated
sites-cli publish onyx --review last          # the artifact is built for a host
```

To see the conversion before committing to it, `sites-cli fragment
./public/index.html --page /` prints exactly what `save` would send and makes
no request. To ship one page and its assets first, publish is two calls:

```bash
sites-cli publish onyx --keys page:/about     # 200 published:false + its own review
sites-cli wait-preview onyx                   # the candidate has its own build
sites-cli publish onyx --review last          # this is what flips live
```

A missing static dependency (`BufferGeometryUtils.js`) makes the `save`
succeed and `wait-preview` exit 1 with `preview_status: "invalid"` and a
diagnostic naming the importer and the specifier. Upload it, `save` the asset
put, and take the new review. No silent rewrite.

Selecting a page whose layout is still unpublished is 422
`unpublished_dependency` naming the exact keys to add, and a review minted
before somebody else published is 409 `upstream_changed` pointing at
`merge-live`. Neither is retried; both name the next call.

## Rebuilding an existing site

Seven agents rebuilt seven live sites in one afternoon and converged on this.
`SOURCE` is the site as it stands, `SLUG` is the new versioned site.

```bash
# 1. Fetch the source: every page, its assets, robots.txt, llms.txt, sitemap.
#    Keep the tree as it is served, so the asset keys match the references.

# 2. The site, and the asset tree.
sites-cli create-site SLUG --name "Name"
sites-cli push SLUG ./build/assets --dry-run
sites-cli push SLUG ./build/assets

# 3. Convert every page into one changes file, then save once.
rm -f /tmp/changes.json
for page in index about services contact; do
  route=$([ "$page" = index ] && echo / || echo "/$page")
  sites-cli fragment "./build/$page.html" --page "$route" \
    --wrap-body --lift-json-ld \
    --append-changes /tmp/changes.json
done
sites-cli validate-config ./build/config.json --site SLUG
sites-cli save SLUG --changes /tmp/changes.json --message "rebuild: pages"
sites-cli save SLUG --config ./build/config.json --message "rebuild: config"

# 4. Build, then compare every page against the source it replaces.
sites-cli wait-preview SLUG
for route in / /about /services /contact; do
  sites-cli check "https://<token>--SLUG.gxbsites.com$route" \
    --against "https://SOURCE$route" \
    --ignore canonical --ignore og:url \
    --screenshot "/tmp/shots/$(echo "$route" | tr / _).png"
done

# 5. Publish, then move the hostname.
sites-cli publish SLUG --review last
sites-cli connect-domain SLUG SOURCE
sites-cli verify-domain SLUG SOURCE
sites-cli publish SLUG --review last
```

Read every `fragment` warning before step 3 finishes. Each one in that table is
something that shipped clean through a full browser check on a real client's
site and had to be found by pixel diff or by reading platform source.

Two things `--against` will report while the site is still on a staging
hostname, and both are expected until step 5: `canonical` and `og:url`. Ignore
those two by name rather than turning the comparison off, so everything else
still fails the check.

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
binary against it (182 checks): token/site binding, the nonzero 409 exit with
no automatic retry or reread and no cache poisoning from the conflict body,
from a `read --at` or from a `save --dry-run`, expected-token persistence,
review caching and forgetting, every v2 subcommand's request shape against
`Mcp::ToolRegistry`, each terminal `preview_status`, byte-for-byte streamed
binary uploads (single PUT and multipart), the dedup fast path and the
structured error an unexpected authorize shape becomes, upload content types
and bounded parallelism, push change-list generation, dedup, the batch-read
skip and its fallback, the empty tree, the platform door, the personal token at
the site doors, the domain tools and the record `connect-domain` prints,
`delete_submission`, `schema` and the local `validate-config` pass,
`list_submissions` and its `read_submissions` 403, `get_analytics`, the
`fragment` conversion and every warning it raises, multi-document `save` and
its config merge, `save --dry-run`, the dry-run contract check, the `check`
wrapper against a stub browser including the CORS probe, the preview-TLS hint
on both host shapes, `--against` and the blank-screenshot refusal, that
`manual` and the dispatch agree, that stdout is one JSON object per command,
that no bearer token reaches stdout or state.json, `list-pages`'s composition
off `describe_site`'s pending diff (and the plural-namespace/singular-kind
mapping it depends on), `guide`'s topic listing and its text/JSON output
modes, `heads`'s bulk request shape and its fallback note against an old
single-route response, `archive-branch` forgetting a branch's `expected` and
`last_review` state, the `publish` publication-number note, and that the
version handshake fires for a genuine round-2 kind mismatch and stays silent
for an unrelated error on the same code path.
