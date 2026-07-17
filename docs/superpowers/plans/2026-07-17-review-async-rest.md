# Review REST Async Pattern Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert all review write methods to the async callback pattern used by the rest of the codebase. GitHub methods migrate from `forge--rest` to `forge-mutate`/`forge--query` (GraphQL mutations exist for all operations). GitLab methods migrate from `forge--rest` to `forge--glab-*`. Also fix two pre-existing methods that flush pending rows outside their callback.

**Architecture:** Introduce `forge--rest-synchronous` and `forge--query-synchronous` defvars in `forge-client.el` (default `nil`). When non-nil, these suppress callbacks/errorbacks, forcing synchronous mode for integration tests. All review write methods gain `:callback` (success — UI work, cleanup) and `:errorback` (failure — signal error, leave state intact). GitLab `forge--review-submit` uses sequential chaining. Unit tests stub at the CLOS method level and are unaffected except for the GitLab `forge--review-submit` tests which stub `forge--rest` via `cl-letf` and must be updated to `forge--glab-post`.

**GitHub GraphQL ID mapping** (all already stored in the DB):
- `pr.their-id` → `PullRequest` node ID → used by `addPullRequestReviewThread`, `addPullRequestReview`
- `rc.their-id` → `PullRequestReviewComment` node ID → used by `deletePullRequestReviewComment`
- `rc.discussion-id` → `PullRequestReviewThread` node ID → used by `addPullRequestReviewThreadReply`, `resolveReviewThread`

**Tech Stack:** Emacs Lisp, EIEIO/cl-generic, ghub, ert, closql.

## Global Constraints

- Never call `ghub-request` directly from forge methods — always through `forge--rest`, `forge--query`, or `forge--glab-*`.
- New columns in existing tables must be appended to the end of the slot list.
- Do not add `if/cond` guards on repo type inside `forge-review.el` — use `cl-defgeneric`/`cl-defmethod` dispatch instead.
- **Every async call that does destructive work in `:callback` MUST also supply `:errorback`.** Without errorback, ghub falls through to callback on error, destroying pending rows on failure. Use `(forge--post-submit-errorback)` — it signals an error and leaves state intact.
- **All destructive cleanup (`closql-delete`, flush pending rows, `forge--pull-topic`) MUST live inside `:callback`, never after the `forge--rest`/`forge-mutate` call.**
- `make test` must pass throughout. Integration tests run after each code task: `./scripts/run-integration-tests.sh --github victorhge/forge --gitlab victorhge/forge`

---

### Task 1: Add `forge--rest-synchronous` and `forge--query-synchronous` switches to `forge-client.el`

**Files:**
- Modify: `lisp/forge-client.el:29-76`

**Interfaces:**
- Produces: `forge--rest-synchronous` defvar (default `nil`) — when non-nil, suppresses `:callback`/`:errorback` in `forge--rest`, forcing `ghub-request` into `url-retrieve-synchronously`.
- Produces: `forge--query-synchronous` defvar (default `nil`) — when non-nil, suppresses `:callback`/`:errorback` in `forge--query` and sets `:synchronous t`.

- [ ] **Step 1: Read the current `forge--query` and `forge--rest` definitions**

```elisp
;; forge-client.el:29-36
(cl-defun forge--query ( obj-or-host query variables
                         &key callback errorback noerror narrow until synchronous)
  (declare (indent defun))
  (pcase-let ((`(,host ,forge) (forge--host-arguments obj-or-host)))
    (ghub-query query variables
      :auth 'forge :host host :forge forge
      :callback callback :errorback errorback :noerror noerror
      :narrow narrow :until until :synchronous synchronous)))

