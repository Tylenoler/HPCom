[CmdletBinding()]
param(
    [switch]$KeepRunning,
    [string]$FlutterSdk = 'D:\Fluttersdk\flutter',
    [string]$RustRoot = 'D:\HCOM-Rust'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutter = Join-Path $FlutterSdk 'bin\flutter.bat'
$dart = Join-Path $FlutterSdk 'bin\dart.bat'
$cargo = Join-Path $RustRoot 'cargo\bin\cargo.exe'

if (-not (Test-Path -LiteralPath $flutter)) {
    throw "Flutter SDK was not found at $FlutterSdk."
}
if (-not (Test-Path -LiteralPath $dart)) {
    throw "Dart SDK was not found at $dart."
}
if (-not (Test-Path -LiteralPath $cargo)) {
    throw "Rust Cargo was not found at $cargo."
}

function Invoke-CheckedTool {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    Write-Host "`n== $Label ==" -ForegroundColor Cyan
    & $Path @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

function Wait-ForReleaseArtifacts {
    param([datetime]$StartedAt)

    $releaseDirectory = Join-Path $projectRoot 'build\windows\x64\runner\Release'
    $freshArtifacts = @(
        (Join-Path $releaseDirectory 'hcom.exe'),
        (Join-Path $releaseDirectory 'data\app.so')
    )
    $coreArtifact = Join-Path $releaseDirectory 'hcom-core.exe'
    $deadline = (Get-Date).AddMinutes(5)
    do {
        $allFresh = $true
        foreach ($path in $freshArtifacts) {
            if (-not (Test-Path -LiteralPath $path) -or
                (Get-Item -LiteralPath $path).LastWriteTime -lt $StartedAt.AddSeconds(-2)) {
                $allFresh = $false
                break
            }
        }
        if ($allFresh -and (Test-Path -LiteralPath $coreArtifact)) {
            return @($freshArtifacts[0], $coreArtifact, $freshArtifacts[1])
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    throw 'Release artifacts were not all rebuilt within five minutes.'
}

Push-Location $projectRoot
try {
    $revision = (& git rev-parse --short HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the Git revision.' }
    $dirty = (& git status --porcelain)
    if ($dirty) { $revision = "$revision-dirty" }
    $buildTime = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss UTC')

    Invoke-CheckedTool 'Clean Flutter build cache' $flutter @('clean')
    Invoke-CheckedTool 'Resolve Flutter dependencies' $flutter @('pub', 'get')
    Invoke-CheckedTool 'Verify Dart formatting' $dart @('format', '--set-exit-if-changed', 'lib', 'test')
    Invoke-CheckedTool 'Analyze Flutter application' $flutter @('analyze', '--no-pub')
    Invoke-CheckedTool 'Run Flutter tests' $flutter @('test', '--no-pub', 'test\widget_test.dart')
    Invoke-CheckedTool 'Run Rust Core tests' $cargo @('test', '--manifest-path', 'core\Cargo.toml')

    $buildStartedAt = Get-Date
    Invoke-CheckedTool 'Build Windows Release' $flutter @(
        'build', 'windows', '--release', '--no-tree-shake-icons',
        "--dart-define=HCOM_GIT_SHA=$revision",
        "--dart-define=HCOM_BUILD_TIME=$buildTime"
    )
    $artifacts = Wait-ForReleaseArtifacts $buildStartedAt

    $releaseDirectory = Split-Path -Parent $artifacts[0]
    $hashFile = Join-Path $releaseDirectory 'SHA256SUMS.txt'
    $hashLines = $artifacts | ForEach-Object {
        $hash = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([IO.Path]::GetFileName($_))"
    }
    Set-Content -LiteralPath $hashFile -Value $hashLines -Encoding ascii

    Write-Host "`n== Launch check ==" -ForegroundColor Cyan
    $process = Start-Process -FilePath $artifacts[0] -PassThru
    Start-Sleep -Seconds 5
    $process.Refresh()
    if ($process.HasExited -or -not $process.Responding) {
        throw 'Release launch check failed: hcom.exe did not remain responsive.'
    }
    if (-not $KeepRunning) {
        Stop-Process -Id $process.Id -Force
    }

    Write-Host "`nBUILD SUCCEEDED" -ForegroundColor Green
    Write-Host "Release: $releaseDirectory"
    Write-Host "Identity: App 0.3.2 · Core 0.2.0 · IPC v1 · $revision · $buildTime"
    Write-Host "SHA256: $hashFile"
}
finally {
    Pop-Location
}
