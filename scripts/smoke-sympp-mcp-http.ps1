param(
  [string]$Url = "http://127.0.0.1:19998/mcp",
  [switch]$Json,
  [switch]$Bound,
  [string]$TerminalId,
  [string]$RepoRoot,
  [string]$ExpectedSourceRevision,
  [switch]$SkipUnboundTools,
  [switch]$SkipLiveServer,
  [switch]$SkipBound,
  [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

function Get-ContractStringList($Value) {
  @($Value | ForEach-Object {
      if ($null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_)) {
        [string]$_
      }
    })
}

$contractRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) { Join-Path $PSScriptRoot ".." } else { $RepoRoot }
$contractPath = Join-Path ([System.IO.Path]::GetFullPath($contractRoot)) "elixir/priv/symphony_plus_plus/mcp_contract.json"
$ToolSets = (Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json).tool_sets
# Trusted local HTTP lists exactly the contract's tools; reads need no Herdr
# identity, writes do, and owner-gated writes also need ownership.
$ExpectedTools = @(Get-ContractStringList $ToolSets.tools | Sort-Object -Unique)
$ReadTools = Get-ContractStringList $ToolSets.read_tools
$OwnerGatedTools = Get-ContractStringList $ToolSets.owner_gated_tools

# Writes without `_meta.herdr` are refused before any target lookup, so these
# calls change nothing even against a live ledger.
$ExpectedOutsideHerdrWriteCalls = @(
  @{
    name = "dispatch_work_package"
    arguments = @{
      work_request_id = "WR-SMOKE-READ-ONLY"
      work_package_id = "WP-SMOKE-READ-ONLY"
    }
  },
  @{
    name = "set_report"
    arguments = @{
      work_request_id = "WR-SMOKE-READ-ONLY"
      brief = "HTTP smoke"
    }
  }
)

$ExpectedOutsideHerdrWriteReason = "read_only_outside_herdr"

$ExpectedReadCalls = @(
  @{
    name = "read_work_request"
    arguments = @{
      work_request_id = "WR-SMOKE-MISSING-READ"
    }
    allowedReasons = @("not_found")
  },
  @{
    name = "read_work_request"
    arguments = @{
      work_request_id = "WR-SMOKE-MISSING-READ"
      view = "plan"
    }
    allowedReasons = @("not_found")
  },
  @{
    name = "read_work_request"
    arguments = @{
      work_request_id = "WR-SMOKE-MISSING-READ"
      view = "board"
    }
    allowedReasons = @("not_found")
  }
)

$RedactedValue = "<redacted>"
$script:SensitiveValues = [System.Collections.Generic.List[string]]::new()

function New-SmokeResult([string]$Status, [string]$Message, [hashtable]$Data = @{}) {
  $result = [ordered]@{
    status = $Status
    message = $Message
    url = $Url
  }

  foreach ($key in $Data.Keys) {
    $result[$key] = $Data[$key]
  }

  return [pscustomobject]$result
}

function Add-SensitiveValue([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return
  }

  if (-not $script:SensitiveValues.Contains($Value)) {
    [void]$script:SensitiveValues.Add($Value)
  }
}

function Protect-SensitiveText([string]$Text) {
  if ($null -eq $Text) {
    return $null
  }

  $protected = [string]$Text
  foreach ($value in $script:SensitiveValues) {
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $protected = $protected.Replace($value, $RedactedValue)
    }
  }

  return $protected
}

function ConvertTo-RedactedJson($Value) {
  return Protect-SensitiveText ($Value | ConvertTo-Json -Depth 12)
}

function Normalize-SourceRevision([string]$Revision) {
  if ([string]::IsNullOrWhiteSpace($Revision)) {
    return $null
  }

  $normalized = $Revision.Trim().ToLowerInvariant()
  if ($normalized -notmatch "^[0-9a-f]{40}$") {
    throw "Expected source revision must be a 40-character git SHA."
  }

  return $normalized
}

function Get-GitHeadRevision([string]$Root) {
  if ([string]::IsNullOrWhiteSpace($Root)) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "invalid_arguments" "RepoRoot must be non-empty when supplied."
    }
  }

  $fullRoot = [System.IO.Path]::GetFullPath($Root)
  if (-not (Test-Path -LiteralPath $fullRoot -PathType Container)) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "invalid_repo_root" "RepoRoot does not exist: $fullRoot"
    }
  }

  $git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "source_revision_unavailable" "Could not find git to verify the daemon source revision for RepoRoot: $fullRoot"
    }
  }

  $output = @(& $git.Source @("-C", $fullRoot, "rev-parse", "--verify", "HEAD") 2>&1)
  if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "source_revision_unavailable" "Could not resolve git HEAD for RepoRoot: $fullRoot"
    }
  }

  try {
    return [pscustomobject]@{
      ok = $true
      revision = Normalize-SourceRevision ([string]$output[0])
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "source_revision_unavailable" "Git returned an invalid HEAD revision for RepoRoot: $fullRoot"
    }
  }
}

function Resolve-ExpectedSourceRevision {
  if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceRevision)) {
    try {
      return [pscustomobject]@{
        ok = $true
        revision = Normalize-SourceRevision $ExpectedSourceRevision
      }
    } catch {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "invalid_arguments" $_.Exception.Message
      }
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    return Get-GitHeadRevision $RepoRoot
  }

  return [pscustomobject]@{
    ok = $true
    revision = $null
  }
}

