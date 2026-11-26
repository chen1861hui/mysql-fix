<#
  XAMPP MariaDB clean rebuild: dump every database, start from a fresh data folder, import back.

  Use this when the error log keeps showing
    "log sequence number ... is in the future" / "Your database may be corrupt"
  (usually after the fix-mysql.ps1 folder swap). The swap gets MySQL running; this removes the
  mismatch for good, because every table is rewritten into a brand-new InnoDB system.

  MySQL must be RUNNING when you start this (run fix-mysql.bat first if it is down).

  1. Counts the rows of every table (before).
  2. mysqldump each user database to C:\xampp\mysql-dumps\<timestamp>\<db>.sql and checks it completed.
  3. Clean shutdown; renames mysql\data -> mysql\data_old_rebuild_<timestamp> (backup, nothing deleted).
  4. Copies mysql\backup -> mysql\data, starts mysqld.
  5. Imports every dump, counts rows again and compares.
  If anything fails after step 3, the original data folder is put back automatically.

  Usage:
    powershell -ExecutionPolicy Bypass -File C:\xampp\mysql-fix\rebuild-mysql.ps1
    ... -SkipDb klc_test        # don't carry a database over
  Or double-click rebuild-mysql.bat.
#>
param(
    [string]$Xampp = 'C:\xampp',
    [string]$DumpRoot = 'C:\xampp\mysql-dumps',
    [string[]]$SkipDb = @()
)

$ErrorActionPreference = 'Stop'
$mysql   = Join-Path $Xampp 'mysql'
$data    = Join-Path $mysql 'data'
$backup  = Join-Path $mysql 'backup'
$bin     = Join-Path $mysql 'bin'
$exe     = Join-Path $bin 'mysql.exe'
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$old     = Join-Path $mysql "data_old_rebuild_$stamp"
$dumpDir = Join-Path $DumpRoot $stamp
$logFile = Join-Path $PSScriptRoot "rebuild-mysql_$stamp.log"

# Recreated from mysql\backup, never dumped.
$systemDbs = @('information_schema', 'performance_schema', 'mysql', 'phpmyadmin', 'test')

