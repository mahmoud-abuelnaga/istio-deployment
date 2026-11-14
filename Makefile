# general
SHELL := /bin/bash
.SHELLFLAGS := -ec
MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RETRY_DELAY ?= 10
RETRY_COUNT ?= 6
WAIT_TIMEOUT ?= 10m

# istio
ISTIO_VERSION ?= 1.29.6
ISTIO_REVISION ?= $(subst .,-,$(ISTIO_VERSION))
ISTIO_REVISION_TAG ?= default
ISTIO_PROTECTED_NAMESPACES := kube-system kube-public kube-node-lease istio-system local-path-storage istio-gateway cnpg-system

# kiali
KIALI_RELEASE_NAME ?= kiali-operator
KIAlI_CHART_VERSION ?= 2.31.0

# kind
CLUSTER_NAME ?= "istio-cluster"
KUBECTL_CONTEXT := kind-$(CLUSTER_NAME)
DEFAULT_STORAGE_CLASS := csi-hostpath-sc

# calico
CALICO_VERSION ?= v3.32.1
CALICO_MANIFEST_URL := https://raw.githubusercontent.com/projectcalico/calico/$(CALICO_VERSION)/manifests/calico.yaml

# namespaces
MONITORING_NAMESPACE ?= monitoring
DATABASE_NAMESPACE ?= database
KIALI_NAMESPACE ?= kiali-operator

# app
CONTAINER_IMAGE_REPO_NAMESPACE := abuelnaga0
CONTAINER_IMAGE_NAME := istio-app
CONTAINER_IMAGE := $(CONTAINER_IMAGE_REPO_NAMESPACE)/$(CONTAINER_IMAGE_NAME)
APP_BASE_URL ?= http://app-1.example.com
REPLAY_URL ?= http://app-2.production.svc.cluster.local/replay
REPLAY_METHOD ?= POST
REPLAY_RATE_PER_SECOND ?= 100
REPLAY_DURATION_MS ?= 10000
REPLAY_TOTAL_REQUESTS ?=
REPLAY_BODY ?= {"message": "hello world"}

# redpanda
REDPANDA_CHART_VERSION ?= 26.2.1
REDPANDA_RELEASE_NAME ?= tempo-kafka

# prometheus operator crds
PROMETHEUS_OPERATOR_CRDS_CHART_VERSION ?= 31.0.1
PROMETHEUS_OPERATOR_CRDS_RELEASE_NAME ?= prometheus-operator-crds

# vm
VM_RELEASE_NAME ?= vm
VM_CHART_VERSION ?= 0.85.6
ALERTMANAGER_SMTP_SECRET ?= alertmanager-smtp

# grafana
GRAFANA_OPERATOR_RELEASE_NAME ?= grafana-operator
GRAFANA_OPERATOR_CHART_VERSION ?= 5.24.0

# tempo
TEMPO_RELEASE_NAME ?= tempo
TEMPO_CHART_VERSION ?= 3.1.0

# loki
LOKI_RELEASE_NAME ?= loki
LOKI_CHART_VERSION ?= 18.4.4

# alloy
ALLOY_CHART_VERSION ?= 1.10.1
ALLOY_LOGS_RELEASE_NAME ?= alloy-logs

# cluster targets
.PHONY: install-calico
install-calico:
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(CALICO_MANIFEST_URL)
	kubectl --context $(KUBECTL_CONTEXT) -n kube-system rollout status daemonset/calico-node --timeout 180s
	kubectl --context $(KUBECTL_CONTEXT) -n kube-system rollout status deploy/calico-kube-controllers --timeout 180s
	kubectl --context $(KUBECTL_CONTEXT) wait --for=condition=Ready nodes --all --timeout 120s

.PHONY: install-local-path-provisioner
install-local-path-provisioner:
	@echo "Deploying local-path-provisioner..."
	kubectl --context $(KUBECTL_CONTEXT) apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml
	kubectl --context $(KUBECTL_CONTEXT) -n local-path-storage rollout status deployment/local-path-provisioner --timeout=$(WAIT_TIMEOUT)

.PHONY: install-csi-hostpath-driver
.ONESHELL:
install-csi-hostpath-driver:
	@echo "Installing VolumeSnapshot CRDs..."
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

	echo "Deploying CSI HostPath Driver..."
	if [ -d "$(MAKEFILE_DIR)csi-driver-host-path" ]; then
		echo "CSI Driver HostPath is alread downloaded. Skipping the download..."
	else
		git clone --depth 1 https://github.com/kubernetes-csi/csi-driver-host-path.git $(MAKEFILE_DIR)csi-driver-host-path
	fi


	cd $(MAKEFILE_DIR)csi-driver-host-path && ./deploy/kubernetes-latest/deploy.sh
	kubectl apply -f $(MAKEFILE_DIR)csi-driver-host-path/examples/csi-storageclass.yaml


.PHONY: get-default-storage-class
.ONESHELL:
get-default-storage-class:
	@kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}'

.PHONY: set-default-storage-class
.ONESHELL:
set-default-storage-class:
	@current_default=$$($(MAKE) --no-print-directory -s get-default-storage-class)
	kubectl patch storageclass $$current_default -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
	kubectl patch storageclass $(DEFAULT_STORAGE_CLASS) -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'


