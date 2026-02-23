# n8n + GitAction workflow repo

This repo is set up to:

- **Version n8n workflows**: store exported workflow JSON in `workflows/` so they can be reviewed in git.
- **Sync with n8n Cloud**: scripts to export/import workflows using the n8n API (API key via `.env`, never committed).
- **Keep things safe**: secrets stay local; CI can validate workflow JSON without needing secrets.

## Quick start

1. Create a local `.env` (see `.env.example`) with:
   - `N8N_API_URL`
   - `N8N_API_KEY`
2. Install tooling:

```bash
npm install
```

3. Export workflows from n8n into this repo:

```bash
npm run n8n:export
```

4. Validate and format:

```bash
npm run validate
npm run format
```

## Repo conventions

- **Workflow files**: `workflows/*.json` (pretty-printed, stable filenames).
- **Secrets**: never commit `.env`; use GitHub Secrets for CI only when you add automation that needs them.
