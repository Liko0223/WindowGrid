# Cloudflare Pages Deployment

The website is a static site in `site/`.

## Deploy from this machine

```bash
wrangler pages deploy site --project-name windowgrid
```

Cloudflare Pages will publish the site to a free `*.pages.dev` domain. The current download button points to:

```text
/downloads/WindowGrid-macOS.dmg
```

For production releases, replace `site/downloads/WindowGrid-macOS.dmg` before deploying, or change the download link in `site/index.html` to a GitHub Releases asset.

## Local preview

```bash
npx serve site
```
