# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```sh
make lisp        # Byte-compile all .el files and generate autoloads
make redo        # Clean then re-compile (use after structural changes)
make docs        # Generate all manual formats from docs/forge.org
make clean       # Remove compiled .elc files and generated autoloads
```

Compilation requires dependencies on the load path. `default.mk` expects sibling directories (e.g., `../../magit/lisp`, `../../ghub/lisp`) relative to the `lisp/` directory, or set `LOAD_PATH` manually.

`make test` runs the ERT suite in `tests/forge-review-test.el` (87 tests). It uses `package-initialize` to load dependencies from the user's installed ELPA — no path configuration needed. Requires `compat-31.x` (not `compat-30.x`) to satisfy `closql`'s `compat-call sort` usage.

## Architecture

Forge is a Magit extension that integrates Git forge APIs (GitHub, GitLab, Forgejo, etc.) into Emacs. Data is persisted in a local SQLite database.

### Compilation order / layer dependency

The `lisp/Makefile` encodes the load order:

```
forge-db  →  forge-core  →  forge  →  forge-repo, forge-post
                                  →  forge-topic  →  forge-{issue,pullreq,discussion,revnote}
                                  →  forge-client  →  forge-{github,gitlab,forgejo,gitea,gogs,bitbucket}
                                  →  forge-commands, forge-tablist  →  forge-{topics,repos}
```

### Key files

- **`forge-db.el`** — SQLite schema (version 15, via `closql`/`emacsql`). Contains `forge--db-table-schemata` (all table definitions) and `forge--db-update-schema` (migration path from each prior version). The database is automatically backed up before schema upgrades.
- **`forge-core.el`** — Base `forge-object` EIEIO class, `forge-alist` (maps git/api/web hosts to repository classes), `forge-get-repository`/`forge-get-topic` generics, URL parsing (`forge--split-forge-url`), and object ID utilities.
- **`forge.el`** — Entry point. Loads all modules, registers sections into `magit-status-sections-hook`, and adds keybindings/transient suffixes to Magit.
- **`forge-repo.el`** — `forge-repository` EIEIO class with all repository slots and URL format class-allocated slots.
- **`forge-post.el`** / **`forge-topic.el`** — Base classes for posts and topics (issues, PRs, discussions). Object hierarchy: `repository > topic > post`.
- **`forge-client.el`** — `forge-query`/`forge-mutate` macros (GraphQL via `ghub`) and `forge-rest` macro (REST). `forge--format-resource` interpolates `:slot` placeholders in resource paths.
- **`forge-{github,gitlab,forgejo,gitea,gogs,bitbucket}.el`** — Per-forge repository subclasses with URL format slots, and forge-specific `forge--pull` / `forge--update-*` method implementations. `forge-github.el` and `forge-gitlab.el` also implement the review-comment generics declared in `forge-review.el` (`forge--update-pullreq-review-comments`, `forge--review-submit`, `forge--review-post-reply`, `forge--review-set-thread-resolved`, `forge--review-delete-comment`, `forge--review-post-comment`, `forge--submit-review-reply`, `forge--submit-add-single-review-comment`).
- **`forge-semi.el`** — "Semi-forges" (cgit, stagit, sr.ht, etc.) that have no API; only browsing is supported.
- **`forge-commands.el`** — All user-facing `transient-define-prefix` commands (`forge-dispatch` and sub-menus).
- **`forge-topics.el`** / **`forge-repos.el`** — Tablist-based list views for topics and repositories.
- **`forge-review.el`** — Inline PR/MR review comment support (new, schema v16). `forge-pullreq-review-comment` EIEIO class; `cl-defgeneric` declarations for the fetch/mapping and write-operation generics (implemented in the backend files); display via `magit-section` in the topic buffer and `after-string` overlays in diff buffers; diff line-number utilities; interactive commands (`forge-add-review-comment`, `forge-reply-to-review-comment`, `forge-resolve/unresolve-review-thread`, `forge-comment-pullreq`, etc.); DB-only staging helpers `forge-review--stage-comment` and `forge-review--save-comment-edit` (used as `forge--submit-post-function` callbacks for local-only operations).

### Object hierarchy

```
closql-object
└── forge-object                        (forge-core.el) abstract
    ├── forge-repository                (forge-repo.el) abstract
    │   ├── forge-unusedapi-repository  abstract — API not yet implemented
    │   │   ├── forge-forgejo-repository
    │   │   ├── forge-gitea-repository
    │   │   └── forge-gogs-repository
    │   ├── forge-noapi-repository      abstract — no API at all (semi-forges)
    │   │   ├── forge-bitbucket-repository
    │   │   ├── forge-gitweb-repository
    │   │   ├── forge-cgit-repository   (and cgit* / cgit** subclasses)
    │   │   ├── forge-stagit-repository
    │   │   └── forge-srht-repository
    │   ├── forge-github-repository     (forge-github.el)
    │   └── forge-gitlab-repository     (forge-gitlab.el)
    ├── forge-post                      (forge-post.el) abstract
    │   ├── forge-topic                 (forge-topic.el) abstract
    │   │   ├── forge-issue             (forge-issue.el)
    │   │   ├── forge-pullreq           (forge-pullreq.el)
    │   │   ├── forge-discussion        (forge-discussion.el)
    │   │   └── forge-revnote           (forge-revnote.el)
    │   ├── forge-issue-post            (forge-issue.el)
    │   ├── forge-pullreq-post          (forge-pullreq.el)
    │   ├── forge-discussion-post       (forge-discussion.el)
    │   ├── forge-discussion-reply      (forge-discussion.el)
    │   └── forge-note                  (forge-post.el)
    ├── forge-notification              (forge-notify.el)
    └── forge-pullreq-review-comment    (forge-review.el) — not a post; inline diff comment
