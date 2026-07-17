# stickies-mcp.ps1 - MCP server over stickies.db (kb-t23).
# Claude Code launches this per .mcp.json and speaks MCP (JSON-RPC 2.0,
# newline-delimited) over stdin/stdout. Opens the DB directly through
# stickies-db.ps1, so it works whether or not the HTTP server is running;
# WAL + busy_timeout make the two writers safe together.
# stdout carries protocol frames only - all logging goes to stderr.

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'stickies-db.ps1')
$db = Open-StickiesDb (Join-Path $PSScriptRoot 'stickies.db')

# Explicit UTF-8 streams (no BOM), bypassing console code-page defaults,
# which differ between PS 5.1 (ANSI) and PS 7 (UTF-8).
$stdin = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), [System.Text.UTF8Encoding]::new($false))
$stdout = [System.IO.StreamWriter]::new([Console]::OpenStandardOutput(), [System.Text.UTF8Encoding]::new($false))
$stdout.AutoFlush = $true
$stdout.NewLine = "`n"

function Send-Message($Obj) {
    $stdout.WriteLine(($Obj | ConvertTo-Json -Compress -Depth 20))
}

function Send-Result($Id, $Result) {
    Send-Message ([ordered]@{ jsonrpc = '2.0'; id = $Id; result = $Result })
}

function Send-RpcError($Id, [int]$Code, [string]$Message) {
    Send-Message ([ordered]@{ jsonrpc = '2.0'; id = $Id; error = [ordered]@{ code = $Code; message = $Message } })
}

function New-ToolResult([string]$Text, [bool]$IsError = $false) {
    return [ordered]@{ content = @([ordered]@{ type = 'text'; text = $Text }); isError = $IsError }
}

$tools = @(
    [ordered]@{
        name        = 'board-read'
        description = 'Read the Stickies kanban board. Returns the {projects, view} JSON envelope (same contract as GET /data on the board server). No arguments = full live board (~48KB); prefer titles=true for orientation or project=<id> to scope. archived=true returns the archived slice instead of the live one.'
        inputSchema = [ordered]@{
            type       = 'object'
            properties = [ordered]@{
                project  = [ordered]@{ type = 'string'; description = 'Project id (e.g. kanban-001); omit for all projects' }
                titles   = [ordered]@{ type = 'boolean'; description = 'Titles only - drop desc/notes from cards' }
                list     = [ordered]@{ type = 'boolean'; description = 'Project list only (id/name/color, no cards); wins over other filters' }
                archived = [ordered]@{ type = 'boolean'; description = 'Return archived stickies instead of live ones' }
            }
        }
    }
    [ordered]@{
        name        = 'board-op'
        description = 'Apply one write op to the Stickies board (same contract as POST /op; one transaction plus an audit row). Pass the op fields at the top level. Kinds: view-set {view}; card-add {projectId, col, card: {id, title, desc, notes}}; card-edit {cardId, title, desc, notes}; card-move {cardId, toProjectId, toCol, toIndex}; card-archive {cardId}; card-delete {cardId}; project-add {project: {id, name, color}}; project-edit {projectId, name, color}; project-delete {projectId}; project-import {projects: [...]}. col values: todo, inprogress, done. Edit ops merge: an omitted field keeps its current value; send an empty string to clear. Card ids are caller-supplied; follow the board convention (project prefix + number, e.g. kb-t24).'
        inputSchema = [ordered]@{
            type                 = 'object'
            properties           = [ordered]@{
                kind        = [ordered]@{
                    type = 'string'
                    enum = @('view-set', 'card-add', 'card-edit', 'card-delete', 'card-move', 'card-archive', 'project-add', 'project-edit', 'project-delete', 'project-import')
                }
                view        = [ordered]@{ type = 'string'; description = 'view-set: project id or "all"' }
                projectId   = [ordered]@{ type = 'string'; description = 'card-add / project-edit / project-delete: target project id' }
                col         = [ordered]@{ type = 'string'; enum = @('todo', 'inprogress', 'done') }
                card        = [ordered]@{
                    type        = 'object'
                    description = 'card-add: the new card'
                    properties  = [ordered]@{
                        id    = [ordered]@{ type = 'string' }
                        title = [ordered]@{ type = 'string' }
                        desc  = [ordered]@{ type = 'string' }
                        notes = [ordered]@{ type = 'string' }
                    }
                    required    = @('id', 'title')
                }
                cardId      = [ordered]@{ type = 'string'; description = 'card-edit / card-delete / card-move / card-archive: target card id' }
                title       = [ordered]@{ type = 'string'; description = 'card-edit: replacement value; omitted = unchanged' }
                desc        = [ordered]@{ type = 'string'; description = 'card-edit: replacement value; omitted = unchanged' }
                notes       = [ordered]@{ type = 'string'; description = 'card-edit: replacement value; omitted = unchanged' }
                toProjectId = [ordered]@{ type = 'string' }
                toCol       = [ordered]@{ type = 'string'; enum = @('todo', 'inprogress', 'done') }
                toIndex     = [ordered]@{ type = 'integer' }
                name        = [ordered]@{ type = 'string'; description = 'project-add (inside project) / project-edit: replacement value; omitted = unchanged' }
                color       = [ordered]@{ type = 'string'; description = 'project-edit: hex color; omitted = unchanged' }
                project     = [ordered]@{
                    type        = 'object'
                    description = 'project-add: the new project'
                    properties  = [ordered]@{
                        id    = [ordered]@{ type = 'string' }
                        name  = [ordered]@{ type = 'string' }
                        color = [ordered]@{ type = 'string' }
                    }
                    required    = @('id', 'name', 'color')
                }
                projects    = [ordered]@{ type = 'array'; description = 'project-import: full {id,name,color,board} objects'; items = [ordered]@{ type = 'object' } }
            }
            required             = @('kind')
            additionalProperties = $true
        }
    }
    [ordered]@{
        name        = 'audit-query'
        description = 'Query the board audit trail, newest first. Each row: id, ts, action, stickyId, old, new (full before/after snapshots). Use stickyId to answer "what happened to sticky X".'
        inputSchema = [ordered]@{
            type       = 'object'
            properties = [ordered]@{
                stickyId = [ordered]@{ type = 'string'; description = 'Filter to one sticky id (e.g. kb-t23)' }
                limit    = [ordered]@{ type = 'integer'; description = 'Max rows to return (default 20)' }
            }
        }
    }
)

