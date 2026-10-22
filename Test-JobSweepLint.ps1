<#
.SYNOPSIS
    Lints the repository with PSScriptAnalyzer, exactly as CI does.

.DESCRIPTION
    Runs PSScriptAnalyzer over every script in the repository with
    PSScriptAnalyzerSettings.psd1. Errors and warnings fail (exit 1); Information
    findings are reported but do not.

    Pinned to the analyzer version the settings were tuned against, because a
    newer analyzer can add rules and fail the build with no code change. Installs
    that version for the current user if it is missing.

    Inside GitHub Actions each finding becomes an annotation on its file and
    line; anywhere else it prints file:line [rule] message.

.EXAMPLE
    .\Test-JobSweepLint.ps1
    powershell.exe -File .\Test-JobSweepLint.ps1      # Windows PowerShell 5.1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$version = '1.25.0'
$edition = "PowerShell $($PSVersionTable.PSVersion)"

if (-not (Get-Module -ListAvailable PSScriptAnalyzer | Where-Object Version -eq $version)) {
    # Windows PowerShell 5.1 needs TLS 1.2 and the NuGet provider for the Gallery.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module PSScriptAnalyzer -RequiredVersion $version -Scope CurrentUser -Force
}
Import-Module PSScriptAnalyzer -RequiredVersion $version

$settings = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
$findings = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -Settings $settings)
$inActions = $env:GITHUB_ACTIONS -eq 'true'

Push-Location $PSScriptRoot
try {
    foreach ($f in $findings) {
        # repo-relative with forward slashes, so GitHub links the annotation to the file
        $file = (Resolve-Path -Relative $f.ScriptPath) -replace '^\.[\\/]', '' -replace '\\', '/'
        if ($inActions) {
            $level = if ("$($f.Severity)" -eq 'Information') { 'notice' } else { 'error' }
            Write-Output "::$level file=$file,line=$($f.Line)::[$($f.RuleName)] $($f.Message)"
        } else {
            Write-Output "$($file):$($f.Line) [$($f.Severity)] [$($f.RuleName)] $($f.Message)"
        }
    }
} finally { Pop-Location }

$blocking = @($findings | Where-Object { "$($_.Severity)" -in 'Error', 'Warning', 'ParseError' })
Write-Output "PSScriptAnalyzer $version on ${edition}: $($findings.Count) finding(s), $($blocking.Count) blocking."
if ($blocking.Count -gt 0) { exit 1 }
