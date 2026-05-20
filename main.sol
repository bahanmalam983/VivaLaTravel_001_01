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
    mapping(uint256 => RouteSketch) private _sketches;
    uint256 private _nextSketchId;
    mapping(address => GuideProfile) public guides;
    mapping(uint256 => AdvisorySession) private _sessions;
    uint256 private _nextSessionId;
    mapping(bytes32 => mapping(address => uint256)) private _reviewCount;
    mapping(address => uint256) private _lastReviewBlock;
    mapping(address => uint256) private _travelerSessionCount;

    address public voyageDirector;
    address public pendingDirector;
    address public compassCouncil;
    address public routingClerk;
    uint256 public seasonEpoch;
    uint256 public treasuryBalance;
    uint256 public totalTipsWei;
    uint256 public totalSessionsOpened;

    error VLT_NotDirector(address who);
    error VLT_NotCouncil(address who);
    error VLT_NotClerk(address who);
    error VLT_NotPendingDirector(address who);
    error VLT_ZeroAddr();
    error VLT_CardExists(bytes32 id);
    error VLT_CardMissing(bytes32 id);
    error VLT_CardRetired(bytes32 id);
    error VLT_BadClimate(uint8 band);
    error VLT_BadRating(uint8 score);
    error VLT_ReviewGap(uint256 nextBlock);
    error VLT_ReviewCap(bytes32 id, address traveler);
    error VLT_SketchEmpty();
    error VLT_SketchTooLong(uint256 len);
    error VLT_SketchDays(uint256 days);
    error VLT_SketchMissing(uint256 id);
    error VLT_NotPlanner(uint256 id, address who);
    error VLT_SketchSealed(uint256 id);
    error VLT_GuideActive(address g);
    error VLT_GuideInactive(address g);
    error VLT_SessionMissing(uint256 id);
    error VLT_SessionSettled(uint256 id);
    error VLT_SessionCancelled(uint256 id);
    error VLT_NotSessionParty(uint256 id, address who);
    error VLT_DepositLow(uint256 got, uint256 need);
    error VLT_ArrayMismatch();
    error VLT_BatchOver();
    error VLT_CapReached();
    error VLT_WithdrawFail();
    error VLT_DirectEth();
    error VLT_TooManySessions(address traveler);

    event VLT_AdvisoryListed(bytes32 indexed cardId, uint8 climateBand, bytes32 headlineHash, address indexed curator);
    event VLT_AdvisoryRetired(bytes32 indexed cardId, uint256 blockNum);
    event VLT_RouteMinted(uint256 indexed sketchId, address indexed planner, uint256 daySpan);
    event VLT_RouteSealed(uint256 indexed sketchId);
    event VLT_ReviewLogged(bytes32 indexed cardId, address indexed traveler, uint8 rating, bytes32 noteHash);
    event VLT_GuideJoined(address indexed guide, bytes32 bioHash);
    event VLT_GuideLeft(address indexed guide);
    event VLT_SessionOpened(uint256 indexed sessionId, bytes32 cardId, address traveler, address guide, uint256 deposit);
    event VLT_SessionSettled(uint256 indexed sessionId, uint256 payout, uint256 fee);
    event VLT_SessionCancelled(uint256 indexed sessionId);
    event VLT_TipRelayed(address indexed fromAddr, address indexed guide, uint256 gross, uint256 fee);
    event VLT_SeasonShifted(uint256 oldEpoch, uint256 newEpoch);
    event VLT_DirectorHandoff(address indexed prev, address indexed next);
    event VLT_CouncilRotated(address indexed prev, address indexed next);
    event VLT_TreasuryPulled(address indexed to, uint256 amount);

    modifier onlyDirector() {
        if (msg.sender != voyageDirector) revert VLT_NotDirector(msg.sender);
        _;
    }

    modifier onlyCouncil() {
        if (msg.sender != compassCouncil) revert VLT_NotCouncil(msg.sender);
        _;
    }

    modifier onlyClerk() {
        if (msg.sender != routingClerk) revert VLT_NotClerk(msg.sender);
        _;
    }

    constructor() {
        voyageDirector = msg.sender;
        compassCouncil = msg.sender;
        routingClerk = msg.sender;
        seasonEpoch = 1;
        _nextSketchId = 1;
        _nextSessionId = 1;
    }

    receive() external payable {
        revert VLT_DirectEth();
    }

    fallback() external payable {
        revert VLT_DirectEth();
    }

    function listAdvisory(bytes32 cardId, uint8 climateBand, bytes32 headlineHash) external onlyDirector whenNotPaused {
        if (cardId == bytes32(0)) revert VLT_ZeroAddr();
        if (climateBand == 0 || climateBand > 12) revert VLT_BadClimate(climateBand);
        if (_cards[cardId].listedBlock != 0) revert VLT_CardExists(cardId);
        if (_cardIndex.length >= MAX_ADVISORIES) revert VLT_CapReached();
        _cards[cardId] = AdvisoryCard({
            cardId: cardId,
            climateBand: climateBand,
            headlineHash: headlineHash,
            listedBlock: block.number,
            retired: false,
            reviewTally: 0,
            ratingSum: 0
        });
        _cardIndex.push(cardId);
        emit VLT_AdvisoryListed(cardId, climateBand, headlineHash, msg.sender);
    }

    function retireAdvisory(bytes32 cardId) external onlyCouncil {
        AdvisoryCard storage c = _cards[cardId];
        if (c.listedBlock == 0) revert VLT_CardMissing(cardId);
        if (c.retired) revert VLT_CardRetired(cardId);
        c.retired = true;
        emit VLT_AdvisoryRetired(cardId, block.number);
    }

    function mintRoute(bytes32[] calldata stopIds, uint256 daySpan) external whenNotPaused returns (uint256 sketchId) {
        if (stopIds.length == 0) revert VLT_SketchEmpty();
        if (stopIds.length > MAX_ROUTE_STOPS) revert VLT_SketchTooLong(stopIds.length);
        if (daySpan < MIN_ROUTE_DAYS || daySpan > MAX_ROUTE_DAYS) revert VLT_SketchDays(daySpan);
        for (uint256 i = 0; i < stopIds.length; ++i) {
            if (_cards[stopIds[i]].listedBlock == 0) revert VLT_CardMissing(stopIds[i]);
        }
        sketchId = _nextSketchId++;
        RouteSketch storage s = _sketches[sketchId];
        s.sketchId = sketchId;
        s.daySpan = daySpan;
        s.planner = msg.sender;
        s.mintedBlock = block.number;
        for (uint256 j = 0; j < stopIds.length; ++j) {
            s.stopIds.push(stopIds[j]);
        }
        emit VLT_RouteMinted(sketchId, msg.sender, daySpan);
    }

    function sealRoute(uint256 sketchId) external {
        RouteSketch storage s = _sketches[sketchId];
        if (s.mintedBlock == 0) revert VLT_SketchMissing(sketchId);
        if (s.planner != msg.sender && msg.sender != voyageDirector) revert VLT_NotPlanner(sketchId, msg.sender);
        if (s.sealed) revert VLT_SketchSealed(sketchId);
        s.sealed = true;
        emit VLT_RouteSealed(sketchId);
    }

    function registerGuide(bytes32 bioHash) external whenNotPaused {
        if (guides[msg.sender].active) revert VLT_GuideActive(msg.sender);
        guides[msg.sender] = GuideProfile({
            wallet: msg.sender,
            bioHash: bioHash,
            joinedBlock: block.number,
            active: true,
            sessionsHosted: 0
        });
        emit VLT_GuideJoined(msg.sender, bioHash);
    }

    function leaveGuideRoster() external {
        if (!guides[msg.sender].active) revert VLT_GuideInactive(msg.sender);
        guides[msg.sender].active = false;
        emit VLT_GuideLeft(msg.sender);
    }

    function postReview(bytes32 cardId, uint8 rating, bytes32 noteHash) external whenNotPaused {
        AdvisoryCard storage c = _cards[cardId];
        if (c.listedBlock == 0) revert VLT_CardMissing(cardId);
        if (c.retired) revert VLT_CardRetired(cardId);
        if (rating < RATING_FLOOR || rating > RATING_CEIL) revert VLT_BadRating(rating);
        uint256 nxt = _lastReviewBlock[msg.sender] + REVIEW_GAP_BLOCKS;
        if (block.number < nxt) revert VLT_ReviewGap(nxt);
        if (_reviewCount[cardId][msg.sender] >= MAX_REVIEWS_PER_ADVISORY) revert VLT_ReviewCap(cardId, msg.sender);
        _reviewCount[cardId][msg.sender]++;
        _lastReviewBlock[msg.sender] = block.number;
        c.reviewTally++;
        c.ratingSum += rating;
        emit VLT_ReviewLogged(cardId, msg.sender, rating, noteHash);
    }

    function openSession(bytes32 cardId, address guide) external payable whenNotPaused nonReentrant returns (uint256 sessionId) {
        if (guide == address(0)) revert VLT_ZeroAddr();
        if (!guides[guide].active) revert VLT_GuideInactive(guide);
        AdvisoryCard storage c = _cards[cardId];
        if (c.listedBlock == 0) revert VLT_CardMissing(cardId);
        if (c.retired) revert VLT_CardRetired(cardId);
        if (_travelerSessionCount[msg.sender] >= MAX_ACTIVE_SESSIONS) revert VLT_TooManySessions(msg.sender);
        uint256 minDeposit = 0.001 ether;
        if (msg.value < minDeposit) revert VLT_DepositLow(msg.value, minDeposit);
        sessionId = _nextSessionId++;
        _sessions[sessionId] = AdvisorySession({
            sessionId: sessionId,
            cardId: cardId,
            traveler: msg.sender,
            guide: guide,
            depositWei: msg.value,
            openedBlock: block.number,
            settled: false,
            cancelled: false
        });
        _travelerSessionCount[msg.sender]++;
        totalSessionsOpened++;
        emit VLT_SessionOpened(sessionId, cardId, msg.sender, guide, msg.value);
    }

    function settleSession(uint256 sessionId) external nonReentrant {
        AdvisorySession storage s = _sessions[sessionId];
        if (s.openedBlock == 0) revert VLT_SessionMissing(sessionId);
        if (s.settled) revert VLT_SessionSettled(sessionId);
        if (s.cancelled) revert VLT_SessionCancelled(sessionId);
        if (msg.sender != s.guide && msg.sender != voyageDirector) revert VLT_NotSessionParty(sessionId, msg.sender);
        s.settled = true;
        _travelerSessionCount[s.traveler]--;
        guides[s.guide].sessionsHosted++;
        uint256 fee = (s.depositWei * SESSION_FEE_BP) / 10_000;
        uint256 payout = s.depositWei - fee;
        treasuryBalance += fee;
        (bool ok, ) = s.guide.call{value: payout}("");
        if (!ok) revert VLT_WithdrawFail();
        emit VLT_SessionSettled(sessionId, payout, fee);
    }

    function cancelSession(uint256 sessionId) external nonReentrant {
        AdvisorySession storage s = _sessions[sessionId];
        if (s.openedBlock == 0) revert VLT_SessionMissing(sessionId);
        if (s.settled) revert VLT_SessionSettled(sessionId);
        if (s.cancelled) revert VLT_SessionCancelled(sessionId);
        if (msg.sender != s.traveler && msg.sender != voyageDirector) revert VLT_NotSessionParty(sessionId, msg.sender);
        s.cancelled = true;
        _travelerSessionCount[s.traveler]--;
        uint256 refund = s.depositWei;
        (bool ok, ) = s.traveler.call{value: refund}("");
        if (!ok) revert VLT_WithdrawFail();
        emit VLT_SessionCancelled(sessionId);
    }

    function tipGuide(address guide) external payable whenNotPaused nonReentrant {
        if (!guides[guide].active) revert VLT_GuideInactive(guide);
        if (msg.value == 0) revert VLT_DepositLow(0, 1);
        uint256 fee = (msg.value * SESSION_FEE_BP) / 10_000;
        uint256 net = msg.value - fee;
        treasuryBalance += fee;
        totalTipsWei += msg.value;
        (bool ok, ) = guide.call{value: net}("");
        if (!ok) revert VLT_WithdrawFail();
        emit VLT_TipRelayed(msg.sender, guide, msg.value, fee);
    }

    function pullTreasury(address to, uint256 amount) external onlyDirector nonReentrant {
        if (to == address(0)) revert VLT_ZeroAddr();
        if (amount > treasuryBalance) revert VLT_DepositLow(treasuryBalance, amount);
        treasuryBalance -= amount;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert VLT_WithdrawFail();
        emit VLT_TreasuryPulled(to, amount);
    }

    function beginDirectorTransfer(address nextDirector) external onlyDirector {
        if (nextDirector == address(0)) revert VLT_ZeroAddr();
        pendingDirector = nextDirector;
    }

    function acceptDirectorRole() external {
        if (msg.sender != pendingDirector) revert VLT_NotPendingDirector(msg.sender);
        address prev = voyageDirector;
        voyageDirector = pendingDirector;
        pendingDirector = address(0);
        emit VLT_DirectorHandoff(prev, voyageDirector);
    }

    function rotateCouncil(address nextCouncil) external onlyDirector {
        if (nextCouncil == address(0)) revert VLT_ZeroAddr();
        address prev = compassCouncil;
        compassCouncil = nextCouncil;
        emit VLT_CouncilRotated(prev, nextCouncil);
    }

    function bumpSeason() external onlyCouncil {
        uint256 prev = seasonEpoch;
        seasonEpoch = prev + 1;
        emit VLT_SeasonShifted(prev, seasonEpoch);
    }

    function councilPause() external onlyCouncil { _pause(); }
    function councilUnpause() external onlyCouncil { _unpause(); }

    function batchListAdvisories(
        bytes32[] calldata cardIds,
        uint8[] calldata bands,
        bytes32[] calldata hashes
    ) external onlyDirector whenNotPaused {
        if (cardIds.length != bands.length || cardIds.length != hashes.length) revert VLT_ArrayMismatch();
        if (cardIds.length > BATCH_CAP) revert VLT_BatchOver();
        for (uint256 i = 0; i < cardIds.length; ++i) {
            bytes32 cid = cardIds[i];
            uint8 band = bands[i];
            bytes32 hsh = hashes[i];
            if (cid == bytes32(0)) revert VLT_ZeroAddr();
            if (band == 0 || band > 12) revert VLT_BadClimate(band);
            if (_cards[cid].listedBlock != 0) revert VLT_CardExists(cid);
            if (_cardIndex.length >= MAX_ADVISORIES) revert VLT_CapReached();
            _cards[cid] = AdvisoryCard({
                cardId: cid, climateBand: band, headlineHash: hsh,
                listedBlock: block.number, retired: false, reviewTally: 0, ratingSum: 0
            });
            _cardIndex.push(cid);
            emit VLT_AdvisoryListed(cid, band, hsh, msg.sender);
        }
    }

    function probeCardStats_0(bytes32 cardId) external view returns (uint256 listed, uint256 tally, uint256 avgRating, bool retired) {
        AdvisoryCard storage c = _cards[cardId];
        listed = c.listedBlock;
        tally = c.reviewTally;
        retired = c.retired;
        avgRating = tally == 0 ? 0 : c.ratingSum / tally;
    }

    function probeSketchMeta_0(uint256 sketchId) external view returns (address planner, uint256 daySpan, bool sealed, uint256 stopCount) {
        RouteSketch storage s = _sketches[sketchId];
        planner = s.planner;
        daySpan = s.daySpan;
        sealed = s.sealed;
        stopCount = s.stopIds.length;
    }

    function probeSessionLane_0(uint256 sessionId) external view returns (address traveler, address guide, uint256 deposit, bool settled, bool cancelled) {
        AdvisorySession storage s = _sessions[sessionId];
        traveler = s.traveler;
        guide = s.guide;
        deposit = s.depositWei;
        settled = s.settled;
        cancelled = s.cancelled;
    }

    function anchorEcho_0() external view returns (address a, address b, address c) {
        a = ADDRESS_A; b = ADDRESS_B; c = ADDRESS_C;
    }

    function probeCardStats_1(bytes32 cardId) external view returns (uint256 listed, uint256 tally, uint256 avgRating, bool retired) {
        AdvisoryCard storage c = _cards[cardId];
        listed = c.listedBlock;
        tally = c.reviewTally;
        retired = c.retired;
        avgRating = tally == 0 ? 0 : c.ratingSum / tally;
    }

    function probeSketchMeta_1(uint256 sketchId) external view returns (address planner, uint256 daySpan, bool sealed, uint256 stopCount) {
        RouteSketch storage s = _sketches[sketchId];
        planner = s.planner;
        daySpan = s.daySpan;
        sealed = s.sealed;
        stopCount = s.stopIds.length;
    }

    function probeSessionLane_1(uint256 sessionId) external view returns (address traveler, address guide, uint256 deposit, bool settled, bool cancelled) {
        AdvisorySession storage s = _sessions[sessionId];
        traveler = s.traveler;
        guide = s.guide;
        deposit = s.depositWei;
        settled = s.settled;
        cancelled = s.cancelled;
    }

    function anchorEcho_1() external view returns (address a, address b, address c) {
        a = ADDRESS_A; b = ADDRESS_B; c = ADDRESS_C;
    }

    function probeCardStats_2(bytes32 cardId) external view returns (uint256 listed, uint256 tally, uint256 avgRating, bool retired) {
        AdvisoryCard storage c = _cards[cardId];
        listed = c.listedBlock;
        tally = c.reviewTally;
        retired = c.retired;
        avgRating = tally == 0 ? 0 : c.ratingSum / tally;
    }

    function probeSketchMeta_2(uint256 sketchId) external view returns (address planner, uint256 daySpan, bool sealed, uint256 stopCount) {
        RouteSketch storage s = _sketches[sketchId];
        planner = s.planner;
        daySpan = s.daySpan;
        sealed = s.sealed;
        stopCount = s.stopIds.length;
    }

    function probeSessionLane_2(uint256 sessionId) external view returns (address traveler, address guide, uint256 deposit, bool settled, bool cancelled) {
        AdvisorySession storage s = _sessions[sessionId];
        traveler = s.traveler;
        guide = s.guide;
        deposit = s.depositWei;
        settled = s.settled;
        cancelled = s.cancelled;
    }

    function anchorEcho_2() external view returns (address a, address b, address c) {
        a = ADDRESS_A; b = ADDRESS_B; c = ADDRESS_C;
    }

    function probeCardStats_3(bytes32 cardId) external view returns (uint256 listed, uint256 tally, uint256 avgRating, bool retired) {
        AdvisoryCard storage c = _cards[cardId];
        listed = c.listedBlock;
        tally = c.reviewTally;
        retired = c.retired;
        avgRating = tally == 0 ? 0 : c.ratingSum / tally;
    }

    function probeSketchMeta_3(uint256 sketchId) external view returns (address planner, uint256 daySpan, bool sealed, uint256 stopCount) {
        RouteSketch storage s = _sketches[sketchId];
        planner = s.planner;
        daySpan = s.daySpan;
        sealed = s.sealed;
        stopCount = s.stopIds.length;
    }

    function probeSessionLane_3(uint256 sessionId) external view returns (address traveler, address guide, uint256 deposit, bool settled, bool cancelled) {
        AdvisorySession storage s = _sessions[sessionId];
        traveler = s.traveler;
        guide = s.guide;
        deposit = s.depositWei;
        settled = s.settled;
        cancelled = s.cancelled;
    }

    function anchorEcho_3() external view returns (address a, address b, address c) {
        a = ADDRESS_A; b = ADDRESS_B; c = ADDRESS_C;
    }

    function probeCardStats_4(bytes32 cardId) external view returns (uint256 listed, uint256 tally, uint256 avgRating, bool retired) {
        AdvisoryCard storage c = _cards[cardId];
        listed = c.listedBlock;
        tally = c.reviewTally;
        retired = c.retired;
        avgRating = tally == 0 ? 0 : c.ratingSum / tally;
    }
