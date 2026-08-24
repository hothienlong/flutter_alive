# Issue Creation Checklist

## Repository Setup

- [ ] Create milestones `v0.1`, `v0.5`, `v1.0`, and `v1.1`.
- [ ] Create the type, priority, platform, and component labels listed in the
  project plan.
- [ ] Create a GitHub Project with statuses `Backlog`, `Ready`, `In Progress`,
  `Review`, `Testing`, and `Done`.
- [ ] Add `Priority`, `Release`, `Component`, `Platform`, `Estimate`, and
  `Parent` fields.

## Work Items

- [ ] Create E1 and E2 epic issues first.
- [ ] Create feature issues and link each to its parent epic.
- [ ] Create stories, enablers, and tests from the backlog table.
- [ ] Replace backlog IDs with GitHub issue numbers in parent checklists.
- [ ] Add `Blocked by` and `Blocks` links for every dependency.
- [ ] Put P0 items and their prerequisites on the critical path view.

## Quality Gate

- [ ] Every item satisfies the Definition of Ready before moving to `Ready`.
- [ ] Pull requests reference their issue with `Closes #<number>` when complete.
- [ ] Test issues contain exact commands or hardware steps and expected output.
- [ ] Release epics cannot close while required hardware or coverage gates are
  incomplete.
- [ ] Completed issues satisfy the shared Definition of Done.

See [github-project-plan.md](github-project-plan.md) for the full hierarchy,
acceptance criteria, dependencies, estimates, labels, and risks.
