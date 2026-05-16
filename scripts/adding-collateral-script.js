const fs = require("fs");
const path = require("path");
const readline = require("readline");
const hre = require("hardhat");
const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");

const SEAT_COUNT = 16;
const EXECUTE_THRESHOLD = 10;

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
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function makePrompt() {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  return {
    ask(query) {
      return new Promise((resolve) => rl.question(query, resolve));
    },
    close() {
      rl.close();
    },
  };
}

function isAddress(ethers, value) {
  try {
    return ethers.utils.isAddress(value);
  } catch {
    return false;
  }
}

function normalizeAddress(ethers, value) {
  return ethers.utils.getAddress(value.trim());
}

async function askAddress(prompt, key, ethers) {
  while (true) {
    const raw = await prompt.ask(`Paste ${key}: `);
    if (!isAddress(ethers, raw)) {
      console.log(`Invalid address for ${key}. Try again.`);
      continue;
    }
    return normalizeAddress(ethers, raw);
  }
}

function rewriteAllContracts(allContractsPath, addresses) {
  const current = fs.readFileSync(allContractsPath, "utf8");
  const updated = current
    .replace(
      /address public constant GENIUS_CONTRACT_VAULT = 0x[a-fA-F0-9]{40};/,
      `address public constant GENIUS_CONTRACT_VAULT = ${addresses.GENIUS_CONTRACT_VAULT};`
    )
    .replace(
      /address public constant GENIUS_CONTRACT_TOKEN = 0x[a-fA-F0-9]{40};/,
      `address public constant GENIUS_CONTRACT_TOKEN = ${addresses.GENIUS_CONTRACT_TOKEN};`
    )
    .replace(
      /address public constant GENIUS_CONTRACT_NFT_CONTROLLER = 0x[a-fA-F0-9]{40};/,
      `address public constant GENIUS_CONTRACT_NFT_CONTROLLER = ${addresses.GENIUS_CONTRACT_NFT_CONTROLLER};`
    )
    .replace(
      /address public constant GENIUS_CONTRACT_NFT_ROYALTIES = 0x[a-fA-F0-9]{40};/,
      `address public constant GENIUS_CONTRACT_NFT_ROYALTIES = ${addresses.GENIUS_CONTRACT_NFT_ROYALTIES};`
    );

  fs.writeFileSync(allContractsPath, updated, "utf8");
}

function makeGrantors(signers) {
  return signers.slice(0, SEAT_COUNT).map((s, i) => ({
    index: i,
    address: s.address,
    liquidityAllowance: ALLOWANCES[i],
    firstLiquidityDay: FIRST_LIQUIDITY_DAYS[i],
  }));
}

function makeMerkleData(ethers, grantors) {
  const leafHexes = grantors.map((g) =>
    ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        ["address", "uint128", "uint128"],
        [g.address, g.liquidityAllowance, g.firstLiquidityDay]
      )
    )
  );
  const leaves = leafHexes.map((h) => Buffer.from(h.slice(2), "hex"));
  const tree = new MerkleTree(leaves, keccak256, { sortPairs: true });
  const root = tree.getHexRoot();
  const withProofs = grantors.map((g, i) => ({
    ...g,
    leaf: leafHexes[i],
    merkleProof: tree.getHexProof(leaves[i]),
  }));
  return { root, withProofs };
}

async function parseProposalId(tx, dao) {
  const rc = await tx.wait();
  for (const log of rc.logs) {
    try {
      const parsed = dao.interface.parseLog(log);
      if (parsed.name === "ProposalCreated") return parsed.args.proposalId;
    } catch {
      // ignore non-DAO logs
    }
  }
  throw new Error("Could not parse ProposalCreated event");
}

async function voteThreshold(dao, signers, proposalId) {
  for (let i = 0; i < EXECUTE_THRESHOLD; i++) {
    await (await dao.connect(signers[i]).voteYes(proposalId)).wait();
  }
}

/**
 * Vault / core `onlyGrantor` checks use the GeniusToken grantor (or equivalent wiring).
 * That address must be this Constitution — not the DAO. The DAO cannot run
 * `changeGrantor` via Constitution until Constitution is already grantor (chicken-and-egg),
 * so whoever *currently* holds grantor on GeniusToken must call `changeGrantor` here.
 *
 * On a persistent localhost chain, grantor may be a *previous* Constitution; only that
 * address can call `changeGrantor`. On Hardhat/localhost we impersonate `token.grantor()`
 * and retry when the deployer is not the grantor.
 */
