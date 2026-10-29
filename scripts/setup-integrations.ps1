<#
.SYNOPSIS
    Checks the lab prerequisites and collects the Dynatrace and ServiceNow
    credentials into .env, validating each one before it is saved.

.DESCRIPTION
    1. Tools: bash, az, jq, openssl, kubectl, git, curl and terraform, checked
       from the same bash that runs deploy.sh, so the PATH it sees is the PATH
       that matters. On Windows, missing tools can be installed with winget.
    2. Azure: az login, and the target subscription when one is given.
    3. Dynatrace: environment URL, API token (required scopes checked through
       /api/v2/apiTokens/lookup) and platform token (MCP gateway handshake).
    4. ServiceNow: instance URL and admin credentials (login, admin role, and
       whether the developer instance is hibernating).

    Secrets are read with hidden input and written only to the git-ignored
    .env, never echoed. Values already in .env are re-validated, and you are
    prompted only for what is missing or rejected. Run it on its own, or let
    deploy.ps1 run it for you.

.PARAMETER SubscriptionId
    Also confirm the signed-in account can see this subscription.

.PARAMETER SkipDynatrace
    Skip the Dynatrace and ServiceNow checks (Azure Monitor-only lab).

.PARAMETER SkipServiceNow
    Skip the ServiceNow checks.

.PARAMETER NonInteractive
    Never prompt or install; fail if anything is missing or invalid.

.EXAMPLE
    .\scripts\setup-integrations.ps1

.EXAMPLE
    .\scripts\setup-integrations.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [string] $SubscriptionId,
    [switch] $SkipDynatrace,
    [switch] $SkipServiceNow,
    [switch] $NonInteractive
)

. (Join-Path $PSScriptRoot 'lib.ps1')

$RepoRoot = Get-LabRepoRoot
$EnvFile = Join-Path $RepoRoot '.env'
$IsWin = $env:OS -eq 'Windows_NT'
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:EnvLines = $null
$script:DtScopes = @()
$script:McpMissing = $false
$script:McpOther = $null

function Write-Step([string] $m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok([string] $m)   { Write-Host "  PASS $m" -ForegroundColor Green }
function Write-Warn([string] $m) { Write-Host "  WARN $m" -ForegroundColor Yellow }
function Write-Fail([string] $m) { Write-Host "  FAIL $m" -ForegroundColor Red; $script:Failures.Add($m) }

function Confirm-Lab([string] $question) {
    if ($NonInteractive) { return $false }
    (Read-Host "  $question [Y/n]") -notmatch '^(n|no)$'
}

# --- .env --------------------------------------------------------------------

function Read-EnvFile {
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot '.env.example') -Destination $EnvFile
        Write-Host "  Created .env from .env.example" -ForegroundColor DarkGray
    }
    $script:EnvLines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in [IO.File]::ReadAllLines($EnvFile)) { $script:EnvLines.Add($l.TrimEnd("`r")) }
}

function Get-EnvValue([string] $key) {
    foreach ($l in $script:EnvLines) {
        if ($l -match "^$key=(.*)$") { return $Matches[1].Trim().Trim('"') }
    }
    ''
}

function Set-EnvValue([string] $key, [string] $value) {
    for ($i = 0; $i -lt $script:EnvLines.Count; $i++) {
        if ($script:EnvLines[$i] -match "^$key=") { $script:EnvLines[$i] = "$key=$value"; return }
    }
    $script:EnvLines.Add("$key=$value")
}

