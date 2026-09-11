# sites-cli

Staff-only create/list/show/open for a GXB tenant site on the `sites` Rails
platform, and editing an existing site's pages/design as text files over the
agent HTTP gateway (`plans/24-agent-sites.md` in `~/projects/sites`).

## Site folder commands (runner-based, staff-only)

```bash
sites-cli list [--prod]             # list tenant sites
sites-cli show SLUG [--prod]        # show one site
sites-cli open SLUG [--prod]        # print URL; open browser with --prod
sites-cli create SLUG [--name NAME] [--team TEAM] [--prod]  # staff-only: create an empty site
```

- Default runs `bin/rails runner` in `SITES_ROOT` (default `~/projects/sites`).
- `--prod` runs `kamal-cli runner FILE.rb` from `SITES_ROOT`.
- `create` is staff-only and mints no agent-facing `create_site` tool. After
  it, mint an API token (`Admin::ApiTokensController` on the site's admin
  page) and set a form recipient -- neither happens automatically. Put the
  token in `~/.config/sites-cli/tokens.json` as `{"SLUG": "sk_site_..."}`.
  That file lives outside this git checkout; the CLI tightens it to mode
  600 on every read, whether or not you set that yourself.
- There is no `push`/`site.yml` folder importer any more. A new site starts
  empty from `create`; everything after that goes through the six text
  file tools below, the same path an agent uses.

## Text file tools (HTTP, once a site has a token)

Six tools -- describe_site, list_files, read_file, write_file, edit_file,
publish -- the same ones Chat and native MCP call, over `POST
/api/v1/tools` on `sites.gxb.vc` (set `SITES_CLI_HOST` to point at a dev
server instead).

```bash
sites-cli describe_site SLUG [PATH]                     # alias: describe
sites-cli list_files SLUG [--prefix _posts/]             # alias: list SLUG
sites-cli read_file SLUG about.md [--view live]          # alias: read
sites-cli write_file SLUG about.md --content "$(cat about.md)" [--expected-version V]  # alias: write
sites-cli edit_file SLUG about.md --edits-file edits.json [--expected-version V]       # alias: edit
sites-cli publish SLUG about.md [--expected-version V]   # or SLUG design
```

- `read_file` remembers `{slug, path, version}` in
  `~/.config/sites-cli/state.json`, so `write_file`/`edit_file`/`publish`
  can omit `--expected-version` right after a `read_file` of that same
  path. A write never preceded by a read still fails (no version to send).
  A 409 is never silently retried -- rerun `read_file`/`describe_site` and
  look at it before trying again.
- `--edits-file` is a JSON array of `{"old_text": "...", "new_text": "..."}`;
  each `old_text` must match the file's current source exactly once.
- `write_file SLUG assets/hero.jpg --file ./hero.jpg [--expected-version V]`
  uploads a photo: authorize -> single presigned PUT, streamed straight from
  disk (`body_stream`, not buffered in memory) -> complete -> poll until
  ready/failed. 5a only -- jpg/png/webp/gif, 25 MiB / 40 megapixel limits, no
  multipart/resume (slice 5b). Prints the CDN original URL on success;
  remembers the version like read_file does.
- `sites-cli list SLUG` lists that site's files, not all tenant sites.
  `sites-cli list` with no slug still lists all sites.
- A non-2xx response (409 conflict, 422 invalid, or an upload rejection)
  prints `{ok: false, error, code, status, body}` -- `status` is the real
  HTTP status and `body` is the server's full structured JSON (e.g. a 409's
  `path`/`version`), not just a flattened message. Nonzero exit either way.
  A 409 is never retried automatically; rerun `read_file`/`describe_site`
  yourself and look at it before writing again.

## Examples

```bash
sites-cli create metrolocksmith --name "Metro Locksmith"
sites-cli open metrolocksmith --prod

sites-cli describe_site acme
sites-cli read_file acme about.md
sites-cli write_file acme about.md --content "$(cat about.md)"
sites-cli write_file acme assets/hero.jpg --file ./hero.jpg
sites-cli publish acme about.md
```

Requires `kamal-cli` on PATH for `--prod`.

## Testing

```bash
ruby test_sites_cli.rb
```

Spins up a stub HTTP server in-process and drives the real CLI binary
against it: token/site binding, nonzero conflict exit with no automatic
retry or reread, byte-for-byte streamed binary upload, and no bearer token
leaking into anything printed.
