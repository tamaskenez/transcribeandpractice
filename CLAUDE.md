For context, see README.md.

We're working on the prototype app. Development loop, per milestone:

1. Pick the first milestone in prototype_app_milestones.md that is not `done`.
2. Clarify: ask questions about functional requirements and acceptance criteria missing from
   prototype_app_spec.md / prototype_app_milestones.md. Each acceptance criterion must state how it
   is verified (automated test, CLI/headless check, or screenshot).
   Technical choices (language, frameworks, libraries) are proposed with rationale in the same step.
3. Write requirements to prototype_app_spec.md, acceptance criteria to prototype_app_milestones.md.
   Set status to `criteria proposed`. Stop and wait for human review.
4. After approval (status `criteria approved`), implement without further check-ins.
   - Minor decisions: decide, record in prototype_app_spec.md under "Decisions".
   - Decisions affecting scope, UX or architecture: stop and ask.
5. Verify every acceptance criterion of this milestone as specified; fix until all pass. Run only
   the checks for this milestone's new or changed features. Do not rerun earlier milestones'
   verification scripts. Use `SKIP_EARLIER=1` where a script chains the earlier ones.
6. Set status to `verified`, note verification results. Stop and report for human review.
7. Apply fixes requested in the review. When the milestone is accepted, set status to `done` and
   merge the milestone branch into master.

Testing: every milestone must be verified, but the prototype does not need a regression test
suite, and earlier milestones are not re-verified. Run an earlier milestone's checks only when the
human asks for it. Throwaway tests that help during development are fine; they don't have to be
kept or maintained.

Git rules:

- Each milestone gets its own branch, created from master when work on the milestone starts.
- Commit work in self-contained units (implement - verify - fix - commit), not one big commit at
  the end.
- Fixes after human review go into separate commits.
- When a milestone is done, merge its branch into master without squashing (`git merge --no-ff`).
