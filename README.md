# helm-charts

A set of Helm charts for CCF.

## Values files

`values-local.yaml` - an example values file for local k8s clusters

## Platform-specific notes

### KIND
Use port-forwarding to access services.


## Deployment Setup for a New Client
Here are some deployment issues we've run into in the past when deploying this helm chart for clients

### Permission-granting from the client side
If the argocd instance is relatively locked down to us, then specific permissions need to be granted to our ccf user group in the `containersolutions` organisation in GitHub.
One way you can speed this up is to add their user to our org, so they can see which permissions need to be set to deploy to their argocd instance with the right levels of access.
Those permissions can then be applied to our users, and we can proceed to deploy. Then we can remove their user from our org.

```
kubectl exec -n argocd deployment/argocd-server -- argocd admin settings rbac can 'ContainerSolutions:ccf' create applications 'ccf/*' --namespace argocd
Yes
```

### Wildcards and group permissions
"looking at the argo policy I used a wildcard but that doesn't seem to work, you need the actual [GitHub] group name [for the CS organisation]"

### PV
We may need permissions added to create PVs on their cluster. We have used EBS in the past.

### Ingress
Ingress may vary in different contexts.



## Helm Chart Gotchas

### Postgres DB password
When helm is first run, it uses the dynamically-generated password that's stored in k8s secret.

A `helm uninstall` may not get rid of the underlying password after first creation, so be aware that if you re-run, postgres may re-use the old value even if a new one is generated. This can be true even if the PV is deleted.

A simple workaround is to set the password value in your values file.

#### Postgres DB password - KIND
When running in KIND, the postgres folder is not removed from the KIND node container running on the host, and the password is reused. Either destroy the kind cluster, or delete the `/var/lib/ccf-postgresql` folder on the kind container before reinstalling the helm chart.

