# Browser-Pending Review Comment Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make forge correctly handle GitHub review comments that were created in the browser but not yet submitted — storing them as local pending comments so the existing stage/submit/discard machinery works on them.

**Architecture:** The root cause is that `forge--update-pullreq-review-comments` hardcodes `:pending-p nil` for every pulled comment, ignoring GitHub's `pullRequestReview.state = "PENDING"`. Since pending comments are author-only (GitHub API returns them only to the review author), any `PENDING` comment forge pulls belongs to the current user. The fix has three parts: (1) set `pending-p t` when `state = pending` during pull mapping; (2) fix the submit path so it submits the *existing* GitHub pending review (via `submitPullRequestReview`) rather than creating a new one (via `addPullRequestReview`) when browser-drafted comments are present; (3) fix the discard path so discarding a browser-pending comment deletes it via the API using its real `their-id` before removing the local row, rather than treating it as a locally-only-staged comment. GitLab has no API-level pending concept, so no GitLab changes are needed.

**Tech Stack:** Emacs Lisp, EIEIO, closql/emacsql, GitHub GraphQL API, ERT test suite.

## Global Constraints

- Run `make test` (ERT suite, `tests/forge-review-test.el`) after every task — all 92+ tests must pass.
- Never call `ghub-request` directly; use `forge--rest` / `forge--query`.
- New slot columns appended to end of `forge-pullreq` slot list only — no schema version bump needed here (we are modifying `forge-pullreq-review-comment` mapping logic, not the DB schema).
- `pending-p` on a row means "user owns this comment and it has not been submitted to the forge API." Browser-drafted comments pulled from GitHub satisfy this exactly.
- All write-method callbacks follow the `(:callback ... :errorback (forge--post-submit-errorback))` protocol.
- Dispatch pattern: generics declared in `forge-review.el`, methods implemented in `forge-github.el`. No `if (github-p repo)` guards in `forge-review.el`.
- `forge-pullreq-review-comment` slots: `id their-id discussion-id number pullreq new-path old-path new-line old-line diff-hunk outdated-p resolved-p reply-to review-state author body created updated reactions pending-p` (see `forge-db.el` lines 480–504 and `forge-review.el` lines 26–50).

---

## Background: The Three Scenarios

After this plan, there are three kinds of review comment rows:

| Kind | `pending-p` | `their-id` | `discussion-id` | Meaning |
|---|---|---|---|---|
| **Locally staged** | `t` | `nil` | `nil` | Typed in forge, not yet sent to API |
| **Browser-pending** | `t` | non-nil node ID | non-nil thread ID | Authored in browser, review not submitted |
| **Submitted** | `nil` | non-nil node ID | non-nil thread ID | Visible to all reviewers |

The distinction between locally-staged and browser-pending is detectable via `their-id`: locally staged rows always have `their-id nil`; browser-pending rows have a real GitHub node ID.

---

### Task 1: Set `pending-p t` for GitHub browser-pending comments during pull

**What changes:** `forge-github.el` — `forge--update-pullreq-review-comments` method.

**Files:**
- Modify: `lisp/forge-github.el` (around line 1420)
- Test: `tests/forge-review-test.el`

**Interfaces:**
- Consumes: `state2` local variable (already computed at line 1394 as `(intern (downcase ...))` — value `'pending` when GitHub returns `"PENDING"`)
- Produces: DB rows with `pending-p t` when `state2 == 'pending`, `pending-p nil` otherwise

