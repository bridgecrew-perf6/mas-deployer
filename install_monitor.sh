#!/bin/bash


############################################
############ Beginning the work ############
############################################
source mas-script-functions.bash
source mas.properties
source masmonitor.properties

namespace=ibm-common-services

echo_h1 "Deploying CP4D"

oc project "${namespace}" > /dev/null 2>&1
if [[ "$?" == "1" ]]; then
  oc new-project "${namespace}" --display-name "IBM Common Services" > /dev/null 2>&1
fi

domain=$(oc get Ingress.config cluster -o jsonpath='{.spec.domain}')

mkdir -p tmp_monitor

if [[ "$(oc get OperatorGroup -n ${namespace} --no-headers --ignore-not-found)" == "" ]]; then

  echo "Need to create operator group"
cat << EOF > tmp_monitor/operatorgroup.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ibm-common-services-operatorgroup
  namespace: ${namespace}
spec:
  targetNamespaces:
    - ${namespace}
EOF

  oc apply -f tmp_monitor/operatorgroup.yaml > /dev/null 2>&1
  echo "${COLOR_GREEN}Done${COLOR_RESET}"

fi;

echo_h2 "Registering IBM entitlement"
REGISTRY_SERVER=cp.icr.io
REGISTRY_USER=cp
REGISTRY_PASSWORD=${ER_KEY}
oc create secret docker-registry ibm-entitlement --docker-server=${REGISTRY_SERVER} --docker-username=${REGISTRY_USER} --docker-password=${REGISTRY_PASSWORD} --docker-email=${REGISTRY_USER} -n ${namespace} > /dev/null 2>&1
oc patch -n ${namespace} serviceaccount/default --type='json' -p='[{"op":"add","path":"/imagePullSecrets/-","value":{"name":"ibm-entitlement"}}]' > /dev/null 2>&1
echo "${COLOR_GREEN}Done${COLOR_RESET}"

echo_h2 "Creating catalog sources"
cat <<EOF > tmp_monitor/catalogsource.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-operator-catalog
  namespace: openshift-marketplace
spec:
  displayName: "IBM Operator Catalog" 
  publisher: IBM
  sourceType: grpc
  image: icr.io/cpopen/ibm-operator-catalog:latest
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
oc apply -f tmp_monitor/catalogsource.yaml > /dev/null 2>&1

while [[ "$(oc get catalogsource -n openshift-marketplace ibm-operator-catalog -o jsonpath='{.status.connectionState.lastObservedState}')" != "READY" ]]; do sleep 5; done &
showWorking $!

printf '\b'
echo "${COLOR_GREEN}Done${COLOR_RESET}"




# oc extract secret/pull-secret -n openshift-config --to=- > tmp_monitor/dockerconfig.json
# REGISTRY_SERVER=cp.icr.io
# REGISTRY_USER=cp
# REGISTRY_PASSWORD=${ER_KEY}
# if [[ "$(cat tmp_monitor/dockerconfig.json | grep auths | wc -l | tr -d \"[:blank:]\")" == "0"]]; then
#   oc create secret docker-registry --docker-server=${REGISTRY_SERVER} --docker-username=${REGISTRY_USER} --docker-password=${REGISTRY_PASSWORD} --docker-email=${REGISTRY_USER} -n openshift-config pull-secret > /dev/null 2>&1
# else
#   oc create secret docker-registry tmp --docker-server=${REGISTRY_SERVER} --docker-username=${REGISTRY_USER} --docker-password=${REGISTRY_PASSWORD} --docker-email=${REGISTRY_USER} --dry-run=client --output="jsonpath={.data.\.dockerconfigjson}" | base64 --decode > tmp_monitor/newreg.json
#   jq -s '.[0] * .[1]' tmp_monitor/dockerconfig.json tmp_monitor/newreg.json > tmp_monitor/dockerconfigjson-merged
#   oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=tmp_monitor/dockerconfigjson-merged > /dev/null 2>&1
# fi;

# clusterID=c95e29if0bkl0dcjhml0
# worknodes=$(ibmcloud oc worker ls   -c ${clusterID} -q | awk '{print $1}' | tr '\n' ' ')


# for worker in `oc get nodes --no-headers | awk '{print $1}'`; do
#   echo "Reloading $worker"
#   rebootnode $worker
# done


# while [[ $() *==* ""]]; do sleep 5;done & 
# showWorking$!
# printf '\b'
# echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"

echo_h2 "Deploying Cloud Pak Foundational Services..."
operatorname=$(oc get csv -n ${namespace} --no-headers --ignore-not-found | grep ibm-common-service-operator | awk '{print $1}')

if [[ "${operatorname}" == "" ]]; then
  cat <<EOF > tmp_monitor/cp4d_foundational.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-common-service-operator
  namespace: ${namespace}
spec:
  channel: v3
  installPlanApproval: Automatic
  name: ibm-common-service-operator
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF

  oc apply -f tmp_monitor/cp4d_foundational.yaml > /dev/null 2>&1
fi

while [[ "$(oc get csv -n ${namespace} --no-headers --ignore-not-found | grep ibm-common-service-operator | awk '{print $1}')" == "" ]]
do
  sleep 1
  operatorname=$(oc get csv -n ${namespace} --no-headers --ignore-not-found | grep ibm-common-service-operator | awk '{print $1}')
done

while [[ "$(oc get csv -n ${namespace} ${operatorname} -o jsonpath='{.status.phase}')" != "Succeeded" ]]; do sleep 5; done &
showWorking $!

printf '\b'
echo "${COLOR_GREEN}Done${COLOR_RESET}"

echo_h2 "Deploying IBM license service"

