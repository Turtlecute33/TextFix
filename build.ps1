# SPDX-License-Identifier: GPL-3.0-only
#
# Publishes the Native AOT agent to .\dist and, with -Zip, packages it for release.
#
#   .\build.ps1              # publish to windows\dist
#   .\build.ps1 -Zip         # publish and zip as TextFix-win-x64.zip
#   .\build.ps1 -Run         # publish and start the agent
#
# Requires the .NET 9 SDK and the MSVC C++ build tools (the AOT compiler links with link.exe).

[CmdletBinding()]
param(
    [switch]$Zip,
    [switch]$Run,
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$project = Join-Path $root "src\TextFix\TextFix.csproj"
$output = Join-Path $root "dist"

# The ILCompiler locates the MSVC linker through vswhere, which Visual Studio installs outside
# PATH. Adding the Installer directory is enough; a full Developer Prompt is not needed.
$installer = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer"
if ((Test-Path (Join-Path $installer "vswhere.exe")) -and ($env:PATH -notlike "*$installer*")) {
    $env:PATH = "$env:PATH;$installer"
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet was not found. Install the .NET 9 SDK: https://dotnet.microsoft.com/download"
}

Write-Host "Publishing $Configuration to $output" -ForegroundColor Cyan
dotnet publish $project -c $Configuration -o $output --nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE" }

$exe = Join-Path $output "TextFix.exe"
$sizeMb = [math]::Round((Get-Item $exe).Length / 1MB, 2)
Write-Host "Built TextFix.exe ($sizeMb MB, self-contained)" -ForegroundColor Green

if ($Zip) {
    $archive = Join-Path $root "TextFix-win-x64.zip"
    Remove-Item $archive -ErrorAction SilentlyContinue
    # The exe alone is the release: no runtime, no side-by-side files, no installer.
    Compress-Archive -Path $exe -DestinationPath $archive
    Write-Host "Packaged $archive" -ForegroundColor Green
}

if ($Run) {
    Get-Process TextFix -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Process $exe
    Write-Host "Agent started; look for the tray icon." -ForegroundColor Green
}
