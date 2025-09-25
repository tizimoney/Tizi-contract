// Import environment variables
require("dotenv").config()
const { createWalletClient, http, encodeFunctionData } = require("viem")
const { privateKeyToAccount } = require("viem/accounts")
const { base } = require("viem/chains")

// ============ Configuration Constants ============

// Authentication
const PRIVATE_KEY = process.env.PRIVATE_KEY
if (!PRIVATE_KEY) throw new Error("Missing PRIVATE_KEY in environment")
const account = privateKeyToAccount(`0x${PRIVATE_KEY}`)
const bridgeAbi = require("./abis/cctp/BridgeUSDCEtherlink.json")

// Contract Addresses
const bridgeAddress = "0x2e2D688154D672FF1B859eF42f2aC166F88564C8"
const AMOUNT = BigInt(100000n) // 0 = all

// Set up wallet clients
const baseClient = createWalletClient({
  chain: base,
  transport: http(),
  account,
})

async function bridgeOut() {
  console.log("Calling bridgeOut on Base → Etherlink...")
  const txHash = await baseClient.sendTransaction({
    to: bridgeAddress,
    data: encodeFunctionData({
      abi: bridgeAbi,
      functionName: "bridgeOut",
      args: [
        AMOUNT
      ],
    }),
  })
  console.log(`bridgeOut tx: ${txHash}`)
  return txHash
}

async function main() {
  await bridgeOut()
  console.log("bridgeOut submitted!")
}

main().catch(console.error);
