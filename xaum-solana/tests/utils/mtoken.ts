import fs from "fs";
import { Keypair, PublicKey } from "@solana/web3.js";
import {
    TOKEN_2022_PROGRAM_ID, ASSOCIATED_TOKEN_PROGRAM_ID,
    getAssociatedTokenAddressSync, createAssociatedTokenAccount,
} from "@solana/spl-token";
import * as anchor from "@coral-xyz/anchor";
import type { XaumToken } from "../../target/types/xaum_token";

const program = anchor.workspace.XaumToken as anchor.Program<XaumToken>;

export const programId = program.programId;

export const [mintPDA] = PublicKey.findProgramAddressSync([Buffer.from("mint")], program.programId);
export const [statePDA] = PublicKey.findProgramAddressSync([anchor.utils.bytes.utf8.encode("state")], program.programId);

const programKeypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("target/deploy/xaum_token-keypair.json", "utf-8")))
);


export function getATA(owner: PublicKey, allowOwnerOffCurve=false) {
    return getAssociatedTokenAddressSync(mintPDA, owner, allowOwnerOffCurve, TOKEN_2022_PROGRAM_ID);
}
export function getATA_old(owner: PublicKey, allowOwnerOffCurve=false) {
    return getAssociatedTokenAddressSync(mintPDA, owner, allowOwnerOffCurve);
}

export async function getTokenState() {
    return await program.account.state.fetch(statePDA);
}


// init
export async function createToken(payer: Keypair, name: string, symbol: string, uri: string, initDelay: number, initGovDelay: number) {
    await program.methods
        .createToken(name, symbol, uri, new anchor.BN(initDelay), new anchor.BN(initGovDelay))
        .accounts({
            payer: payer.publicKey,
            mintAccount: mintPDA,
        })
        .signers([payer, programKeypair])
        .rpc();
}

