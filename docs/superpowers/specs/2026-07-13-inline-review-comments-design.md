# Inline PR/MR Review Comments for Forge — Design Spec

**Date:** 2026-07-13  
**Last updated:** 2026-07-14 (implementation complete — see §12)  
**Scope:** GitHub and GitLab (both supported from the start)  
**Reference packages:** `code-review`, `pr-review`

---

## 1. Context

Forge supports approving and requesting changes on pull/merge requests but has no inline diff comment support. The `reviews` slot on `forge-pullreq` is an untyped stub. This feature adds the full round-trip for both GitHub and GitLab: fetch existing review threads, display them in the PR topic buffer, create new inline comments from the Magit diff buffer, reply to existing threads, submit with a verdict, and resolve/unresolve threads.

---

## 2. Data Model

### `forge-pullreq-review-comment`

One new EIEIO class following the `forge-revnote` pattern — flat, no parent review wrapper. One DB table.

The position model uses `new-path`/`old-path` + `new-line`/`old-line` which covers both forges:
- GitHub: `path` → `new-path`; `diffSide=RIGHT` → `new-line`, `diffSide=LEFT` → `old-line`
- GitLab: explicit `new_path`, `old_path`, `new_line`, `old_line` from `/discussions`

| Slot | Type | Notes |
|------|------|-------|
| `id` | string | `forge--object-id` |
| `their-id` | string | Comment node ID (GitHub) / comment iid (GitLab) |
| `discussion-id` | string | Thread node ID for GitHub resolve mutation; discussion ID for GitLab reply + resolve |
| `database-id` | integer\|nil | GitHub: integer `databaseId` for REST `in_reply_to` |
| `pullreq` | string | FK → `pullreq.id` |
| `new-path` | string | File path in new tree (always set) |
| `old-path` | string\|nil | File path in old tree; nil when same as `new-path` |
| `new-line` | integer\|nil | Line in new file; nil for pure deletions |
| `old-line` | integer\|nil | Line in old file; nil for pure additions |
| `diff-hunk` | string\|nil | Raw diff context snippet |
| `outdated-p` | boolean | Thread is outdated |
| `resolved-p` | boolean | Thread has been resolved |
| `reply-to` | string\|nil | `discussion-id` of thread opener; nil for openers |
| `review-state` | symbol\|nil | `approved`\|`changes-requested`\|`commented` |
| `author` | string | Login |
| `body` | string | Comment text |
| `created` | string | ISO timestamp |
| `updated` | string | ISO timestamp |
| `reactions` | alist | e.g. `((thumbs-up . 3))` — display only |
| `pending-p` | boolean | `t` for locally staged, not-yet-submitted |

`forge-pullreq` slot: `(reviews)` → `(review-comments :closql-class forge-pullreq-review-comment)`

`forge-pullreq` gains a new `base-sha` slot (GitLab merge base SHA, from `diff_refs.base_sha`).

### DB schema migration: version 16

- `CREATE TABLE pullreq-review-comment [...]`
- `ALTER TABLE pullreq ADD COLUMN review-comments DEFAULT eieio-unbound`
- `ALTER TABLE pullreq ADD COLUMN base-sha DEFAULT nil`
- Old `reviews` column left in place (SQLite additive-only migrations)

---

## 3. Fetch & API

### GitHub — GraphQL

Add inside `pullRequests` in `forge--github-repository-query`:

```elisp
(  reviewThreads [(:edges t)]
   id isResolved isOutdated path diffSide line startDiffSide startLine
   (  comments [(:edges t)]
      id databaseId (author login) body createdAt updatedAt diffHunk
      (reactionGroups content (reactors totalCount))
      (pullRequestReview state)))
```

Slot mapping:
- Thread `id` → `discussion-id`; `isResolved` → `resolved-p`; `isOutdated` → `outdated-p`
- `path` → `new-path`; `diffSide=RIGHT,line` → `new-line`; `diffSide=LEFT,line` → `old-line`
- Comment `id` → `their-id`; `databaseId` → `database-id`
- First comment per thread: `reply-to nil`; subsequent: `reply-to` = thread `id`

