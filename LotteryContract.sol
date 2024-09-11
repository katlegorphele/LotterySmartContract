// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts@1.2.0/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts@1.2.0/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

contract Lottery is ReentrancyGuard, VRFConsumerBaseV2Plus {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // ChainLink VRFv2 Subscription Settings
    VRFCoordinatorV2Interface COORDINATOR;

    // These values (sub_id & vrfCoord) are specific to the sepolia testnet
    uint256 private s_subscriptionId;
    address private vrfCoordinator = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
    bytes32 private keyHash = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
    uint16 private requestConfirmations = 3;
    uint32 private numWords = 6;
    uint32 private callbackGasLimit = 2500000;
    address private s_owner;

    struct RequestStatus {
        bool fulfilled;
        bool exists;
        uint[] randomWords;
    }

    mapping(uint256 => RequestStatus) public s_requests;
    mapping(uint => bool) public numberExists; // USED TO CHECK FOR DUPLICATES IN FINAL NUMBER LIST
    uint256 public lastRequestId;

    // Lottery Settings
    IERC20 public paytoken;
    uint256 public currentLotteryId;
    uint256 public currentTicketId;
    uint256 public ticketPrice = 1 ether;
    uint256 public serviceFee = 3000; // BASIS POINTS 3000 is 30%
    uint256 public numberWinner; // Keeps track of lottery
    uint[6] private finalNumbers;

    enum Status {
        Open,
        Close,
        Claimable
    }

    struct LotteryInfo {
        Status status;
        uint256 startTime;
        uint256 endTime;
        uint256 firstTicketId;
        uint256 transferJackpot;
        uint256 lastTicketId;
        uint[6] winningNumbers;
        uint256 totalPayout;
        uint256 commision;
        uint256 winnerCount;
    }

    struct Ticket {
        uint256 ticketId;
        address owner;
        uint[6] chooseNumbers;
    }

    mapping(uint256 => LotteryInfo) public _lotteries;
    mapping(uint256 => Ticket) private _tickets;
    mapping(address => mapping(uint256 => uint256[])) private _userTicketIdsPerLotteryId;
    mapping(address => mapping(uint256 => uint256)) public _winnersPerLotteryId;

    event LotteryWinnerNumber(uint256 indexed lotteryId, uint[6] finalNumber);
    event LotteryClose(uint256 indexed lotteryId, uint256 lastTicketId);
    event LotteryOpen(
        uint256 indexed lotteryId,
        uint256 startTime,
        uint256 endTime,
        uint256 ticketPrice,
        uint256 firstTicketId,
        uint256 transferJackpot,
        uint256 lastTicketId,
        uint256 totalPayout
    );

    event TicketsPurchase(
        address indexed buyer,
        uint256 indexed lotteryId,
        uint[6] chooseNumbers
    );

    constructor(uint256 subscriptionId) 
        VRFConsumerBaseV2Plus(vrfCoordinator)
    {
        COORDINATOR = VRFCoordinatorV2Interface(vrfCoordinator);
        s_owner = msg.sender;
        s_subscriptionId = subscriptionId;
        paytoken = IERC20(0x6f2583Ca0076351397AA78378dc3B5d51cC064ce); // ABC Lottery Token (ALT) token address on Scroll Sepolia
    }

    /**
   Chainlink VRFv2 Specific functions required in the smart contract for full functionality.
    */

    function getRequestStatus(
    ) external view returns (bool fulfilled, uint256[] memory randomWords) {
        require(s_requests[lastRequestId].exists, "request not found");
        RequestStatus memory request = s_requests[lastRequestId];
        return (request.fulfilled, request.randomWords);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        require(s_requests[requestId].exists, "Request not found");
        s_requests[requestId].randomWords = randomWords;
        s_requests[requestId].fulfilled = true;
    }

    /*
    Start of lottery functions 
    */
    // Open lottery function
    function openLottery() external onlyOwner nonReentrant {
        currentLotteryId++;
        currentTicketId++;
        uint256 fundJackpot = (_lotteries[currentLotteryId].transferJackpot).add(1); // This adds 1 to the jackpot prize pool. Adjust as needed
        uint256 transferJackpot;
        uint256 totalPayout;
        uint256 lastTicketId;
        uint256 endTime;
        _lotteries[currentLotteryId] = LotteryInfo({
            status: Status.Open,
            startTime: block.timestamp,
            endTime: (block.timestamp).add(10 seconds),
            firstTicketId: currentTicketId,
            transferJackpot: fundJackpot,
            winningNumbers: [uint(0), uint(0), uint(0), uint(0), uint(0), uint(0)],
            lastTicketId: currentTicketId,
            totalPayout: 0,
            commision: 0,
            winnerCount: 0
        });
        emit LotteryOpen(
            currentLotteryId,
            block.timestamp,
            endTime,
            ticketPrice,
            currentTicketId,
            transferJackpot,
            lastTicketId,
            totalPayout
        );
    }

    // Close lottery function
    function closeLottery() external onlyOwner {
        require(_lotteries[currentLotteryId].status == Status.Open, "Lottery not open");
        require(block.timestamp > _lotteries[currentLotteryId].endTime, "Lottery not over");
        _lotteries[currentLotteryId].lastTicketId = currentTicketId;
        _lotteries[currentLotteryId].status = Status.Close;

        // Request Id for ChainLink VRF
        uint256 requestId;
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({
                        nativePayment: false // KEEP THIS FALSE SO THAT IS USES THE SUBSCRIPTION BALANCE
                    })
                )
            })
        );
        s_requests[requestId] = RequestStatus({
            randomWords: new uint256[](numWords),
            exists: true,
            fulfilled: false
        });
        lastRequestId = requestId;
        emit LotteryClose(currentLotteryId, currentTicketId);
    }

    // Draw numbers function
    function drawNumbers() external onlyOwner nonReentrant {
        require(_lotteries[currentLotteryId].status == Status.Close, "Lottery is not closed");
        uint[] memory numArray = s_requests[lastRequestId].randomWords;
        
        for (uint i = 0; i < finalNumbers.length; i++) {
            uint newNumber = (numArray[i] % 49) + 1;
            while (numberExists[newNumber]) {
                newNumber = (newNumber % 49) + 1;
            }
            finalNumbers[i] = newNumber;
            numberExists[newNumber] = true;
        }
        // uint[6] memory sortedNums;
        // sortedNums = sortArrays(finalNumbers);
        // finalNumbers = sortedNums;
        _lotteries[currentLotteryId].winningNumbers = finalNumbers;
        _lotteries[currentLotteryId].totalPayout = _lotteries[currentLotteryId].transferJackpot;
        emit LotteryWinnerNumber(currentLotteryId, finalNumbers);
    }

    // Buy tickets function
    function buyTickets(uint[6] memory numbers) public payable nonReentrant {
        uint256 walletBalance = paytoken.balanceOf(msg.sender);
        require(walletBalance >= ticketPrice, "Funds not available to complete transaction");
        paytoken.transferFrom(address(msg.sender), address(this), ticketPrice);
        // Calculate Commission Fee
        uint256 commisionFee = (ticketPrice.mul(serviceFee)).div(10000);
        // Platform commission per ticket sale
        _lotteries[currentLotteryId].commision += commisionFee;
        uint256 netEarn = ticketPrice - commisionFee;
        _lotteries[currentLotteryId].transferJackpot += netEarn;

        // Store ticket number array for the buyer
        _userTicketIdsPerLotteryId[msg.sender][currentLotteryId].push(currentTicketId);
        _tickets[currentTicketId] = Ticket({ticketId:currentTicketId, owner: msg.sender, chooseNumbers: numbers });
        currentTicketId++;
        _lotteries[currentLotteryId].lastTicketId = currentTicketId;
        emit TicketsPurchase(msg.sender, currentLotteryId, numbers);
    }

    

    function countWinners( uint256 _lottoId) external onlyOwner {
       require(_lotteries[_lottoId].status == Status.Close, "Lottery not close");
       require(_lotteries[_lottoId].status != Status.Claimable, "Lottery Already Counted");
       delete numberWinner;
       uint256 firstTicketId = _lotteries[_lottoId].firstTicketId;
       uint256 lastTicketId = _lotteries[_lottoId].lastTicketId;
       uint[6] memory winOrder;
       winOrder = sortArrays(finalNumbers);
       bytes32 encodeWin = keccak256(abi.encodePacked(winOrder));
       uint256 i = firstTicketId;
        for (i; i < lastTicketId; i++) {
            address buyer = _tickets[i].owner;
            uint[6] memory userNum = _tickets[i].chooseNumbers;
            bytes32 encodeUser = keccak256(abi.encodePacked(userNum));
              if (encodeUser == encodeWin) {
                  numberWinner++;
                  _lotteries[_lottoId].winnerCount = numberWinner;
                  _winnersPerLotteryId[buyer][_lottoId] = 1;
              }
        }
        if (numberWinner == 0){
            uint256 nextLottoId = (currentLotteryId).add(1);
            _lotteries[nextLottoId].transferJackpot = _lotteries[currentLotteryId].totalPayout;
        }
    _lotteries[currentLotteryId].status = Status.Claimable;
   }

    function sortArrays(uint[6] memory numbers) internal pure returns (uint[6] memory) {
            bool swapped;
        for (uint i = 1; i < numbers.length; i++) {
            swapped = false;
            for (uint j = 0; j < numbers.length - i; j++) {
                uint next = numbers[j + 1];
                uint actual = numbers[j];
                if (next < actual) {
                    numbers[j] = next;
                    numbers[j + 1] = actual;
                    swapped = true;
                }
            }
            if (!swapped) {
                return numbers;
            }
        }
        return numbers;
    }


    function getRandomWords(
        uint256 _requestId
    ) internal view returns (uint256[] memory randomWords) {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.randomWords);
    }


    

    function claimPrize(uint256 _lottoId) external nonReentrant {
        require(_lotteries[_lottoId].status == Status.Claimable, "Not Payable");
        require(_lotteries[_lottoId].winnerCount > 0, "Not Payable");
        require(_winnersPerLotteryId[msg.sender][_lottoId] == 1, "Not Payable");
        uint256 winners = _lotteries[_lottoId].winnerCount;
        uint256 payout = (_lotteries[_lottoId].totalPayout).div(winners);
        paytoken.safeTransfer(msg.sender, payout);
        
        _winnersPerLotteryId[msg.sender][_lottoId] = 0;
   }

    function viewTickets(uint256 ticketId) external view returns (address, uint[6] memory) {
        address buyer;
        buyer = _tickets[ticketId].owner;
        uint[6] memory numbers;
        numbers = _tickets[ticketId].chooseNumbers;
        return (buyer, numbers);
    }


    function getBalance() external view onlyOwner returns(uint256) {
        return paytoken.balanceOf(address(this));
    }

    function fundContract(uint256 amount) external onlyOwner {
        paytoken.safeTransferFrom(address(msg.sender), address(this), amount);
    }

    function withdraw() public onlyOwner() {
      paytoken.safeTransfer(address(msg.sender), (paytoken.balanceOf(address(this))));
    }
}
