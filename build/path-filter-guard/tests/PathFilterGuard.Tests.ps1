BeforeAll {
    . "$PSScriptRoot/../lib/PathFilterGuard.ps1"
    . "$PSScriptRoot/TestRepository.ps1"
}

Describe 'ConvertTo-YamlRegex' {
    It '<Pattern> matches <File>: <Expected>' -TestCases @(
        @{ Pattern = 'src/App/**'; File = 'src/App/Program.cs'; Expected = $true }
        @{ Pattern = 'src/App/**'; File = 'src/App/Deep/Folder/File.cs'; Expected = $true }
        @{ Pattern = 'src/App/**'; File = 'src/AppOther/Program.cs'; Expected = $false }
        @{ Pattern = "'src/App/**'"; File = 'src/App/Program.cs'; Expected = $true }
        @{ Pattern = '/src/App/**'; File = 'src/App/Program.cs'; Expected = $true }
        @{ Pattern = 'src/*/Program.cs'; File = 'src/App/Program.cs'; Expected = $true }
        @{ Pattern = 'src/*/Program.cs'; File = 'src/App/Deep/Program.cs'; Expected = $false }
        @{ Pattern = 'src/**/Program.cs'; File = 'src/Program.cs'; Expected = $true }
        @{ Pattern = 'src/**/Program.cs'; File = 'src/App/Deep/Program.cs'; Expected = $true }
        @{ Pattern = 'src/App?/**'; File = 'src/App1/x.cs'; Expected = $true }
        @{ Pattern = 'src/App'; File = 'src/App/Program.cs'; Expected = $true }
        @{ Pattern = 'src/App'; File = 'src/AppOther/Program.cs'; Expected = $false }
        @{ Pattern = 'global.json'; File = 'global.json'; Expected = $true }
    ) {
        [regex]::IsMatch($File, (ConvertTo-YamlRegex $Pattern)) | Should -Be $Expected
    }
}

Describe 'Test-YamlPathIncluded' {
    BeforeAll {
        function New-Rules([string[]] $Include, [string[]] $Exclude) {
            $filter = [pscustomobject]@{
                Include = [Collections.Generic.List[string]]::new([string[]]@($Include | Where-Object { $_ }))
                Exclude = [Collections.Generic.List[string]]::new([string[]]@($Exclude | Where-Object { $_ }))
            }
            New-YamlRule $filter
        }
    }

    It 'includes everything when there is no include list' {
        Test-YamlPathIncluded -File 'any/file.cs' -Rules (New-Rules) | Should -BeTrue
    }

    It 'lets a more specific exclude win' {
        $rules = New-Rules -Include 'tools/**' -Exclude 'tools/legacy/**'
        Test-YamlPathIncluded -File 'tools/legacy/a.ps1' -Rules $rules | Should -BeFalse
        Test-YamlPathIncluded -File 'tools/current/a.ps1' -Rules $rules | Should -BeTrue
    }

    It 'lets a more specific include win regardless of order' {
        $rules = New-Rules -Include 'tools/legacy/keep/**' -Exclude 'tools/**'
        Test-YamlPathIncluded -File 'tools/legacy/keep/a.ps1' -Rules $rules | Should -BeTrue
        Test-YamlPathIncluded -File 'tools/other/a.ps1' -Rules $rules | Should -BeFalse
    }

    It 'lets the exclude win a tie' {
        $rules = New-Rules -Include 'tools/**' -Exclude 'tools/*.md'
        Test-YamlPathIncluded -File 'tools/readme.md' -Rules $rules | Should -BeFalse
    }
}

