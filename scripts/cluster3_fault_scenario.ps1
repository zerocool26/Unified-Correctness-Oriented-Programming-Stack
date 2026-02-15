param(
    [string]$ScenarioName = "cluster3-fault",
    [string]$ReportPrefix = "cluster3-fault",
    [string]$Node1Id = "00000000-0000-0000-0000-000000000801",
    [string]$Node2Id = "00000000-0000-0000-0000-000000000802",
    [string]$Node3Id = "00000000-0000-0000-0000-000000000803",
    [int]$Node1Port = 7801,
    [int]$Node2Port = 7802,
    [int]$Node3Port = 7803,
    [string]$Node1Trace = "demo-traces/cluster3-fault-node1.trace.jsonl",
    [string]$Node2Trace = "demo-traces/cluster3-fault-node2.trace.jsonl",
    [string]$Node3Trace = "demo-traces/cluster3-fault-node3.trace.jsonl",
    [int]$NodeSteps = 300,
    [int]$ReplaySteps = 360,
    [int]$IdleSleepMs = 10,
    [int]$StartupWaitMs = 1500,
    [int]$BootstrapBurst = 3,
    [ValidateSet("node1", "node2", "node3")]
    [string]$FaultTarget = "node2",
    [int]$Node1FaultDelaySteps = -1,
    [int]$Node1FaultReorderWindow = -1,
    [int]$Node1FaultDropEvery = -1,
    [string[]]$Node1FaultPhases = @(),
    [Alias("FaultDelaySteps")]
    [int]$Node2FaultDelaySteps = 2,
    [Alias("FaultReorderWindow")]
    [int]$Node2FaultReorderWindow = 2,
    [Alias("FaultDropEvery")]
    [int]$Node2FaultDropEvery = 0,
    [int]$Node2PerNodeDelaySteps = -1,
    [int]$Node2PerNodeReorderWindow = -1,
    [int]$Node2PerNodeDropEvery = -1,
    [string[]]$Node2FaultPhases = @(),
    [int]$Node3FaultDelaySteps = -1,
    [int]$Node3FaultReorderWindow = -1,
    [int]$Node3FaultDropEvery = -1,
    [string[]]$Node3FaultPhases = @(),
    [int]$MinActiveFaultNodes = 1,
    [int]$MinClusterEvidence = 1,
    [int]$StartupTimeoutSec = 20,
    [int]$ShutdownTimeoutSec = 120,
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

function Resolve-NodeFaultConfig {
    param(
        [string]$NodeName,
        [int]$BaseDelay,
        [int]$BaseReorder,
        [int]$BaseDrop
    )

    $delay = 0
    $reorder = 1
    $drop = 0

    if ($NodeName -eq $FaultTarget) {
        $delay = [int]$BaseDelay
        $reorder = [int]$BaseReorder
        $drop = [int]$BaseDrop
    }

    if ($NodeName -eq "node1") {
        if ($Node1FaultDelaySteps -ge 0) { $delay = [int]$Node1FaultDelaySteps }
        if ($Node1FaultReorderWindow -ge 0) { $reorder = [int]$Node1FaultReorderWindow }
        if ($Node1FaultDropEvery -ge 0) { $drop = [int]$Node1FaultDropEvery }
    }
    elseif ($NodeName -eq "node2") {
        if ($Node2PerNodeDelaySteps -ge 0) { $delay = [int]$Node2PerNodeDelaySteps }
        if ($Node2PerNodeReorderWindow -ge 0) { $reorder = [int]$Node2PerNodeReorderWindow }
        if ($Node2PerNodeDropEvery -ge 0) { $drop = [int]$Node2PerNodeDropEvery }
    }
    else {
        if ($Node3FaultDelaySteps -ge 0) { $delay = [int]$Node3FaultDelaySteps }
        if ($Node3FaultReorderWindow -ge 0) { $reorder = [int]$Node3FaultReorderWindow }
        if ($Node3FaultDropEvery -ge 0) { $drop = [int]$Node3FaultDropEvery }
    }

    return @{
        Delay = $delay
        Reorder = $reorder
        Drop = $drop
    }
}

function Expand-PhaseSpecs {
    param([string[]]$PhaseSpecs)

    $expanded = @()
    foreach ($spec in @($PhaseSpecs)) {
        if ([string]::IsNullOrWhiteSpace([string]$spec)) {
            continue
        }
        $expanded += @(
            ([string]$spec -split ",") |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    return $expanded
}

function Parse-PhaseSpec {
    param([string]$Spec)

    $raw = [string]$Spec
    $parts = $raw -split ":"
    if ($parts.Count -ne 5) {
        throw ("Invalid fault phase spec `{0}` (expected start:end:drop_every:delay_steps:reorder_window)" -f $Spec)
    }

    $startStep = [int]$parts[0]
    $endStep = $parts[1]
    if ($endStep -ne "*") {
        $endStep = [int]$parts[1]
    }

    return [ordered]@{
        spec = $raw
        start_step = $startStep
        end_step = $endStep
        drop_every = [int]$parts[2]
        delay_steps = [int]$parts[3]
        reorder_window = [int]$parts[4]
    }
}

function Parse-PhaseSpecs {
    param([string[]]$PhaseSpecs)

    $parsed = @()
    foreach ($spec in @($PhaseSpecs)) {
        if ([string]::IsNullOrWhiteSpace([string]$spec)) {
            continue
        }
        $parsed += , (Parse-PhaseSpec -Spec $spec)
    }
    return $parsed
}

function Normalize-DropEveryValue {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return 0
    }
    return [int]$Value
}

function Get-ExpectedInitialPolicy {
    param(
        $Config,
        [object[]]$PhaseDefs
    )

    $phaseAtZero = @($PhaseDefs | Where-Object { [int]$_.start_step -eq 0 } | Select-Object -First 1)
    if ($phaseAtZero.Count -gt 0) {
        return [ordered]@{
            drop_every = [int]$phaseAtZero[0].drop_every
            delay_steps = [int]$phaseAtZero[0].delay_steps
            reorder_window = [int]$phaseAtZero[0].reorder_window
        }
    }

    return [ordered]@{
        drop_every = [int]$Config.Drop
        delay_steps = [int]$Config.Delay
        reorder_window = [int]$Config.Reorder
    }
}

function Assert-PolicyEventMatches {
    param(
        [string]$NodeName,
        $Event,
        [int]$ExpectedDropEvery,
        [int]$ExpectedDelaySteps,
        [int]$ExpectedReorderWindow,
        [string]$Context
    )

    $actualDrop = Normalize-DropEveryValue -Value $Event.drop_every
    $actualDelay = [int]$Event.delay_steps
    $actualReorder = [int]$Event.reorder_window

    if ($actualDrop -ne [int]$ExpectedDropEvery -or
        $actualDelay -ne [int]$ExpectedDelaySteps -or
        $actualReorder -ne [int]$ExpectedReorderWindow) {
        throw ("{0} policy mismatch in {1}: expected drop={2} delay={3} reorder={4}, got drop={5} delay={6} reorder={7}" -f `
                $NodeName, $Context, [int]$ExpectedDropEvery, [int]$ExpectedDelaySteps, [int]$ExpectedReorderWindow, `
                $actualDrop, $actualDelay, $actualReorder)
    }
}

function Assert-PhasePolicyTimeline {
    param(
        [string]$NodeName,
        [object[]]$PolicyEvents,
        $Config,
        [object[]]$PhaseDefs
    )

    if ($PolicyEvents.Count -lt 1) {
        throw ("Expected at least one FaultPolicy event in {0} trace" -f $NodeName)
    }

    $step0Event = @($PolicyEvents | Where-Object { [int]$_.step -eq 0 } | Select-Object -First 1)
    if ($step0Event.Count -eq 0) {
        throw ("Expected FaultPolicy step=0 event in {0} trace" -f $NodeName)
    }

    $expectedInitial = Get-ExpectedInitialPolicy -Config $Config -PhaseDefs $PhaseDefs
    Assert-PolicyEventMatches `
        -NodeName $NodeName `
        -Event $step0Event[0] `
        -ExpectedDropEvery ([int]$expectedInitial.drop_every) `
        -ExpectedDelaySteps ([int]$expectedInitial.delay_steps) `
        -ExpectedReorderWindow ([int]$expectedInitial.reorder_window) `
        -Context "initial policy"

    foreach ($phase in @($PhaseDefs)) {
        $phaseEvent = @($PolicyEvents | Where-Object { [int]$_.step -eq [int]$phase.start_step } | Select-Object -First 1)
        if ($phaseEvent.Count -eq 0) {
            throw ('Expected FaultPolicy event at phase start step={0} in {1} trace (phase {2})' -f [int]$phase.start_step, $NodeName, $phase.spec)
        }
        Assert-PolicyEventMatches `
            -NodeName $NodeName `
            -Event $phaseEvent[0] `
            -ExpectedDropEvery ([int]$phase.drop_every) `
            -ExpectedDelaySteps ([int]$phase.delay_steps) `
            -ExpectedReorderWindow ([int]$phase.reorder_window) `
            -Context ('phase {0}' -f $phase.spec)
    }
}

function Get-ExpectedNetRecvMin {
    param(
        $Config,
        [object[]]$PhaseDefs
    )

    $initial = Get-ExpectedInitialPolicy -Config $Config -PhaseDefs $PhaseDefs
    if ([int]$initial.drop_every -eq 1) {
        return 0
    }
    return 1
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
Remove-Item $Node1Trace, $Node2Trace, $Node3Trace -ErrorAction SilentlyContinue

$node1Args = @(
    "--node-id", $Node1Id,
    "--listen", "127.0.0.1:$Node1Port",
    "--peer", "$Node2Id=127.0.0.1:$Node2Port",
    "--peer", "$Node3Id=127.0.0.1:$Node3Port",
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
    "--peer", "$Node3Id=127.0.0.1:$Node3Port",
    "--trace", $Node2Trace,
    "--steps", $NodeSteps.ToString(),
    "--idle-sleep-ms", $IdleSleepMs.ToString(),
    "--startup-wait-ms", $StartupWaitMs.ToString()
)

$node3Args = @(
    "--node-id", $Node3Id,
    "--listen", "127.0.0.1:$Node3Port",
    "--peer", "$Node1Id=127.0.0.1:$Node1Port",
    "--peer", "$Node2Id=127.0.0.1:$Node2Port",
    "--trace", $Node3Trace,
    "--steps", $NodeSteps.ToString(),
    "--idle-sleep-ms", $IdleSleepMs.ToString(),
    "--startup-wait-ms", $StartupWaitMs.ToString()
)

$baseFaultDelaySteps = [int]$Node2FaultDelaySteps
$baseFaultReorderWindow = [int]$Node2FaultReorderWindow
$baseFaultDropEvery = [int]$Node2FaultDropEvery

$faultConfigNode1 = Resolve-NodeFaultConfig -NodeName "node1" -BaseDelay $baseFaultDelaySteps -BaseReorder $baseFaultReorderWindow -BaseDrop $baseFaultDropEvery
$faultConfigNode2 = Resolve-NodeFaultConfig -NodeName "node2" -BaseDelay $baseFaultDelaySteps -BaseReorder $baseFaultReorderWindow -BaseDrop $baseFaultDropEvery
$faultConfigNode3 = Resolve-NodeFaultConfig -NodeName "node3" -BaseDelay $baseFaultDelaySteps -BaseReorder $baseFaultReorderWindow -BaseDrop $baseFaultDropEvery
$node1PhaseSpecs = @(Expand-PhaseSpecs -PhaseSpecs $Node1FaultPhases)
$node2PhaseSpecs = @(Expand-PhaseSpecs -PhaseSpecs $Node2FaultPhases)
$node3PhaseSpecs = @(Expand-PhaseSpecs -PhaseSpecs $Node3FaultPhases)
$node1PhaseDefs = @(Parse-PhaseSpecs -PhaseSpecs $node1PhaseSpecs)
$node2PhaseDefs = @(Parse-PhaseSpecs -PhaseSpecs $node2PhaseSpecs)
$node3PhaseDefs = @(Parse-PhaseSpecs -PhaseSpecs $node3PhaseSpecs)

if ([int]$faultConfigNode1.Delay -gt 0) {
    $node1Args += @("--fault-delay-steps", ([int]$faultConfigNode1.Delay).ToString())
}
if ([int]$faultConfigNode1.Reorder -gt 1) {
    $node1Args += @("--fault-reorder-window", ([int]$faultConfigNode1.Reorder).ToString())
}
if ([int]$faultConfigNode1.Drop -gt 0) {
    $node1Args += @("--fault-drop-every", ([int]$faultConfigNode1.Drop).ToString())
}
foreach ($phase in @($node1PhaseSpecs)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$phase)) {
        $node1Args += @("--fault-phase", [string]$phase)
    }
}

if ([int]$faultConfigNode2.Delay -gt 0) {
    $node2Args += @("--fault-delay-steps", ([int]$faultConfigNode2.Delay).ToString())
}
if ([int]$faultConfigNode2.Reorder -gt 1) {
    $node2Args += @("--fault-reorder-window", ([int]$faultConfigNode2.Reorder).ToString())
}
if ([int]$faultConfigNode2.Drop -gt 0) {
    $node2Args += @("--fault-drop-every", ([int]$faultConfigNode2.Drop).ToString())
}
foreach ($phase in @($node2PhaseSpecs)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$phase)) {
        $node2Args += @("--fault-phase", [string]$phase)
    }
}

