import "@stdlib/tvm-dicts"
import "@stdlib/gas-payments"
import "@stdlib/lisp-lists"


const `op::add_whitelist` = 0x7258a69b;
const `op::add_whitelist_response` = 0xf258a69b;
const `op::send` = 0xa7733acd;
const `op::send_response` = 0xf7733acd;

// https://github.com/ton-blockchain/ton/blob/master/crypto/smartcont/elector-code.fc
// https://github.com/ton-blockchain/ton/blob/master/crypto/smartcont/config-code.fc
const `op::elector_new_stake` = 0x4e73744b;
const `op::elector_recover_stake` = 0x47657424;
const `op::vote_for_complaint` = 0x56744370;
const `op::vote_for_proposal` = 0x566f7465;

// single-nominator-pool: empty message to deposit; 0x1000 to withdraw https://github.com/orbs-network/single-nominator/blob/main/contracts/single-nominator.fc
const `op::single_nominator_pool_withdraw` = 0x1000;
const `op::single_nominator_pool_change_validator` = 0x1001;

// tonstakers.com: deposit to pool; burn, vote to jetton-wallet - https://ton-ls-protocol.gitbook.io/ton-liquid-staking-protocol/protocol-concept/message-processing
const `op::ton_stakers_deposit` = 0x47d54391;
const `op::jetton_burn` = 0x595f07bc;
const `op::ton_stakers_vote` = 0x69fb306c;

const `error::expired` = 36;
const `error::invalid_seqno` = 33;
const `error::invalid_subwallet_id` = 34;
const `error::invalid_signature` = 35;

const `error::send_mode_not_allowed` = 100;
const `error::non_bounceable_not_allowed` = 101;
const `error::state_init_not_allowed` = 102;
const `error::comment_not_allowed` = 103;
const `error::symbols_not_allowed` = 104;

// https://github.com/ton-blockchain/ton/blob/d2b418bb703ed6ccd89b7d40f9f1e44686012014/crypto/block/block.tlb#L605
const config_id = 0;
const elector_id = 1;

// data

global stored_seqno: int;
global stored_subwallet: int;
global public_key: int;

global whitelist: cell?;

global vesting_start_time: int;
global vesting_total_duration: int;
global unlock_period: int;
global cliff_duration: int;
global vesting_total_amount: int;
global vesting_sender_address: slice;
global owner_address: slice;

// CONDITIONS:
// vesting_total_duration > 0
// vesting_total_duration <= 135 years (2^32 seconds)
// unlock_period > 0
// unlock_period <= vesting_total_duration
// cliff_duration >= 0
// cliff_duration < vesting_total_duration
// vesting_total_duration mod unlock_period == 0
// cliff_duration mod unlock_period == 0

@inline
fun loadVestingParameters(data: cell) {
    var ds: slice = data.beginParse();
    vesting_start_time = ds.loadUint(64);
    vesting_total_duration = ds.loadUint(32);
    unlock_period = ds.loadUint(32);
    cliff_duration = ds.loadUint(32);
    vesting_total_amount = ds.loadCoins();
    vesting_sender_address = ds.loadAddress();
    owner_address = ds.loadAddress();
    ds.assertEndOfSlice();
}

@inline
fun packVestingParameters(): cell {
    return beginCell()
            .storeUint(vesting_start_time, 64)
            .storeUint(vesting_total_duration, 32)
            .storeUint(unlock_period, 32)
            .storeUint(cliff_duration, 32)
            .storeCoins(vesting_total_amount) // max 124 bits
            .storeSlice(vesting_sender_address) // 267 bit
            .storeSlice(owner_address) // 267 bit
            .endCell();
}

@inline_ref
fun loadData() {
    var ds: slice = getContractData().beginParse();
    stored_seqno = ds.loadUint(32);
    stored_subwallet = ds.loadUint(32);
    public_key = ds.loadUint(256);
    whitelist = ds.loadDict();
    loadVestingParameters(ds.loadRef());
    ds.assertEndOfSlice();
}

@inline_ref
fun saveData() {
    setContractData(
            beginCell()
                    .storeUint(stored_seqno, 32)
                    .storeUint(stored_subwallet, 32)
                    .storeUint(public_key, 256)
                    .storeDict(whitelist)
                    .storeRef(packVestingParameters())
                    .endCell()
    );
}

// messages utils


const SEND_MODE_PAY_FEES_SEPARETELY = 1;

