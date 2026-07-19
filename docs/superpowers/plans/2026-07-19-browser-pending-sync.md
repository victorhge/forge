# Browser-Pending Review Comment Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify the pending/non-pending review comment lifecycle so create, edit, and delete always go through the forge API immediately; `pending-p` becomes a server-side state flag only. Add batch publish as the one unique pending operation. Support GitHub and GitLab backends.

**Architecture:** Currently `forge-post-stage` writes a local-only DB row with no API call and `their-id nil`. The new design: staging calls the API to create a server-side draft comment (GitHub: `addPullRequestReviewThread`; GitLab: `POST .../draft_notes`), writes the DB row in the callback with the real `their-id`, and sets `pending-p t`. Edit and delete then share the same API paths as submitted comments. The post buffer gains a third action — "stage + publish batch" — available when the PR already has pending comments. `forge-submit-pending-review` (publish from topic buffer) is unchanged. Browser-pending comments pulled from GitHub/GitLab are stored with `pending-p t` and their real `their-id`, so they slot directly into this model.

**Tech Stack:** Emacs Lisp, EIEIO, closql/emacsql, GitHub GraphQL API, GitLab REST API, ERT test suite.

## Global Constraints

- Run `make test` after every task — all tests must pass.
- Never call `ghub-request` directly; use `forge--rest` / `forge--query`.
- All write-method callbacks follow `(:callback ... :errorback (forge--post-submit-errorback))`.
- Dispatch pattern: generics in `forge-review.el`, methods in `forge-github.el` / `forge-gitlab.el`.
- No `if (github-p repo)` guards in `forge-review.el`.
- `pending-p t` means: comment exists on the server as a draft, authored by the current user, not yet published. `their-id` is always non-nil on pending rows after this plan.
- `forge-pullreq-review-comment` slots (DB column order must not change): `id their-id discussion-id number pullreq new-path old-path new-line old-line diff-hunk outdated-p resolved-p reply-to review-state author body created updated reactions pending-p`.

---

## The Three Comment Kinds (post-plan)

| Kind | `pending-p` | `their-id` | Meaning |
|---|---|---|---|
| **Draft / pending** | `t` | non-nil | Server-side draft; author-only visible |
| **Submitted** | `nil` | non-nil | Published; visible to all |

There is no longer a "locally staged only" kind. Every row in the DB has a real `their-id`.

## Post Buffer Actions

| Key | Action | When available |
|---|---|---|
| `C-c C-c` | Submit immediately as single standalone comment | Always |
| `C-s` | Stage as server-side draft | Always (for `new-review-comment`) |
| `C-c C-p` (new) | Stage as draft + publish entire pending batch | Only when PR already has pending comments |

---

### Task 1: Pull mapping — store browser-pending comments with `pending-p t`

This is a prerequisite. Pulled comments with `pullRequestReview.state = "PENDING"` (GitHub) belong to the current user and must be stored with `pending-p t`. GitLab draft notes are fetched separately (Task 6).

**Files:**
- Modify: `lisp/forge-github.el` (line ~1420)
- Test: `tests/forge-review-test.el`

- [ ] **Step 1: Write a failing test**

  In `tests/forge-review-test.el`, after `forge-review-api-github-review-state-stored` (line ~839):

  ```elisp
  (ert-deftest forge-review-api-github-pending-review-state-sets-pending-p ()
    "A thread from a PENDING review is stored with pending-p t and their-id set."
    (forge-test--with-db
      (let* ((repo    (forge-test--make-repo))
             (pr      (forge-test--make-pullreq repo))
             (payload (copy-tree forge-test--github-thread-payload)))
        (setf (alist-get 'state (alist-get 'pullRequestReview
                                  (nth 0 (alist-get 'comments payload)))) "PENDING")
        (setf (alist-get 'state (alist-get 'pullRequestReview
                                  (nth 1 (alist-get 'comments payload)))) "PENDING")
        (forge--update-pullreq-review-comments repo pr (list payload))
        (let* ((all    (oref pr review-comments))
               (opener (seq-find (lambda (c) (null (oref c reply-to))) all))
               (reply  (seq-find (lambda (c) (oref c reply-to)) all)))
          (should (eq (oref opener pending-p) t))
          (should (eq (oref reply   pending-p) t))
          (should (equal (oref opener their-id) "RC_node1"))
          (should (equal (oref reply  their-id) "RC_node2"))))))
  ```

- [ ] **Step 2: Run to confirm failure**

  ```sh
  cd /home/Build/yren/.emacs.d/elpa/forge
  make test 2>&1 | grep -E "forge-review-api-github-pending"
  ```

  Expected: `FAILED`

- [ ] **Step 3: Implement**

  In `lisp/forge-github.el` line ~1420, change:

  ```elisp
                      :pending-p    nil)
  ```

  to:

  ```elisp
                      :pending-p    (eq state2 'pending))
  ```

- [ ] **Step 4: Run full suite**

  ```sh
  make test 2>&1 | tail -5
  ```

  Expected: all pass.

- [ ] **Step 5: Commit**

  ```sh
  git add lisp/forge-github.el tests/forge-review-test.el
  git commit -m "fix: store browser-pending GitHub review comments with pending-p t on pull"
  ```

---

### Task 2: New generics for draft create, edit, delete, publish

Declare all four operations in `forge-review.el`. This is the interface contract the backends implement.

**Files:**
- Modify: `lisp/forge-review.el`

