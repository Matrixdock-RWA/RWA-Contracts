module mtoken::message_writer;

use std::bcs;

public struct MessageWriter {
    msg: vector<u8>,
}

public fun new(): MessageWriter {
    MessageWriter { msg: vector[] }
}

public fun write_data_pad32(writer: &mut MessageWriter, data: vector<u8>) {
    writer.msg.append(data);
    let mut padding = 32 - data.length() % 32;
    if (padding != 32) {
        while (padding > 0) {
            writer.msg.push_back(0x00);
            padding = padding - 1;
        };
    };
}

public fun write_u256(writer: &mut MessageWriter, val: u256) {
    let mut bytes = bcs::to_bytes(&val); // little endian
    bytes.reverse(); // now big endian
    writer.write_data_pad32(bytes);
}

public fun extract_message(writer: MessageWriter): vector<u8> {
    let MessageWriter { msg } = writer;
    msg
}
