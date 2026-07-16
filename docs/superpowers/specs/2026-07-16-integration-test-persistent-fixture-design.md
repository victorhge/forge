---
title: Integration Test Persistent Fixture
date: 2026-07-16
status: approved
---

# Integration Test Persistent Fixture

## Problem

The current integration test harness creates a throwaway branch + PR/MR per test
run and deletes them in `unwind-protect`. This produces visible API clutter:
branches and PRs appear in the repo's history even when closed, and a crash
before cleanup leaves orphaned artifacts.

## Goal

Eliminate branch and PR/MR creation/deletion from every test run. Each test run
reuses a single persistent fixture PR (GitHub) and MR (GitLab). Only review
comments — which are low-visibility — are created and deleted per run.

---

## Fixture Structure

- **Branch name**: `forge-itest-fixture` (fixed, on both GitHub and GitLab repos)
- **Target**: `main` (GitHub) / default branch (GitLab)
- **File**: `forge-itest-scratch.txt` with content `"line1\nline2\nline3\n"`
- **PR/MR title**: `"forge-itest fixture (persistent)"`
- The PR/MR is never closed; the branch is never deleted by tests.
- The commit SHA is fetched live from the open PR/MR each time — not hardcoded —
  so it remains correct if the fixture is ever manually re-created.

---

## Lazy-Init Logic (`forge-itest--ensure-pr` / `forge-itest--ensure-mr`)

PR/MR is the primary source of truth. Branch existence is only checked as part
of the creation path.

### GitHub

1. `GET /repos/:owner/:name/pulls?state=open&head=:owner:forge-itest-fixture`
   — if an open PR is found, use it directly and return.
2. No open PR: check `GET /repos/:owner/:name/git/ref/heads/forge-itest-fixture`.
   If 404, create the branch from `main` HEAD and push `forge-itest-scratch.txt`.
3. Open the PR.
4. Return plist `(:number N :commit-sha SHA :path "forge-itest-scratch.txt")`.

### GitLab

1. `GET /projects/:id/merge_requests?state=opened&source_branch=forge-itest-fixture`
   — if an open MR is found, use it directly and return.
2. No open MR: check `GET /projects/:id/repository/branches/forge-itest-fixture`.
   If 404, create branch from default-branch HEAD and push file.
3. Open MR, poll until `diff_refs.head_sha` is non-nil.
4. Return plist `(:iid N :mr-alist ALIST :path "forge-itest-scratch.txt")`.

---

## Test Harness Wrappers

Replace `forge-itest--run-with-pr` and `forge-itest--gl-run-with-mr` with:

```elisp
(defmacro forge-itest--with-fixture-pr (owner name &rest body)
  ;; binds: repo-obj pr-obj commit-sha pr-number path posted-ids
  ...)

(defmacro forge-itest--with-fixture-mr (owner name &rest body)
  ;; binds: repo-obj pr-obj mr-alist mr-iid path posted-ids
  ...)
```

Each macro:
1. Calls `ensure-pr`/`ensure-mr` to get the fixture plist.
2. Wraps body in `forge-itest--with-db` (fresh temp SQLite DB per test — unchanged).
3. Creates DB objects from the fixture plist.
4. Binds `posted-ids` as a `let`-bound list (initially `nil`).
5. Runs body in `unwind-protect`.
6. Teardown: iterates `posted-ids`, deletes each comment via REST.

---

## Comment Tracking

A thin helper pushes comment IDs onto the `posted-ids` list:

```elisp
(defun forge-itest--track (posted-ids comment-alist)
  "Push comment ID onto POSTED-IDS and return COMMENT-ALIST."
  (push (alist-get 'id comment-alist) posted-ids)
  comment-alist)
```

Test bodies wrap write calls:

```elisp
(forge-itest--with-fixture-pr owner name
  (let ((opener (forge-itest--track posted-ids
                  (forge-itest--add-review-comment ...))))
    ...))
```

Teardown REST calls:
- GitHub: `DELETE /repos/:owner/:name/pulls/comments/:id`
- GitLab: `DELETE /projects/:id/merge_requests/:iid/notes/:note_id`

Each delete is wrapped in `(condition-case nil ... (error nil))` so one failure
does not abort the rest.

---

## What Does Not Change

- `forge-itest--with-db` — still uses a fresh temp SQLite DB per test.
- Low-level write helpers (`forge-itest--add-review-comment`, etc.) — unchanged.
- The `FORGE_TEST_GITHUB_REPO` / `FORGE_TEST_GITLAB_REPO` env vars — no new vars needed.
- `scripts/run-integration-tests.sh` — no changes needed.
- The three existing `ert-deftest` bodies — logic unchanged; only the harness
  wrapper and comment-tracking calls change.

---

## Rollout

No migration required. The `forge-itest-fixture` branch and PR/MR are created
automatically on first run by `ensure-pr`/`ensure-mr`. Manual setup is not needed.