Describe 'New-PolicyRule and Test-PolicyPathIncluded' {
    It 'lets the last matching entry win' {
        $rules = (New-PolicyRule -Pattern '/src/*; !/src/Legacy/*; /src/Legacy/Keep/*').Rules
        Test-PolicyPathIncluded -File 'src/App/a.cs' -Rules $rules | Should -BeTrue
        Test-PolicyPathIncluded -File 'src/Legacy/a.cs' -Rules $rules | Should -BeFalse
        Test-PolicyPathIncluded -File 'src/Legacy/Keep/a.cs' -Rules $rules | Should -BeTrue
    }

    It 'matches across folders with a single *' {
        $rules = (New-PolicyRule -Pattern '/src/*').Rules
        Test-PolicyPathIncluded -File 'src/App/Deep/a.cs' -Rules $rules | Should -BeTrue
    }

    It 'treats a path without wildcard as the folder and everything below it' {
        $rules = (New-PolicyRule -Pattern '/src/App').Rules
        Test-PolicyPathIncluded -File 'src/App/a.cs' -Rules $rules | Should -BeTrue
        Test-PolicyPathIncluded -File 'src/AppOther/a.cs' -Rules $rules | Should -BeFalse
    }

    It 'includes everything that is not excluded when there are only excludes' {
        $rules = (New-PolicyRule -Pattern '!/docs/*').Rules
        Test-PolicyPathIncluded -File 'src/a.cs' -Rules $rules | Should -BeTrue
        Test-PolicyPathIncluded -File 'docs/a.md' -Rules $rules | Should -BeFalse
    }

    It 'includes everything without a filter' {
        Test-PolicyPathIncluded -File 'src/a.cs' -Rules @() | Should -BeTrue
    }

    It 'warns about ** and still uses the entry' {
        $result = New-PolicyRule -Pattern '/src/**'
        $result.Warnings | Should -HaveCount 1
        $result.Warnings[0] | Should -Match "contains '\*\*'"
        Test-PolicyPathIncluded -File 'src/a/b.cs' -Rules $result.Rules | Should -BeTrue
    }

    It 'ignores entries that do not start with / or *' -TestCases @(
        @{ Pattern = 'src/App/*' }
        @{ Pattern = '/src\App\*' }
    ) {
        $result = New-PolicyRule -Pattern $Pattern
        $result.Rules | Should -HaveCount 0
        $result.Warnings | Should -HaveCount 1
    }
}

Describe 'Get-YamlTriggerFilter' {
    It 'reads include and exclude paths, ignoring branches and comments' {
        $yaml = @'
name: $(Date:yyyyMMdd)$(Rev:.r)

trigger:
  batch: true
  branches:
    include:
    - main
  paths:
    include:
    - 'src/App/**'   # the app
    - "src/Lib/**"
    # - 'src/Disabled/**'
    - global.json
    exclude:
    - 'src/App/docs/**'

pool:
  vmImage: ubuntu-latest
'@
        $filter = Get-YamlTriggerFilter $yaml
        $filter.HasTrigger | Should -BeTrue
        $filter.HasPaths | Should -BeTrue
        $filter.Include | Should -Be @('src/App/**', 'src/Lib/**', 'global.json')
        $filter.Exclude | Should -Be @('src/App/docs/**')
    }

    It 'reads inline lists' {
        $filter = Get-YamlTriggerFilter "trigger:`n  paths:`n    include: [ 'src/A/**', src/B ]`n"
        $filter.Include | Should -Be @('src/A/**', 'src/B')
    }

    It 'reports trigger: none' {
        (Get-YamlTriggerFilter "trigger: none`n").HasTrigger | Should -BeFalse
    }

    It 'treats a missing trigger as the default trigger without paths' {
        $filter = Get-YamlTriggerFilter "pool:`n  vmImage: ubuntu-latest`n"
        $filter.HasTrigger | Should -BeTrue
        $filter.Include | Should -HaveCount 0
    }

    It 'ignores paths under pr: and in templates' {
        $filter = Get-YamlTriggerFilter "trigger:`n  branches:`n    include: [main]`npr:`n  paths:`n    include:`n    - src/Pr/**`n"
        $filter.HasPaths | Should -BeFalse
        $filter.Include | Should -HaveCount 0
    }
}

