# Pitfalls

The mistakes that make path filters silently wrong, and the ones we made building the guard.

## Filters

### A single `*` in YAML does not cross folders

`'tests/Orders.Tests/*'` in a YAML trigger matches `tests/Orders.Tests/OrderTests.cs` and nothing in
`tests/Orders.Tests/Fakes/`. A change to a fake does not trigger the pipeline. Use
`'tests/Orders.Tests/**'`.

The same entry in a branch policy, `/tests/Orders.Tests/*`, does cross folders. So a pipeline with
`*` in YAML runs on the pull request but not after merge — the worst combination, because the pull
request looks fine.

The older validation this playbook replaced did not catch this: it matched with an unanchored
regular expression, so `.../Orders.Tests/` matched any file below it. Checking **every file** against
the filter, anchored, found it in several pipelines at once.

### `**` in a branch policy

Azure DevOps shows it without complaint, but a branch policy uses a single `*` for "anything,
including folders". The guard warns and treats it as `*`.

### Branch policy entries must start with `/`

`src/Orders/*` without a leading slash is not a valid branch policy entry. The guard warns and
ignores it — as a pipeline would.

### Write folders in a branch policy as `/folder/*`

The [branch policy documentation](https://learn.microsoft.com/azure/devops/repos/git/branch-policies#use-path-filters-with-branch-policies)
only shows folders with a trailing `/*` and files with their full path; it does not say what an entry
without a wildcard, such as `/src/Orders`, matches. The guard reads it as that path and everything
below it, like a YAML trigger path. Do not rely on that: the printed filter always uses `/*`, so
copy it as is.

### YAML trigger paths are case-sensitive

The [trigger documentation](https://learn.microsoft.com/azure/devops/pipelines/repos/azure-repos-git#paths)
says so: use the same casing as the real folders. Branch policies are
[not case-sensitive](https://learn.microsoft.com/azure/devops/repos/git/branch-policies#are-the-required-code-reviewer-paths-case-sensitive). So
`src/orders/**` in YAML can look fine, pass a pull request through the branch policy, and still
never trigger after merge. You may find that a wrongly cased entry happens to work today; treat the
documented behaviour as the contract.

The casing usually comes from a `ProjectReference` typed in another casing than the folder on disk —
Windows does not care, so nobody notices. The guard takes the casing from the repository, and reports
an entry that differs only in casing as both missing and superfluous, with a note saying why.

### Fixing the YAML is half the fix

The YAML trigger decides whether a pipeline runs after merge. The branch policy decides whether it
runs on the pull request. Validating one and not the other leaves the other half free to drift, and
the policy is the one nobody looks at because it is not in the repository.

### A branch policy is shared

It applies to every pull request into its branch. Updating a path filter changes which pipelines run
for pull requests already open. That is almost always what you want; mention it anyway.

## Scope

### Tests are in scope

If a pipeline runs a test project, a change to that test project can break the pipeline. So every
test project referencing a project in scope must be in the filter — including tests owned by
another team that happen to reference a shared project.

### Test helpers are in scope too

Test projects reference fixture and fake projects that no production project knows about. They sat
in no filter at all in the repository this was built on. A change to a shared fixture broke tests in
pipelines that never ran. The guard adds projects from the test folders that selected tests
reference.

It deliberately stops at the test folders: a test that references an unrelated production project
does not make that project part of this pipeline.

### Projects that reference nothing fall outside every scope

A test utility project that references no production project is never reached from any pipeline's
graph. If it is only used by tests, it becomes test support once a selected test references it; if
nothing references it, no pipeline builds it — and its own tests run nowhere. The guard cannot find
what nothing points at; look for projects that appear in no scope.

### `Directory.Build.props` adds references everywhere

An analyzer referenced from `Directory.Build.props` is a dependency of every project. Left alone, it
appears in every scope and every filter. Put it in `ignoredReferences`, and add its folder and tests
as required paths and always-in-scope projects instead — one explicit decision rather than a
hundred copies.

### Configuration outside project folders

`.editorconfig`, `global.json`, `Directory.Packages.props`, shared pipeline templates — none of them
belong to a project, and all of them can break a build. They are only checked if they are in
`requiredPaths`.

## Detection

### A filter can only catch what triggers it

The per-pipeline validation runs when the pipeline runs. A test that starts referencing a project, a
moved folder or a removed reference changes the scope of pipelines that the pull request does not
trigger. Without a repository-wide check on project file changes, that drift is found only after
merge. See [the gate pipeline](the-gate-pipeline.md).

### Superfluous entries hide missing ones

When a folder moves, the old entry matches nothing and the new folder is in no filter. Reporting only
missing entries shows half of that; reporting the superfluous one too, with "does not exist", tells
you it moved.

### A project that cannot be read must fail the check

The first version asked `dotnet list reference` per project and treated a failed call as "no
references". A project file with a merge conflict marker or a typo then silently dropped out of
every graph — with its own references — and every check passed with a smaller scope. The MSBuild scan
fails the whole run instead, with the MSBuild error. A reference to a project that is not in the
repository gives a warning.

## Reading references with MSBuild

One `dotnet msbuild` run over `lib/ScanProjectReferences.proj` evaluates every project, which is
several times faster than one `dotnet list reference` call per project. It injects a small target
into each project through MSBuild's extension points. Things to know if you change it:

### Multi-targeted projects need the cross-targeting hook

A project with `<TargetFrameworks>` (plural) is first evaluated without a target framework, and that
evaluation does not import `CustomAfterMicrosoftCommonTargets`. The injected target is then missing
and MSBuild fails with MSB4057. The scan sets `CustomAfterMicrosoftCommonCrossTargetingTargets` to
the same file.

### References that depend on the target framework are not seen

For a multi-targeted project the scan reads the outer evaluation, so a `ProjectReference` with a
condition on `$(TargetFramework)` is not in the result. Put such a project in
`alwaysInScopeProjects`, or make the reference unconditional.

### The scan overrides your own extension point

If your repository already sets `CustomAfterMicrosoftCommonTargets` (or the cross-targeting
variant), the scan replaces it for its own run. That only matters if your file adds project
references; then those are not seen.

### Run it from the repository root

So `global.json` selects the same SDK as your build. No restore is needed: evaluation does not need
packages.

## Azure DevOps API

### Read policies per repository and branch

`_apis/git/policy/configurations` without filters returns every policy in the project, paginated;
on a large project the one you need may not be on the first page. Filter with `repositoryId`,
`refName` and `policyType` (build validation is `0609b952-1397-4640-95ec-e00a01b2c241`).

### An HTML page with status 200

When the token is not accepted, some endpoints return the sign-in page with status 200 instead of
401. The guard treats a string response as an authentication failure instead of "no policies".

### A missing token must fail, not skip

If `SYSTEM_ACCESSTOKEN` is not mapped into the step, a script that quietly checks only the YAML looks
green forever. In a pipeline run the guard throws instead; locally it warns and checks the YAML.

## PowerShell

### One-element arrays unroll

`$files = if ($folder) { @(Get-ChildItem ...) }` gives a string, not an array, when there is one file,
and `.Count` then fails under strict mode. Wrap the whole expression: `@(if (...) { ... })`.
