#!/usr/bin/env bash
# =============================================================================
# EKS Update Checker
# Checks available updates for EKS cluster and its add-ons
# Usage: ./eks-update-check.sh [--cluster <n>] [--region <region>] [--all-clusters]
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Defaults ───────────────────────────────────────────────────────────────────
CLUSTER_NAME=""
AWS_REGION="${AWS_DEFAULT_REGION:-eu-central-1}"
ALL_CLUSTERS=false
FOUND_UPDATES=false

# ── Helper functions ───────────────────────────────────────────────────────────
print_header() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}${CYAN}  $1${RESET}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
}

print_ok()   { echo -e "  ${GREEN}✔${RESET}  $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; FOUND_UPDATES=true; }
print_err()  { echo -e "  ${RED}✘${RESET}  $1"; }
print_info() { echo -e "  ${CYAN}ℹ${RESET}  $1"; }

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "  -c, --cluster <name>    Name of a specific EKS cluster"
  echo "  -r, --region  <region>  AWS region (default: ${AWS_REGION})"
  echo "  -a, --all-clusters      Check all clusters in the region"
  echo "  -h, --help              Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --cluster my-cluster --region eu-west-1"
  echo "  $0 --all-clusters"
  exit 0
}

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--cluster)      CLUSTER_NAME="$2"; shift 2 ;;
    -r|--region)       AWS_REGION="$2";   shift 2 ;;
    -a|--all-clusters) ALL_CLUSTERS=true; shift   ;;
    -h|--help)         usage ;;
    *) echo -e "${RED}Unknown argument: $1${RESET}"; usage ;;
  esac
done

# ── Prerequisites ──────────────────────────────────────────────────────────────
check_prerequisites() {
  print_header "Checking Prerequisites"
  local missing=false

  for cmd in aws jq; do
    if command -v "$cmd" &>/dev/null; then
      print_ok "$cmd found: $(command -v $cmd)"
    else
      print_err "$cmd is MISSING – please install it before running this script"
      missing=true
    fi
  done

  if $missing; then
    echo ""
    echo -e "${RED}Missing dependencies. Cannot continue.${RESET}"
    exit 1
  fi

  # Verify AWS identity
  local identity
  if identity=$(aws sts get-caller-identity --output json 2>&1); then
    local account; account=$(echo "$identity" | jq -r '.Account')
    local arn;     arn=$(echo "$identity"     | jq -r '.Arn')
    print_ok "AWS identity: ${arn} (account: ${account})"
  else
    print_err "Unable to verify AWS identity. Please check your credentials."
    exit 1
  fi
}

# ── Get list of clusters ───────────────────────────────────────────────────────
get_clusters() {
  if [[ -n "$CLUSTER_NAME" ]]; then
    echo "$CLUSTER_NAME"
  else
    aws eks list-clusters --region "$AWS_REGION" --output json \
      | jq -r '.clusters[]'
  fi
}

# ── Check cluster version ──────────────────────────────────────────────────────
check_cluster_version() {
  local cluster="$1"

  print_header "Cluster: ${cluster}"

  local cluster_info
  cluster_info=$(aws eks describe-cluster \
    --name "$cluster" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null) || {
    print_err "Cluster '${cluster}' not found or access denied."
    return 1
  }

  local current_version; current_version=$(echo "$cluster_info" | jq -r '.cluster.version')
  local platform_version; platform_version=$(echo "$cluster_info" | jq -r '.cluster.platformVersion')
  local status; status=$(echo "$cluster_info" | jq -r '.cluster.status')
  local endpoint; endpoint=$(echo "$cluster_info" | jq -r '.cluster.endpoint')

  print_info "Cluster status     : ${status}"
  print_info "Kubernetes version : ${current_version}"
  print_info "Platform version   : ${platform_version}"
  print_info "API endpoint       : ${endpoint}"

  # Check update insights
  echo ""
  echo -e "  ${BOLD}── Update Insights ──${RESET}"
  local insights
  insights=$(aws eks list-insights \
    --cluster-name "$cluster" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null || echo '{"insights":[]}')

  local insight_count
  insight_count=$(echo "$insights" | jq '.insights | length')

  if [[ "$insight_count" -eq 0 ]]; then
    print_ok "No update insights found (cluster is up to date)"
  else
    echo "$insights" | jq -r '.insights[] | "\(.category) | \(.name) | \(.insightStatus.status)"' | \
    while IFS='|' read -r category name status_ins; do
      category=$(echo "$category" | xargs)
      name=$(echo "$name" | xargs)
      status_ins=$(echo "$status_ins" | xargs)
      if [[ "$status_ins" == "PASSING" ]]; then
        print_ok "[${category}] ${name}"
      else
        print_warn "[${category}] ${name} → ${status_ins}"
      fi
    done
  fi
}

