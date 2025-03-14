# Image URL to use all building/pushing image targets
REPOSITORY     ?= localhost:5005
TAG            ?= dev-$(shell git describe --match='' --always --abbrev=6 --dirty)
PLATFORM       ?= linux/$(shell go env GOARCH)
CHAINSAW_ARGS  ?=
VERSION        ?= v0.0.0

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# CONTAINER_TOOL defines the container tool to be used for building images.
# Be aware that the target commands are only tested with Docker which is
# scaffolded by default. However, you might want to replace it to use other
# tools. (i.e. podman)
CONTAINER_TOOL ?= docker

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: clean
clean:
	-rm -r bin/

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk command is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: test
test: ## Run tests.
	go test -coverprofile cover.out ./...

.PHONY: test-e2e
test-e2e: chainsaw ## Run the e2e tests against a k8s instance using Kyverno Chainsaw.
	$(CHAINSAW) test ${CHAINSAW_ARGS}

.PHONY: lint
lint: golangci-lint ## Run golangci-lint linter.
	$(GOLANGCI_LINT) run

.PHONY: lint-fix
lint-fix: golangci-lint ## Run golangci-lint linter and perform fixes.
	$(GOLANGCI_LINT) run --fix

.PHONY: lint-manifests
lint-manifests: kustomize kube-linter ## Run kube-linter on Kubernetes manifests.
	$(KUSTOMIZE) build config/default |\
		$(KUBE_LINTER) lint --config=./config/.kube-linter.yaml -

.PHONY: hadolint
hadolint: hadolint-plugin ## Run hadolint on all Dockerfiles.

.PHONY: hadolint-plugin
hadolint-plugin: ## Run hadolint on plugin Dockerfile.
	$(CONTAINER_TOOL) run --rm -i hadolint/hadolint < Dockerfile

.PHONY: verify-licenses
verify-licenses: addlicense ## Run addlicense to verify if files have license headers.
	find -type f -name "*.go" ! -path "*/vendor/*" | xargs $(ADDLICENSE) -check

.PHONY: add-licenses
add-licenses: addlicense ## Run addlicense to append license headers to files missing one.
	find -type f -name "*.go" ! -path "*/vendor/*" | xargs $(ADDLICENSE) -c "anza-labs contributors."

##@ CI

.PHONY: diff
diff: ## Run git diff-index to check if any changes are made.
	git --no-pager diff HEAD --

.PHONY: release
release: ## Runs the script that generates new release.
	go run ./hack/cmd/release -version $(VERSION)

##@ Build

# If you wish to build the plugin image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
docker-build: docker-build-plugin ## Build all docker images.

.PHONY: docker-build-plugin
docker-build-plugin: ## Build docker image with the plugin.
	$(CONTAINER_TOOL) build \
		--platform=${PLATFORM} \
		--file=./cmd/tun-device-plugin/Dockerfile \
		--tag=$(REPOSITORY)/tun-device-plugin:$(TAG) .

.PHONY: docker-push
docker-push: docker-push-controller ## Push all docker images.

.PHONY: docker-push-controller
docker-push-controller: ## Push docker image with the controller.
	$(CONTAINER_TOOL) push $(REPOSITORY)/tun-device-plugin:$(TAG)

.PHONY: build-installer
build-installer: kustomize ## Generate a consolidated YAML with CRDs and deployment.
	mkdir -p dist
	cd config/plugin && $(KUSTOMIZE) edit set image plugin=$(REPOSITORY)/tun-device-plugin:$(TAG)
	$(KUSTOMIZE) build config/default > dist/install.yaml

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: cluster
cluster: kind ctlptl kustomize
	@PATH=${LOCALBIN}:$(PATH) $(CTLPTL) apply -f hack/kind.yaml

.PHONY: cluster-reset
cluster-reset: kind ctlptl
	@PATH=${LOCALBIN}:$(PATH) $(CTLPTL) delete -f hack/kind.yaml

.PHONY: deploy
deploy: kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/plugin && $(KUSTOMIZE) edit set image plugin=$(REPOSITORY)/tun-device-plugin:$(TAG)
	$(KUSTOMIZE) build config/default | $(KUBECTL) apply -f -

.PHONY: undeploy
undeploy: kustomize ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

##@ Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KUBECTL   ?= kubectl

