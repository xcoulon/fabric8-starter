PROJECT_NAME=fabric8-starter
PACKAGE_NAME:=github.com/fabric8-services/$(PROJECT_NAME)
CUR_DIR=$(shell pwd)
TMP_PATH=$(CUR_DIR)/tmp
INSTALL_PREFIX=$(CUR_DIR)/bin
VENDOR_DIR=vendor
SOURCE_DIR ?= .
SOURCES := $(shell find $(SOURCE_DIR) -path $(SOURCE_DIR)/vendor -prune -o -name '*.go' -print)
DESIGN_DIR=design
DESIGNS := $(shell find $(SOURCE_DIR)/$(DESIGN_DIR) -path $(SOURCE_DIR)/vendor -prune -o -name '*.go' -print)

# declares variable that are OS-sensitive
ifeq ($(OS),Windows_NT)
include ./.make/Makefile.win
else
include ./.make/Makefile.lnx
endif

# Find all required tools:
GIT_BIN := $(shell command -v $(GIT_BIN_NAME) 2> /dev/null)
DEP_BIN_DIR := $(TMP_PATH)/bin
DEP_BIN := $(DEP_BIN_DIR)/$(DEP_BIN_NAME)
DEP_VERSION=v0.4.1
GO_BIN := $(shell command -v $(GO_BIN_NAME) 2> /dev/null)

# This is a fix for a non-existing user in passwd file when running in a docker
# container and trying to clone repos of dependencies
GIT_COMMITTER_NAME ?= "user"
GIT_COMMITTER_EMAIL ?= "user@example.com"
export GIT_COMMITTER_NAME
export GIT_COMMITTER_EMAIL

COMMIT=$(shell git rev-parse HEAD)
GITUNTRACKEDCHANGES := $(shell git status --porcelain --untracked-files=no)
ifneq ($(GITUNTRACKEDCHANGES),)
COMMIT := $(COMMIT)-dirty
endif
BUILD_TIME=`date -u '+%Y-%m-%dT%H:%M:%SZ'`


# For the global "clean" target all targets in this variable will be executed
CLEAN_TARGETS =

# Pass in build time variables to main
LDFLAGS=-ldflags "-X ${PACKAGE_NAME}/controller.Commit=${COMMIT} -X ${PACKAGE_NAME}/controller.BuildTime=${BUILD_TIME}"

# Call this function with $(call log-info,"Your message")
define log-info =
@echo "INFO: $(1)"
endef

# If nothing was specified, run all targets as if in a fresh clone
.PHONY: all
## Default target - fetch dependencies, generate code and build.
all: prebuild-check deps generate build

.PHONY: help
# Based on https://gist.github.com/rcmachado/af3db315e31383502660
## Display this help text.
help:/
	$(info Available targets)
	$(info -----------------)
	@awk '/^[a-zA-Z\-\_0-9]+:/ { \
		helpMessage = match(lastLine, /^## (.*)/); \
		helpCommand = substr($$1, 0, index($$1, ":")-1); \
		if (helpMessage) { \
			helpMessage = substr(lastLine, RSTART + 3, RLENGTH); \
			gsub(/##/, "\n                                     ", helpMessage); \
		} else { \
			helpMessage = "(No documentation)"; \
		} \
		printf "%-35s - %s\n", helpCommand, helpMessage; \
		lastLine = "" \
	} \
	{ hasComment = match(lastLine, /^## (.*)/); \
          if(hasComment) { \
            lastLine=lastLine$$0; \
	  } \
          else { \
	    lastLine = $$0 \
          } \
        }' $(MAKEFILE_LIST)

GOFORMAT_FILES := $(shell find  . -name '*.go' | grep -vEf .gofmt_exclude)

.PHONY: check-go-format
## Exists with an error if there are files whose formatting differs from gofmt's
check-go-format: prebuild-check
	@gofmt -s -l ${GOFORMAT_FILES} 2>&1 \
		| tee /tmp/gofmt-errors \
		| read \
	&& echo "ERROR: These files differ from gofmt's style (run 'make format-go-code' to fix this):" \
	&& cat /tmp/gofmt-errors \
	&& exit 1 \
	|| true

.PHONY: analyze-go-code
## Run a complete static code analysis using the following tools: golint, gocyclo and go-vet.
analyze-go-code: golint gocyclo govet

## Run gocyclo analysis over the code.
golint: $(GOLINT_BIN)
	$(info >>--- RESULTS: GOLINT CODE ANALYSIS ---<<)
	@$(foreach d,$(GOANALYSIS_DIRS),$(GOLINT_BIN) $d 2>&1 | grep -vEf .golint_exclude || true;)

## Run gocyclo analysis over the code.
gocyclo: $(GOCYCLO_BIN)
	$(info >>--- RESULTS: GOCYCLO CODE ANALYSIS ---<<)
	@$(foreach d,$(GOANALYSIS_DIRS),$(GOCYCLO_BIN) -over 10 $d | grep -vEf .golint_exclude || true;)

