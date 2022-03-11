// contracts/GameItems.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./DividendPayingToken.sol";
import "./SafeMath.sol";
import "./IterableMapping.sol";
import "./Ownable.sol";


contract SkpVault is ERC20, Ownable {

    using SafeMath for uint256;

    address public SKPAddress;

    // BSC SHIB
    address public SHIB = 0x2859e4544C4bB03966803b044A93563Bd2D0DD4D;

    // MUMBAI SHIB
    // address public  SHIB = 0xcB1e72786A6eb3b44C2a2429e317c8a2462CFeb1;

    // only more than 1000 shib
    // than pull into distribute address
    uint ShiBDistributeAmount = 1 * (10 ** 17);


    SHIBDividendTracker public dividendTracker;

    bool public canRedeem;

    // last redeem date
    mapping (address => uint256) public nextRedeemDate;

    mapping (address => uint256) public initSKPBalance;

    // how many times did address withraw
    // total need 12 times; 
    mapping (address => uint256) public redeemTimes;

    uint ALL_REDEEM_TIMES = 18;

    // 1 month
    uint256 public redeemWaitTime = 60 * 60 * 24 * 30;

    event ProcessedDividendTracker(
        uint256 iterations,
        uint256 claims,
        uint256 lastProcessedIndex,
        bool indexed automatic,
        uint256 gas,
        address indexed processor
    );

    event RedeemInfo(
        address indexed redeemAddr, 
        uint redeemTimes, 
        uint redeemNum,
        uint redeemTime
    );

    constructor(address _SPKAddress) ERC20("SKP-Lock", "SKP-Lock") {
        SKPAddress = _SPKAddress;
        dividendTracker = new SHIBDividendTracker();
    }

    function changeCanRedeem(bool st) public onlyOwner {
        canRedeem = st;
    }

    // redeem skp token
    function redeemSKP() public {
        address addr = msg.sender;

        uint bal = balanceOf(addr);
        uint times = redeemTimes[addr];

        uint initBalance = initSKPBalance[addr];
        uint redeemNumber;

        require(bal > 0 && times < 18, "error: not token to redeem"); 

        uint redeemDate = nextRedeemDate[addr];
        require(block.timestamp >= redeemDate, "ERROR: Need Wait Time");


        if(times == 0) {
            require(canRedeem, "ERROR: Redeem ERROR");
            require(bal == initBalance, "ERROR: Number ERROR");
            redeemNumber = bal.mul(15).div(100);
            initSKPBalance[addr] -= redeemNumber;
        } else if(times == 17) {
            // all 18 month
            // last month redeem all
            redeemNumber = bal;
        } else {
            redeemNumber = initBalance.mul(1).div(17);
        }

        require(redeemNumber <= bal, "error: insufficient SKP amount");

        IERC20(SKPAddress).transfer(addr, redeemNumber);

        redeemTimes[addr] += 1;
        nextRedeemDate[addr] = block.timestamp + redeemWaitTime;

        safeBurn(addr, redeemNumber);

        emit RedeemInfo(addr, times, redeemNumber, block.timestamp);
    }

    function changeRedeemWaitTime(uint newTime) public onlyOwner {
        redeemWaitTime = newTime;
    }

    // ["0xd7336779179354A5E228586898d31c058795238c", "0xbec9536B52d7977AD2bE0842Db0F74a79c40F010"]
    // [1000, 1000]
    // default 9{0}
    function batchSafeMint(address[] memory addrs, uint[] memory amounts) public onlyOwner {
        uint len = addrs.length;
        uint i;
        for(i; i < len; i ++) {
            safeMint(addrs[i], amounts[i]);
        }
    }

    // amount multi 9{0}
    function safeMint(address _account, uint256 _amount) public onlyOwner {
        _amount = _amount * (10 ** 9);

        uint skpBalance = IERC20(SKPAddress).balanceOf(address(this));
        
        require(totalSupply().add(_amount) <= skpBalance, "ERROR: MINT exceed!");

        _mint(_account, _amount);
        initSKPBalance[_account] += _amount;
        dividendTracker.setBalance(_account, balanceOf(_account));
    }

    function safeBurn(address _account, uint256 _amount) private {
        uint bal = balanceOf(_account);
        require(bal >= _amount, "burn amount exceed");
        _burn(_account, _amount);
        dividendTracker.setBalance(_account, balanceOf(_account));
    }

    function handleCalculate() public {
        uint256 shibBalance = IERC20(SHIB).balanceOf(address(this));

        // add locked
        if(shibBalance >= ShiBDistributeAmount) {
            bool success = IERC20(SHIB).transfer(address(dividendTracker), shibBalance);
            if (success) {
                dividendTracker.distributeSHIBDividends(shibBalance);
            }
        }
    }

    function claimShibReward() public {
        uint256 shibBalance = IERC20(SHIB).balanceOf(address(this));

        // add locked
        require(canRedeem, "ERROR: claim ERROR");

        if(shibBalance >= ShiBDistributeAmount) {
            bool success = IERC20(SHIB).transfer(address(dividendTracker), shibBalance);
            if (success) {
                dividendTracker.distributeSHIBDividends(shibBalance);
            }
        }

        uint withdrawAbleAmount = dividendTracker.withdrawableDividendOf(msg.sender);
        require(withdrawAbleAmount > 0, "ERROR : insufficient Amount");

        dividendTracker.processAccount(msg.sender, false);
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function withdrawableDividendOf(address account) public view returns(uint256) {
        return dividendTracker.withdrawableDividendOf(account);
    }

    function dividendTokenBalanceOf(address account) public view returns (uint256) {
        return dividendTracker.balanceOf(account);
    }

    function getNumberOfDividendTokenHolders() external view returns(uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

}

contract SHIBDividendTracker is Ownable, DividendPayingToken {

    using SafeMath for uint256;
    using SafeMathInt for int256;
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private tokenHoldersMap;
    uint256 public lastProcessedIndex;

    mapping (address => bool) public excludedFromDividends;

    mapping (address => uint256) public lastClaimTimes;

    uint256 public claimWait;
    uint256 public minimumTokenBalanceForDividends;

    event ExcludeFromDividends(address indexed account);
    event ClaimWaitUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event Claim(address indexed account, uint256 amount, bool indexed automatic);

    constructor() DividendPayingToken("SHIB_Dividen_Tracker", "SHIB_Dividend_Tracker") {
        claimWait = 60;
        minimumTokenBalanceForDividends = 100_000_000 * (10 ** 9); // must hold 100,000,000+ tokens
    }

    function _transfer(address, address, uint256) internal pure override {
        require(false, "Dividend_Tracker: No transfers allowed");
    }

    function withdrawDividend() public pure override {
        require(false, "Dividend_Tracker: withdrawDividend disabled. Use the 'claim' function on the main contract.");
    }


    function excludeFromDividends(address account) external onlyOwner {
        require(!excludedFromDividends[account]);
        excludedFromDividends[account] = true;

        _setBalance(account, 0);
        tokenHoldersMap.remove(account);

        emit ExcludeFromDividends(account);
    }

    function updateClaimWait(uint256 newClaimWait) external onlyOwner {
        require(newClaimWait >= 0 && newClaimWait <= 86400, "Dividend_Tracker: claimWait must be updated to between 0 and 24 hours");
        require(newClaimWait != claimWait, "Dividend_Tracker: Cannot update claimWait to same value");
        emit ClaimWaitUpdated(newClaimWait, claimWait);
        claimWait = newClaimWait;
    }

    function getLastProcessedIndex() external view returns(uint256) {
        return lastProcessedIndex;
    }

    function getNumberOfTokenHolders() external view returns(uint256) {
        return tokenHoldersMap.keys.length;
    }

    function canAutoClaim(uint256 lastClaimTime) private view returns (bool) {
        if(lastClaimTime > block.timestamp)  {
            return false;
        }

        return block.timestamp.sub(lastClaimTime) >= claimWait;
    }

    function setBalance(address account, uint256 newBalance) external onlyOwner {
        if(excludedFromDividends[account]) {
            return;
        }

        if(newBalance >= minimumTokenBalanceForDividends) {
            _setBalance(account, newBalance);
            tokenHoldersMap.set(account, newBalance);
        }
        else {
            _setBalance(account, 0);
            tokenHoldersMap.remove(account);
        }

        // processAccount(account, true);
    }

    function process(uint256 gas) public returns (uint256, uint256, uint256) {
        uint256 numberOfTokenHolders = tokenHoldersMap.keys.length;

        if(numberOfTokenHolders == 0) {
            return (0, 0, lastProcessedIndex);
        }

        uint256 _lastProcessedIndex = lastProcessedIndex;

        uint256 gasUsed = 0;

        uint256 gasLeft = gasleft();

        uint256 iterations = 0;
        uint256 claims = 0;

        while(gasUsed < gas && iterations < numberOfTokenHolders) {
            _lastProcessedIndex++;

            if(_lastProcessedIndex >= tokenHoldersMap.keys.length) {
                _lastProcessedIndex = 0;
            }

            address account = tokenHoldersMap.keys[_lastProcessedIndex];

            if(canAutoClaim(lastClaimTimes[account])) {
                if(processAccount(account, true)) {
                    claims++;
                }
            }

            iterations++;

            uint256 newGasLeft = gasleft();

            if(gasLeft > newGasLeft) {
                gasUsed = gasUsed.add(gasLeft.sub(newGasLeft));
            }

            gasLeft = newGasLeft;
        }

        lastProcessedIndex = _lastProcessedIndex;

        return (iterations, claims, lastProcessedIndex);
    }

    function processAccount(address account, bool automatic) public onlyOwner returns (bool) {
        uint256 amount = _withdrawDividendOfUser(account);

        if(amount > 0) {
            lastClaimTimes[account] = block.timestamp;
            emit Claim(account, amount, automatic);
            return true;
        }

        return false;
    }
    



}