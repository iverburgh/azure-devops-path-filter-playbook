#Requires -Version 7.2
<#
.SYNOPSIS
    Shared functions of the path filter guard.

.DESCRIPTION
    Calculates which projects a pipeline depends on, reads the pipeline's YAML trigger path filter
    and its branch policy path filter, and reports what is missing from or superfluous in either.

    Dot-source this file. The scripts next to it are thin wrappers around these functions.
#>

Set-StrictMode -Version Latest

$script:BuildValidationPolicyType = '0609b952-1397-4640-95ec-e00a01b2c241'
$script:ReferenceCache = @{}
$script:RepositoryFileCache = @{}
$script:FolderIndexCache = @{}

#region Configuration and paths

function Get-PathFilterConfig {
    <#
    .SYNOPSIS
        Reads path-filters.json, using a default for every setting the file does not contain.
    #>
    [CmdletBinding()]
    param(
        [string] $ConfigPath
    )

    $config = [ordered]@{
        testProjectPattern    = '(?i)tests?\.csproj$'
        excludedTestPaths     = @()
        testSupportPaths      = @()
        ignoredReferences     = @()
        alwaysInScopeProjects = @()
        requiredPaths         = @('{pipelineFile}', 'Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props', 'global.json')
        allowedExtraPaths     = @()
        projectParameter      = 'projectFile'
        excludedPipelinePaths = @()
        pipelines             = @()
    }

    if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
        $fromFile = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($key in $fromFile.Keys) {
            if ($config.Contains($key)) {
                $config[$key] = $fromFile[$key]
            }
            elseif (-not $key.StartsWith('_') -and $key -ne '$schema') {
                Write-Warning "Unknown setting '$key' in $ConfigPath is ignored."
            }
        }
    }

    foreach ($key in 'excludedTestPaths', 'testSupportPaths', 'ignoredReferences', 'alwaysInScopeProjects', 'requiredPaths', 'allowedExtraPaths', 'excludedPipelinePaths') {
        $config[$key] = @($config[$key] | Where-Object { $_ } | ForEach-Object { ConvertTo-FilterPath $_ })
    }
    $config.pipelines = @($config.pipelines | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ Yaml = ConvertTo-FilterPath $_.yaml; Project = ConvertTo-FilterPath $_.project }
        })

    [pscustomobject]$config
}

function ConvertTo-FilterPath {
    <#
    .SYNOPSIS
        Normalises a path or pattern: no quotes, forward slashes, no leading slash or './'.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path
    )

    $normalized = $Path.Trim().Trim("'", '"').Replace('\', '/')
    while ($normalized.StartsWith('./')) { $normalized = $normalized.Substring(2) }
    $normalized.TrimStart('/')
}

