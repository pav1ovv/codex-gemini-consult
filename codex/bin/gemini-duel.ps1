param(
  [string]$WorkingDirectory = (Get-Location).Path,
  [string]$DuelId,
  [string[]]$ContextPath = @(),
  [int]$TimeoutSeconds = 0,
  [string[]]$AllowedChangeSurface = @(),
  [string[]]$ForbiddenChangeSurface = @(),
  [string[]]$ValidationCommand = @(),
  [switch]$LockedScope,
  [switch]$PrepareCandidates,
  [switch]$AutoRun,
  [switch]$DryRun,
  [switch]$GenerateGeminiCandidate,
  [switch]$RecordCodexCandidate,
  [switch]$RecordGeminiCandidate,
  [switch]$Judge,
  [switch]$WriteVerdict,
  [switch]$PrepareMergeWorkspace,
  [ValidateSet("codex", "gemini", "merge-best-of-both", "reject-both")]
  [string]$VerdictChoice,
  [ValidateSet("general", "ui-implement", "ui-redesign", "architecture")]
  [string]$GeminiMode = "architecture",
  [ValidateSet("quick", "normal", "long", "extended")]
  [string]$GeminiExpectedDuration = "long",
  [string]$GeminiModel,
  [string]$GeminiMockPackageFile,
  [string]$PromptFile,
  [string]$PromptText,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Prompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AbsolutePath {
  param(
    [string]$BaseDirectory,
    [string]$Candidate
  )

  if ([string]::IsNullOrWhiteSpace($Candidate)) {
    return $null
  }

  if ([System.IO.Path]::IsPathRooted($Candidate)) {
    return [System.IO.Path]::GetFullPath($Candidate)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Candidate))
}

