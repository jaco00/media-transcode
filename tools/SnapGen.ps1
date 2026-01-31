# ==========================================
# Tool Name: SnapGen (Simplified)
# Usage: .\SnapGen.ps1 -SourcePath "C:\Orig" -SidecarPath "C:\Side"
# ==========================================

param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage="Please specify the Source (Originals) path.")]
    [string]$SourcePath,

    [Parameter(Mandatory=$true, Position=1, HelpMessage="Please specify the Sidecar destination path.")]
    [string]$SidecarPath,

    [int]$DefaultQuality = 82,
    [string]$DefaultRes = "3840x2160",
    [string]$MagickOps = "-auto-orient",
    [int]$MaxThreads=0,
    [bool]$ShowDetails = $false,
    [switch]$Overwrite,
    [switch]$Quiet

)

$ReservedCores = 2

. ([System.IO.Path]::Combine($PSScriptRoot, "..", "helpers.ps1"))

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $MaxThreads = 1
    Write-Host "⏳ Serial Mode (Legacy PowerShell detected)" -ForegroundColor Red
}else{
    if ($MaxThreads -le 0) {
        $cpuCount = [Environment]::ProcessorCount
        $MaxThreads = if ($cpuCount -le 4) { 1 } else { $cpuCount - $ReservedCores }
        Write-Host "🚀 Parallel Mode ($MaxThreads threads)" -ForegroundColor Green
    }
}

$MagickExe  = (Resolve-ToolExe "magick")

# 1. Prompt for Quality
if (-not $Quiet){
    $userInputQuality = Read-Host "Set JPG Quality (1-100) [Default: $DefaultQuality]"
    $finalQuality = if ([string]::IsNullOrWhiteSpace($userInputQuality)) { $DefaultQuality } else { [int]$userInputQuality }

    # 2. Prompt for Resolution
    $userInputRes = Read-Host "Set Max Resolution [Default: $DefaultRes]"
    $finalRes = if ([string]::IsNullOrWhiteSpace($userInputRes)) { $DefaultRes } else { $userInputRes }
    $finalRes = $finalRes -replace '[,\*/\\xX\s]+', 'x'
}else{
    $finalQuality=$DefaultQuality
    $finalRes=$DefaultRes
}

$maxSizeArg = $finalRes + ">"

$SourcePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourcePath)
$SidecarPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SidecarPath)

# --- Path Validation ---
if (-not (Test-Path $SourcePath)) {
    Write-Error "SourcePath '$SourcePath' not found."
    return
}
if (-not (Test-Path $SidecarPath)) {
    New-Item -ItemType Directory -Path $SidecarPath -Force | Out-Null
}

Write-Host "`n [SUMMARY]" -ForegroundColor Cyan
Write-Host ("─" * 50) -ForegroundColor DarkGray
Write-Host "  Source:      $SourcePath"
Write-Host "  Sidecar:     $SidecarPath"
Write-Host "  Engine:      $MagickOps (Quality: $finalQuality, Res: $finalRes)"
Write-Host "  MaxThreads:  $MaxThreads"
Write-Host ""

$SnapConfig = [PSCustomObject]@{
    MagickExe   = $MagickExe
    MagickOps   = $MagickOps
    Quality     = $finalQuality
    ResLimit    = $maxSizeArg
    Overwrite   = $Overwrite   
    ShowDetails = $ShowDetails
}

# --- Execution Stats ---
$startTime = Get-Date

# --- Core Loop (Full Scan) ---
$tasks = New-Object System.Collections.Generic.List[PSCustomObject]
$spinner = New-ConsoleSpinner -Title "Scanning for images in $SourcePath" -SamplingRate 2500

