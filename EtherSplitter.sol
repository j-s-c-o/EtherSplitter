/*
 * EtherSplitter.sol
 *
 * Smart contract for distributing mining profits between shareholders after
 * deducting power costs in USD. ETH/USD exchange rate is determined by
 * consulting MakerDAO's price oracle.
 *
 * Example usage sequence:
 *  - creator:
 *    - create EtherSplitter contract
 *    - set_power_cost_payout_address(0xabcd...)
 *    - set_power_cost((13/*cents/kWh*/ * 2000/*W*/ * FP_ONE)
 *                     / (100/*cents/USD*/ * 1000/*W/kW*/))
 *    - set_shareholder_weight(0x1234..., 75)
 *    - set_shareholder_weight(0x5678..., 25)
 *  - anyone:
 *    - distribute()  <- updates ETH/USD price, pays for power, shares profits
 *  - any payee:
 *    - withdraw()  <- withdaws any owed funds (profit or power payouts)
 */

pragma solidity ^0.4.21;

// Use the github import when using a linker that isn't stupid (i.e. not remix)
//import 'github.com/ethereum/dapp-bin/library/iterable_mapping.sol';
import 'browser/itmap.sol';

// stub contract for makerdao price oracle data interface
contract DSValue {
    bool has;
    bytes32 val;
    function peek() public constant returns (bytes32, bool) {
        return(val, has);
    }
    function poke(bytes32 wut) public {
        val = wut;
        has = true;
    }
}

