// dapp.js (ESM)
import { ethers } from "https://cdn.jsdelivr.net/npm/ethers@6.13.2/dist/ethers.min.js";

// =============== CONFIG ===============
// 여기에 실제 배포된 스마트 컨트랙트 주소를 입력하세요. (0x... 형식)
const CONTRACT = "0x8464135cf8F25Da09e49BV8782676a84730C318bC"; 
// Hardhat 로컬 노드나 Testnet RPC URL
// 예: const RPC_URL = "http://127.0.0.1:8545";
const API = "https://juwon-link-backend.onrender.com"; // 인덱서 API (없어도 작동)

const ABI = [
  // write
  "function join() public",
  "function postLink(string url) external returns (bytes32)",
  "function click(bytes32 linkId) public",
  "function report(address subject) external",

  // read
  "function isTrusted(address subject) external view returns (bool)",
  "function currentThresholdBps(address subject) external view returns (uint16)",
  "function penaltyBps(address subject) external view returns (uint16)",
  "function subjectReportCount(address subject) external view returns (uint256)",
  "function baselineMembers() view returns (uint256)",
  "function baselineFrozen() view returns (bool)",
  "function getLinkMeta(bytes32) view returns (address subject,string url,uint256 clicks,bool exists)",

  // events
  "event LinkPosted(bytes32 indexed linkId, address indexed subject, string url, uint256 subjectPostSeq)",
  "event LinkClicked(bytes32 indexed linkId, address indexed clicker, uint256 clicks)",
  "event SubjectReported(address indexed reporter, address indexed subject, uint256 totalReports, uint16 penaltyBps)",
  "event SubjectFinalized(address indexed subject, bytes32 linkId, uint256 clicksOnLink, uint256 baselineMembers)"
];

// =============== Ethers setup ===============
let _provider, _signer, _contract, _me;

async function ensureSetup() {
  if (!_provider) {
    if (!window.ethereum) {
      throw new Error("MetaMask가 설치되어 있지 않습니다.");
    }
    _provider = new ethers.BrowserProvider(window.ethereum);
  }
  if (!_signer) _signer = await _provider.getSigner();
  if (!_contract) _contract = new ethers.Contract(CONTRACT, ABI, _signer);
  if (!_me) _me = (await _signer.getAddress()).toLowerCase();
  return { provider: _provider, signer: _signer, contract: _contract, me: _me };
}

// =============== URL → linkId 인덱스 ===============
const linkIndex = new Map();
function keyOf(subject, url) {
  try { url = new URL(url).toString(); } catch {}
  return `${subject.toLowerCase()}|${url}`;
}

async function refreshFromServer() {
  try {
    const r = await fetch(`${API}/links`).then(r => r.json());
    for (const it of r.links || []) {
      linkIndex.set(keyOf(it.subject, it.url), it.linkId);
    }
  } catch (err) {
    console.warn("서버에서 링크 목록 불러오기 실패", err);
  }
}

function startServerStream() {
  try {
    const es = new EventSource(`${API}/stream`);
    es.onmessage = (evt) => {
      const data = JSON.parse(evt.data);
      if (data.type === "LinkPosted") {
        linkIndex.set(keyOf(data.subject, data.url), data.linkId);
      }
    };
  } catch (err) {
    console.warn("서버 스트림 연결 실패", err);
  }
}

refreshFromServer();
startServerStream();

// =============== Exports: 연결/행동 ===============
export async function connectWallet() {
  try {
    const [addr] = await window.ethereum.request({ method: "eth_requestAccounts" });
    console.log("지갑 연결됨:", addr);

    const { contract } = await ensureSetup();
    try { await (await contract.join()).wait(); }
    catch (innerErr) {
      console.warn("contract.join() 실행 중 오류:", innerErr?.message || innerErr);
    }

    return addr;
  } catch (err) {
    console.error("메타마스크 연결 중 오류:", err);
    throw err;
  }
}

