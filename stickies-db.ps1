# stickies-db.ps1 - SQLite storage layer for the Stickies board (kb-t20).
# Dot-source this file, then: $db = Open-StickiesDb <path>
# Engine is winsqlite3.dll (ships with Windows 10+, no install, no admin).
# All strings cross the interop boundary via the UTF-16 API family
# (sqlite3_open16 / bind_text16 / column_text16), which matches .NET strings
# natively - the PS 5.1 ANSI-default encoding bugs from Session 30 cannot
# occur on this path.
#
# Op contract (POST /op bodies; also callable directly via Invoke-StickiesOp):
#   view-set       { kind, view }
#   card-add       { kind, projectId, col, card: { id, title, desc, notes } }
#   card-edit      { kind, cardId, title, desc, notes }
#   card-delete    { kind, cardId }
#   card-move      { kind, cardId, toProjectId, toCol, toIndex }
#   card-archive   { kind, cardId }
#   project-add    { kind, project: { id, name, color } }
#   project-edit   { kind, projectId, name, color }
#   project-delete { kind, projectId }
#   project-import { kind, projects: [ { id, name, color, board: {...} } ] }
# Every op is one transaction; every op except view-set writes an audit row
# (ts, action, sticky_id, old_json, new_json - full snapshots, Postgres style).