- [ ] **Step 1: Write a failing test**

  In `tests/forge-review-test.el`, after the existing `forge-review-api-github-review-state-stored` test (around line 839), add:

  ```elisp
  (ert-deftest forge-review-api-github-pending-review-state-sets-pending-p ()
    "A thread from a PENDING review is stored with pending-p t and their-id set."
    (forge-test--with-db
      (let* ((repo    (forge-test--make-repo))
             (pr      (forge-test--make-pullreq repo))
             (payload (copy-tree forge-test--github-thread-payload)))
        ;; Override review state to PENDING on both comments in the thread.
        (setf (alist-get 'state (alist-get 'pullRequestReview (nth 0 (alist-get 'comments payload))))
              "PENDING")
        (setf (alist-get 'state (alist-get 'pullRequestReview (nth 1 (alist-get 'comments payload))))
              "PENDING")
        (forge--update-pullreq-review-comments repo pr (list payload))
        (let* ((all    (oref pr review-comments))
               (opener (seq-find (lambda (c) (null (oref c reply-to))) all))
               (reply  (seq-find (lambda (c) (oref c reply-to)) all)))
          (should (eq (oref opener pending-p) t))
          (should (eq (oref reply   pending-p) t))
          ;; their-id must be preserved — these are browser-pending, not locally staged.
          (should (equal (oref opener their-id) "RC_node1"))
          (should (equal (oref reply  their-id) "RC_node2"))))))
  ```

- [ ] **Step 2: Run the failing test**

  ```sh
  cd /home/Build/yren/.emacs.d/elpa/forge
  make test 2>&1 | grep -E "FAILED|PASSED|forge-review-api-github-pending"
  ```

  Expected: `forge-review-api-github-pending-review-state-sets-pending-p  FAILED`

- [ ] **Step 3: Implement the fix**

  In `lisp/forge-github.el`, locate line 1420 (the `:pending-p nil` line inside `forge--update-pullreq-review-comments`). Change:

  ```elisp
                      :pending-p    nil)
  ```

  to:

  ```elisp
                      :pending-p    (eq state2 'pending))
  ```

- [ ] **Step 4: Run the full test suite**

  ```sh
  make test 2>&1 | tail -5
  ```

  Expected: all tests pass (no FAILED lines).

- [ ] **Step 5: Commit**

  ```sh
  git add lisp/forge-github.el tests/forge-review-test.el
  git commit -m "fix: set pending-p t for browser-pending GitHub review comments on pull"
  ```

---

### Task 2: Fix the submit path — use `submitPullRequestReview` when browser-pending comments exist

