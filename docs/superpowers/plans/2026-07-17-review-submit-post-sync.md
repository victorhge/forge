# Review Submit Post-Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After `forge--review-submit` succeeds, call `forge--pull-topic` so the local DB rows for submitted comments are replaced with server-assigned IDs — making submitted comments immediately replyable, resolvable, and deletable without requiring a manual `forge-pull`.

**Architecture:** `forge--review-submit` currently calls `forge--rest` (GitLab) or `forge--rest` (GitHub) with no `:callback`. The fix adds a `:callback` that calls `forge--pull-topic` on the PR — the same pattern used by `forge--post-submit-callback` in `forge-post.el`. For GitHub, a single callback on the reviews POST suffices. For GitLab, the loop posts each comment individually; the callback is attached to the last POST, or alternatively a synchronization barrier calls `forge--pull-topic` after all POSTs complete. The simplest correct approach: after the loop, make one final async call to `forge--pull-topic` directly (no REST involved).

**Tech Stack:** Emacs Lisp, EIEIO `cl-defmethod`, `forge--rest` `:callback`, `forge--pull-topic`.

## Global Constraints

- Never call `ghub-request` directly — use `forge--rest` or `forge--query`.
- `cl-defmethod` implementations for GitHub go in `forge-github.el`; GitLab in `forge-gitlab.el`.
- `make test` must pass after every task: `make -C /home/Build/yren/.emacs.d/elpa/forge test`
- Do not change behaviour of `forge--review-submit` for the case where there are zero pending comments.
- `forge.org` already documents "After submitting, Forge pulls the updated review threads" (line 1093) — the implementation must match this.

---

### Task 1: Add post-submit pull to GitHub's `forge--review-submit`

GitHub's `forge--review-submit` currently calls `forge--rest` with no `:callback`. Add one that calls `forge--pull-topic` with the PR's repo and PR object, mirroring the pattern in `forge--post-submit-callback`.

**Files:**
- Modify: `lisp/forge-github.el` — add `:callback` to the `forge--rest` call in `forge--review-submit`

**Interfaces:**
- Consumes: `forge--pull-topic (repo topic)` — already defined in `forge-github.el:416`

- [ ] **Step 1: Read the current `forge--review-submit` for GitHub**

Read `lisp/forge-github.el` around line 1416 to see the full current method body.

- [ ] **Step 2: Add `:callback` to the GitHub `forge--review-submit`**

The current method (approximately):
```elisp
(cl-defmethod forge--review-submit ((_repo forge-github-repository) pr)
  "POST all pending review comments for PR to GitHub as a COMMENT review."
  (let ((comments (forge--github-pending-review-comments pr))
        (data     (list (cons 'event "COMMENT")
                        (cons 'body  ""))))
    (when comments
      (push (cons 'comments (vconcat comments)) data))
    (forge--rest pr "POST"
      "/repos/:owner/:repo/pulls/:number/reviews"
      data)
    (forge--github-flush-pending-review-comments pr)))
```

Change to:
```elisp
(cl-defmethod forge--review-submit ((_repo forge-github-repository) pr)
  "POST all pending review comments for PR to GitHub as a COMMENT review."
  (let* ((repo     (forge-get-repository pr))
         (comments (forge--github-pending-review-comments pr))
         (data     (list (cons 'event "COMMENT")
                         (cons 'body  ""))))
    (when comments
      (push (cons 'comments (vconcat comments)) data))
    (forge--rest pr "POST"
      "/repos/:owner/:repo/pulls/:number/reviews"
      data
      :callback (lambda (&rest _)
                  (forge--pull-topic repo pr)))
    (forge--github-flush-pending-review-comments pr)))
```

- [ ] **Step 3: Run the tests**

