if (-not $script:LogHealthDatabasePath) {
    $script:LogHealthDatabasePath = Join-Path (Join-Path $env:USERPROFILE ".codex") "logs_2.sqlite"
}
if (-not $script:LogHealthBackupRoot) {
    $script:LogHealthBackupRoot = Join-Path (Join-Path $env:USERPROFILE ".codex") "backups"
}
$script:LogHealthCurrent = $null
$script:LogHealthPendingFullCheck = $null
$script:LogHealthPendingBlockVerification = $null
$script:LogHealthUiReady = $false

function Ensure-LogHealthSqliteType {
    if ("CodexProxySqlite" -as [type]) { return }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CodexProxySqlite {
    const int SQLITE_OK = 0;
    const int SQLITE_ROW = 100;
    const int SQLITE_DONE = 101;
    const int SQLITE_OPEN_READONLY = 0x00000001;
    const int SQLITE_OPEN_READWRITE = 0x00000002;
    const int SQLITE_OPEN_CREATE = 0x00000004;

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_open_v2(string filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_close(IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_errmsg(IntPtr db);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_exec(IntPtr db, string sql, IntPtr callback, IntPtr arg, out IntPtr errmsg);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern void sqlite3_free(IntPtr ptr);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db, string sql, int nByte, out IntPtr stmt, IntPtr tail);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int col);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr sqlite3_backup_init(IntPtr dest, string destName, IntPtr source, string sourceName);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_backup_step(IntPtr backup, int pageCount);
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] static extern int sqlite3_backup_finish(IntPtr backup);

    static string Utf8(IntPtr ptr) {
        if (ptr == IntPtr.Zero) return null;
        int len = 0;
        while (Marshal.ReadByte(ptr, len) != 0) len++;
        byte[] bytes = new byte[len];
        Marshal.Copy(ptr, bytes, 0, len);
        return Encoding.UTF8.GetString(bytes);
    }

    static IntPtr Open(string path, bool readOnly) {
        IntPtr db;
        int flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
        int rc = sqlite3_open_v2(path, out db, flags, IntPtr.Zero);
        if (rc != SQLITE_OK) {
            string message = db == IntPtr.Zero ? "open failed" : Utf8(sqlite3_errmsg(db));
            if (db != IntPtr.Zero) sqlite3_close(db);
            throw new InvalidOperationException(message);
        }
        sqlite3_busy_timeout(db, 1500);
        return db;
    }

    public static string Scalar(string path, string sql, bool readOnly) {
        IntPtr db = Open(path, readOnly);
        IntPtr stmt = IntPtr.Zero;
        try {
            int rc = sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero);
            if (rc != SQLITE_OK) throw new InvalidOperationException(Utf8(sqlite3_errmsg(db)));
            rc = sqlite3_step(stmt);
            if (rc == SQLITE_ROW) return Utf8(sqlite3_column_text(stmt, 0));
            if (rc == SQLITE_DONE) return null;
            throw new InvalidOperationException(Utf8(sqlite3_errmsg(db)));
        } finally {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
            sqlite3_close(db);
        }
    }

    public static string QueryTsv(string path, string sql, bool readOnly) {
        IntPtr db = Open(path, readOnly);
        IntPtr stmt = IntPtr.Zero;
        StringBuilder builder = new StringBuilder();
        try {
            int rc = sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero);
            if (rc != SQLITE_OK) throw new InvalidOperationException(Utf8(sqlite3_errmsg(db)));
            int columnCount = sqlite3_column_count(stmt);
            bool firstRow = true;
            while (true) {
                rc = sqlite3_step(stmt);
                if (rc == SQLITE_DONE) break;
                if (rc != SQLITE_ROW) throw new InvalidOperationException(Utf8(sqlite3_errmsg(db)));
                if (!firstRow) builder.Append('\n');
                firstRow = false;
                for (int i = 0; i < columnCount; i++) {
                    if (i > 0) builder.Append('\t');
                    string value = Utf8(sqlite3_column_text(stmt, i)) ?? "";
                    builder.Append(value.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' '));
                }
            }
            return builder.ToString();
        } finally {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
            sqlite3_close(db);
        }
    }

    public static void Execute(string path, string sql) {
        IntPtr db = Open(path, false);
        IntPtr error = IntPtr.Zero;
        try {
            int rc = sqlite3_exec(db, sql, IntPtr.Zero, IntPtr.Zero, out error);
            if (rc != SQLITE_OK) {
                string message = error == IntPtr.Zero ? Utf8(sqlite3_errmsg(db)) : Utf8(error);
                throw new InvalidOperationException(message);
            }
        } finally {
            if (error != IntPtr.Zero) sqlite3_free(error);
            sqlite3_close(db);
        }
    }

    public static void Backup(string sourcePath, string destinationPath) {
        IntPtr source = Open(sourcePath, true);
        IntPtr dest = Open(destinationPath, false);
        IntPtr backup = IntPtr.Zero;
        try {
            backup = sqlite3_backup_init(dest, "main", source, "main");
            if (backup == IntPtr.Zero) throw new InvalidOperationException(Utf8(sqlite3_errmsg(dest)));
            int rc = sqlite3_backup_step(backup, -1);
            int finishRc = sqlite3_backup_finish(backup);
            backup = IntPtr.Zero;
            if (rc != SQLITE_DONE && rc != SQLITE_OK) throw new InvalidOperationException("sqlite backup step failed: " + rc.ToString());
            if (finishRc != SQLITE_OK) throw new InvalidOperationException("sqlite backup finish failed: " + finishRc.ToString());
        } finally {
            if (backup != IntPtr.Zero) sqlite3_backup_finish(backup);
            sqlite3_close(dest);
            sqlite3_close(source);
        }
    }
}
"@
}

