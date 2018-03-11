# EtherSplitter
Ether splitter smart contract

WARNING: USE AT YOUR OWN RISK. THERE ARE PROBABLY BUGS.

This is an amateur attempt at creating a smart contract for distributing mining profits to shareholders of a jointly owned mining rig, after paying out power costs at a fixed rate to a specified address.

Power cost is specified in USD but paid in ETH, and the exchange rate is determined by querying the MakerDAO ETH/USD price oracle:
https://makerdao.com/feeds/#0x729d19f657bd0614b4985cf1d82531c67569197b
https://github.com/makerdao/medianizer/blob/master/src/medianizer.sol
https://www.reddit.com/r/MakerDAO/comments/7qhrzv/makerdao_team_can_you_please_clarify_how_the/

Money can be sent to this contract, or mined directly to it. The contract does not execute any code on receipt of funds.

The public interface to this contract consists of two functions:
 * distribute(): This can be called by anyone. It queries the price oracle, updates the ETH/USD exchange rate, attempts to pay for power (and/or records the outstanding debt if it can't pay), and allocates the remaining income among shareholders according to their share weights. Payments are not initiated directly; rather, balances are updated for each payee in local storage for later calls to withdraw().
 * withdraw(): Withdraws any funds owed to the caller and sends them to the caller, zeroing their outstanding balance.
Note that someone has to call distribute() before withdraw() will do anything useful. It's a good idea to call distribute every now and then to make sure that power payments track ETH/USD price fluctuations fairly.

The contract creator has the sole authority and responsibility for handling administrative tasks like setting the cost of power (in USD/hour), setting the address to be paid for power costs, adding and removing shareholders, etc. The creator can transfer this authority to a different address if needed. The creator can also terminate() (i.e. selfdestruct) the contract as a failsafe, and they will receive any outstanding contract balance.

The contract creator should read the entire interface and familiarize themselves with the required setup steps before deploying the contract and sending any money to it.

NOTE: The IterableMapping library (https://github.com/ethereum/dapp-bin/blob/master/library/iterable_mapping.sol) has been copied into this repository as a workaround to a bug in the remix linker which fails on filenames which contain an underscore. It would be a good idea to switch back to the canonical library when using a real compiler.
