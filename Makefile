-include .env
export

.PHONY: anvil build test abi deploy deployMock deployKuruAdapter deployCore init upgrade upgradeCore addresses verify verifyVault

anvil:
	anvil

build:
	forge build

test:
	forge test -vvv

abi: build
	mkdir -p abi
	jq '.abi' out/CustosCore.sol/CustosCore.json > abi/CustosCore.json
	jq '.abi' out/AgentVault.sol/AgentVault.json > abi/AgentVault.json
	jq '.abi' out/NanSigil.sol/NanSigil.json > abi/NanSigil.json
	jq '.abi' out/MockERC20.sol/MockERC20.json > abi/MockERC20.json

# --slow: Deploy.s.sol broadcasts from several different senders (deployer,
# demo user, script-derived agent wallets) where a later sender's tx
# depends on an earlier sender's already having landed (e.g. an agent
# wallet spending ETH the deployer just sent it). Without --slow, forge
# submits transactions without waiting for prior ones to confirm and a
# dependent tx can hit "insufficient funds" before its funding tx is mined.
deploy: build
	mkdir -p deployments
	forge script script/Deploy.s.sol:DeployScript --rpc-url $(RPC_URL) --broadcast --slow -vvvv

upgrade: build
	mkdir -p deployments
	forge script script/Upgrade.s.sol:UpgradeScript --rpc-url $(RPC_URL) --broadcast --slow -vvvv

# Jalur bertahap untuk jaringan nyata (Monad testnet) — tiap langkah meng-upsert
# key-nya sendiri di DEPLOYMENT_FILE (default deployments/anvil.json), jadi bisa
# dicampur dengan alamat asli lewat env (USDC_ADDRESS, MON_USD_FEED, dst.).
#   deployMock  → token/pasar/yield/feed palsu (skip kalau semua sudah ada)
#   deployKuruAdapter → adapter untuk satu orderbook Kuru asli (ganti deployMock)
#   deployCore  → CustosCore, NanSigil (unless given), VaultFactory, PriceOracle
#   init        → konfigurasi upgradeAuthority; wajib sebelum registerAgent
#   upgradeCore → implementation CustosCore baru ke proxy yang ada
deployMock: build
	mkdir -p deployments
	forge script script/DeployMock.s.sol:DeployMockScript --rpc-url $(RPC_URL) --broadcast --slow -vvvv

# One adapter per real Kuru orderbook. Records it as `.market`, which `init` reads.
deployKuruAdapter: build
	mkdir -p deployments
	forge script script/DeployKuruAdapter.s.sol:DeployKuruAdapterScript --rpc-url $(RPC_URL) --broadcast --slow -vvvv

deployCore: build
	mkdir -p deployments
	forge script script/DeployCore.s.sol:DeployCoreScript --rpc-url $(RPC_URL) --broadcast --slow -vvvv

init: build
	forge script script/Init.s.sol:InitScript --rpc-url $(RPC_URL) --broadcast --slow -vvvv

upgradeCore: build
	forge script script/Upgrade.s.sol:UpgradeScript --rpc-url $(RPC_URL) --broadcast --slow -vvvv

# Verifies the deployed contracts on a block explorer. Addresses come from
# DEPLOYMENT_FILE, constructor arguments from the chain. VERIFIER defaults to
# sourcify, which needs no key; an Etherscan-style or Blockscout explorer needs
# VERIFIER, VERIFIER_URL and usually VERIFIER_API_KEY. DRY_RUN=1 prints the
# arguments and verifies nothing.
verify: build
	./script/verify.sh

# One AgentVault. Pass ALLOWANCE and PERIOD from its AgentRegistered event when
# the creator has changed them since registration.
verifyVault: build
	@test -n "$(VAULT)" || { echo "usage: make verifyVault VAULT=0x..."; exit 1; }
	./script/verify.sh

# Groups deployments/anvil.json's flat address fields by ABI'd contract name
# (matching abi/*.json) and writes deployments/addresses.json, then prints a
# config.yaml-ready `contracts:` block to paste into an Envio indexer.
#
# AgentVault has no fixed address — one is deployed per agent — so its list
# here is only the vaults that existed as of THIS deploy, not exhaustive.
# Envio should still pick up new ones dynamically from AgentRegistered's
# `vault` field (see docs/superpowers/specs/2026-09-14-wire-frontend-to-
# contracts-design.md for the indexer split).
addresses:
	@test -f deployments/anvil.json || { echo "deployments/anvil.json not found — run 'make deploy' first."; exit 1; }
	@jq -n --slurpfile d deployments/anvil.json '{ \
		CustosCore: [$$d[0].custosProxy], \
		NanSigil: [$$d[0].nansigil], \
		MockERC20: [$$d[0].usdc, $$d[0].mon], \
		AgentVault: $$d[0].agentVaults \
	}' > deployments/addresses.json
	@echo "Wrote deployments/addresses.json"
	@echo
	@echo "--- paste into config.yaml's contracts: list ---"
	@jq -r 'to_entries[] | "  - name: " + .key + "\n    address:\n" + (.value | map("    - \"" + . + "\"") | join("\n"))' deployments/addresses.json
