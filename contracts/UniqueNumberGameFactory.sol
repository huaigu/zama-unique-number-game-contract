// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.20;

import {FHE, euint32, externalEuint32, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

/**
 * @title UniqueNumberGameFactory
 * @author Gemini AI based on Zama FHE
 * @notice 一个功能完备的最小唯一数字游戏平台，支持创建多局游戏、自定义规则和费用。
 */
contract UniqueNumberGameFactory is SepoliaConfig {
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

    // --- 事件 ---

    event GameCreated(
        uint256 indexed gameId,
        address indexed creator,
        uint256 entryFee,
        uint32 maxPlayers,
        uint256 deadline
    );
    event SubmissionReceived(uint256 indexed gameId, address indexed player, uint32 playerCount);
    event WinnerCalculationStarted(uint256 indexed gameId, address indexed trigger);
    event WinnerDetermined(uint256 indexed gameId, uint32 winnerNumber, address indexed winnerAddress);
    event PrizeClaimed(uint256 indexed gameId, address indexed winner, uint256 amount);

    // --- 核心函数 ---

    /**
     * @notice 创建一局新游戏
     * @param _minNumber 数字范围下限
     * @param _maxNumber 数字范围上限
     * @param _maxPlayers 最大参与人数
     * @param _entryFee 参与费用 (in wei)
     * @param _deadlineDuration 游戏持续时间 (in seconds from now)
     */
    function createGame(
        uint32 _minNumber,
        uint32 _maxNumber,
        uint32 _maxPlayers,
        uint256 _entryFee,
        uint256 _deadlineDuration
    ) public {
        require(_minNumber > 0 && _maxNumber > _minNumber, "Invalid number range");
        require(_maxPlayers > 1, "Max players must be at least 2");
        require(_maxNumber - _minNumber < 256, "Range is too large for efficient FHE"); // Gas 限制

        uint256 gameId = gameCounter;
        gameCounter++;

        Game storage newGame = games[gameId];
        newGame.gameId = gameId;
        newGame.creator = msg.sender;
        newGame.status = GameStatus.Open;
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

        emit GameCreated(gameId, msg.sender, _entryFee, _maxPlayers, newGame.deadline);
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
        euint32 encryptedWinnerNumber = game.encryptedWinner; // Start with the initial large value

        for (uint32 i = game.minNumber; i <= game.maxNumber; i++) {
            euint32 one = FHE.asEuint32(1);
            euint32 currentNumber = FHE.asEuint32(i);
            FHE.allowThis(one);
            FHE.allowThis(currentNumber);
            
            ebool isUnique = FHE.eq(gameCounts[_gameId][i], one);
            ebool isSmaller = FHE.lt(currentNumber, encryptedWinnerNumber);
            ebool isNewWinner = FHE.and(isUnique, isSmaller);
            
            encryptedWinnerNumber = FHE.select(isNewWinner, currentNumber, encryptedWinnerNumber);
            FHE.allowThis(encryptedWinnerNumber);
        }
        game.encryptedWinner = encryptedWinnerNumber;
        FHE.allowThis(game.encryptedWinner); // 允许合约解密

        // 步骤1: 请求解密获胜数字
        bytes32[] memory cypherTexts = new bytes32[](1);
        cypherTexts[0] = FHE.toBytes32(game.encryptedWinner);
        
        // 生成解密请求ID并保存对应的游戏ID
        uint256 requestId = uint256(keccak256(abi.encodePacked(block.timestamp, _gameId, cypherTexts[0])));
        requestToGameId[requestId] = _gameId;
        
        FHE.requestDecryption(
            cypherTexts,
            this.callbackDecryptWinnerNumber.selector
        );
    }

    /**
     * @notice [回调函数1] 设置解密后的获胜数字，并立即启动第2步FHE计算来寻找获胜者索引
     * @param requestId 解密请求ID
     * @param decryptedWinnerNumber 解密后的获胜数字
     * @param signatures 验证签名
     */
    function callbackDecryptWinnerNumber(
        uint256 requestId,
        uint32 decryptedWinnerNumber,
        bytes[] memory signatures
    ) public {
        // 验证签名防止未授权解密
        FHE.checkSignatures(requestId, signatures);
        
        // 获取对应的游戏ID
        uint256 gameId = requestToGameId[requestId];
        require(gameId > 0 || gameId == 0, "Invalid request ID");
        
        Game storage game = games[gameId];
        game.decryptedWinner = decryptedWinnerNumber;

        // 如果获胜数字是初始大数，说明没有唯一获胜者，游戏结束
        if (decryptedWinnerNumber > game.maxNumber) {
            game.status = GameStatus.Finished; // No winner
            return;
        }

        // 步骤2: 启动FHE计算，找出获胜者在参与列表中的索引
        euint32 encryptedWinnerIndex = FHE.asEuint32(type(uint32).max); // 无效索引
        euint32 winnerNumberAsEuint = FHE.asEuint32(decryptedWinnerNumber);
        FHE.allowThis(encryptedWinnerIndex);
        FHE.allowThis(winnerNumberAsEuint);

        for (uint32 i = 0; i < game.playerCount; i++) {
            euint32 currentIndex = FHE.asEuint32(i);
            FHE.allowThis(currentIndex);
            
            ebool isMatch = FHE.eq(gameEncryptedSubmissions[gameId][i], winnerNumberAsEuint);
            encryptedWinnerIndex = FHE.select(isMatch, currentIndex, encryptedWinnerIndex);
            FHE.allowThis(encryptedWinnerIndex);
        }

        // 允许合约解密获胜者索引
        FHE.allowThis(encryptedWinnerIndex);

        // 步骤2: 请求解密获胜者索引
        bytes32[] memory indexCypherTexts = new bytes32[](1);
        indexCypherTexts[0] = FHE.toBytes32(encryptedWinnerIndex);
        
        // 生成新的请求ID
        uint256 indexRequestId = uint256(keccak256(abi.encodePacked(block.timestamp + 1, gameId, indexCypherTexts[0])));
        requestToGameId[indexRequestId] = gameId;
        
        FHE.requestDecryption(
            indexCypherTexts,
            this.callbackDecryptWinnerIndex.selector
        );
    }

    /**
     * @notice [回调函数2] 设置最终的获胜者地址
     * @param requestId 解密请求ID
     * @param decryptedWinnerIndex 解密后的获胜者索引
     * @param signatures 验证签名
     */
    function callbackDecryptWinnerIndex(
        uint256 requestId,
        uint32 decryptedWinnerIndex,
        bytes[] memory signatures
    ) public {
        // 验证签名防止未授权解密
        FHE.checkSignatures(requestId, signatures);
        
        // 获取对应的游戏ID
        uint256 gameId = requestToGameId[requestId];
        require(gameId > 0 || gameId == 0, "Invalid request ID");
        
        Game storage game = games[gameId];
        if (decryptedWinnerIndex < game.playerCount) {
            address winnerAddress = gamePlayerAddresses[gameId][decryptedWinnerIndex];
            gameWinners[gameId] = winnerAddress;
            emit WinnerDetermined(gameId, game.decryptedWinner, winnerAddress);
        }
        game.status = GameStatus.Finished;
        
        // 清理请求ID映射
        delete requestToGameId[requestId];
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

        (bool success, ) = msg.sender.call{value: prize}("");
        require(success, "Failed to send prize");

        emit PrizeClaimed(_gameId, msg.sender, prize);
    }
}
