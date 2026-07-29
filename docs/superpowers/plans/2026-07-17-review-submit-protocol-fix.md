# Review Submit Protocol Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four `forge--submit-*` functions in `forge-review.el` to conform to the two-argument `(repo post)` protocol expected by `forge-post-submit`, rename the two DB-only staging helpers out of the submit namespace, and add regression tests that call through `forge-post-submit` itself so any future arity mismatch in a submit callback is caught at the actual dispatch layer.

**Architecture:** There are two distinct groups. The two API-calling functions (`forge--submit-review-reply`, `forge--submit-add-single-review-comment`) are promoted to `cl-defmethod` generics with `(repo post)` formals — matching every other submit method. The two DB-only staging functions (`forge--submit-add-review-comment`, `forge--submit-edit-review-comment`) are renamed to `forge-review--stage-comment` and `forge-review--save-comment-edit` (out of the submit namespace), updated to accept and ignore `(_repo _post)`, and their call sites updated accordingly. A final task adds four regression tests that call `forge-post-submit` directly (with `save-buffer` stubbed) to pin the two-arg protocol at the real dispatch layer — the exact path that was never exercised before.

**Tech Stack:** Emacs Lisp, ERT, EIEIO `cl-defgeneric`/`cl-defmethod`, `forge-post-submit` dispatch protocol.

## Global Constraints

- Never call `ghub-request` directly — always use `forge--rest` or `forge--query`.
- New columns appended to end of slot list (not relevant here — no schema changes).
- `cl-defmethod` implementations for GitHub go in `forge-github.el`; GitLab in `forge-gitlab.el`.
- `cl-defgeneric` declarations go in `forge-review.el`.
- `make test` must pass after every task: `make -C /home/Build/yren/.emacs.d/elpa/forge test`
- Do not change the behaviour of `forge--submit-add-review-comment` or `forge--submit-edit-review-comment` — only rename and fix arity.

---

### Task 1: Rename DB-only staging helpers and fix their arity

The two functions `forge--submit-add-review-comment` and `forge--submit-edit-review-comment` do no API work — they stage local pending DB rows. They must be removed from the `forge--submit-` namespace (which implies "API submit callback") and given the correct `(_repo _post)` arity so `forge-post-submit` can call them without error.

**Files:**
- Modify: `lisp/forge-review.el` — rename functions, fix formals, update `forge--setup-post-buffer` call sites

**Interfaces:**
- Produces: `forge-review--stage-comment (_repo _post)` — replaces `forge--submit-add-review-comment`
- Produces: `forge-review--save-comment-edit (_repo _post)` — replaces `forge--submit-edit-review-comment`

- [ ] **Step 1: Rename `forge--submit-add-review-comment` and fix arity**

In `lisp/forge-review.el`, change:
```elisp
(defun forge--submit-add-review-comment ()
  "Submit a new inline review comment from the current post buffer."
  (let* ((pr      forge--buffer-post-object)
```
to:
```elisp
(defun forge-review--stage-comment (_repo _post)
  "Stage a new pending inline review comment from the current post buffer."
  (let* ((pr      forge--buffer-post-object)
```

- [ ] **Step 2: Rename `forge--submit-edit-review-comment` and fix arity**

In `lisp/forge-review.el`, change:
```elisp
(defun forge--submit-edit-review-comment ()
  "Save edits to the current review comment."
  (let* ((rc   forge--buffer-post-object)
```
to:
```elisp
(defun forge-review--save-comment-edit (_repo _post)
  "Save edits to the current review comment."
  (let* ((rc   forge--buffer-post-object)
```

- [ ] **Step 3: Update the two `forge--setup-post-buffer` call sites that reference the old names**

In `lisp/forge-review.el`, find the `forge-add-review-comment` command (around line 452) and change:
```elisp
      #'forge--submit-add-review-comment
```
to:
```elisp
      #'forge-review--stage-comment
```

Find the `forge-edit-review-comment` command (around line 463) and change:
```elisp
      #'forge--submit-edit-review-comment
```
to:
```elisp
      #'forge-review--save-comment-edit
```

- [ ] **Step 4: Run the tests to verify nothing broke**

