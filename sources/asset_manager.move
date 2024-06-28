module balanced::asset_manager{
    use std::string::{Self, String};
    use std::type_name::{Self};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::clock::{Self, Clock};
    use sui::bag::{Self, Bag};

    use xcall::{main as xcall};
    use xcall::xcall_state::{Self, Storage as XCallState, IDCap};
    use xcall::envelope::{Self};
    use xcall::network_address::{Self};
    use xcall::execute_ticket::{Self};
    use xcall::rollback_ticket::{Self};

    use balanced::xcall_manager::{Self, Config as XcallManagerConfig};
    use balanced::deposit::{Self};
    use balanced::deposit_revert::{Self, DepositRevert};
    use balanced::withdraw_to::{Self, WithdrawTo};
    use balanced::balanced_utils::{address_to_hex_string, address_from_hex_string};

    const DEPOSIT_NAME: vector<u8> = b"Deposit";
    const WITHDRAW_TO_NAME: vector<u8> = b"WithdrawTo";
    const DEPOSIT_REVERT_NAME: vector<u8> = b"DepositRevert";
    const WITHDRAW_NATIVE_TO_NAME: vector<u8> = b"WithdrawNativeTo";

    const POINTS: u64 = 10000;

    const EAmountLessThanMinimumAmount: u64 = 0;
    const ProtocolMismatch: u64 = 2;
    const UnknownMessageType: u64 = 3;
    const EExceedsWithdrawLimit: u64 = 4;
    const EIconAssetManagerRequired: u64 = 5;
    const ENotUpgrade: u64 = 6;
    const EAlreadyRegistered: u64 = 7;
    const EWrongVersion: u64 = 8;
    const EInvalidPercentage: u64 = 9;
    const CURRENT_VERSION: u64 = 1;

    public struct REGISTER_WITNESS has drop, store {}

    public struct WitnessCarrier has key { id: UID, witness: REGISTER_WITNESS }
    
    public struct AssetManager<phantom T> has key, store{
        id: UID,
        balance: Balance<T>,
        rate_limit: RateLimit<T>
    }

    public struct Config has key {
        id: UID, 
        icon_asset_manager: String,
        assets: Bag,
        version: u64,
        id_cap: IDCap,
        xcall_manager_id: ID, 
        xcall_id: ID
    }
    

    public struct RateLimit<phantom T> has copy, store {
        period: u64,
        percentage: u64,
        last_update: u64,
        current_limit: u64
    }

    public struct AdminCap has key {
        id: UID, 
    }

    fun init(ctx: &mut TxContext) {
      
        transfer::transfer(AdminCap {
            id: object::new(ctx)
        }, ctx.sender());

        transfer::transfer(
            WitnessCarrier { id: object::new(ctx), witness:REGISTER_WITNESS{} },
            ctx.sender()
        );

    }

    fun get_witness(carrier: WitnessCarrier): REGISTER_WITNESS {
        let WitnessCarrier { id, witness } = carrier;
        id.delete();
        witness
    }

    entry fun configure(_: &AdminCap, xcall_manager_config: &XcallManagerConfig, storage: &XCallState, witness_carrier: WitnessCarrier, icon_asset_manager: String, version: u64, ctx: &mut TxContext ) {
        let w = get_witness(witness_carrier);
        let id_cap =   xcall::register_dapp(storage, w, ctx);
        let xcall_manager_id = xcall_manager::get_id(xcall_manager_config);
        let xcall_id = xcall_state::get_id_cap_xcall(&id_cap);

        transfer::share_object(Config {
            id: object::new(ctx),
            icon_asset_manager: icon_asset_manager,
            assets: bag::new(ctx),
            version: version,
            id_cap: id_cap,
            xcall_manager_id: xcall_manager_id,
            xcall_id: xcall_id
        });
    }

    public fun get_idcap(config: &Config): &IDCap {
        enforce_version(config);
        &config.id_cap
    }

    public fun get_xcall_manager_id(config: &Config): ID{
        config.xcall_manager_id
    }

    public fun get_xcall_id(config: &Config): ID{
        config.xcall_id
    }

    entry fun register_token<T>(_: &AdminCap, config:&mut Config, c: &Clock,
        period: u64, percentage: u64,  ctx: &mut TxContext) {
        enforce_version(config);
        let token_type = string::from_ascii(*type_name::borrow_string(&type_name::get<T>()));
        if(config.assets.contains(token_type)){
            abort EAlreadyRegistered
        };
        
        let rate_limit = RateLimit<T> {
            period: period,
            percentage: percentage,
            last_update: clock::timestamp_ms(c),
            current_limit: 0
        };

       let mut asset_manager = AssetManager<T> {
            id: object::new(ctx),
            balance: balance::zero<T>(),
            rate_limit: rate_limit
        };

        let asset_manager_balance = &asset_manager.balance;
        let rate_limit = &mut asset_manager.rate_limit;
        assert!(POINTS >= percentage, EInvalidPercentage );
        rate_limit.current_limit = (balance::value(asset_manager_balance) * percentage) / POINTS;
        
        config.assets.add(token_type, asset_manager)
    }

    entry fun configure_rate_limit<T> (
        _: &AdminCap,
        config: &mut Config,
        c: &Clock,
        period: u64,
        percentage: u64
    ) {
        enforce_version(config);
        let asset_manager = get_asset_manager_mut<T>(config);
        let rate_limit = &mut asset_manager.rate_limit;
        rate_limit.period = period;
        rate_limit.percentage = percentage;
        rate_limit.last_update = clock::timestamp_ms(c);
        rate_limit.current_limit = (balance::value(&asset_manager.balance) * percentage) / POINTS;
    }

    entry fun reset_limit<T> (
        _: &AdminCap,
        config: &mut Config
    ) 
    {
        enforce_version(config);
        let asset_manager = get_asset_manager_mut<T>(config);
        let rate_limit = &mut asset_manager.rate_limit;

        rate_limit.current_limit = (balance::value(&asset_manager.balance) * rate_limit.percentage) / POINTS
    }

    public fun get_withdraw_limit<T>(config: &Config,
        rate_limit: &RateLimit<T>, c: &Clock): u64  {
        enforce_version(config);
        let asset_manager = get_asset_manager<T>(config);

        let tokenBalance = balance::value(&asset_manager.balance);
        calculate_limit(tokenBalance, rate_limit, c)
    }

    fun calculate_limit<T>(tokenBalance: u64, rate_limit: &RateLimit<T>, c: &Clock): u64 {
        let period = rate_limit.period;
        let percentage = rate_limit.percentage;
        if (period == 0) {
            return 0
        };
        
        let min_reserve = (tokenBalance  * percentage ) / POINTS;
        let max_withdraw = tokenBalance - min_reserve;
        let mut time_diff = (clock::timestamp_ms(c) - rate_limit.last_update)/1000;
        time_diff = if(time_diff > period){ period } else { time_diff };

        let allowed_withdrawal = (max_withdraw * time_diff) / period;
                
        let mut reserve = rate_limit.current_limit;

        if(rate_limit.current_limit > allowed_withdrawal){
            reserve = rate_limit.current_limit - allowed_withdrawal;
        };
        reserve = if(reserve > min_reserve){ reserve } else { min_reserve };
        reserve
    }

    fun verify_withdraw<T>(balance: &Balance<T>, rate_limit: &mut RateLimit<T>, c: &Clock, amount: u64) {

        let tokenBalance = balance::value(balance);
        let limit = calculate_limit(tokenBalance, rate_limit, c);
        assert!(tokenBalance - amount >= limit, EExceedsWithdrawLimit );

        rate_limit.current_limit = limit;
        rate_limit.last_update = clock::timestamp_ms(c);
    }

    entry fun deposit<T>(
        xcallState: &mut XCallState, 
        config: &mut Config, 
        xcall_manager_config: &XcallManagerConfig, 
        fee: Coin<SUI>,
        token: Coin<T>, 
        to: Option<String>, 
        data: Option<vector<u8>>, 
        ctx: &mut TxContext
    ) {
        enforce_version(config);
        let sender = ctx.sender();
        let from_address = address_to_hex_string(&sender);
        let mut to_address = b"".to_string();
        if(option::is_some(&to)){
            to_address = *option::borrow(&to);
        };
        let messageData = option::get_with_default(&data, b"");
        let self = get_asset_manager_mut<T>(config);
        let amount = coin::value(&token);
        assert!(amount>0, EAmountLessThanMinimumAmount);
        coin::put<T>(&mut self.balance, token);

        let token_address = string::from_ascii(*type_name::borrow_string(&type_name::get<T>()));
        let depositMessage = deposit::wrap_deposit(
            token_address,
            from_address,
            to_address,
            amount,
            messageData
        );
        let data = deposit::encode(&depositMessage, DEPOSIT_NAME);

        
        let rollbackMessage = deposit_revert::wrap_deposit_revert (
            token_address,
            sender,
            amount
        );
        let rollback = deposit_revert::encode(&rollbackMessage, DEPOSIT_REVERT_NAME);

       let(sources, destinations) = xcall_manager::get_protocals(xcall_manager_config); 
       let envelope = envelope::wrap_call_message_rollback(data, rollback, sources, destinations);
       xcall::send_call(xcallState, fee, get_idcap(config), config.icon_asset_manager, envelope::encode(&envelope), ctx);
    }

    public fun get_withdraw_token_type(msg:vector<u8>): String{
        deposit::get_token_type(&msg)
    }

    entry fun get_execute_call_params(config: &Config): (ID, ID){
        (get_xcall_manager_id(config), get_xcall_id(config))
    }

    entry fun execute_call<T>(config: &mut Config, xcall_manager_config: &XcallManagerConfig, xcall:&mut XCallState, fee:Coin<SUI>, c: &Clock, request_id:u128, data:vector<u8>, ctx:&mut TxContext){
        enforce_version(config);
        let ticket = xcall::execute_call(xcall, get_idcap(config), request_id, data, ctx);
        let msg = execute_ticket::message(&ticket);
        let from = execute_ticket::from(&ticket);
        let protocols = execute_ticket::protocols(&ticket);

        let verified = xcall_manager::verify_protocols(xcall_manager_config, &protocols);
        assert!(
            verified,
            ProtocolMismatch
        );

        let method: vector<u8> = deposit::get_method(&msg);
        assert!(
            method == WITHDRAW_TO_NAME || method == WITHDRAW_NATIVE_TO_NAME,
            UnknownMessageType
        );
        
        let token_type = string::from_ascii(*type_name::borrow_string(&type_name::get<T>()));
        
        let message_token_type = deposit::get_token_type(&msg);
        if(token_type == message_token_type){
            assert!(from == network_address::from_string(config.icon_asset_manager), EIconAssetManagerRequired);
            let message: WithdrawTo = withdraw_to::decode(&msg);
            let to_address = withdraw_to::to(&message);
            let asset_manager = get_asset_manager_mut<T>(config);
            let balance = &mut asset_manager.balance;
            let rate_limit = &mut asset_manager.rate_limit;
            withdraw(
                balance,
                rate_limit,
                c,
                address_from_hex_string(&to_address),
                withdraw_to::amount(&message),
                ctx
            );
        };

        xcall::execute_call_result(xcall,ticket,true,fee,ctx);
    }

    //Called by admin when execute call fails without a rollback
    entry fun execute_force_rollback(_: &AdminCap, config: &Config, xcall:&mut XCallState, fee:Coin<SUI>, request_id:u128, data:vector<u8>, ctx:&mut TxContext){
        enforce_version(config);
        let ticket = xcall::execute_call(xcall, get_idcap(config), request_id, data, ctx);
        xcall::execute_call_result(xcall,ticket,false,fee,ctx);
    }

    entry fun execute_rollback<T>(config: &mut Config, xcall:&mut XCallState, sn: u128, c: &Clock,  ctx:&mut TxContext){
        enforce_version(config);
        let ticket = xcall::execute_rollback(xcall, get_idcap(config), sn, ctx);
        let msg = rollback_ticket::rollback(&ticket);
        let method: vector<u8> = deposit::get_method(&msg);
        assert!(
            method == DEPOSIT_REVERT_NAME,
            UnknownMessageType
        );

        let token_type = string::from_ascii(*type_name::borrow_string(&type_name::get<T>()));
        
        let message_token_type = deposit::get_token_type(&msg);
        if(token_type == message_token_type){
            let asset_manager = get_asset_manager_mut<T>(config);
            let balance = &mut asset_manager.balance;
            let rate_limit = &mut asset_manager.rate_limit;
            let message: DepositRevert = deposit_revert::decode(&msg);
            withdraw(
                balance,
                rate_limit,
                c,
                deposit_revert::to(&message),
                deposit_revert::amount(&message),
                ctx
            );
        };

        xcall::execute_rollback_result(xcall,ticket,true);
    }

    fun get_asset_manager_mut<T>(config: &mut Config): &mut AssetManager<T> {
        let token_type = string::from_ascii(*type_name::borrow_string(&type_name::get<T>()));
        let asset_manager = config.assets.borrow_mut<String, AssetManager<T>>(token_type);
        asset_manager
    }

    fun get_asset_manager<T>(config: &Config): &AssetManager<T> {
        let token_type = string::from_ascii(*type_name::borrow_string(&type_name::get<T>()));
        let asset_manager = config.assets.borrow<String, AssetManager<T>>(token_type);
        asset_manager
    }

    fun withdraw<T>(balance: &mut Balance<T>, rate_limit: &mut RateLimit<T>, c: &Clock, to: address, amount: u64, ctx: &mut TxContext){
        assert!(amount>0, EAmountLessThanMinimumAmount);
        verify_withdraw(balance, rate_limit, c, amount );

        let token = coin::take(balance, amount, ctx);
        transfer::public_transfer(token, to);
    }

    entry fun set_icon_asset_manager(_: &AdminCap, config: &mut Config, icon_asset_manager: String ){
        enforce_version(config);
        config.icon_asset_manager = icon_asset_manager
    }

    fun set_version(config: &mut Config, version: u64 ){
        config.version = version
    }

    public fun get_version(config: &mut Config): u64{
        config.version
    }

    fun enforce_version(self:&Config){
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