ADDLICENSE     ?= $(LOCALBIN)/addlicense
CHAINSAW       ?= $(LOCALBIN)/chainsaw
CTLPTL         ?= $(LOCALBIN)/ctlptl
GOLANGCI_LINT  ?= $(LOCALBIN)/golangci-lint
KIND           ?= $(LOCALBIN)/kind
KUBE_LINTER    ?= $(LOCALBIN)/kube-linter
KUSTOMIZE      ?= $(LOCALBIN)/kustomize

## Tool Versions
# renovate: datasource=github-tags depName=google/addlicense
ADDLICENSE_VERSION ?= v1.1.1

# renovate: datasource=github-tags depName=kyverno/chainsaw
CHAINSAW_VERSION ?= v0.2.12

# renovate: datasource=github-tags depName=kubernetes-sigs/controller-tools
CONTROLLER_TOOLS_VERSION ?= v0.17.2

# renovate: datasource=github-tags depName=tilt-dev/ctlptl
CTLPTL_VERSION ?= v0.8.39

# renovate: datasource=github-tags depName=golangci/golangci-lint
GOLANGCI_LINT_VERSION ?= v1.64.7

# renovate: datasource=github-tags depName=kubernetes-sigs/kind
KIND_VERSION ?= v0.27.0

# renovate: datasource=github-tags depName=stackrox/kube-linter
KUBE_LINTER_VERSION ?= v0.7.2

# renovate: datasource=github-tags depName=kubernetes-sigs/kustomize
KUSTOMIZE_VERSION ?= v5.6.0

.PHONY: tools
tools: addlicense chainsaw ctlptl golangci-lint kind kube-linter kustomize ## Install all tools.

.PHONY: addlicense
addlicense: $(ADDLICENSE)-$(ADDLICENSE_VERSION) ## Download addlicense locally if necessary.
$(ADDLICENSE)-$(ADDLICENSE_VERSION): $(LOCALBIN)
	$(call go-install-tool,$(ADDLICENSE),github.com/google/addlicense,$(ADDLICENSE_VERSION))

.PHONY: chainsaw
chainsaw: $(CHAINSAW)-$(CHAINSAW_VERSION) ## Download chainsaw locally if necessary.
$(CHAINSAW)-$(CHAINSAW_VERSION): $(LOCALBIN)
	$(call go-install-tool,$(CHAINSAW),github.com/kyverno/chainsaw,$(CHAINSAW_VERSION))

.PHONY: ctlptl
ctlptl: $(CTLPTL)-$(CTLPTL_VERSION) ## Download ctlptl locally if necessary.
$(CTLPTL)-$(CTLPTL_VERSION): $(LOCALBIN)
	$(call go-install-tool,$(CTLPTL),github.com/tilt-dev/ctlptl/cmd/ctlptl,$(CTLPTL_VERSION))

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT)-$(GOLANGCI_LINT_VERSION) ## Download golangci-lint locally if necessary.
$(GOLANGCI_LINT)-$(GOLANGCI_LINT_VERSION): $(LOCALBIN)
	./hack/install-golangci-lint.sh $(LOCALBIN) $(GOLANGCI_LINT) $(GOLANGCI_LINT_VERSION)

.PHONY: kind
kind: $(KIND)-$(KIND_VERSION) ## Download kind locally if necessary.
$(KIND)-$(KIND_VERSION): $(LOCALBIN)
	$(call go-install-tool,$(KIND),sigs.k8s.io/kind,$(KIND_VERSION))

.PHONY: kube-linter
kube-linter: $(KUBE_LINTER)-$(KUBE_LINTER_VERSION) ## Download kube-linter locally if necessary.
$(KUBE_LINTER)-$(KUBE_LINTER_VERSION): $(LOCALBIN)
	$(call go-install-tool,$(KUBE_LINTER),golang.stackrox.io/kube-linter/cmd/kube-linter,$(KUBE_LINTER_VERSION))

.PHONY: kustomize
kustomize: $(KUSTOMIZE)-$(KUSTOMIZE_VERSION) ## Download kustomize locally if necessary.
$(KUSTOMIZE)-$(KUSTOMIZE_VERSION): $(LOCALBIN)
	$(call go-install-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v5,$(KUSTOMIZE_VERSION))

# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f "$(1)-$(3)" ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
rm -f $(1) || true ;\
GOBIN=$(LOCALBIN) go install $${package} ;\
mv $(1) $(1)-$(3) ;\
} ;\
ln -sf $(1)-$(3) $(1)
endef
