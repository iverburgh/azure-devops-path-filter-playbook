# Path filters that follow your project references — for Azure DevOps

[![CI](https://github.com/iverburgh/azure-devops-path-filter-playbook/actions/workflows/ci.yml/badge.svg)](https://github.com/iverburgh/azure-devops-path-filter-playbook/actions/workflows/ci.yml)

In a .NET monorepo on Azure DevOps, every pipeline decides *when* to run from two path filters: the
`trigger > paths` of its YAML file, and the path filter of its branch policy build validation. Both
are hand-written lists of folders. The project references they are supposed to mirror change every
week.

When they drift apart, nothing fails. A pull request that changes a shared library simply does not
build the application that depends on it, and the break shows up after merge — or in production.

This repository makes the drift fail the build instead: PowerShell scripts that calculate what each
pipeline depends on, compare that with **both** filters, report exactly what is missing or
superfluous, and print the filters to copy and paste. Plus the Copilot skill and instructions that
fix the YAML the moment a `ProjectReference` changes.

It grew out of a large .NET monorepo with around 300 projects and 17 application pipelines, where
the approach ran for a long time. The scripts here are a generalised rewrite. Pointed at that
repository, they found things the older validation had missed — test helpers in no filter at all,
single-`*` paths that skipped subfolders, filter entries for folders that no longer existed.

## Start here

| If you want to… | Read |
|---|---|
| Add this to your repository | [docs/getting-started.md](docs/getting-started.md) |
| Understand what "in scope" means and how both filters are evaluated | [docs/how-it-works.md](docs/how-it-works.md) |
| Catch changes that do not trigger the affected pipeline | [docs/the-gate-pipeline.md](docs/the-gate-pipeline.md) |
| Tune it: test folders, analyzers, required paths | [docs/configuration.md](docs/configuration.md) |
| Let Copilot update the filters when references change | [docs/working-with-copilot.md](docs/working-with-copilot.md) |
| **Avoid the mistakes that make path filters silently wrong** | **[docs/pitfalls.md](docs/pitfalls.md)** |

## What it looks like

Every build of every pipeline prints its scope — with the reason each project is in it — and the
minimal filters:

```
Scope of src/Orders/Api/Orders.Api.csproj

  Dependencies (4)
    src/Orders/Api/Orders.Api.csproj                      the project itself
    src/Orders/Application/Orders.Application.csproj      Orders.Api -> Orders.Application
    src/Orders/Domain/Orders.Domain.csproj                Orders.Api -> Orders.Application -> Orders.Domain
    src/Shared/Contracts/Shared.Contracts.csproj          Orders.Api -> Orders.Application -> Shared.Contracts

  Tests (2)
    tests/Orders.Api.Tests/Orders.Api.Tests.csproj        references Orders.Api
    tests/Orders.Domain.Tests/Orders.Domain.Tests.csproj  references Orders.Domain

  Test support (1)
    tests/TestUtilities/TestUtilities.csproj              used by Orders.Api.Tests

Minimal YAML trigger path filter of pipelines/orders-api.yml (trigger > paths > include):

  paths:
    include:
    - 'src/Orders/Api/**'
    - 'src/Orders/Application/**'
    ...

Minimal branch policy path filter (Branch policies > Build validation > this pipeline > Path filter):

/src/Orders/Api/*; /src/Orders/Application/*; /src/Orders/Domain/*; /src/Shared/Contracts/*; ...
```

And when a filter does not match, the build fails with a list you can act on:

```
Path filters of pipelines/orders-api.yml

  YAML trigger
    [MISSING]     src/Orders/Domain/          dependency: Orders.Api -> Orders.Application -> Orders.Domain (not included: src/Orders/Domain/Order.cs)
    [MISSING]     tests/Orders.Api.Tests/     test: references Orders.Api (not included: tests/Orders.Api.Tests/Fakes/FakeClock.cs)
    [SUPERFLUOUS] src/Billing/**              matches nothing this pipeline depends on

  Branch policy
    [MISSING]     tests/TestUtilities/        testsupport: used by Orders.Api.Tests

Result: FAILED. Copy the filters above, or add and remove the listed entries, then rerun.
```

## What's in here

```
build/path-filter-guard/   The scripts, their shared library, configuration and Pester tests
pipelines/                 A steps template for every pipeline, the gate pipeline, an example
.github/skills/            Copilot skills: keep filters in sync, explain a dependency chain
.github/instructions/      Copilot instructions for project files and pipeline trigger paths
docs/                      How it works, how to adopt it, and what goes wrong
tools/                     Checks that keep this repository honest, also run in CI
```

## The short version of what we learned

All explained in [docs/pitfalls.md](docs/pitfalls.md).

- **A pipeline's own validation only runs when its filters trigger it.** Some changes that break a
  filter — a test that starts referencing a project, a moved folder, a removed reference — do not
  trigger the affected pipeline. You need a second, repository-wide check.
- **`*` means something different in the two filters.** In YAML it stays within one folder; in a
  branch policy it crosses folders. `tests/Orders.Tests/*` in YAML silently ignores
  `tests/Orders.Tests/Fakes/`.
- **The branch policy is half the story.** Fixing the YAML does not help a pull request whose build
  validation never starts.
- **Tests are in scope, and so are their helpers.** A change to a shared test fixture can break a
  pipeline's tests without touching a single production project.
- **Superfluous entries are drift too.** A filter entry for a removed reference keeps triggering
  builds for nothing, and an entry for a moved folder hides that the new folder is missing.
- **YAML trigger paths are case-sensitive; branch policies are not.** A wrongly cased entry can pass
  the pull request and never trigger after merge. Take the casing from the repository, not from a
  `ProjectReference`.
- **A project that cannot be read must fail the check.** Treating it as "no references" quietly
  shrinks every scope it is part of, and every check stays green.

## Adapting this to your repository

The scripts work on any repository with SDK-style `.csproj` files and YAML pipelines. What you
decide yourself — which folders hold tests, which projects are added to everything by
`Directory.Build.props`, which files every pipeline should trigger on — lives in one small JSON file.
[docs/getting-started.md](docs/getting-started.md) walks through it.

## Further reading

- [Azure Pipelines triggers: paths](https://learn.microsoft.com/azure/devops/pipelines/repos/azure-repos-git#paths)
  — the YAML trigger path filter reference.
- [Build validation branch policy](https://learn.microsoft.com/azure/devops/repos/git/branch-policies#build-validation)
  — including the path filter.
- [Policy configurations REST API](https://learn.microsoft.com/rest/api/azure/devops/policy/configurations/list)
  — what the scripts read.

## Related playbooks

From the same monorepo, each on its own:

- [Renovate on Azure DevOps](https://github.com/iverburgh/renovate-azure-devops-playbook) —
  automated dependency updates. Its pull requests change project files, which is exactly what the
  gate pipeline here checks.
- [Copilot on Azure DevOps](https://github.com/iverburgh/copilot-azure-devops-playbook) —
  instructions, skills and agents for a repository like this one, including how skills such as the
  ones here are written.
- [Azure App Configuration](https://github.com/iverburgh/azure-app-configuration-playbook) —
  configuration as code, deployed and rolled back together with the application.
- [Domain-Driven Design in .NET](https://github.com/iverburgh/ddd-dotnet-playbook) — bounded
  contexts with their own projects and dependencies: the structure that makes per-context path
  filters possible.

## License

MIT — see [LICENSE](LICENSE).
