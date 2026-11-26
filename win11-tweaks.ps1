#Requires -Version 5.1
<#
.SYNOPSIS
    Windows 11 Declutter & Security Tweaks
.DESCRIPTION
    Interactive TUI to apply common Windows 11 registry fixes:
      1. Remove "Learn about this picture" desktop icon (Spotlight)
      2. Remove fun facts/tips from Spotlight lock screen
      3. Disable web search in Start Menu
      4. Auto-lock PC after 15 min inactivity
.NOTES
    Author : Daniel Hoffmann
    Date   : 2026-04-14
    Run as : Administrator (required for Fix #4)
#>

# ── Strict Mode ──────────────────────────────────────────────────────────────
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Color Palette (Claude Code) ──────────────────────────────────────────────
$script:C = @{
    Bg        = 'Black'
    Fg        = 'Gray'
    Accent    = 'DarkYellow'     # amber / warm orange
    Heading   = 'White'
    Success   = 'Green'
    Error     = 'Red'
    Warning   = 'Yellow'
    Muted     = 'DarkGray'
    Highlight = 'Cyan'
    Selected  = 'Magenta'
}

# ── Layout ───────────────────────────────────────────────────────────────────
$script:W = 76   # content width

function Write-Line {
    param([string]$Char = '─', [string]$Color = $C.Muted)
    Write-Host ($Char * $W) -ForegroundColor $Color
}

function Write-Centered {
    param([string]$Text, [string]$Color = $C.Heading)
    $pad = [Math]::Max(0, [Math]::Floor(($W - $Text.Length) / 2))
    Write-Host (' ' * $pad + $Text) -ForegroundColor $Color
}

function Write-Row {
    param(
        [string]$Label,
        [string]$Value,
        [string]$LabelColor = $C.Accent,
        [string]$ValueColor = $C.Fg
    )
    Write-Host "  $Label" -ForegroundColor $LabelColor -NoNewline
    Write-Host "  $Value" -ForegroundColor $ValueColor
}

function Write-Status {
    param([string]$Text, [string]$Status, [string]$StatusColor)
    $gap = $W - $Text.Length - $Status.Length - 6
    if ($gap -lt 1) { $gap = 1 }
    Write-Host "  $Text" -ForegroundColor $C.Fg -NoNewline
    Write-Host (' ' * $gap) -NoNewline
    Write-Host "[$Status]" -ForegroundColor $StatusColor
}

function Show-Banner {
    Clear-Host
    $Host.UI.RawUI.BackgroundColor = $C.Bg
    Write-Host ''
    Write-Line '═' $C.Accent
    Write-Host ''
    Write-Centered '╦ ╦ ╦ ╔╗╔  ╔╦╗ ╦ ╦ ╔═╗ ╔═╗ ╦╔═ ╔═╗' $C.Accent
    Write-Centered '║║║ ║ ║║║   ║  ║║║ ║╣  ╠═╣ ╠╩╗ ╚═╗' $C.Accent
    Write-Centered '╚╩╝ ╩ ╝╚╝   ╩  ╚╩╝ ╚═╝ ╩ ╩ ╩ ╩ ╚═╝' $C.Accent
    Write-Host ''
    Write-Centered 'Windows 11  Declutter & Security Tweaks' $C.Heading
    Write-Centered 'v1.0' $C.Muted
    Write-Host ''
    Write-Line '═' $C.Accent
    Write-Host ''
}

# ── Fix Definitions ─────────────────────────────────────────────────────────
$script:Fixes = @(
    @{
        Id          = 1
        Name        = 'Remove "Learn about this picture" desktop icon'
        Description = 'Hides the Spotlight overlay icon from the desktop while keeping Spotlight wallpapers active.'
        Scope       = 'HKCU'
        Reboot      = $false
        Apply       = {
            # Hide icon via HideDesktopIcons
            $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            Set-ItemProperty -Path $path -Name '{2cc5ca98-6485-489a-920e-b3e88a6ccce3}' -Value 1 -Type DWord -Force

            # Remove NameSpace registration (prevents re-creation)
            $ns = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace\{2cc5ca98-6485-489a-920e-b3e88a6ccce3}'
            if (Test-Path $ns) { Remove-Item -Path $ns -Force }
        }
        Check       = {
            $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
            $val  = (Get-ItemProperty -Path $path -Name '{2cc5ca98-6485-489a-920e-b3e88a6ccce3}' -ErrorAction SilentlyContinue).'{2cc5ca98-6485-489a-920e-b3e88a6ccce3}'
            return ($val -eq 1)
        }
        Revert      = {
            $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
            Set-ItemProperty -Path $path -Name '{2cc5ca98-6485-489a-920e-b3e88a6ccce3}' -Value 0 -Type DWord -Force
        }
    },
    @{
        Id          = 2
        Name        = 'Remove fun facts from Spotlight lock screen'
        Description = 'Disables the text overlay and tips on the lock screen while keeping Spotlight background images.'
        Scope       = 'HKCU'
        Reboot      = $false
        Apply       = {
            $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            Set-ItemProperty -Path $path -Name 'ContentDeliveryAllowed'            -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $path -Name 'RotatingLockScreenEnabled'         -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $path -Name 'RotatingLockScreenOverlayEnabled'  -Value 0 -Type DWord -Force
            Set-ItemProperty -Path $path -Name 'SubscribedContent-338387Enabled'   -Value 0 -Type DWord -Force
        }
        Check       = {
            $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            $overlay = (Get-ItemProperty -Path $path -Name 'RotatingLockScreenOverlayEnabled' -ErrorAction SilentlyContinue).RotatingLockScreenOverlayEnabled
            $sub     = (Get-ItemProperty -Path $path -Name 'SubscribedContent-338387Enabled'  -ErrorAction SilentlyContinue).'SubscribedContent-338387Enabled'
            return ($overlay -eq 0 -and $sub -eq 0)
        }
        Revert      = {
            $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            Set-ItemProperty -Path $path -Name 'RotatingLockScreenOverlayEnabled'  -Value 1 -Type DWord -Force
            Set-ItemProperty -Path $path -Name 'SubscribedContent-338387Enabled'   -Value 1 -Type DWord -Force
        }
    },
    @{
        Id          = 3
        Name        = 'Disable web search in Start Menu'
        Description = 'Stops Bing web results from appearing when you search in the Start Menu. Local apps and files only.'
        Scope       = 'HKCU'
        Reboot      = $true
        Apply       = {
            # Method 1: DisableSearchBoxSuggestions (correct path with \Explorer subkey)
            $policyPath = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
            if (-not (Test-Path $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
            Set-ItemProperty -Path $policyPath -Name 'DisableSearchBoxSuggestions' -Value 1 -Type DWord -Force

            # Method 2: BingSearchEnabled (belt-and-suspenders)
            $searchPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
            if (-not (Test-Path $searchPath)) { New-Item -Path $searchPath -Force | Out-Null }
            Set-ItemProperty -Path $searchPath -Name 'BingSearchEnabled' -Value 0 -Type DWord -Force
        }
        Check       = {
            $v1 = (Get-ItemProperty -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name 'DisableSearchBoxSuggestions' -ErrorAction SilentlyContinue).DisableSearchBoxSuggestions
            $v2 = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'BingSearchEnabled' -ErrorAction SilentlyContinue).BingSearchEnabled
            return ($v1 -eq 1 -or $v2 -eq 0)
        }
        Revert      = {
            Remove-ItemProperty -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name 'DisableSearchBoxSuggestions' -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'BingSearchEnabled' -ErrorAction SilentlyContinue
        }
    },
    @{
        Id          = 4
        Name        = 'Auto-lock PC after 15 min inactivity'
        Description = 'Sets machine inactivity limit to 900 seconds (15 min). Requires admin and a reboot to take effect.'
        Scope       = 'HKLM'
        Reboot      = $true
        Apply       = {
            $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            Set-ItemProperty -Path $path -Name 'InactivityTimeoutSecs' -Value 900 -Type DWord -Force
            # Refresh group policy
            Start-Process -FilePath 'gpupdate.exe' -ArgumentList '/force' -WindowStyle Hidden -Wait
        }
        Check       = {
            $val = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'InactivityTimeoutSecs' -ErrorAction SilentlyContinue).InactivityTimeoutSecs
            return ($val -eq 900)
        }
        Revert      = {
            $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            Set-ItemProperty -Path $path -Name 'InactivityTimeoutSecs' -Value 0 -Type DWord -Force
            Start-Process -FilePath 'gpupdate.exe' -ArgumentList '/force' -WindowStyle Hidden -Wait
        }
    }
)

# ── Status Check ─────────────────────────────────────────────────────────────
function Get-FixStatus {
    param($Fix)
    try {
        $applied = & $Fix.Check
        if ($applied) { return 'APPLIED' } else { return 'NOT SET' }
    } catch {
        return 'UNKNOWN'
    }
}

# ── Admin Check ──────────────────────────────────────────────────────────────
function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ── Menu Renderer ────────────────────────────────────────────────────────────
function Show-Menu {
    Show-Banner

    $isAdmin = Test-IsAdmin
    if ($isAdmin) {
        Write-Host '  ● Running as Administrator' -ForegroundColor $C.Success
    } else {
        Write-Host '  ○ Not running as Administrator (Fix #4 unavailable)' -ForegroundColor $C.Warning
    }
    Write-Host ''
    Write-Line
    Write-Host ''
    Write-Host '  Press a number to toggle a fix ON/OFF' -ForegroundColor $C.Muted
    Write-Host ''

    foreach ($fix in $Fixes) {
        $status = Get-FixStatus $fix
        $isOn   = ($status -eq 'APPLIED')
        $num    = $fix.Id
        $name   = $fix.Name

        # Toggle indicator
        if ($isOn) {
            $toggle      = '  ON '
            $toggleColor = $C.Success
            $bullet      = '●'
            $bulletColor = $C.Success
        } else {
            $toggle      = ' OFF '
            $toggleColor = $C.Muted
            $bullet      = '○'
            $bulletColor = $C.Muted
        }

        Write-Host "  [$num] " -ForegroundColor $C.Accent -NoNewline
        Write-Host " $bullet " -ForegroundColor $bulletColor -NoNewline
        Write-Host $name -ForegroundColor $C.Heading -NoNewline
        $gap = $W - 10 - $name.Length - $toggle.Length
        if ($gap -lt 1) { $gap = 1 }
        Write-Host (' ' * $gap) -NoNewline
        if ($isOn) {
            Write-Host '[' -ForegroundColor $C.Muted -NoNewline
            Write-Host $toggle -ForegroundColor $toggleColor -NoNewline
            Write-Host ']' -ForegroundColor $C.Muted
        } else {
            Write-Host '[' -ForegroundColor $C.Muted -NoNewline
            Write-Host $toggle -ForegroundColor $toggleColor -NoNewline
            Write-Host ']' -ForegroundColor $C.Muted
        }

        Write-Host "         $($fix.Description)" -ForegroundColor $C.Muted

        $tags = @()
        $tags += $fix.Scope
        if ($fix.Reboot) { $tags += 'reboot needed' }
        Write-Host "         $($tags -join ' · ')" -ForegroundColor $C.Muted
        Write-Host ''
    }

    Write-Line
    Write-Host ''
    Write-Host '  [A] Toggle ALL on' -ForegroundColor $C.Accent -NoNewline
    Write-Host '    [R] Toggle ALL off' -ForegroundColor $C.Accent -NoNewline
    Write-Host '    [Q] Quit' -ForegroundColor $C.Accent
    Write-Host ''
    Write-Line
}

# ── Toggle Single Fix ────────────────────────────────────────────────────────
function Invoke-Toggle {
    param($Fix)

    $status = Get-FixStatus $fix
    $isOn   = ($status -eq 'APPLIED')
    $action = if ($isOn) { 'OFF' } else { 'ON' }
    $label  = $Fix.Name

    # Admin gate for HKLM fixes
    if ($Fix.Scope -eq 'HKLM' -and -not (Test-IsAdmin)) {
        Write-Host "  ✗ " -ForegroundColor $C.Error -NoNewline
        Write-Host "Skipped: $label (requires Administrator)" -ForegroundColor $C.Fg
        return $false
    }

    Write-Host "  ◌ " -ForegroundColor $C.Accent -NoNewline
    Write-Host "Toggling $action : $label" -ForegroundColor $C.Fg -NoNewline

    try {
        if ($isOn) { & $Fix.Revert } else { & $Fix.Apply }
        $icon  = if ($isOn) { '○' } else { '●' }
        $color = if ($isOn) { $C.Warning } else { $C.Success }
        Write-Host "`r  $icon " -ForegroundColor $color -NoNewline
        Write-Host "Toggled $action : $label" -ForegroundColor $C.Fg
        return $true
    } catch {
        Write-Host "`r  ✗ " -ForegroundColor $C.Error -NoNewline
        Write-Host "Failed : $label  ─  $($_.Exception.Message)" -ForegroundColor $C.Fg
        return $false
    }
}

# ── Main Loop ────────────────────────────────────────────────────────────────
$needsReboot = $false

while ($true) {
    Show-Menu

    Write-Host '  > ' -ForegroundColor $C.Accent -NoNewline
    $key = (Read-Host).Trim().ToUpper()

    Write-Host ''

    switch ($key) {
        'Q' {
            if ($needsReboot) {
                Write-Host ''
                Write-Host '  ⚠  Some changes need a reboot to take effect.' -ForegroundColor $C.Warning
                Write-Host '  Reboot now? [Y/N]: ' -ForegroundColor $C.Accent -NoNewline
                $rb = (Read-Host).Trim().ToUpper()
                if ($rb -eq 'Y') {
                    Write-Host '  Rebooting...' -ForegroundColor $C.Warning
                    Restart-Computer -Force
                }
            }
            Write-Host ''
            Write-Host '  Done.' -ForegroundColor $C.Accent
            Write-Host ''
            return
        }

        'A' {
            Write-Host '  Toggling all ON...' -ForegroundColor $C.Heading
            Write-Line '─' $C.Muted
            foreach ($fix in $Fixes) {
                $status = Get-FixStatus $fix
                if ($status -ne 'APPLIED') {
                    $ok = Invoke-Toggle $fix
                    if ($ok -and $fix.Reboot) { $needsReboot = $true }
                } else {
                    Write-Host "  ● Already ON : $($fix.Name)" -ForegroundColor $C.Muted
                }
            }
            Write-Host ''
            Write-Host '  Press any key...' -ForegroundColor $C.Muted
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }

        'R' {
            Write-Host '  Toggling all OFF...' -ForegroundColor $C.Heading
            Write-Line '─' $C.Muted
            foreach ($fix in $Fixes) {
                $status = Get-FixStatus $fix
                if ($status -eq 'APPLIED') {
                    $ok = Invoke-Toggle $fix
                    if ($ok -and $fix.Reboot) { $needsReboot = $true }
                } else {
                    Write-Host "  ○ Already OFF: $($fix.Name)" -ForegroundColor $C.Muted
                }
            }
            Write-Host ''
            Write-Host '  Press any key...' -ForegroundColor $C.Muted
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }

        { $_ -in '1','2','3','4' } {
            $fix = $Fixes[[int]$key - 1]
            $ok  = Invoke-Toggle $fix
            if ($ok -and $fix.Reboot) { $needsReboot = $true }
            Write-Host ''
            Write-Host '  Press any key...' -ForegroundColor $C.Muted
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }

        default {
            Write-Host '  Invalid option.' -ForegroundColor $C.Error
            Start-Sleep -Milliseconds 600
        }
    }
}
