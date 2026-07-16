;;; forge-review-integration-test.el --- Integration tests for inline review comments  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Jonas Bernoulli

;; SPDX-License-Identifier: GPL-3.0-or-later

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

;;; Code:

(require 'forge-review)
(require 'forge-gitlab)
(require 'ert)
(require 'cl-lib)

;;; Low-level helpers — synchronous REST (no :callback = synchronous in ghub)

(defun forge-itest--gh (method resource &optional params)
  "Make a synchronous GitHub REST call.  Return parsed response."
  (ghub-request method resource params
                :auth 'forge :host "api.github.com"))

(defun forge-itest--gl (method resource &optional params)
  "Make a synchronous GitLab REST call.  Return parsed response.
Uses host \"gitlab.com/api/v4\" (what ghub expects for GitLab REST).
Strips GPG-encrypted auth sources so headless batch mode reads
plaintext ~/.authinfo without stalling on a missing pinentry."
  (let ((auth-sources
         (seq-remove (lambda (s) (and (stringp s) (string-suffix-p ".gpg" s)))
                     auth-sources)))
    (ghub-request method resource params
                  :forge 'gitlab :auth 'forge :host "gitlab.com/api/v4")))

(defun forge-itest--graphql-review-threads (owner name pr-number)
  "Return the reviewThreads list for PR-NUMBER via the production GraphQL query.
Calls ghub-query with :synchronous t so the return value is the parsed
data directly — the same mapping path forge--update-pullreq uses at runtime."
  (let* ((narrow `(repository pullRequests (pullRequest . ,pr-number)))
         (query  (ghub--graphql-prepare-query
                  forge--github-repository-query narrow))
         (data   (ghub-query query
                   `((owner . ,owner) (name . ,name))
                   :auth 'forge :host "api.github.com" :forge 'github
                   :synchronous t)))
    (let-alist data
      .repository.pullRequest.reviewThreads)))

;;; Test repo setup / teardown

(defun forge-itest--github-repo ()
  "Return (OWNER NAME) from FORGE_TEST_GITHUB_REPO, or nil."
  (when-let ((repo (getenv "FORGE_TEST_GITHUB_REPO")))
    (split-string repo "/")))

(defun forge-itest--gh-default-branch (owner name)
  "Return the default branch name for OWNER/NAME on GitHub."
  (alist-get 'default_branch
             (forge-itest--gh "GET" (format "/repos/%s/%s" owner name))))

(defun forge-itest--main-sha (owner name)
  "Return the current SHA of HEAD on the default branch."
  (let ((branch (forge-itest--gh-default-branch owner name)))
    (alist-get 'sha
               (alist-get 'object
                          (forge-itest--gh
                           "GET"
                           (format "/repos/%s/%s/git/ref/heads/%s"
                                   owner name branch))))))

(defun forge-itest--create-branch (owner name branch base-sha)
  "Create BRANCH from BASE-SHA in owner/name."
  (forge-itest--gh "POST"
                   (format "/repos/%s/%s/git/refs" owner name)
                   `((ref . ,(concat "refs/heads/" branch))
                     (sha . ,base-sha))))

(defun forge-itest--push-file (owner name branch path content message)
  "Create or update PATH on BRANCH with CONTENT and commit MESSAGE.
Returns the new commit SHA."
  (let* ((b64      (base64-encode-string content t))
         (existing (condition-case nil
                       (forge-itest--gh
                        "GET"
                        (format "/repos/%s/%s/contents/%s" owner name path)
                        `((ref . ,branch)))
                     (error nil)))
         (params   `((message . ,message)
                     (content . ,b64)
                     (branch  . ,branch)
                     ,@(when existing
                         `((sha . ,(alist-get 'sha existing))))))
         (result   (forge-itest--gh
                    "PUT"
                    (format "/repos/%s/%s/contents/%s" owner name path)
                    params)))
    (alist-get 'sha (alist-get 'commit result))))

(defun forge-itest--create-pr (owner name title head base)
  "Open a PR in owner/name and return the PR alist."
  (forge-itest--gh "POST"
                   (format "/repos/%s/%s/pulls" owner name)
                   `((title . ,title)
                     (head  . ,head)
                     (base  . ,base)
                     (body  . "Integration test PR — will be deleted"))))

(defun forge-itest--close-pr (owner name number)
  "Close PR NUMBER."
  (forge-itest--gh "PATCH"
                   (format "/repos/%s/%s/pulls/%s" owner name number)
                   '((state . "closed"))))

(defun forge-itest--delete-branch (owner name branch)
  "Delete BRANCH from owner/name."
  (condition-case nil
      (forge-itest--gh "DELETE"
                       (format "/repos/%s/%s/git/refs/heads/%s" owner name branch))
    (error nil)))

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
             (forge-itest--gh-default-branch owner name))))
    ;; Extract commit SHA from the PR head.
    (let ((commit-sha (alist-get 'sha (alist-get 'head pr-alist)))
          (number     (alist-get 'number pr-alist)))
      (list :number     number
            :commit-sha commit-sha
            :path       forge-itest--fixture-file))))

(defun forge-itest--add-review-comment (owner name pr-number commit-id path line body)
  "Post a review comment on PR-NUMBER at PATH:LINE and return the response alist."
  (forge-itest--gh "POST"
                   (format "/repos/%s/%s/pulls/%s/comments" owner name pr-number)
                   `((body      . ,body)
                     (commit_id . ,commit-id)
                     (path      . ,path)
                     (line      . ,line)
                     (side      . "RIGHT"))))

(defun forge-itest--reply-to-comment (owner name pr-number comment-id body)
  "Post a reply to review comment COMMENT-ID on PR-NUMBER."
  (forge-itest--gh "POST"
                   (format "/repos/%s/%s/pulls/%s/comments" owner name pr-number)
                   `((body        . ,body)
                     (in_reply_to . ,comment-id))))

(defun forge-itest--clear-pr-comments (owner name pr-number)
  "Delete all review comments on PR-NUMBER in OWNER/NAME."
  (let ((comments (forge-itest--gh
                   "GET"
                   (format "/repos/%s/%s/pulls/%s/comments" owner name pr-number))))
    (dolist (c comments)
      (forge-itest--delete-review-comment owner name (alist-get 'id c)))))

(defun forge-itest--gl-clear-mr-comments (project-id mr-iid)
  "Delete all inline discussion notes on MR-IID in PROJECT-ID."
  (let ((discussions (forge-itest--gl-discussions project-id mr-iid)))
    (dolist (disc discussions)
      (dolist (note (alist-get 'notes disc))
        (when (alist-get 'position note)
          (forge-itest--gl-delete-note
           project-id mr-iid (alist-get 'id note)))))))

;;; Comment tracking

(defmacro forge-itest--record (posted-ids-var comment-alist-form)
  "Evaluate COMMENT-ALIST-FORM, push its `id' onto POSTED-IDS-VAR, return it."
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

;;; DB setup

(defmacro forge-itest--with-db (&rest body)
  "Run BODY with a fresh temporary SQLite DB as the forge DB."
  (declare (indent 0))
  `(let ((tmp-file (make-temp-file "forge-itest" nil ".sqlite"))
         (orig     forge-database-file))
     (unwind-protect
         (progn
           (setq forge-database-file tmp-file)
           (ignore-errors
             (let ((old (oref-default 'forge-database singleton)))
               (unless (eq old eieio--unbound) (emacsql-close old))))
           (oset-default 'forge-database singleton eieio--unbound)
           (forge--db-create-review-comment-table (forge-db))
           ,@body)
       (ignore-errors
         (let ((old (oref-default 'forge-database singleton)))
           (unless (eq old eieio--unbound) (emacsql-close old))))
       (oset-default 'forge-database singleton eieio--unbound)
       (setq forge-database-file orig)
       (when (file-exists-p tmp-file) (delete-file tmp-file)))))

(defun forge-itest--make-github-repo-object (owner name)
  "Insert a minimal forge-github-repository for OWNER/NAME and return it."
  (let* ((id   (base64-encode-string (format "github.com/%s/%s" owner name) t))
         (repo (forge-github-repository
                :id       id
                :forge-id (format "%s/%s" owner name)
                :forge    "github.com"
                :owner    owner
                :name     name
                :apihost  "api.github.com"
                :githost  "github.com")))
    (oset repo condition :tracked)
    (closql-insert (forge-db) repo t)
    repo))

(defun forge-itest--make-pullreq-object (repo pr-alist)
  "Insert a forge-pullreq for PR-ALIST under REPO and return it."
  (let-alist pr-alist
    (let* ((repo-id (oref repo id))
           (pr-id   (base64-encode-string
                     (format "github.com/%s/%s:%s"
                             (oref repo owner) (oref repo name) .number)
                     t))
           (pr      (forge-pullreq
                     :id         pr-id
                     :repository repo-id
                     :number     .number
                     :state      'open
                     :author     (alist-get 'login .user)
                     :title      .title
                     :base-ref   (alist-get 'ref .base)
                     :base-rev   (alist-get 'sha .base)
                     :head-ref   (alist-get 'ref .head)
                     :head-rev   (alist-get 'sha .head)
                     :body       (or .body ""))))
      (closql-insert (forge-db) pr t)
      pr)))

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
           (let* ((_        (forge-itest--clear-pr-comments ,owner ,name pr-number))
                  (pr-alist  (forge-itest--gh
                              "GET"
                              (format "/repos/%s/%s/pulls/%s"
                                      ,owner ,name pr-number)))
                  (repo-obj  (forge-itest--make-github-repo-object ,owner ,name))
                  (pr-obj    (forge-itest--make-pullreq-object repo-obj pr-alist)))
             ,@body)
         (dolist (id posted-ids)
           (forge-itest--delete-review-comment ,owner ,name id))))))

;;; GitHub integration tests

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

;;; GitLab integration tests

(defun forge-itest--gitlab-repo ()
  "Return (OWNER NAME) from FORGE_TEST_GITLAB_REPO, or nil."
  (when-let ((repo (getenv "FORGE_TEST_GITLAB_REPO")))
    (split-string repo "/")))

(defun forge-itest--gl-project-id (owner name)
  "Return the numeric project ID for OWNER/NAME on gitlab.com."
  (alist-get 'id
             (forge-itest--gl "GET"
               (format "/projects/%s%%2F%s" owner name))))

(defun forge-itest--gl-default-branch (owner name)
  "Return the default branch name for OWNER/NAME."
  (alist-get 'default_branch
             (forge-itest--gl "GET"
               (format "/projects/%s%%2F%s" owner name))))

(defun forge-itest--gl-branch-sha (owner name branch)
  "Return the HEAD commit SHA of BRANCH in OWNER/NAME."
  (alist-get 'id
             (alist-get 'commit
                        (forge-itest--gl "GET"
                          (format "/projects/%s%%2F%s/repository/branches/%s"
                                  owner name (url-hexify-string branch))))))

(defun forge-itest--gl-create-branch (project-id branch base-sha)
  "Create BRANCH from BASE-SHA in PROJECT-ID."
  (forge-itest--gl "POST"
    (format "/projects/%s/repository/branches" project-id)
    `((branch . ,branch) (ref . ,base-sha))))

(defun forge-itest--gl-push-file (project-id branch path content message)
  "Create PATH on BRANCH with CONTENT and commit MESSAGE.
Returns the new commit SHA."
  (let* ((b64    (base64-encode-string content t))
         (result (forge-itest--gl "POST"
                   (format "/projects/%s/repository/files/%s"
                           project-id
                           (url-hexify-string path))
                   `((branch         . ,branch)
                     (content        . ,b64)
                     (encoding       . "base64")
                     (commit_message . ,message)))))
    (alist-get 'id (alist-get 'commit result))))

(defun forge-itest--gl-create-mr (project-id title source-branch target-branch)
  "Open an MR and return the MR alist."
  (forge-itest--gl "POST"
    (format "/projects/%s/merge_requests" project-id)
    `((title         . ,title)
      (source_branch . ,source-branch)
      (target_branch . ,target-branch)
      (description   . "Integration test MR — will be deleted"))))

(defun forge-itest--gl-close-mr (project-id mr-iid)
  "Close MR MR-IID in PROJECT-ID."
  (forge-itest--gl "PUT"
    (format "/projects/%s/merge_requests/%s" project-id mr-iid)
    '((state_event . "close"))))

(defun forge-itest--gl-delete-branch (project-id branch)
  "Delete BRANCH from PROJECT-ID."
  (condition-case nil
      (forge-itest--gl "DELETE"
        (format "/projects/%s/repository/branches/%s"
                project-id (url-hexify-string branch)))
    (error nil)))

(defun forge-itest--ensure-mr (owner name)
  "Return a plist (:iid N :mr-alist ALIST :path PATH) for the persistent
fixture MR in OWNER/NAME.  Creates the branch and/or MR if absent."
  (let* ((project-id  (forge-itest--gl-project-id owner name))
         (open-mrs    (forge-itest--gl
                       "GET"
                       (format "/projects/%s/merge_requests" project-id)
                       `((state         . "opened")
                         (source_branch . ,forge-itest--fixture-branch))))
         (mr-alist    (when (car open-mrs)
                        ;; List endpoint omits diff_refs; re-fetch via single endpoint.
                        (forge-itest--gl-mr-with-diff-refs
                         project-id (alist-get 'iid (car open-mrs))))))
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
    (list :iid        (alist-get 'iid mr-alist)
          :mr-alist   mr-alist
          :project-id project-id
          :path       forge-itest--fixture-file)))

(defun forge-itest--gl-line-code (path new-line)
  "Return the GitLab line_code for PATH at NEW-LINE (added line, no old side).
Format: SHA1(\"{path}\")_{old_line}_{new_line}, old_line=0 for pure additions."
  (format "%s_0_%d"
          (secure-hash 'sha1 path)
          new-line))

(defun forge-itest--gl-add-review-comment (project-id mr-iid mr-alist
                                            path new-line body)
  "Post an inline review comment on MR-IID at PATH:NEW-LINE.
MR-ALIST is the MR response alist; its diff_refs supply the three SHAs
GitLab needs to locate the diff position.  Returns the discussion alist."
  (let-alist mr-alist
    (forge-itest--gl "POST"
      (format "/projects/%s/merge_requests/%s/discussions" project-id mr-iid)
      `((body      . ,body)
        (position  . ((position_type . "text")
                      (base_sha      . , .diff_refs.base_sha)
                      (start_sha     . , .diff_refs.start_sha)
                      (head_sha      . , .diff_refs.head_sha)
                      (new_path      . ,path)
                      (old_path      . ,path)
                      (new_line      . ,new-line)))))))

(defun forge-itest--gl-reply-to-discussion (project-id mr-iid disc-id body)
  "Post a reply note to DISC-ID on MR-IID."
  (forge-itest--gl "POST"
    (format "/projects/%s/merge_requests/%s/discussions/%s/notes"
            project-id mr-iid disc-id)
    `((body . ,body))))

(defun forge-itest--gl-discussions (project-id mr-iid)
  "Return the full discussions list for MR-IID."
  (forge-itest--gl "GET"
    (format "/projects/%s/merge_requests/%s/discussions" project-id mr-iid)
    '((per_page . 100))))

(defun forge-itest--make-gitlab-repo-object (owner name project-id)
  "Insert a minimal forge-gitlab-repository for OWNER/NAME and return it."
  (let* ((id   (base64-encode-string (format "gitlab.com/%s/%s" owner name) t))
         (repo (forge-gitlab-repository
                :id       id
                :forge-id (number-to-string project-id)
                :forge    "gitlab.com"
                :owner    owner
                :name     name
                :apihost  "gitlab.com"
                :githost  "gitlab.com")))
    (oset repo condition :tracked)
    (closql-insert (forge-db) repo t)
    repo))

(defun forge-itest--make-gitlab-pullreq-object (repo mr-alist)
  "Insert a forge-pullreq for MR-ALIST under REPO and return it."
  (let-alist mr-alist
    (let* ((repo-id (oref repo id))
           (pr-id   (forge--object-id 'forge-pullreq repo .iid))
           (pr      (forge-pullreq
                     :id         pr-id
                     :repository repo-id
                     :number     .iid
                     :state      'open
                     :author     .author.username
                     :title      .title
                     :base-ref   .target_branch
                     :base-rev   .diff_refs.start_sha
                     :head-ref   .source_branch
                     :head-rev   .diff_refs.head_sha
                     :base-sha   .diff_refs.base_sha
                     :body       (or .description ""))))
      (closql-insert (forge-db) pr t)
      pr)))

(defun forge-itest--gl-fetch-mr (project-id mr-iid)
  "Fetch the current MR alist for MR-IID from GitLab."
  (forge-itest--gl "GET"
    (format "/projects/%s/merge_requests/%s" project-id mr-iid)))

(defun forge-itest--gl-mr-with-diff-refs (project-id mr-iid)
  "Return the MR alist once diff_refs.head_sha is non-nil (poll up to 10s)."
  (let ((mr nil) (attempts 0))
    (while (and (< attempts 20)
                (null (let-alist mr .diff_refs.head_sha)))
      (setq mr (forge-itest--gl-fetch-mr project-id mr-iid))
      (unless (let-alist mr .diff_refs.head_sha)
        (sleep-for 0.5))
      (setq attempts (1+ attempts)))
    mr))

(defmacro forge-itest--with-fixture-mr (owner name &rest body)
  "Run BODY with bindings for the persistent GitLab fixture MR.
Binds REPO-OBJ, PR-OBJ, MR-ALIST, MR-IID, PATH, and POSTED-IDS.
Deletes all note IDs accumulated in POSTED-IDS on exit."
  (declare (indent 2))
  `(let* ((fixture    (forge-itest--ensure-mr ,owner ,name))
          (mr-iid     (plist-get fixture :iid))
          (mr-alist   (plist-get fixture :mr-alist))
          (path       (plist-get fixture :path))
          (project-id (plist-get fixture :project-id))
          (posted-ids nil))
     (forge-itest--with-db
       (unwind-protect
           (let* ((_       (forge-itest--gl-clear-mr-comments project-id mr-iid))
                  (repo-obj (forge-itest--make-gitlab-repo-object
                             ,owner ,name project-id))
                  (pr-obj   (forge-itest--make-gitlab-pullreq-object
                             repo-obj mr-alist)))
             ,@body)
         (dolist (id posted-ids)
           (forge-itest--gl-delete-note project-id mr-iid id))))))

(ert-deftest forge-itest-gitlab-fetch-review-threads ()
  "GitLab: fetch via REST — opener+reply structure is correct in the DB."
  (pcase (forge-itest--gitlab-repo)
    ('nil (skip-unless nil))
    (`(,owner ,name)
     (forge-itest--with-fixture-mr owner name
       (let* ((disc     (forge-itest--gl-add-review-comment
                         project-id mr-iid mr-alist path 1
                         "forge-itest opener comment"))
              (disc-id  (alist-get 'id disc))
              (_        (push (alist-get 'id (car (alist-get 'notes disc)))
                              posted-ids))
              (reply    (forge-itest--gl-reply-to-discussion
                         project-id mr-iid disc-id "forge-itest reply comment"))
              (_        (push (alist-get 'id reply) posted-ids)))
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

(ert-deftest forge-itest-gitlab-review-comment-path-and-line ()
  "GitLab: fetch via REST — DB row records correct file path and line number."
  (pcase (forge-itest--gitlab-repo)
    ('nil (skip-unless nil))
    (`(,owner ,name)
     (forge-itest--with-fixture-mr owner name
       (let* ((disc        (forge-itest--gl-add-review-comment
                            project-id mr-iid mr-alist path 2
                            "forge-itest line-2 comment"))
              (_           (push (alist-get 'id (car (alist-get 'notes disc)))
                                 posted-ids))
              (discussions (forge-itest--gl-discussions project-id mr-iid))
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
         (should (= (oref opener new-line) 2)))))))

;;; _
(provide 'forge-review-integration-test)
;;; forge-review-integration-test.el ends here
