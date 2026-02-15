param(
    [string]$ScenarioName = "cluster-fault",
    [string]$ReportPrefix = "cluster-fault",
    [string]$Node1Id = "00000000-0000-0000-0000-000000000701",
    [string]$Node2Id = "00000000-0000-0000-0000-000000000702",
    [int]$Node1Port = 7601,
    [int]$Node2Port = 7602,
    [string]$Node1Trace = "demo-traces/cluster-fault-node1.trace.jsonl",
    [string]$Node2Trace = "demo-traces/cluster-fault-node2.trace.jsonl",
    [int]$NodeSteps = 260,
    [int]$ReplaySteps = 320,
    [int]$IdleSleepMs = 10,
    [int]$StartupWaitMs = 1500,
    [int]$BootstrapBurst = 3,
    [ValidateSet("node1", "node2")]
    [string]$FaultTarget = "node2",
    [Alias("FaultDelaySteps")]
    [int]$Node2FaultDelaySteps = 2,
    [Alias("FaultReorderWindow")]
    [int]$Node2FaultReorderWindow = 2,
    [Alias("FaultDropEvery")]
    [int]$Node2FaultDropEvery = 0,
    [int]$StartupTimeoutSec = 20,
    [int]$ShutdownTimeoutSec = 90,
    [string]$ScenarioReportPath = "",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Wait-TcpPort {
    param(
        [string]$Hostname,
        [int]$Port,
        [int]$TimeoutSec = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $client.BeginConnect($Hostname, $Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(300)) {
                $client.EndConnect($iar)
                return
            }
        }
        catch {
            # Keep waiting.
        }
        finally {
            $client.Close()
        }
        Start-Sleep -Milliseconds 200
    }

    throw ("Timed out waiting for TCP {0}:{1}" -f $Hostname, $Port)
}

function Wait-NodeProcess {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [int]$TimeoutSec
    )

    if (-not $Process.HasExited) {
        try {
            Wait-Process -Id $Process.Id -Timeout $TimeoutSec -ErrorAction Stop
        }
        catch {
            $live = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
            if ($null -ne $live) {
                throw
            }
        }
    }

    $Process.Refresh()
    if ($Process.HasExited -and $Process.ExitCode -ne 0) {
        throw ("{0} exited with non-zero code {1}" -f $Name, $Process.ExitCode)
    }
}

function Invoke-ReplayCheck {
    param(
        [string]$RuntimeExe,
        [string]$NodeId,
        [string]$TracePath,
        [int]$ReplaySteps,
        [string[]]$ExtraArgs = @()
    )

    $args = @(
        "--replay",
        "--node-id", $NodeId,
        "--trace", $TracePath,
        "--steps", $ReplaySteps.ToString()
    ) + $ExtraArgs

    Write-Host ("Replay check: node={0} trace={1}" -f $NodeId, $TracePath)
    & $RuntimeExe @args | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw ("Replay check failed for {0}" -f $TracePath)
    }
}

function Get-ActionName {
    param($ActionObj)

    if ($ActionObj -is [string]) {
        return $ActionObj
    }

    $prop = $ActionObj.PSObject.Properties | Select-Object -First 1
    if ($null -eq $prop) {
        return "<unknown>"
    }
    return $prop.Name
}

