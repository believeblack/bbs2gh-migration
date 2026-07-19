#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Usage:
#   ./0_prechecks.ps1 [-c repos.csv] [-o output.csv] [-p "KEY1,KEY2"]
#
# CSV minimum columns if provided: project-key,repo
# Env: BBS_BASE_URL + (BBS_PAT or BBS_USERNAME+BBS_PASSWORD with BBS_AUTH_TYPE=Basic)

# Defaults (match Bash)
$CSV_PATH = "repos.csv"
$OUTPUT_PATH = ""
$PROJECT_KEYS_CSV = ""

# Equivalent of: sed -i 's/"//g' $CSV_PATH
# NOTE: Intentionally executed BEFORE option parsing to preserve original logic.
if (Test-Path -LiteralPath $CSV_PATH) {
  try {
    $content = Get-Content -LiteralPath $CSV_PATH -Raw
    $content = $content -replace '"', ''
    Set-Content -LiteralPath $CSV_PATH -Value $content -NoNewline
  } catch {
    # best effort; do nothing
  }
}

# Manual arg parsing to mimic getopts behavior
for ($i = 0; $i -lt $args.Count; $i++) {
  switch ($args[$i]) {
    "-c" {
      if ($i + 1 -ge $args.Count) { throw "Usage: $($MyInvocation.MyCommand.Name) [-c repos.csv] [-o output.csv] [-p KEY1,KEY2]" }
      $CSV_PATH = $args[$i + 1]; $i++
    }
    "-o" {
      if ($i + 1 -ge $args.Count) { throw "Usage: $($MyInvocation.MyCommand.Name) [-c repos.csv] [-o output.csv] [-p KEY1,KEY2]" }
      $OUTPUT_PATH = $args[$i + 1]; $i++
    }
    "-p" {
      if ($i + 1 -ge $args.Count) { throw "Usage: $($MyInvocation.MyCommand.Name) [-c repos.csv] [-o output.csv] [-p KEY1,KEY2]" }
      $PROJECT_KEYS_CSV = $args[$i + 1]; $i++
    }
    default {
      throw "Usage: $($MyInvocation.MyCommand.Name) [-c repos.csv] [-o output.csv] [-p KEY1,KEY2]"
    }
  }
}

if (-not $env:BBS_BASE_URL) {
  throw "[ERROR] BBS_BASE_URL env var is required."
}
$BASE_URL = $env:BBS_BASE_URL.TrimEnd('/')

function Get-AuthHeader {
  if ($env:BBS_PAT) {
    return @{ Authorization = "Bearer $($env:BBS_PAT)" }
  }
  elseif (($env:BBS_AUTH_TYPE -eq "Basic") -and $env:BBS_USERNAME -and $env:BBS_PASSWORD) {
    $pair = "{0}:{1}" -f $env:BBS_USERNAME, $env:BBS_PASSWORD
    $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    return @{ Authorization = "Basic $b64" }
  }
  else {
    throw "[ERROR] Provide BBS_PAT or BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD."
  }
}

function Invoke-CurlJson([string]$Url) {
  # Equivalent of: curl -sS -H "$(auth_header)" "$1"
  $headers = Get-AuthHeader
  return Invoke-RestMethod -Method Get -Uri $Url -Headers $headers
}

# Helper: safely read optional JSON properties (jq: '.prop // empty')
function Get-OptPropValue($obj, [string]$propName) {
  $p = $obj.PSObject.Properties[$propName]
  if ($null -ne $p) { return $p.Value }
  return $null
}

