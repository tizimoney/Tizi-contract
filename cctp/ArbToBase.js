require("dotenv").config()
const Web3 = require("web3")
const { BASE_MAINNET_RPC, ARB_MAINNET_RPC, PRIVATE_KEY } = process.env

const mainBridgeAbi = require("./abis/cctp/MainVault.json")
const subBridgeAbi = require("./abis/cctp/SubVault.json")

const waitForTransaction = async (web3, txHash) => {
    let transactionReceipt = await web3.eth.getTransactionReceipt(txHash)
    while (
        transactionReceipt != null &&
        transactionReceipt.status === "FALSE"
    ) {
        transactionReceipt = await web3.eth.getTransactionReceipt(txHash)
        await new Promise((r) => setTimeout(r, 4000))
    }
    return transactionReceipt
}

const main = async () => {
    const web3 = new Web3(ARB_MAINNET_RPC)

    // Add ETH private key used for signing transactions
    const ethSigner = web3.eth.accounts.privateKeyToAccount(PRIVATE_KEY)
    web3.eth.accounts.wallet.add(ethSigner)

    // Add op private key used for signing transactions
    const opSigner = web3.eth.accounts.privateKeyToAccount(PRIVATE_KEY)
    web3.eth.accounts.wallet.add(opSigner)

    // some Address
    const amount = "904813"
    const destDomain = 6
    //const messager = "0x19330d10D9Cc8751218eaf51E8885D058642E08A"
    // arb subVault的地址
    const sender = "0x"
    // mainVault的地址
    const receiver = "0x"
    //const sourceUsdc = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"

    // initialize contracts using address and ABI

    // tokenMessenger
    const baseContract = new web3.eth.Contract(mainBridgeAbi, sender, {
        from: ethSigner.address,
    })
    // messageTransmitter
    const opContract = new web3.eth.Contract(subBridgeAbi, receiver, {
        from: opSigner.address,
    })

    // STEP 1: send USDC from base to op
    const bridgeToGas = await baseContract.methods
        .bridgeOut(amount, destDomain, receiver)
        .estimateGas()
    const burnTx = await baseContract.methods
        .bridgeOut(amount, destDomain, receiver)
        .send({ gas: bridgeToGas })
    const bridgeToReceipt = await waitForTransaction(
        web3,
        burnTx.transactionHash,
    )
    console.log("BridgeToReceipt: ", bridgeToReceipt)

    // STEP 2: Retrieve message bytes from logs
    const transactionReceipt = await web3.eth.getTransactionReceipt(
        burnTx.transactionHash,
    )
    const eventTopic = web3.utils.keccak256("MessageSent(bytes)")
    const log = transactionReceipt.logs.find((l) => l.topics[0] === eventTopic)
    const messageBytes = web3.eth.abi.decodeParameters(["bytes"], log.data)[0]
    const messageHash = web3.utils.keccak256(messageBytes)

    console.log(`MessageBytes: ${messageBytes}`)
    console.log(`MessageHash: ${messageHash}`)

    // STEP 3: Fetch attestation signature
    let attestationResponse = { status: "pending" }
    while (attestationResponse.status != "complete") {
        const response = await fetch(
            `https://iris-api.circle.com/attestations/${messageHash}`,
        )
        attestationResponse = await response.json()
        await new Promise((r) => setTimeout(r, 2000))
    }

    const attestationSignature = attestationResponse.attestation
    console.log(`Signature: ${attestationSignature}`)

    // STEP 4: Using the message bytes and signature recieve the funds on destination chain and address
    web3.setProvider(BASE_MAINNET_RPC) // Connect web3 to AVAX testnet
    const BridgeInTxGas = await opContract.methods
        .bridgeIn(messageBytes, attestationSignature)
        .estimateGas()
    const BridgeInTx = await opContract.methods
        .bridgeIn(messageBytes, attestationSignature)
        .send({ gas: BridgeInTxGas })
    const bridgeInTxReceipt = await waitForTransaction(
        web3,
        BridgeInTx.transactionHash,
    )
    console.log("BridgeInTxReceipt: ", bridgeInTxReceipt)
}

main()
