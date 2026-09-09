//+------------------------------------------------------------------+
//| RSI+StochRSI with Bollinger Band Sequence Filter - MT5 EA        |
//| Converted from TradingView Pine Script v6                         |
//| Risk Management: Equity percentage + Fixed SL/TP                 |
//+------------------------------------------------------------------+

#property copyright "Converted EA"
#property link      ""
#property version   "1.05"
#property strict
#property description "RSI+StochRSI EA with Bollinger Band sequence filter"

//--- Tell MT5 this is an Expert Advisor, not a script
#property service

#include <Trade\Trade.mqh>

CTrade trade;

//+------------------------------------------------------------------+
//| ENUMS                                                            |
//+------------------------------------------------------------------+

enum BBModeEnum { BB_OFF, BB_MEANREVERSION, BB_TRENDCONFIRM, BB_VOLATILITY };

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

// Symbol & Timeframe settings
input string CompareSymbol = "XAUUSD";           // Compare symbol
input ENUM_TIMEFRAMES CompareTF = PERIOD_M5;    // Compare timeframe

// RSI / RSI-MA / StochRSI
input int RSILen = 14;                          // RSI Length
input int RSIMaLen = 14;                        // RSI-based MA Length
input string RSIMaType = "SMA";                 // RSI-MA type: SMA, EMA, RMA
input int StochRSILen = 14;                     // Stochastic Length (RSI range)
input int StochKLen = 3;                        // K smoothing
input int StochDLen = 3;                        // D smoothing
input int StochBuyThresh = 20;                  // Stoch K BUY threshold (<)
input int StochSellThresh = 80;                 // Stoch K SELL threshold (>)

input bool RequireBarClose = true;              // Require bar close
input double MinStochDiff = 3.0;                // Min Stoch K-D diff to confirm crossover

// Clutter reduction
input int CollapseBars = 3;                     // Collapse signals within N bars
input bool CompactLabel = true;                 // Show small price label
input int CompactLabelOffsetPx = 6;             // Label vertical offset

// Quality filters (optional)
input bool UseADX = false;                      // Require ADX >= threshold
input int ADXLen = 14;                          // ADX length
input int ADXThresh = 20;                       // ADX threshold
input bool UseVol = false;                      // Require volume check
input int VolMaLen = 14;                        // Volume SMA length
input double VolMultiplier = 1.0;               // Volume multiplier

input string QualityLogic = "AND";              // Combine checks: AND or OR

// Bollinger Band Filter
input BBModeEnum BBMode = BB_OFF;               // BB mode: Off, MeanReversion, TrendConfirm, Volatility
input int BBLen = 20;                           // BB length
input double BBMult = 2.0;                      // BB multiplier
input double BBBandwidthPctThresh = 2.0;        // BB bandwidth threshold (%)
input bool BBRequireSeq = true;                 // Require prior outside->re-enter sequence
input int BBSeqLookback = 3;                    // Sequence lookback bars
input bool BBSeqAllowTouch = true;              // Count 'touch' as outside

//+------------------------------------------------------------------+
//| RISK MANAGEMENT INPUTS                                           |
//+------------------------------------------------------------------+

input double RiskPercent = 2.0;                 // Risk per trade (% of equity)
input double FixedStopLossPips = 50.0;          // Fixed Stop Loss in pips
input double FixedTakeProfitPips = 100.0;       // Fixed Take Profit in pips

input int MaxTrades = 1;                        // Max concurrent open positions
input bool CloseOppositeSide = true;            // Close opposite position on new signal

input bool PlotHistoricalSignals = true;        // Plot historical signals on chart load
input int HistoricalBarsToScan = 500;           // Number of bars to scan for historical signals

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+

int handleRSI_Remote, handleRSIMa_Remote, handleStochRSI_Remote;
int handleADX_Remote, handleBB_Remote, handleVol_Remote;

double buffer_rsi_remote[], buffer_rsi_ma_remote[], buffer_stoch_k[], buffer_stoch_d[];
double buffer_adx_remote[], buffer_bb_upper[], buffer_bb_lower[], buffer_bb_basis[];
double buffer_volume_remote[], buffer_volume_sma_remote[];
double buffer_close_remote[], buffer_high_remote[], buffer_low_remote[];

int lastBuyBar = -999;
int lastSellBar = -999;

bool historicalSignalsPlotted = false;
int signalCount = 0;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION FUNCTION                                   |
//+------------------------------------------------------------------+