# ── Check add-ons ──────────────────────────────────────────────────────────────
check_addons() {
  local cluster="$1"

  echo ""
  echo -e "  ${BOLD}── Add-ons (CoreDNS, kube-proxy, vpc-cni, …) ──${RESET}"

  local addons
  addons=$(aws eks list-addons \
    --cluster-name "$cluster" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null | jq -r '.addons[]') || {
    print_info "No managed add-ons found or access denied."
    return
  }

  if [[ -z "$addons" ]]; then
    print_info "Cluster has no managed EKS add-ons."
    return
  fi

  # Cluster version for querying recommended versions
  local k8s_version
  k8s_version=$(aws eks describe-cluster \
    --name "$cluster" \
    --region "$AWS_REGION" \
    --query 'cluster.version' \
    --output text 2>/dev/null)

  while IFS= read -r addon; do
    local addon_info
    addon_info=$(aws eks describe-addon \
      --cluster-name "$cluster" \
      --addon-name "$addon" \
      --region "$AWS_REGION" \
      --output json 2>/dev/null)

    local current_ver; current_ver=$(echo "$addon_info" | jq -r '.addon.addonVersion')
    local addon_status; addon_status=$(echo "$addon_info" | jq -r '.addon.status')

    # Get latest available version
    local latest_ver
    latest_ver=$(aws eks describe-addon-versions \
      --addon-name "$addon" \
      --kubernetes-version "$k8s_version" \
      --region "$AWS_REGION" \
      --output json 2>/dev/null \
      | jq -r '
          .addons[0].addonVersions
          | map(select(.compatibilities[0].defaultVersion == true or (.compatibilities | length > 0)))
          | sort_by(.addonVersion) | last | .addonVersion
        ' 2>/dev/null || echo "N/A")

    # Fallback: pick first available version if default not found
    if [[ "$latest_ver" == "null" || "$latest_ver" == "N/A" ]]; then
      latest_ver=$(aws eks describe-addon-versions \
        --addon-name "$addon" \
        --kubernetes-version "$k8s_version" \
        --region "$AWS_REGION" \
        --output json 2>/dev/null \
        | jq -r '.addons[0].addonVersions | sort_by(.addonVersion) | last | .addonVersion' \
        2>/dev/null || echo "N/A")
    fi

    local icon="✔"
    local color="$GREEN"
    local note=""

    if [[ "$current_ver" == "$latest_ver" || "$latest_ver" == "N/A" ]]; then
      icon="✔"; color="$GREEN"
    else
      icon="⚠"; color="$YELLOW"
      note=" → newer available: ${latest_ver}"
      FOUND_UPDATES=true
    fi

    if [[ "$addon_status" != "ACTIVE" ]]; then
      icon="✘"; color="$RED"
      note=" [STATUS: ${addon_status}]"
    fi

    printf "  ${color}%s${RESET}  %-30s  current: %-20s latest: %s%s\n" \
      "$icon" "$addon" "$current_ver" "$latest_ver" "$note"
  done <<< "$addons"
}

# ── Check Node Groups ──────────────────────────────────────────────────────────
check_nodegroups() {
  local cluster="$1"

  echo ""
  echo -e "  ${BOLD}── Node Groups ──${RESET}"

  local nodegroups
  nodegroups=$(aws eks list-nodegroups \
    --cluster-name "$cluster" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null | jq -r '.nodegroups[]') || {
    print_info "No managed node groups found or access denied."
    return
  }

  if [[ -z "$nodegroups" ]]; then
    print_info "Cluster has no managed node groups."
    return
  fi

  while IFS= read -r ng; do
    local ng_info
    ng_info=$(aws eks describe-nodegroup \
      --cluster-name "$cluster" \
      --nodegroup-name "$ng" \
      --region "$AWS_REGION" \
      --output json 2>/dev/null)

    local ng_status;      ng_status=$(echo "$ng_info"      | jq -r '.nodegroup.status')
    local ng_version;     ng_version=$(echo "$ng_info"     | jq -r '.nodegroup.version')
    local release_ver;    release_ver=$(echo "$ng_info"    | jq -r '.nodegroup.releaseVersion // "N/A"')
    local desired;        desired=$(echo "$ng_info"        | jq -r '.nodegroup.scalingConfig.desiredSize')
    local health_issues;  health_issues=$(echo "$ng_info"  | jq -r '.nodegroup.health.issues | length')

    if [[ "$health_issues" -gt 0 ]]; then
      print_err "Node Group: ${ng}  (version: ${ng_version}, nodes: ${desired}, status: ${ng_status}) – ${health_issues} health issue(s)!"
    elif [[ "$ng_status" == "ACTIVE" ]]; then
      print_ok "Node Group: ${ng}  (version: ${ng_version}, nodes: ${desired}, status: ${ng_status})"
    else
      print_warn "Node Group: ${ng}  (version: ${ng_version}, nodes: ${desired}, status: ${ng_status})"
    fi

    # Check for pending updates on the node group
    local ng_updates
    ng_updates=$(aws eks list-updates \
      --name "$cluster" \
      --nodegroup-name "$ng" \
      --region "$AWS_REGION" \
      --output json 2>/dev/null | jq -r '.updateIds | length')

    if [[ "$ng_updates" -gt 0 ]]; then
      print_warn "  └─ ${ng_updates} pending/in-progress update(s) for this node group!"
    fi
  done <<< "$nodegroups"
}

# ── Check Fargate profiles ─────────────────────────────────────────────────────
check_fargate_profiles() {
  local cluster="$1"

  local profiles
  profiles=$(aws eks list-fargate-profiles \
    --cluster-name "$cluster" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null | jq -r '.fargateProfileNames[]' 2>/dev/null || echo "")

  if [[ -n "$profiles" ]]; then
    echo ""
    echo -e "  ${BOLD}── Fargate Profiles ──${RESET}"
    while IFS= read -r profile; do
      local pf_status
      pf_status=$(aws eks describe-fargate-profile \
        --cluster-name "$cluster" \
        --fargate-profile-name "$profile" \
        --region "$AWS_REGION" \
        --query 'fargateProfile.status' \
        --output text 2>/dev/null || echo "UNKNOWN")
      if [[ "$pf_status" == "ACTIVE" ]]; then
        print_ok "Fargate profile: ${profile} (${pf_status})"
      else
        print_warn "Fargate profile: ${profile} (${pf_status})"
      fi
    done <<< "$profiles"
  fi
}

# ── Summary ────────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
  if $FOUND_UPDATES; then
    echo -e "${BOLD}${YELLOW}  ⚠  Updates available – please review the output above.${RESET}"
  else
    echo -e "${BOLD}${GREEN}  ✔  Everything is up to date. No pending updates found.${RESET}"
  fi
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}"
  echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo -e "${BOLD}  EKS Update Checker  |  region: ${AWS_REGION}  |  $(date '+%Y-%m-%d %H:%M:%S')${RESET}"

  check_prerequisites

  local clusters
  if $ALL_CLUSTERS; then
    clusters=$(get_clusters)
    if [[ -z "$clusters" ]]; then
      echo -e "${YELLOW}No EKS clusters found in region ${AWS_REGION}.${RESET}"
      exit 0
    fi
  elif [[ -n "$CLUSTER_NAME" ]]; then
    clusters="$CLUSTER_NAME"
  else
    # No cluster or flag provided – list available clusters and exit
    local available
    available=$(aws eks list-clusters \
      --region "$AWS_REGION" \
      --output json 2>/dev/null | jq -r '.clusters[]' || echo "")

    if [[ -z "$available" ]]; then
      echo -e "${YELLOW}No EKS clusters found in region ${AWS_REGION}.${RESET}"
      exit 0
    fi

    echo ""
    echo -e "${BOLD}Available clusters in region ${AWS_REGION}:${RESET}"
    echo "$available" | nl -ba
    echo ""
    echo -e "Run again with:  ${CYAN}$0 --cluster <name>${RESET}  or  ${CYAN}$0 --all-clusters${RESET}"
    exit 0
  fi

  while IFS= read -r cluster; do
    [[ -z "$cluster" ]] && continue
    check_cluster_version  "$cluster"
    check_addons           "$cluster"
    check_nodegroups       "$cluster"
    check_fargate_profiles "$cluster"
  done <<< "$clusters"

  print_summary
}

main "$@"
