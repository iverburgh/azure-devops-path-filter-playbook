#Requires -Version 7.2
<#
.SYNOPSIS
    Fails when the YAML trigger or the branch policy path filter of one pipeline does not match the
    projects it depends on.

.DESCRIPTION
    Reports, per filter:
      [MISSING]      a project folder or required path in scope that the filter does not include
      [SUPERFLUOUS]  a filter entry that matches nothing the pipeline depends on

    Run it as a step in the pipeline it validates. It reads the pipeline's YAML file from the
    working copy and its build validation policy from Azure DevOps, using the job access token.

    Locally, without an access token, only the YAML trigger is checked:

        ./Test-PathFilters.ps1 -ProjectFile src/Orders/Api/Orders.Api.csproj -PipelineFile pipelines/orders-api.yml

.PARAMETER ProjectFile
    The project the pipeline builds and deploys, relative to the working directory.

.PARAMETER PipelineFile
    The pipeline's YAML file. Optional with -BuildDefinitionId: it is then read from the definition.

.PARAMETER BuildDefinitionId
    The pipeline's definition ID, normally $(System.DefinitionId). Needed for the branch policy check.

.PARAMETER PolicyBranch
    The branch whose policies to check. Defaults to the pull request target branch, then the branch
    being built.

.PARAMETER AllowSuperfluous
    Report superfluous entries as warnings instead of failing.

.PARAMETER SkipBranchPolicy
    Check only the YAML trigger.

.EXAMPLE
    ./Test-PathFilters.ps1 -ProjectFile src/Orders/Api/Orders.Api.csproj -BuildDefinitionId 42 -PolicyBranch refs/heads/main
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProjectFile,

    [string] $PipelineFile,

    [string] $BuildDefinitionId,

    [string] $PolicyBranch,

    [string] $WorkingDirectory,

    [string] $CollectionUri = $env:SYSTEM_COLLECTIONURI,

    [string] $Project = $env:SYSTEM_TEAMPROJECT,

    [string] $RepositoryId = $env:BUILD_REPOSITORY_ID,

    [string] $AccessToken = $env:SYSTEM_ACCESSTOKEN,

    [string] $ConfigPath = (Join-Path $PSScriptRoot 'path-filters.json'),

    [switch] $AllowSuperfluous,

    [switch] $SkipBranchPolicy
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/PathFilterGuard.ps1"

if (-not $WorkingDirectory) {
    $WorkingDirectory = $env:BUILD_SOURCESDIRECTORY
    if (-not $WorkingDirectory) { $WorkingDirectory = (& git rev-parse --show-toplevel 2>$null) }
    if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).Path }
}
$WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
$config = Get-PathFilterConfig -ConfigPath $ConfigPath

$checkPolicy = -not $SkipBranchPolicy
if ($checkPolicy -and -not $AccessToken) {
    if ($env:TF_BUILD) {
        throw 'No access token. Map it into the step: env: SYSTEM_ACCESSTOKEN: $(System.AccessToken). Or pass -SkipBranchPolicy.'
    }
    Write-Warning 'No access token: only the YAML trigger is checked. Pass -AccessToken (az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798) to check the branch policy too.'
    $checkPolicy = $false
}

$policy = @()
$branch = $null
if ($checkPolicy) {
    if (-not $BuildDefinitionId) { throw '-BuildDefinitionId is required to check the branch policy. Pass $(System.DefinitionId), or -SkipBranchPolicy.' }
    if (-not $CollectionUri -or -not $Project) { throw '-CollectionUri and -Project are required outside a pipeline run.' }

    $connection = New-AzDoConnection -CollectionUri $CollectionUri -Project $Project -AccessToken $AccessToken
    $definition = Get-AzDoBuildDefinition -Connection $connection -Id $BuildDefinitionId
    $definitionYaml = ConvertTo-FilterPath "$(Get-PropertyValue $definition 'process.yamlFilename')"
    if (-not $RepositoryId) { $RepositoryId = Get-PropertyValue $definition 'repository.id' }

    if (-not $PipelineFile) {
        $PipelineFile = $definitionYaml
    }
    elseif ($definitionYaml -and (ConvertTo-FilterPath $PipelineFile) -ne $definitionYaml) {
        Write-Warning "-PipelineFile '$PipelineFile' differs from the definition's YAML file '$definitionYaml'; using the definition's."
        $PipelineFile = $definitionYaml
    }

    $branch = Resolve-PolicyBranch $PolicyBranch
    if (-not $branch) { throw 'Cannot determine the branch whose policies to check. Pass -PolicyBranch.' }
    $policy = @(Get-BuildValidationPolicy -Connection $connection -RepositoryId $RepositoryId -Branch $branch |
            Where-Object { "$(Get-PropertyValue $_ 'settings.buildDefinitionId')" -eq "$BuildDefinitionId" })
}

if (-not $PipelineFile) { throw 'Pass -PipelineFile, or -BuildDefinitionId with an access token.' }

$result = Invoke-PathFilterValidation -Project $ProjectFile -PipelineFile $PipelineFile -Root $WorkingDirectory -Config $config `
    -CheckBranchPolicy:$checkPolicy -Policy $policy -PolicyBranch $branch

$failed = Write-PathFilterValidation -Result $result -AllowSuperfluous:$AllowSuperfluous
if (-not $checkPolicy) { Write-Host ''; Write-Host '  Note: the branch policy path filter was not checked.' }

Write-Host ''
if ($failed) {
    Write-Host 'Result: FAILED. Copy the filters above, or add and remove the listed entries, then rerun.'
    Write-PipelineIssue -Type error -Message "Path filters of $($result.Pipeline) do not match its dependencies."
    exit 1
}
Write-Host 'Result: path filters match the dependencies.'
