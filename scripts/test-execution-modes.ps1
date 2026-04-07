Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$launcherPath = Join-Path $repoRoot "codex\bin\gemini-consult.ps1"
$scratchRoot = Join-Path $env:TEMP "codex-gemini-execution-modes"

if (Test-Path -LiteralPath $scratchRoot) {
  Remove-Item -LiteralPath $scratchRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
  throw "Launcher missing: $launcherPath"
}

$cases = @(
  [PSCustomObject]@{
    ExecutionMode = "build"
    Prompt = "Reply with exactly BUILD_MODE_OK."
    ExpectedToken = "Execution mode: build"
    ExpectedHint = "Minimize discussion and move toward implementation-ready output"
  },
  [PSCustomObject]@{
    ExecutionMode = "think"
    Prompt = "Reply with exactly THINK_MODE_OK."
    ExpectedToken = "Execution mode: think"
    ExpectedHint = "Generate alternatives, compare trade-offs"
  },
  [PSCustomObject]@{
    ExecutionMode = "critique"
    Prompt = "Reply with exactly CRITIQUE_MODE_OK."
    ExpectedToken = "Execution mode: critique"
    ExpectedHint = "Do not generate a greenfield rewrite unless explicitly requested"
  }
)

foreach ($case in $cases) {
  $artifactDir = Join-Path $scratchRoot $case.ExecutionMode
  $stdout = & $launcherPath `
    -Mode architecture `
    -ExecutionMode $case.ExecutionMode `
    -ExpectedDuration quick `
    -WorkingDirectory $repoRoot `
    -ArtifactDirectory $artifactDir `
    -ArtifactPrefix "execution-mode" `
    -PromptText $case.Prompt

  $metadataPath = Join-Path $artifactDir "execution-mode-metadata.json"
  $promptPath = Join-Path $artifactDir "execution-mode-prompt.txt"

  if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw "Missing metadata artifact for execution mode $($case.ExecutionMode)"
  }
  if (-not (Test-Path -LiteralPath $promptPath -PathType Leaf)) {
    throw "Missing prompt artifact for execution mode $($case.ExecutionMode)"
  }

  $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
  if ($metadata.executionMode -ne $case.ExecutionMode) {
    throw "Expected metadata.executionMode=$($case.ExecutionMode), got $($metadata.executionMode)"
  }

  $promptText = Get-Content -LiteralPath $promptPath -Raw
  if ($promptText -notmatch [regex]::Escape($case.ExpectedToken)) {
    throw "Prompt artifact missing execution-mode token '$($case.ExpectedToken)'"
  }
  if ($promptText -notmatch [regex]::Escape($case.ExpectedHint)) {
    throw "Prompt artifact missing execution-mode hint '$($case.ExpectedHint)'"
  }
}

Write-Host "EXECUTION_MODES_OK"
