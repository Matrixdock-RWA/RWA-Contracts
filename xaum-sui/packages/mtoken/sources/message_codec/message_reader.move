module mtoken::message_reader;

const EEndOfMessage: u64 = 1;

public struct MessageReader has drop {
    msg: vector<u8>,
    pos: u64,
}

public fun new(msg: vector<u8>): MessageReader {
    MessageReader { msg, pos: 0 }
}

public fun position(reader: &MessageReader): u64 {
    reader.pos
}

public fun remaining(reader: &MessageReader): u64 {
    reader.msg.length() - reader.pos
}

public fun read_data_pad32(reader: &mut MessageReader, mut n: u64): vector<u8> {
    let padding = if (n % 32 != 0) { 32 - n % 32 } else { 0 };
    assert!(reader.pos + n + padding <= reader.msg.length(), EEndOfMessage);
    let mut result: vector<u8> = vector::empty();
    while (n > 0) {
        result.push_back(reader.msg[reader.pos]);
        reader.pos = reader.pos + 1;
        n = n - 1;
    };
    reader.pos = reader.pos + padding; // skip padding
    result
}

public fun read_u256(reader: &mut MessageReader): u256 {
    let bytes = reader.read_data_pad32(32);
    bytes_to_u256_be(&bytes)
}

public fun bytes_to_u256_be(bytes: &vector<u8>): u256 {
    let mut result = 0u256;
    let len = vector::length(bytes);
    let mut i = 0;

    while (i < len) {
        let b = *vector::borrow(bytes, i);
        result = (result << 8) + (b as u256);
        i = i + 1;
    };

    result
}