async function ensureConstitutionIsGeniusGrantor(hre, ethers, tokenAddress, constitutionAddress, grantorSigner) {
  const iface = new ethers.utils.Interface([
    "function grantor() view returns (address)",
    "function changeGrantor(address _newGrantor) external",
  ]);
  const tokenRead = new ethers.Contract(tokenAddress, iface, ethers.provider);
  let current;
  try {
    current = await tokenRead.grantor();
  } catch {
    current = null;
  }
  const want = ethers.utils.getAddress(constitutionAddress);
  if (current && ethers.utils.getAddress(current) === want) {
    console.log("GeniusToken.grantor already matches Constitution; skipping changeGrantor.");
    return;
  }
  console.log(
    "Calling GeniusToken.changeGrantor(Constitution). Current grantor:",
    current ?? "(grantor() unavailable — attempting change from this signer)"
  );

  const sendChange = async (signer) => {
    const token = new ethers.Contract(tokenAddress, iface, signer);
    await (await token.changeGrantor(constitutionAddress)).wait();
  };

  try {
    await sendChange(grantorSigner);
    console.log("GeniusToken grantor updated to Constitution.");
    return;
  } catch (eFirst) {
    const isHardhatNet = hre.network.name === "hardhat" || hre.network.name === "localhost";
    const grantorAddr = grantorSigner.address ? ethers.utils.getAddress(grantorSigner.address) : null;
    const canImpersonate =
      isHardhatNet &&
      current &&
      ethers.utils.getAddress(current) !== grantorAddr;

    if (!canImpersonate) {
      throw new Error(
        `Could not set GeniusToken grantor to Constitution (${constitutionAddress}). ` +
          `The transaction must be sent from the current on-chain grantor (reverts EUnauthorized() otherwise). ` +
          `On-chain grantor: ${current ?? "unknown"}. ` +
          `For localhost: reset the chain, or set GENIUS_GRANTOR_PRIVATE_KEY to that account if it is an EOA. ` +
          `Underlying: ${eFirst.message}`
      );
    }

    console.log(
      "Signer is not token.grantor(); retrying changeGrantor as current grantor via hardhat_impersonateAccount (dev only)."
    );
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [current],
    });
    await hre.network.provider.send("hardhat_setBalance", [
      current,
      "0x1000000000000000000000",
    ]);
    const asGrantor = await ethers.getSigner(current);
    try {
      await sendChange(asGrantor);
      console.log("GeniusToken grantor updated to Constitution (tx from impersonated previous grantor).");
    } catch (e2) {
      throw new Error(
        `Could not changeGrantor even when sending from impersonated grantor ${current}. ` +
          `Underlying: ${e2.message}`
      );
    }
  }
}

