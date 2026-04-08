param(
  [string]$RepositoryRoot = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
  param([string]$BaseDirectory)

  try {
    $repoRoot = (& git -C $BaseDirectory rev-parse --show-toplevel 2>$null | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
      return $null
    }
    return [System.IO.Path]::GetFullPath($repoRoot)
  } catch {
    return $null
  }
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

function Get-RepoFiles {
  param([string]$RepoRoot)

  $files = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  try {
    $tracked = @(& git -C $RepoRoot ls-files 2>$null)
    foreach ($item in $tracked) {
      if (-not [string]::IsNullOrWhiteSpace($item)) {
        [void]$files.Add($item.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
      }
    }
  } catch {
    return $files
  }
  return $files
}

function Resolve-ImportCandidate {
  param(
    [string]$RepoRoot,
    [string]$SourceRelativePath,
    [string]$Specifier,
    [System.Collections.Generic.HashSet[string]]$KnownFiles
  )

  if ([string]::IsNullOrWhiteSpace($Specifier)) {
    return @()
  }

  $results = New-Object System.Collections.Generic.List[string]
  $sourceAbsolutePath = Join-Path $RepoRoot $SourceRelativePath
  $sourceDirectory = Split-Path $sourceAbsolutePath -Parent
  $normalizedSpecifier = $Specifier.Trim().Replace('/', [System.IO.Path]::DirectorySeparatorChar)
  $extCandidates = @("", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".py", ".ps1", ".json", ".css", ".scss", ".sass", ".less")

  if ($normalizedSpecifier.StartsWith(".")) {
    $baseTarget = [System.IO.Path]::GetFullPath((Join-Path $sourceDirectory $normalizedSpecifier))
    foreach ($ext in $extCandidates) {
      $candidate = if ([string]::IsNullOrWhiteSpace($ext)) { $baseTarget } else { $baseTarget + $ext }
      $relative = Get-RelativePathSafe -BasePath $RepoRoot -TargetPath $candidate
      if ($KnownFiles.Contains($relative)) {
        $results.Add($relative)
      }
    }
    foreach ($indexFile in @("index.ts", "index.tsx", "index.js", "index.jsx", "__init__.py")) {
      $candidate = Join-Path $baseTarget $indexFile
      $relative = Get-RelativePathSafe -BasePath $RepoRoot -TargetPath $candidate
      if ($KnownFiles.Contains($relative)) {
        $results.Add($relative)
      }
    }
  } elseif ($normalizedSpecifier -match '^[A-Za-z_][A-Za-z0-9_\.]*$') {
    $modulePath = $normalizedSpecifier.Replace('.', [System.IO.Path]::DirectorySeparatorChar)
    foreach ($candidate in @(
      ($modulePath + ".py"),
      (Join-Path $modulePath "__init__.py")
    )) {
      if ($KnownFiles.Contains($candidate)) {
        $results.Add($candidate)
      }
    }
  }

  return @($results | Select-Object -Unique)
}

function Get-ImportSpecifiers {
  param(
    [string]$FilePath,
    [string]$Content
  )

  $extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
  $specifiers = New-Object System.Collections.Generic.List[string]
  $patterns = switch ($extension) {
    ".ts" { @("(?m)(?:import|export)\s+[^`n]*?\sfrom\s*['""]([^'""]+)['""]", "(?m)require\(\s*['""]([^'""]+)['""]\s*\)", "(?m)import\(\s*['""]([^'""]+)['""]\s*\)") }
    ".tsx" { @("(?m)(?:import|export)\s+[^`n]*?\sfrom\s*['""]([^'""]+)['""]", "(?m)require\(\s*['""]([^'""]+)['""]\s*\)", "(?m)import\(\s*['""]([^'""]+)['""]\s*\)") }
    ".js" { @("(?m)(?:import|export)\s+[^`n]*?\sfrom\s*['""]([^'""]+)['""]", "(?m)require\(\s*['""]([^'""]+)['""]\s*\)", "(?m)import\(\s*['""]([^'""]+)['""]\s*\)") }
    ".jsx" { @("(?m)(?:import|export)\s+[^`n]*?\sfrom\s*['""]([^'""]+)['""]", "(?m)require\(\s*['""]([^'""]+)['""]\s*\)", "(?m)import\(\s*['""]([^'""]+)['""]\s*\)") }
    ".mjs" { @("(?m)(?:import|export)\s+[^`n]*?\sfrom\s*['""]([^'""]+)['""]", "(?m)import\(\s*['""]([^'""]+)['""]\s*\)") }
    ".cjs" { @("(?m)require\(\s*['""]([^'""]+)['""]\s*\)") }
    ".py" { @("(?m)^\s*from\s+([A-Za-z_\.][A-Za-z0-9_\.]*)\s+import\s+", "(?m)^\s*import\s+([A-Za-z_][A-Za-z0-9_\.]*)") }
    ".ps1" { @("(?m)^\s*\.\s+['""]?([^'""]+\.ps1)['""]?") }
    default { @() }
  }

  foreach ($pattern in $patterns) {
    foreach ($match in [regex]::Matches($Content, $pattern)) {
      $value = [string]$match.Groups[1].Value
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        $specifiers.Add($value.Trim())
      }
    }
  }

  return @($specifiers | Select-Object -Unique)
}

$repoRoot = Get-RepoRoot -BaseDirectory $RepositoryRoot
if (-not $repoRoot) {
  Write-Output ""
  exit 0
}

$knownFiles = Get-RepoFiles -RepoRoot $repoRoot
if ($knownFiles.Count -eq 0) {
  Write-Output ""
  exit 0
}

try {
  $changedFiles = @(& git -C $repoRoot diff --name-only HEAD 2>$null)
} catch {
  Write-Output ""
  exit 0
}

if (@($changedFiles).Count -eq 0) {
  Write-Output ""
  exit 0
}

$selected = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($relativePath in $changedFiles) {
  $normalizedRelative = [string]$relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
  if (-not $knownFiles.Contains($normalizedRelative)) {
    continue
  }

  [void]$selected.Add($normalizedRelative)
  $absolutePath = Join-Path $repoRoot $normalizedRelative
  if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
    continue
  }

  try {
    $content = Get-Content -LiteralPath $absolutePath -Raw
  } catch {
    continue
  }

  foreach ($specifier in Get-ImportSpecifiers -FilePath $absolutePath -Content $content) {
    foreach ($candidate in Resolve-ImportCandidate -RepoRoot $repoRoot -SourceRelativePath $normalizedRelative -Specifier $specifier -KnownFiles $knownFiles) {
      [void]$selected.Add($candidate)
    }
  }
}

$ordered = @($selected | Sort-Object)
if ($ordered.Count -eq 0) {
  Write-Output ""
  exit 0
}

Write-Output ($ordered -join ",")
