module mtoken::mtoken_gov;

use mtoken::mtoken::State;
use sui::address;
use sui::clock::Clock;
use sui::coin;
use sui::deny_list::DenyList;
use sui::event;
use sui::hash::keccak256;

// === Constants ===

const MIN_DELAY: u64 = 3600; // 1 hour
const MAX_DELAY: u64 = 3600 * 48; // 2 days
const MIN_GOV_DELAY: u64 = 3600 * 24; // 1 day
const MAX_GOV_DELAY: u64 = 3600 * 24 * 7; // 7 days

const OP_SET_GOV_DELAY: u256 = 1;
const OP_SET_DELAY: u256 = 2;
const OP_SET_OPERATOR: u256 = 3;
const OP_SET_REVOKER: u256 = 4;
const OP_SET_RATE_LIMIT: u256 = 5;
const OP_SET_SINGLE_MSG_LIMIT: u256 = 6;
const OP_NEW_MESSENGER_CAP: u256 = 7;
const OP_REMOVE_RATE_LIMITER: u256 = 8;
const OP_ADD_TO_WHITELIST: u256 = 9;
const OP_UNPAUSE: u256 = 10;
const OP_ENABLE_CC_SEND: u256 = 11;

// === Errors ===

const EDelayTooShort: u64 = 200;
const EDelayTooLong: u64 = 201;
const ENoRateLimiter: u64 = 202;
const ENotNewRevoker: u64 = 203;
const ENoPendingRequest: u64 = 204;
const ENotPaused: u64 = 205;
const ECCSendNotDisabled: u64 = 206;

// === Events ===

public struct SetGovDelayRequestEvent has copy, drop {
    old_gov_delay: u64,
    new_gov_delay: u64,
    et: u64,
}

public struct SetGovDelayEffectedEvent has copy, drop {
    new_gov_delay: u64,
}

public struct SetDelayRequestEvent has copy, drop {
    old_delay: u64,
    new_delay: u64,
    et: u64,
}

public struct SetDelayEffectedEvent has copy, drop {
    new_delay: u64,
}

public struct SetOperatorRequestEvent has copy, drop {
    old_operator: address,
    new_operator: address,
    et: u64,
}

public struct SetOperatorEffectedEvent has copy, drop {
    new_operator: address,
}

public struct SetRevokerRequestEvent has copy, drop {
    old_revoker: address,
    new_revoker: address,
    et: u64,
}

public struct SetRevokerEffectedEvent has copy, drop {
    new_revoker: address,
}

public struct SetRateLimitRequestEvent has copy, drop {
    amount: u64,
    window_seconds: u64,
    et: u64,
}

public struct SetRateLimitEffectedEvent has copy, drop {
    amount: u64,
    window_seconds: u64,
}

public struct RemoveRateLimiterRequestEvent has copy, drop {
    et: u64,
}

public struct RemoveRateLimiterEffectedEvent has copy, drop {}

public struct NewMessengerCapRequestEvent has copy, drop {
    holder: address,
    et: u64,
}

public struct NewMessengerCapEffectedEvent has copy, drop {
    holder: address,
}

public struct AddToWhitelistRequestEvent has copy, drop {
    sender: vector<u8>,
    receiver: address,
    et: u64,
}

public struct AddToWhitelistEffectedEvent has copy, drop {
    sender: vector<u8>,
    receiver: address,
}

public struct SetSingleMsgLimitRequestEvent has copy, drop {
    limit: u64,
    et: u64,
}

public struct SetSingleMsgLimitEffectedEvent has copy, drop {
    limit: u64,
}

public struct UnpauseRequestEvent has copy, drop {
    et: u64,
}

public struct UnpauseEffectedEvent has copy, drop {}

public struct EnableCCSendRequestEvent has copy, drop {
    et: u64,
}

public struct EnableCCSendEffectedEvent has copy, drop {}

// === Gov Functions ===
// delayed & initiated by owner

// gov_delay is the timelock applied to governance-level operations (1d–7d):
// transfer_ownership, set_gov_delay, set_delay, set_revoker, new_messenger_cap,
// remove_rate_limiter, add_to_rate_limiter_whitelist.
// Changes to gov_delay are themselves timelocked by the current gov_delay value.
entry fun set_gov_delay<T>(
    state: &mut State<T>,
    new_gov_delay: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    assert!(new_gov_delay >= MIN_GOV_DELAY, EDelayTooShort);
    assert!(new_gov_delay <= MAX_GOV_DELAY, EDelayTooLong);
    assert!(new_gov_delay >= state.delay(), EDelayTooShort);

    let et = state.ensure_gov_delay(OP_SET_GOV_DELAY, new_gov_delay as u256, clock);
    if (et > 0) {
        event::emit(SetGovDelayRequestEvent {
            old_gov_delay: state.gov_delay(),
            new_gov_delay,
            et,
        });
    } else {
        state.set_gov_delay(new_gov_delay);
        event::emit(SetGovDelayEffectedEvent {
            new_gov_delay,
        });
    }
}

