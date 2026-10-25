BRANCH         := $(shell git rev-parse --abbrev-ref HEAD)
LAST_TAG       := $(shell git tag --sort=-v:refname | head -n1)
VERSION        ?= $(shell echo '$(LAST_TAG)' | awk -F. '{print $$1"."$$2+1".0"}')
VECTOR_VERSION := $(shell sed -n 's/.*VECTOR_VERSION="\([0-9.]*\)".*/\1/p' Dockerfile)
ADDONS_REPO    ?= twiebe/hassos-addons
NOTES          := .git/RELEASE_NOTES

.DEFAULT_GOAL := help
.PHONY: help status release

help: ## Show targets and the release flow
	@echo "Release flow:"
	@echo "  1. Work on dev (Renovate PRs target dev). Every push to dev builds :dev and :dev-<sha>"
	@echo "     and points the vector-dev addon in hassos-addons at it; HA offers it as an update."
	@echo "  2. Note changes in hassos-addons/vector-dev/CHANGELOG.md under '## <version>'."
	@echo "  3. Here:            make release   (dev -> main, tag, wait for the image, GitHub release)"
	@echo "     Needs 'gh auth login'. Release notes come from that changelog section on hassos-addons main."
	@echo "  4. In hassos-addons: make release VERSION=<version>   (vector-dev -> vector)"
	@echo
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-15s %s\n", $$1, $$2}'
	@echo
	@echo "Override the version with VERSION=x.y.z (default: next minor after $(LAST_TAG))."

status: ## Show versions involved in the next release
	@echo "branch:          $(BRANCH)"
	@echo "vector:          $(VECTOR_VERSION)"
	@echo "last release:    $(LAST_TAG)"
	@echo "next release:    $(VERSION)"
	@echo "dev ahead of main:"
	@git log --oneline origin/main..origin/dev

release: ## Fast-forward main to dev, tag VERSION with changelog notes, push, wait for the image, create GitHub release
	@echo '$(VERSION)' | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "VERSION must be x.y.z"; exit 1; }
	@gh auth status >/dev/null 2>&1 || { echo "gh not authenticated, run 'gh auth login'"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "working tree not clean"; exit 1; }
	git fetch origin --tags
	@! git rev-parse -q --verify "refs/tags/$(VERSION)" >/dev/null || { echo "tag $(VERSION) already exists"; exit 1; }
	scripts/release-notes.sh $(ADDONS_REPO) $(VERSION) > $(NOTES)
	@echo "Release notes for $(VERSION):"; cat $(NOTES)
	git switch main
	git merge --ff-only origin/main
	git merge --ff-only origin/dev
	git tag -a $(VERSION) --cleanup=verbatim -F $(NOTES)
	git push origin main $(VERSION)
	scripts/wait-build.sh build.yml $$(git rev-parse HEAD)
	gh release create $(VERSION) --verify-tag --title $(VERSION) --notes-from-tag
	git switch dev
	@echo
	@echo "Next: in hassos-addons run 'make release VERSION=$(VERSION)'"
