-include .env
export

.PHONY: anvil build test abi deploy upgrade

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
	jq '.abi' out/MockERC20.sol/MockERC20.json > abi/MockERC20.json

deploy: build
	forge script script/Deploy.s.sol:DeployScript --rpc-url $(RPC_URL) --broadcast -vvvv

upgrade: build
	forge script script/Upgrade.s.sol:UpgradeScript --rpc-url $(RPC_URL) --broadcast -vvvv
