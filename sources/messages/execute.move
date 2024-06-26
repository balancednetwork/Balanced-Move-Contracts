#[allow(unused_field,unused_use,unused_const,unused_mut_parameter,unused_variable,unused_assignment)]
module balanced::execute {
    use std::string::{Self, String};
    use std::option::{some, none};
    use sui_rlp::encoder;
    use sui_rlp::decoder;

    public struct Execute has drop{
        contract_address: String, 
        data: vector<u8>
    }

    public fun encode(req:&Execute, method: vector<u8>):vector<u8>{
        let mut list=vector::empty<vector<u8>>();
        vector::push_back(&mut list, encoder::encode(&method));
        vector::push_back(&mut list,encoder::encode_string(&req.contract_address));
        vector::push_back(&mut list,encoder::encode(&req.data));

        let encoded=encoder::encode_list(&list,false);
        encoded
    }

    public fun decode(bytes:&vector<u8>): Execute {
        let decoded=decoder::decode_list(bytes);
        let contract_address = decoder::decode_string(vector::borrow(&decoded, 1));
        let data = decoder::decode(vector::borrow(&decoded, 4));
        let req= wrap_execute (
            contract_address,
            data
        );
        req
    }

     public fun wrap_execute(contract_address: String, data: vector<u8>): Execute {
        let deposit = Execute {
            contract_address: contract_address,
            data: data

        };
        deposit
    }

    public fun get_method(bytes:&vector<u8>): vector<u8> {
        let decoded=decoder::decode_list(bytes);
        let method = decoder::decode(vector::borrow(&decoded, 0));
        method
    }

    public fun contract_address(execute: &Execute): String{
        execute.contract_address
    }

    public fun data(execute: &Execute): vector<u8>{
        execute.data
    }

}