New `forge--update-pullreq-review-comments` called from `forge--update-pullreq` after `forge--set-connections`.

Also extend single-topic refetch in `forge--pull-topic`.

### GitLab — REST

Switch MR note fetch from `/notes` to `/discussions`:
```
GET /projects/:id/merge_requests/:iid/discussions
```

Each discussion: `id` → `discussion-id`; `notes[0]` is opener; subsequent notes are replies.
Note `position`: `new_path`→`new-path`, `old_path`→`old-path`, `new_line`→`new-line`, `old_line`→`old-line`.
Store `diff_refs.base_sha` from MR data → `forge-pullreq.base-sha`.

### Write operations

| Operation | GitHub | GitLab |
|-----------|--------|--------|
| Submit batch review | `POST /repos/:o/:r/pulls/:n/reviews` (`event` + `comments[]`) | Per-comment `POST /projects/:id/merge_requests/:iid/discussions` + separate approve call |
| Single immediate | `POST /repos/:o/:r/pulls/:n/comments` | `POST /projects/:id/merge_requests/:iid/discussions` (no position = regular note) |
| Reply | `POST /repos/:o/:r/pulls/:n/comments` with `in_reply_to` = `database-id` | `POST /projects/:id/merge_requests/:iid/discussions/:discussion-id/notes` |
| Resolve | GraphQL `resolveReviewThread(threadId: discussion-id)` | `PUT /projects/:id/merge_requests/:iid/discussions/:discussion-id` `{resolved:true}` |
| Delete comment | `DELETE /repos/:o/:r/pulls/comments/:id` | `DELETE /projects/:id/merge_requests/:iid/notes/:note_id` |

GitLab position body for new thread:
```json
{"position": {
  "position_type": "text",
  "base_sha":  "<pullreq.base-sha>",
  "start_sha": "<pullreq.base-rev>",
  "head_sha":  "<pullreq.head-rev>",
  "old_path":  "...",
  "new_path":  "...",
  "old_line":  null,
  "new_line":  42
}}
```

All write functions dispatch via `cl-defmethod` on repo class.

---

## 4. Display

### Topic buffer

`forge-topic-refresh-buffer` gains after the posts section:
```elisp
(when (forge-pullreq-p topic)
  (forge-insert-review-threads topic))
```

`forge-insert-review-threads` (in `forge-review.el`):
1. Queries `(oref topic review-comments)`, separates openers (`reply-to nil`) from replies
2. Groups openers by `new-path`
3. Top section heading: **"Review threads"**
4. Per-file sub-section (`magit-diff-file-heading` face)
5. Per opener section (`review-comment`):
   - Heading: `@author · line N [resolved][outdated][pending]`
   - Diff hunk via `forge--fontify-diff`
   - Body via `forge--fontify-markdown`
   - Reactions: `👍 3  😄 1`
   - Replies: indented sub-sections matching `reply-to = discussion-id`
6. Resolved threads folded; pending styled distinctly

Section keymap: `forge-review-comment-section-map`

`forge--fontify-diff`: `with-temp-buffer` → insert → `diff-mode` → return propertized string.

---

## 5. Creating & Submitting

### New thread (Magit diff buffer)

`forge-add-review-comment`:
1. Reads path/line from Magit diff text properties → `new-path`, `new-line`/`old-line`
2. Opens `forge-post-mode` buffer
3. `C-c C-c` → inserts `forge-pullreq-review-comment` with `pending-p t`; renders pending marker

### Reply (topic buffer)

`magit-edit-thing` dispatch extended: `review-comment` section → `forge-reply-to-review-comment`. `C-c C-c` routes to forge-appropriate endpoint using `discussion-id` / `database-id`.

### Submit staged review

`forge-approve-pullreq`, `forge-request-changes`, new `forge-comment-pullreq` — all query `pending-p t` rows and dispatch per forge class. On success: delete pending rows; `forge-pull-this-topic`.

### Single immediate

`forge-add-single-review-comment`: posts directly, no staging.

### Discard pending

`forge-discard-review-comment`: deletes DB row; removes marker from open buffers.

---

## 6. Resolve / Unresolve

