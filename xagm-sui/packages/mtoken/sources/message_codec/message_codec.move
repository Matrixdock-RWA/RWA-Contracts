module mtoken::message_codec;

use mtoken::message_reader;
use mtoken::message_writer;
use sui::address;

/*

format of send_mint_budget message:
0x00: 0000000000000000000000000000000000000000000000000000000000000003 // (fixed) tag
0x20: 0000000000000000000000000000000000000000000000000000000000000040 // (fixed) payload offset
0x40: 0000000000000000000000000000000000000000000000000000000000000020 // (fixed) payload length
0x60: 0000000000000000000000000000000000000000000000000000000000012345 // amount

format of send_token message:
0x00: 0000000000000000000000000000000000000000000000000000000000000002 // (fixed) tag
0x20: 0000000000000000000000000000000000000000000000000000000000000040 // (fixed) payload offset
0x40: 00000000000000000000000000000000000000000000000000000000000000e0 // payload length
0x60: ................................................................ // payload

format of send_token payload:
0x00: 0000000000000000000000000000000000000000000000000000000000000060 // (fixed) sender offset
0x20: 00000000000000000000000000000000000000000000000000000000000000a0 // receiver offset
0x40: 0000000000000000000000000000000000000000000000000000000000012345 // amount
0x60: 0000000000000000000000000000000000000000000000000000000000000020 // sender length
0x80: ................................................................ // sender address
0xA0: 0000000000000000000000000000000000000000000000000000000000000020 // receiver length
0xC0: ................................................................ // receiver addr

*/

// === Constants ===
const SUI_ADDR_LENGTH: u64 = 32;
const HEADER_LENGTH: u64 = 96u64;
const TAG_SEND_TOKEN: u256 = 2u256;
const TAG_SEND_MINT_BUDGET: u256 = 3u256;
const PAYLOAD_OFFSET: u256 = 64u256; // 0x40
const MINT_BUDGET_MSG_LENGTH: u64 = 128u64; // 0x80
const MINT_BUDGET_PAYLOAD_LENGTH: u256 = 32u256; // 0x20
const OUTBOUND_SENDER_OFFSET: u256 = 0x60u256;
const OUTBOUND_RECEIVER_OFFSET: u256 = 0xa0u256;
// const SHARED_DECIMALS: u8 = 9;
// const LOCAL_DECIMALS: u8 = 9;
const DECIMALS_SCALE_FACTOR: u256 = 1; // 10u256.pow(LOCAL_DECIMALS - SHARED_DECIMALS);

// === Errors ===
const EInvalidMessageTag: u64 = 1;
const EInvalidMessageLength: u64 = 2;
const EInvalidPayloadOffset: u64 = 3;
const EInvalidPayloadLength: u64 = 4;
const EInvalidSenderOffset: u64 = 5;
const EInvalidReceiverOffset: u64 = 6;
const EInvalidReceiverLength: u64 = 7;

public enum CCInboundMessage {
    MintBudget(u64),
    Token(CCInboundToken),
}

public struct CCInboundToken {
    sender: vector<u8>,
    receiver: address,
    amount: u64,
}

public fun to_shared_decimals(amount: u64): u256 {
    (amount as u256) * DECIMALS_SCALE_FACTOR
}

public fun to_local_decimals(amount: u256): u64 {
    (amount / DECIMALS_SCALE_FACTOR).try_as_u64().extract()
}

// === CCInboundMessage ===

public fun is_mint_budget(msg: &CCInboundMessage): bool {
    match (msg) {
        CCInboundMessage::MintBudget(_) => true,
        _ => false,
    }
}

public fun extract_mint_budget(msg: CCInboundMessage): u64 {
    match (msg) {
        CCInboundMessage::MintBudget(amount) => amount,
        CCInboundMessage::Token(token) => {
            let CCInboundToken { .. } = token;
            abort
        },
    }
}

public fun is_token(msg: &CCInboundMessage): bool {
    match (msg) {
        CCInboundMessage::Token(_) => true,
        _ => false,
    }
}

public fun extract_token_info(msg: CCInboundMessage): (vector<u8>, address, u64) {
    match (msg) {
        CCInboundMessage::Token(token) => {
            let CCInboundToken { sender, receiver, amount } = token;
            (sender, receiver, amount)
        },
        CCInboundMessage::MintBudget(_) => abort,
    }
}

