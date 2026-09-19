#Requires -RunAsAdministrator
param(
    [string]$Installer = 'C:\Users\UNAL\Desktop\adocker\ManageEngine_ADManager_Plus_64_GA.exe',
    [string]$AdmHome   = 'C:\ADManager',
    [string]$LogDir    = 'C:\Program Files\ManageEngine\ADManager Plus\logs',
    [int]$FinalTail    = 200
)

$ErrorActionPreference = 'Stop'

$issFile    = Join-Path $AdmHome 'setup.iss'
$installLog = Join-Path $AdmHome 'install.log'

New-Item -Path $AdmHome -ItemType Directory -Force | Out-Null

# --- Onkontroller -----------------------------------------------------------
if (-not (Test-Path $Installer)) {
    Write-Host "[!] Installer bulunamadi: $Installer" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $issFile)) {
    Write-Host "[!] setup.iss bulunamadi: $issFile" -ForegroundColor Red
    Write-Host "  Once GUI ile kurulum yaparak setup.iss olustur:" -ForegroundColor Yellow
    Write-Host "  $Installer -r -f1`"$issFile`"" -ForegroundColor Yellow
    exit 1
}

Write-Host "[1/3] setup.iss bulundu: $issFile" -ForegroundColor Green

# Eski install.log yeni kosuda tekrar basilmasin
Remove-Item $installLog -Force -ErrorAction SilentlyContinue

# --- Log tail yardimcilari ---------------------------------------------------
# Her dosya icin en son okunan byte konumunu tutar; sadece YENI satirlari basar.
$offsets = @{}

function Get-WatchPaths {
    $paths = @($installLog)
    if (Test-Path $LogDir) {
        $paths += @(Get-ChildItem -Path $LogDir -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
    }
    $paths | Where-Object { Test-Path $_ }
}

function Show-NewLogLines {
    param([string[]]$Paths)

    foreach ($path in $Paths) {
        $fs = $null
        try {
            # Kurulum dosyayi yazarken de okuyabilmek icin ReadWrite+Delete paylasimi
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        }
        catch { continue }

        try {
            if (-not $offsets.ContainsKey($path)) {
                $offsets[$path] = 0L
                Write-Host "[YENI DOSYA] $path" -ForegroundColor Cyan
            }

            $pos = [long]$offsets[$path]
            if ($fs.Length -lt $pos) { $pos = 0L }   # dosya kesilmis/rotate olmus

            if ($fs.Length -gt $pos) {
                [void]$fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
                $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true, 4096, $true)
                $text = $reader.ReadToEnd()
                $reader.Dispose()
                $offsets[$path] = $fs.Length

                $name = Split-Path $path -Leaf
                foreach ($line in ($text -split "\r?\n")) {
                    if ($line.Length -gt 0) {
                        Write-Host "[$name] $line" -ForegroundColor DarkGray
                    }
                }
            }
            else {
                $offsets[$path] = $pos
            }
        }
        finally {
            $fs.Dispose()
        }
    }
}

# --- Kurulum -----------------------------------------------------------------
Write-Host "[2/3] Sessiz kurulum basliyor..." -ForegroundColor Yellow

$p = Start-Process -FilePath $Installer `
    -ArgumentList '-s', "-f1`"$issFile`"", "-f2`"$installLog`"" `
    -PassThru -NoNewWindow

Write-Host "  PID: $($p.Id) - Kurulum devam ediyor..." -ForegroundColor DarkGray

# Ayni process icinde poll et (Start-Job'in Write-Host ciktisi konsola dusmez)
while (-not $p.HasExited) {
    Show-NewLogLines -Paths @(Get-WatchPaths)
    Start-Sleep -Seconds 1
}
$p.WaitForExit()
Show-NewLogLines -Paths @(Get-WatchPaths)   # son kalan satirlar

$exitCode = $p.ExitCode

# InstallShield sonucu install.log icindeki [ResponseResult] ResultCode= satirinda da yazar
$resultCode = $null
if (Test-Path $installLog) {
    $m = Select-String -Path $installLog -Pattern '^ResultCode=(-?\d+)' | Select-Object -First 1
    if ($m) { $resultCode = [int]$m.Matches[0].Groups[1].Value }
}

# Değişkenlerin boş ($null) gelme durumuna karşı varsayılan değer atama ve sayıya çevirme
[int]$safeExitCode = if ($null -eq $exitCode) { -1 } else { [int]$exitCode }
[int]$safeResultCode = if ($null -eq $resultCode) { 0 } else { [int]$resultCode }

# Kurulumun başarılı sayılma şartı
$ok = ($safeExitCode -eq 0) -and ($safeResultCode -eq 0)
$color = if ($ok) { 'Green' } else { 'Red' }

Write-Host "[2/3] Kurulum bitti. ExitCode: $safeExitCode  ResultCode: $safeResultCode" -ForegroundColor $color

if (-not $ok) {
    Write-Host "[!] Kurulum basarisiz. install.log:" -ForegroundColor Red
    
    if (-not [string]::IsNullOrEmpty($installLog) -and (Test-Path $installLog)) {
        Get-Content $installLog -ErrorAction SilentlyContinue
    } else {
        Write-Host "Log dosyasi bulunamadi veya yol belirtilmedi." -ForegroundColor Yellow
    }

    # Çıkış kodunu belirle
    if ($safeExitCode -ne 0 -and $safeExitCode -ne -1) { 
        exit $safeExitCode 
    } else { 
        exit 1 
    }
}

Write-Host "[2/3] Kurulum basarili." -ForegroundColor Green

# --- Kurulum sonrasi ozet ----------------------------------------------------
Write-Host ""
Write-Host "[3/3] ADManager Plus loglari (son $FinalTail satir/dosya)..." -ForegroundColor Yellow

if (-not (Test-Path $LogDir)) {
    Write-Host "[!] Log klasoru bulunamadi: $LogDir" -ForegroundColor Red
    exit 0
}

$files = @(Get-ChildItem -Path $LogDir -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    Write-Host "[!] $LogDir klasorunde dosya bulunamadi." -ForegroundColor Red
    exit 0
}

foreach ($f in $files) {
    Write-Host ""
    Write-Host ('=' * 60) -ForegroundColor DarkGray
    Write-Host "[DOSYA] $($f.Name)  ($([math]::Round($f.Length / 1KB, 1)) KB)" -ForegroundColor Cyan
    Write-Host "[YOL]   $($f.FullName)" -ForegroundColor DarkGray
    Write-Host ('=' * 60) -ForegroundColor DarkGray
    Get-Content $f.FullName -Tail $FinalTail -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "  $_" }
}