/**
 * Deploy Grantor + GeniusDao (local / test workflow).
 *
 * Security: generates 16 random seat wallets and writes their private keys to disk.
 * Add `scripts/generated/` to `.gitignore` and never commit real keys.
 *
 * GeniusDao fee model (single active currency):
 * - At deploy, GeniusDao bootstraps with native ETH proposal fees (`feeToken() == 0x0`, `fee()` in wei).
 * - Governance later switches currency by executing a GRANTOR proposal that self-calls
 *   `daoSetProposalFee(token, amount)` (e.g. GENI v2, then USDC). All subsequent `propose` calls
 *   use that token + amount only; proposers do not pass a fee token in calldata.
 *
 * Workflow:
 * 1. Generate 16 wallets → save private keys under scripts/generated/
 * 2. Deploy Grantor(seats) — initial owner = deployer
 * 3. Deploy GeniusDao(Grantor, directorAddress, geniV2Address)
 *    - `directorAddress` is set to generated seat address[0] for this workflow.
 *    - `geniV2` must be non-zero; use real GENI v2 on testnets (`process.env.GENI_V2`); local default is deployer.
 * 4. Grantor.electNewGrantor(GeniusDao)
 * 5. Create and pass a GRANTOR-type proposal that executes daoAcceptGrantorOwnership(Grantor)
 *    - Pay proposal fee: if bootstrap fee is ETH, send `value: fee`; if you change GeniusDao to ERC20 fees first,
 *      extend this script (approve + propose with value 0).
 * 6. Execute proposal → GeniusDao becomes Grantor owner; Genius `onlyGrantor` paths go via Grantor.callGenius(...)
 */

const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const SEAT_COUNT = 16;
const PROPOSAL_TYPE_GRANTOR = 2;
/** Minimum yes votes required (must match GeniusDao.GRANTOR_EXECUTE_THRESHOLD). */
const EXECUTE_THRESHOLD = 10;
/** Native ETH sent to each seat for gas (`registerSeat` + `voteYes`). 0.02 is usually enough on Sepolia; raise if txs fail under gas spikes. */
const SEAT_FUND_ETH = "0.02";

function ensureDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

