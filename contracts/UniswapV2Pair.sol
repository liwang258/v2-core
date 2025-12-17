pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10 ** 3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0; // uses single storage slot, accessible via getReserves
    uint112 private reserve1; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    /**
     * 返回当前的储备量
     * @return _reserve0 token0的当前储备量
     * @return _reserve1 token1的当前储备量
     * @return _blockTimestampLast  上一次更新这两个储备量的[区块时间戳](单位：秒)
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
        /**
         *  真实上线uniswap这用的是内联汇编，用以降低gas成本
         * assembly {
            // 直接读取存储槽 8（三个变量打包在同一个存储槽），拆分数据返回
                reserve0 := sload(8)       // 取前 112 位 → reserve0
                reserve1 := shr(112, sload(8))  // 右移 112 位 → reserve1
                blockTimestampLast := shr(224, sload(8)) // 右移 224 位 → 时间戳
            }
         */
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    /**
     * 这个方法更新储备量和价格累加器
     * @param balance0 新的 token0 余额
     * @param balance1 新的 token1 余额
     * @param _reserve0 上一次的 token0 储备量
     * @param _reserve1 上一次的 token1 储备量
     */
    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        //关键点:同一个区块内的交易不会更新价格累加器，只有在新的区块内才会更新
        //即：新区块的第一笔交易瞬时价格 乘以 时间差(用来后续计算TWAP的)
        //对有些合约来说他指指定了交易价格必须在某个范围内才允许交易，这个时候就会用到这个价格累加器来计算TWAP的值
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        //更新储备量
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    /**
     * 计算并且分配手续费给feeTo地址
     * @param _reserve0 token0的储备量
     * @param _reserve1 token1的储备量
     * @return feeOn 返回手续费开关是否打开
     */
    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        //获取手续费接收地址
        address feeTo = IUniswapV2Factory(factory).feeTo();
        //非0地址说明手续费开关打开了
        feeOn = feeTo != address(0);
        //获取上一次的k值(reserve0*reserve1)
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                //这里计算当前的rootK和上一次的rootKLast 使用的是储备量的乘积开平方(几何平均数)
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    //totalSupply=首次发行 + 后续添加流动性发行 - 移除流动性销毁 + 手续费发行
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /**
     *  这个方法是用户添加流动性时调用的核心方法
     * @param to 接收流动性代币的用户地址
     * @return liquidity 用户获得的流动性代币数量
     */
    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        //获取当前储备量
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        //获取token0当前的余额(用户在router合约中已经把对应数量的token0和token1转账到这个pair合约地址了)
        uint balance0 = IERC20(token0).balanceOf(address(this));
        //获取token1当前的余额(用户在router合约中已经把对应数量的token0和token1转账到这个pair合约地址了)
        uint balance1 = IERC20(token1).balanceOf(address(this));
        //这里得到用户实际添加的token数量
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
     * 用户在界面上使用token1购买token0调用的核心方法
     * 在调用这个方法之前，用户已经把想要购买 token0（比如 ETH）所需的 token1（比如 USDT）转账到这个合约地址了
     * 这里的逻辑是：把用户转账进来的 token1 作为输入，计算出可以兑换多少 token0 作为输出，然后把 token0 转账给用户
     * 通过lock来保证同一个时刻只能有一个swap操作在执行，防止重入攻击
     * 对用户来说，这个方法的调用通常是通过路由合约 UniswapV2Router02 来间接调用的
     * 例如用户想用 USDT 买入 ETH，路由合约会先把 USDT 转账到这个 Pair 合约地址，然后调用这个 swap 方法，
     * 转账操作和调用这个swap方法是两个独立的交易(用户通过合约交易或者钱包发起，只要这2个交易中有一个失败，整个交易都会回滚)
     * 参数如下：
     * @param amount0Out 要取出的 token0 数量（比如 USDT 是 token1 时，这里为 0）
     * @param amount1Out 要取出的 token1 数量（比如要买入 60000 USDT，这里填 60000 * 10^6，USDT 是 6 位小数）
     * @param to 接收买入代币（USDT）的用户地址
     * @param data 额外数据（普通用户 swap 时通常为空）
     */
    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        //这里通过内联汇编方式获取储备量，节省gas，直接从一个存储槽读取多个变量(自己切割)
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        //校验可购买的量不能超过储备量
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
            //将指定数量的代币转给用户
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            // 闪电贷逻辑 TODO 待理解
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            // 获取最新余额(用户转入的代币已经到账了，转给用户的代币已经扣除了)
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        /**
         * 这里计算用户实际转入的代币数量，_reserve0是之前的储备粮量，balance0是现在的余额
         * 如果用户要买入 token0，那么用户需要转入 token1，balance1 会增加，amount1Out 是 0 amount0Out>0
         * 如果用户要买入 token1，那么用户需要转入 token0，balance0 会增加，amount0Out 是 0 amount1Out>0
         */
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        {
            //这里将balance0和balance1乘以1000，再减去用户转入的amount0In和amount1In乘以3(即扣除0.3%的手续费)
            //当前这个时候还只是计算，并没有实际扣除手续费
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            //扣除手续费后，理论上k值要大于等于以前的k值，否则交易就不合法
            require(
                // 因为balance0Adjusted和balance1Adjusted都乘以1000了，所以右边的k值要乘以1000的平方
                balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000 ** 2),
                'UniswapV2: K'
            );
        }
        //更新储备量，计算TWAP价格累加器
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
