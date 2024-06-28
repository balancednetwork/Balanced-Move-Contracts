// Copyright (c) Sui Foundation, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module balanced::asset_manager_test {
    use sui::test_scenario::{Self,Scenario};
    use std::string::{Self, String};
    use std::type_name::{Self};
    use sui::coin::{Self};
    use sui::sui::SUI;
    use sui::math;
    use sui::hex;
    use sui::clock::{Self};

    use xcall::xcall_state::{Self, Storage as XCallState, ConnCap};
    use xcall::main::{Self as xcall, init_xcall_state};
    use xcall::cs_message::{Self};
    use xcall::message_request::{Self};
    use xcall::network_address::{Self};
    use xcall::message_result::{Self};

    use balanced::asset_manager::{Self, Config, AdminCap, configure, deposit, register_token, WitnessCarrier, configure_rate_limit };
    use balanced::balanced_dollar::{BALANCED_DOLLAR};
    use balanced::xcall_manager::{Self, WitnessCarrier as XcallManagerWitnessCarrier};

    use balanced::withdraw_to::{wrap_withdraw_to, encode};
    use balanced::deposit_revert::{Self, wrap_deposit_revert};

    const ICON_ASSET_MANAGER: vector<u8> = b"icon/hx734";
    const ADMIN: address = @0xBABE;
    const TO_ADDRESS: vector<u8>  = b"0000000000000000000000000000000000000000000000000000000000001234";
    const ADDRESS_TO_ADDRESS: address = @0x0000000000000000000000000000000000000000000000000000000000001234;

    #[test_only]
    fun setup_test(admin:address):Scenario {
        let mut scenario = test_scenario::begin(admin);
        asset_manager::init_test(scenario.ctx());
        scenario.next_tx(admin);
        scenario = init_xcall_state(admin,scenario);
        scenario.next_tx(admin);
        xcall_manager::init_test(scenario.ctx());
        scenario.next_tx(admin);

        let adminCap = scenario.take_from_sender<AdminCap>();
        let managerAdminCap = scenario.take_from_sender<xcall_manager::AdminCap>();
        let carrier = scenario.take_from_sender<WitnessCarrier>();
        let xcall_state= scenario.take_shared<XCallState>();

        let sources = vector[string::utf8(b"centralized-1")];
        let destinations = vector[string::utf8(b"icon/hx234"), string::utf8(b"icon/hx334")];
        let xm_carrier = scenario.take_from_sender<XcallManagerWitnessCarrier>();
        xcall_manager::configure(&managerAdminCap, &xcall_state, xm_carrier, string::utf8(ICON_ASSET_MANAGER),  sources, destinations, 1, scenario.ctx());

        scenario.next_tx(admin);
        let xcallManagerConfig: xcall_manager::Config  = scenario.take_shared<xcall_manager::Config>();
        configure(&adminCap, &xcallManagerConfig, &xcall_state, carrier, string::utf8(ICON_ASSET_MANAGER), 1, scenario.ctx());
      
        test_scenario::return_shared<XCallState>(xcall_state);
        test_scenario::return_shared<xcall_manager::Config>(xcallManagerConfig);
        test_scenario::return_to_sender(&scenario, adminCap);
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

    #[test_only]
    fun register_token_test(): Scenario {
        let admin = ADMIN;
        let mut scenario = setup_test(ADMIN);
        let mut config = scenario.take_shared<Config>();
        let c = clock::create_for_testing(scenario.ctx());
        let adminCap = scenario.take_from_sender<AdminCap>();
        register_token<BALANCED_DOLLAR>(&adminCap, &mut config, &c, 3000, 300, scenario.ctx());
        clock::destroy_for_testing(c);
        test_scenario::return_shared(config);
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
    fun test_register_token() {
        // Arrange
        let mut scenario = setup_test(ADMIN);
        let mut config = scenario.take_shared<Config>();
        // Act
        let c = clock::create_for_testing(scenario.ctx());
        let adminCap = scenario.take_from_sender<AdminCap>();
        register_token<BALANCED_DOLLAR>(&adminCap, &mut config, &c, 300, 300, scenario.ctx());
        scenario.next_tx(ADMIN);
        test_scenario::return_to_sender(&scenario, adminCap);
        clock::destroy_for_testing(c);

        test_scenario::return_shared(config);

        scenario.end();
    }

    #[test]
    fun configure_rate_limit_test() {
        let admin = ADMIN;
        let mut scenario = setup_test(ADMIN);
        let mut config = scenario.take_shared<Config>();
        let adminCap = scenario.take_from_sender<AdminCap>();
        let c = clock::create_for_testing(scenario.ctx());
        register_token<BALANCED_DOLLAR>(&adminCap, &mut config, &c, 300, 300, scenario.ctx());
        scenario.next_tx(admin);
        
        configure_rate_limit<BALANCED_DOLLAR>(&adminCap, &mut config, &c, 9000, 1000);
        clock::destroy_for_testing(c);
        test_scenario::return_shared(config);
        scenario.return_to_sender(adminCap);
        scenario.end();
    }

    #[test]
    fun test_deposit() {
        // Arrange
        let mut scenario = setup_test(ADMIN);
        let mut config = scenario.take_shared<Config>();
        let c = clock::create_for_testing(scenario.ctx());
        let adminCap = scenario.take_from_sender<AdminCap>();
        register_token<BALANCED_DOLLAR>(&adminCap, &mut config, &c, 300, 300, scenario.ctx());

        scenario.next_tx(ADMIN);
        scenario = setup_connection(scenario, ADMIN);

        let xcallManagerConfig: xcall_manager::Config  = scenario.take_shared<xcall_manager::Config>();
        let fee_amount = math::pow(10, 9 + 4);
        let bnusd_amount = math::pow(10, 18);
        let fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());
        let deposited = coin::mint_for_testing<BALANCED_DOLLAR>(bnusd_amount, scenario.ctx());
        let mut xcall_state= scenario.take_shared<XCallState>();
        deposit(&mut xcall_state, &mut config, &xcallManagerConfig, fee, deposited, option::none(), option::none(), scenario.ctx());
        
        test_scenario::return_shared(config);
        test_scenario::return_shared(xcallManagerConfig);
        test_scenario::return_shared(xcall_state);
        test_scenario::return_to_sender(&scenario, adminCap);
        clock::destroy_for_testing(c);
        
        scenario.end();
     }

     #[test]
    fun test_deposit_for_return_remaining_amount() {
        // Arrange
        let mut scenario = setup_test(ADMIN);
        let mut config = scenario.take_shared<Config>();
        let c = clock::create_for_testing(scenario.ctx());
        let adminCap = scenario.take_from_sender<AdminCap>();
        register_token<BALANCED_DOLLAR>(&adminCap, &mut config, &c, 300, 300, scenario.ctx());

        scenario.next_tx(ADMIN);
        scenario = setup_connection(scenario, ADMIN);

        let xcallManagerConfig: xcall_manager::Config  = scenario.take_shared<xcall_manager::Config>();
        let fee_amount = math::pow(10, 9 + 4);
        let bnusd_amount = math::pow(10, 18);
        let fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());
        let deposited = coin::mint_for_testing<BALANCED_DOLLAR>(bnusd_amount*2, scenario.ctx());
        let mut xcall_state= scenario.take_shared<XCallState>();
        deposit(&mut xcall_state, &mut config, &xcallManagerConfig, fee, deposited, option::none(), option::none(), scenario.ctx());
        
        test_scenario::return_shared(config);
        test_scenario::return_shared(xcallManagerConfig);
        test_scenario::return_shared(xcall_state);
        test_scenario::return_to_sender(&scenario, adminCap);
        clock::destroy_for_testing(c);
        
        scenario.end();
     }


    #[test]
    fun withdraw_to_execute_call() {
        // Arrange
        let mut scenario = register_token_test();
        let mut config = scenario.take_shared<Config>();
        let c = clock::create_for_testing(scenario.ctx());
        scenario.next_tx(ADMIN);

        let bnusd_amount = math::pow(10, 9);
        let token_type = string::from_ascii(*type_name::borrow_string(&type_name::get<BALANCED_DOLLAR>()));
        let message = wrap_withdraw_to(token_type, string::utf8(TO_ADDRESS), bnusd_amount);
        let data = encode(&message, b"WithdrawTo");
        
        scenario = setup_connection( scenario, ADMIN);
        let mut xcall_state = scenario.take_shared<XCallState>();
        scenario.next_tx(ADMIN);
        let conn_cap = test_scenario::take_from_sender<ConnCap>(&scenario);

        let xcallManagerConfig: xcall_manager::Config  = scenario.take_shared<xcall_manager::Config>();
        let sources = vector[string::utf8(b"centralized-1")];
        let sui_dapp = id_to_hex_string(&xcall_state::get_id_cap_id(asset_manager::get_idcap(&config)));
        let icon_dapp = network_address::create(string::utf8(b"icon"), string::utf8(b"hx734"));
        let from_nid = string::utf8(b"icon");
        let request = message_request::create(icon_dapp, sui_dapp, 1, 1, data, sources);
        let message = cs_message::encode(&cs_message::new(cs_message::request_code(), message_request::encode(&request)));
        xcall::handle_message(&mut xcall_state, &conn_cap, from_nid, message, scenario.ctx());

        scenario.next_tx(ADMIN);
        
        
        let fee_amount = math::pow(10, 9 + 4);
        let fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());
        let deposit_fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());
        let deposited = coin::mint_for_testing<BALANCED_DOLLAR>(bnusd_amount*2, scenario.ctx());
        deposit(&mut xcall_state, &mut config, &xcallManagerConfig, deposit_fee, deposited, option::none(), option::none(), scenario.ctx());
        asset_manager::execute_call<BALANCED_DOLLAR>( &mut config, &xcallManagerConfig, &mut xcall_state, fee, &c, 1, data, scenario.ctx());

        test_scenario::return_shared(config);
        test_scenario::return_shared(xcallManagerConfig);
        test_scenario::return_shared(xcall_state);
        scenario.return_to_sender(conn_cap);
        clock::destroy_for_testing(c);
        
        scenario.end();
    }

    #[test]
    fun rollback_execute_call() {
        // Arrange
        let mut scenario = register_token_test();
        let mut config = scenario.take_shared<Config>();
         let c = clock::create_for_testing(scenario.ctx());
        scenario.next_tx(ADMIN);

        let bnusd_amount = math::pow(10, 9);
        
        scenario = setup_connection( scenario, ADMIN);
        let mut xcall_state = scenario.take_shared<XCallState>();
        let conn_cap = test_scenario::take_from_sender<ConnCap>(&scenario);
        scenario.next_tx(ADMIN);
        let xcallManagerConfig: xcall_manager::Config  = scenario.take_shared<xcall_manager::Config>();
        let from_nid = string::utf8(b"icon");
       
        let response = message_result::create(1, message_result::failure(),b"");
        let message = cs_message::encode(&cs_message::new(cs_message::result_code(), message_result::encode(&response)));
        scenario.next_tx(ADMIN);
        
        let fee_amount = math::pow(10, 9 + 4);
        let deposit_fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());
        let deposited = coin::mint_for_testing<BALANCED_DOLLAR>(bnusd_amount*2, scenario.ctx());
        deposit( &mut xcall_state, &mut config, &xcallManagerConfig, deposit_fee, deposited, option::none(), option::none(), scenario.ctx());

        let deposit_fee1 = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());
        let deposited1 = coin::mint_for_testing<BALANCED_DOLLAR>(bnusd_amount*2, scenario.ctx());
        deposit( &mut xcall_state, &mut config, &xcallManagerConfig, deposit_fee1, deposited1, option::none(), option::none(), scenario.ctx());
        xcall::handle_message(&mut xcall_state, &conn_cap, from_nid, message, scenario.ctx());
        asset_manager::execute_rollback<BALANCED_DOLLAR>(&mut config, &mut xcall_state, 1, &c, scenario.ctx());

        test_scenario::return_shared(config);
        test_scenario::return_shared(xcallManagerConfig);
        test_scenario::return_shared(xcall_state);
        scenario.return_to_sender(conn_cap);
        clock::destroy_for_testing(c);
        
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
