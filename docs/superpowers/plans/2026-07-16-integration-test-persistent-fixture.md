# Integration Test Persistent Fixture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace throwaway branch+PR/MR creation/deletion per integration test run with a persistent `forge-itest-fixture` branch and PR/MR that is lazily created once and reused; only review comments are created and deleted per run.

**Architecture:** A lazy-init helper (`forge-itest--ensure-pr` / `forge-itest--ensure-mr`) checks for an open PR/MR first, then checks for the branch, creating either if absent. New macro wrappers (`forge-itest--with-fixture-pr` / `forge-itest--with-fixture-mr`) replace the old throwaway wrappers; they bind a `posted-ids` list and delete all tracked comment IDs in their `unwind-protect` teardown. The three existing `ert-deftest` bodies are updated to use the new wrappers and `forge-itest--record` for comment tracking.

**Tech Stack:** Emacs Lisp, ERT, `ghub` REST calls (GitHub REST API v3, GitLab REST API v4), `closql`/`emacsql` SQLite.

## Global Constraints

- All code goes in `tests/forge-review-integration-test.el` — no new files.
- Do not change `forge-itest--with-db`, low-level write helpers, `FORGE_TEST_*` env vars, `scripts/run-integration-tests.sh`, or `Makefile`.
- The fixture branch name is exactly `forge-itest-fixture` on both GitHub and GitLab.
- The fixture file is `forge-itest-scratch.txt` with content `"line1\nline2\nline3\n"`.
- The fixture PR/MR title is `"forge-itest fixture (persistent)"`.
- `push` in Elisp does not mutate a callee's binding — comment tracking must use a macro, not a function.
- Run `make test-integration` (with env vars set) to verify each task.

---

### Task 1: Add `forge-itest--ensure-pr` for GitHub

**Files:**
- Modify: `tests/forge-review-integration-test.el` (GitHub setup/teardown section, after `forge-itest--delete-branch`)

**Interfaces:**
- Produces: `(forge-itest--ensure-pr OWNER NAME)` → plist with keys `:number` (integer), `:commit-sha` (string), `:path` (string `"forge-itest-scratch.txt"`).

