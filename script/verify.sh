#!/usr/bin/env bash
# Verifies the deployed Custos contracts on a block explorer. Run it through
# `make verify`. Addresses come from DEPLOYMENT_FILE and constructor arguments
# from the chain, so that file and RPC_URL must be the same network.
#
# `make verifyVault VAULT=<address>` verifies one AgentVault instead. Every vault
# has the same bytecode, so one verified vault is usually enough for an explorer
# to recognise the others.
#
# DRY_RUN=1 prints each contract with its encoded constructor arguments and calls
# no verifier. Use it when a verification fails and you want to see the arguments.
set -euo pipefail

: "${RPC_URL:?set RPC_URL}"
FILE=${DEPLOYMENT_FILE:-deployments/anvil.json}
VERIFIER=${VERIFIER:-sourcify}
CHAIN=$(cast chain-id --rpc-url "$RPC_URL")

FLAGS=(--chain "$CHAIN" --verifier "$VERIFIER" --watch)
[ -n "${VERIFIER_URL:-}" ] && FLAGS+=(--verifier-url "$VERIFIER_URL")
[ -n "${VERIFIER_API_KEY:-}" ] && FLAGS+=(--verifier-api-key "$VERIFIER_API_KEY")

# `cast call` prints a uint as "500000000 [5e8]" and a string in quotes.
call() { cast call "$1" "$2" --rpc-url "$RPC_URL"; }
num() { call "$1" "$2" | awk '{print $1}'; }
str() { call "$1" "$2" | sed 's/^"//; s/"$//'; }
addr() { jq -r --arg k "$1" '.[$k] // empty' "$FILE"; }

# <address> <path:Name> [abi-encoded constructor args]
verify() {
	if [ -z "$1" ]; then echo "skip $2: not in $FILE"; return; fi
	echo "==> $2 at $1"
	if [ -n "${DRY_RUN:-}" ]; then echo "    args ${3:-none}"; return; fi
	if [ -n "${3:-}" ]; then
		forge verify-contract "$1" "$2" --constructor-args "$3" "${FLAGS[@]}"
	else
		forge verify-contract "$1" "$2" "${FLAGS[@]}"
	fi
}

# ---------------------------------------------------------------------------
# One vault. `allowance` and `periodLength` change after deployment, so pass
# ALLOWANCE and PERIOD from the AgentRegistered event if the creator moved them.
# ---------------------------------------------------------------------------
if [ -n "${VAULT:-}" ]; then
	verify "$VAULT" src/AgentVault.sol:AgentVault "$(cast abi-encode \
		"constructor(bytes32,address,address,address,address,address,address,uint16,uint16,uint16,uint128,uint32,string,string)" \
		"$(call "$VAULT" "agentId()(bytes32)")" \
		"$(call "$VAULT" "creator()(address)")" \
		"$(call "$VAULT" "agent()(address)")" \
		"$(call "$VAULT" "custosCore()(address)")" \
		"$(call "$VAULT" "asset()(address)")" \
		"$(call "$VAULT" "priceOracle()(address)")" \
		"$(call "$VAULT" "yieldSource()(address)")" \
		"$(num "$VAULT" "feeRate()(uint16)")" \
		"$(num "$VAULT" "maxDrawdownBps()(uint16)")" \
		"$(num "$VAULT" "maxUtilizationBps()(uint16)")" \
		"${ALLOWANCE:-$(num "$VAULT" "allowance()(uint128)")}" \
		"${PERIOD:-$(num "$VAULT" "periodLength()(uint32)")}" \
		"$(str "$VAULT" "name()(string)")" \
		"$(str "$VAULT" "symbol()(string)")")"
	exit 0
fi

test -f "$FILE" || { echo "$FILE not found"; exit 1; }

CORE=$(addr custosProxy)
IMPL=$(addr custosImplementation)
FACTORY=$(addr vaultFactory)
ORACLE=$(addr priceOracle)
MARKET=$(addr market)

verify "$IMPL" src/CustosCore.sol:CustosCore

# The proxy was constructed with the initialize calldata, and initialize took the
# deployer as upgrade authority. Set INIT_AUTHORITY to that address when the
# authority has moved to a multisig since (DEPLOY.md step 5).
if [ -n "$CORE" ] && [ -n "$IMPL" ]; then
	AUTHORITY=${INIT_AUTHORITY:-$(call "$CORE" "upgradeAuthority()(address)")}
	INIT=$(cast calldata "initialize(address,address)" "$AUTHORITY" \
		"$(call "$CORE" "accountingAsset()(address)")")
	verify "$CORE" src/CustosProxy.sol:CustosProxy \
		"$(cast abi-encode "constructor(address,bytes)" "$IMPL" "$INIT")"
fi

# `core` is immutable, so the contract is the source of its own argument.
[ -n "$FACTORY" ] && verify "$FACTORY" src/VaultFactory.sol:VaultFactory \
	"$(cast abi-encode "constructor(address)" "$(call "$FACTORY" "core()(address)")")"

# PriceOracle is Ownable. Set ORACLE_OWNER when ownership was transferred after
# the deployment, because the constructor recorded the original owner.
if [ -n "$ORACLE" ]; then
	verify "$ORACLE" src/PriceOracle.sol:PriceOracle \
		"$(cast abi-encode "constructor(address,address)" \
			"${ORACLE_OWNER:-$(call "$ORACLE" "owner()(address)")}" \
			"$(call "$ORACLE" "quoteToken()(address)")")"
fi

# The adapter took KURU_WMON as its third argument, also for a market whose base
# is already an ERC-20. The chain cannot tell those two cases apart, so this uses
# the same environment value that deployKuruAdapter used.
if [ -n "$MARKET" ]; then
	verify "$MARKET" src/adapters/KuruMarketAdapter.sol:KuruMarketAdapter \
		"$(cast abi-encode "constructor(address,address,address)" \
			"$(call "$MARKET" "router()(address)")" \
			"$(call "$MARKET" "orderbook()(address)")" \
			"${KURU_WMON:-0x0000000000000000000000000000000000000000}")"
fi

echo "done"
