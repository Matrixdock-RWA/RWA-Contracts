#[test_only]
module xagm::xagm_tests;

use sui::test_scenario;
use xagm::xagm;

#[test]
fun test_xagm() {
    let mut scenario = test_scenario::begin(@0x0);
    xagm::init_for_testing(scenario.ctx());
    scenario.end();
}
