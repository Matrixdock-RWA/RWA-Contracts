#[test_only]
module xaum::xaum_tests;

use sui::test_scenario;
use xaum::mt as xaum;

#[test]
fun test_xaum() {
    let mut scenario = test_scenario::begin(@0x0);
    scenario.next_tx(@0xAD);
    xaum::init_for_testing(scenario.ctx());
    scenario.end();
}