Describe 'Get-ProjectScope' {
    BeforeAll {
        $script:Repo = New-TestRepository
        Mock dotnet { Get-FixtureProjectReference $args[1] } -ParameterFilter { $args[0] -eq 'list' -and $args[2] -eq 'reference' }
        $script:Scope = Get-ProjectScope -Project 'src/App/App.csproj' -Root $Repo.Root -Config $Repo.Config
    }

    It 'contains the full reference graph' {
        @($Scope | Where-Object Kind -EQ Dependency | ForEach-Object Project) | Should -Be @('src/App/App.csproj', 'src/Lib/Lib.csproj', 'src/Core/Core.csproj')
    }

    It 'explains why a transitive dependency is in scope' {
        ($Scope | Where-Object Project -EQ 'src/Core/Core.csproj').Reason | Should -Be 'App -> Lib -> Core'
    }

    It 'adds test projects that reference a project in scope' {
        @($Scope | Where-Object Kind -EQ Test | ForEach-Object Project) | Should -Be @('tests/App.Tests/App.Tests.csproj', 'tests/Core.Tests/Core.Tests.csproj')
        ($Scope | Where-Object Project -EQ 'tests/Core.Tests/Core.Tests.csproj').Reason | Should -Be 'references Core'
    }

    It 'leaves out tests of unrelated projects and excluded test paths' {
        $projects = @($Scope | ForEach-Object Project)
        $projects | Should -Not -Contain 'tests/Other.Tests/Other.Tests.csproj'
        $projects | Should -Not -Contain 'tests/Integration/Integration.Tests.csproj'
    }

    It 'leaves out ignored references such as analyzers added to every project' {
        @($Scope | ForEach-Object Project) | Should -Not -Contain 'src/Analyzers/Analyzers.csproj'
    }

    It 'adds the projects that selected tests reference, such as test helpers' {
        $support = $Scope | Where-Object Project -EQ 'tests/Shared/TestUtilities/TestUtilities.csproj'
        $support.Kind | Should -Be 'TestSupport'
        $support.Reason | Should -Be 'used by App.Tests'
    }

    It 'does not add production projects that a selected test also references' {
        @($Scope | ForEach-Object Project) | Should -Not -Contain 'src/Other/Other.csproj'
    }

    It 'adds projects that are configured as always in scope' {
        ($Scope | Where-Object Project -EQ 'tests/Analyzers.Tests/Analyzers.Tests.csproj').Kind | Should -Be 'Configured'
    }
}

Describe 'Get-ExpectedYamlPath and ConvertTo-PolicyPathFilter' {
    It 'lists folders per group, then required paths, without folders nested in listed folders' {
        $scope = @(
            New-ScopeItem -Project 'src/Lib/Lib.csproj' -Kind Dependency -Reason 'x'
            New-ScopeItem -Project 'src/App/App.csproj' -Kind Dependency -Reason 'x'
            New-ScopeItem -Project 'src/App/Plugins/Plugin.csproj' -Kind Dependency -Reason 'x'
            New-ScopeItem -Project 'tests/App.Tests/App.Tests.csproj' -Kind Test -Reason 'x'
        )
        $required = @(
            [pscustomobject]@{ Path = 'pipelines/app.yml'; IsFolder = $false; Reason = 'x' }
            [pscustomobject]@{ Path = 'pipelines/templates'; IsFolder = $true; Reason = 'x' }
        )
        Get-ExpectedYamlPath -Scope $scope -Required $required |
            Should -Be @('src/App/**', 'src/Lib/**', 'tests/App.Tests/**', 'pipelines/app.yml', 'pipelines/templates/**')
    }

    It 'converts YAML paths to a branch policy filter' {
        ConvertTo-PolicyPathFilter -YamlPath @('src/App/**', 'global.json') | Should -Be '/src/App/*; /global.json'
    }
}