function ConvertTo-RepoPath {
    <#
    .SYNOPSIS
        Converts an absolute or relative path to a repository-relative path with forward slashes.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root
    )

    $full = [IO.Path]::GetFullPath($Path.Replace('\', '/'), $Root)
    [IO.Path]::GetRelativePath($Root, $full).Replace('\', '/')
}

function Test-PathUnder {
    param(
        [Parameter(Mandatory)][string] $Path,
        [string[]] $Prefix
    )

    foreach ($candidate in $Prefix) {
        $folder = $candidate.TrimEnd('/')
        if ($Path -eq $folder -or $Path.StartsWith("$folder/", [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    $false
}

function Clear-PathFilterCache {
    $script:ReferenceCache = @{}
    $script:RepositoryFileCache = @{}
    $script:FolderIndexCache = @{}
}

function Get-RepositoryFile {
    <#
    .SYNOPSIS
        All files in the working copy: tracked, plus untracked files that are not ignored.
        Falls back to a directory scan outside a git working copy.
    #>
    param(
        [Parameter(Mandatory)][string] $Root
    )

    $key = [IO.Path]::GetFullPath($Root)
    if ($script:RepositoryFileCache.ContainsKey($key)) { return $script:RepositoryFileCache[$key] }

    $files = @()
    try {
        $output = & git -C $Root -c core.quotepath=false ls-files --cached --others --exclude-standard 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) { $files = @($output) }
    }
    catch {
        $files = @()
    }
    if ($files.Count -eq 0) {
        $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
                ForEach-Object { ConvertTo-RepoPath -Path $_.FullName -Root $Root } |
                Where-Object { $_ -notmatch '(^|/)(\.git|bin|obj|node_modules)/' })
    }
    $global:LASTEXITCODE = 0

    $script:RepositoryFileCache[$key] = $files
    $files
}

function Get-FileUnder {
    <#
    .SYNOPSIS
        Files below a repository folder, from an index built once per working copy.
    #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Folder
    )

    $key = [IO.Path]::GetFullPath($Root)
    if (-not $script:FolderIndexCache.ContainsKey($key)) {
        $index = [Collections.Generic.Dictionary[string, Collections.Generic.List[string]]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in Get-RepositoryFile -Root $Root) {
            $slash = $file.LastIndexOf('/')
            while ($slash -gt 0) {
                $parent = $file.Substring(0, $slash)
                if (-not $index.ContainsKey($parent)) { $index[$parent] = [Collections.Generic.List[string]]::new() }
                $index[$parent].Add($file)
                $slash = $parent.LastIndexOf('/')
            }
        }
        $script:FolderIndexCache[$key] = $index
    }

    $list = $null
    if ($script:FolderIndexCache[$key].TryGetValue($Folder.TrimEnd('/'), [ref] $list)) { return $list.ToArray() }
    @()
}

#endregion

#region Project scope

function Get-ProjectName {
    param([Parameter(Mandatory)][string] $Project)
    [IO.Path]::GetFileNameWithoutExtension($Project)
}

function Get-DirectProjectReference {
    <#
    .SYNOPSIS
        Direct project references of one project, as evaluated by MSBuild (so references added in
        Directory.Build.props are included), as repository-relative paths.
    #>
    param(
        [Parameter(Mandatory)][string] $Project,
        [Parameter(Mandatory)][string] $Root
    )

    $projectFile = [IO.Path]::GetFullPath($Project, $Root)
    $key = $projectFile.ToLowerInvariant()
    if ($script:ReferenceCache.ContainsKey($key)) { return $script:ReferenceCache[$key] }

    $output = & dotnet list $projectFile reference 2>&1
    $global:LASTEXITCODE = 0

    $result = ConvertFrom-DotnetListOutput -Output $output -ProjectFile $projectFile -Root $Root
    $script:ReferenceCache[$key] = $result
    $result
}

function ConvertFrom-DotnetListOutput {
    <#
    .SYNOPSIS
        Parses the output of 'dotnet list <project> reference' into repository-relative paths.
    #>
    param(
        [AllowNull()][object[]] $Output,
        [Parameter(Mandatory)][string] $ProjectFile,
        [Parameter(Mandatory)][string] $Root
    )

    $projectFolder = Split-Path $ProjectFile -Parent
    $references = [Collections.Generic.List[string]]::new()
    foreach ($line in $Output) {
        if ($line -is [Management.Automation.ErrorRecord]) { continue }
        $reference = "$line".Trim()
        if ($reference -notmatch '\.csproj$') { continue }

        # dotnet list prints some evaluated references as '<folder>\\..\<rest>'; they resolve as '..\<rest>' from the project folder.
        if ($reference -match '^[A-Za-z]:\\.*?\\\\(?<rest>\.\..*)$') {
            $reference = '..\' + $Matches['rest']
        }
        # Project files use backslashes even on Linux, where GetFullPath would treat them as part of a file name.
        $reference = $reference.Replace('\', '/')
        $references.Add((ConvertTo-RepoPath -Path ([IO.Path]::GetFullPath($reference, $projectFolder)) -Root $Root))
    }

    , $references.ToArray()
}

function Initialize-ReferenceCache {
    <#
    .SYNOPSIS
        Resolves the references of every project in the repository in parallel, so validating many
        pipelines does not wait for one 'dotnet list' call at a time.
    #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [int] $ThrottleLimit = [Environment]::ProcessorCount
    )

    $projects = @(Get-RepositoryFile -Root $Root | Where-Object { $_ -like '*.csproj' } |
            ForEach-Object { [IO.Path]::GetFullPath($_, $Root) } |
            Where-Object { -not $script:ReferenceCache.ContainsKey($_.ToLowerInvariant()) })

    if ($ThrottleLimit -le 1) {
        foreach ($project in $projects) { $null = Get-DirectProjectReference -Project $project -Root $Root }
        return $projects.Count
    }

    $outputs = $projects | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        [pscustomobject]@{ Project = $_; Output = @(& dotnet list $_ reference 2>&1 | ForEach-Object { "$_" }) }
    }
    $global:LASTEXITCODE = 0

    foreach ($item in $outputs) {
        $script:ReferenceCache[$item.Project.ToLowerInvariant()] = ConvertFrom-DotnetListOutput -Output $item.Output -ProjectFile $item.Project -Root $Root
    }
    $projects.Count
}

function Get-TestProject {
    <#
    .SYNOPSIS
        All test projects in the repository, per testProjectPattern and excludedTestPaths.
    #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)] $Config
    )

    @(Get-RepositoryFile -Root $Root |
            Where-Object { $_ -like '*.csproj' -and $_ -match $Config.testProjectPattern } |
            Where-Object { -not (Test-PathUnder -Path $_ -Prefix $Config.excludedTestPaths) } |
            Sort-Object)
}

function New-ScopeItem {
    param(
        [Parameter(Mandatory)][string] $Project,
        [Parameter(Mandatory)][ValidateSet('Dependency', 'Configured', 'Test', 'TestSupport')][string] $Kind,
        [Parameter(Mandatory)][string] $Reason
    )

    $folder = ($Project -replace '/?[^/]+$', '')
    [pscustomobject]@{ Project = $Project; Folder = $folder; Kind = $Kind; Reason = $Reason }
}

function Get-ProjectScope {
    <#
    .SYNOPSIS
        Every project a pipeline depends on: the project's full reference graph, configured
        projects, every test project that directly references a project in that graph, and the
        test helpers those tests reference from the test folders.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Project,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)] $Config,
        [string[]] $TestProjects
    )

    $Project = ConvertTo-RepoPath -Path $Project -Root $Root
    if (-not (Test-Path -LiteralPath (Join-Path $Root $Project))) {
        throw "Project '$Project' does not exist under '$Root'."
    }

    $ignored = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($reference in $Config.ignoredReferences) { $null = $ignored.Add($reference) }

    # Breadth-first, so the recorded parent gives the shortest chain for the explanation.
    $parent = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)
    $parent[$Project] = $null
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Project)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($reference in @(Get-DirectProjectReference -Project $current -Root $Root)) {
            if ($ignored.Contains($reference) -or $parent.Contains($reference)) { continue }
            $parent[$reference] = $current
            $queue.Enqueue($reference)
        }
    }

    $items = [Collections.Generic.List[object]]::new()
    foreach ($dependency in @($parent.Keys)) {
        $chain = [Collections.Generic.List[string]]::new()
        $node = $dependency
        while ($null -ne $node) {
            $chain.Insert(0, (Get-ProjectName $node))
            $node = $parent[$node]
        }
        $reason = if ($chain.Count -eq 1) { 'the project itself' } else { $chain -join ' -> ' }
        $items.Add((New-ScopeItem -Project $dependency -Kind Dependency -Reason $reason))
    }

    foreach ($configured in $Config.alwaysInScopeProjects) {
        if ($parent.Contains($configured)) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $Root $configured))) {
            Write-Warning "alwaysInScopeProjects: '$configured' does not exist and is skipped."
            continue
        }
        $items.Add((New-ScopeItem -Project $configured -Kind Configured -Reason 'always in scope (path-filters.json)'))
    }

    if (-not $PSBoundParameters.ContainsKey('TestProjects')) {
        $TestProjects = Get-TestProject -Root $Root -Config $Config
    }
    $inScope = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) { $null = $inScope.Add($item.Project) }

    $selectedTests = [Collections.Generic.List[string]]::new()
    foreach ($test in $TestProjects) {
        if ($inScope.Contains($test)) { continue }
        $covered = @(Get-DirectProjectReference -Project $test -Root $Root) |
            Where-Object { $parent.Contains($_) } |
            Select-Object -First 1
        if ($covered) {
            $items.Add((New-ScopeItem -Project $test -Kind Test -Reason "references $(Get-ProjectName $covered)"))
            $null = $inScope.Add($test)
            $selectedTests.Add($test)
        }
    }

    # A change to a helper that a selected test compiles against can break that test. Only helpers in
    # the test folders count: a production project a test also references is not this pipeline's code.
    $testSupportPaths = @($Config.testSupportPaths)
    if ($testSupportPaths.Count -eq 0) {
        # Top-level folders with test projects, minus those that also hold this pipeline's own code.
        $codeRoots = @($parent.Keys | ForEach-Object { $_.Split('/')[0] })
        $testSupportPaths = @($TestProjects | ForEach-Object { $_.Split('/')[0] } |
                Where-Object { $_ -notlike '*.csproj' -and $codeRoots -notcontains $_ } | Sort-Object -Unique)
    }
    $queue = [Collections.Generic.Queue[object]]::new()
    foreach ($test in $selectedTests) { $queue.Enqueue(@($test, $test)) }
    while ($queue.Count -gt 0) {
        $current, $test = $queue.Dequeue()
        foreach ($reference in @(Get-DirectProjectReference -Project $current -Root $Root)) {
            if ($ignored.Contains($reference) -or $inScope.Contains($reference)) { continue }
            if (-not (Test-PathUnder -Path $reference -Prefix $testSupportPaths)) { continue }
            if (Test-PathUnder -Path $reference -Prefix $Config.excludedTestPaths) { continue }
            $items.Add((New-ScopeItem -Project $reference -Kind TestSupport -Reason "used by $(Get-ProjectName $test)"))
            $null = $inScope.Add($reference)
            $queue.Enqueue(@($reference, $test))
        }
    }

    $items.ToArray()
}

