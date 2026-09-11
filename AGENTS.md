# sites-cli

Insert or update a GXB tenant site on the `sites` Rails platform from a local
folder, and edit an existing site's pages/design as text files over the
agent HTTP gateway (`plans/24-agent-sites.md` in `~/projects/sites`).

## Site folder commands (runner-based)

```bash
sites-cli list [--prod]             # list tenant sites
sites-cli show SLUG [--prod]        # show one site
sites-cli push DIR [--prod]         # upsert site from folder
sites-cli open SLUG [--prod]        # print URL; open browser with --prod
sites-cli create SLUG [--name NAME] [--team TEAM] [--prod]  # staff-only: create an empty site
```

- Default runs `bin/rails runner` in `SITES_ROOT` (default `~/projects/sites`).
- `--prod` runs `kamal-cli runner FILE.rb` from `SITES_ROOT`.
- `create` is staff-only and mints no agent-facing `create_site` tool. After
  it, mint an API token (`Admin::ApiTokensController` on the site's admin
  page) and set a form recipient -- neither happens automatically. Put the
  token in `~/.config/sites-cli/tokens.json` as `{"SLUG": "sk_site_..."}`
  (the CLI writes that file mode 600).

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
- `write --file` (binary/media upload) is not implemented yet -- it waits
  for slice 5a's upload transport. Use the admin media page for images in
  the meantime.
- `sites-cli list SLUG` lists that site's files, not all tenant sites.
  `sites-cli list` with no slug still lists all sites.

## Folder layout (site folder commands)

```
DIR/site.yml      # slug, name, business, theme, page, tailwind, noindex, status
DIR/index.html    # inner HTML only; Tailwind v4 utilities
DIR/assets/*      # optional png/jpg/jpeg/webp/gif, attached by filename
```

## Examples

```bash
sites-cli push ./metrolocksmith
sites-cli push ./metrolocksmith --prod
sites-cli open metrolocksmith --prod

sites-cli describe_site acme
sites-cli read_file acme about.md
sites-cli write_file acme about.md --content "$(cat about.md)"
sites-cli publish acme about.md
```

Requires `kamal-cli` on PATH for `--prod`.
