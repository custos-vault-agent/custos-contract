// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {FeedInvalid, NoPriceFeed, StalePrice, ZeroAddress} from "./Errors.sol";
import {FeedChanged} from "./Events.sol";

/// @notice Chainlink feed registry: token → value in the accounting asset (USDC).
///
/// @dev Explicit assumption: feeds are `<TOKEN>/USD` and USDC ≈ USD. A USDC depeg is
///      not modelled, same as the rest of the USDC-denominated allowance model.
///
///      Owner = upgradeAuthority. Registering a feed validates it (`aggregator()`
///      non-zero, `decimals()` readable, `latestRoundData()` positive and fresh) —
///      the H2 "safe oracle" gate: `setMarketAllowed` rejects markets whose base has
///      no feed here.
contract PriceOracle is IPriceOracle, Ownable {
    struct Feed {
        AggregatorV3Interface aggregator;
        uint32 maxStaleness;
        uint8 feedDecimals;
        uint8 tokenDecimals;
    }

    address public immutable quoteToken;
    uint8 internal immutable _quoteDecimals;

    mapping(address token => Feed) public feeds;

    constructor(address owner_, address quoteToken_) Ownable(owner_) {
        if (quoteToken_ == address(0)) revert ZeroAddress();
        quoteToken = quoteToken_;
        _quoteDecimals = IERC20Metadata(quoteToken_).decimals();
    }

    /// @param maxStaleness Max answer age; zero removes the feed.
    function setFeed(address token, AggregatorV3Interface aggregator, uint32 maxStaleness)
        external
        onlyOwner
    {
        if (token == address(0)) revert ZeroAddress();
        if (maxStaleness == 0) {
            delete feeds[token];
            emit FeedChanged(token, address(0), 0);
            return;
        }
        if (address(aggregator) == address(0) || aggregator.aggregator() == address(0)) revert FeedInvalid();
        uint8 feedDecimals = aggregator.decimals();
        Feed memory f = Feed({
            aggregator: aggregator,
            maxStaleness: maxStaleness,
            feedDecimals: feedDecimals,
            tokenDecimals: IERC20Metadata(token).decimals()
        });
        _price(f); // rejects a non-positive or stale feed at registration
        feeds[token] = f;
        emit FeedChanged(token, address(aggregator), maxStaleness);
    }

    function hasFeed(address token) external view returns (bool) {
        return address(feeds[token].aggregator) != address(0);
    }

    function valueOf(address token, uint256 amount) external view returns (uint256) {
        Feed memory f = feeds[token];
        if (address(f.aggregator) == address(0)) revert NoPriceFeed();
        // amount * price * 10^quoteDec / 10^(tokenDec + feedDec)
        return Math.mulDiv(
            amount, _price(f) * 10 ** _quoteDecimals, 10 ** (uint256(f.tokenDecimals) + f.feedDecimals)
        );
    }

    function _price(Feed memory f) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            f.aggregator.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert FeedInvalid();
        if (block.timestamp - updatedAt > f.maxStaleness) revert StalePrice();
        return uint256(answer);
    }
}