```

`forge-pullreq-review-comment` is a `closql-object` directly (not via `forge-post`) because it has different slot semantics and is not part of the issue/PR conversation thread.

### Repository identity and tracking states

Repository IDs in the database are derived from **WEBHOST** (not GITHOST). `forge-alist` entries have the form `(GITHOST APIHOST WEBHOST CLASS)`.

A repository object has one of three conditions:
- `:tracked` — explicitly added by the user via `forge-pull`
- `:known` — stored in the database but not explicitly tracked
- `:stub` — constructed offline without a database entry (used by browse commands)

`forge-get-repository` accepts demand keywords (`:tracked`, `:tracked?`, `:known?`, `:stub`, `:stub?`, `:insert!`, `:valid?`) that control what level of repository is required and how to handle missing ones.

### Symbol shorthands

Every source file uses `cond-let` read-symbol-shorthands declared in file-local variables. Short forms like `and$`, `when$`, `if-let`, `when-let`, `while-let` (and their `*` variants) expand to `cond-let--` prefixed equivalents. These are not standard Emacs builtins — they come from the `cond-let` package.

### Inline review comment invariants

- **DB column order**: `base-sha` and `review-comments` were added to `forge-pullreq` via `ALTER TABLE` and must remain at the **end** of the slot list in `forge-pullreq.el` to match closql's positional INSERT.
- **Thread openers vs replies**: `reply-to nil` marks a thread opener; `reply-to = discussion-id` marks a reply. All write operations (resolve, reply, delete) dispatch on the opener's `discussion-id`.
- **API calls in write methods**: backend `cl-defmethod` implementations call `forge--rest` and `forge--query` directly. Tests stub these at the CLOS dispatch layer using fake subclasses (`forge-test-github-repository`, `forge-test-gitlab-repository`) defined in `forge-review-test.el` whose write methods record calls instead of hitting the network.
- **Pending comments**: `pending-p t` rows are locally staged. `forge-comment-pullreq`, `forge--submit-approve-pullreq`, and `forge--submit-request-changes` all flush them. `forge-add-single-review-comment` bypasses staging and posts directly.
- **Post-submit sync**: `forge--review-submit` calls `forge--pull-topic` after posting, replacing locally-staged rows (with temporary IDs) with the server's canonical versions. GitHub always fires the pull (unconditionally in the REST callback). GitLab guards with `(when pending ...)` to skip the pull when no comments were staged, avoiding a spurious round-trip.
- **Submit callback protocol**: all functions assigned to `forge--submit-post-function` must accept exactly two arguments `(repo post)`. DB-only staging callbacks (`forge-review--stage-comment`, `forge-review--save-comment-edit`) use `(_repo _post)` and ignore both. API-submitting callbacks are `cl-defmethod` generics specialised on the repo class.
- **Diff overlays**: `forge--maybe-insert-review-threads-in-diff` is on `magit-refresh-buffer-hook`; it guards with `(derived-mode-p 'magit-diff-mode)` and clears stale overlays before re-placing.
- **GitLab SHA fields**: `base_sha` = merge base (`forge-pullreq.base-sha`); `start_sha` = branch point (`forge-pullreq.base-rev`); `head_sha` = tip (`forge-pullreq.head-rev`). These are three different SHAs.
- **Dispatch pattern**: `forge-review.el` declares `cl-defgeneric` for all forge-specific operations. `forge-github.el` and `forge-gitlab.el` provide `cl-defmethod` implementations specialised on their repo class. Do not add `if (gitlab-p repo)` dispatch guards to `forge-review.el`.

## Code Conventions

### Generic dispatch pattern

All forge-specific behaviour is implemented via `cl-defgeneric` / `cl-defmethod`, never with `if`/`cond` guards on repo type. The pattern is:

1. Declare the generic (docstring only, no default body) in the file that owns the abstraction (`forge-core.el`, `forge-review.el`, etc.).
2. Add `cl-defmethod` implementations specialised on `(repo forge-github-repository)` in `forge-github.el` and `(repo forge-gitlab-repository)` in `forge-gitlab.el`.
3. Use `_` prefix for unused specialised arguments: `((_repo forge-github-repository) ...)`.

Do not use `forge-gitlab-repository--eieio-childp` for dispatch inside generic files. Use it only where a concrete forge type genuinely cannot be expressed as a method (e.g. `forge--set-field-callback` in `forge-client.el`, which runs after a callback rather than as a method dispatch).

### API call conventions

- **GraphQL queries/mutations**: use the `forge-query` / `forge-mutate` macros from `forge-client.el`. These handle host inference, auth, and the `ghub` DSL. Inside `cl-defmethod` bodies, call `forge--query` directly (the function-level equivalent).
- **REST**: use the `forge-rest` macro for normal topic operations (handles host inference). Inside `cl-defmethod` bodies, call `forge--rest` directly.
- **Never call `ghub-request` directly** from forge methods — always go through `forge--rest` or `forge--query` so host inference works correctly.

### Naming conventions

| Pattern | Meaning |
|---|---|
| `forge-FOO` | Public interactive command or user-facing function |
| `forge--FOO` | Internal implementation detail |
| `forge-review--FOO` | Internal to `forge-review.el`; staging helpers (`forge-review--stage-comment`, `forge-review--save-comment-edit`) conform to the `(_repo _post)` submit protocol but write only to the local DB |
| `forge--update-FOO` | Fetch + DB-write of a resource (called from pull flows) |
| `forge--submit-FOO` | Callback used as `forge--submit-post-function`; always a `cl-defmethod` taking `(repo post)`; dispatches to the forge API |
| `forge--review-FOO` | Generic declared in `forge-review.el`; methods in backend files |

### forge-client.el macros

- **`forge-query`** — GraphQL query; wraps body in `(query ...)`.
- **`forge-mutate`** — GraphQL mutation; wraps body with `ghub--prepare-mutation`.
- **`forge--mutate-field`** — Convenience for single-field mutations that refresh the topic on success.
- **`forge-rest`** — REST request; infers host from the object; accepts `forge--prepare-variables` DSL for params.
- **`forge--rest`** / **`forge--query`** — Function-level equivalents (called by the macros); accept pre-evaluated arguments.

### closql / EIEIO slot conventions

- Slot access: `(oref obj slot)` to read, `(oset obj slot val)` to write.
- DB insert: `(closql-insert (forge-db) obj t)` — the trailing `t` means "replace if exists".
- DB lookup: `(closql-get (forge-db) id 'forge-CLASS)`.
- Transactions: `(closql-with-transaction (forge-db) ...)` — used in bulk-insert paths (e.g. `forge--update-pullreq-review-comments`).
- New columns added to an existing table via `ALTER TABLE` must be appended to the **end** of the slot list to preserve closql's positional INSERT order.

## Documentation

Edit **`docs/forge.org`** only. Do **not** edit `docs/forge.texi` (it is generated) and do not modify version numbers in the org file — maintainers handle those before release.
