[CmdletBinding()]
param(
  [ValidateSet("ui-implement", "ui-redesign", "ui-critique", "docs", "architecture", "compress", "general", "prepare-brief")]
  [string]$Mode = "general",
  [ValidateSet("build", "think", "critique")]
  [string]$ExecutionMode,
  [ValidateSet("quick", "normal", "long", "extended")]
  [string]$ExpectedDuration = "normal",
  [string]$WorkingDirectory = (Get-Location).Path,
  [string]$Model,
  [string[]]$ContextPath = @(),
  [int]$MaxFileChars = 20000,
  [switch]$Json,
  [switch]$NoAutoBrief,
  [string]$ArtifactDirectory,
  [string]$ArtifactPrefix = "gemini-output",
  [string]$MockResponseFile,
  [string]$PromptFile,
  [string]$PromptText,
  [Parameter(ValueFromPipeline = $true)]
  [AllowNull()]
  [AllowEmptyString()]
  [object]$PipelineInputObject,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Prompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Save-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $json = $Value | ConvertTo-Json -Depth 50
  Write-Utf8File -Path $Path -Content $json
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

function Set-ProcessArgumentsCompat {
  param(
    [System.Diagnostics.ProcessStartInfo]$StartInfo,
    [string[]]$Arguments
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

  $StartInfo.Arguments = ($quotedArguments -join " ")
}

function Set-ProcessEncodingCompat {
  param(
    [System.Diagnostics.ProcessStartInfo]$StartInfo
  )

  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  foreach ($propertyName in @("StandardInputEncoding", "StandardOutputEncoding", "StandardErrorEncoding")) {
    $property = $StartInfo.PSObject.Properties[$propertyName]
    if ($null -ne $property) {
      $StartInfo.$propertyName = $utf8NoBom
    }
  }
}

function Resolve-GeminiRuntime {
  $geminiCmd = Get-Command gemini.cmd -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
  $baseDir = Split-Path $geminiCmd -Parent
  $bundlePath = Join-Path $baseDir "node_modules\@google\gemini-cli\bundle\gemini.js"
  $localNode = Join-Path $baseDir "node.exe"

  if (Test-Path -LiteralPath $localNode -PathType Leaf) {
    $nodePath = $localNode
  } else {
    $nodePath = Get-Command node -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source
  }

  if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
    throw "Gemini CLI bundle not found at $bundlePath"
  }

  return @{
    NodePath = $nodePath
    BundlePath = $bundlePath
  }
}

function Get-DefaultModels {
  param([string]$SelectedMode)

  switch ($SelectedMode) {
    "ui-implement" { return @("gemini-3.1-pro-preview", "gemini-3-pro-preview", "gemini-2.5-pro", "pro") }
    "ui-redesign"  { return @("gemini-3.1-pro-preview", "gemini-3-pro-preview", "gemini-2.5-pro", "pro") }
    "ui-critique"  { return @("gemini-3-flash-preview", "gemini-2.5-flash", "flash", "gemini-2.5-pro") }
    "docs"         { return @("gemini-3.1-pro-preview", "gemini-3-pro-preview", "gemini-2.5-pro", "pro") }
    "architecture" { return @("gemini-3.1-pro-preview", "gemini-3-pro-preview", "gemini-2.5-pro", "pro") }
    "compress"     { return @("gemini-3.1-flash-lite-preview", "gemini-2.5-flash-lite", "flash-lite", "gemini-2.5-flash") }
    "prepare-brief" { return @("gemini-3.1-flash-lite-preview", "gemini-3-flash-preview", "gemini-2.5-flash-lite", "flash-lite", "gemini-2.5-flash") }
    default        { return @("gemini-3-flash-preview", "gemini-2.5-flash", "flash", "gemini-2.5-pro") }
  }
}

function Resolve-ContextPath {
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

function Test-NoiseLine {
  param([string]$Line)

  if ([string]::IsNullOrWhiteSpace($Line)) {
    return $true
  }

  $trimmed = $Line.Trim()
  return (
    $trimmed -eq "Loaded cached credentials." -or
    $trimmed -match '^Attempt \d+ failed: .*Retrying after .*ms\.\.\.$' -or
    $trimmed -match '^\[STARTUP\]' -or
    $trimmed -eq 'Keychain functional verification failed' -or
    $trimmed -eq 'Using FileKeychain fallback for secure storage.'
  )
}

function Normalize-RenderedOutput {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ""
  }

  return (($Text -split "\r?\n") | Where-Object { -not (Test-NoiseLine -Line $_) }) -join "`n"
}

function Write-ArtifactCapture {
  param(
    [string]$DirectoryPath,
    [string]$Prefix,
    [object]$Result,
    [string]$PromptPayload,
    [string]$SelectedMode,
    [string]$SelectedExecutionMode,
    [bool]$AutoBriefUsed
  )

  if ([string]::IsNullOrWhiteSpace($DirectoryPath)) {
    return
  }

  Ensure-Directory -Path $DirectoryPath

  $rawPath = Join-Path $DirectoryPath ("{0}-raw.txt" -f $Prefix)
  $normalizedPath = Join-Path $DirectoryPath ("{0}-normalized.txt" -f $Prefix)
  $metadataPath = Join-Path $DirectoryPath ("{0}-metadata.json" -f $Prefix)
  $promptPath = Join-Path $DirectoryPath ("{0}-prompt.txt" -f $Prefix)
  $rawCombined = @(
    "STDOUT:",
    [string]$Result.RawStdOut,
    "",
    "STDERR:",
    [string]$Result.RawStdErr
  ) -join "`n"

  Write-Utf8File -Path $rawPath -Content $rawCombined
  Write-Utf8File -Path $normalizedPath -Content ([string]$Result.Output)
  Write-Utf8File -Path $promptPath -Content ([string]$PromptPayload)
  Save-JsonFile -Path $metadataPath -Value ([PSCustomObject]@{
    model = $Result.Model
    exitCode = $Result.ExitCode
    success = ($Result.ExitCode -eq 0)
    mode = $SelectedMode
    executionMode = $SelectedExecutionMode
    autoBriefUsed = $AutoBriefUsed
    outputFormat = $Result.OutputFormat
    rawStdOutBytes = [System.Text.Encoding]::UTF8.GetByteCount(([string]$Result.RawStdOut))
    rawStdErrBytes = [System.Text.Encoding]::UTF8.GetByteCount(([string]$Result.RawStdErr))
    normalizedBytes = [System.Text.Encoding]::UTF8.GetByteCount(([string]$Result.Output))
    capturedAt = (Get-Date).ToString("o")
  })
}

function Get-ModeInstructions {
  param([string]$SelectedMode)

  switch ($SelectedMode) {
    "ui-implement" {
      return @"
Mode: ui-implement
- You are the primary author of new UI/design code.
- Return implementation-ready code, not generic advice.
- Preserve existing design-system constraints and component contracts when supplied.
- Prefer a short change plan, file-by-file code blocks, and short integration notes.
"@
    }
    "ui-redesign" {
      return @"
Mode: ui-redesign
- You are the primary author of a full visual redesign.
- Replace the design comprehensively, not just small cosmetic tweaks.
- Preserve screen purpose, information architecture, route structure, component responsibilities, and functional behavior unless the prompt explicitly authorizes a product change.
- Do not invent new semantic blocks, product scope, or functional flows unless the prompt explicitly asks for that.
- Prefer file-by-file implementation-ready code blocks and short integration notes.
"@
    }
    "ui-critique" {
      return @"
Mode: ui-critique
- Critique the UI directly and rank the most important weaknesses first.
- Prefer concrete fixes over abstract principles.
- If a small rewritten snippet clarifies the fix, include it.
"@
    }
    "docs" {
      return @"
Mode: docs
- Write polished, publishable prose unless the prompt explicitly asks for an outline.
- Favor structure, clarity, and concise final wording.
"@
    }
    "architecture" {
      return @"
Mode: architecture
- Produce 2-3 viable options with trade-offs and a clear recommendation.
- Prefer practical decomposition and integration guidance over theory.
"@
    }
    "compress" {
      return @"
Mode: compress
- Compress aggressively but preserve constraints, assumptions, and open questions.
- Output a compact brief that Codex can reuse in a later prompt.
"@
    }
    "prepare-brief" {
      return @"
Mode: prepare-brief
- Prepare a normalized brief for a later implementation or review pass.
- Do not write code.
- Return compact markdown with goal, deliverable, constraints, relevant files, risks, and open questions.
"@
    }
    default {
      return @"
Mode: general
- Act as a strong second brain.
- Prefer concrete output, concise reasoning, and practical next steps.
"@
    }
  }
}

function Get-DefaultExecutionMode {
  param([string]$SelectedMode)

  switch ($SelectedMode) {
    "ui-critique" { return "critique" }
    "prepare-brief" { return "think" }
    "compress" { return "think" }
    "architecture" { return "think" }
    "general" { return "think" }
    default { return "build" }
  }
}

function Get-ExecutionModeInstructions {
  param([string]$SelectedExecutionMode)

  switch ($SelectedExecutionMode) {
    "build" {
      return @"
Execution mode: build
- Minimize discussion and move toward implementation-ready output.
- Prefer one clear recommended path over multiple broad options unless the prompt explicitly asks for alternatives.
- Optimize for task completion, concrete artifacts, and easy Codex integration.
"@
    }
    "think" {
      return @"
Execution mode: think
- Generate alternatives, compare trade-offs, and make hidden constraints explicit.
- Prefer analysis, option framing, and a clear recommendation before code.
- Do not rush into a greenfield implementation unless the prompt explicitly requests code immediately.
"@
    }
    "critique" {
      return @"
Execution mode: critique
- Focus on review, weaknesses, regressions, and specific improvements.
- Do not generate a greenfield rewrite unless explicitly requested.
- Prefer ranked findings, targeted corrections, and scope discipline over broad reinvention.
"@
    }
  }
}

function Get-DurationInstructions {
  param([string]$SelectedDuration)

  switch ($SelectedDuration) {
    "quick" {
      return @"
Expected duration: quick
- Prefer concise output and fast completion.
- Do not over-elaborate.
"@
    }
    "long" {
      return @"
Expected duration: long
- This task may take a while. Do not trade completeness for speed.
- Prefer a cohesive, high-signal result over fragmented partial output.
"@
    }
    "extended" {
      return @"
Expected duration: extended
- This is an intentionally long-running agent task.
- Take the time needed to produce a cohesive deliverable.
- Do not optimize for quick partials when the prompt asks for an integrated result.
"@
    }
    default {
      return @"
Expected duration: normal
- Balance completeness and speed.
"@
    }
  }
}

function Build-ContextSection {
  param(
    [string]$BaseDirectory,
    [string[]]$RequestedContextPath,
    [int]$Limit
  )

  $contextBlocks = New-Object System.Collections.Generic.List[string]
  foreach ($path in $RequestedContextPath) {
    $resolvedPath = Resolve-ContextPath -BaseDirectory $BaseDirectory -Candidate $path
    if (-not $resolvedPath) {
      continue
    }

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
      $contextBlocks.Add([string]::Join("`n", @(
        "## Missing Context File"
        "Requested: $path"
        "Resolved: $resolvedPath"
      )))
      continue
    }

    try {
      $content = Get-Content -LiteralPath $resolvedPath -Raw
      if ($content.Length -gt $Limit) {
        $content = $content.Substring(0, $Limit) + "`n...[truncated]"
      }
      $relative = Get-RelativePathSafe -BasePath $BaseDirectory -TargetPath $resolvedPath
      $contextBlocks.Add([string]::Join("`n", @(
        "## Context File: $relative"
        "Absolute: $resolvedPath"
        '```text'
        $content
        '```'
      )))
    } catch {
      $contextBlocks.Add([string]::Join("`n", @(
        "## Unreadable Context File"
        "Path: $resolvedPath"
        "Reason: $($_.Exception.Message)"
      )))
    }
  }

  if ($contextBlocks.Count -eq 0) {
    return "## Context Files`nNone provided."
  }

  return ($contextBlocks -join "`n`n")
}

