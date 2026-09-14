// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

library FeeMath {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function calculatePlatformFee(
        uint256 amount,
        uint256 feeBps
    ) internal pure returns (uint256) {
        return (amount * feeBps) / BPS_DENOMINATOR;
    }
}

library EscrowStatus {
    enum Status {
        None,
        Open,
        Ongoing,
        Delivered,
        Finished,
        Refunded
    }
}

contract Escrow {
    using FeeMath for uint256;

    uint256 public constant MAX_FEE_BPS = 1_000;

    IERC20 public immutable token;
    address public immutable owner;
    uint256 public immutable platformFeeBps;

    uint256 public nextEscrowId;
    uint256 public platformBalance;

    struct EscrowItem {
        address client;
        address freelancer;
        uint256 amount;
        uint256 deadline;
        EscrowStatus.Status status;
    }

    mapping(uint256 => EscrowItem) public escrows;

    mapping(address => uint256) public freelancerBalance;
    mapping(address => uint256) public ownerBalance;

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed client,
        address indexed freelancer,
        uint256 amount,
        uint256 deadline
    );

    event EscrowStarted(uint256 indexed escrowId, address indexed freelancer);
    event EscrowDelivered(uint256 indexed escrowId, address indexed freelancer);
    event EscrowApproved(uint256 indexed escrowId, address indexed client);
    event EscrowRefunded(uint256 indexed escrowId, address indexed client);

    event BalancesCredited(
        uint256 indexed escrowId,
        address indexed freelancer,
        uint256 freelancerAmount,
        uint256 platformFee
    );

    event Withdrawal(address indexed account, uint256 amount);

    modifier onlyClient(uint256 escrowId) {
        require(
            escrows[escrowId].client == msg.sender,
            "Escrow: not the client"
        );
        _;
    }

    modifier onlyFreelancer(uint256 escrowId) {
        require(
            escrows[escrowId].freelancer == msg.sender,
            "Escrow: not the freelancer"
        );
        _;
    }

    modifier inStatus(uint256 escrowId, EscrowStatus.Status expected) {
        require(
            escrows[escrowId].status == expected,
            "Escrow: invalid status for this action"
        );
        _;
    }

    constructor(uint256 _platformFeeBps, address _token) {
        require(_token != address(0), "Escrow: zero token address");
        require(
            _platformFeeBps <= MAX_FEE_BPS,
            "Escrow: fee exceeds 10% (1000 bps)"
        );

        platformFeeBps = _platformFeeBps;
        token = IERC20(_token);
        owner = msg.sender;
    }

    function createEscrow(
        address freelancer,
        uint256 amount,
        uint256 deadline
    ) public returns (uint256 escrowId) {
        require(freelancer != address(0), "Escrow: zero freelancer");
        require(
            freelancer != msg.sender,
            "Escrow: client cannot be freelancer"
        );
        require(amount > 0, "Escrow: zero amount");
        require(deadline > block.timestamp, "Escrow: deadline in the past");

        escrowId = nextEscrowId++;

        escrows[escrowId] = EscrowItem({
            client: msg.sender,
            freelancer: freelancer,
            amount: amount,
            deadline: deadline,
            status: EscrowStatus.Status.Open
        });

        emit EscrowCreated(escrowId, msg.sender, freelancer, amount, deadline);

        require(
            token.transferFrom(msg.sender, address(this), amount),
            "Escrow: funding transfer failed"
        );
    }

    function createEscrow(
        uint256 amount,
        address recipient,
        uint256 deadline
    ) external returns (uint256 escrowId) {
        return createEscrow(recipient, amount, deadline);
    }

    function startEscrow(
        uint256 escrowId
    )
        public
        onlyFreelancer(escrowId)
        inStatus(escrowId, EscrowStatus.Status.Open)
    {
        require(
            block.timestamp < escrows[escrowId].deadline,
            "Escrow: deadline passed"
        );

        escrows[escrowId].status = EscrowStatus.Status.Ongoing;

        emit EscrowStarted(escrowId, msg.sender);
    }

    function startTask(uint256 escrowId) external {
        startEscrow(escrowId);
    }

    function markDelivered(
        uint256 escrowId
    )
        external
        onlyFreelancer(escrowId)
        inStatus(escrowId, EscrowStatus.Status.Ongoing)
    {
        escrows[escrowId].status = EscrowStatus.Status.Delivered;

        emit EscrowDelivered(escrowId, msg.sender);
    }

    function approveEscrow(
        uint256 escrowId
    )
        public
        onlyClient(escrowId)
        inStatus(escrowId, EscrowStatus.Status.Delivered)
    {
        EscrowItem storage e = escrows[escrowId];

        uint256 fee = e.amount.calculatePlatformFee(platformFeeBps);
        uint256 payout = e.amount - fee;

        e.status = EscrowStatus.Status.Finished;

        freelancerBalance[e.freelancer] += payout;
        ownerBalance[owner] += fee;
        platformBalance += fee;

        emit BalancesCredited(escrowId, e.freelancer, payout, fee);
        emit EscrowApproved(escrowId, e.client);
    }

    function approval(uint256 escrowId) external {
        approveEscrow(escrowId);
    }

    function requestRefund(uint256 escrowId) external onlyClient(escrowId) {
        EscrowItem storage e = escrows[escrowId];

        require(
            e.status == EscrowStatus.Status.Open ||
                e.status == EscrowStatus.Status.Ongoing,
            "Escrow: cannot refund in current status"
        );
        require(
            block.timestamp >= e.deadline,
            "Escrow: deadline has not passed"
        );

        uint256 amount = e.amount;
        e.status = EscrowStatus.Status.Refunded;

        emit EscrowRefunded(escrowId, e.client);

        require(
            token.transfer(e.client, amount),
            "Escrow: refund transfer failed"
        );
    }

    function withdrawFreelancerBalance() public {
        uint256 amount = freelancerBalance[msg.sender];
        require(amount > 0, "Escrow: nothing to withdraw");

        freelancerBalance[msg.sender] = 0;

        emit Withdrawal(msg.sender, amount);

        require(
            token.transfer(msg.sender, amount),
            "Escrow: token transfer failed"
        );
    }

    function withdrawMoney() external {
        withdrawFreelancerBalance();
    }

    function withdrawOwnerBalance() external {
        require(msg.sender == owner, "Escrow: not the owner");

        uint256 amount = ownerBalance[owner];
        require(amount > 0, "Escrow: nothing to withdraw");

        ownerBalance[owner] = 0;
        platformBalance -= amount;

        emit Withdrawal(owner, amount);

        require(token.transfer(owner, amount), "Escrow: token transfer failed");
    }

    function getEscrow(
        uint256 escrowId
    ) external view returns (EscrowItem memory) {
        return escrows[escrowId];
    }
}

contract Escrows is Escrow {
    constructor(
        uint256 _platformFeeBps,
        address _token
    ) Escrow(_platformFeeBps, _token) {}
}