`forge-resolve-review-thread` / `forge-unresolve-review-thread` on thread openers:
- GitHub: `forge-mutate` → `resolveReviewThread` / `unresolveReviewThread`
- GitLab: `forge-rest` → `PUT /discussions/:id {resolved: true/false}`
- Callback: `oset resolved-p`; `forge-refresh-buffer`

---

## 7. Keybindings & Transient

`forge-topic-menu` "Review" group (keys used, pullreq-only via `:if`):

| Key | Command |
|-----|---------|
| `/v` | `forge-comment-pullreq` — submit staged review |
| `/n` | `forge-add-review-comment` — add (staged) inline comment |
| `/N` | `forge-add-single-review-comment` — add immediate (no staging) |
| `/K` | `forge-discard-review-comment-at-point` |
| `/x` | `forge-resolve-review-thread` |
| `/X` | `forge-unresolve-review-thread` |

`forge-review-comment-section-map`:
- `RET` (`magit-edit-thing` remap) → `forge-reply-to-review-comment`
- `e` → `forge-edit-review-comment`
- `r` → `forge-resolve-review-thread`
- `u` → `forge-unresolve-review-thread`
- `C-c C-k` → `forge-discard-review-comment-at-point`
- `C-c C-r` → `forge-reply-to-review-comment`

`magit-diff-mode-map`: `C-c r c`→add (staged), `C-c r C`→add immediate

---

## 8. Files

| Action | File |
|--------|------|
| New | `lisp/forge-review.el` |
| Modify | `lisp/forge-db.el` — schema v16 |
| Modify | `lisp/forge-github.el` — GraphQL + update + submit |
| Modify | `lisp/forge-gitlab.el` — `/discussions` fetch + update + per-comment POST + reply + resolve |
| Modify | `lisp/forge-pullreq.el` — slot rename + `base-sha` |
| Modify | `lisp/forge-topic.el` — insert call + dispatch |
| Modify | `lisp/forge-commands.el` — new group + `forge-comment-pullreq` |
| Modify | `lisp/forge.el` — require |
| Modify | `default.mk`, `lisp/Makefile` — build wiring |

---

## 9. Reference: Borrowable Patterns from `lab`

The `lab` package (`lab-20260712.1302/lab.el`) implements inline GitLab MR comments in a standalone diff buffer. Several of its techniques map directly onto this design.

### 9.1 Diff line-number extraction (`lab--diff-find-line-number-at`, line 2438)

Parses the nearest `@@ -N,L +N,L @@` hunk header via regex, then counts non-opposing lines forward to `point`. This is the exact algorithm needed in `forge-add-review-comment` to compute `new-line`/`old-line` from a Magit diff cursor position. Reusable nearly verbatim; only the `old?` flag needs mapping to `diffSide`/`old-line` vs `new-line`.

### 9.2 Inverse navigation (`lab--diff-goto-line`, line 2459)

Given `(old-path new-path line-type line-number)`, walks `diff-file-next`/`diff-hunk-next` to land on the right buffer position. Forge needs this to jump to a comment's anchor line when the user navigates review threads in a diff buffer.

### 9.3 `after-string` overlay pattern (`lab--put-comment-overlay`, line 2338)

```elisp
(let ((ov (make-overlay beg end)))
  (overlay-put ov 'lab-comment comment)
  (overlay-put ov 'after-string <rendered-text>))
```

This is the correct mechanism for `forge-review.el`'s inline display. The spec's "pending marker" and "renders in topic buffer" should both use `after-string` overlays at the commented line.

### 9.4 Box-drawing visual style (`lab--make-comment-overlay-text` + `lab--spacer`, lines 2298–2336)

Uses `┏`/`┃`/`┗`/`━` borders with a filled header line (padded to `fill-column` with `━`). The `lab--spacer` helper is a self-contained utility. This style is worth adopting directly for `forge--render-review-comment`.

### 9.5 Markdown fontification (`lab--markdown-fontify`, line 2271)

```elisp
(with-temp-buffer
  (insert text)
  (when (featurep 'markdown-mode)
    (delay-mode-hooks (markdown-mode) (font-lock-ensure)
      (fill-region (point-min) (point-max))))
  (buffer-string))
```