cat << EOF > tmp_monitor/licenservice.yaml
apiVersion: operator.ibm.com/v1alpha1
kind: OperandRequest
metadata:
  name: common-service-license
  namespace: ${namespace}
spec:
  requests:
  - operands:
      - name: ibm-licensing-operator
        bindings:
          public-api-upload:
            secret: ibm-licensing-upload-token
            configmap: ibm-licensing-upload-config
    registry: common-service
    registryNamespace: ${namespace}
EOF

oc apply -f tmp_monitor/licenservice.yaml > /dev/null 2>&1

while [[ "$(oc get pod -n ${namespace} -l app.kubernetes.io/name=ibm-licensing --ignore-not-found -o jsonpath='{.items[0].status.phase}')" != "Running" ]]; do sleep 5; done &
showWorking $!

printf '\b'
echo "${COLOR_GREEN}Done${COLOR_RESET}"


echo_h2 "Deploying CP4D Scheduling service..."

echo -n "Creating scheduling service operator..."
cat <<EOF > tmp_monitor/schedulingservice.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-cpd-scheduling-catalog-subscription
  namespace: ${namespace}
spec:
  channel: v1.3
  installPlanApproval: Automatic
  name: ibm-cpd-scheduling-operator
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF

oc apply -f tmp_monitor/schedulingservice.yaml > /dev/null 2>&1

while [[ $(oc get ClusterServiceVersion -n ${namespace} --no-headers --ignore-not-found | grep ibm-cpd-scheduling-operator | awk '{printf $1}') == "" ]];do sleep 1; done & showWorking $!
printf '\b'

operatorname=$(oc get sub -n ${namespace} ibm-cpd-scheduling-catalog-subscription -o jsonpath='{.status.installedCSV}')
#oc get csv -n ibm-common-services ${operatorname} -o jsonpath='{ .status.phase } : { .status.message}

while [[ "$(oc get csv -n ${namespace} ${operatorname} -o jsonpath='{.status.phase}')" != "Succeeded" ]]; do sleep 5; done &
showWorking $!

printf '\b'
echo "${COLOR_GREEN}Done${COLOR_RESET}"

echo -n "Creating scheduling service instance..."

cat <<EOF > tmp_monitor/scheduler.yaml
apiVersion: scheduler.spectrumcomputing.ibm.com/v1
kind: Scheduling
metadata:
  labels:
    release: cpd-scheduler
  name: ibm-cpd-scheduler
  namespace: ${namespace}
spec:
  version: 1.3.3
  license:
    accept: true
  registry: cp.icr.io/cp/cpd
  releasename: ibm-cpd-scheduler
EOF
oc apply -f tmp_monitor/scheduler.yaml > /dev/null 2>&1
while [[ $(oc get scheduling -n ${namespace} -o jsonpath='{.items[0].status.cpd-schedulingStatus}') != "Completed" ]]; do sleep 5; done &
showWorking $!

printf '\b'
echo "${COLOR_GREEN}Done${COLOR_RESET}"

echo_h2 "Patch CP4D scopying..."
oc patch NamespaceScope common-service -n ${namespace} --type=merge --patch='{"spec": {"csvInjector": {"enable": true} } }' > /dev/null 2>&1
echo "${COLOR_GREEN}Done${COLOR_RESET}"


echo_h2 "Deploying CP4D platform operator..."

echo -n "Creating platform operator..."
cat <<EOF > tmp_monitor/cp4d_platform.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cpd-operator
  namespace: ${namespace}
spec:
  channel: v2.0
  installPlanApproval: Automatic
  name: cpd-platform-operator
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF

oc apply -f tmp_monitor/cp4d_platform.yaml > /dev/null 2>&1


while [[ $(oc get sub -n ${namespace} cpd-operator -o jsonpath='{.status.installedCSV}') == "" ]];do sleep 1; done & showWorking $!
printf '\b'

operatorname=$(oc get sub -n ${namespace} cpd-operator -o jsonpath='{.status.installedCSV}')
while [[ "$(oc get deployments -n ${namespace} -l olm.owner=${operatorname} --ignore-not-found -o jsonpath='{.items[0].status.availableReplicas}')" != "1" ]]; do sleep 5; done &
showWorking $!

printf '\b'
echo "${COLOR_GREEN}Done${COLOR_RESET}"


echo -n "Creating platform instance..."

if [[ "${cp4dstoragevendor}" == "ocs" ]] || [[ "${cp4dstoragevendor}" == "portworx" ]]; then
  storagedef="storageVendor: ${cp4dstoragevendor}"
elif [[ "${cp4dstoragevendor}" == "nfs" ]]; then
  storagedef="storageClass: ${cp4dstorageclass}"
else
  storagedef="storageClass: ${cp4dstorageclass}\n  zenCoreMetadbStorageClass: ${cp4dstorageclass}" 
fi

cat <<EOF > tmp_monitor/platform_service.yaml
apiVersion: operator.ibm.com/v1alpha1
kind: OperandRequest
metadata:
  name: empty-request
  namespace: ${namespace}
spec:
  requests: []
---
apiVersion: cpd.ibm.com/v1
kind: Ibmcpd
metadata:
  name: ibmcpd-cr
  namespace: ${namespace}
  csNamespace: ${namespace}
spec:
  license:
    accept: true
    license: Enterprise
  ${storagedef}
EOF

oc apply -f tmp_monitor/platform_service.yaml > /dev/null 2>&1

while [[ "$(oc get Ibmcpd ibmcpd-cr -n ${namespace} -o jsonpath='{.status.controlPlaneStatus}' --ignore-not-found)" != "Completed" ]]; do sleep 5; done &
showWorking $!

