<#
.SYNOPSIS
  Self-healing Windows portproxy + firewall setup for the credo LAN peer relay on
  WSL2 in default NAT mode.

.DESCRIPTION
  In WSL2 default NAT mode the WSL daemon is NOT reachable from other machines on the
  LAN: it sits behind a NAT that only the Windows host can see, and its IP changes on
  every WSL restart. To let a LAN peer reach the relay daemon (which listens on
  0.0.0.0:PORT inside WSL), the Windows host must forward its own LAN-IP:PORT to the
  current WSL IP:PORT (a netsh portproxy) and allow that port inbound in the firewall.

  Because the WSL IP changes, the portproxy must be refreshed whenever WSL restarts.
  This script solves that with:
    - a scheduled task that re-applies the portproxy at every Windows startup, and
    - the same task being runnable ON DEMAND (from the WSL autostart hook) with no UAC
      prompt, so the portproxy is also refreshed each time the relay daemon starts.

  On NATIVE Linux there is no NAT and the daemon already listens on the LAN directly,
  so this script is not needed there (see the plugin README / peer-lan command docs).

.PARAMETER Port
  The TCP port to forward. MUST match listen_port in ~/.claude/credo/peer-lan.json
  (default 48610).

.PARAMETER Install
  One-time setup (REQUIRES an elevated / Administrator PowerShell):
    - create a LAN-scoped inbound firewall allow rule for TCP Port (if absent),
    - register the scheduled task (TaskName) that runs this script with -Refresh,
      elevated, at startup and on demand, and
    - run one -Refresh immediately.
  Idempotent: re-running updates the rule and task in place, never duplicates them.

.PARAMETER Uninstall
  Remove the scheduled task, the firewall rule, and the portproxy entry for Port
  (REQUIRES an elevated / Administrator PowerShell).

.PARAMETER Refresh
  Recompute the current WSL IP and reset the portproxy for Port to point at it. This
  is the action the scheduled task runs. It needs an elevated context (the task
  provides it); run manually only from an elevated PowerShell.

.PARAMETER TaskName
  Name of the scheduled task (default "credo-peer-lan-proxy").

.EXAMPLE
  # One time per machine, in an ELEVATED Windows PowerShell:
  powershell -NoProfile -ExecutionPolicy Bypass -File credo-peer-lan-winproxy.ps1 -Install -Port 48610

.NOTES
  This script is invoked by the user in Windows PowerShell (and by the Task Scheduler),
  never by the WSL bash hook directly. The WSL hook only triggers the already-registered
  task on demand. State-changing actions (netsh, firewall, task) require elevation.
#>

[CmdletBinding()]
param(
    [int]$Port = 48610,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Refresh,
    [string]$TaskName = "credo-peer-lan-proxy"
)

$ErrorActionPreference = "Stop"

# Absolute path to this script, so the scheduled task can invoke it after setup.
$ScriptPath = $MyInvocation.MyCommand.Path

