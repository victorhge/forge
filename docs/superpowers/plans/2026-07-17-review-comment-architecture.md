# Review Comment Architecture + Naming Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `forge-pullreq-review-comment` into the standard forge object hierarchy (`forge-get-parent`, `forge-get-repository`, `forge--format-resource`) and fix accumulated naming inconsistencies, so review comment methods can use the same `forge--rest rc "VERB" "/:slot/path"` pattern as all other forge objects.

**Architecture:** Bottom-up (Option A): DB schema first, then EIEIO slot rename and call sites, then add the missing CLOS methods, then simplify the backend URL construction that the new methods unlock, then cosmetic/docstring fixes. Each task is independently testable and committable. The DB schema edit is in-place (no version bump) because this feature is pre-production.

**Tech Stack:** Emacs Lisp, EIEIO (cl-defmethod / cl-defgeneric), closql/emacsql (SQLite), ERT tests.

## Global Constraints

- No DB version bump — edit the existing v16 `(up 16 ...)` block and `forge--db-table-schemata` in place.
- All `cl-defgeneric` declarations stay in `forge-review.el`; `cl-defmethod` implementations stay in `forge-github.el` / `forge-gitlab.el` (dispatch pattern from CLAUDE.md).
- Never call `ghub-request` directly; always go through `forge--rest` or `forge--query`.
- Test suite: `make test` (runs `tests/forge-review-test.el` via ERT). Must stay green after every task.
- Slot list order in the EIEIO class must match the DB column order (closql positional INSERT). `database-id` is in position 5 of the schema; rename it to `number` in both places simultaneously.

---

### Task 1: Rename `database-id` → `number` in DB schema and EIEIO class

**Files:**
- Modify: `lisp/forge-db.el:485` (schema column), `lisp/forge-db.el:681` (v16 migration block)
- Modify: `lisp/forge-review.el:43` (EIEIO slot), `lisp/forge-review.el:411` (`:database-id 0` in stage-comment)
- Modify: `lisp/forge-review.el:63-73` (delete dead `forge--db-create-review-comment-table`)

**Interfaces:**
- Produces: `forge-pullreq-review-comment` with slot `number` (`:initarg :number`) instead of `database-id`. All code that writes `:database-id` or reads `(oref rc database-id)` is broken until Task 2 fixes the call sites.

- [ ] **Step 1: Edit `forge-db.el` — rename column in schema**

  In `forge--db-table-schemata`, at line 485, change `database-id` to `number`:

  ```elisp
  ;; before (line 485):
      database-id
  ;; after:
      number
  ```

- [ ] **Step 2: Edit `forge-db.el` — rename column in v16 migration block**

  The v16 `(up 16 ...)` block at line 681 uses `(cdr (assq 'pullreq-review-comment forge--db-table-schemata))` to create the table, so it picks up the schema automatically — no separate change needed there. However, confirm the block reads:

  ```elisp
  (up 16
      (emacsql db [:create-table pullreq-review-comment $S1]
               (cdr (assq 'pullreq-review-comment forge--db-table-schemata)))
      (emacsql db [:alter-table pullreq :add-column base-sha :default nil])
      (emacsql db [:alter-table pullreq :add-column review-comments
                   :default 'eieio-unbound]))
  ```

  No edit required here — it derives the schema from `forge--db-table-schemata`, which was already updated in Step 1.

- [ ] **Step 3: Edit `forge-review.el` — rename EIEIO slot**

  At line 43, change:

  ```elisp
  ;; before:
     (database-id   :initarg :database-id)
  ;; after:
     (number        :initarg :number)
  ```

- [ ] **Step 4: Edit `forge-review.el` — update `:database-id 0` in `forge-review--stage-comment`**

  At line 411, change:

  ```elisp
  ;; before:
                    :database-id  0
  ;; after:
                    :number       0
  ```

- [ ] **Step 5: Delete dead `forge--db-create-review-comment-table` from `forge-review.el`**

  Remove lines 61–73 entirely (the `;;; DB Helpers` section header and the function body). The v16 migration in `forge-db.el` does the same work and is the sole caller:

  ```elisp
  ;;; DB Helpers

  (defun forge--db-create-review-comment-table (db)
    "Create the pullreq-review-comment table and add pullreq columns if needed.
  Safe to call on an existing database; no-ops if already present."
    (ignore-errors
      (emacsql db [:create-table pullreq-review-comment $S1]
               (cdr (assq 'pullreq-review-comment forge--db-table-schemata))))
    (ignore-errors
      (emacsql db [:alter-table pullreq :add-column base-sha :default nil]))
    (ignore-errors
      (emacsql db [:alter-table pullreq :add-column review-comments
                   :default 'eieio-unbound])))
  ```