if ([int]$faultConfigNode3.Delay -gt 0) {
    $node3Args += @("--fault-delay-steps", ([int]$faultConfigNode3.Delay).ToString())
}
if ([int]$faultConfigNode3.Reorder -gt 1) {
    $node3Args += @("--fault-reorder-window", ([int]$faultConfigNode3.Reorder).ToString())
}
if ([int]$faultConfigNode3.Drop -gt 0) {
    $node3Args += @("--fault-drop-every", ([int]$faultConfigNode3.Drop).ToString())
}
foreach ($phase in @($node3PhaseSpecs)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$phase)) {
        $node3Args += @("--fault-phase", [string]$phase)
    }
}

Write-Host "Starting node1 listener on 127.0.0.1:$Node1Port ..."
$node1 = Start-Process -FilePath $runtimeExe -ArgumentList $node1Args -PassThru -WindowStyle Hidden
Write-Host "Starting node2 listener on 127.0.0.1:$Node2Port ..."
$node2 = Start-Process -FilePath $runtimeExe -ArgumentList $node2Args -PassThru -WindowStyle Hidden
Write-Host "Starting node3 listener on 127.0.0.1:$Node3Port ..."
$node3 = Start-Process -FilePath $runtimeExe -ArgumentList $node3Args -PassThru -WindowStyle Hidden

