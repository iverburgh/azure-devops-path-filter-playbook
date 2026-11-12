# Configuration

Everything the scripts need to know about your repository lives in
`build/path-filter-guard/path-filters.json`. Every setting is optional. Paths are relative to the
repository root, with forward slashes.

```json
{
  "testProjectPattern": "(?i)tests?\\.csproj$",
  "excludedTestPaths": ["tests/Integration"],
  "testSupportPaths": [],
  "ignoredReferences": ["src/Analyzers/Analyzers.csproj"],
  "alwaysInScopeProjects": ["tests/Analyzers.Tests/Analyzers.Tests.csproj"],
  "requiredPaths": ["{pipelineFile}", "Directory.Build.props", "Directory.Build.targets", "Directory.Packages.props", "global.json", ".editorconfig", "src/Analyzers", "pipelines/templates"],
  "allowedExtraPaths": [],
  "projectParameter": "projectFile",
  "excludedPipelinePaths": ["pipelines/templates"],
  "pipelines": []
}
```

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `testProjectPattern` | `(?i)tests?\.csproj$` | Regular expression on the path of a project file that marks it as a test project. |
| `excludedTestPaths` | none | Test projects under these folders are never in scope — integration or end-to-end tests that run in their own pipeline. |
| `testSupportPaths` | the top-level folders holding test projects, minus those holding the pipeline's own code | Where test helpers live. A project that a selected test references is in scope only if it is under one of these folders. |
| `ignoredReferences` | none | Projects left out of every graph. For projects that `Directory.Build.props` adds to every project, such as a Roslyn analyzer: without this every pipeline would list them. |
| `alwaysInScopeProjects` | none | Projects in the scope of every pipeline, such as the tests of that analyzer. |
| `requiredPaths` | `{pipelineFile}`, `Directory.Build.props`, `Directory.Build.targets`, `Directory.Packages.props`, `global.json` | Files or folders every pipeline must trigger on. `{pipelineFile}` is the pipeline's own YAML file. Entries that do not exist are skipped. |
| `allowedExtraPaths` | none | Filter entries never reported as superfluous. Compared ignoring quotes, a leading `/` and `*` versus `**`, so one entry covers both filters. |
| `projectParameter` | `projectFile` | The YAML key that names a pipeline's project; used to discover pipelines. |
| `excludedPipelinePaths` | none | YAML files under these folders are never treated as pipelines, such as templates that mention the parameter in an example. |
| `pipelines` | discovered | Explicit list, overriding discovery: `[{ "yaml": "pipelines/orders-api.yml", "project": "src/Orders/Api/Orders.Api.csproj" }]`. |

Keys starting with `_` are ignored, so you can leave comments as `"_comment": "..."`. Unknown keys
give a warning.

## Common setups

### Analyzers added to every project

`Directory.Build.props` adds a `ProjectReference` to `src/Analyzers/Analyzers.csproj` everywhere.
Without configuration, every pipeline's scope includes the analyzer, and changing the analyzer
triggers everything — possibly what you want, but then as a deliberate choice:

```json
"ignoredReferences": ["src/Analyzers/Analyzers.csproj"],
"alwaysInScopeProjects": ["tests/Analyzers.Tests/Analyzers.Tests.csproj"],
"requiredPaths": ["{pipelineFile}", "Directory.Build.props", ".editorconfig", "src/Analyzers"]
```

Every pipeline now runs the analyzer's tests and triggers on the analyzer and `.editorconfig`, and no
dependency list is cluttered with it.

### Shared pipeline templates

A change to a template can break every pipeline that uses it. Make it a required path, and keep the
template folder out of pipeline discovery:

```json
"requiredPaths": ["{pipelineFile}", "pipelines/templates", "Directory.Build.props", "global.json"],
"excludedPipelinePaths": ["pipelines/templates"]
```

### Tests next to the code

When test projects live next to their projects (`src/Orders/Orders.Domain.Tests/`), the default
`testSupportPaths` ends up empty — `src` holds the pipeline's own code — and no test helpers are
added. Name the helper folders explicitly:

```json
"testSupportPaths": ["src/TestHelpers"]
```

## Script parameters

| Parameter | Scripts | Default |
|---|---|---|
| `-WorkingDirectory` | all | pipeline sources directory, then the git root, then the current directory |
| `-ConfigPath` | all | `path-filters.json` next to the scripts |
| `-PolicyBranch` | validation scripts | the pull request target branch, then the branch being built |
| `-CollectionUri`, `-Project`, `-RepositoryId` | validation scripts | the predefined pipeline variables |
| `-AccessToken` | validation scripts | `SYSTEM_ACCESSTOKEN` |
| `-BuildDefinitionId` | `Test-PathFilters.ps1` | none; the template passes `$(System.DefinitionId)` |
| `-SkipBranchPolicy` | validation scripts | off |
| `-AllowSuperfluous` | validation scripts | off |

In a pipeline run, a missing access token is an error rather than a silently skipped check.
