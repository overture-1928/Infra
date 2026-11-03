# Managed Kubernetes three-tier policy example

`network-policies.example.yml` is a copy-and-edit example for a workload Kubernetes cluster created
through Magnum/CAPI. It is not applied by the OpenStack platform automation.

Before applying a derived file, replace the namespace, ingress-controller namespace and label,
container ports, database peer ports and every application label. Confirm that the workload
cluster's CNI enforces Kubernetes NetworkPolicy and that its DNS Pods are reachable through the
selected kube-system rule. Add narrowly scoped egress policies for required external APIs and
package endpoints.

The example expects these Pod labels:

```yaml
app.kubernetes.io/tier: web
app.kubernetes.io/tier: application
app.kubernetes.io/tier: database
```

Keep rendered application manifests, Helm values and credentials in the application's own
repository. This infrastructure repository records the OpenStack integration and reference policy,
not a specific application's images or secrets.
