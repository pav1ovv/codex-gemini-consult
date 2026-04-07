Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$launcherPath = Join-Path $repoRoot "codex\bin\gemini-duel.ps1"
$scratchRoot = Join-Path $env:TEMP "codex-gemini-duel-test-nongit"
$artifactRoot = Join-Path $scratchRoot ".codex\duels"
$duelId = "smoke-dry-run"
$prompt = "Prepare a duel dry run for a locked-scope UI redesign."

if (Test-Path -LiteralPath $scratchRoot) {
  Remove-Item -LiteralPath $scratchRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
  throw "Launcher missing: $launcherPath"
}

$stdout = & $launcherPath `
  -WorkingDirectory $scratchRoot `
  -DuelId $duelId `
  -PromptText $prompt `
  -DryRun `
  -PrepareCandidates

$duelDirectory = Join-Path $artifactRoot $duelId
if ($null -eq $duelDirectory) {
  throw "No duel artifact directory was created under $artifactRoot"
}
if (-not (Test-Path -LiteralPath $duelDirectory -PathType Container)) {
  throw "Expected duel directory was not created: $duelDirectory"
}

$requiredFiles = @(
  "brief.md",
  "context-manifest.json",
  "constraints.json",
  "resume.json",
  "codex\diff.patch",
  "codex\plan.md",
  "codex\summary.md",
  "gemini\diff.patch",
  "gemini\plan.md",
  "gemini\summary.md"
)

foreach ($file in $requiredFiles) {
  $target = Join-Path $duelDirectory $file
  if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "Missing required artifact: $target"
  }
}

$resumePath = Join-Path $duelDirectory "resume.json"
$resume = Get-Content -LiteralPath $resumePath -Raw | ConvertFrom-Json
if ($resume.status -ne "dry-run-ready") {
  throw "Unexpected resume status: $($resume.status)"
}
if ($resume.duelId -ne $duelId) {
  throw "Unexpected duelId in resume.json: $($resume.duelId)"
}
if ($resume.candidateSetup.mode -ne "no-git-fallback") {
  throw "Expected no-git-fallback mode, got $($resume.candidateSetup.mode)"
}
foreach ($candidateName in @("codex", "gemini")) {
  $candidateRoot = $resume.candidateSetup.$candidateName.root
  if (-not (Test-Path -LiteralPath $candidateRoot -PathType Container)) {
    throw "Missing candidate workspace for $candidateName at $candidateRoot"
  }
}

$stdoutSecond = & $launcherPath `
  -WorkingDirectory $scratchRoot `
  -DuelId $duelId `
  -PromptText $prompt `
  -DryRun `
  -PrepareCandidates

$resumeSecond = Get-Content -LiteralPath $resumePath -Raw | ConvertFrom-Json
if ($resumeSecond.status -ne "dry-run-ready") {
  throw "Unexpected resume status after rerun: $($resumeSecond.status)"
}
if ($resumeSecond.runCount -lt 2) {
  throw "Expected rerun to increase runCount, got $($resumeSecond.runCount)"
}

#
# Git-root scenario
#
$gitRoot = Join-Path $env:TEMP "codex-gemini-duel-test-git"
$gitArtifactRoot = Join-Path $gitRoot ".codex\duels"
$gitDuelId = "git-smoke"
if (Test-Path -LiteralPath $gitRoot) {
  Remove-Item -LiteralPath $gitRoot -Recurse -Force
}

git clone --quiet --no-hardlinks $repoRoot $gitRoot | Out-Null