printf '\b'
echo "${COLOR_GREEN}Done${COLOR_RESET}"

echo -n "Waiting for zen lite service..."
while [[ "$(oc get ZenService lite-cr -n ${namespace} -o jsonpath='{.status.zenStatus}')" != "Completed" ]]; do sleep 5; done &
showWorking $!

printf '\b'
echo "${COLOR_GREEN}Done${COLOR_RESET}"

echo ""
echo "URL of Cloud pak for data is $(oc get ZenService lite-cr -o jsonpath='{.status.url}')"
echo "Credentials are admin/$(oc extract secret/admin-user-details --keys=initial_admin_password --to=-)"
echo ""

echo "${COLOR_GREEN}Done${COLOR_RESET}"


echo_h2 "Deploying CP4D db2wh operator..."
cat <<EOF > tmp_monitor/db2u_operator.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-db2wh-cp4d-operator-catalog-subscription
  namespace: ${namespace}
spec:
  channel: v1.0
  name: ibm-db2wh-cp4d-operator
  installPlanApproval: Automatic
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF

oc apply -f tmp_monitor/db2u_operator.yaml > /dev/null 2>&1

while [[ $(oc get sub -n ${namespace} ibm-db2wh-cp4d-operator-catalog-subscription -o jsonpath='{.status.installedCSV}') == "" ]];do sleep 1; done & showWorking $!
printf '\b'

operatorname=$(oc get sub -n ${namespace} ibm-db2wh-cp4d-operator-catalog-subscription -o jsonpath='{.status.installedCSV}')
while [[ "$(oc get deployments -n ${namespace} -l olm.owner=${operatorname} -o jsonpath='{.items[0].status.availableReplicas}' --ignore-not-found)" != "1" ]]; do sleep 5; done &
showWorking $!
printf '\b'
echo "${COLOR_GREEN}Done${COLOR_RESET}"


echo_h2 "Deploying DB2WH service..."
cat <<EOF > tmp_monitor/db2service.yaml
apiVersion: databases.cpd.ibm.com/v1
kind: Db2whService
metadata:
  name: db2wh-cr    
  namespace: ${namespace}
spec:
  license:
    accept: true
    license: Enterprise
  db_type: db2wh

EOF

oc apply -f tmp_monitor/db2service.yaml > /dev/null 2>&1

while [[ "$(oc get Db2whService db2wh-cr -o jsonpath='{.status.db2whStatus}' -n ${namespace} --ignore-not-found)" != "Completed" ]]; do sleep 5; done &
showWorking $!
printf '\b'
echo "${COLOR_GREEN}Done${COLOR_RESET}"

license=$(oc get -n ${namespace} secret db2u-license-keys -o jsonpath="{.data.json}" | base64 -d | jq ".db2wh[\"${db2wh_version}\"]" | tr -d "\"")
cloudpakid=$(oc get configmap -n ${namespace} db2u-json-cm -o jsonpath="{.data.ibm-db2wh\.json}" | jq ".\"default-annotations\".productID")

exit 0 

echo_h2 "Creating new database..."
cat <<EOF > tmp_monitor/db2whinstance.yaml
apiVersion: db2u.databases.ibm.com/v1
kind: Db2uCluster
metadata:
  name: "db2wh-${db2wh_instance_name}"
  namespace: "${namespace}"
