#Requires -Version 7.2
<#
.SYNOPSIS
    Calculates the scope of one pipeline and prints the minimal YAML trigger and branch policy path
    filter to copy and paste.

.DESCRIPTION
    The scope is the project's full project reference graph, the projects configured as always in
    scope, and every test project that directly references a project in that graph. The script prints
    the scope with the reason each project is in it, then the path filters that cover exactly that
    scope.

    In an Azure Pipelines run it also sets these variables for later steps:
      ProjectsInScope  all projects, separated by ';'
      Dependencies     the reference graph only, separated by ';'
      TestProjects     the test projects, one per line (usable as 'projects' input of DotNetCoreCLI)

    Needs the .NET SDK (it uses 'dotnet list reference'); no Azure DevOps access.

.PARAMETER ProjectFile
    The project the pipeline builds and deploys, relative to the working directory.

.PARAMETER PipelineFile
    The pipeline's YAML file, relative to the working directory. Used for the '{pipelineFile}'
    required path.

.PARAMETER WorkingDirectory
    Repository root. Defaults to the pipeline's sources directory, then the git root, then the
    current directory.

.PARAMETER ConfigPath
    path-filters.json. Defaults to the file next to this script.

.EXAMPLE
    pwsh ./build/path-filter-guard/Initialize-Scope.ps1 -ProjectFile src/Orders/Api/Orders.Api.csproj -PipelineFile pipelines/orders-api.yml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProjectFile,

    [string] $PipelineFile,

    [string] $WorkingDirectory,

    [string] $ConfigPath = (Join-Path $PSScriptRoot 'path-filters.json')
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
$project = ConvertTo-RepoPath -Path $ProjectFile -Root $WorkingDirectory
$scope = @(Get-ProjectScope -Project $project -Root $WorkingDirectory -Config $config)
$required = @(Get-RequiredPath -Config $config -Root $WorkingDirectory -PipelineFile $PipelineFile)
$expected = @(Get-ExpectedYamlPath -Scope $scope -Required $required)

Write-ProjectScope -Project $project -Scope $scope -Required $required
Write-ExpectedPathFilter -Expected $expected -PipelineFile $(if ($PipelineFile) { ConvertTo-FilterPath $PipelineFile })
Write-Host 'A build validation policy applies to every pull request into its branch: changing its path filter affects everyone with an open pull request.'

if ($env:TF_BUILD) {
    $all = @($scope | ForEach-Object Project)
    $dependencies = @($scope | Where-Object Kind -EQ 'Dependency' | ForEach-Object Project)
    $tests = @($scope | Where-Object Kind -EQ 'Test' | ForEach-Object Project)
    Write-Host "##vso[task.setvariable variable=ProjectsInScope]$($all -join ';')"
    Write-Host "##vso[task.setvariable variable=Dependencies]$($dependencies -join ';')"
    Write-Host "##vso[task.setvariable variable=TestProjects]$($tests -join '%0A')"
}