- [ ] **Step 1: Add the helper after `forge-itest--delete-branch`**

  Insert the following block immediately after the `forge-itest--delete-branch` defun (around line 136 in the current file):

  ```elisp
  (defconst forge-itest--fixture-branch "forge-itest-fixture"
    "Fixed branch name used by the persistent integration test fixture.")

  (defconst forge-itest--fixture-file "forge-itest-scratch.txt"
    "File path used in the persistent fixture branch.")

  (defconst forge-itest--fixture-content "line1\nline2\nline3\n"
    "File content used in the persistent fixture branch.")

  (defun forge-itest--ensure-pr (owner name)
    "Return a plist (:number N :commit-sha SHA :path PATH) for the persistent
  fixture PR in OWNER/NAME.  Creates the branch and/or PR if absent."
    (let* ((head        (format "%s:%s" owner forge-itest--fixture-branch))
           (open-prs    (forge-itest--gh
                         "GET"
                         (format "/repos/%s/%s/pulls" owner name)
                         `((state . "open") (head . ,head))))
           (pr-alist    (car open-prs)))
      (unless pr-alist
        ;; Check branch; create if missing.
        (let ((branch-exists
               (condition-case nil
                   (forge-itest--gh
                    "GET"
                    (format "/repos/%s/%s/git/ref/heads/%s"
                            owner name forge-itest--fixture-branch))
                 (error nil))))
          (unless branch-exists
            (let ((base-sha (forge-itest--main-sha owner name)))
              (forge-itest--create-branch
               owner name forge-itest--fixture-branch base-sha)
              (forge-itest--push-file
               owner name forge-itest--fixture-branch
               forge-itest--fixture-file
               forge-itest--fixture-content
               "forge-itest: add fixture file"))))
        ;; Open the PR.
        (setq pr-alist
              (forge-itest--create-pr
               owner name
               "forge-itest fixture (persistent)"
               forge-itest--fixture-branch
               "main")))
      ;; Extract commit SHA from the PR head.
      (let ((commit-sha (alist-get 'sha (alist-get 'head pr-alist)))
            (number     (alist-get 'number pr-alist)))
        (list :number     number
              :commit-sha commit-sha
              :path       forge-itest--fixture-file))))
  ```

- [ ] **Step 2: Byte-compile to catch syntax errors**

  ```bash
  cd /home/Build/yren/.emacs.d/elpa/forge
  emacs -Q --batch --eval "(require 'package)" --eval "(package-initialize)" \
    -L ./lisp -L ./tests \
    --eval "(byte-compile-file \"tests/forge-review-integration-test.el\")"
  ```

  Expected: no errors, produces `tests/forge-review-integration-test.elc` (or exits 0).

- [ ] **Step 3: Commit**

  ```bash
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest--ensure-pr for persistent GitHub fixture"
  ```

---

### Task 2: Add `forge-itest--ensure-mr` for GitLab

**Files:**
- Modify: `tests/forge-review-integration-test.el` (GitLab setup/teardown section, after `forge-itest--gl-delete-branch`)

**Interfaces:**
- Consumes: `forge-itest--fixture-branch`, `forge-itest--fixture-file`, `forge-itest--fixture-content` (defined in Task 1).
- Produces: `(forge-itest--ensure-mr OWNER NAME)` → plist with keys `:iid` (integer), `:mr-alist` (alist), `:path` (string).

- [ ] **Step 1: Add the helper after `forge-itest--gl-delete-branch`**

  Insert the following block immediately after the `forge-itest--gl-delete-branch` defun (around line 376 in the current file):

  ```elisp
  (defun forge-itest--ensure-mr (owner name)
    "Return a plist (:iid N :mr-alist ALIST :path PATH) for the persistent
  fixture MR in OWNER/NAME.  Creates the branch and/or MR if absent."
    (let* ((project-id  (forge-itest--gl-project-id owner name))
           (open-mrs    (forge-itest--gl
                         "GET"
                         (format "/projects/%s/merge_requests" project-id)
                         `((state         . "opened")
                           (source_branch . ,forge-itest--fixture-branch))))
           (mr-alist    (car open-mrs)))
      (unless mr-alist
        ;; Check branch; create if missing.
        (let ((branch-exists
               (condition-case nil
                   (forge-itest--gl
                    "GET"
                    (format "/projects/%s/repository/branches/%s"
                            project-id
                            (url-hexify-string forge-itest--fixture-branch)))
                 (error nil))))
          (unless branch-exists
            (let* ((default-br (forge-itest--gl-default-branch owner name))
                   (base-sha   (forge-itest--gl-branch-sha owner name default-br)))
              (forge-itest--gl-create-branch
               project-id forge-itest--fixture-branch base-sha)
              (forge-itest--gl-push-file
               project-id forge-itest--fixture-branch
               forge-itest--fixture-file
               forge-itest--fixture-content
               "forge-itest: add fixture file"))))
        ;; Open the MR.
        (let* ((default-br (forge-itest--gl-default-branch owner name))
               (raw        (forge-itest--gl-create-mr
                            project-id
                            "forge-itest fixture (persistent)"
                            forge-itest--fixture-branch
                            default-br)))
          (setq mr-alist
                (forge-itest--gl-mr-with-diff-refs
                 project-id (alist-get 'iid raw)))))
      (list :iid      (alist-get 'iid mr-alist)
            :mr-alist mr-alist
            :path     forge-itest--fixture-file)))
  ```

- [ ] **Step 2: Byte-compile**

  ```bash
  cd /home/Build/yren/.emacs.d/elpa/forge
  emacs -Q --batch --eval "(require 'package)" --eval "(package-initialize)" \
    -L ./lisp -L ./tests \
    --eval "(byte-compile-file \"tests/forge-review-integration-test.el\")"
  ```

  Expected: exits 0, no errors.

- [ ] **Step 3: Commit**

  ```bash
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest--ensure-mr for persistent GitLab fixture"
  ```

---

### Task 3: Add `forge-itest--record` macro and comment-delete helpers

**Files:**
- Modify: `tests/forge-review-integration-test.el` (after the `forge-itest--ensure-mr` defun, before the DB setup section)

**Interfaces:**
- Produces:
  - `(forge-itest--record POSTED-IDS-VAR COMMENT-ALIST-FORM)` — macro; evaluates form, pushes `(alist-get 'id result)` onto `POSTED-IDS-VAR`, returns result.
  - `(forge-itest--delete-review-comment OWNER NAME ID)` — deletes a GitHub pull review comment by ID.
  - `(forge-itest--gl-delete-note PROJECT-ID MR-IID NOTE-ID)` — deletes a GitLab MR note by ID.

- [ ] **Step 1: Add the macro and delete helpers**

  Insert the following block immediately after `forge-itest--ensure-mr`:

  ```elisp
  ;;; Comment tracking

  (defmacro forge-itest--record (posted-ids-var comment-alist-form)
    "Evaluate COMMENT-ALIST-FORM, push its `id` onto POSTED-IDS-VAR, return it."
    (let ((result (gensym "comment")))
      `(let ((,result ,comment-alist-form))
         (push (alist-get 'id ,result) ,posted-ids-var)
         ,result)))

  (defun forge-itest--delete-review-comment (owner name id)
    "Delete GitHub pull review comment ID from OWNER/NAME."
    (condition-case nil
        (forge-itest--gh "DELETE"
                         (format "/repos/%s/%s/pulls/comments/%s" owner name id))
      (error nil)))

  (defun forge-itest--gl-delete-note (project-id mr-iid note-id)
    "Delete GitLab note NOTE-ID from MR-IID in PROJECT-ID."
    (condition-case nil
        (forge-itest--gl "DELETE"
                         (format "/projects/%s/merge_requests/%s/notes/%s"
                                 project-id mr-iid note-id))
      (error nil)))
  ```

- [ ] **Step 2: Byte-compile**

  ```bash
  cd /home/Build/yren/.emacs.d/elpa/forge
  emacs -Q --batch --eval "(require 'package)" --eval "(package-initialize)" \
    -L ./lisp -L ./tests \
    --eval "(byte-compile-file \"tests/forge-review-integration-test.el\")"
  ```

  Expected: exits 0, no errors.

- [ ] **Step 3: Commit**

  ```bash
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest--record macro and comment-delete helpers"
  ```

---

### Task 4: Add `forge-itest--with-fixture-pr` macro (GitHub wrapper)

**Files:**
- Modify: `tests/forge-review-integration-test.el` (GitHub integration tests section, replacing `forge-itest--run-with-pr`)

**Interfaces:**
- Consumes: `forge-itest--ensure-pr` (Task 1), `forge-itest--with-db`, `forge-itest--make-github-repo-object`, `forge-itest--make-pullreq-object`, `forge-itest--delete-review-comment` (Task 3).
- Produces: `(forge-itest--with-fixture-pr OWNER NAME &rest BODY)` — macro that binds `repo-obj`, `pr-obj`, `commit-sha`, `pr-number`, `path`, `posted-ids` in BODY.

- [ ] **Step 1: Add the macro after `forge-itest--make-pullreq-object`**

  The current `forge-itest--make-pullreq-object` ends around line 214. Insert the following block after it, replacing the existing `forge-itest--run-with-pr` defun entirely:

  ```elisp
  (defmacro forge-itest--with-fixture-pr (owner name &rest body)
    "Run BODY with bindings for the persistent GitHub fixture PR.
  Binds REPO-OBJ, PR-OBJ, COMMIT-SHA, PR-NUMBER, PATH, and POSTED-IDS.
  Deletes all comment IDs accumulated in POSTED-IDS on exit."
    (declare (indent 2))
    `(let* ((fixture    (forge-itest--ensure-pr ,owner ,name))
            (pr-number  (plist-get fixture :number))
            (commit-sha (plist-get fixture :commit-sha))
            (path       (plist-get fixture :path))
            (posted-ids nil))
       (forge-itest--with-db
         (unwind-protect
             (let* ((pr-alist  (forge-itest--gh
                                "GET"
                                (format "/repos/%s/%s/pulls/%s"
                                        ,owner ,name pr-number)))
                    (repo-obj  (forge-itest--make-github-repo-object ,owner ,name))
                    (pr-obj    (forge-itest--make-pullreq-object repo-obj pr-alist)))
               ,@body)
           (dolist (id posted-ids)
             (forge-itest--delete-review-comment ,owner ,name id))))))
  ```

  Then **delete** the old `forge-itest--run-with-pr` defun (lines ~219–241 in the original file).

- [ ] **Step 2: Byte-compile**

  ```bash
  cd /home/Build/yren/.emacs.d/elpa/forge
  emacs -Q --batch --eval "(require 'package)" --eval "(package-initialize)" \
    -L ./lisp -L ./tests \
    --eval "(byte-compile-file \"tests/forge-review-integration-test.el\")"
  ```

  Expected: exits 0, no errors.

- [ ] **Step 3: Commit**

  ```bash
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest--with-fixture-pr; remove throwaway run-with-pr"
  ```

---

### Task 5: Add `forge-itest--with-fixture-mr` macro (GitLab wrapper)

**Files:**
- Modify: `tests/forge-review-integration-test.el` (GitLab integration tests section, replacing `forge-itest--gl-run-with-mr`)

**Interfaces:**
- Consumes: `forge-itest--ensure-mr` (Task 2), `forge-itest--with-db`, `forge-itest--make-gitlab-repo-object`, `forge-itest--make-gitlab-pullreq-object`, `forge-itest--gl-delete-note` (Task 3), `forge-itest--gl-project-id`.
- Produces: `(forge-itest--with-fixture-mr OWNER NAME &rest BODY)` — macro that binds `repo-obj`, `pr-obj`, `mr-alist`, `mr-iid`, `path`, `posted-ids` in BODY.

- [ ] **Step 1: Add the macro after `forge-itest--gl-fetch-mr` / `forge-itest--gl-mr-with-diff-refs`**

  Insert the following block after `forge-itest--gl-mr-with-diff-refs`, replacing the existing `forge-itest--gl-run-with-mr` defun entirely:

  ```elisp
  (defmacro forge-itest--with-fixture-mr (owner name &rest body)
    "Run BODY with bindings for the persistent GitLab fixture MR.
  Binds REPO-OBJ, PR-OBJ, MR-ALIST, MR-IID, PATH, and POSTED-IDS.
  Deletes all note IDs accumulated in POSTED-IDS on exit."
    (declare (indent 2))
    `(let* ((fixture    (forge-itest--ensure-mr ,owner ,name))
            (mr-iid     (plist-get fixture :iid))
            (mr-alist   (plist-get fixture :mr-alist))
            (path       (plist-get fixture :path))
            (project-id (forge-itest--gl-project-id ,owner ,name))
            (posted-ids nil))
       (forge-itest--with-db
         (unwind-protect
             (let* ((repo-obj (forge-itest--make-gitlab-repo-object
                               ,owner ,name project-id))
                    (pr-obj   (forge-itest--make-gitlab-pullreq-object
                               repo-obj mr-alist)))
               ,@body)
           (dolist (id posted-ids)
             (forge-itest--gl-delete-note project-id mr-iid id))))))
  ```

  Then **delete** the old `forge-itest--gl-run-with-mr` defun.

- [ ] **Step 2: Byte-compile**

  ```bash
  cd /home/Build/yren/.emacs.d/elpa/forge
  emacs -Q --batch --eval "(require 'package)" --eval "(package-initialize)" \
    -L ./lisp -L ./tests \
    --eval "(byte-compile-file \"tests/forge-review-integration-test.el\")"
  ```

  Expected: exits 0, no errors.

- [ ] **Step 3: Commit**

  ```bash
  git add tests/forge-review-integration-test.el
  git commit -m "tests: add forge-itest--with-fixture-mr; remove throwaway gl-run-with-mr"
  ```

---

### Task 6: Update GitHub `ert-deftest` bodies to use new wrappers

**Files:**
- Modify: `tests/forge-review-integration-test.el` (the three GitHub `ert-deftest` forms)

**Interfaces:**
- Consumes: `forge-itest--with-fixture-pr` (Task 4), `forge-itest--record` (Task 3).

The three GitHub tests currently call `forge-itest--run-with-pr` with a lambda of `(repo-obj pr-obj commit-sha pr-number path)`. Each needs two changes:
1. Replace `(forge-itest--run-with-pr owner name TITLE (lambda (repo-obj pr-obj commit-sha pr-number path) ...))` with `(forge-itest--with-fixture-pr owner name ...)` (TITLE argument dropped).
2. Wrap each `forge-itest--add-review-comment` / `forge-itest--reply-to-comment` call in `(forge-itest--record posted-ids ...)`.

- [ ] **Step 1: Update `forge-itest-github-fetch-review-threads`**

  Replace:
  ```elisp
  (ert-deftest forge-itest-github-fetch-review-threads ()
    "Fetch via real GraphQL: opener+reply structure is correct in the DB."
    (pcase (forge-itest--github-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--run-with-pr
        owner name "forge-itest review comment test"
        (lambda (repo-obj pr-obj commit-sha pr-number path)
          (let ((opener (forge-itest--add-review-comment
                         owner name pr-number commit-sha path 1
                         "forge-itest opener comment")))
            (forge-itest--reply-to-comment
             owner name pr-number (alist-get 'id opener)
             "forge-itest reply comment")
            (let* ((threads (forge-itest--graphql-review-threads owner name pr-number))
                   (_       (forge--update-pullreq-review-comments repo-obj pr-obj threads))
                   (rows    (oref pr-obj review-comments))
                   (openers (seq-filter (lambda (c) (null (oref c reply-to))) rows))
                   (replies (seq-filter (lambda (c) (oref c reply-to)) rows)))
              (should (= (length rows) 2))
              (should (= (length openers) 1))
              (should (= (length replies) 1))
              (should (equal (oref (car openers) body) "forge-itest opener comment"))
              (should (equal (oref (car replies) body) "forge-itest reply comment"))
              (should (equal (oref (car replies) reply-to)
                             (oref (car openers) discussion-id))))))))))
  ```

  With:
  ```elisp
  (ert-deftest forge-itest-github-fetch-review-threads ()
    "Fetch via real GraphQL: opener+reply structure is correct in the DB."
    (pcase (forge-itest--github-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-pr owner name
         (let ((opener (forge-itest--record posted-ids
                         (forge-itest--add-review-comment
                          owner name pr-number commit-sha path 1
                          "forge-itest opener comment"))))
           (forge-itest--record posted-ids
             (forge-itest--reply-to-comment
              owner name pr-number (alist-get 'id opener)
              "forge-itest reply comment"))
           (let* ((threads (forge-itest--graphql-review-threads owner name pr-number))
                  (_       (forge--update-pullreq-review-comments repo-obj pr-obj threads))
                  (rows    (oref pr-obj review-comments))
                  (openers (seq-filter (lambda (c) (null (oref c reply-to))) rows))
                  (replies (seq-filter (lambda (c) (oref c reply-to)) rows)))
             (should (= (length rows) 2))
             (should (= (length openers) 1))
             (should (= (length replies) 1))
             (should (equal (oref (car openers) body) "forge-itest opener comment"))
             (should (equal (oref (car replies) body) "forge-itest reply comment"))
             (should (equal (oref (car replies) reply-to)
                            (oref (car openers) discussion-id)))))))))
  ```

- [ ] **Step 2: Update `forge-itest-github-review-comment-path-and-line`**

  Replace:
  ```elisp
  (ert-deftest forge-itest-github-review-comment-path-and-line ()
    "Fetch via real GraphQL: DB row records correct file path and line number."
    (pcase (forge-itest--github-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--run-with-pr
        owner name "forge-itest path+line test"
        (lambda (repo-obj pr-obj commit-sha pr-number path)
          (forge-itest--add-review-comment
           owner name pr-number commit-sha path 2
           "forge-itest line-2 comment")
          (let* ((threads (forge-itest--graphql-review-threads owner name pr-number))
                 (_       (forge--update-pullreq-review-comments repo-obj pr-obj threads))
                 (rows    (oref pr-obj review-comments))
                 (opener  (seq-find (lambda (c) (null (oref c reply-to))) rows)))
            (should opener)
            (should (equal (oref opener new-path) path))
            (should (= (oref opener new-line) 2))))))))
  ```

  With:
  ```elisp
  (ert-deftest forge-itest-github-review-comment-path-and-line ()
    "Fetch via real GraphQL: DB row records correct file path and line number."
    (pcase (forge-itest--github-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-pr owner name
         (forge-itest--record posted-ids
           (forge-itest--add-review-comment
            owner name pr-number commit-sha path 2
            "forge-itest line-2 comment"))
         (let* ((threads (forge-itest--graphql-review-threads owner name pr-number))
                (_       (forge--update-pullreq-review-comments repo-obj pr-obj threads))
                (rows    (oref pr-obj review-comments))
                (opener  (seq-find (lambda (c) (null (oref c reply-to))) rows)))
           (should opener)
           (should (equal (oref opener new-path) path))
           (should (= (oref opener new-line) 2)))))))
  ```

- [ ] **Step 3: Update `forge-itest-github-diff-hunk-populated`**

  Replace:
  ```elisp
  (ert-deftest forge-itest-github-diff-hunk-populated ()
    "Fetch via real GraphQL: diff-hunk slot is non-nil for an inline comment."
    (pcase (forge-itest--github-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--run-with-pr
        owner name "forge-itest diff-hunk test"
        (lambda (repo-obj pr-obj commit-sha pr-number path)
          (forge-itest--add-review-comment
           owner name pr-number commit-sha path 1
           "forge-itest hunk comment")
          (let* ((threads (forge-itest--graphql-review-threads owner name pr-number))
                 (_       (forge--update-pullreq-review-comments repo-obj pr-obj threads))
                 (rows    (oref pr-obj review-comments))
                 (opener  (seq-find (lambda (c) (null (oref c reply-to))) rows)))
            (should opener)
            (should (stringp (oref opener diff-hunk)))
            (should (not (string-empty-p (oref opener diff-hunk))))))))))
  ```

  With:
  ```elisp
  (ert-deftest forge-itest-github-diff-hunk-populated ()
    "Fetch via real GraphQL: diff-hunk slot is non-nil for an inline comment."
    (pcase (forge-itest--github-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-pr owner name
         (forge-itest--record posted-ids
           (forge-itest--add-review-comment
            owner name pr-number commit-sha path 1
            "forge-itest hunk comment"))
         (let* ((threads (forge-itest--graphql-review-threads owner name pr-number))
                (_       (forge--update-pullreq-review-comments repo-obj pr-obj threads))
                (rows    (oref pr-obj review-comments))
                (opener  (seq-find (lambda (c) (null (oref c reply-to))) rows)))
           (should opener)
           (should (stringp (oref opener diff-hunk)))
           (should (not (string-empty-p (oref opener diff-hunk)))))))))
  ```

- [ ] **Step 4: Byte-compile**

  ```bash
  cd /home/Build/yren/.emacs.d/elpa/forge
  emacs -Q --batch --eval "(require 'package)" --eval "(package-initialize)" \
    -L ./lisp -L ./tests \
    --eval "(byte-compile-file \"tests/forge-review-integration-test.el\")"
  ```

  Expected: exits 0, no errors.

- [ ] **Step 5: Commit**

  ```bash
  git add tests/forge-review-integration-test.el
  git commit -m "tests: update GitHub ert-deftests to use persistent fixture wrapper"
  ```

---

### Task 7: Update GitLab `ert-deftest` bodies to use new wrappers

**Files:**
- Modify: `tests/forge-review-integration-test.el` (the two GitLab `ert-deftest` forms)

**Interfaces:**
- Consumes: `forge-itest--with-fixture-mr` (Task 5), `forge-itest--record` (Task 3).

The two GitLab tests currently call `forge-itest--gl-run-with-mr` with a lambda of `(repo-obj pr-obj mr-alist mr-iid path)`. Each needs the same two changes as the GitHub tests.

Note on GitLab reply tracking: `forge-itest--gl-reply-to-discussion` returns a note alist whose `id` key is the note ID — this is what `forge-itest--record` captures, and what `forge-itest--gl-delete-note` uses.

- [ ] **Step 1: Update `forge-itest-gitlab-fetch-review-threads`**

  Replace:
  ```elisp
  (ert-deftest forge-itest-gitlab-fetch-review-threads ()
    "GitLab: fetch via REST — opener+reply structure is correct in the DB."
    (pcase (forge-itest--gitlab-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--gl-run-with-mr
        owner name "forge-itest review comment test"
        (lambda (repo-obj pr-obj mr-alist mr-iid path)
          (let* ((disc    (forge-itest--gl-add-review-comment
                           (forge-itest--gl-project-id owner name)
                           mr-iid mr-alist path 1
                           "forge-itest opener comment"))
                 (disc-id (alist-get 'id disc)))
            (forge-itest--gl-reply-to-discussion
             (forge-itest--gl-project-id owner name)
             mr-iid disc-id "forge-itest reply comment")
            (let* ((discussions (forge-itest--gl-discussions
                                 (forge-itest--gl-project-id owner name) mr-iid))
                   (inline      (seq-filter
                                 (lambda (d)
                                   (seq-some (lambda (n) (alist-get 'position n))
                                             (alist-get 'notes d)))
                                 discussions))
                   (_           (forge--update-pullreq-review-comments
                                 repo-obj pr-obj inline))
                   (rows        (oref pr-obj review-comments))
                   (openers     (seq-filter (lambda (c) (null (oref c reply-to))) rows))
                   (replies     (seq-filter (lambda (c) (oref c reply-to)) rows)))
              (should (= (length rows) 2))
              (should (= (length openers) 1))
              (should (= (length replies) 1))
              (should (equal (oref (car openers) body) "forge-itest opener comment"))
              (should (equal (oref (car replies) body) "forge-itest reply comment"))
              (should (equal (oref (car replies) reply-to)
                             (oref (car openers) discussion-id))))))))))
  ```

  With:
  ```elisp
  (ert-deftest forge-itest-gitlab-fetch-review-threads ()
    "GitLab: fetch via REST — opener+reply structure is correct in the DB."
    (pcase (forge-itest--gitlab-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-mr owner name
         (let* ((disc    (forge-itest--record posted-ids
                           (forge-itest--gl-add-review-comment
                            project-id mr-iid mr-alist path 1
                            "forge-itest opener comment")))
                (disc-id (alist-get 'id disc)))
           (forge-itest--record posted-ids
             (forge-itest--gl-reply-to-discussion
              project-id mr-iid disc-id "forge-itest reply comment"))
           (let* ((discussions (forge-itest--gl-discussions project-id mr-iid))
                  (inline      (seq-filter
                                (lambda (d)
                                  (seq-some (lambda (n) (alist-get 'position n))
                                            (alist-get 'notes d)))
                                discussions))
                  (_           (forge--update-pullreq-review-comments
                                repo-obj pr-obj inline))
                  (rows        (oref pr-obj review-comments))
                  (openers     (seq-filter (lambda (c) (null (oref c reply-to))) rows))
                  (replies     (seq-filter (lambda (c) (oref c reply-to)) rows)))
             (should (= (length rows) 2))
             (should (= (length openers) 1))
             (should (= (length replies) 1))
             (should (equal (oref (car openers) body) "forge-itest opener comment"))
             (should (equal (oref (car replies) body) "forge-itest reply comment"))
             (should (equal (oref (car replies) reply-to)
                            (oref (car openers) discussion-id)))))))))
  ```

- [ ] **Step 2: Update `forge-itest-gitlab-review-comment-path-and-line`**

  Replace:
  ```elisp
  (ert-deftest forge-itest-gitlab-review-comment-path-and-line ()
    "GitLab: fetch via REST — DB row records correct file path and line number."
    (pcase (forge-itest--gitlab-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--gl-run-with-mr
        owner name "forge-itest path+line test"
        (lambda (repo-obj pr-obj mr-alist mr-iid path)
          (forge-itest--gl-add-review-comment
           (forge-itest--gl-project-id owner name)
           mr-iid mr-alist path 2 "forge-itest line-2 comment")
          (let* ((discussions (forge-itest--gl-discussions
                               (forge-itest--gl-project-id owner name) mr-iid))
                 (inline      (seq-filter
                               (lambda (d)
                                 (seq-some (lambda (n) (alist-get 'position n))
                                           (alist-get 'notes d)))
                               discussions))
                 (_           (forge--update-pullreq-review-comments
                               repo-obj pr-obj inline))
                 (rows        (oref pr-obj review-comments))
                 (opener      (seq-find (lambda (c) (null (oref c reply-to))) rows)))
            (should opener)
            (should (equal (oref opener new-path) path))
            (should (= (oref opener new-line) 2))))))))
  ```

  With:
  ```elisp
  (ert-deftest forge-itest-gitlab-review-comment-path-and-line ()
    "GitLab: fetch via REST — DB row records correct file path and line number."
    (pcase (forge-itest--gitlab-repo)
      ('nil (skip-unless nil))
      (`(,owner ,name)
       (forge-itest--with-fixture-mr owner name
         (forge-itest--record posted-ids
           (forge-itest--gl-add-review-comment
            project-id mr-iid mr-alist path 2 "forge-itest line-2 comment"))
         (let* ((discussions (forge-itest--gl-discussions project-id mr-iid))
                (inline      (seq-filter
                              (lambda (d)
                                (seq-some (lambda (n) (alist-get 'position n))
                                          (alist-get 'notes d)))
                              discussions))
                (_           (forge--update-pullreq-review-comments
                              repo-obj pr-obj inline))
                (rows        (oref pr-obj review-comments))
                (opener      (seq-find (lambda (c) (null (oref c reply-to))) rows)))
           (should opener)
           (should (equal (oref opener new-path) path))
           (should (= (oref opener new-line) 2))))))
  ```

- [ ] **Step 3: Byte-compile**

  ```bash
  cd /home/Build/yren/.emacs.d/elpa/forge
  emacs -Q --batch --eval "(require 'package)" --eval "(package-initialize)" \
    -L ./lisp -L ./tests \
    --eval "(byte-compile-file \"tests/forge-review-integration-test.el\")"
  ```

  Expected: exits 0, no errors.

- [ ] **Step 4: Commit**

  ```bash
  git add tests/forge-review-integration-test.el
  git commit -m "tests: update GitLab ert-deftests to use persistent fixture wrapper"
  ```

---

### Task 8: Update the Commentary block

**Files:**
- Modify: `tests/forge-review-integration-test.el` (lines 7–33, the `;;; Commentary:` section)

**Interfaces:** None — documentation only.

- [ ] **Step 1: Replace the commentary**

  Replace the existing `;;; Commentary:` block (lines 7–33) with:

  ```elisp
  ;;; Commentary:

  ;; Tests in this file make real API calls against known repositories.
  ;; They skip automatically when the required env vars are absent.
  ;;
  ;; Tokens are read from ~/.authinfo by ghub.  In a normal interactive
  ;; Emacs session, ~/.authinfo.gpg also works.  In batch mode there is
  ;; no pinentry, so run scripts/run-integration-tests.sh which decrypts
  ;; ~/.authinfo.gpg into ~/.authinfo for the duration of the test run.
  ;;
  ;; Required git config keys (ghub uses them to look up tokens):
  ;;
  ;;   git config --global github.user YOUR-GITHUB-USERNAME
  ;;   git config --global gitlab.user YOUR-GITLAB-USERNAME
  ;;
  ;; Required environment variables (tests skip when absent):
  ;;
  ;;   FORGE_TEST_GITHUB_REPO  — "owner/repo" on github.com
  ;;   FORGE_TEST_GITLAB_REPO  — "owner/repo" on gitlab.com
  ;;
  ;; Each test suite reuses a persistent branch `forge-itest-fixture` and a
  ;; single open PR/MR titled "forge-itest fixture (persistent)".  On first
  ;; run (or after accidental deletion) the branch and PR/MR are created
  ;; automatically.  Tests only create and delete review comments — no
  ;; branch or PR/MR churn per run.
  ;;
  ;; Run with:
  ;;   scripts/run-integration-tests.sh [--github owner/repo] [--gitlab owner/repo]
  ```

- [ ] **Step 2: Byte-compile**

  ```bash
  cd /home/Build/yren/.emacs.d/elpa/forge
  emacs -Q --batch --eval "(require 'package)" --eval "(package-initialize)" \
    -L ./lisp -L ./tests \
    --eval "(byte-compile-file \"tests/forge-review-integration-test.el\")"
  ```

  Expected: exits 0, no errors.

- [ ] **Step 3: Commit**

  ```bash
  git add tests/forge-review-integration-test.el
  git commit -m "tests: update commentary to describe persistent fixture approach"
  ```
