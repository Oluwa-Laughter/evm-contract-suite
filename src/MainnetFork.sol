// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external;
    function transferFrom(address from, address to, uint256 amount) external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

contract MainnetFork {
    address public constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IUniswapV2Router02 private immutable router;

    constructor() {
        router = IUniswapV2Router02(ROUTER);
    }

    function swapUsdtForWeth(
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        // 1. Pull USDT from caller
        IERC20(USDT).transferFrom(msg.sender, address(this), amountIn);

        // 2. Approve router (reset to 0 first — USDT requires this)
        IERC20(USDT).approve(address(router), 0);
        IERC20(USDT).approve(address(router), amountIn);

        // 3. Build path and swap
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = WETH;

        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            recipient,
            deadline
        );

        amountOut = amounts[1];
    }

    function addUsdtWethLiquidity(
        uint256 amountUsdtDesired,
        uint256 amountWethDesired,
        uint256 amountUsdtMin,
        uint256 amountWethMin,
        address recipient,
        uint256 deadline
    )
        external
        returns (uint256 amountUsdt, uint256 amountWeth, uint256 liquidity)
    {
        // 1. Pull both tokens from caller
        IERC20(USDT).transferFrom(msg.sender, address(this), amountUsdtDesired);
        IERC20(WETH).transferFrom(msg.sender, address(this), amountWethDesired);

        // 2. Approve router (reset USDT to 0 first)
        IERC20(USDT).approve(address(router), 0);
        IERC20(USDT).approve(address(router), amountUsdtDesired);
        IERC20(WETH).approve(address(router), amountWethDesired);

        // 3. Add liquidity
        (amountUsdt, amountWeth, liquidity) = router.addLiquidity(
            USDT,
            WETH,
            amountUsdtDesired,
            amountWethDesired,
            amountUsdtMin,
            amountWethMin,
            recipient,
            deadline
        );

        // 4. Refund unused tokens
        if (amountUsdtDesired > amountUsdt) {
            IERC20(USDT).transfer(msg.sender, amountUsdtDesired - amountUsdt);
        }
        if (amountWethDesired > amountWeth) {
            IERC20(WETH).transfer(msg.sender, amountWethDesired - amountWeth);
        }
    }
}