This is exactly how `forge--fontify-markdown` (referenced in §4) should be implemented.

### 9.6 Reply context + input stripping (`lab--prepare-reply-context` + `lab--clear-comment-input`, lines 2417–2434)

Pre-populates the edit buffer with the thread rendered as `<!-- ... -->` HTML comments for context, then strips them with a regex before submitting. Greatly improves reply UX. Worth adopting in `forge-reply-to-review-comment`.

### 9.7 Thread collapse/expand (lines 2932–2998)

Saves the original `after-string` under a separate overlay property (`lab-thread-original-text`), swaps in a collapsed placeholder, and restores on expand. Directly applicable to the spec's "resolved threads folded" requirement.

### 9.8 Thread navigation (lines 3019–3044)

```elisp
(seq-find (lambda (ov) (> (overlay-start ov) (point)))
          (seq-filter #'forge-review-comment-overlay-p
                      (overlays-in (point) (point-max))))
```

Ten-line pattern for `forge-next-review-thread` / `forge-previous-review-thread`.

### What does NOT apply

- `lab-merge-request-diff-mode` (standalone diff buffer) — forge integrates into Magit's existing diff buffers.
- `lab--format-hunk` / diff rendering — Magit already handles this.
- `async-defun`/`promise-wait` networking — forge uses `ghub` callbacks.
- Header-line review status — forge uses Magit's section model.

---

## 10. Design Tests

Automated ERT tests live in **`tests/forge-review-test.el`**. Run them with:

```sh
emacs -Q --batch -L lisp $(LOAD_PATH) \
      -l tests/forge-review-test.el \
      --funcall ert-run-tests-batch-and-exit
```

Tests are grouped by layer:

### 10.1 Data model (`forge-review-DM-*`)

| Test ID | What it checks |
|---------|---------------|
| `forge-review-DM-1-slot-round-trip` | All slots survive insert→fetch |
| `forge-review-DM-2-opener-vs-reply-identity` | One opener + two replies; correct `reply-to` linkage |
| `forge-review-DM-3-pending-flag-persists` | `pending-p t` survives DB close/reopen |
| `forge-review-DM-4-schema-migration` | v15→v16: new table + columns present; `reviews` column kept |
| `forge-review-DM-5-nil-old-path` | `old-path nil` (pure addition) inserts and reads back correctly |

### 10.2 Position computation (`forge-review-POS-*`)

| Test ID | What it checks |
|---------|---------------|
| `forge-review-POS-1-addition-line` | `+` line → `(new . N)` |
| `forge-review-POS-2-deletion-line` | `-` line → `(old . N)` |
| `forge-review-POS-3-context-line` | context line → both old and new line numbers |
| `forge-review-POS-4-multi-hunk-second-hunk` | second hunk header is used, not first |
| `forge-review-POS-5-round-trip` | `forge--diff-goto-line` lands on the same position `forge--diff-line-number-at-point` read from |

### 10.3 API / fetch mapping (`forge-review-API-*`)

| Test ID | What it checks |
|---------|---------------|
| `forge-review-API-1-github-graphql-mapping` | `reviewThreads` node → 2 rows; opener has `reply-to nil`; reply has `reply-to = thread-id` |
| `forge-review-API-2-github-left-diffside` | `diffSide=LEFT` → `old-line` set, `new-line` nil |
| `forge-review-API-3-gitlab-discussions-mapping` | `/discussions` payload → 3 rows; opener `new-line=42`; replies `reply-to=discussion-id` |
| `forge-review-API-4-gitlab-base-sha-stored` | `diff_refs.base_sha` stored on pullreq |
| `forge-review-API-5-outdated-thread` | `isOutdated=t` → `outdated-p t` |
| `forge-review-API-6-reactions-aggregated` | `reactionGroups` → `((thumbs-up . 3))` |

### 10.4 Write operations (`forge-review-WR-*`)