async function main() {
  const { ethers } = hre;
  const signers = await ethers.getSigners();
  if (signers.length < 2) {
    throw new Error("Expected at least 2 hardhat signers; account[1] is required as deployer.");
  }
  const deployer = signers[1];

  const generatedDir = path.join(__dirname, "generated");
  const keysPath = path.join(
    generatedDir,
    `grantor-seat-keys-${hre.network.name}-${(await ethers.provider.getNetwork()).chainId}.json`
  );

  ensureDir(generatedDir);

  // --- 16 seat wallets ---
  const seats = [];
  for (let i = 0; i < SEAT_COUNT; i++) {
    const w = ethers.Wallet.createRandom().connect(ethers.provider);
    seats.push({ index: i, address: w.address, privateKey: w.privateKey });
  }

  fs.writeFileSync(
    keysPath,
    JSON.stringify(
      {
        warning: "TEST KEYS ONLY — do not use on mainnet; do not commit to git.",
        network: hre.network.name,
        chainId: (await ethers.provider.getNetwork()).chainId.toString(),
        generatedAt: new Date().toISOString(),
        seats,
      },
      null,
      2
    ),
    "utf8"
  );
  console.log("Wrote seat keys to:", keysPath);

  const seatAddresses = seats.map((s) => s.address);

  // Fund seats from deployer
  const fundWei = ethers.utils.parseEther(SEAT_FUND_ETH);
  for (const s of seats) {
    await deployer.sendTransaction({ to: s.address, value: fundWei });
  }

  // --- 1. Grantor ---
  const Constitution = await ethers.getContractFactory("Constitution", deployer);
  const constitution = await Constitution.deploy(seatAddresses);
  await constitution.deployed();
  console.log("Constitution:", constitution.address, "owner:", await constitution.owner());

  // Constructor requires non-zero addresses.
  // Director is one of the generated seats for this project: seat address[0].
  const directorAddress = seatAddresses[0];
  const geniV2Address =
    process.env.GENI_V2 && process.env.GENI_V2.length > 0
      ? process.env.GENI_V2
      : deployer.address;

  // --- 2. GeniusDao ---
  const GeniusDao = await ethers.getContractFactory("GeniusDao", deployer);
  const geniusDao = await GeniusDao.deploy(
    grantor.address,
    directorAddress,
    geniV2Address
  );
  await geniusDao.deployed();
  console.log("GeniusDao:", geniusDao.address);
  const activeFeeToken = await geniusDao.feeToken();
  const activeFeeAmount = await geniusDao.fee();
  console.log(
    "GeniusDao proposal fee (bootstrap): token",
    activeFeeToken,
    "amount",
    activeFeeAmount.toString()
  );

  // --- 3. Elect DAO as pending Grantor owner ---
  const electTx = await grantor.electNewGrantor(geniusDao.address);
  await electTx.wait();
  console.log("Grantor.electNewGrantor(GeniusDao) done; pending:", await grantor.getPendingOwner());

  // --- 4–5. Proposal: self-call daoAcceptGrantorOwnership(grantor) ---
  const acceptCalldata = geniusDao.interface.encodeFunctionData("daoAcceptGrantorOwnership", [
    grantor.address,
  ]);
  const actionHash = await geniusDao.hashAction(geniusDao.address, 0, acceptCalldata);

  const proposeInput = {
    eta: 0,
    linkProtocol: 0,
    url: ethers.constants.HashZero,
    proposalType: PROPOSAL_TYPE_GRANTOR,
  };

  let proposeOpts = {};
  if (activeFeeToken === ethers.constants.AddressZero) {
    proposeOpts = { value: activeFeeAmount };
  } else {
    throw new Error(
      "This script expects GeniusDao bootstrap fee in ETH (feeToken == 0x0). " +
        "For ERC20 fees, approve GeniusDao and call propose with value 0, or change bootstrap in the contract."
    );
  }

  const proposeTx = await geniusDao.propose([actionHash], proposeInput, proposeOpts);
  const proposeRc = await proposeTx.wait();
  let proposalId = null;
  for (const log of proposeRc.logs) {
    try {
      const parsed = geniusDao.interface.parseLog(log);
      if (parsed.name === "ProposalCreated") {
        proposalId = parsed.args.proposalId;
        break;
      }
    } catch {
      // ignore
    }
  }
  if (proposalId == null) {
    throw new Error("Could not parse ProposalCreated event");
  }
  console.log("Proposal created, id:", proposalId.toString());

  // Seats register + vote (need EXECUTE_THRESHOLD yes votes)
  // Hardhat can over-estimate gas; a high gasLimit avoids false "insufficient funds" on in-memory network.
  // On Sepolia, omit gasLimit so seats only reserve ~estimated cost (important when funding 0.02 ETH each).
  const seatTxOpts =
    hre.network.name === "hardhat" ? { gasLimit: 800000 } : {};

  for (let i = 0; i < SEAT_COUNT; i++) {
    const signer = new ethers.Wallet(seats[i].privateKey, ethers.provider);
    const daoAsSeat = geniusDao.connect(signer);
    await (await daoAsSeat.registerSeat(seatTxOpts)).wait();
  }

  for (let i = 0; i < EXECUTE_THRESHOLD; i++) {
    const signer = new ethers.Wallet(seats[i].privateKey, ethers.provider);
    const daoAsSeat = geniusDao.connect(signer);
    await (await daoAsSeat.voteYes(proposalId, seatTxOpts)).wait();
  }
  console.log("Votes recorded (threshold:", EXECUTE_THRESHOLD, ")");

  // --- 6. Execute (any account; deployer used here) ---
  await (
    await geniusDao.execute(proposalId, [geniusDao.address], [0], [acceptCalldata])
  ).wait();

  const grantorOwner = await grantor.owner();
  console.log("Grantor owner after acceptance:", grantorOwner);
  if (grantorOwner.toLowerCase() !== geniusDao.address.toLowerCase()) {
    throw new Error("Ownership transfer failed: Grantor owner is not GeniusDao");
  }

  console.log("\nDeployment summary:");
  console.log("  Grantor:   ", grantor.address);
  console.log("  GeniusDao: ", geniusDao.address);
  console.log("  Seat keys: ", keysPath);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
