# Stickies

A local-first kanban board with zero installs: a PowerShell HTTP server, SQLite storage via the copy of SQLite that ships inside Windows, and a vanilla-JS board UI. No admin rights, no runtimes, no packages — if the machine runs Windows 10+, it runs Stickies.

- **Server** — `start-stickies.ps1`: an `HttpListener` (http.sys, same kernel driver as IIS) serving the static UI plus a small REST API on `http://localhost:8123`.
- **Storage** — `stickies-db.ps1`: SQLite through `winsqlite3.dll` (ships in System32 on Windows 10+), P/Invoked over the UTF-16 API family so PowerShell 5.1's ANSI encoding defaults can't corrupt text. Every write is one transaction plus one audit row carrying full before/after JSON snapshots.
- **Board** — `kanban.html` / `kanban.css` / `kanban.js`: plain HTML/CSS/JS, no framework, served by the same server.
- **MCP server** — `stickies-mcp.ps1`: a stdio MCP server (JSON-RPC 2.0 in pure PowerShell) exposing the board to AI tooling as three tools: `board-read`, `board-op`, `audit-query`.
- **API docs** — `api.html`: the REST contract, served at `/api.html`.

## Quick start

```powershell
.\start-stickies.ps1
```

Open http://localhost:8123/ — the board loads empty and ready. `stickies.db` is created next to the scripts on first run (schema auto-creates).

Optional: seed the demo board.

```powershell
Invoke-RestMethod http://localhost:8123/op -Method Post -ContentType 'application/json' `
  -Body (Get-Content sample-board.json -Raw)
```

## Data

All state lives in `stickies.db` (plus its `-wal`/`-shm` companions) next to the scripts. The server owns the file; the UI and all other clients talk HTTP. Nothing else is written anywhere. To back up or version the board as JSON, export it:

```powershell
. .\stickies-db.ps1
$db = Open-StickiesDb .\stickies.db
Export-StickiesJson $db | Set-Content kanban-data.json -Encoding UTF8
```

## Running more than one board

Instances are isolated by folder: each deployed copy keeps its own `stickies.db` next to its own scripts. Deploy to a second folder and pick a different port:

```powershell
.\deploy-stickies.ps1 -Target C:\somewhere\else
C:\somewhere\else\start-stickies.ps1 -Port 8124
```

## Deploying

`deploy-stickies.ps1 -Target <folder>` copies the seven app files to the target. The repo is the source artifact; deployed folders are working locations. Data files never travel with a deploy and never belong in this repo.

## MCP (Claude Code and friends)

Register the deployed `stickies-mcp.ps1` in the `.mcp.json` of the project you run your AI tool from:

```json
{
  "mcpServers": {
    "stickies": {
      "command": "powershell.exe",
      "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "stickies-mcp.ps1"]
    }
  }
}
```

The relative `-File` path works when the deployed files sit in that project's root; use an absolute path otherwise. The MCP opens `stickies.db` directly (next to its own script), so it works even when the HTTP server is down; SQLite WAL handles the two writers. The three tool schemas are the complete operating contract — `board-read` mirrors `GET /data`'s filters, `board-op` the `POST /op` vocabulary.

## REST API

Served by the running server at `/api.html`. Summary:

- `GET /data` — the board as `{projects, view}`. Filters compose: `?project=<id>`, `?titles=1`, `?list=1`, `?archived=1`.
- `POST /op` — one write op per call: `card-add`, `card-edit`, `card-move`, `card-archive`, `card-delete`, `project-add`, `project-edit`, `project-delete`, `project-import`, `view-set`.

## Requirements

Windows 10 or later. Works under both Windows PowerShell 5.1 and PowerShell 7.

## Provenance

Extracted from a personal AI-workshop repo where it was built session by session as the workshop's own kanban board. The board you see is the tool's first user.
