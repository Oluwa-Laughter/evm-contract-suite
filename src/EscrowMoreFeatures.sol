// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 29: Include an ERC-20 interface and use it for transferFrom and transfer.
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

library EscrowStatus {
    enum Status {
        None,
        Open,
        Delivered,
        Disputed,
        Resolved,
        Settled,
        Refunded
    }
}

// 30: Include a useful Solidity library in the same file for fee or split calculations.
library EscrowMath {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // Calculates basis points: (amount * bps) / 10,000
    function calculateBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / BPS_DENOMINATOR;
    }

    // Calculates standard settlement: fee to platform, remainder to freelancer
    function calculateSettlement(uint256 amount, uint256 feeBps)
        internal
        pure
        returns (uint256 freelancerPayout, uint256 platformFee)
    {
        platformFee = calculateBps(amount, feeBps);
        freelancerPayout = amount - platformFee;
    }

    // Calculates dispute split:

    function calculateDisputeSplit(uint256 amount, uint256 clientRefundBps, uint256 feeBps)
        internal
        pure
        returns (uint256 clientShare, uint256 freelancerPayout, uint256 platformFee)
    {
        clientShare = calculateBps(amount, clientRefundBps);
        uint256 freelancerGross = amount - clientShare;
        platformFee = calculateBps(freelancerGross, feeBps);
        freelancerPayout = freelancerGross - platformFee;
    }
}

