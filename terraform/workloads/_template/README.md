# Workload Terraform root template

Create a service-specific sibling directory through the repository wrapper. Each generated root
gets an independent Terraform state while reusing the durable VM module.

```bash
./scripts/cluster.sh workload-new example-service
```

The wrapper copies only its explicit template-file allowlist, creates `terraform.tfvars` with mode
`0600`, and pins the workload name to the directory name during planning. Local state, provider
caches, credentials and override files left below `_template` are not copied. The relative module
source in `main.tf` must remain `../../modules/openstack-vm`. Replace every placeholder in the local
variable file and review the first plan while `enable_instances = false`. Set the switch to `true`
only when the resulting create plan is ready. Follow `docs/terraform-workloads.md` for the full
workflow.

The VM and boot volume use `prevent_destroy`, and the boot volume sets
`delete_on_termination = false`. Removing an instance key or requesting replacement of either
resource therefore fails instead of deleting them. Ports, security groups and Floating IPs do not
have that lifecycle guard and must be checked separately in every plan. Automated decommissioning
is intentionally not provided; retire an instance only through a separately reviewed procedure for
that specific stack.
