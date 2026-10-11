//+------------------------------------------------------------------+
//|    RUHAAN_FX_Sniper_Matrix_v6.5.9_FULL_SAFE_EDITION.mq5          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026 - RUHAAN FX"
#property version   "6.59"

#include <Trade\Trade.mqh>
CTrade trade;

// --- Magic Number & Identification ---
input ulong    MagicNumber          = 51399;  // Unique Magic Number for this Chart

// --- EMA & Strategy Inputs ---
input int      FastEMAPeriod        = 8;      // Fast EMA Period
input int      SlowEMAPeriod        = 13;     // Slow EMA Period
input int      SRLookbackBars       = 20;     // Support & Resistance Lookback Bars
input double   PullbackBufferPts    = 150;    // Pullback Max Distance from EMA (Points)
input double   TakeProfitTarget     = 0.50;   // Target Profit ($0.50)
input double   MaxAllowedLoss       = 0.60;   // Max Loss per Trade ($0.60)

// --- Candlestick Pattern Filters ---
input bool     UseCandlePatterns    = true;   // Enable Candlestick Pattern Confirmation
input bool     RequireBullishEngulf = true;   // Enable Bullish Engulfing / Hammer Detection
input bool     RequireBearishEngulf = true;   // Enable Bearish Engulfing / Shooting Star Detection

// --- RSI Momentum Filter Inputs (CORRECTED) ---
input bool     UseRSIFilter         = true;   // Enable RSI Momentum Filter
input int      RSIPeriod            = 14;     // RSI Period
input double   RSI_Buy_Threshold    = 52.0;   // Buy Threshold (Momentum ABOVE 52)
input double   RSI_Sell_Threshold   = 48.0;   // Sell Threshold (Momentum BELOW 48)

// --- Multi-Timeframe (MTF) Trend Filter Inputs (ACTIVATED) ---
input bool     UseMTFFilter         = true;   // MTF M15 Trend Filter Toggle (ENABLED FOR $20 ACC)
input ENUM_TIMEFRAMES HTFTimeframe  = PERIOD_M15; // Higher Timeframe

// --- Dynamic Lot Sizing & Risk Management ---
input bool     UseAutoLot           = false;  // Enable Auto Lot Size based on Risk %
input double   RiskPercent          = 0.5;    // Risk % of Equity per trade
input double   FixedLotSize         = 0.01;   // Base Fixed Lot Size

// --- Dynamic Profit Lock & Trailing SL ($20 Account Settings) ---
input bool     UseTrailingStop      = true;   // Enable Dynamic Profit Trailing Stop
input double   ProfitTriggerUSD     = 0.30;   // Profit Trigger ($0.30) to Lock SL
input double   LockProfitUSD        = 0.15;   // Locked Profit Amount ($0.15)
input double   TrailingStepPts      = 20;     // Trailing Step Distance (Points)

// --- Trading Session Time Filter (UK / London Session: 06:00 - 18:00) ---
input bool     UseSessionFilter     = true;   // Enable Time Session Filter
input int      UK_StartHour         = 6;      // UK Start Hour (06:00 London Time)
input int      UK_EndHour           = 19;     // Set to 19 to trade UNTIL 18:59
input int      ServerToUKOffsetHrs  = 2;      // Broker Time Offset vs UK

// --- ADX Trend Filter Inputs ---
input bool     UseADXFilter         = true;   // Enable ADX Trend Filter
input int      ADXPeriod            = 14;     // ADX Period
input double   MinADXThreshold      = 18.0;   // Min ADX Threshold

// --- Dynamic Grid Step & Dynamic TP Inputs ---
input bool     UseSmartGrid         = true;   // Enable Smart Safety Grid
input bool     UseDynamicGridTP     = true;   // Enable Dynamic Target Profit
input double   DynamicMultiplier    = 1.0;    // TP Scaling Factor Per Grid Level
input bool     UseDynamicATRStep    = true;   // Enable Dynamic ATR Grid Step
input double   ATRStepMultiplier    = 1.5;    // ATR Step Multiplier
input int      GridStepPoints       = 300;    // Minimum Grid Distance (30 pips)
input int      MaxGridOrders        = 1;      // Max Grid Trades (Safety Limit)