function Write-SmokeResult($Result, [int]$ExitCode) {
  if ($Json) {
    ConvertTo-RedactedJson $Result
  }
  elseif ($ExitCode -eq 0) {
    Write-Host (Protect-SensitiveText "OK: $($Result.message)")
    if ($Result.PSObject.Properties["mode"]) {
      Write-Host (Protect-SensitiveText "Mode: $($Result.mode)")
    }
    if ($Result.PSObject.Properties["workPackageId"]) {
      Write-Host (Protect-SensitiveText "WorkPackage: $($Result.workPackageId)")
    }
    if ($Result.PSObject.Properties["daemonSourceRevision"] -and -not [string]::IsNullOrWhiteSpace([string]$Result.daemonSourceRevision)) {
      Write-Host (Protect-SensitiveText "DaemonSourceRevision: $($Result.daemonSourceRevision)")
    }
    if ($Result.PSObject.Properties["tools"]) {
      Write-Host (Protect-SensitiveText "Tools: $($Result.tools -join ', ')")
    }
    if ($Result.PSObject.Properties["resources"]) {
      Write-Host (Protect-SensitiveText "Resources: $($Result.resources -join ', ')")
    }
  }
  else {
    [Console]::Error.WriteLine((Protect-SensitiveText $Result.message))
  }

  exit $ExitCode
}

function ConvertTo-JsonBody([hashtable]$Payload) {
  return $Payload | ConvertTo-Json -Depth 12 -Compress
}

function New-InitializeRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-http-smoke-init"
    method = "initialize"
    params = @{
      protocolVersion = "2025-03-26"
      clientInfo = @{
        name = "sympp-http-smoke"
        version = "0.1.0"
      }
      capabilities = @{}
    }
  }
}

function New-ToolsListRequest {
  return @{
    jsonrpc = "2.0"
    id = "sympp-http-smoke-tools"
    method = "tools/list"
    params = @{}
  }
}

function New-ToolCallRequest([string]$Id, [string]$Name, [hashtable]$Arguments, [hashtable]$Herdr = $null) {
  $params = @{
    name = $Name
    arguments = $Arguments
  }

  # The bridge sends a verified Herdr terminal as `_meta.herdr`; without it a
  # caller is read-only.
  if ($null -ne $Herdr) {
    $params["_meta"] = @{ herdr = $Herdr }
  }

  return @{
    jsonrpc = "2.0"
    id = $Id
    method = "tools/call"
    params = $params
  }
}

function New-SmokeHerdrTerminal([string]$CoreId, [string]$TerminalAddress) {
  return @{
    core_id = $CoreId
    core_name = "sympp-http-smoke"
    terminal_id = $TerminalAddress
    labels = @{}
  }
}

function Get-ResponseHeaderValue($Headers, [string]$Name) {
  if ($null -eq $Headers) {
    return $null
  }

  $rawValue = $null
  if ($Headers -is [System.Net.WebHeaderCollection]) {
    $rawValue = $Headers[$Name]
  }
  elseif ($Headers -is [System.Collections.IDictionary]) {
    foreach ($key in $Headers.Keys) {
      if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rawValue = $Headers[$key]
        break
      }
    }
  }
  else {
    $property = $Headers.PSObject.Properties |
      Where-Object { [string]::Equals($_.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase) } |
      Select-Object -First 1
    if ($property) {
      $rawValue = $property.Value
    }
  }

  foreach ($value in @($rawValue)) {
    if ($null -eq $value) {
      continue
    }

    foreach ($entry in @($value)) {
      foreach ($part in ([string]$entry).Split(",")) {
        $text = $part.Trim()
        if (-not [string]::IsNullOrWhiteSpace($text)) {
          return $text
        }
      }
    }
  }

  return $null
}

function Read-ErrorResponseBody($Response) {
  if ($null -eq $Response) {
    return $null
  }

  try {
    if ($Response.PSObject.Methods["GetResponseStream"]) {
      $stream = $Response.GetResponseStream()
      if ($null -eq $stream) {
        return $null
      }

      $reader = [System.IO.StreamReader]::new($stream)
      try {
        return $reader.ReadToEnd()
      }
      finally {
        $reader.Dispose()
      }
    }

    if ($Response.PSObject.Properties["Content"] -and $Response.Content) {
      return $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
  }
  catch {
    return $null
  }

  return $null
}

function Invoke-McpPost([string]$TargetUrl, [hashtable]$Payload, [string]$SessionId) {
  $headers = @{
    Accept = "application/json"
  }

  if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
    $headers["Mcp-Session-Id"] = [string]$SessionId
  }

  try {
    $response = Invoke-WebRequest `
      -Uri $TargetUrl `
      -Method Post `
      -Headers $headers `
      -ContentType "application/json" `
      -Body (ConvertTo-JsonBody $Payload) `
      -TimeoutSec 10 `
      -UseBasicParsing `
      -ErrorAction Stop

    return [pscustomobject]@{
      ok = $true
      statusCode = [int]$response.StatusCode
      headers = $response.Headers
      content = [string]$response.Content
      error = $null
    }
  }
  catch {
    $response = $_.Exception.Response
    $statusCode = $null
    if ($null -ne $response) {
      try {
        $statusCode = [int]$response.StatusCode
      }
      catch {
        $statusCode = $null
      }
    }

    return [pscustomobject]@{
      ok = $false
      statusCode = $statusCode
      headers = if ($null -ne $response) { $response.Headers } else { $null }
      content = Read-ErrorResponseBody $response
      error = $_.Exception.Message
    }
  }
}

function ConvertFrom-JsonResponse([string]$Content, [string]$Stage) {
  if ([string]::IsNullOrWhiteSpace($Content)) {
    throw "$Stage returned an empty response body."
  }

  try {
    return $Content | ConvertFrom-Json
  }
  catch {
    throw "$Stage returned non-JSON response: $($_.Exception.Message)"
  }
}