spec:
  size: ${db2wh_num_pods}
  license:
    accept: true
    value: ${license}
  podConfig:
    db2u:
      resource:
        db2u:
          requests:
            cpu: "${db2wh_cpu_requests}"
            memory: "${db2wh_memory_requests}"
          limits:
            cpu: "${db2wh_cpu_limits}"
            memory: "${db2wh_memory_limits}"
      annotations:
        cloudpakId: ${cloudpakid}
        cloudpakInstanceId: eb31e68c-7e56-4562-8232-ecb7f33827bb
        cloudpakName: IBM Cloud Pak for Data
        productChargedContainers: All
        productID: ${cloudpakid}
        productMetric: VIRTUAL_PROCESSOR_CORE
        productName: IBM Db2 Warehouse
        productVersion: ${db2wh_version}
      labels:
        db2u/cpdbr: db2u
        icpdsupport/addOnId: db2wh
        icpdsupport/app: db2wh-${db2wh_instance_name}
        icpdsupport/podSelector: db2u-log
        icpdsupport/serviceInstanceId: "${db2wh_instance_name}"
    etcd:
      annotations:
        cloudpakId: ${cloudpakid}
        cloudpakInstanceId: eb31e68c-7e56-4562-8232-ecb7f33827bb
        cloudpakName: IBM Cloud Pak for Data
        productChargedContainers: All
        productID: ${cloudpakid}
        productMetric: FREE
        productName: IBM Db2 Warehouse
        productVersion: ${db2wh_version}
      labels:
        db2u/cpdbr: db2u
        icpdsupport/addOnId: db2wh
        icpdsupport/app: db2wh-${db2wh_instance_name}
        icpdsupport/serviceInstanceId: "${db2wh_instance_name}"
    graph:
      annotations:
        cloudpakId: ${cloudpakid}
        cloudpakInstanceId: eb31e68c-7e56-4562-8232-ecb7f33827bb
        cloudpakName: IBM Cloud Pak for Data
        productChargedContainers: All
        productID: ${cloudpakid}
        productMetric: FREE
        productName: IBM Db2 Warehouse
        productVersion: ${db2wh_version}
      labels:
        icpdsupport/addOnId: db2wh
        icpdsupport/app: db2wh-${db2wh_instance_name}
        icpdsupport/serviceInstanceId: "${db2wh_instance_name}"
    instdb:
      annotations:
        cloudpakId: ${cloudpakid}
        cloudpakInstanceId: eb31e68c-7e56-4562-8232-ecb7f33827bb
        cloudpakName: IBM Cloud Pak for Data
        productChargedContainers: All
        productID: ${cloudpakid}
        productMetric: FREE
        productName: IBM Db2 Warehouse
        productVersion: ${db2wh_version}
      labels:
        icpdsupport/addOnId: db2wh
        icpdsupport/app: db2wh-${db2wh_instance_name}
        icpdsupport/serviceInstanceId: "${db2wh_instance_name}"
    qrep:
      annotations:
        cloudpakId: ${cloudpakid}
        cloudpakInstanceId: eb31e68c-7e56-4562-8232-ecb7f33827bb
        cloudpakName: IBM Cloud Pak for Data
        productChargedContainers: All
        productID: ${cloudpakid}
        productMetric: FREE
        productName: IBM Db2 Warehouse
        productVersion: ${db2wh_version}
      labels:
        icpdsupport/addOnId: db2wh
        icpdsupport/app: db2wh-${db2wh_instance_name}
        icpdsupport/serviceInstanceId: "${db2wh_instance_name}"
    rest:
      annotations:
        cloudpakId: ${cloudpakid}
        cloudpakInstanceId: eb31e68c-7e56-4562-8232-ecb7f33827bb
        cloudpakName: IBM Cloud Pak for Data
        productChargedContainers: All
        productID: ${cloudpakid}
        productMetric: FREE
        productName: IBM Db2 Warehouse
        productVersion: ${db2wh_version}
      labels:
        icpdsupport/addOnId: db2wh
        icpdsupport/app: db2wh-${db2wh_instance_name}
        icpdsupport/serviceInstanceId: "${db2wh_instance_name}"
    restore-morph:
      annotations:
        cloudpakId: ${cloudpakid}
        cloudpakInstanceId: eb31e68c-7e56-4562-8232-ecb7f33827bb
        cloudpakName: IBM Cloud Pak for Data
        productChargedContainers: All
        productID: ${cloudpakid}
        productMetric: FREE
        productName: IBM Db2 Warehouse
        productVersion: ${db2wh_version}
      labels:
        icpdsupport/addOnId: db2wh
        icpdsupport/app: db2wh-${db2wh_instance_name}
        icpdsupport/serviceInstanceId: "${db2wh_instance_name}"
    tools:
      annotations:
        cloudpakId: ${cloudpakid}
        cloudpakInstanceId: eb31e68c-7e56-4562-8232-ecb7f33827bb
        cloudpakName: IBM Cloud Pak for Data
        productChargedContainers: All
        productID: ${cloudpakid}
        productMetric: FREE
        productName: IBM Db2 Warehouse
        productVersion: ${db2wh_version}
      labels:
        db2u/cpdbr: db2u
        icpdsupport/addOnId: db2wh
        icpdsupport/app: db2wh-${db2wh_instance_name}
        icpdsupport/serviceInstanceId: "${db2wh_instance_name}"
  account:
    privileged: true
  environment:
    database:
      name: "${db2wh_dbname}"
      settings:
        dftTableOrg: "${db2wh_table_org}"
      ssl:
        secretName: "internal-tls"
        certLabel: "CN=zen-ca-cert"
    dbType: db2wh
    instance:
      dbmConfig:
        SRVCON_PW_PLUGIN: IBMIAMauthpwfile
        group_plugin: IBMIAMauthgroup
        srvcon_auth: GSS_SERVER_ENCRYPT
        srvcon_gssplugin_list: IBMIAMauth
      registry:
        DB2AUTH: 'OSAUTHDB,ALLOW_LOCAL_FALLBACK,PLUGIN_AUTO_RELOAD'
        DB2_FMP_RUN_AS_CONNECTED_USER: 'NO'
        DB2_WORKLOAD: ${db2wh_workload}
        DB2_4K_DEVICE_SUPPORT: "ON"
    ldap:
      enabled: false
    mln:
      total: ${db2wh_mln_count}
  addOns:
    graph: {}
    rest: {}
  advOpts:
    db2SecurityPlugin: cloud_gss_plugin
  version: "${db2wh_version}"
  storage:
    - name: meta
      spec:
        accessModes:
          - ReadWriteMany
        resources:
          requests:
            storage: "${db2wh_meta_storage_size_gb}"
        storageClassName: "${db2wh_meta_storage_class}"
      type: create
    - name: data
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: "${db2wh_user_storage_size_gb}"
        storageClassName: "${db2wh_user_storage_class}"
      type: template
    - name: backup
      spec:
        accessModes:
          - ReadWriteMany
        resources:
          requests:
            storage: "${db2wh_backup_storage_size_gb}"
        storageClassName: "${db2wh_backup_storage_class}"
      type: create
    - name: activelogs
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: "${db2wh_logs_storage_size_gb}"
        storageClassName: "${db2wh_logs_storage_class}"
      type: template
    - name: tempts
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: "${db2wh_temp_storage_size_gb}"
        storageClassName: "${db2wh_temp_storage_class}"
      type: template
  volumeSources:
    - visibility:
        - db2u
      volumeSource:
        secret:
          secretName: zen-service-broker-secret

EOF

oc apply -f tmp_monitor/db2whinstance.yaml > /dev/null 2>&1

while [[ "$(oc get Db2uCluster db2wh-${db2wh_instance_name} -o jsonpath='{.status.state}' -n ${namespace} --no-headers --ignore-not-found)" != "Ready" ]]; do sleep 5; done &
showWorking $!
printf '\b'
echo "${COLOR_GREEN}Done${COLOR_RESET}"

