Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$consultPath = Join-Path $repoRoot "codex\bin\gemini-consult.ps1"
$duelPath = Join-Path $repoRoot "codex\bin\gemini-duel.ps1"
$getContextPath = Join-Path $repoRoot "scripts\get-context.ps1"
$installHooksPath = Join-Path $repoRoot "scripts\install-hooks.ps1"
$scratchRoot = Join-Path $env:TEMP "codex-gemini-automation-features"

if (Test-Path -LiteralPath $scratchRoot) {
  try {
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force
  } catch {
    cmd.exe /d /c "rmdir /s /q `"$scratchRoot`"" | Out-Null
  }
}
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

$projectRoot = Join-Path $scratchRoot "project"
New-Item -ItemType Directory -Path (Join-Path $projectRoot "src") -Force | Out-Null
Set-Content -LiteralPath (Join-Path $projectRoot "src\a.ts") -Encoding utf8 -Value @'
import { b } from "./b"

export const a = () => b
'@
Set-Content -LiteralPath (Join-Path $projectRoot "src\b.ts") -Encoding utf8 -Value @'
export const b = 1
'@

git -C $projectRoot init | Out-Null
git -C $projectRoot config user.email "codex@example.com"
git -C $projectRoot config user.name "Codex"
git -C $projectRoot add .
git -C $projectRoot commit -m "init" | Out-Null

Set-Content -LiteralPath (Join-Path $projectRoot "src\a.ts") -Encoding utf8 -Value @'
import { b } from "./b"

export const a = () => {
  return b + 1
}
'@
git -C $projectRoot add .
git -C $projectRoot status --short | Out-Null

$contextOutput = & $getContextPath -RepositoryRoot $projectRoot
$contextParts = @(($contextOutput | Out-String).Trim() -split '\s*,\s*' | Where-Object { $_ } | ForEach-Object {
  ([string]$_).Trim().Replace('/', '\')
})
$joinedContext = ($contextParts -join ",")
if ($joinedContext -notlike '*a.ts*') {
  throw "Auto-context output missing src\\a.ts. Actual: [$joinedContext]"
}
if ($joinedContext -notlike '*b.ts*') {
  throw "Auto-context output missing src\\b.ts. Actual: [$joinedContext]"
}

$mockResponsePath = Join-Path $scratchRoot "mock-response.json"
Set-Content -LiteralPath $mockResponsePath -Encoding utf8 -Value @'
{
  "output": "## DECISION\nUse the focused implementation path.\n\n## IMPLEMENTATION_PLAN\n1. Update the target file.\n2. Verify the result.\n\n## RISKS\nNone\n\n## FILES_TO_TOUCH\nsrc/a.ts\nsrc/b.ts"
}
'@

$artifactDir = Join-Path $scratchRoot "consult-artifacts"
$consultStdout = & $consultPath `
  -WorkingDirectory $projectRoot `
  -ArtifactDirectory $artifactDir `
  -ArtifactPrefix "auto-mode" `
  -MockResponseFile $mockResponsePath `
  -PromptText "implement a new component module and keep the current data flow"

$metadata = Get-Content -LiteralPath (Join-Path $artifactDir "auto-mode-metadata.json") -Raw | ConvertFrom-Json
if ($metadata.mode -ne "ui-implement") {
  throw "Expected inferred mode ui-implement, got $($metadata.mode)"
}
if ($metadata.executionMode -ne "build") {
  throw "Expected inferred executionMode build, got $($metadata.executionMode)"
}
if (-not $metadata.contextAutoDiscovered) {
  throw "Expected contextAutoDiscovered=true"
}
if (-not $metadata.structuredSectionsPresent) {
  throw "Expected structuredSectionsPresent=true"
}

$sections = Get-Content -LiteralPath (Join-Path $artifactDir "auto-mode-sections.json") -Raw | ConvertFrom-Json
if ($sections.decision -ne "Use the focused implementation path.") {
  throw "Unexpected structured decision section"
}

$duelMockPackagePath = Join-Path $scratchRoot "gemini-package.json"
Set-Content -LiteralPath $duelMockPackagePath -Encoding utf8 -Value @'
{
  "planMarkdown": "# Plan`n1. Change src/a.ts",
  "summaryMarkdown": "# Summary`nMock candidate",
  "files": [
    {
      "path": "src/a.ts",
      "content": "import { b } from \"./b\"`n`nexport const a = () => b + 2`n"
    }
  ]
}
'@

$duelOutput = & $duelPath `
  -WorkingDirectory $projectRoot `
  -DuelId "autorun-smoke" `
  -PromptText "Refactor the changed module without widening scope." `
  -GeminiMockPackageFile $duelMockPackagePath `
  -ValidationCommand "powershell -NoProfile -Command ""exit 0""" `
  -AutoRun

$duelText = ($duelOutput | Out-String)
foreach ($expectedStage in @("Stage 1/5: Preparing candidates...", "Stage 2/5: Recording Codex candidate...", "Stage 3/5: Generating Gemini candidate...", "Stage 4/5: Running machine judge...", "Stage 5/5: Writing verdict...")) {
  if ($duelText -notmatch [regex]::Escape($expectedStage)) {
    throw "Missing AutoRun progress line: $expectedStage"
  }
}

$verdictPath = Join-Path $projectRoot ".codex\duels\autorun-smoke\judge\verdict.md"
if (-not (Test-Path -LiteralPath $verdictPath -PathType Leaf)) {
  throw "Missing verdict.md after AutoRun"
}

& $installHooksPath -RepositoryRoot $projectRoot | Out-Null
$hookPath = Join-Path $projectRoot ".git\hooks\post-commit"
if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) {
  throw "Hook installer did not create post-commit hook"
}

$env:CODEX_GEMINI_POST_COMMIT_LAUNCHER = $consultPath
$env:CODEX_GEMINI_POST_COMMIT_MOCK_RESPONSE_FILE = $mockResponsePath
Set-Content -LiteralPath (Join-Path $projectRoot "src\b.ts") -Encoding utf8 -Value @'
export const b = 5
'@
git -C $projectRoot add src/b.ts
git -C $projectRoot commit -m "trigger hook" | Out-Null
$reviewHash = (git -C $projectRoot rev-parse --short HEAD).Trim()
$reviewPath = Join-Path $projectRoot (".codex\reviews\" + $reviewHash + ".md")
for ($attempt = 0; $attempt -lt 40 -and -not (Test-Path -LiteralPath $reviewPath -PathType Leaf); $attempt++) {
  Start-Sleep -Milliseconds 250
}
if (-not (Test-Path -LiteralPath $reviewPath -PathType Leaf)) {
  throw "Post-commit critique did not write review artifact"
}

Write-Host "AUTOMATION_FEATURES_OK"