try {
    Wait-TcpPort -Hostname "127.0.0.1" -Port $Node1Port -TimeoutSec $StartupTimeoutSec
    Wait-TcpPort -Hostname "127.0.0.1" -Port $Node2Port -TimeoutSec $StartupTimeoutSec
    Wait-TcpPort -Hostname "127.0.0.1" -Port $Node3Port -TimeoutSec $StartupTimeoutSec

    Wait-NodeProcess -Process $node1 -Name "node1" -TimeoutSec $ShutdownTimeoutSec
    Wait-NodeProcess -Process $node2 -Name "node2" -TimeoutSec $ShutdownTimeoutSec
    Wait-NodeProcess -Process $node3 -Name "node3" -TimeoutSec $ShutdownTimeoutSec
}
finally {
    if ($node1 -and -not $node1.HasExited) {
        Stop-Process -Id $node1.Id -Force
    }
    if ($node2 -and -not $node2.HasExited) {
        Stop-Process -Id $node2.Id -Force
    }
    if ($node3 -and -not $node3.HasExited) {
        Stop-Process -Id $node3.Id -Force
    }
}

if ([string]::IsNullOrWhiteSpace($ScenarioReportPath)) {
    $ScenarioReportPath = "demo-traces/$ReportPrefix.scenario.json"
}
$clusterReportPath = "demo-traces/$ReportPrefix.verify.report.json"
$node1VerifyLabel = "$ReportPrefix-node1"
$node2VerifyLabel = "$ReportPrefix-node2"
$node3VerifyLabel = "$ReportPrefix-node3"
$node1VerifyReportPath = "demo-traces/$node1VerifyLabel.verify.report.json"
$node2VerifyReportPath = "demo-traces/$node2VerifyLabel.verify.report.json"
$node3VerifyReportPath = "demo-traces/$node3VerifyLabel.verify.report.json"