echo_h2 "Creating new database user"
echo "${COLOR_GREEN}Done${COLOR_RESET}"


echo_h2 "Creating MAS JDBC Config..."

cp4dsvc=c-db2wh-${db2wh_instance_name}-db2u-engn-svc
cp4dhost=${cp4dsvc}.${namespace}.svc
cp4dport=$(oc get service c-db2wh-${db2wh_instance_name}-db2u-engn-svc -n ${namespace} -o jsonpath="{.spec.ports[?(@.name=='ssl-server')].targetPort}")
cp4durl="jdbc:db2://${cp4dhost}:${cp4dport}/${db2wh_dbname}:securityMechanism=9;sslConnection=true;encryptionAlgorithm=2;"

cp4dpod=$(oc get pods --selector app=db2wh-${db2wh_instance_name},component=db2wh,formation_id=db2wh-${db2wh_instance_name},role=db,type=engine -n ${namespace} | sed '2!d' | awk '{printf $1}')
cpd4dcertificates=$(oc -n ${namespace} -c db2u exec $cp4dpod -- openssl s_client -connect localhost:${cp4dport} -showcerts 2>&1 < /dev/null  | sed -ne '/BEGIN\ CERTIFICATE/,/END\ CERTIFICATE/p')

#cpd4dcertificates=$(fetchCertificates $cp4dhost $cp4dport)
cpd4dcertificate1=$(getcert "${cpd4dcertificates}" 2 | sed 's/^/\ \ \ \ \ \ \ \ /g')
cpd4dcertificate2=$(getcert "${cpd4dcertificates}" 1 | sed 's/^/\ \ \ \ \ \ \ \ /g')

cat << EOF > tmp/mas_jdbc_config.yaml
apiVersion: config.mas.ibm.com/v1
kind: JdbcCfg
metadata:
  name: ${instanceid}-jdbc-system
  namespace: mas-${instanceid}-core
  labels:
    mas.ibm.com/configScope: system
    mas.ibm.com/instanceId: ${instanceid}
spec:
  certificates:
    - alias: jdbccert1
      crt: |-
${cpd4dcertificate1}
    - alias: jdbccert2
      crt: |-
${cpd4dcertificate2}
  config:
    credentials:
      secretName: ${instanceid}-usersupplied-jdbc-creds-system
    driverOptions: {}
    sslEnabled: true
    url: ${cp4durl}
  displayName: MAS DB2 connection
  type: external
---
kind: Secret
apiVersion: v1
metadata:
  name: ${instanceid}-usersupplied-jdbc-creds-system
  namespace: mas-${instanceid}-core
data:
  username: $(echo -n "${cp4dmonitoruser}" | base64)
  password: $(echo -n "${cp4dmonitorpassword}" | base64)
type: Opaque
EOF

oc apply -f tmp/mas_jdbc_config.yaml > /dev/null 2>&1
echo "${COLOR_GREEN}Done${COLOR_RESET}"

echo -n "	JDBC Configuration ready              "
while [[ $(oc get JdbcCfg ${instanceid}-jdbc-system --ignore-not-found=true -o jsonpath="{.status.conditions[?(@.type=='Ready')].status}" -n mas-${instanceid}-core) != "True" ]];do sleep 5; done & 
showWorking $!
printf '\b'
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"


echo_h2 " Creating Kafka user..."
cat << EOF > tmp/kafka_iot_user.yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  labels:
    strimzi.io/cluster: ${kafkaclustername}
  name: ${kafkauser}
  namespace: ${kafkanamespace}
spec:
  authentication:
    type: scram-sha-512
  authorization:
    acls:
      - operation: All
        resource:
          name: '*'
          patternType: literal
          type: topic
      - operation: All
        resource:
          name: '*'
          patternType: literal
          type: group
      - operation: All
        resource:
          type: cluster
      - operation: All
        resource:
          name: '*'
          patternType: literal
          type: transactionalId
    type: simple
EOF

oc apply -f tmp/kafka_iot_user.yaml > /dev/null 2>&1
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"


kafkauser_password=$(oc get Secret ${kafkauser} -n ${kafkanamespace} -o jsonpath='{.data.password}')

kafka_url1=${kafkaclustername}-kafka-0.${kafkaclustername}-kafka-brokers.${kafkanamespace}.svc
kafka_url2=${kafkaclustername}-kafka-1.${kafkaclustername}-kafka-brokers.${kafkanamespace}.svc
kafka_url3=${kafkaclustername}-kafka-2.${kafkaclustername}-kafka-brokers.${kafkanamespace}.svc



kafkacertificates=$(oc get Kafka maskafka -n mas-kafka -o json | jq -r ".status.listeners | .[]? | .certificates  | .[]?")
nbCertif=$(echo "${kafkacertificates}"| grep -o BEGIN | wc -w | tr -d ' ')

certifYaml=""
for ((i=1;i<=$nbCertif;i++))
do
  certifYaml+="    - alias: kafka${i}"$'\n'
  certifYaml+="      crt: |"$'\n'
  certifYaml+=$(getcert "${kafkacertificates}" $i | sed 's/^/\ \ \ \ \ \ \ \ /g')$'\n'
done

echo -n "Creating  MAS  Kafka config..."
cat << EOF > tmp/mas_kafka_config.yaml
apiVersion: config.mas.ibm.com/v1
kind: KafkaCfg
metadata:
  name: ${instanceid}-kafka-system
  labels:
    mas.ibm.com/configScope: system
    mas.ibm.com/instanceId: ${instanceid}
  namespace: mas-${instanceid}-core
spec:
  certificates:
