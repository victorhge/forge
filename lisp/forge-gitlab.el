;;; forge-gitlab.el --- Gitlab support  -*- lexical-binding:t -*-

;; Copyright (C) 2018-2026 Jonas Bernoulli

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

(require 'forge-client)
(require 'forge-issue)
(require 'forge-pullreq)


;;; Class

(defclass forge-gitlab-repository (forge-repository)
  ((issues-url-format         :initform "https://%h/%o/%n/issues")
   (issue-url-format          :initform "https://%h/%o/%n/issues/%i")
   (issue-post-url-format     :initform "https://%h/%o/%n/issues/%i#note_%I")
   (pullreqs-url-format       :initform "https://%h/%o/%n/merge_requests")
   (pullreq-url-format        :initform "https://%h/%o/%n/merge_requests/%i")
   (pullreq-post-url-format   :initform "https://%h/%o/%n/merge_requests/%i#note_%I")
   (commit-url-format         :initform "https://%h/%o/%n/commit/%r")
   (branch-url-format         :initform "https://%h/%o/%n/commits/%r")
   (remote-url-format         :initform "https://%h/%o/%n")
   (blob-url-format           :initform "https://%h/%o/%n/-/blob/%r/%f")
   (create-issue-url-format   :initform "https://%h/%o/%n/issues/new")
   (create-pullreq-url-format :initform "https://%h/%o/%n/merge_requests/new")
   (pullreq-refspec :initform "+refs/merge-requests/*/head:refs/pullreqs/*")))

;;; Pull
;;;; Repository

(cl-defmethod forge--pull ((repo forge-gitlab-repository)
                           &optional callback since)
  (cl-assert (not (and since (forge-get-repository repo nil :tracked?))))
  (setq forge--mode-line-buffer (current-buffer))
  (forge--msg repo t nil "Pulling REPO")
  (let ((buffer (current-buffer))
        (value nil)
        (step nil)
        (skip (cond ((oref repo selective-p)
                     '(assignees forks labels issues pullreqs))
                    ((magit-get-boolean "forge.omitExpensive")
                     '(assignees forks labels)))))
    (named-let step (data)
      (cond ((not value)
             (when data
               (setq value data)
               (let-alist value
                 (unless .issues_enabled         (cl-pushnew 'issues   skip))
                 (unless .merge_requests_enabled (cl-pushnew 'pullreqs skip)))))
            ((push (cons step data) value)))
      (cl-flet ((fetchp (sym)
                  (unless (or (memq sym skip)
                              (assq sym value))
                    (setq step sym)
                    t)))
        (cond ((not value)         (forge--fetch-repository repo #'step))
              ((fetchp 'assignees) (forge--fetch-assignees  repo #'step))
              ((fetchp 'forks)     (forge--fetch-forks      repo #'step))
              ((fetchp 'labels)    (forge--fetch-labels     repo #'step))
              ((fetchp 'issues)    (forge--fetch-issues     repo #'step since))
              ((fetchp 'pullreqs)  (forge--fetch-pullreqs   repo #'step since))
              (t
               (forge--msg repo t t   "Pulling REPO")
               (forge--msg repo t nil "Storing REPO")
               (let-alist value
                 (closql-with-transaction (forge-db)
                   (forge--update-repository repo value)
                   (forge--update-assignees  repo .assignees)
                   (forge--update-labels     repo .labels)
                   (forge--update-issues     repo .issues)
                   (forge--update-pullreqs   repo .pullreqs)
                   (oset repo condition :tracked)))
               (forge--msg repo t t "Storing REPO")
               (cond ((oref repo selective-p))
                     (callback (funcall callback))
                     ((forge--maybe-git-fetch repo buffer)))))))))

(cl-defmethod forge--fetch-repository ((repo forge-gitlab-repository) callback)
  (forge--glab-get repo "/projects/:project" nil
    :callback callback))

(cl-defmethod forge--update-repository ((repo forge-gitlab-repository) data)
  (let-alist data
    (oset repo created        .created_at)
    (oset repo updated        .last_activity_at)
    (oset repo pushed         nil)
    (oset repo parent         .forked_from_project.path_with_namespace)
    (oset repo description    .description)
    (oset repo homepage       nil)
    (oset repo default-branch .default_branch)
    (oset repo archived-p     .archived)
    (oset repo fork-p         (and .forked_from_project.path_with_namespace t))
    (oset repo locked-p       nil)
    (oset repo mirror-p       .mirror)
    (oset repo private-p      (equal .visibility "private"))
    (oset repo issues-p       .issues_enabled)
    (oset repo wiki-p         .wiki_enabled)
    (oset repo stars          .star_count)
    (oset repo watchers       .star_count)))

;;;; Topics

(cl-defmethod forge--pull-topic ((repo forge-gitlab-repository) _topic
                                 &key callback _errorback)
  (forge--pull repo callback)) ; TODO Pull only the one topic.

;;;; Issues

(cl-defmethod forge--fetch-issues ((repo forge-gitlab-repository) callback since)
  (letrec
      (( cb (let (val cur cnt pos)
              (lambda (&optional v)
                (cond
                  ((and (not pos) v)
                   (setq val v)
                   (setq cur v)
                   (setq pos 1)
                   (setq cnt (length val))
                   (forge--msg nil nil nil "Pulling issue %s/%s" pos cnt)
                   (forge--fetch-issue-posts repo cur cb))
                  ((setq cur (cdr cur))
                   (incf pos)
                   (forge--msg nil nil nil "Pulling issue %s/%s" pos cnt)
                   (forge--fetch-issue-posts repo cur cb))
                  (t
                   (forge--msg repo t t "Pulling REPO issues")
                   (funcall callback val)))))))
    (forge--msg repo t nil "Pulling REPO issues")
    (forge--glab-get repo "/projects/:project/issues"
      `((per_page . 100)
        (order_by . "updated_at")
        ,@(and$ (or since (oref repo issues-until))
                `((updated_after . ,$))))
      :unpaginate t
      :callback cb)))

(cl-defmethod forge--fetch-issue-posts ((repo forge-gitlab-repository) cur cb)
  (forge--glab-get repo
    (let-alist (car cur)
      (format "/projects/%s/issues/%s/notes" .project_id .iid))
    '((per_page . 100))
    :unpaginate t
    :callback (lambda (value)
                (setf (alist-get 'notes (car cur)) value)
                (funcall cb))))

(cl-defmethod forge--update-issues ((repo forge-gitlab-repository) data)
  (dolist (v data)
    (forge--update-issue repo v)))

(cl-defmethod forge--update-issue ((repo forge-gitlab-repository) data)
  (closql-with-transaction (forge-db)
    (let-alist data
      (let* ((issue-id (forge--object-id 'forge-issue repo .iid))
             (issue
              (forge-issue
               :id           issue-id
               :their-id     .iid
               :number       .iid
               :slug         (format "#%s" .iid)
               :repository   (oref repo id)
               ;; Gitlab doesn't make a distinction between completed
               ;; and unplanned issues.  Treat them all as completed.
               :state        (pcase-exhaustive .state
                               ("closed" 'completed)
                               ("opened" 'open))
               :author       .author.username
               :title        .title
               :created      .created_at
               :updated      .updated_at
               ;; `.closed_at' may be nil even though the issues is
               ;; closed.  In such cases use 1, so that this slot
               ;; at least can serve as a boolean.
               :closed       (or .closed_at (and (equal .state "closed") 1))
               :locked-p     .discussion_locked
               :milestone    .milestone.iid
               :body         (forge--sanitize-string .description))))
        (closql-insert (forge-db) issue t)
        (unless (magit-get-boolean "forge.omitExpensive")
          (forge--set-connections repo issue 'assignees .assignees)
          (forge--set-connections repo issue 'labels .labels))
        (dolist (c .notes)
          (let-alist c
            (let ((post
                   (forge-issue-post
                    :id      (forge--object-id issue-id .id)
                    :issue   issue-id
                    :number  .id
                    :author  .author.username
                    :created .created_at
                    :updated .updated_at
                    :body    (forge--sanitize-string .body))))
              (closql-insert (forge-db) post t))))
        (let ((until (oref repo issues-until)))
          (when (or (not until) (string> .updated_at until))
            (oset repo issues-until .updated_at)))
        issue))))

;;;; Pullreqs

(cl-defmethod forge--fetch-pullreqs ((repo forge-gitlab-repository) callback since)
  (letrec
      (( cb (let (val cur cnt pos)
              (lambda (&optional v)
                (cond
                  ((and (not pos) v)
                   (setq val v)
                   (setq cur v)
                   (setq pos 1)
                   (setq cnt (length val))
                   (forge--msg nil nil nil "Pulling pullreq %s/%s" pos cnt)
                   (forge--fetch-pullreq-posts repo cur cb))
                  ((not pos)
                   (forge--msg repo t t "Pulling REPO pullreqs")
                   (funcall callback val))
                  ((not (assq 'source_project (car cur)))
                   (forge--fetch-pullreq-source-repo repo cur cb))
                  ((not (assq 'target_project (car cur)))
                   (forge--fetch-pullreq-target-repo repo cur cb))
                  ((not (assq 'discussions (car cur)))
                   (forge--fetch-pullreq-discussions repo cur cb))
                  ((setq cur (cdr cur))
                   (incf pos)
                   (forge--msg nil nil nil "Pulling pullreq %s/%s" pos cnt)
                   (forge--fetch-pullreq-posts repo cur cb))
                  (t
                   (forge--msg repo t t "Pulling REPO pullreqs")
                   (funcall callback val)))))))
    (forge--msg repo t nil "Pulling REPO pullreqs")
    (forge--glab-get repo "/projects/:project/merge_requests"
      `((per_page . 100)
        (order_by . "updated_at")
        ,@(and$ (or since (oref repo pullreqs-until))
                `((updated_after . ,$))))
      :unpaginate t
      :callback cb)))

(cl-defmethod forge--fetch-pullreq-posts
  ((repo forge-gitlab-repository) cur cb)
  (forge--glab-get repo
    (let-alist (car cur)
      (format "/projects/%s/merge_requests/%s/notes" .target_project_id .iid))
    '((per_page . 100))
    :unpaginate t
    :callback (lambda (value)
                (setf (alist-get 'notes (car cur)) value)
                (funcall cb))))

(cl-defmethod forge--fetch-pullreq-source-repo
  ((repo forge-gitlab-repository) cur cb)
  ;; If the fork no longer exists, then `.source_project_id' is nil.
  ;; This will lead to difficulties later on but there is nothing we
  ;; can do about it.
  (let-alist (car cur)
    (if .source_project_id
        (forge--glab-get repo (format "/projects/%s" .source_project_id) nil
          :errorback (lambda (_err _headers _status _req)
                       (setf (alist-get 'source_project (car cur)) nil)
                       (funcall cb))
          :callback (lambda (value)
                      (setf (alist-get 'source_project (car cur)) value)
                      (funcall cb)))
      (setf (alist-get 'source_project (car cur)) nil)
      (funcall cb))))

(cl-defmethod forge--fetch-pullreq-target-repo
  ((repo forge-gitlab-repository) cur cb)
  (let-alist (car cur)
    (forge--glab-get repo (format "/projects/%s" .target_project_id) nil
      :errorback (lambda (_err _headers _status _req)
                   (setf (alist-get 'target_project (car cur)) nil)
                   (funcall cb))
      :callback (lambda (value)
                  (setf (alist-get 'target_project (car cur)) value)
                  (funcall cb)))))

(cl-defmethod forge--fetch-pullreq-discussions
  ((repo forge-gitlab-repository) cur cb)
  (forge--glab-get repo
    (let-alist (car cur)
      (format "/projects/%s/merge_requests/%s/discussions" .target_project_id .iid))
    '((per_page . 100))
    :unpaginate t
    :callback (lambda (value)
                (setf (alist-get 'discussions (car cur)) value)
                (funcall cb))))

(cl-defmethod forge--update-pullreqs ((repo forge-gitlab-repository) data)
  (dolist (v data)
    (forge--update-pullreq repo v)))

(cl-defmethod forge--update-pullreq ((repo forge-gitlab-repository) data)
  (closql-with-transaction (forge-db)
    (let-alist data
      (let* ((pullreq-id (forge--object-id 'forge-pullreq repo .iid))
             (pullreq
              (forge-pullreq
               :id           pullreq-id
               :their-id     .iid
               :number       .iid
               :slug         (format "!%s" .iid)
               :repository   (oref repo id)
               :state        (pcase-exhaustive .state
                               ("merged" 'merged)
                               ("closed" 'rejected)
                               ("opened" 'open))
               :author       .author.username
               :title        .title
               :created      .created_at
               :updated      .updated_at
               ;; `.merged_at' and `.closed_at' may both be nil even
               ;; though the pullreq is merged or otherwise closed.
               ;; In such cases use 1, so that these slots at least
               ;; can serve as booleans.
               :closed       (or .closed_at
                                 (and (member .state '("closed" "merged")) 1))
               :merged       (or .merged_at
                                 (and (equal .state "merged") 1))
               :draft-p      .draft
               :locked-p     .discussion_locked
               :editable-p   .allow_maintainer_to_push
               :cross-repo-p (not (equal .source_project_id
                                         .target_project_id))
               :base-ref     .target_branch
               :base-rev     .diff_refs.start_sha
               :base-repo    .target_project.path_with_namespace
               :head-ref     .source_branch
               :head-rev     .diff_refs.head_sha
               :head-user    .source_project.owner.username
               :head-repo    .source_project.path_with_namespace
               :milestone    .milestone.iid
               :base-sha     .diff_refs.base_sha
               :body         (forge--sanitize-string .description))))
        (closql-insert (forge-db) pullreq t)
        (unless (magit-get-boolean "forge.omitExpensive")
          (forge--set-connections repo pullreq 'assignees .assignees)
          (forge--set-connections repo pullreq 'review-requests .reviewers)
          (forge--set-connections repo pullreq 'labels .labels))
        (dolist (c .notes)
          (let-alist c
            (let ((post
                   (forge-pullreq-post
                    :id      (forge--object-id pullreq-id .id)
                    :pullreq pullreq-id
                    :number  .id
                    :author  .author.username
                    :created .created_at
                    :updated .updated_at
                    :body    (forge--sanitize-string .body))))
              (closql-insert (forge-db) post t))))
        (when .discussions
          (let ((inline (seq-filter
                         (lambda (d)
                           (seq-some (lambda (n) (alist-get 'position n))
                                     (alist-get 'notes d)))
                         .discussions)))
            (when inline
              (forge--update-pullreq-review-comments repo pullreq inline))))
        (let ((until (oref repo pullreqs-until)))
          (when (or (not until) (string> .updated_at until))
            (oset repo pullreqs-until .updated_at)))
        pullreq))))

;;;; Other

;; The extend of the documentation for "GET /projects/:id/users" is
;; "Get the users list of a project."  I don't know what that means,
;; but it stands to reason that this must at least overlap with the
;; set of users that can be assigned to topics.

(cl-defmethod forge--fetch-assignees ((repo forge-gitlab-repository) callback)
  (forge--glab-get repo "/projects/:project/users"
    '((per_page . 100))
    :unpaginate t
    :callback callback))

(cl-defmethod forge--update-assignees ((repo forge-gitlab-repository) data)
  (oset repo assignees
        (with-slots (id) repo
          (mapcar (lambda (row)
                    (let-alist row
                      ;; For other forges we don't need to store `id'
                      ;; but here we do because that's what has to be
                      ;; used when assigning issues.
                      (list (forge--object-id id .id)
                            .username
                            .name
                            .id)))
                  data))))

(cl-defmethod forge--fetch-forks ((repo forge-gitlab-repository) callback)
  (forge--glab-get repo "/projects/:project/forks"
    '((per_page . 100)
      (simple . t))
    :unpaginate t
    :callback callback))

(cl-defmethod forge--update-forks ((repo forge-gitlab-repository) data)
  (oset repo forks
        (with-slots (id) repo
          (mapcar (lambda (row)
                    (let-alist row
                      (nconc (forge--repository-ids
                              (eieio-object-class repo)
                              (oref repo githost)
                              .namespace.path
                              .path)
                             (list .namespace.path
                                   .path))))
                  data))))

(cl-defmethod forge--fetch-labels ((repo forge-gitlab-repository) callback)
  (forge--glab-get repo "/projects/:project/labels"
    '((per_page . 100))
    :unpaginate t
    :callback callback))

(cl-defmethod forge--update-labels ((repo forge-gitlab-repository) data)
  (oset repo labels
        (with-slots (id) repo
          (mapcar (lambda (row)
                    (let-alist row
                      ;; We should use the label's `id' instead of its
                      ;; `name' but a topic's `labels' field is a list
                      ;; of names instead of a list of ids or an alist.
                      ;; As a result of this we cannot recognize when
                      ;; a label is renamed and a topic continues to be
                      ;; tagged with the old label name until it itself
                      ;; is modified somehow.  Additionally it leads to
                      ;; name conflicts between group and project
                      ;; labels.  See #160.  Also see the comment in
                      ;; `forge--set-connections'.
                      (list (forge--object-id id .name)
                            .name
                            (downcase .color)
                            .description)))
                  ;; For now simply remove one of the duplicates.
                  (cl-delete-duplicates data
                                        :key (##alist-get 'name %)
                                        :test #'equal)))))

;;;; Notifications

;; The closest to notifications that Gitlab provides are "events" as
;; described at https://docs.gitlab.com/ee/api/events.html.  This
;; allows us to see the last events that took place, but that is not
;; good enough because we are mostly interested in events we haven't
;; looked at yet.  Gitlab doesn't make a distinction between unread
;; and read events, so this is rather useless and we don't use it for
;; the time being.

;;; Mutations

(cl-defmethod forge--submit-create-issue ((_ forge-gitlab-repository) repo)
  (forge--glab-post repo "/projects/:project/issues"
    (pcase-let ((`(,title . ,body) (forge--post-buffer-text)))
      `((title        . ,title)
        (description  . ,body)))
    :callback  (forge--post-submit-callback)
    :errorback (forge--post-submit-errorback)))

(cl-defmethod forge--submit-create-pullreq ((_ forge-gitlab-repository) base-repo)
  (pcase-let* ((`(,title . ,body) (forge--post-buffer-text))
               (`(,_base-remote . ,base-branch)
                (magit-split-branch-name forge--buffer-base-branch))
               (`(,head-remote . ,head-branch)
                (magit-split-branch-name forge--buffer-head-branch))
               (head-repo (forge-get-repository :stub head-remote)))
    (forge--glab-post head-repo "/projects/:project/merge_requests"
      `((title . ,(if forge--buffer-draft-p
                      (concat "Draft: " title)
                    title))
        (description . ,body)
        ;; ,@(and (not (equal head-remote base-remote))
        (target_project_id . ,(oref base-repo forge-id))
        (target_branch . ,base-branch)
        (source_branch . ,head-branch)
        (allow_collaboration . t))
      :callback  (forge--post-submit-callback)
      :errorback (forge--post-submit-errorback))))

(cl-defmethod forge--submit-create-post
  ((_     forge-gitlab-repository)
   (topic forge-topic))
  (forge--glab-post topic
    (if (forge-issue-p topic)
        "/projects/:project/issues/:number/notes"
      "/projects/:project/merge_requests/:number/notes")
    `((body . ,(string-trim (buffer-str))))
    :callback  (forge--post-submit-callback)
    :errorback (forge--post-submit-errorback)))

(cl-defmethod forge--submit-edit-post
  ((_    forge-gitlab-repository)
   (post forge-post))
  (forge--glab-put post
    (cl-etypecase post
      (forge-pullreq      "/projects/:project/merge_requests/:number")
      (forge-issue        "/projects/:project/issues/:number")
      (forge-issue-post   "/projects/:project/issues/:topic/notes/:number")
      (forge-pullreq-post "/projects/:project/merge_requests/:topic/notes/:number"))
    (if (cl-typep post 'forge-topic)
        (pcase-let ((`(,title . ,body) (forge--post-buffer-text)))
          `((title . ,title)
            ;; Keep Gitlab from claiming that the user changed
            ;; the description when that isn't true.  The same
            ;; isn't necessary for the title; for that, Gitlab
            ;; performs the necessary check itself.
            ,@(and (not (equal body (oref post body)))
                   `((description . ,body)))))
      `((body . ,(string-trim (buffer-str)))))
    :callback  (forge--post-submit-callback)
    :errorback (forge--post-submit-errorback)))

(cl-defmethod forge--set-topic-field
  ((_repo forge-gitlab-repository)
   (topic forge-topic)
   field value)
  (forge--glab-put topic
    (cl-typecase topic
      (forge-pullreq "/projects/:project/merge_requests/:number")
      (forge-issue   "/projects/:project/issues/:number"))
    `((,field . ,(if (and value (listp value)) (vconcat value) value)))
    :callback (forge--set-field-callback topic)))

(cl-defmethod forge--set-topic-title
  ((repo  forge-gitlab-repository)
   (topic forge-topic)
   title)
  (forge--set-topic-field repo topic 'title title))

(cl-defmethod forge--set-topic-state
  ((repo  forge-gitlab-repository)
   (topic forge-topic)
   state)
  (forge--set-topic-field repo topic 'state_event
                          (pcase-exhaustive state
                            ;; Merging isn't done through here.
                            ('completed "close")
                            ('unplanned "close")
                            ('rejected  "close")
                            ('open      "reopen"))))

(cl-defmethod forge--set-topic-draft
  ((repo  forge-gitlab-repository)
   (topic forge-topic)
   value)
  (forge--mutate-field topic mergeRequestSetDraft
    ((projectPath (oref repo slug))
     (iid (number-to-string (oref topic number)))
     (draft value))))

(cl-defmethod forge--set-topic-labels
  ((repo  forge-gitlab-repository)
   (topic forge-topic)
   labels)
  (forge--set-topic-field repo topic 'labels
                          (string-join labels ",")))

(cl-defmethod forge--set-topic-assignees
  ((repo  forge-gitlab-repository)
   (topic forge-topic)
   assignees)
  (let ((users (mapcar #'cdr (oref repo assignees))))
    (cl-typecase topic
      (forge-pullreq ; Can only be assigned to a single user.
       (forge--set-topic-field repo topic 'assignee_id
                               (or (caddr (assoc (car assignees) users))
                                   0)))
      (forge-issue
       (forge--set-topic-field repo topic 'assignee_ids
                               (or (mapcar (##caddr (assoc % users)) assignees)
                                   0))))))

(cl-defmethod forge--set-topic-review-requests
  ((repo  forge-gitlab-repository)
   (topic forge-pullreq)
   reviewers)
  (let ((users (mapcar #'cdr (oref repo assignees))))
    (forge--set-topic-field repo topic 'reviewer_ids
                            (or (mapcar (##caddr (assoc % users)) reviewers)
                                0))))

(cl-defmethod forge--delete-comment
  ((_    forge-gitlab-repository)
   (post forge-post))
  (forge--glab-delete post
    (cl-etypecase post
      (forge-pullreq-post
       "/projects/:project/merge_requests/:topic/notes/:number")
      (forge-issue-post
       "/projects/:project/issues/:topic/notes/:number")))
  (closql-delete post)
  (forge-refresh-buffer))

(cl-defmethod forge--topic-template-files ((repo forge-gitlab-repository)
                                           (_ (subclass forge-issue)))
  (forge--topic-template-files-1 repo "md" ".gitlab/issue_templates"))

(cl-defmethod forge--topic-template-files ((repo forge-gitlab-repository)
                                           (_ (subclass forge-pullreq)))
  (forge--topic-template-files-1 repo "md" ".gitlab/merge_request_templates"))

(cl-defmethod forge--fork-repository ((repo forge-gitlab-repository) fork _all)
  (with-slots (name apihost) repo
    (forge--glab-post repo "/projects/:project/fork"
      (and (not (equal fork (ghub--username repo)))
           `((namespace . ,fork)))
      :noerror t)
    (ghub-wait (format "/projects/%s%%2F%s" (string-replace "/" "%2F" fork) name)
               nil :auth 'forge :host apihost :forge 'gitlab)))

(cl-defmethod forge--merge-pullreq
  ((_repo forge-gitlab-repository)
   (topic forge-topic)
   hash method)
  (forge--glab-put topic
    "/projects/:project/merge_requests/:number/merge"
    `((squash . ,(eq method 'squash))
      ,@(and hash `((sha . ,hash))))))

;;; Wrappers

(cl-defun forge--glab-get (obj resource
                               &optional params
                               &key query payload headers
                               silent unpaginate noerror reader
                               host callback errorback)
  (declare (indent defun))
  (ghub-request "GET" (if obj (forge--format-resource obj resource) resource)
    params
    :forge 'gitlab
    :host (or host (oref (forge-get-repository obj) apihost))
    :auth 'forge
    :query query :payload payload :headers headers
    :silent silent :unpaginate unpaginate
    :noerror noerror :reader reader
    :callback callback
    :errorback (or errorback (and callback t))))

(cl-defun forge--glab-put (obj resource
                               &optional params
                               &key query payload headers
                               silent unpaginate noerror reader
                               host callback errorback)
  (declare (indent defun))
  (ghub-request "PUT" (if obj (forge--format-resource obj resource) resource)
    params
    :forge 'gitlab
    :host (or host (oref (forge-get-repository obj) apihost))
    :auth 'forge
    :query query :payload payload :headers headers
    :silent silent :unpaginate unpaginate
    :noerror noerror :reader reader
    :callback callback
    :errorback (or errorback (and callback t))))

(cl-defun forge--glab-post (obj resource
                                &optional params
                                &key query payload headers
                                silent unpaginate noerror reader
                                host callback errorback)
  (declare (indent defun))
  (ghub-request "POST" (forge--format-resource obj resource)
    params
    :forge 'gitlab
    :host (or host (oref (forge-get-repository obj) apihost))
    :auth 'forge
    :query query :payload payload :headers headers
    :silent silent :unpaginate unpaginate
    :noerror noerror :reader reader
    :callback callback
    :errorback (or errorback (and callback t))))

(cl-defun forge--glab-delete (obj resource
                                  &optional params
                                  &key query payload headers
                                  silent unpaginate noerror reader
                                  host callback errorback)
  (declare (indent defun))
  (ghub-request "DELETE" (forge--format-resource obj resource)
    params
    :forge 'gitlab
    :host (or host (oref (forge-get-repository obj) apihost))
    :auth 'forge
    :query query :payload payload :headers headers
    :silent silent :unpaginate unpaginate
    :noerror noerror :reader reader
    :callback callback
    :errorback (or errorback (and callback t))))

;;; Review – fetch / mapping

(cl-defmethod forge--update-pullreq-review-comments
  ((_repo forge-gitlab-repository) pr threads)
  "Map GitLab discussion THREADS into DB rows for PR."
  (closql-with-transaction (forge-db)
    (let ((pr-id (oref pr id)))
      (dolist (discussion threads)
        (let* ((disc-id  (alist-get 'id discussion))
               (resolved (eq t (alist-get 'resolved discussion)))
               (notes    (alist-get 'notes discussion))
               (first    t))
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
                (setq first nil)))))))))

;;; Review – write operations

(cl-defmethod forge--review-submit ((_repo forge-gitlab-repository) pr)
  "POST each pending review comment for PR to GitLab individually."
  (let* ((pending   (seq-filter (lambda (rc) (oref rc pending-p))
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
                                               (cons 'old_line (oref rc old-line)))))))))))

(cl-defmethod forge--review-post-reply ((_repo forge-gitlab-repository) pr opener text)
  "POST a reply to OPENER's discussion on GitLab."
  (forge--rest pr "POST"
    (format "/projects/:project/merge_requests/:number/discussions/%s/notes"
            (oref opener discussion-id))
    (list (cons 'body text))))

(cl-defmethod forge--review-set-thread-resolved
  ((_repo forge-gitlab-repository) pr opener resolved)
  "PUT resolved=RESOLVED for OPENER's discussion on GitLab."
  (forge--rest pr "PUT"
    (format "/projects/:project/merge_requests/:number/discussions/%s"
            (oref opener discussion-id))
    (list (cons 'resolved (if resolved t :false)))))

(cl-defmethod forge--review-delete-comment ((_repo forge-gitlab-repository) pr rc)
  "DELETE a submitted review comment RC from GitLab."
  (forge--rest pr "DELETE"
    (format "/projects/:project/merge_requests/:number/notes/%d" (oref rc database-id))
    nil))

(cl-defmethod forge--review-post-comment ((_repo forge-gitlab-repository) pr body path side line)
  "POST a single immediate inline comment at PATH SIDE LINE on GitLab."
  (forge--rest pr "POST"
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
                                      (and (eq side 'old) (cons 'old_line line))))))))

(cl-defmethod forge--submit-review-reply
  ((repo forge-gitlab-repository) (opener forge-pullreq-review-comment))
  "Submit a reply to review comment OPENER on GitLab."
  (let* ((pr   (closql-get (forge-db) (oref opener pullreq) 'forge-pullreq))
         (body (forge--clear-comment-input (buffer-string))))
    (forge--review-post-reply repo pr opener body)
    (forge-refresh-buffer forge--pre-post-buffer)))

(cl-defmethod forge--submit-add-single-review-comment
  ((repo forge-gitlab-repository) (pr forge-pullreq))
  (let* ((body   (forge--clear-comment-input (buffer-string)))
         (result (with-current-buffer forge--pre-post-buffer
                   (forge--diff-line-number-at-point)))
         (side   (if (and (consp result) (eq (car result) 'old)) 'old 'new))
         (line   (if (and (consp result) (consp (car result)))
                     (alist-get 'new result)
                   (cdr result)))
         (path   (with-current-buffer forge--pre-post-buffer
                   (forge--diff-file-at-point))))
    (forge--review-post-comment repo pr body path side line)
    (forge-refresh-buffer forge--pre-post-buffer)))

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
;;   ("while-let"     . "cond-let--while-let")
;;   ("buffer-string" . "buffer-string")
;;   ("buffer-str"    . "forge--buffer-substring-no-properties"))
;; End:
(provide 'forge-gitlab)
;;; forge-gitlab.el ends here