.PHONY: start-cluster
.ONESHELL:
start-cluster:
	@first_deploy="false"
	if kind get clusters | grep -q "$(CLUSTER_NAME)"; then
		echo "Cluster $(CLUSTER_NAME) already exists";
	else
		kind create cluster --name $(CLUSTER_NAME) --config $(MAKEFILE_DIR)cluster/kind.yaml;
		first_deploy="true"
	fi

	kubectl config use-context $(KUBECTL_CONTEXT);
	nodes=$$(kind get nodes --name $(CLUSTER_NAME) 2>/dev/null || echo "")

	if [ -z "$$nodes" ]; then
		echo "No nodes found in cluster $(CLUSTER_NAME)";
		exit 1;
	fi

	docker start $$nodes  # case the containers/nodes are stopped
	reply=""
	for ((i=1; i<=$(RETRY_COUNT); i++)); do
		echo "Waiting for nodes to be ready (attempt $$i/$(RETRY_COUNT))";
		reply=$$(kubectl --context $(KUBECTL_CONTEXT) get --raw /readyz 2>/dev/null || echo "error")
		if [ "$$reply" == "ok" ]; then
			echo "Nodes are ready";
			break;
		fi

		sleep $(RETRY_DELAY);
	done

	if [ "$$reply" != "ok" ]; then
		echo "Failed to start cluster";
		exit 1;
	fi

	if [ "$$first_deploy" != "true" ]; then
		# $(MAKE) refresh-istio-workload-certs
		exit 0;
	fi

	$(MAKE) deploy-namespaces
	$(MAKE) install-calico
	# $(MAKE) install-local-path-provisioner
	$(MAKE) install-csi-hostpath-driver
	$(MAKE) set-default-storage-class
	$(MAKE) install-istio-bin
	$(MAKE) deploy-istio
	$(MAKE) tag-istio-revision
	$(MAKE) deploy-postgres
	$(MAKE) install-grafana-operator
	read -p "smtp username: " smtp_username
	read -s -p "smtp password: " smtp_password
	echo
	$(MAKE) create-alertmanager-smtp-secret USERNAME="$$smtp_username" PASSWORD="$$smtp_password" HOST="smtp.gmail.com:587"
	$(MAKE) deploy-grafana
	$(MAKE) install-prometheus-crds
	$(MAKE) install-vm-helm-repo
	$(MAKE) deploy-vm
	$(MAKE) create-seaweedfs-secret
	$(MAKE) deploy-seaweedfs
	$(MAKE) create-tempo-s3-secret
	$(MAKE) deploy-tempo
	$(MAKE) install-loki-helm-repo
	$(MAKE) deploy-loki
	$(MAKE) install-alloy-helm-repo
	$(MAKE) deploy-alloy-logs
	$(MAKE) deploy-grafana-datasources
	$(MAKE) correlate-metrics-to-logs
	$(MAKE) correlate-metrics-to-traces
	$(MAKE) install-kiali-helm-repo
	$(MAKE) deploy-kiali
	$(MAKE) deploy-destination-rules
	$(MAKE) deploy-in-cluster-routes
	$(MAKE) deploy-gateway

.PHONY: stop-cluster
.ONESHELL:
stop-cluster:
	@nodes=$$(kind get nodes --name $(CLUSTER_NAME) 2>/dev/null || true)
	if [ -z "$$nodes" ]; then
		echo "No nodes found in cluster $(CLUSTER_NAME)";
		exit 1;
	fi

	docker stop $$nodes

.PHONY: delete-cluster
.ONESHELL:
delete-cluster:
	kind delete cluster --name $(CLUSTER_NAME)

.PHONY: watch-lb-service
.ONESHELL:
watch-lb-service:
	cloud-provider-kind --gateway-channel=disabled

.PHONY:
.ONESHELL:
get-pvc-owner:
	@$(if $(strip $(PVC)),,$(error PVC is required))
	$(if $(strip $(PVC_NAMESPACE)),,$(error PVC_NAMESPACE is required))

	pvc="$(PVC)"
	pvc_namespace="$(PVC_NAMESPACE)"

	pod=$$(kubectl get pods -n "$$pvc_namespace" -o go-template='{{range .items}}{{$$pod := .}}{{range .spec.volumes}}{{with .persistentVolumeClaim}}{{if eq .claimName "'"$$pvc"'"}}{{$$pod.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}')
	echo "$$pod"

.PHONY:
.ONESHELL:
get-pod-highest-level-owner:
	@$(if $(strip $(POD)),,$(error POD is required))
	$(if $(strip $(POD_NAMESPACE)),,$(error POD_NAMESPACE is required))

	pod="$(POD)"
	pod_namespace="$(POD_NAMESPACE)"

	owner_json=$$(kubectl get pods -n "$$pod_namespace" "$$pod" -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)]}')
	owner_kind=$$(echo "$$owner_json" | jq -r '.kind // empty')
	owner_name=$$(echo "$$owner_json" | jq -r '.name // empty')

	case "$$owner_kind" in
		"")
			component_type="Pod"
			component_name="$$pod"
			;;
		"ReplicaSet")
			rs_owner_json=$$(kubectl get rs "$$owner_name" -n "$$pod_namespace" -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)]}')
			rs_owner_kind=$$(echo "$$rs_owner_json" | jq -r '.kind // empty')
			rs_owner_name=$$(echo "$$rs_owner_json" | jq -r '.name // empty')

			if [ "$$rs_owner_kind" = "Deployment" ]; then
				component_type="Deployment"
				component_name="$$rs_owner_name"
			else
				component_type="ReplicaSet"
				component_name="$$owner_name"
			fi
			;;
		"Job")
		  job_owner_kind=$$(kubectl get job "$$owner_name" -n "$$pod_namespace" -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].kind}')
			if [ "$$job_owner_kind" = "CronJob" ]; then
				component_type="CronJob"
				component_name=$$(kubectl get job "$$owner_name" -n "$$pod_namespace" -o jsonpath='{.metadata.ownerReferences[?(@.controller==true)].name}')
			else
				component_type="Job"
				component_name="$$owner_name"
			fi
			;;
		*)
			component_type="$$owner_kind"
			component_name="$$owner_name"
			;;
	esac

	echo "{ \"direct_owner\": { \"name\": \"$$owner_name\", \"kind\": \"$$owner_kind\" }, \"highest_level_owner\": { \"name\": \"$$component_name\", \"kind\": \"$$component_type\" } }"


.PHONY: create-temp-pvc
.ONESHELL:
create-temp-pvc:
	$(if $(strip $(TEMP_PVC_NAMESPACE)),,$(error TEMP_PVC_NAMESPACE is required))
	$(if $(strip $(TEMP_PVC_SIZE)),,$(error TEMP_PVC_SIZE is required))
	$(if $(strip $(TEMP_PVC_ACCESS_MODE)),,$(error TEMP_PVC_ACCESS_MODE is required))

	temp_pvc="pvc-$$(openssl rand -hex 8)"
	kubectl apply -n "$(TEMP_PVC_NAMESPACE)" -f - > /dev/null <<-EOF
	{
	  "apiVersion": "v1",
	  "kind": "PersistentVolumeClaim",
	  "metadata": {
	    "name": "$$temp_pvc",
	    "namespace": "$(TEMP_PVC_NAMESPACE)"
	  },
	  "spec": {
	    "accessModes": [
	      "$(TEMP_PVC_ACCESS_MODE)"
	    ],
	    "resources": {
	      "requests": {
	        "storage": "$(TEMP_PVC_SIZE)"
	      }
	    }
	  }
	}
	EOF

	echo "$$temp_pvc"

