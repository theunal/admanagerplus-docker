$ErrorActionPreference = 'Stop'

# stdout UTF-8 (konsol/TTY yoksa hata verebilir, o yuzden try/catch)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$installer     = 'C:\install\ManageEngine_ADManager_Plus_64_GA.exe'
$admHome       = 'C:\ADManager'
$marker        = Join-Path $admHome '.installed'
$issFile       = Join-Path $admHome 'setup.iss'
$installLog    = Join-Path $admHome 'install.log'

# Uygulamanin KURULDUGU dizin (C:\ADManager degil!)
$admInstallDir = 'C:\Program Files\ManageEngine\ADManager Plus'
$binDir        = Join-Path $admInstallDir 'bin'
$admLogDir     = Join-Path $admInstallDir 'logs'

$initialTail   = 20   # Kurulumdan sonra ilk gorulen dosyalarda kac satir gosterilsin

# KEEP_ALIVE: varsayilan ACIK. Hata/cikis durumunda container kapanmaz, bosta bekler;
# `docker exec -it <container> powershell` ile icine girip inceleyebilirsin.
# Eski davranis (hata olursa container kapansin) icin: KEEP_ALIVE=0
$keepAlive = ($env:KEEP_ALIVE -ne '0')

function Exit-Entrypoint {
    param([int]$Code = 1)
    if ($keepAlive) {
        Write-Host "[entrypoint] Cikis kodu $Code icin cikilmiyor (KEEP_ALIVE acik). Container bosta bekliyor." -ForegroundColor Yellow
        while ($true) { Start-Sleep -Seconds 3600 }
    }
    exit $Code
}

# Yakalanmayan her hata: mesaji yaz, sonra Exit-Entrypoint karar versin
trap {
    Write-Host "[entrypoint] HATA: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "$($_.ScriptStackTrace)" -ForegroundColor DarkGray
    Exit-Entrypoint 1
}

# --- Log tail yardimcilari ---------------------------------------------------
# Dosya basina okunan byte konumunu tutar; sadece YENI satirlari stdout'a basar.
$offsets = @{}

function Get-WatchPaths {
    $paths = @($installLog)
    if (Test-Path $admLogDir) {
        $paths += @(
            Get-ChildItem -Path (Join-Path $admLogDir '*') -File -Include '*.log', '*.txt' -ErrorAction SilentlyContinue |
                ForEach-Object FullName
        )
    }
    $paths | Where-Object { Test-Path $_ }
}

