HELM_UNITTEST_VERSION ?= 0.7.0
HELM_SCHEMA_VERSION ?= 2.3.0
CHART_DIR ?= charts/ccf-app

.PHONY: helm.install-plugins
helm.install-plugins:
	@echo "Installing helm plugins..."
	@if ! helm plugin list | grep -q unittest; then \
		echo "Installing helm-unittest $(HELM_UNITTEST_VERSION)..."; \
		helm plugin install https://github.com/helm-unittest/helm-unittest --version $(HELM_UNITTEST_VERSION); \
	else \
		echo "helm-unittest already installed"; \
	fi
	@if ! helm plugin list | grep -q schema; then \
		echo "Installing helm-schema $(HELM_SCHEMA_VERSION)..."; \
		helm plugin install https://github.com/losisin/helm-values-schema-json --version $(HELM_SCHEMA_VERSION); \
	else \
		echo "helm-schema already installed"; \
	fi

.PHONY: helm.test
helm.test: helm.install-plugins
	@echo "Running helm unittest..."
	helm unittest $(CHART_DIR)

.PHONY: helm.schema
helm.schema: helm.install-plugins
	@echo "Generating helm schema..."
	helm schema --values $(CHART_DIR)/values.yaml --output $(CHART_DIR)/values.schema.json

# helm.schema.check: fails if CHART_DIR's values.schema.json differs from the one generated from
# its values.yaml. It writes to a temporary directory, so it never changes the working tree.
.PHONY: helm.schema.check
helm.schema.check: helm.install-plugins
	@echo "Checking $(CHART_DIR)/values.schema.json is up to date..."
	@tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	if ! helm schema --values $(CHART_DIR)/values.yaml --output "$$tmp/values.schema.json"; then \
		echo "Error: helm schema failed for $(CHART_DIR)/values.yaml."; \
		exit 1; \
	fi; \
	if ! diff -u $(CHART_DIR)/values.schema.json "$$tmp/values.schema.json"; then \
		echo "Error: $(CHART_DIR)/values.schema.json is out of date. Run 'make helm.schema CHART_DIR=$(CHART_DIR)' and commit it."; \
		exit 1; \
	fi

# CCF App chart targets
# helm.test.app runs every ccf-app check CI runs (ci.yml make-targets): unit tests, the schema
# drift check and the agent bootstrap script test (needs docker).
.PHONY: helm.test.app
helm.test.app: helm.install-plugins
	@echo "Running helm unittest for ccf-app..."
	helm unittest charts/ccf-app
	$(MAKE) --no-print-directory helm.schema.check CHART_DIR=charts/ccf-app
	ci/agent-bootstrap/run.sh

.PHONY: check-diff
check-diff:
	@echo "Checking for uncommitted changes..."
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "Error: Uncommitted changes detected after running build steps:"; \
		git status; \
		echo "Please run 'make helm.schema' and commit the changes."; \
		exit 1; \
	else \
		echo "No changes detected."; \
	fi

# CCF Agent chart targets
# helm.test.agent runs every ccf-agent check CI runs (ci.yml make-targets): unit tests and the
# schema drift check.
.PHONY: helm.test.agent
helm.test.agent: helm.install-plugins
	@echo "Running helm unittest for ccf-agent..."
	helm unittest charts/ccf-agent
	$(MAKE) --no-print-directory helm.schema.check CHART_DIR=charts/ccf-agent

.PHONY: helm.schema.agent
helm.schema.agent: helm.install-plugins
	@echo "Generating helm schema for ccf-agent..."
	helm schema --values charts/ccf-agent/values.yaml --output charts/ccf-agent/values.schema.json

.PHONY: helm.agent
helm.agent: helm.schema.agent helm.test.agent
	@echo "CCF Agent chart validated successfully"
