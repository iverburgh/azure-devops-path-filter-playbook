---
name: dependency-tree
description: >-
  Show the ProjectReference tree of a .NET project as an ASCII tree, optionally only the paths to one
  dependency. Use when asked why a project depends on another, why a project is in a pipeline's scope,
  or why a path filter validation reports a folder as missing. Triggers on 'dependency tree',
  'why does X depend on Y', 'dependency chain', 'project references', 'why is this in scope'.
---

# Dependency tree

Visualise the `ProjectReference` tree of a .NET project.

## Workflow

### 1. Find the projects

From the question, determine:

- the **root project** whose tree to show — find its `.csproj` with a file search such as
  `**/*Orders.Api*.csproj`;
- optionally the **target dependency** to explain.

### 2. Run the script from the repository root

```powershell
# Full tree
./.github/skills/dependency-tree/scripts/Get-DependencyTree.ps1 -ProjectFile <path/to/Project.csproj>

# Only the paths to one dependency
./.github/skills/dependency-tree/scripts/Get-DependencyTree.ps1 -ProjectFile <path/to/Project.csproj> -TargetDependency <part of name or path>
```

Needs the .NET SDK: references are read with `dotnet list reference`, so references added through
`Directory.Build.props` are included.

### 3. Present the result

- The tree in a code block.
- For a filtered tree: explain the chain in words, and whether the dependency is direct or
  transitive.
- When the chain runs through a shared project, say so: a narrower dependency there would shrink the
  scope of every pipeline that uses it.

## Example

```
Dependency tree of Orders.Api
============================================================

Filtered on paths to: Shared.Contracts
------------------------------------------------------------

Orders.Api
├── Orders.Application
│   └── Shared.Contracts  <<<
└── Orders.Infrastructure
    └── Shared.Contracts  <<<

Dependency chain(s):
  Orders.Api -> Orders.Application -> Shared.Contracts
  Orders.Api -> Orders.Infrastructure -> Shared.Contracts
```
