require("dotenv").config()
const Web3 = require("web3")
const {
    OP_MAINNET_RPC,
    AB_MAINNET_RPC,
    OP_PRIVATE_KEY,
    AB_PRIVATE_KEY,
    RECIPIENT_ADDRESS,
    AMOUNT,
} = process.env

const tokenMessengerAbi = require("./abis/cctp/TokenMessenger.json")
const usdcAbi = require("./abis/Usdc.json")
const messageTransmitterAbi = require("./abis/cctp/MessageTransmitter.json")

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
    const web3 = new Web3(OP_MAINNET_RPC)

    function addressToBytes32(address) {
        return web3.utils.padLeft(web3.utils.toHex(address), 64)
    }

    // Add ETH private key used for signing transactions
    const ethSigner = web3.eth.accounts.privateKeyToAccount(OP_PRIVATE_KEY)
    web3.eth.accounts.wallet.add(ethSigner)

    // Add op private key used for signing transactions
    const opSigner = web3.eth.accounts.privateKeyToAccount(AB_PRIVATE_KEY)
    web3.eth.accounts.wallet.add(opSigner)

    // Testnet Contract Addresses

    // ETH_TOKEN_MESSENGER_CONTRACT_ADDRESS 用于销毁源链上的USDC 部署在OP上
    const ETH_TOKEN_MESSENGER_CONTRACT_ADDRESS =
        "0x9daF8c91AEFAE50b9c0E69629D3F6Ca40cA3B3FE"
    // USDC_ETH_CONTRACT_ADDRESS USDC合约   OP链上
    const USDC_ETH_CONTRACT_ADDRESS =
        "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359"
    // AB_MESSAGE_TRANSMITTER_CONTRACT_ADDRESS 用于接收USDC 部署在AB上
    const AB_MESSAGE_TRANSMITTER_CONTRACT_ADDRESS =
        "0xC30362313FBBA5cf9163F0bb16a0e01f01A896ca"

    // initialize contracts using address and ABI\

    // tokenMessenger
    const ethTokenMessengerContract = new web3.eth.Contract(
        tokenMessengerAbi,
        ETH_TOKEN_MESSENGER_CONTRACT_ADDRESS,
        { from: ethSigner.address },
    )
    // usdc
    const usdcEthContract = new web3.eth.Contract(
        usdcAbi,
        USDC_ETH_CONTRACT_ADDRESS,
        { from: ethSigner.address },
    )
    // messageTransmitter
    const avaxMessageTransmitterContract = new web3.eth.Contract(
        messageTransmitterAbi,
        AB_MESSAGE_TRANSMITTER_CONTRACT_ADDRESS,
        { from: opSigner.address },
    )

    // AVAX destination address
    const mintRecipient = RECIPIENT_ADDRESS

    // 改为bytes32修改
    const destinationAddressInBytes32 = await addressToBytes32(mintRecipient)
    const AB_DESTINATION_DOMAIN = 3

    // Amount that will be transferred
    const amount = AMOUNT

    // STEP 1: Approve messenger contract to withdraw from our active eth address
    const approveTxGas = await usdcEthContract.methods
        .approve(ETH_TOKEN_MESSENGER_CONTRACT_ADDRESS, amount)
        .estimateGas({})
    //const gasPriceApv = await web3.eth.getGasPrice();
    //const gasPriceApvAdjusted = gasPriceApv * 2;
    const approveTx = await usdcEthContract.methods
        .approve(ETH_TOKEN_MESSENGER_CONTRACT_ADDRESS, amount)
        .send({ gas: approveTxGas })
    const approveTxReceipt = await waitForTransaction(
        web3,
        approveTx.transactionHash,
    )
    console.log("ApproveTxReceipt: ", approveTxReceipt)

    // STEP 2: Burn USDC
    const burnTxGas = await ethTokenMessengerContract.methods
        .depositForBurn(
            amount,
            AB_DESTINATION_DOMAIN,
            destinationAddressInBytes32,
            USDC_ETH_CONTRACT_ADDRESS,
        )
        .estimateGas()
    // const gasPriceBurn = await web3.eth.getGasPrice();
    // const gasPriceBurnAdjusted = gasPriceBurn * 2;
    const burnTx = await ethTokenMessengerContract.methods
        .depositForBurn(
            amount,
            AB_DESTINATION_DOMAIN,
            destinationAddressInBytes32,
            USDC_ETH_CONTRACT_ADDRESS,
        )
        .send({ gas: burnTxGas })
    const burnTxReceipt = await waitForTransaction(web3, burnTx.transactionHash)
    console.log("BurnTxReceipt: ", burnTxReceipt)

    // STEP 3: Retrieve message bytes from logs
    const transactionReceipt = await web3.eth.getTransactionReceipt(
        burnTx.transactionHash,
    )
    const eventTopic = web3.utils.keccak256("MessageSent(bytes)")
    const log = transactionReceipt.logs.find((l) => l.topics[0] === eventTopic)
    const messageBytes = web3.eth.abi.decodeParameters(["bytes"], log.data)[0]
    const messageHash = web3.utils.keccak256(messageBytes)

    console.log(`MessageBytes: ${messageBytes}`)
    console.log(`MessageHash: ${messageHash}`)

    // STEP 4: Fetch attestation signature
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

    // STEP 5: Using the message bytes and signature recieve the funds on destination chain and address
    web3.setProvider(AB_MAINNET_RPC) // Connect web3 to AVAX testnet
    const receiveTxGas = await avaxMessageTransmitterContract.methods
        .receiveMessage(messageBytes, attestationSignature)
        .estimateGas()
    // const gasPriceRec = await web3.eth.getGasPrice();
    // const gasPriceRecAdjusted = gasPriceRec * 2;
    // console.log(gasPriceRecAdjusted);
    // console.log(receiveTxGas);
    const receiveTx = await avaxMessageTransmitterContract.methods
        .receiveMessage(messageBytes, attestationSignature)
        .send({ gas: receiveTxGas })
    const receiveTxReceipt = await waitForTransaction(
        web3,
        receiveTx.transactionHash,
    )
    console.log("ReceiveTxReceipt: ", receiveTxReceipt)
}

main()