function Get-RequiredPath {
    <#
    .SYNOPSIS
        Paths every pipeline must trigger on regardless of project references, for those that exist.
    #>
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)][string] $Root,
        [string] $PipelineFile
    )

    foreach ($entry in $Config.requiredPaths) {
        $path = $entry
        $reason = 'required by path-filters.json'
        if ($entry -eq '{pipelineFile}') {
            if (-not $PipelineFile) { continue }
            $path = ConvertTo-FilterPath $PipelineFile
            $reason = 'the pipeline definition itself'
        }

        $base = ($path -replace '/\*\*$', '').TrimEnd('/')
        $full = Join-Path $Root $base
        if (-not (Test-Path -LiteralPath $full)) { continue }

        [pscustomobject]@{
            Path     = $base
            IsFolder = (Test-Path -LiteralPath $full -PathType Container)
            Reason   = $reason
        }
    }
}

function Get-ExpectedYamlPath {
    <#
    .SYNOPSIS
        The minimal YAML trigger include list: one entry per folder in scope, then the required paths.
    #>
    param(
        [object[]] $Scope,
        [object[]] $Required
    )

    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($kind in 'Dependency', 'Configured', 'Test', 'TestSupport') {
        $Scope | Where-Object Kind -EQ $kind |
            ForEach-Object { if ($_.Folder) { "$($_.Folder)/**" } else { $_.Project } } |
            Sort-Object -Unique |
            ForEach-Object { $candidates.Add($_) }
    }
    foreach ($path in $Required) {
        $candidates.Add($(if ($path.IsFolder) { "$($path.Path)/**" } else { $path.Path }))
    }

    $folders = @($candidates | Where-Object { $_.EndsWith('/**') } | ForEach-Object { $_.Substring(0, $_.Length - 3) })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        $own = if ($candidate.EndsWith('/**')) { $candidate.Substring(0, $candidate.Length - 3) } else { $candidate }
        # A folder inside another folder in the list is already covered by it.
        $coveredByOther = $folders | Where-Object { $_ -ne $own -and $own.StartsWith("$_/", [StringComparison]::OrdinalIgnoreCase) }
        if ($coveredByOther) { continue }
        if ($seen.Add($candidate)) { $candidate }
    }
}