function Save-EnvFile {
    # LF and no BOM: the bash loader reads this file.
    [IO.File]::WriteAllText($EnvFile, (($script:EnvLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

function Read-Value([string] $prompt, [string] $current, [switch] $Secret) {
    $hint = if ($current) { if ($Secret) { ' [set; Enter keeps it]' } else { " [$current]" } } else { '' }
    if ($Secret) {
        $ss = Read-Host -Prompt "  $prompt$hint" -AsSecureString
        $v = [Net.NetworkCredential]::new('', $ss).Password
    } else {
        $v = Read-Host -Prompt "  $prompt$hint"
    }
    $v = "$v".Trim()
    if ($v) { $v } else { $current }
}

# Prompts until $validate accepts the value (returns $null) or the user gives up.
function Get-ValidValue {
    param([string] $Key, [string] $Prompt, [scriptblock] $Validate, [switch] $Secret, [switch] $Optional)
    $value = Get-EnvValue $Key
    $asked = $false
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        if (-not $value -or $asked) {
            if ($NonInteractive) {
                if (-not $value) {
                    if ($Optional) { Write-Warn "$Key is not set"; return '' }
                    Write-Fail "$Key is not set in .env"; return $null
                }
            } else {
                $value = Read-Value -prompt $Prompt -current $value -Secret:$Secret
            }
        }
        if (-not $value) {
            if ($Optional) { Write-Warn "$Key left empty"; return '' }
            Write-Warn "$Key is required"; $asked = $true; continue
        }
        $err = & $Validate $value
        if (-not $err) { Set-EnvValue $Key $value; Save-EnvFile; return $value }
        Write-Warn $err
        if ($NonInteractive) { Write-Fail "$Key in .env was rejected"; return $null }
        $asked = $true
        $value = ''
    }
    Write-Fail "${Key}: gave up after several attempts"
    $null
}

# --- HTTP --------------------------------------------------------------------

function Invoke-LabHttp {
    param([string] $Method, [string] $Uri, [hashtable] $Headers = @{}, [string] $Body)
    $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = 30; UseBasicParsing = $true; ErrorAction = 'Stop' }
    if ($Body) { $p.Body = $Body; $p.ContentType = 'application/json' }
    try {
        $r = Invoke-WebRequest @p
        $type = "$($r.Headers['Content-Type'])"
        return [pscustomobject]@{ Code = [int]$r.StatusCode; Body = "$($r.Content)"; Json = ($type -match 'json') }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) { return [pscustomobject]@{ Code = [int]$resp.StatusCode; Body = ''; Json = $false } }
        return [pscustomobject]@{ Code = 0; Body = $_.Exception.Message; Json = $false }
    }
}

function Get-BasicAuth([string] $user, [string] $pass) {
    'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:${pass}"))
}

# Mirrors dt_resolve_urls in lib-integrations.sh.
function Resolve-DynatraceUrls([string] $url) {
    $h = ($url -replace '^https?://', '').Split('/')[0].ToLowerInvariant()
    switch -Regex ($h) {
        '\.apps\.dynatrace\.com$'     { return @{ Apps = "https://$h"; Classic = 'https://' + ($h -replace '\.apps\.dynatrace\.com$', '.live.dynatrace.com') } }
        '\.live\.dynatrace\.com$'     { return @{ Classic = "https://$h"; Apps = 'https://' + ($h -replace '\.live\.dynatrace\.com$', '.apps.dynatrace.com') } }
        '\.apps\.dynatracelabs\.com$' { return @{ Apps = "https://$h"; Classic = 'https://' + ($h -replace '\.apps\.dynatracelabs\.com$', '.dynatracelabs.com') } }
        '\.dynatracelabs\.com$'       { return @{ Classic = "https://$h"; Apps = 'https://' + ($h -replace '\.dynatracelabs\.com$', '.apps.dynatracelabs.com') } }
        default                       { return @{ Classic = "https://$h"; Apps = "https://$h" } }
    }
}

# --- 1. Tools ----------------------------------------------------------------

$Tools = [ordered]@{
    az        = @{ Min = '2.60'; Winget = 'Microsoft.AzureCLI';  Hint = 'https://learn.microsoft.com/cli/azure/install-azure-cli' }
    git       = @{ Min = '';     Winget = 'Git.Git';             Hint = 'https://git-scm.com/downloads' }
    jq        = @{ Min = '';     Winget = 'jqlang.jq';           Hint = 'https://jqlang.github.io/jq/download/' }
    openssl   = @{ Min = '3.0';  Winget = '';                    Hint = 'Ships with Git for Windows; elsewhere use your package manager' }
    curl      = @{ Min = '';     Winget = '';                    Hint = 'Ships with Git for Windows and Windows 10+' }
    kubectl   = @{ Min = '';     Winget = 'Kubernetes.kubectl';  Hint = 'or: az aks install-cli' }
    terraform = @{ Min = '1.6';  Winget = 'Hashicorp.Terraform'; Hint = 'https://developer.hashicorp.com/terraform/install'; NeedsDt = $true }
}

function Update-ProcessPath {
    if (-not $IsWin) { return }
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user, $env:Path) -join ';')
}

