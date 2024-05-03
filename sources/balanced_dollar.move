module balanced::balanced_dollar {
    use std::string::{String};

    use sui::url;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::sui::SUI;

    use xcall::{main as xcall};
    use xcall::xcall_state::{Storage as XCallState};
    use xcall::envelope::{Self};
    use xcall::network_address::{Self};
    use xcall::execute_ticket::{Self};

    use balanced::xcall_manager::{Self, Config as XcallManagerConfig, XcallCap};
    use balanced::cross_transfer::{Self, wrap_cross_transfer, XCrossTransfer};
    use balanced::cross_transfer_revert::{Self, wrap_cross_transfer_revert, XCrossTransferRevert};
    use balanced::balanced_utils::{address_to_hex_string, address_from_hex_string};

    const AmountLessThanMinimumAmount: u64  = 1;
    //const ProtocolMismatch: u64 = 2;
    const OnlyICONBnUSD: u64 = 3;
    const UnknownMessageType: u64 = 5;
    const ENotTransferredAmount: u64 = 6;

    const CROSS_TRANSFER: vector<u8> = b"xCrossTransfer";
    const CROSS_TRANSFER_REVERT: vector<u8> = b"xCrossTransferRevert";


    public struct BALANCED_DOLLAR has drop {}

    public struct AdminCap has key{
        id: UID 
    }

    public struct Config has key, store{
        id: UID, 
        xCallNetworkAddress: String,
        nid: String,
        iconBnUSD: String,
    }

    fun init(witness: BALANCED_DOLLAR, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency<BALANCED_DOLLAR>(
            witness, 
            18, 
            b"bnUSD", 
            b"Balanced Dollar", 
            b"A stable coin issued by Balanced", 
            option::some(url::new_unsafe_from_bytes(b"https://raw.githubusercontent.com/balancednetwork/assets/master/blockchains/icon/assets/cx88fd7df7ddff82f7cc735c871dc519838cb235bb/logo.png")),
            ctx
        );

        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
        
        transfer::public_share_object(metadata);

        transfer::transfer(AdminCap {
            id: object::new(ctx)
        }, tx_context::sender(ctx));
        
    }

    entry fun configure(_: &AdminCap, _xCallNetworkAddress: String, _nid: String, _iconBnUSD: String, ctx: &mut TxContext ){
        transfer::share_object(Config {
            id: object::new(ctx),
            xCallNetworkAddress: _xCallNetworkAddress,
            nid: _nid,
            iconBnUSD: _iconBnUSD
        });
    }

    entry fun crossTransfer(
        xcallState: &mut XCallState,
        config: &Config,
        xcallManagerConfig: &XcallManagerConfig,
        xcallCap: &XcallCap,
        fee: Coin<SUI>,
        token: Coin<BALANCED_DOLLAR>,
        treasury_cap: &mut TreasuryCap<BALANCED_DOLLAR>,
        to: address,
        amount: u64,
        data: Option<vector<u8>>,
        ctx: &mut TxContext
    ) {
        let messageData = option::get_with_default(&data, b"");
        assert!(amount > 0, AmountLessThanMinimumAmount);
        assert!(coin::value(&token) == amount, ENotTransferredAmount);
        coin::burn(treasury_cap, token);

        let sender = address_to_hex_string(&tx_context::sender(ctx));
        let fromAddress = network_address::to_string(&network_address::create(config.xCallNetworkAddress, sender));
        let string_to = address_to_hex_string(&to);
        let toAddress = network_address::to_string(&network_address::create(config.xCallNetworkAddress, string_to));

        let xcallMessageStruct = wrap_cross_transfer(
            fromAddress,
           toAddress,
             amount,
            messageData
        );

        let rollbackStruct = wrap_cross_transfer_revert(
            to,
            amount
        );

        let (sources, destinations) = xcall_manager::get_protocals(xcallManagerConfig);
        let idcap = xcall_manager::get_idcap(xcallCap);

        let xcallMessage = cross_transfer::encode(&xcallMessageStruct, CROSS_TRANSFER);
        let rollback = cross_transfer_revert::encode(&rollbackStruct, CROSS_TRANSFER_REVERT);
        
        let envelope = envelope::wrap_call_message_rollback(xcallMessage, rollback, sources, destinations);
        xcall::send_call(xcallState, fee, idcap, config.iconBnUSD, envelope::encode(&envelope), ctx);
    }

    entry public fun execute_call<BALANCED_DOLLAR>(cap: &mut TreasuryCap<BALANCED_DOLLAR>, xcallCap: &XcallCap, config: &Config, xcall:&mut XCallState, fee: Coin<SUI>, request_id:u128, data:vector<u8>, ctx:&mut TxContext){
        // let verified = xcall_manager::verify_protocols(xcallManagerConfig, protocols);
        // assert!(
        //     verified,
        //     ProtocolMismatch
        // );
        let idcap = xcall_manager::get_idcap(xcallCap);
        let ticket = xcall::execute_call(xcall, idcap, request_id, data, ctx);
        let msg = execute_ticket::message(&ticket);
        let from = execute_ticket::from(&ticket);

        let method: vector<u8> = cross_transfer::get_method(&msg);
        assert!(
            method == CROSS_TRANSFER || method == CROSS_TRANSFER_REVERT, 
            UnknownMessageType
        );

        if (method == CROSS_TRANSFER) {
            assert!(from == network_address::from_string(config.iconBnUSD), OnlyICONBnUSD);
            let message: XCrossTransfer = cross_transfer::decode(&msg);
            let string_to = network_address::addr(&network_address::from_string(cross_transfer::to(&message)));
            let to = address_from_hex_string(&string_to);
            let amount: u64 = cross_transfer::value(&message);

            coin::mint_and_transfer(cap,  amount, to, ctx)
        } else if (method == CROSS_TRANSFER_REVERT) {
            let message: XCrossTransferRevert = cross_transfer_revert::decode(&msg);
            let to = cross_transfer_revert::to(&message);
            let amount: u64 = cross_transfer_revert::value(&message);

            coin::mint_and_transfer(cap,  amount, to, ctx)
        };

        xcall::execute_call_result(xcall,ticket,true,fee,ctx);
    }

    #[test_only]
    /// Wrapper of module initializer for testing
    public fun test_init(ctx: &mut TxContext) {
        init(BALANCED_DOLLAR {}, ctx)
    }

}
