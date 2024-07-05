// SPDX-License-Identifier: MI
pragma solidity ^0.8.17;

import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";

contract Lottery is VRFConsumerBase {
    bytes32 internal keyHash; // 
    uint256 internal fee;
    uint256 public randomResult;


    address public owner;
    address payable[] public players;
    uint public lotteryId;
    mapping (uint => address payable) public lotteryHistory;



    constructor() 
        VRFConsumerBase(
            0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B,
            0x779877A7B0D9E8603169DdbD7836e478b4624789
        ) 
    {
        owner = msg.sender;
        lotteryId = 1;
        keyHash = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
        fee = 0.1 * 10 ** 18;
    }

    function getWinnerByLottery(uint lottery) public view returns (address payable) {
        return lotteryHistory[lottery];
    }

    function getBalance() public view returns (uint) {
        return address(this).balance;
    }

    function getPlayers() public view returns (address payable[] memory) {
        return players;
    }

    function enter() public payable {
        require(msg.value > .001 ether, "No fees");
        players.push(payable(msg.sender));
    }

    // function getRandomNumber() public view returns (uint) {
    //     return uint(keccak256(abi.encodePacked(owner, block.timestamp)));
    // }

    

    function getRandomNumber() public onlyowner returns (bytes32 requestId) { //are we removing the modifier
        require(LINK.balanceOf(address(this)) >= fee, "Not enough LINK");
        return requestRandomness(keyHash, fee);
    }

     function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        randomResult = randomness;
        pickWinner();
    }


    function pickWinner() public onlyowner {
        uint index = randomResult % players.length;
        players[index].transfer(address(this).balance);

        lotteryHistory[lotteryId] = players[index];
        lotteryId++;
        

        // reset the state of the contract
        players = new address payable[](0);
    }

    modifier onlyowner() {
      require(msg.sender == owner);
      _;
    }
}
