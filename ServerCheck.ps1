#requires -Version 5.1

param(
    [string]$ServerListFile = (Join-Path $PSScriptRoot 'ServerList.txt'),
    [PSCredential]$Credential,
    [string]$ReportPath = (Join-Path $PSScriptRoot ('ServerCheck_{0}.html' -f (Get-Date -Format 'yyyy-MM-dd HHmmss')))
)

function Get-PendingRebootStatus {
    param([string]$ComputerName)

    $scriptBlock = {
        $reasons = @()

        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
            $reasons += 'Windows-Komponentenupdate'
        }

        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
            $reasons += 'Windows Update'
        }

        $rename = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($null -ne $rename.PendingFileRenameOperations) {
            $reasons += 'Ausstehende Dateioperationen'
        }

        [pscustomobject]@{
            Pending = ($reasons.Count -gt 0)
            Reasons = ($reasons -join ', ')
        }
    }

    $invokeParams = @{
        ComputerName = $ComputerName
        ScriptBlock = $scriptBlock
        ErrorAction = 'Stop'
    }

    if ($Credential) {
        $invokeParams.Credential = $Credential
    }

    Invoke-Command @invokeParams
}

function Test-Server {
    param(
        [string]$ComputerName,
        [PSCredential]$Credential
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $cimSession = $null

    try {
        $pingOk = Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue
        if (-not $pingOk) {
            [void]$findings.Add([pscustomobject]@{
                Severity = 'Critical'
                Action = 'Keine Ping-Antwort'
            })
        }

        if ($Credential) {
            $cimSession = New-CimSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
            $queryParams = @{ CimSession = $cimSession; ErrorAction = 'Stop' }
        }
        else {
            $queryParams = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
        }

        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" @queryParams

        foreach ($disk in $disks) {
            if ($disk.Size -le 0) { continue }

            $freePercent = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
            $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)

            if ($freePercent -lt 10) {
                [void]$findings.Add([pscustomobject]@{
                    Severity = 'Critical'
                    Action = ('Disk {0}: kritisch wenig Speicher frei ({1} GB / {2} Prozent)' -f $disk.DeviceID, $freeGB, $freePercent)
                })
            }
            elseif ($freePercent -lt 20) {
                [void]$findings.Add([pscustomobject]@{
                    Severity = 'Warning'
                    Action = ('Disk {0}: wenig Speicher frei ({1} GB / {2} Prozent)' -f $disk.DeviceID, $freeGB, $freePercent)
                })
            }
        }

        $reboot = Get-PendingRebootStatus -ComputerName $ComputerName
        if ($reboot.Pending) {
            [void]$findings.Add([pscustomobject]@{
                Severity = 'Warning'
                Action = ('Neustart erforderlich ({0})' -f $reboot.Reasons)
            })
        }
    }
    catch {
        [void]$findings.Add([pscustomobject]@{
            Severity = 'Critical'
            Action = ('Abfrage fehlgeschlagen - {0}' -f $_.Exception.Message)
        })
    }
    finally {
        if ($cimSession) {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        }
    }

    [pscustomobject]@{
        Server = $ComputerName
        Findings = @($findings)
        IsOk = ($findings.Count -eq 0)
    }
}

if (-not (Test-Path -LiteralPath $ServerListFile)) {
    Write-Host ('Serverliste nicht gefunden: {0}' -f $ServerListFile) -ForegroundColor Red
    exit 1
}

