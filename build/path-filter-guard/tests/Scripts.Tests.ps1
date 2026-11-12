BeforeAll {
    . "$PSScriptRoot/../lib/PathFilterGuard.ps1"
    . "$PSScriptRoot/TestRepository.ps1"
    $script:Scripts = Split-Path $PSScriptRoot -Parent

    function New-ScriptRepository {
        param([string[]] $YamlInclude = $script:DefaultInclude)
        $repo = New-TestRepository -YamlInclude $YamlInclude
        $configPath = Join-Path $repo.Root 'path-filters.json'
        @{
            excludedTestPaths     = @('tests/Integration')
            ignoredReferences     = @('src/Analyzers/Analyzers.csproj')
            alwaysInScopeProjects = @('tests/Analyzers.Tests/Analyzers.Tests.csproj')
            requiredPaths         = @('{pipelineFile}', 'Directory.Build.props', 'global.json')
        } | ConvertTo-Json | Set-Content -LiteralPath $configPath
        $repo | Add-Member -NotePropertyName ConfigPath -NotePropertyValue $configPath -PassThru
    }

    function Invoke-Script {
        param([string] $Name, [hashtable] $Parameters)
        Clear-PathFilterCache
        $global:LASTEXITCODE = 0
        $output = & (Join-Path $script:Scripts $Name) @Parameters 6>&1 3>&1 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($output | ForEach-Object { "$_" }) }
    }

    function Set-AzDoMock {
        param([string] $PolicyFilter, [string] $YamlFile = 'pipelines/app.yml')
        # Mocks run in the invoked script's scope, which cannot see this file's script variables.
        $global:MockPolicyFilter = $PolicyFilter
        $global:MockYamlFile = $YamlFile
        Mock Invoke-RestMethod {
            if ($Uri -match '/_apis/build/definitions/42\?') {
                return [pscustomobject]@{ id = 42; process = [pscustomobject]@{ yamlFilename = "/$global:MockYamlFile" }; repository = [pscustomobject]@{ id = 'repo-id' } }
            }
            if ($Uri -match '/_apis/build/definitions\?') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = 42; process = [pscustomobject]@{ yamlFilename = "/$global:MockYamlFile" } }) }
            }
            if ($Uri -match '/_apis/git/policy/configurations\?') {
                return [pscustomobject]@{ value = @(New-FixturePolicy $global:MockPolicyFilter) }
            }
            throw "Unexpected request: $Uri"
        }
    }

    $script:AzDo = @{ CollectionUri = 'https://dev.azure.com/example/'; Project = 'Sample'; RepositoryId = 'repo-id'; AccessToken = 'token'; PolicyBranch = 'main' }
    $script:AllArgs = $script:AzDo
}

AfterAll {
    Remove-Variable -Name MockPolicyFilter, MockYamlFile -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Initialize-Scope.ps1' {
    BeforeAll {
        Mock dotnet { Invoke-FixtureReferenceScan $args } -ParameterFilter { $args[0] -eq 'msbuild' }
        $script:Repo = New-ScriptRepository
    }

    It 'prints the minimal YAML trigger paths to copy' {
        $result = Invoke-Script 'Initialize-Scope.ps1' @{ ProjectFile = 'src/App/App.csproj'; PipelineFile = 'pipelines/app.yml'; WorkingDirectory = $Repo.Root; ConfigPath = $Repo.ConfigPath }
        $result.ExitCode | Should -Be 0
        $yaml = @($result.Lines | Where-Object { $_ -match "^    - '" } | ForEach-Object { $_.Trim().Substring(3).Trim("'") })
        $yaml | Should -Be @('src/App/**', 'src/Core/**', 'src/Lib/**', 'tests/Analyzers.Tests/**', 'tests/App.Tests/**', 'tests/Core.Tests/**', 'tests/Shared/TestUtilities/**', 'pipelines/app.yml', 'Directory.Build.props')
    }

    It 'prints the branch policy path filter as one line' {
        $result = Invoke-Script 'Initialize-Scope.ps1' @{ ProjectFile = 'src/App/App.csproj'; PipelineFile = 'pipelines/app.yml'; WorkingDirectory = $Repo.Root; ConfigPath = $Repo.ConfigPath }
        $result.Lines | Should -Contain '/src/App/*; /src/Core/*; /src/Lib/*; /tests/Analyzers.Tests/*; /tests/App.Tests/*; /tests/Core.Tests/*; /tests/Shared/TestUtilities/*; /pipelines/app.yml; /Directory.Build.props'
    }

    It 'prints why each project is in scope' {
        $result = Invoke-Script 'Initialize-Scope.ps1' @{ ProjectFile = 'src/App/App.csproj'; WorkingDirectory = $Repo.Root; ConfigPath = $Repo.ConfigPath }
        $result.Lines | Where-Object { $_ -match 'src/Core/Core\.csproj' } | Should -Match 'App -> Lib -> Core'
    }

    It 'sets pipeline variables in a pipeline run' {
        $env:TF_BUILD = 'True'
        try {
            $result = Invoke-Script 'Initialize-Scope.ps1' @{ ProjectFile = 'src/App/App.csproj'; WorkingDirectory = $Repo.Root; ConfigPath = $Repo.ConfigPath }
        }
        finally {
            Remove-Item Env:TF_BUILD
        }
        $result.Lines | Should -Contain '##vso[task.setvariable variable=Dependencies]src/App/App.csproj;src/Lib/Lib.csproj;src/Core/Core.csproj'
        $result.Lines | Should -Contain '##vso[task.setvariable variable=TestProjects]tests/App.Tests/App.Tests.csproj%0Atests/Core.Tests/Core.Tests.csproj'
    }
}

