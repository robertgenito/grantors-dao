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
 * 2. Build grantor Merkle root from (account, allowance, firstDay)
 * 3. Deploy Constitution — initial owner = deployer
 * 3. Deploy GeniusDao(Constitution, directorAddress, geniV2Address, grantorRoot)
 *    - `directorAddress` is set to generated seat address[0] for this workflow.
 *    - `geniV2` must be non-zero; use real GENI v2 on testnets (`process.env.GENI_V2`); local default is deployer.
 */

const fs = require("fs");
const path = require("path");
const hre = require("hardhat");
const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");

const SEAT_COUNT = 16;
const EXECUTE_THRESHOLD = 10;
const GRANTOR_FUND_ETH = "5.0";
const ALLOWANCES = [
  "0",
  "0",
  "0",
  "0",
  "0",
  "0",
  "0",
  "0",
  "1041348000000000000",
  "8000000000000000000000",
  "7500000000000000000000",
  "7000000000000000000000",
  "6500000000000000000000",
  "6000000000000000000000",
  "5500000000000000000000",
  "5000000000000000000000",
];
const FIRST_LIQUIDITY_DAYS = [14, 14, 14, 14, 14, 14, 14, 14, 0, 0, 0, 0, 0, 0, 0, 0];

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
  const deploymentPath = path.join(
    generatedDir,
    `local-deployment-${hre.network.name}-${(await ethers.provider.getNetwork()).chainId}.json`
  );
  const rootDeploymentPath = path.join(
    __dirname,
    "..",
    "local-deployment.json"
  );

  ensureDir(generatedDir);

  // --- 16 grantor wallets ---
  const seats = [];
  for (let i = 0; i < SEAT_COUNT; i++) {
    const w = ethers.Wallet.createRandom().connect(ethers.provider);
    seats.push({ index: i, address: w.address, privateKey: w.privateKey });
  }

  const grantors = seats.map((s, i) => ({
    ...s,
    liquidityAllowance: ALLOWANCES[i],
    firstLiquidityDay: FIRST_LIQUIDITY_DAYS[i],
  }));

  const leafHexes = grantors.map((g) =>
    ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        ["address", "uint128", "uint128"],
        [g.address, g.liquidityAllowance, g.firstLiquidityDay]
      )
    )
  );
  const leaves = leafHexes.map((h) => Buffer.from(h.slice(2), "hex"));
  const merkleTree = new MerkleTree(leaves, keccak256, { sortPairs: true });
  const grantorRoot = merkleTree.getHexRoot();

  const grantorsWithProofs = grantors.map((g, i) => ({
    ...g,
    leaf: leafHexes[i],
    merkleProof: merkleTree.getHexProof(leaves[i]),
  }));

  fs.writeFileSync(
    keysPath,
    JSON.stringify(
      {
        warning: "TEST KEYS ONLY — do not use on mainnet; do not commit to git.",
        network: hre.network.name,
        chainId: (await ethers.provider.getNetwork()).chainId.toString(),
        generatedAt: new Date().toISOString(),
        grantorRoot,
        grantors: grantorsWithProofs,
      },
      null,
      2
    ),
    "utf8"
  );
  console.log("Wrote grantor wallets + proofs to:", keysPath);
  console.log("Grantor root:", grantorRoot);

  const seatAddresses = grantors.map((s) => s.address);

  // Fund grantors from deployer
  const fundWei = ethers.utils.parseEther(GRANTOR_FUND_ETH);
  for (const s of grantors) {
    await deployer.sendTransaction({ to: s.address, value: fundWei });
  }

  // --- 1. Grantor ---
  const Constitution = await ethers.getContractFactory("Constitution", deployer);
  const constitution = await Constitution.deploy();
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
    constitution.address,
    directorAddress,
    geniV2Address,
    grantorRoot
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

  await (await constitution.electNewGrantor(geniusDao.address)).wait();
  console.log(
    "Constitution.electNewGrantor(GeniusDao) done; pending:",
    await constitution.getPendingOwner()
  );

  for (let i = 0; i < SEAT_COUNT; i++) {
    const signer = new ethers.Wallet(grantors[i].privateKey, ethers.provider);
    const daoAsGrantor = geniusDao.connect(signer);
    await (
      await daoAsGrantor.acceptGrantorship(
        grantorsWithProofs[i].merkleProof,
        grantorsWithProofs[i].liquidityAllowance,
        grantorsWithProofs[i].firstLiquidityDay
      )
    ).wait();
  }
  console.log("All generated grantors accepted grantorship");

  const acceptCalldata = geniusDao.interface.encodeFunctionData("daoAcceptGrantorOwnership", [
    constitution.address,
  ]);
  const actionHash = await geniusDao.hashAction(geniusDao.address, 0, acceptCalldata);
  const proposeInput = {
    eta: 0,
    linkProtocol: 0,
    url: ethers.constants.HashZero,
  };
  if (activeFeeToken !== ethers.constants.AddressZero) {
    throw new Error("This script expects bootstrap fee in ETH (feeToken == 0x0).");
  }
  const proposeTx = await geniusDao.propose([actionHash], proposeInput, { value: activeFeeAmount });
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
      // ignore non-DAO logs
    }
  }
  if (proposalId == null) {
    throw new Error("Could not parse ProposalCreated event");
  }
  console.log("Ownership proposal created, id:", proposalId.toString());

  for (let i = 0; i < EXECUTE_THRESHOLD; i++) {
    const signer = new ethers.Wallet(grantors[i].privateKey, ethers.provider);
    const daoAsGrantor = geniusDao.connect(signer);
    await (await daoAsGrantor.voteYes(proposalId)).wait();
  }
  console.log("Votes recorded (threshold:", EXECUTE_THRESHOLD, ")");

  await (
    await geniusDao.execute(proposalId, [geniusDao.address], [0], [acceptCalldata])
  ).wait();
  const constitutionOwner = await constitution.owner();
  console.log("Constitution owner after acceptance:", constitutionOwner);
  if (constitutionOwner.toLowerCase() !== geniusDao.address.toLowerCase()) {
    throw new Error("Ownership transfer failed: Constitution owner is not GeniusDao");
  }

  const deploymentConfig = {
    network: hre.network.name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    constitution: constitution.address,
    geniusDao: geniusDao.address,
    grantorRoot,
  };

  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentConfig, null, 2), "utf8");
  fs.writeFileSync(rootDeploymentPath, JSON.stringify(deploymentConfig, null, 2), "utf8");
  console.log("Wrote frontend deployment config:", deploymentPath);
  console.log("Wrote root deployment config:", rootDeploymentPath);

  console.log("\nDeployment summary:");
  console.log("  Constitution:", constitution.address);
  console.log("  GeniusDao: ", geniusDao.address);
  console.log("  Grantor root:", grantorRoot);
  console.log("  Wallet/proof file:", keysPath);
  console.log("  Deployment config:", deploymentPath);
  console.log("  Root deployment config:", rootDeploymentPath);
  console.log("  Grantor wallet funding:", GRANTOR_FUND_ETH, "ETH each");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