.PHONY: copy-pvc-data
.ONESHELL:
copy-pvc-data:
	@$(if $(strip $(SRC_PVC)),,$(error SRC_PVC is required))
	$(if $(strip $(DST_PVC)),,$(error DST_PVC is required))
	$(if $(strip $(NAMESPACE)),,$(error NAMESPACE is required))

	src_pvc="$(SRC_PVC)"
	dst_pvc="$(DST_PVC)"
	namespace="$(NAMESPACE)"
	job_name="pvc-copy-$$(openssl rand -hex 4)"

	echo "Creating job '$$job_name' to copy data from '$$src_pvc' to '$$dst_pvc' in namespace '$$namespace'..."
	kubectl apply -n "$$namespace" -f - <<-EOF
	{
	  "apiVersion": "batch/v1",
	  "kind": "Job",
	  "metadata": {
	    "name": "$$job_name",
	    "namespace": "$$namespace"
	  },
	  "spec": {
	    "backoffLimit": 0,
	    "template": {
	      "spec": {
	        "restartPolicy": "Never",
	        "containers": [
	          {
	            "name": "copy",
	            "image": "busybox:latest",
	            "securityContext": {
	              "runAsUser": 0
	            },
	            "command": [
	              "sh",
	              "-c",
	              "set -e; echo \"Starting data copy from /src to /dst...\"; find /src -mindepth 1 -maxdepth 1 ! -name \"lost+found\" -exec cp -a {} /dst/ \";\"; echo \"Data copy completed successfully.\""
	            ],
	            "volumeMounts": [
	              {
	                "name": "src",
	                "mountPath": "/src",
	                "readOnly": true
	              },
	              {
	                "name": "dst",
	                "mountPath": "/dst"
	              }
	            ]
	          }
	        ],
	        "volumes": [
	          {
	            "name": "src",
	            "persistentVolumeClaim": {
	              "claimName": "$$src_pvc"
	            }
	          },
	          {
	            "name": "dst",
	            "persistentVolumeClaim": {
	              "claimName": "$$dst_pvc"
	            }
	          }
	        ]
	      }
	    }
	  }
	}
	EOF

	echo "Waiting for copy job '$$job_name' to complete..."
	if ! kubectl wait --for=condition=complete "job/$$job_name" -n "$$namespace" --timeout=15m ; then
		echo "Job '$$job_name' failed or timed out. Pod logs:"
		kubectl logs -n "$$namespace" "job/$$job_name" || true
		kubectl delete job "$$job_name" -n "$$namespace" --ignore-not-found
		exit 1
	fi

	echo "Data copy succeeded. Cleaning up job '$$job_name'..."
	kubectl delete job "$$job_name" -n "$$namespace"