function Get-RelativePathSafe {
  param(
    [string]$BasePath,
    [string]$TargetPath
  )

  try {
    return [System.IO.Path]::GetRelativePath($BasePath, $TargetPath)
  } catch {
    $resolvedBase = [System.IO.Path]::GetFullPath($BasePath)
    $resolvedTarget = [System.IO.Path]::GetFullPath($TargetPath)

    $baseUriText = if ($resolvedBase.EndsWith([System.IO.Path]::DirectorySeparatorChar) -or $resolvedBase.EndsWith([System.IO.Path]::AltDirectorySeparatorChar)) {
      $resolvedBase
    } else {
      $resolvedBase + [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = [System.Uri]::new($baseUriText)
    $targetUri = [System.Uri]::new($resolvedTarget)
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
  }
}

function Get-SlugValue {
  param([string]$InputText)

  if ([string]::IsNullOrWhiteSpace($InputText)) {
    return "duel"
  }

  $slug = $InputText.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
  $slug = $slug.Trim("-")
  if ([string]::IsNullOrWhiteSpace($slug)) {
    return "duel"
  }

  if ($slug.Length -gt 40) {
    return $slug.Substring(0, 40).Trim("-")
  }

  return $slug
}

function Get-DefaultDuelId {
  param([string]$InputPrompt)

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  return "$stamp-$(Get-SlugValue -InputText $InputPrompt)"
}

function Resolve-HelperScriptPath {
  param([string]$ScriptName)

  $candidatePaths = @(
    (Join-Path $PSScriptRoot $ScriptName),
    (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ("scripts\" + $ScriptName))
  )

  foreach ($candidate in $candidatePaths) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }

  return $null
}

function Get-AutoContextPath {
  param([string]$BaseDirectory)

  $helperPath = Resolve-HelperScriptPath -ScriptName "get-context.ps1"
  if (-not $helperPath) {
    return @()
  }

  try {
    $raw = & $helperPath -RepositoryRoot $BaseDirectory
    $joined = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($joined)) {
      return @()
    }
    return @(($joined -split '\s*,\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
  } catch {
    return @()
  }
}

function Invoke-DuelStage {
  param(
    [bool]$Enabled,
    [int]$Index,
    [int]$Total,
    [string]$Name,
    [scriptblock]$Action
  )

  if (-not $Enabled) {
    return
  }

  if ($AutoRun) {
    Write-Output ("Stage {0}/{1}: {2}..." -f $Index, $Total, $Name)
  }

  try {
    & $Action
  } catch {
    if ($AutoRun) {
      throw "AutoRun failed at stage $Index/$Total ($Name): $($_.Exception.Message)"
    }
    throw
  }
}

function Ensure-Directory {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-Utf8File {
  param(
    [string]$Path,
    [string]$Content
  )

  $parent = Split-Path $Path -Parent
  if ($parent) {
    Ensure-Directory -Path $parent
  }

  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Invoke-GitCommand {
  param(
    [string[]]$Arguments,
    [switch]$AllowFailure,
    [switch]$DiscardStderr
  )

  $quotedArguments = foreach ($argument in $Arguments) {
    if ($null -eq $argument) {
      '""'
      continue
    }

    $escaped = ([string]$argument).Replace('"', '\"')
    if ($escaped -match '\s|"') {
      '"' + $escaped + '"'
    } else {
      $escaped
    }
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "git"
  $psi.Arguments = ($quotedArguments -join " ")
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  [void]$process.Start()
  $stdoutText = $process.StandardOutput.ReadToEnd()
  $stderrText = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  $exitCode = $process.ExitCode

  if (-not $AllowFailure -and $exitCode -ne 0) {
    $details = if ($DiscardStderr) { "" } else { ": $stderrText" }
    throw "git $($Arguments -join ' ') failed with exit code $exitCode$details"
  }

  return [PSCustomObject]@{
    Output = (($stdoutText -split "\r?\n") | Where-Object { $_ -ne "" })
    Error = $stderrText
    ExitCode = $exitCode
  }
}

function Save-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $json = $Value | ConvertTo-Json -Depth 50
  Write-Utf8File -Path $Path -Content $json
}

function Load-JsonFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }

  return $raw | ConvertFrom-Json
}

function Append-JsonArrayFile {
  param(
    [string]$Path,
    [object]$Entry
  )

  $items = New-Object System.Collections.ArrayList
  $existing = Load-JsonFile -Path $Path
  if ($null -ne $existing) {
    foreach ($item in @($existing)) {
      [void]$items.Add($item)
    }
  }

  [void]$items.Add($Entry)
  Save-JsonFile -Path $Path -Value @($items)
}

function Get-CollectionCount {
  param([object]$Value)

  if ($null -eq $Value) {
    return 0
  }

  return @($Value).Count
}

function Read-PromptText {
  param(
    [string]$BaseDirectory,
    [string]$PromptFilePath,
    [string]$PromptTextValue,
    [string[]]$PromptArgs
  )

  $stdinText = ""
  if ([Console]::IsInputRedirected) {
    $stdinText = [Console]::In.ReadToEnd()
  }

  $promptFileText = ""
  if ($PromptFilePath) {
    $resolvedPromptFile = Resolve-AbsolutePath -BaseDirectory $BaseDirectory -Candidate $PromptFilePath
    if (-not (Test-Path -LiteralPath $resolvedPromptFile -PathType Leaf)) {
      throw "Prompt file not found: $resolvedPromptFile"
    }
    $promptFileText = Get-Content -LiteralPath $resolvedPromptFile -Raw
  }

  $argPrompt = ($PromptArgs -join " ").Trim()
  $resolved = @($stdinText.Trim(), $promptFileText.Trim(), $PromptTextValue, $argPrompt) -join "`n`n"
  return $resolved.Trim()
}

function Get-ResolvedTimeoutSeconds {
  param(
    [string]$SelectedDuration,
    [int]$ExplicitTimeoutSeconds
  )

  if ($ExplicitTimeoutSeconds -gt 0) {
    return $ExplicitTimeoutSeconds
  }

  switch ($SelectedDuration) {
    "quick" { return 600 }
    "long" { return 7200 }
    "extended" { return 14400 }
    default { return 1800 }
  }
}

function Build-ContextManifest {
  param(
    [string]$BaseDirectory,
    [string[]]$RequestedContextPath
  )

  $entries = foreach ($item in $RequestedContextPath) {
    $resolved = Resolve-AbsolutePath -BaseDirectory $BaseDirectory -Candidate $item
    $exists = $false
    $relativePath = $null
    $charCount = 0
    $lineCount = 0

    if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
      $exists = $true
      try {
        $relativePath = Get-RelativePathSafe -BasePath $BaseDirectory -TargetPath $resolved
      } catch {
        $relativePath = $resolved
      }

      try {
        $rawContent = Get-Content -LiteralPath $resolved -Raw
        $charCount = $rawContent.Length
        if ($rawContent.Length -gt 0) {
          $lineCount = @($rawContent -split "\r?\n").Count
        }
      } catch {
        $charCount = 0
        $lineCount = 0
      }
    }

    [PSCustomObject]@{
      requested = $item
      resolved = $resolved
      exists = $exists
      relativePath = $relativePath
      charCount = $charCount
      lineCount = $lineCount
    }
  }

  return [PSCustomObject]@{
    generatedAt = (Get-Date).ToString("o")
    projectRoot = $BaseDirectory
    entries = @($entries)
  }
}

function Build-BriefMarkdown {
  param(
    [string]$ProjectRoot,
    [string]$TaskPrompt,
    [bool]$ScopeLocked,
    [string[]]$AllowedSurface,
    [string[]]$ForbiddenSurface,
    [string[]]$ValidationCommands,
    [object]$ContextManifest
  )

  $contextEntries = @($ContextManifest.entries)
  $contextLines = if ((Get-CollectionCount -Value $contextEntries) -gt 0) {
    ($contextEntries | ForEach-Object {
      if ($_.exists -and $_.relativePath) {
        "- $($_.relativePath)"
      } elseif ($_.resolved) {
        "- $($_.requested) (missing at $($_.resolved))"
      } else {
        "- $($_.requested)"
      }
    }) -join "`n"
  } else {
    "- None provided"
  }

  $allowedLines = if ((Get-CollectionCount -Value $AllowedSurface) -gt 0) { ($AllowedSurface | ForEach-Object { "- $_" }) -join "`n" } else { "- Infer narrowly from the task prompt" }
  $forbiddenLines = if ((Get-CollectionCount -Value $ForbiddenSurface) -gt 0) { ($ForbiddenSurface | ForEach-Object { "- $_" }) -join "`n" } else { "- No explicit forbidden surface declared yet" }
  $validationLines = if ((Get-CollectionCount -Value $ValidationCommands) -gt 0) { ($ValidationCommands | ForEach-Object { "- $_" }) -join "`n" } else { "- Not specified yet" }
  $lockedText = if ($ScopeLocked) { "Locked" } else { "Not explicitly locked yet" }

  return @"
# Duel Brief

## Goal
$TaskPrompt

## Deliverable
- Shared duel ledger and normalized brief for Codex and Gemini candidates.

## Locked Scope
- $lockedText

## Allowed Change Surface
$allowedLines

## Forbidden Change Surface
$forbiddenLines

## Relevant Files
$contextLines

## Validation Commands
$validationLines

## Project Root
- $ProjectRoot

## Risks
- Validation commands may still need to be supplied or auto-discovered later.
- Candidate generation and machine judging depend on later duel phases.
"@
}

function Get-PacketBudget {
  param(
    [string]$TaskPrompt,
    [object]$ContextManifest,
    [string[]]$ValidationCommands
  )

  $contextEntries = @($ContextManifest.entries | Where-Object { $_.exists })
  $fileCount = Get-CollectionCount -Value $contextEntries
  $totalContextChars = 0
  foreach ($entry in $contextEntries) {
    $totalContextChars += [int]$entry.charCount
  }
  $largestFileChars = if ($fileCount -gt 0) {
    [int](($contextEntries | Measure-Object -Property charCount -Maximum).Maximum)
  } else {
    0
  }
  $promptChars = if ($TaskPrompt) { $TaskPrompt.Length } else { 0 }
  $validationCommandCount = @($ValidationCommands).Count
  $packetChars = $promptChars + $totalContextChars + ($validationCommandCount * 120)

  $decision = "allow"
  $class = "small"

  if ($packetChars -gt 55000 -or $fileCount -gt 8 -or $largestFileChars -gt 20000) {
    $decision = "block-until-narrowed"
    $class = "oversized"
  } elseif ($packetChars -gt 30000 -or $fileCount -gt 5) {
    $decision = "split-stage"
    $class = "large"
  } elseif ($packetChars -gt 12000 -or $fileCount -gt 3 -or $promptChars -gt 1500) {
    $decision = "compact-first"
    $class = "medium"
  }

  return [PSCustomObject]@{
    classification = $class
    decision = $decision
    contextFileCount = $fileCount
    totalContextChars = $totalContextChars
    largestFileChars = $largestFileChars
    promptChars = $promptChars
    packetChars = $packetChars
    validationCommandCount = $validationCommandCount
  }
}

function Get-TaskShape {
  param(
    [string]$TaskPrompt,
    [object]$ContextManifest
  )

  $normalizedPrompt = if ($TaskPrompt) { $TaskPrompt.ToLowerInvariant() } else { "" }
  $relativePaths = @($ContextManifest.entries | ForEach-Object { [string]($_.relativePath) })
  $hasShell = @($relativePaths | Where-Object { $_ -match '(shell|layout|token)' }).Count -gt 0
  $hasRoute = @($relativePaths | Where-Object { $_ -match '(route|routes|page|screen)' }).Count -gt 0
  $hasDocs = @($relativePaths | Where-Object { $_ -match '\.(md|txt|docx?)$' }).Count -gt 0
  $hasRefactorLanguage = $normalizedPrompt -match 'refactor|preserve behavior|behavior-preserving'
  $isRedesign = $normalizedPrompt -match 'redesign|replace the design|replace the visual|visual design'
  $isDocsOnly = $normalizedPrompt -match 'documentation|docs|guide|readme'

  $classification = "route-scoped-implementation"
  $reason = "Defaulted to route-scoped implementation because no broader task shape was detected."

  if ($isDocsOnly -and -not $hasShell -and -not $hasRoute) {
    $classification = "docs-only"
    $reason = "Prompt is documentation-focused and the supplied context does not indicate UI or route work."
  } elseif ($hasRefactorLanguage) {
    $classification = "behavior-preserving-refactor"
    $reason = "Prompt emphasizes refactoring while preserving behavior."
  } elseif ($isRedesign -and $hasShell) {
    $classification = "shared-shell-redesign"
    $reason = "Prompt requests a redesign and the supplied files center on shell/layout surfaces."
  } elseif ($isRedesign -and $hasRoute) {
    $classification = "broad-ui-redesign"
    $reason = "Prompt requests a redesign with route-level context, so the task should be narrowed before implementation."
  } elseif ($hasRoute) {
    $classification = "route-scoped-implementation"
    $reason = "Route/page surfaces are present, so route-scoped implementation is the safest starting point."
  } elseif ($hasShell) {
    $classification = "primitives-and-layout"
    $reason = "Context is concentrated in layout or shared primitive files."
  }

  return [PSCustomObject]@{
    classification = $classification
    reason = $reason
    detected = [PSCustomObject]@{
      hasShell = $hasShell
      hasRoute = $hasRoute
      hasDocs = $hasDocs
      redesign = $isRedesign
      docsOnly = $isDocsOnly
      behaviorPreserving = $hasRefactorLanguage
    }
  }
}

function Select-StageContextEntries {
  param(
    [object]$ContextManifest,
    [object]$TaskShape,
    [int]$MaxCount = 3
  )

  $entries = @($ContextManifest.entries | Where-Object { $_.exists })
  if ((Get-CollectionCount -Value $entries) -eq 0) {
    return @()
  }

  $classification = [string]($TaskShape.classification)
  $ranked = foreach ($entry in $entries) {
    $relativePath = [string]$entry.relativePath
    $score = 0

    if ($classification -eq "shared-shell-redesign") {
      if ($relativePath -match 'shell|layout|token') { $score += 100 }
      if ($relativePath -match 'route|page|screen') { $score += 40 }
    } elseif ($classification -eq "route-scoped-implementation" -or $classification -eq "broad-ui-redesign") {
      if ($relativePath -match 'route|page|screen') { $score += 100 }
      if ($relativePath -match 'shell|layout|token') { $score += 40 }
    } elseif ($classification -eq "docs-only") {
      if ($relativePath -match '\.(md|txt|docx?)$') { $score += 100 }
    } else {
      if ($relativePath -match 'contract|schema|test') { $score += 80 }
    }

    $score += [Math]::Min([int]$entry.charCount, 5000) / 250

    [PSCustomObject]@{
      entry = $entry
      score = [int]$score
    }
  }

  return @($ranked | Sort-Object -Property @{ Expression = "score"; Descending = $true }, @{ Expression = { $_.entry.relativePath } } | Select-Object -First $MaxCount | ForEach-Object { $_.entry })
}

function Get-RerouteDecision {
  param(
    [object]$PacketBudget,
    [object]$TaskShape,
    [object[]]$SelectedEntries
  )

  $required = $PacketBudget.decision -ne "allow"
  $targetStage = if ($required) { "candidate-plan" } else { "candidate-package" }
  $reason = if ($required) {
    "Packet budget decision '$($PacketBudget.decision)' requires staged narrowing before implementation."
  } else {
    "Packet is within the direct candidate-generation budget."
  }

  $narrowedShape = [string]$TaskShape.classification
  if ($required -and $TaskShape.classification -eq "broad-ui-redesign") {
    if (@($SelectedEntries | Where-Object { $_.relativePath -match 'shell|layout|token' }).Count -gt 0) {
      $narrowedShape = "shared-shell-redesign"
    } elseif (@($SelectedEntries | Where-Object { $_.relativePath -match 'route|page|screen' }).Count -gt 0) {
      $narrowedShape = "route-scoped-implementation"
    }
  }

  $selectedFileList = @(@($SelectedEntries) | Where-Object { $null -ne $_ } | ForEach-Object { [string]($_.relativePath) })

  return [PSCustomObject]@{
    required = $required
    reason = $reason
    targetStage = $targetStage
    narrowedShape = $narrowedShape
    selectedFiles = $selectedFileList
  }
}

function Build-CompactBriefMarkdown {
  param(
    [string]$TaskPrompt,
    [object]$TaskShape,
    [object]$RerouteDecision,
    [string[]]$AllowedSurface,
    [string[]]$ForbiddenSurface,
    [string[]]$ValidationCommands
  )

  $allowedLines = if (@($AllowedSurface).Count -gt 0) { ($AllowedSurface | ForEach-Object { "- $_" }) -join "`n" } else { "- Keep the implementation narrowly aligned with the selected files." }
  $forbiddenLines = if (@($ForbiddenSurface).Count -gt 0) { ($ForbiddenSurface | ForEach-Object { "- $_" }) -join "`n" } else { "- No explicit forbidden surface supplied." }
  $selectedLines = if (@($RerouteDecision.selectedFiles).Count -gt 0) { ($RerouteDecision.selectedFiles | ForEach-Object { "- $_" }) -join "`n" } else { "- No files selected yet." }
  $validationLines = if (@($ValidationCommands).Count -gt 0) { ($ValidationCommands | ForEach-Object { "- $_" }) -join "`n" } else { "- Not specified." }

  return @"
# Compact Brief

## Goal
$TaskPrompt

## Task Shape
- $($TaskShape.classification)
- $($TaskShape.reason)

## Narrowed Target
- Stage: $($RerouteDecision.targetStage)
- Narrowed shape: $($RerouteDecision.narrowedShape)

## Selected Files
$selectedLines

## Allowed Surface
$allowedLines

## Forbidden Surface
$forbiddenLines

## Validation
$validationLines
"@
}

function Build-ScopeAuditMarkdown {
  param(
    [string]$ProjectRoot,
    [object]$TaskShape,
    [object]$PacketBudget,
    [object]$RerouteDecision,
    [string[]]$AllowedSurface,
    [string[]]$ForbiddenSurface
  )

  $allowedLines = if (@($AllowedSurface).Count -gt 0) { ($AllowedSurface | ForEach-Object { "- $_" }) -join "`n" } else { "- Narrowly infer from the selected files and task shape." }
  $forbiddenLines = if (@($ForbiddenSurface).Count -gt 0) { ($ForbiddenSurface | ForEach-Object { "- $_" }) -join "`n" } else { "- No explicit forbidden surface supplied." }
  $selectedLines = if (@($RerouteDecision.selectedFiles).Count -gt 0) { ($RerouteDecision.selectedFiles | ForEach-Object { "- $_" }) -join "`n" } else { "- None selected yet." }

  return @"
# Scope Audit

## Project Root
- $ProjectRoot

## Task Shape
- $($TaskShape.classification)
- $($TaskShape.reason)

## Packet Budget
- decision: $($PacketBudget.decision)
- classification: $($PacketBudget.classification)
- total context chars: $($PacketBudget.totalContextChars)
- prompt chars: $($PacketBudget.promptChars)
- packet chars: $($PacketBudget.packetChars)

## Selected Files
$selectedLines

## Allowed Change Surface
$allowedLines

## Forbidden Change Surface
$forbiddenLines

## Next Stage
- $($RerouteDecision.targetStage)
"@
}

function Build-ContextSummary {
  param(
    [object]$ContextManifest,
    [object[]]$SelectedEntries
  )

  $entries = @($ContextManifest.entries | Where-Object { $_.exists })
  $totalContextChars = 0
  foreach ($entry in $entries) {
    $totalContextChars += [int]$entry.charCount
  }

  return [PSCustomObject]@{
    totalExistingFiles = $entries.Count
    totalContextChars = $totalContextChars
    selectedFiles = @(@($SelectedEntries) | Where-Object { $null -ne $_ } | ForEach-Object {
      [PSCustomObject]@{
        relativePath = [string]($_.relativePath)
        charCount = [int]$_.charCount
        lineCount = [int]$_.lineCount
      }
    })
    topFilesBySize = @($entries | Sort-Object -Property charCount -Descending | Select-Object -First 5 | ForEach-Object {
      [PSCustomObject]@{
      relativePath = [string]($_.relativePath)
        charCount = [int]$_.charCount
        lineCount = [int]$_.lineCount
      }
    })
  }
}

function Write-PacketArtifacts {
  param(
    [string]$ArtifactRootPath,
    [string]$TaskPrompt,
    [object]$ConstraintsState,
    [object]$ContextManifest,
    [object]$ContextSummary,
    [object]$PacketBudget,
    [object]$TaskShape,
    [object]$RerouteDecision
  )

  $packetRoot = Join-Path $ArtifactRootPath "packet"
  $relevantFilesRoot = Join-Path $packetRoot "relevant-files"
  Ensure-Directory -Path $packetRoot
  Ensure-Directory -Path $relevantFilesRoot

  $constraintLines = @(
    "# Constraints",
    "",
    "## Locked Scope",
    "- $([bool]$ConstraintsState.lockedScope)",
    "",
    "## Allowed Change Surface"
  )
  if (@($ConstraintsState.allowedChangeSurface).Count -gt 0) {
    $constraintLines += @($ConstraintsState.allowedChangeSurface | ForEach-Object { "- $_" })
  } else {
    $constraintLines += "- Not explicitly constrained."
  }
  $constraintLines += ""
  $constraintLines += "## Forbidden Change Surface"
  if (@($ConstraintsState.forbiddenChangeSurface).Count -gt 0) {
    $constraintLines += @($ConstraintsState.forbiddenChangeSurface | ForEach-Object { "- $_" })
  } else {
    $constraintLines += "- None supplied."
  }
  $constraintLines += ""
  $constraintLines += "## Validation Commands"
  if (@($ConstraintsState.validationCommands).Count -gt 0) {
    $constraintLines += @($ConstraintsState.validationCommands | ForEach-Object { "- $_" })
  } else {
    $constraintLines += "- Not specified."
  }

  Write-Utf8File -Path (Join-Path $packetRoot "objective.md") -Content @"
# Objective

$TaskPrompt
"@
  Write-Utf8File -Path (Join-Path $packetRoot "constraints.md") -Content ($constraintLines -join "`n")
  Save-JsonFile -Path (Join-Path $packetRoot "scope.json") -Value ([PSCustomObject]@{
    taskShape = $TaskShape
    packetBudget = $PacketBudget
    reroute = $RerouteDecision
  })
  Save-JsonFile -Path (Join-Path $packetRoot "context-manifest.json") -Value $ContextManifest
  Save-JsonFile -Path (Join-Path $packetRoot "context-summary.json") -Value $ContextSummary
  Write-Utf8File -Path (Join-Path $packetRoot "output-contract.md") -Content @"
# Output Contract

- Current stage: $($RerouteDecision.targetStage)
- Narrowed shape: $($RerouteDecision.narrowedShape)
- Preserve locked scope and do not widen product scope.
- If code is requested later, only touch the selected files unless the ledger explicitly expands scope.
"@
  Write-Utf8File -Path (Join-Path $packetRoot "stage.md") -Content @"
# Stage

- target stage: $($RerouteDecision.targetStage)
- reroute required: $($RerouteDecision.required)
"@

  $index = 1
  foreach ($entry in @($ContextSummary.selectedFiles)) {
    $sourcePath = Resolve-AbsolutePath -BaseDirectory $ContextManifest.projectRoot -Candidate ([string]($entry.relativePath))
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
      continue
    }

    $content = Get-Content -LiteralPath $sourcePath -Raw
    $packetFileContent = @(
      "# File"
      ([string]($entry.relativePath))
      ""
      '```text'
      $content
      '```'
    ) -join "`n"
    Write-Utf8File -Path (Join-Path $relevantFilesRoot ("{0:D2}-{1}.txt" -f $index, (Get-SlugValue -InputText ([string]($entry.relativePath))))) -Content $packetFileContent
    $index += 1
  }
}

function Test-GitRepository {
  param([string]$Path)

  $result = Invoke-GitCommand -Arguments @("-C", $Path, "rev-parse", "--show-toplevel") -AllowFailure -DiscardStderr
  return ($result.ExitCode -eq 0)
}

function Get-GitRepositoryRoot {
  param([string]$Path)

  $result = Invoke-GitCommand -Arguments @("-C", $Path, "rev-parse", "--show-toplevel") -AllowFailure -DiscardStderr
  if ($result.ExitCode -ne 0) {
    return $null
  }

  return (($result.Output | Out-String).Trim())
}

function Ensure-PlaceholderArtifacts {
  param(
    [string]$ArtifactRootPath,
    [string]$CandidateName
  )

  $candidateArtifactRoot = Join-Path $ArtifactRootPath $CandidateName
  Ensure-Directory -Path $candidateArtifactRoot

  if (-not (Test-Path -LiteralPath (Join-Path $candidateArtifactRoot "plan.md"))) {
    Write-Utf8File -Path (Join-Path $candidateArtifactRoot "plan.md") -Content @"
# $CandidateName Candidate Plan

Pending implementation.
"@
  }

  if (-not (Test-Path -LiteralPath (Join-Path $candidateArtifactRoot "summary.md"))) {
    Write-Utf8File -Path (Join-Path $candidateArtifactRoot "summary.md") -Content @"
# $CandidateName Candidate Summary

Pending implementation.
"@
  }

  if (-not (Test-Path -LiteralPath (Join-Path $candidateArtifactRoot "diff.patch"))) {
    Write-Utf8File -Path (Join-Path $candidateArtifactRoot "diff.patch") -Content ""
  }
}

function Ensure-NonGitWorkspace {
  param(
    [string]$SourceRoot,
    [string]$WorkspaceRoot
  )

  Ensure-Directory -Path $WorkspaceRoot

  $sourceItems = Get-ChildItem -LiteralPath $SourceRoot -Force
  foreach ($item in $sourceItems) {
    if ($item.Name -eq ".codex") {
      continue
    }

    $destination = Join-Path $WorkspaceRoot $item.Name
    if (-not (Test-Path -LiteralPath $destination)) {
      Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
    }
  }
}

function Ensure-GitWorktree {
  param(
    [string]$RepositoryRoot,
    [string]$WorkspaceRoot,
    [string]$BranchName
  )

  if ((Test-Path -LiteralPath $WorkspaceRoot -PathType Container) -and (Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".git"))) {
    return
  }

  $branchCheck = Invoke-GitCommand -Arguments @("-C", $RepositoryRoot, "show-ref", "--verify", "--quiet", "refs/heads/$BranchName") -AllowFailure -DiscardStderr
  $branchExists = ($branchCheck.ExitCode -eq 0)

  if ($branchExists) {
    $worktreeAdd = Invoke-GitCommand -Arguments @("-C", $RepositoryRoot, "worktree", "add", "--force", $WorkspaceRoot, $BranchName) -AllowFailure
  } else {
    $worktreeAdd = Invoke-GitCommand -Arguments @("-C", $RepositoryRoot, "worktree", "add", "--force", "-b", $BranchName, $WorkspaceRoot, "HEAD") -AllowFailure
  }

  if ($worktreeAdd.ExitCode -ne 0) {
    throw "Failed to create git worktree at $WorkspaceRoot"
  }
}

function Get-ProjectFiles {
  param([string]$RootPath)

  if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    return @()
  }

  return Get-ChildItem -LiteralPath $RootPath -Recurse -File -Force |
    Where-Object {
      $relativePath = Get-RelativePathSafe -BasePath $RootPath -TargetPath $_.FullName
      $relativePath -notmatch '^(?:\.codex|\.git)(?:\\|/|$)'
    }
}