if (-not (Test-Path $Node1Trace)) {
    throw "Expected trace not found: $Node1Trace"
}
if (-not (Test-Path $Node2Trace)) {
    throw "Expected trace not found: $Node2Trace"
}
if (-not (Test-Path $Node3Trace)) {
    throw "Expected trace not found: $Node3Trace"
}

Write-Host "Node trace summaries:"
& $toolExe $Node1Trace | Out-Host
& $toolExe $Node2Trace | Out-Host
& $toolExe $Node3Trace | Out-Host

Invoke-VerifyWithDiagnostics -ToolExe $toolExe -TracePath $Node1Trace -Label $node1VerifyLabel
Invoke-VerifyWithDiagnostics -ToolExe $toolExe -TracePath $Node2Trace -Label $node2VerifyLabel
Invoke-VerifyWithDiagnostics -ToolExe $toolExe -TracePath $Node3Trace -Label $node3VerifyLabel

Invoke-ReplayCheck -RuntimeExe $runtimeExe -NodeId $Node1Id -TracePath $Node1Trace -ReplaySteps $ReplaySteps -ExtraArgs @(
    "--peer", "$Node2Id=127.0.0.1:$Node2Port",
    "--peer", "$Node3Id=127.0.0.1:$Node3Port",
    "--bootstrap-hello",
    "--bootstrap-burst", $BootstrapBurst.ToString()
)
Invoke-ReplayCheck -RuntimeExe $runtimeExe -NodeId $Node2Id -TracePath $Node2Trace -ReplaySteps $ReplaySteps -ExtraArgs @(
    "--peer", "$Node1Id=127.0.0.1:$Node1Port",
    "--peer", "$Node3Id=127.0.0.1:$Node3Port"
)
Invoke-ReplayCheck -RuntimeExe $runtimeExe -NodeId $Node3Id -TracePath $Node3Trace -ReplaySteps $ReplaySteps -ExtraArgs @(
    "--peer", "$Node1Id=127.0.0.1:$Node1Port",
    "--peer", "$Node2Id=127.0.0.1:$Node2Port"
)

