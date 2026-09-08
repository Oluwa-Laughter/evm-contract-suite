// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract W3B {
    string public name;
    string public symbol;
    address public owner;
    uint256 public totalSupply;
    uint256 public decimal;

    // uint256 public totalStake;

    error NoAddressZero();

    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;
    // mapping(address => uint256) public stakes;

    event OwnerShipTransferred(address previousOwner, address newOwner);
    event Transfer(address sender, address receiver, uint256 amount);
    event Approval(address owner, address spender, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(string memory _name, string memory _symbol, uint256 _decimal) {
        name = _name;
        symbol = _symbol;
        decimal = _decimal;
        owner = msg.sender;

        emit OwnerShipTransferred(address(0), owner);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount,
        bool _mint
    ) internal {
        if (to == address(0)) revert NoAddressZero();

        if (!_mint) {
            require(balances[from] >= amount, "Insufficient balance");

            balances[from] -= amount;
        }

        balances[to] += amount;

        emit Transfer(from, to, amount);
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount, false);
    }

    function approve(address spender, uint256 amount) external {
        allowances[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(allowances[from][msg.sender] >= amount, "Not enough allowance");

        allowances[from][msg.sender] -= amount;

        _transfer(from, to, amount, false);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _transfer(address(0), to, amount, true);

        totalSupply += amount;
    }

    function burnToken(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");

        balances[msg.sender] -= amount;
        totalSupply -= amount;

        emit Transfer(msg.sender, address(0), amount);
    }

    // function stake(uint256 amount) external {
    //     require(amount > 0, "Amount must be greater than zero");

    //     require(balances[msg.sender] >= amount, "Insufficient balance");

    //     balances[msg.sender] -= amount;
    //     stakes[msg.sender] += amount;
    //     totalStake += amount;
    // }

    // function rewardStake(address _staker, uint256 amount) external onlyOwner {
    //     require(_staker != address(0), "Invalid address");
    //     require(stakes[_staker] > 0, "Not a staker");
    //     require(amount > 0, "Reward must be greater than zero");

    //     balances[_staker] += amount;
    //     totalSupply += amount;

    //     emit Transfer(address(0), _staker, amount);
    // }

    // function unstake(uint256 amount) external {
    //     require(amount > 0, "Amount must be greater than zero");

    //     require(stakes[msg.sender] >= amount, "Insufficient staked balance");

    //     stakes[msg.sender] -= amount;
    //     balances[msg.sender] += amount;
    //     totalStake -= amount;
    // }
}

// A simple external staking contract that uses your existing erc20 token contract for staking...
// in this case move your staking logic to another contract...
// the staking contract interacts with your token contract using low level calls to call
// the transfer or transferFrom or balanceOf ... depends on what you want

contract StakingContract {
    address public token;

    uint256 public totalStake;

    mapping(address => uint256) public stakes;

    constructor(address _W3B) {
        token = _W3B;
    }

    function stake(uint256 amount) external {
        require(amount > 0, "Amount must be greater than zero");

        (bool success, ) = token.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                msg.sender,
                address(this),
                amount
            )
        );

        require(success, "Transfer failed");

        stakes[msg.sender] += amount;
        totalStake += amount;
    }

    function unstake(uint256 amount) external {
        require(amount > 0, "Amount must be greater than zero");
        require(stakes[msg.sender] >= amount, "Insufficient staked balance");

        (bool success, ) = token.call(
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                msg.sender,
                amount
            )
        );

        require(success, "Transfer failed");

        stakes[msg.sender] -= amount;
        totalStake -= amount;
    }
}