.PHONY: copy-pvc-data-back-and-forth
.ONESHELL:
copy-pvc-data-back-and-forth:
	@$(if $(strip $(PVC)),,$(error PVC is required))
	$(if $(strip $(PVC_NAMESPACE)),,$(error PVC_NAMESPACE is required))
	$(if $(strip $(PVC_SIZE)),,$(error PVC_SIZE is required))
	$(if $(strip $(PVC_ACCESS_MODE)),,$(error PVC_ACCESS_MODE is required))
	$(if $(strip $(DESIRED_STORAGE_CLASS)),,$(error DESIRED_STORAGE_CLASS is required))

	pvc="$(PVC)"
	pvc_namespace="$(PVC_NAMESPACE)"
	pvc_size="$(PVC_SIZE)"
	pvc_access_mode="$(PVC_ACCESS_MODE)"
	desired_storage_class="$(DESIRED_STORAGE_CLASS)"

	temp_pvc=$$($(MAKE) --no-print-directory -s create-temp-pvc TEMP_PVC_NAMESPACE="$$pvc_namespace" TEMP_PVC_SIZE="$$pvc_size" TEMP_PVC_ACCESS_MODE="$$pvc_access_mode")
	if ! $(MAKE) --no-print-directory -s copy-pvc-data SRC_PVC="$$pvc" DST_PVC="$$temp_pvc" NAMESPACE="$$pvc_namespace"; then
		echo "Copy failed. Deleting temporary PVC '$$temp_pvc'..."
		kubectl delete pvc "$$temp_pvc" -n "$$pvc_namespace" --ignore-not-found
		exit 1
	fi

	new_pvc_json=$$(kubectl -n "$$pvc_namespace" get pvc "$$pvc" -o json | jq \
		--arg sc "$$desired_storage_class" '
			del(
				.metadata.resourceVersion,
				.metadata.uid,
				.metadata.creationTimestamp,
				.metadata.selfLink,
				.metadata.managedFields,
				.status,
				.spec.volumeName,
				.metadata.annotations["pv.kubernetes.io/bind-completed"],
				.metadata.annotations["pv.kubernetes.io/bound-by-controller"],
				.metadata.annotations["volume.beta.kubernetes.io/storage-provisioner"],
				.metadata.annotations["volume.kubernetes.io/storage-provisioner"]
			) | .spec.storageClassName = $$sc
		')

	echo "Deleting original PVC '$$pvc'..."
	kubectl delete pvc "$$pvc" -n "$$pvc_namespace"

	echo "Recreating PVC '$$pvc' with storage class '$$desired_storage_class'..."
	echo "$$new_pvc_json" | kubectl apply -f -

	echo "Copying data back from '$$temp_pvc' to '$$pvc'..."
	if ! $(MAKE) --no-print-directory -s copy-pvc-data SRC_PVC="$$temp_pvc" DST_PVC="$$pvc" NAMESPACE="$$pvc_namespace"; then
		echo "Copy back failed! Temporary PVC '$$temp_pvc' retained for data recovery."
		exit 1
	fi

	echo "Cleaning up temporary PVC '$$temp_pvc'..."
	kubectl delete pvc "$$temp_pvc" -n "$$pvc_namespace" --ignore-not-found


.PHONY: change-pvc-storage-class
.ONESHELL:
change-pvc-storage-class:
	@$(if $(strip $(PVC)),,$(error PVC is required))
	$(if $(strip $(PVC_NAMESPACE)),,$(error PVC_NAMESPACE is required))
	$(if $(strip $(DESIRED_STORAGE_CLASS)),,$(error DESIRED_STORAGE_CLASS is required))

	pvc=$(PVC)
	pvc_namespace=$(PVC_NAMESPACE)
	desired_storage_class=$(DESIRED_STORAGE_CLASS)

	if ! kubectl get storageclasses.storage.k8s.io "$$desired_storage_class" > /dev/null 2>&1 ; then
		@echo "Specified desired storage class '$$desired_storage_class' doesn't exist. Terminating..."
		exit 1
	fi

	if ! kubectl -n "$$pvc_namespace" get pvc "$$pvc" > /dev/null 2>&1 ; then
		@echo "Specified pvc '$$pvc' doesn't exist in the namespace '$$pvc_namespace'. Terminating..."
		exit 1
	fi

	pvc_storage_class=$$(kubectl get persistentvolumeclaims -n "$$pvc_namespace" "$$pvc" -o jsonpath='{.spec.storageClassName}{"\n"}')
	if [ "$$pvc_storage_class" = "$$desired_storage_class" ]; then
		echo "pvc '$$pvc' in the namespace '$$pvc_namespace' already has the storage class '$$desired_storage_class'. Terminating..."
		exit 0
	fi

	echo "Changing pvc storage class..."
	pvc_size=$$(kubectl get persistentvolumeclaims -n "$$pvc_namespace" "$$pvc" -o jsonpath='{.spec.resources.requests.storage}{"\n"}')
	pvc_access_mode=$$(kubectl get persistentvolumeclaims -n "$$pvc_namespace" "$$pvc" -o jsonpath='{.spec.accessModes[0]}{"\n"}')

	pvc_pod=$$($(MAKE) --no-print-directory -s get-pvc-owner PVC="$$pvc" PVC_NAMESPACE="$$pvc_namespace" | head -n 1 | tr -d '[:space:]')

	if [ -n "$$pvc_pod" ]; then
		owner_details=$$($(MAKE) --no-print-directory -s get-pod-highest-level-owner POD="$$pvc_pod" POD_NAMESPACE="$$pvc_namespace")
		highest_level_owner_kind=$$(echo "$$owner_details" | jq -r '.highest_level_owner.kind')
		highest_level_owner_name=$$(echo "$$owner_details" | jq -r '.highest_level_owner.name')
	fi

	owner_kinds_automatically_handled=("Pod" "Deployment" "StatefulSet" "DaemonSet" "ReplicaSet")

	if [[ "$$pvc_pod" != "" && ! " $${owner_kinds_automatically_handled[*]} " =~ " $${highest_level_owner_kind} " ]]; then
		echo "pvc '$$pvc' in namespace '$$pvc_namespace' has a high level owner '$$highest_level_owner_name' of kind '$$highest_level_owner_kind' which the make target can't handle"
		exit 1
	fi

	if [ -z "$$pvc_pod" ]; then
		$(MAKE) --no-print-directory copy-pvc-data-back-and-forth \
			PVC="$$pvc" \
			PVC_NAMESPACE="$$pvc_namespace" \
			PVC_SIZE="$$pvc_size" \
			PVC_ACCESS_MODE="$$pvc_access_mode" \
			DESIRED_STORAGE_CLASS="$$desired_storage_class"

		exit 0
	fi

# istio targets
.PHONY: install-istio-bin
.ONESHELL:
install-istio-bin:
	mkdir -p istio

	if [ -d "$(MAKEFILE_DIR)istio/istio-$(ISTIO_VERSION)" ]; then
		echo "Istio $(ISTIO_VERSION) is already installed";
		exit 0;
	else
		curl -L https://istio.io/downloadIstio | ISTIO_VERSION=$(ISTIO_VERSION) TARGET_ARCH=x86_64 sh -;
		mv istio-$(ISTIO_VERSION) "$(MAKEFILE_DIR)istio/";
	fi

.PHONY: print-add-istioctl-to-path-fish-command
.ONESHELL:
print-add-istioctl-to-path-fish-command:
	@echo 'set -gx PATH "$(MAKEFILE_DIR)istio/istio-$(ISTIO_VERSION)/bin" $$PATH'

.PHONY: deploy-istio
.ONESHELL:
deploy-istio:
	@ISTIOCTL=$(MAKEFILE_DIR)istio/istio-$(ISTIO_VERSION)/bin/istioctl

	# deployed=$$(kubectl --context $(KUBECTL_CONTEXT) -n istio-system \
	#   get deploy istiod-$(ISTIO_REVISION) \
	#   -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null || true)

	# if [ "$$deployed" = "$(ISTIO_VERSION)" ]; then
	# 	echo "istiod $(ISTIO_VERSION) (revision $(ISTIO_REVISION)) is already deployed; Skipping install.";
	# else
	# 	$$ISTIOCTL install -y \
	# 	  --set revision=$(ISTIO_REVISION) \
	# 	  -f $(MAKEFILE_DIR)cluster/istio-operator.yaml;
	# fi

	$$ISTIOCTL install -y \
	  --set revision=$(ISTIO_REVISION) \
	  -f $(MAKEFILE_DIR)cluster/istio/istio-operator.k8s.yaml;

	kubectl --context $(KUBECTL_CONTEXT) \
	  apply -f $(MAKEFILE_DIR)cluster/istio/default.k8s.yaml

	kubectl --context $(KUBECTL_CONTEXT) \
	  apply -f $(MAKEFILE_DIR)cluster/istio/production-ns.k8s.yaml

.PHONY: refresh-istio-workload-certs
.ONESHELL:
refresh-istio-workload-certs:
	@echo "Restarting mesh proxies so they pick up workload certificates..."
	kubectl --context $(KUBECTL_CONTEXT) delete pods -A \
	  -l security.istio.io/tlsMode=istio \
	  --wait=false
	# Gateway pods are injected but do not get security.istio.io/tlsMode=istio.
	kubectl --context $(KUBECTL_CONTEXT) delete pods \
	  -n istio-gateway \
	  -l sidecar.istio.io/inject=true \
	  --wait=false

.PHONY: tag-istio-revision
.ONESHELL:
tag-istio-revision:
	@ISTIOCTL=$(MAKEFILE_DIR)istio/istio-$(ISTIO_VERSION)/bin/istioctl

	overwrite=""
	current=$$(kubectl --context $(KUBECTL_CONTEXT) get mutatingwebhookconfiguration \
	  istio-revision-tag-$(ISTIO_REVISION_TAG) \
	  -o jsonpath='{.metadata.labels.istio\.io/rev}' 2>/dev/null || true)

	if [ -n "$$current" ]; then
		if [ "$$current" = "$(ISTIO_REVISION)" ]; then
			echo "Tag '$(ISTIO_REVISION_TAG)' already points at $(ISTIO_REVISION); Skipping.";
			exit 0;
		else
			echo "WARNING: tag '$(ISTIO_REVISION_TAG)' currently points at revision '$$current'.";
			echo "Overwriting moves every namespace using this tag onto '$(ISTIO_REVISION)'.";
			read -p "Continue? [y/N] " ans;
			case "$$ans" in
				[yY]|[yY][eE][sS]) ;;
				*) echo "Aborted."; exit 1 ;;
			esac
		fi
		overwrite="--overwrite"
	fi

	$$ISTIOCTL tag set $(ISTIO_REVISION_TAG) --revision $(ISTIO_REVISION) $$overwrite -y

