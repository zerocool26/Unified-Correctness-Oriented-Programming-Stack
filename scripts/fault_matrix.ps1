param(
    [string]$Node1Id = "00000000-0000-0000-0000-000000000301",
    [string]$Node2Id = "00000000-0000-0000-0000-000000000302",
    [int]$StartupTimeoutSec = 20,
    [int]$ShutdownTimeoutSec = 60
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

function Invoke-FaultScenario {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [Parameter(Mandatory = $true)]
        [string[]]$Node2FaultArgs,
        [Parameter(Mandatory = $true)]
        [int]$BootstrapBurst,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedAction
    )

    $node1Trace = "demo-traces/$Name-node1.trace.jsonl"
    $node2Trace = "demo-traces/$Name-node2.trace.jsonl"

    Remove-Item $node1Trace, $node2Trace -ErrorAction SilentlyContinue

    $runtimeExe = Join-Path $repoRoot "target\debug\runtime.exe"
    $toolExe = Join-Path $repoRoot "target\debug\tool.exe"

    $node2Args = @(
        "--node-id", $Node2Id,
        "--listen", "127.0.0.1:$Port",
        "--trace", $node2Trace,
        "--idle-sleep-ms", "25",
        "--steps", "240"
    ) + $Node2FaultArgs

    Write-Host "[$Name] starting node2 listener on 127.0.0.1:$Port ..."
    $node2 = Start-Process -FilePath $runtimeExe -ArgumentList $node2Args -PassThru -WindowStyle Hidden

    try {
        Wait-TcpPort -Hostname "127.0.0.1" -Port $Port -TimeoutSec $StartupTimeoutSec

        $node1Args = @(
            "--node-id", $Node1Id,
            "--peer", "$Node2Id=127.0.0.1:$Port",
            "--trace", $node1Trace,
            "--bootstrap-hello",
            "--bootstrap-burst", $BootstrapBurst.ToString(),
            "--steps", "80"
        )

        Write-Host "[$Name] running node1 sender..."
        & $runtimeExe @node1Args | Out-Host

        Wait-Process -Id $node2.Id -Timeout $ShutdownTimeoutSec
    }
    finally {
        if ($node2 -and -not $node2.HasExited) {
            Stop-Process -Id $node2.Id -Force
        }
    }

    if (-not (Test-Path $node2Trace)) {
        throw "[$Name] missing expected trace: $node2Trace"
    }

    $events = Get-Content $node2Trace |
        Where-Object { $_.Trim() -ne "" } |
        ForEach-Object { $_ | ConvertFrom-Json -Depth 32 }

    $fiEvents = @($events | Where-Object { $_.kind.FaultInjected })
    $netRecvEvents = @($events | Where-Object { $_.kind.NetRecv })

    $actionCounts = @{
        Drop = 0
        Delay = 0
        Reorder = 0
    }

    foreach ($evt in $fiEvents) {
        $name = Get-ActionName -ActionObj $evt.kind.FaultInjected.action
        if ($actionCounts.ContainsKey($name)) {
            $actionCounts[$name] += 1
        }
    }

    if ($fiEvents.Count -lt 1) {
        throw "[$Name] assertion failed: expected at least one FaultInjected event"
    }
    if ($actionCounts[$ExpectedAction] -lt 1) {
        throw "[$Name] assertion failed: expected action $ExpectedAction, got counts $($actionCounts | ConvertTo-Json -Compress)"
    }

    switch ($ExpectedAction) {
        "Drop" {
            if ($netRecvEvents.Count -ne 0) {
                throw "[$Name] assertion failed: expected NetRecv=0 under drop policy, got $($netRecvEvents.Count)"
            }
        }
        "Delay" {
            if ($netRecvEvents.Count -lt 1) {
                throw "[$Name] assertion failed: expected NetRecv>=1 under delay policy"
            }
        }
        "Reorder" {
            if ($netRecvEvents.Count -lt 2) {
                throw "[$Name] assertion failed: expected NetRecv>=2 under reorder policy"
            }
        }
    }

    Write-Host "[$Name] replay check..."
    & $runtimeExe --replay --node-id $Node2Id --trace $node2Trace --steps 240 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "[$Name] replay check failed for $node2Trace"
    }

    Write-Host "[$Name] trace summary:"
    & $toolExe $node2Trace | Out-Host
    Invoke-VerifyWithDiagnostics -ToolExe $toolExe -TracePath $node2Trace -Label "$Name-node2"
    Invoke-VerifyWithDiagnostics -ToolExe $toolExe -TracePath $node1Trace -Label "$Name-node1"
    Write-Host "[$Name] assertions passed. FaultInjected=$($fiEvents.Count) NetRecv=$($netRecvEvents.Count)"
}

Write-Host "Building runtime + tool..."
cargo build -p runtime -p tool | Out-Host

New-Item -ItemType Directory -Path (Join-Path $repoRoot "demo-traces") -Force | Out-Null

Invoke-FaultScenario -Name "drop" -Port 7201 -Node2FaultArgs @("--fault-drop-every", "1") -BootstrapBurst 3 -ExpectedAction "Drop"
Invoke-FaultScenario -Name "delay" -Port 7202 -Node2FaultArgs @("--fault-delay-steps", "2") -BootstrapBurst 2 -ExpectedAction "Delay"
Invoke-FaultScenario -Name "reorder" -Port 7203 -Node2FaultArgs @("--fault-reorder-window", "2") -BootstrapBurst 3 -ExpectedAction "Reorder"

Write-Host "All fault scenarios passed."
