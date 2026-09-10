//+------------------------------------------------------------------+
//|                               EMA_Scalper_Ultimate_v6.3.mq5      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "6.30"

#include <Trade\Trade.mqh>
CTrade trade;

// --- Magic Number & Identification ---
input ulong    MagicNumber          = 51399;   // Unique Magic Number for this Chart

// --- EMA Strategy Inputs ---
input int      FastEMAPeriod        = 5;       // Fast EMA Period
input int      SlowEMAPeriod        = 13;      // Slow EMA Period

// --- Dynamic Risk & Money Management (%) ---
input double   RiskPercentPerTrade  = 1.0;     // Risk Per Trade (% of Account Equity)
input double   MaxDailyLossPercent  = 3.0;     // Max Daily Loss Limit (% of Equity/Balance)
input double   TakeProfitTarget     = 0.50;    // Target Basket Profit ($0.50)
input double   MaxAllowedLoss       = 1.00;    // Hard Stop Loss Per Trade ($)

// --- Trailing Stop & Profit Protection Inputs ---
input bool     UseTrailingStop      = true;    // Enable Dynamic Trailing Stop
input int      TrailingStartPoints  = 50;      // Profit distance to start trailing (Points)
input int      TrailingStepPoints   = 20;      // Distance to keep behind price (Points)

// --- Dynamic Red Candle & Volatility Protection ---
input int      MaxCandleSizePoints  = 250;     // Max Allowed Red Candle Size (Points)
input bool     UseSmartGrid         = true;    // Enable Smart Safety Grid
input int      MaxGridOrders        = 3;       // Max Grid Trades (Max 3)
input int      GridStepPoints       = 150;     // Grid Step Distance (Points)

// --- Fast Execution & Broker Sync Inputs ---
input ulong    MaxSlippagePoints    = 15;      // Max Allowed Slippage/Deviation (Points)
input int      MaxSpreadPoints      = 20;      // Maximum Allowed Spread (Points)
input bool     UseATRFilter         = true;    // Enable ATR Volatility Filter
input int      ATRPeriod            = 14;      // ATR Period
input double   MinATRValue          = 0.00015; // Minimum Required Volatility
input bool     SendPhoneAlerts      = true;    // Send Push Notifications To Mobile

// --- Dashboard Customization Inputs ---
input color    BgColor              = C'30,34,45';    // Premium Dark Navy Slate
input color    BorderColor          = C'80,95,120';   // Sleek Metallic Gray
input color    TitleColor           = C'255,191,0';   // Bright Amber Gold
input color    TextColor            = C'220,225,230'; // Crisp Off-White Text
input color    AccentCyan           = C'0,225,255';   // Neon Cyan Info Accent
input color    StatusOkColor        = C'0,230,118';   // Vibrant Emerald Green
input color    StatusAlertColor     = C'255,52,85';   // Bright Crimson Red

// --- Global Handles & Variables ---
int      fastEMA_handle, slowEMA_handle, atr_handle;
string   currentStatus  = "STUDYING MARKET...";
datetime lastTradeBarTime;
double   dailyLossTotal = 0.0;
datetime lastDailyReset;