**Context:** Currently `forge--review-submit` (GitHub) always calls `addPullRequestReview` with new thread inputs. But if the user already has an in-progress pending review on GitHub (browser-drafted comments), those comments are *already attached to an existing review node* on GitHub. Calling `addPullRequestReview` again creates a *second* review, leaving the browser-drafted threads as a separate unsubmitted review. The correct approach is to detect browser-pending rows (those with non-nil `their-id`) and submit the *existing* review via `submitPullRequestReview` (using the review's node ID), then separately send any locally-staged threads (nil `their-id`) either by adding them to the existing review first or by submitting them as a separate review.

The simplest correct implementation: if there are browser-pending rows, look up the review node ID from the first one's `pullRequestReview` context — but that isn't stored. Instead, use GitHub's `submitPullRequestReview` mutation which takes `(pullRequestId, event, body)` and no thread list; it submits *all pending threads already on the review*. Then send locally-staged (nil `their-id`) threads as a new `addPullRequestReview` afterwards, or bundle them in advance.

**Practical design decision:** The cleanest path is:

1. Split pending rows into `browser-pending` (non-nil `their-id`) and `local-staged` (nil `their-id`).
2. If `browser-pending` is non-empty: first add any `local-staged` threads to the existing review using `addPullRequestReviewThread` (the same mutation used by `forge-add-single-review-comment`), *then* call `submitPullRequestReview`. If `browser-pending` is empty: use the existing `addPullRequestReview` path (unchanged).
3. After the final submit mutation's callback: flush all pending rows and re-pull topic.

However, `submitPullRequestReview` needs the *review node ID*, which we don't store. We need to query it. GitHub GraphQL: `pullRequest { reviews(last: 1, states: [PENDING]) { nodes { id } } }`.

To keep the scope of this task bounded, we store the pending review node ID as a new slot `pending-review-id` on `forge-pullreq`, populated during pull when PENDING comments are present. That requires a DB schema bump only if we add the column; since `base-sha` and `review-comments` were appended via `ALTER TABLE` at the end of the slot list, we follow the same pattern.

**Files:**
- Modify: `lisp/forge-review.el` — add `pending-review-id` slot to `forge-pullreq-review-comment`? No — store it on the `forge-pullreq` object to reflect that it's review-level, not comment-level.

  Actually: rather than a schema change, we can derive the review node ID at submit time by querying GitHub. This avoids a schema version bump.

  **Revised approach (no schema change):**
  - Add a new `cl-defgeneric forge--review-fetch-pending-review-id (repo pr &key callback errorback)` in `forge-review.el`.
  - In `forge-github.el`: implement this generic. It first queries for the existing pending review ID via GraphQL, then (a) adds each local-staged thread via `addPullRequestReviewThread` sequentially, then (b) calls `submitPullRequestReview`.
  - Adjust `forge--review-submit` (GitHub) to call this new path when browser-pending rows exist.

  Actually the simplest correct solution: query the pending review ID at submit time with a single GraphQL call, then proceed. The query is:

  ```graphql
  query ($id: ID!) {
    node(id: $id) {
      ... on PullRequest {
        reviews(last: 1, states: [PENDING]) { nodes { id } }
      }
    }
  }
  ```

  Where `$id = (oref pr their-id)`.

**Files:**
- Modify: `lisp/forge-review.el` (add generic declaration)
- Modify: `lisp/forge-github.el` (`forge--review-submit` method and new helper)
- Test: `tests/forge-review-test.el`

**Interfaces:**
- Consumes (Task 1): `pending-p t` rows split by `their-id` nil vs non-nil
- Produces: `submitPullRequestReview` mutation called when browser-pending rows exist; `addPullRequestReview` called only for purely-local pending rows

- [ ] **Step 1: Write a failing test for the browser-pending submit path**

  In `tests/forge-review-test.el`, add after the existing `forge-review-github-submit-pending` test:

  ```elisp
  (ert-deftest forge-review-github-submit-with-browser-pending ()
    "When browser-pending rows exist, submit queries for review ID then calls submitPullRequestReview."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             ;; One browser-pending row (their-id set) and one locally-staged (their-id nil).
             (_bp  (forge-test--make-review-comment
                    pr :id "bp-1" :pending-p t :their-id "RC_node1"
                    :discussion-id "RT_thread1" :body "Browser draft" :new-line 5))
             (_ls  (forge-test--make-review-comment
                    pr :id "ls-1" :pending-p t :their-id nil
                    :body "Local stage" :new-line 7 :new-path "src/foo.el")))
        (forge-itest--with-sync-rest
          (let* ((query-calls  nil)
                 (mutate-calls nil))
            (cl-letf (((symbol-function 'forge--query)
                       (lambda (_obj query vars &rest _)
                         (push (list query vars) query-calls)
                         ;; Return a fake pending review ID for the lookup query,
                         ;; and nil for the addPullRequestReviewThread mutation.
                         (if (string-match-p "PENDING" (format "%s" query))
                             '((node (reviews (nodes ((id . "PRR_review1"))))))
                           nil)))
                      ((symbol-function 'forge--rest)
                       (lambda (&rest args) (push args mutate-calls))))
              (forge--review-submit repo pr)
              ;; Should have queried for the pending review ID.
              (should (= (length query-calls) 1))
              ;; All pending rows flushed.
              (should (null (seq-filter (lambda (rc) (oref rc pending-p))
                                        (oref pr review-comments))))))))))
  ```

  > Note: This test is intentionally coarse — the exact mock shape will be refined in the implementation step. The key invariant is (a) a GraphQL query for `PENDING` reviews fires, and (b) all pending rows are flushed.

- [ ] **Step 2: Run the failing test**

  ```sh
  make test 2>&1 | grep -E "FAILED|forge-review-github-submit-with-browser-pending"
  ```

  Expected: `FAILED`

- [ ] **Step 3: Add the generic declaration in `forge-review.el`**

  In `lisp/forge-review.el`, after the `forge--review-submit` generic (around line 132), add:

  ```elisp
  (cl-defgeneric forge--review-fetch-pending-review-id (repo pr &key callback errorback)
    "Fetch the node ID of the current user's pending review on PR, or nil.
  Calls CALLBACK with the ID string (or nil) as its sole argument.")
  ```

- [ ] **Step 4: Implement `forge--review-fetch-pending-review-id` for GitHub**

  In `lisp/forge-github.el`, after `forge--review-submit` (after line ~1457), add:

  ```elisp
  (cl-defmethod forge--review-fetch-pending-review-id
    ((_repo forge-github-repository) pr &key callback errorback)
    "Query GitHub for the ID of the current user's PENDING review on PR."
    (forge--query pr
      '(query
        [(id $id ID!)]
        (node
         [(id $id)]
         (... on PullRequest
              (reviews [(last 1) (states [PENDING])]
                       (nodes id)))))
      `((id . ,(oref pr their-id)))
      :callback  (lambda (data _headers _status _req)
                   (let* ((nodes (alist-get 'nodes
                                  (alist-get 'reviews
                                   (alist-get 'node data)))))
                     (funcall callback (and nodes (alist-get 'id (car nodes))))))
      :errorback errorback))
  ```

- [ ] **Step 5: Rewrite `forge--review-submit` for GitHub to branch on browser-pending**

  In `lisp/forge-github.el`, replace the existing `forge--review-submit` method body (lines ~1440–1457) with:

  ```elisp
  (cl-defmethod forge--review-submit ((_repo forge-github-repository) pr)
    "Submit pending review comments for PR to GitHub."
    (let* ((repo          (forge-get-repository pr))
           (all-pending   (seq-filter (lambda (rc) (oref rc pending-p))
                                      (oref pr review-comments)))
           (browser-pending (seq-filter (lambda (rc) (oref rc their-id)) all-pending))
           (local-staged    (seq-remove  (lambda (rc) (oref rc their-id)) all-pending))
           (local-threads   (forge--github-pending-review-threads-from local-staged)))
      (if browser-pending
          ;; Path A: an existing pending review lives on GitHub.
          ;; 1. Fetch its node ID.
          ;; 2. Add any locally-staged threads to it.
          ;; 3. Submit it.
          (forge--review-fetch-pending-review-id repo pr
            :callback  (lambda (review-id)
                         (forge--github-add-threads-then-submit
                          repo pr review-id local-threads all-pending))
            :errorback (forge--post-submit-errorback))
        ;; Path B: only locally-staged rows — use existing addPullRequestReview.
        (forge-mutate pr addPullRequestReview
          ((pullRequestId (oref pr their-id))
           (event "COMMENT")
           (body  "")
           (and local-threads (threads (vconcat local-threads))))
          :callback  (lambda (&rest _)
                       (forge--github-flush-pending-review-comments pr)
                       (when local-threads
                         (forge--pull-topic repo pr)))
          :errorback (forge--post-submit-errorback))
        (when forge--query-synchronous
          (forge--github-flush-pending-review-comments pr)
          (when local-threads
            (forge--pull-topic repo pr))))))
  ```

- [ ] **Step 6: Add `forge--github-pending-review-threads-from` helper**

  In `lisp/forge-github.el`, rename the existing `forge--github-pending-review-threads` (line ~1425) to `forge--github-pending-review-threads-from` and update it to accept an explicit list rather than reading from the PR:

  ```elisp
  (defun forge--github-pending-review-threads-from (rcs)
    "Return RCS as GraphQL DraftPullRequestReviewThread input alists."
    (mapcar (lambda (rc)
              (let* ((left-p (and (oref rc old-line) (null (oref rc new-line))))
                     (path   (if left-p (or (oref rc old-path) (oref rc new-path))
                               (oref rc new-path)))
                     (line   (if left-p (oref rc old-line) (oref rc new-line)))
                     (side   (if left-p "LEFT" "RIGHT")))
                (delq nil (list (cons 'path path)
                                (cons 'line line)
                                (cons 'side side)
                                (cons 'body (oref rc body))))))
            rcs))
  ```

  Update the two callers that used `forge--github-pending-review-threads`:
  - `forge--submit-approve-pullreq` (line ~1057) — change `forge--github-pending-review-threads` calls to `(forge--github-pending-review-threads-from (seq-filter ...))`. Actually those callers use `forge--github-pending-review-comments` (the REST format, not GraphQL). Double-check both functions and update only the GraphQL one.

  ```elisp
  ;; Old helper kept for REST approve/request-changes path — rename to clarify:
  ;; forge--github-pending-review-comments  →  kept as-is (returns REST format)
  ;; forge--github-pending-review-threads   →  renamed to forge--github-pending-review-threads-from
  ```

- [ ] **Step 7: Add `forge--github-add-threads-then-submit` helper**

  In `lisp/forge-github.el`, add after the fetch method:

  ```elisp
  (defun forge--github-add-threads-then-submit (repo pr review-id threads all-pending)
    "Add THREADS to an existing GitHub review REVIEW-ID, then submit it.
  ALL-PENDING is the full list of pending rows to flush on success."
    (cl-labels
        ((add-next (remaining)
           (if remaining
               (let ((t1 (car remaining)))
                 (forge--query pr
                   `(mutation
                     [(input $input AddPullRequestReviewThreadInput!)]
                     (addPullRequestReviewThread
                      [(input $input)]
                      (thread id)))
                   `((input
                      (pullRequestReviewId . ,review-id)
                      (path . ,(alist-get 'path t1))
                      (line . ,(alist-get 'line t1))
                      (side . ,(alist-get 'side t1))
                      (body . ,(alist-get 'body t1))))
                   :callback  (lambda (&rest _) (add-next (cdr remaining)))
                   :errorback (forge--post-submit-errorback)))
             ;; All threads added — now submit the review.
             (forge--query pr
               `(mutation
                 [(input $input SubmitPullRequestReviewInput!)]
                 (submitPullRequestReview
                  [(input $input)]
                  (pullRequestReview id)))
               `((input
                  (pullRequestReviewId . ,review-id)
                  (event . "COMMENT")
                  (body  . "")))
               :callback  (lambda (&rest _)
                            (dolist (rc all-pending) (closql-delete rc))
                            (forge--pull-topic repo pr))
               :errorback (forge--post-submit-errorback)))))
      (if forge--query-synchronous
          ;; In synchronous mode callbacks are suppressed; use direct iteration.
          (progn
            (dolist (t1 threads)
              (forge--query pr
                `(mutation
                  [(input $input AddPullRequestReviewThreadInput!)]
                  (addPullRequestReviewThread [(input $input)] (thread id)))
                `((input
                   (pullRequestReviewId . ,review-id)
                   (path . ,(alist-get 'path t1))
                   (line . ,(alist-get 'line t1))
                   (side . ,(alist-get 'side t1))
                   (body . ,(alist-get 'body t1))))))
            (forge--query pr
              `(mutation
                [(input $input SubmitPullRequestReviewInput!)]
                (submitPullRequestReview [(input $input)] (pullRequestReview id)))
              `((input
                 (pullRequestReviewId . ,review-id)
                 (event . "COMMENT")
                 (body  . ""))))
            (dolist (rc all-pending) (closql-delete rc))
            (forge--pull-topic repo pr))
        (add-next threads))))
  ```

- [ ] **Step 8: Update `forge--github-pending-review-comments` to exclude browser-pending rows from REST approve payload**

  In `lisp/forge-github.el`, in `forge--github-pending-review-comments` (line ~1032), change the filter to exclude rows where `their-id` is non-nil (browser-pending rows already exist on GitHub and must not be duplicated in the approve POST):

  ```elisp
  (defun forge--github-pending-review-comments (topic)
    "Return locally-staged pending review-comment rows for TOPIC as REST `comments' alist.
  Excludes browser-pending rows (their-id non-nil) since those already exist on GitHub."
    (mapcar (lambda (rc)
              (let* ((left-p (and (oref rc old-line) (null (oref rc new-line))))
                     (path   (if left-p (or (oref rc old-path) (oref rc new-path))
                               (oref rc new-path)))
                     (line   (if left-p (oref rc old-line) (oref rc new-line)))
                     (side   (if left-p "LEFT" "RIGHT")))
                (list (cons 'path path)
                      (cons 'line line)
                      (cons 'side side)
                      (cons 'body (oref rc body)))))
            (seq-filter (lambda (rc) (and (oref rc pending-p)
                                          (null (oref rc their-id))))
                        (oref topic review-comments))))
  ```

  Verify `forge--github-flush-pending-review-comments` still flushes *all* pending rows (both browser-pending and locally-staged) — it uses `(oref rc pending-p)` without a `their-id` filter, so leave it unchanged.

- [ ] **Step 9: Run the full test suite**

  ```sh
  make test 2>&1 | tail -10
  ```

  Expected: all tests pass. The new test from Step 1 should now pass.

- [ ] **Step 10: Commit**

  ```sh
  git add lisp/forge-review.el lisp/forge-github.el tests/forge-review-test.el
  git commit -m "fix: submit browser-pending GitHub review via submitPullRequestReview"
  ```

---

### Task 3: Fix the discard path for browser-pending comments

**Context:** `forge-discard-review-comment` (forge-review.el line 156) branches on `pending-p`:
- `pending-p t` → local-only delete (no API call). **Wrong for browser-pending**: these have real `their-id` on GitHub, so the API comment should be deleted too.
- `pending-p nil` → API delete first via `forge--review-delete-comment`, then local delete.

The fix: add a third branch — if `pending-p t` AND `their-id` non-nil, call `forge--review-delete-comment` then `(closql-delete rc)`. If `pending-p t` AND `their-id` nil (purely local), keep the existing local-only path.

**Files:**
- Modify: `lisp/forge-review.el` (`forge-discard-review-comment`)
- Test: `tests/forge-review-test.el`

**Interfaces:**
- Consumes (Task 1): `pending-p t`, `their-id` non-nil on browser-pending rows

- [ ] **Step 1: Write a failing test**

  In `tests/forge-review-test.el`, add after the existing discard tests:

  ```elisp
  (ert-deftest forge-review-discard-browser-pending-calls-api ()
    "Discarding a browser-pending comment (pending-p t, their-id set) calls the delete API."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (rc   (forge-test--make-review-comment
                    pr :pending-p t :their-id "RC_node1" :number 201)))
        (let ((delete-called nil))
          (cl-letf (((symbol-function 'forge--review-delete-comment)
                     (lambda (_repo _pr _rc &key callback _errorback)
                       (setq delete-called t)
                       (funcall callback nil nil nil nil))))
            (forge-itest--with-sync-rest
              (forge-discard-review-comment rc)))
          (should delete-called)
          ;; Row should be gone from DB.
          (should (null (closql-get (forge-db) (oref rc id) 'forge-pullreq-review-comment)))))))

  (ert-deftest forge-review-discard-local-staged-skips-api ()
    "Discarding a locally-staged comment (pending-p t, their-id nil) does NOT call the API."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (rc   (forge-test--make-review-comment pr :pending-p t :their-id nil)))
        (let ((delete-called nil))
          (cl-letf (((symbol-function 'forge--review-delete-comment)
                     (lambda (&rest _) (setq delete-called t))))
            (forge-discard-review-comment rc))
          (should-not delete-called)
          (should (null (closql-get (forge-db) (oref rc id) 'forge-pullreq-review-comment)))))))
  ```

- [ ] **Step 2: Run the failing tests**

  ```sh
  make test 2>&1 | grep -E "forge-review-discard"
  ```

  Expected: `forge-review-discard-browser-pending-calls-api  FAILED`
  `forge-review-discard-local-staged-skips-api  PASSED` (this already works)

- [ ] **Step 3: Implement the fix in `forge-review.el`**

  Locate `forge-discard-review-comment` (line ~152). Replace:

  ```elisp
  (defun forge-discard-review-comment (rc)
    "Delete review comment RC from the database and the forge API.
  For pending (not-yet-submitted) comments only the local DB row is
  removed.  For submitted comments the forge API is called first."
    (if (oref rc pending-p)
        (progn
          (closql-delete rc)
          (forge-refresh-buffer))
      (when-let* ((pr   (closql-get (forge-db) (oref rc pullreq) 'forge-pullreq))
                  (repo (forge-get-repository pr)))
        (forge--review-delete-comment repo pr rc
          :callback  (lambda (&rest _)
                       (closql-delete rc)
                       (forge-refresh-buffer))
          :errorback (forge--post-submit-errorback)))))
  ```

  With:

  ```elisp
  (defun forge-discard-review-comment (rc)
    "Delete review comment RC from the database and the forge API.
  For locally-staged pending comments (pending-p t, their-id nil) only the
  local DB row is removed.  For browser-pending comments (pending-p t,
  their-id non-nil) and for submitted comments, the forge API is called first."
    (if (and (oref rc pending-p) (null (oref rc their-id)))
        (progn
          (closql-delete rc)
          (forge-refresh-buffer))
      (when-let* ((pr   (closql-get (forge-db) (oref rc pullreq) 'forge-pullreq))
                  (repo (forge-get-repository pr)))
        (forge--review-delete-comment repo pr rc
          :callback  (lambda (&rest _)
                       (closql-delete rc)
                       (forge-refresh-buffer))
          :errorback (forge--post-submit-errorback)))))
  ```

- [ ] **Step 4: Run the full test suite**

  ```sh
  make test 2>&1 | tail -10
  ```

  Expected: all tests pass including both new discard tests.

- [ ] **Step 5: Commit**

  ```sh
  git add lisp/forge-review.el tests/forge-review-test.el
  git commit -m "fix: call delete API when discarding browser-pending review comment"
  ```

---

### Task 4: Display badge for browser-pending comments

**Context:** `forge--review-comment-heading` (forge-review.el line 230) shows `[pending]` only when `(oref rc pending-p)`. After Task 1, browser-pending rows will have `pending-p t`, so they will automatically pick up the badge. However, it may be useful to distinguish "local draft" from "browser draft" in the heading. This task verifies the badge appears and optionally differentiates the label.

**Files:**
- Modify: `lisp/forge-review.el` (if label differentiation is wanted)
- Test: `tests/forge-review-test.el`

**Interfaces:**
- Consumes (Task 1): `pending-p t` on browser-pending rows; `their-id` non-nil distinguishes browser vs local

- [ ] **Step 1: Write a test verifying the `[pending]` badge appears on browser-pending rows**

  In `tests/forge-review-test.el`, add:

  ```elisp
  (ert-deftest forge-review-display-pending-badge-on-browser-pending ()
    "A browser-pending comment heading includes [pending]."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (rc   (forge-test--make-review-comment
                    pr :pending-p t :their-id "RC_node1" :author "alice"
                    :created "2026-07-19T10:00:00Z")))
        (let ((heading (forge--review-comment-heading rc)))
          (should (string-match-p "\\[pending\\]" heading))))))
  ```

- [ ] **Step 2: Run the test**

  ```sh
  make test 2>&1 | grep "forge-review-display-pending-badge"
  ```

  Expected: `PASSED` immediately (Task 1 already made `pending-p t` for browser-pending rows, so the badge logic already works).

  If it fails, check that `forge--review-comment-heading` is exported and testable; see line ~230 of `forge-review.el`.

- [ ] **Step 3: No code change needed if test passes**

  If the test passes with no changes, the badge is automatically correct from Task 1.

  If differentiation between `[local draft]` and `[pending]` is desired, change `forge--review-comment-heading` in `lisp/forge-review.el` around line 230:

  ```elisp
  (when (oref rc pending-p)
    (if (oref rc their-id)
        (push "[pending]" badges)      ; browser-drafted, not yet submitted
      (push "[local draft]" badges)))  ; staged in forge, not yet sent
  ```

  But only make this change if the user confirms the label distinction is wanted — skip for now.

- [ ] **Step 4: Commit (even if no code changed — commit the test)**

  ```sh
  git add tests/forge-review-test.el
  git commit -m "test: verify pending badge on browser-pending review comments"
  ```

---

### Task 5: Guard edit path for browser-pending comments

**Context:** `forge-edit-review-comment` (line 446) uses `forge-review--save-comment-edit` which calls `(oset rc body body)` — local DB only. For browser-pending rows, editing locally is useful as long as the comment hasn't been submitted yet — the current body will be sent on next submit. No API interaction needed until submit.

**Conclusion:** No code change needed. This task is a verification step only.

- [ ] **Step 1: Write a test confirming edit stores body locally for browser-pending**

  ```elisp
  (ert-deftest forge-review-edit-browser-pending-stores-body-locally ()
    "Editing a browser-pending comment updates the body in the DB without an API call."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (rc   (forge-test--make-review-comment
                    pr :pending-p t :their-id "RC_node1" :body "Original")))
        (let ((api-called nil))
          (cl-letf (((symbol-function 'forge--query) (lambda (&rest _) (setq api-called t)))
                    ((symbol-function 'forge--rest)   (lambda (&rest _) (setq api-called t))))
            (oset rc body "Updated body")
            (closql-insert (forge-db) rc t))
          (should-not api-called)
          (let ((fetched (closql-get (forge-db) (oref rc id) 'forge-pullreq-review-comment)))
            (should (equal (oref fetched body) "Updated body")))))))
  ```

- [ ] **Step 2: Run the test**

  ```sh
  make test 2>&1 | grep "forge-review-edit-browser-pending"
  ```

  Expected: `PASSED` (no code change needed).

- [ ] **Step 3: Commit the test**

  ```sh
  git add tests/forge-review-test.el
  git commit -m "test: edit browser-pending comment stores body locally, no API call"
  ```

---

### Task 6: Pull-time deduplication — don't overwrite locally-staged rows with browser-pending rows

**Context:** `forge--update-pullreq-review-comments` uses `(closql-insert ... t)` (replace-if-exists). Locally-staged rows have synthetic IDs (`pending-<float-time>`-derived). Browser-pending rows from GitHub get IDs derived from the real `their-id`. These two sets have different IDs so they can never collide. This task is a verification step to confirm the invariant holds.

- [ ] **Step 1: Write a test confirming locally-staged rows survive a pull that returns browser-pending rows**

  ```elisp
  (ert-deftest forge-review-pull-preserves-locally-staged-rows ()
    "Pulling browser-pending threads does not delete locally-staged (their-id nil) rows."
    (forge-test--with-db
      (let* ((repo    (forge-test--make-repo))
             (pr      (forge-test--make-pullreq repo))
             ;; Insert a locally-staged row.
             (staged  (forge-test--make-review-comment
                       pr :id "local-staged-1" :pending-p t :their-id nil :body "Mine"))
             (payload (copy-tree forge-test--github-thread-payload)))
        ;; Override the thread to be PENDING (browser-pending).
        (setf (alist-get 'state (alist-get 'pullRequestReview
                                  (nth 0 (alist-get 'comments payload))))
              "PENDING")
        (forge--update-pullreq-review-comments repo pr (list payload))
        ;; Locally-staged row must still exist.
        (let ((fetched (closql-get (forge-db) "local-staged-1" 'forge-pullreq-review-comment)))
          (should fetched)
          (should (equal (oref fetched body) "Mine"))
          (should (oref fetched pending-p))))))
  ```

- [ ] **Step 2: Run the test**

  ```sh
  make test 2>&1 | grep "forge-review-pull-preserves-locally-staged"
  ```

  Expected: `PASSED` (no code change needed).

- [ ] **Step 3: Commit the test**

  ```sh
  git add tests/forge-review-test.el
  git commit -m "test: pull of browser-pending threads does not clobber locally-staged rows"
  ```

---

## Summary of All Code Changes

| File | Change |
|---|---|
| `lisp/forge-github.el` | `forge--update-pullreq-review-comments`: `:pending-p (eq state2 'pending)` instead of hardcoded `nil` |
| `lisp/forge-github.el` | `forge--github-pending-review-comments`: filter to nil `their-id` only (exclude browser-pending from REST approve payload) |
| `lisp/forge-github.el` | Rename `forge--github-pending-review-threads` → `forge--github-pending-review-threads-from` accepting explicit list |
| `lisp/forge-github.el` | `forge--review-submit`: branch on browser-pending rows; use `submitPullRequestReview` path |
| `lisp/forge-github.el` | Add `forge--github-add-threads-then-submit` helper |
| `lisp/forge-review.el` | Add `forge--review-fetch-pending-review-id` generic |
| `lisp/forge-github.el` | Add `forge--review-fetch-pending-review-id` GitHub method |
| `lisp/forge-review.el` | `forge-discard-review-comment`: branch on `their-id` to decide API-first vs local-only |
| `tests/forge-review-test.el` | New tests for each of the above behaviors |
