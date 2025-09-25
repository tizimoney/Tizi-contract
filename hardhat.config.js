require("@nomicfoundation/hardhat-toolbox")
require("dotenv").config()
require("hardhat-deploy")
require("hardhat-deploy-ethers")
require("./tasks")

/** @type import('hardhat/config').HardhatUserConfig */
const { projectId, mnemonic1 } = process.env
module.exports = {
    networks: {
        localnet: {
            url: `http://127.0.0.1:7545`,
            accounts: {
                mnemonic: mnemonic1,
            },
        },
        eth_testnet: {
            url: `https://sepolia.infura.io/v3/${projectId}`,
            accounts: {
                mnemonic: mnemonic1,
            },
        },
        polygon: {
            url: `https://polygon-mainnet.infura.io/v3/${projectId}`,
            accounts: {
                mnemonic: mnemonic1,
            },
        },
        polygon_testnet: {
            url: `https://polygon-mumbai.infura.io/v3/${projectId}`,
            accounts: {
                mnemonic: mnemonic1,
            },
            gasLimit: 100000,
            gasPrice: 41697633457,
        },
        polygon_mainnet: {
            url: `https://polygon-mainnet.infura.io/v3/${projectId}`,
            accounts: {
                mnemonic: mnemonic1,
            },
        },
        mantle_mainnet: {
            url: `https://rpc.mantle.xyz`,
            accounts: {
                mnemonic: mnemonic1,
            },
        },
        arb_mainnet: {
            url: `https://arbitrum-mainnet.infura.io/v3/${projectId}`,
            accounts: {
                mnemonic: mnemonic1,
            },
        },
        avalanche_mainnet: {
            url: `https://avalanche-mainnet.infura.io/v3/${projectId}`,
            accounts: {
                mnemonic: mnemonic1,
            },
        },
        bsc_testnet: {
            url: `https://bsc-testnet-rpc.publicnode.com`,
            accounts: {
                mnemonic: mnemonic1,
            },
        },
        op_mainnet: {
            url: `https://optimism-mainnet.infura.io/v3/${projectId}`,
            accounts: {
                mnemonic: mnemonic1,
            },
        },
        op_testnet: {
            url: `https://optimism-sepolia.infura.io/v3/${projectId}`,
            accounts: {
                mnemonic: mnemonic1,
            },
        },
        base_mainnet: {
            url: `https://mainnet.base.org/`,
            accounts: {
                mnemonic: mnemonic1,
            },
        },
    },
    solidity: {
        compilers: [
            {
                version: "0.8.0",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                    viaIR: true,
                },
            },
            {
                version: "0.8.24",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                    
                },
            },
        ],
    },
    namedAccounts: {
        deployer: {
            default: 0, // wallet address 0, of the mnemonic in .env
        },
        proxyOwner: {
            default: 1,
        },
    },
}