function Show-NewLogLines {
    param(
        [string[]]$Paths,
        [int]$InitialTail = -1   # -1: ilk gorulen dosyayi bastan sona bas
    )

    foreach ($path in $Paths) {
        $fs = $null
        try {
            # Uygulama yazarken de okuyabilmek icin ReadWrite+Delete paylasimi
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        }
        catch { continue }

        try {
            $first = -not $offsets.ContainsKey($path)
            if ($first) {
                $offsets[$path] = 0L
                Write-Host "[YENI DOSYA] $path" -ForegroundColor Cyan
            }

            $pos = [long]$offsets[$path]
            if ($fs.Length -lt $pos) { $pos = 0L }   # dosya kesilmis/rotate olmus

            # Buyuk dosyada ilk gorulusu son 1 MB ile sinirla
            $skipFirstLine = $false
            if ($first -and $InitialTail -ge 0) {
                $limit = [long]1MB
                if ($fs.Length -gt $limit) { $pos = $fs.Length - $limit; $skipFirstLine = $true }
            }

            if ($fs.Length -gt $pos) {
                [void]$fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
                $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true, 4096, $true)
                $text = $reader.ReadToEnd()
                $reader.Dispose()
                $offsets[$path] = $fs.Length

                $lines = @($text -split "\r?\n" | Where-Object { $_.Length -gt 0 })
                if ($skipFirstLine -and $lines.Count -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
                if ($first -and $InitialTail -ge 0 -and $lines.Count -gt $InitialTail) {
                    $lines = @($lines | Select-Object -Last $InitialTail)
                }

                $name = Split-Path $path -Leaf
                foreach ($line in $lines) { Write-Host "[$name] $line" }
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

# --- 1) Kurulum (sadece gerekliyse) ------------------------------------------
# Marker tek basina yetmez: C:\ADManager bir volume ise ama Program Files degilse,
# marker var / uygulama yok durumu olusur. Ikisini birlikte kontrol et.
$installed = (Test-Path $marker) -and (Test-Path $binDir)

if (-not $installed) {
    Write-Host "[entrypoint] Kurulum basliyor..."
    New-Item -Path $admHome -ItemType Directory -Force | Out-Null

    if (-not (Test-Path $installer)) {
        Write-Host "[entrypoint] Installer bulunamadi: $installer" -ForegroundColor Red
        Exit-Entrypoint 1
    }
    if (-not (Test-Path $issFile)) {
        Write-Host "[entrypoint] setup.iss bulunamadi: $issFile" -ForegroundColor Red
        Exit-Entrypoint 1
    }

    Remove-Item $marker, $installLog -Force -ErrorAction SilentlyContinue

    $p = Start-Process -FilePath $installer `
        -ArgumentList '-s', "-f1`"$issFile`"", "-f2`"$installLog`"" `
        -PassThru -NoNewWindow

    # ONEMLI: Process handle'ini cache'le. Bunu yapmazsan surec hizli bitince
    # $p.ExitCode $null doner (bilinen PowerShell davranisi).
    $null = $p.Handle

    Write-Host "[entrypoint] PID: $($p.Id) - Kurulum devam ediyor..." -ForegroundColor DarkGray

    # Ayni process icinde poll et (Start-Job'in Write-Host ciktisi stdout'a dusmez)
    while (-not $p.HasExited) {
        Show-NewLogLines -Paths @(Get-WatchPaths)
        Start-Sleep -Seconds 1
    }
    $p.WaitForExit()
    Show-NewLogLines -Paths @(Get-WatchPaths)

    $exitCode = $p.ExitCode

    # InstallShield sonucu install.log icindeki ResultCode= satirinda da yazar
    $resultCode = $null
    if (Test-Path $installLog) {
        $m = Select-String -Path $installLog -Pattern '^ResultCode=(-?\d+)' | Select-Object -First 1
        if ($m) { $resultCode = [int]$m.Matches[0].Groups[1].Value }
    }

    # $null olan deger "bilinmiyor" demektir, hata sayilmaz; sadece sifirdan farkli
    # GERCEK bir deger hata sayilir. Ikisi de bilinmiyorsa bin klasoru kontrolune guveniriz.
    $exitBad   = ($null -ne $exitCode)   -and ($exitCode -ne 0)
    $resultBad = ($null -ne $resultCode) -and ($resultCode -ne 0)

    if ($exitBad -or $resultBad) {
        Write-Host "[entrypoint] Kurulum basarisiz. ExitCode: $exitCode ResultCode: $resultCode" -ForegroundColor Red
        if ($exitBad) { Exit-Entrypoint $exitCode } else { Exit-Entrypoint 1 }
    }
    if (($null -eq $exitCode) -and ($null -eq $resultCode)) {
        Write-Host "[entrypoint] Uyari: ExitCode ve ResultCode okunamadi, kurulum dizinine gore devam ediliyor." -ForegroundColor Yellow
    }

    if (-not (Test-Path $binDir)) {
        Write-Host "[entrypoint] Kurulum 'basarili' dondu ama $binDir yok. Installer erken cikmis olabilir." -ForegroundColor Red
        Exit-Entrypoint 1
    }

    New-Item -Path $marker -ItemType File -Force | Out-Null
    Write-Host "[entrypoint] Kurulum basarili." -ForegroundColor Green
}
else {
    Write-Host "[entrypoint] Zaten kurulu, kurulum atlaniyor."
}

# --- 2) Uygulamayi baslat ----------------------------------------------------
$svcMatches = @(Get-Service | Where-Object {
    $_.Name -like '*ADManager*' -or $_.DisplayName -like '*ADManager*'
})
$svc     = $svcMatches | Select-Object -First 1
$appProc = $null

if ($svc) {
    Write-Host "[entrypoint] Bulunan servisler: $(($svcMatches | ForEach-Object { $_.Name }) -join ', ')"
    Write-Host "[entrypoint] Izlenecek servis: $($svc.Name) (durum: $($svc.Status))"
    if ($svc.Status -eq 'Stopped') {
        try {
            # Start() asenkron: servis StartPending iken loglari akitmaya devam edebiliriz.
            # Start-Service ise ~30 sn'de zaman asimina ugrayabilir.
            $svc.Start()
        }
        catch {
            Write-Host "[entrypoint] Servis baslatilamadi: $($_.Exception.Message)" -ForegroundColor Red
            Exit-Entrypoint 1
        }
    }
}
else {
    $runBat = Join-Path $binDir 'run.bat'
    if (-not (Test-Path $runBat)) {
        Write-Host "[entrypoint] Servis yok ve $runBat bulunamadi." -ForegroundColor Red
        Exit-Entrypoint 1
    }
    Write-Host "[entrypoint] Servis yok, run.bat ile baslatiliyor..."
    $appProc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'run.bat' `
        -WorkingDirectory $binDir -WindowStyle Hidden -PassThru
}

# --- 3) Loglari stdout'a bas + uygulama sagligini izle -----------------------
$stoppedPolls = 0
try {
    while ($true) {
        Show-NewLogLines -Paths @(Get-WatchPaths) -InitialTail $initialTail

        if ($svc) {
            $svc.Refresh()
            if ($svc.Status -eq 'Stopped') { $stoppedPolls++ } else { $stoppedPolls = 0 }
            if ($stoppedPolls -ge 5) {
                Write-Host "[entrypoint] Servis durdu ($($svc.Name)). Container sonlandiriliyor." -ForegroundColor Red
                Exit-Entrypoint 1
            }
        }
        elseif ($appProc -and $appProc.HasExited) {
            Show-NewLogLines -Paths @(Get-WatchPaths) -InitialTail $initialTail
            Write-Host "[entrypoint] run.bat sonlandi (ExitCode: $($appProc.ExitCode)). Container sonlandiriliyor." -ForegroundColor Red
            Exit-Entrypoint 1
        }

        Start-Sleep -Seconds 2
    }
}
finally {
    # docker stop sirasinda uygulamayi duzgun kapatmaya calis (best-effort)
    try {
        if ($svc) {
            $svc.Refresh()
            if ($svc.Status -ne 'Stopped') {
                Write-Host "[entrypoint] Servis durduruluyor: $($svc.Name)"
                Stop-Service -Name $svc.Name -Force
            }
        }
        elseif ($appProc -and -not $appProc.HasExited) {
            & taskkill.exe /PID $appProc.Id /T /F | Out-Null
        }
    }
    catch { }
}