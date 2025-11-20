# Intel Chipset Device Update Script
# Based on Intel Chipset Device Latest database
# Downloads latest INF files from GitHub and updates if newer versions available
# By Marcin Grygiel / www.firstever.tech

# Check if running as administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script requires administrator privileges. Please run PowerShell as Administrator." -ForegroundColor Red
    exit
}

# =============================================
# CONFIGURATION - Set to 1 to enable debug mode
# =============================================
$DebugMode = 0  # 0 = Disabled, 1 = Enabled
# =============================================

# GitHub repository URLs
$githubBaseUrl = "https://raw.githubusercontent.com/FirstEverTech/Universal-Intel-Chipset-Updater/main/"
$chipsetINFsUrl = $githubBaseUrl + "Intel_Chipset_INFs_Latest.md"
$downloadListUrl = $githubBaseUrl + "Intel_Chipset_INFs_Download.txt"

# Temporary directory for downloads
$tempDir = "C:\Windows\Temp\IntelChipset"

# Function to write debug messages
function Write-DebugMessage {
    param([string]$Message, [string]$Color = "Gray")
    if ($DebugMode -eq 1) {
        Write-Host "DEBUG: $Message" -ForegroundColor $Color
    }
}

# Function to detect Intel Chipset HWIDs from the local system (MAIN CHIPSET ONLY)
function Get-IntelChipsetHWIDs {
    $intelChipsets = @()
    $chipsetCount = 0
    $nonChipsetCount = 0

    # Get all PCI devices from computer
    $pciDevices = Get-PnpDevice -Class 'System' -ErrorAction SilentlyContinue | 
                  Where-Object { $_.HardwareID -like '*PCI\VEN_8086*' -and $_.Status -eq 'OK' }

    foreach ($device in $pciDevices) {
        foreach ($hwid in $device.HardwareID) {
            if ($hwid -match 'PCI\\VEN_8086&DEV_([A-F0-9]{4})') {
                $deviceId = $matches[1]
                $description = $device.FriendlyName

                # Focus on main chipset components only - ignore CPU-related devices
                # Main chipsets typically have descriptions containing "Chipset", "LPC", "PCI Express Root Port", etc.
                if ($description -match 'Chipset|LPC|PCI Express Root Port|PCI-to-PCI bridge|Motherboard Resources') {
                    $intelChipsets += [PSCustomObject]@{
                        HWID = $deviceId
                        Description = $description
                        HardwareID = $hwid
                        InstanceId = $device.InstanceId
                        IsChipset = $true
                    }
                    $chipsetCount++
                } else {
                    $nonChipsetCount++
                }
            }
        }
    }

    # If no specific chipset devices found, fall back to the original detection but take only first few
    if ($intelChipsets.Count -eq 0) {
        foreach ($device in $pciDevices) {
            foreach ($hwid in $device.HardwareID) {
                if ($hwid -match 'PCI\\VEN_8086&DEV_([A-F0-9]{4})') {
                    $deviceId = $matches[1]
                    $description = $device.FriendlyName

                    $intelChipsets += [PSCustomObject]@{
                        HWID = $deviceId
                        Description = $description
                        HardwareID = $hwid
                        InstanceId = $device.InstanceId
                        IsChipset = $false
                    }
                    $chipsetCount++

                    # Limit to 5 devices to avoid CPU components
                    if ($intelChipsets.Count -ge 5) { break }
                }
            }
            if ($intelChipsets.Count -ge 5) { break }
        }
    }

    Write-DebugMessage "Scanning completed: found $chipsetCount potential chipset devices and $nonChipsetCount non-chipset devices"
    return $intelChipsets | Sort-Object HWID -Unique
}