// only owner
export async function setOwner(signer: Keypair, newOwner: PublicKey) {
    await program.methods
        .transferOwnership(newOwner)
        .accounts({owner: signer.publicKey})
        .signers([signer])
        .rpc();
}
// only pending owner (next_owner)
export async function acceptOwnership(signer: Keypair) {
    await program.methods
        .acceptOwnership()
        .accounts({nextOwner: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function setOperator(signer: Keypair, newOperator: PublicKey) {
    await program.methods
        .setOperator(newOperator)
        .accounts({owner: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function setRevoker(signer: Keypair, newRevoker: PublicKey) {
    await program.methods
        .setRevoker(newRevoker)
        .accounts({owner: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function setMessager(signer: Keypair, newMessager: PublicKey) {
    await program.methods
        .setMessager(newMessager)
        .accounts({owner: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function setDelay(signer: Keypair, newDelay: number) {
    await program.methods
        .setDelay(new anchor.BN(newDelay))
        .accounts({owner: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function revokeNextOwner(signer: Keypair) {
    await program.methods
        .revokeNextOwner()
        .accounts({owner: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function revokeNextRevoker(signer: Keypair) {
    await program.methods
        .revokeNextRevoker()
        .accounts({owner: signer.publicKey})
        .signers([signer])
        .rpc();
}

// extensions
export async function updateMetadata(signer: Keypair, newUri: string) {
    await program.methods
        .updateMetadata(newUri)
        .accounts({owner: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function updateTransferFee(signer: Keypair, transferFeeBasisPoints: number, maximumFee: number) {
    await program.methods
        .updateTransferFee(transferFeeBasisPoints, new anchor.BN(maximumFee))
        .accounts({owner: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function pause(signer: Keypair) {
    await program.methods
        .pause()
        .accounts({operator: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function unpause(signer: Keypair) {
    await program.methods
        .unpause()
        .accounts({owner: signer.publicKey})
        .signers([signer])
        .rpc();
}

// only revoker
export async function revokeNextOperator(signer: Keypair) {
    await program.methods
        .revokeNextOperator()
        .accounts({revoker: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function revokeNextMessager(signer: Keypair) {
    await program.methods
        .revokeNextMessager()
        .accounts({revoker: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function revokeNextDelay(signer: Keypair) {
    await program.methods
        .revokeNextDelay()
        .accounts({revoker: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function revokeNextMint(signer: Keypair) {
    await program.methods
        .revokeMint()
        .accounts({revoker: signer.publicKey})
        .signers([signer])
        .rpc();
}

// only operator
export async function changeMintBudget(signer: Keypair, delta: number) {
    await program.methods
        .changeMintBudget(new anchor.BN(delta))
        .accounts({operator: signer.publicKey})
        .signers([signer])
        .rpc();
}
export async function mint(signer: Keypair, to: PublicKey, amt: number, idx=0, allowOwnerOffCurve=false, ataOwner?: PublicKey) {
    // create ATA if it doesn't exist
    const ataAddr = getATA(ataOwner || to, allowOwnerOffCurve);
    const ataInfo = await program.provider.connection.getAccountInfo(ataAddr);
    if (!ataInfo) {
        await createAssociatedTokenAccount(program.provider.connection, signer, mintPDA, ataOwner || to,
            undefined, TOKEN_2022_PROGRAM_ID, ASSOCIATED_TOKEN_PROGRAM_ID, allowOwnerOffCurve);
    }

    const nonce = new Array(32).fill(idx); // TODO
    await program.methods
        .mintToken(new anchor.BN(amt), nonce)
        .accounts({
            operator: signer.publicKey,
            recipient: to,
            associatedTokenAccount: ataAddr,
            // tokenProgram: TOKEN_2022_PROGRAM_ID.toBase58(),
        })
        .signers([signer])
        .rpc();
}
export async function redeem(signer: Keypair, amt: number, customer: PublicKey, data=Buffer.from([])) {
    await program.methods
        .redeemToken(new anchor.BN(amt), customer, data)
        .accounts({
            operator: signer.publicKey,
            mintAccount: mintPDA,
            associatedTokenAccount: getATA(signer.publicKey),
            tokenProgram: TOKEN_2022_PROGRAM_ID.toBase58(),
        })
        .signers([signer])
        .rpc();
}
export async function addToBlockedList(signer: Keypair, user: PublicKey) {
    await program.methods
        .addToBlockedList()
        .accounts({
            operator: signer.publicKey,
            targetTokenAccount: getATA(user),
        })
        .signers([signer])
        .rpc();
}
export async function removeFromBlockedList(signer: Keypair, user: PublicKey) {
    await program.methods
        .removeFromBlockedList()
        .accounts({
            operator: signer.publicKey,
            targetTokenAccount: getATA(user),
        })
        .signers([signer])
        .rpc();
}

export async function setForcedTransferReceiver(signer: Keypair, newReceiver: PublicKey) {
    await program.methods
        .setForcedTransferReceiver(newReceiver)
        .accounts({owner: signer.publicKey})
        .signers([signer])
        .rpc();
}

export async function revokeNextForcedTransferReceiver(signer: Keypair) {
    await program.methods
        .revokeNextForcedTransferReceiver()
        .accounts({revoker: signer.publicKey})
        .signers([signer])
        .rpc();
}

export async function revokeForcedTransfer(signer: Keypair) {
    await program.methods
        .revokeForcedTransfer()
        .accounts({revoker: signer.publicKey})
        .signers([signer])
        .rpc();
}

export async function forcedTransfer(signer: Keypair, from: PublicKey, to: PublicKey, amount: number, idx = 0, data: Buffer = Buffer.alloc(0), extraData: Buffer = Buffer.alloc(0)) {
    const nonce = new Array(32).fill(idx);
    await program.methods
        .forcedTransferTokens(new anchor.BN(amount), nonce, data, extraData)
        .accounts({
            owner: signer.publicKey,
            senderTokenAccount: getATA(from),
            recipientTokenAccount: getATA(to),
        } as any)
        .signers([signer])
        .rpc();
}

export async function withdrawTransferFees(signer: Keypair, toAddr: PublicKey) {
    await program.methods
        .withdrawTransferFees()
        .accounts({
            operator: signer.publicKey,
            mintAccount: mintPDA,
            tokenAccount: getATA(toAddr),
        })
        .signers([signer])
        .rpc();
}
