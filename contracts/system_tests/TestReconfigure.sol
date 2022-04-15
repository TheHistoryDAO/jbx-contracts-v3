// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import './helpers/TestBaseWorkflow.sol';

import '../JBReconfigurationBufferBallot.sol';

uint256 constant WEIGHT = 1000 * 10**18;

contract TestReconfigureProject is TestBaseWorkflow {
  JBController controller;
  JBProjectMetadata _projectMetadata;
  JBFundingCycleData _data;
  JBFundingCycleData _dataReconfiguration;
  JBFundingCycleData _dataWithoutBallot;
  JBFundingCycleMetadata _metadata;
  JBReconfigurationBufferBallot _ballot;
  JBGroupedSplits[] _groupedSplits; // Default empty
  JBFundAccessConstraints[] _fundAccessConstraints; // Default empty
  IJBPaymentTerminal[] _terminals; // Default empty

  function setUp() public override {
    super.setUp();

    controller = jbController();

    _projectMetadata = JBProjectMetadata({content: 'myIPFSHash', domain: 1});

    _ballot = new JBReconfigurationBufferBallot(3 days, jbFundingCycleStore());

    _data = JBFundingCycleData({
      duration: 6 days,
      weight: 1000 * 10**18,
      discountRate: 0,
      ballot: _ballot
    });

    _dataWithoutBallot = JBFundingCycleData({
      duration: 6 days,
      weight: 1000 * 10**18,
      discountRate: 0,
      ballot: JBReconfigurationBufferBallot(address(0))
    });

    _dataReconfiguration = JBFundingCycleData({
      duration: 6 days,
      weight: 69 * 10**18,
      discountRate: 0,
      ballot: JBReconfigurationBufferBallot(address(0))
    });

    _metadata = JBFundingCycleMetadata({
      reservedRate: 5000,
      redemptionRate: 5000,
      ballotRedemptionRate: 0,
      pausePay: false,
      pauseDistributions: false,
      pauseRedeem: false,
      pauseBurn: false,
      allowMinting: true,
      allowChangeToken: false,
      allowTerminalMigration: false,
      allowControllerMigration: false,
      allowSetTerminals: false,
      allowSetController: false,
      holdFees: false,
      useTotalOverflowForRedemptions: false,
      useDataSourceForPay: false,
      useDataSourceForRedeem: false,
      dataSource: IJBFundingCycleDataSource(address(0))
    });

    _terminals = [jbETHPaymentTerminal()];
  }

  function testReconfigureProject() public {

    uint256 projectId = controller.launchProjectFor(
      multisig(),
      _projectMetadata,
      _data,
      _metadata,
      0, // Start asap
      _groupedSplits,
      _fundAccessConstraints,
      _terminals,
      ''
    );

    JBFundingCycle memory fundingCycle = jbFundingCycleStore().currentOf(projectId); //, latestConfig);

    assertEq(fundingCycle.number, 1);
    assertEq(fundingCycle.weight, _data.weight);
  
    uint256 currentConfiguration = fundingCycle.configuration;

    evm.warp(block.timestamp + 10);

    evm.prank(multisig());
    controller.reconfigureFundingCyclesOf(
      projectId,
      _dataReconfiguration,
      _metadata,
      0, // Start asap
      _groupedSplits,
      _fundAccessConstraints,
      ''
    );

    uint256 newConfiguration = block.timestamp;

    // Shouldn't have changed
    fundingCycle = jbFundingCycleStore().currentOf(projectId);
    assertEq(fundingCycle.number, 1);
    assertEq(fundingCycle.configuration, currentConfiguration);
    assertEq(fundingCycle.weight, _data.weight);

    // should be new funding cycle
    evm.warp(fundingCycle.configuration + fundingCycle.duration);
    
    JBFundingCycle memory newFundingCycle = jbFundingCycleStore().currentOf(projectId);
    assertEq(newFundingCycle.number, 2);
    assertEq(newFundingCycle.weight, _dataReconfiguration.weight);
  }

  function testReconfigureProjectFuzzRates(
    uint96 RESERVED_RATE,
    uint96 REDEMPTION_RATE,
    uint96 BALANCE
  ) public {
    evm.assume(payable(msg.sender).balance / 2 >= BALANCE);
    evm.assume(100 < BALANCE);

    address _beneficiary = address(69420);
    uint256 projectId = controller.launchProjectFor(
      multisig(),
      _projectMetadata,
      _dataWithoutBallot,
      _metadata,
      0, // _mustStartAtOrAfter
      _groupedSplits,
      _fundAccessConstraints,
      _terminals,
      ''
    );

    JBFundingCycle memory fundingCycle = jbFundingCycleStore().currentOf(projectId);
    assertEq(fundingCycle.number, 1);

    evm.warp(block.timestamp + 1);

    jbETHPaymentTerminal().pay{value: BALANCE}(
      projectId,
      BALANCE,
      address(0),
      _beneficiary,
      0,
      false,
      'Forge test',
      new bytes(0)
    );

    uint256 _userTokenBalance = PRBMath.mulDiv(BALANCE, (WEIGHT / 10**18), 2); // initial FC rate is 50%
    if (BALANCE != 0)
      assertEq(jbTokenStore().balanceOf(_beneficiary, projectId), _userTokenBalance);

    evm.prank(multisig());
    if (RESERVED_RATE > 10000) evm.expectRevert(abi.encodeWithSignature('INVALID_RESERVED_RATE()'));
    else if (REDEMPTION_RATE > 10000)
      evm.expectRevert(abi.encodeWithSignature('INVALID_REDEMPTION_RATE()'));

    controller.reconfigureFundingCyclesOf(
      projectId,
      _dataWithoutBallot,
      JBFundingCycleMetadata({
        reservedRate: RESERVED_RATE,
        redemptionRate: REDEMPTION_RATE,
        ballotRedemptionRate: 0,
        pausePay: false,
        pauseDistributions: false,
        pauseRedeem: false,
        pauseBurn: false,
        allowMinting: true,
        allowChangeToken: false,
        allowTerminalMigration: false,
        allowControllerMigration: false,
        allowSetTerminals: false,
        allowSetController: false,
        holdFees: false,
        useTotalOverflowForRedemptions: false,
        useDataSourceForPay: false,
        useDataSourceForRedeem: false,
        dataSource: IJBFundingCycleDataSource(address(0))
      }),
      0,
      _groupedSplits,
      _fundAccessConstraints,
      ''
    );

    if (RESERVED_RATE > 10000 || REDEMPTION_RATE > 10000) {
      REDEMPTION_RATE = 5000; // If reconfigure has reverted, keep previous rates
      RESERVED_RATE = 5000;
    }

    evm.warp(block.timestamp + fundingCycle.duration);

    fundingCycle = jbFundingCycleStore().currentOf(projectId);
    assertEq(fundingCycle.number, 2);

    jbETHPaymentTerminal().pay{value: BALANCE}(
      projectId,
      BALANCE,
      address(0),
      _beneficiary,
      0,
      false,
      'Forge test',
      new bytes(0)
    );

    uint256 _newUserTokenBalance = RESERVED_RATE == 0 // New fc, rate is RESERVED_RATE
      ? PRBMath.mulDiv(BALANCE, WEIGHT, 10**18)
      : PRBMath.mulDiv(PRBMath.mulDiv(BALANCE, WEIGHT, 10**18), 10000 - RESERVED_RATE, 10000);

    if (BALANCE != 0)
      assertEq(
        jbTokenStore().balanceOf(_beneficiary, projectId),
        _userTokenBalance + _newUserTokenBalance
      );

    uint256 tokenBalance = jbTokenStore().balanceOf(_beneficiary, projectId);
    uint256 totalSupply = jbController().totalOutstandingTokensOf(projectId, RESERVED_RATE);
    uint256 overflow = jbETHPaymentTerminal().currentEthOverflowOf(projectId);

    evm.startPrank(_beneficiary);
    jbETHPaymentTerminal().redeemTokensOf(
      _beneficiary,
      projectId,
      tokenBalance,
      0,
      payable(_beneficiary),
      '',
      new bytes(0)
    );
    evm.stopPrank();

    if (BALANCE != 0 && REDEMPTION_RATE != 0)
      assertEq(
        _beneficiary.balance,
        PRBMath.mulDiv(
          PRBMath.mulDiv(overflow, tokenBalance, totalSupply),
          REDEMPTION_RATE + PRBMath.mulDiv(tokenBalance, 10000 - REDEMPTION_RATE, totalSupply),
          10000
        )
      );
  }
}