# Asks the bash that deploy.sh will use, so Git Bash/WSL PATH differences show up here.
function Get-BashToolReport([string] $bash) {
    $names = ($Tools.Keys -join ' ')
    $probe = @'
for t in __NAMES__; do
  if command -v "$t" >/dev/null 2>&1; then
    case "$t" in
      az)        v="$(az version --query '"azure-cli"' -o tsv 2>/dev/null)" ;;
      terraform) v="$(terraform version 2>/dev/null | head -n1 | sed 's/^Terraform v//')" ;;
      openssl)   v="$(openssl version 2>/dev/null | awk '{print $2}')" ;;
      kubectl)   v="$(kubectl version --client 2>/dev/null | head -n1 | sed 's/.*v//')" ;;
      *)         v="$("$t" --version 2>/dev/null | head -n1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1)" ;;
    esac
    echo "$t|ok|$v"
  else
    echo "$t|missing|"
  fi
done
'@.Replace('__NAMES__', $names).Replace("`r", '')
    # A file, not bash -c: Windows PowerShell 5.1 mangles quotes in native arguments.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "lab-tools-$PID.sh"
    [IO.File]::WriteAllText($tmp, $probe, [Text.UTF8Encoding]::new($false))
    try {
        $out = if ($bash -eq 'wsl-bash') { & wsl bash (ConvertTo-BashPath $tmp) } else { & $bash $tmp }
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    $report = @{}
    foreach ($line in $out) {
        $parts = "$line".Trim().Split('|')
        if ($parts.Count -eq 3) { $report[$parts[0]] = @{ Found = ($parts[1] -eq 'ok'); Version = $parts[2] } }
    }
    $report
}

function Test-MinVersion([string] $have, [string] $min) {
    if (-not $min) { return $true }
    if ($have -notmatch '^(\d+)\.(\d+)') { return $true }  # unknown format: let the scripts decide
    [version]"$($Matches[1]).$($Matches[2])" -ge [version]$min
}

Write-Step 'Checking tools'
try { $bash = Find-Bash; Write-Ok "bash: $bash" } catch { Write-Fail $_.Exception.Message; $bash = $null }

if ($bash) {
    $report = Get-BashToolReport $bash
    if ($report.Count -eq 0) {
        Write-Fail "Could not run the tool check through $bash"
        $bash = $null
    }
}
if ($bash) {
    $missing = @($Tools.Keys | Where-Object {
        -not ($Tools[$_].ContainsKey('NeedsDt') -and $SkipDynatrace) -and
        -not ($report.ContainsKey($_) -and $report[$_].Found) })

    if ($missing.Count -and $IsWin -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        $installable = @($missing | Where-Object { $Tools[$_].Winget })
        if ($installable.Count -and (Confirm-Lab "Install missing tool(s) with winget: $($installable -join ', ')?")) {
            foreach ($t in $installable) {
                Write-Host "  Installing $t ($($Tools[$t].Winget))..." -ForegroundColor DarkGray
                & winget install --id $Tools[$t].Winget -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
            }
            Update-ProcessPath
            $report = Get-BashToolReport $bash
        }
    }

    foreach ($t in $Tools.Keys) {
        $spec = $Tools[$t]
        if ($spec.ContainsKey('NeedsDt') -and $SkipDynatrace) { continue }
        $r = if ($report.ContainsKey($t)) { $report[$t] } else { $null }
        if (-not $r -or -not $r.Found) {
            if ($t -eq 'kubectl') { Write-Warn "kubectl not found; deploy.sh will run 'az aks install-cli'"; continue }
            Write-Fail "$t not found. $($spec.Hint)"
        } elseif (-not (Test-MinVersion $r.Version $spec.Min)) {
            Write-Fail "$t $($r.Version) is older than $($spec.Min). $($spec.Hint)"
        } else {
            Write-Ok "$t $($r.Version)"
        }
    }
}

# --- 2. Azure ----------------------------------------------------------------

Write-Step 'Checking Azure sign-in'
if (Get-Command az -ErrorAction SilentlyContinue) {
    $null = & az account show -o none 2>$null
    if ($LASTEXITCODE -ne 0 -and (Confirm-Lab 'Not signed in to Azure. Run az login now?')) {
        & az login --only-show-errors -o none
    }
    $subArgs = @(); if ($SubscriptionId) { $subArgs = @('--subscription', $SubscriptionId) }
    $name = & az account show @subArgs --query name -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $name) {
        $user = & az account show @subArgs --query user.name -o tsv 2>$null
        Write-Ok "Azure: $user on '$name'"
    } elseif ($SubscriptionId) {
        Write-Fail "Subscription $SubscriptionId is not visible to the signed-in account. Run: az login --tenant <tenant-of-that-subscription>"
    } else {
        Write-Fail 'Not signed in to Azure. Run: az login'
    }
} else {
    Write-Fail 'az not found on the PowerShell PATH'
}

