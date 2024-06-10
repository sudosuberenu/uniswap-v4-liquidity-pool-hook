// SPDX-License-Identifier: MIT
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


    // Events
    /**
     * @dev Emitted when a user cashes out an order.
     * @param poolId The ID of the pool.
     * @param owner The address of the user who is cashing out.
     * @param cashoutAmount The amount of the cashout.
     * @param currentJackpot The current jackpot amount.
     */
    event CashoutOrder(
        PoolId indexed poolId,
        address indexed owner,
        uint256 cashoutAmount,
        uint256 currentJackpot
    );

    /**
     * @dev Emitted when a user places a new order.
     * @param poolId The ID of the pool.
     * @param owner The address of the user placing the order.
     * @param orderAmount The amount of the order.
     * @param currentJackpot The current jackpot amount.
     * @param liquidity The amount of liquidity added.
     * @param isLong Whether the order is a long position.
     */
    event PlaceOrder(
        PoolId indexed poolId,
        address indexed owner,
        uint256 orderAmount,
        uint256 currentJackpot,
        uint128 liquidity,
        bool isLong
    );

    /**
     * @dev Emitted when a user redeems an order.
     * @param poolId The ID of the pool.
     * @param owner The address of the user redeeming the order.
     * @param redeemAmount The amount of the redeem.
     * @param currentJackpot The current jackpot amount.
     */
    event RedeemOrder(
        PoolId indexed poolId,
        address indexed owner,
        uint256 redeemAmount,
        uint256 currentJackpot
    );


    // Constructor
    /**
     * @dev Sets the pool manager and the URI for the ERC1155 token.
     * @param _manager The address of the pool manager contract.
     * @param _uri The URI for the ERC1155.
     */
    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {}

    // BaseHook Functions
    /**
     * @dev Returns the permissions required for the hook.
     * @return A Hooks.Permissions struct with the permissions.
     */
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

    /**
     * @dev Hook function called before pool initialization.
     * @param key The pool key.
     * @return Selector of the function.
     */
    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        nextJackPots[key.toId()] = block.timestamp + 24 hours;

        return this.beforeInitialize.selector;
    }

    /**
     * @dev Hook function called before adding liquidity to the pool.
     * @param key The pool key.
     * @return Selector of the function.
     */
    function beforeAddLiquidity(
        address, 
        PoolKey calldata key, 
        IPoolManager.ModifyLiquidityParams calldata, 
        bytes calldata)
    external override poolManagerOnly returns (bytes4) {
        _checkJackpot(key);

        return this.beforeAddLiquidity.selector;
    }

    /**
     * @dev Hook function called before removing liquidity from the pool.
     * @param key The pool key.
     * @return Selector of the function.
     */
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        _checkJackpot(key);

        return this.beforeRemoveLiquidity.selector;
    }

    /**
     * @dev Hook function called after adding liquidity to the pool.
     * @param key The pool key.
     * @return Selector of the function and the balance delta.
     */
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

    /**
     * @dev Hook function called after removing liquidity from the pool.
     * @param key The pool key.
     * @return Selector of the function and the balance delta.
     */
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

    /**
     * @dev Hook function called before swapping tokens in the pool.
     * @param key The pool key.
     * @return Selector of the function, the swap delta, and a fee amount.
     */
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkJackpot(key);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev Hook function called after swapping tokens in the pool.
     * @param key The pool key.
     * @return Selector of the function and a swap amount.
     */
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

    /**
     * @dev Hook function called before donating tokens to the pool.
     * @param key The pool key.
     * @return Selector of the function.
     */
    function beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        _checkJackpot(key);

        return this.beforeDonate.selector;
    }

    /**
     * @dev Hook function called after donating tokens to the pool.
     * @param key The pool key.
     * @return Selector of the function.
     */
    function afterDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
         _checkJackpot(key);

        return this.afterDonate.selector;
    }

    // Core Hook External Functions
    /**
     * @dev Places an order in the pool.
     * @param key The pool key.
     * @param isLong Whether the order is a long position.
     * @return The amount of liquidity added.
     */
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

        emit PlaceOrder(key.toId(), msg.sender, currency0Amount, nextJackpotTime, inputLiquidityAmount, isLong);

        return inputLiquidityAmount;
    }

    /**
     * @dev Casheout a position from the pool.
     * @param key The pool key.
     * @param currency0Amount Amount of token0 to cash out.
     * @param inputLiquidityAmount Amount of liquidity to cashout.
     * @param isLong Whether the position is a long position.
     * @param nextJackPotTime The timestamp of the next jackpot.
     */
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

        emit CashoutOrder(key.toId(), msg.sender, cashoutAmount, currentJackpot);

        payable(msg.sender).transfer(cashoutAmount);
    }

    /**
     * @dev Redeems a position from the pool.
     * @param key The pool key.
     * @param currency0Amount Amount of token0 to redeem.
     * @param inputLiquidityAmount Amount of liquidity to redeem.
     * @param isLong Whether the position is a long position.
     * @param nextJackpotTime The timestamp of the next jackpot.
     * @param inputAmountToClaimFor The amount to claim.
     */
    function redeem(
        PoolKey calldata key,
        uint256 currency0Amount,
        uint128 inputLiquidityAmount,
        bool isLong,
        uint256 nextJackpotTime,
        uint256 inputAmountToClaimFor
    ) external {
        _checkJackpot(key);

        uint256 positionId = getPositionId(key, currency0Amount, isLong, inputLiquidityAmount, nextJackpotTime);
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        uint128 positionLiquidity = jackpotLiquidities[key.toId()][nextJackpotTime];

        if (positionLiquidity == 0) revert NothingToClaim();

        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        if (isLong && (positionLiquidity <= inputLiquidityAmount)) {
            revert NotClaimableLongPosition();
        }

        if (!isLong && (positionLiquidity >= inputLiquidityAmount)) {
            revert NotClaimableShortPosition();
        }

        _burn(msg.sender, positionId, inputAmountToClaimFor);

        uint256 jackpotAmount = jackpotAmounts[key.toId()][nextJackpotTime];

        // TODO! Take some % to the Liquidity providers

        uint256 userPercentage = (100 * inputAmountToClaimFor) / jackpotAmount;

        uint256 winningAmount = (jackpotAmount * userPercentage) / 100;

        jackpotRemainingClaims[key.toId()][nextJackpotTime] -= inputAmountToClaimFor;


        emit RedeemOrder(key.toId(), msg.sender, inputAmountToClaimFor, nextJackpotTime);

        payable(msg.sender).transfer(winningAmount);
    }

    // Internal Functions
    /**
     * @dev Checks if it's time for a new jackpot and create a snapshot of the current liquidity / jackpot
     * @param key The pool key.
     * @return True if a new jackpot has been set, false otherwise.
     */
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

    /**
     * @dev Calculates the state of a bet given the current liquidity.
     * @param key The pool key.
     * @param orderLiquidity The liquidity of the order.
     * @param isLong Whether the bet is a long position.
     * @return The state of the bet as a uint256.
     */
    function _calculateBetState(PoolKey calldata key, uint128 orderLiquidity, bool isLong) internal view returns (uint256) {
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
    /**
     * @dev Generates a unique ID for a position.
     * @param key The pool key.
     * @param currency0Amount Amount of token0 involved in the position.
     * @param isLong Whether the position is a long position.
     * @param inputLiquidityAmount Amount of liquidity involved in the position.
     * @param nextJackPot The timestamp of the next jackpot.
     * @return The unique position ID as a uint256.
     */
    function getPositionId(
        PoolKey calldata key,
        uint256 currency0Amount,
        bool isLong,
        uint128 inputLiquidityAmount,
        uint256 nextJackPot
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), currency0Amount, isLong, inputLiquidityAmount, nextJackPot)));
    }

    /**
     * @dev Gets the timestamp of the next jackpot for a given pool.
     * @param key The pool key.
     * @return The timestamp of the next jackpot as a uint256.
     */
    function getNextExecutionTime(PoolKey calldata key) public view returns (uint256) {
        return nextJackPots[key.toId()];
    }

    /**
     * @dev Gets the amount of the jackpot for a given pool and timestamp.
     * @param key The pool key.
     * @param nextJackPotTime The timestamp of the jackpot.
     * @return The jackpot amount as a uint256.
     */
    function getJackpotAmount(PoolKey calldata key, uint256 nextJackPotTime) public view returns (uint256) {
        return jackpotAmounts[key.toId()][nextJackPotTime];
    }

    /**
     * @dev Gets the remaining claims for a given pool and timestamp.
     * @param key The pool key.
     * @param nextJackPotTime The timestamp of the jackpot.
     * @return The remaining claims as a uint256.
     */
    function getJackpotRemainingClaims(PoolKey calldata key, uint256 nextJackPotTime) public view returns (uint256) {
        return jackpotRemainingClaims[key.toId()][nextJackPotTime];
    }

    /**
     * @dev Gets the liquidity for a given pool and jackpot timestamp.
     * @param key The pool key.
     * @param nextJackPotTime The timestamp of the jackpot.
     * @return The liquidity amount as a uint128.
     */
    function getJackpotLiquidity(PoolKey calldata key, uint256 nextJackPotTime) public view returns (uint128) {
        return jackpotLiquidities[key.toId()][nextJackPotTime];
    }

    /**
     * @dev Calculates the cashout amount for a given position.
     * @param key The pool key.
     * @param currency0Amount Amount of token0 involved in the position.
     * @param isLong Whether the position is a long position.
     * @param inputLiquidityAmount Amount of liquidity involved in the position.
     * @param nextJackPot The timestamp of the next jackpot.
     * @return The cashout amount as a uint256.
     */
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

        int256 timeFractionInt = int256(timeFraction);

        int256 cashoutPercentage = -(timeFractionInt * timeFractionInt / 1e18) + 1e18;
        
        uint256 cashoutPercentageWithBetState = uint256(cashoutPercentage) * currentBetState / 1e18;

        uint256 cashoutAmountBeforeTax = cashoutPercentageWithBetState * currency0Amount / 1e18;

        uint256 jackpotTax = cashoutAmountBeforeTax / 100;

        // TODO! Take some % to the Liquidity providers

        uint256 cashoutAmountAfterTax = cashoutAmountBeforeTax - jackpotTax;

        return cashoutAmountAfterTax;
    }

}