// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library EscrowStatus {
    enum Status {
        open,
        ongoing,
        finished,
        delivered,
        refunded
    }
}

library CalculationUtils {
    function calculatePlatformFee(uint256 _amount, uint256 _platformFee) internal pure returns (uint256) {
        return (_amount * _platformFee) / 100;
    }
}

interface IW3B {
    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

contract Escrows {
    IW3B public immutable token;

    uint256 public platformFee;

    address public owner;

    uint256 public platformBalance;

    struct Escrow {
        uint256 _amount;
        address client_address;
        address recepient_address;
        uint256 expiry_date;
        EscrowStatus.Status status;
    }

    constructor(uint256 _platformFee, address _token) {
        require(_platformFee <= 10, "Platformfee is already more than 10%");

        platformFee = _platformFee;

        token = IW3B(_token);

        owner = msg.sender;
    }

    uint256 public nextEscrowId;

    mapping(uint256 => Escrow) public escrows;

    mapping(address => uint256) public _receipientBalance;

    event EscrowCreated(address _address, address receipient_address, uint256 amount, uint256 expiry_date);

    event EscrowPaid(
        address _client_address, uint256 amount, uint256 platformoney, uint256 amountPaid, address receipient_address
    );

    event EscrowRefunded(address client_address, uint256 amount);

    event EscrowTaskStarted(address receipient_address, EscrowStatus.Status _status);

    event EscrowWithdrawal(address receipient_address, uint256 amount);

    event EscrowDelivered(uint256 _escrowId, EscrowStatus.Status _status);

    function createEscrow(uint256 _amount, address _receipient_address, uint256 _expiry_date)
        external
        returns (uint256 escrowId)
    {
        escrowId = nextEscrowId++;

        escrows[escrowId] = Escrow(_amount, msg.sender, _receipient_address, _expiry_date, EscrowStatus.Status.open);

        token.transferFrom(msg.sender, address(this), _amount);

        emit EscrowCreated(msg.sender, _receipient_address, _amount, _expiry_date);
    }

    function startTask(uint256 _escrowId) public {
        Escrow storage escrow = escrows[_escrowId];

        require(escrow.status != EscrowStatus.Status.ongoing, "Escrow has been started");

        require(escrow.status != EscrowStatus.Status.finished, "Escrow has been completed");

        require(escrow.status != EscrowStatus.Status.refunded, "Escrow has been refunded");

        require(escrow.expiry_date > block.timestamp, "Escrow has expired");

        require(escrow.recepient_address == msg.sender, "So sorry you were not assigned this task");

        escrow.status = EscrowStatus.Status.ongoing;

        emit EscrowTaskStarted(escrow.recepient_address, escrow.status);
    }

    function markDelivered(uint256 _escrowId) external {
        Escrow storage escrow = escrows[_escrowId];

        require(escrow.status == EscrowStatus.Status.ongoing, "The escrow task isn't ongoing");

        require(escrow.recepient_address == msg.sender, "You can't mark it delivered");

        escrow.status = EscrowStatus.Status.delivered;

        emit EscrowDelivered(_escrowId, EscrowStatus.Status.delivered);
    }

    function requestRefund(uint256 _escrowId) public {
        Escrow storage escrow = escrows[_escrowId];

        require(
            escrow.status == EscrowStatus.Status.open || escrow.status == EscrowStatus.Status.ongoing,
            "Escrow cannot be refunded"
        );

        require(escrow.expiry_date < block.timestamp, "Escrow has not expired yet");

        require(escrow.client_address == msg.sender, "Not assigned to this address");

        require(
            token.transfer(escrow.client_address, escrow._amount), "refund unsuccessful try again or check your network"
        );

        escrow.status = EscrowStatus.Status.refunded;

        emit EscrowRefunded(escrow.client_address, escrow._amount);
    }

    function approval(uint256 _escrowId) external {
        Escrow storage escrow = escrows[_escrowId];

        require(escrow.status == EscrowStatus.Status.delivered, "Escrow is not delivered yet");

        require(escrow.client_address == msg.sender, "You are not on this escrow please");

        escrow.status = EscrowStatus.Status.finished;

        payRecepient(escrow.recepient_address, escrow._amount, escrow.client_address);
    }

    function withdrawMoney() external {
        uint256 amountToSend = _receipientBalance[msg.sender];

        require(amountToSend > 0, "No balance to withdraw");

        require(token.transfer(msg.sender, amountToSend), "Unable to disburse out payment");

        _receipientBalance[msg.sender] = 0;

        emit EscrowWithdrawal(msg.sender, amountToSend);
    }

    function payRecepient(address _receipient_address, uint256 _amount, address client_address) private {
        uint256 platformMoney = CalculationUtils.calculatePlatformFee(_amount, platformFee);

        uint256 amountToSend = _amount - platformMoney;

        platformBalance += platformMoney;

        _receipientBalance[_receipient_address] += amountToSend;

        emit EscrowPaid(client_address, _amount, platformMoney, amountToSend, _receipient_address);
    }
}
