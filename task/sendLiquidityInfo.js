/*
 * Description:
 * This script is used during the rebase phase to send strategy and
 * value information from other chains to the Base chain use layerzero.
 *
 * Usage:
 * npx hardhat sendLiquidityInfo --chaineid <chainEID>
 * --network <network>
 *
 * Permissions:
 * Admin
 */


const { PRIVATE_KEYS } = process.env
module.exports = async function (taskArgs, hre) {
    //获得合约实例
    const contract = await ethers.getContract( "StrategyManager" )

    const DESTINATION_CHAIN = taskArgs.chaineid
    // set token code
    const setTx = await contract.setLiquidityInfo()
    console.log(`set Liquidity info: ${setTx.hash}`)
    await setTx.wait()

    // get token code
    const code = await contract.liquidityInfo()
    console.log( `Liquidity info is ${ code }` )
    
    const bytes32Address = await contract.peers( DESTINATION_CHAIN )
    console.log(bytes32Address)
    const targetContract = await contract.bytes32ToAddress( bytes32Address )
    console.log(targetContract)

    const sessionSalt = Math.floor(Math.random() * 1000000)
    console.log(sessionSalt)
    const timestamp = Math.floor( Date.now() / 1000 )
    console.log( timestamp )
    let nonce = BigInt(ethers.solidityPackedKeccak256( [ "uint256", "uint256" ], [ timestamp, sessionSalt ] )) % 1000000000000000000n
    console.log( nonce )
    const deadline = Math.floor( Date.now() / 1000 ) + 3600
    console.log( deadline )

    // sign the token code
    // create a wallet to sign the message with
    let privateKey = PRIVATE_KEYS
    let wallet = new ethers.Wallet(privateKey)
    let message = ethers.AbiCoder.defaultAbiCoder().encode( [ "address", "uint256", "uint256", "bytes" ], [ targetContract, nonce, deadline, code ] )
    console.log( message )
    // Sign the message
    let flatSig = await wallet.signMessage( ethers.getBytes( ethers.keccak256(message) ) )
    console.log( flatSig )

    // await contract.setOptions( 3000000,0 )
    // const temp = "test chain"
    const fee = await contract.quote( DESTINATION_CHAIN, flatSig, message, false )
    console.log(fee)
    const _value = fee[ 0 ] + BigInt( 100000 )
    console.log(_value)

    // send message
    const sendTx = await contract.send( DESTINATION_CHAIN, flatSig, message, {
        value: _value
    })
    console.log(`send message ${sendTx.hash}`)
    await sendTx.wait()
}
