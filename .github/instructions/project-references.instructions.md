---
description: 'When a ProjectReference changes, the path filters of every affected pipeline change with it.'
applyTo: '**/*.csproj, **/Directory.Build.props, **/Directory.Build.targets'
---

# Project references and path filters

Adding, removing or changing a `ProjectReference` — or moving or renaming a project — changes the
scope of every pipeline that pulls in this project, directly or transitively. The path filter guard
fails those pipelines until their filters follow.

When you change a reference in this file, in the same change:

1. Load the `path-filter-sync` skill.
2. Run `pwsh ./build/path-filter-guard/Test-AllPathFilters.ps1 -SkipBranchPolicy` and fix every
   `[MISSING]` and `[SUPERFLUOUS]` entry in the YAML triggers it reports.
3. Tell the user which branch policy path filters must change, with the exact one-line value to
   paste per pipeline. You cannot change branch policies from the repository.

Do not add a reference only to reach one type: a reference pulls the whole target project, and
everything it references, into the scope of every pipeline above it. Check the effect with the
`dependency-tree` skill when in doubt.