if (-not ('WinSqlite' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class WinSqlite : IDisposable
{
    const string DLL = "winsqlite3.dll";
    const int SQLITE_OK = 0;
    const int SQLITE_ROW = 100;
    const int SQLITE_DONE = 101;
    static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);

    [DllImport(DLL)] static extern int sqlite3_open16([MarshalAs(UnmanagedType.LPWStr)] string filename, out IntPtr db);
    [DllImport(DLL)] static extern int sqlite3_close_v2(IntPtr db);
    [DllImport(DLL)] static extern int sqlite3_prepare16_v2(IntPtr db, [MarshalAs(UnmanagedType.LPWStr)] string sql, int nBytes, out IntPtr stmt, IntPtr tail);
    [DllImport(DLL)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport(DLL)] static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport(DLL)] static extern int sqlite3_bind_text16(IntPtr stmt, int i, [MarshalAs(UnmanagedType.LPWStr)] string val, int nBytes, IntPtr destructor);
    [DllImport(DLL)] static extern int sqlite3_bind_int64(IntPtr stmt, int i, long val);
    [DllImport(DLL)] static extern int sqlite3_bind_double(IntPtr stmt, int i, double val);
    [DllImport(DLL)] static extern int sqlite3_bind_null(IntPtr stmt, int i);
    [DllImport(DLL)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport(DLL)] static extern IntPtr sqlite3_column_name16(IntPtr stmt, int i);
    [DllImport(DLL)] static extern int sqlite3_column_type(IntPtr stmt, int i);
    [DllImport(DLL)] static extern IntPtr sqlite3_column_text16(IntPtr stmt, int i);
    [DllImport(DLL)] static extern long sqlite3_column_int64(IntPtr stmt, int i);
    [DllImport(DLL)] static extern double sqlite3_column_double(IntPtr stmt, int i);
    [DllImport(DLL)] static extern IntPtr sqlite3_errmsg16(IntPtr db);

    IntPtr _db;

    public void Open(string path)
    {
        int rc = sqlite3_open16(path, out _db);
        if (rc != SQLITE_OK) throw new InvalidOperationException("sqlite3_open16 failed, rc=" + rc);
    }

    public void Close()
    {
        if (_db != IntPtr.Zero) { sqlite3_close_v2(_db); _db = IntPtr.Zero; }
    }

    public void Dispose() { Close(); }

    string ErrMsg() { return Marshal.PtrToStringUni(sqlite3_errmsg16(_db)); }

    IntPtr Prepare(string sql, object[] args)
    {
        IntPtr stmt;
        int rc = sqlite3_prepare16_v2(_db, sql, -1, out stmt, IntPtr.Zero);
        if (rc != SQLITE_OK) throw new InvalidOperationException("prepare failed: " + ErrMsg() + " | " + sql);
        if (args != null)
        {
            for (int i = 0; i < args.Length; i++)
            {
                object a = args[i];
                // PowerShell hands pipeline output across as PSObject-wrapped
                // values; unwrap via reflection so type dispatch below works
                // without referencing System.Management.Automation.
                if (a != null)
                {
                    var baseProp = a.GetType().GetProperty("BaseObject");
                    if (baseProp != null) a = baseProp.GetValue(a, null);
                }
                int bi = i + 1;
                if (a == null) rc = sqlite3_bind_null(stmt, bi);
                else if (a is string) rc = sqlite3_bind_text16(stmt, bi, (string)a, -1, SQLITE_TRANSIENT);
                else if (a is double || a is float) rc = sqlite3_bind_double(stmt, bi, Convert.ToDouble(a));
                else if (a is bool) rc = sqlite3_bind_int64(stmt, bi, ((bool)a) ? 1 : 0);
                else rc = sqlite3_bind_int64(stmt, bi, Convert.ToInt64(a));
                if (rc != SQLITE_OK) { sqlite3_finalize(stmt); throw new InvalidOperationException("bind failed: " + ErrMsg()); }
            }
        }
        return stmt;
    }

    public void Execute(string sql, object[] args)
    {
        IntPtr stmt = Prepare(sql, args);
        try
        {
            int rc = sqlite3_step(stmt);
            if (rc != SQLITE_DONE && rc != SQLITE_ROW)
                throw new InvalidOperationException("step failed: " + ErrMsg() + " | " + sql);
        }
        finally { sqlite3_finalize(stmt); }
    }

    public List<Dictionary<string, object>> Query(string sql, object[] args)
    {
        IntPtr stmt = Prepare(sql, args);
        var rows = new List<Dictionary<string, object>>();
        try
        {
            int cols = sqlite3_column_count(stmt);
            int rc;
            while ((rc = sqlite3_step(stmt)) == SQLITE_ROW)
            {
                var row = new Dictionary<string, object>();
                for (int c = 0; c < cols; c++)
                {
                    string name = Marshal.PtrToStringUni(sqlite3_column_name16(stmt, c));
                    object val;
                    switch (sqlite3_column_type(stmt, c))
                    {
                        case 1:  val = sqlite3_column_int64(stmt, c); break;
                        case 2:  val = sqlite3_column_double(stmt, c); break;
                        case 5:  val = null; break;
                        default: val = Marshal.PtrToStringUni(sqlite3_column_text16(stmt, c)); break;
                    }
                    row[name] = val;
                }
                rows.Add(row);
            }
            if (rc != SQLITE_DONE)
                throw new InvalidOperationException("step failed: " + ErrMsg() + " | " + sql);
        }
        finally { sqlite3_finalize(stmt); }
        return rows;
    }
}
'@
}

function Open-StickiesDb {
    param([Parameter(Mandatory = $true)][string]$Path)
    $db = [WinSqlite]::new()
    $db.Open($Path)
    $db.Execute('PRAGMA journal_mode=WAL', $null)
    $db.Execute('PRAGMA busy_timeout=3000', $null)
    $db.Execute('PRAGMA foreign_keys=ON', $null)
    Initialize-StickiesSchema $db
    return $db
}