// --- Spike Filter Input ---
input bool     UseSpikeBlock        = true;   // Block Trades on Giant Candle Spikes
input double   MaxCandleSpikePts    = 350;    // Max Allowed Candle Size (Points)

// --- External Forex Factory News API Filter ---
input bool     UseExternalNewsAPI   = true;   // Enable Real-Time Forex Factory News Scraper
input int      NewsPauseBefore      = 15;     // Stop Trading (Minutes BEFORE News)
input int      NewsPauseAfter       = 15;     // Pause Trading (Minutes AFTER News)
input string   NewsAPIUrl           = "https://nfs.fxeveryday.com/ff_calendar_thisweek.json";

// --- Fast Execution & Broker Sync Inputs ---
input ulong    MaxSlippagePoints    = 35;     // Max Allowed Slippage/Deviation
input int      MaxSpreadPoints      = 35;     // Maximum Allowed Spread

// --- Daily Loss Percentage & Dynamic Cap (CORRECTED) ---
input double   MaxDailyLossUSD      = 3.00;   // Daily Hard Loss Limit ($3.00)
input double   MaxDailyProfit       = 3.00;   // Daily Target Profit Cap ($3.00)

input bool     UseATRFilter         = true;   // Enable ATR Volatility Filter
input int      ATRPeriod            = 14;     // ATR Period
input double   MinATRValue          = 0.00008;// Min Volatility Threshold
input bool     SendPhoneAlerts      = true;   // Send Push Notifications To Mobile

// --- Dashboard Customization Inputs ---
input color    BgColor              = C'25,28,36';   // Dark Grey Background Color
input color    BorderColor          = C'60,68,85';   // Panel Border Color
input color    TitleColor           = C'255,215,0';  // Gold Title Color
input color    TextColor            = C'220,225,230';// Main Text Color
input color    StatusColor          = C'50,205,50';  // Status Accent Color

// --- News Event Data Structure ---
struct NewsEvent
{
   string   currency;
   datetime time;
   string   impact;
};

// --- Global Handles & Variables ---
int      fastEMA_handle, slowEMA_handle, atr_handle, adx_handle, rsi_handle;
int      htfFastEMA_handle, htfSlowEMA_handle;
string   currentStatus        = "STUDYING MARKET... 👀";
datetime lastTradeBarTime;
double   dailyLossTotal       = 0.0;
double   dailyProfitTotal     = 0.0;
datetime lastDailyReset;
bool     partialClosed        = false;

NewsEvent g_newsEvents[];
datetime  lastNewsFetchTime   = 0;

// --- Network Protection Variables ---
datetime lastExecutionTime    = 0;
int      consecutiveErrors    = 0;
datetime cooldownExpiry       = 0;

// --- CANDLESTICK PATTERN RECOGNITION FUNCTIONS ---
bool IsBullishCandlePattern()
{
   if(!UseCandlePatterns) return true;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 3, rates) < 3) return false;

   double open1  = rates[0].open;
   double close1 = rates[0].close;
   double high1  = rates[0].high;
   double low1   = rates[0].low;

   double open2  = rates[1].open;
   double close2 = rates[1].close;

   double body1 = MathAbs(close1 - open1);

   bool isBullishEngulfing = (close2 < open2) && (close1 > open1) && (close1 > open2) && (open1 < close2);
   double lowerWick = (close1 > open1) ? (open1 - low1) : (close1 - low1);
   double upperWick = (close1 > open1) ? (high1 - close1) : (high1 - open1);
   bool isHammer = (lowerWick >= body1 * 2.0) && (upperWick <= body1 * 0.5) && (body1 > 0);

   if(!RequireBullishEngulf) return true;
   return (isBullishEngulfing || isHammer);
}

bool IsBearishCandlePattern()
{
   if(!UseCandlePatterns) return true;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 3, rates) < 3) return false;

   double open1  = rates[0].open;
   double close1 = rates[0].close;
   double high1  = rates[0].high;
   double low1   = rates[0].low;

   double open2  = rates[1].open;
   double close2 = rates[1].close;

   double body1 = MathAbs(close1 - open1);

   bool isBearishEngulfing = (close2 > open2) && (close1 < open1) && (close1 < open2) && (open1 > close2);
   double lowerWick = (close1 < open1) ? (close1 - low1) : (open1 - low1);
   double upperWick = (close1 < open1) ? (high1 - open1) : (high1 - close1);
   bool isShootingStar = (upperWick >= body1 * 2.0) && (lowerWick <= body1 * 0.5) && (body1 > 0);

   if(!RequireBearishEngulf) return true;
   return (isBearishEngulfing || isShootingStar);
}