function Write-Step($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

function Invoke-Sql([string]$sql) {
    $out = & $exe -u root -N -B -e $sql
    if ($LASTEXITCODE -ne 0) { throw "SQL failed: $sql" }
    return $out
}

function Test-MysqlUp {
    & (Join-Path $bin 'mysqladmin.exe') -u root --connect-timeout=3 ping 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Stop-Mysql {
    & (Join-Path $bin 'mysqladmin.exe') -u root --connect-timeout=3 shutdown 2>$null | Out-Null
    for ($i = 0; $i -lt 120 -and (Get-Process mysqld -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
    if (Get-Process mysqld -ErrorAction SilentlyContinue) { throw "mysqld did not stop within 2 minutes" }
}

# --console sends the server log to our own file: without it, lines after "Server socket created"
# (including crash reports) can go missing from data\mysql_error.log.
$serverLog = Join-Path $PSScriptRoot "mysqld_$stamp.log"
function Start-Mysql {
    Start-Process -FilePath (Join-Path $bin 'mysqld.exe') `
        -ArgumentList "--defaults-file=`"$(Join-Path $bin 'my.ini')`"", '--standalone', '--console' `
        -RedirectStandardError $serverLog -RedirectStandardOutput "$serverLog.out" -WindowStyle Hidden
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep 1
        if (Test-MysqlUp) { Start-Sleep 5; if (Test-MysqlUp) { return } }
    }
    throw "mysqld did not come up (or died right after starting) - see $serverLog"
}

# Returns @{ 'db.table' = rowcount } for the given databases (exact COUNT(*), not estimates).
function Get-RowCounts([string[]]$dbs) {
    $counts = @{}
    foreach ($db in $dbs) {
        $tables = Invoke-Sql "SELECT table_name FROM information_schema.tables WHERE table_schema='$db' AND table_type='BASE TABLE'"
        foreach ($t in @($tables)) {
            if (-not $t) { continue }
            $counts["$db.$t"] = [int64](Invoke-Sql "SELECT COUNT(*) FROM ``$db``.``$t``")
        }
    }
    return $counts
}

# --- checks -------------------------------------------------------------------
if (-not (Test-Path $backup)) { throw "Backup folder not found: $backup (XAMPP's clean copy)" }
if (-not (Test-MysqlUp)) { throw "MySQL is not running. Start it (or run fix-mysql.bat) first." }

$dbs = @(Invoke-Sql 'SHOW DATABASES') | Where-Object { $systemDbs -notcontains $_ -and $SkipDb -notcontains $_ }
if (-not $dbs) { throw "No user databases found." }
Write-Step ("Databases to rebuild: " + ($dbs -join ', '))
if ($SkipDb) { Write-Step ("Skipped (stay only in the backup folder): " + ($SkipDb -join ', ')) }

# --- 1. counts before ---------------------------------------------------------
Write-Step "Counting rows (before)"
$before = Get-RowCounts $dbs
Write-Step ("{0} tables, {1:N0} rows" -f $before.Count, ($before.Values | Measure-Object -Sum).Sum)

# --- 2. dump ------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $dumpDir | Out-Null
foreach ($db in $dbs) {
    $file = Join-Path $dumpDir "$db.sql"
    Write-Step "Dumping $db -> $file"
    & (Join-Path $bin 'mysqldump.exe') -u root --single-transaction --routines --triggers --events `
        --hex-blob --max-allowed-packet=1G --default-character-set=utf8mb4 --databases $db "--result-file=$file"
    if ($LASTEXITCODE -ne 0) { throw "mysqldump failed for $db (nothing has been changed)" }
    $tail = Get-Content $file -Tail 1
    if ($tail -notmatch 'Dump completed') { throw "Dump of $db looks incomplete (nothing has been changed)" }
}

# --- 3. stop + backup ---------------------------------------------------------
Write-Step "Stopping MySQL (clean shutdown)"
Stop-Mysql
Write-Step "Backing up: $data -> $old"
Rename-Item -Path $data -NewName (Split-Path $old -Leaf)

try {
    # --- 4. fresh data folder -------------------------------------------------
    Write-Step "Creating fresh data folder from $backup"
    Copy-Item -Path $backup -Destination $data -Recurse
    Write-Step "Starting MySQL on the fresh data folder"
    Start-Mysql

    # --- 5. import + verify ---------------------------------------------------
    foreach ($db in $dbs) {
        $file = Join-Path $dumpDir "$db.sql"
        Write-Step "Importing $db"
        cmd /c "$exe -u root --max-allowed-packet=1G --default-character-set=utf8mb4 < `"$file`""
        if ($LASTEXITCODE -ne 0) { throw "Import failed for $db" }
    }

    Write-Step "Counting rows (after)"
    $after = Get-RowCounts $dbs
    $bad = @()
    foreach ($k in $before.Keys) {
        if (-not $after.ContainsKey($k)) { $bad += "$k missing" }
        elseif ($after[$k] -ne $before[$k]) { $bad += "$k before=$($before[$k]) after=$($after[$k])" }
    }
    if ($bad) { $bad | ForEach-Object { Write-Step "MISMATCH $_" }; throw "$($bad.Count) table(s) don't match" }
    Write-Step ("All {0} tables match ({1:N0} rows)" -f $after.Count, ($after.Values | Measure-Object -Sum).Sum)
}
catch {
    Write-Step "FAILED: $($_.Exception.Message)"
    Write-Step "Rolling back to the original data folder"
    Get-Process mysqld -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 3
    if (Test-Path $data) { Rename-Item -Path $data -NewName "data_failed_rebuild_$stamp" }
    Rename-Item -Path $old -NewName 'data'
    Start-Mysql
    Write-Step "Original data folder is back and MySQL is running. Dumps kept in $dumpDir"
    exit 1
}

$errors = @(Select-String -Path $serverLog -Pattern '\[ERROR\]')
Write-Step ("Errors in the server log ($serverLog): {0}" -f $errors.Count)
$errors | Select-Object -First 5 | ForEach-Object { Write-Step "  $($_.Line)" }

Write-Step "OK - rebuild done. Old data folder: $old  Dumps: $dumpDir  (delete them once you're happy)."