- [ ] **Step 6: Run tests — expect failures in the call-site tests**

  ```sh
  make test 2>&1 | grep -E "FAILED|PASSED|Error" | head -30
  ```

  Expected: tests that reference `database-id` as a slot name or `:database-id` as a keyword fail. That is correct — they will be fixed in Task 2. Compilation errors about unknown slot `database-id` confirm the rename landed.

- [ ] **Step 7: Commit**

  ```sh
  git add lisp/forge-db.el lisp/forge-review.el
  git commit -m "refactor: rename database-id slot to number in forge-pullreq-review-comment"
  ```

---

### Task 2: Update all call sites from `database-id` to `number`

**Files:**
- Modify: `lisp/forge-github.el` — two sites: mapping (`:database-id .databaseId`) and reply body (`(oref opener database-id)`)
- Modify: `lisp/forge-gitlab.el` — one site: mapping (`:database-id .id`)
- Modify: `tests/forge-review-test.el` — many sites: fixtures, stub methods, assertions

**Interfaces:**
- Consumes: `forge-pullreq-review-comment` with slot `number` (from Task 1)
- Produces: all code compiles; all existing tests pass

- [ ] **Step 1: Edit `forge-github.el` — update mapping**

  Find the `forge--update-pullreq-review-comments` method for GitHub (around line 1400). Change:

  ```elisp
  ;; before:
                      :database-id  .databaseId
  ;; after:
                      :number       .databaseId
  ```

- [ ] **Step 2: Edit `forge-github.el` — update `forge--review-post-reply`**

  Find the `in_reply_to` line (around line 1441). Change:

  ```elisp
  ;; before:
            (cons 'in_reply_to  (oref opener database-id)))))
  ;; after:
            (cons 'in_reply_to  (oref opener number)))))
  ```

- [ ] **Step 3: Edit `forge-github.el` — update `forge--review-delete-comment`**

  Find the `format` call (around line 1454). Change:

  ```elisp
  ;; before:
      (format "/repos/:owner/:repo/pulls/comments/%d" (oref rc database-id))
  ;; after:
      (format "/repos/:owner/:repo/pulls/comments/%d" (oref rc number))
  ```

- [ ] **Step 4: Edit `forge-gitlab.el` — update mapping**

  Find the `forge--update-pullreq-review-comments` method for GitLab (around line 734). Change:

  ```elisp
  ;; before:
                      :database-id  .id
  ;; after:
                      :number       .id
  ```

- [ ] **Step 5: Edit `forge-gitlab.el` — update `forge--review-delete-comment`**

  Find the `format` call (around line 800). Change:

  ```elisp
  ;; before:
      (format "/projects/:project/merge_requests/:number/notes/%d" (oref rc database-id))
  ;; after:
      (format "/projects/:project/merge_requests/:number/notes/%d" (oref rc number))
  ```

  Note: the `:number` in the path string is a literal format placeholder resolved by `forge--format-resource` against `pr`, not the `rc.number` slot — this is unchanged. Only the `(oref rc ...)` at the end changes.

- [ ] **Step 6: Edit `tests/forge-review-test.el` — update stub methods**

  Two stub `cl-defmethod` bodies reference `database-id` (GitHub and GitLab `forge--review-post-reply` and `forge--review-delete-comment` stubs, around lines 92 and 110 and 154):

  ```elisp
  ;; forge-test-github-repository forge--review-post-reply stub (~line 92):
  ;; before:
     (list (cons 'body text) (cons 'in_reply_to (oref opener database-id)))))
  ;; after:
     (list (cons 'body text) (cons 'in_reply_to (oref opener number)))))

  ;; forge-test-github-repository forge--review-delete-comment stub (~line 110):
  ;; before:
     (forge--format-resource
      pr (format "/repos/:owner/:repo/pulls/comments/%d" (oref rc database-id)))
  ;; after:
     (forge--format-resource
      pr (format "/repos/:owner/:repo/pulls/comments/%d" (oref rc number)))

  ;; forge-test-gitlab-repository forge--review-delete-comment stub (~line 154):
  ;; before:
     (forge--format-resource
      pr (format "/projects/:project/merge_requests/:number/notes/%d"
                 (oref rc database-id)))
  ;; after:
     (forge--format-resource
      pr (format "/projects/:project/merge_requests/:number/notes/%d"
                 (oref rc number)))
  ```

