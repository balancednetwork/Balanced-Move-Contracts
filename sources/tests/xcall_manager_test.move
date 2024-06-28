// Copyright (c) Sui Foundation, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module balanced::xcall_manager_test {
    use sui::test_scenario::{Self, next_tx, ctx, Scenario};
    use std::string::{Self, String};

    use sui::coin::{Self};
    use sui::sui::SUI;
    use sui::hex;
    use sui::math;

    const ADMIN: address = @0xBABE;
    use xcall::xcall_state::{Self, Storage as XCallState, ConnCap};
    use xcall::main::{Self as xcall, init_xcall_state};
    use xcall::cs_message::{Self};
    use xcall::message_request::{Self};
    use xcall::network_address::{Self};

    use balanced::configure_protocol::{wrap_protocols, encode};

    use balanced::xcall_manager::{Self, AdminCap, Config,  WitnessCarrier,  verify_protocols    };

    #[test_only]
    fun setup_test(admin:address):Scenario {
        let mut scenario = test_scenario::begin(admin);
        scenario = init_xcall_state(admin,scenario);
        scenario.next_tx(admin);
        xcall_manager::init_test(scenario.ctx());
        scenario.next_tx(admin);
        let adminCap = scenario.take_from_sender<AdminCap>();

        let sources = vector[string::utf8(b"centralized-1")];
        let destinations = vector[string::utf8(b"icon/hx234"), string::utf8(b"icon/hx334")];
        let carrier = scenario.take_from_sender<WitnessCarrier>();
        let xcall_state= scenario.take_shared<XCallState>();
        xcall_manager::configure(&adminCap, &xcall_state, carrier, string::utf8(b"icon/hx337"),  sources, destinations, 1, scenario.ctx());
        test_scenario::return_shared<XCallState>(xcall_state);
        scenario.return_to_sender(adminCap);
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
    fun test_verify_protocols() {
       let scenario = setup_test(ADMIN);

        // Act & Assert
        let config = scenario.take_shared<Config>();
        let sources = vector[string::utf8(b"centralized-1")];
        let (verified) = verify_protocols(&config, &sources);
        assert!(verified, 1);
        test_scenario::return_shared(config);
        scenario.end();
    }

    #[test]
    fun test_verify_protocols_duplicate_sources() {
        let admin = ADMIN;
        let mut scenario = test_scenario::begin(admin);
        scenario = init_xcall_state(admin,scenario);
        scenario.next_tx(admin);
        xcall_manager::init_test(scenario.ctx());
        scenario.next_tx(admin);
        let adminCap = scenario.take_from_sender<AdminCap>();

        let sources = vector[b"centralized-1".to_string(), b"centralized-2".to_string()];
        let destinations = vector[string::utf8(b"icon/hx234"), string::utf8(b"icon/hx334")];
        let carrier = scenario.take_from_sender<WitnessCarrier>();
        let xcall_state= scenario.take_shared<XCallState>();
        xcall_manager::configure(&adminCap, &xcall_state, carrier, string::utf8(b"icon/hx337"),  sources, destinations, 1, scenario.ctx());
        test_scenario::return_shared<XCallState>(xcall_state);
        scenario.return_to_sender(adminCap);
        scenario.next_tx(admin);

        // Act & Assert
        let config = scenario.take_shared<Config>();
        let sources = vector[b"centralized-1".to_string(), b"centralized-1".to_string()];
        let (verified) = verify_protocols(&config, &sources);
        assert!(verified, 0);

        let sources = vector[b"centralized-1".to_string(), b"centralized-2".to_string()];
        let (verified) = verify_protocols(&config, &sources);
        assert!(verified, 1);
        test_scenario::return_shared(config);
        scenario.end();
    }

    #[test]
    fun configure_execute_call() {
        // Arrange
        let mut scenario = setup_test(ADMIN);
        scenario.next_tx(ADMIN);

        let sources = vector[string::utf8(b"centralized-1")];
        let destinations = vector[string::utf8(b"icon_centralized")];
        let message = wrap_protocols(sources, destinations);
        let data = encode(&message, b"ConfigureProtocols");
        
        scenario = setup_connection( scenario, ADMIN);
        let mut xcall_state = scenario.take_shared<XCallState>();
        let conn_cap = test_scenario::take_from_sender<ConnCap>(&scenario);

        let sources = vector[string::utf8(b"centralized-1")];
        let mut config = scenario.take_shared<Config>();
        let adminCap = scenario.take_from_sender<AdminCap>();
        xcall_manager::whitelist_action(&adminCap, &mut config, data);
        let sui_dapp = id_to_hex_string(&xcall_state::get_id_cap_id(xcall_manager::get_idcap(&config)));
        let icon_dapp = network_address::create(string::utf8(b"icon"), string::utf8(b"hx337"));
        let from_nid = string::utf8(b"icon");
        let request = message_request::create(icon_dapp, sui_dapp, 1, 1, data, sources);
        let message = cs_message::encode(&cs_message::new(cs_message::request_code(), message_request::encode(&request)));
        xcall::handle_message(&mut xcall_state, &conn_cap, from_nid, message, scenario.ctx());

        scenario.next_tx(ADMIN);
        let fee_amount = math::pow(10, 9 + 4);
        let fee = coin::mint_for_testing<SUI>(fee_amount, scenario.ctx());

        xcall_manager::execute_call(&mut config, &mut xcall_state, fee, 1, data, scenario.ctx());

        //xcall_manager::remove_action(&adminCap, &mut config, data);

        test_scenario::return_shared(config);
        test_scenario::return_shared(xcall_state);
        scenario.return_to_sender(adminCap);
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