function Get-NonGitChangedFiles {
  param(
    [string]$BaselineRoot,
    [string]$WorkspaceRoot
  )

  $baselineMap = @{}
  foreach ($file in (Get-ProjectFiles -RootPath $BaselineRoot)) {
    $relative = Get-RelativePathSafe -BasePath $BaselineRoot -TargetPath $file.FullName
    $baselineMap[$relative] = $file.FullName
  }

  $workspaceMap = @{}
  foreach ($file in (Get-ProjectFiles -RootPath $WorkspaceRoot)) {
    $relative = Get-RelativePathSafe -BasePath $WorkspaceRoot -TargetPath $file.FullName
    $workspaceMap[$relative] = $file.FullName
  }

  $changed = New-Object System.Collections.Generic.List[string]
  foreach ($relative in (($baselineMap.Keys + $workspaceMap.Keys) | Sort-Object -Unique)) {
    $baselineExists = $baselineMap.ContainsKey($relative)
    $workspaceExists = $workspaceMap.ContainsKey($relative)

    if (-not $baselineExists -or -not $workspaceExists) {
      $changed.Add($relative)
      continue
    }

    $baselineHash = (Get-FileHash -LiteralPath $baselineMap[$relative] -Algorithm SHA256).Hash
    $workspaceHash = (Get-FileHash -LiteralPath $workspaceMap[$relative] -Algorithm SHA256).Hash
    if ($baselineHash -ne $workspaceHash) {
      $changed.Add($relative)
    }
  }

  return @($changed)
}

