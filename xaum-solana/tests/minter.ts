import fs from "fs";
import { Keypair, PublicKey } from "@solana/web3.js";
import * as anchor from "@coral-xyz/anchor";
import { assert } from "chai";
import { checkErrorCode } from "./utils/utils";
import type { XaumMinter } from "../target/types/xaum_minter";

// Timelock V2 governance bounds (minter has only owner + gov_delay; no operational delay).
const MIN_GOV_DELAY = 24 * 3600; // 24h
const MAX_GOV_DELAY = 7 * 24 * 3600; // 7d

describe("Minter (Timelock V2)", () => {
    const provider = anchor.AnchorProvider.env();
    anchor.setProvider(provider);

    const program = anchor.workspace.XaumMinter as anchor.Program<XaumMinter>;
    const [statePDA] = PublicKey.findProgramAddressSync([Buffer.from("state")], program.programId);
    const programKeypair = Keypair.fromSecretKey(
        Uint8Array.from(JSON.parse(fs.readFileSync("target/deploy/xaum_minter-keypair.json", "utf-8")))
    );

    const owner = (provider.wallet as anchor.Wallet).payer;
    const newOwner = Keypair.generate();
    const stranger = Keypair.generate(); // co-signer only; provider wallet pays fees
    const poolA = Keypair.generate().publicKey;
    const poolB = Keypair.generate().publicKey;

    const getState = () => program.account.state.fetch(statePDA);

    // ---- instruction helpers ----
    const setGovDelay = (signer: Keypair, v: number) =>
        program.methods.setGovDelay(new anchor.BN(v)).accounts({ owner: signer.publicKey }).signers([signer]).rpc();
    const revokeNextGovDelay = (signer: Keypair) =>
        program.methods.revokeNextGovDelay().accounts({ owner: signer.publicKey }).signers([signer]).rpc();
    const resizeState = (signer: Keypair) =>
        program.methods.resizeState().accounts({ owner: signer.publicKey }).signers([signer]).rpc();
    const transferOwnership = (signer: Keypair, next: PublicKey) =>
        program.methods.transferOwnership(next).accounts({ owner: signer.publicKey }).signers([signer]).rpc();
    const revokeNextOwner = (signer: Keypair) =>
        program.methods.revokeNextOwner().accounts({ owner: signer.publicKey }).signers([signer]).rpc();

    it("initialize: gov_delay disarmed (0)", async () => {
        await program.methods
            .initialize(poolA, poolB, [], [])
            .accounts({ owner: owner.publicKey })
            .signers([owner, programKeypair])
            .rpc();
        const s = await getState();
        assert.deepEqual(s.owner, owner.publicKey);
        assert.equal(s.govDelay.toNumber(), 0);
        assert.equal(s.nextGovDelay.toNumber(), 0);
        assert.equal(s.nextGovDelayEt.toNumber(), 0);
    });

    it("resize_state: idempotent + owner-only", async () => {
        // fresh account is already created at the V2 INIT_SPACE, so realloc is a no-op
        await resizeState(owner);
        await resizeState(owner); // idempotent
        assert.equal((await getState()).govDelay.toNumber(), 0); // data intact
        await checkErrorCode(resizeState(stranger), "NotOwner");
    });

    it("set_gov_delay: bounds + access control", async () => {
        await checkErrorCode(setGovDelay(stranger, MIN_GOV_DELAY), "NotOwner");
        await checkErrorCode(setGovDelay(owner, MIN_GOV_DELAY - 1), "DelayBelowMinimum");
        await checkErrorCode(setGovDelay(owner, MAX_GOV_DELAY + 1), "DelayExceedsMaximum");
    });

    it("set_gov_delay: request -> revoke (window=0 while disarmed)", async () => {
        await setGovDelay(owner, MIN_GOV_DELAY); // request; window = current gov_delay = 0
        let s = await getState();
        assert.equal(s.nextGovDelay.toNumber(), MIN_GOV_DELAY);
        assert.isTrue(s.nextGovDelayEt.toNumber() > 0);
        assert.equal(s.govDelay.toNumber(), 0); // not yet effective

        await checkErrorCode(revokeNextGovDelay(stranger), "NotOwner");
        await revokeNextGovDelay(owner);
        s = await getState();
        assert.equal(s.nextGovDelayEt.toNumber(), 0);
        assert.equal(s.govDelay.toNumber(), 0);
    });

    it("set_gov_delay: full request -> execute (arming, no wait)", async () => {
        // window is the CURRENT gov_delay (0), so the request is immediately effective
        await setGovDelay(owner, MIN_GOV_DELAY); // request (et = now)
        await checkErrorCode(setGovDelay(owner, MIN_GOV_DELAY + 60), "RequestMismatch"); // wrong value on execute
        await setGovDelay(owner, MIN_GOV_DELAY); // execute
        const s = await getState();
        assert.equal(s.govDelay.toNumber(), MIN_GOV_DELAY);
        assert.equal(s.nextGovDelayEt.toNumber(), 0);
    });

    it("transfer_ownership: uses gov_delay window (24h)", async () => {
        const now = Math.floor(Date.now() / 1000);
        await transferOwnership(owner, newOwner.publicKey);
        const s = await getState();
        assert.deepEqual(s.nextOwner, newOwner.publicKey);
        assert.deepEqual(s.owner, owner.publicKey); // unchanged until accept
        // et ≈ now + gov_delay(24h); generous skew for validator clock
        assert.isTrue(s.nextOwnerEt.toNumber() >= now + MIN_GOV_DELAY - 120);

        // cannot start another transfer while one is pending
        await checkErrorCode(transferOwnership(owner, stranger.publicKey), "PendingOwnerExist");

        // revoke (accepting would require a 24h wait — out of scope for the real-sleep harness)
        await revokeNextOwner(owner);
        assert.equal((await getState()).nextOwnerEt.toNumber(), 0);
    });
});