contract EscrowMoreFeatures {
    uint256 public constant MAX_FEE_BPS = 1_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    error ZeroAddress();
    error FeeExceedsMax(uint256 providedBps, uint256 maxBps);
    error ZeroReviewPeriod();
    error ZeroAmount();
    error DeliveryDeadlineMustBeInFuture(uint256 deadline, uint256 currentTimestamp);
    error PartiesMustBeDistinct();

    error UnknownEscrow(uint256 escrowId);
    error UnauthorizedCaller(address caller);
    error InvalidStatus(EscrowStatus.Status currentStatus);
    error DeliveryDeadlinePassed(uint256 deadline, uint256 currentTimestamp);
    error DeliveryDeadlineNotPassed(uint256 deadline, uint256 currentTimestamp);
    error ReviewDeadlinePassed(uint256 deadline, uint256 currentTimestamp);
    error ReviewDeadlineNotPassed(uint256 deadline, uint256 currentTimestamp);
    error InvalidRefundBps(uint256 providedBps, uint256 maxBps);

    error NoAvailableBalance();
    error TokenTransferFailed();

    // 1. Set a non-zero fee recipient.
    address public immutable feeRecipient;

    // 2. Set the platform fee in basis points. Reject a fee above 1,000 basis points (10%).
    uint256 public immutable platformFeeBps;

    // 3. Set a fixed review period. Reject a zero review period.
    uint256 public immutable reviewPeriod;

    // 4. Give every escrow a unique ID.
    uint256 public nextEscrowId;

    // 5. Store the client, freelancer, arbitrator, token, amount, delivery deadline, review deadline, and current status.
    struct Escrow {
        address client;
        address freelancer;
        address arbitrator;
        address token;
        uint256 amount;
        uint256 deliveryDeadline;
        uint256 reviewDeadline;
        EscrowStatus.Status status;
    }

    // Mapping from escrowId to Escrow data
    mapping(uint256 => Escrow) public escrows;

    // 21. Credit the client, freelancer, and fee recipient using balances scoped by both token address and user address.
    // balances[tokenAddress][userAddress] = amount available to withdraw
    mapping(address => mapping(address => uint256)) public balances;

    // 28. Emit events for creation, delivery, approval, dispute, timeout finalization, dispute resolution, refund, and withdrawal.
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed client,
        address indexed freelancer,
        address arbitrator,
        address token,
        uint256 amount,
        uint256 deliveryDeadline
    );

    event EscrowDelivered(uint256 indexed escrowId, address indexed freelancer, uint256 reviewDeadline);

    event EscrowApproved(
        uint256 indexed escrowId, address indexed client, uint256 freelancerPayout, uint256 platformFee
    );

    event EscrowDisputed(uint256 indexed escrowId, address indexed client);

    event EscrowTimeoutFinalized(
        uint256 indexed escrowId, address indexed freelancer, uint256 freelancerPayout, uint256 platformFee
    );

    event DisputeResolved(
        uint256 indexed escrowId,
        address indexed arbitrator,
        uint256 clientRefund,
        uint256 freelancerPayout,
        uint256 platformFee
    );

    event EscrowRefunded(uint256 indexed escrowId, address indexed client, uint256 amount);

    event Withdrawal(address indexed token, address indexed user, uint256 amount);

    constructor(address _feeRecipient, uint256 _platformFeeBps, uint256 _reviewPeriod) {
        // 1. Set a non-zero fee recipient.
        if (_feeRecipient == address(0)) revert ZeroAddress();

        // 2. Set the platform fee in basis points. Reject a fee above 1,000 basis points (10%).
        if (_platformFeeBps > MAX_FEE_BPS) {
            revert FeeExceedsMax(_platformFeeBps, MAX_FEE_BPS);
        }

        // 3. Set a fixed review period. Reject a zero review period.
        if (_reviewPeriod == 0) revert ZeroReviewPeriod();

        feeRecipient = _feeRecipient;
        platformFeeBps = _platformFeeBps;
        reviewPeriod = _reviewPeriod;
    }

    // 6. The client supplies the freelancer, arbitrator, token, amount, and delivery deadline.
    function createEscrow(
        address freelancer,
        address arbitrator,
        address token,
        uint256 amount,
        uint256 deliveryDeadline
    ) external returns (uint256 escrowId) {
        // 7. Reject zero addresses, a zero amount, or a delivery deadline that is not in the future.
        if (freelancer == address(0) || arbitrator == address(0) || token == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) revert ZeroAmount();
        if (deliveryDeadline <= block.timestamp) {
            revert DeliveryDeadlineMustBeInFuture(deliveryDeadline, block.timestamp);
        }

        // 8. The client, freelancer, and arbitrator must be different addresses.
        if (msg.sender == freelancer || msg.sender == arbitrator || freelancer == arbitrator) {
            revert PartiesMustBeDistinct();
        }

        // 4. Give every escrow a unique ID.
        escrowId = nextEscrowId++;

        // 5. Store the client, freelancer, arbitrator, token, amount, delivery deadline, review deadline, and current status.
        escrows[escrowId] = Escrow({
            client: msg.sender,
            freelancer: freelancer,
            arbitrator: arbitrator,
            token: token,
            amount: amount,
            deliveryDeadline: deliveryDeadline,
            reviewDeadline: 0,
            status: EscrowStatus.Status.Open
        });

        // 28. Emit event for creation before external interaction (CEI)
        emit EscrowCreated(escrowId, msg.sender, freelancer, arbitrator, token, amount, deliveryDeadline);

        // 9. Transfer the tokens from the client into the contract and revert if the transfer fails.
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TokenTransferFailed();
    }

    // 10. Only the assigned freelancer can mark the escrow as delivered.
    // 11. Delivery is allowed only on or before the delivery deadline.
    // 12. Delivery starts the fixed review period and records its review deadline.
    function markDelivered(uint256 escrowId) external {
        Escrow storage escrow = _getValidEscrow(escrowId);

        // 27. Reject wrong statuses, wrong callers, and invalid timing
        if (escrow.status != EscrowStatus.Status.Open) {
            revert InvalidStatus(escrow.status);
        }
        if (msg.sender != escrow.freelancer) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (block.timestamp > escrow.deliveryDeadline) {
            revert DeliveryDeadlinePassed(escrow.deliveryDeadline, block.timestamp);
        }

        // Update status and set review deadline
        escrow.status = EscrowStatus.Status.Delivered;
        escrow.reviewDeadline = block.timestamp + reviewPeriod;

        emit EscrowDelivered(escrowId, msg.sender, escrow.reviewDeadline);
    }

    // 13. If delivery has not happened, only the client can request a full refund after the delivery deadline. No platform fee is charged on this refund.
    function requestRefund(uint256 escrowId) external {
        Escrow storage escrow = _getValidEscrow(escrowId);

        // 27. Reject wrong statuses, wrong callers, and invalid timing
        if (escrow.status != EscrowStatus.Status.Open) {
            revert InvalidStatus(escrow.status);
        }
        if (msg.sender != escrow.client) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (block.timestamp <= escrow.deliveryDeadline) {
            revert DeliveryDeadlineNotPassed(escrow.deliveryDeadline, block.timestamp);
        }

        // 23. Each escrow can be refunded or settled only once and can never return to an earlier status.
        escrow.status = EscrowStatus.Status.Refunded;

        // 21. Credit the client balance scoped by token and user address
        balances[escrow.token][escrow.client] += escrow.amount;

        emit EscrowRefunded(escrowId, msg.sender, escrow.amount);
    }

    // 14. On or before the review deadline, only the client can approve the delivery.
    // 15. Approval settles the full gross payment to the freelancer, less the platform fee.
    function approveDelivery(uint256 escrowId) public {
        Escrow storage escrow = _getValidEscrow(escrowId);

        if (escrow.status != EscrowStatus.Status.Delivered) {
            revert InvalidStatus(escrow.status);
        }
        if (msg.sender != escrow.client) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (block.timestamp > escrow.reviewDeadline) {
            revert ReviewDeadlinePassed(escrow.reviewDeadline, block.timestamp);
        }

        // Internal helper executes settlement and credits balances
        (uint256 freelancerPayout, uint256 platformFee) = _settle(escrow);

        emit EscrowApproved(escrowId, msg.sender, freelancerPayout, platformFee);
    }

    // Alias for approveDelivery
    function approve(uint256 escrowId) external {
        approveDelivery(escrowId);
    }

    // 14. On or before the review deadline, only the client can open a dispute.
    function openDispute(uint256 escrowId) public {
        Escrow storage escrow = _getValidEscrow(escrowId);

        if (escrow.status != EscrowStatus.Status.Delivered) {
            revert InvalidStatus(escrow.status);
        }
        if (msg.sender != escrow.client) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (block.timestamp > escrow.reviewDeadline) {
            revert ReviewDeadlinePassed(escrow.reviewDeadline, block.timestamp);
        }

        escrow.status = EscrowStatus.Status.Disputed;

        emit EscrowDisputed(escrowId, msg.sender);
    }

    // Alias for openDispute
    function dispute(uint256 escrowId) external {
        openDispute(escrowId);
    }

    // 16. If the client does nothing, only the freelancer can finalize the escrow after the review deadline.
    // Use the same payment and fee calculation as approval.
    function finalizeTimeout(uint256 escrowId) public {
        Escrow storage escrow = _getValidEscrow(escrowId);

        if (escrow.status != EscrowStatus.Status.Delivered) {
            revert InvalidStatus(escrow.status);
        }
        if (msg.sender != escrow.freelancer) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (block.timestamp <= escrow.reviewDeadline) {
            revert ReviewDeadlineNotPassed(escrow.reviewDeadline, block.timestamp);
        }

        // Uses the same settlement calculation and balance crediting as approval
        (uint256 freelancerPayout, uint256 platformFee) = _settle(escrow);

        emit EscrowTimeoutFinalized(escrowId, msg.sender, freelancerPayout, platformFee);
    }

    // Alias for finalizeTimeout
    function finalizeEscrow(uint256 escrowId) external {
        finalizeTimeout(escrowId);
    }

    // 17. After a dispute is opened, only the escrow's arbitrator can resolve it.
    // 18. The arbitrator supplies clientRefundBps from 0 to 10,000.
    // 19. Calculate the client's share from the original deposit. The remainder is the freelancer's gross share.
    // 20. Apply the platform fee only to the freelancer's gross share.
    function resolveDispute(uint256 escrowId, uint256 clientRefundBps) external {
        Escrow storage escrow = _getValidEscrow(escrowId);

        if (escrow.status != EscrowStatus.Status.Disputed) {
            revert InvalidStatus(escrow.status);
        }
        if (msg.sender != escrow.arbitrator) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (clientRefundBps > BPS_DENOMINATOR) {
            revert InvalidRefundBps(clientRefundBps, BPS_DENOMINATOR);
        }

        // 23. Dispute resolved once, cannot return to earlier status
        escrow.status = EscrowStatus.Status.Resolved;

        // 19 & 20: Calculate shares and fee using EscrowMath
        (uint256 clientShare, uint256 freelancerPayout, uint256 platformFee) =
            EscrowMath.calculateDisputeSplit(escrow.amount, clientRefundBps, platformFeeBps);

        // 21. Credit client, freelancer, and fee recipient balances scoped by token and user address
        // 22. For every settlement, all credited amounts combined must equal the original deposit:
        //     clientShare + freelancerPayout + platformFee == escrow.amount
        balances[escrow.token][escrow.client] += clientShare;
        balances[escrow.token][escrow.freelancer] += freelancerPayout;
        balances[escrow.token][feeRecipient] += platformFee;

        emit DisputeResolved(escrowId, msg.sender, clientShare, freelancerPayout, platformFee);
    }

    // 24. Users withdraw only their own available balance for the selected token.
    function withdraw(address token) external {
        if (token == address(0)) revert ZeroAddress();

        uint256 amount = balances[token][msg.sender];
        if (amount == 0) revert NoAvailableBalance();

        // 25. Reduce the available balance before calling the token contract (Checks-Effects-Interactions).
        balances[token][msg.sender] = 0;

        // 28. Emit event for withdrawal
        emit Withdrawal(token, msg.sender, amount);

        // 26. Revert if the token transfer fails.
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TokenTransferFailed();
    }

    function _getValidEscrow(uint256 escrowId) internal view returns (Escrow storage) {
        if (escrowId >= nextEscrowId) {
            revert UnknownEscrow(escrowId);
        }
        return escrows[escrowId];
    }

    function _settle(Escrow storage escrow) internal returns (uint256 freelancerPayout, uint256 platformFee) {
        // 23. Each escrow can be refunded or settled only once
        escrow.status = EscrowStatus.Status.Settled;

        (freelancerPayout, platformFee) = EscrowMath.calculateSettlement(escrow.amount, platformFeeBps);

        // 21. Credit balances scoped by token and user address
        // 22. freelancerPayout + platformFee == escrow.amount
        balances[escrow.token][escrow.freelancer] += freelancerPayout;
        balances[escrow.token][feeRecipient] += platformFee;
    }

    function getEscrow(uint256 escrowId) external view returns (Escrow memory) {
        return escrows[escrowId];
    }
}
