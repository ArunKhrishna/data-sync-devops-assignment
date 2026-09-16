CHART := helm/charts/data-sync
RELEASE := data-sync
NAMESPACE := data-sync

.PHONY: validate helm-lint helm-template kustomize ansible-lint

## Run every static check
validate: helm-lint helm-template kustomize ansible-lint

helm-lint:
	helm lint --strict $(CHART)
	helm lint --strict $(CHART) -f $(CHART)/values.staging.yaml
	helm lint --strict $(CHART) -f $(CHART)/values.production.yaml

helm-template:
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) > /dev/null
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) -f $(CHART)/values.staging.yaml > /dev/null
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) -f $(CHART)/values.production.yaml > /dev/null
	@echo "helm template OK for default, staging and production"

kustomize:
	./scripts/verify-kustomize.sh

ansible-lint:
	cd ansible && ansible-lint
	cd ansible && ansible-playbook playbooks/playbook-data-sync.yml --syntax-check