int OnInit()
{
    trade.SetExpertMagicNumber(20240909);
    
    // Create indicator handles
    handleRSI_Remote = iRSI(CompareSymbol, CompareTF, RSILen, PRICE_CLOSE);
    if (handleRSI_Remote == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create RSI handle for ", CompareSymbol);
        return INIT_FAILED;
    }
    
    handleRSIMa_Remote = iMA(CompareSymbol, CompareTF, RSIMaLen, 0, StringToMAType(RSIMaType), PRICE_CLOSE);
    if (handleRSIMa_Remote == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create RSI MA handle for ", CompareSymbol);
        return INIT_FAILED;
    }
    
    handleStochRSI_Remote = iStochastic(CompareSymbol, CompareTF, StochRSILen, StochDLen, StochKLen, MODE_SMA, STO_CLOSECLOSE);
    if (handleStochRSI_Remote == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create Stochastic handle for ", CompareSymbol);
        return INIT_FAILED;
    }
    
    if (UseADX)
    {
        handleADX_Remote = iADX(CompareSymbol, CompareTF, ADXLen);
        if (handleADX_Remote == INVALID_HANDLE)
        {
            Print("ERROR: Failed to create ADX handle for ", CompareSymbol);
            return INIT_FAILED;
        }
    }
    
    handleBB_Remote = iBands(CompareSymbol, CompareTF, BBLen, 0, BBMult, PRICE_CLOSE);
    if (handleBB_Remote == INVALID_HANDLE)
    {
        Print("ERROR: Failed to create Bollinger Bands handle for ", CompareSymbol);
        return INIT_FAILED;
    }
    
    if (UseVol)
    {
        handleVol_Remote = iVolumes(CompareSymbol, CompareTF, VOLUME_REAL);
        if (handleVol_Remote == INVALID_HANDLE)
        {
            Print("ERROR: Failed to create Volume handle for ", CompareSymbol);
            return INIT_FAILED;
        }
    }
    
    Print("EA initialized on ", Symbol(), " monitoring ", CompareSymbol, " @ ", EnumToString(CompareTF));
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION FUNCTION                                 |
//+------------------------------------------------------------------+

void OnDeinit(const int reason)
{
    if (handleRSI_Remote != INVALID_HANDLE) IndicatorRelease(handleRSI_Remote);
    if (handleRSIMa_Remote != INVALID_HANDLE) IndicatorRelease(handleRSIMa_Remote);
    if (handleStochRSI_Remote != INVALID_HANDLE) IndicatorRelease(handleStochRSI_Remote);
    if (handleADX_Remote != INVALID_HANDLE) IndicatorRelease(handleADX_Remote);
    if (handleBB_Remote != INVALID_HANDLE) IndicatorRelease(handleBB_Remote);
    if (handleVol_Remote != INVALID_HANDLE) IndicatorRelease(handleVol_Remote);
}

//+------------------------------------------------------------------+
//| EXPERT TICK FUNCTION                                             |
//+------------------------------------------------------------------+

void OnTick()
{
    // Plot historical signals once on first tick
    if (PlotHistoricalSignals && !historicalSignalsPlotted)
    {
        ScanAndPlotHistoricalSignals();
        historicalSignalsPlotted = true;
    }
    
    // Validate bar counts
    if (Bars(CompareSymbol, CompareTF) < BBSeqLookback + 10)
        return;
    
    if (!UpdateIndicators())
        return;
    
    // Get current values from remote timeframe (index 1 = confirmed bar)
    double rsi_remote = buffer_rsi_remote[1];
    double rsi_remote_ma = buffer_rsi_ma_remote[1];
    double stoch_k = buffer_stoch_k[1];
    double stoch_d = buffer_stoch_d[1];
    double stoch_k_prev = buffer_stoch_k[2];
    double stoch_d_prev = buffer_stoch_d[2];
    double stoch_kd_diff = stoch_k - stoch_d;
    
    double remote_close = buffer_close_remote[1];
    double remote_high = buffer_high_remote[1];
    double remote_low = buffer_low_remote[1];
    
    // Detect crossovers
    bool rawCrossUp = (stoch_k > stoch_d) && (stoch_k_prev <= stoch_d_prev);
    bool rawCrossDown = (stoch_k < stoch_d) && (stoch_k_prev >= stoch_d_prev);
    
    // Apply min K-D diff filter
    bool remoteCrossUp = rawCrossUp && (stoch_kd_diff >= MinStochDiff);
    bool remoteCrossDown = rawCrossDown && ((-stoch_kd_diff) >= MinStochDiff);
    
    // Check RSI vs MA
    bool rsi_lt_ma = rsi_remote < rsi_remote_ma;
    bool rsi_gt_ma = rsi_remote > rsi_remote_ma;
    
    // Base signal conditions
    bool buyRaw = remoteCrossUp && rsi_lt_ma && (stoch_k < StochBuyThresh);
    bool sellRaw = remoteCrossDown && rsi_gt_ma && (stoch_k > StochSellThresh);
    
    // Quality filters
    bool qualityPass = CheckQualityFilters();
    
    // Bollinger Band filters
    bool bbPassBuy = true, bbPassSell = true;
    if (BBMode != BB_OFF)
    {
        CheckBollingerBandPass(remote_close, remote_high, remote_low, bbPassBuy, bbPassSell);
    }
    
    // Final signal with all filters
    bool buyFinal = buyRaw && qualityPass && bbPassBuy;
    bool sellFinal = sellRaw && qualityPass && bbPassSell;
    
    // Collapse/deduplicate signals
    int currentBar = Bars(CompareSymbol, CompareTF) - 1;
    
    bool buySignal = false, sellSignal = false;
    
    if (buyFinal && (currentBar - lastBuyBar) > CollapseBars)
    {
        buySignal = true;
        lastBuyBar = currentBar;
    }
    
    if (sellFinal && (currentBar - lastSellBar) > CollapseBars)
    {
        sellSignal = true;
        lastSellBar = currentBar;
    }
    
    // Execute trades
    if (buySignal)
    {
        PlotBuySignal(remote_close);
        ExecuteBuySignal(remote_close);
    }
    
    if (sellSignal)
    {
        PlotSellSignal(remote_close);
        ExecuteSellSignal(remote_close);
    }
}

//+------------------------------------------------------------------+
//| SCAN AND PLOT HISTORICAL SIGNALS                                 |
//+------------------------------------------------------------------+

void ScanAndPlotHistoricalSignals()
{
    int remoteBars = Bars(CompareSymbol, CompareTF);
    int scanBars = MathMin(HistoricalBarsToScan, remoteBars - 10);
    
    Print("Scanning last ", scanBars, " bars on ", CompareSymbol, " for signals...");
    
    int startIdx = scanBars;
    int buyCount = 0, sellCount = 0;
    
    for (int barIdx = startIdx; barIdx >= 2; barIdx--)
    {
        if (!UpdateIndicatorsForBar(barIdx))
            continue;
        
        // Get values
        double rsi_remote = buffer_rsi_remote[0];
        double rsi_remote_ma = buffer_rsi_ma_remote[0];
        double stoch_k = buffer_stoch_k[0];
        double stoch_d = buffer_stoch_d[0];
        double stoch_k_prev = buffer_stoch_k[1];
        double stoch_d_prev = buffer_stoch_d[1];
        double stoch_kd_diff = stoch_k - stoch_d;
        
        double remote_close = buffer_close_remote[0];
        double remote_high = buffer_high_remote[0];
        double remote_low = buffer_low_remote[0];
        
        // Detect crossovers
        bool rawCrossUp = (stoch_k > stoch_d) && (stoch_k_prev <= stoch_d_prev);
        bool rawCrossDown = (stoch_k < stoch_d) && (stoch_k_prev >= stoch_d_prev);
        
        // Apply min K-D diff filter
        bool remoteCrossUp = rawCrossUp && (stoch_kd_diff >= MinStochDiff);
        bool remoteCrossDown = rawCrossDown && ((-stoch_kd_diff) >= MinStochDiff);
        
        // Check RSI vs MA
        bool rsi_lt_ma = rsi_remote < rsi_remote_ma;
        bool rsi_gt_ma = rsi_remote > rsi_remote_ma;
        
        // Base signal conditions
        bool buyRaw = remoteCrossUp && rsi_lt_ma && (stoch_k < StochBuyThresh);
        bool sellRaw = remoteCrossDown && rsi_gt_ma && (stoch_k > StochSellThresh);
        
        // Quality filters
        bool qualityPass = CheckQualityFiltersForBar(barIdx);
        
        // Bollinger Band filters
        bool bbPassBuy = true, bbPassSell = true;
        if (BBMode != BB_OFF)
        {
            CheckBollingerBandPassForBar(barIdx, remote_close, remote_high, remote_low, bbPassBuy, bbPassSell);
        }
        
        // Final signal with all filters
        bool buyFinal = buyRaw && qualityPass && bbPassBuy;
        bool sellFinal = sellRaw && qualityPass && bbPassSell;
        
        // Plot signals - deduplicate by checking collapse window
        if (buyFinal)
        {
            if ((barIdx - lastBuyBar) > CollapseBars)
            {
                PlotHistoricalBuySignal(barIdx, remote_close);
                lastBuyBar = barIdx;
                buyCount++;
            }
        }
        
        if (sellFinal)
        {
            if ((barIdx - lastSellBar) > CollapseBars)
            {
                PlotHistoricalSellSignal(barIdx, remote_close);
                lastSellBar = barIdx;
                sellCount++;
            }
        }
    }
    
    Print("Historical scan complete: ", buyCount, " BUY signals, ", sellCount, " SELL signals found");
}

//+------------------------------------------------------------------+
//| UPDATE INDICATORS FOR SPECIFIC BAR INDEX                         |
//+------------------------------------------------------------------+

bool UpdateIndicatorsForBar(int barIndex)
{
    // RSI
    ArraySetAsSeries(buffer_rsi_remote, true);
    if (CopyBuffer(handleRSI_Remote, 0, barIndex - 1, 2, buffer_rsi_remote) < 2)
        return false;
    
    // RSI MA
    ArraySetAsSeries(buffer_rsi_ma_remote, true);
    if (CopyBuffer(handleRSIMa_Remote, 0, barIndex - 1, 2, buffer_rsi_ma_remote) < 2)
        return false;
    
    // Stochastic K and D
    ArraySetAsSeries(buffer_stoch_k, true);
    ArraySetAsSeries(buffer_stoch_d, true);
    if (CopyBuffer(handleStochRSI_Remote, 0, barIndex - 1, 2, buffer_stoch_k) < 2)
        return false;
    if (CopyBuffer(handleStochRSI_Remote, 1, barIndex - 1, 2, buffer_stoch_d) < 2)
        return false;
    
    // OHLC
    ArraySetAsSeries(buffer_close_remote, true);
    ArraySetAsSeries(buffer_high_remote, true);
    ArraySetAsSeries(buffer_low_remote, true);
    if (CopyClose(CompareSymbol, CompareTF, barIndex, 1, buffer_close_remote) < 1)
        return false;
    if (CopyHigh(CompareSymbol, CompareTF, barIndex, 1, buffer_high_remote) < 1)
        return false;
    if (CopyLow(CompareSymbol, CompareTF, barIndex, 1, buffer_low_remote) < 1)
        return false;
    
    // Bollinger Bands
    ArraySetAsSeries(buffer_bb_upper, true);
    ArraySetAsSeries(buffer_bb_basis, true);
    ArraySetAsSeries(buffer_bb_lower, true);
    if (CopyBuffer(handleBB_Remote, 1, barIndex - BBSeqLookback, BBSeqLookback + 2, buffer_bb_upper) < BBSeqLookback + 2)
        return false;
    if (CopyBuffer(handleBB_Remote, 0, barIndex - BBSeqLookback, BBSeqLookback + 2, buffer_bb_basis) < BBSeqLookback + 2)
        return false;
    if (CopyBuffer(handleBB_Remote, 2, barIndex - BBSeqLookback, BBSeqLookback + 2, buffer_bb_lower) < BBSeqLookback + 2)
        return false;
    
    // ADX
    if (UseADX)
    {
        ArraySetAsSeries(buffer_adx_remote, true);
        if (CopyBuffer(handleADX_Remote, 0, barIndex, 1, buffer_adx_remote) < 1)
            return false;
    }
    
    // Volume
    if (UseVol)
    {
        ArraySetAsSeries(buffer_volume_remote, true);
        if (CopyBuffer(handleVol_Remote, 0, barIndex - VolMaLen, VolMaLen + 1, buffer_volume_remote) < VolMaLen + 1)
            return false;
        CalculateVolumeSMA();
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| PLOT HISTORICAL BUY SIGNAL                                       |
//+------------------------------------------------------------------+

void PlotHistoricalBuySignal(int barIndex, double price)
{
    signalCount++;
    
    // Get bar time from remote chart
    datetime barTime = iTime(CompareSymbol, CompareTF, barIndex);
    if (barTime == 0)
        return;
    
    // Get local chart position for this time
    int localBar = iBarShift(Symbol(), Period(), barTime);
    if (localBar < 0)
        localBar = 0;
    
    double low = iLow(Symbol(), Period(), localBar);
    
    // Create arrow
    string arrowName = "BUY_HIST_" + IntegerToString(signalCount);
    if (ObjectCreate(0, arrowName, OBJ_ARROW, 0, barTime, low - 200 * Point()))
    {
        ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE, 233);
        ObjectSetInteger(0, arrowName, OBJPROP_COLOR, clrGreen);
        ObjectSetInteger(0, arrowName, OBJPROP_WIDTH, 2);
    }
    
    // Create price label
    if (CompactLabel)
    {
        string labelName = "BUY_LABEL_" + IntegerToString(signalCount);
        if (ObjectCreate(0, labelName, OBJ_TEXT, 0, barTime, low - 400 * Point()))
        {
            ObjectSetString(0, labelName, OBJPROP_TEXT, DoubleToString(price, Digits()));
            ObjectSetString(0, labelName, OBJPROP_FONT, "Arial");
            ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
            ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrGreen);
        }
    }
}

//+------------------------------------------------------------------+
//| PLOT HISTORICAL SELL SIGNAL                                      |
//+------------------------------------------------------------------+

void PlotHistoricalSellSignal(int barIndex, double price)
{
    signalCount++;
    
    // Get bar time from remote chart
    datetime barTime = iTime(CompareSymbol, CompareTF, barIndex);
    if (barTime == 0)
        return;
    
    // Get local chart position for this time
    int localBar = iBarShift(Symbol(), Period(), barTime);
    if (localBar < 0)
        localBar = 0;
    
    double high = iHigh(Symbol(), Period(), localBar);
    
    // Create arrow
    string arrowName = "SELL_HIST_" + IntegerToString(signalCount);
    if (ObjectCreate(0, arrowName, OBJ_ARROW, 0, barTime, high + 200 * Point()))
    {
        ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE, 234);
        ObjectSetInteger(0, arrowName, OBJPROP_COLOR, clrRed);
        ObjectSetInteger(0, arrowName, OBJPROP_WIDTH, 2);
    }
    
    // Create price label
    if (CompactLabel)
    {
        string labelName = "SELL_LABEL_" + IntegerToString(signalCount);
        if (ObjectCreate(0, labelName, OBJ_TEXT, 0, barTime, high + 400 * Point()))
        {
            ObjectSetString(0, labelName, OBJPROP_TEXT, DoubleToString(price, Digits()));
            ObjectSetString(0, labelName, OBJPROP_FONT, "Arial");
            ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
            ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrRed);
        }
    }
}