;; forge-client.el:65-76
(cl-defun forge--rest ( obj-or-host method resource &optional params
                        &key callback errorback noerror unpaginate)
  (declare (indent defun))
  (pcase-let ((`(,host ,forge) (forge--host-arguments obj-or-host)))
    (ghub-request method
      (if (cl-typep obj-or-host 'forge-object)
          (forge--format-resource obj-or-host resource)
        resource)
      params
      :auth 'forge :host host :forge forge
      :callback callback :errorback errorback :noerror noerror
      :unpaginate unpaginate)))
```

- [ ] **Step 2: Add defvars and update both functions**

```elisp
(defvar forge--rest-synchronous nil
  "When non-nil, `forge--rest' makes synchronous requests.
Suppresses :callback/:errorback so ghub-request uses url-retrieve-synchronously.
Bind to t in integration tests so async review methods block until complete.")

(defvar forge--query-synchronous nil
  "When non-nil, `forge--query' makes synchronous GraphQL requests.
Suppresses :callback/:errorback and sets :synchronous t in ghub-query.
Bind to t in integration tests alongside `forge--rest-synchronous'.")

(cl-defun forge--query ( obj-or-host query variables
                         &key callback errorback noerror narrow until synchronous)
  (declare (indent defun))
  (pcase-let ((`(,host ,forge) (forge--host-arguments obj-or-host)))
    (ghub-query query variables
      :auth 'forge :host host :forge forge
      :callback  (and (not forge--query-synchronous) callback)
      :errorback (and (not forge--query-synchronous) errorback)
      :noerror noerror
      :narrow narrow :until until
      :synchronous (or synchronous forge--query-synchronous))))

(cl-defun forge--rest ( obj-or-host method resource &optional params
                        &key callback errorback noerror unpaginate)
  (declare (indent defun))
  (pcase-let ((`(,host ,forge) (forge--host-arguments obj-or-host)))
    (ghub-request method
      (if (cl-typep obj-or-host 'forge-object)
          (forge--format-resource obj-or-host resource)
        resource)
      params
      :auth 'forge :host host :forge forge
      :callback  (and (not forge--rest-synchronous) callback)
      :errorback (and (not forge--rest-synchronous) errorback)
      :noerror noerror
      :unpaginate unpaginate)))
```

- [ ] **Step 3: Run unit tests**

```sh
make test
```

Expected: all tests pass — change is a no-op when both vars are nil.

- [ ] **Step 4: Commit**

```sh
git add lisp/forge-client.el
git commit -m "feat: add forge--rest-synchronous and forge--query-synchronous switches"
```

---

### Task 2: Add `forge-itest--with-sync-rest` helper macro to the integration test file

**Files:**
- Modify: `tests/forge-review-integration-test.el`

**Interfaces:**
- Consumes: both defvars from Task 1.
- Produces: `forge-itest--with-sync-rest` macro — binds both vars to `t`, forcing all HTTP synchronous for the duration of body.

- [ ] **Step 1: Add the macro after the existing helper functions near the top of the file (around line 75)**

```elisp
(defmacro forge-itest--with-sync-rest (&rest body)
  "Execute BODY with all HTTP requests forced synchronous.
Binds `forge--rest-synchronous' and `forge--query-synchronous' to t,
suppressing callbacks/errorbacks so requests block until complete.
Use around every direct review method call in integration tests."
  (declare (indent 0))
  `(let ((forge--rest-synchronous t)
         (forge--query-synchronous t))
     ,@body))
```

- [ ] **Step 2: Run unit tests**

```sh
make test
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```sh
git add tests/forge-review-integration-test.el
git commit -m "test: add forge-itest--with-sync-rest macro for async review methods"
```

---

### Task 3: Fix `forge--submit-approve-pullreq` and `forge--submit-request-changes` — move flush inside callback

These two pre-existing methods already use `:callback`/`:errorback`, but `forge--github-flush-pending-review-comments` runs **outside** the callback — before the HTTP response arrives. Pending rows are deleted even when the POST fails.

**Files:**
- Modify: `lisp/forge-github.el:1053-1077`

- [ ] **Step 1: Read the current implementations (lines 1053–1077)**

The current code calls `(forge--github-flush-pending-review-comments topic)` on the line *after* `forge-rest` — outside the `:callback` lambda.

- [ ] **Step 2: Capture `(forge--post-submit-callback)` before the request, flush inside the wrapper**

```elisp
(cl-defmethod forge--submit-approve-pullreq
  ((_repo forge-github-repository)
   (topic forge-pullreq))
  (let ((body     (string-trim (buffer-str)))
        (comments (forge--github-pending-review-comments topic))
        (cb       (forge--post-submit-callback)))
    (forge-rest topic "POST" "/repos/:owner/:repo/pulls/:number/reviews"
      ((event "APPROVE")
       (and (not (equal body "")) (body body))
       (and comments (comments comments)))
      :callback  (lambda (value headers status req)
                   (forge--github-flush-pending-review-comments topic)
                   (funcall cb value headers status req))
      :errorback (forge--post-submit-errorback))))

(cl-defmethod forge--submit-request-changes
  ((_repo forge-github-repository)
   (topic forge-pullreq))
  (let ((body     (string-trim (buffer-str)))
        (comments (forge--github-pending-review-comments topic))
        (cb       (forge--post-submit-callback)))
    (forge-rest topic "POST" "/repos/:owner/:repo/pulls/:number/reviews"
      ((event "REQUEST_CHANGES")
       (and (not (equal body "")) (body body))
       (and comments (comments comments)))
      :callback  (lambda (value headers status req)
                   (forge--github-flush-pending-review-comments topic)
                   (funcall cb value headers status req))
      :errorback (forge--post-submit-errorback))))
```

- [ ] **Step 3: Run unit tests**

```sh
make test
```

Expected: all tests pass.

- [ ] **Step 4: Run integration tests**

```sh
./scripts/run-integration-tests.sh --github victorhge/forge --gitlab victorhge/forge
```

Expected: approve and request-changes flows pass; pending comments flushed only on success.

- [ ] **Step 5: Commit**

```sh
git add lisp/forge-github.el
git commit -m "fix: move pending comment flush inside callback for approve and request-changes"
```

---

### Task 4: Convert GitHub review write methods to GraphQL mutations

GitHub provides GraphQL mutations for all review comment operations. These must be used in preference to REST, matching the pattern of all other GitHub write methods in the codebase (`forge-mutate`, `forge--query`).

**GitHub GraphQL mutations used:**
| Operation | Mutation | Key input |
|---|---|---|
| Submit batch review | `addPullRequestReview` with `threads` | `pullRequestId` = `pr.their-id`; `threads[].{path,line,side,body}` |
| Post single comment | `addPullRequestReviewThread` | `pullRequestId` = `pr.their-id`; `path`, `line`, `side`, `body` |
| Reply to thread | `addPullRequestReviewThreadReply` | `pullRequestReviewThreadId` = `rc.discussion-id`; `body` |
| Delete comment | `deletePullRequestReviewComment` | `id` = `rc.their-id` (GraphQL node ID) |

`resolveReviewThread`/`unresolveReviewThread` already use `forge--query` — handled in Task 6.

**Files:**
- Modify: `lisp/forge-github.el:1421-1487`
- Modify: `lisp/forge-review.el` — three generic declarations and `forge-discard-review-comment` caller
- Modify: `tests/forge-review-test.el` — update stubs that used `forge--rest` to use `forge--query`

**Interfaces:**
- Consumes: `forge--query-synchronous` from Task 1.
- Produces: all four GitHub review methods use `forge-mutate`/`forge--query` with `:callback`/`:errorback`.

- [ ] **Step 1: Update `forge--review-submit` (GitHub, line 1421)**

Use `addPullRequestReview` with `threads`. The `DraftPullRequestReviewThread` input fields are `path`, `line`, `side` (`"LEFT"`/`"RIGHT"`), `startLine`, `startSide`, `body`. Flush and pull-topic move into `:callback`:

```elisp
(defun forge--github-pending-review-threads (pr)
  "Return pending review-comment rows for PR as GraphQL DraftPullRequestReviewThread inputs."
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
          (seq-filter (lambda (rc) (oref rc pending-p))
                      (oref pr review-comments))))

(cl-defmethod forge--review-submit ((_repo forge-github-repository) pr)
  "Submit pending review comments for PR to GitHub via GraphQL addPullRequestReview."
  (let* ((repo    (forge-get-repository pr))
         (threads (forge--github-pending-review-threads pr)))
    (forge--query pr
      (ghub--prepare-mutation 'addPullRequestReview)
      (list (cons 'input (delq nil
                               (list (cons 'pullRequestId (oref pr their-id))
                                     (cons 'event "COMMENT")
                                     (cons 'body "")
                                     (and threads
                                          (cons 'threads (vconcat threads)))))))
      :callback  (lambda (&rest _)
                   (forge--github-flush-pending-review-comments pr)
                   (when threads
                     (forge--pull-topic repo pr)))
      :errorback (forge--post-submit-errorback))))
```

- [ ] **Step 2: Update generic declarations in `forge-review.el` — add `&key callback errorback`**

```elisp
(cl-defgeneric forge--review-post-reply (repo pr opener text &key callback errorback)
  "POST a reply to OPENER's discussion thread on REPO.
TEXT is the reply body.  CALLBACK is called on success; ERRORBACK on failure.")

(cl-defgeneric forge--review-delete-comment (repo pr rc &key callback errorback)
  "DELETE review comment RC from REPO's PR.
CALLBACK is called on success; ERRORBACK on failure.")

(cl-defgeneric forge--review-post-comment (repo pr body path side line &key callback errorback)
  "POST a single inline comment at PATH SIDE LINE on PR in REPO.
CALLBACK is called on success; ERRORBACK on failure.")
```

- [ ] **Step 3: Update `forge--review-post-reply` (GitHub, line 1436)**

Use `addPullRequestReviewThreadReply`. `rc.discussion-id` is the `PullRequestReviewThread` node ID:

```elisp
(cl-defmethod forge--review-post-reply
  ((_repo forge-github-repository) _pr opener text &key callback errorback)
  "Reply to OPENER's thread on GitHub via addPullRequestReviewThreadReply."
  (forge--query opener
    (ghub--prepare-mutation 'addPullRequestReviewThreadReply)
    (list (cons 'input (list (cons 'pullRequestReviewThreadId (oref opener discussion-id))
                             (cons 'body text))))
    :callback callback :errorback errorback))
```

- [ ] **Step 4: Update `forge--submit-add-review-reply` (GitHub, line 1466)**

```elisp
(cl-defmethod forge--submit-add-review-reply
  ((repo forge-github-repository) (opener forge-pullreq-review-comment))
  "Submit a reply to review comment OPENER on GitHub."
  (let* ((body (forge--clear-comment-input (buffer-string)))
         (buf  forge--pre-post-buffer))
    (forge--review-post-reply repo nil opener body
      :callback  (lambda (&rest _) (forge-refresh-buffer buf))
      :errorback (forge--post-submit-errorback))))
```

- [ ] **Step 5: Update `forge--review-delete-comment` (GitHub, line 1452)**

Use `deletePullRequestReviewComment`. `rc.their-id` is the `PullRequestReviewComment` node ID:

```elisp
(cl-defmethod forge--review-delete-comment
  ((_repo forge-github-repository) _pr rc &key callback errorback)
  "Delete review comment RC on GitHub via deletePullRequestReviewComment."
  (forge--query rc
    (ghub--prepare-mutation 'deletePullRequestReviewComment)
    (list (cons 'input (list (cons 'id (oref rc their-id)))))
    :callback callback :errorback errorback))
```

Find `forge-discard-review-comment` in `forge-review.el` and move the buffer refresh into a callback:

```elisp
;; Replace:
;;   (forge--review-delete-comment repo pr rc)
;;   (forge-refresh-buffer)
;; With:
(forge--review-delete-comment repo pr rc
  :callback  (lambda (&rest _) (forge-refresh-buffer))
  :errorback (forge--post-submit-errorback))
```

- [ ] **Step 6: Update `forge--review-post-comment` (GitHub, line 1456)**

Use `addPullRequestReviewThread`. `pr.their-id` is the `PullRequest` node ID. `side` becomes `"LEFT"`/`"RIGHT"`:

```elisp
(cl-defmethod forge--review-post-comment
  ((_repo forge-github-repository) pr body path side line &key callback errorback)
  "Post a single inline comment at PATH SIDE LINE on GitHub via addPullRequestReviewThread."
  (forge--query pr
    (ghub--prepare-mutation 'addPullRequestReviewThread)
    (list (cons 'input (list (cons 'pullRequestId (oref pr their-id))
                             (cons 'path path)
                             (cons 'line line)
                             (cons 'side (if (eq side 'old) "LEFT" "RIGHT"))
                             (cons 'body body))))
    :callback callback :errorback errorback))
```

Update `forge--submit-add-single-review-comment` (GitHub, line 1474):

```elisp
(cl-defmethod forge--submit-add-single-review-comment
  ((repo forge-github-repository) (pr forge-pullreq))
  "Post a single immediate inline comment on GitHub."
  (let* ((body   (forge--clear-comment-input (buffer-string)))
         (result (with-current-buffer forge--pre-post-buffer
                   (forge--diff-line-number-at-point)))
         (side   (if (and (consp result) (eq (car result) 'old)) 'old 'new))
         (line   (if (and (consp result) (consp (car result)))
                     (alist-get 'new result)
                   (cdr result)))
         (path   (with-current-buffer forge--pre-post-buffer
                   (forge--diff-file-at-point)))
         (buf    forge--pre-post-buffer))
    (forge--review-post-comment repo pr body path side line
      :callback  (lambda (&rest _) (forge-refresh-buffer buf))
      :errorback (forge--post-submit-errorback))))
```

- [ ] **Step 7: Update unit tests that stub `forge--rest` for GitHub review methods**

The `forge--review-submit` tests stub `forge--rest` via `cl-letf`. Change them to stub `forge--query`:

```sh
grep -n "cl-letf.*forge--rest" tests/forge-review-test.el
```

For each GitHub `forge--review-submit` test, replace:

```elisp
(cl-letf (((symbol-function 'forge--rest)
           (lambda (_obj method resource data &rest _)
             (forge-test--record-rest method resource data))))
  (forge--review-submit repo pr))
```

With:

```elisp
(cl-letf (((symbol-function 'forge--query)
           (lambda (_obj query vars &rest _)
             (forge-test--record-mutate
              (car (cadr query))   ; mutation name symbol
              vars))))
  (forge--review-submit repo pr))
```

- [ ] **Step 8: Run unit tests**

```sh
make test
```

Expected: all tests pass.

- [ ] **Step 9: Run integration tests**

```sh
./scripts/run-integration-tests.sh --github victorhge/forge --gitlab victorhge/forge
```

Expected: all GitHub review tests pass.

- [ ] **Step 10: Commit**

```sh
git add lisp/forge-github.el lisp/forge-review.el tests/forge-review-test.el
git commit -m "feat: convert GitHub review methods to GraphQL mutations"
```

---

### Task 5: Convert GitLab review write methods to async using `forge--glab-*`

**Files:**
- Modify: `lisp/forge-gitlab.el:756-840`
- Modify: `tests/forge-review-test.el` — update stubs from `forge--rest` to `forge--glab-post`

**Interfaces:**
- Consumes: generic declarations updated in Task 4.
- Produces: all GitLab review methods async, using `forge--glab-post`/`forge--glab-put`/`forge--glab-delete`. Matches the pattern of all other GitLab write methods (`forge--submit-create-post`, `forge--submit-edit-post`, etc.). `forge--review-submit` uses sequential chaining.

Note on API choice: all GitLab write operations use `forge--glab-post`/`forge--glab-put`/`forge--glab-delete` — wrappers with GitLab host/auth inference and safe default `:errorback (or errorback (and callback t))`. Raw `forge--rest` for GitLab bypasses this inference.

Note on unit tests: fake-subclass stubs for `forge--review-post-reply` etc. are at the CLOS method level and are unaffected. Only the `forge--review-submit` tests that use `cl-letf` over `forge--rest` need updating to `forge--glab-post`.

- [ ] **Step 1: Update `forge--review-submit` (GitLab, line 756)**

Sequential chaining with `forge--glab-post`. Each callback fires the next POST; when exhausted, delete pending rows and pull topic:

```elisp
(cl-defmethod forge--review-submit ((_repo forge-gitlab-repository) pr)
  "POST each pending review comment for PR to GitLab individually."
  (let* ((repo      (forge-get-repository pr))
         (pending   (seq-filter (lambda (rc) (oref rc pending-p))
                                (oref pr review-comments)))
         (base-sha  (oref pr base-sha))
         (start-sha (oref pr base-rev))
         (head-sha  (oref pr head-rev)))
    (when pending
      (cl-labels
          ((post-next (remaining)
             (if (null remaining)
                 (progn
                   (dolist (rc pending) (closql-delete rc))
                   (forge--pull-topic repo pr))
               (let ((rc (car remaining)))
                 (forge--glab-post pr
                   "/projects/:project/merge_requests/:number/discussions"
                   (list (cons 'body     (oref rc body))
                         (cons 'position (delq nil
                                               (list (cons 'base_sha  base-sha)
                                                     (cons 'start_sha start-sha)
                                                     (cons 'head_sha  head-sha)
                                                     (cons 'position_type "text")
                                                     (cons 'new_path  (oref rc new-path))
                                                     (cons 'old_path  (or (oref rc old-path)
                                                                          (oref rc new-path)))
                                                     (and (oref rc new-line)
                                                          (cons 'new_line (oref rc new-line)))
                                                     (and (oref rc old-line)
                                                          (cons 'old_line (oref rc old-line)))))))
                   :callback  (lambda (&rest _) (post-next (cdr remaining)))
                   :errorback (forge--post-submit-errorback))))))
        (post-next pending)))))
```

- [ ] **Step 2: Update `forge--review-post-reply` (GitLab, line 784) and `forge--submit-add-review-reply`**

```elisp
(cl-defmethod forge--review-post-reply
  ((_repo forge-gitlab-repository) pr opener text &key callback errorback)
  "POST a reply to OPENER's discussion on GitLab."
  (forge--glab-post pr
    (format "/projects/:project/merge_requests/:number/discussions/%s/notes"
            (oref opener discussion-id))
    (list (cons 'body text))
    :callback callback :errorback errorback))

(cl-defmethod forge--submit-add-review-reply
  ((repo forge-gitlab-repository) (opener forge-pullreq-review-comment))
  "Submit a reply to review comment OPENER on GitLab."
  (let* ((pr   (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq))
         (body (forge--clear-comment-input (buffer-string)))
         (buf  forge--pre-post-buffer))
    (forge--review-post-reply repo pr opener body
      :callback  (lambda (&rest _) (forge-refresh-buffer buf))
      :errorback (forge--post-submit-errorback))))
```

- [ ] **Step 3: Update `forge--review-delete-comment` (GitLab, line 799)**

`forge-discard-review-comment` caller already updated in Task 4 Step 5:

```elisp
(cl-defmethod forge--review-delete-comment
  ((_repo forge-gitlab-repository) _pr rc &key callback errorback)
  "DELETE a submitted review comment RC from GitLab."
  (forge--glab-delete rc
    "/projects/:project/merge_requests/:topic/notes/:number"
    :callback callback :errorback errorback))
```

- [ ] **Step 4: Update `forge--review-post-comment` (GitLab, line 804) and `forge--submit-add-single-review-comment`**

```elisp
(cl-defmethod forge--review-post-comment
  ((_repo forge-gitlab-repository) pr body path side line &key callback errorback)
  "POST a single immediate inline comment at PATH SIDE LINE on GitLab."
  (forge--glab-post pr
    "/projects/:project/merge_requests/:number/discussions"
    (list (cons 'body body)
          (cons 'position (delq nil
                                (list (cons 'base_sha  (oref pr base-sha))
                                      (cons 'start_sha (oref pr base-rev))
                                      (cons 'head_sha  (oref pr head-rev))
                                      (cons 'position_type "text")
                                      (cons 'new_path  path)
                                      (cons 'old_path  (or path ""))
                                      (and (eq side 'new) (cons 'new_line line))
                                      (and (eq side 'old) (cons 'old_line line))))))
    :callback callback :errorback errorback))

(cl-defmethod forge--submit-add-single-review-comment
  ((repo forge-gitlab-repository) (pr forge-pullreq))
  "Post a single immediate inline comment on GitLab."
  (let* ((body   (forge--clear-comment-input (buffer-string)))
         (result (with-current-buffer forge--pre-post-buffer
                   (forge--diff-line-number-at-point)))
         (side   (if (and (consp result) (eq (car result) 'old)) 'old 'new))
         (line   (if (and (consp result) (consp (car result)))
                     (alist-get 'new result)
                   (cdr result)))
         (path   (with-current-buffer forge--pre-post-buffer
                   (forge--diff-file-at-point)))
         (buf    forge--pre-post-buffer))
    (forge--review-post-comment repo pr body path side line
      :callback  (lambda (&rest _) (forge-refresh-buffer buf))
      :errorback (forge--post-submit-errorback))))
```

- [ ] **Step 5: Update unit tests that stub `forge--rest` for GitLab `forge--review-submit`**

```sh
grep -n "cl-letf.*forge--rest" tests/forge-review-test.el
```

For each GitLab `forge--review-submit` test, replace the `forge--rest` stub with `forge--glab-post`:

```elisp
;; Replace:
(cl-letf (((symbol-function 'forge--rest)
           (lambda (_obj method resource data &rest _)
             (forge-test--record-rest method resource data))))
  ...)
;; With:
(cl-letf (((symbol-function 'forge--glab-post)
           (lambda (_obj resource data &rest _)
             (forge-test--record-rest "POST" resource data))))
  ...)
```

- [ ] **Step 6: Run unit tests**

```sh
make test
```

Expected: all tests pass.

- [ ] **Step 7: Run integration tests**

```sh
./scripts/run-integration-tests.sh --github victorhge/forge --gitlab victorhge/forge
```

Expected: all review tests pass for both GitHub and GitLab.

- [ ] **Step 8: Commit**

```sh
git add lisp/forge-gitlab.el tests/forge-review-test.el
git commit -m "feat: convert GitLab review methods to forge--glab-* async pattern"
```

---

### Task 6: Fix `forge--review-set-thread-resolved` — replace hardcoded `:synchronous t` with callback

**Files:**
- Modify: `lisp/forge-github.el:1443-1450`
- Modify: `lisp/forge-gitlab.el:791-797`
- Modify: `lisp/forge-review.el` — generic declaration and `forge--set-review-thread-resolved` caller

**Interfaces:**
- Consumes: `forge--query-synchronous` from Task 1.
- Produces: generic accepts `&key callback errorback`; GitHub uses `forge--query`; GitLab uses `forge--glab-put`; caller supplies oset+refresh as callback and `(forge--post-submit-errorback)` as errorback.

- [ ] **Step 1: Update the generic declaration in `forge-review.el`**

```elisp
(cl-defgeneric forge--review-set-thread-resolved (repo pr opener resolved &key callback errorback)
  "Resolve or unresolve OPENER's review thread on REPO's PR, per RESOLVED.
CALLBACK is called on success; ERRORBACK on failure.")
```

- [ ] **Step 2: Update GitHub implementation — replace `:synchronous t` with `:callback`/`:errorback`**

```elisp
(cl-defmethod forge--review-set-thread-resolved
  ((_repo forge-github-repository) _pr opener resolved &key callback errorback)
  "Resolve or unresolve the GitHub review thread at OPENER."
  (forge--query opener
    (ghub--prepare-mutation
     (if resolved 'resolveReviewThread 'unresolveReviewThread))
    (list (cons 'input (list (cons 'threadId (oref opener discussion-id)))))
    :callback callback :errorback errorback))
```

- [ ] **Step 3: Update GitLab implementation — use `forge--glab-put`**

```elisp
(cl-defmethod forge--review-set-thread-resolved
  ((_repo forge-gitlab-repository) pr opener resolved &key callback errorback)
  "PUT resolved=RESOLVED for OPENER's discussion on GitLab."
  (forge--glab-put pr
    (format "/projects/:project/merge_requests/:number/discussions/%s"
            (oref opener discussion-id))
    (list (cons 'resolved (if resolved t :false)))
    :callback callback :errorback errorback))
```

- [ ] **Step 4: Update `forge--set-review-thread-resolved` in `forge-review.el`**

Move `oset` and refresh into callback — only run on success:

```elisp
(defun forge--set-review-thread-resolved (resolved)
  "Resolve or unresolve the review thread at point, per RESOLVED."
  (when-let ((opener (magit-section-value-if 'review-comment)))
    (let* ((pr   (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq))
           (repo (forge-get-repository pr)))
      (forge--review-set-thread-resolved repo pr opener resolved
        :callback  (lambda (&rest _)
                     (oset opener resolved-p resolved)
                     (forge-refresh-buffer))
        :errorback (forge--post-submit-errorback)))))
```

- [ ] **Step 5: Run unit tests**

```sh
make test
```

Expected: all tests pass. Unit tests stub `forge--review-set-thread-resolved` at the CLOS level so `forge--query` is never reached.

- [ ] **Step 6: Run integration tests**

```sh
./scripts/run-integration-tests.sh --github victorhge/forge --gitlab victorhge/forge
```

Expected: resolve/unresolve tests pass for both GitHub and GitLab.

- [ ] **Step 7: Commit**

```sh
git add lisp/forge-github.el lisp/forge-gitlab.el lisp/forge-review.el
git commit -m "feat: convert forge--review-set-thread-resolved to async; GitLab uses forge--glab-put"
```

---

### Task 7: Wrap integration test call sites with `forge-itest--with-sync-rest`

**Files:**
- Modify: `tests/forge-review-integration-test.el`

- [ ] **Step 1: Find all call sites**

```sh
grep -n "forge--review-post-reply\|forge--review-delete-comment\|forge--review-post-comment\|forge--review-set-thread-resolved\|forge--review-submit" \
  tests/forge-review-integration-test.el | grep -v "defun\|deftest\|;;"
```

- [ ] **Step 2: Wrap each call site**

Each bare call of the form:

```elisp
(_ (forge--review-post-reply repo-obj pr-obj opener-rc "body"))
```

becomes:

```elisp
(_ (forge-itest--with-sync-rest
     (forge--review-post-reply repo-obj pr-obj opener-rc "body")))
```

Apply to every `forge--review-delete-comment`, `forge--review-post-comment`, `forge--review-set-thread-resolved`, and `forge--review-submit` call site.

- [ ] **Step 3: Run unit tests**

```sh
make test
```

- [ ] **Step 4: Run integration tests**

```sh
./scripts/run-integration-tests.sh --github victorhge/forge --gitlab victorhge/forge
```

Expected: all tests pass with wrapped call sites.

- [ ] **Step 5: Commit**

```sh
git add tests/forge-review-integration-test.el
git commit -m "test: wrap integration test review method calls with forge-itest--with-sync-rest"
```

---

### Task 8: Verify unit tests need no changes for updated generic signatures

Since `&key` arguments are optional in `cl-defgeneric`, existing call sites without `:callback`/`:errorback` remain valid.

**Files:**
- Conditionally modify: `tests/forge-review-test.el`

- [ ] **Step 1: Run tests and watch for argument errors**

```sh
make test 2>&1 | grep -E "wrong-number|FAILED|Error"
```

Expected: no failures. If `wrong-number-of-arguments` appears, add `:callback nil :errorback nil` at that call site.

- [ ] **Step 2: Commit only if changes were needed**

```sh
git add tests/forge-review-test.el
git commit -m "test: update review method call sites for &key callback errorback signatures"
```

---

### Task 9: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace the "Post-submit sync" bullet in the inline review comment invariants section**

Replace the existing "Post-submit sync" bullet with:

```
- **Post-submit async**: All review write methods use `:callback`/`:errorback`, matching the async pattern used throughout the codebase. All destructive work (flush pending rows, `closql-delete`, `forge--pull-topic`, buffer refresh, `oset` local state) runs inside `:callback` only. `:errorback` is always `(forge--post-submit-errorback)` — signals an error and leaves all state intact so the user can retry.
- **GitHub review GraphQL mutations**: `forge--review-submit` uses `addPullRequestReview` (with `threads`); `forge--review-post-comment` uses `addPullRequestReviewThread`; `forge--review-post-reply` uses `addPullRequestReviewThreadReply` (`rc.discussion-id` = thread node ID); `forge--review-delete-comment` uses `deletePullRequestReviewComment` (`rc.their-id` = comment node ID). All IDs are already stored in the DB from the pull mapping.
- **GitLab review methods**: use `forge--glab-post`/`forge--glab-put`/`forge--glab-delete`, matching all other GitLab write methods. `forge--review-submit` uses `cl-labels` sequential chaining — each `:callback` fires the next POST; when exhausted the DB rows are deleted and the topic is pulled. This avoids the parallel-countdown partial-failure problem.
- **Integration test sync mode**: `forge-itest--with-sync-rest` binds `forge--rest-synchronous` and `forge--query-synchronous` to `t`, forcing `ghub-request`/`ghub-query` into synchronous mode. Wrap every direct review method call in integration tests with this macro.
```

- [ ] **Step 2: Run unit and integration tests one final time**

```sh
make test
./scripts/run-integration-tests.sh --github victorhge/forge --gitlab victorhge/forge
```

Expected: all tests pass.

- [ ] **Step 3: Commit**

```sh
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for async GraphQL/glab review pattern and integration test sync mode"
```
