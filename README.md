# sites-cli

Drive a GXB tenant site on the `sites` Rails platform from the shell. The v2
subcommands mirror the plan 30 MCP tools one to one
(`plans/30-agent-first-sites.md` in `~/projects/sites`), so anything an agent
can do through MCP or Chat is one shell command here.

See `AGENTS.md` for the full reference (subcommand -> tool -> capability
table, state file keys, the worked Onyx example). Quick start:

```bash
# one personal token (sk_user_...) in SITES_CLI_TOKEN opens all of this
sites-cli list-sites                    # every site you can read
sites-cli create-site SLUG --name "Name"
sites-cli create SLUG --name "Name"     # a legacy site through the runner, no token

# versioned sites. A site token in ~/.config/sites-cli/tokens.json is used for
# its own slug when there is one; otherwise the personal token names the site.
sites-cli describe onyx                 # capabilities, live, branches, pending
sites-cli push onyx ./public --dry-run  # right contract? right branch? what changed?
sites-cli push onyx ./public            # skip unchanged, upload the rest, one save
sites-cli save onyx --page / --html index.html --config config.json
sites-cli wait-preview onyx             # 1 on invalid/failed/revoked
sites-cli check https://<token>-onyx.gxbsites.com --screenshot onyx.png
sites-cli publish onyx --review last    # or --review "$REVIEW"
sites-cli list-submissions onyx         # needs a read_submissions token
sites-cli analytics onyx --period 30d

# legacy file-API sites
sites-cli read_file SLUG about.md
sites-cli write_file SLUG about.md --content "$(cat about.md)"
sites-cli publish SLUG about.md
```

Every tool subcommand prints the raw `{ok, data}` envelope, or
`{ok:false, error, code, status, body}` with the server's full structured body
on a non-2xx. Exit code is 0 or 1. **stdout is one JSON object, always** --
notes, warnings and next steps go to stderr, so `sites-cli … | jq` works.

## The three ergonomics that matter

- `--expected` (the branch-head CAS token) defaults to the last one this CLI
  saw for that slug+branch, written to `~/.config/sites-cli/state.json` after
  every successful `describe`/`read`/`save`/`create-branch`/`diff`/`merge-live`.
  `--idempotency-key` defaults to a fresh UUID.
- **A 409 `branch_changed` is never retried and never updates that cache**, and
  neither does a `read --at` (a historical read answers with the snapshot token
  it read, not a head). A 409 prints the structured body and exits 1. Rerun
  `describe`, look at what moved, then save again.
- **`--review` never defaults.** The last review printed for a slug+branch is
  remembered separately and only `--review last` spends it, so publishing a
  stale candidate is always deliberate.

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
exists.

## What the server has

Slice D (builds, preview hostnames, real `preview_status`, `revoke_preview`) is
deployed. Slice E (`publish` both forms, `merge-live`, `resolve-merge`,
`history`, `read --at`, the batch asset `read`, `archive-branch`) and slice F
(the platform endpoint, personal tokens, `read_submissions`) are on `main` and
deploy after review; until then a production server answers `unknown tool` for
those names and 404 at the platform path, and the CLI prints that verbatim.

A personal token at a site door needs the server change on branch
`personal-door` (`plans/reviews/30/personal-door-report.md`). Against a server
without it, a slug with no site token answers 403 `capability_denied` saying a
personal token can only call the platform endpoint -- printed verbatim, as
always.

The `*.gxbsites.com` wildcard certificate is not installed yet, so a finished
build reports `preview_status: "provisioning"` and its hostname cannot complete
a TLS handshake. `wait-preview` treats that as terminal and successful, and
says so, rather than spinning out the timeout; `check` on such a hostname
answers `PREVIEW_TLS` and names the certificate rather than the build.

## fragment

A versioned page body is a fragment, not a document: the shell owns
`<!doctype>`, `<html>`, `<head>`, `<title>`, `<meta>`, the import map and
`<main id="main">`, and assets are `{{ asset:path }}` tags. `sites-cli fragment
index.html` does that conversion and prints what it changed; `sites-cli save
SLUG --page / --html index.html --config config.json` does the same thing and
sends it as one `save`. It warns about the things that only break later: an
SVG favicon (a hard 415 on every page), an external stylesheet, a page that
binds its own `/f/` submit handler without `stopPropagation()`.

## check

`check` drives `agent-browser` (see `~/notes/web-browsing.md`). It has no
single console-error stream, so the CLI merges `agent-browser console`
(messages of type `error`) with `agent-browser errors` (uncaught page errors)
into one `console_errors` list, and reads `agent-browser network requests` for
anything with no status or a status >= 400. A site with no favicon therefore
reports a `/favicon.ico` 404; drop it with `--ignore favicon`. The browser
session is always closed, including on failure.

A blocked cross-origin subresource and a missing one look identical in a
browser -- no status, no console message -- so `check` asks the object for
itself with an `Origin` header and reports `diagnosis: "cors_blocked"` when it
is there and sends no `access-control-allow-origin`. `--no-probe` turns that
off.

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