function Get-JsonRpcErrorMessage($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["error"]) {
    return $null
  }

  $reason = Get-JsonRpcErrorReason $Payload
  $errorObject = $Payload.error
  if ($reason) {
    return "$($errorObject.message): $reason"
  }

  return [string]$errorObject.message
}

function Get-JsonRpcErrorReason($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["error"]) {
    return $null
  }

  # Tool errors name their reason in data.code; transport errors in data.reason.
  $errorObject = $Payload.error
  if ($errorObject.PSObject.Properties["data"] -and $errorObject.data.PSObject.Properties["code"]) {
    return [string]$errorObject.data.code
  }
  if ($errorObject.PSObject.Properties["data"] -and $errorObject.data.PSObject.Properties["reason"]) {
    return [string]$errorObject.data.reason
  }

  return $null
}

function Get-ResponseErrorDetail($Response, [string]$Fallback) {
  if (-not [string]::IsNullOrWhiteSpace($Response.content)) {
    try {
      $payload = $Response.content | ConvertFrom-Json
      $jsonRpcError = Get-JsonRpcErrorMessage $payload
      if (-not [string]::IsNullOrWhiteSpace($jsonRpcError)) {
        return $jsonRpcError
      }
    }
    catch {
      return $Response.content
    }
  }

  return $Fallback
}

function New-PortOwner([int]$ProcessId, [string]$LocalAddress) {
  $processName = "<unknown>"
  try {
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($process.ProcessName)) {
      $processName = [string]$process.ProcessName
    }
  }
  catch {
  }

  return [pscustomobject]@{
    pid = $ProcessId
    process = $processName
    localAddress = $LocalAddress
  }
}

function Add-PortOwner($Owners, $Seen, [int]$ProcessId, [string]$LocalAddress) {
  $key = "$ProcessId|$LocalAddress"
  if ($Seen.Contains($key)) {
    return
  }

  [void]$Seen.Add($key)
  [void]$Owners.Add((New-PortOwner $ProcessId $LocalAddress))
}

function Get-TcpPortOwners([int]$Port) {
  $owners = [System.Collections.Generic.List[object]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new()

  if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    try {
      $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
      foreach ($connection in $connections) {
        $processId = [int]$connection.OwningProcess
        if ($processId -gt 0) {
          Add-PortOwner $owners $seen $processId ([string]$connection.LocalAddress)
        }
      }
    }
    catch {
    }
  }

  if ($owners.Count -eq 0 -and (Get-Command netstat -ErrorAction SilentlyContinue)) {
    try {
      $escapedPort = [regex]::Escape([string]$Port)
      foreach ($line in @(& netstat -ano -p tcp 2>$null)) {
        if ($line -match "^\s*TCP\s+(.+):$escapedPort\s+\S+\s+LISTENING\s+(\d+)\s*$") {
          Add-PortOwner $owners $seen ([int]$matches[2]) $matches[1].Trim()
        }
      }
    }
    catch {
    }
  }

  return @($owners)
}

function Format-PortOwners([object[]]$Owners) {
  return (@($Owners) | ForEach-Object {
      "pid=$($_.pid) process=$($_.process) localAddress=$($_.localAddress)"
    }) -join "; "
}

function Get-EndpointPortOwnership([string]$TargetUrl) {
  try {
    $uri = [System.Uri]::new($TargetUrl)
  }
  catch {
    return $null
  }

  if (-not $uri.IsLoopback) {
    return $null
  }

  $port = [int]$uri.Port
  $owners = @(Get-TcpPortOwners $port)
  if ($owners.Count -eq 0) {
    return $null
  }

  return [pscustomobject]@{
    port = $port
    owners = $owners
    summary = Format-PortOwners $owners
  }
}

function Test-ConnectionRefusedError([string]$Message) {
  if ([string]::IsNullOrWhiteSpace($Message)) {
    return $false
  }

  $normalized = $Message.ToLowerInvariant()
  return (
    $normalized.Contains("actively refused") -or
    $normalized.Contains("connection refused") -or
    $normalized.Contains("no connection could be made") -or
    $normalized.Contains("unable to connect") -or
    $normalized.Contains("failed to connect")
  )
}

function Get-ToolNames($ToolsPayload) {
  $tools = $ToolsPayload.result.tools
  if ($null -eq $tools) {
    return @()
  }

  return @($tools | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
}

function Get-HealthSourceRevision($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    return $null
  }

  $structuredContent = $Payload.result.structuredContent
  if ($null -eq $structuredContent -or -not $structuredContent.PSObject.Properties["source"]) {
    return $null
  }

  $source = $structuredContent.source
  if ($null -eq $source -or -not $source.PSObject.Properties["revision"]) {
    return $null
  }

  try {
    return Normalize-SourceRevision ([string]$source.revision)
  } catch {
    return $null
  }
}

function Get-HealthCallerAccess($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    return $null
  }

  $structuredContent = $Payload.result.structuredContent
  if ($null -eq $structuredContent -or -not $structuredContent.PSObject.Properties["caller"]) {
    return $null
  }

  $caller = $structuredContent.caller
  if ($null -eq $caller -or -not $caller.PSObject.Properties["access"]) {
    return $null
  }

  return [string]$caller.access
}