function Build-CollaborationContract {
  param(
    [string]$BaseDirectory,
    [string]$SelectedMode
  )

  $specialistLine = if ($SelectedMode -in @("ui-implement", "ui-redesign")) {
    "- You are the primary author of new UI/design code for this task."
  } else {
    "- Act as the specialist collaborator for this task."
  }

  return @"
You are Gemini, working in tandem with Codex.

Collaboration contract:
- Codex is the orchestrator, local editor, tool user, and verifier.
$specialistLine
- Work only against this explicit project root: $BaseDirectory
- Treat that directory as authoritative. Do not assume any other repository or random cwd.
- If you reference files, prefer paths relative to that root unless the prompt already uses absolute paths.
- Produce concrete deliverables. If code is requested, return implementation-ready output.
- If context is incomplete, state the gap briefly and make the narrowest safe assumption.
"@
}

function Build-FullPrompt {
  param(
    [string]$CollaborationContract,
    [string]$ModeInstructions,
    [string]$ExecutionInstructions,
    [string]$DurationInstructions,
    [string]$ProjectRoot,
    [string]$ContextSection,
    [string]$UserPrompt,
    [string]$NormalizedBrief
  )

  $briefSection = if ([string]::IsNullOrWhiteSpace($NormalizedBrief)) {
    "## Normalized Brief`nNone generated."
  } else {
    "## Normalized Brief`n$NormalizedBrief"
  }

  return @"
$CollaborationContract

$ModeInstructions

$ExecutionInstructions

$DurationInstructions

## Project Root
$ProjectRoot

$briefSection

$ContextSection

## Task For Gemini
$UserPrompt
"@
}

