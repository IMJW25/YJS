// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title SingleRoomClickToTrust_MetaMask_Report
 * @notice 단일 방. 멤버=메타마스크 지갑. "클릭=찬성".
 *         멤버들이 '신고(report)'하면 신고된 사용자의 임계값이 상승(패널티)하여
 *         신뢰 확정이 어려워진다 = 신뢰도 하락 효과.
 */
contract SingleRoomClickToTrust_MetaMask_Report {
    // ───────── Events ─────────
    event MemberJoined(address indexed member, uint256 totalMembers, uint256 activeMembers);
    event BaselineFrozen(uint256 baselineMembers);
    event LinkPosted(bytes32 indexed linkId, address indexed subject, string url, uint256 subjectPostSeq);
    event LinkClicked(bytes32 indexed linkId, address indexed clicker, uint256 clicks);
    event SubjectFinalized(address indexed subject, bytes32 linkId, uint256 clicksOnLink, uint256 baselineMembers);
    event SubjectReported(address indexed reporter, address indexed subject, uint256 totalReports, uint16 penaltyBps);

    // ───────── Errors ─────────
    error NotMember();
    error SelfClickNotAllowed();
    error AlreadyClicked();
    error LinkNotFound();
    error AlreadyFinalized();
    error AlreadyMember();
    error InvalidAddr();
    error AlreadyReported();
    error CannotReportSelf();
    error SubjectNotMember();

    // ───────── Config ─────────
    /// @dev 임계값/패널티는 bps(10000=100%) 단위
    uint16 public immutable THRESHOLD_BPS;     // 기본 임계값 (예: 5000 = 50%)
    uint16 public immutable REPORT_STEP_BPS;   // 신고 1건당 임계 가중치 (예: 200 = 2%p)
    uint16 public immutable MAX_PENALTY_BPS;   // 패널티 상한 (예: 3000 = +30%p)

    constructor(uint16 thresholdBps_, uint16 reportStepBps_, uint16 maxPenaltyBps_) {
        THRESHOLD_BPS   = thresholdBps_   == 0 ? 5000 : thresholdBps_;
        REPORT_STEP_BPS = reportStepBps_  == 0 ?  200 : reportStepBps_;  // 기본 2%p/신고
        MAX_PENALTY_BPS = maxPenaltyBps_;                                 // 0이면 제한 없음
    }

    // ───────── Membership / Baseline ─────────
    mapping(address => bool) public isMember;
    uint256 public totalMembers;
    uint256 public activeMembers;   // 탈퇴 개념이 없으니 total=active로 사용(확장 여지)
    uint256 public baselineMembers; // 고정 모수
    bool    public baselineFrozen;

    // ───────── Link & Subject State ─────────
    struct Link {
        address subject;     // 작성자(멤버)
        string  url;
        uint256 clicks;      // 고유 클릭 수
        bool    exists;
        mapping(address => bool) clicked;
    }
    struct SubjectState {
        bool   finalized;
        bool   trusted;
        uint64 finalizedAt;
    }

    mapping(address => uint256) private _postSeq;
    mapping(bytes32 => Link)    private _links;
    mapping(address => SubjectState) private _subject;

    // ───────── Reports ─────────
    mapping(address => uint256) public subjectReportCount;                  // subject => 신고 수
    mapping(address => mapping(address => bool)) public hasReportedSubject; // reporter => subject => 이미 신고했는지

    // ───────── Views ─────────
    function getSubjectState(address subject) external view returns (bool finalized, bool trusted, uint64 finalizedAt) {
        SubjectState memory s = _subject[subject];
        return (s.finalized, s.trusted, s.finalizedAt);
    }

    function getLinkMeta(bytes32 linkId) external view returns (address subject, string memory url, uint256 clicks, bool exists) {
        Link storage L = _links[linkId];
        return (L.subject, L.url, L.clicks, L.exists);
    }

    function hasClicked(bytes32 linkId, address user) external view returns (bool) {
        Link storage L = _links[linkId];
        if (!L.exists) return false;
        return L.clicked[user];
    }

    function isTrusted(address subject) external view returns (bool) {
        SubjectState memory s = _subject[subject];
        return s.finalized && s.trusted;
    }

    /// @notice subject의 현재 패널티(bps)
    function penaltyBps(address subject) public view returns (uint16) {
        uint256 p = subjectReportCount[subject] * REPORT_STEP_BPS;
        if (MAX_PENALTY_BPS != 0 && p > MAX_PENALTY_BPS) p = MAX_PENALTY_BPS;
        if (p > 10000) p = 10000; // 안전 클램프
        return uint16(p);
    }

    /// @notice subject에게 적용되는 현재 임계값(bps) = 기본 + 패널티(클램프 10000)
    function currentThresholdBps(address subject) public view returns (uint16) {
        uint256 t = THRESHOLD_BPS + penaltyBps(subject);
        if (t > 10000) t = 10000;
        return uint16(t);
    }

    // ───────── Membership ─────────
    function join() public {
        if (msg.sender == address(0)) revert InvalidAddr();
        if (isMember[msg.sender]) revert AlreadyMember();
        isMember[msg.sender] = true;
        totalMembers += 1;
        activeMembers += 1;
        emit MemberJoined(msg.sender, totalMembers, activeMembers);

        // 자동 baseline 고정: 10명 이상 되는 순간 1회
        if (!baselineFrozen && activeMembers >= 10) {
            baselineMembers = activeMembers;
            baselineFrozen = true;
            emit BaselineFrozen(baselineMembers);
        }
    }

    function joinAndClick(bytes32 linkId) external {
        if (!isMember[msg.sender]) {
            join();
        }
        click(linkId);
    }

    // ───────── Posting & Clicking ─────────
    function postLink(string calldata url) external returns (bytes32 linkId) {
        if (!isMember[msg.sender]) revert NotMember();

        uint256 seq = ++_postSeq[msg.sender];
        linkId = keccak256(abi.encodePacked(msg.sender, seq));

        Link storage L = _links[linkId];
        L.subject = msg.sender;
        L.url = url;
        L.exists = true;

        emit LinkPosted(linkId, msg.sender, url, seq);
    }

    function click(bytes32 linkId) public {
        Link storage L = _links[linkId];
        if (!L.exists) revert LinkNotFound();
        if (!isMember[msg.sender]) revert NotMember();

        SubjectState storage S = _subject[L.subject];
        if (S.finalized) revert AlreadyFinalized();
        if (msg.sender == L.subject) revert SelfClickNotAllowed();
        if (L.clicked[msg.sender]) revert AlreadyClicked();

        L.clicked[msg.sender] = true;
        L.clicks += 1;

        emit LinkClicked(linkId, msg.sender, L.clicks);
        _checkAndFinalize(L, linkId);
    }

    /// @notice baseline 뒤늦게 고정된 후 과반이 이미 넘었으면 확정 트리거
    function poke(bytes32 linkId) external {
        Link storage L = _links[linkId];
        if (!L.exists) revert LinkNotFound();
        SubjectState storage S = _subject[L.subject];
        if (S.finalized) revert AlreadyFinalized();
        _checkAndFinalize(L, linkId);
    }

    // ───────── Reports ─────────
    /// @notice 멤버가 subject를 1회 신고(중복 불가). 본인 신고는 금지.
    function report(address subject) external {
        if (!isMember[msg.sender]) revert NotMember();
        if (!isMember[subject]) revert SubjectNotMember();
        if (msg.sender == subject) revert CannotReportSelf();
        if (hasReportedSubject[msg.sender][subject]) revert AlreadyReported();

        hasReportedSubject[msg.sender][subject] = true;
        subjectReportCount[subject] += 1;

        emit SubjectReported(msg.sender, subject, subjectReportCount[subject], penaltyBps(subject));
    }

    // ───────── Internal ─────────
    function _checkAndFinalize(Link storage L, bytes32 linkId) internal {
        if (!baselineFrozen || baselineMembers == 0) return;
        uint256 thr = currentThresholdBps(L.subject);
        // 과반수(가중 임계) 이상 달성 시 확정
        if (L.clicks * 10000 >= baselineMembers * thr) {
            SubjectState storage S = _subject[L.subject];
            S.finalized  = true;
            S.trusted    = true;
            S.finalizedAt = uint64(block.timestamp);
            emit SubjectFinalized(L.subject, linkId, L.clicks, baselineMembers);
        }
    }
}