function Test-NonEmptyString($Value) {
  return $null -ne $Value -and -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function Test-HealthLedgerIdentity($Payload) {
  if ($null -eq $Payload -or -not $Payload.PSObject.Properties["result"]) {
    return [pscustomobject]@{ ok = $false; reason = "missing_result" }
  }

  $structuredContent = $Payload.result.structuredContent
  if ($null -eq $structuredContent -or -not $structuredContent.PSObject.Properties["ledger"]) {
    return [pscustomobject]@{ ok = $false; reason = "missing_ledger" }
  }

  $ledger = $structuredContent.ledger
  if ($null -eq $ledger -or -not $ledger.PSObject.Properties["identity"]) {
    return [pscustomobject]@{ ok = $false; reason = "missing_ledger_identity" }
  }

  $identity = $ledger.identity
  if ($null -eq $identity -or -not (Test-NonEmptyString $identity.kind) -or -not (Test-NonEmptyString $identity.source)) {
    return [pscustomobject]@{ ok = $false; reason = "incomplete_ledger_identity" }
  }

  $kind = [string]$identity.kind
  if ($kind -eq "sqlite" -and -not (Test-NonEmptyString $identity.display_path)) {
    return [pscustomobject]@{ ok = $false; reason = "missing_sqlite_display_path" }
  }

  if ($kind -eq "server" -and -not (Test-NonEmptyString $identity.endpoint)) {
    return [pscustomobject]@{ ok = $false; reason = "missing_server_endpoint" }
  }

  return [pscustomobject]@{ ok = $true; reason = $null }
}

function Invoke-HealthSmoke([string]$SessionId, [string]$ExpectedRevision) {
  $healthResponse = Invoke-McpPost $Url (New-ToolCallRequest "sympp-http-smoke-health" "sympp.health" @{}) $SessionId
  if (-not $healthResponse.ok) {
    $reason = if ($healthResponse.statusCode) { "HTTP $($healthResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $healthResponse $healthResponse.error
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "health_failed" "MCP sympp.health failed with initialized session ($reason): $detail"
    }
  }

  $sessionCheck = Test-ResponseSessionHeader $healthResponse $SessionId "sympp.health"
  if (-not $sessionCheck.ok) {
    return $sessionCheck
  }

  $healthPayload = ConvertFrom-JsonResponse $healthResponse.content "sympp.health"
  $healthError = Get-JsonRpcErrorMessage $healthPayload
  if ($healthError) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "health_failed" "MCP sympp.health returned JSON-RPC error: $healthError"
    }
  }

  $actualRevision = Get-HealthSourceRevision $healthPayload
  if (-not [string]::IsNullOrWhiteSpace($ExpectedRevision)) {
    if ([string]::IsNullOrWhiteSpace($actualRevision)) {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "stale_or_unverified_daemon" "MCP daemon did not report a source revision. Restart the local sympp cockpit from the current checkout and rerun smoke." @{
          expectedSourceRevision = $ExpectedRevision
        }
      }
    }

    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($actualRevision, $ExpectedRevision)) {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "stale_daemon_source_revision_mismatch" "MCP daemon source revision does not match the expected checkout. Restart the local sympp cockpit and rerun smoke." @{
          expectedSourceRevision = $ExpectedRevision
          daemonSourceRevision = $actualRevision
        }
      }
    }
  }

  $identityCheck = Test-HealthLedgerIdentity $healthPayload
  if (-not $identityCheck.ok) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "health_ledger_identity_missing" "MCP sympp.health did not report a complete safe ledger identity ($($identityCheck.reason))."
    }
  }

  $callerAccess = Get-HealthCallerAccess $healthPayload
  if ($callerAccess -ne "read_only") {
    $actual = if ([string]::IsNullOrWhiteSpace($callerAccess)) { "<missing>" } else { $callerAccess }
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "health_caller_access_unexpected" "MCP sympp.health without a Herdr terminal must report caller.access=read_only; got $actual."
    }
  }

  return [pscustomobject]@{
    ok = $true
    sourceRevision = $actualRevision
  }
}

function Initialize-HealthyMcpSession([bool]$RedactSessionId) {
  $expectedRevision = Resolve-ExpectedSourceRevision
  if (-not $expectedRevision.ok) {
    return [pscustomobject]@{
      ok = $false
      result = $expectedRevision.result
    }
  }

  $init = Invoke-InitializeSession $RedactSessionId
  if (-not $init.ok) {
    return [pscustomobject]@{
      ok = $false
      result = $init.result
    }
  }

  $health = Invoke-HealthSmoke $init.sessionId $expectedRevision.revision
  if (-not $health.ok) {
    return [pscustomobject]@{
      ok = $false
      result = $health.result
    }
  }

  return [pscustomobject]@{
    ok = $true
    sessionId = $init.sessionId
    expectedRevision = $expectedRevision.revision
    sourceRevision = $health.sourceRevision
  }
}

function Test-ResponseSessionHeader($Response, [string]$ExpectedSessionId, [string]$Stage) {
  $actualSessionId = Get-ResponseHeaderValue $Response.headers "Mcp-Session-Id"
  if ($actualSessionId -ne $ExpectedSessionId) {
    $actual = if ([string]::IsNullOrWhiteSpace($actualSessionId)) { "<missing>" } else { $actualSessionId }
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "session_id_mismatch" "MCP $Stage did not echo the expected Mcp-Session-Id. expected=$ExpectedSessionId actual=$actual"
    }
  }

  return [pscustomobject]@{ ok = $true }
}

function Resolve-BoundSmokeConfig([bool]$UseBound, [string]$Terminal) {
  if (-not $UseBound) {
    if (-not [string]::IsNullOrWhiteSpace($Terminal)) {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "invalid_arguments" "-TerminalId requires -Bound. Run without -Bound for the read-only smoke."
      }
    }

    return [pscustomobject]@{ ok = $true; bound = $false }
  }

  $terminal = if ([string]::IsNullOrWhiteSpace($Terminal)) { "sympp-http-smoke" } else { $Terminal.Trim() }

  return [pscustomobject]@{
    ok = $true
    bound = $true
    terminalId = $terminal
  }
}