function Get-StreamMessageText {
  param($Content)

  if ($null -eq $Content) {
    return ""
  }

  if ($Content -is [string]) {
    return $Content
  }

  try {
    return ($Content | ConvertTo-Json -Depth 20 -Compress)
  } catch {
    return [string]$Content
  }
}

function Invoke-GeminiPlainProcess {
  param(
    [string]$NodePath,
    [string]$BundlePath,
    [string]$WorkingDirectoryPath,
    [string]$CandidateModel,
    [string]$OutputFormat,
    [string]$PromptPayload
  )

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $NodePath
  $startInfo.WorkingDirectory = $WorkingDirectoryPath
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  Set-ProcessEncodingCompat -StartInfo $startInfo
  Set-ProcessArgumentsCompat -StartInfo $startInfo -Arguments @(
    "--no-warnings=DEP0040",
    $BundlePath,
    "--model",
    $CandidateModel,
    "--output-format",
    $OutputFormat
  )

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  [void]$process.Start()

  $process.StandardInput.Write($PromptPayload)
  $process.StandardInput.Close()

  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()

  $normalizedStdOut = Normalize-RenderedOutput -Text $stdout
  $normalizedStdErr = Normalize-RenderedOutput -Text $stderr
  $combinedOutput = @($normalizedStdOut, $normalizedStdErr) -join "`n"
  $combinedOutput = $combinedOutput.Trim()

  return [PSCustomObject]@{
    ExitCode = $process.ExitCode
    StdOut = $normalizedStdOut
    StdErr = $normalizedStdErr
    RawStdOut = $stdout
    RawStdErr = $stderr
    OutputFormat = $OutputFormat
    Output = $combinedOutput
  }
}

