// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.20;

import {FHE, euint32, externalEuint32, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

// 简单的 Owner 管理
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
 * @notice 一个功能完备的最小唯一数字游戏平台，支持创建多局游戏、自定义规则和费用。
 */
contract UniqueNumberGameFactory is SepoliaConfig, Ownable {
    // --- 数据结构 ---
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
        // 游戏规则
        uint32 minNumber;
        uint32 maxNumber;
        uint32 maxPlayers;
        uint256 entryFee;
        uint256 deadline;
        // 游戏进程
        uint32 playerCount;
        // FHE 计算结果
        euint32 encryptedWinner;
        uint32 decryptedWinner;
    }

    // GameSummary结构体，用于提供游戏的摘要信息
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

    // 玩家统计结构体
    struct PlayerStats {
        uint256 gamesPlayed;
        uint256 gamesWon;
        uint256 totalWinnings;
    }

    // 获胜记录结构体
    struct WinnerRecord {
        uint256 gameId;
        string roomName;
        address winner;
        uint32 winningNumber;
        uint256 prize;
        uint256 timestamp;
    }

    // --- 状态变量 ---

    uint256 public gameCounter; // 用于生成唯一的 gameId
    mapping(uint256 => Game) public games; // 存储所有游戏

    // 存储每局游戏的数据，因为 mapping 不能在 struct 中
    // gameId => number => encrypted count
    mapping(uint256 => mapping(uint32 => euint32)) public gameCounts;
    // gameId => list of player addresses
    mapping(uint256 => address[]) public gamePlayerAddresses;
    // gameId => list of encrypted submissions
    mapping(uint256 => euint32[]) public gameEncryptedSubmissions;
    // gameId => has player submitted?
    mapping(uint256 => mapping(address => bool)) public hasPlayerSubmitted;
    // gameId => prize pool
    mapping(uint256 => uint256) public gamePots;
    // gameId => winner address
    mapping(uint256 => address) public gameWinners;
    // requestId => gameId (用于回调函数识别游戏)
    mapping(uint256 => uint256) private requestToGameId;
    // 获胜历史记录数组
    WinnerRecord[] public winnerHistory;
    
    // 平局退款相关
    // gameId => player => has claimed refund
    mapping(uint256 => mapping(address => bool)) public hasClaimedRefund;
    // gameId => player => has claimed prize
    mapping(uint256 => mapping(address => bool)) public hasPlayerClaimed;
    // 平台费累积
    uint256 public platformFees;
    // 退款比例 (90% = 9000 / 10000)
    uint256 public constant REFUND_PERCENTAGE = 9000;
    uint256 public constant PERCENTAGE_BASE = 10000;

    // --- 事件 ---

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

    // --- 核心函数 ---

    /**
     * @notice 创建一局新游戏
     * @param _roomName 房间名字
     * @param _minNumber 数字范围下限
     * @param _maxNumber 数字范围上限
     * @param _maxPlayers 最大参与人数
     * @param _entryFee 参与费用 (in wei)
     * @param _deadlineDuration 游戏持续时间 (in seconds from now)
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
        require(_maxNumber - _minNumber < 256, "Range is too large for efficient FHE"); // Gas 限制

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
        newGame.encryptedWinner = FHE.asEuint32(_maxNumber + 1); // 初始化为不可能的大数
        FHE.allowThis(newGame.encryptedWinner); // 允许合约访问这个加密值

        // 初始化 FHE 计数器
        for (uint32 i = _minNumber; i <= _maxNumber; i++) {
            gameCounts[gameId][i] = FHE.asEuint32(0);
            FHE.allowThis(gameCounts[gameId][i]); // 允许合约访问计数器
        }

        emit GameCreated(gameId, msg.sender, _roomName, _entryFee, _maxPlayers, newGame.deadline);
    }

    /**
     * @notice 提交一个加密数字参与游戏
     * @param _gameId 游戏ID
     * @param _encryptedNumber 加密的数字
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
        FHE.allowThis(submittedNumber); // 允许合约访问提交的加密数字
        gamePlayerAddresses[_gameId].push(msg.sender);
        gameEncryptedSubmissions[_gameId].push(submittedNumber);

        // 更新 FHE 计数
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

        // 如果达到最大人数，立即触发开奖
        if (game.playerCount == game.maxPlayers) {
            _findWinner(_gameId);
        }
    }

    /**
     * @notice 在截止时间后手动触发开奖
     * @param _gameId 游戏ID
     */
    function findWinnerByDeadline(uint256 _gameId) public {
        Game storage game = games[_gameId];
        require(game.status == GameStatus.Open, "Game is not open or already finished");
        require(block.timestamp >= game.deadline, "Deadline has not passed yet");
        require(game.playerCount > 0, "No players in the game");

        _findWinner(_gameId);
    }

    /**
     * @notice 内部函数，执行寻找获胜数字的FHE计算
     */
    function _findWinner(uint256 _gameId) internal {
        games[_gameId].status = GameStatus.Calculating;
        emit WinnerCalculationStarted(_gameId, msg.sender);

        Game storage game = games[_gameId];
        
        // 🎯 新优化逻辑：直接解密所有玩家提交的数字
        // 批量解密所有玩家提交的数字，然后在明文中计算获胜者
        bytes32[] memory allSubmissions = new bytes32[](game.playerCount);
        for (uint32 i = 0; i < game.playerCount; i++) {
            allSubmissions[i] = FHE.toBytes32(gameEncryptedSubmissions[_gameId][i]);
        }
        
        // 生成解密请求ID并保存对应的游戏ID
        uint256 requestId = uint256(keccak256(abi.encodePacked(block.timestamp, _gameId, "allSubmissions")));
        requestToGameId[requestId] = _gameId;
        
        // 一次性解密所有提交的数字
        FHE.requestDecryption(
            allSubmissions,
            this.callbackDecryptAllSubmissions.selector
        );
    }

    /**
     * @notice [新优化回调函数] 处理所有玩家提交数字的解密结果，直接计算获胜者
     * @param requestId 解密请求ID
     * @param decryptedNumbers 解密后的所有玩家提交数字数组
     * @param signatures 验证签名
     */
    function callbackDecryptAllSubmissions(
        uint256 requestId,
        uint32[] memory decryptedNumbers,
        bytes[] memory signatures
    ) public {
        // 验证签名防止未授权解密
        FHE.checkSignatures(requestId, signatures);
        
        // 获取对应的游戏ID
        uint256 gameId = requestToGameId[requestId];
        require(gameId > 0 || gameId == 0, "Invalid request ID");
        
        Game storage game = games[gameId];
        
        // 清理请求ID映射
        delete requestToGameId[requestId];
        
        // 游戏结束
        game.status = GameStatus.Finished;
        
        // 🎯 核心逻辑：在明文数组中找到唯一最小值
        address winnerAddress = address(0);
        uint32 winningNumber = 0;
        
        // 统计每个数字的出现次数和找唯一数字
        uint32[] memory uniqueNumbers = new uint32[](decryptedNumbers.length);
        uint32 uniqueCount = 0;
        
        // 第一步：统计频次并找到唯一数字
        bool[] memory processed = new bool[](decryptedNumbers.length);
        for (uint32 i = 0; i < decryptedNumbers.length; i++) {
            if (processed[i]) continue;
            
            uint32 currentNumber = decryptedNumbers[i];
            uint32 count = 0;
            
            // 计算当前数字出现次数
            for (uint32 j = 0; j < decryptedNumbers.length; j++) {
                if (decryptedNumbers[j] == currentNumber) {
                    count++;
                    processed[j] = true;
                }
            }
            
            // 如果是唯一数字（出现次数为1），记录下来
            if (count == 1) {
                uniqueNumbers[uniqueCount] = currentNumber;
                uniqueCount++;
            }
        }
        
        // 第二步：在唯一数字中找到最小值
        if (uniqueCount > 0) {
            uint32 minUniqueNumber = uniqueNumbers[0];
            for (uint32 i = 1; i < uniqueCount; i++) {
                if (uniqueNumbers[i] < minUniqueNumber) {
                    minUniqueNumber = uniqueNumbers[i];
                }
            }
            
            // 第三步：找到提交最小唯一数字的玩家
            for (uint32 i = 0; i < decryptedNumbers.length; i++) {
                if (decryptedNumbers[i] == minUniqueNumber) {
                    winnerAddress = gamePlayerAddresses[gameId][i];
                    winningNumber = minUniqueNumber;
                    break;
                }
            }
        }
        
        // 保存结果
        game.decryptedWinner = winningNumber;
        
        if (winnerAddress != address(0)) {
            // 有获胜者
            gameWinners[gameId] = winnerAddress;
            
            // 记录获胜历史
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
            // 无获胜者，计算平台费用
            uint256 totalPot = gamePots[gameId];
            uint256 platformFee = (totalPot * (PERCENTAGE_BASE - REFUND_PERCENTAGE)) / PERCENTAGE_BASE;
            platformFees += platformFee;
            
            emit NoWinnerDetermined(gameId, totalPot);
        }
    }

    /**
     * @notice [废弃函数] 旧的回调函数 - 保留以兼容现有测试
     * @dev 这些函数现在已经不会被调用，统一由 callbackDecryptAllSubmissions 处理
     */
    function callbackDecryptWinnerNumber(
        uint256, // requestId
        uint32,  // decryptedWinnerNumber  
        bytes[] memory // signatures
    ) public pure {
        revert("This callback is deprecated, use callbackDecryptAllSubmissions");
    }

    function callbackDecryptPlayerSubmissions(
        uint256, // requestId
        uint32[] memory, // decryptedNumbers
        bytes[] memory // signatures
    ) public pure {
        revert("This callback is deprecated, use callbackDecryptAllSubmissions");
    }

    function callbackDecryptWinnerIndex(
        uint256, // requestId
        uint32,  // decryptedWinnerIndex
        bytes[] memory // signatures
    ) public pure {
        revert("This callback is deprecated, use callbackDecryptAllSubmissions");
    }

    /**
     * @notice 获胜者领取奖金
     * @param _gameId 游戏ID
     */
    function claimPrize(uint256 _gameId) public {
        Game storage game = games[_gameId];
        require(game.status == GameStatus.Finished, "Game is not finished yet");
        require(gameWinners[_gameId] == msg.sender, "You are not the winner");

        uint256 prize = gamePots[_gameId];
        require(prize > 0, "Prize already claimed or no prize");

        gamePots[_gameId] = 0; // 防止重入攻击
        game.status = GameStatus.PrizeClaimed;
        hasPlayerClaimed[_gameId][msg.sender] = true;

        (bool success, ) = msg.sender.call{value: prize}("");
        require(success, "Failed to send prize");

        emit PrizeClaimed(_gameId, msg.sender, prize);
    }

    /**
     * @notice 平局情况下玩家申请退款（90%退款）
     * @param _gameId 游戏ID
     */
    function claimRefund(uint256 _gameId) public {
        Game storage game = games[_gameId];
        require(game.status == GameStatus.Finished, "Game is not finished yet");
        require(gameWinners[_gameId] == address(0), "Game has a winner, no refund available");
        require(hasPlayerSubmitted[_gameId][msg.sender], "You did not participate in this game");
        require(!hasClaimedRefund[_gameId][msg.sender], "Refund already claimed");

        hasClaimedRefund[_gameId][msg.sender] = true;
        
        // 计算每个玩家的退款金额 (90% of entry fee)
        uint256 refundAmount = (game.entryFee * REFUND_PERCENTAGE) / PERCENTAGE_BASE;
        
        (bool success, ) = msg.sender.call{value: refundAmount}("");
        require(success, "Failed to send refund");

        emit RefundClaimed(_gameId, msg.sender, refundAmount);
    }

    /**
     * @notice 合约创建者提取平台费用
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
     * @notice 获取平台费余额
     * @return amount 当前平台费余额
     */
    function getPlatformFees() external view returns (uint256) {
        return platformFees;
    }

    /**
     * @notice 检查玩家是否可以申请退款
     * @param _gameId 游戏ID
     * @param _player 玩家地址
     * @return canClaim 是否可以申请退款
     */
    function canClaimRefund(uint256 _gameId, address _player) external view returns (bool) {
        Game storage game = games[_gameId];
        
        return game.status == GameStatus.Finished &&
               gameWinners[_gameId] == address(0) &&
               hasPlayerSubmitted[_gameId][_player] &&
               !hasClaimedRefund[_gameId][_player];
    }

    // --- View 函数 ---

    /**
     * @notice 获取所有游戏列表
     * @return games 所有游戏的数组
     */
    function getAllGames() external view returns (Game[] memory) {
        Game[] memory allGames = new Game[](gameCounter);
        for (uint256 i = 0; i < gameCounter; i++) {
            allGames[i] = games[i];
        }
        return allGames;
    }

    /**
     * @notice 获取活跃游戏列表（状态为Open）
     * @return activeGames 活跃游戏的数组
     */
    function getActiveGames() external view returns (Game[] memory) {
        // 首先计算活跃游戏数量
        uint256 activeCount = 0;
        for (uint256 i = 0; i < gameCounter; i++) {
            if (games[i].status == GameStatus.Open) {
                activeCount++;
            }
        }

        // 创建数组并填充活跃游戏
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
     * @notice 根据状态获取游戏列表
     * @param status 游戏状态
     * @return gamesByStatus 指定状态的游戏数组
     */
    function getGamesByStatus(GameStatus status) external view returns (Game[] memory) {
        // 首先计算指定状态的游戏数量
        uint256 statusCount = 0;
        for (uint256 i = 0; i < gameCounter; i++) {
            if (games[i].status == status) {
                statusCount++;
            }
        }

        // 创建数组并填充指定状态的游戏
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
     * @notice 分页获取游戏列表
     * @param offset 偏移量
     * @param limit 限制数量
     * @return paginatedGames 分页的游戏数组
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
     * @notice 获取游戏的摘要信息
     * @param gameId 游戏ID
     * @return summary 游戏摘要信息
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
     * @notice 获取玩家参与的游戏ID列表
     * @param player 玩家地址
     * @return gameIds 玩家参与的游戏ID数组
     */
    function getPlayerGames(address player) external view returns (uint256[] memory) {
        // 首先计算玩家参与的游戏数量
        uint256 playerGameCount = 0;
        for (uint256 i = 0; i < gameCounter; i++) {
            if (hasPlayerSubmitted[i][player]) {
                playerGameCount++;
            }
        }

        // 创建数组并填充玩家参与的游戏ID
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
     * @notice 获取游戏总数
     * @return count 总游戏数量
     */
    function getTotalGamesCount() external view returns (uint256) {
        return gameCounter;
    }

    /**
     * @notice 检查游戏是否可以开始开奖
     * @param gameId 游戏ID
     * @return canFinalize 是否可以开奖
     */
    function canFinalizeGame(uint256 gameId) external view returns (bool) {
        require(gameId < gameCounter, "Game does not exist");
        
        Game storage game = games[gameId];
        
        if (game.status != GameStatus.Open) {
            return false;
        }
        
        // 达到最大人数或者过了截止时间且有参与者
        return (game.playerCount == game.maxPlayers) || 
               (block.timestamp >= game.deadline && game.playerCount > 0);
    }

    /**
     * @notice 获取玩家统计信息
     * @param player 玩家地址
     * @return stats 玩家统计信息
     */
    function getPlayerStats(address player) external view returns (PlayerStats memory) {
        uint256 gamesPlayed = 0;
        uint256 gamesWon = 0;
        uint256 totalWinnings = 0;

        // 计算参与的游戏数量
        for (uint256 i = 0; i < gameCounter; i++) {
            if (hasPlayerSubmitted[i][player]) {
                gamesPlayed++;
            }
        }

        // 从获胜历史中计算获胜次数和总奖金
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
     * @notice 获取获胜历史记录
     * @param limit 限制返回数量，0表示返回全部
     * @return records 获胜记录数组
     */
    function getWinnerHistory(uint256 limit) external view returns (WinnerRecord[] memory) {
        uint256 historyLength = winnerHistory.length;
        uint256 returnLength = (limit == 0 || limit > historyLength) ? historyLength : limit;
        
        WinnerRecord[] memory records = new WinnerRecord[](returnLength);
        
        // 返回最新的记录（倒序）
        for (uint256 i = 0; i < returnLength; i++) {
            records[i] = winnerHistory[historyLength - 1 - i];
        }
        
        return records;
    }

    /**
     * @notice 获取获胜历史记录总数
     * @return count 获胜记录总数
     */
    function getWinnerHistoryCount() external view returns (uint256) {
        return winnerHistory.length;
    }

    /**
     * @notice 获取排行榜（按获胜次数排序的玩家列表）
     * @param limit 返回的玩家数量限制
     * @return topPlayers 排行榜玩家地址数组
     * @return winCounts 对应的获胜次数数组
     * @return totalWinnings 对应的总奖金数组
     */
    function getLeaderboard(uint256 limit) external view returns (
        address[] memory topPlayers,
        uint256[] memory winCounts,
        uint256[] memory totalWinnings
    ) {
        // 收集所有独特的获胜者
        address[] memory uniqueWinners = new address[](winnerHistory.length);
        uint256[] memory winnerCounts = new uint256[](winnerHistory.length);
        uint256[] memory winnerEarnings = new uint256[](winnerHistory.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < winnerHistory.length; i++) {
            address winner = winnerHistory[i].winner;
            bool found = false;
            uint256 foundIndex = 0;

            // 检查是否已经记录过这个获胜者
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

        // 确定返回数量
        uint256 returnCount = (limit == 0 || limit > uniqueCount) ? uniqueCount : limit;
        
        topPlayers = new address[](returnCount);
        winCounts = new uint256[](returnCount);
        totalWinnings = new uint256[](returnCount);

        // 简单的冒泡排序（按获胜次数降序）
        for (uint256 i = 0; i < uniqueCount; i++) {
            for (uint256 j = i + 1; j < uniqueCount; j++) {
                if (winnerCounts[i] < winnerCounts[j]) {
                    // 交换位置
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

        // 复制到返回数组
        for (uint256 i = 0; i < returnCount; i++) {
            topPlayers[i] = uniqueWinners[i];
            winCounts[i] = winnerCounts[i];
            totalWinnings[i] = winnerEarnings[i];
        }

        return (topPlayers, winCounts, totalWinnings);
    }
}
