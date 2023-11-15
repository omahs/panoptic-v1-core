// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.18;

// Foundry
import "forge-std/Test.sol";
// Interfaces
import {IUniswapV3Pool} from "univ3-core/interfaces/IUniswapV3Pool.sol";
import {PanopticPool} from "@contracts/PanopticPool.sol";
import {CollateralTracker} from "@contracts/CollateralTracker.sol";
import {SemiFungiblePositionManager} from "@contracts/SemiFungiblePositionManager.sol";
// Libraries
import {Constants} from "@libraries/Constants.sol";
import {PanopticMath} from "@libraries/PanopticMath.sol";
import {Math} from "@libraries/Math.sol";
// Custom types
import {TokenId} from "@types/TokenId.sol";
import {LeftRight} from "@types/LeftRight.sol";
import {Errors} from "@libraries/Errors.sol";

/// @title Utility contract for token ID construction and advanced queries.
/// @author Axicon Labs Limited
contract PanopticHelper {
    // enables packing of types within int128|int128 or uint128|uint128 containers.
    using LeftRight for int256;
    using LeftRight for uint256;

    using TokenId for uint256;

    SemiFungiblePositionManager immutable SFPM;

    uint256 internal constant DECIMALS = 10_000;

    struct Leg {
        uint64 poolId;
        address UniswapV3Pool;
        uint256 asset;
        uint256 optionRatio;
        uint256 tokenType;
        uint256 isLong;
        uint256 riskPartner;
        int24 strike;
        int24 width;
    }

    // 1, 5, 10, 25, 50, 75, 100
    int256[7] sizingPercentages = [
        int256(1),
        int256(5),
        int256(10),
        int256(25),
        int256(50),
        int256(75),
        int256(100)
    ];

    // max room for error in tokens
    int256 constant epsilon = 10;

    /// @notice Decimals for computation (1 bps (basis point) precision: 0.01%)
    /// int type for composability with signed integer based mathematical operations.
    int128 internal constant DECIMALS_128 = 10_000;

    /// @notice Construct the PanopticHelper contract
    /// @param _SFPM address of the SemiFungiblePositionManager
    /// @dev the SFPM is used to get the pool ID for a given address
    constructor(SemiFungiblePositionManager _SFPM) payable {
        SFPM = _SFPM;
    }

    /// @notice Compute the total amount of collateral needed to cover the existing list of active positions in positionIdList.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param atTick At what price is the collateral requirement evaluated at
    /// @param tokenType whether to return the values in term of token0 or token1
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @return collateralBalance the total combined balance of token0 and token1 for a user in terms of tokenType
    /// @return requiredCollateral The combined collateral requirement for a user in terms of tokenType
    function checkCollateral(
        PanopticPool pool,
        address account,
        int24 atTick,
        uint256 tokenType,
        uint256[] calldata positionIdList
    ) public view returns (uint256, uint256) {
        // Compute premia for all options (includes short+long premium)
        (int128 premium0, int128 premium1, uint256[2][] memory positionBalanceArray) = pool
            .calculateAccumulatedFeesBatch(account, positionIdList);

        // Query the current and required collateral amounts for the two tokens
        uint256 tokenData0 = pool.collateralToken0().getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            premium0
        );
        uint256 tokenData1 = pool.collateralToken1().getAccountMarginDetails(
            account,
            atTick,
            positionBalanceArray,
            premium1
        );

        // convert (using atTick) and return the total collateral balance and required balance in terms of tokenType
        return PanopticMath.convertCollateralData(tokenData0, tokenData1, tokenType, atTick);
    }

    /// @notice Get the collateral status/margin details for a single position, not taking ITM amounts into account.
    /// @dev This can be used to check the amount of tokens required for that specific collateral type.
    /// @param tokenId The option position.
    /// @param positionSize The size of the option position.
    /// @param atTick Tick to convert values at.
    /// @return tokensRequired Required tokens for that new position
    function getPositionCollateralRequirement(
        PanopticPool pool,
        uint256 tokenId,
        uint256 tokenType,
        uint128 positionSize,
        int24 atTick
    ) public view returns (uint256 tokensRequired) {
        unchecked {
            // update pool utilization, taking new inAMM amounts into account
            uint128 poolUtilization;
            CollateralTracker collateralToken = tokenType == 0
                ? pool.collateralToken0()
                : pool.collateralToken1();

            (, , int128 currentPoolUtilization) = collateralToken.getPoolData();

            (int256 longAmounts, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                pool.univ3pool().tickSpacing()
            );

            (int256 longAmount, int256 shortAmount) = tokenType == 0
                ? (longAmounts.rightSlot(), shortAmounts.rightSlot())
                : (longAmounts.leftSlot(), shortAmounts.leftSlot());

            int256 deltaBalance = shortAmount - longAmount;

            int128 newPoolUtilization = int128(
                currentPoolUtilization +
                    (deltaBalance * DECIMALS_128) /
                    int256(collateralToken.totalAssets())
            );

            tokenType == 0
                ? poolUtilization = uint128(newPoolUtilization)
                : poolUtilization = (uint128(newPoolUtilization) << 64);

            // Compute the tokens required using new pool utilization
            tokensRequired = collateralToken.getRequiredCollateralAtTickSinglePosition(
                tokenId,
                positionSize,
                atTick,
                poolUtilization
            );
        }
    }

    /// @notice Get the collateral status/margin details for a single position, includes offsetting effect of ITM positions.
    /// @dev This can be used to check the amount of tokens required for that specific collateral type, with the ITM amounts being
    /// @dev credited or deducted from the tokenRequired.
    /// @param tokenId The option position.
    /// @param positionSize The size of the option position.
    /// @param atTick Tick to convert values at. This can be the current tick or the Uniswap pool TWAP tick.
    /// @return totalTokensRequired Required tokens for that new position
    /// @return itmAmount Amount of tokens that are ITM
    function getITMPositionCollateralRequirement(
        PanopticPool pool,
        uint256 tokenId,
        uint256 tokenType,
        uint128 positionSize,
        int24 atTick
    )
        public
        view
        returns (int256 totalTokensRequired, int256 itmAmount, int256 estimatedExchangedAmount)
    {
        {
            // get tokens required for the current tokenId position
            // if the amount moved is 0 the required tokens are 0
            uint256 tokensRequired = getPositionCollateralRequirement(
                pool,
                tokenId,
                tokenType,
                positionSize,
                atTick
            );

            // compute ITM amounts
            (int256 itmAmount0, int256 itmAmount1) = PanopticMath.getNetITMAmountsForPosition(
                tokenId,
                positionSize,
                pool.univ3pool().tickSpacing(),
                atTick
            );

            // use the ITM amount for the current collateral token
            itmAmount = tokenType == 0 ? itmAmount0 : itmAmount1;

            // deduct ITM amounts from tokens required
            // final requirement can be negative due to an off by ~1-5 token precision loss error
            totalTokensRequired = tokensRequired.toInt256() - itmAmount;
        }

        // move to separate function
        {
            CollateralTracker collateralToken = tokenType == 0
                ? pool.collateralToken0()
                : pool.collateralToken1();

            (int256 longAmounts, int256 shortAmounts) = PanopticMath.computeExercisedAmounts(
                tokenId,
                0,
                positionSize,
                pool.univ3pool().tickSpacing()
            );

            (int256 longAmount, int256 shortAmount) = tokenType == 0
                ? (longAmounts.rightSlot(), shortAmounts.rightSlot())
                : (longAmounts.leftSlot(), shortAmounts.leftSlot());

            // * estimate swapped amounts based on ITM amounts

            // temporarily passing in swapped amounts as 0 (can estimate)
            estimatedExchangedAmount = collateralToken._getExchangedAmount(
                int128(longAmount),
                int128(shortAmount),
                0
            );
        }
    }

    /// @notice Compute the collateral requirement of a given tokenId at the given tick
    /// @param tokenId The tokenId to check collateral requirement for
    /// @param positionSize the size of the new position
    /// @param atTick At what price is the collateral requirement evaluated at
    /// @return requiredCollateral0 The collateral requirement for token0
    /// @return requiredCollateral1 The collateral requirement for token0
    function computeCollateralRequirement(
        PanopticPool pool,
        uint256 tokenId,
        uint128 positionSize,
        int24 atTick
    ) public view returns (uint256 requiredCollateral0, uint256 requiredCollateral1) {
        // Query the required collateral amounts for the two tokens
        requiredCollateral0 = getPositionCollateralRequirement(
            pool,
            tokenId,
            0, // tokenType
            positionSize,
            atTick
        );
        // Query the required collateral amounts for the two tokens
        requiredCollateral1 = getPositionCollateralRequirement(
            pool,
            tokenId,
            1, // tokenType
            positionSize,
            atTick
        );
    }

    /// @notice Compute the collateral requirement of a given tokenId at the given tick, considering the ITM amounts
    /// @param pool The PanopticPool instance to check collateral on
    /// @param positionSize the size of the new position
    /// @param atTick At what price is the collateral requirement evaluated at
    /// @return requiredCollateralITM0 The collateral requirement for token0
    /// @return requiredCollateralITM1 The collateral requirement for token0
    function computeCollateralRequirementITM(
        PanopticPool pool,
        uint256 tokenId,
        uint128 positionSize,
        int24 atTick
    ) public view returns (int256 requiredCollateralITM0, int256 requiredCollateralITM1) {
        // Query the required collateral amounts for the two tokens
        (requiredCollateralITM0, , ) = getITMPositionCollateralRequirement(
            pool,
            tokenId,
            0, // tokenType
            positionSize,
            atTick
        );
        // Query the required collateral amounts for the two tokens
        (requiredCollateralITM1, , ) = getITMPositionCollateralRequirement(
            pool,
            tokenId,
            1, // tokenType
            positionSize,
            atTick
        );
    }

    /// @notice Compute the max position size given a tokenId using the bisection method.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param account Address of the user that owns the positions
    /// @param positionIdList List of positions. Written as [tokenId1, tokenId2, ...]
    /// @param tokenId The tokenId to check collateral requirement for
    /// @param atTick At what price is the collateral requirement evaluated at
    /// @param tokenType whether to return the values in term of token0 or token1
    /// @param maintenanceMarginRatio minimum ratio of actual-to-required collateral that must be maintained to mint a new position (decimals=10000).
    /// @return maxPositionSizes the array of max position sizes in order of sizing percentage [1, 5, 10, 15, 25, 50, 75, 100]
    function computeMaxPositionSize(
        PanopticPool pool,
        address account,
        uint256[] calldata positionIdList,
        uint256 tokenId,
        int24 atTick,
        uint256 tokenType,
        uint256 maintenanceMarginRatio
    ) public view returns (int256[7] memory maxPositionSizes) {
        // stack rolling
        PanopticPool _pool = pool;

        // available collateral being the user's collateral balance less the base requirement and minting
        // margin buffer
        uint256 availableCollateral;
        {
            // collateral balance and required collateral depending on token type
            (uint256 collateralBalance, uint256 requiredCollateral) = checkCollateral(
                _pool,
                account,
                atTick,
                tokenType,
                positionIdList
            );

            availableCollateral =
                collateralBalance -
                (requiredCollateral * maintenanceMarginRatio) /
                DECIMALS;
        }

        // populate max position sizes
        for (uint i; i < 7; ) {
            // upper and lower bounds
            int256 a = 1;
            int256 b = type(int64).max;
            int256 c; // 0 by default

            // check if initial solution resides within bounds of 'a' and 'b'
            {
                while (true) {
                    int256[3] memory solutions;
                    console2.log("testing bisection");
                    try
                        this.bisectionBaseCase1(
                            _pool,
                            tokenId,
                            atTick,
                            tokenType,
                            [a, b, c],
                            availableCollateral,
                            i // sizing index
                        )
                    returns (int256[3] memory solutions) {
                        // if solution not within bounds, then increase by 10%
                        if (solutions[0] * solutions[1] <= 0) {
                            break;
                        } else {
                            b += (b * 10) / 100;
                            console2.log("b increase", b);
                            // if solution position size is greater than 104 bits then throw an error
                            if (b > type(int104).max) {
                                console2.log("tokenId is invalid, the max bounds are too large");
                                revert Errors.ExceedsMaximumRedemption(); // temp error **
                            }
                        }
                        // if invalid notional error then reduce by 5%
                    } catch Error(string memory reason) {
                        if (bytes4(bytes(reason)) == Errors.InvalidNotionalValue.selector) {
                            b -= b - (b * 5) / 100;
                        } else {
                            // any other error then this is an invalid position
                            revert("Invalid position");
                        }
                    }
                }
            }

            while (b - a >= epsilon) {
                // Find middle point
                c = (a + b) / 2;

                console2.log("real bisection");
                int256[3] memory solutions = bisectionBaseCase1(
                    _pool,
                    tokenId,
                    atTick,
                    tokenType,
                    [a, b, c],
                    availableCollateral,
                    i // sizing index
                );

                console2.log("solution 1", solutions[0]);
                console2.log("solution 2", solutions[1]);
                console2.log("solution 3", solutions[2]);

                // Check if middle point is root
                if (solutions[2] == 0) {
                    break;
                    // preforms (a * b) < 0 without multiplication to avoid an overflow
                    // max constraint of 256 bits
                } else if (
                    (solutions[2] < 0 && solutions[0] > 0) || (solutions[2] > 0 && solutions[0] < 0)
                ) {
                    // Decide the side to repeat the steps
                    b = c;
                    console2.log("new b", b);
                } else {
                    a = c;
                    console2.log("new a", a);
                }
            }

            maxPositionSizes[i] = c;

            unchecked {
                i++;
            }
        }
    }

    /// @notice Compute the max position size given a tokenId using the bisection method.
    /// @param pool The PanopticPool instance to check collateral on
    /// @param tokenId The tokenId to check collateral requirement for
    /// @param atTick At what price is the collateral requirement evaluated at
    /// @param tokenType whether to return the values in term of token0 or token1
    /// @param positionSizes The position sizes to evaluate the collateral requirement passed in
    /// @param availableCollateral the interacting user's free collateral balances (total balancde - total requirements for open positions)
    /// @param sizingIndex The ratio of the available collateral being used to determine the maximum position size for
    /// @return solutions the collateral requirements for the corresponding position details passed in
    function bisectionBaseCase1(
        PanopticPool pool,
        uint256 tokenId,
        int24 atTick,
        uint256 tokenType,
        int256[3] memory positionSizes,
        uint256 availableCollateral,
        uint256 sizingIndex
    ) public view returns (int256[3] memory solutions) {
        // stack rolling
        int24 _atTick = atTick;

        //uint256 totalLegs = tokenId.countLegs();
        for (uint i; i < 3; i++) {
            console2.log("positionSizes[i]", positionSizes[i]);
            console2.log("bisection 1");

            int256 requiredCollateralITM0;
            int256 requiredCollateralITM1;
            int256 exchangedAmount0;
            int256 exchangedAmount1;
            {
                // Query the required collateral amounts for token0
                (requiredCollateralITM0, , exchangedAmount0) = getITMPositionCollateralRequirement(
                    pool,
                    tokenId,
                    0,
                    uint128(uint256(positionSizes[i])),
                    _atTick
                );
                // Query the required collateral amounts for token1
                (requiredCollateralITM1, , exchangedAmount1) = getITMPositionCollateralRequirement(
                    pool,
                    tokenId,
                    1,
                    uint128(uint256(positionSizes[i])),
                    _atTick
                );
            }

            // get current price
            uint160 sqrtPriceX96 = Math.getSqrtRatioAtTick(_atTick);

            // convert to get all in token0 or token1
            int256 totalRequirement = tokenType == 0
                ? requiredCollateralITM0 +
                    PanopticMath.convert1to0(requiredCollateralITM1, sqrtPriceX96)
                : requiredCollateralITM1 +
                    PanopticMath.convert0to1(requiredCollateralITM0, sqrtPriceX96);

            solutions[i] =
                ((int256(availableCollateral) * sizingPercentages[sizingIndex]) / 100) -
                totalRequirement;

            console2.log("availableCollateral", availableCollateral);
            console2.log(
                "((int256(availableCollateral) * sizingPercentages[sizingIndex]) / 100)",
                ((int256(availableCollateral) * sizingPercentages[sizingIndex]) / 100)
            );
            console2.log("sizingPercentages[sizingIndex]", sizingPercentages[sizingIndex]);
            console2.log("totalRequirement", totalRequirement);
            console2.log(
                "solution",
                ((int256(availableCollateral) * sizingPercentages[sizingIndex]) / 100)
            );
        }
    }

    /// @notice this function returns the amounts moved for a legs of a tokenId without revert
    /// if the initial position size passed into a position is too small, it reverts due to the notional value being insufficient
    /// this helper returns the amounts without restriction
    /// @param tokenId The tokenId to check collateral requirement for
    /// @param positionSize the number of option contracts held in this position (each contract can control multiple tokens)
    /// @param tickSpacing the tick spacing of the underlying UniV3 pool
    /// @return amountsMoved the total amounts moved for all legs with each value being a LeftRight encoded variable containing the amount0 and the amount1 value controlled by this option position's leg
    function totalAmountsMoved(
        uint256 tokenId,
        uint128 positionSize,
        int24 tickSpacing
    ) public view returns (uint256[4] memory amountsMoved) {
        uint256 totalLegs = tokenId.countLegs();
        for (uint i; i < totalLegs; ) {
            // get the tick range for this leg in order to get the strike price (the underlying price)
            (int24 tickLower, int24 tickUpper) = tokenId.asTicks(i, tickSpacing);

            // positionSize: how many option contracts we have.

            uint128 amount0;
            uint128 amount1;
            unchecked {
                if (tokenId.asset(i) == 0) {
                    // contractSize: is then the product of how many option contracts we have and the amount of underlying controlled per contract
                    amount0 = positionSize * uint128(tokenId.optionRatio(i)); // in terms of the underlying tokens/shares
                    // notional is then "how many underlying tokens are controlled (contractSize) * (the price for each token -- strike price):
                    amount1 = (
                        PanopticMath.convert0to1(
                            amount0,
                            Math.getSqrtRatioAtTick((tickUpper + tickLower) / 2)
                        )
                    ).toUint128(); // how many tokens are controlled by this option position
                } else {
                    amount1 = positionSize * uint128(tokenId.optionRatio(i));
                    amount0 = (
                        PanopticMath.convert1to0(
                            amount1,
                            Math.getSqrtRatioAtTick((tickUpper + tickLower) / 2)
                        )
                    ).toUint128();
                }
            }
            amountsMoved[i] = uint256(0).toRightSlot(amount0).toLeftSlot(amount1);

            unchecked {
                i++;
            }
        }
    }

    /// @notice Returns the net assets (balance - maintenance margin) of a given account on a given pool.
    /// @dev does not work for very large tick gradients.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param tick tick to consider
    /// @param positionIdList list of position IDs to consider
    /// @return netEquity the net assets of `account` on `pool`
    function netEquity(
        address pool,
        address account,
        int24 tick,
        uint256[] calldata positionIdList
    ) internal view returns (int256) {
        (uint256 balanceCross, uint256 requiredCross) = checkCollateral(
            PanopticPool(pool),
            account,
            tick,
            0,
            positionIdList
        );

        return int256(balanceCross) - int256(requiredCross);
    }

    /// @notice Unwraps the contents of the tokenId into its legs.
    /// @param tokenId the input tokenId
    /// @return legs an array of leg structs
    function unwrapTokenId(uint256 tokenId) public view returns (Leg[] memory) {
        uint256 numLegs = tokenId.countLegs();
        Leg[] memory legs = new Leg[](numLegs);

        uint64 poolId = tokenId.validate();
        address UniswapV3Pool = address(SFPM.getUniswapV3PoolFromId(tokenId.univ3pool()));
        for (uint256 i = 0; i < numLegs; ++i) {
            legs[i].poolId = poolId;
            legs[i].UniswapV3Pool = UniswapV3Pool;
            legs[i].asset = tokenId.asset(i);
            legs[i].optionRatio = tokenId.optionRatio(i);
            legs[i].tokenType = tokenId.tokenType(i);
            legs[i].isLong = tokenId.isLong(i);
            legs[i].riskPartner = tokenId.riskPartner(i);
            legs[i].strike = tokenId.strike(i);
            legs[i].width = tokenId.width(i);
        }
        return legs;
    }

    /// @notice Returns an estimate of the downside liquidation price for a given account on a given pool.
    /// @dev returns MIN_TICK if the LP is more than 100000 ticks below the current tick.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param positionIdList list of position IDs to consider
    /// @return liquidationTick the downward liquidation price of `account` on `pool`, if any
    function findLiquidationPriceDown(
        address pool,
        address account,
        uint256[] calldata positionIdList
    ) public view returns (int24 liquidationTick) {
        // initialize right and left bounds from current tick
        (, int24 currentTick, , , , , ) = PanopticPool(pool).univ3pool().slot0();
        int24 x0 = currentTick - 10000;
        int24 x1 = currentTick;
        int24 tol = 100000;
        // use the secant method to find the root of the function netEquity(tick)
        // stopping criterion are netEquity(tick+1) > 0 and netEquity(tick-1) < 0
        // and tick is below currentTick - tol
        // (we have limited ability to calculate collateral for very large tick gradients)
        // in that case, we return the min tick
        while (true) {
            // perform an iteration of the secant method
            (x0, x1) = (
                x1,
                int24(
                    x1 -
                        (int256(netEquity(pool, account, x1, positionIdList)) * (x1 - x0)) /
                        int256(
                            netEquity(pool, account, x1, positionIdList) -
                                netEquity(pool, account, x0, positionIdList)
                        )
                )
            );
            // if price is not within a 100000 tick range of current price, return MIN_TICK
            if (x1 > currentTick + tol || x1 < currentTick - tol) {
                return Constants.MIN_V3POOL_TICK;
            }
            // stop if price is within 0.01% (1 tick) of LP
            if (
                netEquity(pool, account, x1 + 1, positionIdList) >= 0 ==
                netEquity(pool, account, x1 - 1, positionIdList) <= 0
            ) {
                return x1;
            }
        }
    }

    /// @notice Returns an estimate of the upside liquidation price for a given account on a given pool.
    /// @dev returns MAX_TICK if the LP is more than 100000 ticks above current tick.
    /// @param pool address of the pool
    /// @param account address of the account
    /// @param positionIdList list of position IDs to consider
    /// @return liquidationTick the upward liquidation price of `account` on `pool`, if any
    function findLiquidationPriceUp(
        address pool,
        address account,
        uint256[] calldata positionIdList
    ) public view returns (int24 liquidationTick) {
        // initialize right and left bounds from current tick
        (, int24 currentTick, , , , , ) = PanopticPool(pool).univ3pool().slot0();
        int24 x0 = currentTick;
        int24 x1 = currentTick + 10000;
        int24 tol = 100000;
        // use the secant method to find the root of the function netEquity(tick)
        // stopping criterion are netEquity(tick+1) > 0 and netEquity(tick-1) < 0
        // and tick is within the range of currentTick +- tol
        // (we have limited ability to calculate collateral for very large tick gradients)
        // in that case, we return the corresponding max/min tick
        while (true) {
            // perform an iteration of the secant method
            (x0, x1) = (
                x1,
                int24(
                    x1 -
                        (int256(netEquity(pool, account, x1, positionIdList)) * (x1 - x0)) /
                        int256(
                            netEquity(pool, account, x1, positionIdList) -
                                netEquity(pool, account, x0, positionIdList)
                        )
                )
            );
            // if price is not within a 100000 tick range of current price, stop + return MAX_TICK
            if (x1 > currentTick + tol || x1 < currentTick - tol) {
                return Constants.MAX_V3POOL_TICK;
            }
            // stop if price is within 0.01% (1 tick) of LP
            if (
                netEquity(pool, account, x1 + 1, positionIdList) >= 0 ==
                netEquity(pool, account, x1 - 1, positionIdList) <= 0
            ) {
                return x1;
            }
        }
    }

    /// @notice initializes a given leg in a tokenId as a call.
    /// @param tokenId tokenId to edit
    /// @param legIndex index of the leg to edit
    /// @param optionRatio relative size of the leg
    /// @param asset asset of the leg
    /// @param isLong whether the leg is long or short
    /// @param riskPartner defined risk partner of the leg
    /// @param strike strike of the leg
    /// @param width width of the leg
    /// @return tokenId with the leg initialized
    function addCallLeg(
        uint256 tokenId,
        uint256 legIndex,
        uint256 optionRatio,
        uint256 asset,
        uint256 isLong,
        uint256 riskPartner,
        int24 strike,
        int24 width
    ) internal pure returns (uint256) {
        return
            TokenId.addLeg(
                tokenId,
                legIndex,
                optionRatio,
                asset,
                isLong,
                0,
                riskPartner,
                strike,
                width
            );
    }

    /// @notice initializes a given leg in a tokenId as a put.
    /// @param tokenId tokenId to edit
    /// @param legIndex index of the leg to edit
    /// @param optionRatio relative size of the leg
    /// @param asset asset of the leg
    /// @param isLong whether the leg is long or short
    /// @param riskPartner defined risk partner of the leg
    /// @param strike strike of the leg
    /// @param width width of the leg
    /// @return tokenId with the leg initialized
    function addPutLeg(
        uint256 tokenId,
        uint256 legIndex,
        uint256 optionRatio,
        uint256 asset,
        uint256 isLong,
        uint256 riskPartner,
        int24 strike,
        int24 width
    ) internal pure returns (uint256) {
        return
            TokenId.addLeg(
                tokenId,
                legIndex,
                optionRatio,
                asset,
                isLong,
                1,
                riskPartner,
                strike,
                width
            );
    }

    /// @notice creates "Classic" strangle using a call and a put, with asymmetric upward risk.
    /// @dev example: createStrangle(uniPoolAddress, 4, 50, -50, 0, 1, 1, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the strangle
    /// @param callStrike strike of the call
    /// @param putStrike strike of the put
    /// @param asset asset of the strangle
    /// @param isLong is the strangle long or short
    /// @param optionRatio relative size of the strangle
    /// @param start leg index where the (2 legs) of the strangle begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createStrangle(
        address univ3pool,
        int24 width,
        int24 callStrike,
        int24 putStrike,
        uint256 asset,
        uint256 isLong,
        uint256 optionRatio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // Pool
        tokenId = tokenId.addUniv3pool(SFPM.getPoolId(univ3pool));

        // A strangle is composed of
        // 1. a call with a higher strike price
        // 2. a put with a lower strike price

        // Call w/ higher strike
        tokenId = addCallLeg(
            tokenId,
            start,
            optionRatio,
            asset,
            isLong,
            start + 1,
            callStrike,
            width
        );

        // Put w/ lower strike
        tokenId = addPutLeg(
            tokenId,
            start + 1,
            optionRatio,
            asset,
            isLong,
            start,
            putStrike,
            width
        );
    }

    /// @notice creates "Classic" straddle using a call and a put, with asymmetric upward risk.
    /// @dev createStraddle(uniPoolAddress, 4, 0, 0, 1, 1, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the strangle
    /// @param strike strike of the call and put
    /// @param asset asset of the strangle
    /// @param isLong is the strangle long or short
    /// @param optionRatio relative size of the strangle
    /// @param start leg index where the (2 legs) of the straddle begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createStraddle(
        address univ3pool,
        int24 width,
        int24 strike,
        uint256 asset,
        uint256 isLong,
        uint256 optionRatio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // Pool
        tokenId = tokenId.addUniv3pool(SFPM.getPoolId(univ3pool));

        // A straddle is composed of
        // 1. a call with an identical strike price
        // 2. a put with an identical strike price

        // call
        tokenId = addCallLeg(tokenId, start, optionRatio, asset, isLong, start, strike, width);

        // put
        tokenId = addPutLeg(
            tokenId,
            start + 1,
            optionRatio,
            asset,
            isLong,
            start + 1,
            strike,
            width
        );
    }

    /// @notice creates a call spread with 1 long leg and 1 short leg.
    /// @dev example: createCallSpread(uniPoolAddress, 4, -50, 50, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallSpread(
        address univ3pool,
        int24 width,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // Pool
        tokenId = tokenId.addUniv3pool(SFPM.getPoolId(univ3pool));

        // A call spread is composed of
        // 1. a long call with a lower strike price
        // 2. a short call with a higher strike price

        // Long call
        tokenId = addCallLeg(tokenId, start, optionRatio, asset, 1, start + 1, strikeLong, width);

        // Short call
        tokenId = addCallLeg(tokenId, start + 1, optionRatio, asset, 0, start, strikeShort, width);
    }

    /// @notice creates a put spread with 1 long leg and 1 short leg.
    /// @dev example: createPutSpread(uniPoolAddress, 4, -50, 50, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutSpread(
        address univ3pool,
        int24 width,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // Pool
        tokenId = tokenId.addUniv3pool(SFPM.getPoolId(univ3pool));

        // A put spread is composed of
        // 1. a long put with a higher strike price
        // 2. a short put with a lower strike price

        // Long put
        tokenId = addPutLeg(tokenId, start, optionRatio, asset, 1, start + 1, strikeLong, width);

        // Short put
        tokenId = addPutLeg(tokenId, start + 1, optionRatio, asset, 0, start, strikeShort, width);
    }

    /// @notice creates a diagonal spread with 1 long leg and 1 short leg.abi.
    /// @dev example: createCallDiagonalSpread(uniPoolAddress, 4, 8, -50, 50, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallDiagonalSpread(
        address univ3pool,
        int24 widthLong,
        int24 widthShort,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // Pool
        tokenId = tokenId.addUniv3pool(SFPM.getPoolId(univ3pool));

        // A call diagonal spread is composed of
        // 1. a long call with a (lower/higher) strike price and (lower/higher) width(expiry)
        // 2. a short call with a (higher/lower) strike price and (higher/lower) width(expiry)

        // Long call
        tokenId = addCallLeg(
            tokenId,
            start,
            optionRatio,
            asset,
            1,
            start + 1,
            strikeLong,
            widthLong
        );

        // Short call
        tokenId = addCallLeg(
            tokenId,
            start + 1,
            optionRatio,
            asset,
            0,
            start,
            strikeShort,
            widthShort
        );
    }

    /// @notice creates a diagonal spread with 1 long leg and 1 short leg.
    /// @dev example: createPutDiagonalSpread(uniPoolAddress, 4, 8, -50, 50, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strikeLong strike of the long leg
    /// @param strikeShort strike of the short leg
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutDiagonalSpread(
        address univ3pool,
        int24 widthLong,
        int24 widthShort,
        int24 strikeLong,
        int24 strikeShort,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // Pool
        tokenId = tokenId.addUniv3pool(SFPM.getPoolId(univ3pool));

        // A bearish diagonal spread is composed of
        // 1. a long put with a (higher/lower) strike price and (lower/higher) width(expiry)
        // 2. a short put with a (lower/higher) strike price and (higher/lower) width(expiry)

        // Long put
        tokenId = addPutLeg(
            tokenId,
            start,
            optionRatio,
            asset,
            1,
            start + 1,
            strikeLong,
            widthLong
        );

        // Short put
        tokenId = addPutLeg(
            tokenId,
            start + 1,
            optionRatio,
            asset,
            0,
            start,
            strikeShort,
            widthShort
        );
    }

    /// @notice creates a calendar spread with 1 long leg and 1 short leg.
    /// @dev example: createCallCalendarSpread(uniPoolAddress, 4, 8, 0, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strike strike of the long and short legs
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallCalendarSpread(
        address univ3pool,
        int24 widthLong,
        int24 widthShort,
        int24 strike,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // calendar spread is a diagonal spread where the legs have identical strike prices
        // so we can create one using the diagonal spread function
        tokenId = createCallDiagonalSpread(
            univ3pool,
            widthLong,
            widthShort,
            strike,
            strike,
            asset,
            optionRatio,
            start
        );
    }

    /// @notice creates a calendar spread with 1 long leg and 1 short leg.
    /// @dev example: createPutCalendarSpread(uniPoolAddress, 4, 8, 0, 0, 1, 0).
    /// @param univ3pool address of the pool
    /// @param widthLong width of the long leg
    /// @param widthShort width of the short leg
    /// @param strike strike of the long and short legs
    /// @param asset asset of the spread
    /// @param optionRatio relative size of the spread
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutCalendarSpread(
        address univ3pool,
        int24 widthLong,
        int24 widthShort,
        int24 strike,
        uint256 asset,
        uint256 optionRatio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // calendar spread is a diagonal spread where the legs have identical strike prices
        // so we can create one using the diagonal spread function
        tokenId = createPutDiagonalSpread(
            univ3pool,
            widthLong,
            widthShort,
            strike,
            strike,
            asset,
            optionRatio,
            start
        );
    }

    /// @notice creates iron condor w/ call and put spread.
    /// @dev example: createIronCondor(uniPoolAddress, 4, 50, -50, 50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param callStrike strike of the call spread
    /// @param putStrike strike of the put spread
    /// @param wingWidth width of the wings
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createIronCondor(
        address univ3pool,
        int24 width,
        int24 callStrike,
        int24 putStrike,
        int24 wingWidth,
        uint256 asset
    ) public view returns (uint256 tokenId) {
        // an iron condor is composed of
        // 1. a call spread
        // 2. a put spread
        // the "wings" represent how much more OTM the long sides of the spreads are

        // call spread
        tokenId = createCallSpread(
            univ3pool,
            width,
            callStrike + wingWidth,
            callStrike,
            asset,
            1,
            0
        );

        // put spread
        tokenId += createPutSpread(
            address(0),
            width,
            putStrike - wingWidth,
            putStrike,
            asset,
            1,
            2
        );
    }

    /// @notice creates a jade lizard w/ long call and short asymmetric (traditional) strangle.
    /// @dev example: createJadeLizard(uniPoolAddress, 4, 100, 50, -50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longCallStrike strike of the long call
    /// @param shortCallStrike strike of the short call
    /// @param shortPutStrike strike of the short put
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createJadeLizard(
        address univ3pool,
        int24 width,
        int24 longCallStrike,
        int24 shortCallStrike,
        int24 shortPutStrike,
        uint256 asset
    ) public view returns (uint256 tokenId) {
        // a jade lizard is composed of
        // 1. a short strangle
        // 2. a long call

        // short strangle
        tokenId = createStrangle(univ3pool, width, shortCallStrike, shortPutStrike, 0, asset, 1, 1);

        // long call
        tokenId = addCallLeg(tokenId, 0, 1, asset, 1, 0, longCallStrike, width);
    }

    /// @notice creates a big lizard w/ long call and short asymmetric (traditional) straddle.
    /// @dev example: createBigLizard(uniPoolAddress, 4, 100, 50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longCallStrike strike of the long call
    /// @param straddleStrike strike of the short straddle
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createBigLizard(
        address univ3pool,
        int24 width,
        int24 longCallStrike,
        int24 straddleStrike,
        uint256 asset
    ) public view returns (uint256 tokenId) {
        // a big lizard is composed of
        // 1. a short straddle
        // 2. a long call

        // short straddle
        tokenId = createStraddle(univ3pool, width, straddleStrike, 0, asset, 1, 1);

        // long call
        tokenId = addCallLeg(tokenId, 0, 1, asset, 1, 0, longCallStrike, width);
    }

    /// @notice creates a super bull w/ long call spread and short put.
    /// @dev example: createSuperBull(uniPoolAddress, 4, -50, 50, 50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longCallStrike strike of the long call
    /// @param shortCallStrike strike of the short call
    /// @param shortPutStrike strike of the short put
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createSuperBull(
        address univ3pool,
        int24 width,
        int24 longCallStrike,
        int24 shortCallStrike,
        int24 shortPutStrike,
        uint256 asset
    ) public view returns (uint256 tokenId) {
        // a super bull is composed of
        // 1. a long call spread
        // 2. a short put

        // long call spread
        tokenId = createCallSpread(univ3pool, width, longCallStrike, shortCallStrike, asset, 1, 1);

        // short put
        tokenId = addPutLeg(tokenId, 0, 1, asset, 0, 0, shortPutStrike, width);
    }

    /// @notice creates a super bear w/ long put spread and short call.
    /// @dev example: createSuperBear(uniPoolAddress, 4, 50, -50, -50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longPutStrike strike of the long put
    /// @param shortPutStrike strike of the short put
    /// @param shortCallStrike strike of the short call
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createSuperBear(
        address univ3pool,
        int24 width,
        int24 longPutStrike,
        int24 shortPutStrike,
        int24 shortCallStrike,
        uint256 asset
    ) public view returns (uint256 tokenId) {
        // a super bear is composed of
        // 1. a long put spread
        // 2. a short call

        // long put spread
        tokenId = createPutSpread(univ3pool, width, longPutStrike, shortPutStrike, asset, 1, 1);

        // short call
        tokenId = addCallLeg(tokenId, 0, 1, asset, 0, 0, shortCallStrike, width);
    }

    /// @notice creates a butterfly w/ long call spread and short put spread.
    /// @dev example: createIronButterfly(uniPoolAddress, 4, 0, 50, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param strike strike of the long and short legs
    /// @param wingWidth width of the wings
    /// @param asset asset of the strategy
    /// @return tokenId the position id with the strategy configured
    function createIronButterfly(
        address univ3pool,
        int24 width,
        int24 strike,
        int24 wingWidth,
        uint256 asset
    ) public view returns (uint256 tokenId) {
        // an iron butterfly is composed of
        // 1. a long call spread
        // 2. a short put spread

        // long call spread
        tokenId = createCallSpread(univ3pool, width, strike, strike + wingWidth, asset, 1, 0);

        // short put spread
        tokenId += createPutSpread(address(0), width, strike, strike - wingWidth, asset, 1, 2);
    }

    /// @notice creates a ratio spread w/ long call and multiple short calls.
    /// @dev example: createCallRatioSpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long call
    /// @param shortStrike strike of the short calls
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short calls to the long call
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured

    function createCallRatioSpread(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // Pool
        tokenId = tokenId.addUniv3pool(SFPM.getPoolId(univ3pool));

        // a call ratio spread is composed of
        // 1. a long call
        // 2. multiple short calls

        // long call
        tokenId = addCallLeg(tokenId, start, 1, asset, 1, start + 1, longStrike, width);

        // short calls
        tokenId = addCallLeg(tokenId, start + 1, ratio, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ratio spread w/ long put and multiple short puts.
    /// @dev example: createPutRatioSpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long put
    /// @param shortStrike strike of the short puts
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short puts to the long put
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutRatioSpread(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // Pool
        tokenId = tokenId.addUniv3pool(SFPM.getPoolId(univ3pool));

        // a put ratio spread is composed of
        // 1. a long put
        // 2. multiple short puts

        // long put
        tokenId = addPutLeg(tokenId, start, 1, asset, 1, start + 1, longStrike, width);

        // short puts
        tokenId = addPutLeg(tokenId, start + 1, ratio, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ZEBRA spread w/ short call and multiple long calls.
    /// @dev example: createCallZEBRASpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long calls
    /// @param shortStrike strike of the short call
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short call to the long calls
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createCallZEBRASpread(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // Pool
        tokenId = tokenId.addUniv3pool(SFPM.getPoolId(univ3pool));

        // a call ZEBRA(zero extrinsic value back ratio spread) spread is composed of
        // 1. a short call
        // 2. multiple long calls

        // long put
        tokenId = addCallLeg(tokenId, start, ratio, asset, 1, start + 1, longStrike, width);

        // short puts
        tokenId = addCallLeg(tokenId, start + 1, 1, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ZEBRA spread w/ short put and multiple long puts.
    /// @dev example: createPutZEBRASpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long puts
    /// @param shortStrike strike of the short put
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short put to the long puts
    /// @param start leg index where the (2 legs) of the spread begin (usually 0)
    /// @return tokenId the position id with the strategy configured
    function createPutZEBRASpread(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio,
        uint256 start
    ) public view returns (uint256 tokenId) {
        // Pool
        tokenId = tokenId.addUniv3pool(SFPM.getPoolId(univ3pool));

        // a put ZEBRA(zero extrinsic value back ratio spread) spread is composed of
        // 1. a short put
        // 2. multiple long puts

        // long puts
        tokenId = addPutLeg(tokenId, start, ratio, asset, 1, start + 1, longStrike, width);

        // short put
        tokenId = addPutLeg(tokenId, start + 1, 1, asset, 0, start, shortStrike, width);
    }

    /// @notice creates a ZEEHBS w/ call and put ZEBRA spreads.
    /// @dev example: createPutZEBRASpread(uniPoolAddress, 4, -50, 50, 0, 2, 0).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long legs
    /// @param shortStrike strike of the short legs
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short legs to the long legs
    /// @return tokenId the position id with the strategy configured
    function createZEEHBS(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio
    ) public view returns (uint256 tokenId) {
        // a ZEEHBS(Zero extrinsic hedged back spread) is composed of
        // 1. a call ZEBRA spread
        // 2. a put ZEBRA spread

        // call ZEBRA
        tokenId = createCallZEBRASpread(univ3pool, width, longStrike, shortStrike, asset, ratio, 0);

        // put ZEBRA
        tokenId += createPutZEBRASpread(
            address(0),
            width,
            longStrike,
            shortStrike,
            asset,
            ratio,
            2
        );
    }

    /// @notice creates a BATS (AKA double ratio spread) w/ call and put ratio spreads.
    /// @dev example: createBATS(uniPoolAddress, 4, -50, 50, 0, 2).
    /// @param univ3pool address of the pool
    /// @param width width of the spread
    /// @param longStrike strike of the long legs
    /// @param shortStrike strike of the short legs
    /// @param asset asset of the strategy
    /// @param ratio ratio of the short legs to the long legs
    /// @return tokenId the position id with the strategy configured
    function createBATS(
        address univ3pool,
        int24 width,
        int24 longStrike,
        int24 shortStrike,
        uint256 asset,
        uint256 ratio
    ) public view returns (uint256 tokenId) {
        // a BATS(double ratio spread) is composed of
        // 1. a call ratio spread
        // 2. a put ratio spread

        // call ratio spread
        tokenId = createCallRatioSpread(univ3pool, width, longStrike, shortStrike, asset, ratio, 0);

        // put ratio spread
        tokenId += createPutRatioSpread(
            address(0),
            width,
            longStrike,
            shortStrike,
            asset,
            ratio,
            2
        );
    }
}