# --- 3. Dynatrace ------------------------------------------------------------

Read-EnvFile
$DtRequired = @('apiTokens.read', 'apiTokens.write', 'settings.read', 'settings.write')
$DtRecommended = @('metrics.read', 'entities.read', 'metrics.ingest', 'logs.ingest', 'openTelemetryTrace.ingest',
                   'InstallerDownload', 'DataExport', 'activeGateTokenManagement.create')

if ($SkipDynatrace) {
    Write-Step 'Dynatrace: skipped (-SkipDynatrace)'
    $SkipServiceNow = $true
} else {
    Write-Step 'Dynatrace'
    if (-not $NonInteractive) {
        Write-Host '  Token scopes: docs/DYNATRACE-SETUP.md. Secret input is hidden.' -ForegroundColor DarkGray
    }

    $dtUrl = Get-ValidValue -Key 'DT_ENV_URL' -Prompt 'Dynatrace environment URL (https://<env-id>.apps.dynatrace.com)' -Validate {
        param($v)
        if ($v -notmatch '^https://[A-Za-z0-9.-]+') { return 'Must start with https://' }
        $u = Resolve-DynatraceUrls $v
        $r = Invoke-LabHttp GET "$($u.Classic)/api/v2/apiTokens/lookup"
        if ($r.Code -eq 0) { return "Cannot reach $($u.Classic): $($r.Body)" }
        $null  # any HTTP answer (401/405 without a token) proves the host is real
    }

    if ($dtUrl) {
        $u = Resolve-DynatraceUrls $dtUrl
        Write-Ok "Environment: $($u.Classic) (UI $($u.Apps))"

        $dtApi = Get-ValidValue -Key 'DT_API_TOKEN' -Prompt 'Dynatrace API token (dt0c01.*)' -Secret -Validate {
            param($v)
            if ($v -match '^dt0s16\.') { return 'That is a platform token (dt0s16, asked for next). This prompt needs a classic API token (dt0c01) from the Access Tokens app; press Enter to skip it for now.' }
            if ($v -notmatch '^dt0c01\.') { return 'API tokens start with dt0c01.' }
            $body = @{ token = $v } | ConvertTo-Json -Compress
            $r = Invoke-LabHttp POST "$($u.Classic)/api/v2/apiTokens/lookup" @{ Authorization = "Api-Token $v" } $body
            if ($r.Code -ne 200) { return "Dynatrace rejected the API token (HTTP $($r.Code)). It needs at least apiTokens.read." }
            $scopes = @(($r.Body | ConvertFrom-Json).scopes)
            $missing = @($DtRequired | Where-Object { $scopes -notcontains $_ })
            if ($missing.Count) { return "API token is missing required scope(s): $($missing -join ', ')" }
            $script:DtScopes = $scopes
            $null
        }
        if ($dtApi) {
            Write-Ok 'API token accepted with the required scopes'
            $rec = @($DtRecommended | Where-Object { $script:DtScopes -notcontains $_ })
            if ($rec.Count) { Write-Warn "Recommended scope(s) missing (validate.sh checks / token creation may fail): $($rec -join ', ')" }
        }

        $mcp = "$($u.Apps)/platform-reserved/mcp-gateway/v0.1/servers/dynatrace-mcp/mcp"
        $dtPlat = Get-ValidValue -Key 'DT_PLATFORM_TOKEN' -Prompt 'Dynatrace platform token (dt0s16.*; Enter to skip, only needed with -WithAgent)' -Secret -Optional -Validate {
            param($v)
            if ($v -notmatch '^dt0s16\.') { return 'Platform tokens start with dt0s16.' }
            $init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"sre-demo-lab-setup","version":"1.0"}}}'
            $r = Invoke-LabHttp POST $mcp @{ Authorization = "Bearer $v"; Accept = 'application/json, text/event-stream' } $init
            switch ($r.Code) {
                { $_ -in 200, 202 } { return $null }
                { $_ -in 401, 403 } { return "MCP gateway rejected the platform token (HTTP $($r.Code)); it needs mcp-gateway:servers:invoke and mcp-gateway:servers:read" }
                404 { $script:McpMissing = $true; return $null }
                default { $script:McpOther = $r.Code; return $null }
            }
        }
        if ($dtPlat) {
            if ($script:McpMissing) { Write-Warn 'MCP gateway returned 404: install "Dynatrace MCP Server" from Dynatrace Hub' }
            elseif ($script:McpOther) { Write-Warn "MCP gateway returned HTTP $($script:McpOther); token saved, re-checked during deploy" }
            else { Write-Ok 'Platform token reaches the Dynatrace MCP gateway' }
        } elseif ($dtPlat -eq '') {
            Write-Warn 'Without DT_PLATFORM_TOKEN the SRE Agent cannot query Dynatrace'
        }
    }
}

