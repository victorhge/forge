# PR Changed Files Section and Full-Range Diff Command

**Date:** 2026-07-20
**Status:** Approved

## Problem

When reviewing a PR with changes spread across multiple files and multiple review threads, there is no single entry point to view the full PR diff (base → head across all commits). The topic buffer shows review threads but not the code changes; the diff buffer shows code changes but only for one commit at a time. Users must manually construct a diff range or navigate individual commits, losing the thread overview in the process.

## Goal

1. Show a "Changed files" overview in the pull-request topic buffer — lightweight, no DB change, no API call.
2. Provide a single command to open a full-range PR diff buffer from the topic buffer, with review comment overlays already wired up.
3. Allow scoping that command to a single file when point is on a changed-file entry.

## Design

### Changed Files Section

A new collapsible magit section inserted into the pull-request topic buffer, between the commits section and the note/posts.

**Heading:** `"Changed files (N)"` where N is the file count.

**Content:** One child `(changed-file)` section per file, showing the filename and `+X -Y` insertion/deletion counts.

Example rendering:
```
Changed files (3)
  lisp/forge-pullreq.el              +47 -3
  lisp/forge-review.el               +12 -1
  tests/forge-pullreq-test.el        +80 -0
```

**Data source:** `git diff --stat BASE...HEAD` using `forge--pullreq-range`. Run at render time via `magit-git-lines` — no caching, no DB change, no API call.

**Fallback:** If `forge--pullreq-range` returns nil (local refs not yet fetched), the section body shows:
```
  Diff not available (run forge-pull first)
```
The section still renders; it does not error.

**Insertion point:** Added to `forge-pullreq-sections-hook` immediately after `forge--insert-pullreq-commits`.

### `forge-diff-pullreq` Command

An interactive command that opens a `magit-diff-mode` buffer for the full PR range, reusing Magit's single diff buffer (matching Magit's default diff buffer reuse behavior).

**Dispatch logic based on point:**

| Point location | Behavior |
|---|---|
| `(changed-file)` section | Diff scoped to that file: `magit-diff-setup-buffer RANGE nil nil (list "--" FILENAME)` |
| Anywhere else in topic buffer | Full PR diff: `magit-diff-setup-buffer RANGE nil nil nil` |

**`forge-buffer-topic` propagation:** Already handled automatically by `forge--propagate-buffer-topic` on `magit-setup-buffer-hook`. The resulting diff buffer inherits `forge-buffer-topic` from the topic buffer, so `forge--maybe-insert-review-threads-in-diff` fires on refresh and places review comment overlays without any extra wiring.

**Error on missing range:** If `forge--pullreq-range` returns nil, signal `user-error "PR refs not available; run forge-pull first"` rather than passing nil to `magit-diff-setup-buffer`.

**Keybinding:** `d` in `forge-pullreq-mode-map`. This key is currently unbound in the topic buffer (Magit's `d` prefix lives in `magit-mode-map` but the pullreq topic buffer is not a `magit-diff-mode`; no conflict).

### No New Files

Both additions go into `lisp/forge-pullreq.el`, which already owns the commits section inserter (`forge--insert-pullreq-commits`) and `forge--pullreq-range`. No new source files.

## Implementation Locations

| Item | File | Notes |
|---|---|---|
| `forge--insert-pullreq-changed-files` | `lisp/forge-pullreq.el` | New section inserter |
| `forge-diff-pullreq` | `lisp/forge-pullreq.el` | New interactive command |
| Hook registration | `lisp/forge-pullreq.el` | Add to `forge-pullreq-sections-hook` |
| Keybinding | `lisp/forge-pullreq.el` | `d` in `forge-pullreq-mode-map` |

## Testing

All tests are local — no GitHub/GitLab connection required.

### Unit tests (in `tests/forge-pullreq-test.el`)

1. **Changed-files section parsing** — Feed a mock `git diff --stat` output string through the parser, assert correct file count, filenames, and stat suffixes are extracted.

### Integration tests (in `tests/forge-pullreq-test.el`)

Prerequisites: a local git fixture repo with `refs/pullreqs/N` present and a `forge-pullreq` object in the test DB with `base-rev`/`head-rev` populated (same fixture pattern as `tests/forge-review-test.el`).

2. **Changed-files section renders** — Open a topic buffer for a test PR, assert the `(changed-files)` section exists and contains the expected number of `(changed-file)` children.

3. **`forge-diff-pullreq` from topic buffer** — Mock `magit-diff-setup-buffer` via `cl-letf`, call `forge-diff-pullreq` from a topic buffer with point on a non-file section, assert `magit-diff-setup-buffer` is called with the correct range and no `-- FILE` argument.

4. **`forge-diff-pullreq` scoped to file** — Same mock setup, but position point on a `(changed-file)` section child. Assert `magit-diff-setup-buffer` is called with the correct range and `(list "--" FILENAME)` as the files argument.

5. **Missing range fallback** — With `forge--pullreq-range` returning nil (stub via `cl-letf`), assert:
   - The changed-files section renders the placeholder string (not an error).
   - `forge-diff-pullreq` signals `user-error`.

## Out of Scope

- Embedding the full diff content inside the topic buffer (Option B from the investigation). This can be revisited later.
- Per-file diff in a side window (Option C layout). The single reused diff buffer is sufficient.
- Storing changed-file data in the database or fetching it from the API.
- Showing changed files for issues or other non-pullreq topics.