- [ ] **Step 7: Edit `tests/forge-review-test.el` — update `forge-test--make-review-comment` default**

  At line 258, change:

  ```elisp
  ;; before:
                :database-id   101
  ;; after:
                :number        101
  ```

- [ ] **Step 8: Edit `tests/forge-review-test.el` — update `forge-test--make-gl-review-comment`**

  At line 296, change:

  ```elisp
  ;; before:
                :discussion-id "gl-thread-1" :database-id 201)
  ;; after:
                :discussion-id "gl-thread-1" :number 201)
  ```

- [ ] **Step 9: Edit `tests/forge-review-test.el` — update slot round-trip assertion**

  At line 329, change:

  ```elisp
  ;; before:
          (should (equal (oref fetched database-id)   101))
  ;; after:
          (should (equal (oref fetched number)         101))
  ```

- [ ] **Step 10: Edit `tests/forge-review-test.el` — update inline `:database-id` keyword uses**

  Find all remaining `:database-id` keyword uses in test fixtures (lines 918, 1077, 1102, 1348, 1519, 1716, 1746) and change each to `:number`. Use:

  ```sh
  grep -n ":database-id" tests/forge-review-test.el
  ```

  to confirm you have caught them all. Each occurrence looks like:

  ```elisp
  ;; before:
    :id "rc-opener" :database-id 999 :discussion-id "t1"
  ;; after:
    :id "rc-opener" :number 999 :discussion-id "t1"
  ```

  and:

  ```elisp
  ;; before:
    :database-id 777 :pending-p nil
  ;; after:
    :number 777 :pending-p nil
  ```

  and:

  ```elisp
  ;; before:
    :database-id 42 :pending-p nil
  ;; after:
    :number 42 :pending-p nil
  ```

  and the two bare constructor calls in the display/overlay tests (lines ~1716, ~1746):

  ```elisp
  ;; before:
    :database-id 0 :pullreq "pr-1"
  ;; after:
    :number 0 :pullreq "pr-1"
  ```

  ```elisp
  ;; before:
    :database-id 0 :pullreq "pr"
  ;; after:
    :number 0 :pullreq "pr"
  ```

- [ ] **Step 11: Update test docstrings that mention `database-id`**

  Line 913: change test docstring from:

  ```elisp
  "Replying to a GitHub comment sends in_reply_to = database-id."
  ```

  to:

  ```elisp
  "Replying to a GitHub comment sends in_reply_to = number."
  ```

- [ ] **Step 12: Run tests — expect all passing**

  ```sh
  make test 2>&1 | tail -5
  ```

  Expected: all tests pass, no `database-id` references remain.

  Confirm with:

  ```sh
  grep -rn "database-id" lisp/ tests/
  ```

  Expected: no output.

- [ ] **Step 13: Commit**

  ```sh
  git add lisp/forge-github.el lisp/forge-gitlab.el tests/forge-review-test.el
  git commit -m "refactor: update all database-id call sites to number"
  ```

---

### Task 3: Add `forge-get-parent` and `forge-get-repository` for `forge-pullreq-review-comment`

**Files:**
- Modify: `lisp/forge-review.el` — add two `cl-defmethod` implementations after the class definition

**Interfaces:**
- Consumes: `forge-pullreq-review-comment` with slot `pullreq` (existing), `closql-get`, `forge-get-repository` generic (existing in `forge-core.el`)
- Produces:
  - `(forge-get-parent rc)` → the `forge-pullreq` that owns `rc`
  - `(forge-get-repository rc)` → the `forge-repository` that owns the pullreq
  - `forge--format-resource` can now walk `rc → pr → repo`, resolving `:owner`, `:repo`, `:project`, `:topic`, `:number` from an `rc` object