function Invoke-GeminiStreamProcess {
  param(
    [string]$NodePath,
    [string]$BundlePath,
    [string]$WorkingDirectoryPath,
    [string]$CandidateModel,
    [string]$PromptPayload
  )

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $NodePath
  $startInfo.WorkingDirectory = $WorkingDirectoryPath
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  Set-ProcessEncodingCompat -StartInfo $startInfo
  Set-ProcessArgumentsCompat -StartInfo $startInfo -Arguments @(
    "--no-warnings=DEP0040",
    $BundlePath,
    "--model",
    $CandidateModel,
    "--output-format",
    "stream-json"
  )

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  [void]$process.Start()
  $stderrTask = $process.StandardError.ReadToEndAsync()

  $process.StandardInput.Write($PromptPayload)
  $process.StandardInput.Close()

  $assistantBuilder = [System.Text.StringBuilder]::new()
  $rawStdOutBuilder = [System.Text.StringBuilder]::new()
  $assistantFallback = ""
  $nonFatalErrors = New-Object System.Collections.Generic.List[string]
  $nonJsonLines = New-Object System.Collections.Generic.List[string]

  while (-not $process.StandardOutput.EndOfStream) {
    $line = $process.StandardOutput.ReadLine()
    [void]$rawStdOutBuilder.AppendLine($line)
    if ([string]::IsNullOrWhiteSpace($line) -or (Test-NoiseLine -Line $line)) {
      continue
    }

    try {
      $event = $line | ConvertFrom-Json -Depth 50
    } catch {
      $nonJsonLines.Add($line)
      continue
    }

    switch ($event.type) {
      "message" {
        if ($event.role -eq "assistant") {
          $contentText = Get-StreamMessageText -Content $event.content
          if (-not [string]::IsNullOrWhiteSpace($contentText)) {
            $hasDeltaFlag = $event.PSObject.Properties.Name -contains "delta"
            if ($hasDeltaFlag -and $event.delta) {
              [void]$assistantBuilder.Append($contentText)
            } elseif ($contentText.Length -gt $assistantFallback.Length) {
              $assistantFallback = $contentText
            }
          }
        }
      }
      "error" {
        if ($event.PSObject.Properties.Name -contains "message" -and -not [string]::IsNullOrWhiteSpace([string]$event.message)) {
          $nonFatalErrors.Add([string]$event.message)
        } else {
          $nonFatalErrors.Add(($event | ConvertTo-Json -Depth 20 -Compress))
        }
      }
    }
  }

  $process.WaitForExit()
  $stderrTask.Wait()

  $stdoutText = $assistantBuilder.ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($stdoutText)) {
    $stdoutText = $assistantFallback.Trim()
  }
  if ([string]::IsNullOrWhiteSpace($stdoutText) -and $nonJsonLines.Count -gt 0) {
    $stdoutText = (($nonJsonLines | Where-Object { -not (Test-NoiseLine -Line $_) }) -join "`n").Trim()
  }

  $stderrText = Normalize-RenderedOutput -Text $stderrTask.Result
  if ($nonFatalErrors.Count -gt 0) {
    $joinedErrors = ($nonFatalErrors -join "`n").Trim()
    if ($stderrText) {
      $stderrText = ($stderrText + "`n" + $joinedErrors).Trim()
    } else {
      $stderrText = $joinedErrors
    }
  }

  return [PSCustomObject]@{
    ExitCode = $process.ExitCode
    StdOut = $stdoutText
    StdErr = $stderrText
    RawStdOut = $rawStdOutBuilder.ToString()
    RawStdErr = $stderrTask.Result
    OutputFormat = "stream-json"
    Output = (@($stdoutText, $stderrText) -join "`n").Trim()
  }
}