function Format-IssueSummary {
    param($Issue)

    if ($null -eq $Issue) {
        return "issue=<none>"
    }

    return ("code={0} seq={1} node={2} actor={3} msg_id={4} message={5}" -f `
            $Issue.code, $Issue.seq, $Issue.node, $Issue.actor, $Issue.msg_id, $Issue.message)
}

function Invoke-VerifyWithDiagnostics {
    param(
        [string]$ToolExe,
        [string]$TracePath,
        [string]$Label
    )

    $reportPath = "demo-traces/$Label.verify.report.json"
    Remove-Item $reportPath -ErrorAction SilentlyContinue

    & $ToolExe verify $TracePath --report-json $reportPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $reportPath) {
            $report = Get-Content $reportPath -Raw | ConvertFrom-Json -Depth 64
            throw ("Trace verify failed for {0}: {1}" -f $TracePath, (Format-IssueSummary -Issue $report.first_issue))
        }
        throw "Trace verify failed for $TracePath"
    }
}

function Invoke-ClusterVerifyWithDiagnostics {
    param(
        [string]$ToolExe,
        [string[]]$TracePaths,
        [string]$ReportPath
    )

    Remove-Item $ReportPath -ErrorAction SilentlyContinue

    & $ToolExe cluster-verify @TracePaths --report-json $ReportPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $ReportPath) {
            $report = Get-Content $ReportPath -Raw | ConvertFrom-Json -Depth 64
            $localFail = $report.local | Where-Object { -not $_.ok } | Select-Object -First 1
            if ($null -ne $localFail) {
                throw ("Cluster verify local failure {0}: {1}" -f $localFail.path, (Format-IssueSummary -Issue $localFail.first_issue))
            }
            if ($null -ne $report.cluster) {
                throw ("Cluster verify failed: {0}" -f (Format-IssueSummary -Issue $report.cluster.first_issue))
            }
        }
        throw "Cluster verify failed for $($TracePaths -join ', ')"
    }
}

if (-not $SkipBuild) {
    Write-Host "[$ScenarioName] building runtime + tool..."
    cargo build -p runtime -p tool | Out-Host
}
else {
    Write-Host "[$ScenarioName] build skipped (using existing binaries)"
}

$runtimeExe = Join-Path $repoRoot "target\debug\runtime.exe"
$toolExe = Join-Path $repoRoot "target\debug\tool.exe"

if (-not (Test-Path $runtimeExe)) {
    throw "Missing runtime binary: $runtimeExe"
}
if (-not (Test-Path $toolExe)) {
    throw "Missing tool binary: $toolExe"
}

New-Item -ItemType Directory -Path (Join-Path $repoRoot "demo-traces") -Force | Out-Null
Remove-Item $Node1Trace, $Node2Trace -ErrorAction SilentlyContinue

$node1Args = @(
    "--node-id", $Node1Id,
    "--listen", "127.0.0.1:$Node1Port",
    "--peer", "$Node2Id=127.0.0.1:$Node2Port",
    "--trace", $Node1Trace,
    "--bootstrap-hello",
    "--bootstrap-burst", $BootstrapBurst.ToString(),
    "--steps", $NodeSteps.ToString(),
    "--idle-sleep-ms", $IdleSleepMs.ToString(),
    "--startup-wait-ms", $StartupWaitMs.ToString()
)

$node2Args = @(
    "--node-id", $Node2Id,
    "--listen", "127.0.0.1:$Node2Port",
    "--peer", "$Node1Id=127.0.0.1:$Node1Port",
    "--steps", $NodeSteps.ToString(),
    "--trace", $Node2Trace,
    "--idle-sleep-ms", $IdleSleepMs.ToString(),
    "--startup-wait-ms", $StartupWaitMs.ToString()
)

$faultDelaySteps = [int]$Node2FaultDelaySteps
$faultReorderWindow = [int]$Node2FaultReorderWindow
$faultDropEvery = [int]$Node2FaultDropEvery

if ($FaultTarget -eq "node1") {
    if ($faultDelaySteps -gt 0) {
        $node1Args += @("--fault-delay-steps", $faultDelaySteps.ToString())
    }
    if ($faultReorderWindow -gt 1) {
        $node1Args += @("--fault-reorder-window", $faultReorderWindow.ToString())
    }
    if ($faultDropEvery -gt 0) {
        $node1Args += @("--fault-drop-every", $faultDropEvery.ToString())
    }
}
else {
    if ($faultDelaySteps -gt 0) {
        $node2Args += @("--fault-delay-steps", $faultDelaySteps.ToString())
    }
    if ($faultReorderWindow -gt 1) {
        $node2Args += @("--fault-reorder-window", $faultReorderWindow.ToString())
    }
    if ($faultDropEvery -gt 0) {
        $node2Args += @("--fault-drop-every", $faultDropEvery.ToString())
    }
}

Write-Host "Starting node1 listener on 127.0.0.1:$Node1Port ..."
$node1 = Start-Process -FilePath $runtimeExe -ArgumentList $node1Args -PassThru -WindowStyle Hidden
Write-Host "Starting node2 listener on 127.0.0.1:$Node2Port ..."
$node2 = Start-Process -FilePath $runtimeExe -ArgumentList $node2Args -PassThru -WindowStyle Hidden

try {
    Wait-TcpPort -Hostname "127.0.0.1" -Port $Node1Port -TimeoutSec $StartupTimeoutSec
    Wait-TcpPort -Hostname "127.0.0.1" -Port $Node2Port -TimeoutSec $StartupTimeoutSec

    Wait-NodeProcess -Process $node1 -Name "node1" -TimeoutSec $ShutdownTimeoutSec
    Wait-NodeProcess -Process $node2 -Name "node2" -TimeoutSec $ShutdownTimeoutSec
}
finally {
    if ($node1 -and -not $node1.HasExited) {
        Stop-Process -Id $node1.Id -Force
    }
    if ($node2 -and -not $node2.HasExited) {
        Stop-Process -Id $node2.Id -Force
    }
}

if ([string]::IsNullOrWhiteSpace($ScenarioReportPath)) {
    $ScenarioReportPath = "demo-traces/$ReportPrefix.scenario.json"
}
$clusterReportPath = "demo-traces/$ReportPrefix.verify.report.json"
$node1VerifyLabel = "$ReportPrefix-node1"
$node2VerifyLabel = "$ReportPrefix-node2"
$node1VerifyReportPath = "demo-traces/$node1VerifyLabel.verify.report.json"
$node2VerifyReportPath = "demo-traces/$node2VerifyLabel.verify.report.json"

if (-not (Test-Path $Node1Trace)) {
    throw "Expected trace not found: $Node1Trace"
}
if (-not (Test-Path $Node2Trace)) {
    throw "Expected trace not found: $Node2Trace"
}

Write-Host "Node trace summaries:"
& $toolExe $Node1Trace | Out-Host
& $toolExe $Node2Trace | Out-Host

Invoke-VerifyWithDiagnostics -ToolExe $toolExe -TracePath $Node1Trace -Label $node1VerifyLabel
Invoke-VerifyWithDiagnostics -ToolExe $toolExe -TracePath $Node2Trace -Label $node2VerifyLabel

Invoke-ReplayCheck -RuntimeExe $runtimeExe -NodeId $Node1Id -TracePath $Node1Trace -ReplaySteps $ReplaySteps -ExtraArgs @(
    "--peer", "$Node2Id=127.0.0.1:$Node2Port",
    "--bootstrap-hello",
    "--bootstrap-burst", $BootstrapBurst.ToString()
)
Invoke-ReplayCheck -RuntimeExe $runtimeExe -NodeId $Node2Id -TracePath $Node2Trace -ReplaySteps $ReplaySteps -ExtraArgs @(
    "--peer", "$Node1Id=127.0.0.1:$Node1Port"
)

Invoke-ClusterVerifyWithDiagnostics -ToolExe $toolExe -TracePaths @($Node1Trace, $Node2Trace) -ReportPath $clusterReportPath
$clusterReport = Get-Content $clusterReportPath -Raw | ConvertFrom-Json -Depth 64

$node1Events = Get-Content $Node1Trace |
    Where-Object { $_.Trim() -ne "" } |
    ForEach-Object { $_ | ConvertFrom-Json -Depth 32 }
$node2Events = Get-Content $Node2Trace |
    Where-Object { $_.Trim() -ne "" } |
    ForEach-Object { $_ | ConvertFrom-Json -Depth 32 }

$node1NetSend = ($node1Events | Where-Object { $_.kind.NetSend }).Count
$node1NetRecv = ($node1Events | Where-Object { $_.kind.NetRecv }).Count
$node2NetSend = ($node2Events | Where-Object { $_.kind.NetSend }).Count
$node2NetRecv = ($node2Events | Where-Object { $_.kind.NetRecv }).Count

$node1FaultEvents = @($node1Events | Where-Object { $_.kind.FaultInjected })
$node2FaultEvents = @($node2Events | Where-Object { $_.kind.FaultInjected })

$node1ActionCounts = @{
    Drop = 0
    Delay = 0
    Reorder = 0
}
$node2ActionCounts = @{
    Drop = 0
    Delay = 0
    Reorder = 0
}
foreach ($evt in $node1FaultEvents) {
    $name = Get-ActionName -ActionObj $evt.kind.FaultInjected.action
    if ($node1ActionCounts.ContainsKey($name)) {
        $node1ActionCounts[$name] += 1
    }
}
foreach ($evt in $node2FaultEvents) {
    $name = Get-ActionName -ActionObj $evt.kind.FaultInjected.action
    if ($node2ActionCounts.ContainsKey($name)) {
        $node2ActionCounts[$name] += 1
    }
}

$targetFaultEvents = if ($FaultTarget -eq "node1") { $node1FaultEvents } else { $node2FaultEvents }
$targetActionCounts = if ($FaultTarget -eq "node1") { $node1ActionCounts } else { $node2ActionCounts }

if ($targetFaultEvents.Count -lt 1) {
    throw ("Expected at least one FaultInjected event in {0} trace" -f $FaultTarget)
}
if ($faultDelaySteps -gt 0 -and $targetActionCounts.Delay -lt 1) {
    throw ("Expected Delay fault evidence in {0} trace" -f $FaultTarget)
}
if ($faultReorderWindow -gt 1 -and $targetActionCounts.Reorder -lt 1) {
    throw ("Expected Reorder fault evidence in {0} trace" -f $FaultTarget)
}
if ($faultDropEvery -gt 0 -and $targetActionCounts.Drop -lt 1) {
    throw ("Expected Drop fault evidence in {0} trace" -f $FaultTarget)
}

$node1RecvMin = 1
$node2RecvMin = 1
if ($faultDropEvery -eq 1) {
    if ($FaultTarget -eq "node1") {
        $node1RecvMin = 0
    }
    else {
        $node2RecvMin = 0
    }
}

if ($node1NetSend -lt 1 -or $node1NetRecv -lt $node1RecvMin -or $node2NetSend -lt 1 -or $node2NetRecv -lt $node2RecvMin) {
    throw "Expected closed cluster traffic with mixed faults. FaultTarget=$FaultTarget Node1(NetSend=$node1NetSend NetRecv=$node1NetRecv) Node2(NetSend=$node2NetSend NetRecv=$node2NetRecv) TargetFaultCounts=$($targetActionCounts | ConvertTo-Json -Compress)"
}

$summary = [ordered]@{
    scenario = $ScenarioName
    ok = $true
    node_ids = @($Node1Id, $Node2Id)
    ports = @($Node1Port, $Node2Port)
    traces = @($Node1Trace, $Node2Trace)
    reports = @{
        node1_verify = $node1VerifyReportPath
        node2_verify = $node2VerifyReportPath
        cluster_verify = $clusterReportPath
    }
    fault_config = @{
        target = $FaultTarget
        drop_every = $faultDropEvery
        delay_steps = $faultDelaySteps
        reorder_window = $faultReorderWindow
    }
    traffic = @{
        node1_net_send = $node1NetSend
        node1_net_recv = $node1NetRecv
        node2_net_send = $node2NetSend
        node2_net_recv = $node2NetRecv
    }
    fault_counts_target = $targetActionCounts
    fault_counts_by_node = @{
        node1 = $node1ActionCounts
        node2 = $node2ActionCounts
    }
    fault_counts = $targetActionCounts
    cluster_verify = @{
        matched_recv = $clusterReport.cluster.matched_recv
        matched_drop = $clusterReport.cluster.matched_drop
        resolved_lineage_parents = $clusterReport.cluster.resolved_lineage_parents
        external_lineage_parents = $clusterReport.cluster.external_lineage_parents
        external_inbound = $clusterReport.cluster.external_inbound
        external_outbound = $clusterReport.cluster.external_outbound
        issue_count = $clusterReport.cluster.issue_count
    }
}

$summaryJson = $summary | ConvertTo-Json -Depth 16
[System.IO.File]::WriteAllText((Join-Path $repoRoot $ScenarioReportPath), $summaryJson)

Write-Host "Cluster fault scenario passed. Scenario=$ScenarioName FaultTarget=$FaultTarget Node1(NetSend=$node1NetSend NetRecv=$node1NetRecv) Node2(NetSend=$node2NetSend NetRecv=$node2NetRecv) TargetFaultCounts=$($targetActionCounts | ConvertTo-Json -Compress)"
Write-Host "Scenario summary written: $ScenarioReportPath"
