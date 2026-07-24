import { Keypair, PublicKey } from "@solana/web3.js";
import {
    getAccount as getTokenAccountInfo,
    transferCheckedWithFee, createAssociatedTokenAccount,
    TOKEN_2022_PROGRAM_ID,
    getMint,
    ExtensionType,
    getExtensionTypes,
    getMetadataPointerState,
    getPermanentDelegate,
    getTransferFeeConfig,
    getPausableConfig,
    getTokenMetadata,
} from "@solana/spl-token";
import * as anchor from "@coral-xyz/anchor";
import { assert, expect } from "chai";
import { increaseBlockTime, checkErrorCode, checkErrorMsg } from "./utils/utils";
import {
    mintPDA, statePDA,
    getATA,
    getTokenState,
    createToken,
    setOwner, acceptOwnership, setRevoker, acceptRevoker, setOperator, setMessager, setDelay, setGovDelay,
    revokeNextOwner, revokeNextRevoker, revokeNextOperator, revokeNextMessager, revokeNextDelay, revokeNextGovDelay,
    changeMintBudget, mint, redeem, revokeNextMint, addToBlockedList, removeFromBlockedList,
    setForcedTransferReceiver, revokeNextForcedTransferReceiver, revokeForcedTransfer, forcedTransfer,
    updateMetadata, updateTransferFee, pause, unpause, revokeUnpause,
    withdrawTransferFees,
} from "./utils/mtoken";

// Timelock V2 bounds (independent per tier).
const minDelay = 3600; // 1 hour (MIN_DELAY)
const maxDelay = 48 * 3600; // 48 hours (MAX_DELAY)
const minGovDelay = 24 * 3600; // 24 hours (MIN_GOV_DELAY)
const maxGovDelay = 7 * 24 * 3600; // 7 days (MAX_GOV_DELAY)

const initDelay = 3;
const xaumName = "Solana Gold";
const xaumSymbol = "GOLDSOL";
const xaumUri = "GOLDSOL.xyz";

