module balanced::xcall_manager{
    use std::string::{Self, String};
    use sui::coin::{Coin};
    use sui::sui::{SUI};
    use sui::bag::{Self, Bag};

    use xcall::{main as xcall};
    use xcall::xcall_state::{Self, IDCap, Storage as XCallState};
    use xcall::network_address::{Self};
    use xcall::execute_ticket::{Self};

    use balanced::configure_protocol::{Self, ConfigureProtocol};

    const NoProposalForRemovalExists: u64 = 0;
    const ProtocolMismatch: u64 = 1;
    const EIconGovernanceRequired: u64 = 2;
    const ENotUpgrade: u64 = 3;
    const EWrongVersion: u64 = 4;
    const EAlreadyWhiteListed: u64 = 5;
    const ENotWhitelisted: u64 = 6;

    const CURRENT_VERSION: u64 = 1;

    const CONFIGURE_PROTOCOLS_NAME: vector<u8> = b"ConfigureProtocols";

    public struct REGISTER_WITNESS has drop, store {}

    public struct WitnessCarrier has key { id: UID, witness: REGISTER_WITNESS }

    public struct Config has key, store {
        id: UID, 
        icon_governance: String,
        sources: vector<String>,
        destinations: vector<String>,
        proposed_protocol_to_remove: String,
        version: u64,
        id_cap: IDCap,
        xcall_id: ID,
        whitelist_actions: Bag
    }

    public struct AdminCap has key {
        id: UID, 
    }

    fun init(ctx: &mut TxContext){
      
        transfer::transfer(AdminCap {
            id: object::new(ctx)
        }, ctx.sender());

        transfer::transfer(
            WitnessCarrier { id: object::new(ctx), witness:REGISTER_WITNESS{} },
            ctx.sender()
        );
    }

    entry fun whitelist_action(_: &AdminCap, config: &mut Config, action: vector<u8>) {
        enforce_version(config);
        if(config.whitelist_actions.contains(action)){
            abort EAlreadyWhiteListed
        };
        config.whitelist_actions.add(action, true);
    }

    entry fun remove_action(_: &AdminCap, config: &mut Config, action: vector<u8>) {
        enforce_version(config);
        if(!config.whitelist_actions.contains(action)){
            abort ENotWhitelisted
        };
        bag::remove<vector<u8>, bool>(&mut config.whitelist_actions, action);
    }

    entry fun configure(_: &AdminCap, storage: &XCallState, witness_carrier: WitnessCarrier, icon_governance: String, sources: vector<String>, destinations: vector<String>, version: u64, ctx: &mut TxContext ){
        let w = get_witness(witness_carrier);
        let id_cap =   xcall::register_dapp(storage, w, ctx);
        let xcall_id = xcall_state::get_id_cap_xcall(&id_cap);

        transfer::share_object(Config {
            id: object::new(ctx),
            icon_governance: icon_governance,
            sources: sources,
            destinations: destinations,
            proposed_protocol_to_remove: string::utf8(b""),
            version: version,
            id_cap: id_cap,
            xcall_id: xcall_id,
            whitelist_actions: bag::new(ctx)
        });

    }

    public fun get_id(config: &Config): ID{
        config.id.to_inner()
    }

    public fun get_xcall_id(config: &Config): ID{
        config.xcall_id
    }

    fun get_witness(carrier: WitnessCarrier): REGISTER_WITNESS {
        let WitnessCarrier { id, witness } = carrier;
        id.delete();
        witness
    }

    public fun get_idcap(config: &Config): &IDCap {
        enforce_version(config);
        &config.id_cap
    }

    public fun get_protocals(config: &Config):(vector<String>, vector<String>){
        enforce_version(config);
        (config.sources, config.destinations)
    }

    entry fun propose_removal(_: &AdminCap, config: &mut Config, protocol: String) {
        enforce_version(config);
        config.proposed_protocol_to_remove = protocol;
    }

    entry fun get_execute_call_params(config: &Config): (ID){
        (get_xcall_id(config))
    }

