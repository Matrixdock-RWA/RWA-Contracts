module messenger_lz::ptb_builder;

use messenger_lz::messenger_oapp::State;
use mtoken::mtoken::State as MtState;
use oapp::oapp::OApp;
use oapp::ptb_builder_helper;
use ptb_move_call::argument;
use ptb_move_call::move_call::{Self, MoveCall};
use ptb_move_call::move_calls_builder;
use sui::bcs;
use utils::buffer_writer;
use utils::package;
use xagm::xagm::XAGM;

// https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/sui/contracts/oapps/oft/oft/sources/oft_ptb_builder.move#L19
const LZ_RECEIVE_INFO_VERSION_1: u16 = 1;

// https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/sui/contracts/oapps/oft/oft/sources/oft_ptb_builder.move#L21
public struct MsgPtbBuilder {}
public struct MsgPtbBuilder2 {}

// https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/sui/contracts/oapps/oft/oft/sources/oft_ptb_builder.move#L31
public fun lz_receive_info(state: &State, mt_state: &MtState<XAGM>, my_oapp: &OApp): vector<u8> {
    let lz_receive_move_calls = vector[
        move_call::create(
            msg_package(), // package_name
            b"ptb_builder".to_ascii_string(), // module_name
            b"build_lz_receive_ptb".to_ascii_string(), // function_name
            vector[
                argument::create_object(object::id_address(state)),
                argument::create_object(object::id_address(mt_state)),
                argument::create_object(object::id_address(my_oapp)),
            ], // args
            vector[], // type_args
            true, // is_builder_call
            vector[], // result_ids
        ),
    ];
    let move_calls_bytes = bcs::to_bytes(&lz_receive_move_calls);
    let mut writer = buffer_writer::new();
    writer.write_u16(LZ_RECEIVE_INFO_VERSION_1).write_bytes(move_calls_bytes);
    writer.to_bytes()
}

// https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/sui/contracts/oapps/oft/oft/sources/oft_ptb_builder.move#L69
public fun build_lz_receive_ptb(
    state: &State,
    mt_state: &MtState<XAGM>,
    my_oapp: &OApp,
): vector<MoveCall> {
    let mut builder = move_calls_builder::new();
    builder.add(
        move_call::create(
            msg_package(), // package_name
            b"messenger_oapp".to_ascii_string(), // module_name
            b"lz_receive_v2".to_ascii_string(), // function_name
            vector[
                argument::create_object(object::id_address(state)),
                argument::create_object(object::id_address(mt_state)),
                argument::create_object(object::id_address(my_oapp)),
                argument::create_id(ptb_builder_helper::lz_receive_call_id()),
                argument::create_object(@0x403), // deny_list
                argument::create_object(@0x06), // clock
            ], // args
            vector[], // type_args
            false, // is_builder_call
            vector[], // result_ids
        ),
    );
    builder.build()
}

// Returns the current package address of the MsgPtbBuilder
// When upgrading messenger_lz, create a new struct (e.g., MsgPtbBuilder2)
public fun msg_package(): address {
    package::package_of_type<MsgPtbBuilder2>()
}