${certifYaml}
  config:
    credentials:
      secretName: ${instanceid}-usersupplied-kafka-creds-system
    hosts:
      - host: ${kafka_url1}
        port: 9093
      - host: ${kafka_url2}
        port: 9093
      - host: ${kafka_url3}
        port: 9093
    saslMechanism: SCRAM-SHA-512
  displayName: Kafka service
  type: external
---
kind: Secret
apiVersion: v1
metadata:
  name: ${instanceid}-usersupplied-kafka-creds-system
  namespace: mas-${instanceid}-core
  ownerReferences:
    - apiVersion: config.mas.ibm.com/v1
      kind: KafkaCfg
      name: ${instanceid}-kafka-system
      uid: ${owneruid}
data:
  password: ${kafkauser_password}
  username: $(echo -n "${kafkauser}" | base64)
type: Opaque
EOF

oc apply -f tmp/mas_kafka_config.yaml > /dev/null 2>&1
echo -e "${COLOR_GREEN}[OK]${COLOR_RESET}"

while [[ $(oc get KafkaCfg ${instanceid}-kafka-system --ignore-not-found=true -n mas-${instanceid}-core --no-headers -o jsonpath="{.metadata.uid}") == "" ]];do  sleep 1; done &
showWorking $!
printf '\b'
owneruid=$(oc get KafkaCfg ${instanceid}-kafka-system --ignore-not-found=true -n mas-${instanceid}-core --no-headers -o jsonpath="{.metadata.uid}")


#TODO 
#create mas-${instanceid}-iot project
echo "Deploying IoT..."

namespace=mas-${instanceid}-iot
oc project "${namespace}" > /dev/null 2>&1
if [[ "$?" == "1" ]]; then
  oc new-project "${namespace}" --display-name "Maximo Application Suite IOT Tool" > /dev/null 2>&1
fi

oc -n ${namespace} create secret docker-registry ibm-entitlement --docker-server=cp.icr.io --docker-username=cp  --docker-password=${ER_KEY} > /dev/null 2>&1
#install operatorgroup
if [[ "$(oc get OperatorGroup -n ${namespace} --no-headers --ignore-not-found)" == "" ]]; then

  echo "Need to create operator group"
cat << EOF > tmp_monitor/iotoperatorgroup.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ibm-mas-iot-operatorgroup
  namespace: ${namespace}
spec:
  targetNamespaces:
    - ${namespace}
EOF

  oc apply -f tmp_monitor/iotoperatorgroup.yaml > /dev/null 2>&1
  echo "${COLOR_GREEN}Done${COLOR_RESET}"

fi;
#install operator
operatorname=$(oc get csv -n ${namespace} --no-headers --ignore-not-found | grep ibm-mas-iot | awk '{print $1}')

if [[ "${operatorname}" == "" ]]; then

  echo "Need to create operator"
  cat << EOF > tmp_monitor/iotoperator.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-mas-iot-operator
  namespace: ${namespace}
spec:
  channel: 8.x
  installPlanApproval: Manual
  name: ibm-mas-iot
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF


  oc apply -f tmp_monitor/iotoperator.yaml > /dev/null 2>&1

  while [[ $(oc get Subscription ibm-mas-iot-operator -n ${namespace} --ignore-not-found=true -o jsonpath='{.status.state}') != "UpgradePending" ]];do sleep 5; done & 
  showWorking $!
  printf '\b'

  echo "	Approving manual installation"
  # Find install plan
  installplan=$(oc get subscription ibm-mas-iot-operator -o jsonpath="{.status.installplan.name}" -n ${namespace})
  echo "	installplan: $installplan"

  # Approve install plan
  oc patch installplan ${installplan} -n ${namespace} --type merge --patch '{"spec":{"approved":true}}' > /dev/null 2>&1

  echo "${COLOR_GREEN}Done${COLOR_RESET}"
fi


#create IoT
echo "Instanciating IoT..."
cat << EOF > tmp_monitor/iot.yaml
apiVersion: iot.ibm.com/v1
kind: IoT
metadata:
  name: ${instanceid}
  namespace: mas-${instanceid}-iot
  labels:
    mas.ibm.com/applicationId: iot
    mas.ibm.com/instanceId: ${instanceid}
spec:
  bindings:
    jdbc: system
    kafka: system
    mongo: system
  components: {}
  settings:
    deployment:
      size: small
    messagesight:
      storage:
        class: ${iotstorageclass}
        size: ${iotstoragesize}
EOF

oc apply -f tmp_monitor/iot.yaml > /dev/null 2>&1
echo "${COLOR_GREEN}Done${COLOR_RESET}"

owneruid=$(oc get Iot ${instanceid} -n mas-${instanceid}-iot -o jsonpath='{.metadata.uid}' )

#create service bindings ${instanceid}-coreidp-binding ${instanceid}-suite-binding
echo "Creating service bindings..."

cat << EOF > tmp_monitor/servicebindings.yaml
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-coreidp-binding
  namespace: ${namespace}
  ownerReferences:
    - apiVersion: iot.ibm.com/v1
      kind: IoT
      name: ${instanceid}
      uid: ${owernuid}
  labels:
    mas.ibm.com/applicationId: iot
    mas.ibm.com/instanceId: ${instanceid}
spec:
  application:
    group: apps
    name: ${instanceid}-binding-app
    resource: deployments
    version: v1
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
  name: ${instanceid}-jdbc-binding
  namespace: mas-${instanceid}-iot
  ownerReferences:
    - apiVersion: iot.ibm.com/v1
      kind: IoT
      name: ${instanceid}
      uid: ${owernuid}
  labels:
    mas.ibm.com/applicationId: iot
    mas.ibm.com/instanceId: ${instanceid}