```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass. The two renamed tests (`forge-review-write-submit-add-review-comment-stages-pending`, `forge-review-write-submit-edit-review-comment-updates-body`) will now fail because they call the old names — that is expected and will be fixed in Task 2.

- [ ] **Step 5: Commit**

```sh
cd /home/Build/yren/.emacs.d/elpa/forge
git add lisp/forge-review.el
git commit -m "refactor: rename DB-only staging helpers out of forge--submit- namespace"
```

---

### Task 2: Update tests that call the old staging helper names and add dispatch-path tests

Fix the two tests that directly called the renamed functions, and add new tests that call through `forge-post-submit` — the actual dispatch path — so arity mismatches are caught at that layer.

**Files:**
- Modify: `tests/forge-review-test.el` — fix renamed function calls, add `forge-post-submit` dispatch tests

**Interfaces:**
- Consumes: `forge-review--stage-comment (_repo _post)` from Task 1
- Consumes: `forge-review--save-comment-edit (_repo _post)` from Task 1

- [ ] **Step 1: Fix the test that calls `forge--submit-add-review-comment`**

In `tests/forge-review-test.el`, find the two occurrences of `forge--submit-add-review-comment` in the ERT tests and replace with `forge-review--stage-comment`:

```elisp
;; In forge-review-write-submit-add-review-comment-stages-pending:
(forge-review--stage-comment nil nil)

;; In forge-review-write-submit-add-review-comment-context-line:
(forge-review--stage-comment nil nil)
```

Note: the DB-only functions ignore `_repo` and `_post`, so passing `nil nil` is correct in tests.

- [ ] **Step 2: Fix the test that calls `forge--submit-edit-review-comment`**

In `tests/forge-review-test.el`, find the occurrence of `forge--submit-edit-review-comment` and replace:
```elisp
(forge-review--save-comment-edit nil nil)
```

- [ ] **Step 3: Add a helper that simulates `forge-post-submit` dispatch**

The real `forge-post-submit` reads from buffer-locals and calls `(funcall forge--submit-post-function repo post)`. We need a test helper that does the same without needing a live Emacs post buffer. Add this after the existing helpers:

```elisp
(defun forge-test--invoke-submit-fn (fn repo post)
  "Simulate `forge-post-submit' by calling FN with REPO and POST.
This exercises the two-argument dispatch protocol directly."
  (funcall fn repo post))
