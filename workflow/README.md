# Security Scan Workflow Input (n8n)

**The workflow input comes from the previous execution nodes in n8n**, which is a loop of repositories to be scanned.

## Input contract

Each loop item from n8n should provide (at minimum):

| Field           | Type    | Required | Description |
|----------------|---------|----------|-------------|
| `repoPath`     | string  | Yes      | Absolute path to the repo directory to scan |
| `repoName`     | string  | No       | Identifier for report filenames; default = basename of `repoPath` |
| `scanContainers` | boolean | No     | Run container/image scans if applicable (default: true) |
| `allowInstall` | boolean | No       | Allow proposing tool installs (default: false) |

## How n8n passes input

1. **Loop node** outputs one item per repository (e.g. from a "List Repos" or "Get Repo Paths" node).
2. **Each item** should include `repoPath` (and optionally `repoName`).
3. **MCP / Cursor** is invoked with this workflow; the agent reads the current loop item as the workflow input.
4. **Output**: Report path and summary are written so the next n8n node can use them (e.g. `reports/security_scan_<repoName>_<date>.md` and `workflow/output.json`).

## Example n8n expressions

- Repo path from loop: `{{ $json.repoPath }}`
- Repo name from loop: `{{ $json.repoName || $json.name }}`
- Static path (single repo): `"c:\\Users\\Bamidele\\Documents\\my-app"`

See `input.example.json` and `input.schema.json` for the full contract.
