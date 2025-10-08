import { ethers } from "hardhat";
import { UniqueNumberGameFactory__factory } from "../types";

async function main() {
  console.log("Testing callbackDecryptAllSubmissions on Sepolia...");

  const contractAddress = "0x6B674fDfC6A70ff1932CfED6F0C53d57e7F4F27a";

  // Get the signer
  const [signer] = await ethers.getSigners();
  console.log("Calling from account:", signer.address);

  // Connect to the deployed contract
  const gameFactory = UniqueNumberGameFactory__factory.connect(contractAddress, signer);

  // Prepare parameters
  const requestId = 1; // Mock request ID
  const decryptedResult = ethers.AbiCoder.defaultAbiCoder().encode(
    ["uint32[10]"],
    [[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]] // All zeros
  );
  const decryptionProof = "0x"; // Empty proof

  console.log("\nParameters:");
  console.log("- requestId:", requestId);
  console.log("- decryptedResult:", decryptedResult);
  console.log("- decryptionProof:", decryptionProof);

  try {
    console.log("\nCalling callbackDecryptAllSubmissions...");
    const tx = await gameFactory.callbackDecryptAllSubmissions(
      requestId,
      decryptedResult,
      decryptionProof
    );

    console.log("Transaction hash:", tx.hash);
    console.log("Waiting for confirmation...");

    const receipt = await tx.wait();
    console.log("\n✅ Transaction succeeded!");
    console.log("Gas used:", receipt?.gasUsed.toString());
    console.log("Block number:", receipt?.blockNumber);

    // Check events
    if (receipt?.logs && receipt.logs.length > 0) {
      console.log("\n📋 Events emitted:");
      for (const log of receipt.logs) {
        try {
          const parsed = gameFactory.interface.parseLog({
            topics: log.topics as string[],
            data: log.data
          });
          if (parsed) {
            console.log(`  - ${parsed.name}:`, parsed.args);
          }
        } catch (e) {
          // Skip unparseable logs
        }
      }
    }
  } catch (error: any) {
    console.error("\n❌ Transaction failed:");

    if (error.reason) {
      console.error("Reason:", error.reason);
    }

    if (error.data) {
      console.error("Error data:", error.data);
    }

    // Try to decode the error
    if (error.data) {
      try {
        const decodedError = gameFactory.interface.parseError(error.data);
        console.error("Decoded error:", decodedError);
      } catch (e) {
        console.error("Could not decode error");
      }
    }

    console.error("\nFull error:", error);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
