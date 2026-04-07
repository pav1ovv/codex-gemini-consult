Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$launcherPath = Join-Path $repoRoot "codex\bin\gemini-consult.ps1"
$scratchRoot = Join-Path $env:TEMP "codex-gemini-execution-modes"
$mockResponsePath = Join-Path $scratchRoot "mock-response.json"

if (Test-Path -LiteralPath $scratchRoot) {
  Remove-Item -LiteralPath $scratchRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
Set-Content -LiteralPath $mockResponsePath -Encoding utf8 -Value '{"output":"PIPE_MODE_OK`nBUILD_MODE_OK`nTHINK_MODE_OK`nCRITIQUE_MODE_OK"}'

if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
  throw "Launcher missing: $launcherPath"
}

$launcherSource = Get-Content -LiteralPath $launcherPath -Raw
if ($launcherSource -match [regex]::Escape('gemini-3-pro-preview')) {
  throw "Deprecated gemini-3-pro-preview should not remain in launcher fallback lists"
}
foreach ($requiredToken in @(
  '"ui-implement" { return @("gemini-3.1-pro-preview", "gemini-2.5-pro", "pro", "gemini-3-flash-preview", "gemini-2.5-flash", "flash") }',
  '"ui-redesign"  { return @("gemini-3.1-pro-preview", "gemini-2.5-pro", "pro", "gemini-3-flash-preview", "gemini-2.5-flash", "flash") }',
  '"docs"         { return @("gemini-3.1-pro-preview", "gemini-2.5-pro", "pro", "gemini-3-flash-preview", "gemini-2.5-flash", "flash", "gemini-3.1-flash-lite-preview", "gemini-2.5-flash-lite", "flash-lite") }',
  '"architecture" { return @("gemini-3.1-pro-preview", "gemini-2.5-pro", "pro", "gemini-3-flash-preview", "gemini-2.5-flash", "flash", "gemini-3.1-flash-lite-preview", "gemini-2.5-flash-lite", "flash-lite") }'
)) {
  if ($launcherSource -notmatch [regex]::Escape($requiredToken)) {
    throw "Launcher source missing expected quota-fallback chain: $requiredToken"
  }
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
    -MockResponseFile $mockResponsePath `
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

$pipeArtifactDir = Join-Path $scratchRoot "pipeline-input"
$pipePrompt = @'
You are paired with Codex. Reply with exactly PIPE_MODE_OK.
'@
$pipeStdout = $pipePrompt | & $launcherPath `
  -Mode architecture `
  -ExecutionMode think `
  -ExpectedDuration quick `
  -WorkingDirectory $repoRoot `
  -ArtifactDirectory $pipeArtifactDir `
  -ArtifactPrefix "pipeline-mode" `
  -MockResponseFile $mockResponsePath

$pipeMetadataPath = Join-Path $pipeArtifactDir "pipeline-mode-metadata.json"
$pipePromptPath = Join-Path $pipeArtifactDir "pipeline-mode-prompt.txt"

if (-not (Test-Path -LiteralPath $pipeMetadataPath -PathType Leaf)) {
  throw "Missing metadata artifact for PowerShell pipeline input"
}
if (-not (Test-Path -LiteralPath $pipePromptPath -PathType Leaf)) {
  throw "Missing prompt artifact for PowerShell pipeline input"
}

$pipeMetadata = Get-Content -LiteralPath $pipeMetadataPath -Raw | ConvertFrom-Json
if (-not $pipeMetadata.success) {
  throw "Expected pipeline-input metadata.success=true"
}

$pipePromptText = Get-Content -LiteralPath $pipePromptPath -Raw
if ($pipePromptText -notmatch [regex]::Escape("Reply with exactly PIPE_MODE_OK.")) {
  throw "Prompt artifact missing pipeline-provided prompt text"
}

if (($pipeStdout | Out-String) -notmatch "PIPE_MODE_OK") {
  throw "Expected launcher stdout to include PIPE_MODE_OK for pipeline input"
}

Write-Host "EXECUTION_MODES_OK"
