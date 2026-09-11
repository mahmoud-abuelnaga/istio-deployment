#!/usr/bin/env bash
# Grafana correlations are the only cross-signal link that cannot be expressed
# on GrafanaDatasource CRs (spec.datasource has no `correlations` field).
# Loki/Tempo already declare their links in grafana/datasources/*.k8s.yaml.
#
# VictoriaMetrics does not store exemplars, so metrics -> traces/logs has to be
# a correlation rather than exemplarTraceIdDestinations. A correlation can
# read several labels off the source row, so both directions scope by service
# *and* namespace.
#
# Usage: apply-correlation.sh logs|traces
# Idempotent: matching correlations are deleted, then recreated.

set -Eeuo pipefail

target="${1:-}"
case "${target}" in
	logs | traces) ;;
	*)
		printf 'Usage: %s logs|traces\n' "$0" >&2
		exit 1
		;;
esac

readonly NAMESPACE="${NAMESPACE:-monitoring}"
readonly KUBE_CONTEXT="${KUBE_CONTEXT:-}"
readonly GRAFANA_SERVICE="${GRAFANA_SERVICE:-grafana-service}"
readonly GRAFANA_USER="${GRAFANA_USER:-admin}"
readonly GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
readonly SOURCE_UID="${SOURCE_UID:-VictoriaMetrics}"
# 250 * 5s = 1250s, past grafana-operator's 1000s reconciler backoff cap.
readonly DATASOURCE_WAIT_RETRIES="${DATASOURCE_WAIT_RETRIES:-250}"
readonly DATASOURCE_RETRY_DELAY="${DATASOURCE_RETRY_DELAY:-5}"

if [[ "${target}" == traces ]]; then
	readonly TARGET_UID="tempo"
	readonly LABEL="View traces for this service"
	readonly DESCRIPTION="Jump from a span metric series to the traces that produced it"
else
	readonly TARGET_UID="loki"
	readonly LABEL="View logs for this service"
	readonly DESCRIPTION="Jump from a metric series to that service's logs"
fi

port_forward_pid=""
local_port=""

kc() {
	if [[ -n "${KUBE_CONTEXT}" ]]; then
		kubectl --context "${KUBE_CONTEXT}" "$@"
	else
		kubectl "$@"
	fi
}

cleanup() {
	if [[ -n "${port_forward_pid}" ]]; then
		kill "${port_forward_pid}" 2>/dev/null || true
		wait "${port_forward_pid}" 2>/dev/null || true
	fi
}

trap cleanup EXIT

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		printf 'Required command not found: %s\n' "$1" >&2
		exit 1
	fi
}

pick_port() {
	python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

api() {
	local method="$1" path="$2"
	shift 2
	curl -sS --fail-with-body -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
		-X "${method}" "http://127.0.0.1:${local_port}${path}" \
		-H 'Content-Type: application/json' "$@"
}

# grafana-operator retries failed GrafanaDatasource reconciles with exponential
# backoff (5ms -> 1000s). VictoriaMetrics datasources are installed well before
# Grafana exists, so they can sit at the backoff cap. Wait past that cap.
wait_for_datasource() {
	local uid="$1"
	local i

	for ((i = 1; i <= DATASOURCE_WAIT_RETRIES; i++)); do
		if api GET "/api/datasources/uid/${uid}" >/dev/null 2>&1; then
			return 0
		fi
		sleep "${DATASOURCE_RETRY_DELAY}"
	done

	printf 'Datasource %s was never registered in Grafana after %ss\n' \
		"${uid}" "$((DATASOURCE_WAIT_RETRIES * DATASOURCE_RETRY_DELAY))" >&2
	printf 'grafana-operator GrafanaDatasource list:\n' >&2
	kc -n "${NAMESPACE}" get grafanadatasources >&2 || true
	exit 1
}

delete_existing() {
	local uid
	while read -r uid; do
		[[ -z "${uid}" ]] && continue
		printf '  removing existing correlation %s\n' "${uid}"
		api DELETE "/api/datasources/uid/${SOURCE_UID}/correlations/${uid}" >/dev/null
	done < <(
		api GET "/api/datasources/correlations" |
			jq -r --arg src "${SOURCE_UID}" --arg label "${LABEL}" '
				(if type == "array" then . else (.correlations // []) end)
				| .[]
				| select(.sourceUID == $src and .label == $label)
				| .uid
			'
	)
}

correlation_payload() {
	if [[ "${target}" == traces ]]; then
		# ${service}/${namespace} are Grafana correlation variables from the
		# source row. Tempo stores them as resource.service.name / namespace.
		jq -n \
			--arg target "${TARGET_UID}" \
			--arg label "${LABEL}" \
			--arg description "${DESCRIPTION}" \
			--arg query '{resource.service.name="${service}" && resource.service.namespace="${namespace}"}' \
			'{
				targetUID: $target,
				label: $label,
				description: $description,
				type: "query",
				config: {
					type: "query",
					field: "Value",
					target: { queryType: "traceql", query: $query }
				}
			}'
	else
		# Loki indexes service_name; metrics use `service`. Renaming Loki to
		# `service` would make discover_service_name synthesise a second label.
		jq -n \
			--arg target "${TARGET_UID}" \
			--arg label "${LABEL}" \
			--arg description "${DESCRIPTION}" \
			--arg expr '{service_name="${service}", namespace="${namespace}"}' \
			'{
				targetUID: $target,
				label: $label,
				description: $description,
				type: "query",
				config: {
					type: "query",
					field: "Value",
					target: { expr: $expr }
				}
			}'
	fi
}

require_command kubectl
require_command curl
require_command jq
require_command python3

local_port="$(pick_port)"
kc -n "${NAMESPACE}" port-forward "svc/${GRAFANA_SERVICE}" "${local_port}:3000" --address 127.0.0.1 >/dev/null 2>&1 &
port_forward_pid=$!

grafana_up() {
	curl -sf -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
		"http://127.0.0.1:${local_port}/api/health" >/dev/null 2>&1
}

for _ in $(seq 1 30); do
	if grafana_up; then
		break
	fi
	sleep 1
done

if ! grafana_up; then
	printf 'Grafana at svc/%s never became reachable on 127.0.0.1:%s\n' \
		"${GRAFANA_SERVICE}" "${local_port}" >&2
	exit 1
fi

printf 'Waiting for datasources %s and %s\n' "${SOURCE_UID}" "${TARGET_UID}"
wait_for_datasource "${SOURCE_UID}"
wait_for_datasource "${TARGET_UID}"

printf 'Applying metrics -> %s correlation\n' "${target}"
delete_existing
api POST "/api/datasources/uid/${SOURCE_UID}/correlations" \
	-d "$(correlation_payload)" >/dev/null

printf 'Done.\n'
