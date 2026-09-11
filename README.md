# sites-cli

Manage GXB tenant sites on the `sites` Rails platform, and author an
existing site's pages/design as text files over its agent HTTP gateway
(`plans/24-agent-sites.md` in `~/projects/sites`).

Local sites live in `~/projects/sites`. Use `SITES_ROOT` to override.

See `AGENTS.md` for the full command reference. Quick start:

```bash
# Staff-only, runner-based
sites-cli create SLUG [--name NAME] [--team TEAM] [--prod]  # provision an empty site
sites-cli list [--prod]                                      # list tenant sites
sites-cli show SLUG [--prod]                                  # show one site
sites-cli open SLUG [--prod]                                  # print URL; open with --prod

# Text file tools, once a site has a token in ~/.config/sites-cli/tokens.json
sites-cli describe_site SLUG
sites-cli read_file SLUG about.md
sites-cli write_file SLUG about.md --content "$(cat about.md)"
sites-cli write_file SLUG assets/hero.jpg --file ./hero.jpg
sites-cli publish SLUG about.md
```

Without `--prod`, the runner-based commands run `bin/rails runner` in
`SITES_ROOT`. With `--prod`, they pipe a self-contained runner file through
`kamal-cli runner` from the sites app -- requires `kamal-cli` on PATH.

There is no folder importer (`push`/`site.yml`) any more. `create` provisions
an empty site; every page and design edit after that goes through the same
six text file tools an agent uses.

## Setup

```bash
cd ~/tools/sites-cli
ln -s ~/tools/sites-cli/sites-cli ~/bin/sites-cli
```

After `create`, mint an API token (`Admin::ApiTokensController` on the
site's admin page) and put it in `~/.config/sites-cli/tokens.json` as
`{"SLUG": "sk_site_..."}`. That file lives outside this git checkout; the
CLI tightens it to mode 600 on every read.

## Testing

```bash
ruby test_sites_cli.rb
```
