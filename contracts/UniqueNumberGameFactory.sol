// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.20;

import {FHE, euint32, externalEuint32, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

// Simple Owner management
abstract contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(owner() == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * @title UniqueNumberGameFactory
 * @author Gemini AI based on Zama FHE
 * @notice A fully-featured minimal unique number game platform that supports creating multiple games, custom rules and fees.
 */
contract UniqueNumberGameFactory is SepoliaConfig, Ownable {
    // --- Data Structures ---
    enum GameStatus {
        Open,
        Calculating,
        Finished,
        PrizeClaimed
    }

    struct Game {
        uint256 gameId;
        address creator;
        GameStatus status;
        string roomName;
        // Game rules
        uint32 minNumber;
        uint32 maxNumber;
        uint32 maxPlayers;
        uint256 entryFee;
        uint256 deadline;
        // Game progress
        uint32 playerCount;
        // FHE calculation results
        euint32 encryptedWinner;
        uint32 decryptedWinner;
    }

    // GameSummary struct for providing game summary information
    struct GameSummary {
        uint256 gameId;
        string roomName;
        address creator;
        GameStatus status;
        uint32 playerCount;
        uint32 maxPlayers;
        uint32 minNumber;
        uint32 maxNumber;
        uint256 entryFee;
        uint256 deadline;
        uint256 prizePool;
        address winner;
        uint32 winningNumber;
    }

    // Player statistics struct
    struct PlayerStats {
        uint256 gamesPlayed;
        uint256 gamesWon;
        uint256 totalWinnings;
    }

    // Winner record struct
    struct WinnerRecord {
        uint256 gameId;
        string roomName;
        address winner;
        uint32 winningNumber;
        uint256 prize;
        uint256 timestamp;
    }

    // --- Constant Definitions ---
    
    uint32 public constant MAX_PLAYERS_PER_ROOM = 10;

    // --- State Variables ---

    uint256 public gameCounter; // Used to generate unique gameId
    mapping(uint256 => Game) public games; // Store all games

    // Store game data for each game, as mappings cannot be in structs
    // gameId => number => encrypted count
    mapping(uint256 => mapping(uint32 => euint32)) public gameCounts;
    // gameId => list of player addresses
    mapping(uint256 => address[]) public gamePlayerAddresses;
    // gameId => fixed array of 10 encrypted submissions (unused slots filled with encrypted 0)
    mapping(uint256 => euint32[10]) public gameEncryptedSubmissions;
    // gameId => has player submitted?
    mapping(uint256 => mapping(address => bool)) public hasPlayerSubmitted;
    // gameId => prize pool
    mapping(uint256 => uint256) public gamePots;
    // gameId => winner address
    mapping(uint256 => address) public gameWinners;
    // requestId => gameId (used for callback function to identify game)
    mapping(uint256 => uint256) private requestToGameId;
    // Winner history records array
    WinnerRecord[] public winnerHistory;
    
    // Error tracking variables
    mapping(uint256 => bool) public isDecryptionPending;
    mapping(uint256 => uint256) public latestRequestId;
    mapping(uint256 => string) public lastCallbackError;
    
    // Tie refund related
    // gameId => player => has claimed refund
    mapping(uint256 => mapping(address => bool)) public hasClaimedRefund;
    // gameId => player => has claimed prize
    mapping(uint256 => mapping(address => bool)) public hasPlayerClaimed;
    // Platform fees accumulation
    uint256 public platformFees;
    // Refund percentage (90% = 9000 / 10000)
    uint256 public constant REFUND_PERCENTAGE = 9000;
    uint256 public constant PERCENTAGE_BASE = 10000;

    // --- Events ---

    event GameCreated(
        uint256 indexed gameId,
        address indexed creator,
        string roomName,
        uint256 entryFee,
        uint32 maxPlayers,
        uint256 deadline
    );
    event SubmissionReceived(uint256 indexed gameId, address indexed player, uint32 playerCount);
    event WinnerCalculationStarted(uint256 indexed gameId, address indexed trigger);
    event WinnerDetermined(uint256 indexed gameId, uint32 winnerNumber, address indexed winnerAddress);
    event PrizeClaimed(uint256 indexed gameId, address indexed winner, uint256 amount);
    event NoWinnerDetermined(uint256 indexed gameId, uint256 totalRefundPool);
    event RefundClaimed(uint256 indexed gameId, address indexed player, uint256 amount);
    event PlatformFeesWithdrawn(address indexed owner, uint256 amount);
    
    // Debug events
    event CallbackAttempted(uint256 indexed requestId, uint256 indexed gameId);
    event CallbackSucceeded(uint256 indexed requestId, uint256 indexed gameId);
    event CallbackFailed(uint256 indexed requestId, uint256 indexed gameId, string reason);

    // --- Core Functions ---

    /**
     * @notice Create a new game
     * @param _roomName Room name
     * @param _minNumber Lower limit of number range
     * @param _maxNumber Upper limit of number range
     * @param _maxPlayers Maximum number of players
     * @param _entryFee Entry fee (in wei)
     * @param _deadlineDuration Game duration (in seconds from now)
     */
    function createGame(
        string calldata _roomName,
        uint32 _minNumber,
        uint32 _maxNumber,
        uint32 _maxPlayers,
        uint256 _entryFee,
        uint256 _deadlineDuration
    ) public {
        require(bytes(_roomName).length > 0 && bytes(_roomName).length <= 64, "Invalid room name length");
        require(_minNumber > 0 && _maxNumber > _minNumber, "Invalid number range");
        require(_maxPlayers > 1, "Max players must be at least 2");
        require(_maxPlayers <= MAX_PLAYERS_PER_ROOM, "Max players exceeds room limit");
        require(_maxNumber - _minNumber < 256, "Range is too large for efficient FHE"); // Gas limit

        uint256 gameId = gameCounter;
        gameCounter++;

        Game storage newGame = games[gameId];
        newGame.gameId = gameId;
        newGame.creator = msg.sender;
        newGame.status = GameStatus.Open;
        newGame.roomName = _roomName;
        newGame.minNumber = _minNumber;
        newGame.maxNumber = _maxNumber;
        newGame.maxPlayers = _maxPlayers;
        newGame.entryFee = _entryFee;
        newGame.deadline = block.timestamp + _deadlineDuration;
        newGame.encryptedWinner = FHE.asEuint32(_maxNumber + 1); // Initialize to an impossible large number
        FHE.allowThis(newGame.encryptedWinner); // Allow contract to access this encrypted value

        // Initialize FHE counters
        for (uint32 i = _minNumber; i <= _maxNumber; i++) {
            gameCounts[gameId][i] = FHE.asEuint32(0);
            FHE.allowThis(gameCounts[gameId][i]); // Allow contract to access counter
        }
        
        // Initialize fixed-length submission array (filled with encrypted zeros)
        euint32 encryptedZero = FHE.asEuint32(0);
        FHE.allowThis(encryptedZero);
        for (uint32 i = 0; i < MAX_PLAYERS_PER_ROOM; i++) {
            gameEncryptedSubmissions[gameId][i] = encryptedZero;
            FHE.allowThis(gameEncryptedSubmissions[gameId][i]);
        }

        emit GameCreated(gameId, msg.sender, _roomName, _entryFee, _maxPlayers, newGame.deadline);
    }

    /**
     * @notice Submit an encrypted number to participate in the game
     * @param _gameId Game ID
     * @param _encryptedNumber Encrypted number
     */
    function submitNumber(uint256 _gameId, externalEuint32 _encryptedNumber, bytes calldata inputProof) public payable {
        Game storage game = games[_gameId];
        require(game.status == GameStatus.Open, "Game is not open");
        require(block.timestamp < game.deadline, "Game has passed deadline");
        require(msg.value == game.entryFee, "Incorrect entry fee");
        require(!hasPlayerSubmitted[_gameId][msg.sender], "Player has already submitted");

        game.playerCount++;
        hasPlayerSubmitted[_gameId][msg.sender] = true;
        gamePots[_gameId] += msg.value;

        euint32 submittedNumber = FHE.fromExternal(_encryptedNumber, inputProof);
        FHE.allowThis(submittedNumber); // Allow contract to access submitted encrypted number
        gamePlayerAddresses[_gameId].push(msg.sender);
        
        // Store player submission in fixed array (using playerCount-1 as index)
        gameEncryptedSubmissions[_gameId][game.playerCount - 1] = submittedNumber;
        FHE.allowThis(gameEncryptedSubmissions[_gameId][game.playerCount - 1]);

        // Update FHE count
        for (uint32 i = game.minNumber; i <= game.maxNumber; i++) {
            euint32 numberToCompare = FHE.asEuint32(i);
            FHE.allowThis(numberToCompare);
            
            ebool isCurrentNumber = FHE.eq(submittedNumber, numberToCompare);
            
            euint32 one = FHE.asEuint32(1);
            euint32 zero = FHE.asEuint32(0);
            FHE.allowThis(one);
            FHE.allowThis(zero);
            
            euint32 incrementValue = FHE.select(isCurrentNumber, one, zero);
            FHE.allowThis(incrementValue);
            
            gameCounts[_gameId][i] = FHE.add(gameCounts[_gameId][i], incrementValue);
            FHE.allowThis(gameCounts[_gameId][i]);
        }

        emit SubmissionReceived(_gameId, msg.sender, game.playerCount);

        // If maximum number of players is reached, trigger prize draw immediately
        if (game.playerCount == game.maxPlayers) {
            _findWinner(_gameId);
        }
    }

    /**
     * @notice Manually trigger prize draw after deadline
     * @param _gameId Game ID
     */
    function findWinnerByDeadline(uint256 _gameId) public {
        Game storage game = games[_gameId];
        require(game.status == GameStatus.Open, "Game is not open or already finished");
        require(block.timestamp >= game.deadline, "Deadline has not passed yet");
        require(game.playerCount > 0, "No players in the game");

        _findWinner(_gameId);
    }

    /**
     * @notice Internal function to execute FHE calculation for finding winning number
     */
    function _findWinner(uint256 _gameId) internal {
        games[_gameId].status = GameStatus.Calculating;
        isDecryptionPending[_gameId] = true;
        emit WinnerCalculationStarted(_gameId, msg.sender);

        Game storage game = games[_gameId];
        
        // Decrypt fixed-length submission array (always decrypt 10 values)
        bytes32[] memory allSubmissions = new bytes32[](MAX_PLAYERS_PER_ROOM);
        for (uint32 i = 0; i < MAX_PLAYERS_PER_ROOM; i++) {
            allSubmissions[i] = FHE.toBytes32(gameEncryptedSubmissions[_gameId][i]);
        }
        
        // Decrypt all submitted numbers at once
        uint256 requestId = FHE.requestDecryption(
            allSubmissions,
            this.callbackDecryptAllSubmissions.selector
        );
        
        // Save mapping of request ID to game ID
        requestToGameId[requestId] = _gameId;
        latestRequestId[_gameId] = requestId;
    }

    /**
     * @notice Handle decryption results of fixed 10 player submitted numbers
     * @param requestId Decryption request ID
     * @param player0-player9 Decrypted player numbers (unused positions are 0)
     * @param signatures Verification signatures
     */
    function callbackDecryptAllSubmissions(
        uint256 requestId,
        uint32 player0,
        uint32 player1,
        uint32 player2,
        uint32 player3,
        uint32 player4,
        uint32 player5,
        uint32 player6,
        uint32 player7,
        uint32 player8,
        uint32 player9,
        bytes[] memory signatures
    ) public {
        uint256 gameId = requestToGameId[requestId];
        emit CallbackAttempted(requestId, gameId);
        
        uint32[10] memory allNumbers = [player0, player1, player2, player3, player4, player5, player6, player7, player8, player9];
        
        try this._processDecryptedSubmissions(requestId, allNumbers, signatures) {
            isDecryptionPending[gameId] = false;
            emit CallbackSucceeded(requestId, gameId);
        } catch Error(string memory reason) {
            lastCallbackError[gameId] = reason;
            emit CallbackFailed(requestId, gameId, reason);
            if (gameId < gameCounter) {
                games[gameId].status = GameStatus.Open;
                isDecryptionPending[gameId] = false;
            }
        } catch (bytes memory) {
            lastCallbackError[gameId] = "Low level error";
            emit CallbackFailed(requestId, gameId, "Low level error");
            if (gameId < gameCounter) {
                games[gameId].status = GameStatus.Open;
                isDecryptionPending[gameId] = false;
            }
        }
    }
    
    /**
     * @notice Internal function that actually handles decryption result logic
     */
    function _processDecryptedSubmissions(
        uint256 requestId,
        uint32[10] memory allDecryptedNumbers,
        bytes[] memory signatures
    ) external {
        
        // Verify signatures to prevent unauthorized decryption
        FHE.checkSignatures(requestId, signatures);
        
        // Get corresponding game ID
        uint256 gameId = requestToGameId[requestId];
        require(gameId < gameCounter, "Invalid game ID");
        
        Game storage game = games[gameId];
        require(game.status == GameStatus.Calculating, "Game not in calculating status");
        
        // Extract valid numbers from fixed array (filter out 0 values)
        uint32[] memory validNumbers = new uint32[](game.playerCount);
        uint32 validCount = 0;
        
        for (uint32 i = 0; i < MAX_PLAYERS_PER_ROOM && validCount < game.playerCount; i++) {
            if (allDecryptedNumbers[i] != 0) {
                validNumbers[validCount] = allDecryptedNumbers[i];
                validCount++;
            }
        }
        
        require(validCount == game.playerCount, "Valid numbers count mismatch");
        
        // Clean up request ID mapping
        delete requestToGameId[requestId];
        
        // Game ended
        game.status = GameStatus.Finished;
        
        // 🎯 Core logic: Find unique minimum value in valid numbers array
        (address winnerAddress, uint32 winningNumber) = _calculateUniqueMinWinner(
            gameId,
            validNumbers
        );
        
        // Save results
        game.decryptedWinner = winningNumber;
        
        if (winnerAddress != address(0)) {
            // Has winner
            gameWinners[gameId] = winnerAddress;
            
            // Record winning history
            winnerHistory.push(WinnerRecord({
                gameId: gameId,
                roomName: game.roomName,
                winner: winnerAddress,
                winningNumber: winningNumber,
                prize: gamePots[gameId],
                timestamp: block.timestamp
            }));
            
            emit WinnerDetermined(gameId, winningNumber, winnerAddress);
        } else {
            // No winner, calculate platform fees
            uint256 totalPot = gamePots[gameId];
            uint256 platformFee = (totalPot * (PERCENTAGE_BASE - REFUND_PERCENTAGE)) / PERCENTAGE_BASE;
            platformFees += platformFee;
            
            emit NoWinnerDetermined(gameId, totalPot);
        }
    }

    /**
     * @notice Calculate unique minimum number winner
     * @dev Separated pure logic function for easy testing and debugging
     * @param gameId Game ID
     * @param decryptedNumbers Decrypted player submitted numbers
     * @return winnerAddress Winner address, address(0) if no winner
     * @return winningNumber Winning number, 0 if no winner
     */
    function _calculateUniqueMinWinner(
        uint256 gameId,
        uint32[] memory decryptedNumbers
    ) internal view returns (address winnerAddress, uint32 winningNumber) {
        // Validate input parameters
        require(decryptedNumbers.length > 0, "Empty decrypted numbers array");
        require(gameId < gameCounter, "Invalid game ID");
        
        // Count occurrences of each number and find unique numbers
        uint32[] memory uniqueNumbers = new uint32[](decryptedNumbers.length);
        uint32 uniqueCount = 0;
        
        // First step: Count frequencies and find unique numbers
        bool[] memory processed = new bool[](decryptedNumbers.length);
        for (uint32 i = 0; i < decryptedNumbers.length; i++) {
            if (processed[i]) continue;
            
            uint32 currentNumber = decryptedNumbers[i];
            uint32 count = 0;
            
            // Calculate occurrence count of current number
            for (uint32 j = 0; j < decryptedNumbers.length; j++) {
                if (decryptedNumbers[j] == currentNumber) {
                    count++;
                    processed[j] = true;
                }
            }
            
            // If it's a unique number (appears only once), record it
            if (count == 1) {
                uniqueNumbers[uniqueCount] = currentNumber;
                uniqueCount++;
            }
        }
        
        // Second step: Find minimum value among unique numbers
        if (uniqueCount > 0) {
            uint32 minUniqueNumber = uniqueNumbers[0];
            for (uint32 i = 1; i < uniqueCount; i++) {
                if (uniqueNumbers[i] < minUniqueNumber) {
                    minUniqueNumber = uniqueNumbers[i];
                }
            }
            
            // Third step: Find player who submitted the minimum unique number
            for (uint32 i = 0; i < decryptedNumbers.length; i++) {
                if (decryptedNumbers[i] == minUniqueNumber) {
                    winnerAddress = gamePlayerAddresses[gameId][i];
                    winningNumber = minUniqueNumber;
                    break;
                }
            }
        }
        
        // If no unique number is found, return zero values
        // winnerAddress and winningNumber are already initialized to zero values
    }



    /**
     * @notice Winner claims prize
     * @param _gameId Game ID
     */
    function claimPrize(uint256 _gameId) public {
        Game storage game = games[_gameId];
        require(game.status == GameStatus.Finished, "Game is not finished yet");
        require(gameWinners[_gameId] == msg.sender, "You are not the winner");

        uint256 prize = gamePots[_gameId];
        require(prize > 0, "Prize already claimed or no prize");

        gamePots[_gameId] = 0; // Prevent reentrancy attacks
        game.status = GameStatus.PrizeClaimed;
        hasPlayerClaimed[_gameId][msg.sender] = true;

        (bool success, ) = msg.sender.call{value: prize}("");
        require(success, "Failed to send prize");

        emit PrizeClaimed(_gameId, msg.sender, prize);
    }

    /**
     * @notice Player applies for refund in case of tie (90% refund)
     * @param _gameId Game ID
     */
    function claimRefund(uint256 _gameId) public {
        Game storage game = games[_gameId];
        require(game.status == GameStatus.Finished, "Game is not finished yet");
        require(gameWinners[_gameId] == address(0), "Game has a winner, no refund available");
        require(hasPlayerSubmitted[_gameId][msg.sender], "You did not participate in this game");
        require(!hasClaimedRefund[_gameId][msg.sender], "Refund already claimed");

        hasClaimedRefund[_gameId][msg.sender] = true;
        
        // Calculate refund amount for each player (90% of entry fee)
        uint256 refundAmount = (game.entryFee * REFUND_PERCENTAGE) / PERCENTAGE_BASE;
        
        (bool success, ) = msg.sender.call{value: refundAmount}("");
        require(success, "Failed to send refund");

        emit RefundClaimed(_gameId, msg.sender, refundAmount);
    }

    /**
     * @notice Contract creator withdraws platform fees
     */
    function withdrawPlatformFees() public onlyOwner {
        require(platformFees > 0, "No platform fees to withdraw");

        uint256 amount = platformFees;
        platformFees = 0;

        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Failed to withdraw platform fees");

        emit PlatformFeesWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Get platform fee balance
     * @return amount Current platform fee balance
     */
    function getPlatformFees() external view returns (uint256) {
        return platformFees;
    }

    /**
     * @notice Check if player can apply for refund
     * @param _gameId Game ID
     * @param _player Player address
     * @return canClaim Whether can apply for refund
     */
    function canClaimRefund(uint256 _gameId, address _player) external view returns (bool) {
        Game storage game = games[_gameId];
        
        return game.status == GameStatus.Finished &&
               gameWinners[_gameId] == address(0) &&
               hasPlayerSubmitted[_gameId][_player] &&
               !hasClaimedRefund[_gameId][_player];
    }

    // --- View Functions ---

    /**
     * @notice Get all games list
     * @return games Array of all games
     */
    function getAllGames() external view returns (Game[] memory) {
        Game[] memory allGames = new Game[](gameCounter);
        for (uint256 i = 0; i < gameCounter; i++) {
            allGames[i] = games[i];
        }
        return allGames;
    }

    /**
     * @notice Get active games list (status is Open)
     * @return activeGames Array of active games
     */
    function getActiveGames() external view returns (Game[] memory) {
        // First calculate the number of active games
        uint256 activeCount = 0;
        for (uint256 i = 0; i < gameCounter; i++) {
            if (games[i].status == GameStatus.Open) {
                activeCount++;
            }
        }

        // Create array and fill with active games
        Game[] memory activeGames = new Game[](activeCount);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < gameCounter; i++) {
            if (games[i].status == GameStatus.Open) {
                activeGames[currentIndex] = games[i];
                currentIndex++;
            }
        }
        return activeGames;
    }

    /**
     * @notice Get games list by status
     * @param status Game status
     * @return gamesByStatus Array of games with specified status
     */
    function getGamesByStatus(GameStatus status) external view returns (Game[] memory) {
        // First calculate the number of games with specified status
        uint256 statusCount = 0;
        for (uint256 i = 0; i < gameCounter; i++) {
            if (games[i].status == status) {
                statusCount++;
            }
        }

        // Create array and fill with games of specified status
        Game[] memory gamesByStatus = new Game[](statusCount);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < gameCounter; i++) {
            if (games[i].status == status) {
                gamesByStatus[currentIndex] = games[i];
                currentIndex++;
            }
        }
        return gamesByStatus;
    }

    /**
     * @notice Get paginated games list
     * @param offset Offset value
     * @param limit Limit count
     * @return paginatedGames Paginated games array
     */
    function getGamesWithPagination(uint256 offset, uint256 limit) external view returns (Game[] memory) {
        require(offset < gameCounter, "Offset exceeds game count");
        
        uint256 end = offset + limit;
        if (end > gameCounter) {
            end = gameCounter;
        }
        
        uint256 resultLength = end - offset;
        Game[] memory paginatedGames = new Game[](resultLength);
        
        for (uint256 i = 0; i < resultLength; i++) {
            paginatedGames[i] = games[offset + i];
        }
        
        return paginatedGames;
    }

    /**
     * @notice Get game summary information
     * @param gameId Game ID
     * @return summary Game summary information
     */
    function getGameSummary(uint256 gameId) external view returns (GameSummary memory) {
        require(gameId < gameCounter, "Game does not exist");
        
        Game storage game = games[gameId];
        
        return GameSummary({
            gameId: game.gameId,
            roomName: game.roomName,
            creator: game.creator,
            status: game.status,
            playerCount: game.playerCount,
            maxPlayers: game.maxPlayers,
            minNumber: game.minNumber,
            maxNumber: game.maxNumber,
            entryFee: game.entryFee,
            deadline: game.deadline,
            prizePool: gamePots[gameId],
            winner: gameWinners[gameId],
            winningNumber: game.decryptedWinner
        });
    }

    /**
     * @notice Get list of game IDs that player participated in
     * @param player Player address
     * @return gameIds Array of game IDs that player participated in
     */
    function getPlayerGames(address player) external view returns (uint256[] memory) {
        // First calculate the number of games player participated in
        uint256 playerGameCount = 0;
        for (uint256 i = 0; i < gameCounter; i++) {
            if (hasPlayerSubmitted[i][player]) {
                playerGameCount++;
            }
        }

        // Create array and fill with game IDs that player participated in
        uint256[] memory playerGames = new uint256[](playerGameCount);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < gameCounter; i++) {
            if (hasPlayerSubmitted[i][player]) {
                playerGames[currentIndex] = i;
                currentIndex++;
            }
        }
        
        return playerGames;
    }

    /**
     * @notice Get total games count
     * @return count Total games count
     */
    function getTotalGamesCount() external view returns (uint256) {
        return gameCounter;
    }

    /**
     * @notice Check if game can start prize draw
     * @param gameId Game ID
     * @return canFinalize Whether can start prize draw
     */
    function canFinalizeGame(uint256 gameId) external view returns (bool) {
        require(gameId < gameCounter, "Game does not exist");
        
        Game storage game = games[gameId];
        
        if (game.status != GameStatus.Open) {
            return false;
        }
        
        // Reached maximum number of players or passed deadline and has participants
        return (game.playerCount == game.maxPlayers) || 
               (block.timestamp >= game.deadline && game.playerCount > 0);
    }

    /**
     * @notice Get player statistics
     * @param player Player address
     * @return stats Player statistics
     */
    function getPlayerStats(address player) external view returns (PlayerStats memory) {
        uint256 gamesPlayed = 0;
        uint256 gamesWon = 0;
        uint256 totalWinnings = 0;

        // Calculate number of games participated in
        for (uint256 i = 0; i < gameCounter; i++) {
            if (hasPlayerSubmitted[i][player]) {
                gamesPlayed++;
            }
        }

        // Calculate win count and total winnings from winner history
        for (uint256 i = 0; i < winnerHistory.length; i++) {
            if (winnerHistory[i].winner == player) {
                gamesWon++;
                totalWinnings += winnerHistory[i].prize;
            }
        }

        return PlayerStats({
            gamesPlayed: gamesPlayed,
            gamesWon: gamesWon,
            totalWinnings: totalWinnings
        });
    }

    /**
     * @notice Get winner history records
     * @param limit Limit return count, 0 means return all
     * @return records Winner records array
     */
    function getWinnerHistory(uint256 limit) external view returns (WinnerRecord[] memory) {
        uint256 historyLength = winnerHistory.length;
        uint256 returnLength = (limit == 0 || limit > historyLength) ? historyLength : limit;
        
        WinnerRecord[] memory records = new WinnerRecord[](returnLength);
        
        // Return latest records (reverse order)
        for (uint256 i = 0; i < returnLength; i++) {
            records[i] = winnerHistory[historyLength - 1 - i];
        }
        
        return records;
    }

    /**
     * @notice Get winner history records count
     * @return count Winner records count
     */
    function getWinnerHistoryCount() external view returns (uint256) {
        return winnerHistory.length;
    }

    /**
     * @notice Get leaderboard (player list sorted by win count)
     * @param limit Limit of returned players count
     * @return topPlayers Leaderboard player addresses array
     * @return winCounts Corresponding win counts array
     * @return totalWinnings Corresponding total winnings array
     */
    function getLeaderboard(uint256 limit) external view returns (
        address[] memory topPlayers,
        uint256[] memory winCounts,
        uint256[] memory totalWinnings
    ) {
        // Collect all unique winners
        address[] memory uniqueWinners = new address[](winnerHistory.length);
        uint256[] memory winnerCounts = new uint256[](winnerHistory.length);
        uint256[] memory winnerEarnings = new uint256[](winnerHistory.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < winnerHistory.length; i++) {
            address winner = winnerHistory[i].winner;
            bool found = false;
            uint256 foundIndex = 0;

            // Check if this winner has already been recorded
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueWinners[j] == winner) {
                    found = true;
                    foundIndex = j;
                    break;
                }
            }

            if (found) {
                winnerCounts[foundIndex]++;
                winnerEarnings[foundIndex] += winnerHistory[i].prize;
            } else {
                uniqueWinners[uniqueCount] = winner;
                winnerCounts[uniqueCount] = 1;
                winnerEarnings[uniqueCount] = winnerHistory[i].prize;
                uniqueCount++;
            }
        }

        // Determine return count
        uint256 returnCount = (limit == 0 || limit > uniqueCount) ? uniqueCount : limit;
        
        topPlayers = new address[](returnCount);
        winCounts = new uint256[](returnCount);
        totalWinnings = new uint256[](returnCount);

        // Simple bubble sort (descending order by win count)
        for (uint256 i = 0; i < uniqueCount; i++) {
            for (uint256 j = i + 1; j < uniqueCount; j++) {
                if (winnerCounts[i] < winnerCounts[j]) {
                    // Swap positions
                    address tempAddress = uniqueWinners[i];
                    uniqueWinners[i] = uniqueWinners[j];
                    uniqueWinners[j] = tempAddress;
                    
                    uint256 tempCount = winnerCounts[i];
                    winnerCounts[i] = winnerCounts[j];
                    winnerCounts[j] = tempCount;
                    
                    uint256 tempEarnings = winnerEarnings[i];
                    winnerEarnings[i] = winnerEarnings[j];
                    winnerEarnings[j] = tempEarnings;
                }
            }
        }

        // Copy to return arrays
        for (uint256 i = 0; i < returnCount; i++) {
            topPlayers[i] = uniqueWinners[i];
            winCounts[i] = winnerCounts[i];
            totalWinnings[i] = winnerEarnings[i];
        }

        return (topPlayers, winCounts, totalWinnings);
    }
    
    /**
     * @notice Get callback debug information
     * @param gameId Game ID
     * @return isPending Whether waiting for decryption
     * @return requestId Latest request ID
     * @return lastError Last error message
     */
    function getCallbackDebugInfo(uint256 gameId) external view returns (
        bool isPending,
        uint256 requestId,
        string memory lastError
    ) {
        return (
            isDecryptionPending[gameId],
            latestRequestId[gameId],
            lastCallbackError[gameId]
        );
    }
    
}
