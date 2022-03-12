pragma solidity ^0.8.0;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Apollo} from "./Apollo.sol";
import {InitialLPLocker} from "./InitialLPLocker.sol";

contract ApolloTokenPreSale is Ownable {
    using ECDSAUpgradeable for bytes32;
    using SafeERC20 for IERC20;

    address public signer;
    IUniswapV2Router02 public router;
    uint256 public softCap = 100000 * (10**5);
    uint256 public hardCap = 200000 * (10**5);
    uint256 public preSaleEndTime;
    uint256 public totalSoldAmount;
    uint256 public totalRaisedAmount;
    uint256 public constant allowListSalePrice = 10;
    uint256 public constant limitSalePrice = 11;
    uint256 public constant publicSalePrice = 15;
    uint256 public initialLpApollo;
    uint256 public initialLpUsdc;
    uint256 private constant PER_MITIS_USDC = 160 * 10**6;
    bool public finalized;
    bool public failed;
    bool public takenRestApollo;
    Apollo public apolloToken;
    IERC20 public usdcToken;
    InitialLPLocker public initialLPLocker;

    mapping(address => uint256) public allowListSaleRecord;
    mapping(address => uint256) public limitSaleRecord;
    mapping(address => uint256) public publicSaleRecord;
    mapping(address => bool) public isClaimed;

    event AllowlistSale(address user, uint256 amount);
    event Sale(address user, uint256 amount);
    event LimitSale(address user, uint256 amount);
    event Claim(address user, uint256 amount);
    event Refund(address user, uint256 amount);

    constructor(
        address _signer,
        IUniswapV2Router02 _router,
        IERC20 _usdc,
        uint256 _endTime
    ) {
        signer = _signer;
        router = _router;
        preSaleEndTime = _endTime;
        usdcToken = _usdc;
        initialLpUsdc = 75000 * (10**6);
        initialLpApollo = 50000 * (10**5);
        initialLPLocker = new InitialLPLocker();
        _usdc.approve(address(_router), type(uint256).max);
    }

    modifier onSale() {
        require(!failed, "already failed");
        require(!finalized, "already finished");
        _;
    }

    modifier human() {
        require(tx.origin == msg.sender, "only human");
        _;
    }

    function info()
        public
        view
        returns (
            uint256 _softCap,
            uint256 _hardCap,
            uint256 _preSaleEndTime,
            uint256 _totalSoldAmount,
            uint256 _totalRaisedAmount,
            uint256 _myUsdcBalance,
            uint256 _salerUsdcBalance,
            uint256 _myApolloBalance,
            uint256 _myAllowListSaleRecord,
            uint256 _myLimitSaleRecord,
            uint256 _myPublicSaleRecord,
            bool _isClaimed,
            bool _finalized,
            bool _failed
        )
    {
        _softCap = softCap;
        _hardCap = hardCap;
        _preSaleEndTime = preSaleEndTime;
        _totalSoldAmount = totalSoldAmount;
        _totalRaisedAmount = totalRaisedAmount;
        _finalized = finalized;
        _failed = failed;

        address sender = msg.sender;
        if (address(usdcToken) != address(0)) {
            _myUsdcBalance = usdcToken.balanceOf(sender);
            _salerUsdcBalance = usdcToken.balanceOf(address(this));
        }
        if (address(apolloToken) != address(0)) {
            _myApolloBalance = apolloToken.balanceOf(sender);
        }
        _myAllowListSaleRecord = allowListSaleRecord[sender];
        _myLimitSaleRecord = limitSaleRecord[sender];
        _myPublicSaleRecord = publicSaleRecord[sender];
        _isClaimed = isClaimed[sender];
    }

    function allowlistSale(
        uint256 amount,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public onSale human {
        uint256 currentTime = block.timestamp;
        require(currentTime < preSaleEndTime, "presale finished.");
        address user = msg.sender;
        require(
            keccak256(abi.encodePacked(user)).toEthSignedMessageHash().recover(v, r, s) == signer,
            "sale:INVALID SIGNATURE."
        );
        uint256 saled = allowListSaleRecord[user];
        require(amount + saled >= PER_MITIS_USDC, "At least 160 usdc.");
        require(amount + saled <= 10 * PER_MITIS_USDC, "Limit 1600 usdc.");
        allowListSaleRecord[user] = saled + amount;
        totalSoldAmount += amount / allowListSalePrice;
        totalRaisedAmount += amount;
        require(totalSoldAmount <= hardCap, "Hard cap reached.");
        usdcToken.safeTransferFrom(user, address(this), amount);
        emit AllowlistSale(user, amount);
    }

    function limitSale(uint256 amount) public onSale human {
        uint256 currentTime = block.timestamp;
        address user = msg.sender;
        require(currentTime < preSaleEndTime, "limit sale finished");
        require(amount + limitSaleRecord[user] <= PER_MITIS_USDC, "limit 160 usdc.");
        totalSoldAmount += amount / limitSalePrice;
        require(totalSoldAmount <= hardCap, "Hard cap reached.");
        limitSaleRecord[user] += amount;
        totalRaisedAmount += amount;
        usdcToken.safeTransferFrom(user, address(this), amount);
        emit LimitSale(user, amount);
    }

    function sale(uint256 amount) public onSale human {
        uint256 currentTime = block.timestamp;
        require(currentTime > preSaleEndTime, "public sale not starting");
        address user = msg.sender;
        totalSoldAmount += amount / publicSalePrice;
        require(totalSoldAmount <= hardCap, "Hard cap reached.");
        totalRaisedAmount += amount;
        publicSaleRecord[user] += amount;
        usdcToken.safeTransferFrom(user, address(this), amount);
        emit Sale(user, amount);
    }

    function canClaim(address user)
        public
        view
        returns (
            uint256 allowListAmount,
            uint256 limitSaleAmount,
            uint256 publicSaleAmount
        )
    {
        allowListAmount = allowListSaleRecord[user] / allowListSalePrice;
        limitSaleAmount = limitSaleRecord[user] / limitSalePrice;
        publicSaleAmount = publicSaleRecord[user] / publicSalePrice;
    }

    function claim() public human {
        require(finalized, "not finalized");
        address user = msg.sender;
        require(!isClaimed[user], "already claimed");
        (uint256 allowListAmount, uint256 limitSaleAmount, uint256 publicSaleAmount) = canClaim(user);
        uint256 claimAmmount = allowListAmount + limitSaleAmount + publicSaleAmount;
        require(claimAmmount > 0, "no claim");
        IERC20(apolloToken).safeTransfer(user, claimAmmount);
        isClaimed[user] = true;
        emit Claim(user, claimAmmount);
    }

    function refund() public human {
        require(!finalized, "already finished");
        require(failed, "not failed");
        address user = msg.sender;
        uint256 amount = allowListSaleRecord[user] + limitSaleRecord[user] + publicSaleRecord[user];
        require(amount > 0, "no refund");
        usdcToken.safeTransfer(user, amount);
        allowListSaleRecord[user] = 0;
        limitSaleRecord[user] = 0;
        publicSaleRecord[user] = 0;
        emit Refund(user, amount);
    }

    function finish() public onlyOwner {
        require(address(apolloToken) != address(0), "apollo not set");
        require(!finalized, "already finalized");
        finalized = true;
        router.addLiquidity(
            address(usdcToken),
            address(apolloToken),
            initialLpUsdc,
            initialLpApollo,
            0,
            0,
            address(initialLPLocker),
            block.timestamp
        );
    }

    function fundFail() public onlyOwner {
        require(totalSoldAmount < softCap, "soft cap not reached");
        require(block.timestamp > preSaleEndTime, "pre sale not over");
        require(!failed, "already failed");
        require(!finalized, "already finalized");
        failed = true;
    }

    function setInitialLpApollo(uint256 amount) public onlyOwner {
        initialLpApollo = amount;
    }

    function setInitialLpUsdc(uint256 amount) public onlyOwner {
        initialLpUsdc = amount;
    }

    function setUsdcToken(IERC20 token) public onlyOwner {
        usdcToken = token;
    }

    function setPreSaleEndTime(uint256 time) public onlyOwner {
        preSaleEndTime = time;
    }

    function setApollo(Apollo apollo) public onlyOwner {
        apolloToken = apollo;
    }

    function takeRestApolloAndUsdc(address receiver) public onlyOwner {
        require(finalized, "need finished");
        require(!takenRestApollo, "had taken");
        takenRestApollo = true;
        apolloToken.transfer(receiver, hardCap - totalRaisedAmount);
        usdcToken.transfer(receiver, usdcToken.balanceOf(address(this)));
    }
}
