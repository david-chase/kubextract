param(
	[string]$instance,
	[string]$user,
	[string]$pass
)

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
			}
		}
	}

	return $result
}

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

# Ensure BaseApi starts with a '/'
if ($baseApi -ne $null -and -not $baseApi.StartsWith('/')) {
	$baseApi = '/' + $baseApi
}

# Build endpoint as Protocol + instance + "." + BaseUrl + BaseApi
$endpoint = ""
if ($protocol -and $Instance -and $baseUrl -and $baseApi) {
	$endpoint = "$protocol$Instance.$baseUrl$baseApi"
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

    write-host $authUrl

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

# Print the auth token (prefer the apiToken field if present)
if ($AuthToken -ne $null) {
	if ($AuthToken.PSObject.Properties.Name -contains 'apiToken') {
		Write-Output $AuthToken.apiToken
	} else {
		Write-Output $AuthToken
	}
} else {
	Write-Output ''
}

exit 0