Get-ChildItem -Path $SourcePath -Recurse -File -Include *.jpg, *.jpeg, *.png, *.heic, *.webp, *.avif | ForEach-Object {
    &$spinner $_.FullName


    $relPath = $_.FullName.Substring($SourcePath.Length).TrimStart('\')
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if ($relPath.StartsWith($sep)) {
        $relPath = $relPath.Substring(1)
    }

    $destPath = Join-Path $SidecarPath ($relPath + ".jpg")
    if ($Overwrite -or  -not(Test-Path $destPath)) {
        $tasks.Add([PSCustomObject]@{
            Src    = $_.FullName
            Dst    = $destPath
            DstDir = Split-Path $destPath
        })
    }
}

&$spinner "Done" -Finalize

if ($tasks.Count -gt 0) {
    Write-Host "`nTotal Tasks: $($tasks.Count)" -ForegroundColor Cyan
    if(-not $Quiet){
        
        while ($true) {
            $ans = Read-Host " 👉 Start processing? (y/n)"
            if ($ans.ToLower() -eq 'y') {
                break 
            }
            elseif ($ans.ToLower() -eq 'n') {
                Write-Host " 🛑 Operation cancelled by user." -ForegroundColor Yellow
                return 
            }
            else {
                Write-Host " ⚠️  Invalid input! Please enter 'y' to continue or 'n' to exit." -ForegroundColor Red
            }
        }
    }
}
else {
    Write-Host "`n ☕ No new images found. Everything is up to date." -ForegroundColor Green
    return
}

function Invoke-SnapProcess {
    param(
        [Parameter(Mandatory)]
        [object]$Task,

        [Parameter(Mandatory)]
        [object]$Config
    )
    
    $res = [PSCustomObject]@{
        Success   = $false
        SrcBytes  = 0
        NewBytes  = 0
        File      = $Task.Src
        StartTime = Get-Date
    }

    try {
        $dstDir=Split-Path $Task.Dst
        if (-not (Test-Path $dstDir)) { New-Item $dstDir -ItemType Directory -Force | Out-Null }
        
        $srcFile = Get-Item $Task.Src
        $res.SrcBytes = $srcFile.Length
        
        $opsArray = $Config.MagickOps.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
        $allArgs = @($Task.Src) + $opsArray + @("-resize", $Config.ResLimit, "-quality", $Config.Quality, $Task.Dst)
        if ($Config.ShowDetails) {
            $cmdString = "$ExePath " + ($allArgs -join " ")
            Write-Host "  > CMD: $cmdString" -ForegroundColor DarkGray
        }

        $output = & $Config.MagickExe $allArgs 2>&1
        $currentExitCode = $LASTEXITCODE

        # 2. Check for Success (Exit Code 0 and Output File exists)
        if ($currentExitCode -eq 0 -and (Test-Path $Task.Dst)) {
            $res.NewBytes = (Get-Item $Task.Dst).Length
            $res.Success  = $true
        }else{
            Write-Host "`n  [ERROR] Execution Failed" -ForegroundColor Red
            Write-Host "  Command: $displayCmd" -ForegroundColor Red
            Write-Host "  ExitCode: $currentExitCode" -ForegroundColor Red
            if ($output) {
                Write-Host "  Output: $($output -join "`n")" -ForegroundColor Red
            }
        }
    } catch {
        $res.Success = $false
    }
    return $res
}


$counter = 0
$total = $tasks.Count
$startTime = Get-Date

$SrcBytes =0L 
$NewBytes =0L 
$Success=0
$Failed=0

# --- Execution Engine ---
if ($MaxThreads -gt 1) {
    $funcDef = "function Invoke-SnapProcess { ${function:Invoke-SnapProcess} }"
    
    $tasks | ForEach-Object -Parallel {
        Invoke-Expression $using:funcDef
        Invoke-SnapProcess -Task $_ -Config $using:SnapConfig 
    } -ThrottleLimit $MaxThreads | ForEach-Object {
        $res = $_
        $counter++
        if ($res.Success) {
            $SrcBytes += $res.SrcBytes
            $NewBytes += $res.NewBytes
            $Success++
            $elapsed = [math]::Round(((Get-Date) - $res.StartTime).TotalSeconds, 2)
            # Using your display function
            Write-CompressionStatus -File $res.File -SrcBytes $res.SrcBytes -NewBytes $res.NewBytes -Index $counter -Total $total -ElapsedSeconds $elapsed
        } else {
            $Failed++
            Write-Host " ✖ Processing Failed ($counter/$total): $($res.File)" -ForegroundColor Red
        }
    }
}
else {
    foreach ($task in $tasks) {
        $counter++
        $res = Invoke-SnapProcess -Task $task -Config $SnapConfig
        $type = $res.Type

        if ($res.Success) {
            $SrcBytes += $res.SrcBytes
            $NewBytes += $res.NewBytes
            $Success++
            $elapsed = [math]::Round(((Get-Date) - $res.StartTime).TotalSeconds, 2)
            # Using your display function
            Write-CompressionStatus -File $res.File -SrcBytes $res.SrcBytes -NewBytes $res.NewBytes -Index $counter -Total $total -ElapsedSeconds $elapsed
        } else {
            $Failed++
            Write-Host " ✖ Processing Failed ($counter/$total): $($res.File)" -ForegroundColor Red
        }
    }
}

$duration = (Get-Date) - $startTime
$savedBytes = $SrcBytes - $NewBytes
$ratio = if ($SrcBytes -gt 0) { [math]::Round(($savedBytes / $SrcBytes) * 100, 1) } else { 0 }
$failColor = "Gray"
if ($Failed -gt 0) { $failColor = "Red" }

Write-Host ""
Write-Host " [FINAL REPORT]" -ForegroundColor Cyan
Write-Host ("─" * 50) -ForegroundColor DarkGray
Write-Host "  Files Processed : $Success" -ForegroundColor White
Write-Host "  Files Failed    : $Failed" -ForegroundColor $failColor
Write-Host "  Total Duration  : $($duration.Minutes)m $($duration.Seconds)s" -ForegroundColor White
Write-Host "" 
Write-Host "  Original Size   : $(Format-Size $SrcBytes) "
Write-Host "  Compressed Size : $(Format-Size $NewBytes)"
Write-Host "  Space Saved     : $(Format-Size $savedBytes) ($ratio%)" -ForegroundColor Green