function Get-LineDeltaCount {
  param(
    [string]$BaselinePath,
    [string]$WorkspacePath
  )

  $baselineLines = @()
  $workspaceLines = @()

  if (Test-Path -LiteralPath $BaselinePath -PathType Leaf) {
    $baselineLines = @(Get-Content -LiteralPath $BaselinePath)
  }
  if (Test-Path -LiteralPath $WorkspacePath -PathType Leaf) {
    $workspaceLines = @(Get-Content -LiteralPath $WorkspacePath)
  }

  return [Math]::Abs($workspaceLines.Count - $baselineLines.Count) + [Math]::Min($workspaceLines.Count, $baselineLines.Count)
}

function Get-NonGitPatchText {
  param(
    [string]$BaselineRoot,
    [string]$WorkspaceRoot,
    [string[]]$ChangedFiles
  )

  if ((Get-CollectionCount -Value $ChangedFiles) -eq 0) {
    return ""
  }

  $builder = [System.Text.StringBuilder]::new()
  [void]$builder.AppendLine("# Synthetic non-git diff")

  foreach ($relative in $ChangedFiles) {
    $baselinePath = Join-Path $BaselineRoot $relative
    $workspacePath = Join-Path $WorkspaceRoot $relative
    [void]$builder.AppendLine("## $relative")
    [void]$builder.AppendLine("- baseline: $([bool](Test-Path -LiteralPath $baselinePath -PathType Leaf))")
    [void]$builder.AppendLine("- workspace: $([bool](Test-Path -LiteralPath $workspacePath -PathType Leaf))")
    [void]$builder.AppendLine("")
  }

  return $builder.ToString().TrimEnd()
}

