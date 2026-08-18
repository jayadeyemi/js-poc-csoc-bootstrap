# Magnum cluster-template inventory

The `snapshots/` directory contains read-only captures of every Magnum cluster
template visible to the authenticated OpenStack project. Each snapshot contains
an `index.json` plus the complete `openstack coe cluster template show` result
for every template UUID.

Refresh the inventory from the management container with:

```bash
make magnum-templates
```

The command only calls Magnum list/show APIs. It does not create, update,
publish, hide, or delete templates. Snapshots are timestamped and an existing
snapshot is never overwritten.

## Who can add or manage templates?

Magnum distinguishes project-private templates from public cloud templates:

- A project **member** can create a cluster template under Magnum's default
  policy. Unless an administrator publishes it, that template is private to
  its owning project.
- A project **reader** can list and inspect templates visible to that project,
  including public templates and the project's own private templates.
- Only a cloud **administrator** can publish a template for all projects or
  hide a template. Cross-project list, update, and delete operations are also
  administrator-only.
- Project members can update or delete templates owned by their project under
  the default policy, subject to Magnum lifecycle restrictions. They do not
  own Jetstream2's public templates and must not modify them.
- Jetstream2's deployed policy is authoritative and can be stricter than the
  upstream default. A `403 Forbidden` means the authenticated role is not
  allowed to perform that operation; contact Jetstream2 support rather than
  attempting to bypass the policy.

References:

- [Jetstream2: Build a K8s cluster with Magnum](https://docs.jetstream-cloud.org/general/k8smagnum/)
- [Magnum policy configuration](https://docs.openstack.org/magnum/latest/configuration/sample-policy.html)
- [Magnum cluster-template API](https://docs.openstack.org/api-ref/container-infrastructure-management/#manage-cluster-templates)

## Current observation

The `2026-08-18T230443Z` snapshot was captured with cloud `openstack`. It
contains 11 visible templates: eight public Jetstream2 templates and three
private templates owned by the authenticated project. Visibility is not a
global cloud inventory; another project or an administrator may see a
different set.
