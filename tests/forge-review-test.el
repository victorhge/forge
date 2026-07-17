;;; forge-review-test.el --- ERT tests for inline review comments  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Jonas Bernoulli

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'forge-review)
(require 'ert)
(require 'cl-lib)

;;; Test helpers

(defmacro forge-test--with-db (&rest body)
  "Run BODY with a fresh temporary SQLite database bound as the forge DB.
The real `forge-database-file' is never touched."
  (declare (indent 0))
  `(let ((tmp-file (make-temp-file "forge-test" nil ".sqlite"))
         (orig-db-file forge-database-file))
     (unwind-protect
         (progn
           (setq forge-database-file tmp-file)
           ;; Close any existing singleton connection and reset the class slot
           ;; so closql-db opens a fresh connection to tmp-file.
           (ignore-errors
             (let ((old (oref-default 'forge-database singleton)))
               (unless (eq old eieio--unbound)
                 (emacsql-close old))))
           (oset-default 'forge-database singleton eieio--unbound)
           ;; Open the DB; closql--db-create-schema creates all tables including
           ;; pullreq-review-comment (v16 schema).
           (forge-db)
           ,@body)
       (ignore-errors
         (let ((old (oref-default 'forge-database singleton)))
           (unless (eq old eieio--unbound)
             (emacsql-close old))))
       (oset-default 'forge-database singleton eieio--unbound)
       (setq forge-database-file orig-db-file)
       (when (file-exists-p tmp-file)
         (delete-file tmp-file)))))

(defconst forge-test--repo-id
  ;; base64("github.com/alice/myrepo")
  "Z2l0aHViLmNvbS9hbGljZS9teXJlcG8=")

(defconst forge-test--pr-id
  ;; base64("github.com/alice/myrepo:42")
  "Z2l0aHViLmNvbS9hbGljZS9teXJlcG86NDI=")

(defconst forge-test--gl-repo-id
  ;; base64("gitlab.com/alice/proj")
  "Z2l0bGFiLmNvbS9hbGljZS9wcm9q")

(defconst forge-test--gl-pr-id
  ;; base64("gitlab.com/alice/proj:42")
  "Z2l0bGFiLmNvbS9hbGljZS9wcm9qOjQy")

;;; Fake forge subclasses for write-operation tests
;;
;; Instead of patching global functions with cl-letf, tests that exercise
;; write operations use these subclasses.  The stub methods record what
;; would have been sent to the API without making any network calls.
;;
;; `forge-test--last-request' holds the most-recently captured call as a
;; plist.  `forge-test--all-requests' accumulates every call within a
;; capture block; clear it with (setq forge-test--all-requests nil).

(defvar forge-test--last-request nil)
(defvar forge-test--all-requests nil)

(defun forge-test--record-rest (method resource data)
  (let ((entry (list :method method :resource resource :data data)))
    (setq forge-test--last-request entry)
    (push entry forge-test--all-requests)))

(defun forge-test--record-mutate (mutation args)
  (let ((entry (list :mutation mutation :args args)))
    (setq forge-test--last-request entry)
    (push entry forge-test--all-requests)))

(defclass forge-test-github-repository (forge-github-repository) ()
  "Fake GitHub repository class whose write methods record calls instead of
hitting the network.  Use `forge-test--make-repo' to create instances.")

(cl-defmethod forge--review-post-reply
  ((_repo forge-test-github-repository) pr opener text)
  (forge-test--record-rest
   "POST"
   (forge--format-resource pr "/repos/:owner/:repo/pulls/:number/comments")
   (list (cons 'body text) (cons 'in_reply_to (oref opener number)))))

;; Note: forge--submit-review-reply and forge--submit-add-single-review-comment
;; are NOT stubbed here.  They inherit the forge-github-repository cl-defmethod
;; implementations, which internally call forge--review-post-reply /
;; forge--review-post-comment — those ARE stubbed, so no network calls escape.

(cl-defmethod forge--review-set-thread-resolved
  ((_repo forge-test-github-repository) _pr opener resolved)
  (forge-test--record-mutate
   (if resolved 'resolveReviewThread 'unresolveReviewThread)
   (list (cons 'threadId (oref opener discussion-id)))))

(cl-defmethod forge--review-delete-comment
  ((_repo forge-test-github-repository) _pr rc)
  (forge-test--record-rest
   "DELETE"
   (forge--format-resource rc "/repos/:owner/:repo/pulls/comments/:number")
   nil))

(cl-defmethod forge--review-post-comment
  ((_repo forge-test-github-repository) pr body path side line)
  (forge-test--record-rest
   "POST"
   (forge--format-resource pr "/repos/:owner/:repo/pulls/:number/comments")
   (list (cons 'body body) (cons 'path path) (cons 'line line)
         (cons 'side (if (eq side 'old) "LEFT" "RIGHT")))))

(defclass forge-test-gitlab-repository (forge-gitlab-repository) ()
  "Fake GitLab repository class whose write methods record calls instead of
hitting the network.  Use `forge-test--make-gl-repo' to create instances.")

(cl-defmethod forge--review-post-reply
  ((_repo forge-test-gitlab-repository) pr opener text)
  (forge-test--record-rest
   "POST"
   (forge--format-resource
    pr (format "/projects/:project/merge_requests/:number/discussions/%s/notes"
               (oref opener discussion-id)))
   (list (cons 'body text))))

;; Note: forge--submit-review-reply and forge--submit-add-single-review-comment
;; are NOT stubbed here.  They inherit the forge-gitlab-repository cl-defmethod
;; implementations, which internally call forge--review-post-reply /
;; forge--review-post-comment — those ARE stubbed, so no network calls escape.

(cl-defmethod forge--review-set-thread-resolved
  ((_repo forge-test-gitlab-repository) pr opener resolved)
  (forge-test--record-rest
   "PUT"
   (forge--format-resource
    pr (format "/projects/:project/merge_requests/:number/discussions/%s"
               (oref opener discussion-id)))
   (list (cons 'resolved (if resolved t :false)))))

(cl-defmethod forge--review-delete-comment
  ((_repo forge-test-gitlab-repository) _pr rc)
  (forge-test--record-rest
   "DELETE"
   (forge--format-resource rc "/projects/:project/merge_requests/:topic/notes/:number")
   nil))

(cl-defmethod forge--review-post-comment
  ((_repo forge-test-gitlab-repository) pr body path side line)
  (forge-test--record-rest
   "POST"
   (forge--format-resource pr "/projects/:project/merge_requests/:number/discussions")
   (list (cons 'body body)
         (cons 'position (list (cons 'base_sha  (oref pr base-sha))
                               (cons 'start_sha (oref pr base-rev))
                               (cons 'head_sha  (oref pr head-rev))
                               (cons 'position_type "text")
                               (cons 'new_path  path)
                               (cons 'old_path  (or path ""))
                               (cons 'new_line  (when (eq side 'new) line))
                               (cons 'old_line  (when (eq side 'old) line)))))))

(defmacro forge-test--capture-request (&rest body)
  "Execute BODY, returning the last captured REST/mutate call as a plist.
Relies on the fake repo subclasses recording into `forge-test--last-request'."
  (declare (indent 0))
  `(progn
     (setq forge-test--last-request nil
           forge-test--all-requests nil)
     ,@body
     forge-test--last-request))

(defmacro forge-test--capture-all-requests (&rest body)
  "Execute BODY, returning all captured calls in order (first call first)."
  (declare (indent 0))
  `(progn
     (setq forge-test--last-request nil
           forge-test--all-requests nil)
     ,@body
     (nreverse forge-test--all-requests)))

(defmacro forge-test--capture-pull-topic (&rest body)
  "Execute BODY; return t if `forge--pull-topic' was called, nil otherwise.
Stubs `forge--pull-topic' as a no-op recorder."
  (declare (indent 0))
  `(let ((called nil))
     (cl-letf (((symbol-function 'forge--pull-topic)
                (lambda (&rest _) (setq called t))))
       ,@body)
     called))

(defun forge-test--make-repo ()
  "Insert and return a minimal forge-test-github-repository into the current DB."
  (let* ((repo (forge-test-github-repository
                :id       forge-test--repo-id
                :forge-id "123"
                :forge    "github.com"
                :owner    "alice"
                :name     "myrepo"
                :apihost  "api.github.com"
                :githost  "github.com")))
    (oset repo condition :tracked)
    (closql-insert (forge-db) repo t)
    repo))

(defun forge-test--make-gl-repo ()
  "Insert and return a minimal forge-test-gitlab-repository into the current DB."
  (let* ((repo (forge-test-gitlab-repository
                :id       forge-test--gl-repo-id
                :forge-id "456"
                :forge    "gitlab.com"
                :owner    "alice"
                :name     "proj"
                :apihost  "gitlab.com/api/v4"
                :githost  "gitlab.com")))
    (oset repo condition :tracked)
    (closql-insert (forge-db) repo t)
    repo))

(defun forge-test--make-pullreq (repo)
  "Insert and return a minimal forge-pullreq under REPO."
  (let* ((pr (forge-pullreq
              :id         forge-test--pr-id
              :repository (oref repo id)
              :number     42
              :state      'open
              :author     "bob"
              :title      "Add widget"
              :base-ref   "main"
              :base-rev   "abc000"
              :head-ref   "feature"
              :head-rev   "def999"
              :body       "")))
    (closql-insert (forge-db) pr t)
    pr))

(defun forge-test--make-review-comment (pullreq &rest overrides)
  "Return a `forge-pullreq-review-comment' plist with sane defaults.
OVERRIDES is a plist that replaces individual slots."
  (apply #'forge-pullreq-review-comment
         (append
          (list :id            "rc-1"
                :their-id      "gh-node-1"
                :discussion-id "thread-1"
                :number        101
                :pullreq       (oref pullreq id)
                :new-path      "src/foo.el"
                :old-path      nil
                :new-line      10
                :old-line      nil
                :diff-hunk     "@@ -8,3 +8,5 @@\n context\n+added\n context"
                :outdated-p    nil
                :resolved-p    nil
                :reply-to      nil
                :review-state  'commented
                :author        "carol"
                :body          "Looks good"
                :created       "2026-07-13T10:00:00Z"
                :updated       "2026-07-13T10:00:00Z"
                :reactions     nil
                :pending-p     nil)
          overrides)))


(defun forge-test--make-gl-pullreq (repo)
  "Insert and return a minimal forge-pullreq under REPO using the GitLab PR id."
  (let* ((pr (forge-pullreq
              :id         forge-test--gl-pr-id
              :repository (oref repo id)
              :number     42
              :state      'open
              :author     "bob"
              :title      "Add widget"
              :base-ref   "main"
              :base-rev   "abc000"
              :head-ref   "feature"
              :head-rev   "def999"
              :body       "")))
    (closql-insert (forge-db) pr t)
    pr))

(defun forge-test--make-gl-review-comment (pullreq &rest overrides)
  "Return a `forge-pullreq-review-comment' for a GitLab PR with sane defaults.
OVERRIDES is a plist that replaces individual slots."
  (apply #'forge-test--make-review-comment pullreq
         (append (list :id "gl-rc-1" :their-id "gl-node-1"
                       :discussion-id "gl-thread-1" :number 201)
                 overrides)))

(defun forge-test--invoke-submit-fn (fn repo post)
  "Simulate `forge-post-submit' by calling FN with REPO and POST.
This exercises the two-argument dispatch protocol directly."
  (funcall fn repo post))

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

;;; Data model

(ert-deftest forge-review-data-model-slot-round-trip ()
  "Insert a review comment with all slots set; fetch back; all slots match."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr
                   :reactions '((thumbs-up . 2)))))
      (closql-insert (forge-db) rc t)
      (let ((fetched (closql-get (forge-db) "rc-1" 'forge-pullreq-review-comment)))
        (should (equal (oref fetched their-id)      "gh-node-1"))
        (should (equal (oref fetched discussion-id) "thread-1"))
        (should (equal (oref fetched number)         101))
        (should (equal (oref fetched new-path)      "src/foo.el"))
        (should (equal (oref fetched old-path)      nil))
        (should (equal (oref fetched new-line)      10))
        (should (equal (oref fetched old-line)      nil))
        (should (equal (oref fetched author)        "carol"))
        (should (equal (oref fetched body)          "Looks good"))
        (should (equal (oref fetched reactions)     '((thumbs-up . 2))))
        (should (equal (oref fetched pending-p)     nil))))))

(ert-deftest forge-review-data-model-opener-vs-reply-identity ()
  "One opener and two replies; query returns correct structure."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :id "rc-opener" :reply-to nil :discussion-id "t1"))
           (reply1 (forge-test--make-review-comment pr
                     :id "rc-reply1" :reply-to "t1" :discussion-id "t1"
                     :their-id "gh-node-2"))
           (reply2 (forge-test--make-review-comment pr
                     :id "rc-reply2" :reply-to "t1" :discussion-id "t1"
                     :their-id "gh-node-3")))
      (dolist (rc (list opener reply1 reply2))
        (closql-insert (forge-db) rc t))
      (let* ((all    (oref pr review-comments))
             (openers (seq-filter (lambda (c) (null (oref c reply-to))) all))
             (replies (seq-filter (lambda (c) (oref c reply-to)) all)))
        (should (= (length all) 3))
        (should (= (length openers) 1))
        (should (= (length replies) 2))
        (should (cl-every (lambda (c) (equal (oref c reply-to) "t1")) replies))))))

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

(ert-deftest forge-review-data-model-pending-flag-persists ()
  "A pending comment's `pending-p' survives a DB close/reopen cycle."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :pending-p t)))
      (closql-insert (forge-db) rc t)
      ;; Close and reopen the connection.
      (emacsql-close (forge-db))
      (oset-default 'forge-database singleton eieio--unbound)
      (let ((fetched (closql-get (forge-db) "rc-1"
                                 'forge-pullreq-review-comment)))
        (should (eq (oref fetched pending-p) t))))))

(ert-deftest forge-review-data-model-schema-table-created ()
  "forge-db creates the review-comment table via closql--db-create-schema."
  (forge-test--with-db
    (let ((db (forge-db)))
      ;; Table was created by forge-test--with-db setup; verify it exists.
      (should (member 'pullreq_review_comment (emacsql-sqlite-list-tables db)))
      ;; The old reviews column must still be present on pullreq.
      (let ((cols (mapcar #'cadr
                          (emacsql (oref db connection)
                                   "PRAGMA table_info(pullreq)"))))
        (should (member 'reviews cols))))))

(ert-deftest forge-review-data-model-nil-old-path-roundtrip ()
  "A review comment with nil old-path (pure addition) inserts and reads back."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :old-path nil)))
      (closql-insert (forge-db) rc t)
      (should (null (oref (closql-get (forge-db) "rc-1"
                                      'forge-pullreq-review-comment)
                          old-path))))))

;;; Diff line-number computation

(defmacro forge-test--with-diff-buffer (content &rest body)
  "Run BODY with a temp buffer containing CONTENT in diff-mode, point at start."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,content)
     (diff-mode)
     (goto-char (point-min))
     ,@body))

(defconst forge-test--simple-diff
  (concat "diff --git a/src/foo.el b/src/foo.el\n"
          "--- a/src/foo.el\n"
          "+++ b/src/foo.el\n"
          "@@ -8,3 +8,5 @@\n"
          " (context-line-8)\n"         ; old=8  new=8  (context)
          "-(deleted-line-9)\n"         ; old=9  new=--
          "+(added-line-9)\n"           ; old=-- new=9
          "+(added-line-10)\n"          ; old=-- new=10
          " (context-line-10-old)\n"))  ; old=10 new=11

(ert-deftest forge-review-diff-pos-addition-line ()
  "A `+' line maps to the correct new-line number."
  (forge-test--with-diff-buffer forge-test--simple-diff
    ;; Navigate to the first `+' line ("added-line-9" = new line 9).
    (re-search-forward "^+(added-line-9)")
    (beginning-of-line)
    (pcase-let ((`(,side . ,n) (forge--diff-line-number-at-point)))
      (should (eq side 'new))
      (should (= n 9)))))

(ert-deftest forge-review-diff-pos-deletion-line ()
  "A `-' line maps to the correct old-line number."
  (forge-test--with-diff-buffer forge-test--simple-diff
    (re-search-forward "^-(deleted-line-9)")
    (beginning-of-line)
    (pcase-let ((`(,side . ,n) (forge--diff-line-number-at-point)))
      (should (eq side 'old))
      (should (= n 9)))))

(ert-deftest forge-review-diff-pos-context-line-both-sides ()
  "A context line returns both old and new numbers."
  (forge-test--with-diff-buffer forge-test--simple-diff
    ;; First context line: old=8 new=8.
    (re-search-forward "^ (context-line-8)")
    (beginning-of-line)
    (let ((result (forge--diff-line-number-at-point)))
      ;; Returns an alist or a cons pair with both sides.
      (should (alist-get 'old result))
      (should (alist-get 'new result))
      (should (= (alist-get 'old result) 8))
      (should (= (alist-get 'new result) 8)))))

(defconst forge-test--two-hunk-diff
  (concat "diff --git a/src/bar.el b/src/bar.el\n"
          "--- a/src/bar.el\n"
          "+++ b/src/bar.el\n"
          "@@ -1,3 +1,3 @@\n"
          " line-1\n"
          "-(old-line-2)\n"
          "+(new-line-2)\n"
          " line-3\n"
          "@@ -20,3 +20,4 @@\n"
          " line-20\n"
          "+(inserted-between-20-21)\n"  ; new=21
          " line-21\n"
          " line-22\n"))

(ert-deftest forge-review-diff-pos-multi-hunk-second-hunk ()
  "Line numbers in the second hunk are relative to that hunk's header."
  (forge-test--with-diff-buffer forge-test--two-hunk-diff
    (re-search-forward "^+(inserted-between-20-21)")
    (beginning-of-line)
    (pcase-let ((`(,side . ,n) (forge--diff-line-number-at-point)))
      (should (eq side 'new))
      (should (= n 21)))))

(ert-deftest forge-review-diff-pos-goto-line-round-trip ()
  "forge--diff-goto-line brings point back to the line identified by forge--diff-line-number-at-point."
  (forge-test--with-diff-buffer forge-test--simple-diff
    (re-search-forward "^+(added-line-9)")
    (beginning-of-line)
    (let* ((original-pos (point))
           (result       (forge--diff-line-number-at-point))
           (side         (car result))
           (n            (cdr result)))
      (goto-char (point-min))
      (forge--diff-goto-line "src/foo.el" "src/foo.el" side n)
      (should (= (point) original-pos)))))

(ert-deftest forge-review-diff-util-file-at-point ()
  "`forge--diff-file-at-point' returns the path from the nearest +++ header."
  (with-temp-buffer
    (insert "diff --git a/src/foo.el b/src/foo.el\n"
            "--- a/src/foo.el\n"
            "+++ b/src/foo.el\n"
            "@@ -1,2 +1,3 @@\n"
            " ctx\n"
            "+new\n")
    (goto-char (point-max))
    (should (equal (forge--diff-file-at-point) "src/foo.el"))))

(ert-deftest forge-review-diff-util-file-at-point-nil-outside-diff ()
  "`forge--diff-file-at-point' returns nil when there is no +++ header."
  (with-temp-buffer
    (insert "plain text, no diff header\n")
    (goto-char (point-max))
    (should (null (forge--diff-file-at-point)))))

(ert-deftest forge-review-diff-util-find-hunk-header ()
  "`forge--diff-find-hunk-header' returns (OLD-START NEW-START) for the enclosing hunk."
  (forge-test--with-diff-buffer forge-test--simple-diff
    (re-search-forward "^+(added-line-9)")
    (beginning-of-line)
    (pcase-let ((`(,old ,new) (forge--diff-find-hunk-header)))
      (should (= old 8))
      (should (= new 8)))))

(ert-deftest forge-review-diff-pos-goto-line-context-line ()
  "forge--diff-goto-line navigates to a context line with side nil."
  (forge-test--with-diff-buffer forge-test--simple-diff
    (re-search-forward "^ (context-line-8)")
    (beginning-of-line)
    (let ((original-pos (point)))
      (goto-char (point-min))
      ;; side nil triggers the t branch: seeks a non-+/- line where new-n = 8.
      (forge--diff-goto-line "src/foo.el" "src/foo.el" nil 8)
      (should (= (point) original-pos)))))

(ert-deftest forge-review-diff-pos-goto-line-new-side-finds-context-line ()
  "forge--diff-goto-line with side='new locates a context line, not just '+' lines.
Regression: the predicate previously required ch=?+ so context lines were never found."
  (forge-test--with-diff-buffer forge-test--simple-diff
    (re-search-forward "^ (context-line-8)")
    (beginning-of-line)
    (let ((original-pos (point)))
      (goto-char (point-min))
      ;; Context line at new-line 8; side 'new should still find it.
      (forge--diff-goto-line "src/foo.el" "src/foo.el" 'new 8)
      (should (= (point) original-pos)))))

;;; API / fetch mapping

;; These tests call the internal mapping helpers with canned payloads.
;; They do NOT make network requests.

(defconst forge-test--github-thread-payload
  ;; Mimics one reviewThread node after ghub--graphql-walk-response has
  ;; flattened the edges/node wrappers: `comments' is a plain list of alists.
  '((id . "RT_thread1")
    (isResolved . :false)
    (isOutdated . :false)
    (path . "src/foo.el")
    (diffSide . "RIGHT")
    (line . 15)
    (comments
     ((id . "RC_node1")
      (databaseId . 201)
      (author (login . "alice"))
      (body . "First comment")
      (createdAt . "2026-07-13T09:00:00Z")
      (updatedAt . "2026-07-13T09:00:00Z")
      (diffHunk . "@@ -13,4 +13,4 @@\n line\n-old\n+new\n line")
      (reactionGroups . nil)
      (pullRequestReview (state . "COMMENTED")))
     ((id . "RC_node2")
      (databaseId . 202)
      (author (login . "bob"))
      (body . "Reply here")
      (createdAt . "2026-07-13T10:00:00Z")
      (updatedAt . "2026-07-13T10:00:00Z")
      (diffHunk . "@@ -13,4 +13,4 @@\n line\n-old\n+new\n line")
      (reactionGroups . nil)
      (pullRequestReview (state . "COMMENTED"))))))

(ert-deftest forge-review-api-github-graphql-thread-maps-to-rows ()
  "GitHub reviewThread node maps to two DB rows with correct slot values."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo)))
      (forge--update-pullreq-review-comments
       repo pr (list forge-test--github-thread-payload))
      (let* ((all    (oref pr review-comments))
             (opener (seq-find (lambda (c) (null (oref c reply-to))) all))
             (reply  (seq-find (lambda (c) (oref c reply-to)) all)))
        (should (= (length all) 2))
        (should opener)
        (should reply)
        (should (equal (oref opener discussion-id) "RT_thread1"))
        (should (equal (oref opener new-path)      "src/foo.el"))
        (should (= (oref opener new-line)          15))
        (should (null (oref opener old-line)))
        (should (null (oref opener resolved-p)))
        (should (equal (oref reply reply-to)       "RT_thread1"))))))

(ert-deftest forge-review-api-github-left-diffside-maps-to-old-line ()
  "diffSide=LEFT maps to old-line, not new-line."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (payload (cons '(diffSide . "LEFT") forge-test--github-thread-payload)))
      (forge--update-pullreq-review-comments repo pr (list payload))
      (let* ((opener (seq-find
                      (lambda (c) (null (oref c reply-to)))
                      (oref pr review-comments))))
        (should (null (oref opener new-line)))
        (should (= (oref opener old-line) 15))))))

(defconst forge-test--gitlab-discussion-payload
  ;; Mimics one discussion object from GET /merge_requests/:iid/discussions.
  '((id . "abc123")
    (notes
     ((id . 501)
      (type . "DiffNote")
      (author (username . "carol"))
      (body . "GitLab comment")
      (created_at . "2026-07-13T08:00:00Z")
      (updated_at . "2026-07-13T08:00:00Z")
      (position
       (new_path . "src/bar.el")
       (old_path . "src/bar.el")
       (new_line . 42)
       (old_line . nil)))
     ((id . 502)
      (type . "DiffNote")
      (author (username . "dave"))
      (body . "GitLab reply")
      (created_at . "2026-07-13T09:00:00Z")
      (updated_at . "2026-07-13T09:00:00Z")
      (position
       (new_path . "src/bar.el")
       (old_path . "src/bar.el")
       (new_line . 42)
       (old_line . nil)))
     ((id . 503)
      (type . "DiffNote")
      (author (username . "eve"))
      (body . "Another reply")
      (created_at . "2026-07-13T09:30:00Z")
      (updated_at . "2026-07-13T09:30:00Z")
      (position
       (new_path . "src/bar.el")
       (old_path . "src/bar.el")
       (new_line . 42)
       (old_line . nil))))))

(ert-deftest forge-review-api-gitlab-discussion-maps-to-rows ()
  "GitLab discussion maps to three DB rows; opener has new-line; replies have reply-to."
  (forge-test--with-db
    (let* ((repo (forge-gitlab-repository
                  :id forge-test--gl-repo-id :owner "alice" :name "proj"
                  :forge "gitlab.com" :forge-id "456"
                  :apihost "gitlab.com/api/v4" :githost "gitlab.com"))
           (_ (oset repo condition :tracked))
           (_ (closql-insert (forge-db) repo t))
           (pr   (forge-pullreq
                  :id forge-test--gl-pr-id :repository forge-test--gl-repo-id
                  :number 42 :state 'open :author "bob" :title "MR"
                  :base-ref "main" :base-rev "abc000"
                  :head-ref "feature" :head-rev "def999" :body ""))
           (_ (closql-insert (forge-db) pr t)))
      (forge--update-pullreq-review-comments
       repo pr (list forge-test--gitlab-discussion-payload))
      (let* ((all    (oref pr review-comments))
             (opener (seq-find (lambda (c) (null (oref c reply-to))) all))
             (replies (seq-filter (lambda (c) (oref c reply-to)) all)))
        (should (= (length all) 3))
        (should (= (oref opener new-line) 42))
        (should (= (length replies) 2))
        (should (cl-every (lambda (c) (equal (oref c reply-to) "abc123"))
                          replies))))))

(ert-deftest forge-review-api-gitlab-base-sha-stored ()
  "base-sha slot on a pullreq can be set and read back."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (_ (oset pr base-sha "deadbeef")))
      (should (equal (oref pr base-sha) "deadbeef")))))

(ert-deftest forge-review-api-github-outdated-thread-flag ()
  "A GitHub thread with isOutdated=t produces a row with outdated-p t."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (payload (cons '(isOutdated . t) forge-test--github-thread-payload)))
      (forge--update-pullreq-review-comments repo pr (list payload))
      (let ((opener (seq-find (lambda (c) (null (oref c reply-to)))
                              (oref pr review-comments))))
        (should (eq (oref opener outdated-p) t))))))

(ert-deftest forge-review-api-github-reactions-aggregated ()
  "reactionGroups content is aggregated into an alist on the reaction slot."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           ;; Patch the first comment (flat list after ghub walk) to include a reaction group.
           (payload (copy-tree forge-test--github-thread-payload))
           (first-comment (car (alist-get 'comments payload))))
      (setf (alist-get 'reactionGroups first-comment)
            '(((content . "THUMBS_UP") (reactors (totalCount . 3)))))
      (forge--update-pullreq-review-comments repo pr (list payload))
      (let ((opener (seq-find (lambda (c) (null (oref c reply-to)))
                              (oref pr review-comments))))
        (should (equal (oref opener reactions) '((thumbs-up . 3))))))))

(ert-deftest forge-review-api-gitlab-resolved-thread-sets-flag ()
  "A resolved GitLab discussion sets resolved-p=t on the opener."
  (forge-test--with-db
    (let* ((repo (forge-gitlab-repository
                  :id forge-test--gl-repo-id :owner "alice" :name "proj"
                  :forge "gitlab.com" :forge-id "456"
                  :apihost "gitlab.com/api/v4" :githost "gitlab.com"))
           (_ (oset repo condition :tracked))
           (_ (closql-insert (forge-db) repo t))
           (pr  (forge-pullreq
                 :id forge-test--gl-pr-id :repository forge-test--gl-repo-id
                 :number 42 :state 'open :author "bob" :title "MR"
                 :base-ref "main" :base-rev "abc000"
                 :head-ref "feature" :head-rev "def999" :body ""))
           (_ (closql-insert (forge-db) pr t))
           (payload `((id . "disc-res")
                      (resolved . t)
                      (notes
                       ((id . 601)
                        (type . "DiffNote")
                        (author (username . "frank"))
                        (body . "Resolved note")
                        (created_at . "2026-07-14T00:00:00Z")
                        (updated_at . "2026-07-14T00:00:00Z")
                        (position
                         (new_path . "src/x.el") (old_path . "src/x.el")
                         (new_line . 10) (old_line . nil)))))))
      (forge--update-pullreq-review-comments repo pr (list payload))
      (let ((opener (seq-find (lambda (c) (null (oref c reply-to)))
                              (oref pr review-comments))))
        (should opener)
        (should (eq (oref opener resolved-p) t))))))

(ert-deftest forge-review-api-gitlab-unresolved-thread-nil-flag ()
  "An unresolved GitLab discussion sets resolved-p=nil on the opener."
  (forge-test--with-db
    (let* ((repo (forge-gitlab-repository
                  :id forge-test--gl-repo-id :owner "alice" :name "proj"
                  :forge "gitlab.com" :forge-id "456"
                  :apihost "gitlab.com/api/v4" :githost "gitlab.com"))
           (_ (oset repo condition :tracked))
           (_ (closql-insert (forge-db) repo t))
           (pr  (forge-pullreq
                 :id forge-test--gl-pr-id :repository forge-test--gl-repo-id
                 :number 42 :state 'open :author "bob" :title "MR"
                 :base-ref "main" :base-rev "abc000"
                 :head-ref "feature" :head-rev "def999" :body ""))
           (_ (closql-insert (forge-db) pr t))
           (payload `((id . "disc-unres")
                      (resolved . :false)
                      (notes
                       ((id . 602)
                        (type . "DiffNote")
                        (author (username . "grace"))
                        (body . "Unresolved note")
                        (created_at . "2026-07-14T00:00:00Z")
                        (updated_at . "2026-07-14T00:00:00Z")
                        (position
                         (new_path . "src/y.el") (old_path . "src/y.el")
                         (new_line . 5) (old_line . nil)))))))
      (forge--update-pullreq-review-comments repo pr (list payload))
      (let ((opener (seq-find (lambda (c) (null (oref c reply-to)))
                              (oref pr review-comments))))
        (should opener)
        (should (null (oref opener resolved-p)))))))

(ert-deftest forge-review-api-github-review-state-stored ()
  "pullRequestReview.state is lowercased and stored as review-state symbol."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (payload (copy-tree forge-test--github-thread-payload))
           (first-comment (car (alist-get 'comments payload))))
      (setf (alist-get 'pullRequestReview first-comment)
            '((state . "APPROVED")))
      (forge--update-pullreq-review-comments repo pr (list payload))
      (let ((opener (seq-find (lambda (c) (null (oref c reply-to)))
                              (oref pr review-comments))))
        (should (eq (oref opener review-state) 'approved))))))

(ert-deftest forge-review-api-github-refresh-replaces-rows ()
  "Calling update twice with the same thread replaces rows, not duplicates them."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo)))
      (forge--update-pullreq-review-comments
       repo pr (list forge-test--github-thread-payload))
      (forge--update-pullreq-review-comments
       repo pr (list forge-test--github-thread-payload))
      (should (= (length (oref pr review-comments)) 2)))))

(ert-deftest forge-review-api-gitlab-note-without-position-skipped ()
  "A GitLab note without a position (system note) is not inserted into the DB."
  (forge-test--with-db
    (let* ((repo (forge-gitlab-repository
                  :id forge-test--gl-repo-id :owner "alice" :name "proj"
                  :forge "gitlab.com" :forge-id "456"
                  :apihost "gitlab.com/api/v4" :githost "gitlab.com"))
           (_ (oset repo condition :tracked))
           (_ (closql-insert (forge-db) repo t))
           (pr  (forge-pullreq
                 :id forge-test--gl-pr-id :repository forge-test--gl-repo-id
                 :number 42 :state 'open :author "bob" :title "MR"
                 :base-ref "main" :base-rev "abc000"
                 :head-ref "feature" :head-rev "def999" :body ""))
           (_ (closql-insert (forge-db) pr t))
           ;; A discussion whose only note has no position (system note).
           (payload '((id . "sys-disc")
                      (notes
                       ((id . 700)
                        (type . "Note")
                        (author (username . "system"))
                        (body . "mentioned in commit abc")
                        (created_at . "2026-07-14T00:00:00Z")
                        (updated_at . "2026-07-14T00:00:00Z"))))))
      (forge--update-pullreq-review-comments repo pr (list payload))
      (should (null (oref pr review-comments))))))

(ert-deftest forge-review-api-github-bool-all-cases ()
  "forge--github-bool converts t→t, :false→nil, nil→nil."
  (should (eq (forge--github-bool t) t))
  (should (eq (forge--github-bool :false) nil))
  (should (eq (forge--github-bool nil) nil)))

(ert-deftest forge-review-api-reaction-groups-zero-count-excluded ()
  "forge--reaction-groups-to-alist drops groups with totalCount=0 and handles nil."
  (should (null (forge--reaction-groups-to-alist nil)))
  (let ((groups '(((content . "THUMBS_UP") (reactors (totalCount . 0)))
                  ((content . "HEART")     (reactors (totalCount . 2))))))
    (let ((result (forge--reaction-groups-to-alist groups)))
      (should (= (length result) 1))
      (should (equal (car result) '(heart . 2))))))

;;; Write operations

;; These tests exercise the write generics.  For operations where the test
;; fake-subclass stubs the primitive (forge--review-post-reply, etc.),
;; forge-test--capture-request captures the recorded call.  For
;; forge--review-submit, the REAL method runs — tests stub forge--rest via
;; cl-letf so no network calls escape and forge-test--record-rest collects
;; the payload.  forge--pull-topic is stubbed as a no-op in tests whose
;; focus is payload shape; it is verified separately.

(ert-deftest forge-review-write-github-batch-submit ()
  "Submitting two pending GitHub comments produces a single POST to the reviews endpoint."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc1  (forge-test--make-review-comment pr
                   :id "rc-1" :pending-p t :body "Comment A" :new-line 5))
           (rc2  (forge-test--make-review-comment pr
                   :id "rc-2" :pending-p t :body "Comment B" :new-line 8
                   :their-id "gh-node-2")))
      (dolist (rc (list rc1 rc2))
        (closql-insert (forge-db) rc t))
      (let ((req (forge-test--capture-request
                   (forge-test--capture-pull-topic
                     (cl-letf (((symbol-function 'forge--rest)
                                (lambda (obj method resource &optional params &rest _)
                                  (forge-test--record-rest
                                   method
                                   (forge--format-resource obj resource)
                                   params))))
                       (forge--review-submit repo pr))))))
        (should (equal (plist-get req :method) "POST"))
        (should (string-match-p "pulls/42/reviews" (plist-get req :resource)))
        (let ((comments (alist-get 'comments (plist-get req :data))))
          (should (= (length comments) 2))
          (should (cl-some (lambda (c) (equal (alist-get 'body c) "Comment A"))
                           comments))
          (should (cl-some (lambda (c) (equal (alist-get 'body c) "Comment B"))
                           comments)))))))

(ert-deftest forge-review-write-gitlab-per-comment-post ()
  "Submitting two pending GitLab comments produces two POST requests, each with position."
  (forge-test--with-db
    (let* ((repo (forge-test--make-gl-repo))
           (pr   (forge-test--make-pullreq repo))
           (_ (oset pr base-sha "base000"))
           (rc1  (forge-test--make-review-comment pr
                   :id "rc-1" :pending-p t :body "GL Comment A" :new-line 5))
           (rc2  (forge-test--make-review-comment pr
                   :id "rc-2" :pending-p t :body "GL Comment B" :new-line 9
                   :their-id "gl-note-2")))
      (dolist (rc (list rc1 rc2))
        (closql-insert (forge-db) rc t))
      (let ((calls (forge-test--capture-all-requests
                     (forge-test--capture-pull-topic
                       (cl-letf (((symbol-function 'forge--rest)
                                  (lambda (obj method resource &optional params &rest _)
                                    (forge-test--record-rest
                                     method
                                     (forge--format-resource obj resource)
                                     params))))
                         (forge--review-submit repo pr))))))
        (should (= (length calls) 2))
        (cl-every
         (lambda (c)
           (should (string-match-p "merge_requests.*discussions" (plist-get c :resource)))
           (let ((pos (alist-get 'position (plist-get c :data))))
             (should pos)
             (should (alist-get 'base_sha pos))
             (should (alist-get 'head_sha pos))
             (should (alist-get 'start_sha pos))))
         calls)))))

(ert-deftest forge-review-write-github-reply-uses-in-reply-to ()
  "Replying to a GitHub comment sends in_reply_to = number."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :id "rc-opener" :number 999 :discussion-id "t1")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge--review-post-reply repo pr opener "Reply text"))))
        (should (string-match-p "pulls/42/comments" (plist-get req :resource)))
        (should (= (alist-get 'in_reply_to (plist-get req :data)) 999))))))

(ert-deftest forge-review-write-gitlab-reply-uses-discussion-endpoint ()
  "Replying to a GitLab comment posts to the discussion notes sub-endpoint."
  (forge-test--with-db
    (let* ((repo   (forge-test--make-gl-repo))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :id "rc-opener" :discussion-id "disc-abc")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge--review-post-reply repo pr opener "Reply text"))))
        (should (string-match-p "discussions/disc-abc/notes"
                                (plist-get req :resource)))))))

(ert-deftest forge-review-write-github-resolve-sends-mutation ()
  "Resolving a GitHub thread calls resolveReviewThread with discussion-id."
  (forge-test--with-db
    (let* ((repo   (forge-test--make-repo))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :discussion-id "RT_thread1")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge--review-set-thread-resolved repo pr opener t))))
        (should (eq (plist-get req :mutation) 'resolveReviewThread))
        (should (equal (alist-get 'threadId (plist-get req :args))
                       "RT_thread1"))))))

(ert-deftest forge-review-write-gitlab-resolve-sends-put ()
  "Resolving a GitLab thread sends PUT to the discussion endpoint with resolved=t."
  (forge-test--with-db
    (let* ((repo   (forge-test--make-gl-repo))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :discussion-id "disc-abc")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge--review-set-thread-resolved repo pr opener t))))
        (should (equal (plist-get req :method) "PUT"))
        (should (string-match-p "discussions/disc-abc" (plist-get req :resource)))
        (should (eq (alist-get 'resolved (plist-get req :data)) t))))))

(ert-deftest forge-review-write-discard-pending-removes-row ()
  "forge-discard-review-comment deletes the DB row."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :pending-p t)))
      (closql-insert (forge-db) rc t)
      (should (closql-get (forge-db) "rc-1" 'forge-pullreq-review-comment))
      (forge-discard-review-comment rc)
      (should-not (closql-get (forge-db) "rc-1" 'forge-pullreq-review-comment)))))

(ert-deftest forge-review-write-pending-cleared-after-submit ()
  "After forge--review-submit, pending-p becomes nil on all submitted rows."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc1  (forge-test--make-review-comment pr
                   :id "rc-1" :pending-p t :body "A"))
           (rc2  (forge-test--make-review-comment pr
                   :id "rc-2" :pending-p t :body "B" :their-id "gh-2")))
      (dolist (rc (list rc1 rc2))
        (closql-insert (forge-db) rc t))
      (forge-test--capture-pull-topic
        (cl-letf (((symbol-function 'forge--rest) #'ignore))
          (forge--review-submit repo pr)))
      (dolist (id '("rc-1" "rc-2"))
        (let ((fetched (closql-get (forge-db) id 'forge-pullreq-review-comment)))
          (should (null (oref fetched pending-p))))))))

(ert-deftest forge-review-write-github-unresolve-mutation ()
  "forge--review-set-thread-resolved with nil calls unresolveReviewThread mutation."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :discussion-id "RT_thread1")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge--review-set-thread-resolved repo pr opener nil))))
        (should (eq (plist-get req :mutation) 'unresolveReviewThread))
        (should (equal (alist-get 'threadId (plist-get req :args))
                       "RT_thread1"))))))

(ert-deftest forge-review-write-gitlab-unresolve-sends-put-false ()
  "Unresolving a GitLab thread sends PUT with resolved=:false."
  (forge-test--with-db
    (let* ((repo   (forge-test--make-gl-repo))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :discussion-id "disc-xyz")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                  (forge--review-set-thread-resolved repo pr opener nil))))
        (should (equal (plist-get req :method) "PUT"))
        (should (string-match-p "discussions/disc-xyz" (plist-get req :resource)))
        (should (eq (alist-get 'resolved (plist-get req :data)) :false))))))

(ert-deftest forge-review-write-gitlab-start-sha-uses-base-rev ()
  "GitLab submit uses base-rev (not base-sha) as start_sha."
  (forge-test--with-db
    (let* ((repo (forge-test--make-gl-repo))
           (pr   (forge-test--make-pullreq repo))
           (_    (oset pr base-sha "merge-base-000"))
           ;; base-rev is already "abc000" from make-pullreq
           (rc   (forge-test--make-review-comment pr
                   :id "rc-1" :pending-p t :body "GL test" :new-line 5)))
      (closql-insert (forge-db) rc t)
      (let ((calls (forge-test--capture-all-requests
                     (forge-test--capture-pull-topic
                       (cl-letf (((symbol-function 'forge--rest)
                                  (lambda (obj method resource &optional params &rest _)
                                    (forge-test--record-rest
                                     method
                                     (forge--format-resource obj resource)
                                     params))))
                         (forge--review-submit repo pr))))))
        (should (= (length calls) 1))
        (let ((pos (alist-get 'position (plist-get (car calls) :data))))
          (should (equal (alist-get 'base_sha pos) "merge-base-000"))
          (should (equal (alist-get 'start_sha pos) "abc000")))))))

(ert-deftest forge-review-write-gitlab-old-path-falls-back-to-new-path ()
  "When old-path is nil, GitLab submit uses new-path as old_path in the payload."
  (forge-test--with-db
    (let* ((repo (forge-test--make-gl-repo))
           (pr   (forge-test--make-pullreq repo))
           ;; old-path nil is the default from forge-test--make-review-comment
           (rc   (forge-test--make-review-comment pr
                   :id "rc-1" :pending-p t :body "GL test"
                   :new-path "src/foo.el" :old-path nil :new-line 5)))
      (closql-insert (forge-db) rc t)
      (let* ((calls (forge-test--capture-all-requests
                      (forge-test--capture-pull-topic
                        (cl-letf (((symbol-function 'forge--rest)
                                   (lambda (obj method resource &optional params &rest _)
                                     (forge-test--record-rest
                                      method
                                      (forge--format-resource obj resource)
                                      params))))
                          (forge--review-submit repo pr)))))
             (pos (alist-get 'position (plist-get (car calls) :data))))
        (should (equal (alist-get 'new_path pos) "src/foo.el"))
        ;; old_path must fall back to new_path when old-path is nil
        (should (equal (alist-get 'old_path pos) "src/foo.el"))))))

(ert-deftest forge-review-write-discard-submitted-calls-delete-api ()
  "Discarding a submitted (non-pending) GitHub comment calls DELETE on the API."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr
                   :number 777 :pending-p nil)))
      (closql-insert (forge-db) rc t)
      (let ((req (forge-test--capture-request
                   (forge-discard-review-comment rc))))
        (should (equal (plist-get req :method) "DELETE"))
        (should (string-match-p "pulls/comments/777" (plist-get req :resource))))
      (should-not (closql-get (forge-db) "rc-1" 'forge-pullreq-review-comment)))))

(ert-deftest forge-review-write-discard-pending-no-api-call ()
  "Discarding a pending comment removes the DB row without calling the API."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :pending-p t)))
      (closql-insert (forge-db) rc t)
      (setq forge-test--last-request nil)
      (forge-discard-review-comment rc)
      (should-not forge-test--last-request)
      (should-not (closql-get (forge-db) "rc-1" 'forge-pullreq-review-comment)))))

(ert-deftest forge-review-write-gitlab-delete-comment-calls-api ()
  "Deleting a GitLab comment sends DELETE to the notes endpoint."
  (forge-test--with-db
    (let* ((repo (forge-test--make-gl-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :number 42 :pending-p nil)))
      (closql-insert (forge-db) rc t)
      (let ((req (forge-test--capture-request
                   (forge-discard-review-comment rc))))
        (should (equal (plist-get req :method) "DELETE"))
        (should (string-match-p "merge_requests.*notes/42" (plist-get req :resource)))))))

(ert-deftest forge-review-write-comment-pullreq-flushes-pending ()
  "`forge-comment-pullreq' submits all pending comments for the pullreq."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :pending-p t :body "Pending")))
      (closql-insert (forge-db) rc t)
      (let ((req (forge-test--capture-request
                   (forge-test--capture-pull-topic
                     (cl-letf (((symbol-function 'forge--rest)
                                (lambda (obj method resource &optional params &rest _)
                                  (forge-test--record-rest
                                   method
                                   (forge--format-resource obj resource)
                                   params))))
                       (forge-comment-pullreq pr))))))
        (should (equal (plist-get req :method) "POST"))
        (should (string-match-p "pulls/42/reviews" (plist-get req :resource)))))))

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

(ert-deftest forge-review-write-submit-add-review-comment-stages-pending ()
  "`forge-review--stage-comment' inserts a pending row with the correct slots."
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
            (insert "A pending comment")
            (setq-local forge--buffer-post-object pr)
            (setq-local forge--pre-post-buffer diff-buf)
            (forge-review--stage-comment nil nil))))
      (let* ((all (oref pr review-comments))
             (rc  (car all)))
        (should (= (length all) 1))
        (should (eq (oref rc pending-p) t))
        (should (equal (oref rc body) "A pending comment"))
        (should (eq (oref rc new-line) 9))
        (should (equal (oref rc new-path) "src/foo.el")))))

(ert-deftest forge-review-write-submit-add-review-comment-context-line ()
  "`forge-review--stage-comment' on a context line stores both new-line and old-line.
Regression: (car result) was a cons cell, not a symbol, so both lines were stored as nil."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo)))
      (with-temp-buffer
        (insert forge-test--simple-diff)
        (diff-mode)
        (goto-char (point-min))
        (re-search-forward "^ (context-line-8)")
        (beginning-of-line)
        (let ((diff-buf (current-buffer)))
          (with-temp-buffer
            (insert "Context line comment")
            (setq-local forge--buffer-post-object pr)
            (setq-local forge--pre-post-buffer diff-buf)
            (forge-review--stage-comment nil nil))))
      (let* ((rc (car (oref pr review-comments))))
        (should-not (null rc))
        ;; context-line-8 is old=8 new=8; both must be stored
        (should (eq (oref rc new-line) 8))
        (should (eq (oref rc old-line) 8))
        (should (equal (oref rc new-path) "src/foo.el")))))))

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

(ert-deftest forge-review-write-submit-edit-review-comment-updates-body ()
  "`forge-review--save-comment-edit' updates the body slot in the DB."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :body "Original")))
      (closql-insert (forge-db) rc t)
      (with-temp-buffer
        (insert "Updated body")
        (setq-local forge--buffer-post-object rc)
        (setq-local forge--pre-post-buffer (current-buffer))
        (forge-review--save-comment-edit nil nil))
      (should (equal (oref (closql-get (forge-db) "rc-1"
                                       'forge-pullreq-review-comment)
                           body)
                     "Updated body")))))

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

(ert-deftest forge-review-write-submit-review-reply-posts-to-api ()
  "`forge--submit-review-reply' calls forge--review-post-reply with the opener."
  (forge-test--with-db
    (let* ((repo   (forge-test--make-repo))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :id "rc-opener" :number 999 :discussion-id "t1")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (with-temp-buffer
                     (insert "Reply body")
                     (setq-local forge--buffer-post-object opener)
                     (setq-local forge--pre-post-buffer (current-buffer))
                     (forge-test--invoke-submit-fn #'forge--submit-review-reply repo opener)))))
        (should (string-match-p "pulls/42/comments" (plist-get req :resource)))
        (should (= (alist-get 'in_reply_to (plist-get req :data)) 999))
        (should (equal (alist-get 'body (plist-get req :data)) "Reply body"))))))

(ert-deftest forge-review-write-github-pending-comments-shape ()
  "`forge--github-pending-review-comments' returns an alist with path/line/side/body."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr
                   :pending-p t :body "Check this" :new-path "src/x.el" :new-line 7)))
      (closql-insert (forge-db) rc t)
      (let ((comments (forge--github-pending-review-comments pr)))
        (should (= (length comments) 1))
        (let ((c (car comments)))
          (should (equal (alist-get 'path c) "src/x.el"))
          (should (= (alist-get 'line c) 7))
          (should (equal (alist-get 'side c) "RIGHT"))
          (should (equal (alist-get 'body c) "Check this")))))))

(ert-deftest forge-review-write-github-flush-pending-clears-flag ()
  "`forge--github-flush-pending-review-comments' sets pending-p nil on all rows."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc1  (forge-test--make-review-comment pr :id "rc-1" :pending-p t))
           (rc2  (forge-test--make-review-comment pr :id "rc-2" :pending-p t
                   :their-id "gh-2")))
      (dolist (rc (list rc1 rc2))
        (closql-insert (forge-db) rc t))
      (forge--github-flush-pending-review-comments pr)
      (dolist (id '("rc-1" "rc-2"))
        (should (null (oref (closql-get (forge-db) id
                                        'forge-pullreq-review-comment)
                            pending-p)))))))

(ert-deftest forge-review-write-gitlab-post-comment-calls-api ()
  "`forge--review-post-comment' on a GitLab repo posts to the discussions endpoint."
  (forge-test--with-db
    (let* ((repo (forge-test--make-gl-repo))
           (pr   (forge-test--make-pullreq repo)))
      (let ((req (forge-test--capture-request
                   (forge--review-post-comment
                    repo pr "Immediate GL comment" "src/foo.el" 'new 5))))
        (should (equal (plist-get req :method) "POST"))
        (should (string-match-p "merge_requests.*discussions" (plist-get req :resource)))
        (should (equal (alist-get 'body (plist-get req :data)) "Immediate GL comment"))
        (let ((pos (alist-get 'position (plist-get req :data))))
          (should (= (alist-get 'new_line pos) 5))
          (should (null (alist-get 'old_line pos))))))))

;;; Write operations — forge--pull-topic call verification
;;
;; The following three tests verify that `forge--review-submit' calls
;; `forge--pull-topic' after posting.  The test-subclass repos are used
;; because forge--review-submit is no longer overridden there — the real
;; method dispatches on any subclass of forge-github/gitlab-repository.
;; forge--rest is stubbed so no network calls happen; the GitHub stub fires
;; the :callback synchronously since that is where forge--pull-topic is called.

(ert-deftest forge-review-write-github-submit-calls-pull-topic ()
  "`forge--review-submit' on GitHub calls `forge--pull-topic' after posting."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :body "A comment")))
      (oset rc pending-p t)
      (closql-insert (forge-db) rc t)
      (let ((called
             (forge-test--capture-pull-topic
               (cl-letf (((symbol-function 'forge--rest)
                          (lambda (&rest args)
                            (let ((cb (cadr (memq :callback args))))
                              (when cb (funcall cb nil nil nil))))))
                 (forge--review-submit repo pr)))))
        (should called)))))

(ert-deftest forge-review-write-gitlab-submit-calls-pull-topic ()
  "`forge--review-submit' on GitLab calls `forge--pull-topic' after posting."
  (forge-test--with-db
    (let* ((repo (forge-test--make-gl-repo))
           (pr   (forge-test--make-gl-pullreq repo))
           (rc   (forge-test--make-gl-review-comment pr :body "GL comment")))
      (oset rc pending-p t)
      (closql-insert (forge-db) rc t)
      (let ((called
             (forge-test--capture-pull-topic
               (cl-letf (((symbol-function 'forge--rest) #'ignore))
                 (forge--review-submit repo pr)))))
        (should called)))))

(ert-deftest forge-review-write-gitlab-submit-no-pull-when-no-pending ()
  "`forge--review-submit' on GitLab does not call `forge--pull-topic' when
there are no pending comments — avoids spurious API round-trips."
  (forge-test--with-db
    (let* ((repo (forge-test--make-gl-repo))
           (pr   (forge-test--make-gl-pullreq repo)))
      (let ((called (forge-test--capture-pull-topic
                      (forge--review-submit repo pr))))
        (should-not called)))))

;;; forge-post-submit regression
;;
;; These tests call `forge-post-submit' itself — the real dispatcher —
;; instead of calling submit functions directly.  They close the gap that
;; allowed the original arity-mismatch bug to go undetected: if a future
;; submit callback is written with zero args these tests will catch it
;; because they go through the same code path a user triggers with C-c C-c.

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
                          (wrong-number-of-arguments err))))))
      (should (= (length (oref pr review-comments)) 1)))))

(ert-deftest forge-review-regression-save-comment-edit-via-forge-post-submit ()
  "Calling `forge-post-submit' with forge-review--save-comment-edit must not
signal wrong-number-of-arguments."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :body "Original")))
      (closql-insert (forge-db) rc t)
      ;; forge-get-repository is called with rc (forge-pullreq-review-comment),
      ;; which has no method; stub it to return the test repo.
      (cl-letf (((symbol-function 'forge-get-repository) (lambda (_obj) repo)))
        (forge-test--with-post-buffer #'forge-review--save-comment-edit rc
          (insert "Edited body")
          (setq-local forge--pre-post-buffer (current-buffer))
          (should-not (condition-case err
                          (progn (forge-post-submit) nil)
                        (wrong-number-of-arguments err)))))
      (should (equal (oref (closql-get (forge-db) "rc-1"
                                       'forge-pullreq-review-comment)
                           body)
                     "Edited body")))))

(ert-deftest forge-review-regression-submit-review-reply-via-forge-post-submit ()
  "Calling `forge-post-submit' with forge--submit-review-reply must not
signal wrong-number-of-arguments."
  (forge-test--with-db
    (let* ((repo   (forge-test--make-repo))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :id "rc-opener" :number 999 :discussion-id "t1")))
      (closql-insert (forge-db) opener t)
      ;; forge-get-repository is called with opener (forge-pullreq-review-comment),
      ;; which has no method; stub it to return the test repo.
      (let ((req (forge-test--capture-request
                   (cl-letf (((symbol-function 'forge-get-repository)
                              (lambda (_obj) repo)))
                     (forge-test--with-post-buffer #'forge--submit-review-reply opener
                       (insert "Reply via forge-post-submit")
                       (setq-local forge--pre-post-buffer (current-buffer))
                       (should-not (condition-case err
                                       (progn (forge-post-submit) nil)
                                     (wrong-number-of-arguments err))))))))
        (should (string-match-p "pulls/42/comments" (plist-get req :resource)))
        (should (equal (alist-get 'body (plist-get req :data))
                       "Reply via forge-post-submit"))))))

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

;;; Display

(ert-deftest forge-review-display-review-threads-section-present ()
  "forge-insert-review-threads inserts a review-threads section for a pullreq."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr)))
      (closql-insert (forge-db) rc t)
      (with-temp-buffer
        (magit-insert-section (topicbuf)
          (forge-insert-review-threads pr))
        (let ((found nil))
          (magit-map-sections
           (lambda (section)
             (when (eq (oref section type) 'review-threads)
               (setq found t))))
          (should found))))))

(ert-deftest forge-review-display-no-review-threads-for-issues ()
  "forge--maybe-insert-review-threads does NOT insert a section for issues."
  (forge-test--with-db
    (let* ((repo  (forge-test--make-repo))
           (issue (forge-issue
                   :id "iss-1" :repository (oref repo id)
                   :number 1 :state 'open :author "alice"
                   :title "Bug" :body "")))
      (closql-insert (forge-db) issue t)
      (with-temp-buffer
        (setq-local forge-buffer-topic issue)
        (magit-insert-section (topicbuf)
          (forge--maybe-insert-review-threads))
        (let ((found nil))
          (magit-map-sections
           (lambda (section)
             (when (eq (oref section type) 'review-threads)
               (setq found t))))
          (should-not found))))))

(ert-deftest forge-review-display-file-grouping ()
  "Openers on two different files produce two per-file sub-sections."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc1  (forge-test--make-review-comment pr
                   :id "rc-1" :new-path "src/a.el"))
           (rc2  (forge-test--make-review-comment pr
                   :id "rc-2" :new-path "src/a.el" :their-id "n2"))
           (rc3  (forge-test--make-review-comment pr
                   :id "rc-3" :new-path "src/b.el" :their-id "n3")))
      (dolist (rc (list rc1 rc2 rc3))
        (closql-insert (forge-db) rc t))
      (with-temp-buffer
        (magit-insert-section (topicbuf)
          (forge-insert-review-threads pr))
        (let ((file-sections nil))
          (magit-map-sections
           (lambda (section)
             (when (eq (oref section type) 'review-file)
               (push (oref section value) file-sections))))
          (should (= (length file-sections) 2))
          (should (member "src/a.el" file-sections))
          (should (member "src/b.el" file-sections)))))))

(ert-deftest forge-review-display-heading-resolved-outdated-badges ()
  "Resolved and outdated openers have the corresponding badge in the heading."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr
                   :resolved-p t :outdated-p t)))
      (closql-insert (forge-db) rc t)
      (with-temp-buffer
        (magit-insert-section (topicbuf)
          (forge-insert-review-threads pr))
        (let ((heading nil))
          (magit-map-sections
           (lambda (section)
             (when (eq (oref section type) 'review-comment)
               (setq heading (oref section heading)))))
          (should (string-match-p "\\[resolved\\]" heading))
          (should (string-match-p "\\[outdated\\]"  heading))
          (should (string-match-p "@carol" heading))
          (should (string-match-p "line 10" heading)))))))

(ert-deftest forge-review-display-heading-pending-badge ()
  "A pending comment's heading includes [pending]."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :pending-p t)))
      (closql-insert (forge-db) rc t)
      (with-temp-buffer
        (magit-insert-section (topicbuf)
          (forge-insert-review-threads pr))
        (let ((heading nil))
          (magit-map-sections
           (lambda (section)
             (when (eq (oref section type) 'review-comment)
               (setq heading (oref section heading)))))
          (should (string-match-p "\\[pending\\]" heading))
          (should (string-match-p "@carol" heading)))))))

(ert-deftest forge-review-display-reply-sections-are-children ()
  "Reply sections are children of the opener section in the Magit tree."
  (forge-test--with-db
    (let* ((repo   (forge-test--make-repo))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :id "rc-o" :reply-to nil :discussion-id "t1"))
           (reply  (forge-test--make-review-comment pr
                     :id "rc-r" :reply-to "t1" :discussion-id "t1"
                     :their-id "n2")))
      (dolist (rc (list opener reply))
        (closql-insert (forge-db) rc t))
      (with-temp-buffer
        (magit-insert-section (topicbuf)
          (forge-insert-review-threads pr))
        (let ((opener-section nil))
          (magit-map-sections
           (lambda (section)
             (when (and (eq (oref section type) 'review-comment)
                        (null (oref (oref section value) reply-to)))
               (setq opener-section section))))
          (should opener-section)
          (should (cl-some (lambda (child)
                             (eq (oref child type) 'review-reply))
                           (oref opener-section children))))))))

(ert-deftest forge-review-display-resolved-thread-folded ()
  "A resolved thread is hidden (magit-section-hidden = t) after buffer refresh."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :resolved-p t)))
      (closql-insert (forge-db) rc t)
      (with-temp-buffer
        (magit-insert-section (topicbuf)
          (forge-insert-review-threads pr))
        (let ((section nil))
          (magit-map-sections
           (lambda (s)
             (when (eq (oref s type) 'review-comment)
               (setq section s))))
          (should section)
          (should (oref section hidden)))))))

(ert-deftest forge-review-display-overlay-has-after-string ()
  "A pending comment overlay in a diff buffer has a non-nil after-string."
  (with-temp-buffer
    (insert forge-test--simple-diff)
    (diff-mode)
    ;; Manufacture a review-comment object and place its overlay.
    (let* ((rc (forge-pullreq-review-comment
                :id "rc-test" :their-id "x" :discussion-id "t"
                :number 0 :pullreq "pr-1"
                :new-path "src/foo.el" :old-path nil
                :new-line 9 :old-line nil
                :author "alice" :body "Test comment"
                :pending-p t)))
      (goto-char (point-min))
      (re-search-forward "^+(added-line-9)")
      (beginning-of-line)
      (let ((ov (forge--place-review-comment-overlay rc (point) (pos-eol))))
        (should (overlayp ov))
        (should (overlay-get ov 'after-string))
        (should (string-match-p "Test comment"
                                (overlay-get ov 'after-string)))))))

(ert-deftest forge-review-display-diff-hunk-fontified ()
  "forge--fontify-diff returns a string with face or font-lock-face properties."
  (let* ((hunk "@@ -1,3 +1,3 @@\n context\n-removed\n+added\n")
         (result (forge--fontify-diff hunk)))
    (should (stringp result))
    ;; diff-mode sets face or font-lock-face depending on mode.
    (should (cl-some (lambda (i)
                       (or (get-text-property i 'font-lock-face result)
                           (get-text-property i 'face result)))
                     (number-sequence 0 (1- (length result)))))))

(defun forge-test--make-heading-rc (overrides)
  "Make a bare forge-pullreq-review-comment for heading tests (no DB)."
  (apply #'forge-pullreq-review-comment
         (append
          (list :id "h-test" :their-id "x" :discussion-id "t"
                :number 0 :pullreq "pr"
                :new-path "src/foo.el" :old-path nil
                :new-line nil :old-line nil
                :diff-hunk nil :outdated-p nil :resolved-p nil
                :reply-to nil :review-state nil
                :author "alice" :body "" :created "" :updated ""
                :reactions nil :pending-p nil)
          overrides)))

(ert-deftest forge-review-display-heading-includes-line-number ()
  "Heading includes line number and side indicator."
  (let* ((rc (forge-test--make-heading-rc
              (list :new-line 42 :author "alice"))))
    (let ((h (forge--review-comment-heading rc)))
      (should (string-match-p "@alice" h))
      (should (string-match-p "line 42" h))
      (should (string-match-p "RIGHT" h)))))

(ert-deftest forge-review-display-heading-old-line-left-side ()
  "Heading says LEFT when only old-line is set."
  (let* ((rc (forge-test--make-heading-rc
              (list :new-path nil :old-path "src/foo.el"
                    :new-line nil :old-line 7 :author "bob"))))
    (let ((h (forge--review-comment-heading rc)))
      (should (string-match-p "line 7" h))
      (should (string-match-p "LEFT" h)))))

(ert-deftest forge-review-display-heading-no-line-when-nil ()
  "Heading omits line info when both new-line and old-line are nil."
  (let* ((rc (forge-test--make-heading-rc (list :author "eve"))))
    (let ((h (forge--review-comment-heading rc)))
      (should (string-match-p "@eve" h))
      (should-not (string-match-p "line" h)))))

(ert-deftest forge-review-display-body-inserts-diff-hunk ()
  "forge--insert-review-comment-body inserts the diff hunk before the body."
  (let* ((rc (forge-test--make-heading-rc
              (list :diff-hunk "@@ -1,2 +1,3 @@\n ctx\n+added\n ctx"
                    :body "Looks good" :new-line 1))))
    (with-temp-buffer
      (forge--insert-review-comment-body rc)
      (let ((text (buffer-string)))
        (should (string-match-p "@@ -1,2" text))
        (should (string-match-p "Looks good" text))))))

(ert-deftest forge-review-display-body-inserts-reactions ()
  "forge--insert-review-comment-body renders reactions."
  (let* ((rc (forge-test--make-heading-rc
              (list :body "Nice"
                    :reactions '((thumbs-up . 3) (heart . 1))))))
    (with-temp-buffer
      (forge--insert-review-comment-body rc)
      (let ((text (buffer-string)))
        (should (string-match-p "thumbs-up 3" text))
        (should (string-match-p "heart 1" text))))))

(ert-deftest forge-review-display-diff-overlay-hook-installed ()
  "forge--maybe-insert-review-threads-in-diff is on magit-refresh-buffer-hook."
  (should (memq #'forge--maybe-insert-review-threads-in-diff
                magit-refresh-buffer-hook)))

(ert-deftest forge-review-display-diff-overlay-cleared-on-refresh ()
  "forge--clear-review-comment-overlays removes forge-review-comment overlays."
  (with-temp-buffer
    (let ((ov (make-overlay 1 5)))
      (overlay-put ov 'forge-review-comment t)
      (should (cl-some (lambda (o) (overlay-get o 'forge-review-comment))
                       (overlays-in (point-min) (point-max))))
      (forge--clear-review-comment-overlays)
      (should-not (cl-some (lambda (o) (overlay-get o 'forge-review-comment))
                           (overlays-in (point-min) (point-max)))))))

(ert-deftest forge-review-display-stale-overlays-cleared-when-review-comments-empty ()
  "forge--maybe-insert-review-threads-in-diff clears stale overlays even when
review-comments is empty (nil/()).
Regression: when-let* on (comments ()) short-circuited the clear call."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo)))
      (with-temp-buffer
        (insert forge-test--simple-diff)
        (magit-diff-mode)
        ;; Place a stale overlay manually.
        (let ((ov (make-overlay 1 5)))
          (overlay-put ov 'forge-review-comment t))
        (setq-local forge-buffer-topic pr)
        ;; PR has no review comments; the overlay must still be cleared.
        (forge--maybe-insert-review-threads-in-diff)
        (should-not (cl-some (lambda (o) (overlay-get o 'forge-review-comment))
                             (overlays-in (point-min) (point-max))))))))

;;; Thread navigation

(defun forge-test--make-nav-buffer ()
  "Return a diff-mode buffer with two comment overlays at lines 5 and 20."
  (let ((buf (generate-new-buffer " *forge-nav-test*")))
    (with-current-buffer buf
      (dotimes (_ 25) (insert " line\n"))
      (diff-mode)
      (let* ((line5-pos  (progn (goto-char (point-min)) (forward-line 4) (point)))
             (line20-pos (progn (goto-char (point-min)) (forward-line 19) (point)))
             (make-ov    (lambda (pos)
                           (let ((ov (make-overlay pos (+ pos 5))))
                             (overlay-put ov 'forge-review-comment t)
                             ov))))
        (funcall make-ov line5-pos)
        (funcall make-ov line20-pos)))
    buf))

(ert-deftest forge-review-nav-forward-to-next ()
  "forge-next-review-thread moves point to the next overlay."
  (let ((buf (forge-test--make-nav-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))            ; before both overlays
          (forge-next-review-thread)
          (let ((line (line-number-at-pos)))
            (should (= line 5))))
      (kill-buffer buf))))

(ert-deftest forge-review-nav-forward-at-last-signals-error ()
  "forge-next-review-thread at or after the last overlay signals user-error."
  (let ((buf (forge-test--make-nav-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (should-error (forge-next-review-thread) :type 'user-error))
      (kill-buffer buf))))

(ert-deftest forge-review-nav-backward-to-previous ()
  "forge-previous-review-thread moves point to the previous overlay."
  (let ((buf (forge-test--make-nav-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (forge-previous-review-thread)
          (let ((line (line-number-at-pos)))
            (should (= line 20))))
      (kill-buffer buf))))

;;; Collapse / expand

(defun forge-test--make-comment-overlay (body)
  "Return an overlay in a temp buffer whose after-string is BODY."
  (let* ((buf (generate-new-buffer " *forge-collapse-test*"))
         (_ (with-current-buffer buf (insert "line\n")))
         (ov (with-current-buffer buf (make-overlay 1 5))))
    (overlay-put ov 'after-string body)
    (overlay-put ov 'forge-review-comment t)
    ov))

(ert-deftest forge-review-collapse-replaces-body ()
  "forge-collapse-review-thread replaces after-string and stores original."
  (let ((ov (forge-test--make-comment-overlay "Full body text")))
    (unwind-protect
        (progn
          (forge-collapse-review-thread ov)
          (should (not (equal (overlay-get ov 'after-string) "Full body text")))
          (should (equal (overlay-get ov 'forge-thread-original-text) "Full body text")))
      (delete-overlay ov)
      (kill-buffer (overlay-buffer ov)))))

(ert-deftest forge-review-collapse-expand-restores-body ()
  "forge-expand-review-thread restores the original after-string."
  (let ((ov (forge-test--make-comment-overlay "Full body text")))
    (unwind-protect
        (progn
          (forge-collapse-review-thread ov)
          (forge-expand-review-thread ov)
          (should (equal (overlay-get ov 'after-string) "Full body text"))
          (should (null (overlay-get ov 'forge-thread-original-text))))
      (delete-overlay ov)
      (kill-buffer (overlay-buffer ov)))))

(ert-deftest forge-review-collapse-toggle-round-trips ()
  "Two calls to forge-toggle-review-thread leave after-string unchanged."
  (let ((ov (forge-test--make-comment-overlay "Full body text")))
    (unwind-protect
        (progn
          (forge-toggle-review-thread ov)
          (forge-toggle-review-thread ov)
          (should (equal (overlay-get ov 'after-string) "Full body text")))
      (delete-overlay ov)
      (kill-buffer (overlay-buffer ov)))))

;;; Reply context stripping

(ert-deftest forge-review-reply-context-html-comment-stripped ()
  "forge--clear-comment-input strips a leading <!-- ... --> block."
  (let ((input "<!-- context lines\n-->\n\nActual reply"))
    (should (equal (forge--clear-comment-input input) "Actual reply"))))

(ert-deftest forge-review-reply-context-no-comment-unchanged ()
  "forge--clear-comment-input leaves input without HTML comments intact (trimmed)."
  (let ((input "  Just a normal reply  "))
    (should (equal (forge--clear-comment-input input) "Just a normal reply"))))

(ert-deftest forge-review-reply-context-multiple-blocks-stripped ()
  "forge--clear-comment-input removes all <!-- ... --> blocks."
  (let ((input "<!-- block 1\n-->\nKeep this\n<!-- block 2\n-->\nAnd this"))
    (let ((result (forge--clear-comment-input input)))
      (should (not (string-match-p "<!--" result)))
      (should (string-match-p "Keep this" result))
      (should (string-match-p "And this" result)))))

;;; _

(provide 'forge-review-test)
;;; forge-review-test.el ends here
