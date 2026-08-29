#!/usr/bin/env bash
# Deterministic OpenStack CLI fake for local Magnum lifecycle tests.
set -euo pipefail

args="$*"
project="${FAKE_PROJECT_ID:-53f449a040d14cef8512b69e4ad521cd}"
cluster_id="${FAKE_CLUSTER_ID:-11111111-2222-3333-4444-555555555555}"
cluster_name="${MAGNUM_CLUSTER_NAME:-js2-csoc-dev}"
master_flavor="${FAKE_MASTER_FLAVOR:-m3.small}"
worker_flavor="${FAKE_WORKER_FLAVOR:-m3.quad}"
boot_volume_size="${FAKE_BOOT_VOLUME_SIZE:-20}"
min_nodes="${MAGNUM_MIN_NODE_COUNT:-1}"
max_nodes="${MAGNUM_MAX_NODE_COUNT:-1}"

case "${args}" in
  "configuration show -f json")
    if [[ "${OS_CLIENT_CONFIG_FILE:-}" == *runtime* ]]; then
      printf '{"auth_type":"v3applicationcredential","auth.application_credential_id":"runtime-id"}\n'
    else
      printf '{"auth_type":"v3applicationcredential","auth.application_credential_id":"magnum-id"}\n'
    fi
    ;;
  "token issue -f json")
    printf '{"project_id":"%s"}\n' "${project}"
    ;;
  "token issue -f value -c project_id") printf '%s\n' "${project}" ;;
  "token issue -f value -c id") printf 'token-id\n' ;;
  application\ credential\ show*)
    id=$4
    if [[ "${id}" == runtime-id ]]; then
      unrestricted="${FAKE_RUNTIME_UNRESTRICTED:-false}"
      expires_at="${FAKE_RUNTIME_EXPIRES_AT:-2099-01-01T00:00:00Z}"
    else
      unrestricted="${FAKE_MAGNUM_UNRESTRICTED:-true}"
      expires_at="${FAKE_MAGNUM_EXPIRES_AT:-2099-01-01T00:00:00Z}"
    fi
    printf '{"project_id":"%s","unrestricted":%s,"expires_at":"%s"}\n' \
      "${project}" "${unrestricted}" "${expires_at}"
    ;;
  coe\ cluster\ template\ show*)
    printf '{"uuid":"284de191-b8ea-4dae-9046-6ab982bd1c3a","name":"kubernetes-1-34-jammy","public":true,"hidden":false,"coe":"kubernetes","network_driver":"calico","image_id":"ubuntu-jammy-kube-v1.34.8-260518-1604"}\n'
    ;;
  image\ show*)
    printf '{"id":"%s","name":"ubuntu-jammy-kube-v1.34.8-260518-1604","status":"active","min_disk":%s,"virtual_size":%s}\n' \
      "${FAKE_IMAGE_ID:-18895dd1-6e94-482b-9a62-9573328c7429}" \
      "${FAKE_IMAGE_MIN_DISK:-0}" "${FAKE_IMAGE_VIRTUAL_SIZE:-10737418240}"
    ;;
  "network show public -f json")
    printf '{"id":"3fe22c05-6206-4db2-9a13-44f04b6796e6","router:external":true}\n'
    ;;
  "network show auto_allocated_network -f json")
    printf '{"id":"%s","router:external":false}\n' \
      "${FAKE_FIXED_NETWORK_ID:-b1bca63f-e34b-47e5-bf96-565515f38326}"
    ;;
  "subnet show auto_allocated_subnet_v4 -f json")
    printf '{"id":"d676529f-7335-417d-a1e3-283f2411af3b","network_id":"%s","ip_version":4}\n' \
      "${FAKE_SUBNET_NETWORK_ID:-b1bca63f-e34b-47e5-bf96-565515f38326}"
    ;;
  flavor\ show*) printf '{"vcpus":4,"ram":15360,"disk":20}\n' ;;
  keypair\ show*|catalog\ show*) printf '{}\n' ;;
  "limits show --absolute -f json")
    printf '[{"Name":"max_total_instances","Value":%s},{"Name":"total_instances_used","Value":0},{"Name":"max_total_cores","Value":100},{"Name":"total_cores_used","Value":0},{"Name":"max_total_ram_size","Value":1000000},{"Name":"total_ram_used","Value":0}]\n' \
      "${FAKE_MAX_INSTANCES:-100}"
    ;;
  "quota show -f json")
    printf '[{"Resource":"networks","Limit":100},{"Resource":"subnets","Limit":100},{"Resource":"routers","Limit":100},{"Resource":"ports","Limit":1000},{"Resource":"floating_ips","Limit":100},{"Resource":"security_groups","Limit":100},{"Resource":"volumes","Limit":500},{"Resource":"gigabytes","Limit":50000}]\n'
    ;;
  "volume summary -f json")
    printf '{"Total Count":%s,"Total Size":%s}\n' \
      "${FAKE_VOLUME_COUNT:-0}" "${FAKE_VOLUME_SIZE:-0}"
    ;;
  loadbalancer\ quota\ show*) printf '{"load_balancer":-1}\n' ;;
  network\ list*|subnet\ list*|router\ list*|port\ list*|floating\ ip\ list*|security\ group\ list*) printf '[]\n' ;;
  "loadbalancer list --project ${project} -f json") printf '[]\n' ;;
  "loadbalancer list -f json") printf '[]\n' ;;
  "coe cluster list -f json")
    if [[ "${FAKE_AMBIGUOUS:-false}" == true ]]; then
      printf '[{"name":"%s","uuid":"a"},{"name":"%s","uuid":"b"}]\n' "${cluster_name}" "${cluster_name}"
    elif [[ -n "${FAKE_CREATE_LOG:-}" && -s "${FAKE_CREATE_LOG}" ]]; then
      printf '[{"name":"%s","uuid":"%s"}]\n' "${cluster_name}" "${cluster_id}"
    elif [[ "${FAKE_CLUSTER_EXISTS:-false}" == true ]]; then
      printf '[{"name":"%s","uuid":"%s"}]\n' "${cluster_name}" "${cluster_id}"
    else
      printf '[]\n'
    fi
    ;;
  coe\ cluster\ create*)
    printf '%s\n' "${args}" >"${FAKE_CREATE_LOG:?FAKE_CREATE_LOG is required}"
    printf 'request accepted\n'
    ;;
  coe\ cluster\ delete*)
    printf '%s\n' "${args}" >"${FAKE_DELETE_LOG:?FAKE_DELETE_LOG is required}"
    printf 'request accepted\n'
    ;;
  coe\ cluster\ config*)
    printf '%s\n' "${args}" >"${FAKE_CONFIG_LOG:?FAKE_CONFIG_LOG is required}"
    set -- $args
    output_dir=''
    while (( $# )); do
      [[ "$1" == --dir ]] && { output_dir=$2; break; }
      shift
    done
    mkdir -p "${output_dir}"
    printf 'apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\n' >"${output_dir}/config"
    ;;
  coe\ cluster\ show*)
    if [[ "${args}" == *"-f value -c name"* ]]; then
      printf '%s\n' "${cluster_name}"
    elif [[ "${args}" == *"-f value -c status"* ]]; then
      printf '%s\n' "${FAKE_CLUSTER_STATUS:-CREATE_COMPLETE}"
    elif [[ -n "${FAKE_WAIT_SEQUENCE:-}" && -f "${FAKE_WAIT_SEQUENCE}" ]]; then
      counter_file="${FAKE_WAIT_SEQUENCE}.counter"
      count=1
      [[ -f "${counter_file}" ]] && count=$(( $(<"${counter_file}") + 1 ))
      printf '%s\n' "${count}" >"${counter_file}"
      line=$(sed -n "${count}p" "${FAKE_WAIT_SEQUENCE}")
      [[ -n "${line}" ]] || line=$(tail -n 1 "${FAKE_WAIT_SEQUENCE}")
      printf '%s\n' "${line}"
    else
      printf '{"uuid":"%s","name":"%s","cluster_template_id":"284de191-b8ea-4dae-9046-6ab982bd1c3a","fixed_network":"auto_allocated_network","fixed_subnet":"auto_allocated_subnet_v4","keypair":"jetstream-CSOC-POC","status":"%s","health_status":"%s","status_reason":null,"updated_at":"2099-01-01T00:00:00Z","stack_id":"js2-stack","api_address":"https://10.0.0.1:6443","node_addresses":["10.0.0.2"],"master_addresses":["10.0.0.1"],"master_count":1,"master_flavor_id":"%s","labels":{"boot_volume_size":"%s","auto_scaling_enabled":"%s","min_node_count":"%s","max_node_count":"%s"}}\n' \
        "${cluster_id}" "${cluster_name}" "${FAKE_CLUSTER_STATUS:-CREATE_COMPLETE}" \
        "${FAKE_CLUSTER_HEALTH:-HEALTHY}" "${master_flavor}" "${boot_volume_size}" \
        "${FAKE_AUTO_SCALING_ENABLED:-${MAGNUM_AUTO_SCALING_ENABLED:-false}}" \
        "${min_nodes}" "${max_nodes}"
    fi
    ;;
  coe\ nodegroup\ show*)
    if [[ "${args}" == *" default-master "* ]]; then
      printf '{"name":"default-master","node_count":1,"flavor_id":"%s","image_id":"ubuntu-jammy-kube-v1.34.8-260518-1604","status":"CREATE_COMPLETE"}\n' "${master_flavor}"
    elif [[ -n "${FAKE_AUTOSCALE_STATE:-}" && -f "${FAKE_AUTOSCALE_STATE}" \
       && $(<"${FAKE_AUTOSCALE_STATE}") == up ]]; then
      printf '{"name":"default-worker","node_count":2,"min_node_count":1,"max_node_count":2,"flavor_id":"%s","image_id":"ubuntu-jammy-kube-v1.34.8-260518-1604","status":"UPDATE_COMPLETE"}\n' "${worker_flavor}"
    elif [[ -n "${FAKE_NODEGROUP_UPDATE_LOG:-}" && -s "${FAKE_NODEGROUP_UPDATE_LOG}" ]]; then
      printf '{"name":"default-worker","node_count":1,"min_node_count":%s,"max_node_count":%s,"flavor_id":"%s","image_id":"ubuntu-jammy-kube-v1.34.8-260518-1604","status":"UPDATE_COMPLETE"}\n' "${min_nodes}" "${max_nodes}" "${worker_flavor}"
    else
      printf '{"name":"default-worker","node_count":1,"min_node_count":%s,"max_node_count":%s,"flavor_id":"%s","image_id":"ubuntu-jammy-kube-v1.34.8-260518-1604","status":"CREATE_COMPLETE"}\n' \
        "${min_nodes}" "${FAKE_NODEGROUP_MAX:-${max_nodes}}" "${worker_flavor}"
    fi
    ;;
  coe\ nodegroup\ update*)
    printf '%s\n' "${args}" >"${FAKE_NODEGROUP_UPDATE_LOG:?FAKE_NODEGROUP_UPDATE_LOG is required}"
    printf 'request accepted\n'
    ;;
  coe\ nodegroup\ list*) printf '[]\n' ;;
  "server list -f json")
    printf '[{"ID":"server-1","Name":"js2-stack-control-plane","Status":"ACTIVE"},{"ID":"server-2","Name":"js2-stack-worker","Status":"ACTIVE"}]\n'
    ;;
  "server show server-1 -f json") printf '{"volumes_attached":[{"id":"volume-1"}]}\n' ;;
  "server show server-2 -f json") printf '{"volumes_attached":[{"id":"volume-2"}]}\n' ;;
  volume\ show*) printf '{"size":%s}\n' "${boot_volume_size}" ;;
  *) printf 'Unhandled fake openstack command: %s\n' "${args}" >&2; exit 64 ;;
esac
