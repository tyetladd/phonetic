#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows 10 Pre-Sale Cleanup Script

.DESCRIPTION
    Removes personal files, user accounts, settings, and third-party applications
    to prepare a Windows 10 computer for resale.

    PRESERVED:  Windows Updates, Device Drivers, System files
    REMOVED:    Downloads, Documents, Desktop, Pictures, Videos, Music,
                AppData/settings, installed applications, user accounts,
                browser data, credentials, temp files, event logs

.PARAMETER WhatIf
    Simulate the cleanup without making any changes. Useful for reviewing
    what would be removed before committing.

.PARAMETER SkipApps
    Skip the application uninstall step.

.PARAMETER SkipUsers
    Skip the user account removal step.

.EXAMPLE
    # Dry-run (no changes made)
    .\cleanup-before-sale.ps1 -WhatIf

    # Full cleanup
    .\cleanup-before-sale.ps1

    # Cleanup without uninstalling apps
    .\cleanup-before-sale.ps1 -SkipApps
#>

param(
    [switch]$WhatIf,
    [switch]$SkipApps,
    [switch]$SkipUsers
)

# ─────────────────────────────────────────────────────────────
# Guard: must be elevated
# ─────────────────────────────────────────────────────────────
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal] $identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Run this script as Administrator (right-click > Run as administrator)."
    exit 1
}

$ErrorActionPreference = "SilentlyContinue"
$currentUser = $env:USERNAME

# ─────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────
function Write-Step([string]$msg) {
    Write-Host "`n[*] $msg" -ForegroundColor Cyan
}

function Remove-Safely([string]$path) {
    if (-not (Test-Path $path)) { return }
    if ($WhatIf) {
        Write-Host "  [WhatIf] Would delete: $path" -ForegroundColor DarkGray
    } else {
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed: $path"
    }
}

function Clear-FolderContents([string]$path) {
    if (-not (Test-Path $path)) { return }
    Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Safely $_.FullName
    }
}

# ─────────────────────────────────────────────────────────────
# Confirmation prompt
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Yellow
Write-Host "║     Windows 10 Pre-Sale Cleanup Script           ║" -ForegroundColor Yellow
Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Yellow
Write-Host "║  REMOVES: user files, accounts, apps, settings  ║" -ForegroundColor Red
Write-Host "║  KEEPS:   Windows Updates and device drivers     ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Yellow
Write-Host ""

if ($WhatIf) {
    Write-Host "*** DRY-RUN MODE — no changes will be made ***" -ForegroundColor Magenta
    Write-Host ""
} else {
    $confirm = Read-Host "Type YES to proceed (this cannot be undone)"
    if ($confirm -ne "YES") {
        Write-Host "Aborted." -ForegroundColor Red
        exit 0
    }
}

# ─────────────────────────────────────────────────────────────
# 1. Personal folders — all user profiles
# ─────────────────────────────────────────────────────────────
Write-Step "Clearing personal folders from all user profiles..."

$personalFolders = @(
    "Downloads", "Documents", "Desktop", "Pictures", "Videos",
    "Music",     "Contacts",  "Favorites","Links",     "OneDrive",
    "Saved Games","Searches",  "3D Objects","Dropbox",  "Google Drive"
)

$skipProfiles = @("Public", "Default", "Default User", "All Users")

Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin $skipProfiles } |
    ForEach-Object {
        $profile = $_.FullName
        Write-Host "  Profile: $profile"

        foreach ($folder in $personalFolders) {
            Remove-Safely (Join-Path $profile $folder)
        }

        # AppData — skip the current user's AppData so the session stays alive;
        # it will be wiped when that account is deleted (or on final Reset).
        if ($_.Name -ne $currentUser) {
            Remove-Safely (Join-Path $profile "AppData")
        } else {
            # For the current user, clear the high-value sub-trees only
            $localApp  = Join-Path $profile "AppData\Local"
            $roaming   = Join-Path $profile "AppData\Roaming"

            # Browser caches / profiles
            foreach ($browser in @("Google\Chrome","Mozilla\Firefox","Microsoft\Edge",
                                   "BraveSoftware","Opera Software","Vivaldi")) {
                Remove-Safely (Join-Path $localApp  $browser)
                Remove-Safely (Join-Path $roaming   $browser)
            }

            # Recent files, jump lists, quick access
            Remove-Safely (Join-Path $roaming "Microsoft\Windows\Recent")
            Remove-Safely (Join-Path $roaming "Microsoft\Windows\Recent\AutomaticDestinations")
            Remove-Safely (Join-Path $roaming "Microsoft\Windows\Recent\CustomDestinations")

            # Saved passwords / credentials
            Remove-Safely (Join-Path $localApp "Microsoft\Credentials")
            Remove-Safely (Join-Path $localApp "Microsoft\Vault")
            Remove-Safely (Join-Path $roaming  "Microsoft\Credentials")
            Remove-Safely (Join-Path $roaming  "Microsoft\Protect")
        }
    }

