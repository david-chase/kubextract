param(
	[string]$instance,
	[string]$user,
	[string]$pass,
	[string]$outpath,
	[string]$beep
)

#-----------------------------------------------------------------------------------------------
#  kubexport 
#  PowerShell script to query a customer instance and export relevant information as a CSV 
#-----------------------------------------------------------------------------------------------

function Get-IniSection {
	param(
		[Parameter(Mandatory=$true)][string]$Path,
		[Parameter(Mandatory=$true)][string]$Section
	)

	if (-not (Test-Path -Path $Path)) {
		return @{}
	}

	# Read file as lines so we can process section headers and key/value lines reliably
	$lines = Get-Content -Path $Path -ErrorAction SilentlyContinue -Encoding UTF8

	$inSection = $false
	$result = @{}
	$freeLines = @()

	foreach ($line in $lines) {
		$trim = $line.Trim()
		if ($trim -match '^[\s]*\[.*\][\s]*$') {
			if ($trim -ieq "[$Section]") {
				$inSection = $true
				continue
			} elseif ($inSection) {
				break
			}
		}

		if ($inSection) {
			if ($trim -eq '' -or $trim.StartsWith(';') -or $trim.StartsWith('#')) { continue }
			if ($trim -match '^[\s]*([^=]+?)[\s]*=[\s]*(.*)$') {
				$key = $matches[1].Trim()
				$rawValue = $matches[2].Trim()
				# Strip surrounding single or double quotes if present
				if (($rawValue.StartsWith('"') -and $rawValue.EndsWith('"')) -or ($rawValue.StartsWith("'") -and $rawValue.EndsWith("'"))) {
					$value = $rawValue.Substring(1, $rawValue.Length - 2)
				} else {
					$value = $rawValue
				}
				$result[$key] = $value
			} else {
				# If the line contains no '=' and is not a comment/blank, treat it as a free-form line (e.g., one field name per line)
				$freeLines += $trim
			}
		}
	}

	if ($freeLines.Count -gt 0) { $result['__lines'] = $freeLines }

	return $result
}

# CSV helper: escape a value for CSV
function Escape-CsvValue {
	param([object]$Value)
	if ($null -eq $Value) { return '' }
	$string = [string]$Value
	if ($string -match '[",\n\r]') {
		return '"' + ($string -replace '"','""') + '"'
	}
	return $string
}

#-----------------------------------------------------------------------------------------------
# Begin main program
#-----------------------------------------------------------------------------------------------
Write-Host 
Write-Host ::: Kubexport ::: -ForegroundColor Cyan
Write-Host 

# Locate kubextract.ini next to this script
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$iniPath = Join-Path $scriptDir 'kubextract.ini'

$iniParams = Get-IniSection -Path $iniPath -Section 'Parameters'

# Environment variable name is 'kubex' + parameter name
$envVarName = 'kubexinstance'
# Use .NET API to read env var by dynamic name (works cross-platform)
$envValue = [Environment]::GetEnvironmentVariable($envVarName)

# user parameter env var
$envVarNameUser = 'kubexuser'
$envValueUser = [Environment]::GetEnvironmentVariable($envVarNameUser)

# pass parameter env var
$envVarNamePass = 'kubexpass'
$envValuePass = [Environment]::GetEnvironmentVariable($envVarNamePass)

# outpath parameter env var
$envVarNameOutPath = 'kubexoutpath'
$envValueOutPath = [Environment]::GetEnvironmentVariable($envVarNameOutPath)

# beep parameter env var
$envVarNameBeep = 'kubexbeep'
$envValueBeep = [Environment]::GetEnvironmentVariable($envVarNameBeep)

# Precedence: CLI -> INI -> ENV
if ($PSBoundParameters.ContainsKey('instance') -and $instance -ne $null -and $instance -ne '') {
	$Instance = $instance
	$source = 'cli'
} elseif ($iniParams.ContainsKey('instance') -and $iniParams['instance'] -ne '') {
	$Instance = $iniParams['instance']
	$source = 'ini'
} elseif ($envValue -ne $null -and $envValue -ne '') {
	$Instance = $envValue
	$source = 'env'
} else {
	$Instance = $null
	$source = 'none'
}

# Resolve user with same precedence: CLI -> INI -> ENV
if ($PSBoundParameters.ContainsKey('user') -and $user -ne $null -and $user -ne '') {
	$User = $user
	$userSource = 'cli'
} elseif ($iniParams.ContainsKey('user') -and $iniParams['user'] -ne '') {
	$User = $iniParams['user']
	$userSource = 'ini'
} elseif ($envValueUser -ne $null -and $envValueUser -ne '') {
	$User = $envValueUser
	$userSource = 'env'
} else {
	$User = $null
	$userSource = 'none'
}

 # Resolve pass with same precedence: CLI -> INI -> ENV
