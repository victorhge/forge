;;; forge-review.el --- Inline PR/MR review comment support  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Jonas Bernoulli

;; Author: Jonas Bernoulli <emacs.forge@jonas.bernoulli.dev>
;; Maintainer: Jonas Bernoulli <emacs.forge@jonas.bernoulli.dev>

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published
;; by the Free Software Foundation, either version 3 of the License,
;; or (at your option) any later version.
;;
;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Code:

(require 'cl-lib)
(require 'diff-mode)
(require 'forge)
(require 'forge-post)
(require 'forge-pullreq)
(require 'forge-topic)

(declare-function forge-gitlab-repository--eieio-childp "forge-gitlab" (obj))

;;; Class

(defclass forge-pullreq-review-comment (closql-object)
  ((closql-table         :initform 'pullreq-review-comment)
   (closql-primary-key   :initform 'id)
   (closql-order-by      :initform [(asc created)])
   (closql-foreign-key   :initform 'pullreq)
   (closql-class-prefix  :initform "forge-pullreq-review-")
   (id            :initarg :id)
   (their-id      :initarg :their-id)
   (discussion-id :initarg :discussion-id)
   (database-id   :initarg :database-id)
   (pullreq       :initarg :pullreq)
   (new-path      :initarg :new-path)
   (old-path      :initarg :old-path)
   (new-line      :initarg :new-line)
   (old-line      :initarg :old-line)
   (diff-hunk     :initarg :diff-hunk)
   (outdated-p    :initarg :outdated-p)
   (resolved-p    :initarg :resolved-p)
   (reply-to      :initarg :reply-to)
   (review-state  :initarg :review-state)
   (author        :initarg :author)
   (body          :initarg :body)
   (created       :initarg :created)
   (updated       :initarg :updated)
   (reactions     :initarg :reactions)
   (pending-p     :initarg :pending-p)))

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

;;; Fetch / Mapping

(defun forge--reaction-groups-to-alist (groups)
  "Convert GitHub reactionGroups list to an alist of (SYMBOL . COUNT)."
  (when groups
    (delq nil
          (mapcar (lambda (g)
                    (let-alist g
                      (let ((n .reactors.totalCount))
                        (when (and n (> n 0))
                          (cons (intern (downcase
                                         (replace-regexp-in-string
                                          "_" "-" .content)))
                                n)))))
                  groups))))

(defun forge--update-pullreq-review-comments (repo pr threads)
  "Store THREADS (GitHub reviewThreads or GitLab discussions) under PR."
  (closql-with-transaction (forge-db)
    (let ((pr-id (oref pr id)))
      (dolist (thread threads)
        (cond
          ;; GitHub: has `comments' edges
          ((alist-get 'comments thread)
           (forge--update-github-review-thread pr-id thread))
          ;; GitLab: has `notes' list
          ((alist-get 'notes thread)
           (forge--update-gitlab-discussion pr-id thread)))))))

(defun forge--update-github-review-thread (pr-id thread)
  "Store a single GitHub reviewThread into the DB."
  (let-alist thread
    (let* ((thread-id .id)
           (resolved  (forge--github-bool .isResolved))
           (outdated  (forge--github-bool .isOutdated))
           (left-side (equal .diffSide "LEFT"))
           (line      .line)
           (path      .path)
           (comments  (alist-get 'comments thread))
           (opener-their-id nil))
      (dolist (comment comments)
        (let-alist comment
          (let* ((is-opener (null opener-their-id))
                 (rc-id     (forge--object-id pr-id .id))
                 (reply-to  (unless is-opener thread-id))
                 (state2    (when-let ((r .pullRequestReview))
                              (intern (downcase (alist-get 'state r))))))
            (when is-opener
              (setq opener-their-id .id))
            (closql-insert
             (forge-db)
             (forge-pullreq-review-comment
              :id           rc-id
              :their-id     .id
              :discussion-id thread-id
              :database-id  .databaseId
              :pullreq      pr-id
              :new-path     (unless left-side path)
              :old-path     (when left-side path)
              :new-line     (unless left-side line)
              :old-line     (when left-side line)
              :diff-hunk    .diffHunk
              :outdated-p   outdated
              :resolved-p   (unless is-opener nil)
              :reply-to     reply-to
              :review-state state2
              :author       .author.login
              :body         (forge--sanitize-string .body)
              :created      .createdAt
              :updated      .updatedAt
              :reactions    (forge--reaction-groups-to-alist .reactionGroups)
              :pending-p    nil)
             t)))))))

;; TODO: move forge--github-bool to forge-github.el and update all call sites
;; there to use it instead of inlining the same cond.
(defun forge--github-bool (val)
  "Convert GitHub JSON boolean (t/:false/nil) to Elisp boolean."
  (cond ((eq val t) t)
        ((eq val :false) nil)
        (t val)))

(defun forge--update-gitlab-discussion (pr-id discussion)
  "Store a single GitLab discussion (with notes) into the DB."
  (let* ((disc-id   (alist-get 'id discussion))
         (resolved  (eq t (alist-get 'resolved discussion)))
         (notes     (alist-get 'notes discussion))
         (first     t))
    (dolist (note notes)
      (let-alist note
        (let* ((reply-to (unless first disc-id))
               (rc-id    (forge--object-id pr-id (number-to-string .id))))
          (when .position
            (closql-insert
             (forge-db)
             (forge-pullreq-review-comment
              :id           rc-id
              :their-id     (number-to-string .id)
              :discussion-id disc-id
              :database-id  .id
              :pullreq      pr-id
              :new-path     .position.new_path
              :old-path     .position.old_path
              :new-line     .position.new_line
              :old-line     .position.old_line
              :diff-hunk    nil
              :outdated-p   nil
              :resolved-p   (when first resolved)
              :reply-to     reply-to
              :review-state nil
              :author       .author.username
              :body         (forge--sanitize-string .body)
              :created      .created_at
              :updated      .updated_at
              :reactions    nil
              :pending-p    nil)
             t))
          (setq first nil))))))


;;; Diff Line-Number Computation

(defun forge--diff-line-number-at-point ()
  "Return the line number at point in a diff buffer.
For `+' lines: returns (new . N).
For `-' lines: returns (old . N).
For context lines: returns an alist with both (old . N) and (new . N)."
  (save-excursion
    (beginning-of-line)
    (let ((target      (point))
          (target-char (char-after)))
      ;; Find the enclosing hunk header.
      (when (re-search-backward "^@@ -\\([0-9]+\\)[^+]*\\+\\([0-9]+\\)" nil t)
        (let ((old-line (string-to-number (match-string 1)))
              (new-line (string-to-number (match-string 2))))
          (forward-line 1)  ; move past the @@ header line
          ;; Walk forward up to (but not including) target, counting lines.
          (while (< (point) target)
            (let ((ch (char-after)))
              (cond
                ((eq ch ?+) (cl-incf new-line))
                ((eq ch ?-) (cl-incf old-line))
                (t           (cl-incf old-line) (cl-incf new-line))))
            (forward-line 1))
          ;; At target: classify by the target line's prefix character.
          (cond
            ((eq target-char ?+) (cons 'new new-line))
            ((eq target-char ?-) (cons 'old old-line))
            (t                   (list (cons 'old old-line)
                                       (cons 'new new-line)))))))))

(defun forge--diff-find-hunk-header ()
  "Return (OLD-START NEW-START) for the hunk containing point."
  (save-excursion
    (when (re-search-backward "^@@ -\\([0-9]+\\)[^+]*\\+\\([0-9]+\\)" nil t)
      (list (string-to-number (match-string 1))
            (string-to-number (match-string 2))))))

(defun forge--diff-goto-line (new-path old-path side line)
  "Move point to LINE on SIDE in a diff buffer for NEW-PATH or OLD-PATH."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found)
                (re-search-forward
                 (format "^\\(?:\\+\\+\\+ b/%s\\|--- a/%s\\)"
                         (regexp-quote (or new-path ""))
                         (regexp-quote (or old-path "")))
                 nil t))
      ;; Find next hunk
      (while (and (not found)
                  (re-search-forward "^@@ -\\([0-9]+\\)[^+]*\\+\\([0-9]+\\)" nil t))
        (let* ((hunk-old (string-to-number (match-string 1)))
               (hunk-new (string-to-number (match-string 2)))
               (old-n    hunk-old)
               (new-n    hunk-new))
          (forward-line 1)
          (while (not (or found (looking-at "^@@") (eobp)))
            (let ((ch (char-after)))
              (when (cond
                      ((eq side 'new) (and (eq ch ?+) (= new-n line)))
                      ((eq side 'old) (and (eq ch ?-) (= old-n line)))
                      (t              (and (not (memq ch '(?+ ?-)))
                                          (= new-n line))))
                (setq found t)
                (beginning-of-line))
              (unless found
                (cond
                  ((eq ch ?+) (cl-incf new-n))
                  ((eq ch ?-) (cl-incf old-n))
                  (t           (cl-incf old-n) (cl-incf new-n)))
                (forward-line 1)))))))))

;;; Write Operations – thin wrappers for testing

(defun forge-review--do-rest (method resource data &optional success)
  "Perform a REST request.  Thin wrapper to allow stubbing in tests.
METHOD is a string like \"POST\", RESOURCE is a pre-formatted path,
DATA is an alist of request body parameters."
  ;; When called for real (not stubbed), infer the host from the resource.
  ;; Tests stub this function directly, so the body here is rarely executed.
  (ghub-request method resource nil
    :auth 'forge
    :body (json-encode data)
    :headers '(("Content-Type" . "application/json"))
    :callback success))

(defun forge-review--do-mutate (mutation args)
  "Perform a GraphQL mutation.  Thin wrapper to allow stubbing in tests."
  (forge--query nil
    (ghub--prepare-mutation mutation)
    (list (cons 'input args))))

;;; Write Operations – GitHub

(defun forge--submit-github-review (repo pr event)
  "POST all pending review comments for PR to GitHub as a batch review.
EVENT is a symbol like `comment', `approve', or `request-changes'."
  (let ((comments (forge--github-pending-review-comments pr))
        (data     (list (cons 'event (upcase (symbol-name event)))
                        (cons 'body  ""))))
    (when comments
      (push (cons 'comments comments) data))
    (forge-review--do-rest
     "POST"
     (forge--format-resource pr "/repos/:owner/:repo/pulls/:number/reviews")
     data)
    (forge--github-flush-pending-review-comments pr)))

(defun forge--github-post-reply (repo pr opener text)
  "POST a reply to OPENER's thread on GitHub."
  (forge-review--do-rest
   "POST"
   (forge--format-resource pr "/repos/:owner/:repo/pulls/:number/comments")
   (list (cons 'body          text)
         (cons 'in_reply_to_id (oref opener database-id)))))

(defun forge--github-resolve-thread (repo pr opener)
  "Resolve the GitHub review thread identified by OPENER's discussion-id."
  (forge-review--do-mutate
   'resolveReviewThread
   (list (cons 'threadId (oref opener discussion-id)))))

(defun forge--github-unresolve-thread (repo pr opener)
  "Unresolve the GitHub review thread identified by OPENER's discussion-id."
  (forge-review--do-mutate
   'unresolveReviewThread
   (list (cons 'threadId (oref opener discussion-id)))))

;;; Write Operations – GitLab

(defun forge--submit-gitlab-review-comment (repo pr)
  "POST each pending review comment for PR to GitLab individually."
  (let* ((pending (seq-filter
                   (lambda (rc) (oref rc pending-p))
                   (oref pr review-comments)))
         (base-sha (oref pr base-sha))
         (start-sha (oref pr base-rev))
         (head-sha (oref pr head-rev)))
    (dolist (rc pending)
      (let* ((pos (list (cons 'base_sha  base-sha)
                        (cons 'start_sha start-sha)
                        (cons 'head_sha  head-sha)
                        (cons 'position_type "text")
                        (cons 'new_path  (oref rc new-path))
                        (cons 'old_path  (or (oref rc old-path) (oref rc new-path)))
                        (cons 'new_line  (oref rc new-line))
                        (cons 'old_line  (oref rc old-line))))
             (data (list (cons 'body     (oref rc body))
                         (cons 'position pos))))
        (forge-review--do-rest
         "POST"
         (forge--format-resource pr "/projects/:project/merge_requests/:number/discussions")
         data)))))

(defun forge--gitlab-post-reply (repo pr opener text)
  "POST a reply to OPENER's discussion on GitLab."
  (forge-review--do-rest
   "POST"
   (forge--format-resource
    pr
    (format "/projects/:project/merge_requests/:number/discussions/%s/notes"
            (oref opener discussion-id)))
   (list (cons 'body text))))

(defun forge--gitlab-resolve-thread (repo pr opener resolved)
  "PUT resolved=RESOLVED for OPENER's discussion on GitLab."
  (forge-review--do-rest
   "PUT"
   (forge--format-resource
    pr
    (format "/projects/:project/merge_requests/:number/discussions/%s"
            (oref opener discussion-id)))
   (list (cons 'resolved (if resolved t :false)))))

;;; Discard

(defun forge--github-delete-review-comment (repo pr rc)
  "DELETE a submitted review comment RC from GitHub."
  (forge-review--do-rest
   "DELETE"
   (forge--format-resource
    pr
    (format "/repos/:owner/:repo/pulls/comments/%d"
            (oref rc database-id)))
   nil))

(defun forge--gitlab-delete-review-comment (repo pr rc)
  "DELETE a submitted review comment RC from GitLab."
  (forge-review--do-rest
   "DELETE"
   (forge--format-resource
    pr
    (format "/projects/:project/merge_requests/:number/notes/%d"
            (oref rc database-id)))
   nil))

;; TODO: all forge-type dispatch in this file (forge-gitlab-repository--eieio-childp
;; guards) should be converted to cl-defmethod specializing on the repo class,
;; matching the pattern used throughout forge-github.el / forge-gitlab.el.
(defun forge-discard-review-comment (rc)
  "Delete review comment RC from the database and the forge API.
For pending (not-yet-submitted) comments only the local DB row is
removed.  For submitted comments the forge API is called first."
  (unless (oref rc pending-p)
    (when-let* ((pr   (closql-get (forge-db) (oref rc pullreq) 'forge-pullreq))
                (repo (forge-get-repository pr)))
      (if (forge-gitlab-repository--eieio-childp repo)
          (forge--gitlab-delete-review-comment repo pr rc)
        (forge--github-delete-review-comment repo pr rc))))
  (closql-delete rc))

;;; Display – Section class with heading slot

(defclass forge-review-comment-section (magit-section)
  ((heading :initform nil)))

(add-to-list 'magit--section-type-alist
             '(review-comment . forge-review-comment-section))

;;; Display – Topic buffer

(defun forge-insert-review-threads (topic)
  "Insert inline review comment threads for TOPIC into the current buffer."
  (let* ((comments  (oref topic review-comments))
         (openers   (seq-filter (lambda (c) (null (oref c reply-to))) comments))
         (by-file   (seq-group-by (lambda (c)
                                    (or (oref c new-path) (oref c old-path)))
                                  openers))
         (replies-by-disc (make-hash-table :test 'equal)))
    (dolist (c comments)
      (when-let ((disc-id (oref c reply-to)))
        (push c (gethash disc-id replies-by-disc))))
    (magit-insert-section (review-threads)
      (magit-insert-heading "Review threads")
      (if (null openers)
          (insert "  (no review threads)\n")
        (dolist (file-pair (sort by-file (lambda (a b)
                                           (string< (car a) (car b)))))
          (let ((file     (car file-pair))
                (fopeners (cdr file-pair)))
            (magit-insert-section (review-file file)
              (magit-insert-heading file)
              (dolist (opener fopeners)
                (forge--insert-review-thread opener replies-by-disc)))))))))

(defun forge--insert-review-thread (opener replies-by-disc)
  "Insert a single review thread starting with OPENER.
REPLIES-BY-DISC is a hash table mapping discussion-id to reply list."
  (let* ((disc-id  (oref opener discussion-id))
         (resolved (oref opener resolved-p))
         (pending  (oref opener pending-p))
         (heading  (forge--review-comment-heading opener)))
    (magit-insert-section (review-comment opener (or resolved pending))
      (oset magit-insert-section--current heading heading)
      (magit-insert-heading heading)
      (forge--insert-review-comment-body opener)
      (dolist (reply (nreverse (gethash disc-id replies-by-disc)))
        (magit-insert-section (review-reply reply)
          (magit-insert-heading
            (forge--review-comment-heading reply))
          (forge--insert-review-comment-body reply))))))

(defun forge--review-comment-heading (rc)
  "Return a heading string for review comment RC."
  (let* ((author   (or (oref rc author) "(ghost)"))
         (new-line (oref rc new-line))
         (old-line (oref rc old-line))
         (line     (or new-line old-line))
         (side     (if new-line "RIGHT" "LEFT"))
         (created  (or (oref rc created) ""))
         (badges   nil))
    (when (oref rc resolved-p) (push "[resolved]" badges))
    (when (oref rc outdated-p) (push "[outdated]" badges))
    (when (oref rc pending-p)  (push "[pending]"  badges))
    (concat "@" author
            (when line (format " · line %d (%s)" line side))
            (when badges (concat " " (string-join (nreverse badges) " ")))
            (when (not (string-empty-p created))
              (concat " " created)))))

(defun forge--insert-review-comment-body (rc)
  "Insert the body of review comment RC, with diff hunk and reactions."
  (when-let ((hunk (oref rc diff-hunk)))
    (insert (forge--fontify-diff hunk))
    (insert "\n"))
  (let ((body (or (oref rc body) "")))
    (insert (forge--fontify-markdown body))
    (insert "\n"))
  (when-let ((reactions (oref rc reactions)))
    (insert (mapconcat (lambda (pair)
                         (format "%s %d" (car pair) (cdr pair)))
                       reactions "  "))
    (insert "\n"))
  (insert "\n"))

(defun forge--maybe-insert-review-threads ()
  "Insert review threads if the current buffer's topic is a pull-request."
  (when (and forge-buffer-topic
             (forge-pullreq-p forge-buffer-topic))
    (forge-insert-review-threads forge-buffer-topic)))

;;; Display – Diff buffer overlays

(defun forge--place-review-comment-overlay (rc start end)
  "Create and return an overlay at [START END] showing RC's body."
  (let* ((ov       (make-overlay start end))
         (body     (or (oref rc body) ""))
         (author   (or (oref rc author) ""))
         (text     (concat "\n" author ": " body "\n")))
    (overlay-put ov 'after-string text)
    (overlay-put ov 'forge-review-comment t)
    (overlay-put ov 'forge-review-comment-object rc)
    ov))

(defun forge--clear-review-comment-overlays ()
  "Remove all forge review comment overlays from the current buffer."
  (remove-overlays (point-min) (point-max) 'forge-review-comment t))

(defun forge--maybe-insert-review-threads-in-diff ()
  "Insert review comment overlays into the current diff buffer.
Clears any existing overlays first, then places fresh ones."
  (when (derived-mode-p 'magit-diff-mode)
    (when-let* ((pr (forge-current-pullreq))
                (comments (oref pr review-comments)))
      (forge--clear-review-comment-overlays)
      (dolist (rc (seq-filter (lambda (c) (null (oref c reply-to))) comments))
        (let* ((new-path (oref rc new-path))
               (old-path (oref rc old-path))
               (side     (if new-path 'new 'old))
               (line     (or (oref rc new-line) (oref rc old-line))))
          (when line
            (save-excursion
              (condition-case nil
                  (progn
                    (forge--diff-goto-line new-path old-path side line)
                    (let ((pos (point)))
                      (forge--place-review-comment-overlay
                       rc pos (pos-eol))))
                (error nil)))))))))

(add-hook 'magit-refresh-buffer-hook #'forge--maybe-insert-review-threads-in-diff)

;;; Display – Diff hunk fontification

(defun forge--fontify-diff (hunk)
  "Return HUNK string with diff-mode face properties applied."
  (with-temp-buffer
    (insert hunk)
    (diff-mode)
    (font-lock-ensure)
    (buffer-string)))

;;; Navigation

(defun forge-next-review-thread ()
  "Move point to the next review comment overlay."
  (interactive)
  (let* ((pos   (point))
         (found (cl-find-if (lambda (ov)
                              (and (overlay-get ov 'forge-review-comment)
                                   (> (overlay-start ov) pos)))
                            (sort (overlays-in (point) (point-max))
                                  (lambda (a b)
                                    (< (overlay-start a)
                                       (overlay-start b)))))))
    (if found
        (goto-char (overlay-start found))
      (user-error "No more review threads"))))

(defun forge-previous-review-thread ()
  "Move point to the previous review comment overlay."
  (interactive)
  (let* ((pos   (point))
         (found (cl-find-if (lambda (ov)
                              (and (overlay-get ov 'forge-review-comment)
                                   (< (overlay-start ov) pos)))
                            (sort (overlays-in (point-min) (point))
                                  (lambda (a b)
                                    (> (overlay-start a)
                                       (overlay-start b)))))))
    (if found
        (goto-char (overlay-start found))
      (user-error "No previous review threads"))))

;;; Collapse / Expand

(defun forge-collapse-review-thread (ov)
  "Collapse the review thread overlay OV."
  (let ((original (overlay-get ov 'after-string)))
    (overlay-put ov 'forge-thread-original-text original)
    (overlay-put ov 'after-string
                 (concat "\n[...collapsed review thread...]\n"))))

(defun forge-expand-review-thread (ov)
  "Expand the review thread overlay OV."
  (when-let ((original (overlay-get ov 'forge-thread-original-text)))
    (overlay-put ov 'after-string original)
    (overlay-put ov 'forge-thread-original-text nil)))

(defun forge-toggle-review-thread (ov)
  "Toggle collapse/expand of review thread overlay OV."
  (if (overlay-get ov 'forge-thread-original-text)
      (forge-expand-review-thread ov)
    (forge-collapse-review-thread ov)))

;;; Reply context stripping

(defun forge--clear-comment-input (text)
  "Strip HTML comment blocks from TEXT and trim whitespace."
  (let ((result (replace-regexp-in-string
                 "<!--[^>]*-->\\|<!--\\(?:.\\|\n\\)*?-->"
                 ""
                 text)))
    (string-trim result)))

;;; Interactive commands

(defvar-keymap forge-review-comment-section-map
  "<remap> <magit-edit-thing>" #'forge-reply-to-review-comment
  "e"                          #'forge-edit-review-comment
  "r"                          #'forge-resolve-review-thread
  "u"                          #'forge-unresolve-review-thread
  "C-c C-k"                    #'forge-discard-review-comment-at-point
  "C-c C-r"                    #'forge-reply-to-review-comment)

(defun forge--submit-add-review-comment ()
  "Submit a new inline review comment from the current post buffer."
  (let* ((pr      forge--buffer-post-object)
         (body    (forge--clear-comment-input (buffer-string)))
         (result  (with-current-buffer forge--pre-post-buffer
                    (forge--diff-line-number-at-point)))
         (path    (with-current-buffer forge--pre-post-buffer
                    (forge--diff-file-at-point)))
         (rc      (forge-pullreq-review-comment
                   :id           (forge--object-id (oref pr id) (format "pending-%s" (float-time)))
                   :their-id     nil
                   :discussion-id nil
                   :database-id  0
                   :pullreq      (oref pr id)
                   :new-path     (and result (not (eq (car result) 'old)) path)
                   :new-line     (when (and result (eq (car result) 'new)) (cdr result))
                   :old-line     (when (and result (eq (car result) 'old)) (cdr result))
                   :body         body
                   :pending-p    t)))
    (closql-insert (forge-db) rc t)
    (forge-refresh-buffer forge--pre-post-buffer)))

(defun forge--submit-edit-review-comment ()
  "Save edits to the current review comment."
  (let* ((rc   forge--buffer-post-object)
         (body (forge--clear-comment-input (buffer-string))))
    (oset rc body body)
    (forge-refresh-buffer forge--pre-post-buffer)))

(defun forge--submit-review-reply ()
  "Submit a reply to the review comment in the current post buffer."
  (let* ((opener forge--buffer-post-object)
         (pr     (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq))
         (repo   (forge-get-repository pr))
         (body   (forge--clear-comment-input (buffer-string))))
    (if (forge-gitlab-repository--eieio-childp repo)
        (forge--gitlab-post-reply repo pr opener body)
      (forge--github-post-reply repo pr opener body))
    (forge-refresh-buffer forge--pre-post-buffer)))

(defun forge--diff-file-at-point ()
  "Return the file path for the current diff hunk."
  (save-excursion
    (when (re-search-backward "^\\+\\+\\+ b/\\(.*\\)$" nil t)
      (match-string 1))))

(defun forge-add-review-comment ()
  "Add an inline review comment at point in the current diff buffer."
  (interactive)
  (let* ((pr   (forge-current-pullreq t))
         (result (forge--diff-line-number-at-point))
         (line   (if (and (consp result) (consp (car result)))
                     (alist-get 'new result)
                   (cdr result))))
    (forge--setup-post-buffer
      'new-review-comment
      #'forge--submit-add-review-comment
      "review-comment"
      (format "*forge: add review comment at line %s*" (or line "?"))
      `((forge--buffer-post-object ,pr)))))

(defun forge-edit-review-comment ()
  "Edit the review comment at point."
  (interactive)
  (when-let ((rc (magit-section-value-if 'review-comment)))
    (forge--setup-post-buffer
      rc
      #'forge--submit-edit-review-comment
      "review-comment"
      "*forge: edit review comment*")))

(defun forge-discard-review-comment-at-point ()
  "Discard the pending review comment at point."
  (interactive)
  (when-let ((rc (magit-section-value-if 'review-comment)))
    (forge-discard-review-comment rc)
    (forge-refresh-buffer)))

(defun forge-reply-to-review-comment ()
  "Reply to the review comment at point."
  (interactive)
  (when-let ((opener (magit-section-value-if 'review-comment)))
    (let* ((pr (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq)))
      (forge--setup-post-buffer
        opener
        #'forge--submit-review-reply
        "review-reply"
        (format "*forge: reply to review comment by %s*"
                (oref opener author))))))

(defun forge--set-review-thread-resolved (resolved)
  "Resolve or unresolve the review thread at point, per RESOLVED."
  (when-let ((opener (magit-section-value-if 'review-comment)))
    (let* ((pr   (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq))
           (repo (forge-get-repository pr)))
      (if (forge-gitlab-repository--eieio-childp repo)
          (forge--gitlab-resolve-thread repo pr opener resolved)
        (if resolved
            (forge--github-resolve-thread repo pr opener)
          (forge--github-unresolve-thread repo pr opener)))
      (oset opener resolved-p resolved)
      (forge-refresh-buffer))))

(defun forge-resolve-review-thread ()
  "Mark the review thread at point as resolved."
  (interactive)
  (forge--set-review-thread-resolved t))

(defun forge-unresolve-review-thread ()
  "Mark the review thread at point as unresolved."
  (interactive)
  (forge--set-review-thread-resolved nil))

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
    (if (forge-gitlab-repository--eieio-childp repo)
        (forge-review--do-rest
         "POST"
         (forge--format-resource pr "/projects/:project/merge_requests/:number/discussions")
         (list (cons 'body body)
               (cons 'position
                     (list (cons 'base_sha  (oref pr base-sha))
                           (cons 'start_sha (oref pr base-rev))
                           (cons 'head_sha  (oref pr head-rev))
                           (cons 'position_type "text")
                           (cons 'new_path  path)
                           (cons 'old_path  (or path ""))
                           (cons 'new_line  (when (eq side 'new) line))
                           (cons 'old_line  (when (eq side 'old) line))))))
      (forge-review--do-rest
       "POST"
       (forge--format-resource pr "/repos/:owner/:repo/pulls/:number/comments")
       (list (cons 'body   body)
             (cons 'path   path)
             (cons 'line   line)
             (cons 'side   (if (eq side 'old) "LEFT" "RIGHT")))))
    (forge-refresh-buffer forge--pre-post-buffer)))

(defun forge-add-single-review-comment ()
  "Add a single (non-batch) inline comment, posted directly to the API."
  (interactive)
  (let* ((pr     (forge-current-pullreq t))
         (result (forge--diff-line-number-at-point))
         (line   (if (and (consp result) (consp (car result)))
                     (alist-get 'new result)
                   (cdr result))))
    (forge--setup-post-buffer
      'new-single-review-comment
      #'forge--submit-add-single-review-comment
      "review-comment"
      (format "*forge: add immediate comment at line %s*" (or line "?"))
      `((forge--buffer-post-object ,pr)))))

(defun forge-comment-pullreq (pullreq)
  "Submit pending review comments on PULLREQ."
  (interactive (list (forge-current-pullreq t)))
  (let ((repo (forge-get-repository pullreq)))
    (if (forge-gitlab-repository--eieio-childp repo)
        (forge--submit-gitlab-review-comment repo pullreq)
      (forge--submit-github-review repo pullreq 'comment))))

;;; _
;; Local Variables:
;; read-symbol-shorthands: (
;;   ("and$"          . "cond-let--and$")
;;   ("thread$"       . "cond-let--thread$")
;;   ("when$"         . "cond-let--when$")
;;   ("and-let*"      . "cond-let--and-let*")
;;   ("and-let"       . "cond-let--and-let")
;;   ("if-let*"       . "cond-let--if-let*")
;;   ("if-let"        . "cond-let--if-let")
;;   ("when-let*"     . "cond-let--when-let*")
;;   ("when-let"      . "cond-let--when-let")
;;   ("while-let*"    . "cond-let--while-let*")
;;   ("while-let"     . "cond-let--while-let"))
;; End:
(provide 'forge-review)
;;; forge-review.el ends here
