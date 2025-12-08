# Temporary introspection runner for kubextract
# Reads kubextract.ini next to this script, authenticates, and introspects the schema

function Get-IniSection {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Section
    )

    if (-not (Test-Path -Path $Path)) { return @{} }
    $lines = Get-Content -Path $Path -ErrorAction SilentlyContinue -Encoding UTF8
    $inSection = $false
    $result = @{}
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim -match '^[\s]*\[.*\][\s]*$') {
            if ($trim -ieq "[$Section]") { $inSection = $true; continue } elseif ($inSection) { break }
        }
        if ($inSection) {
            if ($trim -eq '' -or $trim.StartsWith(';') -or $trim.StartsWith('#')) { continue }
            if ($trim -match '^[\s]*([^=]+?)[\s]*=[\s]*(.*)$') {
                $key = $matches[1].Trim()
                $rawValue = $matches[2].Trim()
                if (($rawValue.StartsWith('"') -and $rawValue.EndsWith('"')) -or ($rawValue.StartsWith("'") -and $rawValue.EndsWith("'"))) {
                    $value = $rawValue.Substring(1, $rawValue.Length - 2)
                } else { $value = $rawValue }
                $result[$key] = $value
            }
        }
    }
    return $result
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$iniPath = Join-Path $scriptDir 'kubextract.ini'
if (-not (Test-Path $iniPath)) { Write-Error "INI file not found at $iniPath"; exit 2 }

$settings = Get-IniSection -Path $iniPath -Section 'Settings'
$params = Get-IniSection -Path $iniPath -Section 'Parameters'
$queries = Get-IniSection -Path $iniPath -Section 'Queries'

function TrimQuotes([string]$s) { if ($null -eq $s) { return $null }; $t = $s.Trim(); if (($t.StartsWith('"') -and $t.EndsWith('"')) -or ($t.StartsWith("'") -and $t.EndsWith("'"))) { return $t.Substring(1, $t.Length - 2) }; return $t }

$protocol = TrimQuotes $settings['Protocol']
$baseUrl  = TrimQuotes $settings['BaseUrl']
$baseApi  = TrimQuotes $settings['BaseApi']
$baseQL   = TrimQuotes $settings['BaseQL']

if ($baseApi -and -not $baseApi.StartsWith('/')) { $baseApi = '/' + $baseApi }
if ($baseQL -and -not $baseQL.StartsWith('/')) { $baseQL = '/' + $baseQL }

$instance = $params['instance']
$user = $params['user']
$pass = $params['pass']

# Fallback to environment variables if credentials not present in ini
if (-not $user -or $user -eq '') { $user = [Environment]::GetEnvironmentVariable('kubexuser') }
if (-not $pass -or $pass -eq '') { $pass = [Environment]::GetEnvironmentVariable('kubexpass') }

$endpoint = "$protocol$instance.$baseUrl$baseApi"
$authUrl = $endpoint.TrimEnd('/') + '/authorize'
$graphqlBase = "$protocol$instance.$baseUrl$baseQL".TrimEnd('/')

Write-Host "Using endpoint: $endpoint"
Write-Host "GraphQL base: $graphqlBase"

if (-not $user -or -not $pass) { Write-Error "Missing user/pass in Parameters; please provide credentials in ini or env."; exit 3 }

$hHeaders = @{ 'Accept' = 'application/json'; 'Content-Type' = 'application/json' }
$hBody = @{ userName = $user; pwd = $pass } | ConvertTo-Json
try {
    $authResp = Invoke-RestMethod -Method Post -Uri $authUrl -Headers $hHeaders -Body $hBody -ErrorAction Stop
} catch {
    Write-Error "Auth request failed: $($_.Exception.Message)"; exit 4
}

$token = $null
if ($authResp) {
    if ($authResp.PSObject.Properties.Name -contains 'apiToken') { $token = $authResp.apiToken }
    elseif ($authResp.PSObject.Properties.Name -contains 'token') { $token = $authResp.token }
    elseif ($authResp -is [string]) { $token = $authResp }
}
if (-not $token) { Write-Error "Token not found in auth response"; exit 5 }

# pick first query in [Queries]
if ($queries.Keys.Count -eq 0) { Write-Error "No queries found in ini"; exit 6 }
$firstKey = $queries.Keys | Select-Object -First 1
$raw = $queries[$firstKey]
$parts = $raw -split ',' | ForEach-Object { $_.Trim() }
if ($parts.Count -lt 2) { Write-Error "Invalid query format"; exit 7 }
$endPointName = $parts[0]
$queryName = $parts[1]

# Introspection query: request types/fields info
$introspect = @"
query IntrospectFull {
  __schema {
    queryType { name }
    types {
      name
      kind
      fields {
        name
        type { kind name ofType { kind name ofType { kind name } } }
      }
      enumValues { name }
    }
  }
}
"@

$gqlHeaders = @{ 'Content-Type' = 'application/json'; 'Authorization' = "Bearer $token" }
try {
    $r = Invoke-RestMethod -Method Post -Uri $graphqlBase -Headers $gqlHeaders -Body ( @{ query = $introspect } | ConvertTo-Json -Depth 10 ) -ErrorAction Stop
} catch {
    Write-Error "Introspection request failed: $($_.Exception.Message)"; exit 8
}

if (-not ($r -and $r.data -and $r.data.__schema)) { Write-Error "Unexpected introspection response"; exit 9 }
$schema = $r.data.__schema
$typesByName = @{}
foreach ($t in $schema.types) { $typesByName[$t.name] = $t }

# Find query field and its return type
$qTypeName = $schema.queryType.name
if (-not $typesByName.ContainsKey($qTypeName)) { Write-Error "Query type $qTypeName not found"; exit 10 }
$qType = $typesByName[$qTypeName]
$field = $qType.fields | Where-Object { $_.name -eq $queryName } | Select-Object -First 1
if (-not $field) { Write-Error "Field $queryName not found on Query type"; exit 11 }

function Unwrap($type) {
    $t = $type
    while ($t -and -not $t.name) { $t = $t.ofType }
    return $t
}

$inner = Unwrap $field.type
if (-not $inner -or -not $inner.name) { Write-Error "Could not determine return type"; exit 12 }

$innerName = $inner.name
Write-Host "Field $queryName returns type: $innerName"
if (-not $typesByName.ContainsKey($innerName)) { Write-Error "Type $innerName not in schema types"; exit 13 }
$innerDef = $typesByName[$innerName]

# Collect scalar/enum fields on innerDef
$scalarFields = @()
if ($innerDef.fields) {
    foreach ($f in $innerDef.fields) {
        $fi = Unwrap $f.type
        if ($fi -and ($fi.kind -eq 'SCALAR' -or $fi.kind -eq 'ENUM')) {
            $scalarFields += @{ field = $f.name; type = $fi.name }
        }
    }
}

Write-Host "Scalar/Enum fields on ${innerName}:"
if ($scalarFields.Count -eq 0) { Write-Host " (none found)" } else { foreach ($s in $scalarFields) { Write-Host " - $($s.field) : $($s.type)" } }

# Done
exit 0
