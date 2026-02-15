param(
    [string]$IndexPath = "demo-traces/cluster3-choreography-fault-matrix.index.json",
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
    Write-Host "[cluster3-choreography-matrix] building runtime + tool..."
    cargo build -p runtime -p tool | Out-Host
}
else {
    Write-Host "[cluster3-choreography-matrix] build skipped (using existing binaries)"
}

New-Item -ItemType Directory -Path (Join-Path $repoRoot "demo-traces") -Force | Out-Null

$profiles = @(
    @{
        Name = "partition-recover-12"
        Choreography = "partition_to_recovery"
        PrimaryTarget = "node1"
        BootstrapBurst = 5
        NodeSteps = 420
        ReplaySteps = 560
        MinClusterEvidence = 14
        MinActiveFaultNodes = 2
        Node1Phases = @("0:90:1:0:1", "91:*:0:1:2")
        Node2Phases = @("0:90:1:0:1", "91:*:0:1:2")
        Node3Phases = @("0:90:0:1:2", "91:*:0:0:1")
    },
    @{
        Name = "wave-rotation-123"
        Choreography = "target_rotation_wave"
        PrimaryTarget = "node1"
        BootstrapBurst = 5
        NodeSteps = 420
        ReplaySteps = 560
        MinClusterEvidence = 12
        MinActiveFaultNodes = 3
        Node1Phases = @("0:80:4:1:2")
        Node2Phases = @("81:160:4:1:2")
        Node3Phases = @("161:*:4:1:2")
    },
    @{
        Name = "tri-churn-burst"
        Choreography = "tri_churn_burst"
        PrimaryTarget = "node2"
        BootstrapBurst = 6
        NodeSteps = 440
        ReplaySteps = 600
        MinClusterEvidence = 16
        MinActiveFaultNodes = 3
        Node1Phases = @("0:110:0:2:2", "111:220:5:1:2", "221:*:0:0:1")
        Node2Phases = @("0:110:0:2:3", "111:220:4:1:2", "221:*:0:0:1")
        Node3Phases = @("0:110:0:2:2", "111:220:5:1:3", "221:*:0:0:1")
    },
    @{
        Name = "recover-tail-23"
        Choreography = "dual_recovery_tail"
        PrimaryTarget = "node3"
        BootstrapBurst = 6
        NodeSteps = 440
        ReplaySteps = 600
        MinClusterEvidence = 14
        MinActiveFaultNodes = 2
        Node1Phases = @("0:120:0:1:2", "121:*:0:0:1")
        Node2Phases = @("0:120:3:1:2", "121:*:0:0:1")
        Node3Phases = @("0:120:3:1:2", "121:*:0:0:1")
    }
)

$scenarios = @()
for ($i = 0; $i -lt $profiles.Count; $i++) {
    $p = $profiles[$i]
    $scenarioIndex = $i + 1
    $portBase = 8300 + ($scenarioIndex * 10)
    $idBase = 0xB00 + ($scenarioIndex * 10)
    $reportPrefix = "cluster3-choreo-$($p.Name)"

    $scenarios += @{
        Name = $p.Name
        Choreography = $p.Choreography
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
        Node1Phases = @($p.Node1Phases)
        Node2Phases = @($p.Node2Phases)
        Node3Phases = @($p.Node3Phases)
        BootstrapBurst = $p.BootstrapBurst
        NodeSteps = $p.NodeSteps
        ReplaySteps = $p.ReplaySteps
        MinClusterEvidence = $p.MinClusterEvidence
        MinActiveFaultNodes = $p.MinActiveFaultNodes
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

    Write-Host ("[cluster3-choreography-matrix] [{0}/{1}] running {2}" -f ($i + 1), $scenarios.Count, $s.Name)

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
            -MinActiveFaultNodes $s.MinActiveFaultNodes `
            -MinClusterEvidence $s.MinClusterEvidence `
            -FaultTarget $s.PrimaryTarget `
            -FaultDelaySteps 0 `
            -FaultReorderWindow 1 `
            -FaultDropEvery 0 `
            -Node1FaultDelaySteps 0 `
            -Node1FaultReorderWindow 1 `
            -Node1FaultDropEvery 0 `
            -Node2PerNodeDelaySteps 0 `
            -Node2PerNodeReorderWindow 1 `
            -Node2PerNodeDropEvery 0 `
            -Node3FaultDelaySteps 0 `
            -Node3FaultReorderWindow 1 `
            -Node3FaultDropEvery 0 `
            -Node1FaultPhases ($s.Node1Phases -join ",") `
            -Node2FaultPhases ($s.Node2Phases -join ",") `
            -Node3FaultPhases ($s.Node3Phases -join ",") `
            -SkipBuild | Out-Host

        if ($LASTEXITCODE -ne 0) {
            throw ("cluster3 choreography scenario exited with code {0}" -f $LASTEXITCODE)
        }
    }
    catch {
        $scenarioError = $_.Exception.Message
        Write-Host ("[cluster3-choreography-matrix] scenario failed: {0}" -f $scenarioError)
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

    $summary | Add-Member -NotePropertyName fault_choreography -NotePropertyValue $s.Choreography -Force

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
$aggregateChoreography = @{}

foreach ($r in $results) {
    if ($null -ne $r.invariant_buckets) {
        Merge-IssueBucket -Into $aggregateIssueBuckets.local_verify -From $r.invariant_buckets.local_verify
        Merge-IssueBucket -Into $aggregateIssueBuckets.cluster_verify -From $r.invariant_buckets.cluster_verify
    }

    $choreo = [string]$r.fault_choreography
    if (-not $aggregateChoreography.ContainsKey($choreo)) {
        $aggregateChoreography[$choreo] = @{
            scenario_count = 0
            passed_count = 0
            failed_count = 0
        }
    }
    $aggregateChoreography[$choreo].scenario_count += 1
    if ($r.ok) {
        $aggregateChoreography[$choreo].passed_count += 1
    }
    else {
        $aggregateChoreography[$choreo].failed_count += 1
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
    matrix = "cluster3-fault-choreography"
    scenario_count = $results.Count
    passed_count = $passed.Count
    failed_count = $failed.Count
    aggregate = @{
        fault_counts_total = $aggregateFaultCountsTotal
        fault_counts_by_node = $aggregateFaultCountsByNode
        traffic = $aggregateTraffic
        cluster_verify = $aggregateClusterVerify
        choreography = $aggregateChoreography
        invariant_buckets = $aggregateIssueBuckets
        issue_counts = $aggregateIssueCounts
    }
    scenarios = $results
}

$indexJson = $index | ConvertTo-Json -Depth 64
[System.IO.File]::WriteAllText((Join-Path $repoRoot $IndexPath), $indexJson)

Write-Host ("[cluster3-choreography-matrix] index written: {0}" -f $IndexPath)
Write-Host ("[cluster3-choreography-matrix] scenarios passed: {0}/{1}" -f $passed.Count, $results.Count)

if ($failed.Count -gt 0) {
    $failedNames = @($failed | ForEach-Object { [string]$_.scenario })
    throw ("cluster3-choreography-matrix failed scenarios: {0}" -f ($failedNames -join ", "))
}