function Initialize-StickiesSchema {
    param($Db)
    $Db.Execute(@'
CREATE TABLE IF NOT EXISTS projects (
  id       TEXT PRIMARY KEY,
  name     TEXT NOT NULL,
  color    TEXT NOT NULL,
  position INTEGER NOT NULL
)
'@, $null)
    $Db.Execute(@'
CREATE TABLE IF NOT EXISTS stickies (
  id         TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id),
  col        TEXT NOT NULL CHECK (col IN ('todo','inprogress','done')),
  position   INTEGER NOT NULL,
  title      TEXT NOT NULL,
  "desc"     TEXT NOT NULL DEFAULT '',
  notes      TEXT NOT NULL DEFAULT '',
  archived   INTEGER NOT NULL DEFAULT 0
)
'@, $null)
    $Db.Execute(@'
CREATE TABLE IF NOT EXISTS audit (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  ts        TEXT NOT NULL,
  action    TEXT NOT NULL,
  sticky_id TEXT,
  old_json  TEXT,
  new_json  TEXT
)
'@, $null)
    $Db.Execute('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)', $null)
}

function Get-StickiesMeta {
    param($Db, [string]$Key)
    $rows = $Db.Query('SELECT value FROM meta WHERE key = ?', @($Key))
    if ($rows.Count -gt 0) { return $rows[0]['value'] }
    return $null
}

function Set-StickiesMeta {
    param($Db, [string]$Key, [string]$Value)
    $Db.Execute('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value', @($Key, $Value))
}

function Get-Field {
    param($Obj, [string]$Name, $Default = '')
    $v = $Obj.$Name
    if ($null -eq $v) { return $Default }
    return $v
}

function Get-StickySnapshot {
    param($Db, [string]$Id)
    $rows = $Db.Query('SELECT id, project_id, col, position, title, "desc", notes, archived FROM stickies WHERE id = ?', @($Id))
    if ($rows.Count -eq 0) { return $null }
    $r = $rows[0]
    return [ordered]@{
        id        = $r['id']
        projectId = $r['project_id']
        col       = $r['col']
        position  = $r['position']
        title     = $r['title']
        desc      = $r['desc']
        notes     = $r['notes']
        archived  = $r['archived']
    }
}

function Get-ProjectSnapshot {
    param($Db, [string]$Id)
    $rows = $Db.Query('SELECT id, name, color, position FROM projects WHERE id = ?', @($Id))
    if ($rows.Count -eq 0) { return $null }
    $r = $rows[0]
    return [ordered]@{ id = $r['id']; name = $r['name']; color = $r['color']; position = $r['position'] }
}

function Add-AuditRow {
    param($Db, [string]$Action, [string]$StickyId, $Old, $New)
    $oldJson = if ($null -ne $Old) { $Old | ConvertTo-Json -Compress -Depth 6 } else { $null }
    $newJson = if ($null -ne $New) { $New | ConvertTo-Json -Compress -Depth 6 } else { $null }
    $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $Db.Execute('INSERT INTO audit (ts, action, sticky_id, old_json, new_json) VALUES (?, ?, ?, ?, ?)',
        @($ts, $Action, $StickyId, $oldJson, $newJson))
}

# Rewrites position 0..n-1 for the live stickies of one column, preserving order.
function Set-ColumnOrder {
    param($Db, [string]$ProjectId, [string]$Col)
    $rows = $Db.Query('SELECT id FROM stickies WHERE project_id = ? AND col = ? AND archived = 0 ORDER BY position, rowid', @($ProjectId, $Col))
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $Db.Execute('UPDATE stickies SET position = ? WHERE id = ?', @($i, $rows[$i]['id']))
    }
}

function Invoke-StickiesOp {
    param($Db, $Op)
    $Db.Execute('BEGIN IMMEDIATE', $null)
    try {
        switch ($Op.kind) {

            'view-set' {
                Set-StickiesMeta $Db 'view' $Op.view
            }

            'card-add' {
                $card = $Op.card
                $pos = $Db.Query('SELECT COUNT(*) AS n FROM stickies WHERE project_id = ? AND col = ? AND archived = 0', @($Op.projectId, $Op.col))[0]['n']
                $Db.Execute('INSERT INTO stickies (id, project_id, col, position, title, "desc", notes, archived) VALUES (?, ?, ?, ?, ?, ?, ?, 0)',
                    @($card.id, $Op.projectId, $Op.col, $pos, $card.title, (Get-Field $card 'desc'), (Get-Field $card 'notes')))
                Add-AuditRow $Db 'card-add' $card.id $null (Get-StickySnapshot $Db $card.id)
            }

            'card-edit' {
                $old = Get-StickySnapshot $Db $Op.cardId
                if ($null -eq $old) { throw "card-edit: no sticky with id $($Op.cardId)" }
                $Db.Execute('UPDATE stickies SET title = ?, "desc" = ?, notes = ? WHERE id = ?',
                    @($Op.title, (Get-Field $Op 'desc'), (Get-Field $Op 'notes'), $Op.cardId))
                Add-AuditRow $Db 'card-edit' $Op.cardId $old (Get-StickySnapshot $Db $Op.cardId)
            }

            'card-delete' {
                $old = Get-StickySnapshot $Db $Op.cardId
                if ($null -eq $old) { throw "card-delete: no sticky with id $($Op.cardId)" }
                $Db.Execute('DELETE FROM stickies WHERE id = ?', @($Op.cardId))
                Set-ColumnOrder $Db $old.projectId $old.col
                Add-AuditRow $Db 'card-delete' $Op.cardId $old $null
            }

            'card-move' {
                $old = Get-StickySnapshot $Db $Op.cardId
                if ($null -eq $old) { throw "card-move: no sticky with id $($Op.cardId)" }
                $Db.Execute('UPDATE stickies SET project_id = ?, col = ? WHERE id = ?', @($Op.toProjectId, $Op.toCol, $Op.cardId))
                if ($old.projectId -ne $Op.toProjectId -or $old.col -ne $Op.toCol) {
                    Set-ColumnOrder $Db $old.projectId $old.col
                }
                $rows = $Db.Query('SELECT id FROM stickies WHERE project_id = ? AND col = ? AND archived = 0 AND id <> ? ORDER BY position, rowid', @($Op.toProjectId, $Op.toCol, $Op.cardId))
                $ids = New-Object System.Collections.ArrayList
                foreach ($r in $rows) { [void]$ids.Add($r['id']) }
                $idx = [Math]::Max(0, [Math]::Min([int]$Op.toIndex, $ids.Count))
                $ids.Insert($idx, $Op.cardId)
                for ($i = 0; $i -lt $ids.Count; $i++) {
                    $Db.Execute('UPDATE stickies SET position = ? WHERE id = ?', @($i, $ids[$i]))
                }
                Add-AuditRow $Db 'card-move' $Op.cardId $old (Get-StickySnapshot $Db $Op.cardId)
            }

            'card-archive' {
                $old = Get-StickySnapshot $Db $Op.cardId
                if ($null -eq $old) { throw "card-archive: no sticky with id $($Op.cardId)" }
                $Db.Execute('UPDATE stickies SET archived = 1 WHERE id = ?', @($Op.cardId))
                Set-ColumnOrder $Db $old.projectId $old.col
                Add-AuditRow $Db 'card-archive' $Op.cardId $old (Get-StickySnapshot $Db $Op.cardId)
            }

            'project-add' {
                $p = $Op.project
                $pos = $Db.Query('SELECT COUNT(*) AS n FROM projects', $null)[0]['n']
                $Db.Execute('INSERT INTO projects (id, name, color, position) VALUES (?, ?, ?, ?)', @($p.id, $p.name, $p.color, $pos))
                Add-AuditRow $Db 'project-add' $null $null (Get-ProjectSnapshot $Db $p.id)
            }

            'project-edit' {
                $old = Get-ProjectSnapshot $Db $Op.projectId
                if ($null -eq $old) { throw "project-edit: no project with id $($Op.projectId)" }
                $Db.Execute('UPDATE projects SET name = ?, color = ? WHERE id = ?', @($Op.name, $Op.color, $Op.projectId))
                Add-AuditRow $Db 'project-edit' $null $old (Get-ProjectSnapshot $Db $Op.projectId)
            }

            'project-delete' {
                $proj = Get-ProjectSnapshot $Db $Op.projectId
                if ($null -eq $proj) { throw "project-delete: no project with id $($Op.projectId)" }
                $cards = $Db.Query('SELECT id, col, position, title, "desc", notes, archived FROM stickies WHERE project_id = ? ORDER BY col, position', @($Op.projectId))
                $proj['stickies'] = @($cards)
                $Db.Execute('DELETE FROM stickies WHERE project_id = ?', @($Op.projectId))
                $Db.Execute('DELETE FROM projects WHERE id = ?', @($Op.projectId))
                $rows = $Db.Query('SELECT id FROM projects ORDER BY position, rowid', $null)
                for ($i = 0; $i -lt $rows.Count; $i++) {
                    $Db.Execute('UPDATE projects SET position = ? WHERE id = ?', @($i, $rows[$i]['id']))
                }
                Add-AuditRow $Db 'project-delete' $null $proj $null
            }

            'project-import' {
                foreach ($p in $Op.projects) {
                    $exists = $Db.Query('SELECT 1 FROM projects WHERE id = ?', @($p.id))
                    if ($exists.Count -gt 0) { continue }
                    $pos = $Db.Query('SELECT COUNT(*) AS n FROM projects', $null)[0]['n']
                    $Db.Execute('INSERT INTO projects (id, name, color, position) VALUES (?, ?, ?, ?)', @($p.id, $p.name, $p.color, $pos))
                    foreach ($col in @('todo', 'inprogress', 'done')) {
                        $cards = @(Get-Field $p.board $col @())
                        for ($i = 0; $i -lt $cards.Count; $i++) {
                            $c = $cards[$i]
                            $Db.Execute('INSERT INTO stickies (id, project_id, col, position, title, "desc", notes, archived) VALUES (?, ?, ?, ?, ?, ?, ?, 0)',
                                @($c.id, $p.id, $col, $i, $c.title, (Get-Field $c 'desc'), (Get-Field $c 'notes')))
                        }
                    }
                    Add-AuditRow $Db 'project-import' $null $null $p
                }
            }

            default { throw "Unknown op kind: $($Op.kind)" }
        }
        $Db.Execute('COMMIT', $null)
    }
    catch {
        $Db.Execute('ROLLBACK', $null)
        throw
    }
}

# Builds the board document (live stickies only) in the kanban-data.json shape.
# Scoped reads (kb-t22): -ProjectId narrows to one project, -TitlesOnly drops
# desc/notes from cards, -ProjectList returns id/name/color with no boards,
# -Archived returns the archived slice instead of the live one.
# Same envelope ({ projects, view }) in every mode.
function Export-StickiesJson {
    param($Db, [string]$ProjectId, [switch]$TitlesOnly, [switch]$ProjectList, [switch]$Archived, [switch]$Compress)
    $projects = New-Object System.Collections.ArrayList
    $projSql = 'SELECT id, name, color FROM projects'
    $projArgs = $null
    if ($ProjectId) { $projSql += ' WHERE id = ?'; $projArgs = @($ProjectId) }
    $projSql += ' ORDER BY position, rowid'
    foreach ($p in $Db.Query($projSql, $projArgs)) {
        if ($ProjectList) {
            [void]$projects.Add([ordered]@{ id = $p['id']; name = $p['name']; color = $p['color'] })
            continue
        }
        $board = [ordered]@{}
        foreach ($col in @('todo', 'inprogress', 'done')) {
            $cards = New-Object System.Collections.ArrayList
            $archFlag = if ($Archived) { 1 } else { 0 }
            $rows = $Db.Query('SELECT id, title, "desc", notes FROM stickies WHERE project_id = ? AND col = ? AND archived = ? ORDER BY position, rowid', @($p['id'], $col, $archFlag))
            foreach ($r in $rows) {
                if ($TitlesOnly) {
                    [void]$cards.Add([ordered]@{ id = $r['id']; title = $r['title'] })
                } else {
                    [void]$cards.Add([ordered]@{ id = $r['id']; title = $r['title']; desc = $r['desc']; notes = $r['notes'] })
                }
            }
            $board[$col] = $cards.ToArray()
        }
        [void]$projects.Add([ordered]@{ id = $p['id']; name = $p['name']; color = $p['color']; board = $board })
    }
    $view = Get-StickiesMeta $Db 'view'
    if ($null -eq $view) { $view = 'all' }
    $doc = [ordered]@{ projects = $projects.ToArray(); view = $view }
    return ($doc | ConvertTo-Json -Depth 10 -Compress:$Compress)
}

# One-time migration from the JSON files. Refuses to run against a non-empty DB.
function Import-StickiesData {
    param($Db, [string]$LiveJsonPath, [string]$ArchiveJsonPath)
    $existing = $Db.Query('SELECT COUNT(*) AS n FROM stickies', $null)[0]['n']
    if ($existing -gt 0) { throw "Import refused: stickies table already has $existing rows" }

    $live = Get-Content -Raw -Encoding UTF8 $LiveJsonPath | ConvertFrom-Json
    $Db.Execute('BEGIN IMMEDIATE', $null)
    try {
        $pi = 0
        foreach ($p in $live.projects) {
            $Db.Execute('INSERT INTO projects (id, name, color, position) VALUES (?, ?, ?, ?)', @($p.id, $p.name, $p.color, $pi))
            $pi++
            foreach ($col in @('todo', 'inprogress', 'done')) {
                $cards = @(Get-Field $p.board $col @())
                for ($i = 0; $i -lt $cards.Count; $i++) {
                    $c = $cards[$i]
                    $Db.Execute('INSERT INTO stickies (id, project_id, col, position, title, "desc", notes, archived) VALUES (?, ?, ?, ?, ?, ?, ?, 0)',
                        @($c.id, $p.id, $col, $i, $c.title, (Get-Field $c 'desc'), (Get-Field $c 'notes')))
                }
            }
        }
        Set-StickiesMeta $Db 'view' (Get-Field $live 'view' 'all')

        $archivedCount = 0
        if ($ArchiveJsonPath -and (Test-Path $ArchiveJsonPath)) {
            $archive = Get-Content -Raw -Encoding UTF8 $ArchiveJsonPath | ConvertFrom-Json
            foreach ($p in $archive.projects) {
                $exists = $Db.Query('SELECT 1 FROM projects WHERE id = ?', @($p.id))
                if ($exists.Count -eq 0) {
                    $Db.Execute('INSERT INTO projects (id, name, color, position) VALUES (?, ?, ?, ?)', @($p.id, $p.name, $p.color, $pi))
                    $pi++
                }
                foreach ($col in @('todo', 'inprogress', 'done')) {
                    $cards = @(Get-Field $p.board $col @())
                    foreach ($c in $cards) {
                        $pos = $Db.Query('SELECT COUNT(*) AS n FROM stickies WHERE project_id = ? AND col = ?', @($p.id, $col))[0]['n']
                        $Db.Execute('INSERT INTO stickies (id, project_id, col, position, title, "desc", notes, archived) VALUES (?, ?, ?, ?, ?, ?, ?, 1)',
                            @($c.id, $p.id, $col, $pos, $c.title, (Get-Field $c 'desc'), (Get-Field $c 'notes')))
                        $archivedCount++
                    }
                }
            }
        }

        $liveCount = $Db.Query('SELECT COUNT(*) AS n FROM stickies WHERE archived = 0', $null)[0]['n']
        Add-AuditRow $Db 'migrate' $null $null ([ordered]@{ live = $liveCount; archived = $archivedCount; from = (Split-Path -Leaf $LiveJsonPath) })
        $Db.Execute('COMMIT', $null)
    }
    catch {
        $Db.Execute('ROLLBACK', $null)
        throw
    }
    return [ordered]@{ live = $liveCount; archived = $archivedCount }
}
