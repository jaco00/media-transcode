<#
============================================================
File Set Operation Tool
============================================================

This tool performs set-based operations on files between
two directories:

- A : Source / Full Set
- B : Reference / Selected Set
- C : Output directory for moved files

------------------------------------------------------------
Mode 1: refine (keep matched)
------------------------------------------------------------
Description:
  Refine A by intersecting with B, prune unmatched files.

Mathematical definition:
  A := A ∩ B
  C := A − B

Engineering meaning:
  - Keep only files in A that have a match in B
  - Files in A that do NOT exist in B are moved to C

Typical use case:
  - Keep only selected / approved / transcoded files
  - Remove leftovers, raws, or obsolete files

------------------------------------------------------------
Mode 2: exclude (remove matched)
------------------------------------------------------------
Description:
  Exclude B from A, extract intersection.

Mathematical definition:
  A := A − B
  C := A ∩ B

Engineering meaning:
  - Remove files from A that already exist in B
  - Matched files are moved to C

Typical use case:
  - Remove already-processed files
  - Separate duplicates or completed items

------------------------------------------------------------
Notes:
- File equality logic is abstracted via Test-FileEqual()
- Comparison strategy (hash, metadata, ffprobe, etc.)
  can be swapped without changing set logic
============================================================
#>


param(
    [Parameter(Mandatory)]
    [string]$APath,      # Full set
    [Parameter(Mandatory)]
    [string]$BPath,      # Reference / Selected
    [Parameter(Mandatory)]
    [ValidateSet("Intersect", "Subtract")]
    [string]$Mode,       # Operation mode
    [Parameter(Mandatory)]
    [string]$CPath       # Destination for moved files
)

# ===============================
# File Equality Interface
# ===============================
function Test-FileEqual {
    param(
        [System.IO.FileInfo]$FileA,
        [System.IO.FileInfo]$FileB
    )

    # TODO: implement your custom equality logic here
    # Example: files with same relative path are considered equal even if extensions differ
    return ($FileA.Name -eq $FileB.Name -and $FileA.Length -eq $FileB.Length)
}

# ===============================
# Generate Key for HashSet
# ===============================
function Get-FileKey {
    param([System.IO.FileInfo]$File)

    # Use full name or relative path depending on your scenario
    # Here we use Name + Length as placeholder
    return "$($File.Name)|$($File.Length)"
}

# ===============================
# Core Engine
# ===============================
function Invoke-SetOperation {
    param(
        [string]$APath,
        [string]$BPath,
        [string]$Mode,
        [string]$CPath
    )

    # Get all files recursively
    $AFiles = Get-ChildItem $APath -Recurse -File
    $BFiles = Get-ChildItem $BPath -Recurse -File

    # Ensure CPath exists
    if (-not (Test-Path $CPath)) {
        New-Item -ItemType Directory -Path $CPath | Out-Null
    }

    # Build hash index for B
    $BIndex = @{}
    foreach ($b in $BFiles) {
        $key = Get-FileKey $b
        if (-not $BIndex.ContainsKey($key)) {
            $BIndex[$key] = $b
        }
    }

    # Process each file in A
    foreach ($afile in $AFiles) {
        $matched = $false

        # Look up B index first
        $key = Get-FileKey $afile
        if ($BIndex.ContainsKey($key)) {
            $bfile = $BIndex[$key]
            # Call Test-FileEqual for final equality check
            $matched = Test-FileEqual $afile $bfile
        }

        # Determine whether to move based on Mode
        $shouldMove = switch ($Mode) {
            "Intersect" { -not $matched }  # A ∩ B: move files not in B
            "Subtract"  {  $matched }      # A − B: move files found in B
        }

        if ($shouldMove) {
            $dest = Join-Path $CPath $afile.Name
            Move-Item $afile.FullName $dest -Force
        }
    }
}