$gitStdout = & $launcherPath `
  -WorkingDirectory $gitRoot `
  -DuelId $gitDuelId `
  -PromptText "Prepare a git duel dry run." `
  -DryRun `
  -PrepareCandidates

$gitResumePath = Join-Path $gitArtifactRoot "$gitDuelId\resume.json"
if (-not (Test-Path -LiteralPath $gitResumePath -PathType Leaf)) {
  throw "Missing git resume.json at $gitResumePath"
}

$gitResume = Get-Content -LiteralPath $gitResumePath -Raw | ConvertFrom-Json
if ($gitResume.candidateSetup.mode -ne "git-worktree") {
  throw "Expected git-worktree mode, got $($gitResume.candidateSetup.mode)"
}
foreach ($candidateName in @("codex", "gemini")) {
  $candidateRoot = $gitResume.candidateSetup.$candidateName.root
  if (-not (Test-Path -LiteralPath $candidateRoot -PathType Container)) {
    throw "Missing git candidate workspace for $candidateName at $candidateRoot"
  }
  $gitPointer = Join-Path $candidateRoot ".git"
  if (-not (Test-Path -LiteralPath $gitPointer)) {
    throw "Expected git worktree pointer at $gitPointer"
  }
}

Write-Host "DUEL_DRY_RUN_OK"
Write-Host "Artifacts: $duelDirectory"
if ($stdout) {
  Write-Host $stdout
}
if ($stdoutSecond) {
  Write-Host $stdoutSecond
}
if ($gitStdout) {
  Write-Host $gitStdout
}

#
# Full non-git duel scenario with candidate recording, machine judge, and verdict
#
$fullRoot = Join-Path $env:TEMP "codex-gemini-duel-test-full"
$fullDuelId = "full-smoke"
$fullArtifactRoot = Join-Path $fullRoot ".codex\duels\$fullDuelId"
$mockPackagePath = Join-Path $fullRoot "gemini-package.json"

if (Test-Path -LiteralPath $fullRoot) {
  Remove-Item -LiteralPath $fullRoot -Recurse -Force
}

New-Item -ItemType Directory -Path (Join-Path $fullRoot "src") -Force | Out-Null
Set-Content -LiteralPath (Join-Path $fullRoot "src\app.txt") -Encoding utf8 -Value "baseline"
Set-Content -LiteralPath (Join-Path $fullRoot "forbidden.txt") -Encoding utf8 -Value "do not touch"

$fullStdout = & $launcherPath `
  -WorkingDirectory $fullRoot `
  -DuelId $fullDuelId `
  -PromptText "Run a full duel smoke test." `
  -LockedScope `
  -ForbiddenChangeSurface "forbidden.txt" `
  -ValidationCommand "if (-not (Test-Path -LiteralPath 'src\\app.txt')) { throw 'missing app.txt' }" `
  -PrepareCandidates `
  -DryRun

$fullResumePath = Join-Path $fullArtifactRoot "resume.json"
if (-not (Test-Path -LiteralPath $fullResumePath -PathType Leaf)) {
  throw "Missing full duel resume.json at $fullResumePath"
}
$fullResume = Get-Content -LiteralPath $fullResumePath -Raw | ConvertFrom-Json

$codexWorkspace = [string]$fullResume.candidateSetup.codex.root
$geminiWorkspace = [string]$fullResume.candidateSetup.gemini.root
Set-Content -LiteralPath (Join-Path $codexWorkspace "src\app.txt") -Encoding utf8 -Value "codex candidate"
Set-Content -LiteralPath (Join-Path $codexWorkspace "forbidden.txt") -Encoding utf8 -Value "codex touched forbidden surface"

$mockPackage = @'
{
  "planMarkdown": "# Gemini Candidate Plan\n\n- Update only the allowed app file.\n",
  "summaryMarkdown": "# Gemini Candidate Summary\n\n- Locked scope preserved.\n",
  "files": [
    {
      "path": "src/app.txt",
      "content": "gemini candidate"
    }
  ]
}
'@
Set-Content -LiteralPath $mockPackagePath -Encoding utf8 -Value $mockPackage

$recordCodexStdout = & $launcherPath `
  -WorkingDirectory $fullRoot `
  -DuelId $fullDuelId `
  -PromptText "Run a full duel smoke test." `
  -LockedScope `
  -ForbiddenChangeSurface "forbidden.txt" `
  -ValidationCommand "if (-not (Test-Path -LiteralPath 'src\\app.txt')) { throw 'missing app.txt' }" `
  -RecordCodexCandidate

$generateGeminiStdout = & $launcherPath `
  -WorkingDirectory $fullRoot `
  -DuelId $fullDuelId `
  -PromptText "Run a full duel smoke test." `
  -LockedScope `
  -ForbiddenChangeSurface "forbidden.txt" `
  -ValidationCommand "if (-not (Test-Path -LiteralPath 'src\\app.txt')) { throw 'missing app.txt' }" `
  -GenerateGeminiCandidate `
  -GeminiMockPackageFile $mockPackagePath