function Invoke-LogHealthScalar {
    param([string]$DatabasePath, [string]$Sql, [switch]$Writable)
    Ensure-LogHealthSqliteType
    [CodexProxySqlite]::Scalar($DatabasePath, $Sql, -not $Writable)
}

function Invoke-LogHealthRows {
    param([string]$DatabasePath, [string]$Sql, [string[]]$Columns, [switch]$Writable)
    Ensure-LogHealthSqliteType
    $tsv = [CodexProxySqlite]::QueryTsv($DatabasePath, $Sql, -not $Writable)
    if ([string]::IsNullOrWhiteSpace($tsv)) { return @() }
    $rows = @()
    foreach ($line in ($tsv -split "`n")) {
        $cells = $line -split "`t"
        $row = [ordered]@{}
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $row[$Columns[$i]] = if ($i -lt $cells.Count) { $cells[$i] } else { "" }
        }
        $rows += [pscustomobject]$row
    }
    return $rows
}

function Invoke-LogHealthExecute {
    param([string]$DatabasePath, [string]$Sql)
    Ensure-LogHealthSqliteType
    [CodexProxySqlite]::Execute($DatabasePath, $Sql)
}

function ConvertTo-LogHealthInt64 {
    param([object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $parsed = 0L
    if ([long]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-LogHealthFileSize {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [long](Get-Item -LiteralPath $Path).Length }
    return 0L
}

function Format-LogHealthBytes {
    param([object]$Bytes)
    if ($null -eq $Bytes) { return "-" }
    $value = [double]$Bytes
    if ($value -ge 1GB) { return ("{0:N2} GB" -f ($value / 1GB)) }
    if ($value -ge 1MB) { return ("{0:N1} MB" -f ($value / 1MB)) }
    if ($value -ge 1KB) { return ("{0:N0} KB" -f ($value / 1KB)) }
    return ("{0:N0} B" -f $value)
}

function Format-LogHealthPercent {
    param([object]$Ratio)
    if ($null -eq $Ratio) { return "-" }
    return ("{0:N0}%" -f ([double]$Ratio * 100.0))
}

function Get-CodexDesktopVersion {
    try {
        $exe = Find-CodexDesktopExe
        if (-not $exe) { return $null }
        $versionInfo = (Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo
        if (-not [string]::IsNullOrWhiteSpace($versionInfo.ProductVersion)) { return [string]$versionInfo.ProductVersion }
        if (-not [string]::IsNullOrWhiteSpace($versionInfo.FileVersion)) { return [string]$versionInfo.FileVersion }
    } catch {
    }
    return $null
}

function New-LogHealthResult {
    param([string]$DatabasePath = $script:LogHealthDatabasePath, [string]$Status = "Normal", [string]$ErrorMessage = $null)
    $walPath = "$DatabasePath-wal"
    $shmPath = "$DatabasePath-shm"
    [pscustomobject]@{
        DatabasePath = $DatabasePath
        DatabaseExists = (Test-Path -LiteralPath $DatabasePath)
        DatabaseSizeBytes = Get-LogHealthFileSize $DatabasePath
        WalPath = $walPath
        WalSizeBytes = Get-LogHealthFileSize $walPath
        ShmPath = $shmPath
        LogsTableExists = $false
        TriggerExists = $false
        MaxId = $null
        CodexVersion = $null
        LastKnownCodexVersion = $null
        VersionChanged = $false
        Status = $Status
        CheckedAt = (Get-Date).ToString("o")
        ErrorMessage = $ErrorMessage
        DeltaMaxId = $null
        DeltaWalBytes = $null
        TraceRatio = $null
        TraceCount = 0
        TotalRecentRows = 0
        LevelSummary = ""
        TargetSummary = ""
        BackupPath = $null
        CheckpointResult = $null
    }
}

function Invoke-LogHealthSample {
    param(
        [string]$DatabasePath = $script:LogHealthDatabasePath,
        [switch]$IncludeDistributions,
        [string]$CodexVersion = $(Get-CodexDesktopVersion),
        [string]$LastKnownCodexVersion = $(Read-Config).LastKnownCodexVersion,
        [object]$LastKnownMaxId = $(Read-Config).LastLogHealthMaxId
    )

    $result = New-LogHealthResult -DatabasePath $DatabasePath
    $result.CodexVersion = $CodexVersion
    $result.LastKnownCodexVersion = $LastKnownCodexVersion
    $result.VersionChanged = (-not [string]::IsNullOrWhiteSpace($CodexVersion) -and $CodexVersion -ne $LastKnownCodexVersion)
    if (-not $result.DatabaseExists) { $result.Status = "MissingDatabase"; return $result }

    try {
        $tableCount = Invoke-LogHealthScalar -DatabasePath $DatabasePath -Sql "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='logs';"
        $result.LogsTableExists = ([int]$tableCount -gt 0)
        if (-not $result.LogsTableExists) { $result.Status = "UnsupportedSchema"; return $result }
        $triggerCount = Invoke-LogHealthScalar -DatabasePath $DatabasePath -Sql "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='logs_block_all_inserts';"
        $result.TriggerExists = ([int]$triggerCount -gt 0)
        $result.MaxId = ConvertTo-LogHealthInt64 (Invoke-LogHealthScalar -DatabasePath $DatabasePath -Sql "SELECT COALESCE(MAX(id), 0) FROM logs;")

        if ($IncludeDistributions) {
            $levelRows = @(Invoke-LogHealthRows -DatabasePath $DatabasePath -Sql "SELECT COALESCE(level, ''), COUNT(*) FROM (SELECT level FROM logs ORDER BY id DESC LIMIT 2000) GROUP BY level ORDER BY COUNT(*) DESC;" -Columns @("Name", "Count"))
            $targetRows = @(Invoke-LogHealthRows -DatabasePath $DatabasePath -Sql "SELECT COALESCE(target, ''), COUNT(*) FROM (SELECT target FROM logs ORDER BY id DESC LIMIT 2000) GROUP BY target ORDER BY COUNT(*) DESC LIMIT 8;" -Columns @("Name", "Count"))
            $result.LevelSummary = (($levelRows | ForEach-Object { "{0}:{1}" -f $_.Name, $_.Count }) -join ", ")
            $result.TargetSummary = (($targetRows | ForEach-Object { "{0}:{1}" -f $_.Name, $_.Count }) -join ", ")
            $total = 0L; $trace = 0L
            foreach ($row in $levelRows) {
                $count = ConvertTo-LogHealthInt64 $row.Count
                if ($null -eq $count) { $count = 0L }
                $total += $count
                if ([string]$row.Name -ieq "TRACE") { $trace += $count }
            }
            $result.TotalRecentRows = $total
            $result.TraceCount = $trace
            $result.TraceRatio = if ($total -gt 0) { [double]$trace / [double]$total } else { 0.0 }
        }

        if ($result.TriggerExists) {
            $result.Status = "Blocked"
        } else {
            $lastMax = ConvertTo-LogHealthInt64 $LastKnownMaxId
            $maxGrowth = if ($null -ne $lastMax -and $null -ne $result.MaxId) { [long]$result.MaxId - [long]$lastMax } else { 0L }
            if ($result.WalSizeBytes -gt 16MB -or $result.DatabaseSizeBytes -gt 512MB -or $maxGrowth -ge 1000) { $result.Status = "Suspicious" } else { $result.Status = "Normal" }
        }
        return $result
    } catch {
        $failed = New-LogHealthResult -DatabasePath $DatabasePath -Status "CheckFailed" -ErrorMessage $_.Exception.Message
        $failed.CodexVersion = $CodexVersion
        $failed.LastKnownCodexVersion = $LastKnownCodexVersion
        return $failed
    }
}

function New-LogHealthFullResult {
    param([object]$First, [object]$Second)
    if (-not $First -or -not $Second -or $Second.Status -in @("MissingDatabase", "UnsupportedSchema", "CheckFailed")) { return $Second }
    $deltaMaxId = if ($null -ne $First.MaxId -and $null -ne $Second.MaxId) { [long]$Second.MaxId - [long]$First.MaxId } else { $null }
    $deltaWalBytes = [long]$Second.WalSizeBytes - [long]$First.WalSizeBytes
    $status = "Normal"
    if ($Second.TriggerExists -and $deltaMaxId -eq 0 -and $deltaWalBytes -eq 0) { $status = "Blocked" }
    elseif ($deltaMaxId -ge 1000 -and $Second.TraceRatio -ge 0.70) { $status = "TraceStorm" }
    elseif ($deltaMaxId -gt 0 -or $Second.WalSizeBytes -gt 16MB -or $Second.DatabaseSizeBytes -gt 512MB) { $status = "Suspicious" }

    $result = $Second | Select-Object *
    $result.Status = $status
    $result.CheckedAt = (Get-Date).ToString("o")
    $result.DeltaMaxId = $deltaMaxId
    $result.DeltaWalBytes = $deltaWalBytes
    return $result
}

function Set-LogHealthCurrent {
    param([object]$Result)
    $script:LogHealthCurrent = $Result
    if (Get-Command Save-LogHealthConfig -ErrorAction SilentlyContinue) { Save-LogHealthConfig -Result $Result }
    if (Get-Command Write-LauncherLog -ErrorAction SilentlyContinue) {
        Write-LauncherLog ("Log health check: Status={0}; Database={1}; DbBytes={2}; WalBytes={3}; MaxId={4}; DeltaMaxId={5}; TraceRatio={6}; Trigger={7}; Error={8}" -f $Result.Status, $Result.DatabasePath, $Result.DatabaseSizeBytes, $Result.WalSizeBytes, $Result.MaxId, $Result.DeltaMaxId, $Result.TraceRatio, $Result.TriggerExists, $Result.ErrorMessage)
    }
    Update-LogHealthUi
}

function Start-LogHealthLightCheck {
    param([switch]$AllowFullCheck)
    $result = Invoke-LogHealthSample
    Set-LogHealthCurrent $result
    if ($AllowFullCheck -and ($result.VersionChanged -or $result.Status -eq "Suspicious")) { Start-LogHealthFullCheck }
}

function Start-LogHealthFullCheck {
    param([string]$DatabasePath = $script:LogHealthDatabasePath, [int]$SampleSeconds = 10)
    $first = Invoke-LogHealthSample -DatabasePath $DatabasePath
    if ($first.Status -in @("MissingDatabase", "UnsupportedSchema", "CheckFailed")) { Set-LogHealthCurrent $first; return }
    $checking = $first | Select-Object *
    $checking.Status = "Checking"
    $script:LogHealthCurrent = $checking
    $script:LogHealthPendingFullCheck = [pscustomobject]@{ DatabasePath = $DatabasePath; First = $first; DueAt = (Get-Date).AddSeconds([Math]::Max(0, $SampleSeconds)) }
    Update-LogHealthUi
    if ($SampleSeconds -le 0) { Complete-LogHealthFullCheck }
}

function Complete-LogHealthFullCheck {
    if (-not $script:LogHealthPendingFullCheck) { return }
    $pending = $script:LogHealthPendingFullCheck
    $script:LogHealthPendingFullCheck = $null
    $second = Invoke-LogHealthSample -DatabasePath $pending.DatabasePath -IncludeDistributions
    Set-LogHealthCurrent (New-LogHealthFullResult -First $pending.First -Second $second)
}

function New-LogHealthBackup {
    param([string]$DatabasePath = $script:LogHealthDatabasePath)
    if (-not (Test-Path -LiteralPath $DatabasePath)) { throw "Log database does not exist: $DatabasePath" }
    Ensure-LogHealthSqliteType
    $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $backupDir = Join-Path $script:LogHealthBackupRoot "logs_2_sqlite_$stamp"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    [CodexProxySqlite]::Backup($DatabasePath, (Join-Path $backupDir "logs_2.sqlite.backup"))
    Copy-Item -LiteralPath $DatabasePath -Destination (Join-Path $backupDir "logs_2.sqlite.raw") -Force
    foreach ($suffix in @("-wal", "-shm")) {
        $source = "$DatabasePath$suffix"
        if (Test-Path -LiteralPath $source) {
            $name = if ($suffix -eq "-wal") { "logs_2.sqlite-wal.raw" } else { "logs_2.sqlite-shm.raw" }
            try { Copy-Item -LiteralPath $source -Destination (Join-Path $backupDir $name) -Force }
            catch { if (Get-Command Write-LauncherLog -ErrorAction SilentlyContinue) { Write-LauncherLog ("Log health backup skipped {0}: {1}" -f $source, $_.Exception.Message) } }
        }
    }
    if (Get-Command Write-LauncherLog -ErrorAction SilentlyContinue) { Write-LauncherLog ("Log health backup created: {0}" -f $backupDir) }
    return $backupDir
}

function Invoke-LogHealthBlockWrites {
    param([string]$DatabasePath = $script:LogHealthDatabasePath, [switch]$SkipConfirmation, [int]$VerificationSeconds = 10)
    if (-not $SkipConfirmation) {
        $choice = [System.Windows.Forms.MessageBox]::Show((T "log_health_confirm_block"), (T "title"), "YesNo", "Warning")
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $sample = Invoke-LogHealthSample -DatabasePath $DatabasePath
    if (-not $sample.LogsTableExists) { throw "The logs table does not exist. Status: $($sample.Status)" }
    $backupDir = New-LogHealthBackup -DatabasePath $DatabasePath
    Invoke-LogHealthExecute -DatabasePath $DatabasePath -Sql @"
DROP TRIGGER IF EXISTS logs_drop_trace_before_insert;
DROP TRIGGER IF EXISTS logs_block_all_inserts;
CREATE TRIGGER logs_block_all_inserts BEFORE INSERT ON logs BEGIN SELECT RAISE(IGNORE); END;
"@
    $checkpointResult = "ok"
    try {
        Invoke-LogHealthExecute -DatabasePath $DatabasePath -Sql "PRAGMA wal_checkpoint(TRUNCATE);"
    } catch {
        $checkpointResult = "failed: $($_.Exception.Message)"
        if (Get-Command Write-LauncherLog -ErrorAction SilentlyContinue) { Write-LauncherLog ("Log health checkpoint failed: {0}" -f $_.Exception.Message) }
    }
    $first = Invoke-LogHealthSample -DatabasePath $DatabasePath
    $first.BackupPath = $backupDir
    $first.CheckpointResult = $checkpointResult
    $script:LogHealthPendingBlockVerification = [pscustomobject]@{ DatabasePath = $DatabasePath; First = $first; BackupPath = $backupDir; DueAt = (Get-Date).AddSeconds([Math]::Max(0, $VerificationSeconds)) }
    $checking = $first | Select-Object *
    $checking.Status = "Checking"
    Set-LogHealthCurrent $checking
    if ($VerificationSeconds -le 0) { Complete-LogHealthBlockVerification }
}

function Complete-LogHealthBlockVerification {
    if (-not $script:LogHealthPendingBlockVerification) { return }
    $pending = $script:LogHealthPendingBlockVerification
    $script:LogHealthPendingBlockVerification = $null
    $second = Invoke-LogHealthSample -DatabasePath $pending.DatabasePath -IncludeDistributions
    $second.BackupPath = $pending.BackupPath
    $second.CheckpointResult = $pending.First.CheckpointResult
    $result = New-LogHealthFullResult -First $pending.First -Second $second
    $result.BackupPath = $pending.BackupPath
    $result.CheckpointResult = $pending.First.CheckpointResult
    Set-LogHealthCurrent $result
}

function Invoke-LogHealthRestoreWrites {
    param([string]$DatabasePath = $script:LogHealthDatabasePath, [switch]$SkipConfirmation, [int]$SampleSeconds = 10)
    if (-not $SkipConfirmation) {
        $choice = [System.Windows.Forms.MessageBox]::Show((T "log_health_confirm_restore"), (T "title"), "YesNo", "Warning")
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    Invoke-LogHealthExecute -DatabasePath $DatabasePath -Sql "DROP TRIGGER IF EXISTS logs_block_all_inserts;"
    if (Get-Command Write-LauncherLog -ErrorAction SilentlyContinue) { Write-LauncherLog ("Log health restore requested: {0}" -f $DatabasePath) }
    Start-LogHealthFullCheck -DatabasePath $DatabasePath -SampleSeconds $SampleSeconds
}

function Invoke-LogHealthTick {
    if ($script:LogHealthPendingFullCheck -and (Get-Date) -ge $script:LogHealthPendingFullCheck.DueAt) { Complete-LogHealthFullCheck }
    if ($script:LogHealthPendingBlockVerification -and (Get-Date) -ge $script:LogHealthPendingBlockVerification.DueAt) { Complete-LogHealthBlockVerification }
}

function Get-LogHealthStatusDisplay {
    param([string]$Status)
    switch ($Status) {
        "Normal" { if ($script:Language -eq "en") { "normal" } else { "正常" } }
        "Suspicious" { if ($script:Language -eq "en") { "suspicious" } else { "可疑" } }
        "TraceStorm" { if ($script:Language -eq "en") { "TRACE storm" } else { "TRACE 暴涨" } }
        "Blocked" { if ($script:Language -eq "en") { "blocked" } else { "已拦截" } }
        "MissingDatabase" { if ($script:Language -eq "en") { "missing database" } else { "日志库不存在" } }
        "UnsupportedSchema" { if ($script:Language -eq "en") { "unsupported schema" } else { "表结构不支持" } }
        "CheckFailed" { if ($script:Language -eq "en") { "check failed" } else { "检查失败" } }
        "Checking" { T "log_health_running" }
        default { if ($Status) { $Status } else { T "log_health_missing" } }
    }
}

function Update-LogHealthUi {
    if (-not $script:LogHealthUiReady) { return }
    $result = $script:LogHealthCurrent
    if (-not $result) {
        $logHealthStatusLabel.Text = T "log_health_idle"
        $logHealthDetailsLabel.Text = T "log_health_details" @("-", "-", "-", "-", "-", "-", "-", "-", "-")
        return
    }

    $displayStatus = Get-LogHealthStatusDisplay $result.Status
    $logHealthStatusLabel.Text = T "log_health_status" $displayStatus
    $logHealthStatusLabel.ForeColor = switch ($result.Status) {
        "Normal" { [System.Drawing.Color]::FromArgb(28, 140, 74) }
        "Blocked" { [System.Drawing.Color]::FromArgb(28, 140, 74) }
        "Suspicious" { [System.Drawing.Color]::FromArgb(194, 119, 0) }
        "TraceStorm" { [System.Drawing.Color]::FromArgb(200, 45, 45) }
        "CheckFailed" { [System.Drawing.Color]::FromArgb(200, 45, 45) }
        default { [System.Drawing.SystemColors]::ControlText }
    }

    $codexVersion = if ($result.CodexVersion) { $result.CodexVersion } else { "-" }
    $maxId = if ($null -ne $result.MaxId) { [string]$result.MaxId } else { "-" }
    $delta = if ($null -ne $result.DeltaMaxId) { [string]$result.DeltaMaxId } else { "-" }
    $trigger = if ($result.TriggerExists) { T "log_health_yes" } else { T "log_health_no" }
    $backup = if ($result.BackupPath) { $result.BackupPath } else { T "log_health_missing" }
    $checkedAt = if ($result.CheckedAt) { ([datetime]$result.CheckedAt).ToString("yyyy-MM-dd HH:mm:ss") } else { "-" }

    $logHealthDetailsLabel.Text = T "log_health_details" @(
        $codexVersion,
        (Format-LogHealthBytes $result.DatabaseSizeBytes),
        (Format-LogHealthBytes $result.WalSizeBytes),
        $maxId,
        $delta,
        (Format-LogHealthPercent $result.TraceRatio),
        $trigger,
        $checkedAt,
        $backup
    )
}

function Open-LogHealthBackupDirectory {
    $config = Read-Config
    $path = if ($config.LastBackupDir -and (Test-Path -LiteralPath $config.LastBackupDir)) { $config.LastBackupDir } else { $script:LogHealthBackupRoot }
    if (Test-Path -LiteralPath $path) { Start-Process -FilePath $path | Out-Null }
    else { [System.Windows.Forms.MessageBox]::Show((T "log_health_backup_missing"), (T "title"), "OK", "Information") | Out-Null }
}

function Assert-LogHealthSelfTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-LogHealthSelfTest {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-proxy-log-health-selftest-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    $db = Join-Path $tempRoot "logs_2.sqlite"
    $oldBackupRoot = $script:LogHealthBackupRoot
    $oldStateDir = $script:StateDir
    $oldConfigFile = $script:ConfigFile
    $oldLogFile = $script:LogFile
    $script:LogHealthBackupRoot = Join-Path $tempRoot "backups"
    $script:StateDir = Join-Path $tempRoot "state"
    $script:ConfigFile = Join-Path $script:StateDir "codex-only-launcher.json"
    $script:LogFile = Join-Path $script:StateDir "launcher.log"
    try {
        $missing = Invoke-LogHealthSample -DatabasePath (Join-Path $tempRoot "missing.sqlite") -CodexVersion "selftest" -LastKnownCodexVersion "selftest"
        Assert-LogHealthSelfTest ($missing.Status -eq "MissingDatabase") "Missing database should be reported."

        Invoke-LogHealthExecute -DatabasePath $db -Sql "CREATE TABLE logs(id INTEGER PRIMARY KEY AUTOINCREMENT, level TEXT, target TEXT); INSERT INTO logs(level, target) VALUES('INFO', 'selftest');"
        $normal = Invoke-LogHealthSample -DatabasePath $db -CodexVersion "selftest" -LastKnownCodexVersion "selftest"
        Assert-LogHealthSelfTest ($normal.Status -eq "Normal") "Normal database should be reported as Normal."

        Invoke-LogHealthExecute -DatabasePath $db -Sql "CREATE TRIGGER logs_block_all_inserts BEFORE INSERT ON logs BEGIN SELECT RAISE(IGNORE); END;"
        $blocked = Invoke-LogHealthSample -DatabasePath $db -CodexVersion "selftest" -LastKnownCodexVersion "selftest"
        Assert-LogHealthSelfTest ($blocked.Status -eq "Blocked" -and $blocked.TriggerExists) "Existing trigger should be reported as Blocked."
        Invoke-LogHealthExecute -DatabasePath $db -Sql "DROP TRIGGER IF EXISTS logs_block_all_inserts;"

        $first = Invoke-LogHealthSample -DatabasePath $db -CodexVersion "selftest" -LastKnownCodexVersion "selftest"
        $values = @()
        for ($i = 0; $i -lt 1200; $i++) { $values += "('TRACE','codex_api::selftest')" }
        Invoke-LogHealthExecute -DatabasePath $db -Sql ("INSERT INTO logs(level, target) VALUES " + ($values -join ",") + ";")
        $second = Invoke-LogHealthSample -DatabasePath $db -IncludeDistributions -CodexVersion "selftest" -LastKnownCodexVersion "selftest"
        $storm = New-LogHealthFullResult -First $first -Second $second
        Assert-LogHealthSelfTest ($storm.Status -eq "TraceStorm") "TRACE storm should be detected."

        $backup = New-LogHealthBackup -DatabasePath $db
        Assert-LogHealthSelfTest (Test-Path -LiteralPath (Join-Path $backup "logs_2.sqlite.backup")) "SQLite backup snapshot should exist."

        Invoke-LogHealthBlockWrites -DatabasePath $db -SkipConfirmation -VerificationSeconds 0
        $maxBefore = [long](Invoke-LogHealthScalar -DatabasePath $db -Sql "SELECT COALESCE(MAX(id), 0) FROM logs;")
        Invoke-LogHealthExecute -DatabasePath $db -Sql "INSERT INTO logs(level, target) VALUES('INFO','blocked_insert');"
        $maxAfter = [long](Invoke-LogHealthScalar -DatabasePath $db -Sql "SELECT COALESCE(MAX(id), 0) FROM logs;")
        Assert-LogHealthSelfTest ($maxBefore -eq $maxAfter) "Block trigger should prevent MAX(id) growth."

        Invoke-LogHealthRestoreWrites -DatabasePath $db -SkipConfirmation -SampleSeconds 0
        $restored = Invoke-LogHealthSample -DatabasePath $db -CodexVersion "selftest" -LastKnownCodexVersion "selftest"
        Assert-LogHealthSelfTest (-not $restored.TriggerExists) "Restore should delete block trigger."
        Write-Host "Log health self-test passed."
    } finally {
        $script:LogHealthBackupRoot = $oldBackupRoot
        $script:StateDir = $oldStateDir
        $script:ConfigFile = $oldConfigFile
        $script:LogFile = $oldLogFile
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}