//+------------------------------------------------------------------+
//| PLOT BUY SIGNAL ON CHART                                         |
//+------------------------------------------------------------------+

void PlotBuySignal(double price)
{
    static int buyCount = 0;
    buyCount++;
    
    datetime time = TimeCurrent();
    double low = iLow(Symbol(), Period(), 0);
    
    // Create arrow
    string arrowName = "BUY_ARROW_" + IntegerToString(buyCount);
    ObjectCreate(0, arrowName, OBJ_ARROW, 0, time, low - 200 * Point());
    ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE, 233);
    ObjectSetInteger(0, arrowName, OBJPROP_COLOR, clrGreen);
    ObjectSetInteger(0, arrowName, OBJPROP_WIDTH, 2);
    
    // Create price label
    if (CompactLabel)
    {
        string labelName = "BUY_LABEL_" + IntegerToString(buyCount);
        ObjectCreate(0, labelName, OBJ_TEXT, 0, time, low - 400 * Point());
        ObjectSetString(0, labelName, OBJPROP_TEXT, DoubleToString(price, Digits()));
        ObjectSetString(0, labelName, OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 9);
        ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrGreen);
    }
    
    Print("BUY signal at ", price);
}

//+------------------------------------------------------------------+
//| PLOT SELL SIGNAL ON CHART                                        |
//+------------------------------------------------------------------+