| Test ID | What it checks |
|---------|---------------|
| `forge-review-WR-1-github-batch-submit` | Two pending rows → single `POST .../pulls/N/reviews` with `comments` array length 2 |
| `forge-review-WR-2-gitlab-per-comment-post` | Two pending rows → two `POST .../discussions` calls each with full `position` body |
| `forge-review-WR-3-github-reply-uses-in-reply-to` | Reply → `in_reply_to_id = database-id` |
| `forge-review-WR-4-gitlab-reply-uses-discussion-endpoint` | Reply → `POST .../discussions/disc-abc/notes` |
| `forge-review-WR-5-github-resolve-sends-mutation` | Resolve → `forge-mutate resolveReviewThread` with `threadId` |
| `forge-review-WR-6-gitlab-resolve-sends-put` | Resolve → `PUT .../discussions/disc-abc` `{resolved: true}` |
| `forge-review-WR-7-discard-pending-removes-row` | `forge-discard-review-comment` deletes the DB row |
| `forge-review-WR-8-pending-cleared-after-submit` | Success callback clears `pending-p` on submitted rows |

### 10.5 Display (`forge-review-UI-*`)

| Test ID | What it checks |
|---------|---------------|
| `forge-review-UI-1-review-threads-section-present` | `review-threads` section inserted for pullreq |
| `forge-review-UI-2-no-review-threads-for-issues` | Section absent for `forge-issue` |
| `forge-review-UI-3-file-grouping` | Two `review-file` sub-sections for two distinct paths |
| `forge-review-UI-4-heading-badges` | `[resolved]` and `[outdated]` appear in heading |
| `forge-review-UI-5-pending-badge` | `[pending]` appears in heading for `pending-p t` |
| `forge-review-UI-6-reply-sections-are-children` | Reply sections are children of opener section |
| `forge-review-UI-7-resolved-thread-folded` | Resolved thread has `magit-section-hidden t` |
| `forge-review-UI-8-overlay-after-string` | Overlay at commented line has non-nil `after-string` containing body |
| `forge-review-UI-9-diff-hunk-fontified` | `forge--fontify-diff` returns string with `font-lock-face` properties |

### 10.6 Thread navigation (`forge-review-NAV-*`)

| Test ID | What it checks |
|---------|---------------|
| `forge-review-NAV-1-forward-to-next` | Point before both overlays → moves to first |
| `forge-review-NAV-2-forward-at-last-signals-error` | Past last overlay → `user-error` |
| `forge-review-NAV-3-backward` | Point past last → moves to last overlay |

### 10.7 Collapse / expand (`forge-review-COL-*`)

| Test ID | What it checks |
|---------|---------------|
| `forge-review-COL-1-collapse-replaces-body` | `after-string` replaced; original stored under `forge-thread-original-text` |
| `forge-review-COL-2-expand-restores-body` | `after-string` restored; `forge-thread-original-text` cleared |
| `forge-review-COL-3-toggle-round-trips` | Two toggle calls leave `after-string` unchanged |

### 10.8 Reply context stripping (`forge-review-RC-*`)

| Test ID | What it checks |
|---------|---------------|
| `forge-review-RC-1-html-comment-removed` | `<!-- ... -->` block stripped; body preserved |
| `forge-review-RC-2-no-comment-block-unchanged` | Input without HTML comments returned trimmed |
| `forge-review-RC-3-multiple-blocks-stripped` | Multiple `<!-- ... -->` blocks all removed |

---

## 11. Verification (Manual / Integration)

1. `make redo` — clean compile
2. GitHub `forge-pull` → `pullreq-review-comment` rows present
3. GitLab `forge-pull` → same, with `discussion-id` and three-SHA fields
4. Topic buffer → "Review threads" section renders correctly for both forges
5. `C-c r c` on diff line → pending marker + DB row with `pending-p t`
6. GitHub submit → comments on GitHub PR
7. GitLab submit → per-comment POSTs succeed on GitLab MR
8. Reply → appears on both forges
9. Resolve → `[resolved]` badge in buffer; confirmed on forge web UI
10. Buffer kill/reopen → pending comments persist from DB

---

## 12. Implementation Status (as of 2026-07-14)

### Completed

All items from the original spec are implemented. Key files added or modified:

