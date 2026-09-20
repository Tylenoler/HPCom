[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [string]$Platform = 'x64'
)

$ErrorActionPreference = 'Stop'
$driverRoot = Split-Path -Parent $PSCommandPath
$wdkRoot = 'C:\Program Files (x86)\Windows Kits\10'
$wdfHeader = Get-ChildItem "$wdkRoot\Include\wdf\kmdf" -Filter wdf.h -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
$inf2cat = Get-ChildItem "$wdkRoot\bin" -Filter inf2cat.exe -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($null -eq $wdfHeader -or $null -eq $inf2cat) {
    throw 'WDK/KMDF is not installed. Install Microsoft.WindowsWDK.10.0.26100 before building HCOM VCOM.'
}

$msbuild = Get-ChildItem 'D:\VisualStudioCommunity\MSBuild\Current\Bin\MSBuild.exe',
    'D:\VisualStudioCommunity\MSBuild\Microsoft\VC\v170\Bin\MSBuild.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($null -eq $msbuild) {
    throw 'Visual Studio MSBuild was not found.'
}

& $msbuild.FullName (Join-Path $driverRoot 'hcom-vcom.vcxproj') "/p:Configuration=$Configuration" "/p:Platform=$Platform" /m
if ($LASTEXITCODE -ne 0) { throw "Driver build failed with exit code $LASTEXITCODE." }
& $msbuild.FullName (Join-Path $driverRoot 'installer\hcom-vcom-installer.vcxproj') "/p:Configuration=$Configuration" "/p:Platform=$Platform" /m
if ($LASTEXITCODE -ne 0) { throw "Driver installer helper build failed with exit code $LASTEXITCODE." }

$packageDirectory = Join-Path $driverRoot "out\$Platform\$Configuration\package"
New-Item -ItemType Directory -Path $packageDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $driverRoot "out\$Platform\$Configuration\hcom-vcom.sys") -Destination $packageDirectory -Force
Copy-Item -LiteralPath (Join-Path $driverRoot "out\$Platform\$Configuration\hcom-vcom-installer.exe") -Destination $packageDirectory -Force
Copy-Item -LiteralPath (Join-Path $driverRoot 'hcom-vcom.inf') -Destination $packageDirectory -Force
# 10_GE is the Windows 11 family name understood by the installed WDK's
# Inf2Cat.  "11_X64" is not a valid Inf2Cat target token.
& $inf2cat.FullName /driver:$packageDirectory /os:10_X64,10_GE_X64
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat failed with exit code $LASTEXITCODE." }

Write-Host "Driver package: $packageDirectory" -ForegroundColor Green
