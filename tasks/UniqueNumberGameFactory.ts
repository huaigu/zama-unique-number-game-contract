import { task, types } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";

// Get the deployed contract address
task("game:address", "Get the deployed UniqueNumberGameFactory address")
  .setAction(async (_, hre: HardhatRuntimeEnvironment) => {
    const deployment = await hre.deployments.get("UniqueNumberGameFactory");
    console.log("UniqueNumberGameFactory address:", deployment.address);
    return deployment.address;
  });

// Create a new game
task("game:create", "Create a new game")
  .addParam("min", "Minimum number", 1, types.int)
  .addParam("max", "Maximum number", 10, types.int)
  .addParam("players", "Maximum players", 3, types.int)
  .addParam("fee", "Entry fee in ETH", "0.01", types.string)
  .addParam("duration", "Game duration in seconds", 3600, types.int)
  .addOptionalParam("address", "Contract address (if not using deployment)")
  .setAction(async (taskArgs, hre: HardhatRuntimeEnvironment) => {
    const { ethers } = hre;
    const [deployer] = await ethers.getSigners();

    // Get contract address
    const contractAddress = taskArgs.address || (await hre.deployments.get("UniqueNumberGameFactory")).address;
    const gameFactory = await ethers.getContractAt("UniqueNumberGameFactory", contractAddress);

    console.log(`Creating game with params:`);
    console.log(`  Min Number: ${taskArgs.min}`);
    console.log(`  Max Number: ${taskArgs.max}`);
    console.log(`  Max Players: ${taskArgs.players}`);
    console.log(`  Entry Fee: ${taskArgs.fee} ETH`);
    console.log(`  Duration: ${taskArgs.duration} seconds`);

    const entryFee = ethers.parseEther(taskArgs.fee);
    const tx = await gameFactory
      .connect(deployer)
      .createGame(
        taskArgs.min,
        taskArgs.max,
        taskArgs.players,
        entryFee,
        taskArgs.duration
      );

    const receipt = await tx.wait();
    console.log(`Game created! Transaction hash: ${receipt?.hash}`);

    // Get the game ID from events
    const gameCreatedEvent = receipt?.logs.find((log: any) => {
      try {
        const parsed = gameFactory.interface.parseLog(log);
        return parsed?.name === "GameCreated";
      } catch {
        return false;
      }
    });

    if (gameCreatedEvent) {
      const parsed = gameFactory.interface.parseLog(gameCreatedEvent);
      console.log(`Game ID: ${parsed?.args.gameId}`);
    }

    return receipt?.hash;
  });

// View game details
task("game:info", "Get game information")
  .addParam("id", "Game ID", undefined, types.int)
  .addOptionalParam("address", "Contract address")
  .setAction(async (taskArgs, hre: HardhatRuntimeEnvironment) => {
    const { ethers } = hre;

    const contractAddress = taskArgs.address || (await hre.deployments.get("UniqueNumberGameFactory")).address;
    const gameFactory = await ethers.getContractAt("UniqueNumberGameFactory", contractAddress);

    const game = await gameFactory.games(taskArgs.id);
    const pot = await gameFactory.gamePots(taskArgs.id);

    console.log(`\n=== Game ${taskArgs.id} Information ===`);
    console.log(`Creator: ${game.creator}`);
    console.log(`Status: ${["Open", "Calculating", "Finished", "PrizeClaimed"][game.status]}`);
    console.log(`Number Range: ${game.minNumber} - ${game.maxNumber}`);
    console.log(`Players: ${game.playerCount} / ${game.maxPlayers}`);
    console.log(`Entry Fee: ${ethers.formatEther(game.entryFee)} ETH`);
    console.log(`Prize Pool: ${ethers.formatEther(pot)} ETH`);
    console.log(`Deadline: ${new Date(Number(game.deadline) * 1000).toLocaleString()}`);
    
    if (game.decryptedWinner > 0) {
      console.log(`Winner Number: ${game.decryptedWinner}`);
      const winnerAddress = await gameFactory.gameWinners(taskArgs.id);
      if (winnerAddress !== ethers.ZeroAddress) {
        console.log(`Winner Address: ${winnerAddress}`);
      }
    }

    return game;
  });

