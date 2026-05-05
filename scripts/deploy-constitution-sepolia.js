/**
 * Deploy Constitution on Sepolia and set GeniusV2.grantor to it.
 *
 * Requirements:
 * - GENIUS_GRANTOR_PRIVATE_KEY in .env
 * - INFURA_API_KEY in .env (or SEPOLIA_RPC_URL override)
 *
 * Run:
 *   npx hardhat run scripts/deploy-constitution-sepolia.js --network sepolia
 */

const { SEPOLIA_V2_ADDRESSES } = require("./sepolia-v2-addresses");

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

  console.log("Network:", network.name);
  console.log("Chain ID:", net.chainId.toString());
  console.log("Deployer:", deployer.address);
  console.log("GeniusV2:", SEPOLIA_V2_ADDRESSES.geniusV2);

  const Constitution = await ethers.getContractFactory("Constitution", deployer);
  const constitution = await Constitution.deploy();
  await constitution.deployed();

  console.log("Constitution deployed:", constitution.address);

  const geniusV2 = new ethers.Contract(
    SEPOLIA_V2_ADDRESSES.geniusV2,
    [
      "function changeGrantor(address _newGrantor) external",
      "function grantor() view returns (address)",
    ],
    deployer
  );

  const tx = await geniusV2.changeGrantor(constitution.address);
  console.log("changeGrantor tx submitted:", tx.hash);
  await tx.wait();
  console.log("changeGrantor confirmed.");

  const currentGrantor = await geniusV2.grantor();
  console.log("Current GeniusV2 grantor:", currentGrantor);

  if (currentGrantor.toLowerCase() !== constitution.address.toLowerCase()) {
    throw new Error("Grantor update verification failed.");
  }

  console.log("Success: GeniusV2.grantor now points to Constitution.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Script failed:", error);
    process.exit(1);
  });