function Invoke-InitializeSession([bool]$RedactSessionId) {
  $initResponse = Invoke-McpPost $Url (New-InitializeRequest) $null
  if (-not $initResponse.ok) {
    if ($initResponse.statusCode) {
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "initialize_failed" "MCP initialize failed with HTTP $($initResponse.statusCode): $($initResponse.error)"
      }
    }

    $ownership = Get-EndpointPortOwnership $Url
    if ($ownership) {
      $status = if (Test-ConnectionRefusedError $initResponse.error) { "endpoint_unreachable_port_occupied" } else { "endpoint_unreachable_listener_unresponsive" }
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult $status "Could not initialize local MCP endpoint at $Url; a loopback listener is present on port $($ownership.port) ($($ownership.summary)), but initialize failed: $($initResponse.error)" @{
          port = $ownership.port
          portOwners = $ownership.owners
        }
      }
    }

    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "endpoint_unreachable" "Could not reach local MCP endpoint at $Url`: $($initResponse.error)"
    }
  }

  $initPayload = ConvertFrom-JsonResponse $initResponse.content "initialize"
  $initError = Get-JsonRpcErrorMessage $initPayload
  if ($initError) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "initialize_failed" "MCP initialize failed: $initError"
    }
  }

  $sessionId = Get-ResponseHeaderValue $initResponse.headers "Mcp-Session-Id"
  if ([string]::IsNullOrWhiteSpace($sessionId)) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "missing_session_id" "MCP initialize succeeded but did not return Mcp-Session-Id."
    }
  }

  if ($RedactSessionId) {
    Add-SensitiveValue $sessionId
  }

  return [pscustomobject]@{
    ok = $true
    sessionId = $sessionId
    payload = $initPayload
  }
}

function Invoke-ToolsListSmoke([string]$SessionId, [string[]]$Expected) {
  $toolsResponse = Invoke-McpPost $Url (New-ToolsListRequest) $SessionId
  if (-not $toolsResponse.ok) {
    $reason = if ($toolsResponse.statusCode) { "HTTP $($toolsResponse.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $toolsResponse $toolsResponse.error
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "tools_list_failed" "MCP tools/list failed ($reason): $detail"
    }
  }

  $sessionCheck = Test-ResponseSessionHeader $toolsResponse $SessionId "tools/list"
  if (-not $sessionCheck.ok) {
    return $sessionCheck
  }

  $toolsPayload = ConvertFrom-JsonResponse $toolsResponse.content "tools/list"
  $toolsError = Get-JsonRpcErrorMessage $toolsPayload
  if ($toolsError) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "tools_list_failed" "MCP tools/list returned JSON-RPC error: $toolsError"
    }
  }

  $toolNames = Get-ToolNames $toolsPayload
  $missingTools = @($Expected | Where-Object { $toolNames -notcontains $_ })
  if ($missingTools.Count -gt 0) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "missing_expected_tools" "MCP tools/list is missing contract tools: $($missingTools -join ', ')." @{
        tools = $toolNames
        missingTools = $missingTools
      }
    }
  }

  $unexpectedTools = @($toolNames | Where-Object { $Expected -notcontains $_ })
  if ($unexpectedTools.Count -gt 0) {
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "unexpected_tools" "MCP tools/list exposed tools outside the published contract: $($unexpectedTools -join ', ')." @{
        tools = $toolNames
        unexpectedTools = $unexpectedTools
      }
    }
  }

  return [pscustomobject]@{
    ok = $true
    tools = $toolNames
    payload = $toolsPayload
  }
}

function Invoke-SmokeToolCall([string]$SessionId, [string]$Id, [string]$Name, [hashtable]$Arguments, [hashtable]$Herdr, [string]$Stage) {
  $response = Invoke-McpPost $Url (New-ToolCallRequest $Id $Name $Arguments $Herdr) $SessionId
  if (-not $response.ok) {
    $reason = if ($response.statusCode) { "HTTP $($response.statusCode)" } else { "request failed" }
    $detail = Get-ResponseErrorDetail $response $response.error
    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "tool_call_failed" "MCP $Stage failed transport validation ($reason): $detail"
    }
  }

  $sessionCheck = Test-ResponseSessionHeader $response $SessionId $Stage
  if (-not $sessionCheck.ok) {
    return $sessionCheck
  }

  $payload = ConvertFrom-JsonResponse $response.content $Stage
  return [pscustomobject]@{
    ok = $true
    payload = $payload
    reason = Get-JsonRpcErrorReason $payload
    error = Get-JsonRpcErrorMessage $payload
  }
}

function Invoke-OutsideHerdrWriteSmoke([string]$SessionId) {
  $refusedTools = @()
  foreach ($call in $ExpectedOutsideHerdrWriteCalls) {
    $toolName = [string]$call.name
    $stage = "write $toolName without a Herdr terminal"
    $result = Invoke-SmokeToolCall $SessionId "sympp-http-smoke-read-only-$toolName" $toolName $call.arguments $null $stage
    if (-not $result.ok) {
      return $result
    }

    if ($result.reason -ne $ExpectedOutsideHerdrWriteReason) {
      $detail = if ([string]::IsNullOrWhiteSpace($result.error)) { "call unexpectedly succeeded" } else { $result.error }
      return [pscustomobject]@{
        ok = $false
        result = New-SmokeResult "outside_herdr_write_not_refused" "MCP $stage was not refused as read-only: $detail" @{
          tool = $toolName
          reason = $result.reason
        }
      }
    }

    $refusedTools += $toolName
  }

  return [pscustomobject]@{
    ok = $true
    refusedTools = $refusedTools
  }
}