Invoke-ClusterVerifyWithDiagnostics -ToolExe $toolExe -TracePaths @($Node1Trace, $Node2Trace, $Node3Trace) -ReportPath $clusterReportPath
$clusterReport = Get-Content $clusterReportPath -Raw | ConvertFrom-Json -Depth 64

$node1Events = Get-Content $Node1Trace |
    Where-Object { $_.Trim() -ne "" } |
    ForEach-Object { $_ | ConvertFrom-Json -Depth 32 }
$node2Events = Get-Content $Node2Trace |
    Where-Object { $_.Trim() -ne "" } |
    ForEach-Object { $_ | ConvertFrom-Json -Depth 32 }
$node3Events = Get-Content $Node3Trace |
    Where-Object { $_.Trim() -ne "" } |
    ForEach-Object { $_ | ConvertFrom-Json -Depth 32 }

$node1NetSend = ($node1Events | Where-Object { $_.kind.NetSend }).Count
$node1NetRecv = ($node1Events | Where-Object { $_.kind.NetRecv }).Count
$node2NetSend = ($node2Events | Where-Object { $_.kind.NetSend }).Count
$node2NetRecv = ($node2Events | Where-Object { $_.kind.NetRecv }).Count
$node3NetSend = ($node3Events | Where-Object { $_.kind.NetSend }).Count
$node3NetRecv = ($node3Events | Where-Object { $_.kind.NetRecv }).Count

