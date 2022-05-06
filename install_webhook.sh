#!/bin/bash

source mas.properties

groupname=horfee.fr
ovh_app_key=FGFZYoIzFnEhQrvs
ovh_app_secret=AatvdgP4ZzlnBfq784uTStoZqSKLDPP2
ovh_consumer_key=pCIG56LqYtGYS5QojDG8CEsHdosh5W3r
email='jean-philippe.alexandre@fr.ibm.com'

cd tmp
rm -rf cert-manager-webhook-ovh
git clone https://github.com/horfee/cert-manager-webhook-ovh.git
cd cert-manager-webhook-ovh

oc project $1

echo "Waiting for 30s for cert-manager to be ready"
sleep 30
echo "Helm install cert-manager-webhook-ovh"
helm install cert-manager-webhook-ovh ./deploy/cert-manager-webhook-ovh --set groupName="${groupname}"

cd ../
rm -rf cert-manager-webhook-ovh

kubectl create secret generic ovh-credentials --from-literal=applicationSecret="${ovh_app_secret}"

cat << EOF > ./ovh_webhook_permissions.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cert-manager-webhook-ovh:secret-reader
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["ovh-credentials"]
  verbs: ["get", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cert-manager-webhook-ovh:secret-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: cert-manager-webhook-ovh:secret-reader
subjects:
- apiGroup: ""
  kind: ServiceAccount
  name: cert-manager-webhook-ovh
EOF

oc apply -f ./ovh_webhook_permissions.yaml

cat << EOF > ./ovh_issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${clusterissuer}
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${email}"
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
    - dns01:
        webhook:
          groupName: "${groupname}"
          solverName: ovh
          config:
            endpoint: ovh-eu
            applicationKey: "${ovh_app_key}"
            applicationSecretRef:
              key: applicationSecret
              name: ovh-credentials
            consumerKey: "${ovh_consumer_key}"
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${clusterissuer}-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: "${email}"
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
    - dns01:
        webhook:
          groupName: "${groupname}"
          solverName: ovh
          config:
            endpoint: ovh-eu
            applicationKey: "${ovh_app_key}"
            applicationSecretRef:
              key: applicationSecret
              name: ovh-credentials
            consumerKey: "${ovh_consumer_key}"
EOF

oc apply -f ./ovh_issuer.yaml