// Owner or revoker can cancel a pending gov_delay change.
entry fun revoke_set_gov_delay<T>(state: &mut State<T>, ctx: &TxContext) {
    state.check_version();
    state.check_owner_or_revoker(ctx);
    state.revoke_request(OP_SET_GOV_DELAY);
}

entry fun set_delay<T>(state: &mut State<T>, new_delay: u64, clock: &Clock, ctx: &TxContext) {
    state.check_version();
    state.check_owner(ctx);
    assert!(new_delay >= MIN_DELAY, EDelayTooShort);
    assert!(new_delay <= MAX_DELAY, EDelayTooLong);
    assert!(new_delay <= state.gov_delay(), EDelayTooLong);

    let et = state.ensure_gov_delay(OP_SET_DELAY, new_delay as u256, clock);
    if (et > 0) {
        let old_delay = state.delay();
        event::emit(SetDelayRequestEvent { old_delay, new_delay, et });
    } else {
        state.set_delay(new_delay);
        event::emit(SetDelayEffectedEvent { new_delay });
    }
}

entry fun revoke_set_delay<T>(state: &mut State<T>, ctx: &TxContext) {
    state.check_version();
    state.check_owner_or_revoker(ctx);
    state.revoke_request(OP_SET_DELAY);
}

entry fun set_operator<T>(
    state: &mut State<T>,
    new_operator: address,
    clock: &Clock,
    ctx: &TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    let et = state.ensure_delay(OP_SET_OPERATOR, address::to_u256(new_operator), clock);
    if (et > 0) {
        let old_operator = state.operator();
        event::emit(SetOperatorRequestEvent {
            old_operator,
            new_operator,
            et,
        });
    } else {
        state.set_operator(new_operator);
        event::emit(SetOperatorEffectedEvent { new_operator });
    }
}

entry fun revoke_set_operator<T>(state: &mut State<T>, ctx: &TxContext) {
    state.check_version();
    state.check_owner_or_revoker(ctx);
    state.revoke_request(OP_SET_OPERATOR);
}

entry fun set_revoker<T>(
    state: &mut State<T>,
    new_revoker: address,
    clock: &Clock,
    ctx: &TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    let et = state.ensure_gov_delay(OP_SET_REVOKER, address::to_u256(new_revoker), clock);
    assert!(et > 0, ENotNewRevoker);
    let old_revoker = state.revoker();
    event::emit(SetRevokerRequestEvent {
        old_revoker,
        new_revoker,
        et,
    });
}

entry fun accept_revoker<T>(state: &mut State<T>, clock: &Clock, ctx: &TxContext) {
    state.check_version();
    let new_revoker = ctx.sender();
    let et = state.ensure_gov_delay(OP_SET_REVOKER, address::to_u256(new_revoker), clock);
    assert!(et == 0, ENoPendingRequest);
    state.set_revoker(new_revoker);
    event::emit(SetRevokerEffectedEvent { new_revoker });
}

entry fun revoke_set_revoker<T>(state: &mut State<T>, ctx: &TxContext) {
    state.check_version();
    state.check_owner_or_operator(ctx);
    state.revoke_request(OP_SET_REVOKER);
}

entry fun unpause<T>(
    state: &mut State<T>,
    deny_list: &mut DenyList,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    // an unpause request may only be created (and executed) while actually
    // paused — otherwise the owner could pre-plant a matured request during
    // normal operation and instantly defeat a future emergency pause
    // (next-epoch flag reflects the latest pause/unpause action immediately)
    assert!(coin::deny_list_v2_is_global_pause_enabled_next_epoch<T>(deny_list), ENotPaused);
    let et = state.ensure_delay(OP_UNPAUSE, 0u256, clock);
    if (et > 0) {
        event::emit(UnpauseRequestEvent { et });
    } else {
        state.unpause(deny_list, ctx);
        event::emit(UnpauseEffectedEvent {});
    }
}

entry fun revoke_unpause<T>(state: &mut State<T>, ctx: &TxContext) {
    state.check_version();
    state.check_owner_or_revoker(ctx);
    state.revoke_request(OP_UNPAUSE);
}

// re-enable cross-chain token sends after the operator disabled them;
// mirrors pause/unpause: operator disables immediately, owner re-enables with delay
entry fun enable_cc_send<T>(state: &mut State<T>, clock: &Clock, ctx: &TxContext) {
    state.check_version();
    state.check_owner(ctx);
    // an enable request may only be created (and executed) while cc-send is
    // actually disabled — otherwise the owner could pre-plant a matured
    // request during normal operation and instantly defeat a future
    // emergency disable
    assert!(state.is_cc_send_disabled(), ECCSendNotDisabled);
    let et = state.ensure_delay(OP_ENABLE_CC_SEND, 0u256, clock);
    if (et > 0) {
        event::emit(EnableCCSendRequestEvent { et });
    } else {
        state.set_cc_send_disabled(false);
        event::emit(EnableCCSendEffectedEvent {});
    }
}

