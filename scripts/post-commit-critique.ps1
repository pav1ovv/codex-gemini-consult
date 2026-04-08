param(
  [string]$RepositoryRoot = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
  $repoRoot = (& git -C $RepositoryRoot rev-parse --show-toplevel 2>$null | Select-Object -First 1).Trim()
  if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    exit 0
  }

  $changed = @(& git -C $repoRoot diff --name-only HEAD~1 HEAD 2>$null)
  if (@($changed).Count -eq 0) {
    exit 0
  }

  $existingFiles = @()
  foreach ($item in $changed) {
    if ($item -match '^(?:\.codex|\.git|node_modules|dist|build|coverage)(?:/|\\)') {
      continue
    }

    $candidate = Join-Path $repoRoot $item
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $existingFiles += $item
    }
  }

  if (@($existingFiles).Count -eq 0) {
    exit 0
  }

  $launcherPath = if ($env:CODEX_GEMINI_POST_COMMIT_LAUNCHER) {
    $env:CODEX_GEMINI_POST_COMMIT_LAUNCHER
  } else {
    Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex\bin\gemini-consult.ps1"
  }

  if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    exit 0
  }

  $commitHash = (& git -C $repoRoot rev-parse --short HEAD 2>$null | Select-Object -First 1).Trim()
  if ([string]::IsNullOrWhiteSpace($commitHash)) {
    exit 0
  }

  $reviewRoot = Join-Path $repoRoot ".codex\reviews"
  if (-not (Test-Path -LiteralPath $reviewRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null
  }

  $reviewPath = Join-Path $reviewRoot ($commitHash + ".md")
  $artifactDir = Join-Path $env:TEMP ("codex-post-commit-" + $commitHash)
  if (Test-Path -LiteralPath $artifactDir) {
    Remove-Item -LiteralPath $artifactDir -Recurse -Force
  }

  $promptText = "Review the latest commit for regressions, weak spots, and follow-up improvements. Focus on the changed files only."
  if ($env:CODEX_GEMINI_POST_COMMIT_MOCK_RESPONSE_FILE) {
    $output = & $launcherPath `
      -Mode critique `
      -ExecutionMode critique `
      -ExpectedDuration long `
      -TimeoutSeconds 7200 `
      -WorkingDirectory $repoRoot `
      -ArtifactDirectory $artifactDir `
      -ArtifactPrefix ("post-commit-" + $commitHash) `
      -PromptText $promptText `
      -ContextPath $existingFiles `
      -MockResponseFile $env:CODEX_GEMINI_POST_COMMIT_MOCK_RESPONSE_FILE
  } else {
    $output = & $launcherPath `
      -Mode critique `
      -ExecutionMode critique `
      -ExpectedDuration long `
      -TimeoutSeconds 7200 `
      -WorkingDirectory $repoRoot `
      -ArtifactDirectory $artifactDir `
      -ArtifactPrefix ("post-commit-" + $commitHash) `
      -PromptText $promptText `
      -ContextPath $existingFiles
  }
  [System.IO.File]::WriteAllText($reviewPath, (($output | Out-String).Trim()), [System.Text.UTF8Encoding]::new($false))
} catch {
  exit 0
}

exit 0