//+------------------------------------------------------------------+
//| Auto-Configure Broker Execution Settings                         |
//+------------------------------------------------------------------+
void SetBrokerExecutionSettings()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints);
   
   uint fillType = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillType & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((fillType & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| Calculate Dynamic Lot Size based on Dynamic Risk Percentage (%)   |
//+------------------------------------------------------------------+
double CalculateDynamicLotSize(double riskPercent)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = equity * (riskPercent / 100.0);
   
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   if(tickSize == 0 || tickValue == 0 || pointValue == 0) return 0.01;
   
   double lossInPoints = MaxAllowedLoss / (tickValue / tickSize * pointValue);
   if(lossInPoints <= 0) lossInPoints = 100;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lotSize = (riskAmount) / (lossInPoints * (tickValue / tickSize * pointValue));
   lotSize = MathFloor(lotSize / lotStep) * lotStep;

   if(lotSize < minLot) lotSize = minLot;
   if(lotSize > maxLot) lotSize = maxLot;

   return lotSize;
}

//+------------------------------------------------------------------+
//| Check Recent Candle Spike (Red Candle Protection)                |
//+------------------------------------------------------------------+
bool IsCandleSpikeDetected()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 1, rates) > 0)
   {
      double candleSize = (rates[0].high - rates[0].low) / _Point;
      if(candleSize > MaxCandleSizePoints)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   SetBrokerExecutionSettings();

   fastEMA_handle = iMA(_Symbol, _Period, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowEMA_handle = iMA(_Symbol, _Period, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   atr_handle     = iATR(_Symbol, _Period, ATRPeriod);
   
   if(fastEMA_handle == INVALID_HANDLE || slowEMA_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE)
   {
      Print("Error: Failed to initialize indicator handles.");
      return(INIT_FAILED);
   }
   
   lastDailyReset = TimeCurrent();
   currentStatus  = "STUDYING MARKET...";

   EventSetTimer(1);
   DrawGraphicalDashboard(); 

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   DeleteDashboardObjects();
   IndicatorRelease(fastEMA_handle);
   IndicatorRelease(slowEMA_handle);
   IndicatorRelease(atr_handle);
}

void OnTimer()
{
   DrawGraphicalDashboard();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   DrawGraphicalDashboard();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyLossIfNeeded();
   ManagePositionsAndBasket();
   
   if(UseTrailingStop) ApplyTrailingStop();

   double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxDailyAllowedCurrency = accountEquity * (MaxDailyLossPercent / 100.0);

   if(dailyLossTotal >= maxDailyAllowedCurrency)
   {
      currentStatus = "STOPPED: Daily Risk Limit (-$" + DoubleToString(dailyLossTotal, 2) + ")";
      DrawGraphicalDashboard();
      return;
   }

   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > MaxSpreadPoints)
   {
      currentStatus = "PAUSED: Spread High (" + IntegerToString(currentSpread) + " pts)";
      DrawGraphicalDashboard();
      return;
   }

   if(IsCandleSpikeDetected())
   {
      currentStatus = "PAUSED: Spike / Big Candle Protection";
      DrawGraphicalDashboard();
      return;
   }

   if(UseATRFilter)
   {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(atr_handle, 0, 0, 1, atr) > 0)
      {
         if(atr[0] < MinATRValue)
         {
            currentStatus = "IDLE: Low ATR Volatility";
            DrawGraphicalDashboard();
            return;
         }
      }
   }

   int currentPositions = GetCurrentSymbolPositions();

   if(currentPositions == 0)
   {
      datetime currentBarTime = iTime(_Symbol, _Period, 0);
      if(currentBarTime == lastTradeBarTime)
      {
         currentStatus = "IDLE: Trade Executed On Bar";
         DrawGraphicalDashboard();
         return;
      }

      currentStatus = "STUDYING MARKET...";

      double fastEMA[], slowEMA[];
      ArraySetAsSeries(fastEMA, true);
      ArraySetAsSeries(slowEMA, true);
      
      if(CopyBuffer(fastEMA_handle, 0, 0, 3, fastEMA) < 3) return;
      if(CopyBuffer(slowEMA_handle, 0, 0, 3, slowEMA) < 3) return;

      bool buySignal  = (fastEMA[2] < slowEMA[2]) && (fastEMA[1] > slowEMA[1]);
      bool sellSignal = (fastEMA[2] > slowEMA[2]) && (fastEMA[1] < slowEMA[1]);

      double calculatedLot = CalculateDynamicLotSize(RiskPercentPerTrade);

      if(buySignal)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(trade.Buy(calculatedLot, _Symbol, ask, 0, 0, "EMA Scalper Buy"))
         {
            lastTradeBarTime = currentBarTime;
            SendAlert("BUY Open on " + _Symbol + " | Lot: " + DoubleToString(calculatedLot, 2));
         }
      }
      else if(sellSignal)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(trade.Sell(calculatedLot, _Symbol, bid, 0, 0, "EMA Scalper Sell"))
         {
            lastTradeBarTime = currentBarTime;
            SendAlert("SELL Open on " + _Symbol + " | Lot: " + DoubleToString(calculatedLot, 2));
         }
      }
   }
   else if(UseSmartGrid && currentPositions < MaxGridOrders)
   {
      currentStatus = "GRID ACTIVE (" + IntegerToString(currentPositions) + "/" + IntegerToString(MaxGridOrders) + ")";
      CheckAndExecuteGrid();
   }

   DrawGraphicalDashboard();
}

