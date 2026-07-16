-include config.mk
include default.mk

.PHONY: lisp docs test test-integration

all: lisp docs

test:
	@$(EMACS) -Q --batch \
	  --eval "(require 'package)" \
	  --eval "(package-initialize)" \
	  -L ./lisp -L ./tests \
	  --eval "(require 'forge-review)" \
	  --eval "(require 'forge-review-test)" \
	  -f ert-run-tests-batch-and-exit

test-integration:
	@rm -f tests/forge-review-integration-test.elc
	@$(EMACS) -Q --batch \
	  --eval "(require 'package)" \
	  --eval "(package-initialize)" \
	  -L ./lisp -L ./tests \
	  --eval "(require 'forge-review-integration-test)" \
	  -f ert-run-tests-batch-and-exit

help:
	$(info make all          -- Generate lisp and manual)
	$(info make lisp         -- Generate byte-code and autoloads)
	$(info make redo         -- Re-generate byte-code and autoloads)
	$(info make test              -- Run ERT test suite)
	$(info make test-integration  -- Run integration tests (requires FORGE_TEST_GITHUB_REPO))
	$(info make docs         -- Generate all manual formats)
	$(info make redo-docs    -- Re-generate all manual formats)
	$(info make texi         -- Generate texi manual)
	$(info make info         -- Generate info manual)
	$(info make html         -- Generate html manual file)
	$(info make html-dir     -- Generate html manual directory)
	$(info make pdf          -- Generate pdf manual)
	$(info make publish      -- Publish snapshot manuals)
	$(info make release      -- Publish release manuals)
	$(info make stats        -- Generate statistics)
	$(info make stats-upload -- Publish statistics)
	$(info make clean        -- Remove most generated files)
	@printf "\n"

lisp:
	@$(MAKE) -C lisp lisp
redo:
	@$(MAKE) -C lisp clean lisp

docs:
	@$(MAKE) -C docs docs
redo-docs:
	@$(MAKE) -C docs redo-docs
texi:
	@$(MAKE) -C docs texi
info:
	@$(MAKE) -C docs info
html:
	@$(MAKE) -C docs html
html-dir:
	@$(MAKE) -C docs html-dir
pdf:
	@$(MAKE) -C docs pdf

publish:
	@$(MAKE) -C docs publish
release:
	@$(MAKE) -C docs release

stats:
	@$(MAKE) -C docs stats
stats-upload:
	@$(MAKE) -C docs stats-upload

clean:
	@$(MAKE) -C lisp clean
	@$(MAKE) -C docs clean
