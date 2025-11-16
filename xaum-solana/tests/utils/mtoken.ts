import fs from "fs";
import { Keypair, PublicKey } from "@solana/web3.js";
import { getAssociatedTokenAddressSync } from "@solana/spl-token";
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
    return getAssociatedTokenAddressSync(mintPDA, owner, allowOwnerOffCurve);
}

export async function getTokenState() {
    return await program.account.state.fetch(statePDA);
}


// init
export async function createToken(payer: Keypair, name: string, symbol: string, uri: string, initDelay: number) {
    await program.methods
        .createToken(name, symbol, uri, new anchor.BN(initDelay))
        .accounts({payer: payer.publicKey})
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
export async function updateMetadata(signer: Keypair, uri: string) {
    await program.methods
        .updateMetadata(uri)
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
        .accounts({revoker: signer.publicKey} as any)
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
export async function mint(signer: Keypair, to: PublicKey, amt: number, idx=0, allowOwnerOffCurve=false, toATA?: PublicKey) {
    const nonce = new Array(32).fill(idx); // TODO
    await program.methods
        .mintToken(new anchor.BN(amt), nonce)
        .accounts({
            operator: signer.publicKey,
            recipient: to,
            associatedTokenAccount: toATA || getATA(to, allowOwnerOffCurve),
        } as any)
        .signers([signer])
        .rpc();
}
export async function redeem(signer: Keypair, amt: number, customer: PublicKey, data=Buffer.from([])) {
    await program.methods
        .redeemToken(new anchor.BN(amt), customer, data)
        .accounts({
            operator: signer.publicKey,
            associatedTokenAccount: getATA(signer.publicKey),
        } as any)
        .signers([signer])
        .rpc();
}
export async function addToBlockedList(signer: Keypair, user: PublicKey) {
    await program.methods
        .addToBlockedList()
        .accounts({
            operator: signer.publicKey,
            tokenAccount: getATA(user),
            } as any)
            .signers([signer])
            .rpc();
}
export async function removeFromBlockedList(signer: Keypair, user: PublicKey) {
    await program.methods
        .removeFromBlockedList()
        .accounts({
            operator: signer.publicKey,
            tokenAccount: getATA(user),
        } as any)
        .signers([signer])
        .rpc();
}

// cross chain
export async function ccReceive(payer: Keypair, messager: Keypair, recipient: PublicKey, msg: Buffer) {
    await program.methods
        .ccReceive(msg)
        .accounts({
            payer: payer.publicKey,
            messager: messager.publicKey,
            recipient: recipient,
            associatedTokenAccount: getATA(recipient),
        } as any)
        .signers([payer, messager])
        .rpc();
}
export async function ccSendToken(messager: Keypair, sender: Keypair, receiver: Buffer, amount: number) {
    await program.methods
        .ccSendToken(receiver, new anchor.BN(amount))
        .accounts({
            messager: messager.publicKey,
            sender: sender.publicKey,
        } as any)
        .signers([messager, sender])
        .rpc();
}
export async function ccSendMintBudget(messager: Keypair, operator: Keypair, amount: number) {
    await program.methods
        .ccSendMintBudget(new anchor.BN(amount))
        .accounts({
            messager: messager.publicKey,
            operator: operator.publicKey,
        } as any)
        .signers([messager, operator])
        .rpc();
}