$node1FaultEvents = @($node1Events | Where-Object { $_.kind.FaultInjected })
$node2FaultEvents = @($node2Events | Where-Object { $_.kind.FaultInjected })
$node3FaultEvents = @($node3Events | Where-Object { $_.kind.FaultInjected })
$node1PolicyEvents = @($node1Events | Where-Object { $_.kind.FaultPolicy } | ForEach-Object { $_.kind.FaultPolicy })
$node2PolicyEvents = @($node2Events | Where-Object { $_.kind.FaultPolicy } | ForEach-Object { $_.kind.FaultPolicy })
$node3PolicyEvents = @($node3Events | Where-Object { $_.kind.FaultPolicy } | ForEach-Object { $_.kind.FaultPolicy })

$actionCountsNode1 = @{
    Drop = 0
    Delay = 0
    Reorder = 0
}
$actionCountsNode2 = @{
    Drop = 0
    Delay = 0
    Reorder = 0
}
$actionCountsNode3 = @{
    Drop = 0
    Delay = 0
    Reorder = 0
}
foreach ($evt in $node1FaultEvents) {
    $name = Get-ActionName -ActionObj $evt.kind.FaultInjected.action
    if ($actionCountsNode1.ContainsKey($name)) {
        $actionCountsNode1[$name] += 1
    }
}
foreach ($evt in $node2FaultEvents) {
    $name = Get-ActionName -ActionObj $evt.kind.FaultInjected.action
    if ($actionCountsNode2.ContainsKey($name)) {
        $actionCountsNode2[$name] += 1
    }
}
foreach ($evt in $node3FaultEvents) {
    $name = Get-ActionName -ActionObj $evt.kind.FaultInjected.action
    if ($actionCountsNode3.ContainsKey($name)) {
        $actionCountsNode3[$name] += 1
    }
}

$faultEvidenceByNode = @{
    node1 = @{
        Events = $node1FaultEvents
        PolicyEvents = $node1PolicyEvents
        Counts = $actionCountsNode1
        Config = $faultConfigNode1
        Phases = @($node1PhaseSpecs)
        PhaseDefs = @($node1PhaseDefs)
    }
    node2 = @{
        Events = $node2FaultEvents
        PolicyEvents = $node2PolicyEvents
        Counts = $actionCountsNode2
        Config = $faultConfigNode2
        Phases = @($node2PhaseSpecs)
        PhaseDefs = @($node2PhaseDefs)
    }
    node3 = @{
        Events = $node3FaultEvents
        PolicyEvents = $node3PolicyEvents
        Counts = $actionCountsNode3
        Config = $faultConfigNode3
        Phases = @($node3PhaseSpecs)
        PhaseDefs = @($node3PhaseDefs)
    }
}

