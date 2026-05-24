# Cloudflare Pages Deployment

The website is a static site in `site/`.

## Deploy from this machine

```bash
wrangler pages deploy site --project-name windowgrid
```

Cloudflare Pages will publish the site to a free `*.pages.dev` domain. The download button points directly to the latest GitHub Release asset:

```text
https://github.com/Liko0223/WindowGrid/releases/latest/download/WindowGrid-macOS.dmg
```

For production releases, upload a notarized asset named `WindowGrid-macOS.dmg` to the latest GitHub Release before deploying the site.

## Local preview

```bash
npx serve site
```
