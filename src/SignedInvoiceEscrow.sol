// Signed Invoice Escrow Factory

// Build a small invoice-payment system in Solidity ^0.8.20.
// A client creates and funds a one-off ERC-20 escrow through a factory.
// The client can then sign a release offchain; the named freelancer uses that signature to claim payment. If payment is not released by the deadline, the client can refund it.

// Submit one Solidity file containing: IERC20, SignatureLib, InvoiceEscrow, and InvoiceFactory. Do not use imports or inline assembly.

// Token scope
// - Assume a standard ERC-20 whose transfer and transferFrom functions return bool.
// - Fee-on-transfer, rebasing, and nonstandard no-return tokens are out of scope.

// InvoiceFactory
// - Implement createInvoice(address freelancer, address token, uint256 amount, uint256 deadline), returning the deployed escrow address.
// - The client is msg.sender. Deploy one InvoiceEscrow with the client, freelancer, token, amount, and deadline.
// - Record created escrow addresses in public state so they can be verified as factory-created.
// - Fund the new escrow with a checked token.transferFrom from the client.
// - Emit EscrowCreated with the escrow address and invoice details.

// InvoiceEscrow
// - Store immutable client, freelancer, token, amount, and deadline values plus a public bool settled.
// - Reject zero addresses, identical client/freelancer roles, amount == 0, and a deadline that is not in the future.
// - messageHash() must return exactly keccak256(abi.encode(block.chainid, address(this), client, freelancer, address(token), amount, deadline)).
// - claim(uint8 v, bytes32 r, bytes32 s) may be called only by the freelancer, only while unsettled, and only at or before the deadline.
// It must recover the client from messageHash() through SignatureLib. Set settled before the checked token transfer to the freelancer, then emit Claimed.
// - refund() may be called only by the client, only while unsettled, and only after the deadline. Set settled before the checked token transfer to the client, then emit Refunded.

// SignatureLib
// - Apply the Ethereum Signed Message prefix with keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)) before ecrecover.
// - Accept only v == 27 or v == 28.
// - Reject high-s signatures: uint256(s) must be at most 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0.
// - Reject recovery to address(0).

// The settled flag is the one-shot replay guard. Including block.chainid and address(this) in messageHash prevents cross-chain and cross-escrow replay. Do not add fees, disputes, proxies, milestones, EIP-712 boilerplate, or arbitrary bytes-signature parsing.

//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

error InvalidV();
error InvalidS();
error InvalidSignature();
error FreelancerZeroAddress();
error TokenZeroAddress();
error ClientFreelancerSame();
error AmountZero();
error DeadlineNotInFuture();
error ClientZeroAddress();
error NotFreelancer();
error AlreadySettled();
error PastDeadline();
error InvalidSigner();
error NotClient();
error BeforeDeadline();
error TransferFailed();
error TransferFromFailed();

library SignatureLib {
    function recover(bytes32 messageHash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address signer) {
        if (v != 27 && v != 28) revert InvalidV();
        if (uint256(s) > 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0) revert InvalidS();

        bytes32 ethSignedMessageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        signer = ecrecover(ethSignedMessageHash, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
    }
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract InvoiceFactory {
    event EscrowCreated(
        address indexed escrow,
        address indexed client,
        address indexed freelancer,
        address token,
        uint256 amount,
        uint256 deadline
    );

    function createInvoice(address freelancer, address token, uint256 amount, uint256 deadline)
        external
        returns (address escrow)
    {
        if (freelancer == address(0)) revert FreelancerZeroAddress();
        if (token == address(0)) revert TokenZeroAddress();
        if (freelancer == msg.sender) revert ClientFreelancerSame();
        if (amount == 0) revert AmountZero();
        if (deadline <= block.timestamp) revert DeadlineNotInFuture();

        escrow = address(new InvoiceEscrow(msg.sender, freelancer, token, amount, deadline));
        if (!IERC20(token).transferFrom(msg.sender, escrow, amount)) {
            revert TransferFromFailed();
        }

        emit EscrowCreated(escrow, msg.sender, freelancer, token, amount, deadline);
    }
}

contract InvoiceEscrow {
    address public immutable client;
    address public immutable freelancer;
    IERC20 public immutable token;
    uint256 public immutable amount;
    uint256 public immutable deadline;
    bool public settled;

    constructor(address _client, address _freelancer, address _token, uint256 _amount, uint256 _deadline) {
        if (_client == address(0)) revert ClientZeroAddress();
        if (_freelancer == address(0)) revert FreelancerZeroAddress();
        if (_token == address(0)) revert TokenZeroAddress();
        if (_client == _freelancer) revert ClientFreelancerSame();
        if (_amount == 0) revert AmountZero();
        if (_deadline <= block.timestamp) revert DeadlineNotInFuture();

        client = _client;
        freelancer = _freelancer;
        token = IERC20(_token);
        amount = _amount;
        deadline = _deadline;
    }

    function messageHash() public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), client, freelancer, address(token), amount, deadline));
    }

    function claim(uint8 v, bytes32 r, bytes32 s) external {
        if (msg.sender != freelancer) revert NotFreelancer();
        if (settled) revert AlreadySettled();
        if (block.timestamp > deadline) revert PastDeadline();

        address signer = SignatureLib.recover(messageHash(), v, r, s);
        if (signer != client) revert InvalidSigner();

        settled = true;
        if (!token.transfer(freelancer, amount)) revert TransferFailed();
    }

    function refund() external {
        if (msg.sender != client) revert NotClient();
        if (settled) revert AlreadySettled();
        if (block.timestamp <= deadline) revert BeforeDeadline();

        settled = true;
        if (!token.transfer(client, amount)) revert TransferFailed();
    }
}
