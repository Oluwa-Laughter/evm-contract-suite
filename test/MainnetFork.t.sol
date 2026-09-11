// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MainnetFork, IERC20} from "../src/MainnetFork.sol";

contract MainnetForkTest is Test {
    MainnetFork public mainnetFork;

    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant PAIR = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852;
    address constant WHALE = 0x28C6c06298d514Db089934071355E5743bf21d60;

    address user = address(0xAa11bb22cC33dD44Ee55fF66aA77bb88cC99DD00);

    function setUp() public {
        string memory rpcUrl = vm.envOr(
            "MAINNET_RPC_URL",
            string("https://eth.drpc.org")
        );
        vm.createSelectFork(rpcUrl, 25_949_200);

        mainnetFork = new MainnetFork();

        vm.startPrank(WHALE);
        IERC20(WETH).transfer(user, 10 ether);
        IERC20(USDT).transfer(user, 30_000 * 1e6);
        vm.stopPrank();
    }

    function testSwapUsdtForWeth() public {
        uint256 usdtIn = 2_000 * 1e6;
        uint256 wethBefore = IERC20(WETH).balanceOf(user);

        vm.startPrank(user);
        IERC20(USDT).approve(address(mainnetFork), usdtIn);
        uint256 wethOut = mainnetFork.swapUsdtForWeth(
            usdtIn,
            1,
            user,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        console.log("USDT sent:", usdtIn);
        console.log("WETH received:", wethOut);

        assertGt(wethOut, 0);
        assertEq(IERC20(WETH).balanceOf(user), wethBefore + wethOut);
    }

    function testAddUsdtWethLiquidity() public {
        uint256 usdtDesired = 5_000 * 1e6;
        uint256 wethDesired = 2 ether;

        vm.startPrank(user);
        IERC20(USDT).approve(address(mainnetFork), usdtDesired);
        IERC20(WETH).approve(address(mainnetFork), wethDesired);

        (uint256 usdtUsed, uint256 wethUsed, uint256 lpTokens) = mainnetFork
            .addUsdtWethLiquidity(
                usdtDesired,
                wethDesired,
                1,
                1,
                user,
                block.timestamp + 1 hours
            );
        vm.stopPrank();

        console.log("USDT deposited:", usdtUsed);
        console.log("WETH deposited:", wethUsed);
        console.log("LP tokens received:", lpTokens);

        assertGt(lpTokens, 0);
        assertEq(IERC20(PAIR).balanceOf(user), lpTokens);
    }
}
