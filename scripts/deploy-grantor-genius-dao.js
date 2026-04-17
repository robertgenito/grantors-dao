/**
 * Deploy Grantor + GeniusDao (local / test workflow).
 *
 * Security: generates 16 random seat wallets and writes their private keys to disk.
 * Add `scripts/generated/` to `.gitignore` and never commit real keys.
 *
 * Workflow:
 * 1. Generate 16 wallets → save private keys to scripts/generated/grantor-seat-keys.json
 * 2. Deploy Grantor(seats) — initial owner = deployer
 * 3. Deploy GeniusDao(Grantor, devOverridePlaceholder, geniV2Placeholder)
 * 4. Grantor.electNewGrantor(GeniusDao)
 * 5. Create and pass a GRANTOR-type proposal that executes daoAcceptGrantorOwnership(Grantor)
 * 6. Execute proposal → GeniusDao becomes Grantor owner; privileged Genius calls go via Grantor.callGenius(...)
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
  const [deployer] = await ethers.getSigners();

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
  const Grantor = await ethers.getContractFactory("Grantor");
  const grantor = await Grantor.deploy(seatAddresses);
  await grantor.deployed();
  console.log("Grantor:", grantor.address, "owner:", await grantor.owner());

  // Placeholders: must be non-zero for GeniusDao constructor (GENI v2 + unused dev slot).
  const devOverridePlaceholder = deployer.address;
  const geniV2Placeholder = deployer.address;

  // --- 2. GeniusDao ---
  const GeniusDao = await ethers.getContractFactory("GeniusDao");
  const geniusDao = await GeniusDao.deploy(
    grantor.address,
    devOverridePlaceholder,
    geniV2Placeholder
  );
  await geniusDao.deployed();
  console.log("GeniusDao:", geniusDao.address);

  // --- 3. Elect DAO as pending Grantor owner ---
  const electTx = await grantor.electNewGrantor(geniusDao.address);
  await electTx.wait();
  console.log("Grantor.electNewGrantor(GeniusDao) done; pending:", await grantor.getPendingOwner());

  // --- 4–5. Proposal: self-call daoAcceptGrantorOwnership(grantor) ---
  const acceptCalldata = geniusDao.interface.encodeFunctionData("daoAcceptGrantorOwnership", [
    grantor.address,
  ]);
  const actionHash = await geniusDao.hashAction(geniusDao.address, 0, acceptCalldata);

  const proposeFee = await geniusDao.fee();
  const proposeInput = {
    eta: 0,
    txExpiresOn: 0,
    linkProtocol: 0,
    metadataHash: ethers.constants.HashZero,
    feeToken: ethers.constants.AddressZero,
    proposalType: PROPOSAL_TYPE_GRANTOR,
  };

  const proposeTx = await geniusDao.propose([actionHash], proposeInput, { value: proposeFee });
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
