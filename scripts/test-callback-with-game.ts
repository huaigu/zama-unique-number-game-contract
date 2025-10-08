import { ethers } from "hardhat";
import { UniqueNumberGameFactory__factory } from "../types";

async function main() {
  console.log("Testing callback with real game on Sepolia...");

  const contractAddress = "0x6B674fDfC6A70ff1932CfED6F0C53d57e7F4F27a";
  const [signer] = await ethers.getSigners();

  console.log("Account:", signer.address);
  const balance = await ethers.provider.getBalance(signer.address);
  console.log("Balance:", ethers.formatEther(balance), "ETH\n");

  const gameFactory = UniqueNumberGameFactory__factory.connect(contractAddress, signer);

  // Step 1: Check if there are existing games
  const gameCounter = await gameFactory.gameCounter();
  console.log("📊 Current game counter:", gameCounter.toString());

  let gameId: bigint;

  if (gameCounter === 0n) {
    console.log("\n🎮 Creating a test game...");
    const tx = await gameFactory.createGame(
      "Test Callback Game",
      1, // minNumber
      10, // maxNumber
      3, // maxPlayers
      ethers.parseEther("0.01"), // entryFee
      3600 // deadline (1 hour)
    );
    await tx.wait();
    gameId = 0n;
    console.log("✅ Game created with ID:", gameId.toString());
  } else {
    gameId = gameCounter - 1n;
    console.log("\n🎮 Using existing game ID:", gameId.toString());
  }

  // Step 2: Get game info
  const game = await gameFactory.games(gameId);
  console.log("\n📋 Game Info:");
  console.log("  - Room name:", game.roomName);
  console.log("  - Status:", game.status); // 0=Open, 1=Calculating, 2=Finished, 3=PrizeClaimed
  console.log("  - Player count:", game.playerCount.toString());
  console.log("  - Max players:", game.maxPlayers.toString());

  // Step 3: Try callback with mock data
  console.log("\n🔧 Testing callback with invalid data...");

  const mockRequestId = 999; // Mock request ID
  const decryptedResult = ethers.AbiCoder.defaultAbiCoder().encode(
    ["uint32[10]"],
    [[1, 2, 3, 0, 0, 0, 0, 0, 0, 0]] // Mock decrypted numbers
  );
  const decryptionProof = "0x"; // Empty proof (will fail signature check)

  console.log("Parameters:");
  console.log("  - requestId:", mockRequestId);
  console.log("  - decryptedResult: [1,2,3,0,0,0,0,0,0,0]");
  console.log("  - decryptionProof: (empty)");

  try {
    const tx = await gameFactory.callbackDecryptAllSubmissions(
      mockRequestId,
      decryptedResult,
      decryptionProof
    );

    console.log("\nTransaction hash:", tx.hash);
    const receipt = await tx.wait();

    console.log("\n✅ Transaction succeeded (but callback may have failed internally)");
    console.log("Gas used:", receipt?.gasUsed.toString());

    // Parse events
    console.log("\n📋 Events:");
    if (receipt?.logs) {
      for (const log of receipt.logs) {
        try {
          const parsed = gameFactory.interface.parseLog({
            topics: log.topics as string[],
            data: log.data
          });
          if (parsed) {
            console.log(`  ✓ ${parsed.name}`);
            if (parsed.name === "CallbackFailed") {
              console.log(`    - Request ID: ${parsed.args[0]}`);
              console.log(`    - Game ID: ${parsed.args[1]}`);
              console.log(`    - Reason: ${parsed.args[2]}`);
            }
          }
        } catch (e) {
          // Skip
        }
      }
    }

    // Check callback debug info
    console.log("\n🔍 Callback Debug Info:");
    const debugInfo = await gameFactory.getCallbackDebugInfo(gameId);
    console.log("  - Is decryption pending:", debugInfo.isPending);
    console.log("  - Latest request ID:", debugInfo.requestId.toString());
    console.log("  - Last error:", debugInfo.lastError || "(none)");

    // Check if game status changed
    const gameAfter = await gameFactory.games(gameId);
    console.log("\n🎮 Game Status After Callback:");
    console.log("  - Status:", gameAfter.status, "(0=Open, 1=Calculating, 2=Finished)");
    console.log("  - Player count:", gameAfter.playerCount.toString());

  } catch (error: any) {
    console.error("\n❌ Transaction reverted:");
    console.error("Reason:", error.reason || error.message);
  }

  console.log("\n✅ Test completed!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
