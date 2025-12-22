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
    setOwner, setRevoker, setOperator, setMessager, setDelay, 
    revokeNextOwner, revokeNextRevoker, revokeNextOperator, revokeNextMessager, revokeNextDelay,
    changeMintBudget, mint, redeem, revokeNextMint, addToBlockedList, removeFromBlockedList,
    forcedTransfer,
    updateMetadata, updateTransferFee, setPaused,
    withdrawTransferFees,
} from "./utils/mtoken";

const minDelay = 3600; // 1 hour
const maxDelay = 48 * 3600; // 48 hours

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

    it("initialize", async () => {
        await createToken(deployer.payer, xaumName, xaumSymbol, xaumUri, initDelay);
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
        assert.deepEqual(stateData.nextMintRecipient, admin);
        assert.deepEqual(stateData.nextMintAmount.toNumber(), 0);
        assert.deepEqual(stateData.nextMintEt.toNumber(), 0);
        assert.equal(stateData.mintBudget.toNumber(), 0);

        await checkErrorMsg(
            createToken(deployer.payer, xaumName, xaumSymbol, xaumUri, initDelay),
            "already in use",
        );
    });

    describe("delayed ops", () => {
        const testCases = [
            {name: "setOwner", func: setOwner, revokeFunc: revokeNextOwner, field: "owner", nextField: "nextOwner", nextEtField: "nextOwnerEt", roleErr: "NotOwner", caller: deployer.payer, oldVal: deployer.payer.publicKey, newVal: owner.publicKey, newVal2: user1.publicKey, revoker: owner},
            {name: "setRevoker", func: setRevoker, revokeFunc: revokeNextRevoker, field: "revoker", nextField: "nextRevoker", nextEtField: "nextRevokerEt", roleErr: "NotOwner", caller: owner, oldVal: deployer.payer.publicKey, newVal: revoker.publicKey, newVal2: user1.publicKey, revoker: owner},
            {name: "setOperator", func: setOperator, revokeFunc: revokeNextOperator, field: "operator", nextField: "nextOperator", nextEtField: "nextOperatorEt", roleErr: "NotOwner", caller: owner, oldVal: deployer.payer.publicKey, newVal: operator.publicKey, newVal2: user1.publicKey, revoker},
            {name: "setMessager", func: setMessager, revokeFunc: revokeNextMessager, field: "messager", nextField: "nextMessager", nextEtField: "nextMessagerEt", roleErr: "NotOwner", caller: owner, oldVal: deployer.payer.publicKey, newVal: messager.publicKey, newVal2: user1.publicKey, revoker: revoker},
            {name: "setDelay", func: setDelay, revokeFunc: revokeNextDelay, field: "delay", nextField: "nextDelay", nextEtField: "nextDelayEt", roleErr: "NotOwner", caller: owner, oldVal: new anchor.BN(initDelay), newVal: new anchor.BN(initDelay - 1), newVal2: new anchor.BN(12345), revoker},
        ];

        for (const testCase of testCases) {
            const {name, func, field, nextField, nextEtField, roleErr, caller, oldVal, newVal, newVal2} = testCase;

            it(name, async () => {
                await checkErrorCode(func(user1, newVal as any), roleErr);

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

        for (const testCase of testCases) {
            const {name, func, revokeFunc, nextEtField, caller, oldVal, revoker} = testCase;

            it("revoke_" + name, async () => {
                const err = revoker == owner ? "NotOwner" : "NotRevoker";
                await checkErrorCode(revokeFunc(user1), err);

                // request
                await func(name == "setOwner" ? owner : caller, oldVal as any);
                const state = await getTokenState();
                assert.isTrue(state[nextEtField].toNumber() > 0);

                // revoke
                await revokeFunc(revoker);
                const state2 = await getTokenState();
                assert.isTrue(state2[nextEtField].toNumber() == 0);  
            });
        } // end of for

    }); // end of describe

    describe("state config", () => {
        it("setDelay", async () => {
            await checkErrorCode(setDelay(owner, minDelay - 1), "DelayBelowMinimum");
            await checkErrorCode(setDelay(owner, maxDelay + 1), "DelayExceedsMaximum");
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
            await checkErrorCode(setPaused(user1, true), "NotOwner");
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
            await setPaused(owner, true); // ok
            await setPaused(owner, false); // ok
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
            await checkErrorCode(revokeNextMint(user1), "NotRevoker");

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

            await checkErrorCode(mint(operator, user1.publicKey, 100, 0, false, user2.publicKey), "InvalidATA");
            await checkErrorCode(mint(operator, user1.publicKey, 100, 0, false, user.publicKey), "InvalidATA");
            await checkErrorCode(mint(operator, user.publicKey, 100, 0, false, user2.publicKey), "InvalidATA");

            await mint(operator, user.publicKey, 300);
            await increaseBlockTime(provider, initDelay);
            await checkErrorMsg(getTokenAccount(user.publicKey), "TokenAccountNotFoundError");
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

        it("forced_transfer", async () => {
          await checkErrorCode(forcedTransfer(user1, user2.publicKey, user1.publicKey, 100), "NotOwner");
          const bal1a = await getTokenBalance(user1.publicKey);
          const bal2a = await getTokenBalance(user2.publicKey);
          // console.log('bal1a:', bal1a);
          // console.log('bal2a:', bal2a);

          await forcedTransfer(owner, user1.publicKey, user2.publicKey, 100);
          const bal1b = await getTokenBalance(user1.publicKey);
          const bal2b = await getTokenBalance(user2.publicKey);
          // console.log('bal1b:', bal1b);
          // console.log('bal2b:', bal2b);
          assert.equal(bal1b, bal1a - 100);
          assert.equal(bal2b, bal2a + 100);
        });

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
            await setPaused(owner, true); // ok
            await checkErrorMsg(
                transferToken(user1, user2.publicKey, 100),
                "Transferring, minting, and burning is paused on this mint",
            );
        });

    });

});