# Function to get current INF version for a device
function Get-CurrentINFVersion {
    param([string]$DeviceInstanceId)

    try {
        $device = Get-PnpDevice | Where-Object {$_.InstanceId -eq $DeviceInstanceId}
        if ($device) {
            # Primary method: Use DriverVersion property (standard Windows property)
            $versionProperty = $device | Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_DriverVersion" -ErrorAction SilentlyContinue
            if ($versionProperty -and $versionProperty.Data) {
                Write-DebugMessage "Got version from DEVPKEY_Device_DriverVersion: $($versionProperty.Data)"
                return $versionProperty.Data
            }
            
            # Fallback method: Try INFVersion if available
            $infVersionProperty = $device | Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_INFVersion" -ErrorAction SilentlyContinue
            if ($infVersionProperty -and $infVersionProperty.Data) {
                Write-DebugMessage "Got version from DEVPKEY_Device_INFVersion: $($infVersionProperty.Data)"
                return $infVersionProperty.Data
            }
        }
    } catch {
        Write-DebugMessage "Error getting device properties: $_" -Color "Yellow"
    }

    # Fallback to WMI if the above fails
    try {
        $driverInfo = Get-CimInstance -ClassName Win32_PnPSignedDriver | Where-Object { 
            $_.DeviceID -eq $DeviceInstanceId -and $_.DriverVersion
        } | Select-Object -First 1

        if ($driverInfo) {
            Write-DebugMessage "Got version from WMI: $($driverInfo.DriverVersion)"
            return $driverInfo.DriverVersion
        }
    } catch {
        Write-DebugMessage "Error getting INF version from WMI: $_" -Color "Yellow"
    }

    # Additional fallback: Check device INF date
    try {
        $driverDateProperty = $device | Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_DriverDate" -ErrorAction SilentlyContinue
        if ($driverDateProperty -and $driverDateProperty.Data) {
            Write-DebugMessage "Could not get version, but got driver date: $($driverDateProperty.Data)"
            return "Unknown (Driver Date: $($driverDateProperty.Data))"
        }
    } catch {
        Write-DebugMessage "Error getting driver date: $_" -Color "Yellow"
    }

    Write-DebugMessage "Could not determine version for device: $DeviceInstanceId"
    return $null
}

# Function to clean up temporary INF files folders
function Clear-TempINFFolders {
    try {
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-DebugMessage "Cleaned up temporary directory: $tempDir"
        }
    } catch {
        Write-DebugMessage "Error during cleanup: $_" -Color "Yellow"
    }
}

# Function to download and parse INF files information from GitHub
function Get-LatestINFInfo {
    param([string]$Url)

    try {
        Write-DebugMessage "Downloading from: $Url"
        $content = Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop
        Write-DebugMessage "Successfully downloaded content from $Url"
        return $content.Content
    } catch {
        Write-Host "Error downloading INF files information from GitHub." -ForegroundColor Red
        Write-Host "Please check your internet connection and try again." -ForegroundColor Yellow
        Write-DebugMessage "Download error: $_" -Color "Red"
        return $null
    }
}

