---
description: 'Conventions for trigger path filters in Azure Pipelines YAML files.'
applyTo: 'pipelines/**/*.yml, pipelines/**/*.yaml, **/azure-pipelines*.yml'
---

# Pipeline trigger paths

The `trigger > paths > include` list of a .NET pipeline is validated against its project references
by the path filter guard (`build/path-filter-guard/`). Keep it exactly what the guard expects:

- **Generate, do not guess.** Run
  `pwsh ./build/path-filter-guard/Initialize-Scope.ps1 -ProjectFile <project> -PipelineFile <this file>`
  and use the list it prints.
- One entry per project folder, ending in `/**`: `'src/Orders/Api/**'`. A single `*` does not cross
  folders in a YAML trigger.
- Forward slashes, single quotes, no leading slash.
- Include the pipeline file itself and the required paths from `path-filters.json`.
- Nothing else. Every entry must match something the pipeline depends on; extra entries are reported
  as superfluous unless listed in `allowedExtraPaths`.
- Excludes win over includes of the same depth, and a more specific path wins over a less specific
  one — order does not matter in YAML.
- Keep the template call's `projectFile:` parameter on its own line: the gate pipeline uses it to
  find this pipeline.

Every change here has a counterpart in the pipeline's branch policy path filter in Azure DevOps. Give
the user the one-line value to paste (the guard prints it); the repository cannot change it.