describe("MToken", () => {
    const provider = anchor.AnchorProvider.env();
    const deployer = provider.wallet as anchor.Wallet;

    const [owner, operator, revoker, messager, user1, user2] = new Array(6).fill(null).map(() => Keypair.generate());

    const operatorATA = getATA(operator.publicKey);
    const user1ATA = getATA(user1.publicKey);
    const user2ATA = getATA(user2.publicKey);

    const addrList = [
        {name: "deployer", addr: deployer.publicKey.toBase58()},
        {name: "payer", addr: deployer.payer.publicKey.toBase58()},
        {name: "owner", addr: owner.publicKey.toBase58()},
        {name: "operator", addr: operator.publicKey.toBase58(), ata: operatorATA.toBase58()},
        {name: "revoker", addr: revoker.publicKey.toBase58()},
        {name: "messager", addr: messager.publicKey.toBase58()},
        {name: "user1", addr: user1.publicKey.toBase58(), ata: user1ATA.toBase58()},
        {name: "user2", addr: user2.publicKey.toBase58(), ata: user2ATA.toBase58()},
        {name: "mintPDA", addr: mintPDA.toBase58()},
        {name: "statePDA", addr: statePDA.toBase58()},
    ];
    console.table(addrList);


    function getTokenAccount(addr: PublicKey) {
        const ata = getATA(addr);
        return getTokenAccountInfo(provider.connection, ata, "processed", TOKEN_2022_PROGRAM_ID);
    }
    async function getTokenBalance(addr: PublicKey) {
        const ata = getATA(addr);
        const result = await provider.connection.getTokenAccountBalance(ata);
        return Number(result.value.amount);
    }
    async function transferToken(from: Keypair, to: PublicKey, amount: number) {
        const fromATA = getATA(from.publicKey);
        const toATA = getATA(to);
        await transferCheckedWithFee(
            provider.connection,
            from, // payer
            fromATA, // source
            mintPDA, // mint
            toATA, // destination
            from.publicKey, // owner
            BigInt(amount),
            9, // decimals
            0n, // fee
            [], // multiSigners
            undefined, // confirmOptions
            TOKEN_2022_PROGRAM_ID,
        );
    }
    function createATA(payer: Keypair, owner: PublicKey) {
        return createAssociatedTokenAccount(provider.connection, payer, mintPDA, owner,
            undefined, TOKEN_2022_PROGRAM_ID);
    }


    before(async () => {
        await provider.connection.requestAirdrop(owner.publicKey, 2e10);
        await provider.connection.requestAirdrop(operator.publicKey, 2e10);
        await provider.connection.requestAirdrop(revoker.publicKey, 2e10);
        await provider.connection.requestAirdrop(user1.publicKey, 2e10);
        await provider.connection.requestAirdrop(user2.publicKey, 2e10);
    });

    it("create_token: invalid delay", async () => {
        await checkErrorCode(
            createToken(deployer.payer, xaumName, xaumSymbol, xaumUri, -1, 0),
            "NegativeDelay",
        );
        await checkErrorCode(
            createToken(deployer.payer, xaumName, xaumSymbol, xaumUri, 0, -1),
            "NegativeDelay",
        );
        // delay upper bound is MAX_DELAY (48h)
        await checkErrorCode(
            createToken(deployer.payer, xaumName, xaumSymbol, xaumUri, maxDelay + 1, 0),
            "DelayExceedsMaximum",
        );
        // gov_delay upper bound is MAX_GOV_DELAY (7d)
        await checkErrorCode(
            createToken(deployer.payer, xaumName, xaumSymbol, xaumUri, 0, maxGovDelay + 1),
            "DelayExceedsMaximum",
        );
        // gov_delay must not be shorter than the operational delay
        await checkErrorCode(
            createToken(deployer.payer, xaumName, xaumSymbol, xaumUri, maxDelay, 0),
            "GovDelayBelowDelay",
        );
        await checkErrorCode(
            createToken(deployer.payer, xaumName, xaumSymbol, xaumUri, 60 * 60, 1),
            "GovDelayBelowDelay",
        );
    });

    it("initialize", async () => {
        await createToken(deployer.payer, xaumName, xaumSymbol, xaumUri, initDelay, initDelay);
        const stateData = await getTokenState();
        const admin = deployer.payer.publicKey;
        assert.deepEqual(stateData.owner, admin);
        assert.deepEqual(stateData.nextOwner, admin);
        assert.equal(stateData.nextOwnerEt.toNumber(), 0);
        assert.deepEqual(stateData.operator, admin);
        assert.deepEqual(stateData.nextOperator, admin);
        assert.equal(stateData.nextOperatorEt.toNumber(), 0);
        assert.deepEqual(stateData.revoker, admin);
        assert.deepEqual(stateData.nextRevoker, admin);
        assert.equal(stateData.nextRevokerEt.toNumber(), 0);
        assert.deepEqual(stateData.messager, admin);
        assert.deepEqual(stateData.nextMessager, admin);
        assert.equal(stateData.nextMessagerEt.toNumber(), 0);
        assert.equal(stateData.delay.toNumber(), initDelay);
        assert.deepEqual(stateData.nextDelay.toNumber(), 0);
        assert.equal(stateData.nextDelayEt.toNumber(), 0);
        assert.equal(stateData.govDelay.toNumber(), initDelay);
        assert.equal(stateData.nextGovDelay.toNumber(), 0);
        assert.equal(stateData.nextGovDelayEt.toNumber(), 0);
        assert.equal(stateData.nextUnpauseEt.toNumber(), 0);
        assert.deepEqual(stateData.nextMintRecipient, admin);
        assert.deepEqual(stateData.nextMintAmount.toNumber(), 0);
        assert.deepEqual(stateData.nextMintEt.toNumber(), 0);
        assert.equal(stateData.mintBudget.toNumber(), 0);

        await checkErrorMsg(
            createToken(deployer.payer, xaumName, xaumSymbol, xaumUri, initDelay, 0),
            "already in use",
        );
    });

    describe("delayed ops", () => {
        // Ownership transfer is a two-step flow (start by owner, accept by the new owner)
        // and cannot share the generic request/execute loop below.
        it("setOwner", async () => {
            // only the current owner can start a transfer
            await checkErrorCode(setOwner(user1, owner.publicKey), "NotOwner");

            // step 1: current owner (deployer.payer) starts the transfer
            await setOwner(deployer.payer, owner.publicKey);
            const state = await getTokenState();
            assert.deepEqual(state.owner, deployer.payer.publicKey);
            assert.deepEqual(state.nextOwner, owner.publicKey);
            assert.isTrue(state.nextOwnerEt.toNumber() > 0);

            // cannot start another transfer while one is pending
            await checkErrorCode(setOwner(deployer.payer, user1.publicKey), "PendingOwnerExist");

            // step 2 too early
            await checkErrorCode(acceptOwnership(owner), "NotEffective");
            // only the pending owner can accept
            await checkErrorCode(acceptOwnership(user1), "NotNextOwner");

            // wait for gov_delay, then the pending owner accepts
            await increaseBlockTime(provider, initDelay);
            await acceptOwnership(owner);
            const state2 = await getTokenState();
            assert.deepEqual(state2.owner, owner.publicKey);
            assert.equal(state2.nextOwnerEt.toNumber(), 0);

            // accepting again with no pending transfer fails
            await checkErrorCode(acceptOwnership(owner), "NoPendingOwner");
        });

        it("revoke_setOwner", async () => {
            // #2: revoke by owner OR revoker; anyone else rejected
            await checkErrorCode(revokeNextOwner(user1), "NotOwnerOrRevoker");

            // owner can revoke
            await setOwner(owner, user1.publicKey);
            assert.isTrue((await getTokenState()).nextOwnerEt.toNumber() > 0);
            await revokeNextOwner(owner);
            const state2 = await getTokenState();
            assert.equal(state2.nextOwnerEt.toNumber(), 0);
            assert.deepEqual(state2.owner, owner.publicKey); // owner unchanged

            // revoker can also revoke (revoker was set to `revoker` during init? no —
            // at this point the on-chain revoker is still the deployer; use deployer.payer)
            await setOwner(owner, user1.publicKey);
            assert.isTrue((await getTokenState()).nextOwnerEt.toNumber() > 0);
            await revokeNextOwner(deployer.payer); // current revoker
            assert.equal((await getTokenState()).nextOwnerEt.toNumber(), 0);
        });

        // setOperator (#12, delay window) and setMessager (#6, gov_delay window) share the
        // single-call request/execute loop. Both windows equal initDelay here (delay ==
        // gov_delay == initDelay from init), so timing stays fast. setRevoker (#1) is NOT
        // here — it is a two-step accept, tested separately below.
        const testCases = [
            {name: "setOperator", func: setOperator, revokeFunc: revokeNextOperator, field: "operator", nextField: "nextOperator", nextEtField: "nextOperatorEt", caller: owner, oldVal: deployer.payer.publicKey, newVal: operator.publicKey, newVal2: user1.publicKey},
            {name: "setMessager", func: setMessager, revokeFunc: revokeNextMessager, field: "messager", nextField: "nextMessager", nextEtField: "nextMessagerEt", caller: owner, oldVal: deployer.payer.publicKey, newVal: messager.publicKey, newVal2: user1.publicKey},
        ];

        for (const testCase of testCases) {
            const {name, func, field, nextField, nextEtField, caller, oldVal, newVal, newVal2} = testCase;

            it(name, async () => {
                await checkErrorCode(func(user1, newVal as any), "NotOwner");

                // request
                await func(caller, newVal as any);
                const state = await getTokenState();
                assert.deepEqual(state[field], oldVal, "field:" + field);
                assert.deepEqual(state[nextField], newVal);
                assert.isTrue(state[nextEtField].toNumber() > 0);

                // execute too early
                await checkErrorCode(func(caller, newVal as any), "NotEffective");

                // wait for delay and execute
                await increaseBlockTime(provider, initDelay);

                // request with different value
                await checkErrorCode(func(caller, newVal2 as any), "RequestMismatch");

                // execute OK
                await func(caller, newVal as any);
                const state2 = await getTokenState();
                assert.deepEqual(state2[field], newVal);
                assert.isTrue(state2[nextEtField].toNumber() == 0);
            });
        }; // end of for

        // #1 setRevoker: gov_delay + two-step accept (owner requests, new revoker accepts).
        it("setRevoker", async () => {
            // only owner can start
            await checkErrorCode(setRevoker(user1, revoker.publicKey), "NotOwner");

            // step 1: owner requests
            await setRevoker(owner, revoker.publicKey);
            const state = await getTokenState();
            assert.deepEqual(state.revoker, deployer.payer.publicKey); // unchanged until accept
            assert.deepEqual(state.nextRevoker, revoker.publicKey);
            assert.isTrue(state.nextRevokerEt.toNumber() > 0);

            // cannot start another while one is pending
            await checkErrorCode(setRevoker(owner, user1.publicKey), "PendingRevokerExist");

            // step 2 too early / wrong signer
            await checkErrorCode(acceptRevoker(revoker), "NotEffective");
            await checkErrorCode(acceptRevoker(user1), "NotNextRevoker");

            // wait gov_delay, then the pending revoker accepts
            await increaseBlockTime(provider, initDelay);
            await acceptRevoker(revoker);
            const state2 = await getTokenState();
            assert.deepEqual(state2.revoker, revoker.publicKey);
            assert.equal(state2.nextRevokerEt.toNumber(), 0);

            // accepting again with nothing pending fails
            await checkErrorCode(acceptRevoker(revoker), "NoPendingRevoker");
        });

        // #1 revoke: owner OR operator (self-exclusion — revoker cannot cancel its own change).
        it("revoke_setRevoker", async () => {
            await setRevoker(owner, user1.publicKey);
            assert.isTrue((await getTokenState()).nextRevokerEt.toNumber() > 0);

            // the revoker itself cannot revoke (self-exclusion), nor can a stranger
            await checkErrorCode(revokeNextRevoker(revoker), "NotOwnerOrOperator");
            await checkErrorCode(revokeNextRevoker(user1), "NotOwnerOrOperator");

            // operator can revoke
            await revokeNextRevoker(operator);
            assert.equal((await getTokenState()).nextRevokerEt.toNumber(), 0);

            // owner can also revoke
            await setRevoker(owner, user1.publicKey);
            await revokeNextRevoker(owner);
            assert.equal((await getTokenState()).nextRevokerEt.toNumber(), 0);
        });

        // owner-or-revoker revocation for the single-call setters (#6, #12)
        for (const testCase of testCases) {
            const {name, func, revokeFunc, nextEtField, caller, oldVal} = testCase;

            it("revoke_" + name, async () => {
                await checkErrorCode(revokeFunc(user1), "NotOwnerOrRevoker");

                // request
                await func(caller, oldVal as any);
                assert.isTrue((await getTokenState())[nextEtField].toNumber() > 0);

                // revoke by revoker
                await revokeFunc(revoker);
                assert.isTrue((await getTokenState())[nextEtField].toNumber() == 0);

                // request + revoke by owner
                await func(caller, oldVal as any);
                await revokeFunc(owner);
                assert.isTrue((await getTokenState())[nextEtField].toNumber() == 0);
            });
        } // end of for

    }); // end of describe

    describe("state config", () => {
        // gov_delay is still initDelay (3s) here, so setDelay's invariant (new_delay <=
        // gov_delay) always fails for any in-bounds delay — this is exactly the tiering guard.
        it("setDelay: bounds + gov_delay invariant", async () => {
            await checkErrorCode(setDelay(user1, minDelay), "NotOwner");
            await checkErrorCode(setDelay(owner, minDelay - 1), "DelayBelowMinimum");
            await checkErrorCode(setDelay(owner, maxDelay + 1), "DelayExceedsMaximum");
            // in-bounds but exceeds current gov_delay (3s) → tiering guard
            await checkErrorCode(setDelay(owner, minDelay), "DelayExceedsGovDelay");
            // revoke auth is checked before state (no pending needed)
            await checkErrorCode(revokeNextDelay(user1), "NotOwnerOrRevoker");
        });

        it("setGovDelay: bounds", async () => {
            await checkErrorCode(setGovDelay(user1, minGovDelay), "NotOwner");
            await checkErrorCode(setGovDelay(owner, minGovDelay - 1), "DelayBelowMinimum");
            await checkErrorCode(setGovDelay(owner, maxGovDelay + 1), "DelayExceedsMaximum");
            await checkErrorCode(revokeNextGovDelay(user1), "NotOwnerOrRevoker");
        });
    });

    describe("extensions config", () => {

        it("check extensions", async () => {
            const mintInfo = await getMint(provider.connection, mintPDA, "confirmed", TOKEN_2022_PROGRAM_ID);
            const extensionTypes = getExtensionTypes(mintInfo.tlvData);

            console.log("Enabled extensions:", extensionTypes.map(t => ExtensionType[t]).join(", "));

            // Check MetadataPointer extension
            const metadataPointer = getMetadataPointerState(mintInfo);
            assert.isNotNull(metadataPointer, "MetadataPointer extension should be enabled");
            assert.isNotNull(metadataPointer!.authority, "MetadataPointer authority should be set");
            assert.isNotNull(metadataPointer!.metadataAddress, "MetadataPointer metadataAddress should be set");
            assert.isTrue(extensionTypes.includes(ExtensionType.MetadataPointer), "MetadataPointer should be in extension types");

            // Check PermanentDelegate extension
            const permanentDelegate = getPermanentDelegate(mintInfo);
            assert.isNotNull(permanentDelegate, "PermanentDelegate extension should be enabled");
            assert.isTrue(extensionTypes.includes(ExtensionType.PermanentDelegate), "PermanentDelegate should be in extension types");

            // Check TransferFee extension
            const transferFeeConfig = getTransferFeeConfig(mintInfo);
            assert.isNotNull(transferFeeConfig, "TransferFeeConfig extension should be enabled");
            assert.isTrue(extensionTypes.includes(ExtensionType.TransferFeeConfig), "TransferFeeConfig should be in extension types");

            // Check Pausable extension
            const pausableConfig = getPausableConfig(mintInfo);
            assert.isNotNull(pausableConfig, "PausableConfig extension should be enabled");
            assert.isTrue(extensionTypes.includes(ExtensionType.PausableConfig), "PausableConfig should be in extension types");

            // Check TokenMetadata extension
            const tokenMetadata = await getTokenMetadata(provider.connection, mintPDA, "confirmed", TOKEN_2022_PROGRAM_ID);
            assert.isNotNull(tokenMetadata, "TokenMetadata extension should be enabled");
            assert.equal(tokenMetadata!.name, xaumName, "Token name should match");
            assert.equal(tokenMetadata!.symbol, xaumSymbol, "Token symbol should match");
            assert.equal(tokenMetadata!.uri, xaumUri, "Token URI should match");
            assert.isTrue(extensionTypes.includes(ExtensionType.TokenMetadata), "TokenMetadata should be in extension types");

            console.log("✓ All extensions are enabled and configured correctly");
        });

        it("update: onlyOwner", async () => {
            await checkErrorCode(updateMetadata(user1, "newURI"), "NotOwner");
            await checkErrorCode(updateTransferFee(user1, 100, 1000), "NotOwner");
            await checkErrorCode(unpause(user1), "NotOwner");
            await checkErrorCode(pause(user1), "NotOperator");
        });

        it("update_metadata", async () => {
            await updateMetadata(owner, xaumUri.substring(0, xaumUri.length - 3)); // OK
            await updateMetadata(owner, xaumUri + "+" + xaumUri); // OK
            // TODO: check metadata
        });

        it("update_transfer_fee", async () => {
            await updateTransferFee(owner, 20, 1000);
            await increaseBlockTime(provider, initDelay); // wait tx to be processed

            const mintInfo = await getMint(provider.connection, mintPDA, "confirmed", TOKEN_2022_PROGRAM_ID);
            const transferFeeConfig = getTransferFeeConfig(mintInfo);
            // console.log('transferFeeConfig:', transferFeeConfig);
            assert.isNotNull(transferFeeConfig, "TransferFeeConfig should exist");
            assert.equal(transferFeeConfig!.newerTransferFee.transferFeeBasisPoints, 20);
            assert.equal(transferFeeConfig!.newerTransferFee.maximumFee, 1000n);

            // reset to original value
            await updateTransferFee(owner, 0, 0);
        });

        it("set_paused", async () => {
            // unpause request is rejected while not paused — otherwise a pre-staged
            // matured request could bypass the delay of a future emergency pause
            await checkErrorCode(unpause(owner), "NotPaused");

            await pause(operator); // #20 immediate

            // #14 unpause is a delayed two-call op
            await unpause(owner); // request
            assert.isTrue((await getTokenState()).nextUnpauseEt.toNumber() > 0);
            await checkErrorCode(unpause(owner), "NotEffective"); // too early
            await increaseBlockTime(provider, initDelay);
            await unpause(owner); // execute
            assert.equal((await getTokenState()).nextUnpauseEt.toNumber(), 0);
        });

        it("revoke_unpause", async () => {
            await pause(operator);
            await unpause(owner); // request
            assert.isTrue((await getTokenState()).nextUnpauseEt.toNumber() > 0);

            // revoke by owner OR revoker; stranger rejected
            await checkErrorCode(revokeUnpause(user1), "NotOwnerOrRevoker");
            await revokeUnpause(revoker);
            assert.equal((await getTokenState()).nextUnpauseEt.toNumber(), 0);

            // mint is still paused — unpause properly so later tests can transfer
            await unpause(owner); // request
            await increaseBlockTime(provider, initDelay);
            await unpause(owner); // execute
            assert.equal((await getTokenState()).nextUnpauseEt.toNumber(), 0);
        });

        it("pause_clears_pending_unpause", async () => {
            await pause(operator);
            await unpause(owner); // request
            await increaseBlockTime(provider, initDelay); // request matures

            // a new pause wipes the matured request — every pause gets a fresh delay
            await pause(operator);
            assert.equal((await getTokenState()).nextUnpauseEt.toNumber(), 0);

            // owner must go through the full two-call delay again
            await unpause(owner); // new request
            await checkErrorCode(unpause(owner), "NotEffective");
            await increaseBlockTime(provider, initDelay);
            await unpause(owner); // execute
            assert.equal((await getTokenState()).nextUnpauseEt.toNumber(), 0);
        });

    });


    describe("mint/redeem", () => {

        it("change_mint_budget", async () => {
            await checkErrorCode(changeMintBudget(user1, 5000), "NotOperator");

            // increase
            await changeMintBudget(operator, 5000);
            const state = await getTokenState();
            assert.equal(state.mintBudget.toNumber(), 5000);

            // decrease
            await changeMintBudget(operator, -2000);
            const state2 = await getTokenState();
            assert.equal(state2.mintBudget.toNumber(), 3000);
        });

        it("change_mint_budget: underflow", async () => {
            await checkErrorCode(
                changeMintBudget(operator, -200000),
                "MintBudgetNotEnough",
            );
        });

        it("mint: MintBudgetNotEnough", async () => {
            await mint(operator, user2.publicKey, 4000, 1); // OK
            await increaseBlockTime(provider, initDelay);
            await checkErrorCode(mint(operator, user2.publicKey, 4000, 1), "MintBudgetNotEnough");
            await revokeNextMint(revoker);
        });

        it("mint", async () => {
            await checkErrorCode(mint(user1, user1.publicKey, 500), "NotOperator");

            // request
            await mint(operator, user1.publicKey, 500);
            const state = await getTokenState();
            assert.equal(state.nextMintAmount.toNumber(), 500);
            assert.deepEqual(state.nextMintRecipient, user1.publicKey);
            assert.isTrue(state.nextMintEt.toNumber() > 0);
            assert.equal(state.mintBudget.toNumber(), 3000);

            // execute too early
            await checkErrorCode(mint(operator, user1.publicKey, 500), "NotEffective");

            // wait for delay and execute
            await increaseBlockTime(provider, initDelay);

            // request with different value
            await checkErrorCode(mint(operator, user1.publicKey, 800), "IncorrectMintInfo");
            await checkErrorCode(mint(operator, user2.publicKey, 500), "IncorrectMintInfo");
            await checkErrorCode(mint(operator, user1.publicKey, 500, 222), "IncorrectMintInfo");

            // execute OK
            await mint(operator, user1.publicKey, 500);
            const state2 = await getTokenState();
            assert.equal(state2.nextMintAmount.toNumber(), 500);
            assert.deepEqual(state2.nextMintRecipient, user1.publicKey);
            assert.equal(state2.nextMintEt.toNumber(), 0);
            assert.equal(state2.mintBudget.toNumber(), 3000-500);

            // https://solana.com/docs/rpc/http/gettokensupply
            const totalSupply = await provider.connection.getTokenSupply(mintPDA);
            assert.equal(totalSupply.value.amount, "500");
        });

        it("revoke_mint", async () => {
            await checkErrorCode(revokeNextMint(user1), "NotOwnerOrRevoker");

            // request
            await mint(operator, user2.publicKey, 100);
            const state = await getTokenState();
            assert.isTrue(state.nextMintEt.toNumber() > 0);
            assert.equal(state.nextMintAmount.toNumber(), 100);
            assert.deepEqual(state.nextMintRecipient, user2.publicKey);

            // revoke
            await revokeNextMint(revoker);
            const state2 = await getTokenState();
            assert.equal(state2.nextMintEt.toNumber(), 0);
        });

        it("redeem", async () => {
            // mint to operator some tokens
            await mint(operator, operator.publicKey, 100);
            await increaseBlockTime(provider, initDelay);
            await mint(operator, operator.publicKey, 100);
            const state = await getTokenState();
            assert.equal(state.mintBudget.toNumber(), 2500-100);

            await checkErrorCode(redeem(user1, 20, user2.publicKey), "NotOperator");

            await redeem(operator, 20, user1.publicKey); // OK
            const state2 = await getTokenState();
            assert.equal(state2.mintBudget.toNumber(), 2500-100+20);
        });

        it("redeem: InsufficientFunds", async () => {
            await checkErrorMsg(
                redeem(operator, 20000, user1.publicKey),
                "Error: insufficient funds",
            );
        });

        it("mint_to_pda", async () => {
            await mint(operator, statePDA, 100, 0, true);
            await increaseBlockTime(provider, initDelay);
            await mint(operator, statePDA, 100, 0, true);
        });

        it("init_after_execute", async () => {
            const user = Keypair.generate();

            // const errCode = "ConstraintTokenOwner";
            const errMsg = "A token owner constraint was violated";
            await checkErrorMsg(mint(operator, user1.publicKey, 100, 0, false, user2.publicKey), errMsg);
            await checkErrorMsg(mint(operator, user1.publicKey, 100, 0, false, user.publicKey), errMsg);
            await checkErrorMsg(mint(operator, user.publicKey, 100, 0, false, user2.publicKey), errMsg);

            await mint(operator, user.publicKey, 300);
            await increaseBlockTime(provider, initDelay);
            // await checkErrorMsg(getTokenAccount(user.publicKey), "TokenAccountNotFoundError");
            // assert.equal(a.isInitialized, false);

            await mint(operator, user.publicKey, 300);
            const b = await getTokenAccount(user.publicKey);
            assert.equal(b.isInitialized, true);
        });
    });

    describe("blocked_list", () => {

        it("init_user2", async () => {
            await mint(operator, user2.publicKey, 100);
            await increaseBlockTime(provider, initDelay);
            await mint(operator, user2.publicKey, 100);
        });

        it("blocked_list_ops", async () => {
            await checkErrorCode(addToBlockedList(user1, user2.publicKey), "NotOperator");
            await checkErrorCode(removeFromBlockedList(user1, user2.publicKey), "NotOperator");

            await addToBlockedList(operator, user1.publicKey);
            await addToBlockedList(operator, user2.publicKey);
            const u1a = await getTokenAccount(user1.publicKey);
            const u2a = await getTokenAccount(user2.publicKey);
            assert.equal(u1a.isFrozen, true);
            assert.equal(u2a.isFrozen, true);

            await removeFromBlockedList(operator, user1.publicKey);
            const u1b = await getTokenAccount(user1.publicKey);
            const u2b = await getTokenAccount(user2.publicKey);
            assert.equal(u1b.isFrozen, false);
            assert.equal(u2b.isFrozen, true);

            await removeFromBlockedList(operator, user2.publicKey);
            const u2c = await getTokenAccount(user2.publicKey);
            assert.equal(u2c.isFrozen, false);
        });

        it("normal_transfer", async () => {
            // ok
            await transferToken(user1, user2.publicKey, 10);
            await transferToken(user2, user1.publicKey, 10);

            // block user1
            await addToBlockedList(operator, user1.publicKey);
            await checkErrorMsg(transferToken(user1, user2.publicKey, 10), "Account is frozen");
            await checkErrorMsg(transferToken(user2, user1.publicKey, 10), "Account is frozen");
            await removeFromBlockedList(operator, user1.publicKey);
        });

        it("block_error", async () => {
            const user = Keypair.generate();
            await checkErrorMsg(addToBlockedList(operator, user.publicKey), "AccountNotInitialized");

            await createATA(owner, user.publicKey);
            await checkErrorCode(addToBlockedList(operator, user.publicKey), "TokenBalanceZero");
        });
    });

    describe("extensions", () => {

        // TODO: fix me
        it("transfer_fee", async () => {
            await checkErrorCode(withdrawTransferFees(user1, user1.publicKey), "NotOperator");

            await updateTransferFee(owner, 100, 1000); // 1% fee
            // wait nexe epoch

            const bal1a = await getTokenBalance(user1.publicKey);
            const bal2a = await getTokenBalance(user2.publicKey);
            await transferToken(user1, user2.publicKey, 100);
            const bal1b = await getTokenBalance(user1.publicKey);
            const bal2b = await getTokenBalance(user2.publicKey);
            assert.equal(bal1b, bal1a - 100);
            // assert.equal(bal2b, bal2a + 100 - 1);
        });

        it("pausable", async () => {
            await pause(operator); // ok
            await checkErrorMsg(
                transferToken(user1, user2.publicKey, 100),
                "Transferring, minting, and burning is paused on this mint",
            );
            // #14 delayed two-call unpause
            await unpause(owner); // request
            await increaseBlockTime(provider, initDelay);
            await unpause(owner); // execute
        });

    });

    describe("forced_transfer", async () => {

        it("set_forced_transfer_receiver", async () => {
            // only owner; receiver stored as ATA (token account address)
            await checkErrorCode(setForcedTransferReceiver(user1, user2ATA), "NotOwner");

            // request
            await setForcedTransferReceiver(owner, user2ATA);
            let state = await getTokenState();
            assert.deepEqual(state.nextForcedTransferReceiver, user2ATA);
            assert.isTrue(state.nextForcedTransferReceiverEt.toNumber() > 0);

            // revoke
            await revokeNextForcedTransferReceiver(revoker);
            state = await getTokenState();
            assert.equal(state.nextForcedTransferReceiverEt.toNumber(), 0);

            // request again, wait, effect
            await setForcedTransferReceiver(owner, user2ATA);
            await increaseBlockTime(provider, initDelay);
            await setForcedTransferReceiver(owner, user2ATA);
            state = await getTokenState();
            assert.deepEqual(state.forcedTransferReceiver, user2ATA);
            assert.equal(state.nextForcedTransferReceiverEt.toNumber(), 0);
        });

        it("forced_transfer", async () => {
            // only owner can call
            await checkErrorCode(forcedTransfer(user1, user2.publicKey, user1.publicKey, 100), "NotOwner");

            const bal1a = await getTokenBalance(user1.publicKey);
            const bal2a = await getTokenBalance(user2.publicKey);

            // sender must be blocked (user2 is not blocked)
            await checkErrorCode(forcedTransfer(owner, user2.publicKey, user1.publicKey, 100), "NotBlocked");

            // block user1; recipient must be forced_transfer_receiver (user2ATA)
            await addToBlockedList(operator, user1.publicKey);
            await checkErrorCode(forcedTransfer(owner, user1.publicKey, operator.publicKey, 100), "InvalidForcedTransferReceiver");

            // request (call 1)
            await forcedTransfer(owner, user1.publicKey, user2.publicKey, 100);
            let state = await getTokenState();
            assert.equal(state.nextForcedTransferAmount.toNumber(), 100);
            assert.isTrue(state.nextForcedTransferEt.toNumber() > 0);

            // revoke
            await revokeForcedTransfer(revoker);
            state = await getTokenState();
            assert.equal(state.nextForcedTransferEt.toNumber(), 0);

            // request again
            await forcedTransfer(owner, user1.publicKey, user2.publicKey, 100);
            // too early to execute
            await checkErrorCode(forcedTransfer(owner, user1.publicKey, user2.publicKey, 100), "TooEarlyToForcedTransfer");

            // execute (call 2) after delay
            await increaseBlockTime(provider, initDelay);
            await forcedTransfer(owner, user1.publicKey, user2.publicKey, 100);

            const bal1b = await getTokenBalance(user1.publicKey);
            const bal2b = await getTokenBalance(user2.publicKey);
            assert.equal(bal1b, bal1a - 100);
            assert.equal(bal2b, bal2a + 100);
        });

        it("forced_transfer: TransferWouldDrainAccount", async () => {
            // user1 is still blocked from the previous test
            const fullBal = await getTokenBalance(user1.publicKey);
            assert.isTrue(fullBal > 0, "user1 should have tokens");

            // request to drain the full balance (idx=1 to use a distinct nonce)
            await forcedTransfer(owner, user1.publicKey, user2.publicKey, fullBal, 1);
            let state = await getTokenState();
            assert.equal(state.nextForcedTransferAmount.toNumber(), fullBal);
            assert.isTrue(state.nextForcedTransferEt.toNumber() > 0);

            // execute after delay — must fail because it would drain the sender to zero
            await increaseBlockTime(provider, initDelay);
            await checkErrorCode(
                forcedTransfer(owner, user1.publicKey, user2.publicKey, fullBal, 1),
                "TransferWouldDrainAccount",
            );

            // clean up: revoke the pending request
            await revokeForcedTransfer(revoker);
            state = await getTokenState();
            assert.equal(state.nextForcedTransferEt.toNumber(), 0);
        });

    })

    // Arming (setGovDelay / setDelay) runs LAST: executing setGovDelay raises gov_delay to
    // 24h, which would make every gov_delay-windowed op (setOwner/setRevoker/setMessager/…)
    // require a 24h wait. setGovDelay's window is the CURRENT gov_delay (still initDelay here),
    // so its full request→execute is fast. setDelay's full execute is NOT tested — once armed
    // its window is gov_delay (24h) and the real-sleep harness can't wait that long; we
    // exercise its request path (invariant now satisfied) and revoke instead.
    describe("arming (setGovDelay / setDelay)", () => {

        it("setGovDelay: full request -> execute", async () => {
            const newGovDelay = minGovDelay; // 24h value; window is the CURRENT gov_delay
            const curGovDelay = (await getTokenState()).govDelay.toNumber();

            // request (window == current gov_delay == initDelay)
            await setGovDelay(owner, newGovDelay);
            const s1 = await getTokenState();
            assert.equal(s1.govDelay.toNumber(), curGovDelay); // unchanged until execute
            assert.equal(s1.nextGovDelay.toNumber(), newGovDelay);
            assert.isTrue(s1.nextGovDelayEt.toNumber() > 0);

            // too early
            await checkErrorCode(setGovDelay(owner, newGovDelay), "NotEffective");

            await increaseBlockTime(provider, curGovDelay);

            // mismatch
            await checkErrorCode(setGovDelay(owner, newGovDelay + 60), "RequestMismatch");

            // execute
            await setGovDelay(owner, newGovDelay);
            const s2 = await getTokenState();
            assert.equal(s2.govDelay.toNumber(), newGovDelay);
            assert.equal(s2.nextGovDelayEt.toNumber(), 0);
        });

        it("setDelay: request path (invariant satisfied) + revoke", async () => {
            // gov_delay is now 24h, so an in-bounds delay <= gov_delay is accepted.
            await setDelay(owner, minDelay); // 1h <= 24h
            const s1 = await getTokenState();
            assert.equal(s1.nextDelay.toNumber(), minDelay);
            assert.isTrue(s1.nextDelayEt.toNumber() > 0);

            // revoke by revoker (executing would need a 24h wait — out of scope for this harness)
            await revokeNextDelay(revoker);
            assert.equal((await getTokenState()).nextDelayEt.toNumber(), 0);
        });

        it("setGovDelay: revoke", async () => {
            await setGovDelay(owner, minGovDelay + 3600); // request (only the pending is needed)
            assert.isTrue((await getTokenState()).nextGovDelayEt.toNumber() > 0);
            await revokeNextGovDelay(owner);
            assert.equal((await getTokenState()).nextGovDelayEt.toNumber(), 0);
        });

    });

});