$serversRaw = @(Get-Content -LiteralPath $ServerListFile -ErrorAction Stop |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') })

$serversWithFlag = foreach ($entry in $serversRaw) {
    $isBold = $entry.EndsWith(';f', [StringComparison]::OrdinalIgnoreCase)
    $serverName = if ($isBold) {
        $entry.Substring(0, $entry.Length - 2).Trim()
    }
    else {
        $entry
    }

    [pscustomobject]@{
        Name = $serverName
        Bold = $isBold
    }
}

if ($serversWithFlag.Count -eq 0) {
    Write-Host 'Die Serverliste ist leer.' -ForegroundColor Red
    exit 1
}

$totalServers = $serversWithFlag.Count
$results = @()

for ($index = 0; $index -lt $totalServers; $index++) {
    $serverEntry = $serversWithFlag[$index]
    $server = $serverEntry.Name
    $currentServer = $index + 1
    $percentComplete = [math]::Round(($currentServer / $totalServers) * 100, 0)

    Write-Progress `
        -Activity 'Server Health Check wird ausgefuehrt' `
        -Status ('Server gecheckt: {0} von {1} ({2})' -f $currentServer, $totalServers, $server) `
        -PercentComplete $percentComplete

    $testResult = Test-Server -ComputerName $server -Credential $Credential

    $results += [pscustomobject]@{
        Server = $testResult.Server
        Findings = $testResult.Findings
        IsOk = $testResult.IsOk
        Bold = $serverEntry.Bold
    }
}

Write-Progress -Activity 'Server Health Check wird ausgefuehrt' -Completed

$problemResults = @($results | Where-Object { -not $_.IsOk })

Write-Host ''
Write-Host '========== FEHLER / WARNUNGEN ==========' -ForegroundColor Yellow

if ($problemResults.Count -eq 0) {
    Write-Host 'Keine Fehler oder Warnungen gefunden.' -ForegroundColor Green
}
else {
    $serverColumnWidth = ($results | ForEach-Object { $_.Server.Length } | Measure-Object -Maximum).Maximum
    if ($serverColumnWidth -lt 25) { $serverColumnWidth = 25 }

    $lineFormat = '{0,-' + $serverColumnWidth + '}  {1}'

    Write-Host ($lineFormat -f 'SERVER', 'HANDLUNGSBEDARF') -ForegroundColor Cyan
    Write-Host (('-' * $serverColumnWidth) + '  ' + ('-' * 70)) -ForegroundColor DarkGray

    foreach ($result in $problemResults) {
        foreach ($finding in $result.Findings) {
            $foregroundColor = if ($finding.Severity -eq 'Critical') { 'Red' } else { 'Yellow' }
            Write-Host ($lineFormat -f $result.Server, $finding.Action) -ForegroundColor $foregroundColor -BackgroundColor Black
        }
    }
}

Write-Host ''
Write-Host ('Gepruefte Server: {0}; Problemfaelle: {1}' -f $results.Count, $problemResults.Count) -ForegroundColor Gray
Write-Host ''
Write-Host 'Hinweis: Dieses Skript fragt keine Reimelt- und Zeppelin-Instanzen ab! Es wird noch ausgebaut.' -ForegroundColor Yellow

$rows = foreach ($result in $results) {
    if ($result.IsOk) {
        [pscustomobject]@{
            Server = $result.Server
            Severity = 'OK'
            Action = 'Keine Fehler oder Warnungen'
            Bold = $result.Bold
        }
    }
    else {
        foreach ($finding in $result.Findings) {
            [pscustomobject]@{
                Server = $result.Server
                Severity = $finding.Severity
                Action = $finding.Action
                Bold = $result.Bold
            }
        }
    }
}

$sortedRows = $rows | Sort-Object -Property @{
    Expression = {
        switch ($_.Severity) {
            'Critical' { 1 }
            'Warning'  { 2 }
            default    { 3 }
        }
    }
}

$rowHtml = foreach ($row in $sortedRows) {
    $cssClass = switch ($row.Severity) {
        'Critical' { 'critical' }
        'Warning'  { 'warning' }
        default    { 'ok' }
    }

    $boldClass = if ($row.Bold) { ' bold' } else { '' }
    $serverHtml = [System.Net.WebUtility]::HtmlEncode([string]$row.Server)
    $severityHtml = [System.Net.WebUtility]::HtmlEncode([string]$row.Severity)
    $actionHtml = [System.Net.WebUtility]::HtmlEncode([string]$row.Action)

    "<tr class='$cssClass$boldClass'><td>$serverHtml</td><td>$severityHtml</td><td>$actionHtml</td><td class='check'><input type='checkbox'></td></tr>"
}

$htmlPath = [System.IO.Path]::ChangeExtension($ReportPath, '.html')
$html = @"
<!doctype html>
<html lang='de'>
<head>
<meta charset='utf-8'>
<title>Serv</title>
<style>
@page { size: A4; margin: 16mm; }
body { font-family: Arial, sans-serif; font-size: 10pt; color: #222; }
h1 { color: #1f4e79; margin-bottom: 4px; }
.meta { color: #666; margin-bottom: 16px; }
.checks { margin-top: 8px; color: #444; }
.checks strong { color: #222; }
.checks ul { margin-top: 4px; margin-bottom: 12px; padding-left: 22px; }
.checks li { margin-bottom: 2px; }
table { width: 100%; border-collapse: collapse; }
th { background: #1f4e79; color: white; text-align: left; }
th, td { border: 1px solid #aaa; padding: 6px; vertical-align: top; }
.critical { background: #f8d7da; }
.warning { background: #fff3cd; }
.ok { background: #d1e7dd; }
.bold { font-weight: bold; }
.check { width: 55px; text-align: center; }
input[type=checkbox] { width: 16px; height: 16px; }
.footer { margin-top: 16px; color: #666; font-size: 8pt; }
</style>
</head>
<body>
<h1>Serv</h1>
<div class='meta'>
Erstellt: $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')<br>
Gepruefte Server: $($results.Count) | Problemfaelle: $($problemResults.Count)
<div class='checks'>
<strong>Geprueft werden:</strong>
<ul>
<li>Ping-Erreichbarkeit der Server</li>
<li>Freier Speicherplatz auf allen lokalen Laufwerken (C:, D:, E: usw.)</li>
<li>Ausstehender Neustart</li>
<li>Ausstehende Windows-Komponentenupdates</li>
<li>Ausstehende Windows-Updates</li>
<li>Ausstehende Dateioperationen nach einem Neustart</li>
</ul>
</div>
</div>
<table>
<thead><tr><th>Server</th><th>Status</th><th>Handlungsbedarf</th><th>Erledigt</th></tr></thead>
<tbody>
$($rowHtml -join [Environment]::NewLine)
</tbody>
</table>
<div class='footer'>Hinweis: Dieses Skript fragt keine Reimelt- und Zeppelin-Instanzen ab! Es wird noch ausgebaut.</div>
</body>
</html>
"@

$html | Set-Content -LiteralPath $htmlPath -Encoding UTF8

Write-Host ('HTML-Report wurde erstellt: {0}' -f $htmlPath) -Foreground