function ConvertTo-PolicyPathFilter {
    <#
    .SYNOPSIS
        Converts YAML trigger paths to the one-line format of a branch policy path filter.
    #>
    param(
        [Parameter(Mandatory)][string[]] $YamlPath
    )

    ($YamlPath | ForEach-Object { '/' + ((ConvertTo-FilterPath $_) -replace '\*\*', '*') }) -join '; '
}

#endregion

#region Filter parsing and matching

function Get-YamlTriggerFilter {
    <#
    .SYNOPSIS
        Reads the path filter of the top-level 'trigger:' block of a pipeline YAML file.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Yaml
    )

    $result = [pscustomobject]@{
        HasTrigger = $true
        HasPaths   = $false
        Include    = [Collections.Generic.List[string]]::new()
        Exclude    = [Collections.Generic.List[string]]::new()
    }

    $lines = $Yaml -split '\r?\n'
    $start = -1
    $inline = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^trigger\s*:\s*(?<value>[^#]*?)\s*(#.*)?$') {
            $start = $i
            $inline = $Matches['value']
            break
        }
    }

    # No trigger key means the default CI trigger: every branch, every path.
    if ($start -lt 0) { return $result }
    if ($inline -eq 'none') { $result.HasTrigger = $false; return $result }
    if ($inline) { return $result }

    $pathsIndent = -1
    $current = $null
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line -match '^\S') { break }

        $indent = $line.Length - $line.TrimStart().Length
        $text = ($line.Trim() -replace '\s+#.*$', '')

        if ($text -match '^paths\s*:\s*$') {
            $pathsIndent = $indent
            $result.HasPaths = $true
            $current = $null
            continue
        }
        if ($pathsIndent -lt 0) { continue }
        if ($indent -le $pathsIndent -and -not $text.StartsWith('-')) {
            $pathsIndent = -1
            $current = $null
            continue
        }
        if ($text -match '^(?<key>include|exclude)\s*:\s*(?<list>\[.*\])?$') {
            $current = $Matches['key']
            if ($Matches['list']) {
                foreach ($item in $Matches['list'].Trim('[', ']').Split(',')) {
                    $value = $item.Trim().Trim("'", '"')
                    if ($value) { $result.($current.Substring(0, 1).ToUpper() + $current.Substring(1)).Add($value) }
                }
            }
            continue
        }
        if ($current -and $text -match '^-\s*(?<item>.+)$') {
            $value = $Matches['item'].Trim().Trim("'", '"')
            if ($current -eq 'include') { $result.Include.Add($value) } else { $result.Exclude.Add($value) }
        }
    }

    $result
}

function Test-HasWildcard {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Pattern)
    $Pattern -match '[*?]'
}

function Get-LiteralPrefix {
    <#
    .SYNOPSIS
        The leading folder segments of a pattern that contain no wildcard.
    #>
    param([Parameter(Mandatory)][string] $Pattern)

    $segments = foreach ($segment in (ConvertTo-FilterPath $Pattern.TrimStart('!')).Split('/')) {
        if (-not $segment -or (Test-HasWildcard $segment)) { break }
        $segment
    }
    @($segments) -join '/'
}

function Get-CanonicalFilter {
    <#
    .SYNOPSIS
        A form in which a YAML path and the equivalent branch policy path compare equal.
    #>
    param([Parameter(Mandatory)][string] $Pattern)
    ((ConvertTo-FilterPath $Pattern.TrimStart('!')) -replace '\*+', '*').TrimEnd('/').ToLowerInvariant()
}

function ConvertTo-YamlRegex {
    <#
    .SYNOPSIS
        Converts a YAML trigger path to a regular expression. '*' and '?' stay within one folder,
        '**' crosses folders, and a path without wildcards also matches everything below it.
    #>
    param([Parameter(Mandatory)][string] $Pattern)

    $path = ConvertTo-FilterPath $Pattern
    if (-not (Test-HasWildcard $path)) {
        return '^' + [regex]::Escape($path.TrimEnd('/')) + '(/|$)'
    }

    $regex = [regex]::Escape($path)
    $regex = $regex.Replace('\*\*/', "`u{1}").Replace('\*\*', "`u{2}").Replace('\*', '[^/]*').Replace('\?', '[^/]')
    '^' + $regex.Replace("`u{1}", '(.*/)?').Replace("`u{2}", '.*') + '$'
}