| File | Status |
|------|--------|
| `lisp/forge-review.el` | **New** — ~850 lines |
| `lisp/forge-db.el` | Modified — schema v16 |
| `lisp/forge-pullreq.el` | Modified — `base-sha`, `review-comments` slots appended |
| `lisp/forge-github.el` | Modified — GraphQL fetch, approve/request-changes flush |
| `lisp/forge-gitlab.el` | Modified — `/discussions` fetch, `base-sha` store |
| `lisp/forge-topic.el` | Modified — Review group in `forge-topic-menu`, `declare-function` |
| `lisp/forge.el` | Modified — `(require 'forge-review)`, diff keybindings |
| `default.mk`, `lisp/Makefile` | Modified — build wiring for `forge-review.el` |
| `tests/forge-review-test.el` | **New** — 56 ERT tests across 10 groups |

### Deviations from original spec

**Keybindings** — The spec proposed `/c`, `/C`, `/A`, `/R`, `/K`, `/r`, `/u`. The implementation uses:

| Spec key | Actual key | Command |
|----------|------------|---------|
| `/c` (submit review) | `/v` | `forge-comment-pullreq` |
| (not in spec) | `/n` | `forge-add-review-comment` |
| (not in spec) | `/N` | `forge-add-single-review-comment` |
| `/K` | `/K` | `forge-discard-review-comment-at-point` |
| `/r` | `/x` | `forge-resolve-review-thread` |
| `/u` | `/X` | `forge-unresolve-review-thread` |

**Section keymap** — `RET` remaps `magit-edit-thing` → `forge-reply-to-review-comment` (not edit). Separate `e` key → `forge-edit-review-comment`.

**`forge-add-single-review-comment`** — Posts directly to the API in a dedicated `forge--submit-add-single-review-comment` handler; does not go through the pending/staging path.

**Approve/request-changes flush** — `forge--submit-approve-pullreq` and `forge--submit-request-changes` in `forge-github.el` now collect pending `review-comment` rows and include them as the `comments` array in the review POST, then clear `pending-p`.

**Diff overlay refresh** — `forge--maybe-insert-review-threads-in-diff` is registered on `magit-refresh-buffer-hook` so overlays are re-placed after every buffer refresh. Stale overlays are cleared before re-placement via `forge--clear-review-comment-overlays`.

### Bugs fixed during implementation

| Bug | Fix |
|-----|-----|
| `start_sha` in GitLab submission used `base-sha` (merge base) for both fields | Changed to use `(oref pr base-rev)` for `start_sha` |
| `forge--gitlab-resolve-thread` sent string `"true"` instead of boolean | Changed signature to take `resolved` arg; uses `(if resolved t :false)` |
| `incf` undefined in `forge--diff-goto-line` | Fixed to `cl-incf` |
| Section keymap `RET` mapped to edit instead of reply | Remapped to `forge-reply-to-review-comment`; `e` = edit |
| No unresolve support on either forge | Added `forge--github-unresolve-thread` and `forge--gitlab-resolve-thread` with `nil` arg |
| `forge-discard-review-comment` did not call API for submitted comments | Now dispatches `forge--github-delete-review-comment` / `forge--gitlab-delete-review-comment` before `closql-delete` |
| GitLab `resolved-p` not read from API response | `forge--update-gitlab-discussion` now reads `(alist-get 'resolved discussion)` |

### Test suite

56 ERT tests in `tests/forge-review-test.el` across 10 groups:

| Groups 1–8 | From original spec §10 |
|-----------|------------------------|
| DM (1–5) | Data model |
| POS (1–5) | Position computation |
| API (1–6) | Fetch/mapping |
| WR (1–8) | Write operations |
| UI (1–9) | Display |
| NAV (1–3) | Thread navigation |
| COL (1–3) | Collapse/expand |
| RC (1–3) | Reply context stripping |

| Groups 9–10 | Added during implementation |
|------------|----------------------------|
| NEW (1–8) | Heading line/side, body hunk/reactions, GitHub/GitLab unresolve, GitLab `start_sha` fix |
| NEW (9–14) | GitLab `resolved-p` from API, discard API call, discard pending (no API), overlay hook, clear overlays |

Run with `make test` (requires compat-31 on the load path; see CLAUDE.md).