function Get-CandidateDiffState {
  param(
    [string]$ProjectRoot,
    [string]$WorkspaceRoot,
    [string]$Mode
  )

  if ($Mode -eq "git-worktree") {
    $changedFilesResult = Invoke-GitCommand -Arguments @("-C", $WorkspaceRoot, "diff", "--name-only", "--relative", "HEAD") -AllowFailure
    if ($changedFilesResult.ExitCode -ne 0) {
      throw "Failed to list changed files for workspace $WorkspaceRoot"
    }
    $changedFiles = @($changedFilesResult.Output)

    $patchResult = Invoke-GitCommand -Arguments @("-C", $WorkspaceRoot, "diff", "--binary", "--no-color", "HEAD") -AllowFailure
    if ($patchResult.ExitCode -gt 1) {
      throw "Failed to compute git diff for workspace $WorkspaceRoot"
    }
    $patchText = ($patchResult.Output | Out-String).TrimEnd()

    $diffLineCount = 0
    if (-not [string]::IsNullOrWhiteSpace($patchText)) {
      $diffLineCount = @((($patchText -split "\r?\n") | Where-Object { $_ -match '^[\+\-]' -and $_ -notmatch '^\+\+\+|^---' })).Count
    }

    return [PSCustomObject]@{
      changedFiles = @($changedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      patchText = $patchText
      diffLineCount = $diffLineCount
    }
  }

  $changedFiles = Get-NonGitChangedFiles -BaselineRoot $ProjectRoot -WorkspaceRoot $WorkspaceRoot
  $patchText = Get-NonGitPatchText -BaselineRoot $ProjectRoot -WorkspaceRoot $WorkspaceRoot -ChangedFiles $changedFiles
  $diffLineCount = 0
  foreach ($relative in $changedFiles) {
    $diffLineCount += Get-LineDeltaCount -BaselinePath (Join-Path $ProjectRoot $relative) -WorkspacePath (Join-Path $WorkspaceRoot $relative)
  }

  return [PSCustomObject]@{
    changedFiles = $changedFiles
    patchText = $patchText
    diffLineCount = $diffLineCount
  }
}

function Test-RelativePathSafe {
  param([string]$RelativePath)

  if ([string]::IsNullOrWhiteSpace($RelativePath)) {
    return $false
  }

  if ([System.IO.Path]::IsPathRooted($RelativePath)) {
    return $false
  }

  return -not (($RelativePath -split '[\\/]') -contains "..")
}

function Apply-PackageToWorkspace {
  param(
    [string]$WorkspaceRoot,
    [object]$Package
  )

  foreach ($file in $Package.files) {
    $relativePath = [string]$file.path
    if (-not (Test-RelativePathSafe -RelativePath $relativePath)) {
      throw "Refusing to write unsafe relative path from Gemini package: $relativePath"
    }

    $targetPath = Join-Path $WorkspaceRoot $relativePath
    Write-Utf8File -Path $targetPath -Content ([string]$file.content)
  }
}

function Update-CandidateArtifacts {
  param(
    [string]$ArtifactRootPath,
    [string]$CandidateName,
    [string]$ProjectRoot,
    [string]$WorkspaceRoot,
    [string]$WorkspaceMode,
    [string]$PlanMarkdown,
    [string]$SummaryMarkdown
  )

  $candidateArtifactRoot = Join-Path $ArtifactRootPath $CandidateName
  Ensure-Directory -Path $candidateArtifactRoot

  if (-not [string]::IsNullOrWhiteSpace($PlanMarkdown)) {
    Write-Utf8File -Path (Join-Path $candidateArtifactRoot "plan.md") -Content $PlanMarkdown
  }
  if (-not [string]::IsNullOrWhiteSpace($SummaryMarkdown)) {
    Write-Utf8File -Path (Join-Path $candidateArtifactRoot "summary.md") -Content $SummaryMarkdown
  }

  $diffState = Get-CandidateDiffState -ProjectRoot $ProjectRoot -WorkspaceRoot $WorkspaceRoot -Mode $WorkspaceMode
  Write-Utf8File -Path (Join-Path $candidateArtifactRoot "diff.patch") -Content $diffState.patchText

  $candidateMetadata = [PSCustomObject]@{
    name = $CandidateName
    workspaceRoot = $WorkspaceRoot
    workspaceMode = $WorkspaceMode
    changedFiles = @($diffState.changedFiles)
    changedFileCount = @($diffState.changedFiles).Count
    diffLineCount = $diffState.diffLineCount
    updatedAt = (Get-Date).ToString("o")
  }
  Save-JsonFile -Path (Join-Path $candidateArtifactRoot "candidate.json") -Value $candidateMetadata
}

function Extract-BetweenMarkers {
  param(
    [string]$Text,
    [string]$StartMarker,
    [string]$EndMarker
  )

  $start = $Text.IndexOf($StartMarker, [System.StringComparison]::Ordinal)
  if ($start -lt 0) {
    throw "Missing start marker '$StartMarker' in Gemini candidate output."
  }

  $start += $StartMarker.Length
  $end = $Text.IndexOf($EndMarker, $start, [System.StringComparison]::Ordinal)
  if ($end -lt 0) {
    throw "Missing end marker '$EndMarker' in Gemini candidate output."
  }

  return $Text.Substring($start, $end - $start).Trim()
}

function Get-NextGeminiAttemptNumber {
  param([string]$ArtifactRootPath)

  $attemptsPath = Join-Path $ArtifactRootPath "gemini\attempts.json"
  $existing = Load-JsonFile -Path $attemptsPath
  if ($null -eq $existing) {
    return 1
  }

  return @($existing).Count + 1
}

function Write-GeminiAttemptArtifacts {
  param(
    [string]$ArtifactRootPath,
    [int]$AttemptNumber,
    [string]$RawText,
    [string]$NormalizedText,
    [object]$Package,
    [object]$Metadata
  )

  $geminiRoot = Join-Path $ArtifactRootPath "gemini"
  Ensure-Directory -Path $geminiRoot

  $safeRawText = if ($null -ne $RawText) { [string]$RawText } else { "" }
  $safeNormalizedText = if ($null -ne $NormalizedText) { [string]$NormalizedText } else { "" }

  Write-Utf8File -Path (Join-Path $geminiRoot ("attempt-{0}-raw.txt" -f $AttemptNumber)) -Content $safeRawText
  Write-Utf8File -Path (Join-Path $geminiRoot ("attempt-{0}-normalized.txt" -f $AttemptNumber)) -Content $safeNormalizedText
  if ($null -ne $Package) {
    Save-JsonFile -Path (Join-Path $geminiRoot ("attempt-{0}-package.json" -f $AttemptNumber)) -Value $Package
  }
  Save-JsonFile -Path (Join-Path $geminiRoot ("attempt-{0}-metadata.json" -f $AttemptNumber)) -Value $Metadata
}

function Invoke-GeminiCandidatePlan {
  param(
    [string]$ArtifactRootPath,
    [string]$TaskPrompt,
    [object]$TaskShape,
    [object]$RerouteDecision
  )

  $selectedLines = if (@($RerouteDecision.selectedFiles).Count -gt 0) {
    ($RerouteDecision.selectedFiles | ForEach-Object { "- $_" }) -join "`n"
  } else {
    "- None selected yet"
  }

  $planMarkdown = @"
# Gemini Candidate Plan

## Stage
- $($RerouteDecision.targetStage)

## Task Shape
- $($TaskShape.classification)

## Goal
$TaskPrompt

## Selected Files
$selectedLines

## Constraints
- Preserve locked scope and functional behavior.
- Do not widen scope beyond the selected files without a reroute.
"@

  Write-Utf8File -Path (Join-Path $ArtifactRootPath "gemini\plan.md") -Content $planMarkdown
  return $planMarkdown
}

function Invoke-GeminiCandidatePackage {
  param(
    [string]$ProjectRoot,
    [string]$ArtifactRootPath,
    [string]$TaskPrompt,
    [string]$SelectedMode,
    [string]$SelectedDuration,
    [string]$SelectedModel,
    [string]$MockPackageFilePath,
    [object]$TaskShape,
    [object]$RerouteDecision,
    [int]$ResolvedTimeoutSeconds,
    [string[]]$EffectiveContextPath
  )

  $attemptLogPath = Join-Path $ArtifactRootPath "gemini\attempts.json"
  $attemptStartedAt = (Get-Date).ToString("o")
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $attemptNumber = Get-NextGeminiAttemptNumber -ArtifactRootPath $ArtifactRootPath
  $package = $null
  $rawText = ""
  $normalizedText = ""
  $transport = "prompt-file-via-gemini-consult"
  $promptPath = $null
  $resolvedMock = $null

  $candidatePlan = Invoke-GeminiCandidatePlan `
    -ArtifactRootPath $ArtifactRootPath `
    -TaskPrompt $TaskPrompt `
    -TaskShape $TaskShape `
    -RerouteDecision $RerouteDecision

  if ($MockPackageFilePath) {
    $resolvedMock = Resolve-AbsolutePath -BaseDirectory $ProjectRoot -Candidate $MockPackageFilePath
    if (-not (Test-Path -LiteralPath $resolvedMock -PathType Leaf)) {
      throw "Gemini mock package file not found: $resolvedMock"
    }
    $rawText = Get-Content -LiteralPath $resolvedMock -Raw
    $normalizedText = $rawText.Trim()
    $package = $rawText | ConvertFrom-Json
    $transport = "mock-package-file"
    $stopwatch.Stop()
    $metadata = [PSCustomObject]@{
      attemptNumber = $attemptNumber
      startedAt = $attemptStartedAt
      finishedAt = (Get-Date).ToString("o")
      durationMs = $stopwatch.ElapsedMilliseconds
      mode = $SelectedMode
      expectedDuration = $SelectedDuration
      requestedModel = $SelectedModel
      promptPath = $null
      transport = $transport
      mockPackageFile = $resolvedMock
      success = $true
      packageFileCount = @($package.files).Count
      packageExtractionSucceeded = $true
      rawBytes = [System.Text.Encoding]::UTF8.GetByteCount($rawText)
      normalizedBytes = [System.Text.Encoding]::UTF8.GetByteCount($normalizedText)
      truncated = $false
      rerouteTargetStage = [string]$RerouteDecision.targetStage
    }
    Write-GeminiAttemptArtifacts `
      -ArtifactRootPath $ArtifactRootPath `
      -AttemptNumber $attemptNumber `
      -RawText $rawText `
      -NormalizedText $normalizedText `
      -Package $package `
      -Metadata $metadata
    Append-JsonArrayFile -Path $attemptLogPath -Entry ([PSCustomObject]@{
      attemptNumber = $attemptNumber
      startedAt = $attemptStartedAt
      finishedAt = (Get-Date).ToString("o")
      durationMs = $stopwatch.ElapsedMilliseconds
      mode = $SelectedMode
      expectedDuration = $SelectedDuration
      requestedModel = $SelectedModel
      promptPath = $null
      transport = $transport
      mockPackageFile = $resolvedMock
      success = $true
      packageFileCount = @($package.files).Count
      packageExtractionSucceeded = $true
    })
    return $package
  }

  $launcherPath = Join-Path $PSScriptRoot "gemini-consult.ps1"
  if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
    throw "Gemini consult launcher not found at $launcherPath"
  }

  $briefPath = Join-Path $ArtifactRootPath "brief.md"
  $contextManifestPath = Join-Path $ArtifactRootPath "context-manifest.json"
  $compactBriefPath = Join-Path $ArtifactRootPath "compact-brief.md"
  $packetRoot = Join-Path $ArtifactRootPath "packet"
  $promptPath = Join-Path $ArtifactRootPath "gemini-candidate-prompt.md"

  $promptBody = @"
You are producing the Gemini candidate package for a Codex duel run.

Return exactly one JSON object between these markers:
DUEL_PACKAGE_JSON_START
{ ... }
DUEL_PACKAGE_JSON_END

Schema:
{
  "planMarkdown": "string",
  "summaryMarkdown": "string",
  "files": [
    { "path": "relative/path.ext", "content": "full file content" }
  ]
}

Rules:
- paths must be relative to the provided project root
- do not use absolute paths
- do not include markdown fences
- do not include comments outside the JSON markers
- preserve locked scope and forbidden surfaces
- only modify files that are necessary for the requested task

Task:
$TaskPrompt

Use these repo-grounded artifacts:
- brief: $briefPath
- context manifest: $contextManifestPath
- compact brief: $compactBriefPath
- packet root: $packetRoot
- narrowed stage: $($RerouteDecision.targetStage)
- narrowed shape: $($RerouteDecision.narrowedShape)
"@

  Write-Utf8File -Path $promptPath -Content $promptBody

  $arguments = @(
    "-Mode", $SelectedMode,
    "-ExpectedDuration", $SelectedDuration,
    "-TimeoutSeconds", $ResolvedTimeoutSeconds,
    "-WorkingDirectory", $ProjectRoot,
    "-PromptFile", $promptPath,
    "-ArtifactDirectory", (Join-Path $ArtifactRootPath "gemini"),
    "-ArtifactPrefix", ("attempt-{0}" -f $attemptNumber)
  )
  if (@($EffectiveContextPath).Count -gt 0) {
    $arguments += @("-ContextPath", @($EffectiveContextPath))
  }
  if ($SelectedModel) {
    $arguments += @("-Model", $SelectedModel)
  }

  try {
    $rawOutput = & $launcherPath @arguments
    $normalizedArtifactPath = Join-Path $ArtifactRootPath ("gemini\attempt-{0}-normalized.txt" -f $attemptNumber)
    $rawArtifactPath = Join-Path $ArtifactRootPath ("gemini\attempt-{0}-raw.txt" -f $attemptNumber)
    if (Test-Path -LiteralPath $normalizedArtifactPath -PathType Leaf) {
      $normalizedText = Get-Content -LiteralPath $normalizedArtifactPath -Raw
    } else {
      $normalizedText = ($rawOutput | Out-String).Trim()
    }
    if (Test-Path -LiteralPath $rawArtifactPath -PathType Leaf) {
      $rawText = Get-Content -LiteralPath $rawArtifactPath -Raw
    } else {
      $rawText = ($rawOutput | Out-String)
    }
    $jsonBody = Extract-BetweenMarkers -Text $normalizedText -StartMarker "DUEL_PACKAGE_JSON_START" -EndMarker "DUEL_PACKAGE_JSON_END"
    $package = $jsonBody | ConvertFrom-Json
    Save-JsonFile -Path (Join-Path $ArtifactRootPath ("gemini\attempt-{0}-package.json" -f $attemptNumber)) -Value $package
    $metadataPath = Join-Path $ArtifactRootPath ("gemini\attempt-{0}-metadata.json" -f $attemptNumber)
    $metadata = Load-JsonFile -Path $metadataPath
    if ($null -eq $metadata) {
      $metadata = [PSCustomObject]@{}
    }
    $metadata | Add-Member -NotePropertyName packageExtractionSucceeded -NotePropertyValue $true -Force
    $metadata | Add-Member -NotePropertyName rerouteTargetStage -NotePropertyValue ([string]$RerouteDecision.targetStage) -Force
    $metadata | Add-Member -NotePropertyName rawBytes -NotePropertyValue ([System.Text.Encoding]::UTF8.GetByteCount($rawText)) -Force
    $metadata | Add-Member -NotePropertyName normalizedBytes -NotePropertyValue ([System.Text.Encoding]::UTF8.GetByteCount($normalizedText)) -Force
    $metadata | Add-Member -NotePropertyName success -NotePropertyValue $true -Force
    Save-JsonFile -Path $metadataPath -Value $metadata
    return $package
  } finally {
    $stopwatch.Stop()
    $success = ($null -ne $package)
    Append-JsonArrayFile -Path $attemptLogPath -Entry ([PSCustomObject]@{
      attemptNumber = $attemptNumber
      startedAt = $attemptStartedAt
      finishedAt = (Get-Date).ToString("o")
      durationMs = $stopwatch.ElapsedMilliseconds
      mode = $SelectedMode
      expectedDuration = $SelectedDuration
      requestedModel = $SelectedModel
      promptPath = $promptPath
      transport = $transport
      mockPackageFile = $null
      success = $success
      packageFileCount = if ($success) { @($package.files).Count } else { 0 }
      packageExtractionSucceeded = $success
      candidatePlanBytes = [System.Text.Encoding]::UTF8.GetByteCount($candidatePlan)
    })
  }
}