function New-YamlRule {
    <#
    .SYNOPSIS
        Compiled matching rules for a YAML trigger filter. No include list means everything is included.
    #>
    param([Parameter(Mandatory)] $Filter)

    $rules = [Collections.Generic.List[object]]::new()
    if ($Filter.Include.Count -eq 0) {
        $rules.Add([pscustomobject]@{ Raw = '**'; Regex = [regex]::new('^.*$'); Specificity = 0; Exclude = $false; Implicit = $true })
    }
    foreach ($pattern in $Filter.Include) {
        $rules.Add([pscustomobject]@{ Raw = $pattern; Regex = [regex]::new((ConvertTo-YamlRegex $pattern), 'IgnoreCase'); Specificity = (Get-LiteralPrefix $pattern).Split('/', [StringSplitOptions]::RemoveEmptyEntries).Count; Exclude = $false; Implicit = $false })
    }
    foreach ($pattern in $Filter.Exclude) {
        $rules.Add([pscustomobject]@{ Raw = $pattern; Regex = [regex]::new((ConvertTo-YamlRegex $pattern), 'IgnoreCase'); Specificity = (Get-LiteralPrefix $pattern).Split('/', [StringSplitOptions]::RemoveEmptyEntries).Count; Exclude = $true; Implicit = $false })
    }
    $rules.ToArray()
}

function Test-YamlPathIncluded {
    <#
    .SYNOPSIS
        YAML trigger semantics: order does not matter; the most specific matching include or exclude
        wins, and an exclude wins a tie.
    #>
    param(
        [Parameter(Mandatory)][string] $File,
        [object[]] $Rules
    )

    $include = -1
    $exclude = -1
    foreach ($rule in $Rules) {
        if (-not $rule.Regex.IsMatch($File)) { continue }
        if ($rule.Exclude) { $exclude = [Math]::Max($exclude, $rule.Specificity) }
        else { $include = [Math]::Max($include, $rule.Specificity) }
    }

    if ($include -lt 0) { return $false }
    if ($exclude -lt 0) { return $true }
    $include -gt $exclude
}

