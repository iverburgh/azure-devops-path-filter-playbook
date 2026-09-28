# Working with Copilot

The build tells you when a filter is wrong. With GitHub Copilot in VS Code, the filters can be right
before you push: an instruction that fires when you edit a project file, and a skill that knows the
procedure.

## What is included

| File | Loaded | Does |
|---|---|---|
| [project-references.instructions.md](../.github/instructions/project-references.instructions.md) | automatically, when Copilot edits a `.csproj`, `Directory.Build.props` or `Directory.Build.targets` | Tells Copilot that a changed reference means changed path filters, in the same change |
| [pipeline-triggers.instructions.md](../.github/instructions/pipeline-triggers.instructions.md) | automatically, when Copilot edits a pipeline YAML file | The conventions for trigger paths: generate them, `/**`, no extras |
| [path-filter-sync](../.github/skills/path-filter-sync/SKILL.md) skill | on demand, when a task is about path filters or references | Run the guard, fix the YAML, report the branch policy values |
| [dependency-tree](../.github/skills/dependency-tree/SKILL.md) skill | on demand, for "why is this in scope" | Draws the reference tree, or only the chains to one project |

The instruction globs assume pipelines under `pipelines/`; adjust `applyTo` to your layout.

## What it looks like

You ask Copilot to add a reference:

> Let `Orders.Application` use the date helpers from `Shared.Time`.

Copilot adds the `ProjectReference`. Because it edited a `.csproj`, the project-references
instruction is in its context, so it continues:

1. runs `Test-AllPathFilters.ps1 -SkipBranchPolicy`;
2. sees `[MISSING] src/Shared/Time/` for the orders API and the orders worker — two pipelines, because
   both use `Orders.Application`;
3. updates both YAML trigger lists;
4. ends with the branch policy values to paste for both pipelines, and a reminder that the pull
   request stays red until they are updated.

## Why the branch policy stays manual

Branch policies live in Azure DevOps, not in the repository, and apply to everyone's pull requests
into that branch. An agent could change them through the REST API — but a policy change is shared,
immediate and outside version control, so the skill hands the exact value to a person instead of
applying it.

## Asking why

When a pipeline's scope contains something surprising:

> Why does the orders API depend on Shared.Serialization?

The dependency-tree skill answers with the chain, and points out when it runs through a shared
project — a hint that a narrower reference there would shrink the scope of every pipeline above it:

```
Orders.Api
└── Orders.Application
    └── Shared.Contracts
        └── Shared.Serialization  <<<

Dependency chain(s):
  Orders.Api -> Orders.Application -> Shared.Contracts -> Shared.Serialization
```