void PlotSellSignal(double price)
{
    static int sellCount = 0;
    sellCount++;
    
    datetime time = TimeCurrent();
    double high = iHigh(Symbol(), Period(), 0);
    
    // Create arrow
    string arrowName = "SELL_ARROW_" + IntegerToString(sellCount);
    ObjectCreate(0, arrowName, OBJ_ARROW, 0, time, high + 200 * Point());
    ObjectSetInteger(0, arrowName, OBJPROP_ARROWCODE, 234);
    ObjectSetInteger(0, arrowName, OBJPROP_COLOR, clrRed);
    ObjectSetInteger(0, arrowName, OBJPROP_WIDTH, 2);
    
    // Create price label
    if (CompactLabel)
    {
        string labelName = "SELL_LABEL_" + IntegerToString(sellCount);
        ObjectCreate(0, labelName, OBJ_TEXT, 0, time, high + 400 * Point());
        ObjectSetString(0, labelName, OBJPROP_TEXT, DoubleToString(price, Digits()));
        ObjectSetString(0, labelName, OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 9);
        ObjectSetInteger(0, labelName, OBJPROP_COLOR, clrRed);
    }
    
    Print("SELL signal at ", price);
}

//+------------------------------------------------------------------+
//| UPDATE INDICATOR BUFFERS (FOR REAL-TIME)                         |
//+------------------------------------------------------------------+

