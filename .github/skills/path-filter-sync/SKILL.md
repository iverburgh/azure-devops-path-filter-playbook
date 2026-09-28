---
name: path-filter-sync
description: >-
  Keep Azure DevOps path filters in sync with .NET project references. Use it WHENEVER a
  ProjectReference is added, removed or changed, a project is moved or renamed, a test project gains
  a reference, or a path filter validation fails: the YAML trigger paths of every affected pipeline
  and their branch policy build validation path filters must change with it. Triggers on 'path
  filter', 'trigger paths', 'branch policy path filter', 'Validate path filters', 'MISSING',
  'SUPERFLUOUS', 'ProjectReference added', 'ProjectReference removed', 'moved project'.
---

# Path filter sync

Every .NET pipeline has **two** path filters, and the path filter guard fails the build when either
does not match the project reference graph:

| Filter | Where | Can an agent change it? |
|---|---|---|
| YAML trigger | the pipeline's YAML file, `trigger > paths > include` | **Yes** — it is a file in the repository |
| Branch policy | Azure DevOps > Repos > Branches > *integration branch* > Branch policies > Build validation > *pipeline* > Path filter | **No** — tell the user the exact value to paste |

A pipeline's scope is: the project it builds, its full recursive `ProjectReference` graph, every test
project that directly references a project in that graph, and the projects those tests reference
(test helpers). Plus the required paths from `build/path-filter-guard/path-filters.json` — the
pipeline file itself, `Directory.Build.props` and similar.

**Golden rule:** a changed `ProjectReference` changes the scope of every pipeline that pulls in that
project, directly or transitively. Both filters of all of those pipelines must follow.

## Step 1 — Find the affected pipelines

Run the guard for all pipelines. Without an access token it checks the YAML triggers only, which is
what you can fix:

```powershell
pwsh ./build/path-filter-guard/Test-AllPathFilters.ps1 -SkipBranchPolicy
```

Each pipeline gets `[PASS]` or `[FAIL]`, and every failing one lists:

- `[MISSING]` — a folder in scope that the filter does not include, with the reason it is in scope
  (for example `dependency: Orders.Api -> Orders.Application -> Orders.Domain`);
- `[SUPERFLUOUS]` — a filter entry that matches nothing the pipeline depends on, typically after a
  reference was removed or a folder moved.

It then prints the minimal filters to copy. To see one pipeline:

```powershell
pwsh ./build/path-filter-guard/Initialize-Scope.ps1 -ProjectFile <project.csproj> -PipelineFile <pipeline.yml>
```

To see **why** a project is in scope, use the `dependency-tree` skill.

## Step 2 — Fix the YAML triggers

Prefer replacing the whole `include` list with the list the script printed: it is sorted and minimal.
When you edit by hand:

- one entry per project folder: `'src/<path>/<Project>/**'`;
- use `**` — a single `*` does **not** cross folders in a YAML trigger, so
  `'tests/Orders.Tests/*'` misses `tests/Orders.Tests/Helpers/Fixture.cs`;
- forward slashes, single quotes, no leading slash;
- remove entries reported as superfluous, unless they are listed in `allowedExtraPaths`.

## Step 3 — Tell the user about the branch policy

The branch policy filter lives in Azure DevOps, not in the repository. Always end with:

1. the exact one-line value the script printed after *Minimal branch policy path filter*;
2. where to paste it: Repos > Branches > *integration branch* > Branch policies > Build validation >
   *the pipeline* > Path filter;
3. that the build stays red until the policy is updated, even after the YAML is fixed;
4. that the policy applies to every open pull request into that branch.

Branch policy format: entries separated by `;`, each starting with `/` (or `*`), optionally
prefixed by `!` to exclude, **single** `*` only — in a branch policy `*` already crosses folders.

## Step 4 — Verify

Run step 1 again: every pipeline must show `[PASS]`. In the pull request, rerun the pipelines after
the branch policy is updated.

## Pitfalls

- Fixing only the YAML is not enough; the branch policy is validated as well.
- Forgetting the test project folder, or a helper project that the tests reference.
- Shared contract projects are referenced by many pipelines: one new reference can affect pipelines
  nobody thinks of. Trust the script, not intuition.
- A project added to every project through `Directory.Build.props` (an analyzer, for example) belongs
  in `ignoredReferences`, or every pipeline would list it.