spec:
  application:
    group: apps
    name: ${instanceid}-binding-app
    resource: deployments
    version: v1
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: config.mas.ibm.com
      kind: JdbcCfg
      name: ${instanceid}-jdbc-system
      namespace: mas-${instanceid}-core
      version: v1
---
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-kafka-binding
  namespace: mas-${instanceid}-iot
  ownerReferences:
    - apiVersion: iot.ibm.com/v1
      kind: IoT
      name: ${instanceid}
      uid: ${owernuid}
  labels:
    mas.ibm.com/applicationId: iot
    mas.ibm.com/instanceId: ${instanceid}
spec:
  application:
    group: apps
    name: ${instanceid}-binding-app
    resource: deployments
    version: v1
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: config.mas.ibm.com
      kind: KafkaCfg
      name: ${instanceid}-kafka-system
      namespace: mas-${instanceid}-core
      version: v1
---
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-mongo-binding
  namespace: mas-${instanceid}-iot
  ownerReferences:
    - apiVersion: iot.ibm.com/v1
      kind: IoT
      name: ${instanceid}
      uid: ${owernuid}
  labels:
    mas.ibm.com/applicationId: iot
    mas.ibm.com/instanceId: ${instanceid}
spec:
  application:
    group: apps
    name: ${instanceid}-binding-app
    resource: deployments
    version: v1
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: config.mas.ibm.com
      kind: MongoCfg
      name: ${instanceid}-mongo-system
      namespace: mas-${instanceid}-core
      version: v1
---
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-suite-binding
  namespace: mas-${instanceid}-iot
  ownerReferences:
    - apiVersion: iot.ibm.com/v1
      kind: IoT
      name: ${instanceid}
      uid: ${owernuid}
  labels:
    mas.ibm.com/applicationId: iot
    mas.ibm.com/instanceId: ${instanceid}
spec:
  application:
    group: apps
    name: ${instanceid}-binding-app
    resource: deployments
    version: v1
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: core.mas.ibm.com
      kind: Suite
      name: ${instanceid}
      namespace: mas-${instanceid}-core
      version: v1

EOF

oc apply -f tmp_monitor/servicebindings.yaml > /dev/null 2>&1
echo "${COLOR_GREEN}Done${COLOR_RESET}"

echo "Creating Iot workspace..."

cat << EOF > tmp_monitor/iotworkspace.yaml
apiVersion: iot.ibm.com/v1
kind: IoTWorkspace
metadata:
  name: ${instanceid}-${workspaceid}
  namespace: mas-${instanceid}-iot
  labels:
    mas.ibm.com/applicationId: iot
    mas.ibm.com/instanceId: ${instanceid}
    mas.ibm.com/workspaceId: ${workspaceid}
spec: {}
EOF

oc apply -f tmp_monitor/servicebindings.yaml > /dev/null 2>&1
echo "${COLOR_GREEN}Done${COLOR_RESET}"

echo "Deploying monitor..."
#create mas-${instanceid}-monitor
namespace=mas-${instanceid}-monitor
oc project "${namespace}" > /dev/null 2>&1
if [[ "$?" == "1" ]]; then
  oc new-project "${namespace}" --display-name "Maximo Application Suite Monitor" > /dev/null 2>&1
fi

oc -n ${namespace} create secret docker-registry ibm-entitlement --docker-server=cp.icr.io --docker-username=cp  --docker-password=${ER_KEY} > /dev/null 2>&1
#install operatorgroup
if [[ "$(oc get OperatorGroup -n ${namespace} --no-headers --ignore-not-found)" == "" ]]; then

  echo "Need to create operator group"
cat << EOF > tmp_monitor/monitoroperatorgroup.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ibm-mas-monitor-operatorgroup
  namespace: ${namespace}
spec:
  targetNamespaces:
    - ${namespace}
EOF

  oc apply -f tmp_monitor/monitoroperatorgroup.yaml > /dev/null 2>&1
  echo "${COLOR_GREEN}Done${COLOR_RESET}"

fi;
#install operator
operatorname=$(oc get csv -n ${namespace} --no-headers --ignore-not-found | grep ibm-mas-monitor | awk '{print $1}')

if [[ "${operatorname}" == "" ]]; then

  echo "Need to create operator"
  cat << EOF > tmp_monitor/monitoroperator.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-mas-monitor-operator
  namespace: ${namespace}
spec:
  channel: 8.x
  installPlanApproval: Manual
  name: ibm-mas-monitor
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
EOF


  oc apply -f tmp_monitor/monitoroperator.yaml > /dev/null 2>&1

  while [[ $(oc get Subscription ibm-mas-monitor-operator -n ${namespace} --ignore-not-found=true -o jsonpath='{.status.state}') != "UpgradePending" ]];do sleep 5; done & 
  showWorking $!
  printf '\b'

  echo "	Approving manual installation"
  # Find install plan
  installplan=$(oc get subscription ibm-mas-monitor-operator -o jsonpath="{.status.installplan.name}" -n ${namespace})
  echo "	installplan: $installplan"

  # Approve install plan
  oc patch installplan ${installplan} -n ${namespace} --type merge --patch '{"spec":{"approved":true}}' > /dev/null 2>&1

  echo "${COLOR_GREEN}Done${COLOR_RESET}"
fi

echo "Instanciating Monitor app..."
cat << EOF > tmp_monitor/monitor.yaml
apiVersion: apps.mas.ibm.com/v1
kind: MonitorApp
metadata:
  name: ${instanceid}
  namespace: mas-${instanceid}-monitor
  labels:
    mas.ibm.com/applicationId: monitor
    mas.ibm.com/instanceId: ${instanceid}
spec:
  bindings:
    jdbc: system
    mongo: system
  components: {}
  settings:
    deployment:
      size: small
