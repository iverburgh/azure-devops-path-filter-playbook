# Test helpers: a small repository on disk with real project files.
#
#   src/App      -> src/Lib -> src/Core        (the pipeline's project graph)
#   src/Other                                  (unrelated)
#   src/Analyzers                              (added to every project, like Directory.Build.props does)
#   tests/App.Tests -> App, TestUtilities, Other
#   tests/Core.Tests -> Core, tests/Other.Tests -> Other
#   tests/Shared/TestUtilities                 (referenced by App.Tests only)
#   tests/Integration/Integration.Tests -> App (excluded by configuration)
#   tests/Analyzers.Tests                      (always in scope by configuration)

$script:DefaultInclude = @(
    'src/App/**', 'src/Core/**', 'src/Lib/**',
    'tests/Analyzers.Tests/**',
    'tests/App.Tests/**', 'tests/Core.Tests/**',
    'tests/Shared/TestUtilities/**',
    'pipelines/app.yml', 'Directory.Build.props'
)

function New-TestRepository {
    param(
        [string[]] $YamlInclude = $script:DefaultInclude,
        [string[]] $YamlExclude = @(),
        [switch] $TriggerNone
    )

    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $projects = [ordered]@{
        'src/App/App.csproj'                            = @('..\Lib\Lib.csproj')
        'src/Lib/Lib.csproj'                            = @('..\Core\Core.csproj')
        'src/Core/Core.csproj'                          = @()
        'src/Other/Other.csproj'                        = @()
        'src/Analyzers/Analyzers.csproj'                = @()
        'tests/App.Tests/App.Tests.csproj'              = @('..\..\src\App\App.csproj', '..\Shared\TestUtilities\TestUtilities.csproj', '..\..\src\Other\Other.csproj')
        'tests/Core.Tests/Core.Tests.csproj'            = @('..\..\src\Core\Core.csproj')
        'tests/Other.Tests/Other.Tests.csproj'          = @('..\..\src\Other\Other.csproj')
        'tests/Shared/TestUtilities/TestUtilities.csproj' = @()
        'tests/Analyzers.Tests/Analyzers.Tests.csproj'  = @('..\..\src\Analyzers\Analyzers.csproj')
        'tests/Integration/Integration.Tests.csproj'    = @('..\..\src\App\App.csproj')
    }

    foreach ($project in $projects.Keys) {
        $references = @($projects[$project])
        if ($project -ne 'src/Analyzers/Analyzers.csproj') {
            $depth = ($project.Split('/').Count - 1)
            $references += ('..\' * $depth) + 'src\Analyzers\Analyzers.csproj'
        }
        $items = ($references | ForEach-Object { "    <ProjectReference Include=`"$_`" />" }) -join "`n"
        $path = Join-Path $root $project
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Set-Content -LiteralPath $path -Value "<Project Sdk=`"Microsoft.NET.Sdk`">`n  <ItemGroup>`n$items`n  </ItemGroup>`n</Project>"
        Set-Content -LiteralPath (Join-Path (Split-Path $path) 'Class1.cs') -Value 'namespace Sample;'
    }
    New-Item -ItemType Directory -Path (Join-Path $root 'src/Lib/Generated') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'src/Lib/Generated/Model.g.cs') -Value '// generated'
    Set-Content -LiteralPath (Join-Path $root 'Directory.Build.props') -Value '<Project />'

    $include = ($YamlInclude | ForEach-Object { "    - '$_'" }) -join "`n"
    $exclude = if ($YamlExclude) { "`n    exclude:`n" + (($YamlExclude | ForEach-Object { "    - '$_'" }) -join "`n") } else { '' }
    $trigger = if ($TriggerNone) { 'trigger: none' } else { "trigger:`n  branches:`n    include:`n    - main`n  paths:`n    include:`n$include$exclude" }
    New-Item -ItemType Directory -Path (Join-Path $root 'pipelines') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'pipelines/app.yml') -Value @"
$trigger

steps:
- template: templates/path-filter-guard.yml
  parameters:
    projectFile: 'src/App/App.csproj'
"@

    $config = Get-PathFilterConfig
    $config.excludedTestPaths = @('tests/Integration')
    $config.ignoredReferences = @('src/Analyzers/Analyzers.csproj')
    $config.alwaysInScopeProjects = @('tests/Analyzers.Tests/Analyzers.Tests.csproj')
    $config.requiredPaths = @('{pipelineFile}', 'Directory.Build.props', 'global.json')

    [pscustomobject]@{
        Root         = $root
        Config       = $config
        PolicyFilter = ConvertTo-PolicyPathFilter -YamlPath $script:DefaultInclude
    }
}

function Invoke-FixtureReferenceScan {
    <#
    .SYNOPSIS
        Stands in for 'dotnet msbuild ScanProjectReferences.proj': reads the project list and writes
        '<project>|<reference>' lines with absolute paths, as the real scan does.
    #>
    param([object[]] $Arguments)

    $listFile = "$($Arguments | Where-Object { "$_" -like '-p:ProjectListFile=*' })".Substring('-p:ProjectListFile='.Length)
    $outputFile = "$($Arguments | Where-Object { "$_" -like '-p:ScanOutputFile=*' })".Substring('-p:ScanOutputFile='.Length)
    $lines = foreach ($project in [IO.File]::ReadAllLines($listFile)) {
        foreach ($include in @(Select-Xml -LiteralPath $project -XPath '//ProjectReference/@Include' | ForEach-Object { $_.Node.Value })) {
            "$project|$([IO.Path]::GetFullPath($include.Replace('\', '/'), (Split-Path $project -Parent)))"
        }
    }
    [IO.File]::WriteAllLines($outputFile, [string[]]@($lines))
    $global:LASTEXITCODE = 0
}

function New-FixturePolicy {
    param([string] $Filter, [string] $DefinitionId = '42')
    [pscustomobject]@{
        isEnabled = $true
        settings  = [pscustomobject]@{ buildDefinitionId = [int] $DefinitionId; filenamePatterns = @($Filter -split ';\s*') }
    }
}
