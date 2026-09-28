# Getting started

What you need, in order, to guard the path filters of your pipelines. Steps 1 to 4 take an hour.
Step 5 — fixing the filters the first run finds — depends on how far they have drifted.

## 1. Check the prerequisites

- **SDK-style `.csproj` files.** References are read with `dotnet list reference`, which evaluates
  MSBuild, so references added in `Directory.Build.props` are seen too.
- **PowerShell 7.2 or newer** on the agents (`pwsh: true` in the tasks) and locally.
- **The .NET SDK** on the agents, before the guard runs. `UseDotNet@2` with `useGlobalJson: true` is
  enough; no restore is needed.
- **Git** on the agents. The scripts list files with `git ls-files`, so ignored files (`bin/`,
  `obj/`) never count.

## 2. Copy the files in

| From here | To your repository |
|---|---|
| `build/path-filter-guard/` | the same folder — or another; then update `scriptsFolder` in the template |
| `pipelines/templates/path-filter-guard.yml` | next to your pipeline templates |
| `pipelines/validate-all-path-filters.yml` | next to your pipelines |
| `.github/skills/*`, `.github/instructions/*` | the same folders, if you use GitHub Copilot |

Keep the `tests/` folder: it lets you change the scripts with confidence, and costs nothing at
build time.

## 3. Run it locally first

Without an access token the scripts check the YAML triggers only, which is where you start:

```powershell
pwsh ./build/path-filter-guard/Test-AllPathFilters.ps1 -SkipBranchPolicy
```

It finds pipelines by looking for YAML files that pass a `.csproj` through a parameter named
`projectFile`. If your pipelines call it something else (`publishProject`, `project`), set
`projectParameter` in `path-filters.json`, or list the pipelines explicitly — see
[configuration](configuration.md).

For one pipeline, with the scope and the filters to copy:

```powershell
pwsh ./build/path-filter-guard/Initialize-Scope.ps1 -ProjectFile src/Orders/Api/Orders.Api.csproj -PipelineFile pipelines/orders-api.yml
```

Look at the scope before anything else. If it contains projects that should not be there — an
analyzer every project references, integration tests that run elsewhere — configure them now:
[configuration](configuration.md).

To include the branch policies, give the scripts a token and your organization:

```powershell
$env:SYSTEM_ACCESSTOKEN = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
$repositoryId = az repos show --org https://dev.azure.com/<org> --project <project> --repository <repository> --query id -o tsv
pwsh ./build/path-filter-guard/Test-AllPathFilters.ps1 -CollectionUri https://dev.azure.com/<org>/ -Project <project> -RepositoryId $repositoryId -PolicyBranch main
```

## 4. Add the template to every pipeline

Before restore and build:

```yaml
steps:
- template: templates/path-filter-guard.yml
  parameters:
    projectFile: 'src/Orders/Api/Orders.Api.csproj'
    pipelineFile: 'pipelines/orders-api.yml'
```

The first step prints the scope and the filters on every run — also on green builds, so the right
values are always one click away. It sets `$(TestProjects)`, `$(Dependencies)` and
`$(ProjectsInScope)` for later steps; `$(TestProjects)` is a ready-made `projects` input for
`DotNetCoreCLI@2` that runs only the tests covering this pipeline.

The second step validates both filters and fails the build on anything missing or superfluous. It
reads the branch policy with the job access token; see [the example pipeline](../pipelines/orders-api.yml).

## 5. Fix what the first run finds

Expect findings. Paste the printed YAML list into each pipeline, and the printed one-line value into
each pipeline's branch policy: **Repos > Branches > *your integration branch* > Branch policies >
Build validation > *the pipeline* > Path filter**.

A branch policy applies to every pull request into its branch. Changing a filter changes which
pipelines run for everyone's open pull requests — usually what you want, but say so in the team.

## 6. Add the gate pipeline

A pipeline's own validation only runs when its own filters trigger it. Create a pipeline from
`pipelines/validate-all-path-filters.yml` and add it as **required** build validation on your
integration branch, with this path filter:

```
*.csproj; *.props; *.targets; /build/path-filter-guard/*; /pipelines/*
```

Why this matters, and what it catches that the per-pipeline step cannot:
[the gate pipeline](the-gate-pipeline.md).

## 7. Permissions

The job access token must be able to read build definitions and policy configurations of the
project. In a default project it can. If the validation step fails with 401 or 403, check the
project's pipeline settings — *Limit job authorization scope* — and the permissions of the build
service identity on the project.