.PHONY: label-istio-revision-tag-on-namespace
.ONESHELL:
label-istio-revision-tag-on-namespace:
	@if [ -z "$(NAMESPACE)" ]; then
		echo "Error: NAMESPACE variable is not set";
		exit 1;
	fi

	case " $(ISTIO_PROTECTED_NAMESPACES) " in
		*" $(NAMESPACE) "*)
			echo "Error: refusing to enable injection in protected namespace '$(NAMESPACE)'.";
			echo "Protected: $(ISTIO_PROTECTED_NAMESPACES)";
			exit 0
			;;
	esac

	echo "Tagging namespace $(NAMESPACE) with Istio revision $(ISTIO_REVISION_TAG)";
	kubectl --context $(KUBECTL_CONTEXT) label namespace $(NAMESPACE) istio.io/rev=$(ISTIO_REVISION_TAG) --overwrite

.PHONY: unlabel-istio-revision-on-namespace
.ONESHELL:
unlabel-istio-revision-on-namespace:
	@if [ -z "$(NAMESPACE)" ]; then
		echo "Error: NAMESPACE variable is not set";
		exit 1;
	fi

	current=$$(kubectl --context $(KUBECTL_CONTEXT) get namespace $(NAMESPACE) \
	  -o jsonpath='{.metadata.labels.istio\.io/rev}' 2>/dev/null || true)

	if [ -z "$$current" ]; then
		echo "Namespace $(NAMESPACE) has no istio.io/rev label; Skipping.";
		exit 0;
	fi

	echo "Removing istio.io/rev=$$current from namespace $(NAMESPACE)";
	kubectl --context $(KUBECTL_CONTEXT) label namespace $(NAMESPACE) istio.io/rev-


.PHONY: deploy-namespaces
.ONESHELL:
deploy-namespaces:
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)cluster/namespaces/

.PHONY: deploy-destination-rules
.ONESHELL:
deploy-destination-rules:
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)cluster/istio/destination-rules/

.PHONY: deploy-gateway
.ONESHELL:
deploy-gateway:
	@kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)cluster/gateways/ingressgateway-service.k8s.yaml
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)cluster/gateways/ingressgateway-gateway.k8s.yaml
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)cluster/gateways/revisions/default/ingressgateway-deployment.k8s.yaml
	kubectl apply -f $(MAKEFILE_DIR)cluster/gateways/ingressgateway-scrape.k8s.yaml

	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)cluster/gateways/egressgateway-service.k8s.yaml
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)cluster/gateways/egressgateway-gateway.k8s.yaml
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)cluster/gateways/revisions/default/egressgateway-deployment.k8s.yaml
	$(MAKE) deploy-gateway-service-entries
	$(MAKE) deploy-gateway-routes

.PHONY: deploy-gateway-routes
.ONESHELL:
deploy-gateway-routes:
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)cluster/gateways/routes/

.PHONY: deploy-in-cluster-routes
.ONESHELL:
deploy-in-cluster-routes:
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)cluster/istio/routes/

.PHONY: deploy-gateway-service-entries
.ONESHELL:
deploy-gateway-service-entries:
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)cluster/gateways/service-entries/

.PHONY: install-kiali-helm-repo
.ONESHELL:
install-kiali-helm-repo:
	helm repo add kiali https://kiali.org/helm-charts || true
	helm repo update

.PHONY: deploy-kiali
.ONESHELL:
deploy-kiali:
	@release="$(KIALI_RELEASE_NAME)"
	namespace="$(KIALI_NAMESPACE)"
	values="$(MAKEFILE_DIR)kiali/values.yaml"
	chart="kiali/kiali-operator"
	desired_values=$$(yq -o=json "$$values" | jq -S -c .)

	metadata_json=$$(helm get metadata "$$release" \
	  --namespace "$$namespace" \
	  --kube-context $(KUBECTL_CONTEXT) \
	  -o json 2>/dev/null || true)

	if [ -n "$$metadata_json" ]; then
		current_version=$$(echo "$$metadata_json" | jq -r '.version // empty')
		current_values=$$(helm get values "$$release" \
		  --namespace "$$namespace" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  -o json | jq -S -c .)

		if [ "$$current_values" = "$$desired_values" ] && [ "$$current_version" = "$(KIAlI_CHART_VERSION)" ]; then
			echo "Kiali Operator release '$$release' already matches $$values (chart $(KIAlI_CHART_VERSION)); Skipping.";
			exit 0;
		fi

		echo "Upgrading Kiali Operator release '$$release'...";
		helm upgrade "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --version $(KIAlI_CHART_VERSION) \
		  --values "$$values" \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	else
		echo "Installing Kiali Operator release '$$release'...";
		helm install "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --create-namespace \
		  --version $(KIAlI_CHART_VERSION) \
		  --values "$$values" \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	fi

# apps targets
.PHONY: build-container-image
.ONESHELL:
build-container-image:
	@if [ -z "$(CONTAINER_IMAGE)" ]; then
		echo "Error: CONTAINER_IMAGE variable is not set";
		exit 1;
	fi

	random_tag=$$(openssl rand -hex 4)
	docker build \
	  -t $(CONTAINER_IMAGE):$$random_tag \
		-t $(CONTAINER_IMAGE):latest \
		-f apps/codebase/Dockerfile \
		apps/codebase/

	docker push $(CONTAINER_IMAGE):$$random_tag
	docker push $(CONTAINER_IMAGE):latest
	@echo "Container image tagged as $(CONTAINER_IMAGE):$$random_tag and latest and pushed to Docker Hub"

.PHONY: get-latest-container-image-tag
get-latest-container-image-tag:
	@curl -sS "https://hub.docker.com/v2/repositories/$(CONTAINER_IMAGE_REPO_NAMESPACE)/$(CONTAINER_IMAGE_NAME)/tags/?page_size=100" \
	  | jq -r '[.results[] | select(.name != "latest")] | max_by(.last_updated).name // empty'

.PHONY: deploy-app-1
.ONESHELL:
deploy-app-1:
	@echo "Deploying app-1 deployment..."
	CONTAINER_IMAGE_TAG="$(if $(strip $(CONTAINER_IMAGE_TAG)),$(CONTAINER_IMAGE_TAG),$$($(MAKE) --no-print-directory -s get-latest-container-image-tag))"

	if [ -z "$$CONTAINER_IMAGE_TAG" ]; then
		echo "Error: CONTAINER_IMAGE_TAG is not set";
		exit 1;
	fi

	export CONTAINER_IMAGE_TAG
	envsubst '$${CONTAINER_IMAGE_TAG}' < $(MAKEFILE_DIR)apps/app-1/deployment.k8s.yaml | kubectl --context $(KUBECTL_CONTEXT) apply -f -
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)apps/app-1/service.k8s.yaml
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)apps/app-1/scrape.k8s.yaml