export async function postOnChainLink(url) {
  const { contract, me } = await ensureSetup();
  const tx = await contract.postLink(url);
  const rc = await tx.wait();
  for (const log of rc.logs) {
    try {
      const parsed = contract.interface.parseLog(log);
      if (parsed?.name === "LinkPosted") {
        const { linkId, subject, url: u } = parsed.args;
        linkIndex.set(keyOf(subject, u), linkId);
        return linkId;
      }
    } catch {}
  }
  await refreshFromServer();
  const k = keyOf(me, url);
  if (linkIndex.has(k)) return linkIndex.get(k);
  throw new Error("linkId를 찾지 못했습니다.");
}

export async function sendOnChainClick(url, subjectAddress) {
  const { contract } = await ensureSetup();
  const k = keyOf(subjectAddress, url);
  if (!linkIndex.has(k)) await refreshFromServer();
  const linkId = linkIndex.get(k);
  if (!linkId) throw new Error("해당 URL의 linkId가 아직 온체인에 없습니다.");
  const tx = await contract.click(linkId);
  const r = await tx.wait();
  return r.hash;
}

export async function voteOnChain(subjectAddress, support) {
  const { contract } = await ensureSetup();
  if (support) return;
  const tx = await contract.report(subjectAddress);
  await tx.wait();
}

export async function reportOnChain(subjectAddress) {
  return voteOnChain(subjectAddress, false);
}

// =============== Exports: 읽기(대시보드/행 단위) ===============
export async function getBaseline() {
  const { contract } = await ensureSetup();
  const [bm, frozen] = await Promise.all([contract.baselineMembers(), contract.baselineFrozen()]);
  return { baselineMembers: Number(bm), baselineFrozen: Boolean(frozen) };
}

export async function getSubjectStats(subject) {
  const { contract } = await ensureSetup();
  // getSubjectState는 ABI에 없으니 필요하다면 ABI에 추가해야 함
  if (!contract.getSubjectState) {
    throw new Error("getSubjectState 함수가 ABI에 포함되어 있지 않습니다.");
  }
  const [finalizedTrustedAt, reports, pen, thr, trusted] = await Promise.all([
    contract.getSubjectState(subject),
    contract.subjectReportCount(subject),
    contract.penaltyBps(subject),
    contract.currentThresholdBps(subject),
    contract.isTrusted(subject)
  ]);
  const [finalized, isTrusted, finalizedAt] = finalizedTrustedAt;
  return {
    reports: Number(reports),
    penaltyBps: Number(pen),
    thresholdBps: Number(thr),
    finalized: Boolean(finalized),
    trusted: Boolean(isTrusted),
    finalizedAt: Number(finalizedAt)
  };
}

export async function getLinkStatsByUrl(url, subjectAddress) {
  const { contract } = await ensureSetup();
  const k = keyOf(subjectAddress, url);
  if (!linkIndex.has(k)) await refreshFromServer();
  const linkId = linkIndex.get(k);
  if (!linkId) return { linkId: null, clicks: null, exists: false };
  const meta = await contract.getLinkMeta(linkId);
  return { linkId, clicks: Number(meta[2]), exists: Boolean(meta[3]) };
}

// =============== Exports: 이벤트 수신(선택) ===============
export function listenClickEvents(cb) {
  ensureSetup().then(({ contract }) => {
    contract.on("LinkClicked", (linkId, clicker, clicks) => {
      cb?.({ linkId, clicker, clicks: Number(clicks) });
    });
  });
  startServerStream();
}

export function listenVoteEvents(cb) {
  ensureSetup().then(({ contract }) => {
    contract.on("SubjectReported", (reporter, subject, totalReports, penaltyBps) => {
      cb?.({ voter: reporter, target: subject, support: false, totalReports: Number(totalReports), penaltyBps: Number(penaltyBps) });
    });
    contract.on("SubjectFinalized", (subject, linkId) => {
      cb?.({ voter: null, target: subject, support: true, finalizedBy: linkId });
    });
  });
  startServerStream();
}