double GetCalculatedLotSize()
{
   if(!UseAutoLot) return FixedLotSize;

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickVal <= 0) return FixedLotSize;

   double riskAmount = equity * (RiskPercent / 100.0);
   double calculated = (riskAmount / (MaxAllowedLoss * 100));

   double stepLot = MathFloor(calculated / lotStep) * lotStep;
   if(stepLot < minLot) stepLot = minLot;
   if(stepLot > maxLot) stepLot = maxLot;

   return stepLot;
}

int GetHTFTrend()
{
   if(!UseMTFFilter) return 0;

   double htfFast[], htfSlow[];
   ArraySetAsSeries(htfFast, true);
   ArraySetAsSeries(htfSlow, true);

   if(CopyBuffer(htfFastEMA_handle, 0, 1, 1, htfFast) < 1) return 0;
   if(CopyBuffer(htfSlowEMA_handle, 0, 1, 1, htfSlow) < 1) return 0;

   if(htfFast[0] > htfSlow[0]) return 1;   // Bullish
   if(htfFast[0] < htfSlow[0]) return -1;  // Bearish

   return 0;
}

bool IsInUKTradingSession()
{
   if(!UseSessionFilter) return true;

   MqlDateTime serverDt;
   TimeToStruct(TimeCurrent(), serverDt);

   int ukHour = serverDt.hour - ServerToUKOffsetHrs;
   if(ukHour < 0) ukHour += 24;

   if(UK_StartHour <= UK_EndHour)
      return (ukHour >= UK_StartHour && ukHour < UK_EndHour);
   else
      return (ukHour >= UK_StartHour || ukHour < UK_EndHour);
}

void FetchForexFactoryNews()
{
   if(!UseExternalNewsAPI) return;
   if(TimeCurrent() - lastNewsFetchTime < 14400 && ArraySize(g_newsEvents) > 0) return;

   string cookie = NULL, headers;
   char post[], result[];
   int res;
   int timeout = 5000;

   ResetLastError();
   res = WebRequest("GET", NewsAPIUrl, cookie, NULL, timeout, post, 0, result, headers);

   if(res == 200)
   {
      string jsonResponse = CharArrayToString(result);
      ParseNewsJson(jsonResponse);
      lastNewsFetchTime = TimeCurrent();
      Print("RUHAAN FX: Real-Time Forex Factory News Calendar Successfully Updated.");
   }
}

void ParseNewsJson(string json)
{
   string baseCurr   = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string profitCurr = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   ArrayResize(g_newsEvents, 0);
   int pos = 0;

   while((pos = StringFind(json, "\"impact\":\"High\"", pos)) != -1)
   {
      int startObj = StringFind(json, "{", pos - 150);
      int endObj   = StringFind(json, "}", pos);

      if(startObj != -1 && endObj != -1)
      {
         string block = StringSubstr(json, startObj, endObj - startObj + 1);
         if(StringFind(block, baseCurr) != -1 || StringFind(block, profitCurr) != -1)
         {
            int size = ArraySize(g_newsEvents);
            ArrayResize(g_newsEvents, size + 1);
            g_newsEvents[size].impact = "High";
            g_newsEvents[size].currency = (StringFind(block, baseCurr) != -1) ? baseCurr : profitCurr;
         }
      }
      pos += 15;
   }
}

bool IsExternalNewsPauseActive()
{
   if(!UseExternalNewsAPI) return false;

   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(g_newsEvents); i++)
   {
      long diffMinutes = (long)(g_newsEvents[i].time - now) / 60;
      if(diffMinutes >= -NewsPauseAfter && diffMinutes <= NewsPauseBefore)
      {
         return true; 
      }
   }
   return false;
}

void GetSupportResistance(double &support, double &resistance)
{
   int highestBar = iHighest(_Symbol, _Period, MODE_HIGH, SRLookbackBars, 1);
   int lowestBar  = iLowest(_Symbol, _Period, MODE_LOW, SRLookbackBars, 1);

   resistance = iHigh(_Symbol, _Period, highestBar);
   support    = iLow(_Symbol, _Period, lowestBar);
}

