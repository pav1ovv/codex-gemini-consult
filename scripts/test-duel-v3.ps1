Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$launcherPath = Join-Path $repoRoot "codex\bin\gemini-duel.ps1"
$scratchRoot = Join-Path $env:TEMP "codex-gemini-duel-test-v3"
$duelId = "v3-staged-smoke"
$artifactRoot = Join-Path $scratchRoot ".codex\duels\$duelId"
$mockPackagePath = Join-Path $scratchRoot "gemini-package-v3.json"

if (Test-Path -LiteralPath $scratchRoot) {
  Remove-Item -LiteralPath $scratchRoot -Recurse -Force
}

New-Item -ItemType Directory -Path (Join-Path $scratchRoot "src\shell") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $scratchRoot "src\routes") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $scratchRoot "src\contracts") -Force | Out-Null

$sharedShellPath = Join-Path $scratchRoot "src\shell\shared-shell.tsx"
$routePath = Join-Path $scratchRoot "src\routes\accounts.tsx"
$contractPath = Join-Path $scratchRoot "src\contracts\bulk-select.json"
$extraContextA = Join-Path $scratchRoot "src\shell\layout-notes.md"
$extraContextB = Join-Path $scratchRoot "src\shell\tokens.md"

Set-Content -LiteralPath $sharedShellPath -Encoding utf8 -Value ("shell`n" * 700)
Set-Content -LiteralPath $routePath -Encoding utf8 -Value ("route`n" * 500)
Set-Content -LiteralPath $contractPath -Encoding utf8 -Value '{ "contract": "bulk-select" }'
Set-Content -LiteralPath $extraContextA -Encoding utf8 -Value ("layout`n" * 600)
Set-Content -LiteralPath $extraContextB -Encoding utf8 -Value ("tokens`n" * 600)

if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
  throw "Launcher missing: $launcherPath"
}

$prepareStdout = & $launcherPath `
  -WorkingDirectory $scratchRoot `
  -DuelId $duelId `
  -PromptText "Replace the design comprehensively, but preserve screen purpose, route structure, buildPayload behavior, and bulk account operations." `
  -LockedScope `
  -ContextPath @(
    "src\shell\shared-shell.tsx",
    "src\routes\accounts.tsx",
    "src\contracts\bulk-select.json",
    "src\shell\layout-notes.md",
    "src\shell\tokens.md"
  ) `
  -ForbiddenChangeSurface @("src\contracts", "buildPayload") `
  -ValidationCommand "if (-not (Test-Path -LiteralPath 'src\\routes\\accounts.tsx')) { throw 'route missing' }" `
  -PrepareCandidates `
  -DryRun

$requiredPacketFiles = @(
  "packet\objective.md",
  "packet\constraints.md",
  "packet\scope.json",
  "packet\context-manifest.json",
  "packet\context-summary.json",
  "packet\output-contract.md",
  "packet\stage.md",
  "scope-audit.md",
  "task-shape.json",
  "compact-brief.md",
  "reroute-log.json",
  "resume.json"
)

foreach ($relativePath in $requiredPacketFiles) {
  $target = Join-Path $artifactRoot $relativePath
  if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Missing required v3 artifact: $target"
  }
}

$resume = Get-Content -LiteralPath (Join-Path $artifactRoot "resume.json") -Raw | ConvertFrom-Json
if ($resume.pipelineVersion -ne "v3") {
  throw "Expected pipelineVersion v3, got $($resume.pipelineVersion)"
}
if ($resume.phases.scopeAudit -ne "ready") {
  throw "Expected scopeAudit phase to be ready after preparation, got $($resume.phases.scopeAudit)"
}
if ($resume.phases.briefCompact -ne "ready") {
  throw "Expected briefCompact phase to be ready after preparation, got $($resume.phases.briefCompact)"
}
if ($resume.packetBudget.decision -notin @("compact-first", "split-stage", "block-until-narrowed")) {
  throw "Expected oversized preparation to avoid direct allow, got $($resume.packetBudget.decision)"
}
if (-not $resume.reroute.required) {
  throw "Expected oversized staged duel to require reroute"
}

$taskShape = Get-Content -LiteralPath (Join-Path $artifactRoot "task-shape.json") -Raw | ConvertFrom-Json
if ($taskShape.classification -notin @("shared-shell-redesign", "route-scoped-implementation", "broad-ui-redesign")) {
  throw "Unexpected task-shape classification: $($taskShape.classification)"
}

$mockPackage = @'
{
  "planMarkdown": "# Gemini Candidate Plan\n\n- Narrow to the shared shell and the route file.\n",
  "summaryMarkdown": "# Gemini Candidate Summary\n\n- Locked scope preserved.\n",
  "files": [
    {
      "path": "src/shell/shared-shell.tsx",
      "content": "shared shell redesign"
    },
    {
      "path": "src/routes/accounts.tsx",
      "content": "route implementation"
    }
  ]
}
'@
Set-Content -LiteralPath $mockPackagePath -Encoding utf8 -Value $mockPackage

$generateStdout = & $launcherPath `
  -WorkingDirectory $scratchRoot `
  -DuelId $duelId `
  -PromptText "Replace the design comprehensively, but preserve screen purpose, route structure, buildPayload behavior, and bulk account operations." `
  -LockedScope `
  -ContextPath @(
    "src\shell\shared-shell.tsx",
    "src\routes\accounts.tsx",
    "src\contracts\bulk-select.json",
    "src\shell\layout-notes.md",
    "src\shell\tokens.md"
  ) `
  -ForbiddenChangeSurface @("src\contracts", "buildPayload") `
  -ValidationCommand "if (-not (Test-Path -LiteralPath 'src\\routes\\accounts.tsx')) { throw 'route missing' }" `
  -GeminiMode ui-redesign `
  -GeminiExpectedDuration long `
  -GeminiMockPackageFile $mockPackagePath `
  -GenerateGeminiCandidate

