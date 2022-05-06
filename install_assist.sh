#!/bin/bash


############################################
############ Beginning the work ############
############################################
source mas-script-functions.bash
source masassist.properties


echo_h1 "Deploying CP4D"
oc project "${cp4dnamespace}" > /dev/null 2>&1
if [[ "$?" == "1" ]]; then
  oc new-project "${cp4dnamespace}" --display-name "Cloud Pak For Data" > /dev/null 2>&1
fi

rm -rf tmp_assist
mkdir tmp_assist

domain=$(oc get Ingress.config cluster -o jsonpath='{.spec.domain}')

# Fetch client installer from https://github.com/IBM/cpd-cli/releases according to your system
echo -n "	Fetching CP4D install command line..."
cd tmp_assist
mkdir cp4d

cpdcli_version=3.5.7
if [[ "$OSTYPE" == "darwin"* ]]; then
  curl -s -L -o cpd-cli-EE-${cpdcli_version}.tgz https://github.com/IBM/cpd-cli/releases/download/v${cpdcli_version}/cpd-cli-darwin-EE-${cpdcli_version}.tgz
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
  curl -s -L -o cpd-cli-EE-${cpdcli_version}.tgz https://github.com/IBM/cpd-cli/releases/download/v${cpdcli_version}/cpd-cli-linux-EE-${cpdcli_version}.tgz
fi
tar zxf cpd-cli-EE-${cpdcli_version}.tgz -C ./cp4d
echo "${COLOR_GREEN}Done${COLOR_RESET}"


if [[ "$cp4dtransfertimages" == "true" ]]; then
  echo -n "	Creating registry route..."
  #ATTENTION : if you are not a the bastion node, you will have to create a route for registry
  oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge > /dev/null 1>&1
fi;

# cat << EOF > create_registry_route.yaml
# kind: Route
# apiVersion: route.openshift.io/v1
# metadata:
#   name: registry
#   namespace: openshift-image-registry
# spec:
#   host: registry-openshift-image-registry.${domain}
#   to:
#     kind: Service
#     name: image-registry
#   weight: 100
#   port:
#     targetPort: 5000-tcp
#   tls:
#     termination: passthrough
#     insecureEdgeTerminationPolicy: None
#   wildcardPolicy: None
# EOF

# oc apply -f create_registry_route.yaml > /dev/null 1>&1
echo "${COLOR_GREEN}Done${COLOR_RESET}"

cd cp4d
cat << EOF >> repo.yaml
  - url: cp.icr.io
    username: cp
    apikey: <enter_api_key>
    namespace: cp
    name: prod-entitled-registry
  - url: cp.icr.io
    username: cp
    apikey: <enter_api_key>
    namespace: cp
    name: entitled-registry
  - url: cp.icr.io
    username: cp
    apikey: <enter_api_key>
    namespace: cp/cpd
    name: databases-registry
  - url: cp.icr.io
    username: cp
    apikey: <enter_api_key>
    namespace: cp/modeltrain
    name: modeltrain-classic-registry
  - url: cp.icr.io
    username: cp
    apikey: <enter_api_key>
    namespace: cp/watson-discovery
    name: watson-discovery-registry
EOF

if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i "" "s/<enter_api_key>/${ER_KEY}/g" repo.yaml
else
    sed -i "s/<enter_api_key>/${ER_KEY}/g" repo.yaml
fi

if [[ "$cp4denv_is_prod" == "true" ]]; then

cat << EOF > discovery-override.yaml
wdRelease:
  deploymentType: Production
  enableContentIntelligence: false
  
  etcd:
    storageSize: 15Gi

  postgres:
    database:
      storageRequest: 50Gi
EOF

else

cat << EOF > discovery-override.yaml
wdRelease:
  deploymentType: Development
EOF

fi

echo "	Need to deploy CP4D services : lite,edb-operator,watson_discovery"
echo " 	Deploying CP4D lite assembly..."

./cpd-cli adm \
    --assembly lite \
    --namespace ${cp4dnamespace} \
    --repo ./repo.yaml \
    --apply \
    --accept-all-licenses

if [[ "$?" != 0 ]]; then
    echo "Error doing adm operation for lite assembly. I must stop."
    exit 1
fi

if [[ "$cp4dtransfertimages" == "true" ]]; then
  ./cpd-cli install \
    --assembly lite \
    --namespace ${cp4dnamespace} \
    --repo ./repo.yaml \
    --storageclass ${cp4dstorageclass} \
    --target-registry-username=$(oc whoami) \
    --target-registry-password=$(oc whoami -t) \
    --insecure-skip-tls-verify \
    --transfer-image-to=default-route-openshift-image-registry.${domain}/${cp4dnamespace} \
    --cluster-pull-prefix $(oc registry info --internal)/${cp4dnamespace} \
    --latest-dependency \
    --accept-all-licenses

else

  ./cpd-cli install \
    --assembly lite \
    --namespace ${cp4dnamespace} \
    --repo ./repo.yaml \
    --storageclass ${cp4dstorageclass} \
    --latest-dependency \
    --accept-all-licenses
fi

