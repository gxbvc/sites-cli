# sites-cli

Drive a GXB tenant site on the `sites` Rails platform from the shell. The v2
subcommands mirror the plan 30 MCP tools one to one
(`plans/30-agent-first-sites.md` in `~/projects/sites`), so anything an agent
can do through MCP or Chat is one shell command here.

See `AGENTS.md` for the full reference (subcommand -> tool -> capability
table, state file keys, the worked Onyx example). Quick start:

```bash
# staff, runner-based
sites-cli create SLUG --name "Name"     # provision a site
sites-cli list                          # every tenant site
sites-cli open SLUG --prod              # print + open the URL

# versioned sites, once the site has a token in ~/.config/sites-cli/tokens.json
sites-cli describe onyx                 # capabilities, live, branches, pending
sites-cli push onyx ./public            # skip unchanged, upload the rest, one save
sites-cli save onyx --changes changes.json
sites-cli wait-preview onyx             # 1 on invalid/failed/revoked
sites-cli check https://<token>-onyx.gxbsites.com --screenshot onyx.png
sites-cli publish onyx --review last     # or --review "$REVIEW"

# legacy file-API sites
sites-cli read_file SLUG about.md
sites-cli write_file SLUG about.md --content "$(cat about.md)"
sites-cli publish SLUG about.md
```

Every tool subcommand prints the raw `{ok, data}` envelope, or
`{ok:false, error, code, status, body}` with the server's full structured body
on a non-2xx. Exit code is 0 or 1.

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

## What the server has

Slice D (builds, preview hostnames, real `preview_status`, `revoke_preview`) is
deployed. Slice E (`publish` both forms, `merge-live`, `resolve-merge`,
`history`, `read --at`, the batch asset `read`, `archive-branch`) is on `main`
and deploys after review; until then a production server answers `unknown tool`
for those names and the CLI prints that verbatim.

The `*.gxbsites.com` wildcard certificate is not installed yet, so a finished
build reports `preview_status: "provisioning"` and its hostname cannot complete
a TLS handshake. `wait-preview` treats that as terminal and successful, and
says so, rather than spinning out the timeout.

`create-site` posts the platform `create_site` tool, but `/api/v1/tools` only
authenticates site-bound tokens and the server answers those 403
`capability_denied`, so it cannot work over HTTP. Use the runner command
`sites-cli create SLUG --name NAME`.

## check

`check` drives `agent-browser` (see `~/notes/web-browsing.md`). It has no
single console-error stream, so the CLI merges `agent-browser console`
(messages of type `error`) with `agent-browser errors` (uncaught page errors)
into one `console_errors` list, and reads `agent-browser network requests` for
anything with no status or a status >= 400. A site with no favicon therefore
reports a `/favicon.ico` 404; drop it with `--ignore favicon`. The browser
session is always closed, including on failure.

## Setup

```bash
cd ~/tools/sites-cli
ln -s ~/tools/sites-cli/sites-cli ~/bin/sites-cli
```

After `create`, mint an API token (`Admin::ApiTokensController` on the site's
admin page) and put it in `~/.config/sites-cli/tokens.json` as
`{"SLUG": "sk_site_..."}`. That file lives outside this git checkout; the CLI
tightens it to mode 600 on every read.

`SITES_ROOT` (default `~/projects/sites`) points the runner commands at the
Rails app; `SITES_CLI_HOST` (default `https://sites.gxb.vc`) points the HTTP
commands at a different server. `--prod` needs `kamal-cli` on PATH.

## Testing

```bash
ruby test_sites_cli.rb
```