$recordCodexStdout = & $launcherPath `
  -WorkingDirectory $scratchRoot `
  -DuelId $duelId `
  -PromptText "Replace the design comprehensively, but preserve screen purpose, route structure, buildPayload behavior, and bulk account operations." `
  -LockedScope `
  -ContextPath @(
    "src\shell\shared-shell.tsx",
    "src\routes\accounts.tsx",
    "src\contracts\bulk-select.json",
    "src\shell\layout-notes.md",
    "src\shell\tokens.md"
  ) `
  -ForbiddenChangeSurface @("src\contracts", "buildPayload") `
  -ValidationCommand "if (-not (Test-Path -LiteralPath 'src\\routes\\accounts.tsx')) { throw 'route missing' }" `
  -RecordCodexCandidate

$requiredGeminiArtifacts = @(
  "gemini\attempts.json",
  "gemini\attempt-1-raw.txt",
  "gemini\attempt-1-normalized.txt",
  "gemini\attempt-1-package.json",
  "gemini\attempt-1-metadata.json",
  "gemini\plan.md",
  "gemini\summary.md",
  "gemini\candidate.json"
)

foreach ($relativePath in $requiredGeminiArtifacts) {
  $target = Join-Path $artifactRoot $relativePath
  if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Missing required Gemini v3 artifact: $target"
  }
}

$attemptMetadata = Get-Content -LiteralPath (Join-Path $artifactRoot "gemini\attempt-1-metadata.json") -Raw | ConvertFrom-Json
if (-not $attemptMetadata.success) {
  throw "Expected attempt metadata to mark the Gemini run successful"
}
if (-not $attemptMetadata.packageExtractionSucceeded) {
  throw "Expected package extraction to succeed from persisted artifacts"
}

$judgeStdout = & $launcherPath `
  -WorkingDirectory $scratchRoot `
  -DuelId $duelId `
  -PromptText "Replace the design comprehensively, but preserve screen purpose, route structure, buildPayload behavior, and bulk account operations." `
  -LockedScope `
  -ContextPath @(
    "src\shell\shared-shell.tsx",
    "src\routes\accounts.tsx",
    "src\contracts\bulk-select.json",
    "src\shell\layout-notes.md",
    "src\shell\tokens.md"
  ) `
  -ForbiddenChangeSurface @("src\contracts", "buildPayload") `
  -ValidationCommand "if (-not (Test-Path -LiteralPath 'src\\routes\\accounts.tsx')) { throw 'route missing' }" `
  -Judge

$scoreboard = Get-Content -LiteralPath (Join-Path $artifactRoot "judge\scoreboard.json") -Raw | ConvertFrom-Json
if (-not $scoreboard.reroutedRun) {
  throw "Expected scoreboard to mark the duel as rerouted"
}
if ($scoreboard.packetBudget.decision -eq "allow") {
  throw "Expected scoreboard to preserve the non-allow packet budget decision"
}

$verdictStdout = & $launcherPath `
  -WorkingDirectory $scratchRoot `
  -DuelId $duelId `
  -PromptText "Replace the design comprehensively, but preserve screen purpose, route structure, buildPayload behavior, and bulk account operations." `
  -LockedScope `
  -ContextPath @(
    "src\shell\shared-shell.tsx",
    "src\routes\accounts.tsx",
    "src\contracts\bulk-select.json",
    "src\shell\layout-notes.md",
    "src\shell\tokens.md"
  ) `
  -ForbiddenChangeSurface @("src\contracts", "buildPayload") `
  -ValidationCommand "if (-not (Test-Path -LiteralPath 'src\\routes\\accounts.tsx')) { throw 'route missing' }" `
  -WriteVerdict `
  -VerdictChoice merge-best-of-both `
  -PrepareMergeWorkspace

$mergeWorkspace = Join-Path $artifactRoot "judge\merge-best-of-both\workspace"
if (-not (Test-Path -LiteralPath $mergeWorkspace -PathType Container)) {
  throw "Expected merge-best-of-both workspace at $mergeWorkspace"
}

Write-Host "DUEL_V3_FLOW_OK"
if ($prepareStdout) {
  Write-Host $prepareStdout
}
if ($generateStdout) {
  Write-Host $generateStdout
}
if ($recordCodexStdout) {
  Write-Host $recordCodexStdout
}
if ($judgeStdout) {
  Write-Host $judgeStdout
}
if ($verdictStdout) {
  Write-Host $verdictStdout
}
