param(
    [string]$Node1Id = "00000000-0000-0000-0000-000000000201",
    [string]$Node2Id = "00000000-0000-0000-0000-000000000202",
    [int]$Node2Port = 7102,
    [string]$Node1Trace = "demo-traces/fault-node1.trace.jsonl",
    [string]$Node2Trace = "demo-traces/fault-node2.trace.jsonl",
    [int]$Node1Steps = 40,
    [int]$Node2Steps = 160,
    [int]$StartupTimeoutSec = 20,
    [int]$ShutdownTimeoutSec = 40
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

$node2Args = @(
    "--node-id", $Node2Id,
    "--listen", "127.0.0.1:$Node2Port",
    "--trace", $Node2Trace,
    "--fault-drop-every", "1",
    "--idle-sleep-ms", "25",
    "--steps", $Node2Steps.ToString()
)

Write-Host "Starting node2 listener on 127.0.0.1:$Node2Port ..."
$node2 = Start-Process -FilePath $runtimeExe -ArgumentList $node2Args -PassThru -WindowStyle Hidden

try {
    Wait-TcpPort -Hostname "127.0.0.1" -Port $Node2Port -TimeoutSec $StartupTimeoutSec
    Write-Host "Node2 is accepting connections."

    $node1Args = @(
        "--node-id", $Node1Id,
        "--peer", "$Node2Id=127.0.0.1:$Node2Port",
        "--trace", $Node1Trace,
        "--bootstrap-hello",
        "--steps", $Node1Steps.ToString()
    )

    Write-Host "Running node1 sender..."
    & $runtimeExe @node1Args | Out-Host

    Write-Host "Waiting for node2 shutdown..."
    Wait-Process -Id $node2.Id -Timeout $ShutdownTimeoutSec
}
finally {
    if ($node2 -and -not $node2.HasExited) {
        Stop-Process -Id $node2.Id -Force
    }
}

if (-not (Test-Path $Node2Trace)) {
    throw "Expected trace not found: $Node2Trace"
}

Write-Host "Trace summary:"
& $toolExe $Node2Trace | Out-Host
& $toolExe verify $Node2Trace | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Trace verify failed for $Node2Trace"
}
& $toolExe verify $Node1Trace | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Trace verify failed for $Node1Trace"
}

$events = Get-Content $Node2Trace |
    Where-Object { $_.Trim() -ne "" } |
    ForEach-Object { $_ | ConvertFrom-Json -Depth 32 }

$faultInjected = ($events | Where-Object { $_.kind.FaultInjected }).Count
$netRecv = ($events | Where-Object { $_.kind.NetRecv }).Count

if ($faultInjected -lt 1) {
    throw "Assertion failed: expected at least one FaultInjected event in $Node2Trace"
}
if ($netRecv -gt 0) {
    throw "Assertion failed: expected zero NetRecv events when --fault-drop-every 1 is active; got $netRecv"
}

Write-Host "Assertions passed: FaultInjected=$faultInjected NetRecv=$netRecv"
