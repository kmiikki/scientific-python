# Development and publication

GitHub’s default branch, `main`, tracks the current development state. Work directly on local `main` and stage, review and commit in small, focused changes. Run relevant tests and preserve the installer’s transaction and ownership safety checks. Record known defects and pending platform acceptance.

## Development session

Begin in the canonical checkout on `main` with a fast-forward-only update.

```bash
git fetch origin
git pull --ff-only origin main
```

During development, stage selected files and review the staged diff. Commit locally once the changes form a coherent unit. Work in progress can remain staged or unstaged.

```bash
git add -- README.md docs/release-checklist.md
git diff --cached
git commit -m "Describe the changes"
```

At the end of the session, report the implementation, tests and commits queued for public `main`. Obtain explicit user approval before running `git push origin main`. Verify the remote commit after the push. GitHub repository settings changes also require explicit user approval.

GitHub’s **Code → Download ZIP** downloads `scientific-python-main.zip` from the current default branch.

## Milestones

A version tag such as `v0.9.0` identifies an exact revision. Obtain separate explicit user approval before creating or pushing a release tag or creating, publishing, modifying, replacing or deleting a GitHub Release. Preserve published tags, artifacts and commit history.

For an approved milestone, record its commit, the tests and platforms verified, and known limitations. Build the release archive from that commit and verify its contents and SHA-256 checksum.
