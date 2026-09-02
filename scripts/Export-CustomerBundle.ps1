[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceDir,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDir,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-CustomerManifest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    try {
        $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $data.customers) {
            throw "Manifest does not contain 'customers' array"
        }
        return @($data.customers)
    } catch {
        throw "Unable to read customer manifest '$Path': $($_.Exception.Message)"
    }
}

function Add-PatternsFromValue {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Target,

        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) { return }

    # string
    if ($Value -is [string]) {
        $s = [string]$Value
        if (-not [string]::IsNullOrWhiteSpace($s)) {
            $Target.Add($s)
        }
        return
    }

    # IEnumerable (arrays, etc.)
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary])) {
        foreach ($item in $Value) {
            Add-PatternsFromValue -Target $Target -Value $item
        }
        return
    }

    # object with likely pattern properties
    if ($Value -is [psobject]) {
        foreach ($propName in @('pattern','match','glob','globPattern','file','filePattern','value')) {
            if ($Value.PSObject.Properties.Name -contains $propName) {
                $v = $Value.$propName
                if ($v -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$v)) {
                    $Target.Add([string]$v)
                }
            }
        }

        # Some manifests may contain { "rules": { "patterns": [...] } }-like structures
        foreach ($propName in @('patterns','includes','include','matches','files','filePatterns','csvPatterns','csv')) {
            if ($Value.PSObject.Properties.Name -contains $propName) {
                Add-PatternsFromValue -Target $Target -Value $Value.$propName
            }
        }
    }
}

function Get-CustomerCsvPatterns {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Customer
    )

    $patterns = New-Object System.Collections.Generic.List[string]

    foreach ($propName in @('rules','patterns','include','includes','match','matches','filePatterns','csvPatterns')) {
        if ($Customer.PSObject.Properties.Name -contains $propName) {
            Add-PatternsFromValue -Target $patterns -Value $Customer.$propName
        }
    }

    # Fallback: pick any string-valued properties that look like CSV match rules
    if ($patterns.Count -eq 0) {
        foreach ($p in $Customer.PSObject.Properties) {
            if ($p.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) {
                $s = [string]$p.Value
                if ($s -like '*.csv' -or $s -like '**.csv*' -or $s -like '*?*' -or $s -like '*[*]*') {
                    $patterns.Add($s)
                }
            }
        }
    }

    # De-dupe and trim, keep stable order
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in $patterns) {
        $t = ($p ?? '').ToString().Trim()
        if ($t.Length -eq 0) { continue }
        if (-not $seen.ContainsKey($t)) {
            $seen[$t] = $true
            $out.Add($t)
        }
    }

    return ,$out.ToArray()
}

function Get-UniqueArchivePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,

        [Parameter(Mandatory = $true)]
        [string]$CustomerName
    )

    # Ensure repeated runs do not overwrite earlier ZIPs
    $attempt = 0
    while ($true) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        if ($attempt -gt 0) {
            $timestamp = "$timestamp-$attempt"
        }
        $archivePath = Join-Path -Path $DestinationRoot -ChildPath ("$CustomerName-$timestamp.zip")
        if (-not (Test-Path -Path $archivePath -PathType Leaf)) {
            return $archivePath
        }
        $attempt++
    }
}

function Get-CustomerSelectedCsvFiles {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Customer,

        [Parameter(Mandatory = $true)]
        [array]$AllCsvFiles
    )

    $customerName = [string]$Customer.name
    if ([string]::IsNullOrWhiteSpace($customerName)) {
        throw "Customer is missing required 'name' property."
    }

    $patterns = Get-CustomerCsvPatterns -Customer $Customer

    $selected = New-Object 'System.Collections.Generic.Dictionary[string, System.IO.FileInfo]'

    foreach ($pattern in $patterns) {
        $matched = @($AllCsvFiles | Where-Object { $_.Name -like $pattern })
        if ($matched.Count -eq 0) {
            Write-Warning "Customer '$customerName': manifest pattern '$pattern' matched no source CSV files."
            continue
        }

        foreach ($f in $matched) {
            # de-dupe by file name
            if (-not $selected.ContainsKey($f.Name)) {
                $selected[$f.Name] = $f
            }
        }
    }

    return @($selected.Values)
}

function New-CustomerBundle {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Customer,

        [Parameter(Mandatory = $true)]
        [array]$AllCsvFiles,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationRoot,

        [switch]$DryRun
    )

    $customerName = [string]$Customer.name
    $stageDir = Join-Path -Path $DestinationRoot -ChildPath $customerName

    Write-Verbose "Preparing bundle for $customerName"

    $selectedCsvFiles = Get-CustomerSelectedCsvFiles -Customer $Customer -AllCsvFiles $AllCsvFiles | Sort-Object Name

    $archivePath = Get-UniqueArchivePath -DestinationRoot $DestinationRoot -CustomerName $customerName
    $manifestPath = Join-Path -Path $stageDir -ChildPath 'manifest.txt'

    if ($DryRun) {
        # Dry-run must not create folders/ZIPs/manifest outputs.
        Write-Output ([pscustomobject]@{
            Customer      = $customerName
            FileCount     = $selectedCsvFiles.Count
            StageDir      = $stageDir
            Archive       = $archivePath
            ManifestPath  = $manifestPath
            DryRun        = $true
            SelectedFiles = ($selectedCsvFiles | ForEach-Object Name)
        })
        return
    }

    # Clean stage dir so we don't accidentally include stale files from earlier runs
    if (Test-Path -Path $stageDir) {
        Remove-Item -Path $stageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    foreach ($file in $selectedCsvFiles) {
        $targetPath = Join-Path -Path $stageDir -ChildPath $file.Name
        Copy-Item -Path $file.FullName -Destination $targetPath -Force
    }

    # Verification manifest: name, byte size, SHA256 hash
    $manifestLines = foreach ($file in $selectedCsvFiles) {
        $hash = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
        "$($file.Name)`t$($file.Length)`t$hash"
    }

    Set-Content -Path $manifestPath -Value $manifestLines -Encoding UTF8

    # Create ZIP without overwriting earlier archives (archivePath is unique)
    $zipSourcePath = Join-Path -Path $stageDir -ChildPath '*'
    Compress-Archive -Path $zipSourcePath -DestinationPath $archivePath -CompressionLevel Optimal

    [pscustomobject]@{
        Customer  = $customerName
        FileCount = $selectedCsvFiles.Count
        StageDir  = $stageDir
        Archive   = $archivePath
        DryRun    = [bool]$DryRun
    }
}

try {
    if (-not (Test-Path -Path $SourceDir -PathType Container)) {
        throw "Source directory does not exist: $SourceDir"
    }

    if (-not (Test-Path -Path $ManifestPath -PathType Leaf)) {
        throw "Customer manifest does not exist: $ManifestPath"
    }

    $customers = Read-CustomerManifest -Path $ManifestPath
    if ($customers.Count -eq 0) {
        throw "Customer manifest contains no customers: $ManifestPath"
    }

    $allCsvFiles = @(Get-ChildItem -Path $SourceDir -File -Filter '*.csv' -ErrorAction Stop)

    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $results = foreach ($customer in $customers) {
        New-CustomerBundle -Customer $customer -AllCsvFiles $allCsvFiles -DestinationRoot $OutputDir -DryRun:$DryRun
    }

    # Emit results for potential operator scripting
    $results | Write-Output

} catch {
    Write-Error $_.Exception.Message
    exit 1
}
