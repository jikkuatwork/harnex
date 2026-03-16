---
name: close
description: Close an issue — update STATE.md, bump version, commit, build & install gem. Use when the user says "close issue", "ship it", "release", or invokes "/close".
---

# Close Issue Workflow

When the user asks to close/ship an issue, run this sequence:

## 1. Update `koder/STATE.md`

- Set the issue status to **fixed** in the issues table
- Add/update the plan entry if one exists
- Update the "Current snapshot" section with a one-liner about the change
- Update test count if tests were added
- Update the "Next step" section (bump version reference, note what was done)

## 2. Bump version

- Read `lib/harnex/version.rb` for the current version
- Bump the patch version (e.g. 0.1.2 → 0.1.3)
- If the change is significant, ask the user about a minor bump

## 3. Commit

- Stage all changed files (implementation, tests, koder docs, version, skills)
- Commit with message format: `<summary of change> (#NN) (vX.Y.Z)`
- Include `Co-Authored-By` trailer

## 4. Build & install gem

```bash
gem build harnex.gemspec && gem install ./harnex-<version>.gem
```

Clean up the `.gem` file after install:

```bash
rm -f harnex-<version>.gem
```

## 5. Verify

- Run `harnex --version` or `ruby -e "require 'harnex'; puts Harnex::VERSION"` to confirm
- Report the installed version to the user

## Notes

- Do NOT push to remote unless the user asks
- Do NOT publish to rubygems unless the user explicitly asks
- If tests haven't been run yet, run them before committing
- If STATE.md is already up to date, skip step 1