function Invoke-GeminiCandidate {
  param(
    [string]$NodePath,
    [string]$BundlePath,
    [string]$WorkingDirectoryPath,
    [string]$CandidateModel,
    [string]$OutputFormat,
    [string]$PromptPayload
  )

  if ($OutputFormat -eq "stream-json") {
    return Invoke-GeminiStreamProcess `
      -NodePath $NodePath `
      -BundlePath $BundlePath `
      -WorkingDirectoryPath $WorkingDirectoryPath `
      -CandidateModel $CandidateModel `
      -PromptPayload $PromptPayload
  }

  return Invoke-GeminiPlainProcess `
    -NodePath $NodePath `
    -BundlePath $BundlePath `
    -WorkingDirectoryPath $WorkingDirectoryPath `
    -CandidateModel $CandidateModel `
    -OutputFormat $OutputFormat `
    -PromptPayload $PromptPayload
}

function Invoke-GeminiWithFallback {
  param(
    [string]$NodePath,
    [string]$BundlePath,
    [string]$WorkingDirectoryPath,
    [string[]]$ModelsToTry,
    [string]$OutputFormat,
    [string]$PromptPayload,
    [string]$MockResponseFilePath
  )

  if ($MockResponseFilePath) {
    $resolvedMockPath = [System.IO.Path]::GetFullPath($MockResponseFilePath)
    if (-not (Test-Path -LiteralPath $resolvedMockPath -PathType Leaf)) {
      throw "Mock response file not found: $resolvedMockPath"
    }

    $mockText = Get-Content -LiteralPath $resolvedMockPath -Raw
    $mockOutput = ""
    try {
      $mockJson = $mockText | ConvertFrom-Json -Depth 50
      if ($mockJson.PSObject.Properties.Name -contains "output") {
        $mockOutput = [string]$mockJson.output
      } elseif ($mockJson.PSObject.Properties.Name -contains "Output") {
        $mockOutput = [string]$mockJson.Output
      } else {
        $mockOutput = $mockText
      }
    } catch {
      $mockOutput = $mockText
    }

    return [PSCustomObject]@{
      Model = "mock"
      ExitCode = 0
      OutputFormat = $OutputFormat
      Output = $mockOutput.Trim()
      RawStdOut = $mockText
      RawStdErr = ""
    }
  }

  $attempts = @()
  foreach ($candidateModel in $ModelsToTry) {
    $result = Invoke-GeminiCandidate `
      -NodePath $NodePath `
      -BundlePath $BundlePath `
      -WorkingDirectoryPath $WorkingDirectoryPath `
      -CandidateModel $candidateModel `
      -OutputFormat $OutputFormat `
      -PromptPayload $PromptPayload

    $renderedOutput = @($result.StdOut, $result.StdErr) -join "`n"
    $renderedOutput = $renderedOutput.Trim()

    $attempts += [PSCustomObject]@{
      Model = $candidateModel
      ExitCode = $result.ExitCode
      OutputFormat = $result.OutputFormat
      Output = $renderedOutput
      RawStdOut = [string]$result.RawStdOut
      RawStdErr = [string]$result.RawStdErr
    }

    if ($result.ExitCode -eq 0) {
      return [PSCustomObject]@{
        Model = $candidateModel
        ExitCode = $result.ExitCode
        OutputFormat = $result.OutputFormat
        Output = $renderedOutput
        RawStdOut = [string]$result.RawStdOut
        RawStdErr = [string]$result.RawStdErr
      }
    }
  }

  $attemptSummary = $attempts | ForEach-Object {
    "Model: $($_.Model)`nFormat: $($_.OutputFormat)`nExitCode: $($_.ExitCode)`nOutput:`n$($_.Output)"
  }
  throw ("Gemini consult failed for all candidate models.`n`n" + ($attemptSummary -join "`n`n---`n`n"))
}

