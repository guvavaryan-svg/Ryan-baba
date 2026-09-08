//+------------------------------------------------------------------+
//|                               EMA_Scalper_Ultimate_v5.1.mq5      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "5.10"

#include <Trade\Trade.mqh>
CTrade trade;

// --- Magic Number & Identification ---
input ulong    MagicNumber       = 51399;  // Unique Magic Number for this Chart

// --- EMA Strategy Inputs ---
input int      FastEMAPeriod     = 5;      // Fast EMA Period
input int      SlowEMAPeriod     = 13;     // Slow EMA Period
input double   LotSize           = 0.01;   // Base Lot Size
input double   TakeProfitTarget  = 0.50;   // Basket Target Profit ($0.50)
input double   MaxAllowedLoss    = 1.00;   // Hard Stop Loss Per Trade ($1.00)

// --- Grid & Recovery Inputs ---
input bool     UseSmartGrid      = true;   // Enable Smart Safety Grid
input int      MaxGridOrders     = 3;      // Max Grid Trades (Max 3)
input int      GridStepPoints    = 150;    // Grid Step Distance (Points)

// --- Risk & Protection Inputs ---
input int      MaxSpreadPoints   = 30;     // Maximum Allowed Spread (Points)
input double   MaxDailyLoss      = 3.00;   // Maximum Daily Loss Limit ($3.00)
input bool     UseATRFilter      = true;   // Enable ATR Volatility Filter
input int      ATRPeriod         = 14;     // ATR Period
input double   MinATRValue       = 0.00015;// Minimum Required Volatility
input bool     SendPhoneAlerts   = true;   // Send Push Notifications To Mobile

// --- Dashboard Customization Inputs ---
input color    BgColor           = C'25,28,36';   // Dark Grey Background Color
input color    BorderColor       = C'60,68,85';   // Panel Border Color
input color    TitleColor        = C'255,215,0';  // Gold Title Color
input color    TextColor         = C'220,225,230';// Main Text Color
input color    StatusColor       = C'50,205,50';  // Status Accent Color (Lime Green)

// --- Global Handles & Variables ---
int      fastEMA_handle, slowEMA_handle, atr_handle;
string   currentStatus  = "STUDYING MARKET...";
datetime lastTradeBarTime;
double   dailyLossTotal = 0.0;
datetime lastDailyReset;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

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

   // High frequency 1-second timer for real-time GUI panel refresh
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

//+------------------------------------------------------------------+
//| Timer & Event Handlers                                           |
//+------------------------------------------------------------------+
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

   if(dailyLossTotal >= MaxDailyLoss)
   {
      currentStatus = "STOPPED: Max Daily Loss Hit (-$" + DoubleToString(dailyLossTotal, 2) + ")";
      DrawGraphicalDashboard();
      return;
   }

   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > MaxSpreadPoints)
   {
      currentStatus = "PAUSED: High Spread (" + IntegerToString(currentSpread) + " pts)";
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
            currentStatus = "IDLE: Low Volatility (ATR)";
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
         currentStatus = "IDLE: Trade executed on current bar";
         DrawGraphicalDashboard();
         return;
      }

      currentStatus = "STUDYING MARKET (Scanning Crossover)...";

      double fastEMA[], slowEMA[];
      ArraySetAsSeries(fastEMA, true);
      ArraySetAsSeries(slowEMA, true);
      
      if(CopyBuffer(fastEMA_handle, 0, 0, 3, fastEMA) < 3) return;
      if(CopyBuffer(slowEMA_handle, 0, 0, 3, slowEMA) < 3) return;

      bool buySignal  = (fastEMA[2] < slowEMA[2]) && (fastEMA[1] > slowEMA[1]);
      bool sellSignal = (fastEMA[2] > slowEMA[2]) && (fastEMA[1] < slowEMA[1]);

      if(buySignal)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "EMA Scalper Buy"))
         {
            lastTradeBarTime = currentBarTime;
            SendAlert("BUY Open on " + _Symbol);
         }
      }
      else if(sellSignal)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "EMA Scalper Sell"))
         {
            lastTradeBarTime = currentBarTime;
            SendAlert("SELL Open on " + _Symbol);
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
//| Management Logic                                                 |
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
      if(basketProfit >= TakeProfitTarget)
      {
         CloseAllSymbolPositions();
         currentStatus = "CLOSED: Target Hit (+$" + DoubleToString(basketProfit, 2) + ")";
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

      if(posType == POSITION_TYPE_BUY)
      {
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(openPrice - currentAsk >= GridStepPoints * _Point) trade.Buy(LotSize, _Symbol, currentAsk, 0, 0, "Grid Buy");
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(currentBid - openPrice >= GridStepPoints * _Point) trade.Sell(LotSize, _Symbol, currentBid, 0, 0, "Grid Sell");
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
//| Graphical Dashboard Engine with Dark-Grey Background Panel       |
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

   // --- 1. Create Background Panel ---
   string bgName = "EMA_Dash_BG_Panel";
   if(ObjectFind(0, bgName) < 0)
   {
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, 15);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, 15);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 370);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE, 225);
      ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, BgColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, BorderColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
   }

   // --- 2. Dashboard Text Lines ---
   string lines[11];
   lines[0] = "------------------------------------------";
   lines[1] = "        EMA HYBRID ULTIMATE v5.1          ";
   lines[2] = "------------------------------------------";
   lines[3] = " Magic Number   : " + IntegerToString(MagicNumber);
   lines[4] = " Symbol / Period: " + _Symbol + " (" + EnumToString(_Period) + ")";
   lines[5] = " Spread          : " + IntegerToString(currentSpread) + " pts (Max " + IntegerToString(MaxSpreadPoints) + ")";
   lines[6] = " Balance / Equity: $" + DoubleToString(balance, 2) + " / $" + DoubleToString(equity, 2);
   lines[7] = " Daily Loss Used : $" + DoubleToString(dailyLossTotal, 2) + " / $" + DoubleToString(MaxDailyLoss, 2);
   lines[8] = " Open Positions  : " + IntegerToString(GetCurrentSymbolPositions()) + " (P/L: $" + DoubleToString(openProfit, 2) + ")";
   lines[9] = " CANDLE TIMER    : " + GetCandleTimeRemaining();
   lines[10]= " STATUS          : " + currentStatus;

   int yDist = 25;
   for(int i = 0; i < 11; i++)
   {
      string objName = "EMA_Dash_Line_" + IntegerToString(i);
      if(ObjectFind(0, objName) < 0)
      {
         ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, 25);
         ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 9);
         ObjectSetString(0, objName, OBJPROP_FONT, "Courier New");
         ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      }

      ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, yDist);
      ObjectSetString(0, objName, OBJPROP_TEXT, lines[i]);

      // Color Customization for high contrast
      if(i == 1) 
         ObjectSetInteger(0, objName, OBJPROP_COLOR, TitleColor);
      else if(i == 10) 
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
   for(int i = 0; i < 11; i++)
   {
      ObjectDelete(0, "EMA_Dash_Line_" + IntegerToString(i));
   }
   ChartRedraw();
}