function Invoke-ReadSmoke([string]$SessionId) {
  $readTools = @()
  foreach ($call in $ExpectedReadCalls) {
    $toolName = [string]$call.name
    $stage = "read $toolName"
    $result = Invoke-SmokeToolCall $SessionId "sympp-http-smoke-read-$toolName" $toolName $call.arguments $null $stage
    if (-not $result.ok) {
      return $result
    }

    if ([string]::IsNullOrWhiteSpace($result.reason)) {
      if (-not [string]::IsNullOrWhiteSpace($result.error)) {
        return [pscustomobject]@{
          ok = $false
          result = New-SmokeResult "read_failed" "MCP $stage returned a JSON-RPC error without a reason: $($result.error)" @{
            tool = $toolName
            reason = $null
          }
        }
      }

      $readTools += "${toolName}:ok"
      continue
    }

    $allowedReasons = @($call.allowedReasons)
    if ($allowedReasons -contains $result.reason) {
      $readTools += "${toolName}:$($result.reason)"
      continue
    }

    return [pscustomobject]@{
      ok = $false
      result = New-SmokeResult "read_failed" "MCP $stage returned an unexpected error: $($result.error)" @{
        tool = $toolName
        reason = $result.reason
      }
    }
  }

  return [pscustomobject]@{
    ok = $true
    readTools = $readTools
  }
}

function Invoke-McpSmoke {
  $session = Initialize-HealthyMcpSession $false
  if (-not $session.ok) {
    return $session.result
  }

  if ($SkipUnboundTools) {
    return New-SmokeResult "ok" "Local sympp HTTP MCP daemon is initialized and passed health/source checks." @{
      mode = "unbound_health"
      sessionId = $session.sessionId
      daemonSourceRevision = $session.sourceRevision
      expectedSourceRevision = $session.expectedRevision
    }
  }

  $toolsCheck = Invoke-ToolsListSmoke $session.sessionId $ExpectedTools
  if (-not $toolsCheck.ok) {
    return $toolsCheck.result
  }

  $reads = Invoke-ReadSmoke $session.sessionId
  if (-not $reads.ok) {
    return $reads.result
  }

  $outsideHerdr = Invoke-OutsideHerdrWriteSmoke $session.sessionId
  if (-not $outsideHerdr.ok) {
    return $outsideHerdr.result
  }

  return New-SmokeResult "ok" "Local sympp HTTP MCP daemon is initialized, lists the contract tools, serves reads and refuses writes outside Herdr." @{
    sessionId = $session.sessionId
    daemonSourceRevision = $session.sourceRevision
    expectedSourceRevision = $session.expectedRevision
    tools = $toolsCheck.tools
    readTools = $reads.readTools
    outsideHerdrRefusedTools = $outsideHerdr.refusedTools
  }
}

# Writes to the target ledger: creates one smoke WorkRequest owned by a fake
# Herdr terminal on a core the factory cannot see, then checks that a second
# terminal is refused and the owner can keep writing.
function Invoke-BoundMcpSmoke($Config) {
  $session = Initialize-HealthyMcpSession $true
  if (-not $session.ok) {
    return $session.result
  }

  $tools = @()
  $readTools = @()
  $refusedTools = @()
  if (-not $SkipUnboundTools) {
    $toolsCheck = Invoke-ToolsListSmoke $session.sessionId $ExpectedTools
    if (-not $toolsCheck.ok) {
      return $toolsCheck.result
    }

    $reads = Invoke-ReadSmoke $session.sessionId
    if (-not $reads.ok) {
      return $reads.result
    }

    $outsideHerdr = Invoke-OutsideHerdrWriteSmoke $session.sessionId
    if (-not $outsideHerdr.ok) {
      return $outsideHerdr.result
    }

    $tools = $toolsCheck.tools
    $readTools = $reads.readTools
    $refusedTools = $outsideHerdr.refusedTools
  }

  $coreId = "sympp-http-smoke-" + [guid]::NewGuid().ToString("N")
  $owner = New-SmokeHerdrTerminal $coreId $Config.terminalId
  $other = New-SmokeHerdrTerminal $coreId ($Config.terminalId + "-other")

  $create = Invoke-SmokeToolCall $session.sessionId "sympp-http-smoke-create" "create_work_request" @{
    repo = "nextide/sympp-http-smoke"
    base_branch = "main"
    title = "HTTP smoke ownership"
    request_kind = "investigation"
    description = "Created by the sympp HTTP smoke to check Herdr ownership."
  } $owner "create_work_request as a Herdr terminal"
  if (-not $create.ok) {
    return $create.result
  }

  if ($create.error) {
    return New-SmokeResult "create_work_request_failed" "MCP create_work_request as a Herdr terminal returned JSON-RPC error: $($create.error)"
  }

  $workRequestId = [string]$create.payload.result.structuredContent.work_request.id
  $workedOn = $create.payload.result.structuredContent.worked_on
  if ([string]::IsNullOrWhiteSpace($workRequestId) -or $null -eq $workedOn) {
    return New-SmokeResult "create_work_request_not_owned" "MCP create_work_request did not return the new WorkRequest with the caller as its owner."
  }

  $refused = Invoke-SmokeToolCall $session.sessionId "sympp-http-smoke-other-terminal" "set_report" @{
    work_request_id = $workRequestId
    brief = "Second terminal"
  } $other "set_report from a second Herdr terminal"
  if (-not $refused.ok) {
    return $refused.result
  }

  if ($refused.reason -ne "owned_by_other_terminal") {
    $detail = if ([string]::IsNullOrWhiteSpace($refused.error)) { "call unexpectedly succeeded" } else { $refused.error }
    return New-SmokeResult "second_terminal_not_refused" "MCP set_report from a second terminal was not refused as owned_by_other_terminal: $detail" @{
      reason = $refused.reason
    }
  }

  $refusedData = $refused.payload.error.data
  if ([string]::IsNullOrWhiteSpace([string]$refusedData.owner.address) -or [string]::IsNullOrWhiteSpace([string]$refusedData.next_action)) {
    return New-SmokeResult "ownership_refusal_incomplete" "MCP owned_by_other_terminal did not name the owner address and next action."
  }

  $ownerWrite = Invoke-SmokeToolCall $session.sessionId "sympp-http-smoke-owner-write" "set_report" @{
    work_request_id = $workRequestId
    brief = "HTTP smoke owner write"
  } $owner "set_report from the owner"
  if (-not $ownerWrite.ok) {
    return $ownerWrite.result
  }

  if ($ownerWrite.error) {
    return New-SmokeResult "owner_write_failed" "MCP set_report from the owning terminal returned JSON-RPC error: $($ownerWrite.error)"
  }

  $data = @{
    mode = "herdr_ownership"
    terminalId = $Config.terminalId
    sessionId = $RedactedValue
    sessionIdRedacted = $true
    daemonSourceRevision = $session.sourceRevision
    expectedSourceRevision = $session.expectedRevision
    workRequestId = $workRequestId
    owner = [string]$workedOn.address
    refusedOwnerAddress = [string]$refusedData.owner.address
  }

  if (-not $SkipUnboundTools) {
    $data["tools"] = $tools
    $data["readTools"] = $readTools
    $data["outsideHerdrRefusedTools"] = $refusedTools
  }

  return New-SmokeResult "ok" "Local sympp HTTP MCP daemon gave the smoke WorkRequest to its creating terminal and refused a second terminal." $data
}

