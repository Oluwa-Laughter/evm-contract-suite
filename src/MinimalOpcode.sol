//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MinimalOpcode {
    function store(uint256 value) external {
        assembly {
            sstore(0, value)
        }
    }

    function load() external view returns (uint256 value) {
        assembly {
            value := sload(0)
        }
    }

    function deployAndCall() external returns (address child, uint256 result) {
        assembly {
            mstore(10, 0x600a600c600039600a6000f3602a60005260206000f3)
            child := create(0, 10, 22)
            if iszero(child) {
                revert(0, 0)
            }
            if iszero(call(100000, child, 0, 0, 0, 0, 32)) {
                revert(0, 0)
            }
            result := mload(0)
        }
    }
}
