param(
    [string]$Node1Id = "00000000-0000-0000-0000-000000000501",
    [string]$Node2Id = "00000000-0000-0000-0000-000000000502",
    [string]$Node3Id = "00000000-0000-0000-0000-000000000503",
    [int]$Node1Port = 7401,
    [int]$Node2Port = 7402,
    [int]$Node3Port = 7403,
    [string]$Node1Trace = "demo-traces/cluster3-node1.trace.jsonl",
    [string]$Node2Trace = "demo-traces/cluster3-node2.trace.jsonl",
    [string]$Node3Trace = "demo-traces/cluster3-node3.trace.jsonl",
    [int]$NodeSteps = 260,
    [int]$ReplaySteps = 320,
    [int]$IdleSleepMs = 10,
    [int]$StartupWaitMs = 1500,
    [int]$StartupTimeoutSec = 20,
    [int]$ShutdownTimeoutSec = 120
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
        [string[]]$TracePaths
    )

    $reportPath = "demo-traces/cluster3.verify.report.json"
    Remove-Item $reportPath -ErrorAction SilentlyContinue

    & $ToolExe cluster-verify @TracePaths --report-json $reportPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $reportPath) {
            $report = Get-Content $reportPath -Raw | ConvertFrom-Json -Depth 64
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

Write-Host "Building runtime + tool..."
cargo build -p runtime -p tool | Out-Host

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

Invoke-VerifyWithDiagnostics -ToolExe $toolExe -TracePath $Node1Trace -Label "cluster3-node1"
Invoke-VerifyWithDiagnostics -ToolExe $toolExe -TracePath $Node2Trace -Label "cluster3-node2"
Invoke-VerifyWithDiagnostics -ToolExe $toolExe -TracePath $Node3Trace -Label "cluster3-node3"

Invoke-ReplayCheck -RuntimeExe $runtimeExe -NodeId $Node1Id -TracePath $Node1Trace -ReplaySteps $ReplaySteps -ExtraArgs @(
    "--peer", "$Node2Id=127.0.0.1:$Node2Port",
    "--peer", "$Node3Id=127.0.0.1:$Node3Port"
)
Invoke-ReplayCheck -RuntimeExe $runtimeExe -NodeId $Node2Id -TracePath $Node2Trace -ReplaySteps $ReplaySteps -ExtraArgs @(
    "--peer", "$Node1Id=127.0.0.1:$Node1Port",
    "--peer", "$Node3Id=127.0.0.1:$Node3Port"
)
Invoke-ReplayCheck -RuntimeExe $runtimeExe -NodeId $Node3Id -TracePath $Node3Trace -ReplaySteps $ReplaySteps -ExtraArgs @(
    "--peer", "$Node1Id=127.0.0.1:$Node1Port",
    "--peer", "$Node2Id=127.0.0.1:$Node2Port"
)

Invoke-ClusterVerifyWithDiagnostics -ToolExe $toolExe -TracePaths @($Node1Trace, $Node2Trace, $Node3Trace)

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

if ($node1NetSend -lt 1 -or $node1NetRecv -lt 1 -or
    $node2NetSend -lt 1 -or $node2NetRecv -lt 1 -or
    $node3NetSend -lt 1 -or $node3NetRecv -lt 1) {
    throw "Expected network traffic on all nodes. Node1(NetSend=$node1NetSend NetRecv=$node1NetRecv) Node2(NetSend=$node2NetSend NetRecv=$node2NetRecv) Node3(NetSend=$node3NetSend NetRecv=$node3NetRecv)"
}

Write-Host "Cluster3 scenario passed. Node1(NetSend=$node1NetSend NetRecv=$node1NetRecv) Node2(NetSend=$node2NetSend NetRecv=$node2NetRecv) Node3(NetSend=$node3NetSend NetRecv=$node3NetRecv)"
