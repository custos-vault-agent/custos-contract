-include .env
export

.PHONY: anvil build test abi deploy upgrade

# --code-size-limit: CustosCore is ~291 bytes over the EIP-170 24576-byte
# limit (pre-existing, from the vault-per-agent rewrite). Real chains would
# reject deploying it; this only exists so local Anvil accepts it too, to
# pair with forge's own --disable-code-size-limit below.
anvil:
	anvil --code-size-limit 40000

build:
	forge build

test:
	forge test -vvv

abi: build
	mkdir -p abi
	jq '.abi' out/CustosCore.sol/CustosCore.json > abi/CustosCore.json
	jq '.abi' out/AgentVault.sol/AgentVault.json > abi/AgentVault.json
	jq '.abi' out/MockERC20.sol/MockERC20.json > abi/MockERC20.json

# CustosCore is currently ~291 bytes over the EIP-170 24576-byte limit
# (pre-existing, from the vault-per-agent rewrite — nothing in this plan
# added to its size). --disable-code-size-limit is a local-Anvil-only
# escape hatch so deploy/upgrade keep working here; it does NOT make the
# contract deployable on a real chain. See the plan's self-review note —
# splitting CustosCore into smaller facets is a real, separate follow-up.
deploy: build
	mkdir -p deployments
	forge script script/Deploy.s.sol:DeployScript --rpc-url $(RPC_URL) --broadcast --disable-code-size-limit -vvvv

upgrade: build
	mkdir -p deployments
	forge script script/Upgrade.s.sol:UpgradeScript --rpc-url $(RPC_URL) --broadcast --disable-code-size-limit -vvvv