// Submit a number to a game (Note: This requires real FHE encryption on Sepolia)
task("game:submit", "Submit a number to a game (Sepolia only - requires FHE encryption)")
  .addParam("id", "Game ID", undefined, types.int)
  .addParam("number", "Number to submit", undefined, types.int)
  .addOptionalParam("address", "Contract address")
  .setAction(async (taskArgs, hre: HardhatRuntimeEnvironment) => {
    if (hre.network.name !== "sepolia") {
      throw new Error("This task only works on Sepolia network with real FHE encryption");
    }

    console.log("⚠️  Note: Submitting numbers requires FHE encryption setup on Sepolia");
    console.log("This is a complex operation that requires:");
    console.log("1. Proper FHE client setup");
    console.log("2. Key generation and management");
    console.log("3. Encrypted input creation");
    console.log("\nRefer to Zama FHEVM documentation for complete implementation.");
    console.log("For testing purposes, use the local hardhat network with mock encryption.");

    // This would require FHE client setup which is beyond basic deployment
    // Users should refer to Zama docs for complete FHE client integration
  });

// Manually trigger winner calculation (after deadline)
task("game:calculate", "Manually trigger winner calculation")
  .addParam("id", "Game ID", undefined, types.int)
  .addOptionalParam("address", "Contract address")
  .setAction(async (taskArgs, hre: HardhatRuntimeEnvironment) => {
    const { ethers } = hre;
    const [signer] = await ethers.getSigners();

    const contractAddress = taskArgs.address || (await hre.deployments.get("UniqueNumberGameFactory")).address;
    const gameFactory = await ethers.getContractAt("UniqueNumberGameFactory", contractAddress);

    console.log(`Triggering winner calculation for game ${taskArgs.id}...`);

    const tx = await gameFactory
      .connect(signer)
      .findWinnerByDeadline(taskArgs.id);

    const receipt = await tx.wait();
    console.log(`Winner calculation triggered! Transaction hash: ${receipt?.hash}`);

    return receipt?.hash;
  });

// Claim prize (winner only)
task("game:claim", "Claim prize from a finished game")
  .addParam("id", "Game ID", undefined, types.int)
  .addOptionalParam("address", "Contract address")
  .setAction(async (taskArgs, hre: HardhatRuntimeEnvironment) => {
    const { ethers } = hre;
    const [signer] = await ethers.getSigners();

    const contractAddress = taskArgs.address || (await hre.deployments.get("UniqueNumberGameFactory")).address;
    const gameFactory = await ethers.getContractAt("UniqueNumberGameFactory", contractAddress);

    console.log(`Attempting to claim prize for game ${taskArgs.id}...`);

    const tx = await gameFactory
      .connect(signer)
      .claimPrize(taskArgs.id);

    const receipt = await tx.wait();
    console.log(`Prize claimed! Transaction hash: ${receipt?.hash}`);

    return receipt?.hash;
  });

// List all games (simple version)
task("game:list", "List recent games")
  .addOptionalParam("count", "Number of games to show", 5, types.int)
  .addOptionalParam("address", "Contract address")
  .setAction(async (taskArgs, hre: HardhatRuntimeEnvironment) => {
    const { ethers } = hre;

    const contractAddress = taskArgs.address || (await hre.deployments.get("UniqueNumberGameFactory")).address;
    const gameFactory = await ethers.getContractAt("UniqueNumberGameFactory", contractAddress);

    const gameCounter = await gameFactory.gameCounter();
    const totalGames = Number(gameCounter);

    console.log(`\n=== Recent Games (Total: ${totalGames}) ===`);

    const startId = Math.max(0, totalGames - taskArgs.count);
    for (let i = startId; i < totalGames; i++) {
      const game = await gameFactory.games(i);
      const pot = await gameFactory.gamePots(i);

      console.log(`\nGame ${i}:`);
      console.log(`  Status: ${["Open", "Calculating", "Finished", "PrizeClaimed"][game.status]}`);
      console.log(`  Players: ${game.playerCount}/${game.maxPlayers}`);
      console.log(`  Range: ${game.minNumber}-${game.maxNumber}`);
      console.log(`  Prize: ${ethers.formatEther(pot)} ETH`);
    }
  });