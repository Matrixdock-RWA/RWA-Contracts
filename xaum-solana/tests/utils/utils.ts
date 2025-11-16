import { PublicKey } from "@solana/web3.js";
import * as anchor from '@coral-xyz/anchor';
import { AnchorProvider } from "@coral-xyz/anchor";
import { assert, expect } from 'chai';

export async function printTxLogs(provider: AnchorProvider, transactionSignature: string) {
    const latestBlockHash = await provider.connection.getLatestBlockhash();
    await provider.connection.confirmTransaction({
        blockhash: latestBlockHash.blockhash,
        lastValidBlockHeight: latestBlockHash.lastValidBlockHeight,
        signature: transactionSignature,
    }, "confirmed");
    const txDetails = await provider.connection.getParsedTransaction(transactionSignature, "confirmed");
    if (txDetails?.meta?.logMessages) {
        console.log("Transaction logs:");
        txDetails.meta.logMessages.forEach(log => console.log(log));
    }
}


export async function printTokens(provider: AnchorProvider, userPublicKey: string) {
    const tokenAccounts = await provider.connection.getParsedTokenAccountsByOwner(new PublicKey(userPublicKey), {
        programId: new PublicKey("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"), // SPL Token Program ID
    });

    console.log("printTokens:");
    tokenAccounts.value.forEach((accountInfo) => {
        const accountData = accountInfo.account.data;
        console.log("Token Account Address:", accountInfo.pubkey.toBase58());
        console.log("Mint:", accountData["parsed"]["info"]["mint"]);
        console.log("Token Balance:", accountData["parsed"]["info"]["tokenAmount"]["uiAmount"]);
    });
}


export async function getLatestBlock(connection: anchor.web3.Connection) {
    const latestSlot = await connection.getSlot();
    const blockTime = await connection.getBlockTime(latestSlot);
    return { latestSlot, blockTime };
}


export async function increaseBlockTime(provider: anchor.AnchorProvider, seconds: number) {
    // const noopTx = new anchor.web3.Transaction();
    // for (let i = 0; i < 10; i++) {
    //     await provider.sendAndConfirm(noopTx);
    // }

    const r0 = await getLatestBlock(provider.connection);
    await new Promise((resolve) => setTimeout(resolve, seconds * 1000));
    while (true) {
        const r1 = await getLatestBlock(provider.connection);
        if ((r0.blockTime + seconds) <= r1.blockTime) {
            break;
        }
        await new Promise((resolve) => setTimeout(resolve, 100));
    }

}


function checkErr(err: any, errCode: string) {
    assert.equal(err.error.errorCode.code, errCode);
    assert.equal(err.error.errorMessage, errCode);
}

export async function checkErrorCode(p: Promise<any>, errCode: string, isDebug=false) {
    try {
        await p;
        assert.fail("Expected an error but did not get one.");
    } catch (err) {
        if (isDebug) {
            console.log('err:', err);
        }
        // console.log('expected err:', err.error.errorCode.code);
        assert.equal(err.error.errorCode.code, errCode);
        assert.equal(err.error.errorMessage, errCode);
    }
}

export async function checkErrorMsg(p: Promise<any>, errMsg: string, isDebug=false) {
    try {
        await p;
        assert.fail("Expected an error but did not get one.");
    } catch (err) {
        if (isDebug) {
            console.log('err:', err);
        }
        assert.include(err+"", errMsg);
    }
}