function Build-CandidateSetup {
  param(
    [string]$ProjectRoot,
    [string]$ArtifactRootPath,
    [string]$ResolvedDuelIdentifier,
    [bool]$ShouldPrepareCandidates
  )

  $workspaceRoot = Join-Path $ArtifactRootPath "workspaces"
  Ensure-Directory -Path $workspaceRoot

  $codexWorkspaceRoot = Join-Path $workspaceRoot "codex"
  $geminiWorkspaceRoot = Join-Path $workspaceRoot "gemini"

  Ensure-PlaceholderArtifacts -ArtifactRootPath $ArtifactRootPath -CandidateName "codex"
  Ensure-PlaceholderArtifacts -ArtifactRootPath $ArtifactRootPath -CandidateName "gemini"

  if (-not $ShouldPrepareCandidates) {
    return [PSCustomObject]@{
      mode = "not-prepared"
      prepared = $false
      workspacesRoot = $workspaceRoot
      codex = [PSCustomObject]@{
        root = $codexWorkspaceRoot
        branch = $null
        strategy = "pending"
      }
      gemini = [PSCustomObject]@{
        root = $geminiWorkspaceRoot
        branch = $null
        strategy = "pending"
      }
    }
  }

  if (Test-GitRepository -Path $ProjectRoot) {
    $repositoryRoot = Get-GitRepositoryRoot -Path $ProjectRoot
    $branchBase = Get-SlugValue -InputText $ResolvedDuelIdentifier
    $codexBranch = "codex/duel-$branchBase-codex"
    $geminiBranch = "codex/duel-$branchBase-gemini"

    Ensure-GitWorktree -RepositoryRoot $repositoryRoot -WorkspaceRoot $codexWorkspaceRoot -BranchName $codexBranch
    Ensure-GitWorktree -RepositoryRoot $repositoryRoot -WorkspaceRoot $geminiWorkspaceRoot -BranchName $geminiBranch

    return [PSCustomObject]@{
      mode = "git-worktree"
      prepared = $true
      workspacesRoot = $workspaceRoot
      codex = [PSCustomObject]@{
        root = $codexWorkspaceRoot
        branch = $codexBranch
        strategy = "git-worktree"
      }
      gemini = [PSCustomObject]@{
        root = $geminiWorkspaceRoot
        branch = $geminiBranch
        strategy = "git-worktree"
      }
    }
  }

  Ensure-NonGitWorkspace -SourceRoot $ProjectRoot -WorkspaceRoot $codexWorkspaceRoot
  Ensure-NonGitWorkspace -SourceRoot $ProjectRoot -WorkspaceRoot $geminiWorkspaceRoot

  return [PSCustomObject]@{
    mode = "no-git-fallback"
    prepared = $true
    workspacesRoot = $workspaceRoot
    codex = [PSCustomObject]@{
      root = $codexWorkspaceRoot
      branch = $null
      strategy = "mirror-copy"
    }
    gemini = [PSCustomObject]@{
      root = $geminiWorkspaceRoot
      branch = $null
      strategy = "mirror-copy"
    }
  }
}