if [[ "$?" != 0 ]]; then
    echo "Error installing lite. I must stop."
    exit 1
fi

echo " 	Deploying CP4D watson-discovery assemblies..."

./cpd-cli adm \
  --assembly watson-discovery \
  --repo ./repo.yaml \
  --namespace ${cp4dnamespace} \
  –-apply \
  --accept-all-licenses

if [[ "$?" != 0 ]]; then
    echo "Error doing adm operation on watson-discovery. I must stop."
    exit 1
fi

echo " 	Deploying CP4D ebd-operator assembly..."

if [[ "$cp4dtransfertimages" == "true" ]]; then
#./cpd-cli install --assembly edb-operator --optional-modules edb-pg-base:x86_64 --namespace ${cp4dnamespace} --repo repo.yaml --cluster-pull-prefix $(oc registry info --internal)/${cp4dnamespace} --insecure-skip-tls-verify --storageclass $cp4dstorageclass --target-registry-username=$(oc whoami) --target-registry-password=$(oc whoami -t) --latest-dependency --accept-all-licenses
  ./cpd-cli install \
    --assembly edb-operator \
    --optional-modules edb-pg-base:x86_64 \
    --namespace ${cp4dnamespace} \
    --repo repo.yaml \
    --storageclass ${cp4dstorageclass} \
    --target-registry-username=$(oc whoami) \
    --target-registry-password=$(oc whoami -t) \
    --insecure-skip-tls-verify \
    --transfer-image-to=default-route-openshift-image-registry.${domain}/${cp4dnamespace} \
    --cluster-pull-prefix $(oc registry info --internal)/${cp4dnamespace} \
    --latest-dependency \
    --accept-all-licenses

else

  ./cpd-cli install  \
    --assembly edb-operator \
    --optional-modules edb-pg-base:x86_64 \
    --namespace ${cp4dnamespace} \
    --repo repo.yaml \
    --storageclass ${cp4dstorageclass} \
    --latest-dependency \
    --accept-all-licenses

fi

if [[ "$?" != 0 ]]; then
    echo "Error installing edb-operator. I must stop."
    exit 1
fi

echo " 	Deploying CP4D watson-discovery assembly..."

if [[ "$cp4dtransfertimages" == "true" ]]; then

  ./cpd-cli install \
    --assembly watson-discovery \
    --namespace ${cp4dnamespace} \
    --repo repo.yaml \
    --storageclass ${cp4dstorageclass} \
    --override discovery-override.yaml \
    --target-registry-username=$(oc whoami) \
    --target-registry-password=$(oc whoami -t) \
    --insecure-skip-tls-verify \
    --transfer-image-to=default-route-openshift-image-registry.${domain}/${cp4dnamespace} \
    --cluster-pull-prefix $(oc registry info --internal)/${cp4dnamespace} \
    --latest-dependency \
    --accept-all-licenses

else

  ./cpd-cli install \
    --assembly watson-discovery \
    --namespace ${cp4dnamespace} \
    --storageclass ${cp4dstorageclass} \
    --override discovery-override.yaml \
    --repo repo.yaml \
    --latest-dependency \
    --accept-all-licenses

fi

if [[ "$?" != 0 ]]; then
    echo "Error installing watson-discovery. I must stop."
    exit 1
fi

echo "${COLOR_GREEN}Done${COLOR_RESET}"

exit 0

cd ../


cat << EOF > mas_cos_config.yaml
apiVersion: config.mas.ibm.com/v1
kind: ObjectStorageCfg
metadata:
  name: ${instanceid}-objectstorage-system
  namespace: mas-${instanceid}-core
  labels:
    mas.ibm.com/configScope: system
    mas.ibm.com/instanceId: ${instanceid}
spec:
  config:
    credentials:
      secretName: ${instanceid}-usersupplied-objectstorage-creds-system
    url: ${assist_cos_url}
  displayName: COS url
  type: external
EOF
oc apply -f mas_operatorgroup.yaml > /dev/null 2>&1
echo -e "${COLOR_GREEN}Done${COLOR_RESET}"


#TODO 
#create mas-${instanceid}-assist project
oc new-project "mas-${instanceid}-assist" --display-name "Cloud Pak For Data" > /dev/null 2>&1

namespace=$(oc config view --minify -o 'jsonpath={..namespace}')

cat << EOF > mas_operatorgroup.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ibm-mas-operatorgroup
  namespace: ${namespace}
spec:
  targetNamespaces:
    - ${namespace}
EOF

oc apply -f mas_operatorgroup.yaml > /dev/null 2>&1
echo "	Operator group created"

# install couchdb operator
cat << EOF > couchdb_operator.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: couchdb-operator-certified
  namespace: mas-${instanceid}-assist
  labels:
    operators.coreos.com/couchdb-operator-certified.mas-${instanceid}-assist: ''
spec:
  channel: v1.4
  installPlanApproval: Automatic
  name: couchdb-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
EOF

oc apply -f couchdb_operator.yaml > /dev/null 2>&1
echo "	CouchDB Operator created"

