#Requires -Version 5.1
<#
.SYNOPSIS
    Queries Splunk for log issues and sends a Microsoft Teams alert.

.DESCRIPTION
    Runs a Splunk search via the REST API, checks the result count against
    a threshold, and posts a formatted card to a Teams incoming webhook.
    Designed to run on demand or on a schedule via Windows Task Scheduler.

.EXAMPLE
    .\splunk-alert.ps1

.EXAMPLE
    $env:SPLUNK_TOKEN = "mytoken"; .\splunk-alert.ps1
#>

# ── Configuration ─────────────────────────────────────────────────────────────
# Edit these values, or override any of them via environment variables.

$Config = @{
    # Splunk REST API base URL — include port (usually 8089)
    SplunkHost      = "https://splunk.mycompany.com:8089"

    # API token from Splunk: Settings > Tokens > New Token
    SplunkToken     = ""

    # Any valid SPL search expression
    SplunkQuery     = "search index=main (level=error OR level=critical)"

    # How far back to search — must be >= how often you run the script
    SplunkTimeRange = "-15m"

    # Alert fires when Splunk returns >= this many results
    AlertThreshold  = 1

    # Max seconds to wait for the Splunk search job to finish
    MaxPollSeconds  = 60

    # How many sample log lines to include in the Teams message
    SampleSize      = 5

    # Teams channel > ... > Connectors > Incoming Webhook > copy URL
    TeamsWebhookUrl = ""

    # Log file path — set to $null to disable file logging
    LogFile         = "C:\Logs\splunk-alert.log"

    # Set to $true if Splunk uses a self-signed certificate
    SkipTlsVerify   = $false
}

# Environment variable overrides (useful for Task Scheduler / CI)
if ($env:SPLUNK_HOST)       { $Config.SplunkHost      = $env:SPLUNK_HOST }
if ($env:SPLUNK_TOKEN)      { $Config.SplunkToken     = $env:SPLUNK_TOKEN }
if ($env:SPLUNK_QUERY)      { $Config.SplunkQuery     = $env:SPLUNK_QUERY }
if ($env:SPLUNK_TIMERANGE)  { $Config.SplunkTimeRange = $env:SPLUNK_TIMERANGE }
if ($env:ALERT_THRESHOLD)   { $Config.AlertThreshold  = [int]$env:ALERT_THRESHOLD }
if ($env:TEAMS_WEBHOOK_URL) { $Config.TeamsWebhookUrl = $env:TEAMS_WEBHOOK_URL }

# ── Logging ───────────────────────────────────────────────────────────────────

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $ts   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "[$ts] [$Level] $Message"
    Write-Host $line

    if ($Config.LogFile) {
        $dir = Split-Path -Parent $Config.LogFile
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -Path $Config.LogFile -Value $line -Encoding UTF8
    }
}

# ── TLS / certificate handling ────────────────────────────────────────────────

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($Config.SkipTlsVerify) {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # PS 5.1: inject a permissive certificate policy
        if (-not ([System.Management.Automation.PSTypeName]'TrustAllCerts').Type) {
            Add-Type @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
                                      WebRequest req, int problem) { return true; }
}
'@
            [Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
        }
    }
    Write-Log 'TLS certificate verification disabled' 'WARN'
}

# ── Validation ────────────────────────────────────────────────────────────────

function Assert-Config {
    $missing = @()
    if (-not $Config.SplunkHost)      { $missing += 'SplunkHost' }
    if (-not $Config.SplunkToken)     { $missing += 'SplunkToken' }
    if (-not $Config.SplunkQuery)     { $missing += 'SplunkQuery' }
    if (-not $Config.TeamsWebhookUrl) { $missing += 'TeamsWebhookUrl' }
    if ($missing.Count -gt 0) {
        Write-Log "Missing required config values: $($missing -join ', ')" 'ERROR'
        exit 1
    }
}

# ── Splunk REST API helpers ───────────────────────────────────────────────────

function Invoke-SplunkApi {
    param(
        [string]$Method = 'GET',
        [string]$Path,
        [hashtable]$Body = @{}
    )

    $params = @{
        Method      = $Method
        Uri         = "$($Config.SplunkHost)$Path"
        Headers     = @{ Authorization = "Bearer $($Config.SplunkToken)" }
        ContentType = 'application/x-www-form-urlencoded'
        ErrorAction = 'Stop'
    }

    if ($Body.Count -gt 0 -and $Method -eq 'POST') {
        $params.Body = $Body
    }

    # -SkipCertificateCheck is a PS 6+ parameter
    if ($Config.SkipTlsVerify -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params.SkipCertificateCheck = $true
    }

    return Invoke-RestMethod @params
}

