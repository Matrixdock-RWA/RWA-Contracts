// wrapper for rate limiter to add queueing functionality
module mtoken::mtoken_rate_limiter;

use mtoken::rate_limiter::{Self, RateLimiter};
use sui::clock::Clock;
use sui::event;
use sui::table::{Self, Table};

// === Constants ===

const GLOBAL_EID: u32 = 1; // we enforces a global rate limit.

// === Events ===

public struct RateLimitedMsgAddedEvent has copy, drop {
    msg_id: u64,
    sender: vector<u8>,
    receiver: address,
    amount: u64,
}

public struct RateLimitedMsgRemovedEvent has copy, drop {
    msg_id: u64,
}

public struct SingleMsgLimitUpdatedEvent has copy, drop {
    limit: u64,
}

public struct WhitelistUpdatedEvent has copy, drop {
    sender: vector<u8>,
    receiver: address,
    flag: bool,
}

// === Structs ===

public struct RateLimitedMsg has drop, store {
    sender: vector<u8>,
    receiver: address,
    amount: u64,
}

// Key for the whitelist table: (sender, receiver) pair.
public struct WhitelistKey has copy, drop, store {
    sender: vector<u8>,
    receiver: address,
}

public struct MTokenRateLimiter has store {
    rate_limiter: RateLimiter,
    rate_limited_msgs: Table<u64, RateLimitedMsg>,
    next_msg_id: u64,
    // 0 = disabled; when set, a single message exceeding this amount is queued
    // regardless of remaining window capacity.
    single_msg_limit: u64,
    // (sender, receiver) pairs that bypass all rate limiting checks.
    whitelist: Table<WhitelistKey, bool>,
}

// === Creation ===

public(package) fun create(ctx: &mut TxContext): MTokenRateLimiter {
    MTokenRateLimiter {
        rate_limiter: rate_limiter::create(true, ctx),
        rate_limited_msgs: table::new(ctx),
        next_msg_id: 0, // start from 0, incremented by 1 for each new message.
        single_msg_limit: 0,
        whitelist: table::new(ctx),
    }
}

// === Rate Limit Core Functions ===

public(package) fun try_consume_rate_limit_capacity(
    self: &mut MTokenRateLimiter,
    sender: vector<u8>,
    receiver: address,
    amount: u64,
    clock: &Clock,
): bool {
    // whitelist bypass: skip all rate limiting for whitelisted (sender, receiver) pairs.
    if (self.is_in_whitelist(sender, receiver)) {
        return true
    };

    // check single message limit and window rate limit together.
    // both must pass; a single message exceeding single_msg_limit is queued even
    // if window capacity is available.
    let limit = self.single_msg_limit;
    if (
        (limit == 0 || amount <= limit) &&
        self.rate_limiter.try_consume_rate_limit_capacity(GLOBAL_EID, amount, clock)
    ) {
        return true
    };

    // message overflowed, enqueued for later processing.
    let msg = RateLimitedMsg { sender, receiver, amount };
    let msg_id = self.next_msg_id;
    self.rate_limited_msgs.add(msg_id, msg);
    self.next_msg_id = self.next_msg_id + 1;
    event::emit(RateLimitedMsgAddedEvent {
        msg_id,
        sender,
        receiver,
        amount,
    });
    false
}

public(package) fun remove_rate_limited_msg(
    self: &mut MTokenRateLimiter,
    msg_id: u64,
): (vector<u8>, address, u64) {
    let msg = self.rate_limited_msgs.remove(msg_id);
    event::emit(RateLimitedMsgRemovedEvent { msg_id });
    let RateLimitedMsg { sender, receiver, amount } = msg;
    (sender, receiver, amount)
}

// === Rate Limit Management ===

// Set the rate limit and the window
public(package) fun set_rate_limit(
    self: &mut MTokenRateLimiter,
    amount: u64,
    window_seconds: u64,
    clock: &Clock,
) {
    self.rate_limiter.set_rate_limit(GLOBAL_EID, amount, window_seconds, clock)
}

// Set the per-message amount limit. 0 disables the check.
// A message with amount > limit is queued regardless of window capacity.
public(package) fun set_single_msg_limit(self: &mut MTokenRateLimiter, limit: u64) {
    self.single_msg_limit = limit;
    event::emit(SingleMsgLimitUpdatedEvent { limit });
}

// Add or update a whitelist entry. flag=true bypasses rate limiting; flag=false re-enables it.
public(package) fun update_whitelist(
    self: &mut MTokenRateLimiter,
    sender: vector<u8>,
    receiver: address,
    flag: bool,
) {
    let key = WhitelistKey { sender, receiver };
    if (self.whitelist.contains(key)) {
        *self.whitelist.borrow_mut(key) = flag;
    } else {
        self.whitelist.add(key, flag);
    };
    event::emit(WhitelistUpdatedEvent { sender, receiver, flag });
}

// === Drop Function ===

public(package) fun drop(self: MTokenRateLimiter) {
    let MTokenRateLimiter { rate_limiter, rate_limited_msgs, whitelist, .. } = self;
    rate_limiter.drop();
    rate_limited_msgs.drop();
    whitelist.drop();
}

// === View Functions ===

// return the rate limit and window (in seconds)
public(package) fun get_rate_limit(self: &MTokenRateLimiter): (u64, u64) {
    self.rate_limiter.rate_limit_config(GLOBAL_EID)
}

// return (in_flight, capacity) at the current clock time
public(package) fun amount_can_be_received(self: &MTokenRateLimiter, clock: &Clock): (u64, u64) {
    let in_flight = self.rate_limiter.in_flight(GLOBAL_EID, clock);
    let capacity = self.rate_limiter.rate_limit_capacity(GLOBAL_EID, clock);
    (in_flight, capacity)
}

// return (sender, receiver, amount) of a queued rate-limited message
public(package) fun rate_limited_msg(
    self: &MTokenRateLimiter,
    msg_id: u64,
): (vector<u8>, address, u64) {
    let msg = &self.rate_limited_msgs[msg_id];
    (msg.sender, msg.receiver, msg.amount)
}

// return true if the message is queued
public(package) fun has_rate_limited_msg(self: &MTokenRateLimiter, msg_id: u64): bool {
    self.rate_limited_msgs.contains(msg_id)
}

// return true if there are any pending rate-limited messages
public(package) fun has_pending_msgs(self: &MTokenRateLimiter): bool {
    !self.rate_limited_msgs.is_empty()
}

// return the single message limit (0 = disabled)
public(package) fun get_single_msg_limit(self: &MTokenRateLimiter): u64 {
    self.single_msg_limit
}

// return true if the (sender, receiver) pair is whitelisted
public(package) fun is_in_whitelist(
    self: &MTokenRateLimiter,
    sender: vector<u8>,
    receiver: address,
): bool {
    let key = WhitelistKey { sender, receiver };
    self.whitelist.contains(key) && *self.whitelist.borrow(key)
}