async function main() {
  const { ethers } = hre;
  const signers = await ethers.getSigners();
  if (signers.length < SEAT_COUNT) {
    throw new Error(`Need at least ${SEAT_COUNT} signers to run this workflow.`);
  }

  const deployer = signers[0];
  const director = signers[1];

  const generatedDir = path.join(__dirname, "generated");
  ensureDir(generatedDir);
  const chainId = (await ethers.provider.getNetwork()).chainId.toString();
  const keysPath = path.join(generatedDir, `grantor-seats-${hre.network.name}-${chainId}.json`);
  const deploymentPath = path.join(generatedDir, `genesis-deployment-${hre.network.name}-${chainId}.json`);

  // Deploy Constitution first so user can wire its address in Genius env/contracts.
  const Constitution = await ethers.getContractFactory("Constitution", deployer);
  const constitution = await Constitution.deploy();
  await constitution.deployed();
  console.log("Constitution deployed:", constitution.address);
  console.log(
    "Use this Constitution address in Genius deployment env/config, deploy Genius core, then paste core addresses below."
  );

  const prompt = makePrompt();
  const addresses = {};
  try {
    const ready = await prompt.ask("Type 'ready' after Genius core contracts are deployed: ");
    if (ready.trim().toLowerCase() !== "ready") {
      throw new Error("Aborted. Re-run and type 'ready' when core contracts are deployed.");
    }

    addresses.GENIUS_CONTRACT_VAULT = await askAddress(prompt, "GENIUS_CONTRACT_VAULT", ethers);
    addresses.GENIUS_CONTRACT_TOKEN = await askAddress(prompt, "GENIUS_CONTRACT_TOKEN", ethers);
    addresses.GENIUS_CONTRACT_NFT_CONTROLLER = await askAddress(prompt, "GENIUS_CONTRACT_NFT_CONTROLLER", ethers);
    addresses.GENIUS_CONTRACT_NFT_ROYALTIES = await askAddress(prompt, "GENIUS_CONTRACT_NFT_ROYALTIES", ethers);
  } finally {
    prompt.close();
  }

  const unique = new Set(Object.values(addresses).map((x) => x.toLowerCase()));
  if (unique.size !== 4) throw new Error("Core addresses must be unique.");

  const allContractsPath = path.join(__dirname, "..", "contracts", "AllContracts.sol");
  console.log("\nRewriting contracts/AllContracts.sol with provided addresses...");
  rewriteAllContracts(allContractsPath, addresses);
  console.log("Recompile triggered so newly deployed contracts pick updated constants...");
  await hre.run("compile");

  const grantors = makeGrantors(signers);
  const merkle = makeMerkleData(ethers, grantors);

  fs.writeFileSync(
    keysPath,
    JSON.stringify(
      {
        warning: "Local signer-based grantor data for test workflow.",
        network: hre.network.name,
        chainId,
        generatedAt: new Date().toISOString(),
        grantorRoot: merkle.root,
        grantors: merkle.withProofs,
      },
      null,
      2
    ),
    "utf8"
  );

  const geniV2Address =
    process.env.GENI_V2 && process.env.GENI_V2.length > 0 ? process.env.GENI_V2 : deployer.address;
  const GeniusDao = await ethers.getContractFactory("GeniusDao", deployer);
  const geniusDao = await GeniusDao.deploy(constitution.address, director.address, geniV2Address, merkle.root);
  await geniusDao.deployed();
  console.log("GeniusDao deployed:", geniusDao.address);

  await (await constitution.electNewGrantor(geniusDao.address)).wait();
  console.log("Constitution nominated GeniusDao as pending owner.");

  for (let i = 0; i < SEAT_COUNT; i++) {
    const g = merkle.withProofs[i];
    await (
      await geniusDao.connect(signers[i]).acceptGrantorship(g.merkleProof, g.liquidityAllowance, g.firstLiquidityDay)
    ).wait();
  }
  console.log("All grantors accepted grantorship.");

  const feeToken = await geniusDao.feeToken();
  const feeAmount = await geniusDao.fee();
  if (feeToken !== ethers.constants.AddressZero) {
    throw new Error("Bootstrap fee must be native ETH for this script flow.");
  }

  // Proposal #1: DAO accepts Constitution ownership.
  const acceptOwnershipData = geniusDao.interface.encodeFunctionData("daoAcceptGrantorOwnership", [constitution.address]);
  const ownershipActionHash = await geniusDao.hashAction(geniusDao.address, 0, acceptOwnershipData);
  const proposalInput = {
    eta: 0,
    linkProtocol: 0,
    url: ethers.constants.HashZero,
  };
  const p1 = await parseProposalId(
    await geniusDao.propose([ownershipActionHash], proposalInput, { value: feeAmount }),
    geniusDao
  );
  await voteThreshold(geniusDao, signers, p1);
  await (await geniusDao.execute(p1, [geniusDao.address], [0], [acceptOwnershipData])).wait();
  const ownerAfterP1 = await constitution.owner();
  if (ownerAfterP1.toLowerCase() !== geniusDao.address.toLowerCase()) {
    throw new Error("Ownership acceptance failed.");
  }
  console.log("Proposal #1 executed. Constitution owner:", ownerAfterP1);

  // Core contracts must treat Constitution as grantor before Vault-onlyOwner/grantor paths succeed.
  const grantorSigner =
    process.env.GENIUS_GRANTOR_PRIVATE_KEY && process.env.GENIUS_GRANTOR_PRIVATE_KEY.length > 0
      ? new ethers.Wallet(process.env.GENIUS_GRANTOR_PRIVATE_KEY, ethers.provider)
      : deployer;
  if (grantorSigner.address !== deployer.address) {
    console.log("Using GENIUS_GRANTOR_PRIVATE_KEY for changeGrantor:", grantorSigner.address);
  }
  await ensureConstitutionIsGeniusGrantor(
    hre,
    ethers,
    addresses.GENIUS_CONTRACT_TOKEN,
    constitution.address,
    grantorSigner
  );

  // Proposal #2: Begin credit issuance for mock USDT via Constitution.callVault.
  const MUSDT = await ethers.getContractFactory("mUSDT", deployer);
  const mUsdt = await MUSDT.deploy();
  await mUsdt.deployed();

  const vaultIface = new ethers.utils.Interface([
    "function beginCreditIssuance(address token, uint256 initRate)",
  ]);
  const beginCreditData = vaultIface.encodeFunctionData("beginCreditIssuance", [mUsdt.address, 1]);
  const daoCallVaultData = geniusDao.interface.encodeFunctionData("daoCallVault", [beginCreditData]);
  const beginCreditHash = await geniusDao.hashAction(geniusDao.address, 0, daoCallVaultData);
  const p2 = await parseProposalId(
    await geniusDao.propose([beginCreditHash], proposalInput, { value: feeAmount }),
    geniusDao
  );
  await voteThreshold(geniusDao, signers, p2);

  await (
    await geniusDao.execute(
      p2,
      [geniusDao.address],
      [0],
      [daoCallVaultData]
    )
  ).wait();
  console.log("Proposal #2 executed: daoCallVault(Vault.beginCreditIssuance(mUSDT, 1)).");

  const deploymentConfig = {
    network: hre.network.name,
    chainId,
    coreContracts: addresses,
    constitution: constitution.address,
    geniusDao: geniusDao.address,
    director: director.address,
    grantorRoot: merkle.root,
    proposalIds: {
      ownershipAccept: p1.toString(),
      beginCreditIssuance: p2.toString(),
    },
    mockTokens: {
      mUSDT: mUsdt.address,
    },
  };

  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentConfig, null, 2), "utf8");
  console.log("Wrote deployment artifact:", deploymentPath);
  console.log("Wrote grantor proof artifact:", keysPath);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});

