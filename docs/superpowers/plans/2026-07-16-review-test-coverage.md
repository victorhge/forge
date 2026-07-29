# Review Test Coverage Expansion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand forge review test coverage by closing four unit-test gaps in `forge-review-test.el` and adding ten integration tests in `forge-review-integration-test.el`.

**Architecture:** Task 1 adds a shared section-dispatch helper and four unit tests (three new, one replacement) to `forge-review-test.el`. Tasks 2–6 add five GitHub integration tests. Tasks 7–11 add five GitLab integration tests. All integration tests use the existing persistent fixture PR/MR and follow the write-then-re-fetch pattern already established by the existing tests.

**Tech Stack:** ERT, `closql`/`emacsql`, `ghub` REST/GraphQL (synchronous batch mode), `magit-insert-section` for section-dispatch tests.

## Global Constraints

- No production code changes — only `tests/forge-review-test.el` and `tests/forge-review-integration-test.el`.
- All test names follow existing conventions: `forge-review-write-*` for unit tests, `forge-itest-github-*` / `forge-itest-gitlab-*` for integration tests.
- Integration tests must be skippable when env var is absent (use existing `pcase (forge-itest--github-repo)` / `pcase (forge-itest--gitlab-repo)` pattern).
- `forge-itest--with-fixture-pr` binds: `repo-obj`, `pr-obj`, `commit-sha`, `pr-number`, `path`, `posted-ids`.
- `forge-itest--with-fixture-mr` binds: `repo-obj`, `pr-obj`, `mr-alist`, `mr-iid`, `path`, `project-id`, `posted-ids`.
- Push comment IDs onto `posted-ids` for teardown (delete in `unwind-protect`). For deleted comments push nothing.
- Unit tests use `forge-test--make-repo` (GitHub fake subclass) and `forge-test--make-gl-repo` (GitLab fake subclass) — these record API calls without hitting the network.
- Run unit tests with: `make test` (expected: all 56+ tests pass, 0 unexpected).
- Run integration tests with: `./scripts/run-integration-tests.sh --github OWNER/REPO --gitlab OWNER/REPO`.

---

### Task 1: Unit test gaps — section-dispatch helper + four tests

**Files:**
- Modify: `tests/forge-review-test.el:1055–1068` (replace one test, add three, add one helper macro)

**Interfaces:**
- Consumes: `forge-test--make-repo`, `forge-test--make-gl-repo`, `forge-test--make-pullreq`, `forge-test--make-review-comment`, `forge-test--capture-request`, `forge-test--with-db` — all defined earlier in the file.
- Produces: `forge-test--with-section-at-rc` macro — used by three of the four new tests.

**Background:** `forge--set-review-thread-resolved` reads the opener via `(magit-section-value-if 'review-comment)`. To call it in a test, point must be inside a `forge-review-comment-section` whose value is the RC object. The macro below creates that context without needing a live Magit diff buffer.

`forge-discard-review-comment-at-point` and `forge-resolve/unresolve-review-thread` all read point the same way.

