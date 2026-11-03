SHELL := /usr/bin/env bash
TERRAFORM := $(if $(wildcard .cache/terraform/bin/terraform),.cache/terraform/bin/terraform,terraform)

.PHONY: check fmt host-syntax terraform-init terraform-plan

check:
	./scripts/internal/check-openstack-repository.sh

fmt:
	$(TERRAFORM) -chdir=terraform fmt -recursive

host-syntax:
	ANSIBLE_LOCAL_TEMP=/tmp/infra-openstack-ansible \
		ansible-playbook -i ansible/inventory/openstack-three-node.yml \
		ansible/playbooks/prepare-openstack-host.yml --syntax-check

terraform-init:
	$(TERRAFORM) -chdir=terraform/openstack init

terraform-plan:
	$(TERRAFORM) -chdir=terraform/openstack plan