- [ ] **Step 1: Write failing tests**

  Add two ERT tests at the end of the `;;; Data model` section in `tests/forge-review-test.el` (after `forge-review-data-model-opener-vs-reply-identity`, around line 370):

  ```elisp
  (ert-deftest forge-review-data-model-get-parent-returns-pullreq ()
    "`forge-get-parent' on a review comment returns its owning pullreq."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (rc   (forge-test--make-review-comment pr)))
        (closql-insert (forge-db) rc t)
        (should (equal (oref (forge-get-parent rc) id)
                       (oref pr id))))))

  (ert-deftest forge-review-data-model-get-repository-returns-repo ()
    "`forge-get-repository' on a review comment returns its owning repository."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (rc   (forge-test--make-review-comment pr)))
        (closql-insert (forge-db) rc t)
        (should (equal (oref (forge-get-repository rc) id)
                       (oref repo id))))))
  ```

- [ ] **Step 2: Run tests to confirm they fail**

  ```sh
  make test 2>&1 | grep -E "forge-review-data-model-get-parent|forge-review-data-model-get-repository"
  ```

  Expected: both tests FAIL with `"No method found"` or similar — `forge-get-parent` has no method for `forge-pullreq-review-comment`.

- [ ] **Step 3: Add the two methods to `forge-review.el`**

  After the class definition (after line 59, before the `;;; Fetch / Mapping` section header), insert a new `;;; Query` section:

  ```elisp
  ;;; Query

  (cl-defmethod forge-get-parent ((rc forge-pullreq-review-comment))
    (closql-get (forge-db) (oref rc pullreq) 'forge-pullreq))

  (cl-defmethod forge-get-repository ((rc forge-pullreq-review-comment))
    (forge-get-repository (forge-get-parent rc)))
  ```

- [ ] **Step 4: Run tests to confirm they pass**

  ```sh
  make test 2>&1 | tail -5
  ```

  Expected: all tests pass including the two new ones.

- [ ] **Step 5: Commit**

  ```sh
  git add lisp/forge-review.el tests/forge-review-test.el
  git commit -m "feat: add forge-get-parent and forge-get-repository for forge-pullreq-review-comment"
  ```

---

### Task 4: Simplify backend URL construction using `forge--rest rc`

With `forge-get-parent` wired up and the slot renamed to `number`, the `(format "…%d" (oref rc number))` workarounds in both backends can be replaced with clean `forge--rest rc` calls that let `forge--format-resource` resolve all path segments.

**Files:**
- Modify: `lisp/forge-github.el` — `forge--review-delete-comment` method
- Modify: `lisp/forge-gitlab.el` — `forge--review-delete-comment` method
- Modify: `tests/forge-review-test.el` — update the two delete-comment stub methods to match

**Interfaces:**
- Consumes: `forge-get-parent` for `forge-pullreq-review-comment` (Task 3), `number` slot (Task 1)
- Produces: `forge--review-delete-comment` passes `rc` as the resource object; `:number` resolves from `rc.number`, `:topic` resolves from `pr.number` (via parent walk since `rc` is not a `forge-topic`), `:project`/`:owner`/`:repo` resolve from the repo (via grandparent walk).

**URL resolution walkthrough:**

For `forge-github-repository`:
- Path: `"/repos/:owner/:repo/pulls/comments/:number"`
- `:owner` → not on `rc` → walks to `pr` → not on `pr` → walks to `repo` → `(oref repo owner)` ✓
- `:repo` → same walk → `(oref repo name)` ✓
- `:number` → `(oref rc number)` = the integer comment ID ✓

For `forge-gitlab-repository`:
- Path: `"/projects/:project/merge_requests/:topic/notes/:number"`
- `:project` → walks to repo → `owner%2Fname` ✓
- `:topic` → `(and (forge--childp rc 'forge-topic) ...)` → `rc` is NOT a topic → nil → walks to `pr` → `(oref pr number)` = MR iid ✓
- `:number` → `(oref rc number)` = the integer note ID ✓

- [ ] **Step 1: Update the test stub for GitHub `forge--review-delete-comment`**

  In `tests/forge-review-test.el`, the `forge-test-github-repository` stub (around line 108). Change from passing `pr` to passing `rc`:

  ```elisp
  ;; before:
  (cl-defmethod forge--review-delete-comment
    ((_repo forge-test-github-repository) pr rc)
    (forge-test--record-rest
     "DELETE"
     (forge--format-resource
      pr (format "/repos/:owner/:repo/pulls/comments/%d" (oref rc number)))
     nil))
  ;; after:
  (cl-defmethod forge--review-delete-comment
    ((_repo forge-test-github-repository) _pr rc)
    (forge-test--record-rest
     "DELETE"
     (forge--format-resource rc "/repos/:owner/:repo/pulls/comments/:number")
     nil))
  ```

- [ ] **Step 2: Update the test stub for GitLab `forge--review-delete-comment`**

  The `forge-test-gitlab-repository` stub (around line 150). Change:

  ```elisp
  ;; before:
  (cl-defmethod forge--review-delete-comment
    ((_repo forge-test-gitlab-repository) pr rc)
    (forge-test--record-rest
     "DELETE"
     (forge--format-resource
      pr (format "/projects/:project/merge_requests/:number/notes/%d"
                 (oref rc number)))
     nil))
  ;; after:
  (cl-defmethod forge--review-delete-comment
    ((_repo forge-test-gitlab-repository) _pr rc)
    (forge-test--record-rest
     "DELETE"
     (forge--format-resource rc "/projects/:project/merge_requests/:topic/notes/:number")
     nil))
  ```

- [ ] **Step 3: Run tests — expect all pass (stubs now use the new form)**

  ```sh
  make test 2>&1 | tail -5
  ```

  Expected: all tests pass. The stubs drive the same assertions; confirming the resource strings are equivalent validates the path resolution logic before touching the production code.

- [ ] **Step 4: Simplify `forge--review-delete-comment` in `forge-github.el`**

  Find the method (around line 1450):

  ```elisp
  ;; before:
  (cl-defmethod forge--review-delete-comment ((_repo forge-github-repository) pr rc)
    "DELETE a submitted review comment RC from GitHub."
    (forge--rest pr "DELETE"
      (format "/repos/:owner/:repo/pulls/comments/%d" (oref rc number))
      nil))
  ;; after:
  (cl-defmethod forge--review-delete-comment ((_repo forge-github-repository) _pr rc)
    "DELETE a submitted review comment RC from GitHub."
    (forge--rest rc "DELETE" "/repos/:owner/:repo/pulls/comments/:number" nil))
  ```

- [ ] **Step 5: Simplify `forge--review-delete-comment` in `forge-gitlab.el`**

  Find the method (around line 798):

  ```elisp
  ;; before:
  (cl-defmethod forge--review-delete-comment ((_repo forge-gitlab-repository) pr rc)
    "DELETE a submitted review comment RC from GitLab."
    (forge--rest pr "DELETE"
      (format "/projects/:project/merge_requests/:number/notes/%d" (oref rc number))
      nil))
  ;; after:
  (cl-defmethod forge--review-delete-comment ((_repo forge-gitlab-repository) _pr rc)
    "DELETE a submitted review comment RC from GitLab."
    (forge--rest rc "DELETE"
      "/projects/:project/merge_requests/:topic/notes/:number" nil))
  ```

- [ ] **Step 6: Run tests — expect all pass**

  ```sh
  make test 2>&1 | tail -5
  ```

  Expected: all tests pass.

- [ ] **Step 7: Commit**

  ```sh
  git add lisp/forge-github.el lisp/forge-gitlab.el tests/forge-review-test.el
  git commit -m "refactor: simplify review-delete-comment URLs using forge--rest rc"
  ```

---

### Task 5: Cosmetic fixes — renames and docstrings

Five independent fixes, done in one task since none requires tests and they are all low-risk.

**Files:**
- Modify: `lisp/forge-review.el` — rename `forge--submit-review-reply` generic and its `#'forge--submit-review-reply` callback reference; rename `forge-comment-pullreq`
- Modify: `lisp/forge-github.el` — rename `forge--submit-review-reply` method
- Modify: `lisp/forge-gitlab.el` — rename `forge--submit-review-reply` method
- Modify: `lisp/forge-post.el` — fix `assert` → `demand` param names; expand `forge-edit-post-action` docstring; expand `forge-edit-post-hook` docstring
- Modify: `lisp/forge-topic.el` — update `declare-function` and transient menu entry for `forge-comment-pullreq`
- Modify: `docs/forge.org` — update two references to `forge-comment-pullreq`
- Modify: `tests/forge-review-test.el` — rename all references to `forge--submit-review-reply`; rename `forge-comment-pullreq` reference; update two regression test docstrings

**Interfaces:**
- Produces: all public symbols renamed, docstrings accurate, tests updated. No behaviour changes.

- [ ] **Step 1: Rename `forge--submit-review-reply` → `forge--submit-add-review-reply` in `forge-review.el`**

  Three sites:

  1. The `cl-defgeneric` at line 430:
     ```elisp
     ;; before:
     (cl-defgeneric forge--submit-review-reply (repo opener)
       "Submit a reply to the review comment OPENER in the current post buffer.
     REPO is the `forge-repository' the pull request belongs to.")
     ;; after:
     (cl-defgeneric forge--submit-add-review-reply (repo opener)
       "Submit a reply to the review comment OPENER in the current post buffer.
     REPO is the `forge-repository' the pull request belongs to.")
     ```

  2. The callback reference at line 478:
     ```elisp
     ;; before:
             #'forge--submit-review-reply
     ;; after:
             #'forge--submit-add-review-reply
     ```

- [ ] **Step 2: Rename the method in `forge-github.el`**

  Find `(cl-defmethod forge--submit-review-reply` (around line 1467):

  ```elisp
  ;; before:
  (cl-defmethod forge--submit-review-reply
    ((repo forge-github-repository) (opener forge-pullreq-review-comment))
  ;; after:
  (cl-defmethod forge--submit-add-review-reply
    ((repo forge-github-repository) (opener forge-pullreq-review-comment))
  ```

- [ ] **Step 3: Rename the method in `forge-gitlab.el`**

  Find `(cl-defmethod forge--submit-review-reply` (around line 818):

  ```elisp
  ;; before:
  (cl-defmethod forge--submit-review-reply
    ((repo forge-gitlab-repository) (opener forge-pullreq-review-comment))
  ;; after:
  (cl-defmethod forge--submit-add-review-reply
    ((repo forge-gitlab-repository) (opener forge-pullreq-review-comment))
  ```

- [ ] **Step 4: Rename `forge-comment-pullreq` → `forge-submit-pending-review` in `forge-review.el`**

  At line 521:

  ```elisp
  ;; before:
  (defun forge-comment-pullreq (pullreq)
    "Submit pending review comments on PULLREQ."
    (interactive (list (forge-current-pullreq t)))
    (forge--review-submit (forge-get-repository pullreq) pullreq))
  ;; after:
  (defun forge-submit-pending-review (pullreq)
    "Submit pending review comments on PULLREQ."
    (interactive (list (forge-current-pullreq t)))
    (forge--review-submit (forge-get-repository pullreq) pullreq))
  ```

- [ ] **Step 5: Update `forge-topic.el` — `declare-function` and transient menu**

  Two sites in `lisp/forge-topic.el`:

  Line 35 — `declare-function`:
  ```elisp
  ;; before:
  (declare-function forge-comment-pullreq          "forge-review" (pullreq))
  ;; after:
  (declare-function forge-submit-pending-review    "forge-review" (pullreq))
  ```

  Line 1613 — transient menu entry:
  ```elisp
  ;; before:
      ("/v" "submit review"  forge-comment-pullreq)
  ;; after:
      ("/v" "submit review"  forge-submit-pending-review)
  ```

- [ ] **Step 6: Update `docs/forge.org`**

  Two references (lines 1065 and 1082). Change both `forge-comment-pullreq` occurrences to `forge-submit-pending-review`:

  ```
  grep -n "forge-comment-pullreq" docs/forge.org
  ```

  Line 1065: change `~forge-comment-pullreq~` → `~forge-submit-pending-review~`
  Line 1082: change `forge-comment-pullreq` → `forge-submit-pending-review`

- [ ] **Step 7: Fix `assert` → `demand` param names in `forge-post.el`**

  `forge-post-at-point` at line 81 and `forge-comment-at-point` at line 88. For each, change the parameter name `assert` to `demand` in the arglist and in the `(and assert ...)` guard:

  ```elisp
  ;; forge-post-at-point before:
  (defun forge-post-at-point (&optional assert)
    "Return the post at point.
  If there is no such post and DEMAND is non-nil, then signal
  an error."
    (or (magit-section-value-if '(issue pullreq post))
        (and assert (user-error "There is no post at point"))))

  ;; after:
  (defun forge-post-at-point (&optional demand)
    "Return the post at point.
  If there is no such post and DEMAND is non-nil, then signal
  an error."
    (or (magit-section-value-if '(issue pullreq post))
        (and demand (user-error "There is no post at point"))))

  ;; forge-comment-at-point before:
  (defun forge-comment-at-point (&optional assert)
    "Return the comment at point.
  If there is no such comment and DEMAND is non-nil, then signal
  an error."
    (or (and (magit-section-value-if '(post))
             (let ((post (oref (magit-current-section) value)))
               (and (or (forge-pullreq-post-p post)
                        (forge-issue-post-p post))
                    post)))
        (and assert (user-error "There is no comment at point"))))

  ;; after:
  (defun forge-comment-at-point (&optional demand)
    "Return the comment at point.
  If there is no such comment and DEMAND is non-nil, then signal
  an error."
    (or (and (magit-section-value-if '(post))
             (let ((post (oref (magit-current-section) value)))
               (and (or (forge-pullreq-post-p post)
                        (forge-issue-post-p post))
                    post)))
        (and demand (user-error "There is no comment at point"))))
  ```

- [ ] **Step 8: Expand `forge-edit-post-action` and `forge-edit-post-hook` docstrings in `forge-post.el`**

  `forge-edit-post-hook` docstring at line 48 — change the action list:

  ```elisp
  ;; before:
  "one of `new-discussion', `new-issue', `new-pullreq', `reply' and `edit'."
  ;; after:
  "one of `new-discussion', `new-issue', `new-pullreq', `new-answer',
  `new-comment', `new-approval', `new-request', `new-review-comment',
  `new-single-review-comment', `reply' and `edit'."
  ```

  `forge-edit-post-action` docstring at line 129 — change the same list:

  ```elisp
  ;; before:
  "One of `new-discussion', `new-issue', `new-pullreq', `reply' and `edit'."
  ;; after:
  "One of `new-discussion', `new-issue', `new-pullreq', `new-answer',
  `new-comment', `new-approval', `new-request', `new-review-comment',
  `new-single-review-comment', `reply' and `edit'."
  ```

- [ ] **Step 9: Update `tests/forge-review-test.el` — rename `forge--submit-review-reply`**

  Four occurrences (lines 94, 134, 1343, 1355, 1513, 1526 — use grep to confirm):

  ```sh
  grep -n "forge--submit-review-reply" tests/forge-review-test.el
  ```

  Change every occurrence of `forge--submit-review-reply` to `forge--submit-add-review-reply`. This includes comment text (lines 94, 134), a test docstring (line 1343), a direct call (line 1355), another docstring (line 1513), and a `#'` reference (line 1526).

- [ ] **Step 10: Update `tests/forge-review-test.el` — rename `forge-comment-pullreq`**

  Line 1110 (test docstring) and line 1124 (call site):

  ```elisp
  ;; line 1110 before:
  "`forge-comment-pullreq' submits all pending comments for the pullreq."
  ;; after:
  "`forge-submit-pending-review' submits all pending comments for the pullreq."

  ;; line 1124 before:
                         (forge-comment-pullreq pr)))))
  ;; after:
                         (forge-submit-pending-review pr)))))
  ```

- [ ] **Step 11: Run tests — expect all pass**

  ```sh
  make test 2>&1 | tail -5
  ```

  Expected: all tests pass.

  Confirm no old names remain:

  ```sh
  grep -rn "forge--submit-review-reply\|forge-comment-pullreq\b\|:database-id\b\|\bassert\b" lisp/forge-post.el lisp/forge-review.el lisp/forge-github.el lisp/forge-gitlab.el tests/forge-review-test.el lisp/forge-topic.el
  ```

  Expected: no output (the `assert` grep is scoped to only those files to avoid false positives from unrelated code).

- [ ] **Step 12: Commit**

  ```sh
  git add lisp/forge-review.el lisp/forge-github.el lisp/forge-gitlab.el lisp/forge-post.el lisp/forge-topic.el docs/forge.org tests/forge-review-test.el
  git commit -m "refactor: rename submit-review-reply, forge-comment-pullreq; fix docstrings and param names"
  ```