function New-PolicyRule {
    <#
    .SYNOPSIS
        Compiled matching rules for a branch policy path filter, with a warning for every entry
        Azure DevOps would not accept or interpret as intended.
    #>
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Pattern
    )

    $rules = [Collections.Generic.List[object]]::new()
    $warnings = [Collections.Generic.List[string]]::new()

    $entries = @($Pattern | Where-Object { $_ } | ForEach-Object { $_ -split ';' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($raw in $entries) {
        $exclude = $raw.StartsWith('!')
        $path = $raw.TrimStart('!').Trim()

        if (-not ($path.StartsWith('/') -or $path.StartsWith('*'))) {
            $warnings.Add("Branch policy entry '$raw' must start with '/' or '*' (optionally after '!'); it is ignored.")
            continue
        }
        if ($path.Contains('\')) {
            $warnings.Add("Branch policy entry '$raw' uses a backslash; only '/' is allowed. It is ignored.")
            continue
        }
        if ($path.Contains('**')) {
            $warnings.Add("Branch policy entry '$raw' contains '**'. In a branch policy a single '*' already matches across folders; use '*'.")
            $path = $path -replace '\*{2,}', '*'
        }

        $relative = $path.TrimStart('/')
        $regex = if (Test-HasWildcard $relative) {
            '^' + [regex]::Escape($relative).Replace('\*', '.*').Replace('\?', '.') + '$'
        }
        else {
            '^' + [regex]::Escape($relative.TrimEnd('/')) + '(/|$)'
        }
        $rules.Add([pscustomobject]@{ Raw = $raw; Regex = [regex]::new($regex, 'IgnoreCase'); Exclude = $exclude; Implicit = $false })
    }

    [pscustomobject]@{ Rules = $rules.ToArray(); Warnings = $warnings.ToArray() }
}

function Test-PolicyPathIncluded {
    <#
    .SYNOPSIS
        Branch policy semantics: entries are evaluated in order and the last match wins. Without any
        include entry, everything not excluded is included.
    #>
    param(
        [Parameter(Mandatory)][string] $File,
        [object[]] $Rules
    )

    if (-not $Rules) { return $true }
    $included = -not ($Rules | Where-Object { -not $_.Exclude })
    foreach ($rule in $Rules) {
        if ($rule.Regex.IsMatch($File)) { $included = -not $rule.Exclude }
    }
    $included
}

#endregion

#region Validation

function Get-ValidationTarget {
    <#
    .SYNOPSIS
        What a filter must cover: the files of every project folder in scope and every required path.
    #>
    param(
        [object[]] $Scope,
        [object[]] $Required,
        [Parameter(Mandatory)][string] $Root
    )

    foreach ($item in $Scope) {
        $files = @(if ($item.Folder) { Get-FileUnder -Root $Root -Folder $item.Folder })
        if ($files.Count -eq 0) { $files = @($item.Project) }
        [pscustomobject]@{
            Display = if ($item.Folder) { "$($item.Folder)/" } else { $item.Project }
            Reason  = "$($item.Kind.ToLowerInvariant()): $($item.Reason)"
            Files   = $files
        }
    }
    foreach ($path in $Required) {
        $files = @(if ($path.IsFolder) { Get-FileUnder -Root $Root -Folder $path.Path } else { $path.Path })
        if ($files.Count -eq 0) { $files = @($path.Path) }
        [pscustomobject]@{
            Display = if ($path.IsFolder) { "$($path.Path)/" } else { $path.Path }
            Reason  = $path.Reason
            Files   = $files
        }
    }
}

function Test-FilterCoverage {
    <#
    .SYNOPSIS
        Compares a filter with the validation targets: every target file must be included (else
        Missing), and every include entry must match at least one target file (else Superfluous).
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Yaml', 'Policy')][string] $Kind,
        [object[]] $Rules,
        [object[]] $Target,
        [Parameter(Mandatory)][string] $Root,
        [string[]] $AllowedExtraPath
    )

    $filterName = if ($Kind -eq 'Yaml') { 'YAML trigger' } else { 'Branch policy' }
    $findings = [Collections.Generic.List[object]]::new()

    foreach ($item in $Target) {
        $unmatched = $null
        foreach ($file in $item.Files) {
            $included = if ($Kind -eq 'Yaml') { Test-YamlPathIncluded -File $file -Rules $Rules } else { Test-PolicyPathIncluded -File $file -Rules $Rules }
            if (-not $included) { $unmatched = $file; break }
        }
        if ($unmatched) {
            $detail = $item.Reason
            if ($item.Display.EndsWith('/')) { $detail += " (not included: $unmatched)" }
            $findings.Add([pscustomobject]@{ Filter = $filterName; Type = 'Missing'; Path = $item.Display; Detail = $detail })
        }
    }

    $allowed = [Collections.Generic.HashSet[string]]::new()
    foreach ($path in $AllowedExtraPath) { $null = $allowed.Add((Get-CanonicalFilter $path)) }
    $targetFiles = @($Target | ForEach-Object { $_.Files } | Select-Object -Unique)

    foreach ($rule in @($Rules | Where-Object { -not $_.Exclude -and -not $_.Implicit })) {
        if ($allowed.Contains((Get-CanonicalFilter $rule.Raw))) { continue }
        $used = $false
        foreach ($file in $targetFiles) {
            if ($rule.Regex.IsMatch($file)) { $used = $true; break }
        }
        if ($used) { continue }

        $prefix = Get-LiteralPrefix $rule.Raw
        $detail = if ($prefix -and -not (Test-Path -LiteralPath (Join-Path $Root $prefix))) {
            "matches no file: '$prefix' does not exist (moved or deleted?)"
        }
        else {
            'matches nothing this pipeline depends on'
        }
        $findings.Add([pscustomobject]@{ Filter = $filterName; Type = 'Superfluous'; Path = $rule.Raw; Detail = $detail })
    }

    $findings.ToArray()
}

function Get-PropertyValue {
    param($Object, [Parameter(Mandatory)][string] $Name)
    foreach ($part in $Name.Split('.')) {
        if ($null -eq $Object) { return $null }
        $property = $Object.PSObject.Properties[$part]
        if (-not $property) { return $null }
        $Object = $property.Value
    }
    $Object
}

function Invoke-PathFilterValidation {
    <#
    .SYNOPSIS
        Validates the YAML trigger and, optionally, the branch policy path filter of one pipeline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Project,
        [Parameter(Mandatory)][string] $PipelineFile,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)] $Config,
        [string[]] $TestProjects,
        [switch] $CheckBranchPolicy,
        [object[]] $Policy,
        [string] $PolicyBranch
    )

    $PipelineFile = ConvertTo-FilterPath $PipelineFile
    $scopeParameters = @{ Project = $Project; Root = $Root; Config = $Config }
    if ($PSBoundParameters.ContainsKey('TestProjects')) { $scopeParameters.TestProjects = $TestProjects }

    $scope = @(Get-ProjectScope @scopeParameters)
    $required = @(Get-RequiredPath -Config $Config -Root $Root -PipelineFile $PipelineFile)
    $expected = @(Get-ExpectedYamlPath -Scope $scope -Required $required)
    $targets = @(Get-ValidationTarget -Scope $scope -Required $required -Root $Root)

    $findings = [Collections.Generic.List[object]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    $checked = [Collections.Generic.List[string]]::new()

    $yamlFile = Join-Path $Root $PipelineFile
    if (-not (Test-Path -LiteralPath $yamlFile)) { throw "Pipeline file '$PipelineFile' does not exist under '$Root'." }
    $trigger = Get-YamlTriggerFilter -Yaml (Get-Content -LiteralPath $yamlFile -Raw)
    if (-not $trigger.HasTrigger) {
        $notes.Add("YAML trigger: 'trigger: none', so there is no CI trigger to check.")
    }
    else {
        $checked.Add('YAML trigger')
        if ($trigger.Include.Count -eq 0) {
            $notes.Add('YAML trigger: no include paths, so every change on the branch triggers this pipeline.')
        }
        foreach ($finding in Test-FilterCoverage -Kind Yaml -Rules (New-YamlRule $trigger) -Target $targets -Root $Root -AllowedExtraPath $Config.allowedExtraPaths) {
            $findings.Add($finding)
        }
    }

    if ($CheckBranchPolicy) {
        $policies = @($Policy | Where-Object { $_ })
        if ($policies.Count -eq 0) {
            $notes.Add("Branch policy: no enabled build validation policy for this pipeline on $PolicyBranch, so pull requests are not validated by it.")
        }
        elseif ($policies.Count -gt 1) {
            $notes.Add("Branch policy: $($policies.Count) enabled build validation policies for this pipeline on $PolicyBranch; cannot tell which applies, so the check is skipped.")
        }
        else {
            $checked.Add('Branch policy')
            $policyRules = New-PolicyRule -Pattern @(Get-PropertyValue $policies[0] 'settings.filenamePatterns')
            foreach ($warning in $policyRules.Warnings) { $notes.Add($warning) }
            if ($policyRules.Rules.Count -eq 0) {
                $notes.Add('Branch policy: no path filter, so every pull request triggers this pipeline.')
            }
            foreach ($finding in Test-FilterCoverage -Kind Policy -Rules $policyRules.Rules -Target $targets -Root $Root -AllowedExtraPath $Config.allowedExtraPaths) {
                $findings.Add($finding)
            }
        }
    }

    [pscustomobject]@{
        Pipeline = $PipelineFile
        Project  = ConvertTo-RepoPath -Path $Project -Root $Root
        Scope    = $scope
        Required = $required
        Expected = $expected
        Findings = $findings.ToArray()
        Notes    = $notes.ToArray()
        Checked  = $checked.ToArray()
    }
}

