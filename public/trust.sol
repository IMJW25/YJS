//trust.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ChatTrust {
    struct Member {
        address addr;
        bool isOfficial;
        uint256 certification;
        uint256 joinTime;
        uint256 initialYesVotes;
        uint256 clickCount;
    }
    mapping(address => Member) public members;
    address[] public memberList;
    mapping(address => mapping(address => uint256)) public relationshipScore;
    mapping(address => mapping(address => bool)) public hasClicked;
    event MemberApproved(address indexed member, uint256 certification);
    event MemberRemoved(address indexed member);
    event LinkClicked(address indexed from, address indexed to, uint256 relScore, uint256 certScore);
    modifier onlyOfficial() {
        require(members[msg.sender].isOfficial, "Not official member");
        _;
    }

    // 6개 초기 멤버를 각각 입력 받는 생성자
    constructor(
        address initAddr0,
        address initAddr1,
        address initAddr2,
        address initAddr3,
        address initAddr4,
        address initAddr5
    ) {
        address[6] memory initialAddrs = [initAddr0, initAddr1, initAddr2, initAddr3, initAddr4, initAddr5];
        for (uint256 i = 0; i < 6; i++) {
            members[initialAddrs[i]] = Member(initialAddrs[i], true, 0, block.timestamp, 0, 0);
            memberList.push(initialAddrs[i]);
        }
    }

    // 이하 기존 함수들은 그대로...
    function getPairRelationship(address a, address b) public view returns (uint256) {
        uint256 scoreA = relationshipScore[a][b];
        uint256 scoreB = relationshipScore[b][a];
        return scoreA + scoreB;
    }
    function getPersonalRelationshipScore(address member) public view returns (uint256) {
        uint256 total = 0;
        uint256 cnt = 0;
        for (uint256 i = 0; i < memberList.length; i++) {
            address other = memberList[i];
            if (other == member) continue;
            if (!members[other].isOfficial) continue;
            total += getPairRelationship(member, other);
            cnt++;
        }
        if (cnt == 0) return 0;
        return total / cnt;
    }
    function clickLink(address target) external onlyOfficial {
        require(members[target].isOfficial, "Target not official");
        require(!hasClicked[msg.sender][target], "Already clicked");
        if (relationshipScore[msg.sender][target] == 0) {
            relationshipScore[msg.sender][target] = 500;
        }
        hasClicked[msg.sender][target] = true;
        members[target].clickCount++;
        _updateCertification(target);
        emit LinkClicked(msg.sender, target, getPairRelationship(msg.sender, target), members[target].certification);
    }
    function _updateCertification(address target) internal {
        uint256 totalMembers = memberList.length;
        members[target].certification = ( (members[target].initialYesVotes + members[target].clickCount) * 1000 ) / totalMembers;
    }
    function getVerifiersCount() public view returns (uint256) {
        uint256 n = memberList.length;
        if (n < 4) return n;
        else if (n <= 10) return 3;
        else if (n <= 99) return 5;
        else return 10;
    }
    function getVerifiers() public view returns (address[] memory) {
        uint256 num = getVerifiersCount();
        address[] memory sorted = memberList;
        for (uint256 i = 0; i < sorted.length; i++) {
            for (uint256 j = i+1; j < sorted.length; j++) {
                if (members[sorted[j]].certification > members[sorted[i]].certification) {
                    address tmp = sorted[i];
                    sorted[i] = sorted[j];
                    sorted[j] = tmp;
                }
            }
        }
        address[] memory top = new address[](num);
        for (uint256 k = 0; k < num; k++) {
            top[k] = sorted[k];
        }
        return top;
    }
    function approveCandidate(address candidate, uint256 yesVotes, uint256 verifierCount) external onlyOfficial {
        require(!members[candidate].isOfficial, "Already member");
        uint256 ratioMilli = (yesVotes * 1000) / verifierCount;
        require(ratioMilli >= 667, "Fail: Not enough approvals (2/3 required)");
        members[candidate] = Member(candidate, true, (yesVotes * 1000) / memberList.length, block.timestamp, yesVotes, 0);
        memberList.push(candidate);
        emit MemberApproved(candidate, members[candidate].certification);
    }
    function getMemberCount() public view returns (uint256) {
        return memberList.length;
    }
}
