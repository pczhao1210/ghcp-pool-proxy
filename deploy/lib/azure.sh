#!/usr/bin/env bash

azure_prompt_required() {
  local variable_name="$1"
  local label="$2"
  local default_value="${3:-}"
  prompt_default "$variable_name" "$label" "$default_value"
  [[ -n "${!variable_name:-}" ]] || die "$variable_name cannot be empty"
}

azure_select_mode() {
  local variable_name="$1"
  local label="$2"
  local default_value="${3:-create}"
  local current_value="${!variable_name:-}"
  local answer
  if [[ -z "$current_value" ]]; then
    [[ -t 0 ]] || die "$variable_name=create|reuse is required in non-interactive mode"
    printf '%s:\n  1) create - managed by this deployment\n  2) reuse - validate an existing ARM resource ID\nSelect [%s]: ' \
      "$label" "$( [[ "$default_value" == "create" ]] && printf 1 || printf 2 )" >&2
    IFS= read -r answer
    answer="${answer:-$default_value}"
    case "$answer" in
      1|create) current_value="create" ;;
      2|reuse) current_value="reuse" ;;
      *) die "invalid $label mode: $answer" ;;
    esac
    printf -v "$variable_name" '%s' "$current_value"
  fi
  [[ "$current_value" == "create" || "$current_value" == "reuse" ]] || {
    die "$variable_name must be create or reuse"
  }
}

azure_is_interactive() {
  [[ -t 0 ]]
}

azure_choose_from_json() {
  local variable_name="$1"
  local label="$2"
  local manual_label="$3"
  local choices_json="$4"
  local count answer index name resource_group location details selected_value
  count="$(jq -r 'length' <<< "$choices_json")"
  [[ "$count" =~ ^[0-9]+$ ]] || die "could not read available $label"

  if [[ "$count" -eq 0 ]]; then
    printf 'No visible %s found; enter a value manually.\n' "$label" >&2
    azure_prompt_required "$variable_name" "$manual_label"
    return 0
  fi

  printf 'Available %s:\n' "$label" >&2
  for ((index = 0; index < count; index++)); do
    name="$(jq -r --argjson index "$index" '.[$index].name // .[$index].value' <<< "$choices_json")"
    resource_group="$(jq -r --argjson index "$index" '.[$index].resourceGroup // empty' <<< "$choices_json")"
    location="$(jq -r --argjson index "$index" '.[$index].location // empty' <<< "$choices_json")"
    details="$(jq -r --argjson index "$index" '.[$index].details // empty' <<< "$choices_json")"
    printf '  %d) %s' "$((index + 1))" "$name" >&2
    [[ -z "$resource_group" ]] || printf ' | resource group: %s' "$resource_group" >&2
    [[ -z "$location" ]] || printf ' | region: %s' "$location" >&2
    [[ -z "$details" ]] || printf ' | %s' "$details" >&2
    printf '\n' >&2
  done
  printf '  0) Enter a value manually\nSelect [1]: ' >&2
  IFS= read -r answer
  answer="${answer:-1}"
  if [[ "$answer" == "0" ]]; then
    azure_prompt_required "$variable_name" "$manual_label"
    return 0
  fi
  [[ "$answer" =~ ^[1-9][0-9]*$ && "$answer" -le "$count" ]] || {
    die "invalid $label selection: $answer"
  }
  selected_value="$(jq -r --argjson index "$((answer - 1))" '.[$index].value // empty' <<< "$choices_json")"
  [[ -n "$selected_value" ]] || die "selected $label has no usable value"
  printf -v "$variable_name" '%s' "$selected_value"
}