Describe 'Test-PathFilters.ps1' {
    BeforeAll {
        Mock dotnet { Invoke-FixtureReferenceScan $args } -ParameterFilter { $args[0] -eq 'msbuild' }
    }

    It 'succeeds when the YAML trigger matches, without Azure DevOps access' {
        $repo = New-ScriptRepository
        $result = Invoke-Script 'Test-PathFilters.ps1' @{ ProjectFile = 'src/App/App.csproj'; PipelineFile = 'pipelines/app.yml'; WorkingDirectory = $repo.Root; ConfigPath = $repo.ConfigPath; SkipBranchPolicy = $true }
        $result.ExitCode | Should -Be 0
        $result.Lines | Should -Contain '    [OK] nothing missing, nothing superfluous'
    }

    It 'fails and prints what is missing and superfluous, plus the filters to copy' {
        $repo = New-ScriptRepository -YamlInclude (($script:DefaultInclude | Where-Object { $_ -ne 'src/Core/**' }) + 'src/Other/**')
        $result = Invoke-Script 'Test-PathFilters.ps1' @{ ProjectFile = 'src/App/App.csproj'; PipelineFile = 'pipelines/app.yml'; WorkingDirectory = $repo.Root; ConfigPath = $repo.ConfigPath; SkipBranchPolicy = $true }
        $result.ExitCode | Should -Be 1
        $result.Lines | Where-Object { $_ -match '\[MISSING\]' } | Should -Match 'src/Core/ .*App -> Lib -> Core'
        $result.Lines | Where-Object { $_ -match '\[SUPERFLUOUS\]' } | Should -Match 'src/Other/\*\*'
        $result.Lines | Should -Contain "    - 'src/Core/**'"
    }

    It 'passes with -AllowSuperfluous when only superfluous entries are found' {
        $repo = New-ScriptRepository -YamlInclude ($script:DefaultInclude + 'src/Other/**')
        $result = Invoke-Script 'Test-PathFilters.ps1' @{ ProjectFile = 'src/App/App.csproj'; PipelineFile = 'pipelines/app.yml'; WorkingDirectory = $repo.Root; ConfigPath = $repo.ConfigPath; SkipBranchPolicy = $true; AllowSuperfluous = $true }
        $result.ExitCode | Should -Be 0
    }

    It 'fails when the branch policy misses a path, reading the YAML file from the definition' {
        $repo = New-ScriptRepository
        Set-AzDoMock -PolicyFilter ($repo.PolicyFilter -replace '/src/Lib/\*; ', '')
        $parameters = $script:AzDo.Clone() + @{ ProjectFile = 'src/App/App.csproj'; BuildDefinitionId = '42'; WorkingDirectory = $repo.Root; ConfigPath = $repo.ConfigPath }
        $parameters.Remove('RepositoryId')
        $result = Invoke-Script 'Test-PathFilters.ps1' $parameters
        $result.ExitCode | Should -Be 1
        $result.Lines | Where-Object { $_ -match '\[MISSING\]' } | Should -Match 'src/Lib/'
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Uri -match 'refName=refs%2Fheads%2Fmain' -and $Uri -match 'repositoryId=repo-id' } -Times 1 -Exactly
    }

    It 'refuses to skip the branch policy silently in a pipeline run without token' {
        $repo = New-ScriptRepository
        $env:TF_BUILD = 'True'
        try {
            { & (Join-Path $script:Scripts 'Test-PathFilters.ps1') -ProjectFile 'src/App/App.csproj' -BuildDefinitionId 42 -WorkingDirectory $repo.Root -ConfigPath $repo.ConfigPath -AccessToken '' } |
                Should -Throw '*SYSTEM_ACCESSTOKEN*'
        }
        finally {
            Remove-Item Env:TF_BUILD
        }
    }
}

Describe 'Test-AllPathFilters.ps1' {
    BeforeAll {
        Mock dotnet { Invoke-FixtureReferenceScan $args } -ParameterFilter { $args[0] -eq 'msbuild' }
    }

    It 'passes every discovered pipeline whose filters match' {
        $repo = New-ScriptRepository
        Set-AzDoMock -PolicyFilter $repo.PolicyFilter
        $result = Invoke-Script 'Test-AllPathFilters.ps1' ($script:AllArgs.Clone() + @{ WorkingDirectory = $repo.Root; ConfigPath = $repo.ConfigPath })
        $result.ExitCode | Should -Be 0
        $result.Lines | Where-Object { $_ -match '\[PASS\]' } | Should -Match 'pipelines/app.yml'
        $result.Lines | Should -Contain '1 passed, 0 failed.'
    }

    It 'fails and summarises counts per pipeline' {
        $repo = New-ScriptRepository -YamlInclude ($script:DefaultInclude | Where-Object { $_ -ne 'tests/Core.Tests/**' })
        Set-AzDoMock -PolicyFilter ($repo.PolicyFilter + '; /src/Other/*')
        $result = Invoke-Script 'Test-AllPathFilters.ps1' ($script:AllArgs.Clone() + @{ WorkingDirectory = $repo.Root; ConfigPath = $repo.ConfigPath })
        $result.ExitCode | Should -Be 1
        $result.Lines | Where-Object { $_ -match '\[FAIL\]' } | Should -Match 'pipelines/app.yml\s+1 missing, 1 superfluous'
    }

    It 'reads Azure DevOps once for definitions and once for policies' {
        $repo = New-ScriptRepository
        Set-AzDoMock -PolicyFilter $repo.PolicyFilter
        $null = Invoke-Script 'Test-AllPathFilters.ps1' ($script:AllArgs.Clone() + @{ WorkingDirectory = $repo.Root; ConfigPath = $repo.ConfigPath })
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly
    }
}
