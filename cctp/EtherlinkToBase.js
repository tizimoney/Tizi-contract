// Import environment variables
require("dotenv").config()
const { createWalletClient, http, encodeFunctionData } = require("viem")
const { privateKeyToAccount } = require("viem/accounts")
const { etherlink } = require("viem/chains")

// ============ Configuration Constants ============

// Authentication
const PRIVATE_KEY = process.env.PRIVATE_KEY
if (!PRIVATE_KEY) throw new Error("Missing PRIVATE_KEY in environment")
const account = privateKeyToAccount(`0x${PRIVATE_KEY}`)
const bridgeAbi = require("./abis/cctp/EtherLinkVault.json")

// Contract Addresses
const bridgeAddress = "0x88989fFEe6238E1909Ed2bF0ec4E0A2b607C7468"
const AMOUNT = BigInt(100000n) // 0 = all

// Set up wallet clients
const etherlinkClient = createWalletClient({
  chain: etherlink,
  transport: http(),
  account,
})

async function bridgeOut() {
  console.log("Calling bridgeOut on Etherlink → Base...")
  const txHash = await etherlinkClient.sendTransaction({
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
