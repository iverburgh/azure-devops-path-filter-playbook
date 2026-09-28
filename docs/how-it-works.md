# How it works

## The scope of a pipeline

A pipeline builds one project — the one passed as `projectFile`. Its **scope** is every project
whose change can change the outcome of that pipeline:

| Kind | What | Shown as |
|---|---|---|
| Dependency | The project and its full, recursive `ProjectReference` graph | `Orders.Api -> Orders.Application -> Orders.Domain` |
| Test | Every test project that directly references a project in that graph | `references Orders.Domain` |
| Test support | Projects in the test folders that those tests reference: fixtures, fakes, helpers | `used by Orders.Api.Tests` |
| Configured | Projects listed in `alwaysInScopeProjects` | `always in scope (path-filters.json)` |

Plus the **required paths** from `requiredPaths`: the pipeline file itself, `Directory.Build.props`,
`global.json` and anything else every pipeline must react to — only those that exist.

A few decisions behind this:

- **References are read with `dotnet list reference`**, not by parsing XML, so references added by
  `Directory.Build.props` or conditions are seen as MSBuild sees them.
- **The graph is walked breadth-first**, so the reason shown for a dependency is its shortest chain.
- **Tests are selected by direct reference.** A test that references `Orders.Domain` covers the
  pipeline that uses `Orders.Domain`. A test that only references something `Orders.Domain` uses
  does not; its own pipeline covers it.
- **Test support stops at the test folders.** A test project also referencing some other production
  project does not pull that project into scope: it is not this pipeline's code.

## From scope to filters

Each project in scope contributes its folder; each required path contributes itself:

```yaml
paths:
  include:
  - 'src/Orders/Api/**'
  - 'src/Orders/Application/**'
  - 'tests/Orders.Api.Tests/**'
  - 'pipelines/orders-api.yml'
```

Folders inside another listed folder are dropped. Groups are sorted — dependencies, configured,
tests, test support, then required paths — so the list diffs cleanly.

The branch policy filter is the same list in the branch policy format: a leading `/`, a single `*`,
separated by `;`:

```
/src/Orders/Api/*; /src/Orders/Application/*; /tests/Orders.Api.Tests/*; /pipelines/orders-api.yml
```

## How each filter is evaluated

The two filters look alike and behave differently. The scripts evaluate each the way Azure DevOps
does:

| | YAML trigger | Branch policy |
|---|---|---|
| Separator | a YAML list | `;` |
| Leading `/` | optional | required (or start with `*`) |
| `*` | any characters **within one folder** | any characters, **across folders** |
| `**` | across folders | not meant to be used; treated as `*` with a warning |
| `?` | one character within a folder | one character |
| Path without wildcard | that path and everything below it | that path and everything below it |
| Exclude | `exclude:` list | prefix `!` |
| Conflicts | the most specific entry wins; an exclude wins a tie; order does not matter | entries apply in order; the last match wins |
| No includes | everything is included | everything not excluded is included |

## What is checked

Both filters get the same two checks:

**Missing.** For every folder in scope, every file in it must be included. Checking files rather
than the folder name is what catches a single `*` that misses subfolders, or an exclude that hides
part of a project. The first file that is not included is shown, so you can see why.

**Superfluous.** Every include entry must match at least one file in scope. An entry that matches
nothing is reported, and when the path it names no longer exists, that is said explicitly — that is
usually a moved folder, whose new location will show up as missing.

Superfluous entries fail the build too, unless you pass `-AllowSuperfluous` or list the entry in
`allowedExtraPaths`. They are cheaper than missing ones — an extra build, not a missed one — but they
are drift all the same, and they accumulate.

## What is not checked

- Files outside every project folder that a build still uses: shared pipeline templates, a
  `nuget.config`, a script. List them in `requiredPaths`.
- Whether a path filter is **too broad**. `src/**` covers everything and is never reported missing;
  it is only reported superfluous if nothing in scope lives under `src/`.
- `pr:` triggers in YAML. Azure Repos ignores them; pull requests are validated through branch
  policies.
- Pipelines that are not .NET builds. Their filters are yours to keep.

## The three scripts

| Script | Where it runs | Needs Azure DevOps | Fails the build |
|---|---|---|---|
| `Initialize-Scope.ps1` | every pipeline, and locally | no | no — prints scope and filters, sets variables |
| `Test-PathFilters.ps1` | every pipeline, and locally | for the branch policy check | yes, for that pipeline's filters |
| `Test-AllPathFilters.ps1` | the gate pipeline, and locally | for the branch policy check | yes, for any pipeline's filters |

All three share `lib/PathFilterGuard.ps1`. `Test-AllPathFilters.ps1` resolves every project's
references once, in parallel, and reads Azure DevOps twice in total: the list of build definitions
and the branch's build validation policies.
