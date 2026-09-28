#Requires -Version 7.2
<#
.SYNOPSIS
    Validates the path filters of every .NET pipeline in the repository and fails when any YAML
    trigger or branch policy path filter does not match the current project references.

.DESCRIPTION
    A pipeline's own validation step only runs when its filters trigger it. A change elsewhere —
    a test project that starts referencing a project, a moved folder, a removed reference — can make
    its filters wrong without triggering it. Run this script in a separate pipeline, attached as
    build validation on every change to a project file, to catch that.

    Pipelines are taken from path-filters.json ('pipelines'), or discovered: every YAML file that
    passes a .csproj through the configured project parameter (default 'projectFile').

    Azure DevOps is read twice in total: the list of build definitions and the branch's build
    validation policies. Project references are resolved once and shared between pipelines.

.PARAMETER PolicyBranch
    The branch whose policies to check. Defaults to the pull request target branch, then the branch
    being built.

.PARAMETER AllowSuperfluous
    Report superfluous entries as warnings instead of failing.

.PARAMETER SkipBranchPolicy
    Check only the YAML triggers.

.PARAMETER ThrottleLimit
    How many 'dotnet list reference' calls run in parallel. Defaults to the number of processors;
    1 disables parallelism.

.EXAMPLE
    ./Test-AllPathFilters.ps1 -SkipBranchPolicy

.EXAMPLE
    $env:SYSTEM_ACCESSTOKEN = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
    ./Test-AllPathFilters.ps1 -CollectionUri https://dev.azure.com/<org>/ -Project <project> -RepositoryId <repository> -PolicyBranch refs/heads/main
#>
[CmdletBinding()]
param(
    [string] $PolicyBranch,

    [string] $WorkingDirectory,

    [string] $CollectionUri = $env:SYSTEM_COLLECTIONURI,

    [string] $Project = $env:SYSTEM_TEAMPROJECT,

    [string] $RepositoryId = $env:BUILD_REPOSITORY_ID,

    [string] $AccessToken = $env:SYSTEM_ACCESSTOKEN,

    [string] $ConfigPath = (Join-Path $PSScriptRoot 'path-filters.json'),

    [switch] $AllowSuperfluous,

    [switch] $SkipBranchPolicy,

    [int] $ThrottleLimit = [Environment]::ProcessorCount
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
    Write-Warning 'No access token: only YAML triggers are checked.'
    $checkPolicy = $false
}

$pipelines = @(Find-AppPipeline -Root $WorkingDirectory -Config $config)
if ($pipelines.Count -eq 0) {
    throw "No pipelines found. Add them to 'pipelines' in $ConfigPath, or check 'projectParameter' ('$($config.projectParameter)')."
}

$definitions = @{}
$policies = @()
$branch = $null
if ($checkPolicy) {
    if (-not $CollectionUri -or -not $Project -or -not $RepositoryId) {
        throw '-CollectionUri, -Project and -RepositoryId are required outside a pipeline run.'
    }
    $branch = Resolve-PolicyBranch $PolicyBranch
    if (-not $branch) { throw 'Cannot determine the branch whose policies to check. Pass -PolicyBranch.' }

    $connection = New-AzDoConnection -CollectionUri $CollectionUri -Project $Project -AccessToken $AccessToken
    $definitions = Get-AzDoYamlDefinitionMap -Connection $connection -RepositoryId $RepositoryId
    $policies = @(Get-BuildValidationPolicy -Connection $connection -RepositoryId $RepositoryId -Branch $branch)
    Write-Host "Read $($definitions.Count) YAML build definition(s) and $($policies.Count) enabled build validation policies on $branch."
}

$testProjects = @(Get-TestProject -Root $WorkingDirectory -Config $config)
$resolved = Initialize-ReferenceCache -Root $WorkingDirectory -ThrottleLimit $ThrottleLimit
Write-Host "Resolved the references of $resolved project(s)."
Write-Host "Validating $($pipelines.Count) pipeline(s); $($testProjects.Count) test project(s) considered."

$summary = [Collections.Generic.List[object]]::new()
foreach ($pipeline in $pipelines) {
    $pipelinePolicy = @()
    $checkThisPolicy = $checkPolicy
    if ($checkPolicy) {
        $definitionId = $definitions[$pipeline.Yaml.ToLowerInvariant()]
        if (-not $definitionId) {
            Write-Warning "$($pipeline.Yaml) has no build definition in Azure DevOps; only its YAML trigger is checked."
            Write-PipelineIssue -Type warning -Message "$($pipeline.Yaml) has no build definition; its branch policy is not checked."
            $checkThisPolicy = $false
        }
        else {
            $pipelinePolicy = @($policies | Where-Object { "$(Get-PropertyValue $_ 'settings.buildDefinitionId')" -eq $definitionId })
        }
    }

    try {
        $result = Invoke-PathFilterValidation -Project $pipeline.Project -PipelineFile $pipeline.Yaml -Root $WorkingDirectory -Config $config `
            -TestProjects $testProjects -CheckBranchPolicy:$checkThisPolicy -Policy $pipelinePolicy -PolicyBranch $branch
        $failed = Write-PathFilterValidation -Result $result -AllowSuperfluous:$AllowSuperfluous
        $summary.Add([pscustomobject]@{
                Pipeline    = $pipeline.Yaml
                Failed      = $failed
                Missing     = @($result.Findings | Where-Object Type -EQ 'Missing').Count
                Superfluous = @($result.Findings | Where-Object Type -EQ 'Superfluous').Count
            })
    }
    catch {
        Write-Host ''
        Write-Host "Path filters of $($pipeline.Yaml)"
        Write-Host "  [ERROR] $($_.Exception.Message)"
        Write-PipelineIssue -Type error -Message "$($pipeline.Yaml): $($_.Exception.Message)"
        $summary.Add([pscustomobject]@{ Pipeline = $pipeline.Yaml; Failed = $true; Missing = 0; Superfluous = 0 })
    }
}

$width = ($summary | ForEach-Object { $_.Pipeline.Length } | Measure-Object -Maximum).Maximum
Write-Host ''
Write-Host 'Summary'
foreach ($row in $summary) {
    $status = if ($row.Failed) { '[FAIL]' } else { '[PASS]' }
    $counts = if ($row.Missing -or $row.Superfluous) { "$($row.Missing) missing, $($row.Superfluous) superfluous" } else { '' }
    Write-Host ("  {0} {1}  {2}" -f $status, $row.Pipeline.PadRight($width), $counts)
}
if (-not $checkPolicy) { Write-Host ''; Write-Host '  Note: branch policy path filters were not checked.' }

$failures = @($summary | Where-Object Failed)
Write-Host ''
Write-Host "$($summary.Count - $failures.Count) passed, $($failures.Count) failed."
if ($failures.Count -gt 0) {
    Write-PipelineIssue -Type error -Message "Path filters do not match the dependencies for: $(($failures | ForEach-Object Pipeline) -join ', ')"
    exit 1
}