if ($PSBoundParameters.ContainsKey('pass') -and $pass -ne $null -and $pass -ne '') {
	$Pass = $pass
	$passSource = 'cli'
} elseif ($iniParams.ContainsKey('pass') -and $iniParams['pass'] -ne '') {
	$Pass = $iniParams['pass']
	$passSource = 'ini'
} elseif ($envValuePass -ne $null -and $envValuePass -ne '') {
	$Pass = $envValuePass
	$passSource = 'env'
} else {
	$Pass = $null
	$passSource = 'none'
}

# Resolve outpath with precedence: CLI -> INI -> ENV
if ($PSBoundParameters.ContainsKey('outpath') -and $outpath -ne $null -and $outpath -ne '') {
	$OutPath = $outpath
	$outPathSource = 'cli'
} elseif ($iniParams.ContainsKey('outpath') -and $iniParams['outpath'] -ne '') {
	$OutPath = $iniParams['outpath']
	$outPathSource = 'ini'
} elseif ($envValueOutPath -ne $null -and $envValueOutPath -ne '') {
	$OutPath = $envValueOutPath
	$outPathSource = 'env'
} else {
	$OutPath = $null
	$outPathSource = 'none'
}

# Resolve beep with precedence: CLI -> INI -> ENV (normalize to boolean)
$Beep = $false
$beepSource = 'none'
function To-Bool([string]$v) {
	if ($null -eq $v) { return $null }
	switch ($v.Trim().ToLower()) {
		'true' { return $true }
		'false' { return $false }
		'1' { return $true }
		'0' { return $false }
		default { return $null }
	}
}

$cliBeep = $null
if ($PSBoundParameters.ContainsKey('beep') -and $beep -ne $null -and $beep -ne '') { $cliBeep = To-Bool $beep }
$iniBeep = $null
if ($iniParams.ContainsKey('beep') -and $iniParams['beep'] -ne '') { $iniBeep = To-Bool $iniParams['beep'] }
$envBeep = $null
if ($envValueBeep -ne $null -and $envValueBeep -ne '') { $envBeep = To-Bool $envValueBeep }

if ($cliBeep -ne $null) { $Beep = $cliBeep; $beepSource = 'cli' }
elseif ($iniBeep -ne $null) { $Beep = $iniBeep; $beepSource = 'ini' }
elseif ($envBeep -ne $null) { $Beep = $envBeep; $beepSource = 'env' }

# Read Settings section (Protocol, BaseUrl, BaseApi)
$settings = Get-IniSection -Path $iniPath -Section 'Settings'

function Trim-Quotes {
	param([string]$s)
	if ($null -eq $s) { return $null }
	$t = $s.Trim()
	if (($t.StartsWith('"') -and $t.EndsWith('"')) -or ($t.StartsWith("'") -and $t.EndsWith("'"))) {
		return $t.Substring(1, $t.Length - 2)
	}
	return $t
}

$protocol = Trim-Quotes $settings['Protocol']
$baseUrl  = Trim-Quotes $settings['BaseUrl']
$baseApi  = Trim-Quotes $settings['BaseApi']
$baseQL   = Trim-Quotes $settings['BaseQL']

# Ensure BaseApi starts with a '/'
if ($baseApi -ne $null -and -not $baseApi.StartsWith('/')) {
	$baseApi = '/' + $baseApi
}

# Ensure BaseQL starts with a '/'
if ($baseQL -ne $null -and -not $baseQL.StartsWith('/')) {
    $baseQL = '/' + $baseQL
}

# Build endpoint as Protocol + instance + "." + BaseUrl + BaseApi
$endpoint = ""
if ($protocol -and $Instance -and $baseUrl -and $baseApi) {
	$endpoint = "$protocol$Instance.$baseUrl$baseApi"
}

# Construct GraphQL base URL: Protocol + instance + "." + BaseUrl + BaseQL
$graphqlEndpoint = ""
if ($protocol -and $Instance -and $baseUrl -and $baseQL) {
    $graphqlEndpoint = "$protocol$Instance.$baseUrl$baseQL"
}

# Function: Get an auth token by POSTing credentials to endpoint/authorize
function Get-AuthToken {
	param(
		[Parameter(Mandatory=$true)][string]$Endpoint,
		[Parameter(Mandatory=$true)][string]$User,
		[Parameter(Mandatory=$true)][string]$Pass
	)

	# Ensure single slash before 'authorize'
	$authUrl = $Endpoint.TrimEnd('/') + '/authorize'
	$hHeaders = @{ "Accept" = "application/json"; "Content-Type" = "application/json" }
	$hBody = @{ userName = $User; pwd = $Pass }

	try {
		$response = Invoke-RestMethod -Method Post -Uri $authUrl -Headers $hHeaders -Body ( $hBody | ConvertTo-Json ) -ErrorAction Stop
		return $response
	} catch {
		return $null
	}
}

# Request an auth token and store the response in $AuthToken
$AuthToken = $null
if ($endpoint) {
	$AuthToken = Get-AuthToken -Endpoint $endpoint -User $User -Pass $Pass
}

