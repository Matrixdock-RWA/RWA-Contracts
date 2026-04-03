#![no_std]

mod contract;
mod error;
mod events;
mod state;
mod storage_types;
mod test;

pub use crate::contract::BullionMinterClient;
