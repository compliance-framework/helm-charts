HELM_UNITTEST_VERSION ?= 0.7.0
HELM_SCHEMA_VERSION ?= 0.17.0
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
