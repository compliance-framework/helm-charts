# helm-charts

A set of Helm charts for CCF.

## Values files

`values-local.yaml` - an example values file for local k8s clusters

## Platform-specific notes

### KIND
Use port-forwarding to access services.

## Gotchas

### Postgres DB password
When helm is first run, it uses the dynamically-generated password that's stored in k8s secret.

A `helm uninstall` may not get rid of the underlying password after first creation, so be aware that if you re-run, postgres may re-use the old value even if a new one is generated. This can be true even if the PV is deleted.

A simple workaround is to set the password value in your values file.

#### Posgres DB password - KIND
When running in KIND, the postgres folder is not removed from the KIND node container running on the host, and the password is reused. Either destroy the kind cluster, or delete the `/var/lib/ccf-postgresql` folder on the kind container before reinstalling the helm chart.