//+------------------------------------------------------------------+
//| Management Logic (Immediate & Dynamic Target Closing)             |
//+------------------------------------------------------------------+
void ManagePositionsAndBasket()
{
   double basketProfit = 0.0;
   int openCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         basketProfit += PositionGetDouble(POSITION_PROFIT);
         openCount++;
      }
   }

   if(openCount > 0)
   {
      // --- Close at $0.48+ to guarantee closing before spread delays ---
      if(basketProfit >= (TakeProfitTarget - 0.02))
      {
         CloseAllSymbolPositions();
         currentStatus = "CLOSED: Target Secured (+$" + DoubleToString(basketProfit, 2) + ")";
         SendAlert("Profit Target Secured: $" + DoubleToString(basketProfit, 2));
      }
      else if(basketProfit <= -(MaxAllowedLoss * openCount))
      {
         double lossVal = MathAbs(basketProfit);
         CloseAllSymbolPositions();
         dailyLossTotal += lossVal;
         currentStatus = "CLOSED: Hard Loss Hit (-$" + DoubleToString(lossVal, 2) + ")";
         SendAlert("Closed with Loss: -$" + DoubleToString(lossVal, 2));
      }
   }
}

//+------------------------------------------------------------------+
//| Dynamic Trailing Stop Loss Engine                               |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double currentSL = PositionGetDouble(POSITION_SL);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

         if(type == POSITION_TYPE_BUY)
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            if(bid - openPrice > TrailingStartPoints * _Point)
            {
               double newSL = bid - (TrailingStepPoints * _Point);
               if(newSL > currentSL) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
         else if(type == POSITION_TYPE_SELL)
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            if(openPrice - ask > TrailingStartPoints * _Point)
            {
               double newSL = ask + (TrailingStepPoints * _Point);
               if(newSL < currentSL || currentSL == 0) trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

void CheckAndExecuteGrid()
{
   ulong lastTicket = 0;
   datetime lastTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         datetime pTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(pTime > lastTime)
         {
            lastTime = pTime;
            lastTicket = PositionGetTicket(i);
         }
      }
   }

   if(lastTicket > 0 && PositionSelectByTicket(lastTicket))
   {
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double calcLot = CalculateDynamicLotSize(RiskPercentPerTrade);

      if(posType == POSITION_TYPE_BUY)
      {
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(openPrice - currentAsk >= GridStepPoints * _Point) trade.Buy(calcLot, _Symbol, currentAsk, 0, 0, "Grid Buy");
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(currentBid - openPrice >= GridStepPoints * _Point) trade.Sell(calcLot, _Symbol, currentBid, 0, 0, "Grid Sell");
      }
   }
}

void CloseAllSymbolPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         trade.PositionClose(ticket);
   }
}

int GetCurrentSymbolPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) count++;
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

void ResetDailyLossIfNeeded()
{
   MqlDateTime nowStruct, lastStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   TimeToStruct(lastDailyReset, lastStruct);
   if(nowStruct.day != lastStruct.day)
   {
      dailyLossTotal = 0.0;
      lastDailyReset = TimeCurrent();
   }
}

