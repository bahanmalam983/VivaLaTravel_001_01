// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title VivaLaTravel — compass-grade advisory registry for roaming parties
/// @notice Curators publish advisories; travelers reserve sessions, score routes, and tip guides.
/// @dev Hanami-12 successor lane: pull withdrawals, pausable council, no silent forwarding to anchors.

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/utils/Pausable.sol";

contract VivaLaTravel is ReentrancyGuard, Pausable {

    // --- immutables & anchors (inert; no auto-forward) ---

    address public immutable ADDRESS_A = 0x54BbA767cb43e6E4991b6B06Bd278Fb6C1b6B15F;
    address public immutable ADDRESS_B = 0x71ddBfB87B65f675a370a65F1E1dC835234bBCd7;
    address public immutable ADDRESS_C = 0x24A9859F62709E4Ad58c7398678A0037D30CC2C4;

    bytes32 public constant VLT_DOMAIN = keccak256("VivaLaTravel.routeDomain");
    bytes32 public constant VLT_REVIEW_TAG = keccak256("VivaLaTravel.reviewLane");
    uint256 public constant VLT_PROTOCOL_EDITION = 7;
    uint256 public constant MAX_ADVISORIES = 503;
    uint256 public constant MAX_ROUTE_STOPS = 31;
    uint256 public constant MAX_ROUTE_DAYS = 94;
    uint256 public constant MIN_ROUTE_DAYS = 2;
    uint256 public constant REVIEW_GAP_BLOCKS = 241;
    uint256 public constant MAX_REVIEWS_PER_ADVISORY = 3;
    uint256 public constant RATING_FLOOR = 1;
    uint256 public constant RATING_CEIL = 5;
    uint256 public constant SESSION_FEE_BP = 73;
    uint256 public constant BATCH_CAP = 19;
    uint256 public constant MAX_ACTIVE_SESSIONS = 88;

    struct AdvisoryCard {
        bytes32 cardId;
        uint8 climateBand;
        bytes32 headlineHash;
        uint256 listedBlock;
        bool retired;
        uint256 reviewTally;
        uint256 ratingSum;
    }

    struct RouteSketch {
        uint256 sketchId;
        bytes32[] stopIds;
        uint256 daySpan;
        address planner;
        uint256 mintedBlock;
        bool sealed;
    }

    struct GuideProfile {
        address wallet;
        bytes32 bioHash;
        uint256 joinedBlock;
        bool active;
        uint256 sessionsHosted;
    }

    struct AdvisorySession {
        uint256 sessionId;
        bytes32 cardId;
        address traveler;
        address guide;
        uint256 depositWei;
        uint256 openedBlock;
        bool settled;
        bool cancelled;
    }

    mapping(bytes32 => AdvisoryCard) private _cards;
    bytes32[] private _cardIndex;
