pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    /**
     * feeTo:手续费的接收地址
     * Uniswap V2 中，交易对合约（UniswapV2Pair）的交易手续费（默认 0.3%），
     * 会按规则分配：大部分给流动性提供者（LP）(0.25%)，小部分（可选0.05%）会转给 feeTo 地址（通常是项目方、国库或治理合约）
     * @notice
     */
    address public feeTo;
    //有权修改feeTo变量的账户/合约
    address public feeToSetter;
    //key:第一个ERC20代币（tokenA）合约的地址 value（key：第二个ERC20代币合约(tokenB)地址,value:tokenA和tokenB组成的交易对(Pair)合约地址）
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    //创建交易对
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        //交易对小的(贵的)在前面，大的在后面
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        //这首次创建交易对必然是0地址，如果不是0地址说明已经创建过了，不允许重复创建交易对
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        // type(UniswapV2Pair) Solidity 内置语法，作用是「获取 UniswapV2Pair 合约的「类型信息」」,类似其它语言的类反射
        //  type(UniswapV2Pair).creationCode获取UniswapV2Pair合约的字节码（就是部署时候的包含构造函数逻辑、初始化代码），
        //执行后会在链上创建合约账户，并返回合约地址
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        //计算部署的 salt值（盐值），这样确保同一代币对 永远部署到同一个地址
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        // 内联汇编，调用Create2部署合约
        assembly {
            //create:合约地址由(部署者地址+交易次数(nonce)决定，地址不可预测
            //create2：和合约地址由(部署者地址+salt+合约字节码的hash)决定，地址是可预测的
            // 0:部署合约时，向新合约中转入的ETH数量(wei为单位)
            // add(bytecode, 32):表示codeOffset， Solidity 中，bytes memory 类型的变量在内存中存储时，前 32 字节是「字节数组的长度」，
            // 从第 33 字节开始才是真正的字节码内容 add(bytecode, 32)：表示「跳过前 32 字节的长度信息，从字节码的真实内容开始读取」
            // mload(bytecode):表示codeLength（合约字节码的长度) mload(bytecode)：Solidity 内联汇编的内置函数，作用是「读取内存中 bytecode 变量起始位置的 32 字节数据」
            // —— 而这 32 字节正好是 bytecode 的长度
            // pair:接收 create2 返回的合约地址
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        //初始化交易对
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        //方便提升查询效率
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        //所有的交易对
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /**
     *feeToSetter 设置feeTo的合约地址
     * @param _feeTo
     */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    /**
     * Uniswap V2上线后，项目方通过这个方法将feeToSetter权限转移给了Uniswap DAO的治理合约
     * 此后，所有 feeTo 地址的修改（比如调整手续费接收方、关闭手续费等），都需要通过 DAO 提案投票通过后，由治理合约执行，实现了去中心化治理
     * @param _feeToSetter
     *
     */
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
