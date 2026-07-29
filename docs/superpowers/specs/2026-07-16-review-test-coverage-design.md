---
title: Review Test Coverage Expansion
date: 2026-07-16
status: approved
---

# Review Test Coverage Expansion

## Goal

Expand test coverage for `forge-review.el` write-side operations. Current tests only
cover the fetch/mapping path (`forge--update-pullreq-review-comments`). This adds:

1. Three unit tests in `forge-review-test.el` that close identified gaps in the
   interactive-command layer.
2. Ten integration tests in `forge-review-integration-test.el` that exercise the five
   write generics against real GitHub and GitLab APIs with re-fetch verification.

---

## Part 1: Unit test gaps (`forge-review-test.el`)

### Gap 1 — `forge--set-review-thread-resolved` coordinator not tested as a unit

`forge-review-write-resolve-updates-resolved-p-in-db` (line 1055) calls the generic
directly and then manually `(oset opener resolved-p t)`. The coordinator
`forge--set-review-thread-resolved` — which calls the generic AND sets `resolved-p`
as a combined operation — is never exercised. Replace that test with a new one that
calls the coordinator and asserts both effects.

Because `forge--set-review-thread-resolved` reads the opener via
`(magit-section-value-if 'review-comment)`, it requires a Magit section tree in scope.
This is handled by the shared helper below.

### Gap 2 — `forge-discard-review-comment-at-point` section dispatch untested

The function extracts the RC via `(magit-section-value-if 'review-comment)`. No test
exercises this dispatch. Need one test that places point inside a `review-comment`
section and calls the interactive command, asserting the DB row is removed.

### Gap 3 — `forge-resolve/unresolve-review-thread` full path untested

Both commands delegate to `forge--set-review-thread-resolved`. No test exercises the
full path: section dispatch → generic call → DB update. Need two tests (resolve and
unresolve) each asserting both the captured API call and the updated DB row.

### Shared helper

All three gaps use the same section-dispatch pattern. Extract it as a macro:

```elisp
(defmacro forge-test--with-section-at-rc (rc &rest body)
  "Run BODY with point inside a review-comment section whose value is RC."
  (declare (indent 1))
  `(with-temp-buffer
     (magit-insert-section (topicbuf)
       (magit-insert-section section (review-comment ,rc)
         (insert "thread\n")))
     (goto-char (point-min))
     (forward-line)
     ,@body))
```

### New / replaced tests

| Test name | Action | Replaces |
|---|---|---|
| `forge-review-write-set-thread-resolved-calls-api-and-updates-db` | calls coordinator, asserts mutation + `resolved-p t` in DB | replaces L1055 |
| `forge-review-write-discard-at-point-removes-row` | places point in section, calls interactive, asserts row gone | new |
| `forge-review-write-resolve-at-point-calls-api-and-updates-db` | `forge-resolve-review-thread` via section, asserts `resolveReviewThread` + `resolved-p t` | new |
| `forge-review-write-unresolve-at-point-calls-api-and-updates-db` | `forge-unresolve-review-thread` via section, asserts `unresolveReviewThread` + `resolved-p nil` | new |

The old test `forge-review-write-resolve-updates-resolved-p-in-db` is deleted; its
intent is fully subsumed by the new coordinator test.

---

## Part 2: Integration tests (`forge-review-integration-test.el`)

### Design principles

- Each test calls the **production `cl-defmethod`** for the generic directly (not the
  interactive command), then re-fetches from the live API to assert the state change
  is visible. This is the same pattern as the existing integration tests.
- The production `forge--rest` / `forge--query` inside the methods are synchronous when
  no `:callback` is provided, so they work in batch mode.
- All tests run inside `forge-itest--with-fixture-pr` / `forge-itest--with-fixture-mr`
  which clear stale comments at setup and delete posted comments at teardown via
  `posted-ids`.
- Comment IDs are tracked manually via `push` onto `posted-ids` (not `forge-itest--record`)
  for operations that return API response alists. For operations that delete, nothing
  is pushed (the teardown's delete would 404, which is already silently handled).

### New helper: `forge-itest--gh-pr-comments`

```elisp
(defun forge-itest--gh-pr-comments (owner name pr-number)
  "Return the list of review comments on PR-NUMBER."
  (forge-itest--gh "GET"
    (format "/repos/%s/%s/pulls/%s/comments" owner name pr-number)))
```

Already exists as part of `forge-itest--clear-pr-comments`; extract it as a named
helper so tests can re-fetch without clearing.

### GitHub tests (5)

**`forge-itest-github-post-reply`**
- Setup: post one opener via REST helper; insert opener into DB with `their-id` and
  `database-id` from API response; call `forge--review-post-reply` with repo-obj,
  pr-obj, opener-rc, and body text.
- Assert: re-fetch comments; find the comment whose `in_reply_to_id` matches
  opener's `database-id`; assert its body equals the text passed.
- Teardown: both IDs in `posted-ids`.

**`forge-itest-github-delete-comment`**
- Setup: post one comment via REST helper; insert into DB; call
  `forge--review-delete-comment` with repo-obj, pr-obj, and the RC.
- Assert: re-fetch comments; assert no comment with that `id` exists.
- Teardown: nothing pushed (already deleted).

**`forge-itest-github-post-comment`**
- Setup: call `forge--review-post-comment` with repo-obj, pr-obj, body, path, `'new`, 3.
- Assert: re-fetch comments; find comment with that body; assert `path` and `line`
  match; assert `side` is `"RIGHT"`.