function Invoke-ToolCall($Id, $Params) {
    $name = $Params.name
    $toolArgs = $Params.arguments

    if ($name -eq 'board-read') {
        $json = Export-StickiesJson $db -ProjectId ([string]$toolArgs.project) -TitlesOnly:([bool]$toolArgs.titles) -ProjectList:([bool]$toolArgs.list) -Archived:([bool]$toolArgs.archived) -Compress
        Send-Result $Id (New-ToolResult $json)
    }
    elseif ($name -eq 'board-op') {
        try {
            Invoke-StickiesOp $db $toolArgs
            Send-Result $Id (New-ToolResult '{"ok":true}')
        }
        catch {
            Send-Result $Id (New-ToolResult "Op failed: $($_.Exception.Message)" $true)
        }
    }
    elseif ($name -eq 'audit-query') {
        $limit = 20
        if ($toolArgs -and $toolArgs.limit) { $limit = [int]$toolArgs.limit }
        $stickyId = if ($toolArgs) { [string]$toolArgs.stickyId } else { '' }
        Send-Result $Id (New-ToolResult (Export-StickiesAuditJson $db -StickyId $stickyId -Limit $limit -Compress))
    }
    else {
        Send-RpcError $Id -32602 "Unknown tool: $name"
    }
}

[Console]::Error.WriteLine('stickies-mcp: ready')

try {
    while ($null -ne ($line = $stdin.ReadLine())) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $msg = $null
        try { $msg = $line | ConvertFrom-Json } catch {
            Send-RpcError $null -32700 'Parse error'
            continue
        }
        $hasId = $null -ne $msg.PSObject.Properties['id']
        $id = $(if ($hasId) { $msg.id } else { $null })
        try {
            if ($msg.method -eq 'initialize') {
                $pv = $msg.params.protocolVersion
                if (-not $pv) { $pv = '2024-11-05' }
                Send-Result $id ([ordered]@{
                        protocolVersion = $pv
                        capabilities    = [ordered]@{ tools = @{} }
                        serverInfo      = [ordered]@{ name = 'stickies-mcp'; version = '1.0' }
                    })
            }
            elseif ($msg.method -eq 'notifications/initialized') { }
            elseif ($msg.method -eq 'tools/list') {
                Send-Result $id ([ordered]@{ tools = $tools })
            }
            elseif ($msg.method -eq 'tools/call') {
                Invoke-ToolCall $id $msg.params
            }
            elseif ($msg.method -eq 'ping') {
                Send-Result $id @{}
            }
            elseif ($hasId) {
                Send-RpcError $id -32601 "Method not found: $($msg.method)"
            }
        }
        catch {
            [Console]::Error.WriteLine("stickies-mcp error ($($msg.method)): $_")
            if ($hasId) { Send-RpcError $id -32603 "Internal error: $($_.Exception.Message)" }
        }
    }
}
finally {
    $db.Close()
}
