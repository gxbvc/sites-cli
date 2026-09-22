# sites-cli

Drive a GXB tenant site on the `sites` Rails platform from the shell. The v2
subcommands mirror the plan 30 MCP tools one to one
(`plans/30-agent-first-sites.md` in `~/projects/sites`), so anything an agent
can do through MCP or Chat is one shell command here.

See `AGENTS.md` for the full reference (the subcommand table, the document
schemas, the state file keys, the rebuild recipe). Quick start:

```bash
# one personal token (sk_user_...) in SITES_CLI_TOKEN opens all of this
sites-cli list-sites                    # every site you can read
sites-cli create-site SLUG --name "Name"

# versioned sites. A site token in ~/.config/sites-cli/tokens.json is used for
# its own slug when there is one; otherwise the personal token names the site.
sites-cli describe onyx                 # capabilities, live, branches, pending
sites-cli push onyx ./public            # skip unchanged, upload the rest, one save
sites-cli validate-config config.json --site onyx
sites-cli save onyx --config config.json \
  --page /      --html index.html \
  --page /about --html about.html       # one changes array, one snapshot, one build
sites-cli wait-preview onyx             # 1 on invalid/failed/revoked
sites-cli check https://<token>--onyx.gxbsites.com --against https://onyx.com
sites-cli publish onyx --review last    # or --review "$REVIEW"
sites-cli connect-domain onyx onyx.com  # prints the DNS record to publish
sites-cli list-submissions onyx         # needs a read_submissions token

sites-cli manual                        # the subcommand table, from the code
sites-cli tools onyx                    # the server's own tool index for a site
sites-cli schema onyx config            # the config document's JSON Schema
```

Every tool subcommand prints the raw `{ok, data}` envelope, or
`{ok:false, error, code, status, body}` with the server's full structured body
on a non-2xx. Exit code is 0 or 1. **stdout is one JSON object, always** --
notes, warnings and next steps go to stderr, so `sites-cli … | jq` works, and
nothing ever prints a Ruby backtrace.

## The four ergonomics that matter

- `--expected` (the branch-head CAS token) defaults to the last one this CLI
  saw for that slug+branch, written to `~/.config/sites-cli/state.json` after
  every successful `describe`/`read`/`save`/`create-branch`/`diff`/`merge-live`.
  `--idempotency-key` defaults to a fresh UUID.
- **A 409 `branch_changed` is never retried and never updates that cache**, and
  neither does a `read --at` or a `save --dry-run`. A 409 prints the structured
  body and exits 1. Rerun `describe`, look at what moved, then save again.
- **`--review` never defaults.** The last review printed for a slug+branch is
  remembered separately and only `--review last` spends it, so publishing a
  stale candidate is always deliberate.
- **One `save` carries as many documents as you name.** `--page KEY --html
  FILE`, `--markdown`, `--config`, `--collection`, `--redirect`, `--delete` and
  `--asset` all repeat and keep their order, and the whole command is one
  changes array, one snapshot and one build.

## publish is two calls

`publish SLUG --keys page:/about` proposes a candidate: live plus those keys
plus the assets they reach. It answers a 200 carrying `published: false` and
its own `review` and `preview_url`. Live is untouched. That is exit 0 -- the
request succeeded -- but it is never "shipped": the second call,
`publish SLUG --review last`, is the one that flips live. The CLI says so on
stderr every time it sees `published: false`.

## Two doors, one credential

There are still two doors. `list_sites` and `create_site` have no site to be
bound to, so they go to `POST /api/v1/platform/tools`; every other tool goes to
`POST /api/v1/tools`, and uploads to `/api/v1/media/uploads`.

One **personal** token opens both (`sk_user_...`, minted at
`https://sites.gxb.vc/profile`, GXB staff only, from `SITES_CLI_TOKEN` or the
`_platform` entry in `~/.config/sites-cli/tokens.json`). At a site door the
request names the site, and the server resolves it through the sites that
person can read and checks their capabilities on it. So

```bash
sites-cli create-site onyx --name "Onyx" && sites-cli push onyx ./public
```

works with nothing in between -- no admin page, no second token.

A **site token** (`tokens.json` under the slug) is for handing one site to
someone who should have only that site. It wins for its own slug, and those
requests are sent exactly as they always were. A site token at the platform
door is a 403, printed verbatim, and so is a site token naming a different
site. A site you cannot read is a 404, never a 403.