.PHONY: deploy-app-2
.ONESHELL:
deploy-app-2:
	@echo "Deploying app-2 deployment..."
	ISTIOCTL=$(MAKEFILE_DIR)istio/istio-$(ISTIO_VERSION)/bin/istioctl
	CONTAINER_IMAGE_TAG="$(if $(strip $(CONTAINER_IMAGE_TAG)),$(CONTAINER_IMAGE_TAG),$$($(MAKE) --no-print-directory -s get-latest-container-image-tag))"

	if [ -z "$$CONTAINER_IMAGE_TAG" ]; then
		echo "Error: CONTAINER_IMAGE_TAG is not set";
		exit 1;
	fi

	export CONTAINER_IMAGE_TAG
	envsubst '$${CONTAINER_IMAGE_TAG}' < $(MAKEFILE_DIR)apps/app-2/deployment.k8s.yaml | \
		$$ISTIOCTL kube-inject -f - | \
		kubectl --context $(KUBECTL_CONTEXT) apply -f -

	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)apps/app-2/service.k8s.yaml
	kubectl --context $(KUBECTL_CONTEXT) apply -f $(MAKEFILE_DIR)apps/app-2/scrape.k8s.yaml

.PHONY: start-replay-job
.ONESHELL:
start-replay-job:
	@set -o pipefail
	echo "POST $(APP_BASE_URL)/replay-extended"
	jq -n \
	  --arg url "$(REPLAY_URL)" \
	  --arg method "$(REPLAY_METHOD)" \
	  --argjson ratePerSecond "$(REPLAY_RATE_PER_SECOND)" \
	  --argjson durationMs "$(REPLAY_DURATION_MS)" \
	  --argjson body '$(REPLAY_BODY)' \
	  --arg totalRequests "$(REPLAY_TOTAL_REQUESTS)" \
	  '{url: $$url, method: $$method, ratePerSecond: $$ratePerSecond, durationMs: $$durationMs, body: $$body} + (if $$totalRequests == "" then {} else {totalRequests: ($$totalRequests | tonumber)} end)' \
	| curl -sS -X POST "$(APP_BASE_URL)/replay-extended" \
	    -H 'Content-Type: application/json' \
	    -d @- \
	| jq .

# postgres targets
.PHONY: install-cnpg
install-cnpg:
	@kubectl apply --server-side \
		-f $(MAKEFILE_DIR)postgres/cnpg.k8s.yaml \
		--context $(KUBECTL_CONTEXT)

	kubectl rollout status deployment/cnpg-controller-manager \
		--timeout $(WAIT_TIMEOUT) \
		--namespace cnpg-system \
		--context $(KUBECTL_CONTEXT)

.PHONY: deploy-postgres
deploy-postgres: install-cnpg
	@kubectl apply -f $(MAKEFILE_DIR)postgres/grafana-db-user-secret.k8s.yaml \
		--namespace $(DATABASE_NAMESPACE) \
		--context $(KUBECTL_CONTEXT)

	kubectl apply -f $(MAKEFILE_DIR)postgres/cluster.k8s.yaml \
		--namespace $(DATABASE_NAMESPACE) \
		--context $(KUBECTL_CONTEXT)

	kubectl wait --for=condition=Ready cluster/grafana-db \
		--namespace $(DATABASE_NAMESPACE) \
		--timeout $(WAIT_TIMEOUT) \
		--context $(KUBECTL_CONTEXT)


# grafana targets
.PHONY: install-grafana-operator
.ONESHELL:
install-grafana-operator:
	@release="$(GRAFANA_OPERATOR_RELEASE_NAME)"
	namespace="$(MONITORING_NAMESPACE)"
	values="$(MAKEFILE_DIR)grafana/values.yaml"
	chart="oci://ghcr.io/grafana/helm-charts/grafana-operator"
	desired_values=$$(yq -o=json "$$values" | jq -S -c .)

	metadata_json=$$(helm get metadata "$$release" \
	  --namespace "$$namespace" \
	  --kube-context $(KUBECTL_CONTEXT) \
	  -o json 2>/dev/null || true)

	if [ -n "$$metadata_json" ]; then
		current_version=$$(echo "$$metadata_json" | jq -r '.version // empty')
		current_values=$$(helm get values "$$release" \
		  --namespace "$$namespace" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  -o json | jq -S -c .)

		if [ "$$current_values" = "$$desired_values" ] && [ "$$current_version" = "$(GRAFANA_OPERATOR_CHART_VERSION)" ]; then
			echo "Grafana Operator release '$$release' already matches $$values (chart $(GRAFANA_OPERATOR_CHART_VERSION)); Skipping.";
			exit 0;
		fi

		echo "Upgrading Grafana Operator release '$$release'...";
		helm upgrade "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --version $(GRAFANA_OPERATOR_CHART_VERSION) \
		  --values "$$values" \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	else
		echo "Installing Grafana Operator release '$$release'...";
		helm install "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --version $(GRAFANA_OPERATOR_CHART_VERSION) \
		  --values "$$values" \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	fi

.PHONY: deploy-grafana
deploy-grafana:
	@$(MAKE) check-alertmanager-smtp-secret-exists
	kubectl apply -f $(MAKEFILE_DIR)grafana/Grafana.k8s.yaml \
		--namespace $(MONITORING_NAMESPACE) \
		--context $(KUBECTL_CONTEXT)
	kubectl wait --for=create deployment/grafana-deployment \
		--timeout $(WAIT_TIMEOUT) \
		--namespace $(MONITORING_NAMESPACE) \
		--context $(KUBECTL_CONTEXT)
	kubectl rollout status deployment/grafana-deployment \
		--timeout $(WAIT_TIMEOUT) \
		--namespace $(MONITORING_NAMESPACE) \
		--context $(KUBECTL_CONTEXT)

.PHONY: correlate-metrics-to-logs
correlate-metrics-to-logs:
	NAMESPACE=$(MONITORING_NAMESPACE) \
	KUBE_CONTEXT=$(KUBECTL_CONTEXT) \
	$(MAKEFILE_DIR)grafana/apply-correlation.sh logs

.PHONY: correlate-metrics-to-traces
correlate-metrics-to-traces:
	NAMESPACE=$(MONITORING_NAMESPACE) \
	KUBE_CONTEXT=$(KUBECTL_CONTEXT) \
	$(MAKEFILE_DIR)grafana/apply-correlation.sh traces

.PHONY: deploy-grafana-datasources
deploy-grafana-datasources:
	kubectl apply -f $(MAKEFILE_DIR)grafana/datasources/ \
		--namespace $(MONITORING_NAMESPACE) \
		--context $(KUBECTL_CONTEXT)

