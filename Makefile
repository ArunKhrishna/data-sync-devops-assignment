CHART := helm/charts/data-sync
RELEASE := data-sync
NAMESPACE := data-sync

.PHONY: validate helm-lint helm-template kustomize ansible-lint

## Run every static check
validate: helm-lint helm-template kustomize ansible-lint

## Lint the chart three times: its own defaults, then each shipped env override file
helm-lint:
	helm lint --strict $(CHART)
	helm lint --strict $(CHART) -f $(CHART)/values.staging.yaml
	helm lint --strict $(CHART) -f $(CHART)/values.production.yaml
	@echo "helm lint OK for default, staging and production"

## Render the chart the same three ways, to catch anything lint misses
helm-template:
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) > /dev/null
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) -f $(CHART)/values.staging.yaml > /dev/null
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) -f $(CHART)/values.production.yaml > /dev/null
	@echo "helm template OK for default, staging and production"

## Build the production Kustomize overlay and check it against the raw chart output
kustomize:
	./scripts/verify-kustomize.sh
	@echo "kustomize overlay OK"

## Lint the Ansible role and syntax-check the playbook
ansible-lint:
	cd ansible && ansible-lint
	cd ansible && ansible-playbook playbooks/playbook-data-sync.yml --syntax-check
	@echo "ansible-lint OK"
