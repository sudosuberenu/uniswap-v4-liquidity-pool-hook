// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {StateLibrary} from 'v4-core/libraries/StateLibrary.sol';
import {BalanceDeltaLibrary} from 'v4-core/types/BalanceDelta.sol';
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from 'v4-core/types/BeforeSwapDelta.sol';

import "forge-std/console.sol";



contract LiquidityJackpotHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    // Storage
    mapping(PoolId poolId => mapping(uint256 jackpotDate => uint128 liquidity)) public jackpotLiquidities;
    mapping(PoolId poolId => mapping(uint256 jackpotDate => uint256 totalJackpot)) public jackpotAmounts;
    mapping(PoolId poolId => mapping(uint256 jackpotDate => uint256 remainingClaims)) public jackpotRemainingClaims;
    mapping(PoolId poolId => uint256 nextJackpot) public nextJackPots;

    uint128[] internal longLiquidyAmounts;
    uint128[] internal shortLiquidyAmounts;

    // Errors
    error NothingToClaim();
    error NothingToCashout();
    error NotJackpotTime();
    error NotEnoughToClaim();
    error NotClaimableLongPosition();
    error NotClaimableShortPosition();

    // Constructor
    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {}

    // BaseHook Functions
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterAddLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: true,
                afterDonate: true,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }


    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        nextJackPots[key.toId()] = block.timestamp + 24 hours;

        return this.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address, 
        PoolKey calldata key, 
        IPoolManager.ModifyLiquidityParams calldata, 
        bytes calldata)
    external override poolManagerOnly returns (bytes4) {
        _checkJackpot(key);

        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        _checkJackpot(key);

        return this.beforeRemoveLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        _checkJackpot(key);

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        _checkJackpot(key);

        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkJackpot(key);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        _checkJackpot(key);

        return (this.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        _checkJackpot(key);

        return this.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
         _checkJackpot(key);

        return this.afterDonate.selector;
    }

    // Core Hook External Functions
    function placeOrder(
        PoolKey calldata key,
        bool isLong
    ) external payable returns (uint128) {
        _checkJackpot(key);

        uint256 currency0Amount = msg.value;
        uint128 inputLiquidityAmount = poolManager.getLiquidity(key.toId());

        uint256 positionId = getPositionId(key, currency0Amount, isLong, inputLiquidityAmount, nextJackPots[key.toId()]);
        _mint(msg.sender, positionId, currency0Amount, "");

        uint256 nextJackpotTime = nextJackPots[key.toId()];
        jackpotAmounts[key.toId()][nextJackpotTime] += currency0Amount;
        jackpotRemainingClaims[key.toId()][nextJackpotTime] += currency0Amount;

        return inputLiquidityAmount;
    }

    function cashout(
        PoolKey calldata key,
        uint256 currency0Amount,
        uint128 inputLiquidityAmount,
        bool isLong,
        uint256 nextJackPotTime
    ) external {
        _checkJackpot(key);

        uint256 currentJackpot = nextJackPots[key.toId()];

        if (currentJackpot != nextJackPotTime) {
            revert NotJackpotTime();
        }

        uint256 positionId = getPositionId(key, currency0Amount, isLong, inputLiquidityAmount, nextJackPotTime);
        uint256 positionTokens = balanceOf(msg.sender, positionId);

        if (positionTokens == 0) {
            revert NothingToCashout();
        }

        uint256 cashoutAmount = calculateCashoutAmount(key, currency0Amount, isLong, inputLiquidityAmount, currentJackpot);

        _burn(msg.sender, positionId, positionTokens);
        
        jackpotAmounts[key.toId()][currentJackpot] -= cashoutAmount;
        jackpotRemainingClaims[key.toId()][nextJackPotTime] -= positionTokens;

        payable(msg.sender).transfer(cashoutAmount);
    }

    function redeem(
        PoolKey calldata key,
        uint256 currency0Amount,
        uint128 inputLiquidityAmount,
        bool isLong,
        uint256 nextJackPotTime,
        uint256 inputAmountToClaimFor
    ) external {
        _checkJackpot(key);

        uint256 positionId = getPositionId(key, currency0Amount, isLong, inputLiquidityAmount, nextJackPotTime);
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        uint128 positionLiquidity = jackpotLiquidities[key.toId()][nextJackPotTime];

        if (positionLiquidity == 0) revert NothingToClaim();

        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        if (isLong && (positionLiquidity <= inputLiquidityAmount)) {
            revert NotClaimableLongPosition();
        }

        if (!isLong && (positionLiquidity >= inputLiquidityAmount)) {
            revert NotClaimableShortPosition();
        }

        _burn(msg.sender, positionId, inputAmountToClaimFor);

        uint256 jackpotAmount = jackpotAmounts[key.toId()][nextJackPotTime];

        // Take some % to the Liquidity providers

        uint256 userPercentage = (100 * inputAmountToClaimFor) / jackpotAmount;

        uint256 winningAmount = (jackpotAmount * userPercentage) / 100;

        jackpotRemainingClaims[key.toId()][nextJackPotTime] -= inputAmountToClaimFor;

        payable(msg.sender).transfer(winningAmount);
    }

    // Internal Functions
    // Create snapshot of the current liquidity / jackpot
    function _checkJackpot(PoolKey calldata key) internal returns (bool) {
        uint256 currentTimestamp = block.timestamp;
        uint256 nextJackpotTime = nextJackPots[key.toId()];

        if (currentTimestamp < nextJackpotTime) {
            return false;
        }

        uint128 currentLiquidity = poolManager.getLiquidity(key.toId());

        jackpotLiquidities[key.toId()][nextJackpotTime] = currentLiquidity;
        nextJackPots[key.toId()] = nextJackpotTime + 24 hours;

        return true;
    }

    function _calculateBetState(PoolKey calldata key, uint128 orderLiquidity, bool isLong) internal view returns (uint) {
        uint128 currentLiquidity = poolManager.getLiquidity(key.toId());

        uint256 betState = 0;

        if (isLong) {
            if (currentLiquidity > orderLiquidity) {
                betState = 1e18;
            } else {
                uint256 ratioLiquidity = (currentLiquidity * 1e18) / orderLiquidity;
                betState = ratioLiquidity;
            }
        } else {
            if (currentLiquidity < orderLiquidity) {
                betState = 1e18;
            } else {
                uint256 ratioLiquidity = (orderLiquidity * 1e18) / currentLiquidity;
                betState = ratioLiquidity;
            }
        }

        return betState;
    }

    // Helper Functions
    function getPositionId(
        PoolKey calldata key,
        uint256 currency0Amount,
        bool isLong,
        uint128 inputLiquidityAmount,
        uint256 nextJackPot
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), currency0Amount, isLong, inputLiquidityAmount, nextJackPot)));
    }

    function getNextExecutionTime(PoolKey calldata key) public view returns (uint256) {
        return nextJackPots[key.toId()];
    }

    function getJackpotAmount(PoolKey calldata key, uint256 nextJackPotTime) public view returns (uint256) {
        return jackpotAmounts[key.toId()][nextJackPotTime];
    }

    function getJackpotRemainingClaims(PoolKey calldata key, uint256 nextJackPotTime) public view returns (uint256) {
        return jackpotRemainingClaims[key.toId()][nextJackPotTime];
    }

    function getJackpotLiquidity(PoolKey calldata key, uint256 nextJackPotTime) public view returns (uint128) {
        return jackpotLiquidities[key.toId()][nextJackPotTime];
    }

    function calculateCashoutAmount(
        PoolKey calldata key,
        uint256 currency0Amount,
        bool isLong,
        uint128 inputLiquidityAmount,
        uint256 nextJackPot) public view returns (uint256) {
        
        uint64 oneDayInSeconds = 86400;
        
        uint256 timeRemaining = nextJackPot - block.timestamp;

        uint256 currentBetState = _calculateBetState(key, inputLiquidityAmount, isLong);

        uint256 timeFraction = (oneDayInSeconds - timeRemaining) * 1e18 / oneDayInSeconds;

        int256 timeFractionInt = int256(timeFraction);  // Convert to int for calculation

        int256 cashoutPercentage = -(timeFractionInt * timeFractionInt / 1e18) + 1e18;
        
        uint256 cashoutPercentageWithBetState = uint256(cashoutPercentage) * currentBetState / 1e18;

        uint256 cashoutAmountBeforeTax = cashoutPercentageWithBetState * currency0Amount / 1e18;

        uint256 jackpotTax = cashoutAmountBeforeTax / 100;

        // TODO: Consider LP part
        uint256 cashoutAmountAfterTax = cashoutAmountBeforeTax - jackpotTax;

        return cashoutAmountAfterTax;
    }

}