```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass. The existing `forge-review-write-github-submit-*` tests use `forge-test-github-repository` whose `forge--review-submit` stub records the REST call without making a network request, so the callback never fires in tests — that is correct; the callback is an async side-effect tested separately in Task 3.

- [ ] **Step 4: Commit**

```sh
cd /home/Build/yren/.emacs.d/elpa/forge
git add lisp/forge-github.el
git commit -m "fix: pull topic after forge--review-submit on GitHub to sync server-assigned IDs"
```

---

### Task 2: Add post-submit pull to GitLab's `forge--review-submit`

GitLab's `forge--review-submit` loops and POSTs each pending comment individually with no callback. After all POSTs complete, call `forge--pull-topic`. Since the POSTs are fire-and-forget (no `:callback` today), the simplest correct approach is to call `forge--pull-topic` directly after the `dolist` — it is itself async and will run after Emacs processes the pending network responses.

**Files:**
- Modify: `lisp/forge-gitlab.el` — add `forge--pull-topic` call after the `dolist` in `forge--review-submit`

**Interfaces:**
- Consumes: `forge--pull-topic (repo topic)` — defined in `forge-gitlab.el:122`

- [ ] **Step 1: Read the current `forge--review-submit` for GitLab**

Read `lisp/forge-gitlab.el` around line 756 to see the full current method body.

- [ ] **Step 2: Add the post-submit pull call**

The current method ends with the `dolist`. Add a `forge--pull-topic` call after it:

```elisp
(cl-defmethod forge--review-submit ((_repo forge-gitlab-repository) pr)
  "POST each pending review comment for PR to GitLab individually."
  (let* ((repo      (forge-get-repository pr))
         (pending   (seq-filter (lambda (rc) (oref rc pending-p))
                                (oref pr review-comments)))
         (base-sha  (oref pr base-sha))
         (start-sha (oref pr base-rev))
         (head-sha  (oref pr head-rev)))
    (dolist (rc pending)
      (forge--rest pr "POST"
        "/projects/:project/merge_requests/:number/discussions"
        (list (cons 'body     (oref rc body))
              (cons 'position (delq nil
                                    (list (cons 'base_sha  base-sha)
                                          (cons 'start_sha start-sha)
                                          (cons 'head_sha  head-sha)
                                          (cons 'position_type "text")
                                          (cons 'new_path  (oref rc new-path))
                                          (cons 'old_path  (or (oref rc old-path) (oref rc new-path)))
                                          (and (oref rc new-line)
                                               (cons 'new_line (oref rc new-line)))
                                          (and (oref rc old-line)
                                               (cons 'old_line (oref rc old-line)))))))))
    (when pending
      (forge--pull-topic repo pr))))
```

The `(when pending ...)` guard avoids a spurious pull when there were no staged comments.

- [ ] **Step 3: Run the tests**

```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```sh
cd /home/Build/yren/.emacs.d/elpa/forge
git add lisp/forge-gitlab.el
git commit -m "fix: pull topic after forge--review-submit on GitLab to sync server-assigned IDs"
```

---

### Task 3: Add tests verifying `forge--pull-topic` is called after submit

The existing `forge--review-submit` tests verify the API payload shape but do not check that `forge--pull-topic` is called. Add tests for both backends.

**Files:**
- Modify: `tests/forge-review-test.el` — add pull-topic-called tests for GitHub and GitLab

**Interfaces:**
- Consumes: `forge--review-submit (repo pr)` as updated in Tasks 1 and 2

- [ ] **Step 1: Add a helper to record `forge--pull-topic` calls**

After the `forge-test--capture-request` macro, add:

```elisp
(defmacro forge-test--capture-pull-topic (&rest body)
  "Execute BODY; return t if `forge--pull-topic' was called, nil otherwise.
Stubs `forge--pull-topic' as a no-op recorder."
  (declare (indent 0))
  `(let ((called nil))
     (cl-letf (((symbol-function 'forge--pull-topic)
                (lambda (&rest _) (setq called t))))
       ,@body)
     called))
```

- [ ] **Step 2: Add test that GitHub `forge--review-submit` calls `forge--pull-topic`**

```elisp
(ert-deftest forge-review-write-github-submit-calls-pull-topic ()
  "`forge--review-submit' on GitHub calls `forge--pull-topic' after posting."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :body "A comment")))
      (oset rc pending-p t)
      (closql-insert (forge-db) rc t)
      (let ((called (forge-test--capture-pull-topic
                      (forge-test--capture-request
                        (forge--review-submit repo pr)))))
        (should called)))))
```

- [ ] **Step 3: Add test that GitLab `forge--review-submit` calls `forge--pull-topic`**

```elisp
(ert-deftest forge-review-write-gitlab-submit-calls-pull-topic ()
  "`forge--review-submit' on GitLab calls `forge--pull-topic' after posting."
  (forge-test--with-db
    (let* ((repo (forge-test--make-gl-repo))
           (pr   (forge-test--make-gl-pullreq repo))
           (rc   (forge-test--make-gl-review-comment pr :body "GL comment")))
      (oset rc pending-p t)
      (closql-insert (forge-db) rc t)
      (let ((called (forge-test--capture-pull-topic
                      (forge-test--capture-request
                        (forge--review-submit repo pr)))))
        (should called)))))
```

Note: `forge-test--make-gl-pullreq` and `forge-test--make-gl-review-comment` must exist. Check the test file — if they don't exist, add them following the pattern of `forge-test--make-pullreq` and `forge-test--make-review-comment` but using `forge-test--gl-pr-id` and `forge-test--gl-repo-id`.

- [ ] **Step 4: Add test that GitLab `forge--review-submit` does NOT call `forge--pull-topic` when there are no pending comments**

```elisp
(ert-deftest forge-review-write-gitlab-submit-no-pull-when-no-pending ()
  "`forge--review-submit' on GitLab does not call `forge--pull-topic' when
there are no pending comments — avoids spurious API round-trips."
  (forge-test--with-db
    (let* ((repo (forge-test--make-gl-repo))
           (pr   (forge-test--make-gl-pullreq repo)))
      (let ((called (forge-test--capture-pull-topic
                      (forge--review-submit repo pr))))
        (should-not called)))))
```

- [ ] **Step 5: Run the full test suite**

```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass.

- [ ] **Step 6: Commit**

```sh
cd /home/Build/yren/.emacs.d/elpa/forge
git add tests/forge-review-test.el
git commit -m "tests: verify forge--review-submit calls forge--pull-topic after posting"
```

---

### Task 4: Update CLAUDE.md and forge.org to reflect post-submit sync

`forge.org` already documents "After submitting, Forge pulls the updated review threads" — the implementation now matches. CLAUDE.md needs a new invariant documenting this behaviour.

**Files:**
- Modify: `CLAUDE.md` — add invariant for post-submit pull
- Modify: `docs/forge.org` — verify existing wording is accurate; no change expected

**Interfaces:** none — documentation only

- [ ] **Step 1: Add a post-submit sync invariant to CLAUDE.md**

In the "Inline review comment invariants" section, after the "Pending comments" bullet, add:

```
- **Post-submit sync**: `forge--review-submit` calls `forge--pull-topic` after successfully posting pending comments. This replaces locally-staged rows (with temporary IDs) with the server's canonical versions. The pull is guarded: on GitLab it is skipped when there were no pending comments to avoid a spurious round-trip.
```

- [ ] **Step 2: Verify forge.org is already accurate**

Read `docs/forge.org` lines 1080–1095. The text should say "After submitting, Forge pulls the updated review threads so that the newly posted comments appear with their server-assigned IDs." If it does, no change is needed. If the wording is missing or inaccurate, update it to match.

- [ ] **Step 3: Run the tests**

```sh
make -C /home/Build/yren/.emacs.d/elpa/forge test
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```sh
cd /home/Build/yren/.emacs.d/elpa/forge
git add CLAUDE.md docs/forge.org
git commit -m "docs: document post-submit forge--pull-topic sync in CLAUDE.md and forge.org"
```