# Preflight auth test
try {
  $null = Invoke-RestMethod -Method Get -Uri ("{0}/rest/api/1.0/projects?limit=1" -f $BASE_URL) -Headers (Get-AuthHeader)
} catch {
  throw "[ERROR] Bitbucket auth failed. Verify BBS_BASE_URL and credentials."
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$OUTPUT_CSV = if ([string]::IsNullOrEmpty($OUTPUT_PATH)) { "bbs_pr_validation_output-$timestamp.csv" } else { $OUTPUT_PATH }

# IFS=',' read -r -a PROJECT_KEYS <<< "${PROJECT_KEYS_CSV:-}"
$PROJECT_KEYS = @()
if (-not [string]::IsNullOrEmpty($PROJECT_KEYS_CSV)) {
  $PROJECT_KEYS = $PROJECT_KEYS_CSV.Split(',', [System.StringSplitOptions]::None)
}

function Discover-Projects {
  $start = 0
  $results = New-Object System.Collections.Generic.List[string]
  while ($true) {
    $resp = Invoke-CurlJson ("{0}/rest/api/1.0/projects?limit=100&start={1}" -f $BASE_URL, $start)

    if ($resp.values) {
      foreach ($v in $resp.values) {
        if ($null -ne $v.key -and $v.key -ne "") {
          $results.Add([string]$v.key) | Out-Null
        }
      }
    }

    $isLast    = Get-OptPropValue $resp "isLastPage"
    $nextStart = Get-OptPropValue $resp "nextPageStart"

    if ($isLast -eq "True" -or $isLast -eq "true") { break }
    if ($null -eq $nextStart -or $nextStart -eq "") { break }

    $start = [int]$nextStart
  }
  return $results.ToArray()
}

function Discover-ReposForProject([string]$projectKey) {
  $start = 0
  $lines = New-Object System.Collections.Generic.List[string]
  while ($true) {
    $resp = Invoke-CurlJson ("{0}/rest/api/1.0/projects/{1}/repos?limit=100&start={2}" -f $BASE_URL, $projectKey, $start)

    if ($resp.values) {
      foreach ($r in $resp.values) {
        $pname = [string]$r.project.name
        $slug  = [string]$r.slug
        $arch  = [string]$r.archived
        $lines.Add(("{0},{1},{2}" -f $pname, $slug, $arch)) | Out-Null
      }
    }

    $isLast    = Get-OptPropValue $resp "isLastPage"
    $nextStart = Get-OptPropValue $resp "nextPageStart"

    if ($isLast -eq "True" -or $isLast -eq "true") { break }
    if ($null -eq $nextStart -or $nextStart -eq "") { break }

    $start = [int]$nextStart
  }
  return $lines.ToArray()
}

function Get-OpenPrCount([string]$projectKey, [string]$repoSlug) {
  $start = 0
  $total = 0
  while ($true) {
    try {
      $resp = Invoke-CurlJson ("{0}/rest/api/1.0/projects/{1}/repos/{2}/pull-requests?state=OPEN&limit=100&start={3}" -f $BASE_URL, $projectKey, $repoSlug, $start)
    } catch {
      break  # equivalent of: || break
    }

    $cnt = 0
    if ($resp.values) { $cnt = @($resp.values).Count }
    $total += $cnt

    $isLast    = Get-OptPropValue $resp "isLastPage"
    $nextStart = Get-OptPropValue $resp "nextPageStart"

    if ($isLast -eq "True" -or $isLast -eq "true") { break }
    if ($null -eq $nextStart -or $nextStart -eq "") { break }

    $start = [int]$nextStart
  }
  return $total
}

Write-Host ""
Write-Host " Bitbucket Pipeline Readiness Check (Open PRs only) "
Write-Host "===================================================="

# Load or discover input rows
$rows_tmp = [System.IO.Path]::GetTempFileName()

if ((Test-Path -LiteralPath $CSV_PATH) -and ((Get-Item -LiteralPath $CSV_PATH).Length -gt 0)) {
  $header = (Get-Content -LiteralPath $CSV_PATH -TotalCount 1)
  if ($header -match "project-key" -and $header -match ",repo") {
    # tail -n +2 "$CSV_PATH" > "$rows_tmp"
    $rest = Get-Content -LiteralPath $CSV_PATH | Select-Object -Skip 1
    Set-Content -LiteralPath $rows_tmp -Value $rest
  } else {
    Write-Host "[ERROR] CSV missing minimum columns: project-key,repo"
    Write-Host "[INFO] Falling back to auto-discovery."
  }
}

# If rows_tmp is empty, auto-discovery
$rows_len = 0
if (Test-Path -LiteralPath $rows_tmp) {
  $rows_len = (Get-Content -LiteralPath $rows_tmp -ErrorAction SilentlyContinue | Measure-Object).Count
}

if ($rows_len -eq 0) {
  Write-Host "[INFO] Auto-discovering projects & repos..."
  $projects = @(Discover-Projects)

  foreach ($pk in $projects) {
    if ($PROJECT_KEYS.Count -gt 0) {
      $match = $false
      foreach ($filter in $PROJECT_KEYS) {
        if ($pk -eq $filter) { $match = $true }
      }
      if ($match -eq $false) { continue }
    }

    $repoLines = @(Discover-ReposForProject -projectKey $pk)
    foreach ($line in $repoLines) {
      $parts = $line.Split(',', 3)
      $pname = $parts[0]
      $rslug = $parts[1]
      $archived = $parts[2]
      Add-Content -LiteralPath $rows_tmp -Value ("{0},{1},{2},{3}" -f $pk, $pname, $rslug, $archived)
    }
  }
}

# Process
$ready_tmp = [System.IO.Path]::GetTempFileName()
$results_tmp = [System.IO.Path]::GetTempFileName()

Set-Content -LiteralPath $results_tmp -Value "project_key,project_name,repo_slug,is_archived,open_pr_count,warnings,ready_to_migrate"

$total_open_prs = 0

Get-Content -LiteralPath $rows_tmp | ForEach-Object {
  $line = $_
  if ([string]::IsNullOrWhiteSpace($line)) { return }

  # while IFS=',' read -r projKey projName repoSlug isArchived;
  $parts = $line.Split(',', 4)
  $projKey = $parts[0]
  $projName = if ($parts.Count -ge 2) { $parts[1] } else { "" }
  $repoSlug = if ($parts.Count -ge 3) { $parts[2] } else { "" }
  $isArchived = if ($parts.Count -ge 4) { $parts[3] } else { "" }

  $openPrs = Get-OpenPrCount -projectKey $projKey -repoSlug $repoSlug
  $total_open_prs += [int]$openPrs

  $warns = ""
  if ([int]$openPrs -gt 0) {
    $warns = "OPEN_PRS"
    Write-Host ("[WARNING] {0}/{1} PRs(Open): {2}" -f $projKey, $repoSlug, $openPrs)
  } else {
    Write-Host ("[OK] {0}/{1} PRs(Open): {2}" -f $projKey, $repoSlug, $openPrs)
    Add-Content -LiteralPath $ready_tmp -Value ("{0}/{1}" -f $projKey, $repoSlug)
  }

  $ready = $false; if ([string]::IsNullOrEmpty($warns)) { $ready = $true }

  $arch = $isArchived
  if ([string]::IsNullOrEmpty($arch)) { $arch = "false" }  # ${isArchived:-false}

  Add-Content -LiteralPath $results_tmp -Value ("{0},{1},{2},{3},{4},{5},{6}" -f $projKey, $projName, $repoSlug, $arch, $openPrs, $warns, $ready)
}

Move-Item -Force -LiteralPath $results_tmp -Destination $OUTPUT_CSV
Write-Host ("[INFO] Wrote precheck CSV: {0}" -f $OUTPUT_CSV)

# if [[ -s "$ready_tmp" ]]; then ...
$ready_count = (Get-Content -LiteralPath $ready_tmp -ErrorAction SilentlyContinue | Measure-Object).Count
if ($ready_count -gt 0) {
  Write-Host ""
  Write-Host "[READY] Repos ready to migrate (no open PRs)✅:"
  Get-Content -LiteralPath $ready_tmp | ForEach-Object { Write-Host (" - {0}" -f $_) }
} else {
  Write-Host ""
  Write-Host "[READY] No repos are currently without open PRs."
}

# total_repos="$(($(wc -l < "$rows_tmp")))"
$total_repos = (Get-Content -LiteralPath $rows_tmp -ErrorAction SilentlyContinue | Measure-Object).Count

# repos_with_warnings="$(awk -F',' 'NR>1 && $6!="" {c++} END{print c+0}' "$OUTPUT_CSV")"
$repos_with_warnings = 0
try {
  $repos_with_warnings = @(Import-Csv -LiteralPath $OUTPUT_CSV | Where-Object { $_.warnings -ne "" }).Count
} catch {
  $repos_with_warnings = 0
}

Write-Host ""
Write-Host ("[SUMMARY] Total repos: {0}" -f $total_repos)
Write-Host ("Open PRs total: {0}" -f $total_open_prs)
Write-Host "======================Completed============================="