void SendAlert(string message)
{
   Print(message);
   PlaySound("alert.wav");
   if(SendPhoneAlerts) SendNotification("EA Alert: " + message);
}

//+------------------------------------------------------------------+
//| Graphical Dashboard Engine                                       |
//+------------------------------------------------------------------+
void DrawGraphicalDashboard()
{
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double openProfit  = 0.0;
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         openProfit += PositionGetDouble(POSITION_PROFIT);
   }

   string bgName = "EMA_Dash_BG_Panel";
   if(ObjectFind(0, bgName) < 0)
   {
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, 12);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 380);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE, 240);
      ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, BgColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, BorderColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
   }

   double maxDailyCurrencyLimit = equity * (MaxDailyLossPercent / 100.0);

   string lines[11];
   lines[0] = "------------------------------------------";
   lines[1] = "   EMA HYBRID PRO v6.3 (AUTO TRAILING)   ";
   lines[2] = "------------------------------------------";
   lines[3] = " Target TP / Trail: $" + DoubleToString(TakeProfitTarget, 2) + " / " + (UseTrailingStop ? "ACTIVE" : "OFF");
   lines[4] = " Symbol / Period  : " + _Symbol + " (" + EnumToString(_Period) + ")";
   lines[5] = " Current Spread   : " + IntegerToString(currentSpread) + " pts (Max " + IntegerToString(MaxSpreadPoints) + ")";
   lines[6] = " Balance / Equity : $" + DoubleToString(balance, 2) + " / $" + DoubleToString(equity, 2);
   lines[7] = " Daily Loss Limit : $" + DoubleToString(dailyLossTotal, 2) + " / $" + DoubleToString(maxDailyCurrencyLimit, 2) + " (" + DoubleToString(MaxDailyLossPercent, 1) + "%)";
   lines[8] = " Open Positions   : " + IntegerToString(GetCurrentSymbolPositions()) + " (P/L: $" + DoubleToString(openProfit, 2) + ")";
   lines[9] = " CANDLE TIMER     : " + GetCandleTimeRemaining();
   lines[10]= " STATUS           : " + currentStatus;

   int yDist = 20;
   for(int i = 0; i < 11; i++)
   {
      string objName = "EMA_Dash_Line_" + IntegerToString(i);
      if(ObjectFind(0, objName) < 0)
      {
         ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, 22);
         ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 9);
         ObjectSetString(0, objName, OBJPROP_FONT, "Courier New");
         ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      }

      ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, yDist);
      ObjectSetString(0, objName, OBJPROP_TEXT, lines[i]);

      if(i == 1) 
         ObjectSetInteger(0, objName, OBJPROP_COLOR, TitleColor);
      else if(i == 0 || i == 2)
         ObjectSetInteger(0, objName, OBJPROP_COLOR, BorderColor);
      else if(i == 3 || i == 9)
         ObjectSetInteger(0, objName, OBJPROP_COLOR, AccentCyan);
      else if(i == 8)
         ObjectSetInteger(0, objName, OBJPROP_COLOR, openProfit >= 0 ? StatusOkColor : StatusAlertColor);
      else if(i == 10) 
         ObjectSetInteger(0, objName, OBJPROP_COLOR, StringFind(currentStatus, "STOPPED") < 0 ? StatusOkColor : StatusAlertColor);
      else 
         ObjectSetInteger(0, objName, OBJPROP_COLOR, TextColor);

      yDist += 18;
   }
   ChartRedraw();
}

void DeleteDashboardObjects()
{
   ObjectDelete(0, "EMA_Dash_BG_Panel");
   for(int i = 0; i < 11; i++)
   {
      ObjectDelete(0, "EMA_Dash_Line_" + IntegerToString(i));
   }
   ChartRedraw();
}
