param(
    [string]$IndexPath = "demo-traces/cluster3-multi-fault-matrix.index.json",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function New-CountMap {
    return @{
        Drop = 0
        Delay = 0
        Reorder = 0
    }
}

function New-IssueBucket {
    return @{}
}

function Add-IssueCounts {
    param(
        [hashtable]$Bucket,
        $Issues
    )

    foreach ($issue in @($Issues)) {
        $code = [string]$issue.code
        if ([string]::IsNullOrWhiteSpace($code)) {
            $code = "unknown"
        }
        if (-not $Bucket.ContainsKey($code)) {
            $Bucket[$code] = 0
        }
        $Bucket[$code] += 1
    }
}

function Merge-IssueBucket {
    param(
        [hashtable]$Into,
        [hashtable]$From
    )

    foreach ($key in $From.Keys) {
        if (-not $Into.ContainsKey($key)) {
            $Into[$key] = 0
        }
        $Into[$key] += [int]$From[$key]
    }
}

function Get-IssueBucketTotal {
    param([hashtable]$Bucket)
    $total = 0
    foreach ($value in $Bucket.Values) {
        $total += [int]$value
    }
    return $total
}

function Get-InvariantIssueRollups {
    param(
        [string[]]$VerifyReportPaths,
        [string]$ClusterReportPath
    )

    $localBucket = New-IssueBucket
    $clusterBucket = New-IssueBucket
    $localReportCount = 0

    foreach ($path in $VerifyReportPaths) {
        if (-not (Test-Path $path)) {
            continue
        }
        $localReportCount += 1
        $report = Get-Content $path -Raw | ConvertFrom-Json -Depth 64
        Add-IssueCounts -Bucket $localBucket -Issues $report.issues
    }

    if (Test-Path $ClusterReportPath) {
        $clusterReport = Get-Content $ClusterReportPath -Raw | ConvertFrom-Json -Depth 64
        if ($localReportCount -eq 0 -and $null -ne $clusterReport.local) {
            foreach ($local in $clusterReport.local) {
                Add-IssueCounts -Bucket $localBucket -Issues $local.issues
            }
        }
        if ($null -ne $clusterReport.cluster) {
            Add-IssueCounts -Bucket $clusterBucket -Issues $clusterReport.cluster.issues
        }
    }

    return @{
        local_verify = $localBucket
        cluster_verify = $clusterBucket
    }
}

function New-NodeId {
    param([int]$Suffix)
    return ("00000000-0000-0000-0000-{0:x12}" -f $Suffix)
}

if (-not $SkipBuild) {
    Write-Host "[cluster3-multi-fault-matrix] building runtime + tool..."
    cargo build -p runtime -p tool | Out-Host
}
else {
    Write-Host "[cluster3-multi-fault-matrix] build skipped (using existing binaries)"
}

New-Item -ItemType Directory -Path (Join-Path $repoRoot "demo-traces") -Force | Out-Null

$profiles = @(
    @{
        Name = "dual12-delay-reorder"
        PrimaryTarget = "node1"
        BootstrapBurst = 3
        NodeSteps = 320
        ReplaySteps = 420
        MinClusterEvidence = 10
        Node1Delay = 1; Node1Reorder = 2; Node1Drop = 0
        Node2Delay = 1; Node2Reorder = 2; Node2Drop = 0
        Node3Delay = 0; Node3Reorder = 1; Node3Drop = 0
    },
    @{
        Name = "dual23-delay-drop"
        PrimaryTarget = "node2"
        BootstrapBurst = 3
        NodeSteps = 320
        ReplaySteps = 420
        MinClusterEvidence = 8
        Node1Delay = 0; Node1Reorder = 1; Node1Drop = 0
        Node2Delay = 1; Node2Reorder = 1; Node2Drop = 3
        Node3Delay = 1; Node3Reorder = 1; Node3Drop = 3
    },
    @{
        Name = "dual13-reorder-drop"
        PrimaryTarget = "node1"
        BootstrapBurst = 3
        NodeSteps = 320
        ReplaySteps = 420
        MinClusterEvidence = 8
        Node1Delay = 0; Node1Reorder = 3; Node1Drop = 4
        Node2Delay = 0; Node2Reorder = 1; Node2Drop = 0
        Node3Delay = 0; Node3Reorder = 2; Node3Drop = 4
    },
    @{
        Name = "tri-mixed-light"
        PrimaryTarget = "node1"
        BootstrapBurst = 4
        NodeSteps = 340
        ReplaySteps = 440
        MinClusterEvidence = 12
        Node1Delay = 1; Node1Reorder = 1; Node1Drop = 0
        Node2Delay = 1; Node2Reorder = 1; Node2Drop = 0
        Node3Delay = 0; Node3Reorder = 1; Node3Drop = 3
    },
    @{
        Name = "tri-delay-reorder-dense"
        PrimaryTarget = "node2"
        BootstrapBurst = 5
        NodeSteps = 360
        ReplaySteps = 480
        MinClusterEvidence = 16
        Node1Delay = 2; Node1Reorder = 2; Node1Drop = 0
        Node2Delay = 2; Node2Reorder = 3; Node2Drop = 0
        Node3Delay = 1; Node3Reorder = 2; Node3Drop = 0
    },
    @{
        Name = "tri-drop-mix-dense"
        PrimaryTarget = "node3"
        BootstrapBurst = 5
        NodeSteps = 360
        ReplaySteps = 480
        MinClusterEvidence = 12
        Node1Delay = 1; Node1Reorder = 2; Node1Drop = 5
        Node2Delay = 1; Node2Reorder = 2; Node2Drop = 4
        Node3Delay = 1; Node3Reorder = 2; Node3Drop = 3
    }
)

$scenarios = @()
for ($i = 0; $i -lt $profiles.Count; $i++) {
    $p = $profiles[$i]
    $activeNodes = @()
    $nodeFaultSpecs = @(
        @{ Name = "node1"; Delay = [int]$p.Node1Delay; Reorder = [int]$p.Node1Reorder; Drop = [int]$p.Node1Drop },
        @{ Name = "node2"; Delay = [int]$p.Node2Delay; Reorder = [int]$p.Node2Reorder; Drop = [int]$p.Node2Drop },
        @{ Name = "node3"; Delay = [int]$p.Node3Delay; Reorder = [int]$p.Node3Reorder; Drop = [int]$p.Node3Drop }
    )
    foreach ($spec in $nodeFaultSpecs) {
        if ([int]$spec.Delay -gt 0 -or [int]$spec.Reorder -gt 1 -or [int]$spec.Drop -gt 0) {
            $activeNodes += [string]$spec.Name
        }
    }
    if ($activeNodes.Count -lt 2) {
        throw ("profile {0} is not multi-target; active fault nodes={1}" -f $p.Name, ($activeNodes -join ","))
    }

    $scenarioIndex = $i + 1
    $portBase = 7900 + ($scenarioIndex * 10)
    $idBase = 0x900 + ($scenarioIndex * 10)
    $reportPrefix = "cluster3-multi-fault-$($p.Name)"

    $scenarios += @{
        Name = $p.Name
        ReportPrefix = $reportPrefix
        PrimaryTarget = $p.PrimaryTarget
        Node1Id = (New-NodeId -Suffix ($idBase + 1))
        Node2Id = (New-NodeId -Suffix ($idBase + 2))
        Node3Id = (New-NodeId -Suffix ($idBase + 3))
        Node1Port = ($portBase + 1)
        Node2Port = ($portBase + 2)
        Node3Port = ($portBase + 3)
        Node1Trace = "demo-traces/$reportPrefix-node1.trace.jsonl"
        Node2Trace = "demo-traces/$reportPrefix-node2.trace.jsonl"
        Node3Trace = "demo-traces/$reportPrefix-node3.trace.jsonl"
        Node1Delay = $p.Node1Delay
        Node1Reorder = $p.Node1Reorder
        Node1Drop = $p.Node1Drop
        Node2Delay = $p.Node2Delay
        Node2Reorder = $p.Node2Reorder
        Node2Drop = $p.Node2Drop
        Node3Delay = $p.Node3Delay
        Node3Reorder = $p.Node3Reorder
        Node3Drop = $p.Node3Drop
        BootstrapBurst = $p.BootstrapBurst
        NodeSteps = $p.NodeSteps
        ReplaySteps = $p.ReplaySteps
        MinClusterEvidence = $p.MinClusterEvidence
    }
}

$results = @()
for ($i = 0; $i -lt $scenarios.Count; $i++) {
    $s = $scenarios[$i]
    $summaryPath = "demo-traces/$($s.ReportPrefix).scenario.json"
    $node1VerifyReportPath = "demo-traces/$($s.ReportPrefix)-node1.verify.report.json"
    $node2VerifyReportPath = "demo-traces/$($s.ReportPrefix)-node2.verify.report.json"
    $node3VerifyReportPath = "demo-traces/$($s.ReportPrefix)-node3.verify.report.json"
    $clusterVerifyReportPath = "demo-traces/$($s.ReportPrefix).verify.report.json"

    Write-Host ("[cluster3-multi-fault-matrix] [{0}/{1}] running {2}" -f ($i + 1), $scenarios.Count, $s.Name)

    $scenarioError = $null
    try {
        & pwsh -File scripts/cluster3_fault_scenario.ps1 `
            -ScenarioName $s.Name `
            -ReportPrefix $s.ReportPrefix `
            -ScenarioReportPath $summaryPath `
            -Node1Id $s.Node1Id `
            -Node2Id $s.Node2Id `
            -Node3Id $s.Node3Id `
            -Node1Port $s.Node1Port `
            -Node2Port $s.Node2Port `
            -Node3Port $s.Node3Port `
            -Node1Trace $s.Node1Trace `
            -Node2Trace $s.Node2Trace `
            -Node3Trace $s.Node3Trace `
            -NodeSteps $s.NodeSteps `
            -ReplaySteps $s.ReplaySteps `
            -BootstrapBurst $s.BootstrapBurst `
            -MinActiveFaultNodes 2 `
            -MinClusterEvidence $s.MinClusterEvidence `
            -FaultTarget $s.PrimaryTarget `
            -FaultDelaySteps 0 `
            -FaultReorderWindow 1 `
            -FaultDropEvery 0 `
            -Node1FaultDelaySteps $s.Node1Delay `
            -Node1FaultReorderWindow $s.Node1Reorder `
            -Node1FaultDropEvery $s.Node1Drop `
            -Node2PerNodeDelaySteps $s.Node2Delay `
            -Node2PerNodeReorderWindow $s.Node2Reorder `
            -Node2PerNodeDropEvery $s.Node2Drop `
            -Node3FaultDelaySteps $s.Node3Delay `
            -Node3FaultReorderWindow $s.Node3Reorder `
            -Node3FaultDropEvery $s.Node3Drop `
            -SkipBuild | Out-Host

        if ($LASTEXITCODE -ne 0) {
            throw ("cluster3 multi fault scenario exited with code {0}" -f $LASTEXITCODE)
        }
    }
    catch {
        $scenarioError = $_.Exception.Message
        Write-Host ("[cluster3-multi-fault-matrix] scenario failed: {0}" -f $scenarioError)
    }

    $rollups = Get-InvariantIssueRollups `
        -VerifyReportPaths @($node1VerifyReportPath, $node2VerifyReportPath, $node3VerifyReportPath) `
        -ClusterReportPath $clusterVerifyReportPath

    if (Test-Path $summaryPath) {
        $summary = Get-Content $summaryPath -Raw | ConvertFrom-Json -Depth 64
    }
    else {
        $summary = [ordered]@{
            scenario = $s.Name
            ok = $false
            traces = @($s.Node1Trace, $s.Node2Trace, $s.Node3Trace)
            reports = @{
                node1_verify = $node1VerifyReportPath
                node2_verify = $node2VerifyReportPath
                node3_verify = $node3VerifyReportPath
                cluster_verify = $clusterVerifyReportPath
            }
            fault_config = @{
                target = $s.PrimaryTarget
            }
        }
    }

    if ($null -ne $scenarioError) {
        $summary | Add-Member -NotePropertyName ok -NotePropertyValue $false -Force
        $summary | Add-Member -NotePropertyName error -NotePropertyValue $scenarioError -Force
    }
    else {
        $summary | Add-Member -NotePropertyName error -NotePropertyValue $null -Force
    }

    $issueCounts = @{
        local_verify = (Get-IssueBucketTotal -Bucket $rollups.local_verify)
        cluster_verify = (Get-IssueBucketTotal -Bucket $rollups.cluster_verify)
    }
    $summary | Add-Member -NotePropertyName invariant_buckets -NotePropertyValue $rollups -Force
    $summary | Add-Member -NotePropertyName issue_counts -NotePropertyValue $issueCounts -Force

    $results += $summary
}

$passed = @($results | Where-Object { $_.ok })
$failed = @($results | Where-Object { -not $_.ok })

$aggregateFaultCountsTotal = New-CountMap
$aggregateFaultCountsByNode = @{
    node1 = (New-CountMap)
    node2 = (New-CountMap)
    node3 = (New-CountMap)
}
$aggregateTraffic = @{
    node1_net_send = 0
    node1_net_recv = 0
    node2_net_send = 0
    node2_net_recv = 0
    node3_net_send = 0
    node3_net_recv = 0
}
$aggregateClusterVerify = @{
    matched_recv = 0
    matched_drop = 0
    resolved_lineage_parents = 0
    external_lineage_parents = 0
    external_inbound = 0
    external_outbound = 0
}
$aggregateIssueBuckets = @{
    local_verify = (New-IssueBucket)
    cluster_verify = (New-IssueBucket)
}

foreach ($r in $results) {
    if ($null -ne $r.invariant_buckets) {
        Merge-IssueBucket -Into $aggregateIssueBuckets.local_verify -From $r.invariant_buckets.local_verify
        Merge-IssueBucket -Into $aggregateIssueBuckets.cluster_verify -From $r.invariant_buckets.cluster_verify
    }
}

foreach ($r in $passed) {
    foreach ($nodeName in @("node1", "node2", "node3")) {
        $aggregateFaultCountsByNode[$nodeName].Drop += [int]$r.fault_counts_by_node.$nodeName.Drop
        $aggregateFaultCountsByNode[$nodeName].Delay += [int]$r.fault_counts_by_node.$nodeName.Delay
        $aggregateFaultCountsByNode[$nodeName].Reorder += [int]$r.fault_counts_by_node.$nodeName.Reorder
    }
    $aggregateFaultCountsTotal.Drop += [int]$r.fault_counts_by_node.node1.Drop + [int]$r.fault_counts_by_node.node2.Drop + [int]$r.fault_counts_by_node.node3.Drop
    $aggregateFaultCountsTotal.Delay += [int]$r.fault_counts_by_node.node1.Delay + [int]$r.fault_counts_by_node.node2.Delay + [int]$r.fault_counts_by_node.node3.Delay
    $aggregateFaultCountsTotal.Reorder += [int]$r.fault_counts_by_node.node1.Reorder + [int]$r.fault_counts_by_node.node2.Reorder + [int]$r.fault_counts_by_node.node3.Reorder

    $aggregateTraffic.node1_net_send += [int]$r.traffic.node1_net_send
    $aggregateTraffic.node1_net_recv += [int]$r.traffic.node1_net_recv
    $aggregateTraffic.node2_net_send += [int]$r.traffic.node2_net_send
    $aggregateTraffic.node2_net_recv += [int]$r.traffic.node2_net_recv
    $aggregateTraffic.node3_net_send += [int]$r.traffic.node3_net_send
    $aggregateTraffic.node3_net_recv += [int]$r.traffic.node3_net_recv

    $aggregateClusterVerify.matched_recv += [int]$r.cluster_verify.matched_recv
    $aggregateClusterVerify.matched_drop += [int]$r.cluster_verify.matched_drop
    $aggregateClusterVerify.resolved_lineage_parents += [int]$r.cluster_verify.resolved_lineage_parents
    $aggregateClusterVerify.external_lineage_parents += [int]$r.cluster_verify.external_lineage_parents
    $aggregateClusterVerify.external_inbound += [int]$r.cluster_verify.external_inbound
    $aggregateClusterVerify.external_outbound += [int]$r.cluster_verify.external_outbound
}

$aggregateIssueCounts = @{
    local_verify = (Get-IssueBucketTotal -Bucket $aggregateIssueBuckets.local_verify)
    cluster_verify = (Get-IssueBucketTotal -Bucket $aggregateIssueBuckets.cluster_verify)
}

$index = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    matrix = "cluster3-multi-target-fault"
    scenario_count = $results.Count
    passed_count = $passed.Count
    failed_count = $failed.Count
    aggregate = @{
        fault_counts_total = $aggregateFaultCountsTotal
        fault_counts_by_node = $aggregateFaultCountsByNode
        traffic = $aggregateTraffic
        cluster_verify = $aggregateClusterVerify
        invariant_buckets = $aggregateIssueBuckets
        issue_counts = $aggregateIssueCounts
    }
    scenarios = $results
}

$indexJson = $index | ConvertTo-Json -Depth 64
[System.IO.File]::WriteAllText((Join-Path $repoRoot $IndexPath), $indexJson)

Write-Host ("[cluster3-multi-fault-matrix] index written: {0}" -f $IndexPath)
Write-Host ("[cluster3-multi-fault-matrix] scenarios passed: {0}/{1}" -f $passed.Count, $results.Count)

if ($failed.Count -gt 0) {
    $failedNames = @($failed | ForEach-Object { [string]$_.scenario })
    throw ("cluster3-multi-fault-matrix failed scenarios: {0}" -f ($failedNames -join ", "))
}
