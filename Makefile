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
	jq '.abi' out/NansenModule.sol/NansenModule.json > abi/NansenModule.json
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
