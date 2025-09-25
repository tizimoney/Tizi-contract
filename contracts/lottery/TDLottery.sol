// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "../interfaces/IERC20.sol";

interface IRandomNumberGenerator {
    struct RequestStatus {
        bool fulfilled; // whether the request has been successfully fulfilled
        bool exists; // whether a requestId exists
        uint256[] randomWords;
    }

    function s_requests(uint256) external view returns (RequestStatus memory);

    function requestRandomWords(
        bool enableNativePayment
    ) external returns (uint256 requestId);

    function resultNum() external returns (uint256);

    function getRequestStatus(
        uint256 _requestId
    ) external view returns (bool fulfilled, uint256[] memory randomWords);
}

interface IToken {
    function mint(address to, uint256 amount) external;
    function burn(address account, uint256 amount) external;
}

interface IVault {
    function transferToUser(address to, uint256 amount) external returns (bool);
}

contract TDLottery is Ownable, ReentrancyGuard {
    address public immutable TD;
    address public immutable TLT;
    address public immutable randomNumberGenerator;
    address private immutable vault;

    enum Status {
        Open,
        Close,
        Claimable
    }

    struct Lottery {
        Status status;
        uint256 startTime;
        uint256 endTime;
        uint256 depositPrice;
        uint256 participateAmount;
        address winner;
        uint256 finalNumber;
    }

    struct winnerHistory {
        address winner;
        uint256 priceAmount;
        uint256 winTime;
    }

    struct depositInfo {
        address buyer;
        uint256 amount;
    }

    uint256 public lastRequestId;
    uint256 public lotteryCount = 0;
    uint256 public drawBatch = 0;
    uint256 public depositBatch = 0;
    uint256 public lastRebaseTime;
    uint256 public lastDrawTime;
    uint256 public amountAfterRebase;

    mapping (uint256 => Lottery) public LotteryInfo;
    mapping (address => uint256) public userWinPrice;
    mapping (uint256 => mapping (address => uint256)) public userDepositAmountByBatch;
    mapping (uint256 => winnerHistory) public winnerInfo;
    mapping (address => uint256) public userDepositAmount;
    address[][] public depositAddress;

    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    event userDeposit(address user, uint256 amount, uint256 time, uint256 batch);
    event userWithdraw(address user, uint256 amount, uint256 time);
    event createNewLottery(uint256 time, uint256 batch);
    event rebase(uint256 time, uint256 batch);
    event lotteryClose(uint256 time, uint256 batch, uint256 requestId);
    event LotteryDraw(uint256 time, uint256 batch, uint256 randomNum, address winner, uint256 winPrice);
    event zeroTDWhenLotteryDraw(uint256 time, uint256 batch, uint256 lastAmount);
    event userClaim(uint256 time, address user, uint256 amount);
    event AdminTokenRecovery(address _tokenAddress, uint256 _tokenAmount);

    constructor(
        address _TD,
        address _TLT,
        address _random,
        address _vault
    ) Ownable(msg.sender) {
        TD = _TD;
        TLT = _TLT;
        randomNumberGenerator = _random;
        vault = _vault;
        depositAddress.push();
        lastDrawTime = block.timestamp;
        createLottery();
    }

    function setRebaseTime() external onlyOwner {
        lastRebaseTime = block.timestamp;
        amountAfterRebase = IERC20(TD).balanceOf(address(this));
        emit rebase(lastRebaseTime, depositBatch);

        uint256 depositAmountBefore = LotteryInfo[depositBatch].depositPrice;
        if(amountAfterRebase > depositAmountBefore) {
            createLottery();
        }
    }

    function deposit(uint256 _amount) external notContract {
        require(IERC20(TD).balanceOf(msg.sender) >= _amount, "Balance wrong");
        require(IERC20(TD).transferFrom(msg.sender, address(this), _amount) == true,"transferFrom wrong");
        require(LotteryInfo[depositBatch].status == Status.Open);

        LotteryInfo[depositBatch].depositPrice += _amount;
        userDepositAmount[msg.sender] += _amount;
        if(userDepositAmountByBatch[depositBatch][msg.sender] == 0) {
            LotteryInfo[depositBatch].participateAmount++;
        }
        userDepositAmountByBatch[depositBatch][msg.sender] += _amount;

        bool isAddressExist = false;
        for(uint j = 0; j < depositAddress[depositBatch - 1].length; j++) {
            if(depositAddress[depositBatch - 1][j] == msg.sender) {
                isAddressExist = true;
            }
        }
        if(!isAddressExist) {
            depositAddress[depositBatch - 1].push(msg.sender);
        }

        IToken(TLT).mint(msg.sender, _amount);
        emit userDeposit(msg.sender, _amount, block.timestamp, depositBatch);
    }

    function withdraw(uint256 _amount) external notContract {
        require(IERC20(TLT).balanceOf(msg.sender) >= _amount, "Balance wrong");
        require(userDepositAmount[msg.sender] >= _amount,"msg sender has not deposited before");
        IToken(TLT).burn(msg.sender, _amount);

        if(block.timestamp >= lastRebaseTime && lastRebaseTime > lastDrawTime) {
            if(userDepositAmountByBatch[drawBatch][msg.sender] >= _amount) {
                LotteryInfo[drawBatch].depositPrice -= _amount;
                userDepositAmountByBatch[drawBatch][msg.sender] -= _amount;
                if(userDepositAmountByBatch[drawBatch][msg.sender] == 0) {
                    LotteryInfo[drawBatch].participateAmount--;
                }
                userDepositAmount[msg.sender] -= _amount;
                amountAfterRebase -= _amount;
            } else {
                uint256 lastAmount = userDepositAmountByBatch[drawBatch][msg.sender];
                if(lastAmount != 0) {
                    LotteryInfo[drawBatch].participateAmount--;
                }
                userDepositAmountByBatch[drawBatch][msg.sender] = 0;
                LotteryInfo[drawBatch].depositPrice -= lastAmount;
                amountAfterRebase -= lastAmount;
                require(LotteryInfo[depositBatch].depositPrice >= _amount - lastAmount, "no enough deposit amount!");

                LotteryInfo[depositBatch].depositPrice -= (_amount - lastAmount);
                userDepositAmountByBatch[depositBatch][msg.sender] -= (_amount - lastAmount);
                if(userDepositAmountByBatch[depositBatch][msg.sender] == 0) {
                    LotteryInfo[depositBatch].participateAmount--;
                }
                userDepositAmount[msg.sender] -= _amount;
            }
        } else {
            LotteryInfo[depositBatch].depositPrice -= _amount;
            userDepositAmountByBatch[depositBatch][msg.sender] -= _amount;
            if(userDepositAmountByBatch[depositBatch][msg.sender] == 0) {
                LotteryInfo[depositBatch].participateAmount--;
            }
            userDepositAmount[msg.sender] -= _amount;
        }

        require(IERC20(TD).balanceOf(address(this)) >= _amount, "no enough balance");
        require(IERC20(TD).transfer(msg.sender, _amount) == true, "transfer failed");
        emit userWithdraw(msg.sender, _amount, block.timestamp);
    }

    function claimPrize() external notContract {
        uint256 prizeAmount = userWinPrice[msg.sender];
        require(prizeAmount > 0, "no prize");
        require(IERC20(TD).balanceOf(vault) >= prizeAmount, "no enough balance in vault!");

        require(IVault(vault).transferToUser(msg.sender, prizeAmount), "transfer failed");
        userWinPrice[msg.sender] = 0;
        emit userClaim(block.timestamp, msg.sender, prizeAmount);
    }

    function closeLottery() external onlyOwner {
        require(LotteryInfo[drawBatch].status == Status.Close);
        
        lastRequestId = IRandomNumberGenerator(randomNumberGenerator).requestRandomWords(false);
        emit lotteryClose(block.timestamp, drawBatch, lastRequestId);
    }

    function drawFinalNumberAndMakeLotteryClaimable() external onlyOwner {
        (bool isFulfilled,) = IRandomNumberGenerator(randomNumberGenerator).getRequestStatus(lastRequestId);
        require(isFulfilled == true,"random number has not fulfilled");
        require(LotteryInfo[drawBatch].status == Status.Close,"lottery status should be close");
        require(LotteryInfo[drawBatch].winner == address(0), "already have winner");

        if(LotteryInfo[drawBatch].depositPrice == 0) {
            uint256 winPrice = amountAfterRebase - LotteryInfo[drawBatch].depositPrice;
            require(IERC20(TD).transfer(vault, winPrice) == true, "transfer to vault failed!");
            LotteryInfo[drawBatch].status = Status.Claimable;
            LotteryInfo[drawBatch].endTime = block.timestamp;
            emit zeroTDWhenLotteryDraw(block.timestamp, drawBatch, winPrice);
        } else {
            uint256 winPrice = amountAfterRebase - LotteryInfo[drawBatch].depositPrice;
            uint256 randomNumber = IRandomNumberGenerator(randomNumberGenerator).resultNum();
            uint256 _finalNumber = (randomNumber % ((LotteryInfo[drawBatch].depositPrice) / 1000000000000000000)) + 1;
            address _finalWinner = findWinner(_finalNumber);
            require(IERC20(TD).balanceOf(address(this)) >= winPrice, "no enough balance");
            require(IERC20(TD).transfer(vault, winPrice) == true, "transfer to vault failed!");

            LotteryInfo[drawBatch].winner = _finalWinner;
            LotteryInfo[drawBatch].finalNumber = _finalNumber;
            LotteryInfo[drawBatch].status = Status.Claimable;
            LotteryInfo[drawBatch].endTime = block.timestamp;

            userWinPrice[_finalWinner] += winPrice;
            winnerHistory memory _winnerHistory = winnerHistory({
                winner: _finalWinner,
                priceAmount: winPrice,
                winTime: block.timestamp
            });
            winnerInfo[drawBatch] = _winnerHistory;

            lastDrawTime = block.timestamp;

            updateLeftDeposit();
            emit LotteryDraw(block.timestamp, drawBatch, _finalNumber, _finalWinner, winPrice);
        }
    }

    function findWinner(uint256 randomNum) internal view returns (address) {
        uint256 count = 0;
        for(uint i = 0; i < depositAddress[drawBatch - 1].length; i++) {
            address depositer = depositAddress[drawBatch - 1][i];
            uint256 depositAmount = userDepositAmountByBatch[drawBatch][depositer] / 1000000000000000000;
            if(depositAmount > 0) {
                if(count < randomNum && count + depositAmount >= randomNum) {
                    return depositer;
                }
                count += depositAmount;
            }
        }
    }

    function updateLeftDeposit() internal {
        for(uint i = 0; i < depositAddress[drawBatch - 1].length; i++) {
            address _depositer = depositAddress[drawBatch - 1][i];
            if(userDepositAmountByBatch[drawBatch][_depositer] > 0 && userDepositAmountByBatch[depositBatch][_depositer] == 0) {
                depositAddress[depositBatch - 1].push(_depositer);
                LotteryInfo[depositBatch].participateAmount++;
            }

            userDepositAmountByBatch[depositBatch][_depositer] += userDepositAmountByBatch[drawBatch][_depositer];
            LotteryInfo[depositBatch].depositPrice += userDepositAmountByBatch[drawBatch][_depositer];
        }
    }

    function createLottery() internal {
        lotteryCount++;

        LotteryInfo[lotteryCount] = Lottery({
            status: Status.Open,
            startTime: block.timestamp,
            endTime: 0,
            depositPrice: 0,
            participateAmount: 0,
            winner: address(0),
            finalNumber: 0
        });

        depositBatch++;
        if(depositBatch != 1) {
            drawBatch++;
            LotteryInfo[drawBatch].status = Status.Close;
            if(depositAddress.length < depositBatch) {
                for(uint i = depositAddress.length; i < depositBatch; i++) {
                    depositAddress.push();
                }
            }
        }

        emit createNewLottery(block.timestamp, depositBatch);
    }

    function recoverWrongTokens(address _tokenAddress) external onlyOwner {
        require(_tokenAddress != address(TD), "Cannot be TD token");

        uint256 _tokenAmount = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).transfer(address(msg.sender), _tokenAmount);

        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }

    function _isContract(address _addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }
}