A personal token's scopes are a ceiling on top of the person's capabilities:
the smaller of the two wins, and `describe` reports the intersection. `read`
stopped containing `read_submissions`, so `list-submissions` needs a token
minted with that box ticked; a scope cannot be added to a token that already
exists. `manage_domains` is its own capability the same way.

## What the server has: ask it

`sites-cli tools SLUG` prints the server's own tool index for that site and
`sites-cli schema SLUG` prints the config, page, collection, redirect and
changes schemas. A paragraph in a README cannot stay true across a deploy; two
commands can.

## The public URL comes from a domain

The canonical link, `og:url`, the sitemap, `llms.txt` and every JSON-LD `@id`
are baked from the site's primary domain, and no config key sets it.
`<slug>.gxbsites.com` always works. A real hostname is `connect-domain` (which
prints the TXT record to publish), then `verify-domain`, then publish again.

## fragment

A versioned page body is a fragment, not a document: the shell owns
`<!doctype>`, `<html>`, `<head>`, `<title>`, `<meta>`, the import map and
`<main id="main">`, and assets are `{{ asset:path }}` tags. `sites-cli fragment
index.html --page /` does that conversion and prints the real `put page` change
`save` takes; `--append-changes FILE` collects many into one file so twelve
pages are one snapshot.

It warns about what it drops that nothing else catches: the `<body>`
attributes (`--wrap-body` re-wraps them), a `/f/` form with no
`[data-form-result]` element (`--add-form-result` inserts one), a JSON-LD
script in the body (`--lift-json-ld` moves it to `metadata.schema`), a
third-party stylesheet, an unresizable SVG favicon, and a page that binds its
own `/f/` submit handler without `stopPropagation()`.

## check

`check` drives `agent-browser` (see `~/notes/web-browsing.md`) and reports
console errors and failed requests. It merges `agent-browser console` (type
`error`) with `agent-browser errors` into one `console_errors` list and reads
`agent-browser network requests` for anything with no status or >= 400; drop
noise with `--ignore favicon`. The session it opens is closed by name, never
`close --all`.

`check URL --against URL2` diffs the head (title, description, canonical,
robots, theme-color, og:image, twitter:card, favicon, JSON-LD types), the
image/script/stylesheet counts and the normalised visible text, prints a
unified diff and exits 1 on any difference `--ignore` does not cover. That is
how you prove a rebuild matches the site it replaces.

`--screenshot PATH` captures the full page (`--viewport` for the old
behaviour), and a capture that comes back blank exits 1 with the reason
instead of reporting a clean check.

A blocked cross-origin subresource and a missing one look identical in a
browser -- no status, no console message -- so `check` asks the object for
itself with an `Origin` header and reports `diagnosis: "cors_blocked"` when it
is there and sends no `access-control-allow-origin`. `--no-probe` turns that
off.

## Uploads

`upload` and `push` take any content type: the extension table is a hint, and
anything it does not name is typed by extension and falls back to
`application/octet-stream`. The server refuses only what a browser would run as
a page on the asset CDN, and that message is printed verbatim. Bytes the
platform already holds anywhere cost one authorize and no PUT. Files over
25 MB take the multipart transport, four parts in flight, each retried with a
fresh presign.

## Setup

```bash
cd ~/tools/sites-cli
ln -s ~/tools/sites-cli/sites-cli ~/bin/sites-cli
```

Mint your own personal token at `https://sites.gxb.vc/profile` and put it in
`SITES_CLI_TOKEN`, or in `~/.config/sites-cli/tokens.json` as `"_platform"`.
That is everything one person needs. A per-site token
(`Admin::ApiTokensController` on the site's admin page, then `{"SLUG":
"sk_site_..."}` in the same file) is for giving somebody access to that one
site. The file lives outside this git checkout; the CLI tightens it to mode
600 on every read.

`SITES_ROOT` (default `~/projects/sites`) points the runner commands at the
Rails app; `SITES_CLI_HOST` (default `https://sites.gxb.vc`) points the HTTP
commands at a different server. `--prod` needs `kamal-cli` on PATH.

## Testing

```bash
ruby test_sites_cli.rb
```
