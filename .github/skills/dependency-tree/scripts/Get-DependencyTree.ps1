#Requires -Version 7.2
<#
.SYNOPSIS
    Shows the ProjectReference tree of a .NET project as an ASCII tree.

.DESCRIPTION
    Resolves every project reference recursively with 'dotnet list reference' and prints the tree.
    With -TargetDependency only the branches that lead to that project are shown, followed by each
    dependency chain on one line.

.PARAMETER ProjectFile
    The project whose tree to show.

.PARAMETER TargetDependency
    Part of a project name or path. Shows only the paths to matching projects.

.EXAMPLE
    ./Get-DependencyTree.ps1 -ProjectFile src/Orders/Api/Orders.Api.csproj

.EXAMPLE
    ./Get-DependencyTree.ps1 -ProjectFile src/Orders/Api/Orders.Api.csproj -TargetDependency Shared.Contracts
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProjectFile,

    [string] $TargetDependency
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Cache = @{}

function Get-ProjectReference {
    param([Parameter(Mandatory)][string] $Project)

    if ($script:Cache.ContainsKey($Project)) { return $script:Cache[$Project] }

    $folder = Split-Path $Project -Parent
    $output = & dotnet list $Project reference 2>&1
    $global:LASTEXITCODE = 0

    $references = foreach ($line in $output) {
        if ($line -is [Management.Automation.ErrorRecord]) { continue }
        $reference = "$line".Trim()
        if ($reference -notmatch '\.csproj$') { continue }
        if ($reference -match '^[A-Za-z]:\\.*?\\\\(?<rest>\.\..*)$') { $reference = '..\' + $Matches['rest'] }
        [IO.Path]::GetFullPath($reference.Replace('\', '/'), $folder)
    }

    $script:Cache[$Project] = @($references)
    $script:Cache[$Project]
}

function New-TreeNode {
    param(
        [Parameter(Mandatory)][string] $Project,
        [Collections.Generic.HashSet[string]] $Ancestors = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    )

    $node = [pscustomobject]@{
        Name     = [IO.Path]::GetFileNameWithoutExtension($Project)
        Path     = [IO.Path]::GetRelativePath($script:Root, $Project).Replace('\', '/')
        Children = [Collections.Generic.List[object]]::new()
        Circular = $false
        IsTarget = $false
    }
    if (-not $Ancestors.Add($Project)) {
        $node.Circular = $true
        return $node
    }
    foreach ($reference in Get-ProjectReference -Project $Project) {
        if (Test-Path -LiteralPath $reference) { $node.Children.Add((New-TreeNode -Project $reference -Ancestors $Ancestors)) }
    }
    $null = $Ancestors.Remove($Project)
    $node
}

function Test-IsTarget {
    param([Parameter(Mandatory)] $Node)
    $Node.Name -like "*$TargetDependency*" -or $Node.Path -like "*$TargetDependency*"
}

function Get-PrunedTree {
    <# A copy of the tree with only the branches that lead to the target. #>
    param([Parameter(Mandatory)] $Node)

    $children = [Collections.Generic.List[object]]::new()
    foreach ($child in $Node.Children) {
        $pruned = Get-PrunedTree -Node $child
        if ($pruned) { $children.Add($pruned) }
    }
    $isTarget = Test-IsTarget $Node
    if (-not $isTarget -and $children.Count -eq 0) { return $null }

    [pscustomobject]@{ Name = $Node.Name; Path = $Node.Path; Children = $children; Circular = $Node.Circular; IsTarget = $isTarget }
}

function Write-Tree {
    param(
        [Parameter(Mandatory)] $Node,
        [string] $Prefix = '',
        [bool] $IsLast = $true,
        [bool] $IsRoot = $true
    )

    $marker = if ($IsRoot) { '' } elseif ($IsLast) { '└── ' } else { '├── ' }
    $label = $Node.Name
    if ($Node.Circular) { $label += ' (circular)' }
    if ($Node.IsTarget) { $label += '  <<<' }
    Write-Output "$Prefix$marker$label"

    $childPrefix = if ($IsRoot) { '' } elseif ($IsLast) { "$Prefix    " } else { "$Prefix│   " }
    for ($i = 0; $i -lt $Node.Children.Count; $i++) {
        Write-Tree -Node $Node.Children[$i] -Prefix $childPrefix -IsLast ($i -eq $Node.Children.Count - 1) -IsRoot $false
    }
}

function Get-Chain {
    param([Parameter(Mandatory)] $Node, [string[]] $Path = @())

    $current = $Path + $Node.Name
    if ($Node.IsTarget) { $current -join ' -> ' }
    foreach ($child in $Node.Children) {
        if (-not $child.Circular) { Get-Chain -Node $child -Path $current }
    }
}

$script:Root = (& git rev-parse --show-toplevel 2>$null)
if (-not $script:Root) { $script:Root = (Get-Location).Path }
$global:LASTEXITCODE = 0

$project = [IO.Path]::GetFullPath($ProjectFile)
if (-not (Test-Path -LiteralPath $project)) { throw "Project '$ProjectFile' not found." }

$tree = New-TreeNode -Project $project
Write-Output ''
Write-Output "Dependency tree of $($tree.Name)"
Write-Output ('=' * 60)
Write-Output ''

if (-not $TargetDependency) {
    Write-Tree -Node $tree
    return
}

Write-Output "Filtered on paths to: $TargetDependency"
Write-Output ('-' * 60)
Write-Output ''
$pruned = Get-PrunedTree -Node $tree
if (-not $pruned) {
    Write-Output "$($tree.Name) does not depend on anything matching '$TargetDependency'."
    return
}
Write-Tree -Node $pruned
Write-Output ''
Write-Output 'Dependency chain(s):'
Get-Chain -Node $pruned | Select-Object -Unique | ForEach-Object { Write-Output "  $_" }