EOF

oc apply -f tmp_monitor/monitor.yaml > /dev/null 2>&1
echo "${COLOR_GREEN}Done${COLOR_RESET}"
owneruid=$(oc get MonitorApp ${instanceid} -n mas-${instanceid}-monitor -o jsonpath='{.metadata.uid}')

echo "Instanciating Monitor workspace..."
cat << EOF > tmp_monitor/monitorworkspace.yaml
apiVersion: apps.mas.ibm.com/v1
kind: MonitorWorkspace
metadata:
  name: ${instanceid}-${workspaceid}
  namespace: mas-${instanceid}-monitor
  labels:
    mas.ibm.com/applicationId: monitor
    mas.ibm.com/instanceId: ${instanceid}
    mas.ibm.com/workspaceId: ${workspaceid}
spec:
  bindings:
    iot: workspace
    jdbc: system
  components: {}
  settings:
    deployment: {}
EOF

oc apply -f tmp_monitor/monitorworkspace.yaml > /dev/null 2>&1
echo "${COLOR_GREEN}Done${COLOR_RESET}"

workspaceuid=$(oc get MonitorWorkspace ${instanceid}-${workspaceid} -n mas-${instanceid}-monitor -o jsonpath='{.metadata.uid}')

echo "Creating service bindings..."
cat << EOF > tmp_monitor/monitorservicebindings.yaml
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-coreidp-binding
  namespace: mas-${instanceid}-monitor
  ownerReferences:
    - apiVersion: apps.mas.ibm.com/v1
      kind: MonitorApp
      name: ${instanceid}
      uid: ${owneruid}
  labels:
    mas.ibm.com/applicationId: monitor
    mas.ibm.com/instanceId: ${instanceid}
spec:
  application:
    group: apps
    name: ${instanceid}-binding-app
    resource: deployments
    version: v1
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
  name: ${instanceid}-${workspaceid}-add-binding
  namespace: mas-${instanceid}-monitor
  ownerReferences:
    - apiVersion: apps.mas.ibm.com/v1
      kind: MonitorWorkspace
      name: ${instanceid}-${workspaceid}
      uid: ${workspaceuid}
  labels:
    mas.ibm.com/applicationId: monitor
    mas.ibm.com/instanceId: ${instanceid}
    mas.ibm.com/workspaceId: ${workspaceid}
spec:
  application:
    group: apps
    name: ${instanceid}-binding-app
    resource: deployments
    version: v1
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: asset-data-dictionary.ibm.com
      kind: DataDictionaryWorkspace
      name: ${instanceid}-${workspaceid}
      namespace: mas-${instanceid}-add
      version: v1
---
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-${workspaceid}-jdbc-binding
  namespace: mas-${instanceid}-monitor
  ownerReferences:
    - apiVersion: apps.mas.ibm.com/v1
      kind: MonitorWorkspace
      name: ${instanceid}-${workspaceid}
      uid: ${workspaceuid}

  labels:
    mas.ibm.com/applicationId: monitor
    mas.ibm.com/instanceId: ${instanceid}
    mas.ibm.com/workspaceId: ${workspaceid}
spec:
  application:
    group: apps
    name: ${instanceid}-binding-app
    resource: deployments
    version: v1
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: config.mas.ibm.com
      kind: JdbcCfg
      name: ${instanceid}-jdbc-system
      namespace: mas-${instanceid}-core
      version: v1
---
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-jdbc-binding

  namespace: mas-${instanceid}-monitor
  ownerReferences:
    - apiVersion: apps.mas.ibm.com/v1
      kind: MonitorApp
      name: ${instanceid}
      uid: ${owneruid}
  labels:
    mas.ibm.com/applicationId: monitor
    mas.ibm.com/instanceId: ${instanceid}
spec:
  application:
    group: apps
    name: ${instanceid}-binding-app
    resource: deployments
    version: v1
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: config.mas.ibm.com
      kind: JdbcCfg
      name: ${instanceid}-jdbc-system
      namespace: mas-${instanceid}-core
      version: v1
---
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-mongo-binding
  namespace: mas-${instanceid}-monitor
  ownerReferences:
    - apiVersion: apps.mas.ibm.com/v1
      kind: MonitorApp
      name: ${instanceid}
      uid: ${owneruid}
  labels:
    mas.ibm.com/applicationId: monitor
    mas.ibm.com/instanceId: ${instanceid}
spec:
  application:
    group: apps
    name: ${instanceid}-binding-app
    resource: deployments
    version: v1
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: config.mas.ibm.com
      kind: MongoCfg
      name: ${instanceid}-mongo-system
      namespace: mas-${instanceid}-core
      version: v1
---
apiVersion: binding.operators.coreos.com/v1alpha1
kind: ServiceBinding
metadata:
  name: ${instanceid}-suite-binding
  namespace: mas-${instanceid}-monitor
  ownerReferences:
    - apiVersion: apps.mas.ibm.com/v1
      kind: MonitorApp
      name: ${instanceid}
      uid: ${owneruid}
  labels:
    mas.ibm.com/applicationId: monitor
    mas.ibm.com/instanceId: ${instanceid}
spec:
  application:
    group: apps
    name: ${instanceid}-binding-app
    resource: deployments
    version: v1
  bindAsFiles: true
  namingStrategy: lowercase
  services:
    - group: core.mas.ibm.com
      kind: Suite
      name: ${instanceid}
      namespace: mas-${instanceid}-core
      version: v1
EOF

oc apply -f tmp_monitor/monitorservicebindings.yaml > /dev/null 2>&1
echo "${COLOR_GREEN}Done${COLOR_RESET}"