$activeFaultNodes = @()
foreach ($nodeName in @("node1", "node2", "node3")) {
    $cfg = $faultEvidenceByNode[$nodeName].Config
    $phaseSpecs = @($faultEvidenceByNode[$nodeName].Phases | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $hasPhase = ($phaseSpecs.Count -gt 0)
    if ([int]$cfg.Delay -gt 0 -or [int]$cfg.Reorder -gt 1 -or [int]$cfg.Drop -gt 0 -or $hasPhase) {
        $activeFaultNodes += $nodeName
    }
}
if ($activeFaultNodes.Count -lt [int]$MinActiveFaultNodes) {
    throw ("Expected at least {0} active fault profile(s) across node1/node2/node3" -f [int]$MinActiveFaultNodes)
}

foreach ($nodeName in $activeFaultNodes) {
    $nodeFault = $faultEvidenceByNode[$nodeName]
    $cfg = $nodeFault.Config
    $counts = $nodeFault.Counts
    $events = $nodeFault.Events
    $phaseDefs = @($nodeFault.PhaseDefs)
    $policyEvents = @($nodeFault.PolicyEvents)

    Assert-PhasePolicyTimeline -NodeName $nodeName -PolicyEvents $policyEvents -Config $cfg -PhaseDefs $phaseDefs

    $expectDrop = ([int]$cfg.Drop -gt 0)
    $expectDelay = ([int]$cfg.Delay -gt 0)
    $expectReorder = ([int]$cfg.Reorder -gt 1)

    if ($expectDelay -and [int]$counts.Delay -lt 1) {
        throw ("Expected Delay fault evidence in {0} trace" -f $nodeName)
    }
    if ($expectReorder -and [int]$counts.Reorder -lt 1) {
        throw ("Expected Reorder fault evidence in {0} trace" -f $nodeName)
    }
    if ($expectDrop -and [int]$counts.Drop -lt 1) {
        throw ("Expected Drop fault evidence in {0} trace" -f $nodeName)
    }
}

$totalFaultInjected = $node1FaultEvents.Count + $node2FaultEvents.Count + $node3FaultEvents.Count
if ($totalFaultInjected -lt 1) {
    throw "Expected at least one FaultInjected event across cluster traces"
}

$targetActionCounts = $actionCountsNode2
if ($FaultTarget -eq "node1") {
    $targetActionCounts = $actionCountsNode1
}
elseif ($FaultTarget -eq "node3") {
    $targetActionCounts = $actionCountsNode3
}

$node1RecvMin = Get-ExpectedNetRecvMin -Config $faultConfigNode1 -PhaseDefs $node1PhaseDefs
$node2RecvMin = Get-ExpectedNetRecvMin -Config $faultConfigNode2 -PhaseDefs $node2PhaseDefs
$node3RecvMin = Get-ExpectedNetRecvMin -Config $faultConfigNode3 -PhaseDefs $node3PhaseDefs

if ($node1NetSend -lt 1 -or $node1NetRecv -lt $node1RecvMin -or
    $node2NetSend -lt 1 -or $node2NetRecv -lt $node2RecvMin -or
    $node3NetSend -lt 1 -or $node3NetRecv -lt $node3RecvMin) {
    throw "Expected closed 3-node traffic with mixed faults. FaultTarget=$FaultTarget Node1(NetSend=$node1NetSend NetRecv=$node1NetRecv) Node2(NetSend=$node2NetSend NetRecv=$node2NetRecv) Node3(NetSend=$node3NetSend NetRecv=$node3NetRecv) TargetFaultCounts=$($targetActionCounts | ConvertTo-Json -Compress)"
}
if ($BootstrapBurst -gt 1 -and $node1NetSend -lt $BootstrapBurst) {
    throw ("Expected node1 NetSend >= BootstrapBurst. NetSend={0} BootstrapBurst={1}" -f $node1NetSend, $BootstrapBurst)
}

$clusterMatchedTotal = [int]$clusterReport.cluster.matched_recv + [int]$clusterReport.cluster.matched_drop
if ($clusterMatchedTotal -lt [int]$MinClusterEvidence) {
    throw ("Expected cluster evidence >= {0}, got {1}" -f [int]$MinClusterEvidence, $clusterMatchedTotal)
}

$summary = [ordered]@{
    scenario = $ScenarioName
    ok = $true
    node_ids = @($Node1Id, $Node2Id, $Node3Id)
    ports = @($Node1Port, $Node2Port, $Node3Port)
    traces = @($Node1Trace, $Node2Trace, $Node3Trace)
    reports = @{
        node1_verify = $node1VerifyReportPath
        node2_verify = $node2VerifyReportPath
        node3_verify = $node3VerifyReportPath
        cluster_verify = $clusterReportPath
    }
    fault_config = @{
        target = $FaultTarget
        bootstrap_burst = $BootstrapBurst
        drop_every = $baseFaultDropEvery
        delay_steps = $baseFaultDelaySteps
        reorder_window = $baseFaultReorderWindow
        node1 = @{
            drop_every = [int]$faultConfigNode1.Drop
            delay_steps = [int]$faultConfigNode1.Delay
            reorder_window = [int]$faultConfigNode1.Reorder
            phases = @($node1PhaseSpecs)
        }
        node2 = @{
            drop_every = [int]$faultConfigNode2.Drop
            delay_steps = [int]$faultConfigNode2.Delay
            reorder_window = [int]$faultConfigNode2.Reorder
            phases = @($node2PhaseSpecs)
        }
        node3 = @{
            drop_every = [int]$faultConfigNode3.Drop
            delay_steps = [int]$faultConfigNode3.Delay
            reorder_window = [int]$faultConfigNode3.Reorder
            phases = @($node3PhaseSpecs)
        }
    }
    active_fault_nodes = $activeFaultNodes
    traffic = @{
        node1_net_send = $node1NetSend
        node1_net_recv = $node1NetRecv
        node2_net_send = $node2NetSend
        node2_net_recv = $node2NetRecv
        node3_net_send = $node3NetSend
        node3_net_recv = $node3NetRecv
    }
    fault_counts_target = $targetActionCounts
    fault_counts_by_node = @{
        node1 = $actionCountsNode1
        node2 = $actionCountsNode2
        node3 = $actionCountsNode3
    }
    fault_policy_events_by_node = @{
        node1 = $node1PolicyEvents.Count
        node2 = $node2PolicyEvents.Count
        node3 = $node3PolicyEvents.Count
    }
    fault_counts_node2 = $actionCountsNode2
    cluster_verify = @{
        matched_recv = $clusterReport.cluster.matched_recv
        matched_drop = $clusterReport.cluster.matched_drop
        matched_total = $clusterMatchedTotal
        resolved_lineage_parents = $clusterReport.cluster.resolved_lineage_parents
        external_lineage_parents = $clusterReport.cluster.external_lineage_parents
        external_inbound = $clusterReport.cluster.external_inbound
        external_outbound = $clusterReport.cluster.external_outbound
        issue_count = $clusterReport.cluster.issue_count
    }
}

$summaryJson = $summary | ConvertTo-Json -Depth 16
[System.IO.File]::WriteAllText((Join-Path $repoRoot $ScenarioReportPath), $summaryJson)

Write-Host "Cluster3 fault scenario passed. Scenario=$ScenarioName FaultTarget=$FaultTarget Node1(NetSend=$node1NetSend NetRecv=$node1NetRecv) Node2(NetSend=$node2NetSend NetRecv=$node2NetRecv) Node3(NetSend=$node3NetSend NetRecv=$node3NetRecv) TargetFaultCounts=$($targetActionCounts | ConvertTo-Json -Compress)"
Write-Host "Scenario summary written: $ScenarioReportPath"