# ─────────────────────────────────────────────────────────────
# 2. Public folders
# ─────────────────────────────────────────────────────────────
Write-Step "Clearing Public folders..."

foreach ($folder in @("Documents","Downloads","Music","Pictures","Videos","Desktop")) {
    Clear-FolderContents "C:\Users\Public\$folder"
}

# ─────────────────────────────────────────────────────────────
# 3. Uninstall third-party applications
# ─────────────────────────────────────────────────────────────
if (-not $SkipApps) {
    Write-Step "Uninstalling third-party desktop applications..."

    # Publishers whose software we want to keep
    $keepPublishers = @(
        "Microsoft Corporation","Microsoft Windows","Microsoft",
        "Windows","Intel Corporation","Intel","NVIDIA","AMD",
        "Advanced Micro Devices","Realtek Semiconductor","Realtek",
        "Qualcomm","Broadcom","Marvell","Silicon Laboratories",
        "American Megatrends","Phoenix Technologies","Insyde Software"
    )

    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($regPath in $regPaths) {
        Get-ItemProperty $regPath -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName      -and
                $_.UninstallString  -and
                $_.Publisher        -notin $keepPublishers -and
                $_.DisplayName      -notmatch "^(Microsoft|Windows|Intel|NVIDIA|AMD|Realtek|Qualcomm|Broadcom|Driver)" -and
                $_.SystemComponent  -ne 1 -and
                $_.ReleaseType      -ne "Security Update" -and
                $_.ReleaseType      -ne "Update"
            } |
            ForEach-Object {
                $name    = $_.DisplayName
                $uninst  = $_.UninstallString
                Write-Host "  Uninstalling: $name"

                if ($WhatIf) { return }

                try {
                    if ($uninst -match "msiexec") {
                        # Extract product code {GUID}
                        if ($uninst -match "\{[A-F0-9\-]+\}") {
                            $code = $Matches[0]
                            Start-Process "msiexec.exe" `
                                -ArgumentList "/x $code /qn /norestart" `
                                -Wait -ErrorAction SilentlyContinue
                        }
                    } else {
                        # Strip quotes, try common silent flags
                        $exe  = ($uninst -split '"' | Where-Object { $_ -match "\.exe" } | Select-Object -First 1).Trim()
                        $args = "/S /silent /quiet /uninstall /SILENT /VERYSILENT"
                        if ($exe -and (Test-Path $exe)) {
                            Start-Process -FilePath $exe -ArgumentList $args `
                                -Wait -ErrorAction SilentlyContinue
                        }
                    }
                } catch {
                    Write-Host "    Could not auto-uninstall '$name' — remove it manually." -ForegroundColor Yellow
                }
            }
    }

    # UWP / Microsoft Store apps (non-Microsoft)
    Write-Step "Removing third-party Store (UWP) apps..."
    Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { $_.Publisher -notmatch "CN=Microsoft" } |
        ForEach-Object {
            Write-Host "  Removing Store app: $($_.Name)"
            if (-not $WhatIf) {
                Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
            }
        }
}

# ─────────────────────────────────────────────────────────────
# 4. Remove non-system local user accounts
# ─────────────────────────────────────────────────────────────
if (-not $SkipUsers) {
    Write-Step "Removing local user accounts..."

    $builtinAccounts = @("Administrator","Guest","DefaultAccount","WDAGUtilityAccount")

    Get-LocalUser -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $builtinAccounts -and $_.Name -ne $currentUser } |
        ForEach-Object {
            Write-Host "  Removing user: $($_.Name)"
            if (-not $WhatIf) {
                Remove-LocalUser -Name $_.Name -ErrorAction SilentlyContinue
                Remove-Safely "C:\Users\$($_.Name)"
            }
        }

    Write-Host "  Note: '$currentUser' (current session) was kept — delete it manually" `
               "after logging into a different admin account, or use Reset this PC." `
               -ForegroundColor Yellow
}

# ─────────────────────────────────────────────────────────────
# 5. Windows settings & personalisation (registry, current user)
# ─────────────────────────────────────────────────────────────
Write-Step "Clearing Windows settings, personalization and credentials..."

if (-not $WhatIf) {
    # Recent docs / run history / typed paths
    Remove-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs" `
        -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU" `
        -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths" `
        -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "HKCU:\Software\Microsoft\Internet Explorer\TypedURLs" `
        -Recurse -Force -ErrorAction SilentlyContinue

    # Reset wallpaper to default (avoid exposing personal photo)
    Set-ItemProperty "HKCU:\Control Panel\Desktop" -Name "Wallpaper" -Value "" `
        -ErrorAction SilentlyContinue

    # Clear stored network (Wi-Fi) passwords
    netsh wlan delete profile name=* 2>$null

    # Clear credential manager entries
    cmdkey /list 2>$null | Select-String "Target:" | ForEach-Object {
        $target = ($_ -split "Target:\s*")[1].Trim()
        if ($target) { cmdkey /delete:"$target" 2>$null }
    }

    # Flush DNS cache
    ipconfig /flushdns | Out-Null

    # Remove saved RDP connections
    Remove-Item "HKCU:\Software\Microsoft\Terminal Server Client" `
        -Recurse -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────
# 6. Temp files
# ─────────────────────────────────────────────────────────────
Write-Step "Clearing temporary files..."

if (-not $WhatIf) {
    Clear-FolderContents "C:\Windows\Temp"
    Clear-FolderContents $env:TEMP

    # Windows Update download cache (safe — re-downloaded on next check)
    Clear-FolderContents "C:\Windows\SoftwareDistribution\Download"

    # Thumbnail cache
    Remove-Safely "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"

    # Prefetch (rebuilds automatically)
    Clear-FolderContents "C:\Windows\Prefetch"
}

# ─────────────────────────────────────────────────────────────
# 7. Event logs
# ─────────────────────────────────────────────────────────────
Write-Step "Clearing Windows Event Logs..."

if (-not $WhatIf) {
    wevtutil el 2>$null | ForEach-Object { wevtutil cl "$_" 2>$null }
}

# ─────────────────────────────────────────────────────────────
# 8. Recycle Bin
# ─────────────────────────────────────────────────────────────
Write-Step "Emptying Recycle Bin..."

if (-not $WhatIf) {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║              Cleanup complete                    ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Removed:" -ForegroundColor White
Write-Host "  ✓ Personal files (Downloads, Documents, Desktop, Pictures…)" -ForegroundColor Green
Write-Host "  ✓ Browser data and profiles"                                  -ForegroundColor Green
Write-Host "  ✓ AppData / application settings"                            -ForegroundColor Green
Write-Host "  ✓ Third-party applications"                                   -ForegroundColor Green
Write-Host "  ✓ Local user accounts (except current session)"              -ForegroundColor Green
Write-Host "  ✓ Wi-Fi passwords and saved credentials"                     -ForegroundColor Green
Write-Host "  ✓ Recent files, run history, typed paths"                    -ForegroundColor Green
Write-Host "  ✓ Temp files, prefetch, thumbnail cache"                     -ForegroundColor Green
Write-Host "  ✓ Event logs and Recycle Bin"                                -ForegroundColor Green
Write-Host ""
Write-Host "Preserved:" -ForegroundColor White
Write-Host "  ✓ Windows Updates"                                           -ForegroundColor Green
Write-Host "  ✓ Device Drivers"                                            -ForegroundColor Green
Write-Host "  ✓ System files"                                              -ForegroundColor Green
Write-Host ""
Write-Host "Recommended final step:" -ForegroundColor Yellow
Write-Host "  Settings > System > Recovery > Reset this PC > Remove everything" -ForegroundColor Yellow
Write-Host "  Choose 'Local reinstall' to keep drivers/updates, then" -ForegroundColor Yellow
Write-Host "  'Remove files and clean the drive' for the most thorough wipe." -ForegroundColor Yellow
Write-Host ""
