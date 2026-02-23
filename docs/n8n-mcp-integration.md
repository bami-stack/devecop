# n8n + MCP: Security Scan Workflow

This document describes how to connect the security-scan Cursor workflow to **n8n via an MCP server**, with **workflow input coming from previous execution nodes** (a loop of repositories to scan).

## Your workflow topology

- **Main workflow:** Schedule Trigger → **Discover repo** (GitHub) → **Filter** → **Loop Over Items1** → **MCP Client** → (when loop **done**) → **validate** → **Upload a file** (true) / **Send a message** (false).
- **Server workflow:** **MCP Server Trigger** (with Tools) — this is the workflow that runs when the MCP Client calls the MCP server.

Data flow: each **loop item** (one repo from the filtered list) is sent to the **MCP Client**. The MCP Client invokes the MCP server, which starts the **MCP Server Trigger** workflow with that item as input. The server workflow should run the security scan for that repo and return the report path (and optionally summary) so the main workflow can use it in **validate** and **Upload a file**.

## Overview

- **n8n**: Runs a loop over a list of repositories (e.g. from a "Get Repos" or "List Folders" node).
- **Each loop item** contains at least `repoPath` (absolute path to one repo).
- **MCP server** (e.g. Cursor MCP or a custom MCP that triggers Cursor/agent) is called **per item** with that repo as input.
- **This workflow** runs the security scan for that single repo and writes:
  - `reports/security_scan_<repoName>_<date>.md`
  - `workflow/output.json` (for the next n8n node).

## n8n flow shape

1. **Trigger / Schedule** (optional).
2. **Get list of repositories**  
   - e.g. HTTP request to your API, read from a sheet, or "List files" in a parent folder.  
   - Output: array of items like `{ "repoPath": "c:\\repos\\api", "repoName": "api" }`.
3. **Loop over items** (Split Out or Loop Over Items).
4. **For each item, invoke MCP / Cursor workflow**  
   - Pass current item to the MCP server so the security-scan workflow receives:
     - `repoPath`: `{{ $json.repoPath }}`
     - `repoName`: `{{ $json.repoName || $json.name }}` (optional).
5. **Use workflow output**  
   - Read `workflow/output.json` or the report path from the MCP response for the next node (e.g. Slack, email, or aggregate).

## Passing input to the Cursor workflow

The workflow accepts input in three ways (checked in this order):

| Method | Use case |
|--------|----------|
| **Prompt/context** | n8n MCP node sends a message like: "Run security scan. repoPath: `{{ $json.repoPath }}`, repoName: `{{ $json.repoName }}`" |
| **Environment** | n8n (or the process that runs Cursor) sets `SECURITY_SCAN_REPO_PATH={{ $json.repoPath }}` before invoking the agent |
| **File** | n8n writes the current loop item to `workflow/input.json` in the security-scan workspace, then invokes the workflow (e.g. "Run security scan using workflow/input.json") |

Ensure the **workspace** used by Cursor/MCP is the **security-scan** project (or contains `workflow/`, `scripts/`, `reports/` and `.cursor/commands/security-scanmd.md`).

## Workflow input contract

Each loop item should match the schema in `workflow/input.schema.json`:

- **repoPath** (required): string, absolute path to the repo to scan.
- **repoName** (optional): string, used in report filename.
- **scanContainers** (optional): boolean, default true.
- **allowInstall** (optional): boolean, default false (no tool installs without approval).

See `workflow/input.example.json` and `workflow/README.md` for examples.

## Output for next n8n nodes

After each run, the workflow writes:

- **Report**: `reports/security_scan_<repoName>_<date>.md`  
  - Summary table, prioritized fixes, commands run, next steps.
- **Machine-readable summary**: `workflow/output.json`  
  - Fields: `repoPath`, `repoName`, `reportPath`, `reportName`, `date`, `totalFindings`, `criticalHigh`, `commandsRun`.

Your n8n flow can read `workflow/output.json` (or the path in it) to send notifications, gate pipelines, or aggregate results.

## Optional: CLI runner without Cursor

If you run the scan outside Cursor (e.g. from n8n Execute Command or a script):