## Run go vet analysis over the code.
govet:
	$(info >>--- RESULTS: GO VET CODE ANALYSIS ---<<)
	@$(foreach d,$(GOANALYSIS_DIRS),go tool vet --all $d/*.go 2>&1;)

.PHONY: format-go-code
## Formats any go file that differs from gofmt's style
format-go-code: prebuild-check
	@gofmt -s -l -w ${GOFORMAT_FILES}

.PHONY: build
## Build server and client.
build: prebuild-check deps generate $(BINARY_SERVER_BIN) 

$(BINARY_SERVER_BIN): $(SOURCES)
ifeq ($(OS),Windows_NT)
	go build -v ${LDFLAGS} -o "$(shell cygpath --windows '$(BINARY_SERVER_BIN)')"
else
	go build -v ${LDFLAGS} -o ${BINARY_SERVER_BIN}
endif

# These are binary tools from our vendored packages
$(GOLINT_BIN):
	cd $(VENDOR_DIR)/github.com/golang/lint/golint && go build -v
$(GOCYCLO_BIN):
	cd $(VENDOR_DIR)/github.com/fzipp/gocyclo && go build -v
$(GOAGEN_BIN): $(VENDOR_DIR)
	cd $(VENDOR_DIR)/github.com/goadesign/goa/goagen && go build -v

CLEAN_TARGETS += clean-artifacts
.PHONY: clean-artifacts
## Removes the ./bin directory.
clean-artifacts:
	-rm -rf $(INSTALL_PREFIX)

CLEAN_TARGETS += clean-object-files
.PHONY: clean-object-files
## Runs go clean to remove any executables or other object files.
clean-object-files:
	go clean ./...

CLEAN_TARGETS += clean-generated
.PHONY: clean-generated
## Removes all generated code.
clean-generated:
	-rm -rf ./app
	-rm -rf ./client/
	-rm -rf ./swagger/
	-rm -rf ./tool/cli/
	-rm -f ./migration/sqlbindata.go
	-rm -f ./migration/sqlbindata_test.go
	-rm -rf ./account/tenant
	-rm -rf ./auth/authservice
	-rm -f ./spacetemplate/template_assets.go

CLEAN_TARGETS += clean-vendor
.PHONY: clean-vendor
## Removes the ./vendor directory.
clean-vendor:
	-rm -rf $(VENDOR_DIR)

.PHONY: deps
## Download build dependencies.
deps: $(DEP_BIN) $(VENDOR_DIR)

# install dep in a the tmp/bin dir of the repo
$(DEP_BIN): $(DEP_BIN_DIR) 
	@echo "Installing 'dep' $(DEP_VERSION) at '$(DEP_BIN_DIR)'..."
	mkdir -p $(DEP_BIN_DIR)
ifeq ($(UNAME_S),Darwin)
	@curl -L -s https://github.com/golang/dep/releases/download/$(DEP_VERSION)/dep-darwin-amd64 -o $(DEP_BIN) 
	@cd $(DEP_BIN_DIR) && \
	curl -L -s https://github.com/golang/dep/releases/download/$(DEP_VERSION)/dep-darwin-amd64.sha256 -o $(DEP_BIN_DIR)/dep-darwin-amd64.sha256 && \
	echo "1544afdd4d543574ef8eabed343d683f7211202a65380f8b32035d07ce0c45ef  dep" > dep-darwin-amd64.sha256 && \
	shasum -a 256 --check dep-darwin-amd64.sha256
else
	@curl -L -s https://github.com/golang/dep/releases/download/$(DEP_VERSION)/dep-linux-amd64 -o $(DEP_BIN)
	@cd $(DEP_BIN_DIR) && \
	echo "31144e465e52ffbc0035248a10ddea61a09bf28b00784fd3fdd9882c8cbb2315  dep" > dep-linux-amd64.sha256 && \
	sha256sum -c dep-linux-amd64.sha256
endif
	@chmod +x $(DEP_BIN)

$(VENDOR_DIR): Gopkg.toml Gopkg.lock
	@echo "checking dependencies with $(DEP_BIN_NAME)"
	@$(DEP_BIN) ensure -v 

app/controllers.go: $(DESIGNS) $(GOAGEN_BIN) $(VENDOR_DIR) vendor/github.com/fabric8-services/fabric8-common/goasupport/jsonapi_errors_stringer/generator.go 
	$(GOAGEN_BIN) app -d ${PACKAGE_NAME}/${DESIGN_DIR}
	$(GOAGEN_BIN) controller -d ${PACKAGE_NAME}/${DESIGN_DIR} -o controller/ --pkg controller --app-pkg ${PACKAGE_NAME}/app
	$(GOAGEN_BIN) gen -d ${PACKAGE_NAME}/${DESIGN_DIR} --pkg-path=github.com/fabric8-services/fabric8-common/goasupport/status --out app
	$(GOAGEN_BIN) gen -d ${PACKAGE_NAME}/${DESIGN_DIR} --pkg-path=github.com/fabric8-services/fabric8-common/goasupport/jsonapi_errors_stringer --out app
	$(GOAGEN_BIN) swagger -d ${PACKAGE_NAME}/${DESIGN_DIR}
	
.PHONY: generate
## Generate GOA sources. Only necessary after clean of if changed `design` folder.
generate: prebuild-check app/controllers.go

.PHONY: regenerate
## Runs the "clean-generated" and the "generate" target
regenerate: clean-generated generate

$(INSTALL_PREFIX):
# Build artifacts dir
	mkdir -p $(INSTALL_PREFIX)

$(TMP_PATH):
	mkdir -p $(TMP_PATH)

$(DEP_BIN_DIR):
	mkdir -p $(DEP_BIN_DIR)

.PHONY: show-info
show-info:
	$(call log-info,"$(shell go version)")
	$(call log-info,"$(shell go env)")

.PHONY: prebuild-check
prebuild-check: $(TMP_PATH) $(INSTALL_PREFIX) show-info
# Check that all tools where found
ifndef GIT_BIN
	$(error The "$(GIT_BIN_NAME)" executable could not be found in your PATH)
endif
ifndef DEP_BIN
	$(error The "$(DEP_BIN_NAME)" executable could not be found in your PATH)
endif

ifndef GO_BIN
	$(error The "$(GO_BIN_NAME)" executable could not be found in your PATH)
endif

# Keep this "clean" target here at the bottom
.PHONY: clean
## Runs all clean-* targets.
clean: $(CLEAN_TARGETS)