function Test-Admin {
    # True when the current PowerShell runs elevated (member of the Administrators role).
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WslIp {
    # Current default-distro WSL IPv4, as seen from the Windows host. The daemon binds
    # 0.0.0.0 inside WSL, so any WSL IP reaches it; we take the first IPv4 token of
    # `wsl hostname -I`. wsl.exe output can carry trailing CR / NUL bytes and several
    # space-separated addresses, so normalize and pick the first valid IPv4.
    $raw = (& wsl.exe hostname -I) 2>$null
    if ($null -eq $raw) { return $null }
    $text = ($raw -join " ") -replace "`0", ""
    foreach ($tok in ($text -split "\s+")) {
        $t = $tok.Trim()
        if ($t -match "^\d{1,3}(\.\d{1,3}){3}$") { return $t }
    }
    return $null
}

function Invoke-Refresh {
    param([int]$Port)

    if (-not (Test-Admin)) {
        Write-Warning ("Refresh resets a netsh portproxy, which needs Administrator rights. " +
            "Run this from an elevated PowerShell, or let the scheduled task run it.")
    }

    $wslip = Get-WslIp
    if ([string]::IsNullOrWhiteSpace($wslip)) {
        throw "Could not determine the WSL IP (wsl.exe hostname -I returned nothing). Is WSL installed and a default distro set?"
    }

    # Idempotent reset: delete any existing mapping for this listen port (ignore if
    # absent), then add the current one. netsh returns non-zero when the entry does not
    # exist; that is expected on a first run, so the delete error is swallowed.
    & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port 2>$null | Out-Null
    & netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$Port connectaddress=$wslip connectport=$Port
    if ($LASTEXITCODE -ne 0) {
        throw "netsh portproxy add failed (exit $LASTEXITCODE). Are you elevated?"
    }
    Write-Host ("Portproxy set: 0.0.0.0:{0} -> {1}:{0}" -f $Port, $wslip)
}

function Invoke-Install {
    param([int]$Port, [string]$TaskName)

    if (-not (Test-Admin)) {
        throw "-Install needs an elevated PowerShell. Right-click Windows PowerShell and choose 'Run as administrator', then re-run with -Install."
    }

    # (a) LAN-scoped inbound firewall allow rule for TCP Port. The DisplayName carries
    # the port so distinct ports get distinct rules. Remove any existing rule with this
    # name first, so re-running -Install never leaves duplicates and always applies the
    # current scope.
    $ruleName = "credo-peer-lan $Port"
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -RemoteAddress LocalSubnet -Profile Private, Domain | Out-Null
    Write-Host ("Firewall rule ensured: '{0}' (TCP {1}, inbound, LocalSubnet, Private+Domain)" -f $ruleName, $Port)

    # (b) Scheduled task that runs THIS script with -Refresh. It runs elevated
    # (RunLevel Highest) so netsh succeeds, at every startup, and S4U so it runs whether
    # or not the user is logged on without storing a password. A non-elevated caller
    # (the WSL hook) can trigger it on demand with `schtasks /Run /TN <name>` and gets NO
    # UAC prompt, because triggering only asks the Task Scheduler service to run it - the
    # elevation lives in the task definition, not in the caller.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`" -Refresh -Port {1}" -f $ScriptPath, $Port)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
        -LogonType S4U -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    # -Force makes registration idempotent: it overwrites an existing task of the same
    # name instead of failing, so re-running -Install updates it in place.
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host ("Scheduled task registered: '{0}' (elevated, at startup + on demand)" -f $TaskName)

    # (c) Apply the portproxy right now so the relay works without a reboot.
    Invoke-Refresh -Port $Port

    Write-Host ""
    Write-Host "Install complete. The portproxy now refreshes automatically at Windows startup"
    Write-Host "and whenever the WSL relay daemon starts (the autostart hook triggers the task)."
}

function Invoke-Uninstall {
    param([int]$Port, [string]$TaskName)

    if (-not (Test-Admin)) {
        throw "-Uninstall needs an elevated PowerShell. Run as administrator, then re-run with -Uninstall."
    }

    # Remove the scheduled task (ignore if absent).
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host ("Scheduled task removed: '{0}'" -f $TaskName)
    }
    else {
        Write-Host ("Scheduled task '{0}' not present; nothing to remove." -f $TaskName)
    }

    # Remove the firewall rule (ignore if absent).
    $ruleName = "credo-peer-lan $Port"
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($rule) {
        $rule | Remove-NetFirewallRule
        Write-Host ("Firewall rule removed: '{0}'" -f $ruleName)
    }
    else {
        Write-Host ("Firewall rule '{0}' not present; nothing to remove." -f $ruleName)
    }

    # Remove the portproxy entry (ignore if absent).
    & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port 2>$null | Out-Null
    Write-Host ("Portproxy entry for listenport {0} removed (if any)." -f $Port)
}

# -- dispatch ----------------------------------------------------------------
$selected = @($Install, $Uninstall, $Refresh | Where-Object { $_ }).Count
if ($selected -gt 1) {
    throw "Choose exactly one action: -Install, -Uninstall, or -Refresh."
}

if ($Install) {
    Invoke-Install -Port $Port -TaskName $TaskName
}
elseif ($Uninstall) {
    Invoke-Uninstall -Port $Port -TaskName $TaskName
}
elseif ($Refresh) {
    Invoke-Refresh -Port $Port
}
else {
    Write-Host "credo-peer-lan-winproxy.ps1 - WSL2 portproxy helper for the credo LAN relay"
    Write-Host ""
    Write-Host "Usage (run elevated for -Install / -Uninstall / -Refresh):"
    Write-Host "  -Install    [-Port N] [-TaskName name]   one-time setup: firewall + task + refresh"
    Write-Host "  -Uninstall  [-Port N] [-TaskName name]   remove task, firewall rule, portproxy"
    Write-Host "  -Refresh    [-Port N]                     re-point the portproxy at the current WSL IP"
    Write-Host ""
    Write-Host "Port MUST match listen_port in ~/.claude/credo/peer-lan.json (default 48610)."
}