azure_resource_group_choices() {
  local groups_json
  groups_json="$(az group list --subscription "$AZURE_SUBSCRIPTION_ID" -o json)" || {
    die "could not list Azure resource groups"
  }
  jq -c '
    [.[] | {
      value: .name,
      name: .name,
      location: (.location // "")
    }]
    | sort_by(.name | ascii_downcase)
  ' <<< "$groups_json"
}

azure_resource_choices() {
  local resource_type="$1"
  local label="$2"
  local resources_json
  resources_json="$(az resource list --subscription "$AZURE_SUBSCRIPTION_ID" --resource-type "$resource_type" -o json)" || {
    die "could not list $label"
  }
  jq -c --arg location "$AZURE_LOCATION" '
    [
      .[]
      | select((.location // "" | ascii_downcase) == ($location | ascii_downcase))
      | {
          value: .id,
          name: (.name // (.id | split("/") | last)),
          resourceGroup: (.resourceGroup // ""),
          location: (.location // "")
        }
    ]
    | sort_by([(.resourceGroup | ascii_downcase), (.name | ascii_downcase)])
  ' <<< "$resources_json"
}

azure_subnet_choices() {
  local vnet_group vnet_name subnets_json
  vnet_group="$(azure_resource_group "$VNET_RESOURCE_ID")"
  vnet_name="$(azure_resource_name "$VNET_RESOURCE_ID")"
  subnets_json="$(az network vnet subnet list --subscription "$AZURE_SUBSCRIPTION_ID" \
    --resource-group "$vnet_group" --vnet-name "$vnet_name" -o json)" || {
    die "could not list subnets in virtual network $vnet_name"
  }
  jq -c --arg resourceGroup "$vnet_group" --arg location "$AZURE_LOCATION" '
    [
      .[]
      | {
          value: .id,
          name: .name,
          resourceGroup: $resourceGroup,
          location: $location,
          details: (
            if (.addressPrefix // "") != "" then "CIDR " + .addressPrefix
            elif ((.addressPrefixes // []) | length) > 0 then "CIDR " + (.addressPrefixes | join(", "))
            else ""
            end
          )
        }
    ]
    | sort_by(.name | ascii_downcase)
  ' <<< "$subnets_json"
}

azure_select_existing_resource_group() {
  [[ -n "${AZURE_RESOURCE_GROUP:-}" ]] && return 0
  azure_is_interactive || die "AZURE_RESOURCE_GROUP is required in non-interactive reuse mode"
  local choices_json
  choices_json="$(azure_resource_group_choices)"
  azure_choose_from_json AZURE_RESOURCE_GROUP "resource groups" "Azure resource group name" "$choices_json"
}

azure_select_existing_resource() {
  local variable_name="$1"
  local resource_type="$2"
  local label="$3"
  local manual_label="$4"
  [[ -n "${!variable_name:-}" ]] && return 0
  azure_is_interactive || die "$variable_name is required in non-interactive reuse mode"
  local choices_json
  choices_json="$(azure_resource_choices "$resource_type" "$label")"
  azure_choose_from_json "$variable_name" "$label" "$manual_label" "$choices_json"
}

azure_select_existing_subnet() {
  local variable_name="$1"
  local label="$2"
  local manual_label="$3"
  [[ -n "${!variable_name:-}" ]] && return 0
  azure_is_interactive || die "$variable_name is required in non-interactive reuse mode"
  local choices_json
  choices_json="$(azure_subnet_choices)"
  azure_choose_from_json "$variable_name" "$label" "$manual_label" "$choices_json"
}

azure_confirm() {
  local message="$1"
  [[ "$ASSUME_YES" -eq 0 ]] || return 0
  [[ -t 0 ]] || die "--yes is required for non-interactive Azure changes"
  local answer
  printf '%s [y/N]: ' "$message" >&2
  IFS= read -r answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "Azure deployment cancelled"
}

azure_arm_part() {
  local resource_id="$1"
  local wanted="${2,,}"
  local parts=()
  local index
  IFS='/' read -r -a parts <<< "${resource_id#/}"
  for ((index = 0; index + 1 < ${#parts[@]}; index++)); do
    if [[ "${parts[index],,}" == "$wanted" ]]; then
      printf '%s\n' "${parts[index + 1]}"
      return 0
    fi
  done
  return 1
}

azure_resource_name() {
  local resource_id="$1"
  printf '%s\n' "${resource_id##*/}"
}

azure_resource_group() {
  azure_arm_part "$1" resourceGroups
}

azure_resource_subscription() {
  azure_arm_part "$1" subscriptions
}

azure_validate_resource_id() {
  local resource_id="$1"
  local expected_type="$2"
  local label="$3"
  [[ "$resource_id" == /subscriptions/*/resourceGroups/*/providers/* ]] || {
    die "$label must be a complete ARM resource ID"
  }
  local resource_subscription actual_type state location
  resource_subscription="$(azure_resource_subscription "$resource_id")"
  [[ "${resource_subscription,,}" == "${AZURE_SUBSCRIPTION_ID,,}" ]] || {
    die "$label must be in selected subscription $AZURE_SUBSCRIPTION_ID"
  }
  actual_type="$(az resource show --ids "$resource_id" --query type -o tsv)" || {
    die "$label does not exist or is not readable: $resource_id"
  }
  [[ "${actual_type,,}" == "${expected_type,,}" ]] || {
    die "$label has type $actual_type; expected $expected_type"
  }
  state="$(az resource show --ids "$resource_id" --query properties.provisioningState -o tsv 2>/dev/null || true)"
  [[ -z "$state" || "$state" == "Succeeded" ]] || {
    die "$label provisioning state is $state, not Succeeded"
  }
  location="$(az resource show --ids "$resource_id" --query location -o tsv 2>/dev/null || true)"
  if [[ -n "$location" && -n "$AZURE_LOCATION" && "${location,,}" != "${AZURE_LOCATION,,}" ]]; then
    die "$label is in $location; selected deployment region is $AZURE_LOCATION"
  fi
}

azure_validate_name() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || {
    die "$label contains unsupported characters or is longer than 63 characters"
  }
}

azure_login() {
  if ! az account show >/dev/null 2>&1; then
    [[ -t 0 ]] || die "Azure CLI is not logged in; run az login first"
    azure_confirm "Azure CLI is not logged in. Start device-code login?"
    az login --use-device-code >/dev/null
  fi
  local current_subscription
  current_subscription="$(az account show --query id -o tsv)"
  AZURE_ORIGINAL_SUBSCRIPTION_ID="$current_subscription"
  prompt_default AZURE_SUBSCRIPTION_ID "Azure subscription ID" "$current_subscription"
  [[ -n "$AZURE_SUBSCRIPTION_ID" ]] || die "AZURE_SUBSCRIPTION_ID cannot be empty"
  az account set --subscription "$AZURE_SUBSCRIPTION_ID"
  AZURE_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
}

azure_collect_resource_group() {
  azure_select_mode AZURE_RESOURCE_GROUP_MODE "Azure resource group" create
  if [[ "$AZURE_RESOURCE_GROUP_MODE" == "reuse" ]]; then
    azure_select_existing_resource_group
    az group show --name "$AZURE_RESOURCE_GROUP" >/dev/null 2>&1 || {
      die "resource group does not exist or is not readable: $AZURE_RESOURCE_GROUP"
    }
    local group_location
    group_location="$(az group show --name "$AZURE_RESOURCE_GROUP" --query location -o tsv)"
    azure_prompt_required AZURE_LOCATION "Azure resource region" "$group_location"
  else
    azure_prompt_required AZURE_RESOURCE_GROUP "Azure resource group name" "ghcp-$ENVIRONMENT"
    [[ "$(az group exists --name "$AZURE_RESOURCE_GROUP" -o tsv)" != "true" ]] || {
      die "resource group already exists; choose AZURE_RESOURCE_GROUP_MODE=reuse"
    }
    azure_prompt_required AZURE_LOCATION "Azure region" "eastus"
  fi
  azure_validate_name "$AZURE_RESOURCE_GROUP" "Azure resource group name"
  prompt_default AZURE_OWNER "Azure owner tag" "operator"
  prompt_default AZURE_COST_CENTER "Azure costCenter tag" "unspecified"
  AZURE_DEPLOYMENT_NAME="${AZURE_DEPLOYMENT_NAME:-ghcp-$ENVIRONMENT-$(date -u +%Y%m%d%H%M%S)}"
  AZURE_DEPLOYMENT_ID="${AZURE_DEPLOYMENT_ID:-$AZURE_DEPLOYMENT_NAME}"
}

azure_assert_create_target_absent() {
  local mode="$1"
  local resource_id="$2"
  local label="$3"
  [[ "$mode" == "create" ]] || return 0
  if az resource show --ids "$resource_id" >/dev/null 2>&1; then
    die "$label already exists; choose reuse and provide its ARM resource ID"
  fi
}

azure_collect_subnet() {
  local mode_variable="$1"
  local id_variable="$2"
  local name_variable="$3"
  local prefix_variable="$4"
  local label="$5"
  local default_name="$6"
  local default_prefix="$7"
  azure_select_mode "$mode_variable" "$label" "$( [[ "$VNET_MODE" == "create" ]] && printf create || printf reuse )"
  local mode="${!mode_variable}"
  if [[ "$VNET_MODE" == "create" && "$mode" != "create" ]]; then
    die "$label cannot be reused when the VNet is newly created"
  fi
  if [[ "$mode" == "create" ]]; then
    if [[ "$VNET_MODE" == "reuse" ]]; then
      local vnet_group
      vnet_group="$(azure_resource_group "$VNET_RESOURCE_ID")"
      [[ "${vnet_group,,}" == "${AZURE_RESOURCE_GROUP,,}" ]] || {
        die "creating $label in a reused VNet currently requires the VNet and deployment to use the same resource group"
      }
    fi
    azure_prompt_required "$name_variable" "$label name" "$default_name"
    azure_prompt_required "$prefix_variable" "$label CIDR" "$default_prefix"
    azure_validate_name "${!name_variable}" "$label name"
    printf -v "$id_variable" '%s' "$VNET_RESOURCE_ID/subnets/${!name_variable}"
  else
    azure_select_existing_subnet "$id_variable" "$label subnets" "$label ARM resource ID"
    azure_validate_resource_id "${!id_variable}" "Microsoft.Network/virtualNetworks/subnets" "$label"
    local subnet_id="${!id_variable}"
    local parent_id="${subnet_id%/subnets/*}"
    [[ "${parent_id,,}" == "${VNET_RESOURCE_ID,,}" ]] || {
      die "$label does not belong to selected VNet"
    }
  fi
}

azure_collect_network() {
  azure_select_mode VNET_MODE "Virtual network" create
  if [[ "$VNET_MODE" == "create" ]]; then
    azure_prompt_required VNET_NAME "Virtual network name" "vnet-ghcp-$ENVIRONMENT"
    azure_prompt_required VNET_ADDRESS_PREFIX "Virtual network CIDR" "10.42.0.0/16"
    azure_validate_name "$VNET_NAME" "Virtual network name"
    VNET_RESOURCE_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/$VNET_NAME"
  else
    azure_select_existing_resource VNET_RESOURCE_ID "Microsoft.Network/virtualNetworks" \
      "virtual networks" "Virtual network ARM resource ID"
    azure_validate_resource_id "$VNET_RESOURCE_ID" "Microsoft.Network/virtualNetworks" "Virtual network"
    VNET_NAME="$(azure_resource_name "$VNET_RESOURCE_ID")"
  fi

  azure_collect_subnet AKS_SUBNET_MODE AKS_SUBNET_RESOURCE_ID AKS_SUBNET_NAME AKS_SUBNET_PREFIX \
    azure_select_existing_resource AKS_RESOURCE_ID "Microsoft.ContainerService/managedClusters" \
      "AKS clusters" "AKS ARM resource ID"
  azure_collect_subnet POSTGRES_SUBNET_MODE POSTGRES_SUBNET_RESOURCE_ID POSTGRES_SUBNET_NAME POSTGRES_SUBNET_PREFIX \
    "PostgreSQL delegated subnet" "snet-postgresql" "10.42.16.0/24"
  azure_collect_subnet PRIVATE_ENDPOINT_SUBNET_MODE PRIVATE_ENDPOINT_SUBNET_RESOURCE_ID \
    PRIVATE_ENDPOINT_SUBNET_NAME PRIVATE_ENDPOINT_SUBNET_PREFIX \
    "Private endpoint subnet" "snet-private-endpoints" "10.42.17.0/24"
}

azure_validate_reused_aks() {
  local group name provisioning_state node_count subnet_ids subnet_id subnet_vnet
  local selected_subnet_found=0
  group="$(azure_resource_group "$AKS_RESOURCE_ID")"
  name="$(azure_resource_name "$AKS_RESOURCE_ID")"
  provisioning_state="$(az aks show --resource-group "$group" --name "$name" --query provisioningState -o tsv)"
  [[ "$provisioning_state" == "Succeeded" ]] || die "AKS provisioning state is $provisioning_state"
  node_count="$(az aks show --resource-group "$group" --name "$name" --query 'agentPoolProfiles[].count | sum(@)' -o tsv)"
  if [[ "$ENVIRONMENT" == "staging" && "${node_count:-0}" -lt 2 ]]; then
    die "staging requires at least two AKS nodes; reused cluster reports $node_count"
  fi
  subnet_ids="$(az aks show --resource-group "$group" --name "$name" --query 'agentPoolProfiles[].vnetSubnetId' -o tsv)"
  [[ -n "$subnet_ids" ]] || die "reused AKS does not report a node subnet"
  for subnet_id in $subnet_ids; do
    subnet_vnet="${subnet_id%/subnets/*}"
    [[ "${subnet_vnet,,}" == "${VNET_RESOURCE_ID,,}" ]] || {
      die "reused AKS node subnet is outside the selected VNet: $subnet_id"
    }
    if [[ "${subnet_id,,}" == "${AKS_SUBNET_RESOURCE_ID,,}" ]]; then
      selected_subnet_found=1
    fi
  done
  [[ "$selected_subnet_found" -eq 1 ]] || {
    die "reused AKS does not use the selected AKS node subnet"
  }
}

azure_validate_reused_postgres() {
  local public_access delegated_subnet
  public_access="$(az resource show --ids "$POSTGRES_RESOURCE_ID" --api-version 2024-08-01 \
    --query properties.network.publicNetworkAccess -o tsv 2>/dev/null || true)"
  [[ -z "$public_access" || "$public_access" == "Disabled" ]] || {
    die "reused PostgreSQL must have public network access disabled"
  }
  delegated_subnet="$(az resource show --ids "$POSTGRES_RESOURCE_ID" --api-version 2024-08-01 \
    --query properties.network.delegatedSubnetResourceId -o tsv 2>/dev/null || true)"
  [[ -n "$delegated_subnet" ]] || die "reused PostgreSQL must use a delegated subnet"
  [[ "${delegated_subnet,,}" == "${POSTGRES_SUBNET_RESOURCE_ID,,}" ]] || {
    die "reused PostgreSQL is not attached to the selected delegated subnet"
  }
}

azure_validate_reused_redis() {
  local database_id="$REDIS_RESOURCE_ID/databases/default"
  local policy protocol port access_keys public_access
  public_access="$(az resource show --ids "$REDIS_RESOURCE_ID" --api-version 2025-07-01 \
    --query properties.publicNetworkAccess -o tsv 2>/dev/null || true)"
  [[ "$public_access" == "Disabled" ]] || die "reused Azure Managed Redis must have public network access disabled"
  policy="$(az resource show --ids "$database_id" --api-version 2025-07-01 --query properties.clusteringPolicy -o tsv)" || {
    die "reused Azure Managed Redis default database is missing or unreadable"
  }
  protocol="$(az resource show --ids "$database_id" --api-version 2025-07-01 --query properties.clientProtocol -o tsv)"
  port="$(az resource show --ids "$database_id" --api-version 2025-07-01 --query properties.port -o tsv)"
  access_keys="$(az resource show --ids "$database_id" --api-version 2025-07-01 --query properties.accessKeysAuthentication -o tsv)"
  [[ "$policy" == "NoCluster" ]] || die "reused Redis must use NoCluster; found $policy"
  [[ "$protocol" == "Encrypted" ]] || die "reused Redis must require encrypted clients; found $protocol"
  [[ "$port" == "10000" ]] || die "reused Redis must expose port 10000; found $port"
  [[ "$access_keys" == "Enabled" || -n "${REDIS_PASSWORD:-}" ]] || {
    die "reused Redis has access keys disabled; REDIS_PASSWORD must provide a supported data-plane credential"
  }
}

azure_collect_services() {
  local suffix="${AZURE_SUBSCRIPTION_ID//-/}"
  suffix="${suffix:0:6}"
  local base_name="ghcp-$ENVIRONMENT-$suffix"

  azure_select_mode AKS_MODE "AKS cluster" create
  if [[ "$AKS_MODE" == "create" ]]; then
    azure_prompt_required AKS_NAME "AKS cluster name" "$base_name-aks"
    prompt_default AKS_NODE_COUNT "AKS system node count" "$( [[ "$ENVIRONMENT" == "staging" ]] && printf 2 || printf 3 )"
    prompt_default AKS_NODE_VM_SIZE "AKS system node VM size" "Standard_D4ds_v5"
    prompt_default AKS_SKU_TIER "AKS pricing tier (Free/Standard/Premium)" "Standard"
    azure_validate_name "$AKS_NAME" "AKS cluster name"
    [[ "$AKS_NODE_COUNT" =~ ^[1-9][0-9]*$ ]] || die "AKS_NODE_COUNT must be a positive integer"
    [[ "$AKS_SKU_TIER" == "Free" || "$AKS_SKU_TIER" == "Standard" || "$AKS_SKU_TIER" == "Premium" ]] || {
      die "AKS_SKU_TIER must be Free, Standard, or Premium"
    }
    [[ "$ENVIRONMENT" != "staging" || "$AKS_NODE_COUNT" -ge 2 ]] || die "staging requires at least two AKS nodes"
    [[ "$ENVIRONMENT" != "production" || "$AKS_SKU_TIER" != "Free" ]] || die "production AKS cannot use the Free tier"
    AKS_RESOURCE_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$AKS_NAME"
  else
    azure_prompt_required AKS_RESOURCE_ID "AKS ARM resource ID"
    azure_validate_resource_id "$AKS_RESOURCE_ID" "Microsoft.ContainerService/managedClusters" "AKS cluster"
    AKS_NAME="$(azure_resource_name "$AKS_RESOURCE_ID")"
    azure_validate_reused_aks
    AKS_NODE_COUNT=1
    AKS_NODE_VM_SIZE="Standard_D4ds_v5"
    AKS_SKU_TIER="Standard"
  fi

  azure_select_mode POSTGRES_MODE "PostgreSQL Flexible Server" create
  prompt_default POSTGRES_DATABASE_NAME "PostgreSQL database name" "ghcp"
  if [[ "$POSTGRES_MODE" == "create" ]]; then
    azure_prompt_required POSTGRES_NAME "PostgreSQL server name" "$base_name-pg"
    azure_prompt_required POSTGRES_ADMINISTRATOR_LOGIN "PostgreSQL administrator login" "ghcpadmin"
    if [[ "$ACTION" == "apply" ]]; then
      prompt_secret POSTGRES_ADMINISTRATOR_PASSWORD "PostgreSQL administrator password"
    else
      POSTGRES_ADMINISTRATOR_PASSWORD="${POSTGRES_ADMINISTRATOR_PASSWORD:-render-only-placeholder}"
    fi
    prompt_default POSTGRES_SKU_NAME "PostgreSQL compute SKU" "Standard_D2ds_v5"
    prompt_default POSTGRES_SKU_TIER "PostgreSQL SKU tier" "GeneralPurpose"
    prompt_default POSTGRES_STORAGE_SIZE_GB "PostgreSQL storage GiB" "128"
    prompt_default POSTGRES_HIGH_AVAILABILITY "PostgreSQL HA (Disabled/SameZone/ZoneRedundant)" "ZoneRedundant"
    azure_validate_name "$POSTGRES_NAME" "PostgreSQL server name"
    [[ "$POSTGRES_STORAGE_SIZE_GB" =~ ^[1-9][0-9]*$ ]] || die "POSTGRES_STORAGE_SIZE_GB must be a positive integer"
    [[ "$POSTGRES_HIGH_AVAILABILITY" == "Disabled" || "$POSTGRES_HIGH_AVAILABILITY" == "SameZone" || "$POSTGRES_HIGH_AVAILABILITY" == "ZoneRedundant" ]] || {
      die "invalid POSTGRES_HIGH_AVAILABILITY"
    }
    [[ "$ENVIRONMENT" != "production" || "$POSTGRES_HIGH_AVAILABILITY" != "Disabled" ]] || {
      die "production PostgreSQL cannot disable high availability"
    }
    POSTGRES_RESOURCE_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.DBforPostgreSQL/flexibleServers/$POSTGRES_NAME"
  else
    azure_select_existing_resource POSTGRES_RESOURCE_ID "Microsoft.DBforPostgreSQL/flexibleServers" \
      "PostgreSQL Flexible Servers" "PostgreSQL ARM resource ID"
    azure_validate_resource_id "$POSTGRES_RESOURCE_ID" "Microsoft.DBforPostgreSQL/flexibleServers" "PostgreSQL"
    POSTGRES_NAME="$(azure_resource_name "$POSTGRES_RESOURCE_ID")"
    POSTGRES_ADMINISTRATOR_LOGIN=""
    POSTGRES_ADMINISTRATOR_PASSWORD=""
    POSTGRES_SKU_NAME="Standard_D2ds_v5"
    POSTGRES_SKU_TIER="GeneralPurpose"
    POSTGRES_STORAGE_SIZE_GB=128
    POSTGRES_HIGH_AVAILABILITY="ZoneRedundant"
    azure_validate_reused_postgres
  fi

  azure_select_mode REDIS_MODE "Azure Managed Redis" create
  if [[ "$REDIS_MODE" == "create" ]]; then
    azure_prompt_required REDIS_NAME "Azure Managed Redis name" "$base_name-redis"
    prompt_default REDIS_SKU_NAME "Azure Managed Redis SKU" "Balanced_B3"
    azure_validate_name "$REDIS_NAME" "Azure Managed Redis name"
    REDIS_RESOURCE_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$AZURE_RESOURCE_GROUP/providers/Microsoft.Cache/redisEnterprise/$REDIS_NAME"
  else
    azure_select_existing_resource REDIS_RESOURCE_ID "Microsoft.Cache/redisEnterprise" \
      "Azure Managed Redis resources" "Azure Managed Redis ARM resource ID"
    azure_validate_resource_id "$REDIS_RESOURCE_ID" "Microsoft.Cache/redisEnterprise" "Azure Managed Redis"
    REDIS_NAME="$(azure_resource_name "$REDIS_RESOURCE_ID")"
    REDIS_SKU_NAME="Balanced_B3"
    azure_validate_reused_redis
  fi

  if [[ "$AZURE_RESOURCE_GROUP_MODE" == "reuse" ]]; then
    azure_assert_create_target_absent "$VNET_MODE" "$VNET_RESOURCE_ID" "Virtual network"
    azure_assert_create_target_absent "$AKS_SUBNET_MODE" "$AKS_SUBNET_RESOURCE_ID" "AKS node subnet"
    azure_assert_create_target_absent "$POSTGRES_SUBNET_MODE" "$POSTGRES_SUBNET_RESOURCE_ID" "PostgreSQL delegated subnet"
    azure_assert_create_target_absent "$PRIVATE_ENDPOINT_SUBNET_MODE" "$PRIVATE_ENDPOINT_SUBNET_RESOURCE_ID" "Private endpoint subnet"
    azure_assert_create_target_absent "$AKS_MODE" "$AKS_RESOURCE_ID" "AKS cluster"
    azure_assert_create_target_absent "$POSTGRES_MODE" "$POSTGRES_RESOURCE_ID" "PostgreSQL server"
    azure_assert_create_target_absent "$REDIS_MODE" "$REDIS_RESOURCE_ID" "Azure Managed Redis"
  fi
}

azure_write_parameters() {
  umask 077
  AZURE_PARAMETERS_FILE="$(mktemp)"
  jq -n \
    --arg location "$AZURE_LOCATION" \
    --arg environment "$ENVIRONMENT" \
    --arg owner "$AZURE_OWNER" \
    --arg costCenter "$AZURE_COST_CENTER" \
    --arg deploymentId "$AZURE_DEPLOYMENT_ID" \
    --arg vnetMode "$VNET_MODE" --arg vnetName "$VNET_NAME" --arg vnetResourceId "$VNET_RESOURCE_ID" --arg vnetAddressPrefix "${VNET_ADDRESS_PREFIX:-}" \
    --arg aksSubnetMode "$AKS_SUBNET_MODE" --arg aksSubnetName "${AKS_SUBNET_NAME:-}" --arg aksSubnetResourceId "$AKS_SUBNET_RESOURCE_ID" --arg aksSubnetPrefix "${AKS_SUBNET_PREFIX:-}" \
    --arg postgresSubnetMode "$POSTGRES_SUBNET_MODE" --arg postgresSubnetName "${POSTGRES_SUBNET_NAME:-}" --arg postgresSubnetResourceId "$POSTGRES_SUBNET_RESOURCE_ID" --arg postgresSubnetPrefix "${POSTGRES_SUBNET_PREFIX:-}" \
    --arg privateEndpointSubnetMode "$PRIVATE_ENDPOINT_SUBNET_MODE" --arg privateEndpointSubnetName "${PRIVATE_ENDPOINT_SUBNET_NAME:-}" --arg privateEndpointSubnetResourceId "$PRIVATE_ENDPOINT_SUBNET_RESOURCE_ID" --arg privateEndpointSubnetPrefix "${PRIVATE_ENDPOINT_SUBNET_PREFIX:-}" \
    --arg aksMode "$AKS_MODE" --arg aksName "$AKS_NAME" --arg aksResourceId "$AKS_RESOURCE_ID" --arg aksNodeVmSize "$AKS_NODE_VM_SIZE" --arg aksSkuTier "$AKS_SKU_TIER" --argjson aksNodeCount "$AKS_NODE_COUNT" \
    --arg postgresMode "$POSTGRES_MODE" --arg postgresName "$POSTGRES_NAME" --arg postgresResourceId "$POSTGRES_RESOURCE_ID" --arg postgresDatabaseName "$POSTGRES_DATABASE_NAME" \
    --arg postgresAdministratorLogin "$POSTGRES_ADMINISTRATOR_LOGIN" --arg postgresAdministratorPassword "$POSTGRES_ADMINISTRATOR_PASSWORD" --arg postgresSkuName "$POSTGRES_SKU_NAME" --arg postgresSkuTier "$POSTGRES_SKU_TIER" \
    --argjson postgresStorageSizeGB "$POSTGRES_STORAGE_SIZE_GB" --arg postgresHighAvailability "$POSTGRES_HIGH_AVAILABILITY" \
    --arg redisMode "$REDIS_MODE" --arg redisName "$REDIS_NAME" --arg redisResourceId "$REDIS_RESOURCE_ID" --arg redisSkuName "$REDIS_SKU_NAME" \
    '{
      "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
      contentVersion: "1.0.0.0",
      parameters: {
        location: {value: $location},
        tags: {value: {application: "ghcp-pool-proxy", environment: $environment, owner: $owner, costCenter: $costCenter, managedBy: "deploy-cluster.sh", deploymentId: $deploymentId}},
        vnetMode: {value: $vnetMode}, vnetName: {value: $vnetName}, vnetResourceId: {value: $vnetResourceId}, vnetAddressPrefix: {value: $vnetAddressPrefix},
        aksSubnetMode: {value: $aksSubnetMode}, aksSubnetName: {value: $aksSubnetName}, aksSubnetResourceId: {value: $aksSubnetResourceId}, aksSubnetPrefix: {value: $aksSubnetPrefix},
        postgresSubnetMode: {value: $postgresSubnetMode}, postgresSubnetName: {value: $postgresSubnetName}, postgresSubnetResourceId: {value: $postgresSubnetResourceId}, postgresSubnetPrefix: {value: $postgresSubnetPrefix},
        privateEndpointSubnetMode: {value: $privateEndpointSubnetMode}, privateEndpointSubnetName: {value: $privateEndpointSubnetName}, privateEndpointSubnetResourceId: {value: $privateEndpointSubnetResourceId}, privateEndpointSubnetPrefix: {value: $privateEndpointSubnetPrefix},
        aksMode: {value: $aksMode}, aksName: {value: $aksName}, aksResourceId: {value: $aksResourceId}, aksNodeCount: {value: $aksNodeCount}, aksNodeVmSize: {value: $aksNodeVmSize}, aksSkuTier: {value: $aksSkuTier},
        postgresMode: {value: $postgresMode}, postgresName: {value: $postgresName}, postgresResourceId: {value: $postgresResourceId}, postgresDatabaseName: {value: $postgresDatabaseName},
        postgresAdministratorLogin: {value: $postgresAdministratorLogin}, postgresAdministratorPassword: {value: $postgresAdministratorPassword}, postgresSkuName: {value: $postgresSkuName}, postgresSkuTier: {value: $postgresSkuTier}, postgresStorageSizeGB: {value: $postgresStorageSizeGB}, postgresHighAvailability: {value: $postgresHighAvailability},
        redisMode: {value: $redisMode}, redisName: {value: $redisName}, redisResourceId: {value: $redisResourceId}, redisSkuName: {value: $redisSkuName}
      }
    }' > "$AZURE_PARAMETERS_FILE"
  chmod 600 "$AZURE_PARAMETERS_FILE"
}

azure_ensure_provider() {
  local namespace="$1"
  local state
  state="$(az provider show --namespace "$namespace" --query registrationState -o tsv 2>/dev/null || true)"
  [[ "$state" == "Registered" ]] && return 0
  log "Registering Azure resource provider $namespace"
  az provider register --namespace "$namespace" --wait
}

azure_prepare_control_plane() {
  if [[ "$AZURE_RESOURCE_GROUP_MODE" == "create" ]]; then
    az group create --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_LOCATION" \
      --tags application=ghcp-pool-proxy environment="$ENVIRONMENT" managedBy=deploy-cluster.sh >/dev/null
  fi
  azure_ensure_provider Microsoft.Network
  azure_ensure_provider Microsoft.ManagedIdentity
  azure_ensure_provider Microsoft.ContainerService
  azure_ensure_provider Microsoft.DBforPostgreSQL
  azure_ensure_provider Microsoft.Cache
}

azure_set_created_outputs() {
  local output_file="$1"
  AKS_RESOURCE_ID="$(jq -r '.aksId.value' "$output_file")"
  AKS_NAME="$(jq -r '.aksName.value' "$output_file")"
  POSTGRES_RESOURCE_ID="$(jq -r '.postgresId.value' "$output_file")"
  POSTGRES_HOST="$(jq -r '.postgresHost.value' "$output_file")"
  REDIS_RESOURCE_ID="$(jq -r '.redisId.value' "$output_file")"
  REDIS_HOST="$(jq -r '.redisHost.value' "$output_file")"
}

azure_set_reused_endpoints() {
  if [[ "$POSTGRES_MODE" == "reuse" ]]; then
    POSTGRES_HOST="$(az resource show --ids "$POSTGRES_RESOURCE_ID" --api-version 2024-08-01 \
      --query properties.fullyQualifiedDomainName -o tsv)"
  fi
  if [[ "$REDIS_MODE" == "reuse" ]]; then
    REDIS_HOST="$(az resource show --ids "$REDIS_RESOURCE_ID" --api-version 2025-07-01 \
      --query properties.hostName -o tsv)"
  fi
  [[ -n "$POSTGRES_HOST" ]] || die "could not resolve PostgreSQL hostname"
  [[ -n "$REDIS_HOST" ]] || die "could not resolve Azure Managed Redis hostname"
  POSTGRES_PORT=5432
  REDIS_ADDR="$REDIS_HOST:10000"
  REDIS_TLS_SERVER_NAME="$REDIS_HOST"
}

azure_prepare_infrastructure() {
  [[ -r "$AZURE_TEMPLATE" ]] || die "Azure Bicep template is missing: $AZURE_TEMPLATE"
  prereq_ensure_azure_tools
  azure_login
  azure_collect_resource_group
  azure_collect_network
  azure_collect_services
  azure_write_parameters
  log "Compiling Azure Bicep template"
  az bicep build --file "$AZURE_TEMPLATE" --stdout >/dev/null

  if [[ "$ACTION" == "--render" ]]; then
    POSTGRES_HOST="${POSTGRES_HOST:-$POSTGRES_NAME.postgres.database.azure.com}"
    REDIS_HOST="${REDIS_HOST:-$REDIS_NAME.$AZURE_LOCATION.redis.azure.net}"
    azure_set_reused_endpoints
    return 0
  fi

  azure_confirm "Prepare Azure providers/resource group and run what-if for deployment $AZURE_DEPLOYMENT_NAME?"
  azure_prepare_control_plane
  log "Azure what-if: $AZURE_RESOURCE_GROUP/$AZURE_DEPLOYMENT_NAME"
  az deployment group what-if \
    --name "$AZURE_DEPLOYMENT_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file "$AZURE_TEMPLATE" \
    --parameters "@$AZURE_PARAMETERS_FILE" \
    --result-format ResourceIdOnly
  azure_confirm "Apply the reviewed Azure what-if result?"

  [[ -n "$WORK_DIR" ]] || WORK_DIR="$(mktemp -d)"
  local output_file="$WORK_DIR/azure-outputs.json"
  az deployment group create \
    --name "$AZURE_DEPLOYMENT_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file "$AZURE_TEMPLATE" \
    --parameters "@$AZURE_PARAMETERS_FILE" \
    --query properties.outputs -o json > "$output_file"
  azure_set_created_outputs "$output_file"
  azure_set_reused_endpoints
}

azure_prepare_kube_context() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    kube cluster-info >/dev/null || die "Kubernetes context is not reachable: $KUBE_CONTEXT"
    return 0
  fi
  [[ -n "$WORK_DIR" ]] || WORK_DIR="$(mktemp -d)"
  local group kubeconfig
  group="$(azure_resource_group "$AKS_RESOURCE_ID")"
  kubeconfig="$WORK_DIR/aks-kubeconfig"
  az aks get-credentials --resource-group "$group" --name "$AKS_NAME" \
    --file "$kubeconfig" --overwrite-existing >/dev/null
  chmod 600 "$kubeconfig"
  export KUBECONFIG="$kubeconfig"
  KUBE_CONTEXT="$($KUBECTL config current-context)"
  kube cluster-info >/dev/null || die "AKS API is not reachable"
}

azure_default_migration_dsn() {
  [[ "$POSTGRES_MODE" == "create" ]] || return 0
  local encoded_user encoded_password encoded_database
  encoded_user="$(jq -rn --arg value "$POSTGRES_ADMINISTRATOR_LOGIN" '$value | @uri')"
  encoded_password="$(jq -rn --arg value "$POSTGRES_ADMINISTRATOR_PASSWORD" '$value | @uri')"
  encoded_database="$(jq -rn --arg value "$POSTGRES_DATABASE_NAME" '$value | @uri')"
  printf 'postgres://%s:%s@%s:5432/%s?sslmode=require\n' \
    "$encoded_user" "$encoded_password" "$POSTGRES_HOST" "$encoded_database"
}

azure_load_redis_password() {
  [[ -n "${REDIS_PASSWORD:-}" ]] && return 0
  local database_id="$REDIS_RESOURCE_ID/databases/default"
  REDIS_PASSWORD="$(az rest --method post \
    --url "https://management.azure.com${database_id}/listKeys?api-version=2025-07-01" \
    --query primaryKey -o tsv 2>/dev/null || true)"
  if [[ -z "$REDIS_PASSWORD" ]]; then
    prompt_secret REDIS_PASSWORD "Azure Managed Redis access key"
  fi
}