function Should-UseAutoBrief {
  param(
    [string]$SelectedMode,
    [string]$SelectedDuration,
    [int]$ContextCount,
    [int]$PromptLength,
    [bool]$DisableAutoBrief
  )

  if ($DisableAutoBrief) {
    return $false
  }

  if ($SelectedMode -in @("prepare-brief", "compress", "ui-critique", "general")) {
    return $false
  }

  if ($ContextCount -gt 0) {
    return $true
  }

  if ($SelectedDuration -in @("long", "extended")) {
    return $true
  }

  return ($PromptLength -ge 1200)
}

function Invoke-ConsultMain {
  param(
    [string[]]$CollectedPipelineInput,
    [string]$RedirectedStdinText
  )

  $pipelineText = if ($CollectedPipelineInput.Count -gt 0) { ($CollectedPipelineInput -join [Environment]::NewLine).Trim() } else { "" }

  $promptFileText = ""
  if ($PromptFile) {
    $resolvedPromptFile = Resolve-ContextPath -BaseDirectory ([System.IO.Path]::GetFullPath($WorkingDirectory)) -Candidate $PromptFile
    if (-not (Test-Path -LiteralPath $resolvedPromptFile -PathType Leaf)) {
      throw "Prompt file not found: $resolvedPromptFile"
    }
    $promptFileText = Get-Content -LiteralPath $resolvedPromptFile -Raw
  }

  $argPrompt = ($Prompt -join " ").Trim()
  $primaryInput = if ($pipelineText) { $pipelineText } else { $RedirectedStdinText.Trim() }
  $userPrompt = @($primaryInput, $promptFileText.Trim(), $PromptText, $argPrompt) -join "`n`n"
  $userPrompt = $userPrompt.Trim()

  if ([string]::IsNullOrWhiteSpace($userPrompt)) {
    throw "Provide a prompt as arguments, PowerShell pipeline input, or stdin."
  }

  $resolvedWorkingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)
  if (-not (Test-Path -LiteralPath $resolvedWorkingDirectory -PathType Container)) {
    throw "Working directory not found: $resolvedWorkingDirectory"
  }

  $contextSection = Build-ContextSection `
    -BaseDirectory $resolvedWorkingDirectory `
    -RequestedContextPath $ContextPath `
    -Limit $MaxFileChars

  $geminiRuntime = Resolve-GeminiRuntime
  $normalizedBrief = ""
  $resolvedExecutionMode = if ($ExecutionMode) { $ExecutionMode } else { Get-DefaultExecutionMode -SelectedMode $Mode }

  $useAutoBrief = Should-UseAutoBrief `
    -SelectedMode $Mode `
    -SelectedDuration $ExpectedDuration `
    -ContextCount $ContextPath.Count `
    -PromptLength $userPrompt.Length `
    -DisableAutoBrief $NoAutoBrief.IsPresent

  if ($useAutoBrief) {
    $briefPrompt = @"
You are preparing a normalized brief for a later Gemini task executed by Codex.

Do not write code.

The later task mode will be: $Mode

Return compact markdown with these sections:
- Goal
- Deliverable
- Constraints
- Relevant Files And Surfaces
- Risks
- Open Questions Or Assumptions

Use only the information provided here.

## Original Task
$userPrompt

$contextSection
"@

    try {
      $briefResult = Invoke-GeminiWithFallback `
        -NodePath $geminiRuntime.NodePath `
        -BundlePath $geminiRuntime.BundlePath `
        -WorkingDirectoryPath $resolvedWorkingDirectory `
        -ModelsToTry (Get-DefaultModels -SelectedMode "prepare-brief") `
        -OutputFormat "text" `
        -PromptPayload $briefPrompt `
        -MockResponseFilePath $MockResponseFile
      $normalizedBrief = [string]$briefResult.Output
    } catch {
      $normalizedBrief = ""
    }
  }

  $collaborationContract = Build-CollaborationContract -BaseDirectory $resolvedWorkingDirectory -SelectedMode $Mode
  $modeInstructions = Get-ModeInstructions -SelectedMode $Mode
  $executionInstructions = Get-ExecutionModeInstructions -SelectedExecutionMode $resolvedExecutionMode
  $durationInstructions = Get-DurationInstructions -SelectedDuration $ExpectedDuration
  $fullPrompt = Build-FullPrompt `
    -CollaborationContract $collaborationContract `
    -ModeInstructions $modeInstructions `
    -ExecutionInstructions $executionInstructions `
    -DurationInstructions $durationInstructions `
    -ProjectRoot $resolvedWorkingDirectory `
    -ContextSection $contextSection `
    -UserPrompt $userPrompt `
    -NormalizedBrief $normalizedBrief

  $modelsToTry = if ($Model) { @($Model) } else { Get-DefaultModels -SelectedMode $Mode }
  $outputFormat = if ($Json) {
    "json"
  } elseif ($ExpectedDuration -in @("long", "extended")) {
    "stream-json"
  } else {
    "text"
  }

  $renderedOutput = Invoke-GeminiWithFallback `
    -NodePath $geminiRuntime.NodePath `
    -BundlePath $geminiRuntime.BundlePath `
    -WorkingDirectoryPath $resolvedWorkingDirectory `
    -ModelsToTry $modelsToTry `
    -OutputFormat $outputFormat `
    -PromptPayload $fullPrompt `
    -MockResponseFilePath $MockResponseFile

  if ($renderedOutput) {
    Write-ArtifactCapture `
      -DirectoryPath $ArtifactDirectory `
      -Prefix $ArtifactPrefix `
      -Result $renderedOutput `
      -PromptPayload $fullPrompt `
      -SelectedMode $Mode `
      -SelectedExecutionMode $resolvedExecutionMode `
      -AutoBriefUsed $useAutoBrief
    Write-Output $renderedOutput.Output
  }
}

$redirectedStdinText = ""
if ([Console]::IsInputRedirected -and -not $MyInvocation.ExpectingInput) {
  $redirectedStdinText = [Console]::In.ReadToEnd()
}

$collectedPipelineInput = @()
if ($MyInvocation.ExpectingInput) {
  $collectedPipelineInput = @($input | ForEach-Object { if ($null -ne $_) { [string]$_ } })
}

Invoke-ConsultMain `
  -CollectedPipelineInput $collectedPipelineInput `
  -RedirectedStdinText $redirectedStdinText
