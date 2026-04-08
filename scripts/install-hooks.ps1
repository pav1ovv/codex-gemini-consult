param(
  [string]$RepositoryRoot = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (& git -C $RepositoryRoot rev-parse --show-toplevel 2>$null | Select-Object -First 1).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
  throw "Current directory is not a git repository: $RepositoryRoot"
}

$hooksDir = Join-Path $repoRoot ".git\hooks"
if (-not (Test-Path -LiteralPath $hooksDir -PathType Container)) {
  throw "Hooks directory not found: $hooksDir"
}

$helperPath = Join-Path $PSScriptRoot "post-commit-critique.ps1"
if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
  throw "Missing helper script: $helperPath"
}

$hookPath = Join-Path $hooksDir "post-commit"
$helperPathEscaped = $helperPath.Replace('"', '\"')
$repoRootEscaped = $repoRoot.Replace('"', '\"')
$hookBody = @"
#!/usr/bin/env sh
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$helperPathEscaped" -RepositoryRoot "$repoRootEscaped" >/dev/null 2>&1 &
exit 0
"@

[System.IO.File]::WriteAllText($hookPath, $hookBody, [System.Text.UTF8Encoding]::new($false))
Write-Host "Installed post-commit hook: $hookPath"