#endregion

#region Output

function Write-PipelineIssue {
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warning')][string] $Type,
        [Parameter(Mandatory)][string] $Message
    )
    if ($env:TF_BUILD) { Write-Host "##vso[task.logissue type=$Type]$Message" }
}

function Write-ProjectScope {
    param(
        [Parameter(Mandatory)][string] $Project,
        [object[]] $Scope,
        [object[]] $Required
    )

    $rows = @(
        foreach ($group in @(
                @{ Title = 'Dependencies'; Kind = 'Dependency' },
                @{ Title = 'Always in scope'; Kind = 'Configured' },
                @{ Title = 'Tests'; Kind = 'Test' },
                @{ Title = 'Test support'; Kind = 'TestSupport' })) {
            $items = @($Scope | Where-Object Kind -EQ $group.Kind | Sort-Object Project)
            if ($items.Count -eq 0) { continue }
            [pscustomobject]@{ Header = "$($group.Title) ($($items.Count))"; Path = $null; Reason = $null }
            foreach ($item in $items) { [pscustomobject]@{ Header = $null; Path = $item.Project; Reason = $item.Reason } }
        }
        if (@($Required).Count -gt 0) {
            [pscustomobject]@{ Header = "Required paths ($(@($Required).Count))"; Path = $null; Reason = $null }
            foreach ($path in $Required) { [pscustomobject]@{ Header = $null; Path = $path.Path; Reason = $path.Reason } }
        }
    )

    $width = ($rows | Where-Object Path | ForEach-Object { $_.Path.Length } | Measure-Object -Maximum).Maximum
    Write-Host ''
    Write-Host "Scope of $Project"
    foreach ($row in $rows) {
        if ($row.Header) { Write-Host ''; Write-Host "  $($row.Header)"; continue }
        Write-Host ("    {0}  {1}" -f $row.Path.PadRight($width), $row.Reason)
    }
}

function Write-ExpectedPathFilter {
    param(
        [Parameter(Mandatory)][string[]] $Expected,
        [string] $PipelineFile
    )

    $of = if ($PipelineFile) { " of $PipelineFile" } else { '' }
    Write-Host ''
    Write-Host "Minimal YAML trigger path filter$of (trigger > paths > include):"
    Write-Host ''
    Write-Host '  paths:'
    Write-Host '    include:'
    foreach ($path in $Expected) { Write-Host "    - '$path'" }
    Write-Host ''
    Write-Host 'Minimal branch policy path filter (Branch policies > Build validation > this pipeline > Path filter):'
    Write-Host ''
    Write-Host (ConvertTo-PolicyPathFilter -YamlPath $Expected)
    Write-Host ''
}

function Write-PathFilterValidation {
    <#
    .SYNOPSIS
        Prints the findings of one pipeline and returns $true when it failed.
    #>
    param(
        [Parameter(Mandatory)] $Result,
        [switch] $AllowSuperfluous
    )

    $missing = @($Result.Findings | Where-Object Type -EQ 'Missing')
    $superfluous = @($Result.Findings | Where-Object Type -EQ 'Superfluous')
    $failed = $missing.Count -gt 0 -or ($superfluous.Count -gt 0 -and -not $AllowSuperfluous)

    Write-Host ''
    Write-Host "Path filters of $($Result.Pipeline)"
    Write-Host "  Scope of $($Result.Project): $(@($Result.Scope).Count) project(s) and $(@($Result.Required).Count) required path(s)"

    foreach ($filter in $Result.Checked) {
        $items = @($Result.Findings | Where-Object Filter -EQ $filter)
        Write-Host ''
        Write-Host "  $filter"
        if ($items.Count -eq 0) {
            Write-Host '    [OK] nothing missing, nothing superfluous'
            continue
        }
        $width = ($items | ForEach-Object { $_.Path.Length } | Measure-Object -Maximum).Maximum
        foreach ($finding in $items) {
            $label = if ($finding.Type -eq 'Missing') { '[MISSING]    ' } else { '[SUPERFLUOUS]' }
            Write-Host ("    {0} {1}  {2}" -f $label, $finding.Path.PadRight($width), $finding.Detail)
            $type = if ($finding.Type -eq 'Superfluous' -and $AllowSuperfluous) { 'warning' } else { 'error' }
            Write-PipelineIssue -Type $type -Message "$($Result.Pipeline) - $filter - $($finding.Type.ToLowerInvariant()): $($finding.Path) - $($finding.Detail)"
        }
    }

    if ($Result.Notes.Count -gt 0) { Write-Host '' }
    foreach ($note in $Result.Notes) {
        Write-Host "  Note: $note"
        Write-PipelineIssue -Type warning -Message "$($Result.Pipeline) - $note"
    }

    if ($failed) {
        Write-ExpectedPathFilter -Expected $Result.Expected -PipelineFile $Result.Pipeline
    }
    $failed
}

