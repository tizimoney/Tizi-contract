// Import environment variables
require("dotenv").config()
const { createWalletClient, http, encodeFunctionData } = require( "viem" );
const { privateKeyToAccount } = require("viem/accounts");
const { base, sonic, optimism } = require("viem/chains");
const axios = require("axios");

// ============ Configuration Constants ============

// Authentication
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const account = privateKeyToAccount( `0x${ PRIVATE_KEY }` );
const bridgeAbi = require("./abis/cctp/CCTPv2.json")

// Contract Addresses
const baseVault =
  "0xFca7039E95194e4fe7fcD04BbF04a9d49E8a8b8B";
const sonicVault =
  "0xd794dEA6065e409eA6b1d2c44669d6B05041D905";

// Transfer Parameters
const AMOUNT = 100000n; // Set transfer amount in 10^6 subunits (1 USDC; change as needed)
const maxFee = 100n; // Set fast transfer max fee in 10^6 subunits (0.0005 USDC; change as needed)

// Chain-specific Parameters
const srcDomain = 6
const destDomain = 13

// Set up wallet clients
const baseClient = createWalletClient({
  chain: base,
  transport: http(),
  account,
});
const sonicClient = createWalletClient({
  chain: sonic,
  transport: http(),
  account,
});

async function burnUSDC() {
  console.log("Burning USDC on base...");
  const burnTx = await baseClient.sendTransaction({
    to: baseVault,
    data: encodeFunctionData({
      abi: [
        {
          type: "function",
          name: "bridgeOut",
          stateMutability: "nonpayable",
          inputs: [
            { name: "_amount", type: "uint256" },
            { name: "_destDomain", type: "uint32" },
            { name: "_receiver", type: "address" },
            { name: "_maxFee", type: "uint256" },
            { name: "_minFinalityThreshold", type: "uint32" },
          ],
          outputs: [],
        },
      ],
      functionName: "bridgeOut",
      args: [
        AMOUNT,
        destDomain,
        sonicVault,
        maxFee,
        1000
      ],
    }),
  });
  console.log(`Burn Tx: ${burnTx}`);
  return burnTx;
}

async function retrieveAttestation(transactionHash) {
  console.log("Retrieving attestation...");
  const url = `https://iris-api.circle.com/v2/messages/${srcDomain}?transactionHash=${transactionHash}`;
  console.log(url)
  while ( true ) {
    try {
      const response = await axios.get(url);
      if (response.status === 404) {
        console.log("Waiting for attestation...");
      }
      if (response.data?.messages?.[0]?.status === "complete") {
        console.log("Attestation retrieved successfully!");
        return response.data.messages[0];
      }
      console.log("Waiting for attestation...");
      await new Promise((resolve) => setTimeout(resolve, 5000));
    } catch (error) {
      console.error("Error fetching attestation:", error.message);
      await new Promise((resolve) => setTimeout(resolve, 5000));
    }
  }
}

async function mintUSDC(attestation) {
  console.log("Minting USDC on Sonic...");
  const mintTx = await sonicClient.sendTransaction({
    to: sonicVault,
    data: encodeFunctionData({
      abi: bridgeAbi,
      functionName: "bridgeIn",
      args: [attestation.message, attestation.attestation],
    }),
  });
  console.log(`Mint Tx: ${mintTx}`);
}

async function main() {
  const burnTx = await burnUSDC();
  const attestation = await retrieveAttestation(burnTx);
  await mintUSDC(attestation);
  console.log("USDC transfer completed!");
}

main().catch(console.error);
