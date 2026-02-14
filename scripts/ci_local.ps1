param(
    [switch]$SkipFaultMatrix,
    [switch]$SkipLean
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$env:CARGO_INCREMENTAL = "0"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

Write-Host "[1/4] cargo fmt --check"
cargo fmt --all -- --check | Out-Host

Write-Host "[2/4] cargo check"
cargo check --workspace --all-targets --locked | Out-Host

Write-Host "[3/4] cargo test"
cargo test --workspace --locked | Out-Host

if (-not $SkipFaultMatrix) {
    Write-Host "[4/4] fault matrix"
    pwsh -File scripts/fault_matrix.ps1 | Out-Host
}
else {
    Write-Host "[4/4] fault matrix skipped"
}

if (-not $SkipLean) {
    $lakeCmd = Get-Command lake -ErrorAction SilentlyContinue
    if ($null -ne $lakeCmd) {
        Write-Host "[5/5] lean kernel build"
        Push-Location semantics-lean
        try {
            lake build | Out-Host
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Host "[5/5] lean kernel build skipped (lake not installed)"
    }
}
else {
    Write-Host "[5/5] lean kernel build skipped"
}

Write-Host "Local CI checks passed."
