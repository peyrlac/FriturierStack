[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^[A-Z][A-Z0-9_]*$')]
    [string] $Variable,

    [ValidateSet('api', 'bot', 'both')]
    [string] $Service = 'both',

    [string] $ComposePath,

    [string] $DefaultValue,

    [switch] $Required
)

if ([string]::IsNullOrWhiteSpace($ComposePath)) {
    $scriptDirectory = Split-Path -Parent $PSCommandPath
    $ComposePath = Join-Path $scriptDirectory '..\docker-compose.yml'
}

$composeFile = [IO.Path]::GetFullPath($ComposePath)
if (-not (Test-Path -LiteralPath $composeFile -PathType Leaf)) {
    throw "Docker Compose file not found: $composeFile"
}

$content = Get-Content -LiteralPath $composeFile -Raw
$services = switch ($Service) {
    'api'  { @('friturier-api') }
    'bot'  { @('friturier-bot') }
    'both' { @('friturier-api', 'friturier-bot') }
}

$reference = if ($Required) {
    '${' + $Variable + '}'
} elseif ($PSBoundParameters.ContainsKey('DefaultValue')) {
    '${' + $Variable + ':-' + $DefaultValue + '}'
} else {
    '${' + $Variable + ':-}'
}

$updated = $content
foreach ($serviceName in $services) {
    $serviceMatch = [regex]::Match(
        $updated,
        '(?ms)^  ' + [regex]::Escape($serviceName) + ':\r?\n.*?(?=^  [A-Za-z0-9_-]+:|\z)'
    )
    if (-not $serviceMatch.Success) {
        throw "Service not found in ${composeFile}: $serviceName"
    }

    $serviceText = $serviceMatch.Value
    if ([regex]::IsMatch($serviceText, '(?m)^      ' + [regex]::Escape($Variable) + ':')) {
        Write-Verbose "$Variable already exists in $serviceName; skipping."
        continue
    }

    $environmentMatch = [regex]::Match(
        $serviceText,
        '(?ms)^    environment:\r?\n.*?(?=^    [A-Za-z0-9_-]+:|\z)'
    )
    if (-not $environmentMatch.Success) {
        throw "Environment block not found in service $serviceName."
    }

    $environmentText = $environmentMatch.Value.TrimEnd("`r", "`n")
    $lineEnding = if ($environmentText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $newEnvironmentText = $environmentText + $lineEnding + '      ' + $Variable + ': ' + $reference + $lineEnding
    $updatedServiceText = $serviceText.Substring(0, $environmentMatch.Index) +
        $newEnvironmentText + $serviceText.Substring($environmentMatch.Index + $environmentMatch.Length)
    $updated = $updated.Substring(0, $serviceMatch.Index) +
        $updatedServiceText + $updated.Substring($serviceMatch.Index + $serviceMatch.Length)
}

if ($updated -eq $content) {
    Write-Output 'No changes needed.'
    exit 0
}

if ($PSCmdlet.ShouldProcess($composeFile, "Add $Variable to $Service environment")) {
    [IO.File]::WriteAllText($composeFile, $updated, [Text.UTF8Encoding]::new($false))
    Write-Output "Added $Variable to $Service in $composeFile"
}