entry fun revoke_enable_cc_send<T>(state: &mut State<T>, ctx: &TxContext) {
    state.check_version();
    state.check_owner_or_revoker(ctx);
    state.revoke_request(OP_ENABLE_CC_SEND);
}

entry fun new_messenger_cap<T>(
    state: &mut State<T>,
    holder: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    let et = state.ensure_gov_delay(OP_NEW_MESSENGER_CAP, address::to_u256(holder), clock);
    if (et > 0) {
        event::emit(NewMessengerCapRequestEvent { holder, et });
    } else {
        state.cc_new_messenger_cap(holder, ctx);
        event::emit(NewMessengerCapEffectedEvent { holder });
    }
}

entry fun revoke_new_messenger_cap<T>(state: &mut State<T>, ctx: &TxContext) {
    state.check_version();
    state.check_owner_or_revoker(ctx);
    state.revoke_request(OP_NEW_MESSENGER_CAP);
}

// remove the rate limiter from the state
// note: aborts if there are pending rate-limited messages to prevent silent token loss.
// process or discard all queued messages before calling this.
entry fun remove_rate_limiter<T>(state: &mut State<T>, clock: &Clock, ctx: &TxContext) {
    state.check_version();
    state.check_owner(ctx);
    let et = state.ensure_gov_delay(OP_REMOVE_RATE_LIMITER, 0u256, clock);
    if (et > 0) {
        event::emit(RemoveRateLimiterRequestEvent { et });
    } else {
        state.remove_rate_limiter();
        event::emit(RemoveRateLimiterEffectedEvent {});
    }
}

entry fun revoke_remove_rate_limiter<T>(state: &mut State<T>, ctx: &TxContext) {
    state.check_version();
    state.check_owner_or_revoker(ctx);
    state.revoke_request(OP_REMOVE_RATE_LIMITER);
}

entry fun set_rate_limit<T>(
    state: &mut State<T>,
    amount: u64,
    window_seconds: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    assert!(state.has_rate_limiter(), ENoRateLimiter);
    // Pack window_seconds into upper 64 bits, amount into lower 64 bits.
    let new_value = ((window_seconds as u256) << 64) | (amount as u256);
    let et = state.ensure_delay(OP_SET_RATE_LIMIT, new_value, clock);
    if (et > 0) {
        event::emit(SetRateLimitRequestEvent { amount, window_seconds, et });
    } else {
        state.set_rate_limit(amount, window_seconds, clock);
        event::emit(SetRateLimitEffectedEvent { amount, window_seconds });
    }
}

entry fun revoke_set_rate_limit<T>(state: &mut State<T>, ctx: &TxContext) {
    state.check_version();
    state.check_owner_or_revoker(ctx);
    state.revoke_request(OP_SET_RATE_LIMIT);
}

entry fun set_single_msg_limit<T>(
    state: &mut State<T>,
    limit: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    assert!(state.has_rate_limiter(), ENoRateLimiter);
    let et = state.ensure_delay(OP_SET_SINGLE_MSG_LIMIT, limit as u256, clock);
    if (et > 0) {
        event::emit(SetSingleMsgLimitRequestEvent { limit, et });
    } else {
        state.set_single_msg_limit(limit);
        event::emit(SetSingleMsgLimitEffectedEvent { limit });
    }
}

entry fun revoke_set_single_msg_limit<T>(state: &mut State<T>, ctx: &TxContext) {
    state.check_version();
    state.check_owner_or_revoker(ctx);
    state.revoke_request(OP_SET_SINGLE_MSG_LIMIT);
}

// Only one pending add_to_whitelist request can exist at a time: while a request is pending
// and the delay has not elapsed, a second call aborts with ENotEffective. Execute or revoke
// the current request before queuing the next.
entry fun add_to_rate_limiter_whitelist<T>(
    state: &mut State<T>,
    sender: vector<u8>,
    receiver: address,
    clock: &Clock,
    ctx: &TxContext,
) {
    state.check_version();
    state.check_owner(ctx);
    assert!(state.has_rate_limiter(), ENoRateLimiter);

    let mut data = vector[];
    data.append(sender);
    data.append(receiver.to_bytes());
    let hash = keccak256(&data);
    let val = address::from_bytes(hash).to_u256(); // → u256

    let et = state.ensure_gov_delay(OP_ADD_TO_WHITELIST, val, clock);
    if (et > 0) {
        event::emit(AddToWhitelistRequestEvent { sender, receiver, et });
    } else {
        state.add_to_rate_limiter_whitelist(sender, receiver);
        event::emit(AddToWhitelistEffectedEvent { sender, receiver });
    }
}

entry fun revoke_add_to_whitelist<T>(state: &mut State<T>, ctx: &TxContext) {
    state.check_version();
    state.check_owner_or_revoker(ctx);
    state.revoke_request(OP_ADD_TO_WHITELIST);
}