function Start-SplunkJob {
    Write-Log "Creating search job: $($Config.SplunkQuery)"
    $response = Invoke-SplunkApi -Method POST -Path '/services/search/jobs' -Body @{
        search        = $Config.SplunkQuery
        earliest_time = $Config.SplunkTimeRange
        latest_time   = 'now'
        output_mode   = 'json'
    }
    if (-not $response.sid) {
        throw "Splunk did not return a job SID. Response: $($response | ConvertTo-Json)"
    }
    return $response.sid
}

function Wait-SplunkJob {
    param([string]$Sid)
    $deadline = (Get-Date).AddSeconds($Config.MaxPollSeconds)
    while ((Get-Date) -lt $deadline) {
        $job   = Invoke-SplunkApi -Path "/services/search/jobs/$Sid`?output_mode=json"
        $state = $job.entry[0].content.dispatchState
        Write-Log "Job state: $state"
        switch ($state) {
            'DONE'   { return }
            'FAILED' { throw "Splunk search job failed (SID: $Sid)" }
        }
        Start-Sleep -Seconds 3
    }
    throw "Splunk search job timed out after $($Config.MaxPollSeconds)s (SID: $Sid)"
}

function Get-SplunkResults {
    param([string]$Sid)
    $response = Invoke-SplunkApi `
        -Path "/services/search/jobs/$Sid/results?output_mode=json&count=$($Config.SampleSize)"
    return $response.results
}

# ── Teams alert ───────────────────────────────────────────────────────────────

function Send-TeamsAlert {
    param(
        [int]$Count,
        [array]$Results
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')

    # Prefer _raw log line; fall back to field=value pairs for stats queries
    $sampleLines = foreach ($r in $Results) {
        if ($r._raw) {
            $r._raw.Trim()
        } else {
            $fields = $r.PSObject.Properties |
                Where-Object { $_.Name -notlike '_*' -and $_.Value } |
                ForEach-Object { "$($_.Name)=$($_.Value)" }
            $fields -join '  '
        }
    }
    $sampleText = $sampleLines -join "`n"

    $payload = [ordered]@{
        '@type'    = 'MessageCard'
        '@context' = 'http://schema.org/extensions'
        themeColor = 'FF0000'
        summary    = "Splunk Alert: $Count event(s) found"
        sections   = @(
            [ordered]@{
                activityTitle    = 'Splunk Alert'
                activitySubtitle = "$Count event(s) matched in the last $($Config.SplunkTimeRange) as of $timestamp"
                facts            = @(
                    @{ name = 'Query';        value = $Config.SplunkQuery }
                    @{ name = 'Time Range';   value = $Config.SplunkTimeRange }
                    @{ name = 'Events Found'; value = "$Count" }
                    @{ name = 'Splunk Host';  value = $Config.SplunkHost }
                )
            },
            @{
                title = "Sample events (showing up to $($Config.SampleSize))"
                text  = "<pre>$sampleText</pre>"
            }
        )
        potentialAction = @(
            @{
                '@type'  = 'OpenUri'
                name     = 'Open Splunk'
                targets  = @(@{ os = 'default'; uri = $Config.SplunkHost })
            }
        )
    } | ConvertTo-Json -Depth 10

    $params = @{
        Method      = 'POST'
        Uri         = $Config.TeamsWebhookUrl
        ContentType = 'application/json'
        Body        = $payload
        ErrorAction = 'Stop'
    }
    if ($Config.SkipTlsVerify -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params.SkipCertificateCheck = $true
    }

    Invoke-RestMethod @params | Out-Null
    Write-Log 'Teams alert sent'
}

# ── Main ──────────────────────────────────────────────────────────────────────

try {
    Assert-Config

    $sid = Start-SplunkJob
    Write-Log "Search job created: SID=$sid"

    Wait-SplunkJob -Sid $sid

    $results = Get-SplunkResults -Sid $sid
    $count   = @($results).Count
    Write-Log "Found $count result(s) (threshold: $($Config.AlertThreshold))"

    if ($count -ge $Config.AlertThreshold) {
        Send-TeamsAlert -Count $count -Results $results
    } else {
        Write-Log 'Below threshold — no alert sent'
    }

    exit 0
}
catch {
    Write-Log "FATAL: $_" 'ERROR'
    exit 1
}