```

- [ ] **Step 4: Add dispatch-path test for `forge-review--stage-comment`**

Add this test after `forge-review-write-submit-add-review-comment-context-line`:

```elisp
(ert-deftest forge-review-write-stage-comment-dispatch-protocol ()
  "`forge-review--stage-comment' accepts the two-arg (repo post) protocol used by
`forge-post-submit' — verifies arity is not wrong-number-of-arguments."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo)))
      (with-temp-buffer
        (insert forge-test--simple-diff)
        (diff-mode)
        (goto-char (point-min))
        (re-search-forward "^+(added-line-9)")
        (beginning-of-line)
        (let ((diff-buf (current-buffer)))
          (with-temp-buffer
            (insert "Dispatch protocol test")
            (setq-local forge--buffer-post-object pr)
            (setq-local forge--pre-post-buffer diff-buf)
            ;; Call through the two-arg protocol, not directly
            (forge-test--invoke-submit-fn #'forge-review--stage-comment repo pr))))
      (let* ((all (oref pr review-comments)))
        (should (= (length all) 1))
        (should (eq (oref (car all) pending-p) t))
        (should (equal (oref (car all) body) "Dispatch protocol test"))))))
```

- [ ] **Step 5: Add dispatch-path test for `forge-review--save-comment-edit`**

```elisp
(ert-deftest forge-review-write-save-comment-edit-dispatch-protocol ()
  "`forge-review--save-comment-edit' accepts the two-arg (repo post) protocol."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :body "Original")))
      (closql-insert (forge-db) rc t)
      (with-temp-buffer
        (insert "Updated via dispatch")
        (setq-local forge--buffer-post-object rc)
        (setq-local forge--pre-post-buffer (current-buffer))
        (forge-test--invoke-submit-fn #'forge-review--save-comment-edit repo rc))
      (should (equal (oref (closql-get (forge-db) "rc-1"
                                       'forge-pullreq-review-comment)
                           body)
                     "Updated via dispatch")))))
```

- [ ] **Step 6: Run the full test suite**

```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass including the two new dispatch-protocol tests.

- [ ] **Step 7: Commit**

```sh
cd /home/Build/yren/.emacs.d/elpa/forge
git add tests/forge-review-test.el
git commit -m "tests: fix renamed staging helper calls and add dispatch-protocol coverage"
```

---

### Task 3: Promote `forge--submit-review-reply` to a `cl-defgeneric` + `cl-defmethod`

`forge--submit-review-reply` makes an API call via `forge--review-post-reply`. It should follow the same pattern as all other API-submitting callbacks: be a `cl-defgeneric` in `forge-review.el` with `cl-defmethod` implementations in each backend file, and take the `(repo post)` formals.

**Files:**
- Modify: `lisp/forge-review.el` — replace `defun` with `cl-defgeneric`; remove internal `repo` lookup
- Modify: `lisp/forge-github.el` — add `cl-defmethod forge--submit-review-reply`
- Modify: `lisp/forge-gitlab.el` — add `cl-defmethod forge--submit-review-reply`

**Interfaces:**
- Produces: `(cl-defgeneric forge--submit-review-reply (repo post))` in `forge-review.el`
- Produces: `(cl-defmethod forge--submit-review-reply ((_repo forge-github-repository) (opener forge-pullreq-review-comment)))` in `forge-github.el`
- Produces: `(cl-defmethod forge--submit-review-reply ((_repo forge-gitlab-repository) (opener forge-pullreq-review-comment)))` in `forge-gitlab.el`

- [ ] **Step 1: Replace `defun forge--submit-review-reply` with a `cl-defgeneric` in `forge-review.el`**

Remove the entire existing `defun`:
```elisp
(defun forge--submit-review-reply ()
  "Submit a reply to the review comment in the current post buffer."
  (let* ((opener forge--buffer-post-object)
         (pr     (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq))
         (repo   (forge-get-repository pr))
         (body   (forge--clear-comment-input (buffer-string))))
    (forge--review-post-reply repo pr opener body)
    (forge-refresh-buffer forge--pre-post-buffer)))
```

Replace with:
```elisp
(cl-defgeneric forge--submit-review-reply (repo opener)
  "Submit a reply to the review comment OPENER in the current post buffer.
REPO is the `forge-repository' the pull request belongs to.")
```

- [ ] **Step 2: Add `cl-defmethod forge--submit-review-reply` to `forge-github.el`**

Add after the existing `forge--review-post-comment` method (near the end of the review section):

```elisp
(cl-defmethod forge--submit-review-reply
  ((_repo forge-github-repository) (opener forge-pullreq-review-comment))
  (let* ((pr   (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq))
         (body (forge--clear-comment-input (buffer-string))))
    (forge--review-post-reply _repo pr opener body)
    (forge-refresh-buffer forge--pre-post-buffer)))
```

- [ ] **Step 3: Add `cl-defmethod forge--submit-review-reply` to `forge-gitlab.el`**

Add after the existing `forge--review-post-comment` method:

```elisp
(cl-defmethod forge--submit-review-reply
  ((_repo forge-gitlab-repository) (opener forge-pullreq-review-comment))
  (let* ((pr   (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq))
         (body (forge--clear-comment-input (buffer-string))))
    (forge--review-post-reply _repo pr opener body)
    (forge-refresh-buffer forge--pre-post-buffer)))
```

- [ ] **Step 4: Run the tests**

```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass. The existing `forge-review-write-submit-review-reply-posts-to-api` test verifies the API call — it sets `forge--buffer-post-object` to an `opener` and calls `forge--submit-review-reply` directly, which now dispatches on the repo class via the fake subclass.

Wait — the existing test calls `(forge--submit-review-reply)` with zero args. It must be updated: see Step 5.

- [ ] **Step 5: Update the existing review-reply test to use the new signature**

In `tests/forge-review-test.el`, find `forge-review-write-submit-review-reply-posts-to-api` and change:

```elisp
;; Old: (forge--submit-review-reply)
;; New: call through invoke helper with repo and opener
(forge-test--invoke-submit-fn #'forge--submit-review-reply repo opener)
```

The full test should become:
```elisp
(ert-deftest forge-review-write-submit-review-reply-posts-to-api ()
  "`forge--submit-review-reply' calls forge--review-post-reply with the opener."
  (forge-test--with-db
    (let* ((repo   (forge-test--make-repo))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :id "rc-opener" :database-id 999 :discussion-id "t1")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (with-temp-buffer
                     (insert "Reply body")
                     (setq-local forge--buffer-post-object opener)
                     (setq-local forge--pre-post-buffer (current-buffer))
                     (forge-test--invoke-submit-fn #'forge--submit-review-reply repo opener)))))
        (should (string-match-p "pulls/42/comments" (plist-get req :resource)))
        (should (= (alist-get 'in_reply_to_id (plist-get req :data)) 999))
        (should (equal (alist-get 'body (plist-get req :data)) "Reply body"))))))
```

- [ ] **Step 6: Also add a dispatch-path test for the stub test class**

The existing test already goes through the fake repo subclass, so dispatch is exercised. The `forge-test-github-repository` has `forge--review-post-reply` stubbed. We need `forge--submit-review-reply` stubbed on the test class too — but since the method body in `forge-github.el` calls `forge--review-post-reply`, and the test class overrides that, no separate stub is needed. The call chain is:

```
forge-test--invoke-submit-fn
  → forge--submit-review-reply (forge-github-repository method, inherited by test class)
    → forge--review-post-reply (forge-test-github-repository stub, records request)
```

Confirm by running:
```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass.

- [ ] **Step 7: Commit**

```sh
cd /home/Build/yren/.emacs.d/elpa/forge
git add lisp/forge-review.el lisp/forge-github.el lisp/forge-gitlab.el tests/forge-review-test.el
git commit -m "refactor: promote forge--submit-review-reply to cl-defgeneric with backend methods"
```

---

### Task 4: Promote `forge--submit-add-single-review-comment` to a `cl-defgeneric` + `cl-defmethod`

Same promotion as Task 3, for the other API-calling submit function.

**Files:**
- Modify: `lisp/forge-review.el` — replace `defun` with `cl-defgeneric`
- Modify: `lisp/forge-github.el` — add `cl-defmethod forge--submit-add-single-review-comment`
- Modify: `lisp/forge-gitlab.el` — add `cl-defmethod forge--submit-add-single-review-comment`

**Interfaces:**
- Produces: `(cl-defgeneric forge--submit-add-single-review-comment (repo post))` in `forge-review.el`
- Produces: `(cl-defmethod forge--submit-add-single-review-comment ((_repo forge-github-repository) (pr forge-pullreq)))` in `forge-github.el`
- Produces: `(cl-defmethod forge--submit-add-single-review-comment ((_repo forge-gitlab-repository) (pr forge-pullreq)))` in `forge-gitlab.el`

- [ ] **Step 1: Replace `defun forge--submit-add-single-review-comment` with `cl-defgeneric` in `forge-review.el`**

Remove:
```elisp
(defun forge--submit-add-single-review-comment ()
  "Post a new inline comment directly to the forge API (no staging)."
  (let* ((pr      forge--buffer-post-object)
         (repo    (forge-get-repository pr))
         (body    (forge--clear-comment-input (buffer-string)))
         (result  (with-current-buffer forge--pre-post-buffer
                    (forge--diff-line-number-at-point)))
         (side    (if (and (consp result) (eq (car result) 'old)) 'old 'new))
         (line    (if (and (consp result) (consp (car result)))
                      (alist-get 'new result)
                    (cdr result)))
         (path    (with-current-buffer forge--pre-post-buffer
                    (forge--diff-file-at-point))))
    (forge--review-post-comment repo pr body path side line)
    (forge-refresh-buffer forge--pre-post-buffer)))
```

Replace with:
```elisp
(cl-defgeneric forge--submit-add-single-review-comment (repo post)
  "Post a single immediate inline comment from the current post buffer.
REPO is the `forge-repository'; POST is the `forge-pullreq'.")
```

- [ ] **Step 2: Add `cl-defmethod forge--submit-add-single-review-comment` to `forge-github.el`**

Add after `forge--submit-review-reply` (added in Task 3):

```elisp
(cl-defmethod forge--submit-add-single-review-comment
  ((_repo forge-github-repository) (pr forge-pullreq))
  (let* ((body   (forge--clear-comment-input (buffer-string)))
         (result (with-current-buffer forge--pre-post-buffer
                   (forge--diff-line-number-at-point)))
         (side   (if (and (consp result) (eq (car result) 'old)) 'old 'new))
         (line   (if (and (consp result) (consp (car result)))
                     (alist-get 'new result)
                   (cdr result)))
         (path   (with-current-buffer forge--pre-post-buffer
                   (forge--diff-file-at-point))))
    (forge--review-post-comment _repo pr body path side line)
    (forge-refresh-buffer forge--pre-post-buffer)))
```

- [ ] **Step 3: Add `cl-defmethod forge--submit-add-single-review-comment` to `forge-gitlab.el`**

Add after `forge--submit-review-reply` (added in Task 3):

```elisp
(cl-defmethod forge--submit-add-single-review-comment
  ((_repo forge-gitlab-repository) (pr forge-pullreq))
  (let* ((body   (forge--clear-comment-input (buffer-string)))
         (result (with-current-buffer forge--pre-post-buffer
                   (forge--diff-line-number-at-point)))
         (side   (if (and (consp result) (eq (car result) 'old)) 'old 'new))
         (line   (if (and (consp result) (consp (car result)))
                     (alist-get 'new result)
                   (cdr result)))
         (path   (with-current-buffer forge--pre-post-buffer
                   (forge--diff-file-at-point))))
    (forge--review-post-comment _repo pr body path side line)
    (forge-refresh-buffer forge--pre-post-buffer)))
```

- [ ] **Step 4: Update the existing single-review-comment test**

In `tests/forge-review-test.el`, find `forge-review-write-submit-add-single-review-comment-posts-to-api` and update the call from zero-arg to two-arg dispatch:

```elisp
(ert-deftest forge-review-write-submit-add-single-review-comment-posts-to-api ()
  "`forge--submit-add-single-review-comment' calls forge--review-post-comment."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo)))
      (with-temp-buffer
        (insert forge-test--simple-diff)
        (diff-mode)
        (goto-char (point-min))
        (re-search-forward "^+(added-line-9)")
        (beginning-of-line)
        (let* ((diff-buf (current-buffer))
               (req (forge-test--capture-request
                      (with-temp-buffer
                        (insert "Immediate comment")
                        (setq-local forge--buffer-post-object pr)
                        (setq-local forge--pre-post-buffer diff-buf)
                        (forge-test--invoke-submit-fn
                         #'forge--submit-add-single-review-comment repo pr)))))
          (should (equal (plist-get req :method) "POST"))
          (should (string-match-p "pulls/42/comments" (plist-get req :resource)))
          (should (equal (alist-get 'body (plist-get req :data)) "Immediate comment"))
          (should (= (alist-get 'line (plist-get req :data)) 9)))))))
```

- [ ] **Step 5: Run the full test suite**

```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass.

- [ ] **Step 6: Commit**

```sh
cd /home/Build/yren/.emacs.d/elpa/forge
git add lisp/forge-review.el lisp/forge-github.el lisp/forge-gitlab.el tests/forge-review-test.el
git commit -m "refactor: promote forge--submit-add-single-review-comment to cl-defgeneric with backend methods"
```

---

### Task 5: Gap — add `forge-test-{github,gitlab}-repository` stubs for the two new generics

The test fake subclasses in `forge-review-test.el` must override the two new generic methods so tests don't accidentally dispatch to the real backend methods (which would try to hit the network). Without this, any test that calls through the dispatch layer on a `forge-test-*` instance would fall through to the `forge-github-repository` method and attempt a network call.

**Files:**
- Modify: `tests/forge-review-test.el` — add stub methods on `forge-test-github-repository` and `forge-test-gitlab-repository`

**Interfaces:**
- Consumes: `forge--submit-review-reply (repo opener)` from Task 3
- Consumes: `forge--submit-add-single-review-comment (repo post)` from Task 4

- [ ] **Step 1: Add stub for `forge--submit-review-reply` on the GitHub test class**

After the existing `forge--review-post-reply` stub on `forge-test-github-repository`, add:

```elisp
(cl-defmethod forge--submit-review-reply
  ((_repo forge-test-github-repository) (opener forge-pullreq-review-comment))
  (let* ((pr   (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq))
         (body (forge--clear-comment-input (buffer-string))))
    (forge--review-post-reply _repo pr opener body)
    (forge-refresh-buffer forge--pre-post-buffer)))
```

Wait — this would call `forge--review-post-reply` on the test class, which *is* already stubbed. The issue is we don't want to duplicate the method body. A cleaner solution: since `forge-test-github-repository` inherits from `forge-github-repository`, and the method in `forge-github.el` calls `forge--review-post-reply` (which the test class already stubs), there is **no need** for a separate stub — the inheritance chain already gives us the right behaviour:

```
forge--submit-review-reply (forge-github-repository method, inherited)
  → forge--review-post-reply (forge-test-github-repository stub, records request)
```

Verify this is correct by re-running tests from Task 3 Step 6. If the test passes without an explicit stub on `forge-test-github-repository`, no stub is needed. Document this in a comment above the test class:

```elisp
;; Note: forge--submit-review-reply and forge--submit-add-single-review-comment
;; are NOT stubbed here.  They inherit the forge-github-repository cl-defmethod
;; implementations, which internally call forge--review-post-reply /
;; forge--review-post-comment — those ARE stubbed, so no network calls escape.
```

- [ ] **Step 2: Add the same note for the GitLab test class**

```elisp
;; Note: forge--submit-review-reply and forge--submit-add-single-review-comment
;; are NOT stubbed here.  They inherit the forge-gitlab-repository cl-defmethod
;; implementations, which internally call forge--review-post-reply /
;; forge--review-post-comment — those ARE stubbed, so no network calls escape.
```

- [ ] **Step 3: Run the full test suite one final time**

```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```sh
cd /home/Build/yren/.emacs.d/elpa/forge
git add tests/forge-review-test.el
git commit -m "tests: document inheritance chain for submit-method stubs in test fake classes"
```

---

### Task 6: Add regression tests through `forge-post-submit` to close the gap

This task exists specifically to close the gap that allowed the original arity mismatch to go undetected. Tests in Tasks 2–4 call submit functions via `forge-test--invoke-submit-fn`, which calls `(funcall fn repo post)` directly. That bypasses `forge-post-submit` itself — the real dispatcher. If a future submit callback is again written with zero args, none of those tests would catch it, because they never go through `forge-post-submit`.

These tests call `forge-post-submit` with `forge--submit-post-function` set to each review submit function, replicating the exact path a user triggers with `C-c C-c` in a post buffer.

`forge-post-submit` calls `(save-buffer)` which requires a real file on disk. Use `cl-letf` to stub it as a no-op.

**Files:**
- Modify: `tests/forge-review-test.el` — add four `forge-post-submit` dispatch-path regression tests

**Interfaces:**
- Consumes: `forge-review--stage-comment (_repo _post)` from Task 1
- Consumes: `forge-review--save-comment-edit (_repo _post)` from Task 1
- Consumes: `forge--submit-review-reply (repo opener)` from Task 3
- Consumes: `forge--submit-add-single-review-comment (repo post)` from Task 4

- [ ] **Step 1: Add a helper macro that simulates `C-c C-c` in a post buffer**

Add this macro after `forge-test--invoke-submit-fn`:

```elisp
(defmacro forge-test--with-post-buffer (submit-fn post-obj &rest body)
  "Run BODY in a temp buffer configured as a forge post buffer.
Sets `forge--submit-post-function' to SUBMIT-FN and
`forge--buffer-post-object' to POST-OBJ.  Stubs `save-buffer' as a
no-op so `forge-post-submit' can be called without a real file."
  (declare (indent 2))
  `(with-temp-buffer
     (setq-local forge--submit-post-function ,submit-fn)
     (setq-local forge--buffer-post-object ,post-obj)
     (cl-letf (((symbol-function 'save-buffer) #'ignore))
       ,@body)))
```

- [ ] **Step 2: Add regression test for `forge-review--stage-comment` via `forge-post-submit`**

```elisp
(ert-deftest forge-review-regression-stage-comment-via-forge-post-submit ()
  "Calling `forge-post-submit' with forge-review--stage-comment as
`forge--submit-post-function' must not signal wrong-number-of-arguments.
This is the regression test for the original arity-mismatch bug."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo)))
      (with-temp-buffer
        (insert forge-test--simple-diff)
        (diff-mode)
        (goto-char (point-min))
        (re-search-forward "^+(added-line-9)")
        (beginning-of-line)
        (let ((diff-buf (current-buffer)))
          (forge-test--with-post-buffer #'forge-review--stage-comment pr
            (insert "Regression test body")
            (setq-local forge--pre-post-buffer diff-buf)
            ;; This is the actual regression: forge-post-submit calls
            ;; (funcall forge--submit-post-function repo post).
            ;; If the arity is wrong it signals wrong-number-of-arguments.
            (should-not (condition-case err
                            (progn (forge-post-submit) nil)
                          (wrong-number-of-arguments err)))))
        (should (= (length (oref pr review-comments)) 1))))))
```

- [ ] **Step 3: Add regression test for `forge-review--save-comment-edit` via `forge-post-submit`**

```elisp
(ert-deftest forge-review-regression-save-comment-edit-via-forge-post-submit ()
  "Calling `forge-post-submit' with forge-review--save-comment-edit must not
signal wrong-number-of-arguments."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :body "Original")))
      (closql-insert (forge-db) rc t)
      (forge-test--with-post-buffer #'forge-review--save-comment-edit rc
        (insert "Edited body")
        (setq-local forge--pre-post-buffer (current-buffer))
        (should-not (condition-case err
                        (progn (forge-post-submit) nil)
                      (wrong-number-of-arguments err))))
      (should (equal (oref (closql-get (forge-db) "rc-1"
                                       'forge-pullreq-review-comment)
                           body)
                     "Edited body")))))
```

- [ ] **Step 4: Add regression test for `forge--submit-review-reply` via `forge-post-submit`**

```elisp
(ert-deftest forge-review-regression-submit-review-reply-via-forge-post-submit ()
  "Calling `forge-post-submit' with forge--submit-review-reply must not
signal wrong-number-of-arguments."
  (forge-test--with-db
    (let* ((repo   (forge-test--make-repo))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :id "rc-opener" :database-id 999 :discussion-id "t1")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge-test--with-post-buffer #'forge--submit-review-reply opener
                     (insert "Reply via forge-post-submit")
                     (setq-local forge--pre-post-buffer (current-buffer))
                     (should-not (condition-case err
                                     (progn (forge-post-submit) nil)
                                   (wrong-number-of-arguments err)))))))
        (should (string-match-p "pulls/42/comments" (plist-get req :resource)))
        (should (equal (alist-get 'body (plist-get req :data))
                       "Reply via forge-post-submit"))))))
```

- [ ] **Step 5: Add regression test for `forge--submit-add-single-review-comment` via `forge-post-submit`**

```elisp
(ert-deftest forge-review-regression-submit-single-comment-via-forge-post-submit ()
  "Calling `forge-post-submit' with forge--submit-add-single-review-comment must not
signal wrong-number-of-arguments."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo)))
      (with-temp-buffer
        (insert forge-test--simple-diff)
        (diff-mode)
        (goto-char (point-min))
        (re-search-forward "^+(added-line-9)")
        (beginning-of-line)
        (let* ((diff-buf (current-buffer))
               (req (forge-test--capture-request
                      (forge-test--with-post-buffer
                          #'forge--submit-add-single-review-comment pr
                        (insert "Immediate via forge-post-submit")
                        (setq-local forge--pre-post-buffer diff-buf)
                        (should-not (condition-case err
                                        (progn (forge-post-submit) nil)
                                      (wrong-number-of-arguments err)))))))
          (should (string-match-p "pulls/42/comments" (plist-get req :resource)))
          (should (equal (alist-get 'body (plist-get req :data))
                         "Immediate via forge-post-submit")))))))
```

- [ ] **Step 6: Run the full test suite**

```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass including the four new regression tests.

- [ ] **Step 7: Commit**

```sh
cd /home/Build/yren/.emacs.d/elpa/forge
git add tests/forge-review-test.el
git commit -m "tests: add forge-post-submit regression tests to catch arity mismatches in submit callbacks"
```

---

### Task 7: Update CLAUDE.md and forge.org to reflect the protocol fix

All four renamed/promoted functions are referenced in CLAUDE.md and the naming-convention table is now inaccurate. Update both documents.

**Files:**
- Modify: `CLAUDE.md` — update Key files section, Inline review comment invariants, and naming conventions table
- Modify: `docs/forge.org` — no user-visible behaviour changed; no update needed

**Interfaces:** none — documentation only

- [ ] **Step 1: Update the Key files section in CLAUDE.md**

Find the line listing the review-comment generics in `forge-github.el`/`forge-gitlab.el`:
```
`forge--update-pullreq-review-comments`, `forge--review-submit`, `forge--review-post-reply`, `forge--review-set-thread-resolved`, `forge--review-delete-comment`, `forge--review-post-comment`
```
Add the two new generics:
```
`forge--update-pullreq-review-comments`, `forge--review-submit`, `forge--review-post-reply`, `forge--review-set-thread-resolved`, `forge--review-delete-comment`, `forge--review-post-comment`, `forge--submit-review-reply`, `forge--submit-add-single-review-comment`
```

- [ ] **Step 2: Update the `forge-review.el` Key files entry**

Find:
```
interactive commands (`forge-add-review-comment`, `forge-reply-to-review-comment`, `forge-resolve/unresolve-review-thread`, `forge-comment-pullreq`, etc.).
```
Append the staging helpers and clarify the submit protocol:
```
interactive commands (`forge-add-review-comment`, `forge-reply-to-review-comment`, `forge-resolve/unresolve-review-thread`, `forge-comment-pullreq`, etc.); DB-only staging helpers `forge-review--stage-comment` and `forge-review--save-comment-edit` (used as `forge--submit-post-function` callbacks for local-only operations).
```

- [ ] **Step 3: Update the Pending comments invariant in CLAUDE.md**

Find:
```
- **Pending comments**: `pending-p t` rows are locally staged. `forge-comment-pullreq`, `forge--submit-approve-pullreq`, and `forge--submit-request-changes` all flush them. `forge-add-single-review-comment` bypasses staging and posts directly.
```
Replace with:
```
- **Pending comments**: `pending-p t` rows are locally staged. `forge-comment-pullreq`, `forge--submit-approve-pullreq`, and `forge--submit-request-changes` all flush them. `forge-add-single-review-comment` bypasses staging and posts directly.
- **Submit callback protocol**: all functions assigned to `forge--submit-post-function` must accept exactly two arguments `(repo post)`. DB-only staging callbacks (`forge-review--stage-comment`, `forge-review--save-comment-edit`) use `(_repo _post)` and ignore both. API-submitting callbacks are `cl-defmethod` generics specialised on the repo class.
```

- [ ] **Step 4: Update the naming conventions table in CLAUDE.md**

Find the `forge--submit-FOO` row:
```
| `forge--submit-FOO` | Callback function used as `forge--post-submit-function` in a post buffer |
```
Replace with:
```
| `forge--submit-FOO` | Callback used as `forge--submit-post-function`; always a `cl-defmethod` taking `(repo post)`; dispatches to the forge API |
| `forge-review--FOO` | Internal to `forge-review.el`; staging helpers like `forge-review--stage-comment` take `(_repo _post)` but do not call the API |
```

Note: the `forge-review--FOO` row already exists in the table — update it rather than adding a duplicate. The existing entry says:
```
| `forge-review--FOO` | Internal to `forge-review.el` (the `--` after the module name signals extra privacy) |
```
Replace with:
```
| `forge-review--FOO` | Internal to `forge-review.el`; staging helpers (`forge-review--stage-comment`, `forge-review--save-comment-edit`) conform to the `(_repo _post)` submit protocol but write only to the local DB |
```

- [ ] **Step 5: Run the tests to confirm no code was accidentally changed**

```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass.

- [ ] **Step 6: Commit**

```sh
cd /home/Build/yren/.emacs.d/elpa/forge
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for review submit protocol fix and renamed staging helpers"
```