double CalculateDynamicTargetProfit(int openCount)
{
   if(openCount <= 0) return TakeProfitTarget;
   if(!UseDynamicGridTP) return TakeProfitTarget;

   double calculatedTP = TakeProfitTarget * (1.0 + ((openCount - 1) * DynamicMultiplier));
   if(calculatedTP <= 0.0) return TakeProfitTarget;
   
   return NormalizeDouble(calculatedTP, 2);
}

double GetCurrentGridStepDistance()
{
   double basePointsDistance = GridStepPoints * _Point;

   if(!UseDynamicATRStep) return basePointsDistance;

   double atr[];
   ArraySetAsSeries(atr, true);
   
   if(CopyBuffer(atr_handle, 0, 1, 1, atr) > 0 && atr[0] > 0)
   {
      double calculatedStep = atr[0] * ATRStepMultiplier;
      if(calculatedStep < basePointsDistance) return basePointsDistance;
      return calculatedStep;
   }

   return basePointsDistance;
}

void SetBrokerExecutionSettings()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);
   trade.SetAsyncMode(false);
   
   uint fillType = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillType & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((fillType & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

int OnInit()
{
   SetBrokerExecutionSettings();

   fastEMA_handle = iMA(_Symbol, _Period, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowEMA_handle = iMA(_Symbol, _Period, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   atr_handle     = iATR(_Symbol, _Period, ATRPeriod);
   adx_handle     = iADX(_Symbol, _Period, ADXPeriod);
   rsi_handle     = iRSI(_Symbol, _Period, RSIPeriod, PRICE_CLOSE);

   htfFastEMA_handle = iMA(_Symbol, HTFTimeframe, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   htfSlowEMA_handle = iMA(_Symbol, HTFTimeframe, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   
   if(fastEMA_handle == INVALID_HANDLE || slowEMA_handle == INVALID_HANDLE || 
      atr_handle == INVALID_HANDLE || adx_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE ||
      htfFastEMA_handle == INVALID_HANDLE || htfSlowEMA_handle == INVALID_HANDLE)
   {
      Print("Error: Failed to initialize indicator handles.");
      return(INIT_FAILED);
   }
   
   lastDailyReset    = TimeCurrent();
   currentStatus     = "STUDYING MARKET... 👀";
   consecutiveErrors = 0;
   partialClosed     = false;

   if(UseExternalNewsAPI) FetchForexFactoryNews();

   EventSetTimer(1);
   DrawGraphicalDashboard(); 

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteDashboardObjects();
   IndicatorRelease(fastEMA_handle);
   IndicatorRelease(slowEMA_handle);
   IndicatorRelease(atr_handle);
   IndicatorRelease(adx_handle);
   IndicatorRelease(rsi_handle);
   IndicatorRelease(htfFastEMA_handle);
   IndicatorRelease(htfSlowEMA_handle);
}

void OnTimer()
{
   if(UseExternalNewsAPI) FetchForexFactoryNews();
   DrawGraphicalDashboard();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   DrawGraphicalDashboard();
}

bool SafeExecuteTrade(ENUM_ORDER_TYPE orderType, double requestedLots, string comment)
{
   if(TimeCurrent() < cooldownExpiry)
   {
      currentStatus = "COOLDOWN ACTIVE ⏳ (" + IntegerToString((int)(cooldownExpiry - TimeCurrent())) + "s)";
      return false;
   }

   if(TimeCurrent() - lastExecutionTime < 3) return false;

   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      currentStatus = "PAUSED: No Terminal Connection ⚠️";
      return false;
   }

   if(consecutiveErrors >= 5)
   {
      currentStatus = "COOLDOWN INITIATED (30s Pause) ⏳";
      cooldownExpiry = TimeCurrent() + 30;
      consecutiveErrors = 0;
      return false;
   }

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   double safeVolume = MathFloor(requestedLots / lotStep) * lotStep;
   if(safeVolume < minLot) safeVolume = minLot;
   if(safeVolume > maxLot) safeVolume = maxLot;

   bool success = false;

   for(int attempt = 1; attempt <= 3; attempt++)
   {
      if(orderType == ORDER_TYPE_BUY)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         ask = NormalizeDouble(ask, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         success = trade.Buy(safeVolume, _Symbol, ask, 0, 0, comment);
      }
      else if(orderType == ORDER_TYPE_SELL)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         bid = NormalizeDouble(bid, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         success = trade.Sell(safeVolume, _Symbol, bid, 0, 0, comment);
      }

      if(success) break;
      Sleep(200);
   }

   lastExecutionTime = TimeCurrent();

   if(!success)
   {
      consecutiveErrors++;
      Print("Broker rejected order! Code: ", trade.ResultRetcode(), " Desc: ", trade.ResultRetcodeDescription());
      return false;
   }

   consecutiveErrors = 0;
   return true;
}

// --- DYNAMIC PROFIT LOCKING SYSTEM (FOR $20 ACCOUNT) ---
void ProcessTrailingStop()
{
   if(!UseTrailingStop) return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue <= 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         double posProfit  = PositionGetDouble(POSITION_PROFIT);
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL   = PositionGetDouble(POSITION_SL);
         double volume     = PositionGetDouble(POSITION_VOLUME);

         // Kana Profit Yasvika/Kudarika $0.30
         if(posProfit >= ProfitTriggerUSD)
         {
            double lockPts = (LockProfitUSD / (volume * tickValue)) * _Point;

            if(posType == POSITION_TYPE_BUY)
            {
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double targetSL = NormalizeDouble(openPrice + lockPts, digits);

               if(currentSL < targetSL)
               {
                  trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
                  currentStatus = "LOCKED $" + DoubleToString(LockProfitUSD, 2) + " PROFIT 🛡️ (BUY)";
               }
               else
               {
                  double stepSL = NormalizeDouble(ask - (TrailingStepPts * _Point), digits);
                  if(stepSL > currentSL)
                  {
                     trade.PositionModify(ticket, stepSL, PositionGetDouble(POSITION_TP));
                     currentStatus = "TRAILING PROFIT UP 📈";
                  }
               }
            }
            else if(posType == POSITION_TYPE_SELL)
            {
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               double targetSL = NormalizeDouble(openPrice - lockPts, digits);

               if(currentSL == 0 || currentSL > targetSL)
               {
                  trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
                  currentStatus = "LOCKED $" + DoubleToString(LockProfitUSD, 2) + " PROFIT 🛡️ (SELL)";
               }
               else
               {
                  double stepSL = NormalizeDouble(bid + (TrailingStepPts * _Point), digits);
                  if(stepSL < currentSL)
                  {
                     trade.PositionModify(ticket, stepSL, PositionGetDouble(POSITION_TP));
                     currentStatus = "TRAILING PROFIT DOWN 📉";
                  }
               }
            }
         }
      }
   }
}

void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      currentStatus = "PAUSED: No Terminal Connection ⚠️";
      return;
   }

   ResetDailyLimitsIfNeeded();
   ManagePositionsAndBasket();
   ProcessTrailingStop();

   if(dailyLossTotal >= MaxDailyLossUSD)
   {
      currentStatus = "STOPPED: Daily Loss Hit 😡 (-$" + DoubleToString(dailyLossTotal, 2) + " / Max $" + DoubleToString(MaxDailyLossUSD, 2) + ")";
      return;
   }

   if(dailyProfitTotal >= MaxDailyProfit)
   {
      currentStatus = "TARGET REACHED 🎯: Daily Target Hit 😊 (+$" + DoubleToString(dailyProfitTotal, 2) + ")";
      return;
   }

   if(!IsInUKTradingSession())
   {
      currentStatus = "PAUSED 😴: Outside UK Session (" + IntegerToString(UK_StartHour) + ":00-18:00 UK)";
      return;
   }

   if(IsExternalNewsPauseActive())
   {
      currentStatus = "PAUSED 📰: High Impact Forex News Event (API Protected)";
      return;
   }

   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > MaxSpreadPoints)
   {
      currentStatus = "PAUSED ⚠️: High Spread (" + IntegerToString(currentSpread) + " pts)";
      return;
   }

   if(UseSpikeBlock)
   {
      double high1 = iHigh(_Symbol, _Period, 1);
      double low1  = iLow(_Symbol, _Period, 1);
      double candleSizePts = (high1 - low1) / _Point;

      if(candleSizePts > MaxCandleSpikePts)
      {
         currentStatus = "PAUSED ⚡: Big Spike Block (" + DoubleToString(candleSizePts, 0) + " pts)";
         return;
      }
   }

   if(UseATRFilter)
   {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(atr_handle, 0, 1, 1, atr) > 0)
      {
         if(atr[0] < MinATRValue)
         {
            currentStatus = "IDLE 😴: Low Volatility (ATR)";
            return;
         }
      }
   }

   double adxVal = 0.0;
   if(UseADXFilter)
   {
      double adxValues[];
      ArraySetAsSeries(adxValues, true);
      if(CopyBuffer(adx_handle, 0, 1, 1, adxValues) > 0)
      {
         adxVal = adxValues[0];
         if(adxVal < MinADXThreshold)
         {
            currentStatus = "PAUSED 😴: ADX Low (" + DoubleToString(adxVal, 1) + " < " + DoubleToString(MinADXThreshold, 1) + ")";
            return;
         }
      }
   }
   bool isMarketStrong = (!UseADXFilter || adxVal >= MinADXThreshold);

   bool isRsiBuyValid = true;
   bool isRsiSellValid = true;
   if(UseRSIFilter)
   {
      double rsiVals[];
      ArraySetAsSeries(rsiVals, true);
      if(CopyBuffer(rsi_handle, 0, 1, 1, rsiVals) > 0)
      {
         isRsiBuyValid  = (rsiVals[0] >= RSI_Buy_Threshold);
         isRsiSellValid = (rsiVals[0] <= RSI_Sell_Threshold);
      }
   }

   double fastEMA[], slowEMA[];
   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   
   if(CopyBuffer(fastEMA_handle, 0, 1, 2, fastEMA) < 2) return;
   if(CopyBuffer(slowEMA_handle, 0, 1, 2, slowEMA) < 2) return;

   double closePrice[], openPrice[];
   ArraySetAsSeries(closePrice, true);
   ArraySetAsSeries(openPrice, true);
   if(CopyClose(_Symbol, _Period, 1, 2, closePrice) < 2) return;
   if(CopyOpen(_Symbol, _Period, 1, 2, openPrice) < 2) return;

   bool isBullish = (closePrice[0] > openPrice[0]);
   bool isBearish = (closePrice[0] < openPrice[0]);

   double currentFast = fastEMA[0]; 
   double currentSlow = slowEMA[0];
   double prevFast    = fastEMA[1]; 
   double prevSlow    = slowEMA[1];

   double supportLevel = 0.0, resistanceLevel = 0.0;
   GetSupportResistance(supportLevel, resistanceLevel);

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double bufferDistance = PullbackBufferPts * _Point;

   bool emaBuyCross  = (prevFast <= prevSlow && currentFast > currentSlow) && isBullish;
   bool emaSellCross = (prevFast >= prevSlow && currentFast < currentSlow) && isBearish;

   bool strongBuyTrend  = (currentFast > currentSlow) && isBullish;
   bool strongSellTrend = (currentFast < currentSlow) && isBearish;

   bool buyPullback  = (currentFast > currentSlow) && (currentAsk > supportLevel) && (MathAbs(currentAsk - currentFast) <= bufferDistance) && isBullish;
   bool sellPullback = (currentFast < currentSlow) && (currentBid < resistanceLevel) && (MathAbs(currentBid - currentFast) <= bufferDistance) && isBearish;

   bool bullishPatternConfirmed = IsBullishCandlePattern();
   bool bearishPatternConfirmed = IsBearishCandlePattern();

   int htfTrend = GetHTFTrend();
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   double tradeLot = GetCalculatedLotSize();

   // --- BUY SIGNAL EXECUTION ---
   if((emaBuyCross || (strongBuyTrend && isMarketStrong) || buyPullback) && isRsiBuyValid && bullishPatternConfirmed)
   {
      if(UseMTFFilter && htfTrend != 1)
      {
         currentStatus = "PAUSED: Buy Signal Blocked by M15 Bearish Trend";
         return;
      }

      if(GetCurrentSymbolPositions() == 0 && currentBarTime != lastTradeBarTime)
      {
         if(SafeExecuteTrade(ORDER_TYPE_BUY, tradeLot, "Sniper Matrix Buy v6.5.9"))
         {
            lastTradeBarTime = currentBarTime;
            partialClosed    = false;
            SendAlert("STRONG BUY ENTRY Open on " + _Symbol);
         }
      }
   }
   // --- SELL SIGNAL EXECUTION ---
   else if((emaSellCross || (strongSellTrend && isMarketStrong) || sellPullback) && isRsiSellValid && bearishPatternConfirmed)
   {
      if(UseMTFFilter && htfTrend != -1)
      {
         currentStatus = "PAUSED: Sell Signal Blocked by M15 Bullish Trend";
         return;
      }

      if(GetCurrentSymbolPositions() == 0 && currentBarTime != lastTradeBarTime)
      {
         if(SafeExecuteTrade(ORDER_TYPE_SELL, tradeLot, "Sniper Matrix Sell v6.5.9"))
         {
            lastTradeBarTime = currentBarTime;
            partialClosed    = false;
            SendAlert("STRONG SELL ENTRY Open on " + _Symbol);
         }
      }
   }
   else if(UseSmartGrid && GetCurrentSymbolPositions() > 0 && GetCurrentSymbolPositions() < MaxGridOrders)
   {
      currentStatus = "GRID ACTIVE ⚡ (" + IntegerToString(GetCurrentSymbolPositions()) + "/" + IntegerToString(MaxGridOrders) + ")";
      CheckAndExecuteGrid();
   }
   else if(GetCurrentSymbolPositions() == 0)
   {
      currentStatus = "STUDYING MARKET... 👀 (Waiting for Signals)";
   }
}