- Teardown: push returned comment `id` onto `posted-ids`.
- Note: `forge--review-post-comment` returns the API response alist via `forge--rest`;
  capture it to extract the ID for teardown.

**`forge-itest-github-resolve-thread`**
- Setup: post opener; insert into DB with `discussion-id` = GraphQL thread ID (must
  re-fetch via `forge-itest--graphql-review-threads` after posting to get the node ID);
  call `forge--review-set-thread-resolved` with `resolved=t`.
- Assert: re-fetch via `forge-itest--graphql-review-threads`; find thread; assert
  `isResolved = t`.
- Teardown: opener ID in `posted-ids`; thread is left resolved (harmless, cleared next run).

**`forge-itest-github-submit-review`**
- Setup: create two pending `forge-pullreq-review-comment` rows in the DB (with
  `pending-p t`, realistic `new-path`, `new-line`, `body`, `database-id 0`); insert
  them; call `forge--review-submit` with repo-obj and pr-obj.
- Assert: re-fetch comments; assert both bodies appear; assert both have `pending-p`
  nil on the DB rows after submit.
- Teardown: collect returned comment IDs from the re-fetch by body match; push onto
  `posted-ids`.
- Note: `forge--review-submit` calls `forge--github-flush-pending-review-comments`
  internally, setting `pending-p nil` — assert this happened in the DB.

### GitLab tests (5)

**`forge-itest-gitlab-post-reply`**
- Setup: post one discussion via `forge-itest--gl-add-review-comment`; extract
  `disc-id` and opener note `database-id`; insert opener RC into DB; call
  `forge--review-post-reply` with repo-obj, pr-obj, opener-rc, and body text.
- Assert: re-fetch discussions; find the discussion; assert the second note's body
  equals the text passed.
- Teardown: push opener note ID and reply note ID onto `posted-ids`.

**`forge-itest-gitlab-delete-comment`**
- Setup: post one discussion; extract opener note ID and `database-id`; insert RC into
  DB with that `database-id`; call `forge--review-delete-comment`.
- Assert: re-fetch discussions; assert no note with that ID exists in any discussion.
- Teardown: nothing pushed (already deleted).

**`forge-itest-gitlab-post-comment`**
- Setup: call `forge--review-post-comment` with repo-obj, pr-obj, body, path, `'new`, 3.
- Assert: re-fetch discussions; find discussion with that body in the first note; assert
  position `new_line = 3` and `new_path = path`.
- Teardown: push opener note ID from the returned response alist onto `posted-ids`.
- Note: `forge--review-post-comment` returns the discussion alist; extract the opener
  note ID as `(alist-get 'id (car (alist-get 'notes result)))`.

**`forge-itest-gitlab-resolve-thread`**
- Setup: post one discussion; extract `disc-id`; insert opener RC into DB with
  `discussion-id = disc-id`; call `forge--review-set-thread-resolved` with `resolved=t`.
- Assert: re-fetch discussions; find that discussion; assert `resolved = t`.
- Teardown: push opener note ID onto `posted-ids`.

**`forge-itest-gitlab-submit-review`**
- Setup: create two pending RC rows in the DB (with correct SHAs from `pr-obj` slots
  `base-sha`, `base-rev`, `head-rev`); insert them; call `forge--review-submit`.
- Assert: re-fetch discussions; assert two inline discussions appear with the correct
  bodies; assert DB rows have `pending-p nil` after submit.
- Teardown: collect note IDs from re-fetched discussions by body match; push onto
  `posted-ids`.

### Key implementation notes

- **`forge--review-post-comment` return value**: on GitHub, `forge--rest` with no
  `:callback` returns the parsed alist; capture it. On GitLab, same. Use this to
  extract the note ID for teardown rather than re-fetching.
- **`forge-itest-github-resolve-thread` requires two fetches**: one REST fetch to post
  the comment (getting `database-id`), then one GraphQL fetch to get the `discussion-id`
  (thread node ID) needed by `forge--review-set-thread-resolved`. Both are already
  available as helpers (`forge-itest--add-review-comment` and
  `forge-itest--graphql-review-threads`).
- **`forge-itest-gitlab-submit-review`** pending rows must use the PR's actual SHAs
  (from `pr-obj` slots), not hardcoded values, otherwise GitLab rejects the position.
- **No new env vars or script changes** needed.

---

## What does not change

- `forge-review-test.el` structure outside the four affected tests.
- The persistent fixture (`forge-itest-fixture` branch/PR/MR) — no new fixtures needed.
- `scripts/run-integration-tests.sh` — no changes.
- `forge-review.el`, `forge-github.el`, `forge-gitlab.el` — tests only, no production
  code changes.