// === Encoding ===

public fun encode_cc_mint_budget_message(amount: u64): vector<u8> {
    let mut writer = message_writer::new();
    writer.write_u256(TAG_SEND_MINT_BUDGET);
    writer.write_u256(PAYLOAD_OFFSET);
    writer.write_u256(MINT_BUDGET_PAYLOAD_LENGTH as u256);
    writer.write_u256(to_shared_decimals(amount));
    writer.extract_message()
}

public fun encode_cc_token_message(sender: address, receiver: vector<u8>, amount: u64): vector<u8> {
    let payload = encode_cc_token_payload(sender, receiver, amount);
    let mut writer = message_writer::new();
    writer.write_u256(TAG_SEND_TOKEN);
    writer.write_u256(PAYLOAD_OFFSET);
    writer.write_u256(payload.length() as u256);
    writer.write_data_pad32(payload);
    writer.extract_message()
}

fun encode_cc_token_payload(sender: address, receiver: vector<u8>, amount: u64): vector<u8> {
    let mut writer = message_writer::new();
    writer.write_u256(OUTBOUND_SENDER_OFFSET); // offset of sender, fixed
    writer.write_u256(OUTBOUND_RECEIVER_OFFSET); // offset of receiver, fixed
    writer.write_u256(to_shared_decimals(amount)); // amount
    writer.write_u256(SUI_ADDR_LENGTH as u256); // sender length
    writer.write_data_pad32(sender.to_bytes()); // sender address
    writer.write_u256(receiver.length() as u256); // receiver length
    writer.write_data_pad32(receiver); // receiver address
    writer.extract_message()
}

// === Decoding ===

public fun decode_cc_message(msg: vector<u8>): CCInboundMessage {
    assert!(msg.length() > HEADER_LENGTH, EInvalidMessageLength);
    let tag = msg[31] as u256;
    if (tag == TAG_SEND_MINT_BUDGET) {
        CCInboundMessage::MintBudget(decode_cc_mint_budget_message(msg))
    } else if (tag == TAG_SEND_TOKEN) {
        CCInboundMessage::Token(decode_cc_token_message(msg))
    } else {
        assert!(false, EInvalidMessageTag);
        abort // unreachable
    }
}

fun decode_cc_mint_budget_message(message: vector<u8>): u64 {
    assert!(message.length() == MINT_BUDGET_MSG_LENGTH, EInvalidMessageLength);
    let mut reader = message_reader::new(message);
    assert!(reader.read_u256() == TAG_SEND_MINT_BUDGET, EInvalidMessageTag);
    assert!(reader.read_u256() == PAYLOAD_OFFSET, EInvalidPayloadOffset);
    assert!(reader.read_u256() == MINT_BUDGET_PAYLOAD_LENGTH, EInvalidPayloadLength);
    let amount = reader.read_u256();
    to_local_decimals(amount)
}

fun decode_cc_token_message(message: vector<u8>): CCInboundToken {
    let mut reader = message_reader::new(message);
    assert!(reader.read_u256() == TAG_SEND_TOKEN, EInvalidMessageTag);
    assert!(reader.read_u256() == PAYLOAD_OFFSET, EInvalidPayloadOffset);
    let payload_len = reader.read_u256();
    assert!(reader.remaining() as u256 == payload_len, EInvalidPayloadLength);

    // decode payload
    let sender_offset = reader.read_u256();
    let receiver_offset = reader.read_u256();
    let amount = reader.read_u256();
    let sender_pos = reader.position();
    let sender_len = reader.read_u256();
    let sender = reader.read_data_pad32(sender_len as u64);
    let receiver_pos = reader.position();
    let receiver_len = reader.read_u256();
    let receiver = reader.read_data_pad32(receiver_len as u64);

    assert!((sender_pos - HEADER_LENGTH) as u256 == sender_offset, EInvalidSenderOffset);
    assert!((receiver_pos - HEADER_LENGTH) as u256 == receiver_offset, EInvalidReceiverOffset);
    assert!(receiver.length() == SUI_ADDR_LENGTH, EInvalidReceiverLength);

    CCInboundToken {
        sender,
        receiver: address::from_bytes(receiver),
        amount: to_local_decimals(amount),
    }
}
