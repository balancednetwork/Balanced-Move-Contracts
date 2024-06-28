// Copyright (c) Sui Foundation, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module balanced::balanced_dollar_test {
    use sui::test_scenario::{Self, next_tx, ctx, Scenario};
    use std::string::{Self, String};

    use sui::coin::{Self, TreasuryCap};
    use sui::sui::SUI;
    use sui::math;
    use sui::hex;

    use xcall::xcall_state::{Self, Storage as XCallState, ConnCap};
    use xcall::main::{Self as xcall, init_xcall_state};
    use xcall::cs_message::{Self};
    use xcall::message_request::{Self};
    use xcall::network_address::{Self};
    use xcall::message_result::{Self};

    use balanced::xcall_manager::{Self, WitnessCarrier as XcallManagerWitnessCarrier};
    use balanced::balanced_dollar_crosschain::{Self, AdminCap, Config, configure, cross_transfer, WitnessCarrier, get_treasury_cap_for_testing    };
    use balanced_dollar::balanced_dollar::{Self, BALANCED_DOLLAR};
    
    use balanced::cross_transfer::{wrap_cross_transfer, encode};
    use balanced::cross_transfer_revert::{Self, wrap_cross_transfer_revert};

    const ADMIN: address = @0xBABE;
    const TO: vector<u8> = b"sui/address";
    
    const ICON_BnUSD: vector<u8> = b"icon/hx734";

    const TO_ADDRESS: vector<u8>  = b"sui-test/0000000000000000000000000000000000000000000000000000000000001234";
    const FROM_ADDRESS: vector<u8>  = b"000000000000000000000000000000000000000000000000000000000000123d";
    const ADDRESS_TO_ADDRESS: address = @0x645d;

     #[test_only]
    fun setup_test(admin:address):Scenario {
        let mut scenario = test_scenario::begin(admin);
        balanced_dollar::init_test(scenario.ctx());
        scenario.next_tx(admin);
        balanced_dollar_crosschain::init_test(scenario.ctx());
        scenario.next_tx(admin);
        scenario = init_xcall_state(admin, scenario);
        scenario.next_tx(admin);
        xcall_manager::init_test(scenario.ctx());
        scenario.next_tx(admin);
        let adminCap = scenario.take_from_sender<AdminCap>();
        let managerAdminCap = scenario.take_from_sender<xcall_manager::AdminCap>();
        let xcall_state= scenario.take_shared<XCallState>();
        let carrier = scenario.take_from_sender<WitnessCarrier>();
        let sources = vector[string::utf8(b"centralized-1")];
        let destinations = vector[string::utf8(b"icon/hx234"), string::utf8(b"icon/hx334")];
        let xm_carrier = scenario.take_from_sender<XcallManagerWitnessCarrier>();
        xcall_manager::configure(&managerAdminCap, &xcall_state, xm_carrier, string::utf8(ICON_BnUSD),  sources, destinations, 1, scenario.ctx());

        scenario.next_tx(admin);
        let xcallManagerConfig: xcall_manager::Config  = scenario.take_shared<xcall_manager::Config>();
        let treasuryCap = scenario.take_from_sender<TreasuryCap<BALANCED_DOLLAR>>();
        configure(&adminCap, treasuryCap, &xcallManagerConfig, &xcall_state, carrier, string::utf8(b"icon/hx534"),  1,  scenario.ctx());
        test_scenario::return_shared<XCallState>(xcall_state);
        test_scenario::return_shared<xcall_manager::Config>(xcallManagerConfig);
        scenario.return_to_sender(adminCap);
        scenario.return_to_sender(managerAdminCap);
        scenario.next_tx(admin);
        scenario
    }

    #[test_only]
    fun setup_connection(mut scenario: Scenario, admin:address): Scenario {
        let mut storage = scenario.take_shared<XCallState>();
        let adminCap = scenario.take_from_sender<xcall_state::AdminCap>();
        xcall::register_connection_admin(&mut storage, &adminCap, string::utf8(b"centralized-1"), admin, scenario.ctx());
        test_scenario::return_shared(storage);
        test_scenario::return_to_sender(&scenario, adminCap);
        scenario.next_tx(admin);
        scenario
    }

    #[test]
    fun test_config(){
        // Assert
        let scenario = setup_test(ADMIN);
        let config = scenario.take_shared<Config>();
        test_scenario::return_shared(config);
        scenario.end();
    }

    #[test]
    fun test_cross_transfer() {
        // Arrange
        let mut scenario = setup_test(ADMIN);

        scenario.next_tx(ADMIN);
        scenario = setup_connection(scenario, ADMIN);
       
        // Assert
        let mut config = scenario.take_shared<Config>();
        let xcallManagerConfig: xcall_manager::Config = scenario.take_shared<xcall_manager::Config>();

        let fee_amount = math::pow(10, 9 + 4);
        let bnusd_amount = math::pow(10, 18);
        let fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());
        let mut treasuryCap = get_treasury_cap_for_testing(&mut config);
        let deposited = coin::mint(treasuryCap, bnusd_amount, scenario.ctx());

        let mut xcall_state= scenario.take_shared<XCallState>();
    
        cross_transfer(&mut xcall_state, &mut config, &xcallManagerConfig, fee, deposited, TO.to_string(), option::none(), scenario.ctx());
        test_scenario::return_shared(xcallManagerConfig);
        test_scenario::return_shared( config);
        test_scenario::return_shared(xcall_state);
        scenario.end();
    }

    #[test]
    fun cross_transfer_execute_call() {
        // Arrange
        let mut scenario = setup_test(ADMIN);
        scenario.next_tx(ADMIN);

        let bnusd_amount = math::pow(10, 18) as u128;
        let message = wrap_cross_transfer(string::utf8(FROM_ADDRESS),  string::utf8(TO_ADDRESS), bnusd_amount, b"");
        let data = encode(&message, b"xCrossTransfer");
        
        scenario = setup_connection( scenario, ADMIN);
        scenario.next_tx(ADMIN);
        let mut xcall_state = scenario.take_shared<XCallState>();
        let conn_cap = test_scenario::take_from_sender<ConnCap>(&scenario);

        let mut config = scenario.take_shared<Config>();

        let sources = vector[string::utf8(b"centralized-1")];
        let xcallManagerConfig: xcall_manager::Config  = scenario.take_shared<xcall_manager::Config>();
        let sui_dapp = id_to_hex_string(&xcall_state::get_id_cap_id(balanced_dollar_crosschain::get_idcap(&config)));
        let icon_dapp = network_address::create(string::utf8(b"icon"), string::utf8(b"hx534"));
        let from_nid = string::utf8(b"icon");
        let request = message_request::create(icon_dapp, sui_dapp, 1, 1, data, sources);
        let message = cs_message::encode(&cs_message::new(cs_message::request_code(), message_request::encode(&request)));
        xcall::handle_message(&mut xcall_state, &conn_cap, from_nid, message, scenario.ctx());

        scenario.next_tx(ADMIN);
        
        let fee_amount = math::pow(10, 9 + 4);
        let fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());
        balanced_dollar_crosschain::execute_call(&mut config, &xcallManagerConfig, &mut xcall_state, fee, 1, data, scenario.ctx());

        test_scenario::return_shared(config);
        test_scenario::return_shared(xcallManagerConfig);
        test_scenario::return_shared(xcall_state);
        scenario.return_to_sender(conn_cap);
        
        scenario.end();
    }

    #[test]
    fun cross_transfer_rollback_execute_call() {
        // Arrange
        let mut scenario = setup_test(ADMIN);
        scenario.next_tx(ADMIN);

        let bnusd_amount = math::pow(10, 18);
        scenario = setup_connection( scenario, ADMIN);
        let mut xcall_state = scenario.take_shared<XCallState>();
        let conn_cap = test_scenario::take_from_sender<ConnCap>(&scenario);
        let mut config = scenario.take_shared<Config>();

        let xcallManagerConfig: xcall_manager::Config  = scenario.take_shared<xcall_manager::Config>();
        let from_nid = string::utf8(b"icon");
        let response = message_result::create(1, message_result::failure(),b"");
        let message = cs_message::encode(&cs_message::new(cs_message::result_code(), message_result::encode(&response)));
        scenario.next_tx(ADMIN);
        
        let fee_amount = math::pow(10, 9 + 4);
        let fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());
        let mut treasuryCap = get_treasury_cap_for_testing(&mut config);
        let deposited = coin::mint(treasuryCap, bnusd_amount, scenario.ctx());
        cross_transfer(&mut xcall_state, &mut config, &xcallManagerConfig, fee, deposited, TO.to_string(), option::none(), scenario.ctx());
        xcall::handle_message(&mut xcall_state, &conn_cap, from_nid, message, scenario.ctx());

       
        balanced_dollar_crosschain::execute_rollback(&mut config,  &mut xcall_state, 1, scenario.ctx());

        test_scenario::return_shared(config);
        test_scenario::return_shared(xcallManagerConfig);
        test_scenario::return_shared(xcall_state);
        scenario.return_to_sender(conn_cap);
        
        scenario.end();
    }

    #[test_only]
    fun id_to_hex_string(id:&ID): String {
        let bytes = object::id_to_bytes(id);
        let hex_bytes = hex::encode(bytes);
        let mut prefix = string::utf8(b"0x");
        prefix.append(string::utf8(hex_bytes));
        prefix
    }

}