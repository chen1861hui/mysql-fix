<#
  XAMPP MariaDB auto backup + replace (the standard "copy the backup folder" fix, automated).

  1. Stops mysqld if it is running.
  2. Renames mysql\data -> mysql\data_old_<timestamp>   (full backup, nothing is deleted)
  3. Copies mysql\backup -> mysql\data                     (fresh system tables + InnoDB logs)
  4. Copies every user database folder + ibdata1 back from the old data folder
  5. Starts mysqld and checks it stays up.

  Usage (from PowerShell):
    powershell -ExecutionPolicy Bypass -File C:\xampp\mysql-fix\fix-mysql.ps1
    ... -SkipDb klc            # leave a broken database out (it stays in data_old_*)
    ... -NoStart               # do the swap but don't start the server
  Or double-click fix-mysql.bat.
#>
param(
    [string]$Xampp = 'C:\xampp',
    [string[]]$SkipDb = @(),
    [switch]$NoStart,
    [int]$WatchSeconds = 30
)

$ErrorActionPreference = 'Stop'
$mysql   = Join-Path $Xampp 'mysql'
$data    = Join-Path $mysql 'data'
$backup  = Join-Path $mysql 'backup'
$bin     = Join-Path $mysql 'bin'
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$old     = Join-Path $mysql "data_old_$stamp"
$logFile = Join-Path $PSScriptRoot "fix-mysql_$stamp.log"

# Folders that come from mysql\backup and must NOT be copied back from the old data dir.
$systemDbs = @('mysql', 'performance_schema', 'phpmyadmin', 'test')

function Write-Step($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

function Test-MysqlUp {
    & (Join-Path $bin 'mysqladmin.exe') -u root --connect-timeout=3 ping 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# --- checks -------------------------------------------------------------------
if (-not (Test-Path $data))   { throw "Data folder not found: $data" }
if (-not (Test-Path $backup)) { throw "Backup folder not found: $backup (XAMPP's clean copy)" }

$needBytes = (Get-ChildItem $data -Recurse -File | Measure-Object Length -Sum).Sum
$drive = Get-PSDrive -Name ($mysql.Substring(0, 1))
if ($drive.Free -lt ($needBytes * 1.1)) {
    throw ("Not enough disk space: need about {0:N0} MB, free {1:N0} MB" -f ($needBytes / 1MB), ($drive.Free / 1MB))
}

# --- 1. stop ------------------------------------------------------------------
$proc = Get-Process mysqld -ErrorAction SilentlyContinue
if ($proc) {
    Write-Step "Stopping mysqld (pid $($proc.Id -join ','))"
    & (Join-Path $bin 'mysqladmin.exe') -u root --connect-timeout=3 shutdown 2>$null | Out-Null
    Start-Sleep -Seconds 5
    Get-Process mysqld -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}
if (Get-Process mysqld -ErrorAction SilentlyContinue) { throw "mysqld is still running; stop it in the XAMPP panel and retry." }

# --- 2. backup (rename) -------------------------------------------------------
Write-Step "Backing up: $data -> $old"
Rename-Item -Path $data -NewName (Split-Path $old -Leaf)

try {
    # --- 3. fresh copy from backup --------------------------------------------
    Write-Step "Copying clean files from $backup"
    Copy-Item -Path $backup -Destination $data -Recurse

    # --- 4. bring user databases + ibdata1 back -------------------------------
    $userDbs = Get-ChildItem $old -Directory | Where-Object { $systemDbs -notcontains $_.Name }
    foreach ($db in $userDbs) {
        if ($SkipDb -contains $db.Name) { Write-Step "Skipping database $($db.Name) (left in $old)"; continue }
        Write-Step "Restoring database $($db.Name)"
        Copy-Item -Path $db.FullName -Destination (Join-Path $data $db.Name) -Recurse -Force
    }
    Write-Step "Restoring ibdata1"
    Copy-Item -Path (Join-Path $old 'ibdata1') -Destination (Join-Path $data 'ibdata1') -Force
}
catch {
    Write-Step "FAILED: $($_.Exception.Message) - putting the original data folder back"
    if (Test-Path $data) { Remove-Item $data -Recurse -Force }
    Rename-Item -Path $old -NewName 'data'
    throw
}

if ($NoStart) { Write-Step "Done (not started). Backup: $old"; exit 0 }

# --- 5. start + watch ---------------------------------------------------------
Write-Step "Starting mysqld"
# --console sends the server log to our own file, so a crash right after start is not lost.
$serverLog = Join-Path $PSScriptRoot "mysqld_$stamp.log"
Start-Process -FilePath (Join-Path $bin 'mysqld.exe') `
    -ArgumentList "--defaults-file=`"$(Join-Path $bin 'my.ini')`"", '--standalone', '--console' `
    -RedirectStandardError $serverLog -RedirectStandardOutput "$serverLog.out" -WindowStyle Hidden

$up = $false
for ($i = 0; $i -lt 20 -and -not $up; $i++) { Start-Sleep -Seconds 1; $up = Test-MysqlUp }
if (-not $up) { Write-Step "mysqld did not answer. See $serverLog. Backup: $old"; exit 1 }

Write-Step "mysqld is up - watching for $WatchSeconds s"
Start-Sleep -Seconds $WatchSeconds
if (-not (Test-MysqlUp)) { Write-Step "mysqld died after starting. See $serverLog. Backup: $old"; exit 1 }

Write-Step "OK - MySQL is running. Backup kept at $old (delete it once you're happy)."
Write-Step "Note: user accounts/passwords were reset to XAMPP defaults (root, no password)."
