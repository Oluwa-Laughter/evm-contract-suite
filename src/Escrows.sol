// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* -------------------------------------------------------------------------- */
/*                         Inline ERC-20 interface                            */
/* -------------------------------------------------------------------------- */

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/* -------------------------------------------------------------------------- */
/*                       Fee calculation library                              */
/* -------------------------------------------------------------------------- */

library FeeMath {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Returns `feeBps` of `amount`, where `feeBps` is in basis points.
    function calculatePlatformFee(uint256 amount, uint256 feeBps) internal pure returns (uint256) {
        return (amount * feeBps) / BPS_DENOMINATOR;
    }
}

/* -------------------------------------------------------------------------- */
/*                              Escrow status                                 */
/* -------------------------------------------------------------------------- */

library EscrowStatus {
    enum Status {
        None, // default / not initialised
        Open, // created and funded, not yet started
        Ongoing, // freelancer has accepted and is working
        Delivered, // freelancer marked work as delivered
        Finished, // client approved, balances credited
        Refunded // client refunded after deadline
    }
}

/* -------------------------------------------------------------------------- */
/*                                Escrow core                                 */
/* -------------------------------------------------------------------------- */

contract Escrows {
    using FeeMath for uint256;

    /* ----------------------------- Constants ------------------------------ */

    uint256 public constant MAX_FEE_BPS = 1_000; // 10%

    /* ----------------------------- Immutables ----------------------------- */

    IERC20 public immutable token;

    /* ------------------------------- Storage ------------------------------ */

    uint256 public platformFeeBps; // set once in constructor (basis points)

    address public immutable owner;

    uint256 public nextEscrowId;

    uint256 public platformBalance;

    struct Escrow {
        address client;
        address freelancer;
        uint256 amount;
        uint256 deadline;
        EscrowStatus.Status status;
    }

    mapping(uint256 => Escrow) public escrows;

    // Internal accounting per user; only withdrawable by the user themself.
    mapping(address => uint256) public freelancerBalance;
    mapping(address => uint256) public ownerBalance;

    /* -------------------------------- Events ------------------------------ */

    event EscrowCreated(
        uint256 indexed escrowId, address indexed client, address indexed freelancer, uint256 amount, uint256 deadline
    );

    event EscrowStarted(uint256 indexed escrowId, address indexed freelancer);
    event EscrowDelivered(uint256 indexed escrowId, address indexed freelancer);
    event EscrowApproved(uint256 indexed escrowId, address indexed client);
    event EscrowRefunded(uint256 indexed escrowId, address indexed client);

    event BalancesCredited(
        uint256 indexed escrowId, address indexed freelancer, uint256 freelancerAmount, uint256 platformFee
    );

    event Withdrawal(address indexed account, uint256 amount);

    /* ------------------------------ Modifiers ----------------------------- */

    modifier onlyClient(uint256 escrowId) {
        require(escrows[escrowId].client == msg.sender, "Escrows: not the client");
        _;
    }

    modifier onlyFreelancer(uint256 escrowId) {
        require(escrows[escrowId].freelancer == msg.sender, "Escrows: not the freelancer");
        _;
    }

    modifier inStatus(uint256 escrowId, EscrowStatus.Status expected) {
        require(escrows[escrowId].status == expected, "Escrows: invalid status for this action");
        _;
    }

    /* ----------------------------- Constructor ---------------------------- */

    /// @param _platformFeeBps Fee in basis points (1 = 0.01%, 100 = 1%, 1000 = 10%).
    /// @param _token Address of the ERC-20 token used for payments.
    constructor(uint256 _platformFeeBps, address _token) {
        require(_token != address(0), "Escrows: zero token address");
        require(_platformFeeBps <= MAX_FEE_BPS, "Escrows: fee exceeds 10% (1000 bps)");

        platformFeeBps = _platformFeeBps;
        token = IERC20(_token);
        owner = msg.sender;
    }

    /* ============================ External API ============================ */

    /// @notice Client creates and funds a new escrow.
    /// @param freelancer Address that will receive payment on approval.
    /// @param amount      Token amount to escrow.
    /// @param deadline    Unix timestamp after which the client may refund.
    /// @return escrowId   Unique id for the created escrow.
    function createEscrow(address freelancer, uint256 amount, uint256 deadline) external returns (uint256 escrowId) {
        require(freelancer != address(0), "Escrows: zero freelancer");
        require(freelancer != msg.sender, "Escrows: client is freelancer");
        require(amount > 0, "Escrows: zero amount");
        require(deadline > block.timestamp, "Escrows: deadline in the past");

        escrowId = nextEscrowId++;

        escrows[escrowId] = Escrow({
            client: msg.sender,
            freelancer: freelancer,
            amount: amount,
            deadline: deadline,
            status: EscrowStatus.Status.Open
        });

        require(token.transferFrom(msg.sender, address(this), amount), "Escrows: funding transfer failed");

        emit EscrowCreated(escrowId, msg.sender, freelancer, amount, deadline);
    }

    /// @notice Freelancer acknowledges the work and moves the escrow to Ongoing.
    function startEscrow(uint256 escrowId)
        external
        onlyFreelancer(escrowId)
        inStatus(escrowId, EscrowStatus.Status.Open)
    {
        require(block.timestamp < escrows[escrowId].deadline, "Escrows: deadline passed");

        escrows[escrowId].status = EscrowStatus.Status.Ongoing;

        emit EscrowStarted(escrowId, msg.sender);
    }

    /// @notice Freelancer marks the work as delivered.
    function markDelivered(uint256 escrowId)
        external
        onlyFreelancer(escrowId)
        inStatus(escrowId, EscrowStatus.Status.Ongoing)
    {
        escrows[escrowId].status = EscrowStatus.Status.Delivered;

        emit EscrowDelivered(escrowId, msg.sender);
    }

    /// @notice Client approves the delivered work; splits and credits balances.
    function approveEscrow(uint256 escrowId)
        external
        onlyClient(escrowId)
        inStatus(escrowId, EscrowStatus.Status.Delivered)
    {
        Escrow storage e = escrows[escrowId];

        uint256 fee = e.amount.calculatePlatformFee(platformFeeBps);
        uint256 payout = e.amount - fee;

        e.status = EscrowStatus.Status.Finished;

        freelancerBalance[e.freelancer] += payout;
        ownerBalance[owner] += fee;
        platformBalance += fee;

        emit BalancesCredited(escrowId, e.freelancer, payout, fee);
        emit EscrowApproved(escrowId, e.client);
    }

    /// @notice Client refunds themselves if the deadline passed before delivery.
    function requestRefund(uint256 escrowId) external onlyClient(escrowId) {
        Escrow storage e = escrows[escrowId];

        require(
            e.status == EscrowStatus.Status.Open || e.status == EscrowStatus.Status.Ongoing,
            "Escrows: cannot refund in current status"
        );
        require(block.timestamp >= e.deadline, "Escrows: deadline has not passed");

        uint256 amount = e.amount;
        e.status = EscrowStatus.Status.Refunded;

        require(token.transfer(e.client, amount), "Escrows: refund transfer failed");

        emit EscrowRefunded(escrowId, e.client);
    }

    /// @notice Withdraw the caller's accumulated freelancer balance.
    function withdrawFreelancerBalance() external {
        uint256 amount = freelancerBalance[msg.sender];
        require(amount > 0, "Escrows: nothing to withdraw");

        // Effects first to prevent re-entrancy draining more than credited.
        freelancerBalance[msg.sender] = 0;

        require(token.transfer(msg.sender, amount), "Escrows: token transfer failed");

        emit Withdrawal(msg.sender, amount);
    }

    /// @notice Withdraw the owner's accumulated platform-fee balance.
    function withdrawOwnerBalance() external {
        require(msg.sender == owner, "Escrows: not the owner");

        uint256 amount = ownerBalance[owner];
        require(amount > 0, "Escrows: nothing to withdraw");

        ownerBalance[owner] = 0;
        platformBalance -= amount;

        require(token.transfer(owner, amount), "Escrows: token transfer failed");

        emit Withdrawal(owner, amount);
    }

    /* ============================== Views ================================= */

    function getEscrow(uint256 escrowId) external view returns (Escrow memory) {
        return escrows[escrowId];
    }
}
