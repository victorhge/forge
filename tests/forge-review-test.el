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
           ;; Open the DB (creates v15 schema), then add the review-comment table.
           (let ((db (forge-db)))
             (forge--db-create-review-comment-table db))
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

(defun forge-test--make-repo ()
  "Insert and return a minimal forge-github-repository into the current DB."
  (let* ((repo (forge-github-repository
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
                :database-id   101
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

;;; ──────────────────────────────────────────────────────────────
;;; Group 1: Data model
;;; ──────────────────────────────────────────────────────────────

(ert-deftest forge-review-DM-1-slot-round-trip ()
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
        (should (equal (oref fetched database-id)   101))
        (should (equal (oref fetched new-path)      "src/foo.el"))
        (should (equal (oref fetched old-path)      nil))
        (should (equal (oref fetched new-line)      10))
        (should (equal (oref fetched old-line)      nil))
        (should (equal (oref fetched author)        "carol"))
        (should (equal (oref fetched body)          "Looks good"))
        (should (equal (oref fetched reactions)     '((thumbs-up . 2))))
        (should (equal (oref fetched pending-p)     nil))))))

(ert-deftest forge-review-DM-2-opener-vs-reply-identity ()
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

(ert-deftest forge-review-DM-3-pending-flag-persists ()
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

(ert-deftest forge-review-DM-4-schema-migration ()
  "forge--db-create-review-comment-table creates the review-comment table."
  (forge-test--with-db
    (let ((db (forge-db)))
      ;; Table was created by forge-test--with-db setup; verify it exists.
      (should (member 'pullreq_review_comment (emacsql-sqlite-list-tables db)))
      ;; The old reviews column must still be present on pullreq.
      (let ((cols (mapcar #'cadr
                          (emacsql (oref db connection)
                                   "PRAGMA table_info(pullreq)"))))
        (should (member 'reviews cols))))))

(ert-deftest forge-review-DM-5-nil-old-path ()
  "A review comment with nil old-path (pure addition) inserts and reads back."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :old-path nil)))
      (closql-insert (forge-db) rc t)
      (should (null (oref (closql-get (forge-db) "rc-1"
                                      'forge-pullreq-review-comment)
                          old-path))))))

;;; ──────────────────────────────────────────────────────────────
;;; Group 2: Diff line-number computation
;;; ──────────────────────────────────────────────────────────────

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

(ert-deftest forge-review-POS-1-addition-line ()
  "A `+' line maps to the correct new-line number."
  (forge-test--with-diff-buffer forge-test--simple-diff
    ;; Navigate to the first `+' line ("added-line-9" = new line 9).
    (re-search-forward "^+(added-line-9)")
    (beginning-of-line)
    (pcase-let ((`(,side . ,n) (forge--diff-line-number-at-point)))
      (should (eq side 'new))
      (should (= n 9)))))

(ert-deftest forge-review-POS-2-deletion-line ()
  "A `-' line maps to the correct old-line number."
  (forge-test--with-diff-buffer forge-test--simple-diff
    (re-search-forward "^-(deleted-line-9)")
    (beginning-of-line)
    (pcase-let ((`(,side . ,n) (forge--diff-line-number-at-point)))
      (should (eq side 'old))
      (should (= n 9)))))

(ert-deftest forge-review-POS-3-context-line ()
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

(ert-deftest forge-review-POS-4-multi-hunk-second-hunk ()
  "Line numbers in the second hunk are relative to that hunk's header."
  (forge-test--with-diff-buffer forge-test--two-hunk-diff
    (re-search-forward "^+(inserted-between-20-21)")
    (beginning-of-line)
    (pcase-let ((`(,side . ,n) (forge--diff-line-number-at-point)))
      (should (eq side 'new))
      (should (= n 21)))))

(ert-deftest forge-review-POS-5-round-trip ()
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

;;; ──────────────────────────────────────────────────────────────
;;; Group 3: API / fetch mapping
;;; ──────────────────────────────────────────────────────────────

;; These tests call the internal mapping helpers with canned payloads.
;; They do NOT make network requests.

(defconst forge-test--github-thread-payload
  ;; Mimics one reviewThread node from the GraphQL response.
  '((id . "RT_thread1")
    (isResolved . :false)
    (isOutdated . :false)
    (path . "src/foo.el")
    (diffSide . "RIGHT")
    (line . 15)
    (comments
     (edges
      ((node . ((id . "RC_node1")
                (databaseId . 201)
                (author (login . "alice"))
                (body . "First comment")
                (createdAt . "2026-07-13T09:00:00Z")
                (updatedAt . "2026-07-13T09:00:00Z")
                (diffHunk . "@@ -13,4 +13,4 @@\n line\n-old\n+new\n line")
                (reactionGroups . nil)
                (pullRequestReview (state . "COMMENTED")))))
      ((node . ((id . "RC_node2")
                (databaseId . 202)
                (author (login . "bob"))
                (body . "Reply here")
                (createdAt . "2026-07-13T10:00:00Z")
                (updatedAt . "2026-07-13T10:00:00Z")
                (diffHunk . "@@ -13,4 +13,4 @@\n line\n-old\n+new\n line")
                (reactionGroups . nil)
                (pullRequestReview (state . "COMMENTED")))))))))

(ert-deftest forge-review-API-1-github-graphql-mapping ()
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

(ert-deftest forge-review-API-2-github-left-diffside ()
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

(ert-deftest forge-review-API-3-gitlab-discussions-mapping ()
  "GitLab discussion maps to three DB rows; opener has new-line; replies have reply-to."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo)))
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

(ert-deftest forge-review-API-4-gitlab-base-sha-stored ()
  "base_sha from GitLab diff_refs is stored on the pullreq."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (mr-data '((diff_refs (base_sha . "deadbeef")
                                 (start_sha . "abc")
                                 (head_sha . "def")))))
      (forge--update-pullreq-base-sha pr mr-data)
      (should (equal (oref pr base-sha) "deadbeef")))))

(ert-deftest forge-review-API-5-outdated-thread ()
  "A GitHub thread with isOutdated=t produces a row with outdated-p t."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (payload (cons '(isOutdated . t) forge-test--github-thread-payload)))
      (forge--update-pullreq-review-comments repo pr (list payload))
      (let ((opener (seq-find (lambda (c) (null (oref c reply-to)))
                              (oref pr review-comments))))
        (should (eq (oref opener outdated-p) t))))))

(ert-deftest forge-review-API-6-reactions-aggregated ()
  "reactionGroups content is aggregated into an alist on the reaction slot."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           ;; Patch the first comment to include a reaction group.
           (payload (copy-tree forge-test--github-thread-payload))
           (first-edge (car (alist-get 'edges (alist-get 'comments payload))))
           (first-node (alist-get 'node first-edge)))
      (setf (alist-get 'reactionGroups first-node)
            '(((content . "THUMBS_UP") (reactors (totalCount . 3)))))
      (forge--update-pullreq-review-comments repo pr (list payload))
      (let ((opener (seq-find (lambda (c) (null (oref c reply-to)))
                              (oref pr review-comments))))
        (should (equal (oref opener reactions) '((thumbs-up . 3))))))))

;;; ──────────────────────────────────────────────────────────────
;;; Group 4: Write operations
;;; ──────────────────────────────────────────────────────────────

;; These tests capture the payload that would be sent to the API by
;; intercepting the forge-rest / forge-mutate call.

(defmacro forge-test--capture-request (&rest body)
  "Execute BODY, capturing the last REST/mutate call.
Stubs `forge-review--do-rest' and `forge-review--do-mutate'.
Returns a plist with :method, :resource, :data, or :mutation/:args."
  (declare (indent 0))
  (let ((captured (make-symbol "captured")))
    `(let (,captured)
       (cl-letf (((symbol-function 'forge-review--do-rest)
                  (lambda (method resource data &optional _success)
                    (setq ,captured
                          (list :method   method
                                :resource resource
                                :data     data))))
                 ((symbol-function 'forge-review--do-mutate)
                  (lambda (mutation args)
                    (setq ,captured
                          (list :mutation mutation :args args)))))
         ,@body
         ,captured))))

(ert-deftest forge-review-WR-1-github-batch-submit ()
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
                   (forge--submit-github-review repo pr 'comment))))
        (should (equal (plist-get req :method) "POST"))
        (should (string-match-p "pulls/42/reviews" (plist-get req :resource)))
        (let ((comments (alist-get 'comments (plist-get req :data))))
          (should (= (length comments) 2))
          (should (cl-some (lambda (c) (equal (alist-get 'body c) "Comment A"))
                           comments))
          (should (cl-some (lambda (c) (equal (alist-get 'body c) "Comment B"))
                           comments)))))))

(ert-deftest forge-review-WR-2-gitlab-per-comment-post ()
  "Submitting two pending GitLab comments produces two POST requests, each with position."
  (forge-test--with-db
    (let* ((repo    (forge-gitlab-repository
                     :id "repo-gl" :owner "alice" :name "proj"
                     :forge "gitlab.com" :forge-id "456"
                     :apihost "gitlab.com/api/v4" :githost "gitlab.com"
                     ))
           (_ (oset repo condition :tracked))
           (_ (closql-insert (forge-db) repo t))
           (pr   (forge-test--make-pullreq repo))
           (_ (oset pr base-sha "base000"))
           (rc1  (forge-test--make-review-comment pr
                   :id "rc-1" :pending-p t :body "GL Comment A" :new-line 5))
           (rc2  (forge-test--make-review-comment pr
                   :id "rc-2" :pending-p t :body "GL Comment B" :new-line 9
                   :their-id "gl-note-2")))
      (dolist (rc (list rc1 rc2))
        (closql-insert (forge-db) rc t))
      (let ((calls nil))
        (cl-letf (((symbol-function 'forge-review--do-rest)
                   (lambda (method resource data &optional _success)
                     (push (list :method method :resource resource :data data)
                           calls))))
          (forge--submit-gitlab-review-comment repo pr))
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

(ert-deftest forge-review-WR-3-github-reply-uses-in-reply-to ()
  "Replying to a GitHub comment sends in_reply_to_id = database-id."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :id "rc-opener" :database-id 999 :discussion-id "t1")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge--github-post-reply repo pr opener "Reply text"))))
        (should (string-match-p "pulls/42/comments" (plist-get req :resource)))
        (should (= (alist-get 'in_reply_to_id (plist-get req :data)) 999))))))

(ert-deftest forge-review-WR-4-gitlab-reply-uses-discussion-endpoint ()
  "Replying to a GitLab comment posts to the discussion notes sub-endpoint."
  (forge-test--with-db
    (let* ((repo (forge-gitlab-repository
                  :id "repo-gl" :owner "alice" :name "proj"
                  :forge "gitlab.com" :forge-id "456"
                  :apihost "gitlab.com/api/v4" :githost "gitlab.com"))
           (_ (oset repo condition :tracked))
           (_ (closql-insert (forge-db) repo t))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :id "rc-opener" :discussion-id "disc-abc")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge--gitlab-post-reply repo pr opener "Reply text"))))
        (should (string-match-p "discussions/disc-abc/notes"
                                (plist-get req :resource)))))))

(ert-deftest forge-review-WR-5-github-resolve-sends-mutation ()
  "Resolving a GitHub thread calls resolveReviewThread with discussion-id."
  (forge-test--with-db
    (let* ((repo   (forge-test--make-repo))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :discussion-id "RT_thread1")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge--github-resolve-thread repo pr opener))))
        (should (eq (plist-get req :mutation) 'resolveReviewThread))
        (should (equal (alist-get 'threadId (plist-get req :args))
                       "RT_thread1"))))))

(ert-deftest forge-review-WR-6-gitlab-resolve-sends-put ()
  "Resolving a GitLab thread sends PUT to the discussion endpoint with resolved=t."
  (forge-test--with-db
    (let* ((repo (forge-gitlab-repository
                  :id "repo-gl" :owner "alice" :name "proj"
                  :forge "gitlab.com" :forge-id "456"
                  :apihost "gitlab.com/api/v4" :githost "gitlab.com"))
           (_ (oset repo condition :tracked))
           (_ (closql-insert (forge-db) repo t))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :discussion-id "disc-abc")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge--gitlab-resolve-thread repo pr opener t))))
        (should (equal (plist-get req :method) "PUT"))
        (should (string-match-p "discussions/disc-abc" (plist-get req :resource)))
        (should (eq (alist-get 'resolved (plist-get req :data)) t))))))

(ert-deftest forge-review-WR-7-discard-pending-removes-row ()
  "forge-discard-review-comment deletes the DB row."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :pending-p t)))
      (closql-insert (forge-db) rc t)
      (should (closql-get (forge-db) "rc-1" 'forge-pullreq-review-comment))
      (forge-discard-review-comment rc)
      (should-not (closql-get (forge-db) "rc-1" 'forge-pullreq-review-comment)))))

(ert-deftest forge-review-WR-8-pending-cleared-after-submit ()
  "After a successful submit callback, pending-p becomes nil on all submitted rows."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc1  (forge-test--make-review-comment pr
                   :id "rc-1" :pending-p t :body "A"))
           (rc2  (forge-test--make-review-comment pr
                   :id "rc-2" :pending-p t :body "B" :their-id "gh-2")))
      (dolist (rc (list rc1 rc2))
        (closql-insert (forge-db) rc t))
      ;; Simulate the success callback that the submit function fires.
      (cl-letf (((symbol-function 'forge-review--do-rest) #'ignore))
        (forge--submit-github-review repo pr 'comment))
      (dolist (id '("rc-1" "rc-2"))
        (let ((fetched (closql-get (forge-db) id 'forge-pullreq-review-comment)))
          (should (null (oref fetched pending-p))))))))

;;; ──────────────────────────────────────────────────────────────
;;; Group 5: Display
;;; ──────────────────────────────────────────────────────────────

(ert-deftest forge-review-UI-1-review-threads-section-present ()
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

(ert-deftest forge-review-UI-2-no-review-threads-for-issues ()
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

(ert-deftest forge-review-UI-3-file-grouping ()
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

(ert-deftest forge-review-UI-4-heading-badges ()
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

(ert-deftest forge-review-UI-5-pending-badge ()
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

(ert-deftest forge-review-UI-6-reply-sections-are-children ()
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

(ert-deftest forge-review-UI-7-resolved-thread-folded ()
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

(ert-deftest forge-review-UI-8-overlay-after-string ()
  "A pending comment overlay in a diff buffer has a non-nil after-string."
  (with-temp-buffer
    (insert forge-test--simple-diff)
    (diff-mode)
    ;; Manufacture a review-comment object and place its overlay.
    (let* ((rc (forge-pullreq-review-comment
                :id "rc-test" :their-id "x" :discussion-id "t"
                :database-id 0 :pullreq "pr-1"
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

(ert-deftest forge-review-UI-9-diff-hunk-fontified ()
  "forge--fontify-diff returns a string with face or font-lock-face properties."
  (let* ((hunk "@@ -1,3 +1,3 @@\n context\n-removed\n+added\n")
         (result (forge--fontify-diff hunk)))
    (should (stringp result))
    ;; diff-mode sets face or font-lock-face depending on mode.
    (should (cl-some (lambda (i)
                       (or (get-text-property i 'font-lock-face result)
                           (get-text-property i 'face result)))
                     (number-sequence 0 (1- (length result)))))))

;;; ──────────────────────────────────────────────────────────────
;;; Group 6: Thread navigation
;;; ──────────────────────────────────────────────────────────────

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

(ert-deftest forge-review-NAV-1-forward-to-next ()
  "forge-next-review-thread moves point to the next overlay."
  (let ((buf (forge-test--make-nav-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))            ; before both overlays
          (forge-next-review-thread)
          (let ((line (line-number-at-pos)))
            (should (= line 5))))
      (kill-buffer buf))))

(ert-deftest forge-review-NAV-2-forward-at-last-signals-error ()
  "forge-next-review-thread at or after the last overlay signals user-error."
  (let ((buf (forge-test--make-nav-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (should-error (forge-next-review-thread) :type 'user-error))
      (kill-buffer buf))))

(ert-deftest forge-review-NAV-3-backward ()
  "forge-previous-review-thread moves point to the previous overlay."
  (let ((buf (forge-test--make-nav-buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (forge-previous-review-thread)
          (let ((line (line-number-at-pos)))
            (should (= line 20))))
      (kill-buffer buf))))

;;; ──────────────────────────────────────────────────────────────
;;; Group 7: Collapse / expand
;;; ──────────────────────────────────────────────────────────────

(defun forge-test--make-comment-overlay (body)
  "Return an overlay in a temp buffer whose after-string is BODY."
  (let* ((buf (generate-new-buffer " *forge-collapse-test*"))
         (_ (with-current-buffer buf (insert "line\n")))
         (ov (with-current-buffer buf (make-overlay 1 5))))
    (overlay-put ov 'after-string body)
    (overlay-put ov 'forge-review-comment t)
    ov))

(ert-deftest forge-review-COL-1-collapse-replaces-body ()
  "forge-collapse-review-thread replaces after-string and stores original."
  (let ((ov (forge-test--make-comment-overlay "Full body text")))
    (unwind-protect
        (progn
          (forge-collapse-review-thread ov)
          (should (not (equal (overlay-get ov 'after-string) "Full body text")))
          (should (equal (overlay-get ov 'forge-thread-original-text) "Full body text")))
      (delete-overlay ov)
      (kill-buffer (overlay-buffer ov)))))

(ert-deftest forge-review-COL-2-expand-restores-body ()
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

(ert-deftest forge-review-COL-3-toggle-round-trips ()
  "Two calls to forge-toggle-review-thread leave after-string unchanged."
  (let ((ov (forge-test--make-comment-overlay "Full body text")))
    (unwind-protect
        (progn
          (forge-toggle-review-thread ov)
          (forge-toggle-review-thread ov)
          (should (equal (overlay-get ov 'after-string) "Full body text")))
      (delete-overlay ov)
      (kill-buffer (overlay-buffer ov)))))

;;; ──────────────────────────────────────────────────────────────
;;; Group 8: Reply context stripping
;;; ──────────────────────────────────────────────────────────────

(ert-deftest forge-review-RC-1-html-comment-removed ()
  "forge--clear-comment-input strips a leading <!-- ... --> block."
  (let ((input "<!-- context lines\n-->\n\nActual reply"))
    (should (equal (forge--clear-comment-input input) "Actual reply"))))

(ert-deftest forge-review-RC-2-no-comment-block-unchanged ()
  "forge--clear-comment-input leaves input without HTML comments intact (trimmed)."
  (let ((input "  Just a normal reply  "))
    (should (equal (forge--clear-comment-input input) "Just a normal reply"))))

(ert-deftest forge-review-RC-3-multiple-blocks-stripped ()
  "forge--clear-comment-input removes all <!-- ... --> blocks."
  (let ((input "<!-- block 1\n-->\nKeep this\n<!-- block 2\n-->\nAnd this"))
    (let ((result (forge--clear-comment-input input)))
      (should (not (string-match-p "<!--" result)))
      (should (string-match-p "Keep this" result))
      (should (string-match-p "And this" result)))))

;;; ──────────────────────────────────────────────────────────────
;;; Group 9: New functionality (heading, display, resolve/unresolve)
;;; ──────────────────────────────────────────────────────────────

(defun forge-test--make-heading-rc (overrides)
  "Make a bare forge-pullreq-review-comment for heading tests (no DB)."
  (apply #'forge-pullreq-review-comment
         (append
          (list :id "h-test" :their-id "x" :discussion-id "t"
                :database-id 0 :pullreq "pr"
                :new-path "src/foo.el" :old-path nil
                :new-line nil :old-line nil
                :diff-hunk nil :outdated-p nil :resolved-p nil
                :reply-to nil :review-state nil
                :author "alice" :body "" :created "" :updated ""
                :reactions nil :pending-p nil)
          overrides)))

(ert-deftest forge-review-NEW-1-heading-includes-line-number ()
  "Heading includes line number and side indicator."
  (let* ((rc (forge-test--make-heading-rc
              (list :new-line 42 :author "alice"))))
    (let ((h (forge--review-comment-heading rc)))
      (should (string-match-p "@alice" h))
      (should (string-match-p "line 42" h))
      (should (string-match-p "RIGHT" h)))))

(ert-deftest forge-review-NEW-2-heading-old-line-left-side ()
  "Heading says LEFT when only old-line is set."
  (let* ((rc (forge-test--make-heading-rc
              (list :new-path nil :old-path "src/foo.el"
                    :new-line nil :old-line 7 :author "bob"))))
    (let ((h (forge--review-comment-heading rc)))
      (should (string-match-p "line 7" h))
      (should (string-match-p "LEFT" h)))))

(ert-deftest forge-review-NEW-3-heading-no-line-when-nil ()
  "Heading omits line info when both new-line and old-line are nil."
  (let* ((rc (forge-test--make-heading-rc (list :author "eve"))))
    (let ((h (forge--review-comment-heading rc)))
      (should (string-match-p "@eve" h))
      (should-not (string-match-p "line" h)))))

(ert-deftest forge-review-NEW-4-body-inserts-diff-hunk ()
  "forge--insert-review-comment-body inserts the diff hunk before the body."
  (let* ((rc (forge-test--make-heading-rc
              (list :diff-hunk "@@ -1,2 +1,3 @@\n ctx\n+added\n ctx"
                    :body "Looks good" :new-line 1))))
    (with-temp-buffer
      (forge--insert-review-comment-body rc)
      (let ((text (buffer-string)))
        (should (string-match-p "@@ -1,2" text))
        (should (string-match-p "Looks good" text))))))

(ert-deftest forge-review-NEW-5-body-inserts-reactions ()
  "forge--insert-review-comment-body renders reactions."
  (let* ((rc (forge-test--make-heading-rc
              (list :body "Nice"
                    :reactions '((thumbs-up . 3) (heart . 1))))))
    (with-temp-buffer
      (forge--insert-review-comment-body rc)
      (let ((text (buffer-string)))
        (should (string-match-p "thumbs-up 3" text))
        (should (string-match-p "heart 1" text))))))

(ert-deftest forge-review-NEW-6-github-unresolve-mutation ()
  "forge--github-unresolve-thread calls unresolveReviewThread mutation."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :discussion-id "RT_thread1")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge--github-unresolve-thread repo pr opener))))
        (should (eq (plist-get req :mutation) 'unresolveReviewThread))
        (should (equal (alist-get 'threadId (plist-get req :args))
                       "RT_thread1"))))))

(ert-deftest forge-review-NEW-7-gitlab-unresolve-sends-put-false ()
  "Unresolving a GitLab thread sends PUT with resolved=:false."
  (forge-test--with-db
    (let* ((repo (forge-gitlab-repository
                  :id "repo-gl" :owner "alice" :name "proj"
                  :forge "gitlab.com" :forge-id "456"
                  :apihost "gitlab.com/api/v4" :githost "gitlab.com"))
           (_ (oset repo condition :tracked))
           (_ (closql-insert (forge-db) repo t))
           (pr     (forge-test--make-pullreq repo))
           (opener (forge-test--make-review-comment pr
                     :discussion-id "disc-xyz")))
      (closql-insert (forge-db) opener t)
      (let ((req (forge-test--capture-request
                   (forge--gitlab-resolve-thread repo pr opener nil))))
        (should (equal (plist-get req :method) "PUT"))
        (should (string-match-p "discussions/disc-xyz" (plist-get req :resource)))
        (should (eq (alist-get 'resolved (plist-get req :data)) :false))))))

(ert-deftest forge-review-NEW-8-gitlab-start-sha-uses-base-rev ()
  "GitLab submit uses base-rev (not base-sha) as start_sha."
  (forge-test--with-db
    (let* ((repo (forge-gitlab-repository
                  :id "repo-gl" :owner "alice" :name "proj"
                  :forge "gitlab.com" :forge-id "456"
                  :apihost "gitlab.com/api/v4" :githost "gitlab.com"))
           (_ (oset repo condition :tracked))
           (_ (closql-insert (forge-db) repo t))
           (pr (forge-test--make-pullreq repo))
           (_ (oset pr base-sha "merge-base-000"))
           ;; base-rev is already "abc000" from make-pullreq
           (rc (forge-test--make-review-comment pr
                 :id "rc-1" :pending-p t :body "GL test" :new-line 5)))
      (closql-insert (forge-db) rc t)
      (let ((calls nil))
        (cl-letf (((symbol-function 'forge-review--do-rest)
                   (lambda (method resource data &optional _success)
                     (push (list :method method :resource resource :data data)
                           calls))))
          (forge--submit-gitlab-review-comment repo pr))
        (should (= (length calls) 1))
        (let ((pos (alist-get 'position (plist-get (car calls) :data))))
          (should (equal (alist-get 'base_sha pos) "merge-base-000"))
          (should (equal (alist-get 'start_sha pos) "abc000")))))))

;;; ──────────────────────────────────────────────────────────────
;;; Group 10: New items (gitlab resolved-p, discard API, approve/
;;;           request-changes pending flush, diff overlay hook)
;;; ──────────────────────────────────────────────────────────────

(ert-deftest forge-review-NEW-9-gitlab-resolved-p-from-api ()
  "A resolved GitLab discussion sets resolved-p=t on the opener."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
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

(ert-deftest forge-review-NEW-10-gitlab-unresolved-p-from-api ()
  "An unresolved GitLab discussion sets resolved-p=nil on the opener."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
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

(ert-deftest forge-review-NEW-11-discard-submitted-calls-api ()
  "Discarding a submitted (non-pending) GitHub comment calls DELETE on the API."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr
                   :database-id 777 :pending-p nil)))
      (closql-insert (forge-db) rc t)
      (let ((req (forge-test--capture-request
                   (forge-discard-review-comment rc))))
        (should (equal (plist-get req :method) "DELETE"))
        (should (string-match-p "pulls/comments/777" (plist-get req :resource))))
      (should-not (closql-get (forge-db) "rc-1" 'forge-pullreq-review-comment)))))

(ert-deftest forge-review-NEW-12-discard-pending-no-api-call ()
  "Discarding a pending comment removes the DB row without calling the API."
  (forge-test--with-db
    (let* ((repo (forge-test--make-repo))
           (pr   (forge-test--make-pullreq repo))
           (rc   (forge-test--make-review-comment pr :pending-p t)))
      (closql-insert (forge-db) rc t)
      (let ((called nil))
        (cl-letf (((symbol-function 'forge-review--do-rest)
                   (lambda (&rest _) (setq called t))))
          (forge-discard-review-comment rc))
        (should-not called))
      (should-not (closql-get (forge-db) "rc-1" 'forge-pullreq-review-comment)))))

(ert-deftest forge-review-NEW-13-diff-overlay-hook-installed ()
  "forge--maybe-insert-review-threads-in-diff is on magit-refresh-buffer-hook."
  (should (memq #'forge--maybe-insert-review-threads-in-diff
                magit-refresh-buffer-hook)))

(ert-deftest forge-review-NEW-14-diff-overlay-cleared-on-refresh ()
  "forge--clear-review-comment-overlays removes forge-review-comment overlays."
  (with-temp-buffer
    (let ((ov (make-overlay 1 5)))
      (overlay-put ov 'forge-review-comment t)
      (should (cl-some (lambda (o) (overlay-get o 'forge-review-comment))
                       (overlays-in (point-min) (point-max))))
      (forge--clear-review-comment-overlays)
      (should-not (cl-some (lambda (o) (overlay-get o 'forge-review-comment))
                           (overlays-in (point-min) (point-max)))))))

;;; _

(provide 'forge-review-test)
;;; forge-review-test.el ends here