# Function to parse chipset INF files information from Markdown
function Parse-ChipsetINFsFromMarkdown {
    param([string]$MarkdownContent)

    Write-DebugMessage "Starting Markdown parsing"
    $chipsetData = @{}
    $lines = $MarkdownContent -split "`n"
    $currentPlatform = $null
    $currentGeneration = $null
    $inMainstreamSection = $false
    $inWorkstationSection = $false
    $inXeonSection = $false
    $inAtomSection = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()

        # Detect section headers (like ### Mainstream Desktop/Mobile)
        if ($line -match '^### Mainstream Desktop/Mobile') {
            $inMainstreamSection = $true
            $inWorkstationSection = $false
            $inXeonSection = $false
            $inAtomSection = $false
            Write-DebugMessage "Entered Mainstream Desktop/Mobile section"
            continue
        }
        elseif ($line -match '^### Workstation/Enthusiast') {
            $inMainstreamSection = $false
            $inWorkstationSection = $true
            $inXeonSection = $false
            $inAtomSection = $false
            Write-DebugMessage "Entered Workstation/Enthusiast section"
            continue
        }
        elseif ($line -match '^### Xeon/Server Platforms') {
            $inMainstreamSection = $false
            $inWorkstationSection = $false
            $inXeonSection = $true
            $inAtomSection = $false
            Write-DebugMessage "Entered Xeon/Server Platforms section"
            continue
        }
        elseif ($line -match '^### Atom/Low-Power Platforms') {
            $inMainstreamSection = $false
            $inWorkstationSection = $false
            $inXeonSection = $false
            $inAtomSection = $true
            Write-DebugMessage "Entered Atom/Low-Power Platforms section"
            continue
        }

        # Detect platform headers (like #### Panther Lake)
        if ($line -match '^####\s+(.+)') {
            $currentPlatform = $matches[1]
            
            # Determine section for platform display
            if ($inMainstreamSection) {
                $sectionName = "Mainstream Desktop/Mobile"
            } elseif ($inWorkstationSection) {
                $sectionName = "Workstation/Enthusiast"
            } elseif ($inXeonSection) {
                $sectionName = "Xeon/Server Platforms"
            } elseif ($inAtomSection) {
                $sectionName = "Atom/Low-Power Platforms"
            } else {
                $sectionName = "Unknown"
            }
            
            Write-DebugMessage "Processing platform: $currentPlatform ($sectionName)"
            continue
        }

        # Detect generation headers (like **Generation:** 7 Series – Desktop/Mobile)
        if ($line -match '\*\*Generation:\*\*\s*(.+)') {
            $currentGeneration = $matches[1]
            Write-DebugMessage "Generation: $currentGeneration"
            continue
        }

        # Detect table headers and data rows
        if ($line -match '^\|.*INF.*\|.*Package.*\|.*Version.*\|.*Date.*\|.*HWIDs.*\|$' -and $currentPlatform) {
            Write-DebugMessage "Found table for platform: $currentPlatform"
            # Skip separator line
            $i++

            # Process data rows until we hit a non-table line
            while ($i -lt $lines.Count -and $lines[$i] -match '^\|.*\|.*\|.*\|.*\|.*\|$') {
                $dataLine = $lines[$i].Trim()
                $i++

                # Skip separator lines
                if ($dataLine -match '^\|\s*:---') { continue }

                # Parse table row
                $columns = ($dataLine -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
                if ($columns.Count -ge 5) {
                    $inf = $columns[0]
                    $package = $columns[1]
                    $version = $columns[2]
                    $date = $columns[3] -replace '\\', ''  # Remove backslash if present
                    $hwIds = $columns[4] -split ',' | ForEach-Object { $_.Trim() }

                    Write-DebugMessage "Parsed row: INF=$inf, Package=$package, Version=$version, HWIDs=$($hwIds -join ',')"

                    foreach ($hwId in $hwIds) {
                        if ($hwId -match '^[A-F0-9]{4}$') {
                            $chipsetData[$hwId] = @{
                                Platform = $currentPlatform
                                Section = $sectionName
                                Generation = $currentGeneration
                                INF = $inf
                                Package = $package
                                Version = $version
                                Date = $date
                                HasAsterisk = $date -match '\*$'
                            }
                            Write-DebugMessage "Added HWID: $hwId for platform $currentPlatform"
                        }
                    }
                }
            }
        }
    }

    Write-DebugMessage "Markdown parsing completed. Found $($chipsetData.Count) HWID entries."
    return $chipsetData
}

# Function to parse download list
function Parse-DownloadList {
    param([string]$DownloadListContent)

    Write-DebugMessage "Starting download list parsing"
    $downloadData = @{}
    $blocks = $DownloadListContent -split "`n`n" | Where-Object { $_.Trim() }

    Write-DebugMessage "Found $($blocks.Count) blocks in download list"

    foreach ($block in $blocks) {
        $name = $null
        $infVer = $null
        $link = $null
        $prefix = $null
        $variant = "Consumer" # Default value

        $lines = $block -split "`n" | ForEach-Object { $_.Trim() }
        foreach ($line in $lines) {
            if ($line -match '^Name\s*=\s*(.+)') {
                $name = $matches[1]
            } elseif ($line -match '^INFVer\s*=\s*[^,]+,([0-9.]+)') {
                $infVer = $matches[1]
            } elseif ($line -match '^Link\s*=\s*(.+)') {
                $link = $matches[1]
            } elseif ($line -match '^Prefix\s*=\s*(.+)') {
                $prefix = $matches[1]
            } elseif ($line -match '^Variant\s*=\s*(.+)') {
                $variant = $matches[1]
            }
        }

        if ($infVer -and $link) {
            $key = "$infVer-$variant"
            $downloadData[$key] = @{
                Name = $name
                INFVer = $infVer
                Link = $link
                Prefix = $prefix
                Variant = $variant
            }
            Write-DebugMessage "Added download entry: $key -> $name"
        }
    }

    Write-DebugMessage "Download list parsing completed. Found $($downloadData.Count) entries."
    return $downloadData
}