- [ ] **Step 1: Add generic declarations**

  In `lisp/forge-review.el`, replace the existing `forge--review-submit` generic and the `cl-defgeneric` for `forge--review-delete-comment`, `forge--review-post-comment`, `forge--review-post-reply` with this complete set. Keep all existing generics and add the new ones after `forge--review-submit`:

  ```elisp
  (cl-defgeneric forge--review-create-draft (repo pr body path side line
                                              &key callback errorback)
    "Create a server-side draft review comment on PR at PATH SIDE LINE with BODY.
  Calls CALLBACK with the new comment node as its sole argument on success.")

  (cl-defgeneric forge--review-edit-draft (repo pr rc body &key callback errorback)
    "Edit the body of draft review comment RC on PR to BODY.")

  (cl-defgeneric forge--review-publish-pending (repo pr &key callback errorback)
    "Publish all pending (draft) review comments on PR as a batch COMMENT review.")
  ```

  Note: `forge--review-delete-comment` already exists and covers both draft and submitted comments — no new generic needed for delete.

- [ ] **Step 2: No tests needed here** (generics with no default body cannot be tested in isolation; each backend task tests its implementation).

- [ ] **Step 3: Commit**

  ```sh
  git add lisp/forge-review.el
  git commit -m "feat: declare forge--review-create-draft/edit-draft/publish-pending generics"
  ```

---

### Task 3: GitHub backend — implement draft create, edit, publish

**Files:**
- Modify: `lisp/forge-github.el`
- Test: `tests/forge-review-test.el`

**Interfaces:**
- `forge--review-create-draft`: uses `addPullRequestReviewThread` mutation (same as `forge--review-post-comment`) but the PR must have an in-progress review. GitHub creates one automatically on first call.
- `forge--review-edit-draft`: uses `updatePullRequestReviewComment` mutation with `(oref rc their-id)`.
- `forge--review-publish-pending`: uses `submitPullRequestReview` mutation. Needs the pending review node ID — query with `reviews(last:1 states:[PENDING])`.
- `forge--review-delete-comment` already uses `deletePullRequestReviewComment` — works for draft comments too, no change needed.

- [ ] **Step 1: Write failing tests**

  In `tests/forge-review-test.el`:

  ```elisp
  (ert-deftest forge-review-github-create-draft-calls-addPullRequestReviewThread ()
    "forge--review-create-draft calls addPullRequestReviewThread and stores row with pending-p t."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo)))
        (forge-itest--with-sync-rest
          (let ((called-with nil))
            (cl-letf (((symbol-function 'forge--query)
                       (lambda (_obj _query vars &rest _)
                         (setq called-with vars)
                         ;; Fake response: new thread with one comment node.
                         '((addPullRequestReviewThread
                            (thread
                             (comments
                              (nodes ((id . "RC_new1")
                                      (databaseId . 999)
                                      (pullRequestReview (id . "PRR_rev1"))
                                      (author (login . "alice"))
                                      (body . "My draft")
                                      (createdAt . "2026-07-19T10:00:00Z")
                                      (updatedAt . "2026-07-19T10:00:00Z")
                                      (reactionGroups . nil)
                                      (diffHunk . "")
                                      (position . 5))))))))))
              (forge--review-create-draft
               repo pr "My draft" "src/foo.el" 'new 5
               :callback (lambda (rc)
                           (should (equal (oref rc their-id) "RC_new1"))
                           (should (oref rc pending-p)))
               :errorback #'error)))))))

  (ert-deftest forge-review-github-publish-pending-calls-submitPullRequestReview ()
    "forge--review-publish-pending queries review ID then calls submitPullRequestReview."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (_rc  (forge-test--make-review-comment
                    pr :pending-p t :their-id "RC_node1")))
        (forge-itest--with-sync-rest
          (let ((mutations nil))
            (cl-letf (((symbol-function 'forge--query)
                       (lambda (_obj query vars &rest _)
                         (push (cons query vars) mutations)
                         (if (string-match-p "PENDING" (format "%s" query))
                             '((node (reviews (nodes ((id . "PRR_rev1"))))))
                           nil))))
              (forge--review-publish-pending
               repo pr
               :callback (lambda (&rest _) nil)
               :errorback #'error)
              ;; First call: lookup; second: submitPullRequestReview.
              (should (= (length mutations) 2))
              (should (string-match-p "submit" (downcase (format "%s" (caar mutations)))))))))))
  ```

- [ ] **Step 2: Run to confirm failures**

  ```sh
  make test 2>&1 | grep -E "forge-review-github-create-draft|forge-review-github-publish"
  ```

  Expected: both `FAILED`

- [ ] **Step 3: Implement `forge--review-create-draft` for GitHub**

  In `lisp/forge-github.el`, add after `forge--review-post-comment`:

  ```elisp
  (cl-defmethod forge--review-create-draft
    ((_repo forge-github-repository) pr body path side line &key callback errorback)
    "Create a GitHub draft review thread at PATH SIDE LINE with BODY."
    (forge--query pr
      `(mutation
        [(input $input AddPullRequestReviewThreadInput!)]
        (addPullRequestReviewThread
         [(input $input)]
         (thread
          (comments
           [(first 1)]
           (nodes id databaseId
                  (author login) body createdAt updatedAt
                  diffHunk (reactionGroups content (reactors totalCount))
                  (pullRequestReview id state))))))
      `((input
         (pullRequestId . ,(oref pr their-id))
         (path . ,path)
         (line . ,line)
         (side . ,(if (eq side 'old) "LEFT" "RIGHT"))
         (body . ,body)))
      :callback  (lambda (data _headers _status _req)
                   (let* ((node (car (alist-get 'nodes
                                      (alist-get 'comments
                                       (alist-get 'thread
                                        (alist-get 'addPullRequestReviewThread data)))))))
                     (when callback
                       (funcall callback
                                (forge--github-draft-node-to-rc pr node)))))
      :errorback errorback))

  (defun forge--github-draft-node-to-rc (pr node)
    "Map a GitHub comment NODE from addPullRequestReviewThread into a DB row.
  Inserts the row and returns it."
    (let-alist node
      (let* ((rc (forge-pullreq-review-comment
                  :id           (forge--object-id (oref pr id) .id)
                  :their-id     .id
                  :discussion-id nil        ; thread ID not returned here; filled on next pull
                  :number       .databaseId
                  :pullreq      (oref pr id)
                  :new-path     nil         ; not returned by mutation; filled on next pull
                  :old-path     nil
                  :new-line     nil
                  :old-line     nil
                  :diff-hunk    .diffHunk
                  :outdated-p   nil
                  :resolved-p   nil
                  :reply-to     nil
                  :review-state 'pending
                  :author       .author.login
                  :body         (forge--sanitize-string .body)
                  :created      .createdAt
                  :updated      .updatedAt
                  :reactions    (forge--reaction-groups-to-alist .reactionGroups)
                  :pending-p    t)))
        (closql-insert (forge-db) rc t)
        rc)))
  ```

