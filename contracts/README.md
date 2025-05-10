## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Deploy PriceOracle

To deploy the PriceOracle contract to Sepolia:

```shell
$ forge script script/PriceOracle.s.sol --rpc-url <your_rpc_url> --broadcast --verify -vvvv --private-key <your_private_key> --via-ir
```

Replace `<your_rpc_url>` with your Infura or other RPC provider URL and `<your_private_key>` with your wallet's private key.

Deployed PriceOracle Contract Address (Sepolia):
```
0xa45b494b08da460B011A379933f476Cb4566e01e
```

View on Etherscan: [PriceOracle Contract](https://sepolia.etherscan.io/address/0xa45b494b08da460b011a379933f476cb4566e01e#readContract)

To verify the contract on Sepolia:
```shell
$ forge verify-contract 0xa45b494b08da460B011A379933f476Cb4566e01e src/PriceOracle.sol:PriceOracle --chain-id 11155111 --watch --etherscan-api-key <your_etherscan_api_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
