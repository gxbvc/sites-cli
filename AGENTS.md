# sites-cli

Insert or update a GXB tenant site on the `sites` Rails platform from a local folder.

## Commands

```bash
sites-cli list [--prod]             # list tenant sites
sites-cli show SLUG [--prod]        # show one site
sites-cli push DIR [--prod]         # upsert site from folder
sites-cli open SLUG [--prod]        # print URL; open browser with --prod
```

- Default runs `bin/rails runner` in `SITES_ROOT` (default `~/projects/sites`).
- `--prod` runs `kamal-cli runner FILE.rb` from `SITES_ROOT`.
- Does not add an HTTP write API or weaken the HTML-body trust boundary.

## Folder layout

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
```

No credentials file needed. Requires `kamal-cli` on PATH for `--prod`.
