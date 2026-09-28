# The gate pipeline

Every pipeline validates its own filters in its own build. That catches most drift — but not the
changes that cause it.

## The blind spot

A path filter can only catch a change that triggers it. Some changes that make a filter wrong are
changes that filter does not cover:

- **A test starts covering a project.** `Billing.Tests` adds a reference to `Orders.Domain`. The
  orders pipeline now has a new test in scope. The pull request touches `tests/Billing.Tests/`, which
  is in no orders filter, so the orders pipeline does not run.
- **A folder is moved.** The filters still name the old folder; nothing under the new folder triggers
  the pipelines that depend on it; none of them runs to notice.
- **A reference is removed.** The project that dropped the reference is still in scope, but its old
  dependency is not — and pipelines whose filters listed that dependency only for this reason do not
  necessarily run. Their stale entries stay, and keep triggering builds for nothing.
- **A filter is edited by hand** in a pipeline that does not trigger on its own file, or in a branch
  policy, which triggers nothing at all.

A new reference *inside* the scope is caught by the pipeline itself: the changed project file is in
its filters, so it runs and its own validation reports the new dependency as missing.

## The fix

One more pipeline, `pipelines/validate-all-path-filters.yml`, that validates **every** pipeline's
filters, attached as **required** build validation on the integration branch, triggered by anything
that can change the project graph:

```
*.csproj; *.props; *.targets; /build/path-filter-guard/*; /pipelines/*
```

- `*.csproj` — the project graph itself, anywhere in the repository (a leading `*` is how a branch
  policy filter matches a file name at any depth).
- `*.props; *.targets` — `Directory.Build.props` and friends can add references to every project.
- `/build/path-filter-guard/*` — a change to the scripts or `path-filters.json`.
- `/pipelines/*` — a change to a pipeline's trigger. Each pipeline also validates itself when its own
  file changes, but the gate catches an edit that breaks the filter of a pipeline that does not
  trigger on its own change.

The pipeline has `trigger: none`: it exists only to run on pull requests.

## Cost

It resolves the references of every project in the repository, in parallel, and reads Azure DevOps
twice. On a repository with around 300 projects that takes a minute or two on a hosted agent, and it
only runs when a project file changes.

## When it fails

The log has one section per failing pipeline with `[MISSING]` and `[SUPERFLUOUS]` lines, the filters
to copy, and a summary at the end:

```
Summary
  [PASS] pipelines/billing-api.yml
  [FAIL] pipelines/orders-api.yml     1 missing, 0 superfluous
  [PASS] pipelines/shipping-worker.yml

2 passed, 1 failed.
```

The author of the pull request fixes the YAML in the same pull request — the Copilot skill in this
repository does that — and updates the branch policy of every failing pipeline with the printed
value. Then rerun the gate.