- [ ] **Step 4: Implement `forge--review-edit-draft` for GitHub**

  In `lisp/forge-github.el`, add:

  ```elisp
  (cl-defmethod forge--review-edit-draft
    ((_repo forge-github-repository) _pr rc body &key callback errorback)
    "Edit the body of GitHub draft review comment RC."
    (forge--query rc
      `(mutation
        [(input $input UpdatePullRequestReviewCommentInput!)]
        (updatePullRequestReviewComment
         [(input $input)]
         (pullRequestReviewComment id body updatedAt)))
      `((input
         (pullRequestReviewCommentId . ,(oref rc their-id))
         (body . ,body)))
      :callback  (lambda (data _headers _status _req)
                   (let* ((updated (alist-get 'updatePullRequestReviewComment data)))
                     (oset rc body (alist-get 'body updated))
                     (oset rc updated (alist-get 'updatedAt updated))
                     (when callback (funcall callback rc))))
      :errorback errorback))
  ```

- [ ] **Step 5: Implement `forge--review-publish-pending` for GitHub**

  In `lisp/forge-github.el`, add:

  ```elisp
  (cl-defmethod forge--review-publish-pending
    ((_repo forge-github-repository) pr &key callback errorback)
    "Submit the current user's pending review on PR via submitPullRequestReview."
    (forge--query pr
      '(query
        [(id $id ID!)]
        (node [(id $id)]
              (... on PullRequest
                   (reviews [(last 1) (states [PENDING])]
                            (nodes id)))))
      `((id . ,(oref pr their-id)))
      :callback  (lambda (data _headers _status _req)
                   (let* ((nodes (alist-get 'nodes
                                  (alist-get 'reviews
                                   (alist-get 'node data))))
                          (review-id (and nodes (alist-get 'id (car nodes)))))
                     (if (not review-id)
                         (when errorback
                           (funcall errorback
                                    (make-condition-variable "no pending review found") nil nil nil))
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
                         :callback  callback
                         :errorback errorback))))
      :errorback errorback))
  ```

- [ ] **Step 6: Run the full test suite**

  ```sh
  make test 2>&1 | tail -10
  ```

  Expected: all pass including the two new tests.

- [ ] **Step 7: Commit**

  ```sh
  git add lisp/forge-github.el tests/forge-review-test.el
  git commit -m "feat: implement GitHub draft create/edit/publish generics"
  ```

---

### Task 4: GitLab backend — implement draft create, edit, delete, publish

GitLab draft notes API: `GET/POST /projects/:id/merge_requests/:iid/draft_notes`, `PUT/DELETE /projects/:id/merge_requests/:iid/draft_notes/:note_id`, `POST /projects/:id/merge_requests/:iid/draft_notes/bulk_publish`.

**Files:**
- Modify: `lisp/forge-gitlab.el`
- Test: `tests/forge-review-test.el`

**Interfaces:**
- Create: `POST .../draft_notes` with `{note, position: {base_sha, start_sha, head_sha, position_type, new_path, old_path, new_line, old_line}}`. Response: draft note object with `id`.
- Edit: `PUT .../draft_notes/:id` with `{note}`.
- Delete: `DELETE .../draft_notes/:id`. (Already covered by existing `forge--review-delete-comment` GitLab method using `forge--glab-delete` — verify it uses the right path.)
- Publish: `POST .../draft_notes/bulk_publish` with no body (publishes all drafts).
- Pull: `GET .../draft_notes` returns all drafts for the current user. These must be fetched separately (not part of `forge--update-pullreq-review-comments` which reads submitted notes). Add a `forge--update-pullreq-draft-notes` helper called from the pull flow.

- [ ] **Step 1: Write failing tests**

  In `tests/forge-review-test.el`:

  ```elisp
  (ert-deftest forge-review-gitlab-create-draft-posts-to-draft-notes ()
    "forge--review-create-draft for GitLab POSTs to draft_notes and stores row with pending-p t."
    (forge-test--with-db
      (let* ((repo (forge-test--make-gl-repo))
             (pr   (forge-test--make-gl-pullreq repo)))
        (forge-itest--with-sync-rest
          (let ((posted-to nil))
            (cl-letf (((symbol-function 'forge--rest)
                       (lambda (_obj verb path _params &rest _)
                         (setq posted-to (list verb path))
                         ;; Fake draft note response.
                         '((id . 77)
                           (author (username . "alice"))
                           (note . "My draft")
                           (created_at . "2026-07-19T10:00:00Z")
                           (updated_at . "2026-07-19T10:00:00Z")
                           (position
                            (new_path . "src/foo.el")
                            (old_path . "src/foo.el")
                            (new_line . 5)
                            (old_line . nil))))))
              (forge--review-create-draft
               repo pr "My draft" "src/foo.el" 'new 5
               :callback (lambda (rc)
                           (should (equal (oref rc their-id) "77"))
                           (should (oref rc pending-p)))
               :errorback #'error)
              (should (equal (car posted-to) "POST"))))))))

  (ert-deftest forge-review-gitlab-publish-pending-calls-bulk-publish ()
    "forge--review-publish-pending for GitLab POSTs to draft_notes/bulk_publish."
    (forge-test--with-db
      (let* ((repo (forge-test--make-gl-repo))
             (pr   (forge-test--make-gl-pullreq repo)))
        (forge-itest--with-sync-rest
          (let ((path-called nil))
            (cl-letf (((symbol-function 'forge--rest)
                       (lambda (_obj _verb path &rest _)
                         (setq path-called path))))
              (forge--review-publish-pending
               repo pr
               :callback (lambda (&rest _) nil)
               :errorback #'error)
              (should (string-match-p "bulk_publish" path-called))))))))
  ```

- [ ] **Step 2: Run to confirm failures**

  ```sh
  make test 2>&1 | grep -E "forge-review-gitlab-create-draft|forge-review-gitlab-publish"
  ```

  Expected: both `FAILED`

- [ ] **Step 3: Implement `forge--review-create-draft` for GitLab**

  In `lisp/forge-gitlab.el`, add after `forge--update-pullreq-review-comments`:

  ```elisp
  (cl-defmethod forge--review-create-draft
    ((_repo forge-gitlab-repository) pr body path side line &key callback errorback)
    "Create a GitLab draft note on PR at PATH SIDE LINE with BODY."
    (let* ((base-sha  (oref pr base-sha))
           (start-sha (oref pr base-rev))
           (head-sha  (oref pr head-rev))
           (new-line  (and (eq side 'new) line))
           (old-line  (and (eq side 'old) line)))
      (forge--rest pr "POST"
        "/projects/:project/merge_requests/:number/draft_notes"
        (delq nil
              (list (cons 'note body)
                    (cons 'position
                          (delq nil
                                (list (cons 'base_sha          base-sha)
                                      (cons 'start_sha         start-sha)
                                      (cons 'head_sha          head-sha)
                                      (cons 'position_type     "text")
                                      (cons 'new_path          path)
                                      (cons 'old_path          path)
                                      (and new-line (cons 'new_line new-line))
                                      (and old-line (cons 'old_line old-line)))))))
        :callback  (lambda (data _headers _status _req)
                     (when callback
                       (funcall callback
                                (forge--gitlab-draft-note-to-rc pr data))))
        :errorback errorback)))

  (defun forge--gitlab-draft-note-to-rc (pr note)
    "Map a GitLab draft NOTE response into a DB row for PR. Inserts and returns it."
    (let-alist note
      (let* ((id-str (number-to-string .id))
             (rc     (forge-pullreq-review-comment
                      :id           (forge--object-id (oref pr id) id-str)
                      :their-id     id-str
                      :discussion-id nil
                      :number       .id
                      :pullreq      (oref pr id)
                      :new-path     .position.new_path
                      :old-path     .position.old_path
                      :new-line     .position.new_line
                      :old-line     .position.old_line
                      :diff-hunk    nil
                      :outdated-p   nil
                      :resolved-p   nil
                      :reply-to     nil
                      :review-state nil
                      :author       .author.username
                      :body         (forge--sanitize-string .note)
                      :created      .created_at
                      :updated      .updated_at
                      :reactions    nil
                      :pending-p    t)))
        (closql-insert (forge-db) rc t)
        rc)))
  ```

- [ ] **Step 4: Implement `forge--review-edit-draft` for GitLab**

  In `lisp/forge-gitlab.el`, add:

  ```elisp
  (cl-defmethod forge--review-edit-draft
    ((_repo forge-gitlab-repository) pr rc body &key callback errorback)
    "Edit the body of GitLab draft note RC."
    (forge--rest pr "PUT"
      (format "/projects/:project/merge_requests/:number/draft_notes/%s"
              (oref rc number))
      (list (cons 'note body))
      :callback  (lambda (_data _headers _status _req)
                   (oset rc body body)
                   (when callback (funcall callback rc)))
      :errorback errorback))
  ```

- [ ] **Step 5: Verify `forge--review-delete-comment` for GitLab covers draft notes**

  Read the existing GitLab `forge--review-delete-comment` method and confirm it resolves to a path covering draft notes. If it uses `/projects/:project/merge_requests/:topic/notes/:number`, that covers submitted notes only. Draft notes need `/draft_notes/:number`.

  In `lisp/forge-gitlab.el`, find `forge--review-delete-comment` and update to dispatch on `pending-p`:

  ```elisp
  (cl-defmethod forge--review-delete-comment
    ((_repo forge-gitlab-repository) pr rc &key callback errorback)
    "Delete review comment RC on GitLab — draft_notes for pending, notes for submitted."
    (forge--rest pr
      "DELETE"
      (if (oref rc pending-p)
          (format "/projects/:project/merge_requests/:number/draft_notes/%s"
                  (oref rc number))
        "/projects/:project/merge_requests/:topic/notes/:number")
      nil
      :callback  callback
      :errorback errorback))
  ```

- [ ] **Step 6: Implement `forge--review-publish-pending` for GitLab**

  In `lisp/forge-gitlab.el`, add:

  ```elisp
  (cl-defmethod forge--review-publish-pending
    ((_repo forge-gitlab-repository) pr &key callback errorback)
    "Publish all GitLab draft notes on PR via bulk_publish."
    (forge--rest pr "POST"
      "/projects/:project/merge_requests/:number/draft_notes/bulk_publish"
      nil
      :callback  callback
      :errorback errorback))
  ```

- [ ] **Step 7: Run full test suite**

  ```sh
  make test 2>&1 | tail -10
  ```

  Expected: all pass.

- [ ] **Step 8: Commit**

  ```sh
  git add lisp/forge-gitlab.el tests/forge-review-test.el
  git commit -m "feat: implement GitLab draft note create/edit/delete/publish generics"
  ```

---

### Task 5: Rewrite staging — `forge-post-stage` calls the API

Replace the local-only `forge-review--stage-comment` with an API call via `forge--review-create-draft`. The DB row is written in the callback with the real `their-id`.

**Files:**
- Modify: `lisp/forge-review.el`
- Test: `tests/forge-review-test.el`

**Interfaces:**
- Consumes (Tasks 3, 4): `forge--review-create-draft` generic
- `forge-post-stage` reads post buffer state, calls `forge--review-create-draft`, closes buffer on success

- [ ] **Step 1: Write a failing test**

  In `tests/forge-review-test.el`:

  ```elisp
  (ert-deftest forge-review-stage-comment-calls-create-draft-api ()
    "`forge-review--stage-comment' calls forge--review-create-draft, not local insert."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (api-called nil))
        (forge-itest--with-sync-rest
          (forge-test--with-diff-buffer
            "--- a/src/foo.el\n+++ b/src/foo.el\n@@ -1,3 +1,3 @@\n line\n-old\n+new\n"
            (forward-line 3)  ; land on the +new line
            (cl-letf (((symbol-function 'forge--review-create-draft)
                       (lambda (_repo _pr _body _path _side _line &key callback _errorback)
                         (setq api-called t)
                         ;; Simulate callback with a fake rc.
                         (let ((rc (forge-test--make-review-comment
                                    pr :pending-p t :their-id "RC_new1")))
                           (funcall callback rc)))))
              (with-temp-buffer
                (forge-post-mode)
                (setq forge--buffer-post-object pr)
                (setq forge--pre-post-buffer (current-buffer))
                (insert "My staged comment")
                (forge-review--stage-comment
                 repo pr)))))
        (should api-called))))
  ```

- [ ] **Step 2: Run to confirm failure**

  ```sh
  make test 2>&1 | grep "forge-review-stage-comment-calls-create-draft"
  ```

  Expected: `FAILED`

- [ ] **Step 3: Rewrite `forge-review--stage-comment`**

  In `lisp/forge-review.el`, replace `forge-review--stage-comment` (lines ~382–412):

  ```elisp
  (defun forge-review--stage-comment (repo post)
    "Stage a new draft inline review comment via the forge API.
  Reads body and diff-line context from the current post buffer.
  Writes the DB row in the callback once the server responds with a real ID."
    (let* ((pr     (if (forge--childp post 'forge-pullreq) post
                     forge--buffer-post-object))
           (body   (forge--clear-comment-input (buffer-string)))
           (result (with-current-buffer forge--pre-post-buffer
                     (forge--diff-line-number-at-point)))
           (path   (with-current-buffer forge--pre-post-buffer
                     (forge--diff-file-at-point)))
           (context-p (and result (consp (car result))))
           (side   (cond (context-p       'new)
                         ((eq (car result) 'old) 'old)
                         (t               'new)))
           (line   (cond (context-p       (alist-get 'new result))
                         (t               (cdr result)))))
      (forge--review-create-draft repo pr body path side line
        :callback  (lambda (_rc)
                     (forge-refresh-buffer forge--pre-post-buffer)
                     (magit-mode-bury-buffer 'kill))
        :errorback (forge--post-submit-errorback))))
  ```

- [ ] **Step 4: Run full test suite**

  ```sh
  make test 2>&1 | tail -10
  ```

  Expected: all pass.

- [ ] **Step 5: Commit**

  ```sh
  git add lisp/forge-review.el tests/forge-review-test.el
  git commit -m "fix: forge-review--stage-comment calls API draft create instead of local insert"
  ```

---

### Task 6: Rewrite edit — `forge-review--save-comment-edit` calls the API

Replace the local-only `oset rc body` with `forge--review-edit-draft` (for pending) or the existing `forge--submit-edit-post` path (for submitted).

**Files:**
- Modify: `lisp/forge-review.el`
- Test: `tests/forge-review-test.el`

- [ ] **Step 1: Write a failing test**

  ```elisp
  (ert-deftest forge-review-save-comment-edit-calls-api-for-pending ()
    "`forge-review--save-comment-edit' calls forge--review-edit-draft for pending rc."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (rc   (forge-test--make-review-comment
                    pr :pending-p t :their-id "RC_node1" :body "Original"))
             (api-called nil))
        (forge-itest--with-sync-rest
          (cl-letf (((symbol-function 'forge--review-edit-draft)
                     (lambda (_repo _pr _rc body &key callback _errorback)
                       (setq api-called t)
                       (oset rc body body)
                       (funcall callback rc))))
            (with-temp-buffer
              (forge-post-mode)
              (setq forge--buffer-post-object rc)
              (setq forge--pre-post-buffer (current-buffer))
              (insert "Updated body")
              (forge-review--save-comment-edit repo rc))))
        (should api-called)
        (should (equal (oref rc body) "Updated body")))))
  ```

- [ ] **Step 2: Run to confirm failure**

  ```sh
  make test 2>&1 | grep "forge-review-save-comment-edit-calls-api"
  ```

  Expected: `FAILED`

- [ ] **Step 3: Rewrite `forge-review--save-comment-edit`**

  In `lisp/forge-review.el`, replace `forge-review--save-comment-edit` (lines ~414–419):

  ```elisp
  (defun forge-review--save-comment-edit (repo post)
    "Save edits to review comment POST via the forge API."
    (let* ((rc   (if (forge--childp post 'forge-pullreq-review-comment) post
                   forge--buffer-post-object))
           (pr   (closql-get (forge-db) (oref rc pullreq) 'forge-pullreq))
           (body (forge--clear-comment-input (buffer-string))))
      (if (oref rc pending-p)
          (forge--review-edit-draft repo pr rc body
            :callback  (lambda (_rc)
                         (forge-refresh-buffer forge--pre-post-buffer)
                         (magit-mode-bury-buffer 'kill))
            :errorback (forge--post-submit-errorback))
        ;; Submitted comment: use the existing edit-post path.
        (forge--submit-edit-post repo rc))))
  ```

- [ ] **Step 4: Run full test suite**

  ```sh
  make test 2>&1 | tail -10
  ```

  Expected: all pass.

- [ ] **Step 5: Commit**

  ```sh
  git add lisp/forge-review.el tests/forge-review-test.el
  git commit -m "fix: forge-review--save-comment-edit calls API for both pending and submitted comments"
  ```

---

### Task 7: Fix discard — always API-first regardless of `pending-p`

Remove the `pending-p`-gated local-only branch. Both pending and submitted comments go through `forge--review-delete-comment`.

**Files:**
- Modify: `lisp/forge-review.el`
- Test: `tests/forge-review-test.el`

- [ ] **Step 1: Write a failing test**

  ```elisp
  (ert-deftest forge-review-discard-pending-calls-api ()
    "Discarding a pending comment (pending-p t) calls forge--review-delete-comment."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (rc   (forge-test--make-review-comment
                    pr :pending-p t :their-id "RC_node1" :number 201))
             (delete-called nil))
        (cl-letf (((symbol-function 'forge--review-delete-comment)
                   (lambda (_repo _pr _rc &key callback _errorback)
                     (setq delete-called t)
                     (funcall callback nil nil nil nil))))
          (forge-discard-review-comment rc))
        (should delete-called)
        (should (null (closql-get (forge-db) (oref rc id)
                                  'forge-pullreq-review-comment))))))
  ```

- [ ] **Step 2: Run to confirm failure**

  ```sh
  make test 2>&1 | grep "forge-review-discard-pending-calls-api"
  ```

  Expected: `FAILED`

- [ ] **Step 3: Simplify `forge-discard-review-comment`**

  In `lisp/forge-review.el`, replace `forge-discard-review-comment` (lines ~152–166):

  ```elisp
  (defun forge-discard-review-comment (rc)
    "Delete review comment RC from the forge API and the local database."
    (when-let* ((pr   (closql-get (forge-db) (oref rc pullreq) 'forge-pullreq))
                (repo (forge-get-repository pr)))
      (forge--review-delete-comment repo pr rc
        :callback  (lambda (&rest _)
                     (closql-delete rc)
                     (forge-refresh-buffer))
        :errorback (forge--post-submit-errorback))))
  ```

- [ ] **Step 4: Run full test suite**

  ```sh
  make test 2>&1 | tail -10
  ```

  Expected: all pass.

- [ ] **Step 5: Commit**

  ```sh
  git add lisp/forge-review.el tests/forge-review-test.el
  git commit -m "fix: forge-discard-review-comment always calls API, removing local-only branch"
  ```

---

### Task 8: Rewrite submit path — use `forge--review-publish-pending`

Replace `forge--review-submit` (called by `forge-submit-pending-review`) with `forge--review-publish-pending`. Remove `forge--github-pending-review-threads`, `forge--github-flush-pending-review-comments`, and the old async GitLab sequential-POST loop — the server now owns the draft rows, so there is nothing to flush client-side beyond refreshing the topic.

**Files:**
- Modify: `lisp/forge-review.el` (`forge-submit-pending-review`)
- Modify: `lisp/forge-github.el` (remove old helpers, update approve/request-changes flush)
- Modify: `lisp/forge-gitlab.el` (remove old `forge--review-submit` sequential loop)
- Test: `tests/forge-review-test.el`

- [ ] **Step 1: Write a failing test**

  ```elisp
  (ert-deftest forge-review-submit-pending-calls-publish-pending ()
    "`forge-submit-pending-review' calls forge--review-publish-pending and re-pulls topic."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             (_rc  (forge-test--make-review-comment
                    pr :pending-p t :their-id "RC_node1"))
             (publish-called nil)
             (pull-called nil))
        (forge-itest--with-sync-rest
          (cl-letf (((symbol-function 'forge--review-publish-pending)
                     (lambda (_repo _pr &key callback _errorback)
                       (setq publish-called t)
                       (funcall callback nil nil nil nil)))
                    ((symbol-function 'forge--pull-topic)
                     (lambda (&rest _) (setq pull-called t))))
            (forge-submit-pending-review pr)))
        (should publish-called)
        (should pull-called))))
  ```

- [ ] **Step 2: Run to confirm failure**

  ```sh
  make test 2>&1 | grep "forge-review-submit-pending-calls-publish"
  ```

  Expected: `FAILED`

- [ ] **Step 3: Rewrite `forge-submit-pending-review`**

  In `lisp/forge-review.el`, replace `forge-submit-pending-review` (lines ~499–502):

  ```elisp
  (defun forge-submit-pending-review (pullreq)
    "Publish all pending (draft) review comments on PULLREQ."
    (interactive (list (forge-current-pullreq t)))
    (let* ((repo (forge-get-repository pullreq)))
      (forge--review-publish-pending repo pullreq
        :callback  (lambda (&rest _)
                     (forge--pull-topic repo pullreq))
        :errorback (forge--post-submit-errorback))))
  ```

- [ ] **Step 4: Remove `forge--review-submit` generic and all old flush helpers**

  In `lisp/forge-review.el`, delete the `forge--review-submit` generic declaration.

  In `lisp/forge-github.el`, delete:
  - `forge--github-pending-review-comments` (line ~1032)
  - `forge--github-flush-pending-review-comments` (line ~1047)
  - `forge--github-pending-review-threads` (line ~1425)
  - `forge--review-submit` cl-defmethod (line ~1440)

  Update `forge--submit-approve-pullreq` and `forge--submit-request-changes` (lines ~1053, ~1068): these currently bundle pending comment rows into the approve/request-changes REST POST body. Since pending rows now live on the server as drafts (not local constructs), remove the `comments` bundling — the approve/request-changes POST no longer needs to carry review comment payloads.

  In `lisp/forge-gitlab.el`, delete the `forge--review-submit` cl-defmethod (the sequential POST loop, lines ~760–811).

- [ ] **Step 5: Run full test suite**

  ```sh
  make test 2>&1 | tail -10
  ```

  Expected: all pass. Any tests for the old helpers should now be removed or updated.

- [ ] **Step 6: Commit**

  ```sh
  git add lisp/forge-review.el lisp/forge-github.el lisp/forge-gitlab.el tests/forge-review-test.el
  git commit -m "refactor: replace forge--review-submit with forge--review-publish-pending; remove local flush helpers"
  ```

---

### Task 9: Add "Stage + Publish batch" post buffer action (`C-c C-p`)

Add a third action to the post buffer for `new-review-comment`: stage the new comment as a draft, then immediately publish the entire pending batch. Only shown when the PR already has pending comments.

**Files:**
- Modify: `lisp/forge-post.el` (keymap + transient menu)
- Modify: `lisp/forge-review.el` (new `forge-review--stage-and-publish` command)
- Test: `tests/forge-review-test.el`

**Interfaces:**
- Consumes (Tasks 3, 4, 8): `forge--review-create-draft` + `forge--review-publish-pending`

- [ ] **Step 1: Write a failing test**

  ```elisp
  (ert-deftest forge-review-stage-and-publish-creates-draft-then-publishes ()
    "`forge-review--stage-and-publish' calls create-draft then publish-pending."
    (forge-test--with-db
      (let* ((repo (forge-test--make-repo))
             (pr   (forge-test--make-pullreq repo))
             ;; Pre-existing pending comment so the action is available.
             (_existing (forge-test--make-review-comment
                         pr :pending-p t :their-id "RC_existing"))
             (create-called nil)
             (publish-called nil))
        (forge-itest--with-sync-rest
          (cl-letf (((symbol-function 'forge--review-create-draft)
                     (lambda (_repo _pr _body _path _side _line &key callback _errorback)
                       (setq create-called t)
                       (funcall callback (forge-test--make-review-comment
                                          pr :pending-p t :their-id "RC_new2"))))
                    ((symbol-function 'forge--review-publish-pending)
                     (lambda (_repo _pr &key callback _errorback)
                       (setq publish-called t)
                       (funcall callback nil nil nil nil)))
                    ((symbol-function 'forge--pull-topic)
                     (lambda (&rest _) nil)))
            (forge-test--with-diff-buffer
              "--- a/src/foo.el\n+++ b/src/foo.el\n@@ -1,3 +1,3 @@\n line\n-old\n+new\n"
              (forward-line 3)
              (with-temp-buffer
                (forge-post-mode)
                (setq forge--buffer-post-object pr)
                (setq forge--pre-post-buffer (current-buffer))
                (insert "New comment")
                (forge-review--stage-and-publish repo pr)))))
        (should create-called)
        (should publish-called))))
  ```

- [ ] **Step 2: Run to confirm failure**

  ```sh
  make test 2>&1 | grep "forge-review-stage-and-publish"
  ```

  Expected: `FAILED`

- [ ] **Step 3: Add `forge-review--stage-and-publish` to `forge-review.el`**

  In `lisp/forge-review.el`, after `forge-review--stage-comment`:

  ```elisp
  (defun forge-review--stage-and-publish (repo post)
    "Stage a new draft comment then publish all pending comments as a batch review."
    (let* ((pr    (if (forge--childp post 'forge-pullreq) post
                    forge--buffer-post-object))
           (body  (forge--clear-comment-input (buffer-string)))
           (result (with-current-buffer forge--pre-post-buffer
                     (forge--diff-line-number-at-point)))
           (path  (with-current-buffer forge--pre-post-buffer
                    (forge--diff-file-at-point)))
           (context-p (and result (consp (car result))))
           (side  (cond (context-p       'new)
                        ((eq (car result) 'old) 'old)
                        (t               'new)))
           (line  (cond (context-p       (alist-get 'new result))
                        (t               (cdr result)))))
      (forge--review-create-draft repo pr body path side line
        :callback  (lambda (_rc)
                     (forge--review-publish-pending repo pr
                       :callback  (lambda (&rest _)
                                    (forge--pull-topic repo pr)
                                    (magit-mode-bury-buffer 'kill))
                       :errorback (forge--post-submit-errorback)))
        :errorback (forge--post-submit-errorback))))
  ```

- [ ] **Step 4: Add `C-c C-p` keybinding and transient entry to `forge-post.el`**

  In `lisp/forge-post.el`, in `forge-post-mode-map` (line ~109), add:

  ```elisp
  "C-c C-p" #'forge-post-stage-and-publish
  ```

  Add the command:

  ```elisp
  (declare-function forge-review--stage-and-publish "forge-review" (repo post))

  (defun forge-post-stage-and-publish ()
    "Stage the current inline review comment as a draft, then publish the pending batch."
    (interactive)
    (save-buffer)
    (forge-review--stage-and-publish
     (forge-get-repository forge--buffer-post-object)
     forge--buffer-post-object))
  ```

  In `forge-post-menu` transient (line ~320), add a new entry in the Actions group:

  ```elisp
  ("C-p" "Stage + publish batch" forge-post-stage-and-publish
   :if (lambda ()
         (and (eq forge-edit-post-action 'new-review-comment)
              (seq-some (lambda (rc) (oref rc pending-p))
                        (oref forge--buffer-post-object review-comments)))))
  ```

- [ ] **Step 5: Run full test suite**

  ```sh
  make test 2>&1 | tail -10
  ```

  Expected: all pass.

- [ ] **Step 6: Commit**

  ```sh
  git add lisp/forge-post.el lisp/forge-review.el tests/forge-review-test.el
  git commit -m "feat: add C-c C-p stage+publish-batch action to review comment post buffer"
  ```

---

### Task 10: Pull GitLab draft notes alongside submitted notes

GitLab draft notes are not in the regular `GET .../discussions` response. They need a separate `GET .../draft_notes` call during topic pull. Add this to the GitLab pull flow so browser-pending drafts are visible after a `forge-pull`.

**Files:**
- Modify: `lisp/forge-gitlab.el`
- Test: `tests/forge-review-test.el`

- [ ] **Step 1: Write a failing test**

  ```elisp
  (ert-deftest forge-review-gitlab-pull-fetches-draft-notes ()
    "Pulling a GitLab MR fetches /draft_notes and stores rows with pending-p t."
    (forge-test--with-db
      (let* ((repo (forge-test--make-gl-repo))
             (pr   (forge-test--make-gl-pullreq repo))
             (draft-note '((id . 55)
                           (author (username . "carol"))
                           (note . "Draft body")
                           (created_at . "2026-07-19T09:00:00Z")
                           (updated_at . "2026-07-19T09:00:00Z")
                           (position
                            (new_path . "src/bar.el")
                            (old_path . "src/bar.el")
                            (new_line . 10)
                            (old_line . nil)))))
        (forge--update-pullreq-draft-notes repo pr (list draft-note))
        (let* ((all     (oref pr review-comments))
               (pending (seq-filter (lambda (rc) (oref rc pending-p)) all)))
          (should (= (length pending) 1))
          (should (equal (oref (car pending) their-id) "55"))
          (should (equal (oref (car pending) body) "Draft body"))))))
  ```

- [ ] **Step 2: Run to confirm failure**

  ```sh
  make test 2>&1 | grep "forge-review-gitlab-pull-fetches-draft"
  ```

  Expected: `FAILED`

- [ ] **Step 3: Add `forge--update-pullreq-draft-notes` for GitLab**

  In `lisp/forge-gitlab.el`, add after `forge--update-pullreq-review-comments`:

  ```elisp
  (cl-defmethod forge--update-pullreq-draft-notes
    ((_repo forge-gitlab-repository) pr notes)
    "Map GitLab draft NOTES into DB rows for PR with pending-p t."
    (closql-with-transaction (forge-db)
      (dolist (note notes)
        (forge--gitlab-draft-note-to-rc pr note))))
  ```

- [ ] **Step 4: Call it from the GitLab pull flow**

  In `lisp/forge-gitlab.el`, find where `forge--update-pullreq-review-comments` is called after fetching inline discussions (line ~377). Add a subsequent REST call to fetch draft notes and map them:

  ```elisp
  ;; After updating submitted review comments, fetch draft notes for the current user.
  (forge--rest pr "GET"
    "/projects/:project/merge_requests/:number/draft_notes"
    nil
    :callback (lambda (data _headers _status _req)
                (forge--update-pullreq-draft-notes repo pullreq data)))
  ```

  Note: this is a fire-and-forget fetch inside the existing pull callback chain. If it fails (e.g. GitLab version without draft notes API), the error is logged but does not abort the pull.

- [ ] **Step 5: Run full test suite**

  ```sh
  make test 2>&1 | tail -10
  ```

  Expected: all pass.

- [ ] **Step 6: Commit**

  ```sh
  git add lisp/forge-gitlab.el tests/forge-review-test.el
  git commit -m "feat: fetch GitLab draft notes during pull and store as pending review comments"
  ```

---

## Summary of All Code Changes

| File | Change |
|---|---|
| `lisp/forge-github.el` | Pull mapping: `:pending-p (eq state2 'pending)` |
| `lisp/forge-github.el` | Remove `forge--review-submit`, `forge--github-pending-review-threads`, `forge--github-pending-review-comments`, `forge--github-flush-pending-review-comments` |
| `lisp/forge-github.el` | Add `forge--review-create-draft`, `forge--github-draft-node-to-rc`, `forge--review-edit-draft`, `forge--review-publish-pending` methods |
| `lisp/forge-github.el` | Remove `comments` bundling from `forge--submit-approve-pullreq` / `forge--submit-request-changes` |
| `lisp/forge-gitlab.el` | Remove `forge--review-submit` sequential POST loop |
| `lisp/forge-gitlab.el` | Add `forge--review-create-draft`, `forge--gitlab-draft-note-to-rc`, `forge--review-edit-draft`, `forge--review-delete-comment` (draft/submitted dispatch), `forge--review-publish-pending`, `forge--update-pullreq-draft-notes` methods |
| `lisp/forge-gitlab.el` | Pull flow: add draft notes fetch after discussion fetch |
| `lisp/forge-review.el` | Remove `forge--review-submit` generic |
| `lisp/forge-review.el` | Add `forge--review-create-draft`, `forge--review-edit-draft`, `forge--review-publish-pending` generics |
| `lisp/forge-review.el` | Rewrite `forge-review--stage-comment` (API call), `forge-review--save-comment-edit` (API call), `forge-discard-review-comment` (remove pending-p branch), `forge-submit-pending-review` (use publish-pending) |
| `lisp/forge-review.el` | Add `forge-review--stage-and-publish` |
| `lisp/forge-post.el` | Add `C-c C-p` keybinding, `forge-post-stage-and-publish` command, transient entry |
| `tests/forge-review-test.el` | New tests for each of the above |