#endregion

#region Azure DevOps

function Resolve-PolicyBranch {
    <#
    .SYNOPSIS
        The branch whose policies to check: the given one, else the pull request target, else the
        branch being built. An unexpanded '$(...)' macro counts as not given.
    #>
    param([string] $Branch)

    foreach ($candidate in @($Branch, $env:SYSTEM_PULLREQUEST_TARGETBRANCH, $env:BUILD_SOURCEBRANCH)) {
        if ($candidate -and -not $candidate.StartsWith('$(')) {
            if ($candidate.StartsWith('refs/')) { return $candidate }
            return "refs/heads/$candidate"
        }
    }
    $null
}

function New-AzDoConnection {
    param(
        [Parameter(Mandatory)][string] $CollectionUri,
        [Parameter(Mandatory)][string] $Project,
        [Parameter(Mandatory)][string] $AccessToken
    )
    [pscustomobject]@{
        BaseUri = "$($CollectionUri.TrimEnd('/'))/$([uri]::EscapeDataString($Project))"
        Headers = @{ Authorization = "Bearer $AccessToken" }
    }
}

function Invoke-AzDoGet {
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)][string] $Path
    )

    $response = Invoke-RestMethod -Uri "$($Connection.BaseUri)/_apis/$Path" -Headers $Connection.Headers -Method Get
    if ($response -is [string]) {
        throw 'Azure DevOps returned HTML instead of JSON: the access token was not accepted.'
    }
    $response
}

function Get-AzDoBuildDefinition {
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)][string] $Id
    )
    Invoke-AzDoGet -Connection $Connection -Path "build/definitions/$($Id)?api-version=7.1"
}

function Get-AzDoYamlDefinitionMap {
    <#
    .SYNOPSIS
        Maps YAML file path to build definition ID for every YAML pipeline of the repository.
    #>
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)][string] $RepositoryId
    )

    $response = Invoke-AzDoGet -Connection $Connection -Path "build/definitions?repositoryId=$RepositoryId&repositoryType=TfsGit&includeAllProperties=true&`$top=1000&api-version=7.1"
    $map = @{}
    foreach ($definition in @($response.value)) {
        $yaml = Get-PropertyValue $definition 'process.yamlFilename'
        if ($yaml) { $map[(ConvertTo-FilterPath $yaml).ToLowerInvariant()] = "$($definition.id)" }
    }
    if (@($response.value).Count -ge 1000) {
        Write-Warning 'The repository has 1000 or more build definitions; only the first 1000 were read.'
    }
    $map
}

function Get-BuildValidationPolicy {
    <#
    .SYNOPSIS
        Enabled build validation policies on one branch of one repository.
    #>
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)][string] $RepositoryId,
        [Parameter(Mandatory)][string] $Branch
    )

    $path = "git/policy/configurations?repositoryId=$RepositoryId&refName=$([uri]::EscapeDataString($Branch))&policyType=$script:BuildValidationPolicyType&api-version=7.2-preview.1"
    @((Invoke-AzDoGet -Connection $Connection -Path $path).value | Where-Object { $_.isEnabled })
}

function Find-AppPipeline {
    <#
    .SYNOPSIS
        The pipelines to validate: from path-filters.json, or every YAML file that passes a .csproj
        through the configured project parameter.
    #>
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)] $Config
    )

    if ($Config.pipelines.Count -gt 0) { return $Config.pipelines }

    $parameter = [regex]::Escape($Config.projectParameter)
    $pattern = "(?m)^\s*(-\s+)?$parameter\s*:\s*['""]?(?<project>[^'""\r\n#]+?\.csproj)['""]?\s*(#.*)?$"
    foreach ($file in @(Get-RepositoryFile -Root $Root | Where-Object { $_ -match '\.ya?ml$' } | Sort-Object)) {
        if (Test-PathUnder -Path $file -Prefix $Config.excludedPipelinePaths) { continue }
        $content = Get-Content -LiteralPath (Join-Path $Root $file) -Raw
        if (-not $content -or $content -notmatch $pattern) { continue }

        $project = $Matches['project'].Trim() -replace '^\$\((Build\.SourcesDirectory|System\.DefaultWorkingDirectory|Build\.Repository\.LocalPath)\)[\\/]', ''
        [pscustomobject]@{ Yaml = $file; Project = ConvertTo-FilterPath $project }
    }
}

#endregion