# --- 4. ServiceNow -----------------------------------------------------------

if ($SkipServiceNow) {
    if (-not $SkipDynatrace) { Write-Step 'ServiceNow: skipped (-SkipServiceNow)' }
} else {
    Write-Step 'ServiceNow'
    if (-not $NonInteractive) {
        Write-Host '  Developer instances hibernate: wake yours at https://developer.servicenow.com first.' -ForegroundColor DarkGray
    }

    $snowUrl = Get-ValidValue -Key 'SNOW_INSTANCE_URL' -Prompt 'ServiceNow instance URL (https://<instance>.service-now.com)' -Validate {
        param($v)
        if ($v -notmatch '^https://[A-Za-z0-9.-]+') { return 'Must start with https://' }
        $r = Invoke-LabHttp GET "$($v.TrimEnd('/'))/api/now/table/sys_user?sysparm_limit=1"
        if ($r.Code -eq 0) { return "Cannot reach ${v}: $($r.Body)" }
        if ($r.Code -eq 200 -and -not $r.Json) { return 'The instance answered with a web page, not the API: it is probably hibernating. Wake it at developer.servicenow.com and try again.' }
        $null
    }

    if ($snowUrl) {
        $base = $snowUrl.TrimEnd('/')
        Write-Ok "Instance reachable: $base"

        $snowUser = Get-ValidValue -Key 'SNOW_ADMIN_USER' -Prompt 'ServiceNow admin user name' -Validate {
            param($v) if ($v -match '\s') { 'User names have no spaces' } else { $null }
        }
        if ($snowUser) {
            $snowPass = Get-ValidValue -Key 'SNOW_ADMIN_PASSWORD' -Prompt "Password for $snowUser" -Secret -Validate {
                param($v)
                $h = @{ Authorization = (Get-BasicAuth $snowUser $v); Accept = 'application/json' }
                $q = [uri]::EscapeDataString("user.user_name=$snowUser^role.name=admin")
                $r = Invoke-LabHttp GET "$base/api/now/table/sys_user_has_role?sysparm_query=$q&sysparm_fields=sys_id&sysparm_limit=1" $h
                switch ($r.Code) {
                    200 {
                        if (-not $r.Json) { return 'Instance returned a web page: is it hibernating?' }
                        if (@(($r.Body | ConvertFrom-Json).result).Count -eq 0) {
                            return "$snowUser signed in but does not hold the admin role; Terraform needs admin to create the integration user and grant roles"
                        }
                        return $null
                    }
                    401 { return 'ServiceNow rejected the user name or password (HTTP 401)' }
                    403 { return "$snowUser cannot read roles (HTTP 403); use an admin account" }
                    default { return "ServiceNow returned HTTP $($r.Code)" }
                }
            }
            if ($snowPass) { Write-Ok "$snowUser signed in and holds the admin role" }
        }
        $group = Get-EnvValue 'SNOW_ASSIGNMENT_GROUP'; if (-not $group) { Set-EnvValue 'SNOW_ASSIGNMENT_GROUP' 'SRE Demo Lab' }
        $iu = Get-EnvValue 'SNOW_INTEGRATION_USER'; if (-not $iu) { Set-EnvValue 'SNOW_INTEGRATION_USER' 'sre_demo_integration' }
        Save-EnvFile
        Write-Ok "Assignment group '$(Get-EnvValue 'SNOW_ASSIGNMENT_GROUP')', integration user '$(Get-EnvValue 'SNOW_INTEGRATION_USER')' (created by Terraform)"
    }
}

# --- Summary -----------------------------------------------------------------

Write-Host ''
if ($script:Failures.Count) {
    Write-Host "Setup incomplete: $($script:Failures.Count) problem(s)." -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw 'Prerequisite or credential checks failed.'
}
Write-Host "All checks passed. Credentials saved to $EnvFile (git-ignored)." -ForegroundColor Green
