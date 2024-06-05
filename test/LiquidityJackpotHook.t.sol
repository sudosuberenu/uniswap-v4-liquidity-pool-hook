// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry libraries
import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Our contracts
import {LiquidityJackpotHook} from "../src/LiquidityJackpotHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

import "forge-std/console.sol";


contract LiquidityJackpotHookTest is Test, Deployers {
    // Use the libraries
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;

    LiquidityJackpotHook hook;

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        address hookAddress = address(uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_DONATE_FLAG |
            Hooks.AFTER_DONATE_FLAG
            ));

        deployCodeTo("LiquidityJackpotHook.sol", abi.encode(manager, "Liquidity Position Token", "LIQPOS_TOKEN"), hookAddress);
        hook = LiquidityJackpotHook(hookAddress);



        // Initialize a pool with these two tokens
        uint24 fee = 3000;
        (key, ) = initPool(
            token0,
            token1,
            hook,
            fee,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // Add initial liquidity to the pool
        // Some liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10,
                salt: 0
            }),
            ZERO_BYTES
        );

        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10,
                salt: 0
            }),
            ZERO_BYTES
        );

        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function test_placeOrder_long() public {
        // Set up initial conditions
        bool isLong = true;
        uint128 inputLiquidityAmount = 30;
        uint256 currency0Amount = 1 ether;

        // Place the order
        uint128 orderLiquidityAmount = hook.placeOrder{value: currency0Amount}(key, isLong);

        assertEq(orderLiquidityAmount, inputLiquidityAmount);

        // Check the balance of ERC-1155 tokens we received
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);
        uint256 positionId = hook.getPositionId(key, currency0Amount, isLong, inputLiquidityAmount, nextExecutionTime);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);

        assertTrue(positionId != 0);
        assertEq(tokenBalance, currency0Amount);
    }

    function test_placeOrder_short() public {
        // Set up initial conditions
        bool isLong = false;
        uint128 inputLiquidityAmount = 30;
        uint256 currency0Amount = 1 ether;

        // Place the order
        uint256 balanceBeforeOrder = address(this).balance;
        uint128 orderLiquidityAmount = hook.placeOrder{value: currency0Amount}(key, isLong);
        uint256 balanceAfterOrder = address(this).balance;

        assertEq(balanceBeforeOrder - balanceAfterOrder, currency0Amount);
        assertEq(orderLiquidityAmount, inputLiquidityAmount);
        assertEq(address(hook).balance, currency0Amount);

        // Check the balance of ERC-1155 tokens we received
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);
        uint256 positionId = hook.getPositionId(key, currency0Amount, isLong, inputLiquidityAmount, nextExecutionTime);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        uint256 currentJackpotAmount = hook.getJackpotAmount(key, nextExecutionTime);

        assertTrue(positionId != 0);
        assertEq(tokenBalance, currency0Amount);
        assertEq(currentJackpotAmount, currency0Amount);
    }

    function test_checkJackpot_success() public {
        // Set up initial conditions
        uint256 currency0Amount = 1 ether;
        bool isLong = true;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);

        // Place the Long order
        hook.placeOrder{value: currency0Amount}(key, isLong);

        vm.warp(block.timestamp + 30 hours);
        
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ''
        );

        uint256 afterExecutionTime = hook.getNextExecutionTime(key);
        uint256 jackpotAmount = hook.getJackpotAmount(key, nextExecutionTime);
        uint128 jackpotLiquidity = hook.getJackpotLiquidity(key, nextExecutionTime);

        assertEq(nextExecutionTime + 24 hours, afterExecutionTime);
        assertEq(jackpotAmount, currency0Amount);
        assertEq(jackpotLiquidity, 30);
    }

    function test_redeem_success() public {
        // Set up initial conditions
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 30 ether;
        bool isLong = true;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);
        uint256 inputAmountToClaimFor = 1 ether;

        // Place the order
        uint256 currentBeforeBalance = address(this).balance;

        uint128 orderLiquidityAmount = hook.placeOrder{value: currency0Amount}(key, isLong);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10,
                salt: 0
            }),
            ZERO_BYTES
        );

        vm.warp(block.timestamp + 30 hours);

        // Redeem the order
        hook.redeem(key, currency0Amount, orderLiquidityAmount, isLong, nextExecutionTime, inputAmountToClaimFor);

        uint256 positionId = hook.getPositionId(key, currency0Amount, isLong, inputLiquidityAmount, nextExecutionTime);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        uint256 currentAfterBalance = address(this).balance;

        assertTrue(positionId != 0);
        assertEq(tokenBalance, 0);
        assertEq(currentBeforeBalance, currentAfterBalance);
    }

    function test_redeem_jackpotNoLiquidity_NothingToClaim() public {
        // Set up initial conditions
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 10 ether;
        bool isLong = true;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);
        uint256 inputAmountToClaimFor = 1 ether;
        
        hook.placeOrder{value: currency0Amount}(key, isLong);

        vm.expectRevert(LiquidityJackpotHook.NothingToClaim.selector);

        hook.redeem(key, currency0Amount, inputLiquidityAmount, isLong, nextExecutionTime, inputAmountToClaimFor);
    }

    function test_redeem_jackpotNotExecuted_NothingToClaim() public {
        // Set up initial conditions
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 10 ether;
        bool isLong = true;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);
        uint256 inputAmountToClaimFor = 1 ether;

        vm.expectRevert(LiquidityJackpotHook.NothingToClaim.selector);

        hook.redeem(key, currency0Amount, inputLiquidityAmount, isLong, nextExecutionTime, inputAmountToClaimFor);
    }

    function test_redeem_notEnoughFunds_NotEnoughToClaim() public {
        // Set up initial conditions
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 30 ether;
        bool isLong = true;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);
        uint256 inputAmountToClaimFor = 1 ether;

        vm.expectRevert(LiquidityJackpotHook.NotEnoughToClaim.selector);

        vm.warp(block.timestamp + 30 hours);

        hook.redeem(key, currency0Amount, inputLiquidityAmount, isLong, nextExecutionTime, inputAmountToClaimFor);

        uint256 positionId = hook.getPositionId(key, currency0Amount, isLong, inputLiquidityAmount, nextExecutionTime);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, 0);
    }

    function test_redeem_notLongWinning_NotClaimablePosition() public {
        // Set up initial conditions
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 30;
        bool isLong = true;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);
        uint256 inputAmountToClaimFor = 1 ether;

        uint128 orderLiquidityAmount = hook.placeOrder{value: currency0Amount}(key, isLong);

        vm.warp(block.timestamp + 30 hours);

        vm.expectRevert(LiquidityJackpotHook.NotClaimableLongPosition.selector);

        hook.redeem(key, currency0Amount, orderLiquidityAmount, isLong, nextExecutionTime, inputAmountToClaimFor);

        uint256 positionId = hook.getPositionId(key, currency0Amount, isLong, inputLiquidityAmount, nextExecutionTime);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, 1 ether);
    }

    function test_redeem_notShortWinning_NotClaimablePosition() public {
        // Set up initial conditions
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 30;
        bool isLong = false;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);
        uint256 inputAmountToClaimFor = 1 ether;

        uint128 orderLiquidityAmount = hook.placeOrder{value: currency0Amount}(key, isLong);

        vm.warp(block.timestamp + 30 hours);

        vm.expectRevert(LiquidityJackpotHook.NotClaimableShortPosition.selector);

        hook.redeem(key, currency0Amount, orderLiquidityAmount, isLong, nextExecutionTime, inputAmountToClaimFor);

        uint256 positionId = hook.getPositionId(key, currency0Amount, isLong, inputLiquidityAmount, nextExecutionTime);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, 1 ether);
    }

    function test_cashOutOrder_NotJackpotTime() public {
        // Set up initial conditions
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 10 ether;
        bool isLong = false;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);

        vm.warp(block.timestamp + 30 hours);

        vm.expectRevert(LiquidityJackpotHook.NotJackpotTime.selector);

        hook.cashout(key, currency0Amount, inputLiquidityAmount, isLong, nextExecutionTime);
    }

    function test_cashOutOrder_NothingToCashout() public {
        // Set up initial conditions
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 10 ether;
        bool isLong = false;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);

        vm.expectRevert(LiquidityJackpotHook.NothingToCashout.selector);

        hook.cashout(key, currency0Amount, inputLiquidityAmount, isLong, nextExecutionTime);
    }

    function test_cashOutOrder_success() public {
        // Set up initial conditions
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 30;
        bool isLong = false;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);

        hook.placeOrder{value: currency0Amount}(key, isLong);

        uint256 ramainingClaimsBefore = hook.getJackpotRemainingClaims(key, nextExecutionTime);

        uint256 currentBeforeBalance = address(this).balance;

        uint256 jackpotAmountBefore = hook.getJackpotAmount(key, nextExecutionTime);

        hook.cashout(key, currency0Amount, inputLiquidityAmount, isLong, nextExecutionTime);

        uint256 positionId = hook.getPositionId(key, currency0Amount, isLong, inputLiquidityAmount, nextExecutionTime);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        uint256 currentAfterBalance = address(this).balance;
        uint256 jackpotAmountAfter = hook.getJackpotAmount(key, nextExecutionTime);
        uint256 ramainingClaimsAfter = hook.getJackpotRemainingClaims(key, nextExecutionTime);

        uint256 cashoutAmountBeforeTax = 990000000000000000;

        assertEq(jackpotAmountBefore, 1 ether);
        assertTrue(positionId != 0);
        assertEq(tokenBalance, 0);
        assertEq(currentBeforeBalance, currentAfterBalance - cashoutAmountBeforeTax);
        assertEq(jackpotAmountAfter, 1 ether - 990000000000000000);
        assertEq(ramainingClaimsBefore, ramainingClaimsAfter + 1 ether);
    }

    function test_calculateCashoutAmount_maxAmount() public view {
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 1;
        bool isLong = true;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);

        uint256 cashoutAmount = hook.calculateCashoutAmount(key, currency0Amount, isLong, inputLiquidityAmount, nextExecutionTime);

        assertEq(cashoutAmount, 990000000000000000);
    }

    function test_calculateCashoutAmount_betStateGood_halfTimeToJackpot() public {
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 1;
        bool isLong = true;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);

        vm.warp(block.timestamp + 12 hours);

        uint256 cashoutAmount = hook.calculateCashoutAmount(key, currency0Amount, isLong, inputLiquidityAmount, nextExecutionTime);

        assertEq(cashoutAmount, 742500000000000000);
    }

    function test_calculateCashoutAmount_betStateReallyBad_halfTimeToJackpot() public {
        uint256 currency0Amount = 1 ether;
        uint128 inputLiquidityAmount = 1;
        bool isLong = false;
        uint256 nextExecutionTime = hook.getNextExecutionTime(key);

        vm.warp(block.timestamp + 12 hours);

        uint256 cashoutAmount = hook.calculateCashoutAmount(key, currency0Amount, isLong, inputLiquidityAmount, nextExecutionTime);

        assertEq(cashoutAmount, 24750000000000000);
    }

}