double GetBasketProfit()
{
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         profit += PositionGetDouble(POSITION_PROFIT);
      }
   }
   return profit;
}

void ManagePositionsAndBasket()
{
   int openCount = GetCurrentSymbolPositions();
   double basketProfit = GetBasketProfit();

   if(openCount > 0)
   {
      double dynamicTP = CalculateDynamicTargetProfit(openCount);

      if(basketProfit >= dynamicTP)
      {
         CloseAllSymbolPositions();
         currentStatus = "CLOSED 🎯: Target Hit 😊 (+$" + DoubleToString(basketProfit, 2) + ")";
         SendAlert("Profit Target Secured: $" + DoubleToString(basketProfit, 2));
      }
      else if(basketProfit <= -MaxAllowedLoss)
      {
         CloseAllSymbolPositions();
         currentStatus = "CLOSED 🔴: Hard Loss Hit 😡 (-$" + DoubleToString(MathAbs(basketProfit), 2) + ")";
         SendAlert("Closed with Loss: -$" + DoubleToString(MathAbs(basketProfit), 2));
      }
   }
}

void CheckAndExecuteGrid()
{
   ulong lastTicket = 0;
   datetime lastTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         datetime pTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(pTime > lastTime)
         {
            lastTime = pTime;
            lastTicket = ticket;
         }
      }
   }

   if(lastTicket > 0 && PositionSelectByTicket(lastTicket))
   {
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

      double requiredStepDistance = GetCurrentGridStepDistance();
      double tradeLot = GetCalculatedLotSize();

      if(posType == POSITION_TYPE_BUY)
      {
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(openPrice - currentAsk >= requiredStepDistance) 
            SafeExecuteTrade(ORDER_TYPE_BUY, tradeLot, "Grid Buy (ATR Step)");
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(currentBid - openPrice >= requiredStepDistance) 
            SafeExecuteTrade(ORDER_TYPE_SELL, tradeLot, "Grid Sell (ATR Step)");
      }
   }
}