# vm targets
.PHONY: install-prometheus-crds
.ONESHELL:
install-prometheus-crds:
	@release="$(PROMETHEUS_OPERATOR_CRDS_RELEASE_NAME)"
	namespace="$(MONITORING_NAMESPACE)"
	chart="oci://ghcr.io/prometheus-community/charts/prometheus-operator-crds"

	metadata_json=$$(helm get metadata "$$release" \
	  --namespace "$$namespace" \
	  --kube-context $(KUBECTL_CONTEXT) \
	  -o json 2>/dev/null || true)

	if [ -n "$$metadata_json" ]; then
		current_version=$$(echo "$$metadata_json" | jq -r '.version // empty')

		if [ "$$current_version" = "$(PROMETHEUS_OPERATOR_CRDS_CHART_VERSION)" ]; then
			echo "Prometheus Operator CRDs release '$$release' already at chart $(PROMETHEUS_OPERATOR_CRDS_CHART_VERSION); Skipping.";
			exit 0;
		fi

		echo "Upgrading Prometheus Operator CRDs release '$$release'...";
		helm upgrade "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --version $(PROMETHEUS_OPERATOR_CRDS_CHART_VERSION) \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	else
		echo "Installing Prometheus Operator CRDs release '$$release'...";
		helm install "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --version $(PROMETHEUS_OPERATOR_CRDS_CHART_VERSION) \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	fi

.PHONY: install-vm-helm-repo
install-vm-helm-repo:
	@helm repo add vm https://victoriametrics.github.io/helm-charts/ || true
	helm repo update

.PHONY: create-alertmanager-smtp-secret
create-alertmanager-smtp-secret:
	@$(if $(strip $(USERNAME)),,$(error USERNAME is required))
	$(if $(strip $(PASSWORD)),,$(error PASSWORD is required))
	$(if $(strip $(HOST)),,$(error HOST is required))

	kubectl create secret generic $(ALERTMANAGER_SMTP_SECRET) \
	  --from-literal username="$(USERNAME)" \
		--from-literal password="$(PASSWORD)" \
		--from-literal host="$(HOST)" \
		--namespace $(MONITORING_NAMESPACE) \
		--context $(KUBECTL_CONTEXT) \
		--dry-run=client -o yaml | kubectl --context $(KUBECTL_CONTEXT) apply -f -

.PHONY: check-alertmanager-smtp-secret-exists
check-alertmanager-smtp-secret-exists:
	@kubectl get secrets $(ALERTMANAGER_SMTP_SECRET) \
	  --namespace $(MONITORING_NAMESPACE) \
		--context $(KUBECTL_CONTEXT) > /dev/null 2>&1

.PHONY: deploy-vm
.ONESHELL:
deploy-vm:
	@$(MAKE) check-alertmanager-smtp-secret-exists
	$(MAKE) install-prometheus-crds
	$(MAKE) install-vm-helm-repo

	release="$(VM_RELEASE_NAME)"
	namespace="$(MONITORING_NAMESPACE)"
	values="$(MAKEFILE_DIR)vm/values.yaml"
	chart="vm/victoria-metrics-k8s-stack"
	desired_values=$$(yq -o=json "$$values" | jq -S -c .)

	metadata_json=$$(helm get metadata "$$release" \
	  --namespace "$$namespace" \
	  --kube-context $(KUBECTL_CONTEXT) \
	  -o json 2>/dev/null || true)

	if [ -n "$$metadata_json" ]; then
		current_version=$$(echo "$$metadata_json" | jq -r '.version // empty')
		current_values=$$(helm get values "$$release" \
		  --namespace "$$namespace" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  -o json | jq -S -c .)

		if [ "$$current_values" = "$$desired_values" ] && [ "$$current_version" = "$(VM_CHART_VERSION)" ]; then
			echo "VictoriaMetrics release '$$release' already matches $$values (chart $(VM_CHART_VERSION)); Skipping.";
			exit 0;
		fi

		echo "Upgrading VictoriaMetrics release '$$release'...";
		helm upgrade "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --version $(VM_CHART_VERSION) \
		  --values "$$values" \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	else
		echo "Installing VictoriaMetrics release '$$release'...";
		helm install "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --version $(VM_CHART_VERSION) \
		  --values "$$values" \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	fi


# redpanda targets
.PHONY: install-redpanda-helm-repo
install-redpanda-helm-repo:
	helm repo add redpanda https://charts.redpanda.com || true
	helm repo update

.PHONY: deploy-redpanda
.ONESHELL:
deploy-redpanda:
	@$(MAKE) install-redpanda-helm-repo

	release="$(REDPANDA_RELEASE_NAME)"
	namespace="$(MONITORING_NAMESPACE)"
	values="$(MAKEFILE_DIR)redpanda/values.yaml"
	chart="redpanda/redpanda"
	desired_values=$$(yq -o=json "$$values" | jq -S -c .)

	metadata_json=$$(helm get metadata "$$release" \
	  --namespace "$$namespace" \
	  --kube-context $(KUBECTL_CONTEXT) \
	  -o json 2>/dev/null || true)

	if [ -n "$$metadata_json" ]; then
		current_version=$$(echo "$$metadata_json" | jq -r '.version // empty')
		current_values=$$(helm get values "$$release" \
		  --namespace "$$namespace" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  -o json | jq -S -c .)

		if [ "$$current_values" = "$$desired_values" ] && [ "$$current_version" = "$(REDPANDA_CHART_VERSION)" ]; then
			echo "Redpanda release '$$release' already matches $$values (chart $(REDPANDA_CHART_VERSION)); Skipping.";
			exit 0;
		fi

		echo "Upgrading Redpanda release '$$release'...";
		helm upgrade "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --version $(REDPANDA_CHART_VERSION) \
		  --values "$$values" \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	else
		echo "Installing Redpanda release '$$release'...";
		helm install "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --version $(REDPANDA_CHART_VERSION) \
		  --values "$$values" \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	fi

# seaweedfs targets
.PHONY: create-seaweedfs-secret
create-seaweedfs-secret:
	@kubectl -n $(DATABASE_NAMESPACE) --context $(KUBECTL_CONTEXT) create secret generic seaweedfs-credentials \
		--from-literal access-key='seaweedadmin' \
		--from-literal secret-key='95325476d20db54a227d4419a7c1d2f6eec217ae87a0fd7f' \
		--dry-run=client -o yaml | kubectl --context $(KUBECTL_CONTEXT) apply -f -

	kubectl -n $(MONITORING_NAMESPACE) --context $(KUBECTL_CONTEXT) create secret generic seaweedfs-credentials \
		--from-literal access-key='seaweedadmin' \
		--from-literal secret-key='95325476d20db54a227d4419a7c1d2f6eec217ae87a0fd7f' \
		--dry-run=client -o yaml | kubectl --context $(KUBECTL_CONTEXT) apply -f -

