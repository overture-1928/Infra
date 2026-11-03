# Neutron VM three-tier workload template

Create a stack through the repository wrapper:

```bash
./scripts/cluster.sh workload-new myapp three-tier-vm
```

This profile creates three Neutron networks and subnets, one Neutron router, tier-specific security
groups, soft anti-affinity server groups, Ceph-backed VMs and separate database data volumes. Its
security-group graph permits the configured ingress CIDRs to reach Web, Web to reach Application,
and Application to reach Database. This profile does not expose Floating IP inputs for any workload
VM; Octavia or the approved reverse proxy owns the public endpoint.

Edit the generated mode `0600` `terraform.tfvars` and keep `enable_resources = false` for the first
plan. The public reverse proxy or Octavia configuration and all guest software remain separate from
this Terraform root. Configure those through a stack-specific Ansible playbook only after reviewing
the Terraform outputs and generated inventory.

The root reuses `../../modules/openstack-vm`. VM boot volumes, database data volumes, Neutron
networks, subnets and router have lifecycle protection. Database replication, leader election,
schema migration and backups are application responsibilities; Ceph replication alone is not a
database backup.