bool UpdateIndicators()
{
    // RSI
    ArraySetAsSeries(buffer_rsi_remote, true);
    if (CopyBuffer(handleRSI_Remote, 0, 0, 10, buffer_rsi_remote) < 10)
        return false;
    
    // RSI MA
    ArraySetAsSeries(buffer_rsi_ma_remote, true);
    if (CopyBuffer(handleRSIMa_Remote, 0, 0, 10, buffer_rsi_ma_remote) < 10)
        return false;
    
    // Stochastic K and D
    ArraySetAsSeries(buffer_stoch_k, true);
    ArraySetAsSeries(buffer_stoch_d, true);
    if (CopyBuffer(handleStochRSI_Remote, 0, 0, 10, buffer_stoch_k) < 10)
        return false;
    if (CopyBuffer(handleStochRSI_Remote, 1, 0, 10, buffer_stoch_d) < 10)
        return false;
    
    // OHLC
    ArraySetAsSeries(buffer_close_remote, true);
    ArraySetAsSeries(buffer_high_remote, true);
    ArraySetAsSeries(buffer_low_remote, true);
    if (CopyClose(CompareSymbol, CompareTF, 0, 10, buffer_close_remote) < 10)
        return false;
    if (CopyHigh(CompareSymbol, CompareTF, 0, 10, buffer_high_remote) < 10)
        return false;
    if (CopyLow(CompareSymbol, CompareTF, 0, 10, buffer_low_remote) < 10)
        return false;
    
    // Bollinger Bands
    ArraySetAsSeries(buffer_bb_upper, true);
    ArraySetAsSeries(buffer_bb_basis, true);
    ArraySetAsSeries(buffer_bb_lower, true);
    if (CopyBuffer(handleBB_Remote, 1, 0, BBSeqLookback + 5, buffer_bb_upper) < BBSeqLookback + 5)
        return false;
    if (CopyBuffer(handleBB_Remote, 0, 0, BBSeqLookback + 5, buffer_bb_basis) < BBSeqLookback + 5)
        return false;
    if (CopyBuffer(handleBB_Remote, 2, 0, BBSeqLookback + 5, buffer_bb_lower) < BBSeqLookback + 5)
        return false;
    
    // ADX
    if (UseADX)
    {
        ArraySetAsSeries(buffer_adx_remote, true);
        if (CopyBuffer(handleADX_Remote, 0, 0, 10, buffer_adx_remote) < 10)
            return false;
    }
    
    // Volume
    if (UseVol)
    {
        ArraySetAsSeries(buffer_volume_remote, true);
        if (CopyBuffer(handleVol_Remote, 0, 0, 10, buffer_volume_remote) < 10)
            return false;
        CalculateVolumeSMA();
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| QUALITY FILTERS CHECK (REAL-TIME)                               |
//+------------------------------------------------------------------+

bool CheckQualityFilters()
{
    bool checkADX = true;
    bool checkVol = true;
    
    if (UseADX)
    {
        checkADX = buffer_adx_remote[1] >= ADXThresh;
    }
    
    if (UseVol)
    {
        checkVol = buffer_volume_remote[1] >= VolMultiplier * buffer_volume_sma_remote[1];
    }
    
    if (StringCompare(QualityLogic, "AND") == 0)
        return checkADX && checkVol;
    else
        return checkADX || checkVol;
}

//+------------------------------------------------------------------+
//| QUALITY FILTERS CHECK (HISTORICAL)                              |
//+------------------------------------------------------------------+

bool CheckQualityFiltersForBar(int barIdx)
{
    bool checkADX = true;
    bool checkVol = true;
    
    if (UseADX)
    {
        if (CopyBuffer(handleADX_Remote, 0, barIdx, 1, buffer_adx_remote) > 0)
            checkADX = buffer_adx_remote[0] >= ADXThresh;
    }
    
    if (UseVol)
    {
        if (CopyBuffer(handleVol_Remote, 0, barIdx, 1, buffer_volume_remote) > 0)
            checkVol = buffer_volume_remote[0] >= VolMultiplier * buffer_volume_sma_remote[0];
    }
    
    if (StringCompare(QualityLogic, "AND") == 0)
        return checkADX && checkVol;
    else
        return checkADX || checkVol;
}

//+------------------------------------------------------------------+
//| BOLLINGER BAND PASS CHECK (REAL-TIME)                            |
//+------------------------------------------------------------------+

void CheckBollingerBandPass(double remoteClose, double remoteHigh, double remoteLow, 
                            bool &bbPassBuy, bool &bbPassSell)
{
    bbPassBuy = true;
    bbPassSell = true;
    
    double bb_basis = buffer_bb_basis[1];
    double bb_upper = buffer_bb_upper[1];
    double bb_lower = buffer_bb_lower[1];
    
    if (BBMode == BB_MEANREVERSION)
    {
        bool priorOutsideBuy = false;
        bool priorOutsideSell = false;
        
        for (int i = 1; i <= BBSeqLookback && i < 10; i++)
        {
            double l_i = buffer_low_remote[i];
            double h_i = buffer_high_remote[i];
            double c_i = buffer_close_remote[i];
            double lower_i = buffer_bb_lower[i];
            double upper_i = buffer_bb_upper[i];
            
            if (BBSeqAllowTouch)
            {
                if (l_i <= lower_i) priorOutsideBuy = true;
                if (h_i >= upper_i) priorOutsideSell = true;
            }
            else
            {
                if (c_i < lower_i) priorOutsideBuy = true;
                if (c_i > upper_i) priorOutsideSell = true;
            }
        }
        
        if (BBRequireSeq)
        {
            bbPassBuy = priorOutsideBuy && (remoteClose > bb_lower);
            bbPassSell = priorOutsideSell && (remoteClose < bb_upper);
        }
        else
        {
            bbPassBuy = remoteClose <= bb_lower;
            bbPassSell = remoteClose >= bb_upper;
        }
    }
    else if (BBMode == BB_TRENDCONFIRM)
    {
        bbPassBuy = remoteClose > bb_basis;
        bbPassSell = remoteClose < bb_basis;
    }
    else if (BBMode == BB_VOLATILITY)
    {
        double bb_bandwidth_pct = bb_basis != 0 ? 100.0 * (bb_upper - bb_lower) / bb_basis : 0;
        bbPassBuy = bbPassSell = (bb_bandwidth_pct >= BBBandwidthPctThresh);
    }
}

//+------------------------------------------------------------------+
//| BOLLINGER BAND PASS CHECK (HISTORICAL)                           |
//+------------------------------------------------------------------+

void CheckBollingerBandPassForBar(int barIdx, double remoteClose, double remoteHigh, double remoteLow, 
                                   bool &bbPassBuy, bool &bbPassSell)
{
    bbPassBuy = true;
    bbPassSell = true;
    
    double bb_basis = buffer_bb_basis[0];
    double bb_upper = buffer_bb_upper[0];
    double bb_lower = buffer_bb_lower[0];
    
    if (BBMode == BB_MEANREVERSION)
    {
        bool priorOutsideBuy = false;
        bool priorOutsideSell = false;
        
        for (int i = 0; i <= BBSeqLookback && i < BBSeqLookback + 2; i++)
        {
            double l_i = buffer_low_remote[i];
            double h_i = buffer_high_remote[i];
            double c_i = buffer_close_remote[i];
            double lower_i = buffer_bb_lower[i];
            double upper_i = buffer_bb_upper[i];
            
            if (BBSeqAllowTouch)
            {
                if (l_i <= lower_i) priorOutsideBuy = true;
                if (h_i >= upper_i) priorOutsideSell = true;
            }
            else
            {
                if (c_i < lower_i) priorOutsideBuy = true;
                if (c_i > upper_i) priorOutsideSell = true;
            }
        }
        
        if (BBRequireSeq)
        {
            bbPassBuy = priorOutsideBuy && (remoteClose > bb_lower);
            bbPassSell = priorOutsideSell && (remoteClose < bb_upper);
        }
        else
        {
            bbPassBuy = remoteClose <= bb_lower;
            bbPassSell = remoteClose >= bb_upper;
        }
    }
    else if (BBMode == BB_TRENDCONFIRM)
    {
        bbPassBuy = remoteClose > bb_basis;
        bbPassSell = remoteClose < bb_basis;
    }
    else if (BBMode == BB_VOLATILITY)
    {
        double bb_bandwidth_pct = bb_basis != 0 ? 100.0 * (bb_upper - bb_lower) / bb_basis : 0;
        bbPassBuy = bbPassSell = (bb_bandwidth_pct >= BBBandwidthPctThresh);
    }
}

//+------------------------------------------------------------------+
//| VOLUME SMA CALCULATION                                           |
//+------------------------------------------------------------------+

void CalculateVolumeSMA()
{
    ArraySetAsSeries(buffer_volume_sma_remote, true);
    ArrayResize(buffer_volume_sma_remote, 10);
    
    for (int i = 0; i < 10; i++)
    {
        double sum = 0;
        int count = 0;
        for (int j = i; j < i + VolMaLen && j < 10; j++)
        {
            sum += buffer_volume_remote[j];
            count++;
        }
        buffer_volume_sma_remote[i] = count > 0 ? sum / count : buffer_volume_remote[i];
    }
}

//+------------------------------------------------------------------+
//| EXECUTE BUY SIGNAL                                               |
//+------------------------------------------------------------------+

void ExecuteBuySignal(double entryPrice)
{
    if (CloseOppositeSide)
        CloseSellPositions();
    
    if (CountOpenPositions(POSITION_TYPE_BUY) >= MaxTrades)
        return;
    
    double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    double equityRisk = accountEquity * RiskPercent / 100.0;
    double pipValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
    double pointValue = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    
    if (pipValue <= 0 || pointValue <= 0)
        return;
    
    double positionSize = equityRisk / (FixedStopLossPips * pipValue / pointValue);
    positionSize = NormalizeVolume(positionSize);
    
    if (positionSize <= 0)
        return;
    
    double sl = entryPrice - FixedStopLossPips * pointValue;
    double tp = entryPrice + FixedTakeProfitPips * pointValue;
    
    trade.Buy(positionSize, Symbol(), entryPrice, sl, tp, "RSI-Stoch BUY");
}

//+------------------------------------------------------------------+
//| EXECUTE SELL SIGNAL                                              |
//+------------------------------------------------------------------+

void ExecuteSellSignal(double entryPrice)
{
    if (CloseOppositeSide)
        CloseBuyPositions();
    
    if (CountOpenPositions(POSITION_TYPE_SELL) >= MaxTrades)
        return;
    
    double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    double equityRisk = accountEquity * RiskPercent / 100.0;
    double pipValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
    double pointValue = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    
    if (pipValue <= 0 || pointValue <= 0)
        return;
    
    double positionSize = equityRisk / (FixedStopLossPips * pipValue / pointValue);
    positionSize = NormalizeVolume(positionSize);
    
    if (positionSize <= 0)
        return;
    
    double sl = entryPrice + FixedStopLossPips * pointValue;
    double tp = entryPrice - FixedTakeProfitPips * pointValue;
    
    trade.Sell(positionSize, Symbol(), entryPrice, sl, tp, "RSI-Stoch SELL");
}

//+------------------------------------------------------------------+
//| CLOSE BUY POSITIONS                                              |
//+------------------------------------------------------------------+

void CloseBuyPositions()
{
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong posTicket = PositionGetTicket(i);
        if (posTicket == 0) continue;
        
        if (PositionGetString(POSITION_SYMBOL) == Symbol() && 
            PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
            trade.PositionClose(posTicket);
        }
    }
}

//+------------------------------------------------------------------+
//| CLOSE SELL POSITIONS                                             |
//+------------------------------------------------------------------+

void CloseSellPositions()
{
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong posTicket = PositionGetTicket(i);
        if (posTicket == 0) continue;
        
        if (PositionGetString(POSITION_SYMBOL) == Symbol() && 
            PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
        {
            trade.PositionClose(posTicket);
        }
    }
}

//+------------------------------------------------------------------+
//| COUNT OPEN POSITIONS                                             |
//+------------------------------------------------------------------+

int CountOpenPositions(ENUM_POSITION_TYPE posType)
{
    int count = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong posTicket = PositionGetTicket(i);
        if (posTicket == 0) continue;
        
        if (PositionGetString(POSITION_SYMBOL) == Symbol() && 
            PositionGetInteger(POSITION_TYPE) == posType)
        {
            count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| NORMALIZE VOLUME                                                 |
//+------------------------------------------------------------------+

double NormalizeVolume(double volume)
{
    double minVol = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
    double maxVol = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
    
    if (minVol <= 0 || maxVol <= 0 || step <= 0)
        return 0.1;
    
    volume = MathMax(volume, minVol);
    volume = MathMin(volume, maxVol);
    volume = MathRound(volume / step) * step;
    
    return volume;
}

//+------------------------------------------------------------------+
//| STRING TO MA TYPE CONVERTER                                      |
//+------------------------------------------------------------------+

ENUM_MA_METHOD StringToMAType(string maType)
{
    if (StringCompare(maType, "EMA") == 0)
        return MODE_EMA;
    else if (StringCompare(maType, "RMA") == 0)
        return MODE_SMMA;
    else
        return MODE_SMA;
}