Describe 'Invoke-PathFilterValidation' {
    BeforeAll {
        Mock dotnet { Get-FixtureProjectReference $args[1] } -ParameterFilter { $args[0] -eq 'list' -and $args[2] -eq 'reference' }
    }

    It 'passes when both filters cover exactly the scope' {
        $repo = New-TestRepository
        $result = Invoke-PathFilterValidation -Project 'src/App/App.csproj' -PipelineFile 'pipelines/app.yml' -Root $repo.Root -Config $repo.Config `
            -CheckBranchPolicy -Policy @(New-FixturePolicy $repo.PolicyFilter) -PolicyBranch 'refs/heads/main'
        $result.Findings | Should -HaveCount 0
        $result.Checked | Should -Be @('YAML trigger', 'Branch policy')
    }

    It 'reports a missing dependency in the YAML trigger, with the reason' {
        $repo = New-TestRepository -YamlInclude ($script:DefaultInclude | Where-Object { $_ -ne 'src/Core/**' })
        $result = Invoke-PathFilterValidation -Project 'src/App/App.csproj' -PipelineFile 'pipelines/app.yml' -Root $repo.Root -Config $repo.Config
        $result.Findings | Should -HaveCount 1
        $finding = $result.Findings[0]
        $finding.Filter | Should -Be 'YAML trigger'
        $finding.Type | Should -Be 'Missing'
        $finding.Path | Should -Be 'src/Core/'
        $finding.Detail | Should -Match 'App -> Lib -> Core'
    }

    It 'reports an excluded file as missing' {
        $repo = New-TestRepository -YamlExclude 'src/Lib/Generated/**'
        $result = Invoke-PathFilterValidation -Project 'src/App/App.csproj' -PipelineFile 'pipelines/app.yml' -Root $repo.Root -Config $repo.Config
        ($result.Findings | Where-Object Type -EQ Missing).Path | Should -Be 'src/Lib/'
    }

    It 'reports a path that matches nothing in scope as superfluous' {
        $repo = New-TestRepository -YamlInclude ($script:DefaultInclude + 'src/Other/**' + 'src/Removed/**')
        $result = Invoke-PathFilterValidation -Project 'src/App/App.csproj' -PipelineFile 'pipelines/app.yml' -Root $repo.Root -Config $repo.Config
        $superfluous = @($result.Findings | Where-Object Type -EQ Superfluous)
        $superfluous.Path | Should -Be @('src/Other/**', 'src/Removed/**')
        ($superfluous | Where-Object Path -EQ 'src/Removed/**').Detail | Should -Match 'does not exist'
    }

    It 'does not report allowed extra paths as superfluous' {
        $repo = New-TestRepository -YamlInclude ($script:DefaultInclude + 'src/Other/**')
        $repo.Config.allowedExtraPaths = @('src/Other/**')
        $result = Invoke-PathFilterValidation -Project 'src/App/App.csproj' -PipelineFile 'pipelines/app.yml' -Root $repo.Root -Config $repo.Config
        $result.Findings | Should -HaveCount 0
    }

    It 'reports a missing test project in the branch policy' {
        $repo = New-TestRepository
        $policy = New-FixturePolicy ($repo.PolicyFilter -replace '/tests/Core\.Tests/\*; ', '')
        $result = Invoke-PathFilterValidation -Project 'src/App/App.csproj' -PipelineFile 'pipelines/app.yml' -Root $repo.Root -Config $repo.Config `
            -CheckBranchPolicy -Policy @($policy) -PolicyBranch 'refs/heads/main'
        $result.Findings | Should -HaveCount 1
        $finding = $result.Findings[0]
        $finding.Filter | Should -Be 'Branch policy'
        $finding.Path | Should -Be 'tests/Core.Tests/'
        $finding.Detail | Should -Match 'references Core'
    }

    It 'notes a pipeline without build validation policy' {
        $repo = New-TestRepository
        $result = Invoke-PathFilterValidation -Project 'src/App/App.csproj' -PipelineFile 'pipelines/app.yml' -Root $repo.Root -Config $repo.Config `
            -CheckBranchPolicy -Policy @() -PolicyBranch 'refs/heads/main'
        $result.Notes | Should -Match 'no enabled build validation policy'
        $result.Checked | Should -Be @('YAML trigger')
    }

    It 'skips the YAML check for trigger: none' {
        $repo = New-TestRepository -TriggerNone
        $result = Invoke-PathFilterValidation -Project 'src/App/App.csproj' -PipelineFile 'pipelines/app.yml' -Root $repo.Root -Config $repo.Config
        $result.Checked | Should -HaveCount 0
        $result.Notes | Should -Match 'trigger: none'
    }
}

Describe 'Find-AppPipeline' {
    It 'discovers pipelines that pass a project through the project parameter' {
        $repo = New-TestRepository
        $pipelines = @(Find-AppPipeline -Root $repo.Root -Config $repo.Config)
        $pipelines | Should -HaveCount 1
        $pipelines[0].Yaml | Should -Be 'pipelines/app.yml'
        $pipelines[0].Project | Should -Be 'src/App/App.csproj'
    }
}