contract EtherSplitter {
    // The creator has special trusted powers over this contract. The creator
    // can:
    //  - add, remove, and modify weights of shareholders
    //  - change the power cost rate
    //  - change the power payout address
    //  - change the price oracle address
    //  - change the ETH/USD price
    //  - transfer ownership to another address
    //  - initiate selfdestruct and receive any remaining contract balance
    address creator_;
    modifier creator_only() {
        require(msg.sender == creator_);
        _;
    }

    // Contract-wide mutex for preventing reentrancy.
    bool locked_;
    modifier mutex() {
        require(!locked_);
        locked_ = true;
        _;
        locked_ = false;
    }

    // Mapping from address => weight (uint)
    IterableMapping.itmap public shareholders_;
    uint public total_weight_;
    // Address where power costs should be paid. Doesn't have to be a
    // shareholder.
    address public power_cost_payout_address_;
    // Outstanding withdrawable balance for each current or past shareholder
    // or power payout address.
    mapping(address => uint) public balances_;
    // Internal bookkeeping variable that tracks how much of the contract's
    // current balance has been allocated into the balances map already. This
    // is needed because funds come in without triggering any code, so when
    // allocations are calculated later, we need to know how much is already
    // accounted for and how much is new and still needs to be allocated.
    uint public total_allocated_balance_;
    // Amount owed to the power_cost_payout_address_ that can't be paid out
    // with the current contract balance. Any new funds that come in will go
    // toward this debt before being distributed.
    uint public power_debt_;

    // Reference value of 1.0 in fixed point representation.
    uint constant FP_ONE = 1000000000000000000;

    // Timestamp of the last time a distribution was made
    uint public last_distribution_time_;
    // Cost of power USD per hour (fixed point). Example value for a load of
    // 2kW at $0.13/kWh:
    //  power_cost_usd_ = (13/*cents/kWh*/ * 2000/*W*/ * FP_ONE)
    //      / (100/*cents/USD*/ * 1000/*W/kW*/);
    uint public power_cost_usd_;

    // Address of the ETH/USD price oracle to use. Defaults to the MakerDAO
    // price oracle medianizer contract. Target must implement the DSValue
    // interface above.
    address public eth_price_oracle_ = 0x729D19f657BD0614b4985Cf1D82531c67569197B;
    // Last valid price of 1 ETH in USD (fixed point). Initially set to an
    // arbitrary value of $1000.
    uint public last_valid_eth_price_ = 1000 * FP_ONE;

    //=========================================================================
    // Creator interface

    // Creates a new contract with no shareholders.
    function EtherSplitter() public {
        creator_ = msg.sender;
        last_distribution_time_ = now;
    }

    // Sets the weight for a new or existing shareholder. If this is a new
    // shareholder, they will be added to the shareholders_ mapping.
    // NOTE: It's a good idea to call distribute() before making any changes,
    // because changes are essentially retroactive to the last distribuition
    // time.
    function set_shareholder_weight(address shareholder, uint weight)
        public mutex creator_only
    {
        total_weight_ += weight - shareholders_.data[uint(shareholder)].value;
        IterableMapping.insert(shareholders_, uint(shareholder), weight);
    }

    // Removes a shareholder from shareholders_, effectively setting their
    // weight to zero. They will not receive any future distributions, although
    // any unclaimed funds previously allocated to them will still be available
    // for withdrawal.
    // NOTE: It's a good idea to call distribute() before making any changes,
    // because changes are essentially retroactive to the last distribuition
    // time.
    function remove_shareholder(address to_remove) public mutex creator_only {
        total_weight_ -= shareholders_.data[uint(to_remove)].value;
        IterableMapping.remove(shareholders_, uint(to_remove));
    }
    
    // Change the power cost rate (USD per hour, fixed point)
    function set_power_cost(uint power_cost) public mutex creator_only {
        require(power_cost >= 0);
        power_cost_usd_ = power_cost;
    }

    // Change the power cost payout address
    function set_power_cost_payout_address(address power_cost_payout_address)
        public mutex creator_only
    {
        power_cost_payout_address_ = power_cost_payout_address;
    }
    
    // Change the price oracle address
    function set_price_oracle(address price_oracle_address)
        public mutex creator_only
    {
        eth_price_oracle_ = price_oracle_address;
    }
    
    // Change the ETH/USD price (price of 1 ETH in USD, fixed point)
    function set_price(uint usd_price) public mutex creator_only {
        last_valid_eth_price_ = usd_price;
    }

    // Transfer contract ownership to another address.
    function set_new_creator(address new_creator) public mutex creator_only {
        creator_ = new_creator;
    }

    // Initiate selfdestruct and send any remaining contract balance to
    // creator_.
    function terminate() public mutex creator_only {
        selfdestruct(creator_);
    }

    //=========================================================================
    // Internal

    // Queries the price oracle to update the ETH/USD price. Private, to avoid
    // mutex conflicts when called internally.
    function update_price() private {
        DSValue oracle = DSValue(eth_price_oracle_);
        bytes32 price;
        bool success;
        (price, success) = oracle.peek();
        if (success) {
            last_valid_eth_price_ = uint(price);
        }
    }

    //=========================================================================
    // Public interface

    // Fallback function: Do nothing; consume no extra gas.
    function() public payable {}

    // Distributes contract funds among shareholders according to weight, after
    // subtracting power costs. Funds are not directly paid out by calling this
    // function; rather, they are allocated to the balances_ mapping, which
    // allows them to be withdrawn by their recipients.
    function distribute() public mutex {
        update_price();

        // Calculate the amount of new, unallocated money that has come in
        // since the last distribute() call.
        uint income = address(this).balance - total_allocated_balance_;
        assert(income >= 0);

        // Calculate and send payment for power based on time since last
        // payout.
        uint power_owed =
            power_cost_usd_ * (now - last_distribution_time_) * 1 ether
            / (3600 * last_valid_eth_price_);
        power_owed += power_debt_;
        if (power_owed <= income) {
            // Pay for power and deduct from distributable income.
            power_debt_ = 0;
            income -= power_owed;
            total_allocated_balance_ += power_owed;
            balances_[power_cost_payout_address_] += power_owed;
        } else {
            // Don't have enough income to pay for power, so go into debt.
            power_debt_ = power_owed - income;
            total_allocated_balance_ += income;
            balances_[power_cost_payout_address_] += income;
            income = 0;
        }
        last_distribution_time_ = now;

        // Calculate output amounts based on differences of sums to ensure that
        // rounding errors all add up correctly within this transaction. No
        // attempt is made to ensure fairness of cumulative rounding errors
        // across multiple transactions.
        uint sum_weight = 0;
        uint sum_sent = 0;
        for (uint i = IterableMapping.iterate_start(shareholders_);
            IterableMapping.iterate_valid(shareholders_, i);
            i = IterableMapping.iterate_next(shareholders_, i))
        {
            uint shareholder;
            uint weight;
            (shareholder, weight) =
                IterableMapping.iterate_get(shareholders_, i);
            uint new_sum_weight = sum_weight + weight;
            uint new_sum_sent = (income * new_sum_weight) / total_weight_;
            balances_[address(shareholder)] += new_sum_sent - sum_sent;
            sum_weight = new_sum_weight;
            sum_sent = new_sum_sent;
        }
        total_allocated_balance_ += sum_sent;
    }
    
    // Withdraws all distributed funds that are owed to the caller.
    function withdraw() public mutex {
        uint balance = balances_[msg.sender];
        if (balance > 0) {
            balances_[msg.sender] = 0;
            total_allocated_balance_ -= balance;
            msg.sender.transfer(balance);
        }
    }
}