    entry fun execute_call(config: &mut Config, xcall:&mut XCallState, fee: Coin<SUI>, request_id:u128, data:vector<u8>, ctx:&mut TxContext){
        enforce_version(config);
        let ticket = xcall::execute_call(xcall, &config.id_cap, request_id, data, ctx);
        let msg = execute_ticket::message(&ticket);
        let from = execute_ticket::from(&ticket);
        let protocols = execute_ticket::protocols(&ticket);

        let method: vector<u8> = configure_protocol::get_method(&msg);
        if (!verify_protocols_unordered(&config.sources, &protocols)) {
            assert!(
                method == CONFIGURE_PROTOCOLS_NAME,
                ProtocolMismatch
            );
            verify_protocol_recovery(&protocols, config);
        };

        assert!(config.whitelist_actions.contains(data), ENotWhitelisted);
        bag::remove<vector<u8>, bool>(&mut config.whitelist_actions, data);

        if (method == CONFIGURE_PROTOCOLS_NAME) {
            assert!(from == network_address::from_string(config.icon_governance), EIconGovernanceRequired);
            let message: ConfigureProtocol = configure_protocol::decode(&msg);
            config.sources = configure_protocol::sources(&message);
            config.destinations = configure_protocol::destinations(&message);
            xcall::execute_call_result(xcall,ticket,true,fee,ctx)
        } else {
            xcall::execute_call_result(xcall,ticket,false,fee,ctx)
        }
    }

    public fun verify_protocols(
       config: &Config, protocols: &vector<String>
    ): bool {
        enforce_version(config);
        verify_protocols_unordered(&config.sources, protocols)
    }

    fun verify_protocol_recovery(protocols: &vector<String>, config: &Config) {
        assert!(
            verify_protocols_unordered(&get_modified_protocols(config), protocols),
            ProtocolMismatch
        );
    }

    fun verify_protocols_unordered(
        array1: &vector<String>,
        array2: &vector<String>
    ):bool {
        let len1 = vector::length(array1);
        if(len1!=vector::length(array2)){
            false
        }else{
            let mut matched = true;
            let mut i = 0;
            while(i < len1){
                let protocol = vector::borrow(array2, i);
                if(!vector::contains(array1, protocol)){
                    matched = false;
                    break
                };
                i = i+1;
            };
            matched
        }
    }

    public fun get_modified_protocols(config: &Config): vector<String> {
        enforce_version(config);
        assert!(config.proposed_protocol_to_remove != string::utf8(b""), NoProposalForRemovalExists);

        let mut modifiedProtocols = vector::empty<String>();
        let sourceLen = vector::length(&config.sources);
        let mut i = 0;
        while(i < sourceLen) {
            let protocol = *vector::borrow(&config.sources, i);
            if(config.proposed_protocol_to_remove != protocol){
                vector::push_back(&mut modifiedProtocols, protocol);
            };
            i = i+1;
        };
        modifiedProtocols
    }

    entry fun set_icon_governance(_: &AdminCap, config: &mut Config, icon_governance: String ){
        enforce_version(config);
        config.icon_governance = icon_governance
    }

    entry fun set_sources(_: &AdminCap, config: &mut Config, sources: vector<String> ){
        enforce_version(config);
        config.sources = sources
    }

    entry fun set_destinations(_: &AdminCap, config: &mut Config, destinations:  vector<String> ){
        enforce_version(config);
        config.destinations = destinations
    }

    fun set_version(config: &mut Config, version: u64 ){
        config.version = version
    }

    public fun get_version(config: &mut Config): u64{
        config.version
    }

    fun enforce_version(self: &Config){
        assert!(self.version==CURRENT_VERSION, EWrongVersion);
    }

    entry fun migrate(_: &AdminCap, self: &mut Config) {
        assert!(get_version(self) < CURRENT_VERSION, ENotUpgrade);
        set_version(self, CURRENT_VERSION);
    }

    #[test_only]
    public fun init_test(ctx: &mut TxContext) {
        init(ctx)
    }

}