void CloseAllSymbolPositions()
{
   double closingProfit = GetBasketProfit();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         trade.PositionClose(ticket);
         Sleep(100);
      }
   }

   if(closingProfit < 0)
      dailyLossTotal += MathAbs(closingProfit);
   else
      dailyProfitTotal += closingProfit;

   partialClosed = false;
}

int GetCurrentSymbolPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) count++;
   }
   return count;
}

string GetCandleTimeRemaining()
{
   datetime candleStartTime = iTime(_Symbol, _Period, 0);
   int candleDurationSeconds = PeriodSeconds(_Period);
   datetime candleEndTime = candleStartTime + candleDurationSeconds;
   long remainingSeconds = candleEndTime - TimeCurrent();
   if(remainingSeconds < 0) remainingSeconds = 0;
   return StringFormat("%02d:%02d", (int)(remainingSeconds / 60), (int)(remainingSeconds % 60));
}

void ResetDailyLimitsIfNeeded()
{
   MqlDateTime nowStruct, lastStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   TimeToStruct(lastDailyReset, lastStruct);
   if(nowStruct.day != lastStruct.day)
   {
      dailyLossTotal   = 0.0;
      dailyProfitTotal = 0.0;
      lastDailyReset   = TimeCurrent();
   }
}

void SendAlert(string message)
{
   Print(message);
   if(SendPhoneAlerts) SendNotification("EA Alert: " + message);
}