- [ ] **Step 1: Replace the inadequate test and add the helper macro**

  Find this block in `tests/forge-review-test.el` (lines 1055–1068):

  ```elisp
  (ert-deftest forge-review-write-resolve-updates-resolved-p-in-db ()
    "`forge--set-review-thread-resolved' sets resolved-p on the opener after API call."
    (forge-test--with-db
      (let* ((repo   (forge-test--make-repo))
             (pr     (forge-test--make-pullreq repo))
             (opener (forge-test--make-review-comment pr
                       :discussion-id "RT_x" :resolved-p nil)))
        (closql-insert (forge-db) opener t)
        (forge--review-set-thread-resolved repo pr opener t)
        (oset opener resolved-p t)
        (should (eq (oref (closql-get (forge-db) "rc-1"
                                      'forge-pullreq-review-comment)
                          resolved-p)
                    t)))))
  ```

  Replace it with:

  ```elisp
  (defmacro forge-test--with-section-at-rc (rc &rest body)
    "Run BODY with point inside a review-comment section whose value is RC.
  Uses `magit-insert-section' to build a minimal Magit section tree so that
  `magit-section-value-if' returns RC at point."
    (declare (indent 1))
    `(with-temp-buffer
       (magit-insert-section (topicbuf)
         (magit-insert-section section (review-comment ,rc)
           (insert "thread\n")))
       (goto-char (point-min))
       (forward-line)
       ,@body))

  (ert-deftest forge-review-write-set-thread-resolved-calls-api-and-updates-db ()
    "`forge--set-review-thread-resolved' (coordinator) calls the generic AND sets
  resolved-p in the DB — both effects in one call, not separately."
    (forge-test--with-db
      (let* ((repo   (forge-test--make-repo))
             (pr     (forge-test--make-pullreq repo))
             (opener (forge-test--make-review-comment pr
                       :discussion-id "RT_x" :resolved-p nil)))
        (closql-insert (forge-db) opener t)
        (forge-test--with-section-at-rc opener
          (let ((req (forge-test--capture-request
                       (forge--set-review-thread-resolved t))))
            (should (eq (plist-get req :mutation) 'resolveReviewThread))
            (should (equal (alist-get 'threadId (plist-get req :args)) "RT_x"))
            (should (eq (oref (closql-get (forge-db) "rc-1"
                                          'forge-pullreq-review-comment)
                              resolved-p)
                        t)))))))

  (ert-deftest forge-review-write-discard-at-point-removes-row ()
    "`forge-discard-review-comment-at-point' removes the DB row via section dispatch."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (rc   (forge-test--make-review-comment pr :pending-p t)))
        (closql-insert (forge-db) rc t)
        (should (closql-get (forge-db) "rc-1" 'forge-pullreq-review-comment))
        (forge-test--with-section-at-rc rc
          (forge-discard-review-comment-at-point))
        (should-not (closql-get (forge-db) "rc-1" 'forge-pullreq-review-comment)))))

  (ert-deftest forge-review-write-resolve-at-point-calls-api-and-updates-db ()
    "`forge-resolve-review-thread' dispatches via section, fires the mutation,
  and sets resolved-p t in the DB."
    (forge-test--with-db
      (let* ((repo   (forge-test--make-repo))
             (pr     (forge-test--make-pullreq repo))
             (opener (forge-test--make-review-comment pr
                       :discussion-id "RT_resolve" :resolved-p nil)))
        (closql-insert (forge-db) opener t)
        (forge-test--with-section-at-rc opener
          (let ((req (forge-test--capture-request
                       (forge-resolve-review-thread))))
            (should (eq (plist-get req :mutation) 'resolveReviewThread))
            (should (equal (alist-get 'threadId (plist-get req :args))
                           "RT_resolve"))
            (should (eq (oref (closql-get (forge-db) "rc-1"
                                          'forge-pullreq-review-comment)
                              resolved-p)
                        t)))))))

  (ert-deftest forge-review-write-unresolve-at-point-calls-api-and-updates-db ()
    "`forge-unresolve-review-thread' dispatches via section, fires the mutation,
  and sets resolved-p nil in the DB."
    (forge-test--with-db
      (let* ((repo   (forge-test--make-repo))
             (pr     (forge-test--make-pullreq repo))
             (opener (forge-test--make-review-comment pr
                       :discussion-id "RT_unresolve" :resolved-p t)))
        (closql-insert (forge-db) opener t)
        (forge-test--with-section-at-rc opener
          (let ((req (forge-test--capture-request
                       (forge-unresolve-review-thread))))
            (should (eq (plist-get req :mutation) 'unresolveReviewThread))
            (should (equal (alist-get 'threadId (plist-get req :args))
                           "RT_unresolve"))
            (should (null (oref (closql-get (forge-db) "rc-1"
                                            'forge-pullreq-review-comment)
                                resolved-p))))))))
  ```

- [ ] **Step 2: Run unit tests to verify all pass**

  ```sh
  make test
  ```

  Expected: output ends with `Ran N tests, N results as expected, 0 unexpected`. The new test names should appear in the passing list. If `forge-review-write-discard-at-point-removes-row` fails with "Wrong type argument" check that `forge-discard-review-comment-at-point` guards with `when-let` — point must be inside the section (one `forward-line` puts it there).

- [ ] **Step 3: Commit**

  ```sh
  git add tests/forge-review-test.el
  git commit -m "tests: close section-dispatch gaps in forge-review-test"
  ```

---

### Task 2: Integration — `forge-itest--gh-pr-comments` helper + `forge-itest-github-post-reply`

**Files:**
- Modify: `tests/forge-review-integration-test.el` — add helper before `;;; GitHub integration tests`, add test after `forge-itest-github-diff-hunk-populated`.

**Interfaces:**
- Consumes: `forge-itest--with-fixture-pr`, `forge-itest--add-review-comment`, `forge--review-post-reply`, `forge-itest--graphql-review-threads`, `forge--update-pullreq-review-comments`.
- Produces: `forge-itest--gh-pr-comments` — used by this and later GitHub tasks.

**Background:** `forge--review-post-reply` on GitHub calls `forge--rest pr "POST" "/repos/:owner/:repo/pulls/:number/comments"` with `in_reply_to_id = (oref opener database-id)`. The `opener` RC object in the DB must have its `database-id` slot set to the integer `id` returned by the API when the opener was posted.

- [ ] **Step 1: Add `forge-itest--gh-pr-comments` helper**

  In `tests/forge-review-integration-test.el`, find:

  ```elisp
  (defun forge-itest--clear-pr-comments (owner name pr-number)
    "Delete all review comments on PR-NUMBER in OWNER/NAME."
    (let ((comments (forge-itest--gh
                     "GET"
                     (format "/repos/%s/%s/pulls/%s/comments" owner name pr-number))))
      (dolist (c comments)
        (forge-itest--delete-review-comment owner name (alist-get 'id c)))))
  ```

  Insert immediately before it:

  ```elisp
  (defun forge-itest--gh-pr-comments (owner name pr-number)
    "Return the list of review comments on PR-NUMBER in OWNER/NAME."
    (forge-itest--gh "GET"
      (format "/repos/%s/%s/pulls/%s/comments" owner name pr-number)))
  ```

  Then simplify `forge-itest--clear-pr-comments` to use it:

  ```elisp
  (defun forge-itest--clear-pr-comments (owner name pr-number)
    "Delete all review comments on PR-NUMBER in OWNER/NAME."
    (dolist (c (forge-itest--gh-pr-comments owner name pr-number))
      (forge-itest--delete-review-comment owner name (alist-get 'id c))))
  ```

- [ ] **Step 2: Add `forge-itest-github-post-reply` test**

  Append immediately after `forge-itest-github-diff-hunk-populated` (before `;;; GitLab integration tests`):

  ```elisp
  (ert-deftest forge-itest-github-post-reply ()
    "GitHub: forge--review-post-reply posts a reply visible via re-fetch."
    (pcase (forge-itest--github-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-pr owner name
         (let* ((opener-alist (forge-itest--record posted-ids
                                (forge-itest--add-review-comment
                                 owner name pr-number commit-sha path 1
                                 "forge-itest post-reply opener")))
                (opener-db-id  (alist-get 'id opener-alist))
                (opener-rc     (forge-pullreq-review-comment
                                :id           (forge--object-id (oref pr-obj id)
                                                                (number-to-string opener-db-id))
                                :their-id     (number-to-string opener-db-id)
                                :discussion-id "placeholder"
                                :database-id  opener-db-id
                                :pullreq      (oref pr-obj id)
                                :new-path     path
                                :new-line     1
                                :body         "forge-itest post-reply opener"
                                :pending-p    nil))
                (_             (closql-insert (forge-db) opener-rc t))
                (_             (forge--review-post-reply repo-obj pr-obj opener-rc
                                                         "forge-itest post-reply body"))
                (comments      (forge-itest--gh-pr-comments owner name pr-number))
                (reply         (seq-find (lambda (c)
                                           (equal (alist-get 'in_reply_to_id c) opener-db-id))
                                         comments)))
           (should reply)
           (should (equal (alist-get 'body reply) "forge-itest post-reply body"))
           (push (alist-get 'id reply) posted-ids))))))
  ```

- [ ] **Step 3: Run integration tests (GitHub only) to verify**

  ```sh
  ./scripts/run-integration-tests.sh --github victorhge/forge
  ```

  Expected: `forge-itest-github-post-reply` passes. 4/4 GitHub tests pass, 0 unexpected.

- [ ] **Step 4: Commit**

  ```sh
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest-github-post-reply integration test"
  ```

---

### Task 3: Integration — `forge-itest-github-delete-comment`

**Files:**
- Modify: `tests/forge-review-integration-test.el` — append after `forge-itest-github-post-reply`.

**Interfaces:**
- Consumes: `forge-itest--with-fixture-pr`, `forge-itest--add-review-comment`, `forge-itest--gh-pr-comments`, `forge--review-delete-comment`.

**Background:** `forge--review-delete-comment` on GitHub calls `DELETE /repos/:owner/:repo/pulls/comments/:database-id`. The RC in the DB must have `database-id` set to the integer `id` from the API.

- [ ] **Step 1: Add the test**

  Append after `forge-itest-github-post-reply`:

  ```elisp
  (ert-deftest forge-itest-github-delete-comment ()
    "GitHub: forge--review-delete-comment removes the comment from the API."
    (pcase (forge-itest--github-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-pr owner name
         (let* ((comment-alist (forge-itest--add-review-comment
                                owner name pr-number commit-sha path 1
                                "forge-itest delete-comment"))
                (comment-id    (alist-get 'id comment-alist))
                (rc            (forge-pullreq-review-comment
                                :id           (forge--object-id (oref pr-obj id)
                                                                (number-to-string comment-id))
                                :their-id     (number-to-string comment-id)
                                :discussion-id "placeholder"
                                :database-id  comment-id
                                :pullreq      (oref pr-obj id)
                                :new-path     path
                                :new-line     1
                                :body         "forge-itest delete-comment"
                                :pending-p    nil))
                (_             (closql-insert (forge-db) rc t))
                (_             (forge--review-delete-comment repo-obj pr-obj rc))
                (comments      (forge-itest--gh-pr-comments owner name pr-number)))
           (should-not (seq-find (lambda (c) (= (alist-get 'id c) comment-id))
                                 comments)))))))
  ```

  Note: nothing is pushed to `posted-ids` — the comment is already deleted.

- [ ] **Step 2: Run integration tests**

  ```sh
  ./scripts/run-integration-tests.sh --github victorhge/forge
  ```

  Expected: 5/5 GitHub tests pass.

- [ ] **Step 3: Commit**

  ```sh
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest-github-delete-comment integration test"
  ```

---

### Task 4: Integration — `forge-itest-github-post-comment`

**Files:**
- Modify: `tests/forge-review-integration-test.el` — append after `forge-itest-github-delete-comment`.

**Interfaces:**
- Consumes: `forge-itest--with-fixture-pr`, `forge-itest--gh-pr-comments`, `forge--review-post-comment`.

**Background:** `forge--review-post-comment` on GitHub calls `POST /repos/:owner/:repo/pulls/:number/comments` with `body`, `path`, `line`, and `side`. It returns the response alist (synchronous `forge--rest`). `path` is bound by `forge-itest--with-fixture-pr` as `forge-itest--fixture-file` (`"forge-itest-scratch.txt"`).

- [ ] **Step 1: Add the test**

  Append after `forge-itest-github-delete-comment`:

  ```elisp
  (ert-deftest forge-itest-github-post-comment ()
    "GitHub: forge--review-post-comment posts an inline comment visible via re-fetch."
    (pcase (forge-itest--github-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-pr owner name
         (let* ((result   (forge--review-post-comment
                           repo-obj pr-obj
                           "forge-itest post-comment body"
                           path 'new 3))
                (new-id   (alist-get 'id result))
                (_        (push new-id posted-ids))
                (comments (forge-itest--gh-pr-comments owner name pr-number))
                (found    (seq-find (lambda (c) (equal (alist-get 'id c) new-id))
                                    comments)))
           (should found)
           (should (equal (alist-get 'body found) "forge-itest post-comment body"))
           (should (equal (alist-get 'path found) path))
           (should (= (alist-get 'line found) 3))
           (should (equal (alist-get 'side found) "RIGHT")))))))
  ```

- [ ] **Step 2: Run integration tests**

  ```sh
  ./scripts/run-integration-tests.sh --github victorhge/forge
  ```

  Expected: 6/6 GitHub tests pass.

- [ ] **Step 3: Commit**

  ```sh
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest-github-post-comment integration test"
  ```

---

### Task 5: Integration — `forge-itest-github-resolve-thread`

**Files:**
- Modify: `tests/forge-review-integration-test.el` — append after `forge-itest-github-post-comment`.

**Interfaces:**
- Consumes: `forge-itest--with-fixture-pr`, `forge-itest--add-review-comment`, `forge-itest--graphql-review-threads`, `forge--update-pullreq-review-comments`, `forge--review-set-thread-resolved`.

**Background:** `forge--review-set-thread-resolved` on GitHub calls the `resolveReviewThread` or `unresolveReviewThread` GraphQL mutation with `threadId = (oref opener discussion-id)`. The `discussion-id` is the GraphQL node ID of the review thread — it is only available via GraphQL, not the REST API. The approach: post a comment via REST, then fetch threads via `forge-itest--graphql-review-threads` and run `forge--update-pullreq-review-comments` to map the GraphQL payload into DB rows; then read the opener's `discussion-id` from the DB row.

- [ ] **Step 1: Add the test**

  Append after `forge-itest-github-post-comment`:

  ```elisp
  (ert-deftest forge-itest-github-resolve-thread ()
    "GitHub: forge--review-set-thread-resolved marks the thread resolved via GraphQL."
    (pcase (forge-itest--github-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-pr owner name
         (let* ((comment-alist (forge-itest--record posted-ids
                                 (forge-itest--add-review-comment
                                  owner name pr-number commit-sha path 1
                                  "forge-itest resolve-thread")))
                (_comment-id   (alist-get 'id comment-alist))
                ;; Map threads into DB so we get the GraphQL discussion-id.
                (threads       (forge-itest--graphql-review-threads owner name pr-number))
                (_             (forge--update-pullreq-review-comments repo-obj pr-obj threads))
                (opener        (seq-find (lambda (c) (null (oref c reply-to)))
                                         (oref pr-obj review-comments)))
                (_             (forge--review-set-thread-resolved repo-obj pr-obj opener t))
                ;; Re-fetch and verify isResolved.
                (threads2      (forge-itest--graphql-review-threads owner name pr-number))
                (thread-nodes  (alist-get 'nodes threads2))
                (disc-id       (oref opener discussion-id))
                (found-thread  (seq-find (lambda (t)
                                           (equal (alist-get 'id t) disc-id))
                                         thread-nodes)))
           (should found-thread)
           (should (eq (alist-get 'isResolved found-thread) t)))))))
  ```

- [ ] **Step 2: Run integration tests**

  ```sh
  ./scripts/run-integration-tests.sh --github victorhge/forge
  ```

  Expected: 7/7 GitHub tests pass. The thread is left resolved on the remote; `forge-itest--clear-pr-comments` deletes the comment on the next run and GitHub auto-unresolves deleted threads.

- [ ] **Step 3: Commit**

  ```sh
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest-github-resolve-thread integration test"
  ```

---

### Task 6: Integration — `forge-itest-github-submit-review`

**Files:**
- Modify: `tests/forge-review-integration-test.el` — append after `forge-itest-github-resolve-thread`.

**Interfaces:**
- Consumes: `forge-itest--with-fixture-pr`, `forge-itest--gh-pr-comments`, `forge--review-submit`.

**Background:** `forge--review-submit` on GitHub calls `POST /repos/:owner/:repo/pulls/:number/reviews` with `event="COMMENT"` and a `comments` array built from all pending rows. It then calls `forge--github-flush-pending-review-comments` which sets `pending-p nil` on all rows. The two pending rows need `new-path`, `new-line`, `body`, `database-id 0` (not yet submitted), and `pending-p t`.

- [ ] **Step 1: Add the test**

  Append after `forge-itest-github-resolve-thread`:

  ```elisp
  (ert-deftest forge-itest-github-submit-review ()
    "GitHub: forge--review-submit posts all pending comments and clears pending-p."
    (pcase (forge-itest--github-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-pr owner name
         (let* ((rc1 (forge-pullreq-review-comment
                      :id           (forge--object-id (oref pr-obj id) "pending-1")
                      :their-id     nil
                      :discussion-id nil
                      :database-id  0
                      :pullreq      (oref pr-obj id)
                      :new-path     path
                      :new-line     1
                      :body         "forge-itest submit-review A"
                      :pending-p    t))
                (rc2 (forge-pullreq-review-comment
                      :id           (forge--object-id (oref pr-obj id) "pending-2")
                      :their-id     nil
                      :discussion-id nil
                      :database-id  0
                      :pullreq      (oref pr-obj id)
                      :new-path     path
                      :new-line     2
                      :body         "forge-itest submit-review B"
                      :pending-p    t))
                (_   (closql-insert (forge-db) rc1 t))
                (_   (closql-insert (forge-db) rc2 t))
                (_   (forge--review-submit repo-obj pr-obj))
                ;; Re-fetch from API to confirm both comments appeared.
                (comments (forge-itest--gh-pr-comments owner name pr-number))
                (found-a  (seq-find (lambda (c)
                                      (equal (alist-get 'body c) "forge-itest submit-review A"))
                                    comments))
                (found-b  (seq-find (lambda (c)
                                      (equal (alist-get 'body c) "forge-itest submit-review B"))
                                    comments)))
           (should found-a)
           (should found-b)
           (push (alist-get 'id found-a) posted-ids)
           (push (alist-get 'id found-b) posted-ids)
           ;; Verify pending-p was cleared in the DB.
           (should (null (oref (closql-get (forge-db) (oref rc1 id)
                                           'forge-pullreq-review-comment)
                               pending-p)))
           (should (null (oref (closql-get (forge-db) (oref rc2 id)
                                           'forge-pullreq-review-comment)
                               pending-p))))))))
  ```

- [ ] **Step 2: Run integration tests**

  ```sh
  ./scripts/run-integration-tests.sh --github victorhge/forge
  ```

  Expected: 8/8 GitHub tests pass.

- [ ] **Step 3: Commit**

  ```sh
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest-github-submit-review integration test"
  ```

---

### Task 7: Integration — `forge-itest-gitlab-post-reply`

**Files:**
- Modify: `tests/forge-review-integration-test.el` — append after `forge-itest-gitlab-review-comment-path-and-line` (before `;;; _`).

**Interfaces:**
- Consumes: `forge-itest--with-fixture-mr`, `forge-itest--gl-add-review-comment`, `forge--review-post-reply`, `forge-itest--gl-discussions`.

**Background:** `forge--review-post-reply` on GitLab posts to `/projects/:project/merge_requests/:number/discussions/:discussion-id/notes` with `body`. The `opener` RC in the DB must have `discussion-id` set to the string discussion ID returned by `forge-itest--gl-add-review-comment`. The reply note's `id` (integer) must be pushed to `posted-ids` for cleanup.

- [ ] **Step 1: Add the test**

  Append after `forge-itest-gitlab-review-comment-path-and-line`:

  ```elisp
  (ert-deftest forge-itest-gitlab-post-reply ()
    "GitLab: forge--review-post-reply posts a reply visible in the discussion."
    (pcase (forge-itest--gitlab-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-mr owner name
         (let* ((disc      (forge-itest--gl-add-review-comment
                            project-id mr-iid mr-alist path 1
                            "forge-itest gl-post-reply opener"))
                (disc-id   (alist-get 'id disc))
                (note-id   (alist-get 'id (car (alist-get 'notes disc))))
                (_         (push note-id posted-ids))
                (opener-rc (forge-pullreq-review-comment
                            :id           (forge--object-id (oref pr-obj id)
                                                            (number-to-string note-id))
                            :their-id     (number-to-string note-id)
                            :discussion-id disc-id
                            :database-id  note-id
                            :pullreq      (oref pr-obj id)
                            :new-path     path
                            :new-line     1
                            :body         "forge-itest gl-post-reply opener"
                            :pending-p    nil))
                (_         (closql-insert (forge-db) opener-rc t))
                (_         (forge--review-post-reply repo-obj pr-obj opener-rc
                                                     "forge-itest gl-post-reply body"))
                ;; Re-fetch discussions and find the reply note.
                (discs     (forge-itest--gl-discussions project-id mr-iid))
                (the-disc  (seq-find (lambda (d) (equal (alist-get 'id d) disc-id))
                                     discs))
                (notes     (alist-get 'notes the-disc))
                (reply     (cadr notes)))
           (should reply)
           (should (equal (alist-get 'body reply) "forge-itest gl-post-reply body"))
           (push (alist-get 'id reply) posted-ids))))))
  ```

- [ ] **Step 2: Run integration tests (GitLab only)**

  ```sh
  ./scripts/run-integration-tests.sh --gitlab victorhge/forge
  ```

  Expected: `forge-itest-gitlab-post-reply` passes. 3/3 GitLab tests pass.

- [ ] **Step 3: Commit**

  ```sh
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest-gitlab-post-reply integration test"
  ```

---

### Task 8: Integration — `forge-itest-gitlab-delete-comment`

**Files:**
- Modify: `tests/forge-review-integration-test.el` — append after `forge-itest-gitlab-post-reply`.

**Interfaces:**
- Consumes: `forge-itest--with-fixture-mr`, `forge-itest--gl-add-review-comment`, `forge--review-delete-comment`, `forge-itest--gl-discussions`.

**Background:** `forge--review-delete-comment` on GitLab calls `DELETE /projects/:project/merge_requests/:number/notes/:database-id`. The RC must have `database-id` set to the integer note ID.

- [ ] **Step 1: Add the test**

  Append after `forge-itest-gitlab-post-reply`:

  ```elisp
  (ert-deftest forge-itest-gitlab-delete-comment ()
    "GitLab: forge--review-delete-comment removes the note from the API."
    (pcase (forge-itest--gitlab-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-mr owner name
         (let* ((disc    (forge-itest--gl-add-review-comment
                          project-id mr-iid mr-alist path 1
                          "forge-itest gl-delete-comment"))
                (note-id (alist-get 'id (car (alist-get 'notes disc))))
                (rc      (forge-pullreq-review-comment
                          :id           (forge--object-id (oref pr-obj id)
                                                          (number-to-string note-id))
                          :their-id     (number-to-string note-id)
                          :discussion-id (alist-get 'id disc)
                          :database-id  note-id
                          :pullreq      (oref pr-obj id)
                          :new-path     path
                          :new-line     1
                          :body         "forge-itest gl-delete-comment"
                          :pending-p    nil))
                (_       (closql-insert (forge-db) rc t))
                (_       (forge--review-delete-comment repo-obj pr-obj rc))
                ;; Re-fetch and verify note is gone.
                (discs   (forge-itest--gl-discussions project-id mr-iid))
                (all-note-ids (mapcar (lambda (n) (alist-get 'id n))
                                      (seq-mapcat (lambda (d) (alist-get 'notes d))
                                                  discs))))
           (should-not (memq note-id all-note-ids)))))))
  ```

- [ ] **Step 2: Run integration tests**

  ```sh
  ./scripts/run-integration-tests.sh --gitlab victorhge/forge
  ```

  Expected: 4/4 GitLab tests pass.

- [ ] **Step 3: Commit**

  ```sh
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest-gitlab-delete-comment integration test"
  ```

---

### Task 9: Integration — `forge-itest-gitlab-post-comment`

**Files:**
- Modify: `tests/forge-review-integration-test.el` — append after `forge-itest-gitlab-delete-comment`.

**Interfaces:**
- Consumes: `forge-itest--with-fixture-mr`, `forge--review-post-comment`, `forge-itest--gl-discussions`.

**Background:** `forge--review-post-comment` on GitLab posts to `/projects/:project/merge_requests/:number/discussions` with a `position` block using `pr-obj`'s `base-sha`, `base-rev`, `head-rev`. It returns the discussion alist. The opener note ID is `(alist-get 'id (car (alist-get 'notes result)))`.

- [ ] **Step 1: Add the test**

  Append after `forge-itest-gitlab-delete-comment`:

  ```elisp
  (ert-deftest forge-itest-gitlab-post-comment ()
    "GitLab: forge--review-post-comment posts an inline comment visible via re-fetch."
    (pcase (forge-itest--gitlab-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-mr owner name
         (let* ((result   (forge--review-post-comment
                           repo-obj pr-obj
                           "forge-itest gl-post-comment body"
                           path 'new 3))
                (note-id  (alist-get 'id (car (alist-get 'notes result))))
                (_        (push note-id posted-ids))
                (disc-id  (alist-get 'id result))
                ;; Re-fetch and find the discussion.
                (discs    (forge-itest--gl-discussions project-id mr-iid))
                (the-disc (seq-find (lambda (d) (equal (alist-get 'id d) disc-id))
                                    discs))
                (opener   (car (alist-get 'notes the-disc)))
                (pos      (alist-get 'position opener)))
           (should the-disc)
           (should (equal (alist-get 'body opener)
                          "forge-itest gl-post-comment body"))
           (should (= (alist-get 'new_line pos) 3))
           (should (equal (alist-get 'new_path pos) path)))))))
  ```

- [ ] **Step 2: Run integration tests**

  ```sh
  ./scripts/run-integration-tests.sh --gitlab victorhge/forge
  ```

  Expected: 5/5 GitLab tests pass.

- [ ] **Step 3: Commit**

  ```sh
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest-gitlab-post-comment integration test"
  ```

---

### Task 10: Integration — `forge-itest-gitlab-resolve-thread`

**Files:**
- Modify: `tests/forge-review-integration-test.el` — append after `forge-itest-gitlab-post-comment`.

**Interfaces:**
- Consumes: `forge-itest--with-fixture-mr`, `forge-itest--gl-add-review-comment`, `forge--review-set-thread-resolved`, `forge-itest--gl-discussions`.

**Background:** `forge--review-set-thread-resolved` on GitLab sends `PUT /projects/:project/merge_requests/:number/discussions/:discussion-id` with `resolved=t`. The `opener` RC must have `discussion-id` set to the string discussion ID. Re-fetch the discussion and check the top-level `resolved` key.

- [ ] **Step 1: Add the test**

  Append after `forge-itest-gitlab-post-comment`:

  ```elisp
  (ert-deftest forge-itest-gitlab-resolve-thread ()
    "GitLab: forge--review-set-thread-resolved marks the discussion resolved."
    (pcase (forge-itest--gitlab-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-mr owner name
         (let* ((disc      (forge-itest--gl-add-review-comment
                            project-id mr-iid mr-alist path 1
                            "forge-itest gl-resolve-thread"))
                (disc-id   (alist-get 'id disc))
                (note-id   (alist-get 'id (car (alist-get 'notes disc))))
                (_         (push note-id posted-ids))
                (opener-rc (forge-pullreq-review-comment
                            :id           (forge--object-id (oref pr-obj id)
                                                            (number-to-string note-id))
                            :their-id     (number-to-string note-id)
                            :discussion-id disc-id
                            :database-id  note-id
                            :pullreq      (oref pr-obj id)
                            :new-path     path
                            :new-line     1
                            :body         "forge-itest gl-resolve-thread"
                            :pending-p    nil))
                (_         (closql-insert (forge-db) opener-rc t))
                (_         (forge--review-set-thread-resolved repo-obj pr-obj opener-rc t))
                ;; Re-fetch and verify resolved.
                (discs     (forge-itest--gl-discussions project-id mr-iid))
                (the-disc  (seq-find (lambda (d) (equal (alist-get 'id d) disc-id))
                                     discs)))
           (should the-disc)
           (should (eq (alist-get 'resolved the-disc) t)))))))
  ```

- [ ] **Step 2: Run integration tests**

  ```sh
  ./scripts/run-integration-tests.sh --gitlab victorhge/forge
  ```

  Expected: 6/6 GitLab tests pass.

- [ ] **Step 3: Commit**

  ```sh
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest-gitlab-resolve-thread integration test"
  ```

---

### Task 11: Integration — `forge-itest-gitlab-submit-review`

**Files:**
- Modify: `tests/forge-review-integration-test.el` — append after `forge-itest-gitlab-resolve-thread`.

**Interfaces:**
- Consumes: `forge-itest--with-fixture-mr`, `forge--review-submit`, `forge-itest--gl-discussions`.

**Background:** `forge--review-submit` on GitLab iterates all pending rows and calls `POST /projects/:project/merge_requests/:number/discussions` for each one, using `pr-obj`'s `base-sha` / `base-rev` / `head-rev` slots as the three SHA fields. Unlike GitHub, GitLab has no "flush" step — pending rows stay in the DB with `pending-p t` after submit (the GitLab method only POSTs, it does not call a flush function). Verify both discussions appear remotely; push their note IDs for cleanup.

- [ ] **Step 1: Add the test**

  Append after `forge-itest-gitlab-resolve-thread`:

  ```elisp
  (ert-deftest forge-itest-gitlab-submit-review ()
    "GitLab: forge--review-submit posts all pending comments as individual discussions."
    (pcase (forge-itest--gitlab-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-mr owner name
         (let* ((rc1 (forge-pullreq-review-comment
                      :id           (forge--object-id (oref pr-obj id) "gl-pending-1")
                      :their-id     nil
                      :discussion-id nil
                      :database-id  0
                      :pullreq      (oref pr-obj id)
                      :new-path     path
                      :old-path     path
                      :new-line     1
                      :old-line     nil
                      :body         "forge-itest gl-submit-review A"
                      :pending-p    t))
                (rc2 (forge-pullreq-review-comment
                      :id           (forge--object-id (oref pr-obj id) "gl-pending-2")
                      :their-id     nil
                      :discussion-id nil
                      :database-id  0
                      :pullreq      (oref pr-obj id)
                      :new-path     path
                      :old-path     path
                      :new-line     2
                      :old-line     nil
                      :body         "forge-itest gl-submit-review B"
                      :pending-p    t))
                (_   (closql-insert (forge-db) rc1 t))
                (_   (closql-insert (forge-db) rc2 t))
                (_   (forge--review-submit repo-obj pr-obj))
                ;; Re-fetch inline discussions and match by body.
                (discs   (forge-itest--gl-discussions project-id mr-iid))
                (inline  (seq-filter
                          (lambda (d)
                            (seq-some (lambda (n) (alist-get 'position n))
                                      (alist-get 'notes d)))
                          discs))
                (bodies  (mapcar (lambda (d)
                                   (alist-get 'body (car (alist-get 'notes d))))
                                 inline)))
           (should (member "forge-itest gl-submit-review A" bodies))
           (should (member "forge-itest gl-submit-review B" bodies))
           ;; Push note IDs for teardown.
           (dolist (d inline)
             (when (member (alist-get 'body (car (alist-get 'notes d)))
                           '("forge-itest gl-submit-review A"
                             "forge-itest gl-submit-review B"))
               (push (alist-get 'id (car (alist-get 'notes d)))
                     posted-ids))))))))
  ```

- [ ] **Step 2: Run all integration tests**

  ```sh
  ./scripts/run-integration-tests.sh --github victorhge/forge --gitlab victorhge/forge
  ```

  Expected: all 15 tests pass (8 GitHub, 7 GitLab), 0 unexpected.

- [ ] **Step 3: Commit**

  ```sh
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest-gitlab-submit-review integration test"
  ```

---

## Self-review

**Spec coverage check:**

| Spec requirement | Task |
|---|---|
| `forge-test--with-section-at-rc` helper | Task 1 |
| `forge--set-review-thread-resolved` coordinator test (replaces L1055) | Task 1 |
| `forge-discard-review-comment-at-point` dispatch test | Task 1 |
| `forge-resolve-review-thread` full path test | Task 1 |
| `forge-unresolve-review-thread` full path test | Task 1 |
| `forge-itest--gh-pr-comments` helper | Task 2 |
| `forge-itest-github-post-reply` | Task 2 |
| `forge-itest-github-delete-comment` | Task 3 |
| `forge-itest-github-post-comment` | Task 4 |
| `forge-itest-github-resolve-thread` | Task 5 |
| `forge-itest-github-submit-review` | Task 6 |
| `forge-itest-gitlab-post-reply` | Task 7 |
| `forge-itest-gitlab-delete-comment` | Task 8 |
| `forge-itest-gitlab-post-comment` | Task 9 |
| `forge-itest-gitlab-resolve-thread` | Task 10 |
| `forge-itest-gitlab-submit-review` | Task 11 |

All 16 spec requirements covered. No placeholders. Type/slot names consistent throughout (`database-id`, `discussion-id`, `pending-p`, `new-path`, `new-line`, `old-path`, `old-line` — matching the EIEIO class definition in `forge-review.el`).