# Check and extract token value
$tokenValue = $null
if ($AuthToken -ne $null) {
	if ($AuthToken.PSObject.Properties.Name -contains 'apiToken') {
		$tokenValue = $AuthToken.apiToken
	} elseif ($AuthToken.PSObject.Properties.Name -contains 'token') {
		$tokenValue = $AuthToken.token
	} elseif ($AuthToken -is [string]) {
		$tokenValue = $AuthToken
	}
}

if (-not $tokenValue) {
	Write-Output 'Authorization failed or token not found'
	exit 1
} else {
	Write-Output 'Authorization token obtained'
}


# Read Queries section (list of query names) and execute each query via per-query sections
$queries = Get-IniSection -Path $iniPath -Section 'Queries'
$queryNames = @()
if ($queries.ContainsKey('__lines')) {
	$queryNames = $queries['__lines'] | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
} else {
	$queryNames = $queries.Keys
}

foreach ($qKey in $queryNames) {
	$queryNameSection = $qKey
	$qcfg = Get-IniSection -Path $iniPath -Section $queryNameSection

	$endPointName = $qcfg['EndPoint']
	$gqlField = $qcfg['GraphQLQuery']
	$viewId = $qcfg['viewId']
	$filterId = $qcfg['filterId']
	$treeviewPath = $qcfg['treeviewPath']

	if (-not $endPointName -or -not $gqlField) {
		Write-Output "Skipping query '$queryNameSection' - missing EndPoint or GraphQLQuery"
		continue
	}

	# Build request URL: graphqlEndpoint + endpointName
	$requestUrl = $graphqlEndpoint.TrimEnd('/') + '/' + $endPointName.TrimStart('/')

	# Build args text (only include non-empty values)
	$argParts = @()
	if ($viewId) { $argParts += "viewId: `"$viewId`"" }
	if ($filterId) { $argParts += "filterId: `"$filterId`"" }
	if ($treeviewPath) { $argParts += "treeviewPath: `"$treeviewPath`"" }
	if ($argParts.Count -gt 0) {
		$argsText = "( " + ($argParts -join ', ') + " )"
	} else {
		$argsText = ''
	}

	# Determine selection set: if the query section contains free-form lines (under __lines), treat them as field names (one per line)
	$selection = "{ entityId }"
	if ($qcfg.ContainsKey('__lines')) {
		$lines = $qcfg['__lines'] | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
		if ($lines.Count -gt 0) {
			$selBody = $lines -join "`n    "
			$selection = "{`n    $selBody`n}"
		}
	}

	# Build GraphQL operation using selection
	$gql = "query $queryNameSection { $gqlField$argsText $selection }"

	$bodyObj = @{ query = $gql }

	$hHeaders = @{ 'Content-Type' = 'application/json'; 'Authorization' = "Bearer $tokenValue" }

	try {
		$resp = Invoke-RestMethod -Method Post -Uri $requestUrl -Headers $hHeaders -Body ( $bodyObj | ConvertTo-Json -Depth 10 ) -ErrorAction Stop
		Write-Output "Query '$queryNameSection' -> $requestUrl : OK"

		# Write results to CSV if OutPath is provided
		if ($OutPath) {
			if (-not (Test-Path -Path $OutPath)) {
				try { New-Item -ItemType Directory -Path $OutPath -Force | Out-Null } catch {}
			}

			$fields = @('entityId')
			if ($qcfg.ContainsKey('__lines')) {
				$lines = $qcfg['__lines'] | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
				if ($lines.Count -gt 0) { $fields = $lines }
			}

			# Extract records from response
			$dataRoot = $null
			if ($resp -and $resp.data) {
				$dataRoot = $resp.data | Select-Object -ExpandProperty $gqlField -ErrorAction SilentlyContinue
			}
			if ($null -eq $dataRoot) {
				Write-Output "Query '$queryNameSection' : no data returned"
			} else {
				$records = $dataRoot
				if (-not ($records -is [System.Collections.IEnumerable]) -or ($records -is [string])) {
					$records = @($records)
				}

				$linesOut = @()
				$linesOut += ($fields | ForEach-Object { $_ }) -join ','
				foreach ($rec in $records) {
					$row = @()
					foreach ($f in $fields) {
						$val = $null
						if ($rec -is [psobject] -and $rec.PSObject.Properties.Name -contains $f) {
							$val = $rec.$f
						}
						$row += (Escape-CsvValue $val)
					}
					$linesOut += ($row -join ',')
				}

				$today = Get-Date -Format 'yyyy-MM-dd'
				$fname = "$today $Instance $queryNameSection.csv"
				$outFile = Join-Path $OutPath $fname
				$linesOut | Set-Content -Path $outFile -Encoding UTF8
				Write-Output "Query '$queryNameSection' -> wrote $(($records.Count)) rows to $outFile"
			}
		}
	} catch {
		Write-Output "Query '$queryNameSection' -> $requestUrl : FAILED - $($_.Exception.Message)"
	}
}

# Optional beep before exit (cross-platform: bell character works on Linux/Windows)
if ($Beep) {
	Write-Host $([char]7) -NoNewline
}

exit 0

