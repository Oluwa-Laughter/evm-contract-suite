// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EscrowMoreFeatures, EscrowStatus, IERC20} from "../src/EscrowMoreFeatures.sol";

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract EscrowMoreFeaturesTest is Test {
    EscrowMoreFeatures public escrow;
    MockERC20 public token;

    address public feeRecipient = address(0x100);
    address public client = address(0x200);
    address public freelancer = address(0x300);
    address public arbitrator = address(0x400);

    uint256 public constant PLATFORM_FEE_BPS = 500; // 5%
    uint256 public constant REVIEW_PERIOD = 3 days;
    uint256 public constant ESCROW_AMOUNT = 1_000 ether;

    function setUp() public {
        token = new MockERC20();
        escrow = new EscrowMoreFeatures(
            feeRecipient,
            PLATFORM_FEE_BPS,
            REVIEW_PERIOD
        );

        token.mint(client, 10_000 ether);

        vm.prank(client);
        token.approve(address(escrow), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Deployment Tests
    // -------------------------------------------------------------------------
    function test_DeploymentSuccess() public view {
        assertEq(escrow.feeRecipient(), feeRecipient);
        assertEq(escrow.platformFeeBps(), PLATFORM_FEE_BPS);
        assertEq(escrow.reviewPeriod(), REVIEW_PERIOD);
        assertEq(escrow.nextEscrowId(), 0);
    }

    function test_DeploymentRevertZeroFeeRecipient() public {
        vm.expectRevert(EscrowMoreFeatures.ZeroAddress.selector);
        new EscrowMoreFeatures(address(0), PLATFORM_FEE_BPS, REVIEW_PERIOD);
    }

    function test_DeploymentRevertExcessiveFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.FeeExceedsMax.selector, 1001, 1000
            )
        );
        new EscrowMoreFeatures(feeRecipient, 1001, REVIEW_PERIOD);
    }

    function test_DeploymentRevertZeroReviewPeriod() public {
        vm.expectRevert(EscrowMoreFeatures.ZeroReviewPeriod.selector);
        new EscrowMoreFeatures(feeRecipient, PLATFORM_FEE_BPS, 0);
    }

    // -------------------------------------------------------------------------
    // Escrow Creation Tests
    // -------------------------------------------------------------------------
    function test_CreateEscrowSuccess() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;

        vm.prank(client);
        uint256 id = escrow.createEscrow(
            freelancer,
            arbitrator,
            address(token),
            ESCROW_AMOUNT,
            deliveryDeadline
        );

        assertEq(id, 0);
        assertEq(escrow.nextEscrowId(), 1);
        assertEq(token.balanceOf(address(escrow)), ESCROW_AMOUNT);

        EscrowMoreFeatures.Escrow memory e = escrow.getEscrow(id);
        assertEq(e.client, client);
        assertEq(e.freelancer, freelancer);
        assertEq(e.arbitrator, arbitrator);
        assertEq(e.token, address(token));
        assertEq(e.amount, ESCROW_AMOUNT);
        assertEq(e.deliveryDeadline, deliveryDeadline);
        assertEq(e.reviewDeadline, 0);
        assertEq(uint8(e.status), uint8(EscrowStatus.Status.Open));
    }

    function test_CreateEscrowRevertZeroAddresses() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;

        vm.startPrank(client);
        vm.expectRevert(EscrowMoreFeatures.ZeroAddress.selector);
        escrow.createEscrow(address(0), arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.expectRevert(EscrowMoreFeatures.ZeroAddress.selector);
        escrow.createEscrow(freelancer, address(0), address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.expectRevert(EscrowMoreFeatures.ZeroAddress.selector);
        escrow.createEscrow(freelancer, arbitrator, address(0), ESCROW_AMOUNT, deliveryDeadline);
        vm.stopPrank();
    }

    function test_CreateEscrowRevertZeroAmount() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        vm.expectRevert(EscrowMoreFeatures.ZeroAmount.selector);
        escrow.createEscrow(freelancer, arbitrator, address(token), 0, deliveryDeadline);
    }

    function test_CreateEscrowRevertPastDeadline() public {
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.DeliveryDeadlineMustBeInFuture.selector,
                block.timestamp,
                block.timestamp
            )
        );
        escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, block.timestamp);
    }

    function test_CreateEscrowRevertSameAddresses() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;

        vm.startPrank(client);
        vm.expectRevert(EscrowMoreFeatures.PartiesMustBeDistinct.selector);
        escrow.createEscrow(client, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.expectRevert(EscrowMoreFeatures.PartiesMustBeDistinct.selector);
        escrow.createEscrow(freelancer, client, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.expectRevert(EscrowMoreFeatures.PartiesMustBeDistinct.selector);
        escrow.createEscrow(freelancer, freelancer, address(token), ESCROW_AMOUNT, deliveryDeadline);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Delivery Tests
    // -------------------------------------------------------------------------
    function test_MarkDeliveredSuccess() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        uint256 id = escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.warp(block.timestamp + 2 days);
        vm.prank(freelancer);
        escrow.markDelivered(id);

        EscrowMoreFeatures.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(EscrowStatus.Status.Delivered));
        assertEq(e.reviewDeadline, block.timestamp + REVIEW_PERIOD);
    }

    function test_MarkDeliveredRevertNonFreelancer() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        uint256 id = escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.UnauthorizedCaller.selector,
                client
            )
        );
        escrow.markDelivered(id);
    }

    function test_MarkDeliveredRevertPastDeliveryDeadline() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        uint256 id = escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.warp(deliveryDeadline + 1);
        vm.prank(freelancer);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.DeliveryDeadlinePassed.selector,
                deliveryDeadline,
                deliveryDeadline + 1
            )
        );
        escrow.markDelivered(id);
    }

    // -------------------------------------------------------------------------
    // Refund Tests
    // -------------------------------------------------------------------------
    function test_RefundSuccessAfterDeadline() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        uint256 id = escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        // Before deadline -> reverts
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.DeliveryDeadlineNotPassed.selector,
                deliveryDeadline,
                block.timestamp
            )
        );
        escrow.requestRefund(id);

        // Warp after deadline
        vm.warp(deliveryDeadline + 1);

        // Non-client cannot refund
        vm.prank(freelancer);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.UnauthorizedCaller.selector,
                freelancer
            )
        );
        escrow.requestRefund(id);

        // Client refunds
        vm.prank(client);
        escrow.requestRefund(id);

        assertEq(escrow.balances(address(token), client), ESCROW_AMOUNT);
        EscrowMoreFeatures.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(EscrowStatus.Status.Refunded));

        // Withdraw refund
        uint256 clientBalBefore = token.balanceOf(client);
        vm.prank(client);
        escrow.withdraw(address(token));
        assertEq(token.balanceOf(client), clientBalBefore + ESCROW_AMOUNT);
        assertEq(escrow.balances(address(token), client), 0);
    }

    function test_RefundRevertIfDelivered() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        uint256 id = escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.prank(freelancer);
        escrow.markDelivered(id);

        vm.warp(deliveryDeadline + 1);
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.InvalidStatus.selector,
                EscrowStatus.Status.Delivered
            )
        );
        escrow.requestRefund(id);
    }

    // -------------------------------------------------------------------------
    // Approval Tests
    // -------------------------------------------------------------------------
    function test_ApproveDeliverySuccess() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        uint256 id = escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.prank(freelancer);
        escrow.markDelivered(id);

        // Fee is 5% = 50 ether; Freelancer gets 950 ether
        uint256 expectedFee = (ESCROW_AMOUNT * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedPayout = ESCROW_AMOUNT - expectedFee;

        vm.prank(client);
        escrow.approveDelivery(id);

        assertEq(escrow.balances(address(token), freelancer), expectedPayout);
        assertEq(escrow.balances(address(token), feeRecipient), expectedFee);

        // Total credited equals deposit exactly
        assertEq(expectedPayout + expectedFee, ESCROW_AMOUNT);

        // Freelancer withdraws
        vm.prank(freelancer);
        escrow.withdraw(address(token));
        assertEq(token.balanceOf(freelancer), expectedPayout);

        // Fee recipient withdraws
        vm.prank(feeRecipient);
        escrow.withdraw(address(token));
        assertEq(token.balanceOf(feeRecipient), expectedFee);
    }

    function test_ApproveDeliveryRevertPastReviewDeadline() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        uint256 id = escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.prank(freelancer);
        escrow.markDelivered(id);

        EscrowMoreFeatures.Escrow memory e = escrow.getEscrow(id);
        vm.warp(e.reviewDeadline + 1);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.ReviewDeadlinePassed.selector,
                e.reviewDeadline,
                e.reviewDeadline + 1
            )
        );
        escrow.approveDelivery(id);
    }

    // -------------------------------------------------------------------------
    // Timeout Finalization Tests
    // -------------------------------------------------------------------------
    function test_FinalizeTimeoutSuccess() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        uint256 id = escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.prank(freelancer);
        escrow.markDelivered(id);

        EscrowMoreFeatures.Escrow memory e = escrow.getEscrow(id);

        // Before review deadline -> reverts
        vm.prank(freelancer);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.ReviewDeadlineNotPassed.selector,
                e.reviewDeadline,
                block.timestamp
            )
        );
        escrow.finalizeTimeout(id);

        // Warp past review deadline
        vm.warp(e.reviewDeadline + 1);

        // Non-freelancer reverts
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.UnauthorizedCaller.selector,
                client
            )
        );
        escrow.finalizeTimeout(id);

        // Freelancer finalizes
        vm.prank(freelancer);
        escrow.finalizeTimeout(id);

        uint256 expectedFee = (ESCROW_AMOUNT * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedPayout = ESCROW_AMOUNT - expectedFee;

        assertEq(escrow.balances(address(token), freelancer), expectedPayout);
        assertEq(escrow.balances(address(token), feeRecipient), expectedFee);
    }

    // -------------------------------------------------------------------------
    // Dispute & Resolution Tests
    // -------------------------------------------------------------------------
    function test_DisputeAndResolutionSuccess() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        uint256 id = escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.prank(freelancer);
        escrow.markDelivered(id);

        // Client opens dispute
        vm.prank(client);
        escrow.openDispute(id);

        EscrowMoreFeatures.Escrow memory e = escrow.getEscrow(id);
        assertEq(uint8(e.status), uint8(EscrowStatus.Status.Disputed));

        // Non-arbitrator cannot resolve
        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.UnauthorizedCaller.selector,
                client
            )
        );
        escrow.resolveDispute(id, 4_000);

        // Invalid refund bps > 10,000 reverts
        vm.prank(arbitrator);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.InvalidRefundBps.selector,
                10_001,
                10_000
            )
        );
        escrow.resolveDispute(id, 10_001);

        // Arbitrator awards 40% refund to client (4000 bps)
        // Client gets: 1000 * 40% = 400 ether
        // Freelancer gross: 1000 - 400 = 600 ether
        // Platform fee: 600 * 5% = 30 ether
        // Freelancer net payout: 600 - 30 = 570 ether
        // Total credited: 400 + 30 + 570 = 1000 ether (EXACT!)
        uint256 clientRefundBps = 4_000;
        uint256 expectedClient = (ESCROW_AMOUNT * clientRefundBps) / 10_000; // 400
        uint256 freelancerGross = ESCROW_AMOUNT - expectedClient; // 600
        uint256 expectedFee = (freelancerGross * PLATFORM_FEE_BPS) / 10_000; // 30
        uint256 expectedFreelancer = freelancerGross - expectedFee; // 570

        vm.prank(arbitrator);
        escrow.resolveDispute(id, clientRefundBps);

        assertEq(escrow.balances(address(token), client), expectedClient);
        assertEq(escrow.balances(address(token), freelancer), expectedFreelancer);
        assertEq(escrow.balances(address(token), feeRecipient), expectedFee);
        assertEq(expectedClient + expectedFreelancer + expectedFee, ESCROW_AMOUNT);

        // Escrow cannot be settled or resolved again
        vm.prank(arbitrator);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowMoreFeatures.InvalidStatus.selector,
                EscrowStatus.Status.Resolved
            )
        );
        escrow.resolveDispute(id, clientRefundBps);
    }

    function test_DisputeFullClientRefund() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        uint256 id = escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.prank(freelancer);
        escrow.markDelivered(id);

        vm.prank(client);
        escrow.openDispute(id);

        // 100% refund to client
        vm.prank(arbitrator);
        escrow.resolveDispute(id, 10_000);

        assertEq(escrow.balances(address(token), client), ESCROW_AMOUNT);
        assertEq(escrow.balances(address(token), freelancer), 0);
        assertEq(escrow.balances(address(token), feeRecipient), 0);
    }

    function test_DisputeZeroClientRefund() public {
        uint256 deliveryDeadline = block.timestamp + 7 days;
        vm.prank(client);
        uint256 id = escrow.createEscrow(freelancer, arbitrator, address(token), ESCROW_AMOUNT, deliveryDeadline);

        vm.prank(freelancer);
        escrow.markDelivered(id);

        vm.prank(client);
        escrow.openDispute(id);

        // 0% refund to client (freelancer gets full settlement)
        vm.prank(arbitrator);
        escrow.resolveDispute(id, 0);

        uint256 expectedFee = (ESCROW_AMOUNT * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedFreelancer = ESCROW_AMOUNT - expectedFee;

        assertEq(escrow.balances(address(token), client), 0);
        assertEq(escrow.balances(address(token), freelancer), expectedFreelancer);
        assertEq(escrow.balances(address(token), feeRecipient), expectedFee);
        assertEq(expectedFreelancer + expectedFee, ESCROW_AMOUNT);
    }

    // -------------------------------------------------------------------------
    // Withdrawal Tests
    // -------------------------------------------------------------------------
    function test_WithdrawRevertZeroBalance() public {
        vm.prank(freelancer);
        vm.expectRevert(EscrowMoreFeatures.NoAvailableBalance.selector);
        escrow.withdraw(address(token));
    }
}
