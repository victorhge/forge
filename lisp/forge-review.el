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

;;; Class

(defclass forge-pullreq-review-comment (forge-object)
  ((closql-table         :initform 'pullreq-review-comment)
   (closql-primary-key   :initform 'id)
   (closql-order-by      :initform [(asc created)])
   (closql-foreign-key   :initform 'pullreq)
   (closql-class-prefix  :initform "forge-pullreq-review-")
   (id            :initarg :id)
   (their-id      :initarg :their-id)
   (discussion-id :initarg :discussion-id)
   (number        :initarg :number)
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

;;; Query

(cl-defmethod forge-get-parent ((rc forge-pullreq-review-comment))
  (closql-get (forge-db) (oref rc pullreq) 'forge-pullreq))

(cl-defmethod forge-get-repository ((rc forge-pullreq-review-comment))
  (forge-get-repository (forge-get-parent rc)))

(cl-defmethod forge--format ((rc forge-pullreq-review-comment) slot &optional spec)
  (forge--format (forge-get-parent rc) slot spec))

;;; Fetch / Mapping – generics (methods live in forge-github.el / forge-gitlab.el)

(cl-defgeneric forge--update-pullreq-review-comments (repo pr threads)
  "Map API THREADS (review threads or discussions) into DB rows for PR.")


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
                      ((eq side 'new) (and (not (eq ch ?-)) (= new-n line)))
                      ((eq side 'old) (and (not (eq ch ?+)) (= old-n line)))
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

;;; Write Operations – generics (methods live in forge-github.el / forge-gitlab.el)

(cl-defgeneric forge--review-submit (repo pr)
  "Submit pending review comments on PR to the forge as a COMMENT review.")

(cl-defgeneric forge--review-post-reply (repo pr opener text)
  "Post TEXT as a reply to the thread whose opener is OPENER.")

(cl-defgeneric forge--review-set-thread-resolved (repo pr opener resolved)
  "Resolve (RESOLVED t) or unresolve (RESOLVED nil) the thread at OPENER.")

(cl-defgeneric forge--review-delete-comment (repo pr rc)
  "Delete review comment RC from the forge.")

(cl-defgeneric forge--review-post-comment (repo pr body path side line)
  "Post BODY as a single immediate inline comment at PATH SIDE LINE.")

;;; Discard

(defun forge-discard-review-comment (rc)
  "Delete review comment RC from the database and the forge API.
For pending (not-yet-submitted) comments only the local DB row is
removed.  For submitted comments the forge API is called first."
  (unless (oref rc pending-p)
    (when-let* ((pr   (closql-get (forge-db) (oref rc pullreq) 'forge-pullreq))
                (repo (forge-get-repository pr)))
      (forge--review-delete-comment repo pr rc)))
  (closql-delete rc)
  (forge-refresh-buffer))

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
    (when-let* ((pr (forge-current-pullreq)))
      (forge--clear-review-comment-overlays)
      (dolist (rc (seq-filter (lambda (c) (null (oref c reply-to)))
                              (oref pr review-comments)))
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

(defun forge-review--stage-comment (_repo _post)
  "Stage a new pending inline review comment from the current post buffer."
  (let* ((pr      forge--buffer-post-object)
         (body    (forge--clear-comment-input (buffer-string)))
         (result  (with-current-buffer forge--pre-post-buffer
                    (forge--diff-line-number-at-point)))
         (path    (with-current-buffer forge--pre-post-buffer
                    (forge--diff-file-at-point)))
         ;; result shape: (new . N) | (old . N) | ((old . N) (new . N))
         (context-p (and result (consp (car result))))
         (rc      (forge-pullreq-review-comment
                   :id           (forge--object-id (oref pr id) (format "pending-%s" (float-time)))
                   :their-id     nil
                   :discussion-id nil
                   :number       0
                   :pullreq      (oref pr id)
                   :new-path     (and result (not (eq (car result) 'old)) path)
                   :old-path     (and result (eq (car result) 'old) path)
                   :new-line     (cond (context-p (alist-get 'new result))
                                       ((eq (car result) 'new) (cdr result)))
                   :old-line     (cond (context-p (alist-get 'old result))
                                       ((eq (car result) 'old) (cdr result)))
                   :body         body
                   :pending-p    t)))
    (closql-insert (forge-db) rc t)
    (forge-refresh-buffer forge--pre-post-buffer)))

(defun forge-review--save-comment-edit (_repo _post)
  "Save edits to the current review comment."
  (let* ((rc   forge--buffer-post-object)
         (body (forge--clear-comment-input (buffer-string))))
    (oset rc body body)
    (forge-refresh-buffer forge--pre-post-buffer)))

(cl-defgeneric forge--submit-add-review-reply (repo opener)
  "Submit a reply to the review comment OPENER in the current post buffer.
REPO is the `forge-repository' the pull request belongs to.")

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
      #'forge-review--stage-comment
      "review-comment"
      (format "*forge: add review comment at line %s*" (or line "?"))
      `((forge--buffer-post-object ,pr)))))

(defun forge-edit-review-comment ()
  "Edit the review comment at point."
  (interactive)
  (when-let ((rc (magit-section-value-if 'review-comment)))
    (forge--setup-post-buffer
      rc
      #'forge-review--save-comment-edit
      "review-comment"
      "*forge: edit review comment*")))

(defun forge-discard-review-comment-at-point ()
  "Discard the pending review comment at point."
  (interactive)
  (when-let ((rc (magit-section-value-if 'review-comment)))
    (forge-discard-review-comment rc)))

(defun forge-reply-to-review-comment ()
  "Reply to the review comment at point."
  (interactive)
  (when-let ((opener (magit-section-value-if 'review-comment)))
    (let* ((pr (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq)))
      (forge--setup-post-buffer
        opener
        #'forge--submit-add-review-reply
        "review-reply"
        (format "*forge: reply to review comment by %s*"
                (oref opener author))))))

(defun forge--set-review-thread-resolved (resolved)
  "Resolve or unresolve the review thread at point, per RESOLVED."
  (when-let ((opener (magit-section-value-if 'review-comment)))
    (let* ((pr   (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq))
           (repo (forge-get-repository pr)))
      (forge--review-set-thread-resolved repo pr opener resolved)
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

(cl-defgeneric forge--submit-add-single-review-comment (repo post)
  "Post a single immediate inline comment from the current post buffer.
REPO is the `forge-repository'; POST is the `forge-pullreq'.")

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

(defun forge-submit-pending-review (pullreq)
  "Submit pending review comments on PULLREQ."
  (interactive (list (forge-current-pullreq t)))
  (forge--review-submit (forge-get-repository pullreq) pullreq))

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