@inline
fun returnExcess(toAddress: slice, op: int, queryId: int) {
    var msg: builder = beginCell()
            .storeUint(BOUNCEABLE, 6)
            .storeSlice(toAddress)
            .storeCoins(0)
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeUint(op, 32)
            .storeUint(queryId, 64);

    sendRawMessage(msg.endCell(), SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

@inline_ref
fun matchAddressFromConfig(address: slice, configId: int): bool {
    var (addressWc: int, addressHash: int) = parseStandardAddress(address);
    if (addressWc != -1) {
        return false;
    }
    var configCell: cell? = getBlockchainConfigParam(configId);
    if (configCell == null) {
        return false;
    }
    var configSlice: slice = configCell.beginParse();
    if (configSlice.getRemainingBitsCount() < 256) {
        return false;
    }
    return addressHash == configSlice.preloadUint(256);
}


// address utils

const ADDRESS_SIZE = 264; // 256 + 8

@inline
fun packAddress(address: slice): slice {
    var (wc: int, addressHash: int) = parseStandardAddress(address);
    return beginCell().storeInt(wc, 8).storeUint(addressHash, 256).endCell().beginParse();
}

@inline
fun unpackAddress(address: slice): (int, int) {
    var wc: int = address.loadInt(8);
    var addressHash: int = address.loadUint(256);
    return (wc, addressHash);
}

@pure
fun isDictGet(dict: cell?, keyLen: int, index: slice): (slice, bool)
    asm(index dict keyLen) "DICTGET" "NULLSWAPIFNOT";

@inline
fun IsWhitelisted(address: slice): bool {
    var (_, found: bool) = whitelist.isDictGet(ADDRESS_SIZE, packAddress(address));
    return found;
}

// locked

@inline_ref
fun GetLockedAmount(nowTime: int): int {
    if (nowTime > vesting_start_time + vesting_total_duration) {
        return 0;
    }

    if (nowTime < vesting_start_time + cliff_duration) {
        return vesting_total_amount;
    }

    return vesting_total_amount - mulDivFloor(vesting_total_amount,
            (nowTime - vesting_start_time) / unlock_period,
            vesting_total_duration / unlock_period);
}

@inline_ref
fun sendMessageOut(inMsgBody: slice) {
    var sendMode: int = inMsgBody.loadUint(8);
    var msg: cell = inMsgBody.loadRef();
    inMsgBody.assertEndOfSlice(); // only 1 ref allowed

    var lockedAmount: int = GetLockedAmount(now());

    if (lockedAmount > 0) { // if the vesting has expired, you can send any messages

        assert(sendMode == SEND_MODE_IGNORE_ERRORS + SEND_MODE_PAY_FEES_SEPARETELY) throw `error::send_mode_not_allowed`;

        var msgCs: slice = msg.beginParse();
        var flags: int = msgCs.loadUint(4);
        var senderAddress: slice = msgCs.loadAddress(); // skip
        var destinationAddress: slice = msgCs.loadAddress();

        if (! isSliceBitsEqual(destinationAddress, vesting_sender_address)) { // can send to vesting_sender_address any message

            if (IsWhitelisted(destinationAddress)) {
                var isBounceable: bool = (flags & 2) == 2;
                assert(isBounceable) throw `error::non_bounceable_not_allowed`;

                msgCs.loadCoins(); // skip value
                msgCs.skipBits(1); // skip extracurrency collection
                msgCs.loadCoins(); // skip ihr_fee
                msgCs.loadCoins(); // skip fwd_fee
                msgCs.loadUint(64); // skip createdLt
                msgCs.loadUint(32); // skip createdAt
                var maybeStateInit: int = msgCs.loadUint(1);
                assert(maybeStateInit == 0) throw `error::state_init_not_allowed`;

                var maybeBody: int = msgCs.loadUint(1);
                var body: slice = maybeBody ? msgCs.loadRef().beginParse() : msgCs;

                if (matchAddressFromConfig(destinationAddress, elector_id)) { // elector - direct validation

                    var op: int = body.loadUint(32);
                    assert((op == `op::elector_new_stake`) || (op == `op::elector_recover_stake`) || (op == `op::vote_for_complaint`) || (op == `op::vote_for_proposal`)) throw `error::comment_not_allowed`;

                } else if (matchAddressFromConfig(destinationAddress, config_id)) { // conifg - direct validation

                    var op: int = body.loadUint(32);
                    assert((op == `op::vote_for_proposal`)) throw `error::comment_not_allowed`;

                } else if (body.getRemainingBitsCount() > 0) { // empty message allowed for other destination (not elector)

                    var op: int = body.loadUint(32);
                    assert((op == 0) || // text comment
                                    (op == `op::single_nominator_pool_withdraw`) || (op == `op::single_nominator_pool_change_validator`) || // single-nominator
                                    (op == `op::ton_stakers_deposit`) || (op == `op::jetton_burn`) || (op == `op::ton_stakers_vote`) | // tonstakers.com
                                    (op == `op::vote_for_proposal`) || (op == `op::vote_for_complaint`)) throw `error::comment_not_allowed`;

                    if ((op == 0) & (body.getRemainingBitsCount() > 0)) { // empty text comment allowed
                        var action: int = body.loadUint(8);
                        assert((action == stringToBase256("d")) || (action == stringToBase256("w")) || // nominator-pool - https://github.com/ton-blockchain/nominator-pool
                                        (action == stringToBase256("D")) || (action == stringToBase256("W"))) throw `error::symbols_not_allowed`;
                    }
                }

                lockedAmount = 0;
            }

            if (lockedAmount > 0) {
                reserveToncoinsOnBalance(lockedAmount, 2); // mode 2 - at most `amount` nanotons. Bit +2 in y means that the external action does not fail if the specified amount cannot be reserved; instead, all remaining balance is reserved
            }
        }
    }

    sendRawMessage(msg, sendMode);
}

// receive

fun onInternalMessage(myBalance: int, msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    if (inMsgBody.getRemainingBitsCount() < 32 + 64) { // ignore simple transfers
        return;
    }

    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);
    if (flags & 1) { // ignore all bounced messages
        return;
    }
    var senderAddress: slice = cs.loadAddress();

    loadData();

    var op: int = inMsgBody.loadUint(32);
    var queryId: int = inMsgBody.loadUint(64);

    if (isSliceBitsEqual(senderAddress, owner_address) && (op == `op::send`)) {

        sendMessageOut(inMsgBody);

        returnExcess(senderAddress, `op::send_response`, queryId);

    } else if (isSliceBitsEqual(senderAddress, vesting_sender_address) & (op == `op::add_whitelist`)) {

        var refCs: slice = inMsgBody;
        var hasRefs: bool = false;
        do {
            var whitelistAddress: slice = refCs.loadAddress();
            whitelist.sDictSetBuilder(ADDRESS_SIZE, packAddress(whitelistAddress), beginCell().storeInt(-1, 1));

            hasRefs = refCs.getRemainingRefsCount() > 0;
            if (hasRefs) {
                var ref: cell = refCs.loadRef();
                refCs = ref.beginParse();
            }
        } while (hasRefs);

        returnExcess(senderAddress, `op::add_whitelist_response`, queryId);

        saveData();

    }

    // else just accept coins from anyone
}

// same with wallet-v3 https://github.com/ton-blockchain/ton/blob/master/crypto/smartcont/wallet3-code.fc#L15
fun onExternalMessage(inMsg: slice) {
    var signature: slice = inMsg.loadBits(512);
    var cs: slice = inMsg;
    var (msgSubwalletId: int, validUntil: int, msgSeqno: int) = (cs.loadUint(32), cs.loadUint(32), cs.loadUint(32));
    assert(!(validUntil <= now())) throw `error::expired`;
    var ds: slice = getContractData().beginParse();
    var (mySeqno: int, mySubwalletId: int, myPublicKey: int) = (ds.loadUint(32), ds.loadUint(32), ds.loadUint(256));
    assert(msgSeqno == mySeqno) throw `error::invalid_seqno`;
    assert(msgSubwalletId == mySubwalletId) throw `error::invalid_subwallet_id`;
    assert(isSignatureValid(sliceHash(inMsg), signature, myPublicKey)) throw `error::invalid_signature`;

    acceptExternalMessage();

    loadData();

    if (getRemainingRefsCount(cs) == 1) {
        try {
            sendMessageOut(cs);
        } catch (y, x) {
        }
    }

    stored_seqno += 1;
    saveData();
}

// get-methods

// same with wallet-v3 and wallet-v4
get seqno(): int {
    return getContractData().beginParse().preloadUint(32);
}

// same with wallet-v4 https://github.com/ton-blockchain/wallet-contract/blob/main/func/wallet-v4-code.fc
get get_subwallet_id(): int {
    return getContractData().beginParse().skipBits(32).preloadUint(32);
}

// same with wallet-v3 and wallet-v4
get get_public_key(): int {
    return getContractData().beginParse().skipBits(64).preloadUint(256);
}

get get_vesting_data(): (int, int, int, int, int, slice, slice, cell?) {
    loadData();

    return (vesting_start_time, vesting_total_duration, unlock_period, cliff_duration, vesting_total_amount,
            vesting_sender_address, owner_address, whitelist);
}

// same with wallet-v4
get is_whitelisted(address: slice): bool {
    loadData();

    return IsWhitelisted(address);
}

// same with wallet-v4
get get_whitelist(): tuple? {
    loadData();

    var list: tuple? = null;

    var d: cell? = whitelist;
    do {
        var (key: slice?, value: slice?, found: bool) = d.sDictDeleteFirstAndGet(ADDRESS_SIZE);
        if (found) {
            var (wc: int, addressHash: int) = unpackAddress(key!);
            list = listPrepend([wc, addressHash], list);
        }
    } while (found);

    return list;
}

get get_locked_amount(atTime: int): int {
    loadData();

    return GetLockedAmount(atTime);
}