function Invoke-SelfTest {
  $dictionary = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $dictionary["Mcp-Session-Id"] = @("state-key-one", "ignored")
  $normalized = Get-ResponseHeaderValue $dictionary "mcp-session-id"
  if ($normalized -ne "state-key-one") {
    throw "Expected first header-array value to be used, got '$normalized'."
  }

  $customHeaders = [pscustomobject]@{
    "mcp-session-id" = @("state-key-two")
  }
  $normalized = Get-ResponseHeaderValue $customHeaders "Mcp-Session-Id"
  if ($normalized -ne "state-key-two") {
    throw "Expected PSCustomObject header value to be used, got '$normalized'."
  }

  if ((Get-ResponseHeaderValue @{} "Mcp-Session-Id") -ne $null) {
    throw "Expected missing header to normalize to null."
  }

  $webHeaders = [System.Net.WebHeaderCollection]::new()
  $webHeaders.Add("Mcp-Session-Id", "state-key-three")
  $normalized = Get-ResponseHeaderValue $webHeaders "mcp-session-id"
  if ($normalized -ne "state-key-three") {
    throw "Expected WebHeaderCollection header value to be used, got '$normalized'."
  }

  $duplicateWebHeaders = [System.Net.WebHeaderCollection]::new()
  $duplicateWebHeaders.Add("Mcp-Session-Id", "state-key-four")
  $duplicateWebHeaders.Add("Mcp-Session-Id", "ignored")
  $normalized = Get-ResponseHeaderValue $duplicateWebHeaders "Mcp-Session-Id"
  if ($normalized -ne "state-key-four") {
    throw "Expected first duplicated WebHeaderCollection value to be used, got '$normalized'."
  }

  $sessionCheck = Test-ResponseSessionHeader ([pscustomobject]@{ headers = @{ "Mcp-Session-Id" = "expected-session" } }) "expected-session" "self-test"
  if (-not $sessionCheck.ok) {
    throw "Expected matching session header to pass continuity validation."
  }

  $sessionCheck = Test-ResponseSessionHeader ([pscustomobject]@{ headers = @{ "Mcp-Session-Id" = "rotated-session" } }) "expected-session" "self-test"
  if ($sessionCheck.ok -or $sessionCheck.result.status -ne "session_id_mismatch") {
    throw "Expected mismatched session header to fail continuity validation."
  }

  foreach ($tool in @("sympp.health", "create_work_request", "set_report", "read_work_request", "dispatch_work_package")) {
    if ($ExpectedTools -notcontains $tool) {
      throw "Expected the published contract to list $tool."
    }
  }

  if ($ReadTools -notcontains "read_work_request" -or $ReadTools -contains "set_report") {
    throw "Expected the contract's read tools to include reads and exclude writes."
  }

  foreach ($call in $ExpectedOutsideHerdrWriteCalls) {
    if ($ReadTools -contains [string]$call.name -or $ExpectedTools -notcontains [string]$call.name) {
      throw "Expected outside-Herdr write smoke calls to be listed write tools."
    }
  }

  foreach ($call in $ExpectedReadCalls) {
    if ($ReadTools -notcontains [string]$call.name) {
      throw "Expected read smoke calls to be contract read tools."
    }
  }

  if ($OwnerGatedTools -notcontains "set_report" -or $OwnerGatedTools -contains "create_work_request") {
    throw "Expected set_report to be owner-gated and create_work_request not."
  }

  $request = New-ToolCallRequest "self-test" "set_report" @{ work_request_id = "WR" } (New-SmokeHerdrTerminal "core" "t1")
  if ($request.params._meta.herdr.terminal_id -ne "t1" -or $request.params._meta.herdr.core_id -ne "core") {
    throw "Expected Herdr smoke calls to carry _meta.herdr."
  }

  $anonymous = New-ToolCallRequest "self-test" "read_work_request" @{ work_request_id = "WR" }
  if ($anonymous.params.ContainsKey("_meta")) {
    throw "Expected calls outside Herdr to carry no _meta."
  }

  $healthPayload = @{
    result = @{
      structuredContent = @{
        source = @{
          revision = "ABCDEF1234567890ABCDEF1234567890ABCDEF12"
        }
        caller = @{
          access = "read_only"
        }
      }
    }
  } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  if ((Get-HealthSourceRevision $healthPayload) -ne "abcdef1234567890abcdef1234567890abcdef12") {
    throw "Expected health source revision extraction to normalize daemon revisions."
  }

  if ((Get-HealthCallerAccess $healthPayload) -ne "read_only") {
    throw "Expected health caller access extraction to read caller.access."
  }

  $missingSourcePayload = @{ result = @{ structuredContent = @{} } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  if ($null -ne (Get-HealthSourceRevision $missingSourcePayload)) {
    throw "Expected missing health source revision to normalize to null."
  }

  if ($null -ne (Get-HealthCallerAccess $missingSourcePayload)) {
    throw "Expected missing health caller to normalize to null."
  }

  $jsonRpcErrorWithoutReason = @{
    error = @{
      message = "synthetic bridge error"
    }
  } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  if ($null -ne (Get-JsonRpcErrorReason $jsonRpcErrorWithoutReason)) {
    throw "Expected JSON-RPC errors without data.reason to normalize to a null reason."
  }
  if ((Get-JsonRpcErrorMessage $jsonRpcErrorWithoutReason) -ne "synthetic bridge error") {
    throw "Expected JSON-RPC errors without data.reason to preserve their message."
  }

  if ((Normalize-SourceRevision "0123456789ABCDEF0123456789ABCDEF01234567") -ne "0123456789abcdef0123456789abcdef01234567") {
    throw "Expected source revision normalization to lower-case valid git SHAs."
  }

  $invalidRevisionThrew = $false
  try {
    [void](Normalize-SourceRevision "not-a-sha")
  } catch {
    $invalidRevisionThrew = $true
  }
  if (-not $invalidRevisionThrew) {
    throw "Expected invalid source revisions to fail validation."
  }

  $script:SensitiveValues.Clear()
  Add-SensitiveValue "secret-value-for-self-test"
  Add-SensitiveValue "session-for-self-test"
  $redactedJson = ConvertTo-RedactedJson (New-SmokeResult "ok" "secret-value-for-self-test session-for-self-test" @{
      secret = "secret-value-for-self-test"
      sessionId = "session-for-self-test"
    })
  if ($redactedJson -match "secret-value-for-self-test" -or $redactedJson -match "session-for-self-test") {
    throw "Expected JSON smoke output redaction to remove raw secret and session values."
  }

  if ($redactedJson -notmatch [regex]::Escape($RedactedValue)) {
    throw "Expected JSON smoke output redaction marker to be present."
  }

  $resolved = Resolve-BoundSmokeConfig $true "t-self-test"
  if (-not $resolved.ok -or $resolved.terminalId -ne "t-self-test") {
    throw "Expected bound smoke argument resolution to accept a terminal id."
  }

  $defaultTerminal = Resolve-BoundSmokeConfig $true ""
  if (-not $defaultTerminal.ok -or $defaultTerminal.terminalId -ne "sympp-http-smoke") {
    throw "Expected bound smoke argument resolution to default the terminal id."
  }

  $script:SkipUnboundTools = $true
  try {
    $unboundSkip = Resolve-BoundSmokeConfig $false ""
    if (-not $unboundSkip.ok -or $unboundSkip.bound) {
      throw "Expected -SkipUnboundTools without -Bound to remain a valid health/source smoke."
    }
  }
  finally {
    $script:SkipUnboundTools = $false
  }

  $unexpectedBoundArgument = Resolve-BoundSmokeConfig $false "t-self-test"
  if ($unexpectedBoundArgument.ok -or $unexpectedBoundArgument.result.status -ne "invalid_arguments") {
    throw "Expected -TerminalId without -Bound to fail validation."
  }

  return New-SmokeResult "ok" "PowerShell header normalization, source revision, redaction, and bound argument validation self-test passed."
}

function Invoke-StaticSmokeValidation {
  [void](Invoke-SelfTest)
  return New-SmokeResult "ok" "Static sympp MCP contract, source revision, redaction, and bound argument validation passed; live server probe skipped."
}

try {
  if ($SelfTest) {
    Write-SmokeResult (Invoke-SelfTest) 0
  }

  $config = Resolve-BoundSmokeConfig ([bool]($Bound -and -not $SkipBound)) $TerminalId
  if (-not $config.ok) {
    Write-SmokeResult $config.result 1
  }

  if ($SkipLiveServer) {
    Write-SmokeResult (Invoke-StaticSmokeValidation) 0
  }

  $result = if ($config.bound) { Invoke-BoundMcpSmoke $config } else { Invoke-McpSmoke }
  $exitCode = if ($result.status -eq "ok") { 0 } else { 1 }
  Write-SmokeResult $result $exitCode
}
catch {
  $result = New-SmokeResult "script_error" $_.Exception.Message
  Write-SmokeResult $result 1
}
