/**
 * Deploy GeniusDao on Sepolia and nominate it in Constitution.
 *
 * Requirements:
 * - GENIUS_GRANTOR_PRIVATE_KEY in .env
 * - INFURA_API_KEY in .env (or SEPOLIA_RPC_URL override)
 *
 * Run:
 *   npx hardhat run scripts/deploy-genius-dao-sepolia.js --network sepolia
 */

const fs = require("fs");
const path = require("path");
const { MerkleTree } = require("merkletreejs");
const keccak256 = require("keccak256");
const { SEPOLIA_V2_ADDRESSES } = require("./sepolia-v2-addresses");

const CONSTITUTION_ADDRESS = "0xA7Cafdbb5AAAbDA037a02C0dFC65EAafAfe45BF6";
const DEV_OVERRIDE_ADDRESS = "0xD80673E705A1E35d60cB9f8eA0e29530422c63EC";
const GENI_V2_ADDRESS = SEPOLIA_V2_ADDRESSES.geniusV2;

const GRANTOR_ROWS = [
  { account: "0x6FBdc08cAD5f3278411E2B1Aaeb3B640252E680b", allowance: "0", firstDay: 14 },
  { account: "0xa94fb62e9744d21c5b4ac3a53ddbe6d1fe1fa061", allowance: "0", firstDay: 14 },
  { account: "0x9aee4D2A8C258f9a79E76E03AA5F434e101513Ca", allowance: "0", firstDay: 14 },
  { account: "0xfB8A75eD557a9a910DBB2D7bd0AE982e3D340C11", allowance: "0", firstDay: 14 },
  { account: "0xa7b3ab3bb5726ea77470a6caff2f0497370424ca", allowance: "0", firstDay: 14 },
  { account: "0x3a3e2a7FB86ebf64611f5c94fE527fE8f10c9aE0", allowance: "0", firstDay: 14 },
  { account: "0x731adFf6b8D7d90bD40ECC516e4f21b3CB7B578e", allowance: "0", firstDay: 14 },
  { account: "0x4E854287a2A13740ba04294C6e00401793390E03", allowance: "0", firstDay: 14 },
  { account: "0xcdd6cf7c098531800f050eddea1ccd5316cce70c", allowance: "1041350000000000000", firstDay: 0 },
  { account: "0xbe56a9c2af057e37e27a7dcd401e9f9e68b6692b", allowance: "8000000000000000000000", firstDay: 0 },
  { account: "0x96F05E6B1F7DCdaaF490b18c7878DC0DD628D409", allowance: "7500000000000000000000", firstDay: 0 },
  { account: "0x278546Ab7675e8298a4def41461C24b4867A231c", allowance: "7000000000000000000000", firstDay: 0 },
  { account: "0xF0ef1f9ea5a37a3C8C1f8d61A6b8CB1E86B94158", allowance: "6500000000000000000000", firstDay: 0 },
  { account: "0x5785E3D6e289aCeF79B68490A183d3Cec7b6552b", allowance: "6000000000000000000000", firstDay: 0 },
  { account: "0x8218641D5359DC6e999D07B6BcE14fB5A207AcE5", allowance: "5500000000000000000000", firstDay: 0 },
  { account: "0x421c55331AfE0AfAD26b4152d2e8c1baf4467D49", allowance: "5000000000000000000000", firstDay: 0 },
];

function ensureDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

async function main() {
  const hre = require("hardhat");
  const { ethers, network } = hre;

  if (!process.env.GENIUS_GRANTOR_PRIVATE_KEY) {
    throw new Error("Missing GENIUS_GRANTOR_PRIVATE_KEY in environment.");
  }
  if (!process.env.INFURA_API_KEY && !process.env.SEPOLIA_RPC_URL) {
    throw new Error("Missing INFURA_API_KEY (or SEPOLIA_RPC_URL) in environment.");
  }
  if (network.name !== "sepolia") {
    throw new Error(`This script is intended for sepolia only. Current network: ${network.name}`);
  }

  const [deployer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();

  // Build Merkle root using the DAO expected leaf encoding:
  // keccak256(abi.encode(address, uint128, uint128))
  const leafHexes = GRANTOR_ROWS.map((g) =>
    ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        ["address", "uint128", "uint128"],
        [g.account, g.allowance, g.firstDay]
      )
    )
  );
  const leaves = leafHexes.map((h) => Buffer.from(h.slice(2), "hex"));
  const merkleTree = new MerkleTree(leaves, keccak256, { sortPairs: true });
  const grantorRoot = merkleTree.getHexRoot();

  console.log("Network:", network.name);
  console.log("Chain ID:", net.chainId.toString());
  console.log("Deployer:", deployer.address);
  console.log("Constitution:", CONSTITUTION_ADDRESS);
  console.log("Dev override:", DEV_OVERRIDE_ADDRESS);
  console.log("GeniV2:", GENI_V2_ADDRESS);
  console.log("Grantor root:", grantorRoot);

  const GeniusDao = await ethers.getContractFactory("GeniusDao", deployer);
  const geniusDao = await GeniusDao.deploy(
    CONSTITUTION_ADDRESS,
    DEV_OVERRIDE_ADDRESS,
    GENI_V2_ADDRESS,
    grantorRoot
  );
  await geniusDao.deployed();
  console.log("GeniusDao deployed:", geniusDao.address);

  const constitution = new ethers.Contract(
    CONSTITUTION_ADDRESS,
    [
      "function electNewGrantor(address newOwner) external",
      "function getPendingOwner() external view returns (address)",
    ],
    deployer
  );

  const tx = await constitution.electNewGrantor(geniusDao.address);
  console.log("electNewGrantor tx submitted:", tx.hash);
  await tx.wait();
  console.log("electNewGrantor confirmed.");

  const pendingOwner = await constitution.getPendingOwner();
  console.log("Constitution pending owner:", pendingOwner);
  if (pendingOwner.toLowerCase() !== geniusDao.address.toLowerCase()) {
    throw new Error("Pending owner verification failed.");
  }

  const generatedDir = path.join(__dirname, "generated");
  ensureDir(generatedDir);
  const outPath = path.join(
    generatedDir,
    `sepolia-genius-dao-deploy-${net.chainId.toString()}.json`
  );
  fs.writeFileSync(
    outPath,
    JSON.stringify(
      {
        network: network.name,
        chainId: net.chainId.toString(),
        deployer: deployer.address,
        constitution: CONSTITUTION_ADDRESS,
        devOverride: DEV_OVERRIDE_ADDRESS,
        geniV2: GENI_V2_ADDRESS,
        grantorRoot,
        geniusDao: geniusDao.address,
        constitutionPendingOwner: pendingOwner,
        grantors: GRANTOR_ROWS,
      },
      null,
      2
    ),
    "utf8"
  );

  console.log("\nDeployment summary:");
  console.log("  GeniusDao:", geniusDao.address);
  console.log("  Grantor root:", grantorRoot);
  console.log("  Constitution pending owner:", pendingOwner);
  console.log("  Output file:", outPath);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Script failed:", error);
    process.exit(1);
  });
