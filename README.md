# sites-cli

Insert or update a GXB tenant site on the `sites` platform from a local folder.

Local sites live in `~/projects/sites`. Use `SITES_ROOT` to override.

## Commands

```bash
sites-cli list [--prod]             # list tenant sites
sites-cli show SLUG [--prod]        # show one site
sites-cli push DIR [--prod]         # upsert site from folder
sites-cli open SLUG [--prod]        # print URL; open with --prod
```

Without `--prod`, the tool runs `bin/rails runner` in `SITES_ROOT`. With `--prod`, it generates a self-contained runner file and pipes it through `kamal-cli runner` from the sites app.

## Folder layout

```
DIR/site.yml      # slug, name, business, theme, page, tailwind, noindex, status
DIR/index.html    # inner HTML only; Tailwind v4 utilities
DIR/assets/*      # optional png/jpg/jpeg/webp/gif, attached by filename
```

Example `site.yml`:

```yaml
slug: metrolocksmith
name: Metro Locksmith
status: live
noindex: true
tailwind: true
business:
  tagline: 24/7 mobile locksmith serving Dallas and Fort Worth.
  phone: "+1-214-638-9911"
  phone_display: (214) 638-9911
  email: info@metrolocksmith.example
  address:
    street: 5321 Kiwanis Rd
    locality: Dallas
    region: TX
    postal_code: "75236"
    country: US
  area_served:
    - Dallas
    - Fort Worth
    - Irving
    - Arlington
  services:
    - Emergency lockout
    - Lock rekeying
    - Key duplication
    - Safe opening
    - Automotive keys
  schema_types:
    - Locksmith
    - LocalBusiness
theme:
  palette:
    primary: "#1f2937"
    accent: "#2563eb"
    ink: "#111827"
    surface: "#ffffff"
    muted: "#6b7280"
  fonts:
    heading: Inter
    body: Inter
page:
  title: Metro Locksmith · Dallas TX
  description: 24/7 mobile locksmith. Fast, local, and fully insured.
  schema_type: LocalBusiness
```

## Setup

```bash
cd ~/tools/sites-cli
ln -s ~/tools/sites-cli/sites-cli ~/bin/sites-cli
```

For production pushes, `kamal-cli` must be on PATH and `~/projects/sites/config/deploy.yml` must exist.