.PHONY: check-seaweedfs-secret-exists
check-seaweedfs-secret-exists:
	@kubectl get secrets seaweedfs-credentials \
		--namespace $(DATABASE_NAMESPACE) \
		--context $(KUBECTL_CONTEXT) > /dev/null 2>&1
	kubectl get secrets seaweedfs-credentials \
		--namespace $(MONITORING_NAMESPACE) \
		--context $(KUBECTL_CONTEXT) > /dev/null 2>&1

.PHONY: deploy-seaweedfs
deploy-seaweedfs:
	$(MAKE) check-seaweedfs-secret-exists

	kubectl apply -f $(MAKEFILE_DIR)seaweedfs/ \
		--namespace $(DATABASE_NAMESPACE) \
		--context $(KUBECTL_CONTEXT)

	kubectl rollout status statefulset/seaweedfs \
		--namespace $(DATABASE_NAMESPACE) \
		--timeout $(WAIT_TIMEOUT) \
		--context $(KUBECTL_CONTEXT)

# tempo targets
.PHONY: create-tempo-s3-secret
.ONESHELL:
create-tempo-s3-secret:
	@$(MAKE) check-seaweedfs-secret-exists
	access_key="$$(kubectl -n $(DATABASE_NAMESPACE) --context $(KUBECTL_CONTEXT) get secret seaweedfs-credentials -o jsonpath='{.data.access-key}' | base64 -d)"
	secret_key="$$(kubectl -n $(DATABASE_NAMESPACE) --context $(KUBECTL_CONTEXT) get secret seaweedfs-credentials -o jsonpath='{.data.secret-key}' | base64 -d)"
	kubectl -n $(MONITORING_NAMESPACE) --context $(KUBECTL_CONTEXT) create secret generic tempo-s3 \
		--from-literal=S3_ACCESS_KEY="$$access_key" \
		--from-literal=S3_SECRET_KEY="$$secret_key" \
		--from-literal=S3_BUCKET="tempo-traces" \
		--from-literal=S3_ENDPOINT="seaweedfs.database.svc.cluster.local:8333" \
		--dry-run=client -o yaml | kubectl --context $(KUBECTL_CONTEXT) apply -f -

.PHONY: check-tempo-s3-secret-exists
check-tempo-s3-secret-exists:
	@kubectl get secrets tempo-s3 \
		--namespace $(MONITORING_NAMESPACE) \
		--context $(KUBECTL_CONTEXT) > /dev/null 2>&1

.PHONY: deploy-tempo
.ONESHELL:
deploy-tempo:
	@$(MAKE) check-tempo-s3-secret-exists
	helm upgrade --install $(TEMPO_RELEASE_NAME) oci://ghcr.io/grafana-community/helm-charts/tempo \
	  --version $(TEMPO_CHART_VERSION) --values $(MAKEFILE_DIR)tempo/values.yaml \
	  --kube-context $(KUBECTL_CONTEXT) --namespace $(MONITORING_NAMESPACE) \
	  --wait --timeout $(WAIT_TIMEOUT)
	kubectl --context $(KUBECTL_CONTEXT) apply --namespace $(MONITORING_NAMESPACE) \
	  -f $(MAKEFILE_DIR)tempo/support.k8s.yaml
	# The upstream chart does not expose the pod termination grace period.
	grace=$$(yq -r '.terminationGracePeriodSeconds' $(MAKEFILE_DIR)tempo/values.yaml)
	patch=$$(jq -n --argjson grace "$$grace" '{spec: {template: {spec: {terminationGracePeriodSeconds: $$grace}}}}')
	kubectl --context $(KUBECTL_CONTEXT) --namespace $(MONITORING_NAMESPACE) \
	  patch statefulset tempo --field-manager=tempo-tuning --type=merge -p "$$patch"
	kubectl --context $(KUBECTL_CONTEXT) --namespace $(MONITORING_NAMESPACE) \
	  rollout status statefulset/tempo --timeout=$(WAIT_TIMEOUT)

# loki
.PHONY: install-loki-helm-repo
install-loki-helm-repo:
	helm repo add grafana-community https://grafana-community.github.io/helm-charts || true
	helm repo update

.PHONY: deploy-loki
.ONESHELL:
deploy-loki:
	@$(MAKE) check-seaweedfs-secret-exists
	$(MAKE) install-loki-helm-repo
	helm upgrade --install $(LOKI_RELEASE_NAME) grafana-community/loki \
	  --version $(LOKI_CHART_VERSION) --values $(MAKEFILE_DIR)loki/values.yaml \
	  --kube-context $(KUBECTL_CONTEXT) --namespace $(MONITORING_NAMESPACE) \
	  --wait --timeout $(WAIT_TIMEOUT)

# alloy
.PHONY: install-alloy-helm-repo
install-alloy-helm-repo:
	helm repo add grafana https://grafana.github.io/helm-charts || true
	helm repo update

.PHONY: deploy-alloy-logs
.ONESHELL:
deploy-alloy-logs:
	@$(MAKE) install-alloy-helm-repo

	release="$(ALLOY_LOGS_RELEASE_NAME)"
	namespace="$(MONITORING_NAMESPACE)"
	values="$(MAKEFILE_DIR)alloy/logs.values.yaml"
	chart="grafana/alloy"
	desired_values=$$(yq -o=json "$$values" | jq -S -c .)

	metadata_json=$$(helm get metadata "$$release" \
	  --namespace "$$namespace" \
	  --kube-context $(KUBECTL_CONTEXT) \
	  -o json 2>/dev/null || true)

	if [ -n "$$metadata_json" ]; then
		current_version=$$(echo "$$metadata_json" | jq -r '.version // empty')
		current_values=$$(helm get values "$$release" \
		  --namespace "$$namespace" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  -o json | jq -S -c .)

		if [ "$$current_values" = "$$desired_values" ] && [ "$$current_version" = "$(ALLOY_CHART_VERSION)" ]; then
			echo "Alloy logs release '$$release' already matches $$values (chart $(ALLOY_CHART_VERSION)); Skipping.";
			exit 0;
		fi

		echo "Upgrading Alloy logs release '$$release'...";
		helm upgrade "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --version $(ALLOY_CHART_VERSION) \
		  --values "$$values" \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	else
		echo "Installing Alloy logs release '$$release'...";
		helm install "$$release" "$$chart" \
		  --kube-context $(KUBECTL_CONTEXT) \
		  --namespace "$$namespace" \
		  --version $(ALLOY_CHART_VERSION) \
		  --values "$$values" \
		  --wait \
		  --timeout $(WAIT_TIMEOUT);
	fi