# Function to download and extract file
function Download-Extract-File {
    param([string]$Url, [string]$OutputPath, [string]$Prefix)

    try {
        $tempFile = "$tempDir\temp_$(Get-Random).$([System.IO.Path]::GetExtension($Url).TrimStart('.'))"

        # Download file
        Write-DebugMessage "Downloading from: $Url to $tempFile"
        Invoke-WebRequest -Uri $Url -OutFile $tempFile -UseBasicParsing

        if (Test-Path $tempFile) {
            # Determine file type and extract/copy accordingly
            $fileExtension = [System.IO.Path]::GetExtension($Url).ToLower()
            
            if ($fileExtension -eq '.zip') {
                # Extract ZIP file
                try {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($tempFile, $OutputPath)
                    $success = $true
                    Write-Host "ZIP file extracted successfully." -ForegroundColor Green
                    Write-DebugMessage "ZIP extraction successful to: $OutputPath"
                } catch {
                    # Fallback to COM object
                    try {
                        Write-Host "Using COM object for ZIP extraction..." -ForegroundColor Yellow
                        Write-DebugMessage "Using COM object for ZIP extraction (fallback)"
                        $shell = New-Object -ComObject Shell.Application
                        $zipFolder = $shell.NameSpace($tempFile)
                        $destFolder = $shell.NameSpace($OutputPath)
                        $destFolder.CopyHere($zipFolder.Items(), 0x14) # 0x14 = No UI + Overwrite
                        $success = $true
                        Write-Host "ZIP file extracted successfully using COM." -ForegroundColor Green
                        Write-DebugMessage "COM extraction successful"
                    } catch {
                        Write-Host "Error extracting ZIP file: $_" -ForegroundColor Red
                        Write-DebugMessage "ZIP extraction error: $_" -Color "Red"
                        $success = $false
                    }
                }
            } elseif ($fileExtension -eq '.exe') {
                # For EXE, copy to output path with proper structure
                New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

                if ($Prefix -and $Prefix -ne '\SetupChipset.exe') {
                    # Create subdirectory structure
                    $subDir = Split-Path $Prefix.TrimStart('\') -Parent
                    if ($subDir) {
                        $fullOutputPath = Join-Path $OutputPath $subDir
                        New-Item -ItemType Directory -Path $fullOutputPath -Force | Out-Null
                        Write-DebugMessage "Created subdirectory: $fullOutputPath"
                    }

                    $outputFile = Join-Path $OutputPath ($Prefix.TrimStart('\'))
                    Copy-Item $tempFile $outputFile -Force
                    Write-Host "EXE file copied to: $outputFile" -ForegroundColor Green
                    Write-DebugMessage "EXE copied to: $outputFile"
                } else {
                    # Default case
                    Copy-Item $tempFile "$OutputPath\SetupChipset.exe" -Force
                    Write-Host "EXE file copied to: $OutputPath\SetupChipset.exe" -ForegroundColor Green
                    Write-DebugMessage "EXE copied to: $OutputPath\SetupChipset.exe"
                }
                $success = $true
            } else {
                # Unknown file type
                Write-Host "Unknown file type: $fileExtension" -ForegroundColor Red
                Write-DebugMessage "Unknown file type: $fileExtension" -Color "Red"
                $success = $false
            }

            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            Write-DebugMessage "Removed temporary file: $tempFile"
            return $success
        }
    } catch {
        Write-Host "Error downloading or extracting INF files package: $_" -ForegroundColor Red
        Write-DebugMessage "Download/Extract error: $_" -Color "Red"
    }
    return $false
}

# Function to install chipset INF files
function Install-ChipsetINF {
    param([string]$INFPath, [string]$Prefix)

    # Determine setup path based on prefix
    if ($Prefix) {
        $setupPath = Join-Path $INFPath ($Prefix.TrimStart('\'))
    } else {
        $setupPath = Join-Path $INFPath "SetupChipset.exe"
    }

    Write-DebugMessage "Installing from path: $setupPath"

    if (Test-Path $setupPath) {

        Write-Host ""
        Write-Host "IMPORTANT NOTICE:" -ForegroundColor Yellow
        Write-Host "The INF files updater is now running." -ForegroundColor Yellow
        Write-Host "Please DO NOT close this window or interrupt the process." -ForegroundColor Yellow
        Write-Host "The system may appear unresponsive during installation - this is normal." -ForegroundColor Yellow
        Write-Host ""

        Write-Host "Running installer: SetupChipset.exe" -ForegroundColor Cyan
        Write-DebugMessage "Starting installer with arguments: -S -OVERALL -downgrade -norestart"

        try {
            # Run installer with parameters -S -OVERALL -downgrade -norestart
            $process = Start-Process -FilePath $setupPath -ArgumentList "-S -OVERALL -downgrade -norestart" -Wait -PassThru

            # Code 3010 = SUCCESS - RESTART REQUIRED (this is not an error!)
            if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                Write-Host "INF files installed successfully." -ForegroundColor Green
                Write-DebugMessage "Installer completed successfully with exit code: $($process.ExitCode)"
                return $true
            } else {
                Write-Host "Installer finished with exit code: $($process.ExitCode)" -ForegroundColor Red
                Write-DebugMessage "Installer failed with exit code: $($process.ExitCode)" -Color "Red"
                return $false
            }

        } catch {
            Write-Host "Error running installer: $_" -ForegroundColor Red
            Write-DebugMessage "Installer error: $_" -Color "Red"
            return $false
        }
    } else {
        Write-Host "Error: Installer not found at $setupPath" -ForegroundColor Red
        Write-DebugMessage "Installer not found at: $setupPath" -Color "Red"
        # Try to find any setup executable
        $exeFiles = Get-ChildItem -Path $INFPath -Filter "*.exe" -Recurse | Where-Object {
            $_.Name -like "*Setup*" -or $_.Name -like "*Install*"
        }
        if ($exeFiles) {
            Write-Host "Found alternative installer: $($exeFiles[0].FullName)" -ForegroundColor Yellow
            Write-DebugMessage "Found alternative installer: $($exeFiles[0].FullName)"
            return Install-ChipsetINF -INFPath $INFPath -Prefix "\$($exeFiles[0].Name)"
        }
        return $false
    }
}

# Main script execution
Write-Host "=== Intel Chipset Device Software Update ===" -ForegroundColor Cyan
Write-Host "Scanning for Intel Chipset..." -ForegroundColor Green

# Create temporary directory
Clear-TempINFFolders
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
Write-DebugMessage "Created temporary directory: $tempDir"

# Detect Intel Chipset HWIDs on local system (MAIN CHIPSET ONLY)
$detectedIntelChipsets = Get-IntelChipsetHWIDs

if ($detectedIntelChipsets.Count -eq 0) {
    Write-Host "No Intel chipset devices found." -ForegroundColor Yellow
    Write-Host "If you have an Intel platform, make sure you have at least SandyBridge or newer platform." -ForegroundColor Yellow
    Clear-TempINFFolders
    exit
}

Write-Host "Found $($detectedIntelChipsets.Count) Intel chipset device(s)" -ForegroundColor Green

# Debug information about detected devices and their versions
if ($DebugMode -eq 1) {
    Write-Host "`n=== DEBUG INFORMATION ===" -ForegroundColor Cyan
    Write-Host "Checking versions for detected devices:" -ForegroundColor Gray
    foreach ($device in $detectedIntelChipsets) {
        $currentVersion = Get-CurrentINFVersion -DeviceInstanceId $device.InstanceId
        Write-Host "Device: $($device.Description)" -ForegroundColor Gray
        Write-Host "  HWID: $($device.HWID) | Version: $currentVersion" -ForegroundColor Gray
    }
    Write-Host "=== END DEBUG ===`n" -ForegroundColor Cyan
}

# Download latest INF information
Write-Host "Downloading latest INF information..." -ForegroundColor Green
$chipsetInfo = Get-LatestINFInfo -Url $chipsetINFsUrl
$downloadListInfo = Get-LatestINFInfo -Url $downloadListUrl

if (-not $chipsetInfo -or -not $downloadListInfo) {
    Write-Host "Failed to download INF information. Exiting." -ForegroundColor Red
    Clear-TempINFFolders
    exit
}

# Parse INF information
Write-Host "Parsing INF information..." -ForegroundColor Green
$chipsetData = Parse-ChipsetINFsFromMarkdown -MarkdownContent $chipsetInfo
$downloadData = Parse-DownloadList -DownloadListContent $downloadListInfo

if ($chipsetData.Count -eq 0 -or $downloadData.Count -eq 0) {
    Write-Host "Error: Could not parse INF information." -ForegroundColor Red
    Write-Host "Chipset data entries: $($chipsetData.Count)" -ForegroundColor Red
    Write-Host "Download data entries: $($downloadData.Count)" -ForegroundColor Red
    Write-Host "Please check the format of markdown and download list files." -ForegroundColor Yellow
    Clear-TempINFFolders
    exit
}

# Find matching chipset platforms
$matchingChipsets = @()
$chipsetUpdateAvailable = $false

foreach ($device in $detectedIntelChipsets) {
    $hwId = $device.HWID
    if ($chipsetData.ContainsKey($hwId)) {
        $chipsetInfo = $chipsetData[$hwId]
        # Using InstanceId to get INF files version
        $currentVersion = Get-CurrentINFVersion -DeviceInstanceId $device.InstanceId

        $matchingChipsets += @{
            Device = $device
            ChipsetInfo = $chipsetInfo
            CurrentVersion = $currentVersion
            HardwareID = $device.HardwareID
            InstanceId = $device.InstanceId
        }

        Write-Host "Found compatible platform: $($chipsetInfo.Platform) (HWID: $hwId)" -ForegroundColor Green
        Write-DebugMessage "Platform match: $($chipsetInfo.Platform) - Current: $currentVersion, Latest: $($chipsetInfo.Version)"
    }
}

if ($matchingChipsets.Count -eq 0) {
    Write-Host "No compatible Intel chipset platforms found." -ForegroundColor Yellow
    Write-Host "If you have an Intel platform, make sure you have at least SandyBridge or newer platform." -ForegroundColor Yellow
    Clear-TempINFFolders
    exit
}

# Group by platform to avoid duplicate installations of the same INF files
$uniquePlatforms = @{}
foreach ($match in $matchingChipsets) {
    $platform = $match.ChipsetInfo.Platform
    $package = $match.ChipsetInfo.Package

    if (-not $uniquePlatforms.ContainsKey($platform)) {
        $uniquePlatforms[$platform] = @{
            ChipsetInfo = $match.ChipsetInfo
            Devices = @($match.Device)
            CurrentVersions = @()
        }
    }

    if ($match.CurrentVersion) {
        $uniquePlatforms[$platform].CurrentVersions += $match.CurrentVersion
    }
}

# Display platform information
Write-Host "`n=== Platform Information ===" -ForegroundColor Cyan

# Initialize flag to track if any platform has asterisk
$hasAnyAsterisk = $false

foreach ($platformName in $uniquePlatforms.Keys) {
    $platformData = $uniquePlatforms[$platformName]
    $chipsetInfo = $platformData.ChipsetInfo
    $devices = $platformData.Devices
    $currentVersions = $platformData.CurrentVersions | Sort-Object -Unique

    Write-Host "Platform: $platformName" -ForegroundColor White
    if ($chipsetInfo.Generation) {
        Write-Host "Generation: $($chipsetInfo.Generation)" -ForegroundColor Gray
    }

    if ($currentVersions.Count -gt 0) {
        Write-Host "Current Version: $(($currentVersions -join ', '))" -ForegroundColor Gray
    } else {
        Write-Host "Current Version: Unable to determine" -ForegroundColor Gray
    }

    # Latest Version without date
    Write-Host "Latest Version: $($chipsetInfo.Version)" -ForegroundColor Gray

    # Installer Version with date in yellow
    $installerVersionDisplay = "$($chipsetInfo.Package) ($($chipsetInfo.Date))"
    Write-Host "Installer Version: $installerVersionDisplay" -ForegroundColor Yellow

    # Check if update is available
    $needsUpdate = $false
    if ($currentVersions.Count -gt 0) {
        foreach ($currentVersion in $currentVersions) {
            if ($currentVersion -ne $chipsetInfo.Version) {
                $needsUpdate = $true
                break
            }
        }

        if (-not $needsUpdate) {
            Write-Host "Status: Already on latest version" -ForegroundColor Green
        } else {
            Write-Host "Status: New version available! ($(($currentVersions -join ', ')) -> $($chipsetInfo.Version))" -ForegroundColor Yellow
            $chipsetUpdateAvailable = $true
        }
    } else {
        Write-Host "Status: INF files will be installed" -ForegroundColor Yellow
        $chipsetUpdateAvailable = $true
    }

    # Track if any platform has asterisk
    if ($chipsetInfo.HasAsterisk) {
        $hasAnyAsterisk = $true
    }

    Write-Host ""
}

# Show asterisk warning only once after all platforms, if any platform has asterisk
if ($hasAnyAsterisk) {
    Write-Host "Note: INF files marked with (*) do not have embedded dates" -ForegroundColor Yellow
    Write-Host "      and will show as 07/18/1968 in system. The actual" -ForegroundColor Yellow
    Write-Host "      INF files release corresponds to the installer date." -ForegroundColor Yellow
    Write-Host ""
}

# If all devices are up to date, ask if user wants to reinstall anyway
if ((-not $chipsetUpdateAvailable) -and ($uniquePlatforms.Count -gt 0)) {
    Write-Host "All platforms are up to date." -ForegroundColor Green
    $response = Read-Host "Do you want to force reinstall this INF files anyway? (Y/N)"
    if ($response -eq "Y" -or $response -eq "y") {
        $chipsetUpdateAvailable = $true
    } else {
        Write-Host "Installation cancelled." -ForegroundColor Yellow
        Clear-TempINFFolders
        exit
    }
}

# Ask for update confirmation with important notice
if ($chipsetUpdateAvailable) {
    Write-Host ""
    Write-Host "IMPORTANT NOTICE:" -ForegroundColor Yellow
    Write-Host "The INF files update process may take several minutes to complete." -ForegroundColor Yellow
    Write-Host "During installation, the screen may temporarily go black and some" -ForegroundColor Yellow
    Write-Host "devices may temporarily disconnect as PCIe bus INF files are being" -ForegroundColor Yellow
    Write-Host "updated. This is normal behavior and the system will return to" -ForegroundColor Yellow
    Write-Host "normal operation once the installation is complete." -ForegroundColor Yellow
    Write-Host ""
    $response = Read-Host "Do you want to proceed with INF files update? (Y/N)"
} else {
    $response = "N"
}

if ($response -eq "Y" -or $response -eq "y") {
    Write-Host "`nStarting INF files update process..." -ForegroundColor Green

    # INTELLIGENT PACKAGE MANAGEMENT: Group by package version and install only unique packages
    $packageGroups = @{}
    foreach ($platformName in $uniquePlatforms.Keys) {
        $platformData = $uniquePlatforms[$platformName]
        $packageVersion = $platformData.ChipsetInfo.Package
        
        if (-not $packageGroups.ContainsKey($packageVersion)) {
            $packageGroups[$packageVersion] = @()
        }
        $packageGroups[$packageVersion] += $platformName
    }

    # Sort packages by version (newest first) to ensure we install the latest versions
    $sortedPackages = $packageGroups.Keys | Sort-Object { [version]($_ -replace '\s*\(S\)\s*', '') } -Descending
    Write-DebugMessage "Package groups: $($packageGroups.Count) unique packages"

    $successCount = 0
    $processedPackages = @{}

    foreach ($packageVersion in $sortedPackages) {
        $platforms = $packageGroups[$packageVersion]
        
        Write-Host "`nPackage $packageVersion for platforms: $($platforms -join ', ')" -ForegroundColor Cyan
        Write-DebugMessage "Processing package: $packageVersion for platforms: $($platforms -join ', ')"

        # Determine variant based on actual package version suffix from Markdown
        $variant = "Consumer"
        # Check if package has (S) suffix indicating Server variant
        if ($packageVersion -match '\(S\)$') {
            $variant = "Server"
        }
        Write-DebugMessage "Determined variant: $variant"

        # Get download information for this package version and variant
        $cleanPackageVersion = $packageVersion -replace '\s*\(S\)\s*', ''  # Remove (S) suffix if present
        $downloadKey = "$cleanPackageVersion-$variant"
        Write-DebugMessage "Looking for download key: $downloadKey"

        if ($downloadData.ContainsKey($downloadKey)) {
            $downloadInfo = $downloadData[$downloadKey]
            $driverPath = "$tempDir\$cleanPackageVersion-$variant"

            Write-Host "Downloading Intel Chipset Device Software $cleanPackageVersion ($variant)..." -ForegroundColor Green
            Write-DebugMessage "Download info: Name=$($downloadInfo.Name), Link=$($downloadInfo.Link), Prefix=$($downloadInfo.Prefix)"
            
            if (Download-Extract-File -Url $downloadInfo.Link -OutputPath $driverPath -Prefix $downloadInfo.Prefix) {
                Write-Host "INF files downloaded and extracted successfully." -ForegroundColor Green
                
                if (Install-ChipsetINF -INFPath $driverPath -Prefix $downloadInfo.Prefix) {
                    $successCount++
                    $processedPackages[$cleanPackageVersion] = $true
                    Write-Host "Successfully installed package $cleanPackageVersion for $($platforms.Count) platform(s)" -ForegroundColor Green
                    Write-DebugMessage "Installation successful for package: $cleanPackageVersion"
                } else {
                    Write-Host "Failed to install INF files." -ForegroundColor Red
                    Write-DebugMessage "Installation failed for package: $cleanPackageVersion"
                }
            } else {
                Write-Host "Failed to download or extract INF files." -ForegroundColor Red
                Write-DebugMessage "Download/Extract failed for package: $cleanPackageVersion"
            }
        } else {
            Write-Host "Error: Download information not found for package version $cleanPackageVersion (variant: $variant)" -ForegroundColor Red
            Write-Host "Please check Intel_Chipset_INFs_Download.txt for missing entries" -ForegroundColor Yellow
            Write-DebugMessage "Download key not found: $downloadKey" -Color "Red"
        }
    }

    if ($successCount -gt 0) {
        Write-Host "`nIMPORTANT NOTICE:" -ForegroundColor Yellow
        Write-Host "Computer restart is required to complete INF installation!" -ForegroundColor Yellow
        
        Write-Host "`nSummary: Installed $successCount unique package(s) for all detected platforms" -ForegroundColor Green
        Write-DebugMessage "Installation summary: $successCount successful packages"
    } else {
        Write-Host "`nNo INF files were successfully installed." -ForegroundColor Red
        Write-DebugMessage "No packages were successfully installed"
    }
} else {
    Write-Host "Update cancelled." -ForegroundColor Yellow
    Write-DebugMessage "User cancelled the update"
}

# Clean up
Write-Host "`nCleaning up temporary files..." -ForegroundColor Gray
Clear-TempINFFolders

Write-Host "`nINF files update process completed." -ForegroundColor Cyan
Write-Host "If you have any issues with this tool, please report them at:"
Write-Host "https://github.com/FirstEverTech/Universal-Intel-Chipset-Updater" -ForegroundColor Cyan

if ($DebugMode -eq 1) {
    Write-Host "`n[DEBUG MODE ENABLED - All debug messages were shown]" -ForegroundColor Magenta
}