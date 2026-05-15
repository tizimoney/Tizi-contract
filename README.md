# Tizi Contract

Tizi is a multi-chain stablecoin protocol that issues **TD (Tizi Dollar)** — a yield-bearing stablecoin backed by USDC and deployed across multiple blockchains. Built on a hub-and-spoke architecture with Base as the main chain, Tizi enables users to earn yields on DeFi strategies across multiple chains, including Sei, Sonic, Ethereum, Arbitrum, Avalanche, BSC, and Optimism.

## Table of Contents

- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Dependencies](#dependencies)
- [Development](#development)
- [Security](#security)

## Architecture

Tizi follows a **hub-and-spoke model** centered on Base chain. The main chain manages deposits, withdrawals, staking, and yield distribution, while sub-chains host vaults that deploy capital into external DeFi strategies.

- **TD (Tizi Dollar)** — Cross-chain stablecoin minted 1:1 against USDC deposits. Uses LayerZero OFT for omnichain transfers.
- **stTD (Staked TD)** — Yield-bearing ERC4626 token. Users stake TD to receive stTD and earn strategy yield distributed linearly over time.
- **Vaults** — `MainVault` on Base receives deposits and distributes USDC to sub-chain vaults via CCTP and CCIP. Sub-chain vaults deploy funds into whitelisted strategies.
- **Update Yield** — Cross-chain statistics aggregation via LayerZero and Axelar feeds into `MainTokenStats`, which calculates total net asset value for periodic yield distribution.
- **Access Control** — Role-based (Admin, Manager, Strategist) with timelock governance on each chain.

For detailed protocol documentation, visit [tizi.money](https://tizi.money).

## Repository Structure

```
contracts/
├── TiziDollar.sol                # Cross-chain stablecoin (ERC20Permit + LayerZero OFT)
├── StakedTD.sol                  # Upgradeable ERC4626 staking vault (Base)
├── ChildstTD.sol                 # ERC4626 staking token for sub-chains
├── STTDAdapter.sol               # OFTAdapter for stTD cross-chain transfers
├── StakeVault.sol                # TD custody vault for staking operations
├── DepositHelper.sol             # User-facing deposit & withdrawal gateway (Base)
├── StrategyManager.sol           # Strategy lifecycle management (Base)
├── SubStrategyManager.sol        # Strategy lifecycle management (sub-chains)
├── AuthorityControl/             # Role-based access control
├── crosschain/                   # LayerZero & Axelar cross-chain messaging
├── interfaces/                   # Shared interfaces
├── Nft/                          # Withdrawal NFT (TUWT) & NFT vault
├── Statistics/                   # Cross-chain asset statistics & update yield
├── TimeLock/                     # Timelock governance controllers
└── Vault/                        # MainVault (Base) & SubVault (sub-chains)
```

```
hardhat.config.js                 # Hardhat configuration
package.json                      # Node dependencies & scripts
```

## Dependencies

### Required

- **[Node.js](https://nodejs.org/)** >= 18
- **[npm](https://www.npmjs.com/)** >= 9

### Install

```bash
# Clone the repository
git clone https://github.com/iridea-nj/Tizi.git
cd Tizi-contract

# Copy environment template and populate
cp .env.example .env

# Install dependencies
npm install
```

### Key Libraries


| Package                                      | Usage                                                |
| -------------------------------------------- | ---------------------------------------------------- |
| `@openzeppelin/contracts` v5                 | ERC20, ERC721, ERC4626, AccessControl, UUPS upgrades |
| `@layerzerolabs/oft-evm` v3                  | TD and stTD omnichain transfers                      |
| `@layerzerolabs/oapp-evm` v0.3               | Cross-chain messaging                                |
| `@axelar-network/axelar-gmp-sdk-solidity` v5 | Alternative cross-chain messaging                    |
| `@chainlink/contracts-ccip`                  | USDC cross-chain transfers                           |
| `@pythnetwork/pyth-sdk-solidity` v4          | Oracle price feeds                                   |
| `ethers` v6                                  | Blockchain interaction                               |


## Development

### Build

```bash
# Compile contracts
npx hardhat compile
```

### Testing

```bash
# Run test suite
npx hardhat test

# Run with coverage
npx hardhat coverage
```

### Code Quality

```bash
# Check contract sizes
npx hardhat size-contracts

# Format code
npx prettier --write 'contracts/**/*.sol'
```

### Networks


| Network     | Config Name         |
| ----------- | ------------------- |
| Base        | `base_mainnet`      |
| Arbitrum    | `arb_mainnet`       |
| Avalanche   | `avalanche_mainnet` |
| Optimism    | `op_mainnet`        |
| BSC Testnet | `bsc_testnet`       |
| Sepolia     | `eth_testnet`       |
| Local       | `localnet`          |


## Security

Tizi implements multiple layers of security:

- **Role-based access control** with separation between Admin, Manager, and Strategist roles
- **Timelock governance** on all admin operations across every chain
- **Upgradeable contracts** (StakedTD) follow OpenZeppelin UUPS pattern

### Audits

Audit reports are available at [tizimoney.gitbook.io/tizi/other/audits](https://tizimoney.gitbook.io/tizi/other/audits).

## License

MIT © 2024 Tizi — see [LICENSE](./LICENSE)