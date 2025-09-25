// require( "dotenv" ).config();
// const { DirectSecp256k1Wallet, Registry, GeneratedType } = require('@cosmjs/proto-signing');
// const { SigningStargateClient } = require ('@cosmjs/stargate');
// const { fromHex } = require( '@cosmjs/encoding' )
// const { MsgDepositForBurn } = require('./generated/tx.ts')
// const { ethers } = require( 'ethers' )

import "dotenv/config"
import { DirectSecp256k1Wallet, Registry, GeneratedType } from "@cosmjs/proto-signing";
import { SigningStargateClient } from "@cosmjs/stargate";
import { MsgDepositForBurn } from "./generated/tx";
import { fromHex } from "@cosmjs/encoding"
import { ethers } from "ethers"
const mainBridgeAbi = require( "./abis/cctp/MainVault.json" )

function delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

export const cctpTypes: ReadonlyArray<[string, GeneratedType]> = [
    ["/circle.cctp.v1.MsgDepositForBurn", MsgDepositForBurn],
];

function createDefaultRegistry(): Registry {
    return new Registry(cctpTypes)
};

export function hexToUint8Array(hexString:string) {
    if (hexString.length % 2 !== 0) {
        throw "hexToUint8Array wrong";
    }

    const arrayBuffer = new Uint8Array(hexString.length / 2);

    for (let i = 0; i < hexString.length; i += 2) {
        const byteValue = parseInt(hexString.substring(i, i + 2), 16);
        arrayBuffer[i / 2] = byteValue;
    }

    return arrayBuffer;
}

const main = async() => {

    const privatekey = process.env.PRIVATE_KEY;
    if ( privatekey ) {
        const wallet = await DirectSecp256k1Wallet.fromKey(
            fromHex( privatekey.toString() ), "noble" );
        
        const [ account ] = await wallet.getAccounts();
        console.log( account.address )
        
        const client = await SigningStargateClient.connectWithSigner(
            "https://rpc-noble.imperator.co",
            wallet,
            {
                registry: createDefaultRegistry()
            }
        );
    
        // MainVault address
        const rawMintRecipient = "0x7A846F4579fA0A31c68F0f641E370fB28D90a8db";
        console.log(rawMintRecipient)
        const cleanedMintRecipient = rawMintRecipient.replace(/^0x/, '');
        const zeroesNeeded = 64 - cleanedMintRecipient.length;
        const mintRecipient = '0'.repeat( zeroesNeeded ) + cleanedMintRecipient;
        const mintRecipientBytes = hexToUint8Array(mintRecipient);
    
        const msg = {
            typeUrl: "/circle.cctp.v1.MsgDepositForBurn",
            value: {
                from: account.address,
                amount: "100000",
                destinationDomain: 6,
                mintRecipient: mintRecipientBytes,
                burnToken: "uusdc",
                // If using DepositForBurnWithCaller, add destinationCaller here
            }
        };
    
        const fee = {
            amount: [
                {
                    denom: "uusdc",
                    amount: "0",
                },
            ],
            gas: "200000",
        };
        const memo = "";
        const result = await client.signAndBroadcast(
            account.address,
            [msg],
            fee,
            memo
        );
    
        console.log(`Burned on Noble: https://mintscan.io/noble-testnet/tx/${result.transactionHash}`);
        console.log(`Minting on Ethereum to https://sepolia.etherscan.io/address/${rawMintRecipient}`);
        console.log( result )
        const url = `https://iris-api.circle.com/messages/4/${result.transactionHash}`
        console.log( url )
        await delay(10000)
        
        let response
        let data
        while ( true ) {
            response = await fetch(url)   
            data = await response.json()
            if ( data.messages[ 0 ].attestation !== "PENDING" ) {
                break
            }

            await delay(2000)
        }
        
        console.log(data)
        const message = data.messages[0].message
        const attestation = data.messages[0].attestation
        console.log( data.messages[0].message )
        console.log( data.messages[0].attestation )
        
        const provider = new ethers.JsonRpcProvider( process.env.BASE_MAINNET_RPC )
        const signer = new ethers.Wallet( privatekey, provider )
        const MAIN_VAULT_CONTRACT_ADDRESS = "0x7A846F4579fA0A31c68F0f641E370fB28D90a8db"
        const vaultContract = new ethers.Contract( MAIN_VAULT_CONTRACT_ADDRESS, mainBridgeAbi, signer );
    
        const receiveTx = await vaultContract.bridgeIn( message, attestation )
        await receiveTx.wait();
        console.log("Receive transaction hash:", receiveTx.hash);
    }
}


main()