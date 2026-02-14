param(
    [string]$Node1Id = "00000000-0000-0000-0000-000000000401",
    [string]$Node2Id = "00000000-0000-0000-0000-000000000402",
    [int]$Node1Port = 7301,
    [int]$Node2Port = 7302,
    [string]$Node1Trace = "demo-traces/cluster-node1.trace.jsonl",
    [string]$Node2Trace = "demo-traces/cluster-node2.trace.jsonl",
    [int]$NodeSteps = 220,
    [int]$IdleSleepMs = 10,
    [int]$StartupWaitMs = 1500,
    [int]$BootstrapBurst = 2,
    [int]$StartupTimeoutSec = 20,
    [int]$ShutdownTimeoutSec = 90
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

Write-Host "Starting node1 listener on 127.0.0.1:$Node1Port ..."
$node1 = Start-Process -FilePath $runtimeExe -ArgumentList $node1Args -PassThru -WindowStyle Hidden
Write-Host "Starting node2 listener on 127.0.0.1:$Node2Port ..."
$node2 = Start-Process -FilePath $runtimeExe -ArgumentList $node2Args -PassThru -WindowStyle Hidden

try {
    Wait-TcpPort -Hostname "127.0.0.1" -Port $Node1Port -TimeoutSec $StartupTimeoutSec
    Wait-TcpPort -Hostname "127.0.0.1" -Port $Node2Port -TimeoutSec $StartupTimeoutSec

    Wait-Process -Id $node1.Id -Timeout $ShutdownTimeoutSec
    Wait-Process -Id $node2.Id -Timeout $ShutdownTimeoutSec
}
finally {
    if ($node1 -and -not $node1.HasExited) {
        Stop-Process -Id $node1.Id -Force
    }
    if ($node2 -and -not $node2.HasExited) {
        Stop-Process -Id $node2.Id -Force
    }
}

if (-not (Test-Path $Node1Trace)) {
    throw "Expected trace not found: $Node1Trace"
}
if (-not (Test-Path $Node2Trace)) {
    throw "Expected trace not found: $Node2Trace"
}

Write-Host "Node trace summaries:"
& $toolExe $Node1Trace | Out-Host
& $toolExe $Node2Trace | Out-Host

& $toolExe verify $Node1Trace | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Trace verify failed for $Node1Trace"
}
& $toolExe verify $Node2Trace | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Trace verify failed for $Node2Trace"
}

& $toolExe cluster-verify $Node1Trace $Node2Trace | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Cluster verify failed for $Node1Trace and $Node2Trace"
}

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

if ($node1NetSend -lt 1 -or $node1NetRecv -lt 1 -or $node2NetSend -lt 1 -or $node2NetRecv -lt 1) {
    throw "Expected bidirectional network traffic. Node1(NetSend=$node1NetSend NetRecv=$node1NetRecv) Node2(NetSend=$node2NetSend NetRecv=$node2NetRecv)"
}

Write-Host "Cluster scenario passed. Node1(NetSend=$node1NetSend NetRecv=$node1NetRecv) Node2(NetSend=$node2NetSend NetRecv=$node2NetRecv)"
