require("dotenv").config();
const { ethers } = require('ethers');
const { bech32 } = require( 'bech32' );
const{ETH_TESTNET_RPC} = process.env
const Web3 = require("web3")
const { BASE_MAINNET_RPC, PRIVATE_KEY } = process.env
const mainBridgeAbi = require("./abis/cctp/MainVault.json")
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
    const web3 = new Web3(BASE_MAINNET_RPC)
    
    // Add ETH private key used for signing transactions
    const ethSigner = web3.eth.accounts.privateKeyToAccount(PRIVATE_KEY)
    web3.eth.accounts.wallet.add(ethSigner)
    
    // Noble destination address and transfer to evm address
    const nobleAddress = "noble1f8xajkr7k0t2nqhldng8htdrze68gy0td7kdxh"
    const mintRecipient = bech32.fromWords(bech32.decode(nobleAddress).words)
    const mintRecipientBytes = new Uint8Array(32);
    mintRecipientBytes.set(mintRecipient, 32 - mintRecipient.length);
    const mintRecipientHex = ethers.hexlify( mintRecipientBytes );
    const EVMAddress = ethers.getAddress("0x"+mintRecipientHex.slice(-40))
    console.log( mintRecipientHex )
    console.log( EVMAddress )

    // some Address
    const amount = "996388"
    const destDomain = 4
    // mainVault的地址
    const sender = "0x7A846F4579fA0A31c68F0f641E370fB28D90a8db"
    // subVault的地址
    const receiver = EVMAddress
    
    const baseContract = new web3.eth.Contract(mainBridgeAbi, sender, {
        from: ethSigner.address,
    } )
    
    // STEP 1: send USDC from base to noble
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
    console.log( "BridgeToReceipt: ", bridgeToReceipt )
    
    console.log(`Response at: https://iris-api.circle.com/messages/6/${burnTx.transactionHash}`)
}   

main()