while [[ $(oc get Subscription couchdb-operator-certified -n ${namespace} --ignore-not-found=true -o jsonpath='{.status.state}') != "UpgradePending" ]];do sleep 5; done & 
showWorking $!
printf '\b'

echo "	Approving manual installation"
# Find install plan
installplan=$(oc get subscription couchdb-operator-certified -o jsonpath="{.status.installplan.name}" -n ${namespace})
echo "	installplan: $installplan"

# Approve install plan
oc patch installplan ${installplan} -n ${namespace} --type merge --patch '{"spec":{"approved":true}}' > /dev/null 2>&1

echo -n "	Operator ready              "
while [[ $(oc get deployment/couchdb-operator --ignore-not-found=true -o jsonpath='{.status.readyReplicas}' -n ${namespace}) != "1" ]];do sleep 5; done & 
showWorking $!
printf '\b'
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"

#create service bindings ${instanceid}-coreidp-binding ${instanceid}-suite-binding
cat << EOF > servicebindings.yaml
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-coreidp-binding
  namespace: mas-${instanceid}-assist
  labels:
    mas.ibm.com/applicationId: assist
    mas.ibm.com/instanceId: ${instanceid}
spec:
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: internal.mas.ibm.com
      kind: CoreIDP
      name: ${instanceid}-coreidp
      namespace: mas-${instanceid}-core
      version: v1
---
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-objectstorage-binding
  namespace: mas-${instanceid}-assist
  labels:
    mas.ibm.com/applicationId: assist
    mas.ibm.com/instanceId: ${instanceid}
spec:
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: config.mas.ibm.com
      kind: ObjectStorageCfg
      name: ${instanceid}-objectstorage-system
      namespace: mas-${instanceid}-core
      version: v1
---
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-suite-binding
  namespace: mas-${instanceid}-assist
  labels:
    mas.ibm.com/applicationId: assist
    mas.ibm.com/instanceId: ${instanceid}
spec:
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: core.mas.ibm.com
      kind: Suite
      name: ${instanceid}
      namespace: mas-${instanceid}-core
      version: v1
EOF
oc apply -f servicebindings.yaml > /dev/null 2>&1
echo -e "${COLOR_GREEN}Done${COLOR_RESET}"

cat << EOF > assist_operator.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-mas-assist
  namespace: ${namespace}
spec:
  channel: 8.3.x
  installPlanApproval: Manual
  name: ibm-mas-assist
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF

oc apply -f assist_operator.yaml > /dev/null 2>&1
echo "	Assist Operator created"

while [[ $(oc get Subscription ibm-mas-assist -n ${namespace} --ignore-not-found=true -o jsonpath='{.status.state}') != "UpgradePending" ]];do sleep 5; done & 
showWorking $!
printf '\b'

echo "	Approving manual installation"
# Find install plan
installplan=$(oc get subscription ibm-mas-assist -o jsonpath="{.status.installplan.name}" -n ${namespace})
echo "	installplan: $installplan"

# Approve install plan
oc patch installplan ${installplan} -n ${namespace} --type merge --patch '{"spec":{"approved":true}}' > /dev/null 2>&1

echo -n "	Operator ready              "
while [[ $(oc get deployment/ibm-mas-assist-operator --ignore-not-found=true -o jsonpath='{.status.readyReplicas}' -n ${namespace}) != "1" ]];do sleep 5; done & 
showWorking $!
printf '\b'
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"

# create AssistApp
cat << EOF > assist_app.yaml
apiVersion: apps.mas.ibm.com/v1
kind: AssistApp
metadata:
  name: ${workspaceid}
  namespace: mas-${instanceid}-assist
  labels:
    mas.ibm.com/applicationId: assist
    mas.ibm.com/instanceId: ${instanceid}
spec:
  bindings:
    objectstorage: system
  components: {}
EOF

oc apply -f assist_app.yaml > /dev/null 2>&1
echo -e "${COLOR_GREEN}Done${COLOR_RESET}"

# create CouchDBCluster
cat << EOF > couchdbcluster.yaml
apiVersion: couchdb.databases.cloud.ibm.com/v1
kind: CouchDBCluster
metadata:
  name: ${instanceid}-assist-couchdb
  namespace: mas-${instanceid}-assist
  labels:
    app.kubernetes.io/component: couchdb
    app.kubernetes.io/instance: ${instanceid}
    app.kubernetes.io/managed-by: ibm-mas-assist-operator
    app.kubernetes.io/name: ibm-mas-assist
    mas.ibm.com/applicationId: assist
    mas.ibm.com/instanceId: ${instanceid}
spec:
  disk: 30Gi
  environment:
    adminPassword: AZPrQKkGgzMRCaQ
  resources:
    db:
      limits:
        cpu: '2'
        memory: 2Gi
      requests:
        cpu: '0.5'
        memory: 576Mi
    mgmt:
      equests:
        cpu: '0.5'
        memory: 576Mi
      limits:
        cpu: '2'
        memory: 2Gi
  size: 3
  storageClass: ${couchdb_storageclass}
EOF

oc apply -f couchdbcluster.yaml > /dev/null 2>&1
echo -e "${COLOR_GREEN}Done${COLOR_RESET}"

