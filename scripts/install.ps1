param(
  [switch]$InstallGeminiCli,
  [switch]$AppendAgents
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Merge-ContextFileNames {
  param([string]$SettingsPath)

  $settings = @{}
  if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
    $raw = Get-Content -LiteralPath $SettingsPath -Raw
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $parsed = $raw | ConvertFrom-Json -Depth 50 -AsHashtable
      if ($null -ne $parsed) {
        $settings = $parsed
      }
    }
  }

  if (-not $settings.ContainsKey("context")) {
    $settings["context"] = @{}
  }

  $existingNames = @()
  if ($settings["context"].ContainsKey("fileName")) {
    $value = $settings["context"]["fileName"]
    if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
      $existingNames = @($value)
    } elseif ($null -ne $value) {
      $existingNames = @([string]$value)
    }
  }

  $merged = New-Object System.Collections.Generic.List[string]
  foreach ($name in @("AGENTS.md", "GEMINI.md") + $existingNames) {
    if (-not [string]::IsNullOrWhiteSpace($name) -and -not $merged.Contains($name)) {
      $merged.Add($name)
    }
  }

  $settings["context"]["fileName"] = @($merged)
  ($settings | ConvertTo-Json -Depth 50) | Set-Content -LiteralPath $SettingsPath -Encoding utf8
}

function Append-AgentsSnippet {
  param(
    [string]$AgentsPath,
    [string]$SnippetPath
  )

  $marker = "<!-- gemini-consult:start -->"
  $snippet = Get-Content -LiteralPath $SnippetPath -Raw

  if (Test-Path -LiteralPath $AgentsPath -PathType Leaf) {
    $existing = Get-Content -LiteralPath $AgentsPath -Raw
    if ($existing.Contains($marker)) {
      return
    }
    $separator = if ($existing.EndsWith("`n")) { "" } else { "`r`n`r`n" }
    Set-Content -LiteralPath $AgentsPath -Encoding utf8 -Value ($existing + $separator + $snippet.Trim() + "`r`n")
    return
  }

  Set-Content -LiteralPath $AgentsPath -Encoding utf8 -Value ($snippet.Trim() + "`r`n")
}

$repoRoot = Split-Path $PSScriptRoot -Parent
$userHome = [Environment]::GetFolderPath("UserProfile")
$codexHome = Join-Path $userHome ".codex"
$geminiHome = Join-Path $userHome ".gemini"

if ($InstallGeminiCli) {
  if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "npm not found on PATH. Install Node.js LTS first: https://nodejs.org/"
  }
  npm install -g @google/gemini-cli@latest
}

Ensure-Directory -Path $codexHome
Ensure-Directory -Path (Join-Path $codexHome "bin")
Ensure-Directory -Path (Join-Path $codexHome "skills")
Ensure-Directory -Path $geminiHome
Ensure-Directory -Path (Join-Path $geminiHome "context")
Ensure-Directory -Path (Join-Path $geminiHome "commands")
Ensure-Directory -Path (Join-Path $geminiHome "commands\\codex")

Copy-Item -LiteralPath (Join-Path $repoRoot "codex\\bin\\gemini-consult.ps1") -Destination (Join-Path $codexHome "bin\\gemini-consult.ps1") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "codex\\bin\\gemini-consult.cmd") -Destination (Join-Path $codexHome "bin\\gemini-consult.cmd") -Force

$skillTarget = Join-Path $codexHome "skills\\gemini-consult"
if (Test-Path -LiteralPath $skillTarget) {
  Remove-Item -LiteralPath $skillTarget -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $repoRoot "codex\\skills\\gemini-consult") -Destination $skillTarget -Recurse -Force

Copy-Item -LiteralPath (Join-Path $repoRoot "gemini\\GEMINI.md") -Destination (Join-Path $geminiHome "GEMINI.md") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "gemini\\context\\*") -Destination (Join-Path $geminiHome "context") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "gemini\\commands\\codex\\*") -Destination (Join-Path $geminiHome "commands\\codex") -Force

Merge-ContextFileNames -SettingsPath (Join-Path $geminiHome "settings.json")

if ($AppendAgents) {
  Append-AgentsSnippet `
    -AgentsPath (Join-Path $codexHome "AGENTS.md") `
    -SnippetPath (Join-Path $repoRoot "codex\\AGENTS.gemini-consult-snippet.md")
}

Write-Host ""
Write-Host "Install complete."
Write-Host "Gemini CLI: $(if (Get-Command gemini -ErrorAction SilentlyContinue) { 'available' } else { 'not found on PATH yet' })"
Write-Host "Codex skill: $skillTarget"
Write-Host "Gemini context: $(Join-Path $geminiHome 'GEMINI.md')"
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Run 'gemini' once and complete sign-in if needed."
Write-Host "2. Restart Codex so it reloads global skills and AGENTS context."
