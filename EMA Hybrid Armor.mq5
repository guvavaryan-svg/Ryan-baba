//+------------------------------------------------------------------+
//|                        EMA_Scalper_Ultimate_v5.6_Armor.mq5       |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "5.60"

#include <Trade\Trade.mqh>
CTrade trade;

// --- Magic Number & Identification ---
input ulong    MagicNumber       = 51399;  // Unique Magic Number for this Chart

// --- EMA Strategy Inputs ---
input int      FastEMAPeriod     = 5;      // Fast EMA Period
input int      SlowEMAPeriod     = 13;     // Slow EMA Period
input double   LotSize           = 0.01;   // Base Lot Size (Fixed to 0.01)
input double   TakeProfitTarget  = 0.50;   // Basket Target Profit ($0.50)
input double   MaxAllowedLoss    = 1.00;   // Hard Stop Loss Per Trade ($1.00)

// --- Grid & Recovery Inputs ---
input bool     UseSmartGrid      = true;   // Enable Smart Safety Grid
input int      MaxGridOrders     = 3;      // Max Grid Trades (Max 3)
input int      GridStepPoints    = 150;    // Grid Step Distance (Points)

// --- Fast Execution & Broker Sync Inputs ---
input ulong    MaxSlippagePoints = 50;     // Max Allowed Slippage/Deviation (Points)
input int      MaxSpreadPoints   = 50;     // Maximum Allowed Spread (Points)
input double   MaxDailyLoss      = 3.00;   // Maximum Daily Loss Limit ($3.00)
input double   MaxDailyProfit    = 10.00;  // Maximum Daily Profit Target ($10.00)
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
string   currentStatus     = "STUDYING MARKET...";
datetime lastTradeBarTime;
double   dailyLossTotal    = 0.0;
double   dailyProfitTotal  = 0.0;
datetime lastDailyReset;

// --- Network Protection & Anti-Flooding Variables ---
datetime lastExecutionTime = 0;
int      consecutiveErrors = 0;

//+------------------------------------------------------------------+
//| Auto-Configure Broker Execution Settings                         |
//+------------------------------------------------------------------+
void SetBrokerExecutionSettings()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints); // Eliminates Price Gap/Slippage
   trade.SetAsyncMode(false); // Synchronous execution: Waits for broker confirmation before reporting
   
   // Set optimal filling mode dynamically
   uint fillType = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillType & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((fillType & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
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
   
   lastDailyReset    = TimeCurrent();
   currentStatus     = "STUDYING MARKET...";
   consecutiveErrors = 0;

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
//| Anti-Broker Rejection & Safe Order Execution Engine              |
//+------------------------------------------------------------------+
bool SafeExecuteTrade(ENUM_ORDER_TYPE orderType, double requestedLots, string comment)
{
   // 1. Anti-Spam Check: Halt if requests are closer than 3 seconds
   if(TimeCurrent() - lastExecutionTime < 3) 
      return false;

   // 2. Terminal Connection Check
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      currentStatus = "PAUSED: No Terminal Connection";
      return false;
   }

   // 3. Rejection Cooldown Check
   if(consecutiveErrors >= 5)
   {
      currentStatus = "COOLDOWN: Too many rejections (30s Pause)";
      Sleep(30000); 
      consecutiveErrors = 0;
      return false;
   }

   // 4. Normalize Lot Size against Broker Rules
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   double safeVolume = MathFloor(requestedLots / lotStep) * lotStep;
   if(safeVolume < minLot) safeVolume = minLot;
   if(safeVolume > maxLot) safeVolume = maxLot;

   bool success = false;

   // 5. Execution Loop with Retry Logic
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

      Sleep(200); // 200ms delay before retrying
   }

   lastExecutionTime = TimeCurrent();

   if(!success)
   {
      consecutiveErrors++;
      Print("Broker rejected order! Code: ", trade.ResultRetcode(), " Desc: ", trade.ResultRetcodeDescription());
      return false;
   }

   consecutiveErrors = 0; // Reset counter upon successful trade
   return true;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Connection Safety Check
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      currentStatus = "PAUSED: No Terminal Connection";
      DrawGraphicalDashboard();
      return;
   }

   ResetDailyLimitsIfNeeded();
   ManagePositionsAndBasket();

   // Check Daily Loss Limit
   if(dailyLossTotal >= MaxDailyLoss)
   {
      currentStatus = "STOPPED: Max Daily Loss Hit (-$" + DoubleToString(dailyLossTotal, 2) + ")";
      DrawGraphicalDashboard();
      return;
   }

   // Check Daily Profit Limit
   if(dailyProfitTotal >= MaxDailyProfit)
   {
      currentStatus = "TARGET REACHED: Daily Target Hit (+$" + DoubleToString(dailyProfitTotal, 2) + ")";
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
         if(SafeExecuteTrade(ORDER_TYPE_BUY, LotSize, "EMA Scalper Buy"))
         {
            lastTradeBarTime = currentBarTime;
            SendAlert("BUY Open on " + _Symbol);
         }
      }
      else if(sellSignal)
      {
         if(SafeExecuteTrade(ORDER_TYPE_SELL, LotSize, "EMA Scalper Sell"))
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
         dailyProfitTotal += basketProfit; // Tracks total profit achieved today
         currentStatus = "CLOSED: Target Hit (+$" + DoubleToString(basketProfit, 2) + ")";
         SendAlert("Profit Target Secured: $" + DoubleToString(basketProfit, 2));
      }
      else if(basketProfit <= -(MaxAllowedLoss * openCount))
      {
         double lossVal = MathAbs(basketProfit);
         CloseAllSymbolPositions();
         dailyLossTotal += lossVal; // Tracks total loss accrued today
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
         if(openPrice - currentAsk >= GridStepPoints * _Point) 
            SafeExecuteTrade(ORDER_TYPE_BUY, LotSize, "Grid Buy");
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(currentBid - openPrice >= GridStepPoints * _Point) 
            SafeExecuteTrade(ORDER_TYPE_SELL, LotSize, "Grid Sell");
      }
   }
}

void CloseAllSymbolPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         if(!trade.PositionClose(ticket))
            Print("Failed to close position #", ticket, " Error: ", GetLastError());
         Sleep(100); // Prevents close flooding
      }
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
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, 15);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, 15);
      ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 370);
      ObjectSetInteger(0, bgName, OBJPROP_YSIZE, 258);
      ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, BgColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, BorderColor);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
   }

   string lines[13];
   lines[0] = "------------------------------------------";
   lines[1] = "      EMA HYBRID v5.6 (ARMOR EDITION)     ";
   lines[2] = "------------------------------------------";
   lines[3] = " Magic Number   : " + IntegerToString(MagicNumber);
   lines[4] = " Symbol / Period: " + _Symbol + " (" + EnumToString(_Period) + ")";
   lines[5] = " Spread          : " + IntegerToString(currentSpread) + " pts (Max " + IntegerToString(MaxSpreadPoints) + ")";
   lines[6] = " Balance / Equity: $" + DoubleToString(balance, 2) + " / $" + DoubleToString(equity, 2);
   lines[7] = " Daily Loss Used : $" + DoubleToString(dailyLossTotal, 2) + " / $" + DoubleToString(MaxDailyLoss, 2);
   lines[8] = " Daily Profit Made: $" + DoubleToString(dailyProfitTotal, 2) + " / $" + DoubleToString(MaxDailyProfit, 2);
   lines[9] = " Open Positions  : " + IntegerToString(GetCurrentSymbolPositions()) + " (P/L: $" + DoubleToString(openProfit, 2) + ")";
   lines[10]= " Errors          : " + IntegerToString(consecutiveErrors) + "/5 (Cooldown)";
   lines[11]= " CANDLE TIMER    : " + GetCandleTimeRemaining();
   lines[12]= " STATUS          : " + currentStatus;

   int yDist = 25;
   for(int i = 0; i < 13; i++)
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

      if(i == 1) 
         ObjectSetInteger(0, objName, OBJPROP_COLOR, TitleColor);
      else if(i == 12) 
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
   for(int i = 0; i < 13; i++)
   {
      ObjectDelete(0, "EMA_Dash_Line_" + IntegerToString(i));
   }
   ChartRedraw();
}