```powershell
# Input from env
$env:SECURITY_SCAN_REPO_PATH = "c:\repos\my-app"
.\scripts\run-security-scan.ps1

# Or from workflow/input.json (n8n writes this file per loop item)
.\scripts\run-security-scan.ps1

# Or explicit args
.\scripts\run-security-scan.ps1 -RepoPath "c:\repos\my-app" -RepoName "my-app"
```

The same `reports/` and `workflow/output.json` are produced so n8n can consume them the same way.

## MCP server setup

- Configure your MCP server so that when n8n calls it with a "security scan" action, it:
  1. Receives the current n8n loop item (e.g. `repoPath`, `repoName`).
  2. Invokes the Cursor security-scan workflow with that input (via prompt, env, or `workflow/input.json`).
  3. Returns or exposes the path to `workflow/output.json` and/or the report path so n8n can use it in the next node.

Exact steps depend on your MCP implementation (Cursor MCP, custom MCP, or n8n’s MCP node). Use the input contract and output paths above as the interface between n8n and this workflow.

---

## Main workflow: mapping GitHub repos to scan input

**Discover repo** (GitHub `getRepositories`) typically outputs items with `name`, `fullName`, `cloneUrl`, etc., but the security scan needs a **local path** (`repoPath`). Do one of the following:

- **If repos are already cloned** (e.g. under `c:\repos\`): add a **Code** or **Set** node after the Filter (or inside the loop) to set:
  - `repoPath`: e.g. `c:\repos\{{ $json.name }}` or a lookup from `fullName`.
  - `repoName`: `{{ $json.name }}`.
- **If you clone on demand**: add a **Clone repo** (or **Execute Command** to `git clone`) node in the loop before MCP Client, then pass the clone directory as `repoPath` into the MCP Client.

Ensure each item passed to **MCP Client** includes at least `repoPath` (and ideally `repoName`) so the server workflow receives the correct input.

---

## Server workflow: what to add after MCP Server Trigger

The **MCP Server Trigger** workflow receives the request from the main workflow’s MCP Client (one item per repo). Add nodes under the trigger (and under **Tools** if you expose MCP tools) so that:

1. **Input from trigger**  
   The first node after MCP Server Trigger receives the payload. Use the same field names as the main workflow’s loop item: `repoPath`, `repoName`.

2. **Write `workflow/input.json`** (optional but reliable)  
   Use a **Code** node or **Write Binary File** to write the security-scan input to the `workflow/input.json` file in the security-scan project:
   - `repoPath`: from trigger payload (e.g. `$input.repoPath` or `$json.repoPath`).
   - `repoName`: from payload or derived from `repoPath`.

3. **Run the scan**  
   Use **Execute Command** to run the PowerShell runner from the security-scan project root:
   - Command: `powershell -File "c:\Users\Bamidele\Documents\security-scan\scripts\run-security-scan.ps1"`  
   - (Or use `-RepoPath` / `-RepoName` from the trigger payload if you prefer not to write `input.json`.)

4. **Return output to the main workflow**  
   After the script runs, it writes `workflow/output.json` (with `reportPath`, `totalFindings`, `criticalHigh`, etc.). Your MCP Server Trigger workflow should:
   - Read that file (or pass the script’s stdout) and include it in the **response** sent back to the MCP Client.  
   - Then the main workflow’s **validate** node can use the returned data (e.g. `criticalHigh === 0`) to decide **true** → Upload a file (report), **false** → Send a message.

5. **Upload a file** (main workflow)  
   When validate is **true**, use the **report path** returned from the server workflow (e.g. from `workflow/output.json`’s `reportPath`) as the file to upload. If the MCP Client receives the report path in its response, you can pass it to the next execution (after the loop) or aggregate and upload in a final step.

---

## Troubleshooting the warning icons

- **MCP Client (main workflow):** The warning usually means the node is not fully configured (e.g. MCP server URL, authentication, or tool name). Ensure the MCP server that runs the **MCP Server Trigger** workflow is reachable and that the client is set to call the correct tool/endpoint with the loop item as input.
- **Upload a file:** The warning often indicates missing credentials (e.g. S3, Google Drive) or an invalid file path. Once the server workflow returns a valid `reportPath`, use that in the Upload node (from the MCP response or from a subsequent node that reads `workflow/output.json`).