void DrawGraphicalDashboard()
{
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double openProfit  = GetBasketProfit();
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int openCount      = GetCurrentSymbolPositions();

   string plEmoji = "😐";
   if(openProfit > 0)      plEmoji = "😊";
   else if(openProfit < 0) plEmoji = "😡";

   string bgName = "EMA_Dash_BG_Panel";
   if(ObjectFind(0, bgName) < 0)
   {
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, 15);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, 15);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 380);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE, 285);
      ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, BgColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, BorderColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
   }

   double targetDisplay = CalculateDynamicTargetProfit(openCount);
   double currentGridStepPts = GetCurrentGridStepDistance() / _Point;

   int htfTrend = GetHTFTrend();
   string htfStr = UseMTFFilter ? ((htfTrend == 1) ? "BULLISH 🟢" : ((htfTrend == -1) ? "BEARISH 🔴" : "NEUTRAL ⚪")) : "DISABLED ⚪";

   string lines[14];
   lines[0]  = "------------------------------------------";
   lines[1]  = " RUHAAN FX - SNIPER MATRIX v6.5.9";
   lines[2]  = "------------------------------------------";
   lines[3]  = " Session Filter : London UK (06:00-18:00)";
   lines[4]  = " M15 HTF Trend  : " + htfStr;
   lines[5]  = " Lot Size Sizing: Fixed " + DoubleToString(GetCalculatedLotSize(), 2);
   lines[6]  = " Daily Max Loss : $" + DoubleToString(MaxDailyLossUSD, 2) + " Cap";
   lines[7]  = " Spread / Range : " + IntegerToString(currentSpread) + " pts (Max " + IntegerToString(MaxSpreadPoints) + ")";
   lines[8]  = " Balance / Equity: $" + DoubleToString(balance, 2) + " / $" + DoubleToString(equity, 2);
   lines[9]  = " Target Basket TP: $" + DoubleToString(targetDisplay, 2);
   lines[10] = " Dynamic Lock    : $0.30 Trigger -> $0.15 Lock";
   lines[11] = " Open Positions  : " + IntegerToString(openCount) + " (P/L: $" + DoubleToString(openProfit, 2) + " " + plEmoji + ")";
   lines[12] = " CANDLE TIMER    : " + GetCandleTimeRemaining();
   lines[13] = " STATUS          : " + currentStatus;

   int yDist = 25;
   for(int i = 0; i < 14; i++)
   {
      string objName = "EMA_Dash_Line_" + IntegerToString(i);
      if(ObjectFind(0, objName) < 0)
      {
         ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, 25);
         ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 9);
         ObjectSetString(0, objName, OBJPROP_FONT, "Segoe UI Emoji");
         ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      }

      ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, yDist);
      ObjectSetString(0, objName, OBJPROP_TEXT, lines[i]);

      if(i == 1) 
         ObjectSetInteger(0, objName, OBJPROP_COLOR, TitleColor);
      else if(i == 13) 
         ObjectSetInteger(0, objName, OBJPROP_COLOR, StatusColor);
      else if(i == 0 || i == 2)
         ObjectSetInteger(0, objName, OBJPROP_COLOR, BorderColor);
      else 
         ObjectSetInteger(0, objName, OBJPROP_COLOR, TextColor);

      yDist += 17;
   }
   ChartRedraw();
}

void DeleteDashboardObjects()
{
   ObjectDelete(0, "EMA_Dash_BG_Panel");
   for(int i = 0; i < 14; i++)
   {
      ObjectDelete(0, "EMA_Dash_Line_" + IntegerToString(i));
   }
   ChartRedraw();
}
