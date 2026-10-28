# Export Throne ABI from Foundry artifacts to backend and frontend.
# Usage:
#   powershell -File scripts/export_abi.ps1
#   powershell -File scripts/export_abi.ps1 -Check
param(
    [switch]$Check
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$contracts = Join-Path $root "contracts"
$targets = @(
    (Join-Path $root "backend\app\abi\Throne.json"),
    (Join-Path $root "frontend\src\abi\Throne.json")
)

$env:PATH = "$env:USERPROFILE\.foundry\bin;C:\Program Files\Git\bin;$env:PATH"
Push-Location $contracts
try {
    forge build | Out-Host
    $abiText = forge inspect src/Throne.sol:Throne abi
} finally {
    Pop-Location
}

# forge inspect --json may wrap as a JSON string; normalize to a compact array.
$parsed = $abiText | ConvertFrom-Json
if ($parsed -is [string]) {
    $parsed = $parsed | ConvertFrom-Json
}
$normalized = ($parsed | ConvertTo-Json -Depth 20 -Compress) + "`n"

function Get-NormalizedFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($path).Trim()
    if (-not $raw) { return $null }
    $obj = $raw | ConvertFrom-Json
    return ($obj | ConvertTo-Json -Depth 20 -Compress) + "`n"
}

$failed = $false
foreach ($dest in $targets) {
    $dir = Split-Path $dest
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    if ($Check) {
        $existing = Get-NormalizedFile $dest
        if ($existing -ne $normalized) {
            Write-Error "ABI drift: $dest does not match forge inspect src/Throne.sol:Throne abi"
            $failed = $true
        } else {
            Write-Host "OK $dest"
        }
    } else {
        [System.IO.File]::WriteAllText($dest, $normalized)
        Write-Host "Wrote $dest"
    }
}

if ($Check -and $failed) { exit 1 }
