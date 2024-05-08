// Copyright (c) Sui Foundation, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module balanced::balanced_dollar_test {
    use sui::test_scenario::{Self, next_tx, ctx, Scenario};
    use std::string::{Self, String};
    use std::debug::{Self};

    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::address::{Self};
    use sui::sui::SUI;
    use sui::math;
    use sui::hex;

    use xcall::xcall_state::{Self, Storage as XCallState, AdminCap as XcallAdminCap};
    use xcall::main::{Self as xcall, init_xcall_state};
    use xcall::cs_message::{Self};
    use xcall::message_request::{Self};
    use xcall::network_address::{Self};

    use balanced::xcall_manager::{Self, Config as XcallManagerConfig, WitnessCarrier, XcallCap };
    use balanced::balanced_dollar::{Self, BALANCED_DOLLAR, AdminCap, Config, configure, cross_transfer    };
    
    use balanced::cross_transfer::{XCrossTransfer, wrap_cross_transfer, encode};
    use balanced::cross_transfer_revert::{Self, XCrossTransferRevert, wrap_cross_transfer_revert};

    const ADMIN: address = @0xBABE;
    const TO: address = @0xBABE1;
    
    const ICON_BnUSD: vector<u8> = b"icon/hx734";
    const XCALL_NETWORK_ADDRESS: vector<u8> = b"netId";

    const TO_ADDRESS: vector<u8>  = b"sui/0000000000000000000000000000000000000000000000000000000000001234";
    const FROM_ADDRESS: vector<u8>  = b"sui/000000000000000000000000000000000000000000000000000000000000123d";
    const ADDRESS_TO_ADDRESS: address = @0x645d;

     #[test_only]
    fun setup_test(admin:address):Scenario {
        let mut scenario = test_scenario::begin(admin);
        balanced_dollar::init_test(scenario.ctx());
        scenario.next_tx(admin);
        scenario = init_xcall_state(admin,scenario);
        scenario.next_tx(admin);
        xcall_manager::init_test(scenario.ctx());
        scenario.next_tx(admin);
        let adminCap = scenario.take_from_sender<AdminCap>();
        let managerAdminCap = scenario.take_from_sender<xcall_manager::AdminCap>();
        configure(&adminCap, string::utf8(b"sui1/xcall"), string::utf8(b"sui1"), string::utf8(b"icon/hx534"),  1,  scenario.ctx());

        let sources = vector[string::utf8(b"centralized")];
        let destinations = vector[string::utf8(b"icon/hx234"), string::utf8(b"icon/hx334")];
        xcall_manager::configure(&managerAdminCap, string::utf8(b"icon/hx734"),  sources, destinations,  1, scenario.ctx());
        scenario.return_to_sender(adminCap);
        scenario.return_to_sender(managerAdminCap);
        scenario.next_tx(admin);
        scenario
    }

    #[test_only]
    fun setup_register_xcall(admin:address,mut scenario:Scenario):Scenario{
        let carrier = scenario.take_from_sender<WitnessCarrier>();
        let xcall_state= scenario.take_shared<XCallState>();
        let adminCap = scenario.take_from_sender<AdminCap>();
        xcall_manager::register_xcall(&xcall_state,carrier,scenario.ctx());
        test_scenario::return_shared<XCallState>(xcall_state);
        scenario.return_to_sender(adminCap);
        scenario.next_tx(admin);
        scenario

    }

    #[test_only]
    fun setup_connection(mut scenario: Scenario, from_nid: String, admin:address): Scenario {
        let mut storage = scenario.take_shared<XCallState>();
        let adminCap = scenario.take_from_sender<xcall_state::AdminCap>();
        xcall::register_connection(&mut storage, &adminCap,from_nid, string::utf8(b"centralized"), scenario.ctx());
        test_scenario::return_shared(storage);
        test_scenario::return_to_sender(&scenario, adminCap);
        scenario.next_tx(admin);
        scenario
    }

    #[test]
    fun test_config(){
        // Assert
        let mut scenario = setup_test(ADMIN);
        scenario = setup_register_xcall(ADMIN, scenario);
        let config = scenario.take_shared<Config>();
        debug::print(&config);
        test_scenario::return_shared(config);
        scenario.end();
    }

    #[test]
    fun test_cross_transfer() {
        // Arrange
        let mut scenario = setup_test(ADMIN);
        scenario = setup_register_xcall(ADMIN, scenario);

        scenario.next_tx(ADMIN);
        scenario = setup_connection(scenario, string::utf8(b"sui"), ADMIN);
       
        // Assert
        let config = scenario.take_shared<Config>();
        let xcallManagerConfig: xcall_manager::Config = scenario.take_shared<xcall_manager::Config>();
        let mut treasury_cap = scenario.take_shared<TreasuryCap<BALANCED_DOLLAR>>();

        let fee_amount = math::pow(10, 9 + 4);
        let bnusd_amount = math::pow(10, 18);
        let fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());
        let deposited = coin::mint(&mut treasury_cap, bnusd_amount, scenario.ctx());

        let mut xcall_state= scenario.take_shared<XCallState>();
        let xcallCap= scenario.take_shared<XcallCap>();
    
        cross_transfer(&mut xcall_state, &config, &xcallManagerConfig, &xcallCap, fee, deposited, &mut treasury_cap, TO,  bnusd_amount, option::none(), scenario.ctx());
        test_scenario::return_shared(xcallManagerConfig);
        test_scenario::return_shared( config);
        test_scenario::return_shared(xcall_state);
        test_scenario::return_shared(xcallCap);
        test_scenario::return_shared(treasury_cap);
        scenario.end();
    }

    #[test]
    fun cross_transfer_execute_call() {
        // Arrange
        let mut scenario = setup_test(ADMIN);
        scenario = setup_register_xcall(ADMIN, scenario);
        scenario.next_tx(ADMIN);

        let xcallCap= scenario.take_shared<XcallCap>();
        let bnusd_amount = math::pow(10, 18);
        let message = wrap_cross_transfer(string::utf8(FROM_ADDRESS),  string::utf8(TO_ADDRESS), bnusd_amount, b"");
        let data = encode(&message, b"xCrossTransfer");
        
        scenario = setup_connection( scenario, string::utf8(b"icon"), ADMIN);
        let mut xcall_state = scenario.take_shared<XCallState>();
        let conn_cap = xcall_state::create_conn_cap_for_testing(&mut xcall_state);

        let sources = vector[string::utf8(b"centralized")];
        let sui_dapp = id_to_hex_string(&xcall_state::get_id_cap_id(xcall_manager::get_idcap(&xcallCap)));
        let icon_dapp = network_address::create(string::utf8(b"icon"), string::utf8(b"hx534"));
        let from_nid = string::utf8(b"icon");
        let request = message_request::create(icon_dapp, sui_dapp, 1, 1, data, sources);
        let message = cs_message::encode(&cs_message::new(cs_message::request_code(), message_request::encode(&request)));
        xcall::handle_message(&mut xcall_state, &conn_cap, from_nid, message, scenario.ctx());

        scenario.next_tx(ADMIN);
        
        let config = scenario.take_shared<Config>();
        let xcallManagerConfig: xcall_manager::Config  = scenario.take_shared<xcall_manager::Config>();
        let fee_amount = math::pow(10, 9 + 4);
        let fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());
        let mut treasury_cap = scenario.take_shared<TreasuryCap<BALANCED_DOLLAR>>();

        balanced_dollar::execute_call<BALANCED_DOLLAR>(&mut treasury_cap, &xcallCap, &config, &xcallManagerConfig, &mut xcall_state, fee, 1, data, scenario.ctx());

        test_scenario::return_shared(xcallCap);
        test_scenario::return_shared(config);
        test_scenario::return_shared(xcallManagerConfig);
        test_scenario::return_shared(xcall_state);
        test_scenario::return_shared(treasury_cap);
        
        scenario.end();
    }
    

    #[test]
    fun cross_transfer_rollback_execute_call() {
        // Arrange
        let mut scenario = setup_test(ADMIN);
        scenario = setup_register_xcall(ADMIN, scenario);
        scenario.next_tx(ADMIN);

        let xcallCap= scenario.take_shared<XcallCap>();
        let bnusd_amount = math::pow(10, 18);
        let message = wrap_cross_transfer_revert( ADDRESS_TO_ADDRESS, bnusd_amount);
        let data = cross_transfer_revert::encode(&message, b"xCrossTransferRevert");

        scenario = setup_connection( scenario, string::utf8(b"icon"), ADMIN);
        let mut xcall_state = scenario.take_shared<XCallState>();
        let conn_cap = xcall_state::create_conn_cap_for_testing(&mut xcall_state);

        let sources = vector[string::utf8(b"centralized")];
        let sui_dapp = id_to_hex_string(&xcall_state::get_id_cap_id(xcall_manager::get_idcap(&xcallCap)));
        let icon_dapp = network_address::create(string::utf8(b"icon"), string::utf8(b"hx534"));
        let from_nid = string::utf8(b"icon");
        let request = message_request::create(icon_dapp, sui_dapp, 2, 1, data, sources);
        let message = cs_message::encode(&cs_message::new(cs_message::request_code(), message_request::encode(&request)));
        xcall::handle_message(&mut xcall_state, &conn_cap, from_nid, message, scenario.ctx());

        scenario.next_tx(ADMIN);
        
        let config = scenario.take_shared<Config>();
        let xcallManagerConfig: xcall_manager::Config  = scenario.take_shared<xcall_manager::Config>();
        let fee_amount = math::pow(10, 9 + 4);
        let fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());

        let mut treasury_cap = scenario.take_shared<TreasuryCap<BALANCED_DOLLAR>>();
        balanced_dollar::execute_call<BALANCED_DOLLAR>(&mut treasury_cap, &xcallCap, &config, &xcallManagerConfig, &mut xcall_state, fee, 1, data, scenario.ctx());

        test_scenario::return_shared(xcallCap);
        test_scenario::return_shared(config);
        test_scenario::return_shared(xcallManagerConfig);
        test_scenario::return_shared(xcall_state);
        test_scenario::return_shared(treasury_cap);
        
        scenario.end();
    }

    #[test_only]
    fun id_to_hex_string(id:&ID): String {
        let bytes = object::id_to_bytes(id);
        let hex_bytes = hex::encode(bytes);
        string::utf8(hex_bytes)
    }

}