$attemptsPath = Join-Path $fullArtifactRoot "gemini\attempts.json"
if (-not (Test-Path -LiteralPath $attemptsPath -PathType Leaf)) {
  throw "Missing Gemini attempt log at $attemptsPath"
}
$attempts = Get-Content -LiteralPath $attemptsPath -Raw | ConvertFrom-Json
if (@($attempts).Count -lt 1) {
  throw "Expected at least one Gemini attempt entry"
}
if (-not @($attempts)[-1].success) {
  throw "Expected the latest Gemini attempt entry to be marked successful"
}

$judgeStdout = & $launcherPath `
  -WorkingDirectory $fullRoot `
  -DuelId $fullDuelId `
  -PromptText "Run a full duel smoke test." `
  -LockedScope `
  -ForbiddenChangeSurface "forbidden.txt" `
  -ValidationCommand "if (-not (Test-Path -LiteralPath 'src\\app.txt')) { throw 'missing app.txt' }" `
  -Judge

$scoreboardPath = Join-Path $fullArtifactRoot "judge\scoreboard.json"
if (-not (Test-Path -LiteralPath $scoreboardPath -PathType Leaf)) {
  throw "Missing scoreboard at $scoreboardPath"
}
$scoreboard = Get-Content -LiteralPath $scoreboardPath -Raw | ConvertFrom-Json
if ($scoreboard.environmentBlocked) {
  throw "Expected the smoke test environment to be scored normally, not as blocked-environment"
}
if ($scoreboard.recommendedWinner -ne "gemini") {
  throw "Expected gemini to win the machine judge, got $($scoreboard.recommendedWinner)"
}
$codexScore = $scoreboard.candidates | Where-Object { $_.name -eq "codex" } | Select-Object -First 1
$geminiScore = $scoreboard.candidates | Where-Object { $_.name -eq "gemini" } | Select-Object -First 1
if ($codexScore.gatePass) {
  throw "Codex candidate should have failed locked-scope gate after touching forbidden.txt"
}
if (-not $geminiScore.gatePass) {
  throw "Gemini candidate should have passed the machine judge in the smoke test"
}
if (@($codexScore.forbiddenTouched) -notcontains "forbidden.txt") {
  throw "Expected forbidden.txt to be reported as a forbidden Codex touch"
}

$verdictStdout = & $launcherPath `
  -WorkingDirectory $fullRoot `
  -DuelId $fullDuelId `
  -PromptText "Run a full duel smoke test." `
  -LockedScope `
  -ForbiddenChangeSurface "forbidden.txt" `
  -ValidationCommand "if (-not (Test-Path -LiteralPath 'src\\app.txt')) { throw 'missing app.txt' }" `
  -WriteVerdict

$verdictPath = Join-Path $fullArtifactRoot "judge\verdict.md"
if (-not (Test-Path -LiteralPath $verdictPath -PathType Leaf)) {
  throw "Missing verdict at $verdictPath"
}
$verdictContent = Get-Content -LiteralPath $verdictPath -Raw
if ($verdictContent -notmatch '## Final Choice\s+- gemini') {
  throw "Expected the default final verdict to follow the machine recommendation"
}

$mergeStdout = & $launcherPath `
  -WorkingDirectory $fullRoot `
  -DuelId $fullDuelId `
  -PromptText "Run a full duel smoke test." `
  -LockedScope `
  -ForbiddenChangeSurface "forbidden.txt" `
  -ValidationCommand "if (-not (Test-Path -LiteralPath 'src\\app.txt')) { throw 'missing app.txt' }" `
  -WriteVerdict `
  -VerdictChoice merge-best-of-both `
  -PrepareMergeWorkspace

$mergeWorkspace = Join-Path $fullArtifactRoot "judge\merge-best-of-both\workspace"
$mergePlan = Join-Path $fullArtifactRoot "judge\merge-best-of-both\merge-plan.md"
if (-not (Test-Path -LiteralPath $mergeWorkspace -PathType Container)) {
  throw "Missing merge workspace at $mergeWorkspace"
}
if (-not (Test-Path -LiteralPath $mergePlan -PathType Leaf)) {
  throw "Missing merge plan at $mergePlan"
}

Write-Host "DUEL_FULL_FLOW_OK"
if ($fullStdout) {
  Write-Host $fullStdout
}
if ($recordCodexStdout) {
  Write-Host $recordCodexStdout
}
if ($generateGeminiStdout) {
  Write-Host $generateGeminiStdout
}
if ($judgeStdout) {
  Write-Host $judgeStdout
}
if ($verdictStdout) {
  Write-Host $verdictStdout
}
if ($mergeStdout) {
  Write-Host $mergeStdout
}