function Test-PathAgainstSurfaceRule {
  param(
    [string]$RelativePath,
    [string]$Rule
  )

  if ([string]::IsNullOrWhiteSpace($Rule)) {
    return $false
  }

  if ($Rule.Contains("*") -or $Rule.Contains("?")) {
    return $RelativePath -like $Rule
  }

  $trimmedRule = $Rule.TrimEnd([char[]]@('\','/'))
  return $RelativePath -eq $trimmedRule -or $RelativePath.StartsWith("$trimmedRule\\") -or $RelativePath.StartsWith("$trimmedRule/")
}

function Test-ValidationCommand {
  param(
    [string]$WorkspaceRoot,
    [string]$CommandText
  )

  $previousLocation = Get-Location
  $stdout = ""
  $stderr = ""
  $exitCode = 0

  try {
    Set-Location -LiteralPath $WorkspaceRoot
    $stdout = powershell -NoProfile -NonInteractive -Command $CommandText 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
  } catch {
    $stderr = $_.Exception.Message
    $exitCode = 1
  } finally {
    Set-Location -LiteralPath $previousLocation
  }

  return [PSCustomObject]@{
    command = $CommandText
    workspaceRoot = $WorkspaceRoot
    exitCode = $exitCode
    output = $stdout.Trim()
    error = $stderr
    passed = ($exitCode -eq 0)
  }
}

function Build-Scoreboard {
  param(
    [string]$ArtifactRootPath,
    [string]$ProjectRoot,
    [object]$ResumeState,
    [object]$ConstraintsState
  )

  $candidates = @()
  $validationCommandList = @($ConstraintsState.validationCommands)
  foreach ($candidateName in @("codex", "gemini")) {
    $workspaceRoot = [string]$ResumeState.candidateSetup.$candidateName.root
    $workspaceMode = [string]$ResumeState.candidateSetup.mode
    $candidateArtifactRoot = Join-Path $ArtifactRootPath $candidateName
    $candidateMetadata = Load-JsonFile -Path (Join-Path $candidateArtifactRoot "candidate.json")
    if ($null -eq $candidateMetadata) {
      throw "Candidate metadata missing for $candidateName. Record the candidate first."
    }

    $validationResults = @()
    foreach ($commandText in @($ConstraintsState.validationCommands)) {
      if ([string]::IsNullOrWhiteSpace([string]$commandText)) {
        continue
      }
      $validationResults += Test-ValidationCommand -WorkspaceRoot $workspaceRoot -CommandText ([string]$commandText)
    }

    $changedFiles = @($candidateMetadata.changedFiles)
    $forbiddenTouched = @()
    foreach ($relativePath in $changedFiles) {
      foreach ($rule in @($ConstraintsState.forbiddenChangeSurface)) {
        if (Test-PathAgainstSurfaceRule -RelativePath ([string]$relativePath) -Rule ([string]$rule)) {
          $forbiddenTouched += [string]$relativePath
          break
        }
      }
    }

    $failedValidationResults = @($validationResults | Where-Object { -not $_.passed })
    $allValidationPass = (@($validationResults).Count -eq 0) -or ($failedValidationResults.Count -eq 0)
    $lockedScopePass = (-not [bool]$ConstraintsState.lockedScope) -or (@($forbiddenTouched).Count -eq 0)
    $contractCheckPass = (@($forbiddenTouched).Count -eq 0)
    $gatePass = $allValidationPass -and $lockedScopePass -and $contractCheckPass

    $candidates += [PSCustomObject]@{
      name = $candidateName
      workspaceRoot = $workspaceRoot
      workspaceMode = $workspaceMode
      changedFiles = $changedFiles
      changedFileCount = [int]$candidateMetadata.changedFileCount
      diffLineCount = [int]$candidateMetadata.diffLineCount
      forbiddenTouched = @($forbiddenTouched)
      validationResults = @($validationResults)
      allValidationPass = $allValidationPass
      lockedScopePass = $lockedScopePass
      contractCheckPass = $contractCheckPass
      gatePass = $gatePass
    }
  }

  $codexCandidate = $candidates | Where-Object { $_.name -eq "codex" } | Select-Object -First 1
  $geminiCandidate = $candidates | Where-Object { $_.name -eq "gemini" } | Select-Object -First 1
  $blockedCommands = New-Object System.Collections.Generic.List[string]
  if ((Get-CollectionCount -Value $validationCommandList) -gt 0) {
    for ($index = 0; $index -lt (Get-CollectionCount -Value $validationCommandList); $index++) {
      $commandResults = @()
      foreach ($candidate in $candidates) {
        $candidateValidationResults = @($candidate.validationResults)
        if ($index -lt (Get-CollectionCount -Value $candidateValidationResults)) {
          $commandResults += $candidateValidationResults[$index]
        }
      }

      if ((Get-CollectionCount -Value $commandResults) -ne (Get-CollectionCount -Value $candidates)) {
        continue
      }

      $passedResults = @($commandResults | Where-Object { $_.passed })
      if ((Get-CollectionCount -Value $passedResults) -gt 0) {
        continue
      }

      $normalizedDiagnostics = @($commandResults | ForEach-Object {
        $diagnostic = ((@($_.output, $_.error) -join "`n").Trim())
        $workspaceRoot = [string]$_.workspaceRoot
        if (-not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
          $diagnostic = $diagnostic.Replace($workspaceRoot, "<workspace>")
        }
        $diagnostic
      } | Sort-Object -Unique)

      if ((Get-CollectionCount -Value $normalizedDiagnostics) -eq 1) {
        [void]$blockedCommands.Add([string]$validationCommandList[$index])
      }
    }
  }

  $environmentBlocked = ((Get-CollectionCount -Value $validationCommandList) -gt 0) -and ((Get-CollectionCount -Value $blockedCommands) -eq (Get-CollectionCount -Value $validationCommandList))
  foreach ($candidate in $candidates) {
    $candidate | Add-Member -NotePropertyName blockedEnvironment -NotePropertyValue $environmentBlocked -Force
  }

  $recommendedWinner = "merge-best-of-both"
  if ($environmentBlocked) {
    $recommendedWinner = "reject-both"
  } elseif ($codexCandidate.gatePass -and -not $geminiCandidate.gatePass) {
    $recommendedWinner = "codex"
  } elseif ($geminiCandidate.gatePass -and -not $codexCandidate.gatePass) {
    $recommendedWinner = "gemini"
  } elseif (-not $codexCandidate.gatePass -and -not $geminiCandidate.gatePass) {
    $recommendedWinner = "reject-both"
  } elseif ($codexCandidate.changedFileCount -lt $geminiCandidate.changedFileCount) {
    $recommendedWinner = "codex"
  } elseif ($geminiCandidate.changedFileCount -lt $codexCandidate.changedFileCount) {
    $recommendedWinner = "gemini"
  } elseif ($codexCandidate.diffLineCount -lt $geminiCandidate.diffLineCount) {
    $recommendedWinner = "codex"
  } elseif ($geminiCandidate.diffLineCount -lt $codexCandidate.diffLineCount) {
    $recommendedWinner = "gemini"
  }

  return [PSCustomObject]@{
    generatedAt = (Get-Date).ToString("o")
    projectRoot = $ProjectRoot
    environmentBlocked = $environmentBlocked
    reroutedRun = [bool]$ResumeState.reroute.required
    reroute = $ResumeState.reroute
    packetBudget = $ResumeState.packetBudget
    blockedCommands = @($blockedCommands)
    recommendedWinner = $recommendedWinner
    candidates = $candidates
  }
}

function Write-VerificationLog {
  param(
    [string]$LogPath,
    [object]$Scoreboard
  )

  $builder = [System.Text.StringBuilder]::new()
  [void]$builder.AppendLine("# Duel Verification Log")
  [void]$builder.AppendLine("")
  [void]$builder.AppendLine("- environment blocked: $($Scoreboard.environmentBlocked)")
  [void]$builder.AppendLine("- rerouted run: $($Scoreboard.reroutedRun)")
  [void]$builder.AppendLine("- packet budget decision: $($Scoreboard.packetBudget.decision)")
  if (@($Scoreboard.blockedCommands).Count -gt 0) {
    foreach ($command in @($Scoreboard.blockedCommands)) {
      [void]$builder.AppendLine("- blocked command: $command")
    }
  }
  [void]$builder.AppendLine("")

  foreach ($candidate in $Scoreboard.candidates) {
    [void]$builder.AppendLine("## $($candidate.name)")
    [void]$builder.AppendLine("- gate pass: $($candidate.gatePass)")
    [void]$builder.AppendLine("- blocked environment: $($candidate.blockedEnvironment)")
    [void]$builder.AppendLine("- changed files: $($candidate.changedFileCount)")
    [void]$builder.AppendLine("- diff lines: $($candidate.diffLineCount)")
    if (@($candidate.validationResults).Count -eq 0) {
      [void]$builder.AppendLine("- validation: not configured")
    } else {
      foreach ($result in $candidate.validationResults) {
        [void]$builder.AppendLine("- [$($result.exitCode)] $($result.command)")
      }
    }
    [void]$builder.AppendLine("")
  }

  Write-Utf8File -Path $LogPath -Content ($builder.ToString().TrimEnd())
}

function Ensure-MergeWorkspace {
  param(
    [string]$ArtifactRootPath,
    [object]$ResumeState
  )

  $mergeRoot = Join-Path $ArtifactRootPath "judge\merge-best-of-both"
  $workspaceRoot = Join-Path $mergeRoot "workspace"
  Ensure-Directory -Path $mergeRoot

  if (Test-Path -LiteralPath $workspaceRoot) {
    Remove-Item -LiteralPath $workspaceRoot -Recurse -Force
  }

  Copy-Item -LiteralPath ([string]$ResumeState.candidateSetup.codex.root) -Destination $workspaceRoot -Recurse -Force

  $codexCandidate = Load-JsonFile -Path (Join-Path $ArtifactRootPath "codex\candidate.json")
  $geminiCandidate = Load-JsonFile -Path (Join-Path $ArtifactRootPath "gemini\candidate.json")
  $codexFiles = @($codexCandidate.changedFiles)
  $geminiFiles = @($geminiCandidate.changedFiles)
  $overlap = @($codexFiles | Where-Object { $geminiFiles -contains $_ })

  $mergePlan = @"
# Merge Best Of Both

## Workspace
- $workspaceRoot

## Codex Changed Files
$(if ((Get-CollectionCount -Value $codexFiles) -gt 0) { ($codexFiles | ForEach-Object { "- $_" }) -join "`n" } else { "- None" })

## Gemini Changed Files
$(if ((Get-CollectionCount -Value $geminiFiles) -gt 0) { ($geminiFiles | ForEach-Object { "- $_" }) -join "`n" } else { "- None" })

## Overlap
$(if ((Get-CollectionCount -Value $overlap) -gt 0) { ($overlap | ForEach-Object { "- $_" }) -join "`n" } else { "- None" })
"@

  Write-Utf8File -Path (Join-Path $mergeRoot "merge-plan.md") -Content $mergePlan
  return $workspaceRoot
}

function Write-VerdictMarkdown {
  param(
    [string]$VerdictPath,
    [object]$Scoreboard,
    [string]$FinalChoice,
    [string]$MergeWorkspaceRoot
  )

  $details = $Scoreboard.candidates | ForEach-Object {
    @"
## $($_.name)
- gate pass: $($_.gatePass)
- changed files: $($_.changedFileCount)
- diff lines: $($_.diffLineCount)
- forbidden touched: $(if (@($_.forbiddenTouched).Count -gt 0) { (@($_.forbiddenTouched) -join ", ") } else { "none" })
"@
  }

  $mergeSection = if ($MergeWorkspaceRoot) {
    "## Merge Workspace`n- $MergeWorkspaceRoot"
  } else {
    ""
  }

  $content = @"
# Duel Verdict

## Recommendation
- $($Scoreboard.recommendedWinner)

## Environment Blocked
- $($Scoreboard.environmentBlocked)

## Rerouted Run
- $($Scoreboard.reroutedRun)
- packet budget decision: $($Scoreboard.packetBudget.decision)

## Final Choice
- $FinalChoice

$(($details -join "`n"))

$mergeSection
"@

  Write-Utf8File -Path $VerdictPath -Content $content.Trim()
}

$resolvedWorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
if (-not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) {
  throw "Working directory not found: $resolvedWorkingDirectory"
}

if ($AutoRun) {
  $PrepareCandidates = $true
  $RecordCodexCandidate = $true
  $GenerateGeminiCandidate = $true
  $Judge = $true
  $WriteVerdict = $true
}

$taskPrompt = Read-PromptText `
  -BaseDirectory $resolvedWorkingDirectory `
  -PromptFilePath $PromptFile `
  -PromptTextValue $PromptText `
  -PromptArgs $Prompt

if ([string]::IsNullOrWhiteSpace($taskPrompt)) {
  throw "Provide a duel prompt as arguments, pipeline input, prompt text, or prompt file."
}

$resolvedDuelId = if ([string]::IsNullOrWhiteSpace($DuelId)) {
  Get-DefaultDuelId -InputPrompt $taskPrompt
} else {
  Get-SlugValue -InputText $DuelId
}

$artifactRoot = Join-Path $resolvedWorkingDirectory ".codex\duels\$resolvedDuelId"
$judgeRoot = Join-Path $artifactRoot "judge"
Ensure-Directory -Path $artifactRoot
Ensure-Directory -Path $judgeRoot

$resolvedTimeoutSeconds = Get-ResolvedTimeoutSeconds -SelectedDuration $GeminiExpectedDuration -ExplicitTimeoutSeconds $TimeoutSeconds
$contextWasExplicit = $PSBoundParameters.ContainsKey("ContextPath")
$effectiveContextPath = if ($contextWasExplicit) { @($ContextPath) } else { Get-AutoContextPath -BaseDirectory $resolvedWorkingDirectory }

$contextManifest = Build-ContextManifest -BaseDirectory $resolvedWorkingDirectory -RequestedContextPath $effectiveContextPath
$constraints = [PSCustomObject]@{
  lockedScope = [bool]$LockedScope
  allowedChangeSurface = @($AllowedChangeSurface)
  forbiddenChangeSurface = @($ForbiddenChangeSurface)
  validationCommands = @($ValidationCommand)
  projectRoot = $resolvedWorkingDirectory
}
$briefMarkdown = Build-BriefMarkdown `
  -ProjectRoot $resolvedWorkingDirectory `
  -TaskPrompt $taskPrompt `
  -ScopeLocked ([bool]$LockedScope) `
  -AllowedSurface $AllowedChangeSurface `
  -ForbiddenSurface $ForbiddenChangeSurface `
  -ValidationCommands $ValidationCommand `
  -ContextManifest $contextManifest

$briefPath = Join-Path $artifactRoot "brief.md"
$contextManifestPath = Join-Path $artifactRoot "context-manifest.json"
$constraintsPath = Join-Path $artifactRoot "constraints.json"
$resumePath = Join-Path $artifactRoot "resume.json"
$scopeAuditPath = Join-Path $artifactRoot "scope-audit.md"
$taskShapePath = Join-Path $artifactRoot "task-shape.json"
$compactBriefPath = Join-Path $artifactRoot "compact-brief.md"
$rerouteLogPath = Join-Path $artifactRoot "reroute-log.json"

$packetBudget = Get-PacketBudget `
  -TaskPrompt $taskPrompt `
  -ContextManifest $contextManifest `
  -ValidationCommands $ValidationCommand

$taskShape = Get-TaskShape `
  -TaskPrompt $taskPrompt `
  -ContextManifest $contextManifest

$selectedStageEntries = Select-StageContextEntries `
  -ContextManifest $contextManifest `
  -TaskShape $taskShape

$rerouteDecision = Get-RerouteDecision `
  -PacketBudget $packetBudget `
  -TaskShape $taskShape `
  -SelectedEntries $selectedStageEntries

$contextSummary = Build-ContextSummary `
  -ContextManifest $contextManifest `
  -SelectedEntries $selectedStageEntries

$compactBriefMarkdown = Build-CompactBriefMarkdown `
  -TaskPrompt $taskPrompt `
  -TaskShape $taskShape `
  -RerouteDecision $rerouteDecision `
  -AllowedSurface $AllowedChangeSurface `
  -ForbiddenSurface $ForbiddenChangeSurface `
  -ValidationCommands $ValidationCommand

$scopeAuditMarkdown = Build-ScopeAuditMarkdown `
  -ProjectRoot $resolvedWorkingDirectory `
  -TaskShape $taskShape `
  -PacketBudget $packetBudget `
  -RerouteDecision $rerouteDecision `
  -AllowedSurface $AllowedChangeSurface `
  -ForbiddenSurface $ForbiddenChangeSurface

Write-Utf8File -Path $briefPath -Content $briefMarkdown
Save-JsonFile -Path $contextManifestPath -Value $contextManifest
Save-JsonFile -Path $constraintsPath -Value $constraints
Write-Utf8File -Path $scopeAuditPath -Content $scopeAuditMarkdown
Save-JsonFile -Path $taskShapePath -Value ([PSCustomObject]@{
  classification = $taskShape.classification
  reason = $taskShape.reason
  detected = $taskShape.detected
  reroute = $rerouteDecision
})
Write-Utf8File -Path $compactBriefPath -Content $compactBriefMarkdown
Append-JsonArrayFile -Path $rerouteLogPath -Entry ([PSCustomObject]@{
  timestamp = (Get-Date).ToString("o")
  reason = $rerouteDecision.reason
  required = [bool]$rerouteDecision.required
  targetStage = [string]$rerouteDecision.targetStage
  narrowedShape = [string]$rerouteDecision.narrowedShape
  selectedFiles = @($rerouteDecision.selectedFiles)
  packetDecision = [string]$packetBudget.decision
})
Write-PacketArtifacts `
  -ArtifactRootPath $artifactRoot `
  -TaskPrompt $taskPrompt `
  -ConstraintsState $constraints `
  -ContextManifest $contextManifest `
  -ContextSummary $contextSummary `
  -PacketBudget $packetBudget `
  -TaskShape $taskShape `
  -RerouteDecision $rerouteDecision

$existingResume = Load-JsonFile -Path $resumePath
$existingRunCount = if ($existingResume) { [int]$existingResume.runCount } else { 0 }
$createdAt = if ($existingResume -and $existingResume.createdAt) { [string]$existingResume.createdAt } else { (Get-Date).ToString("o") }

$candidateSetup = $null
if ($existingResume -and $existingResume.candidateSetup -and $existingResume.candidateSetup.prepared -and -not $PrepareCandidates) {
  $candidateSetup = $existingResume.candidateSetup
} else {
  if ($AutoRun) {
    Write-Output "Stage 1/5: Preparing candidates..."
  }
  try {
    $candidateSetup = Build-CandidateSetup `
      -ProjectRoot $resolvedWorkingDirectory `
      -ArtifactRootPath $artifactRoot `
      -ResolvedDuelIdentifier $resolvedDuelId `
      -ShouldPrepareCandidates ([bool]$PrepareCandidates)
  } catch {
    if ($AutoRun) {
      throw "AutoRun failed at stage 1/5 (Preparing candidates): $($_.Exception.Message)"
    }
    throw
  }
}

$resume = [PSCustomObject]@{
  duelId = $resolvedDuelId
  status = if ($DryRun) { "dry-run-ready" } else { "scaffolded" }
  mode = "duel"
  pipelineVersion = "v3"
  projectRoot = $resolvedWorkingDirectory
  artifactRoot = $artifactRoot
  prepareCandidates = [bool]$PrepareCandidates
  dryRun = [bool]$DryRun
  runCount = $existingRunCount + 1
  createdAt = $createdAt
  updatedAt = (Get-Date).ToString("o")
  packetBudget = $packetBudget
  taskShape = $taskShape
  reroute = $rerouteDecision
  contextSummary = $contextSummary
  candidateSetup = $candidateSetup
  phases = [PSCustomObject]@{
    preflight = "ready"
    scopeAudit = "ready"
    briefCompact = "ready"
    brief = "ready"
    candidatePlan = if ($rerouteDecision.required) { "ready" } else { "pending" }
    candidatePackage = "pending"
    codexCandidate = if ($candidateSetup.prepared) { "workspace-ready" } else { "pending" }
    geminiCandidate = if ($candidateSetup.prepared) { "workspace-ready" } else { "pending" }
    judge = "pending"
  }
}

if ($existingResume -and $existingResume.phases) {
  foreach ($property in $existingResume.phases.PSObject.Properties) {
    if ($resume.phases.PSObject.Properties.Name -contains $property.Name) {
      $resume.phases.$($property.Name) = $property.Value
    }
  }
}

Invoke-DuelStage -Enabled ([bool]$RecordCodexCandidate) -Index 2 -Total 5 -Name "Recording Codex candidate" -Action {
  if (-not $candidateSetup.prepared) {
    throw "Prepare candidates before recording the Codex candidate."
  }

  $summary = @"
# codex Candidate Summary

Recorded from the prepared Codex workspace.
"@

  Update-CandidateArtifacts `
    -ArtifactRootPath $artifactRoot `
    -CandidateName "codex" `
    -ProjectRoot $resolvedWorkingDirectory `
    -WorkspaceRoot ([string]$candidateSetup.codex.root) `
    -WorkspaceMode ([string]$candidateSetup.mode) `
    -PlanMarkdown $null `
    -SummaryMarkdown $summary

  $resume.phases.codexCandidate = "recorded"
}

Invoke-DuelStage -Enabled ([bool]$GenerateGeminiCandidate) -Index 3 -Total 5 -Name "Generating Gemini candidate" -Action {
  if (-not $candidateSetup.prepared) {
    throw "Prepare candidates before generating the Gemini candidate."
  }

  $package = Invoke-GeminiCandidatePackage `
    -ProjectRoot $resolvedWorkingDirectory `
    -ArtifactRootPath $artifactRoot `
    -TaskPrompt $taskPrompt `
    -SelectedMode $GeminiMode `
    -SelectedDuration $GeminiExpectedDuration `
    -SelectedModel $GeminiModel `
    -MockPackageFilePath $GeminiMockPackageFile `
    -TaskShape $taskShape `
    -RerouteDecision $rerouteDecision `
    -ResolvedTimeoutSeconds $resolvedTimeoutSeconds `
    -EffectiveContextPath $effectiveContextPath

  if ($null -eq $package.files -or (Get-CollectionCount -Value $package.files) -eq 0) {
    throw "Gemini candidate package did not include any files."
  }

  Apply-PackageToWorkspace -WorkspaceRoot ([string]$candidateSetup.gemini.root) -Package $package
  Update-CandidateArtifacts `
    -ArtifactRootPath $artifactRoot `
    -CandidateName "gemini" `
    -ProjectRoot $resolvedWorkingDirectory `
    -WorkspaceRoot ([string]$candidateSetup.gemini.root) `
    -WorkspaceMode ([string]$candidateSetup.mode) `
    -PlanMarkdown ([string]$package.planMarkdown) `
    -SummaryMarkdown ([string]$package.summaryMarkdown)

  $resume.phases.candidatePlan = "recorded"
  $resume.phases.candidatePackage = "recorded"
  $resume.phases.geminiCandidate = "recorded"
}

if ($RecordGeminiCandidate -and -not $GenerateGeminiCandidate) {
  if (-not $candidateSetup.prepared) {
    throw "Prepare candidates before recording the Gemini candidate."
  }

  $summary = @"
# gemini Candidate Summary

Recorded from the prepared Gemini workspace.
"@

  Update-CandidateArtifacts `
    -ArtifactRootPath $artifactRoot `
    -CandidateName "gemini" `
    -ProjectRoot $resolvedWorkingDirectory `
    -WorkspaceRoot ([string]$candidateSetup.gemini.root) `
    -WorkspaceMode ([string]$candidateSetup.mode) `
    -PlanMarkdown $null `
    -SummaryMarkdown $summary

  $resume.phases.geminiCandidate = "recorded"
}

$scoreboard = $null
if ($Judge -or $WriteVerdict -or $PrepareMergeWorkspace) {
  $scoreboardPath = Join-Path $judgeRoot "scoreboard.json"
  if ($Judge) {
    Invoke-DuelStage -Enabled $true -Index 4 -Total 5 -Name "Running machine judge" -Action {
      $script:scoreboard = Build-Scoreboard `
        -ArtifactRootPath $artifactRoot `
        -ProjectRoot $resolvedWorkingDirectory `
        -ResumeState $resume `
        -ConstraintsState $constraints

      Save-JsonFile -Path $scoreboardPath -Value $scoreboard
      Write-VerificationLog -LogPath (Join-Path $judgeRoot "verification.log") -Scoreboard $scoreboard
      $resume.phases.judge = "scored"
    }
  } elseif (Test-Path -LiteralPath $scoreboardPath -PathType Leaf) {
    $scoreboard = Load-JsonFile -Path $scoreboardPath
  } else {
    throw "Scoreboard missing. Run -Judge before writing a verdict."
  }
}

Invoke-DuelStage -Enabled ([bool]$WriteVerdict) -Index 5 -Total 5 -Name "Writing verdict" -Action {
  $finalChoice = if ($VerdictChoice) { $VerdictChoice } else { [string]$scoreboard.recommendedWinner }
  $mergeWorkspaceRoot = $null
  if ($PrepareMergeWorkspace -or $finalChoice -eq "merge-best-of-both") {
    $mergeWorkspaceRoot = Ensure-MergeWorkspace -ArtifactRootPath $artifactRoot -ResumeState $resume
  }

  Write-VerdictMarkdown `
    -VerdictPath (Join-Path $judgeRoot "verdict.md") `
    -Scoreboard $scoreboard `
    -FinalChoice $finalChoice `
    -MergeWorkspaceRoot $mergeWorkspaceRoot

  $resume.phases.judge = "verdict-written"
}

Save-JsonFile -Path $resumePath -Value $resume

Write-Output "Duel artifact root: $artifactRoot"
Write-Output "Duel status: $($resume.status)"
Write-Output "Run count: $($resume.runCount)"
Write-Output "Candidate setup: $($candidateSetup.mode)"
if ($GenerateGeminiCandidate) {
  Write-Output "Gemini candidate: recorded"
}
if ($RecordCodexCandidate) {
  Write-Output "Codex candidate: recorded"
}
if ($Judge -and $scoreboard) {
  Write-Output "Judge recommendation: $($scoreboard.recommendedWinner)"
}
if ($WriteVerdict) {
  Write-Output "Verdict written: $(Join-Path $judgeRoot 'verdict.md')"
  if ($AutoRun) {
    Write-Output "Verdict path: $(Join-Path $judgeRoot 'verdict.md')"
  }
}
if ($DryRun) {
  Write-Output "Dry run complete. Candidate generation and machine judging may still be scaffolded depending on the selected actions."
}
