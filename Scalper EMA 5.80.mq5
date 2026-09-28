//+------------------------------------------------------------------+
//|             EMA_Scalper_Ultimate_v5.8_Armor_Dynamic.mq5          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "5.80"

#include <Trade\Trade.mqh>
CTrade trade;

// --- Magic Number & Identification ---
input ulong    MagicNumber       = 51399;  // Unique Magic Number for this Chart

// --- EMA Strategy Inputs ---
input int      FastEMAPeriod     = 5;      // Fast EMA Period
input int      SlowEMAPeriod     = 13;     // Slow EMA Period
input double   LotSize           = 0.01;   // Base Lot Size (Fixed to 0.01)
input double   TakeProfitTarget  = 0.50;   // Base Basket Target Profit ($0.50)
input double   MaxAllowedLoss    = 1.00;   // Hard Stop Loss Per Basket ($1.00)

// --- Dynamic Grid & Recovery Inputs ---
input bool     UseSmartGrid      = true;   // Enable Smart Safety Grid
input bool     UseDynamicGridTP  = true;   // Enable Dynamic Target Profit
input double   DynamicMultiplier = 1.0;    // TP Scaling Factor Per Grid Level (1.0 = Linear)
input bool     UseDynamicATRStep = true;   // Enable Dynamic ATR Grid Step (Overrides Fixed Step)
input double   ATRStepMultiplier = 1.5;    // ATR Step Multiplier (ATR * Multiplier)
input int      MaxGridOrders     = 3;      // Max Grid Trades (Max 3)
input int      GridStepPoints    = 150;    // Fixed Grid Step Distance (Fallback Points)

// --- News Filter Inputs ---
input bool     UseNewsFilter     = true;   // Enable High-Impact News Filter
input int      NewsPauseBefore   = 15;     // Pause Trading (Minutes BEFORE News)
input int      NewsPauseAfter    = 15;     // Pause Trading (Minutes AFTER News)

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
datetime cooldownExpiry    = 0;

//+------------------------------------------------------------------+
//| Dynamic Target Profit Calculator Engine                         |
//+------------------------------------------------------------------+
double CalculateDynamicTargetProfit(int openCount)
{
   if(openCount <= 0) return TakeProfitTarget;
   
   if(!UseDynamicGridTP) 
      return TakeProfitTarget;

   double calculatedTP = TakeProfitTarget * (1.0 + ((openCount - 1) * DynamicMultiplier));
   
   if(calculatedTP <= 0.0) return TakeProfitTarget;
   
   return NormalizeDouble(calculatedTP, 2);
}

//+------------------------------------------------------------------+
//| Dynamic Grid Step Distance Calculator (ATR-Based)               |
//+------------------------------------------------------------------+
double GetCurrentGridStepDistance()
{
   if(!UseDynamicATRStep)
   {
      return GridStepPoints * _Point;
   }

   double atr[];
   ArraySetAsSeries(atr, true);
   
   if(CopyBuffer(atr_handle, 0, 0, 1, atr) > 0 && atr[0] > 0)
   {
      double calculatedStep = atr[0] * ATRStepMultiplier;
      
      // Ensure step is not smaller than fixed GridStepPoints for safety
      if(calculatedStep < (GridStepPoints * _Point))
      {
         return GridStepPoints * _Point;
      }
      return calculatedStep;
   }

   return GridStepPoints * _Point;
}

//+------------------------------------------------------------------+
//| Auto-Configure Broker Execution Settings                         |
//+------------------------------------------------------------------+
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
//| High Impact News Calendar Check                                  |
//+------------------------------------------------------------------+
bool IsHighImpactNewsTime()
{
   if(!UseNewsFilter) return false;

   MqlCalendarValue values[];
   datetime fromTime = TimeCurrent() - (NewsPauseAfter * 60);
   datetime toTime   = TimeCurrent() + (NewsPauseBefore * 60);

   if(CalendarValueHistory(values, fromTime, toTime, NULL, NULL) > 0)
   {
      for(int i = 0; i < ArraySize(values); i++)
      {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event))
         {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH)
            {
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Anti-Broker Rejection & Safe Order Execution Engine              |
//+------------------------------------------------------------------+
bool SafeExecuteTrade(ENUM_ORDER_TYPE orderType, double requestedLots, string comment)
{
   if(TimeCurrent() < cooldownExpiry)
   {
      currentStatus = "COOLDOWN ACTIVE (" + IntegerToString((int)(cooldownExpiry - TimeCurrent())) + "s)";
      return false;
   }

   if(TimeCurrent() - lastExecutionTime < 3) 
      return false;

   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      currentStatus = "PAUSED: No Terminal Connection";
      return false;
   }

   if(consecutiveErrors >= 5)
   {
      currentStatus = "COOLDOWN INITIATED (30s Pause)";
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

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      currentStatus = "PAUSED: No Terminal Connection";
      return;
   }

   ResetDailyLimitsIfNeeded();
   ManagePositionsAndBasket();

   if(dailyLossTotal >= MaxDailyLoss)
   {
      currentStatus = "STOPPED: Max Daily Loss Hit (-$" + DoubleToString(dailyLossTotal, 2) + ")";
      return;
   }

   if(dailyProfitTotal >= MaxDailyProfit)
   {
      currentStatus = "TARGET REACHED: Daily Target Hit (+$" + DoubleToString(dailyProfitTotal, 2) + ")";
      return;
   }

   if(IsHighImpactNewsTime())
   {
      currentStatus = "PAUSED: High Impact News Event";
      return;
   }

   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > MaxSpreadPoints)
   {
      currentStatus = "PAUSED: High Spread (" + IntegerToString(currentSpread) + " pts)";
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
            return;
         }
      }
   }

   double fastEMA[], slowEMA[];
   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   
   if(CopyBuffer(fastEMA_handle, 0, 0, 3, fastEMA) < 3) return;
   if(CopyBuffer(slowEMA_handle, 0, 0, 3, slowEMA) < 3) return;

   bool buySignal  = (fastEMA[2] < slowEMA[2]) && (fastEMA[1] > slowEMA[1]);
   bool sellSignal = (fastEMA[2] > slowEMA[2]) && (fastEMA[1] < slowEMA[1]);

   int buyPositions = 0, sellPositions = 0;
   GetPositionTypesCount(buyPositions, sellPositions);

   if(buySignal)
   {
      if(sellPositions > 0)
      {
         CloseAllSymbolPositions();
         currentStatus = "REVERSING: Closed SELL on BUY Crossover";
      }

      datetime currentBarTime = iTime(_Symbol, _Period, 0);
      if(GetCurrentSymbolPositions() == 0 && currentBarTime != lastTradeBarTime)
      {
         if(SafeExecuteTrade(ORDER_TYPE_BUY, LotSize, "EMA Reverse Buy"))
         {
            lastTradeBarTime = currentBarTime;
            SendAlert("BUY Open (Crossover) on " + _Symbol);
         }
      }
   }
   else if(sellSignal)
   {
      if(buyPositions > 0)
      {
         CloseAllSymbolPositions();
         currentStatus = "REVERSING: Closed BUY on SELL Crossover";
      }

      datetime currentBarTime = iTime(_Symbol, _Period, 0);
      if(GetCurrentSymbolPositions() == 0 && currentBarTime != lastTradeBarTime)
      {
         if(SafeExecuteTrade(ORDER_TYPE_SELL, LotSize, "EMA Reverse Sell"))
         {
            lastTradeBarTime = currentBarTime;
            SendAlert("SELL Open (Crossover) on " + _Symbol);
         }
      }
   }
   else if(UseSmartGrid && GetCurrentSymbolPositions() > 0 && GetCurrentSymbolPositions() < MaxGridOrders)
   {
      currentStatus = "GRID ACTIVE (" + IntegerToString(GetCurrentSymbolPositions()) + "/" + IntegerToString(MaxGridOrders) + ")";
      CheckAndExecuteGrid();
   }
   else if(GetCurrentSymbolPositions() == 0)
   {
      currentStatus = "STUDYING MARKET (Scanning Crossover)...";
   }
}

//+------------------------------------------------------------------+
//| Management Logic with Enhanced Dynamic Grid Target               |
//+------------------------------------------------------------------+
void ManagePositionsAndBasket()
{
   double basketProfit = 0.0;
   int openCount = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         basketProfit += PositionGetDouble(POSITION_PROFIT);
         openCount++;
      }
   }

   if(openCount > 0)
   {
      double dynamicTP = CalculateDynamicTargetProfit(openCount);

      if(basketProfit >= dynamicTP)
      {
         CloseAllSymbolPositions();
         dailyProfitTotal += basketProfit;
         currentStatus = "CLOSED: Target Hit (+$" + DoubleToString(basketProfit, 2) + ")";
         SendAlert("Profit Target Secured: $" + DoubleToString(basketProfit, 2));
      }
      else if(basketProfit <= -MaxAllowedLoss)
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
//| Check and Execute Grid Trade using Dynamic Step Distance         |
//+------------------------------------------------------------------+
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

      // Fetch dynamic ATR step distance
      double requiredStepDistance = GetCurrentGridStepDistance();

      if(posType == POSITION_TYPE_BUY)
      {
         double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(openPrice - currentAsk >= requiredStepDistance) 
            SafeExecuteTrade(ORDER_TYPE_BUY, LotSize, "Grid Buy (ATR Step)");
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(currentBid - openPrice >= requiredStepDistance) 
            SafeExecuteTrade(ORDER_TYPE_SELL, LotSize, "Grid Sell (ATR Step)");
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
         trade.PositionClose(ticket);
         Sleep(100);
      }
   }
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

void GetPositionTypesCount(int &buyCount, int &sellCount)
{
   buyCount = 0;
   sellCount = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(posType == POSITION_TYPE_BUY) buyCount++;
         if(posType == POSITION_TYPE_SELL) sellCount++;
      }
   }
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
   int openCount      = GetCurrentSymbolPositions();
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
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

   double targetDisplay = CalculateDynamicTargetProfit(openCount);
   double currentGridStepPts = GetCurrentGridStepDistance() / _Point;

   string lines[13];
   lines[0] = "------------------------------------------";
   lines[1] = "     EMA HYBRID v5.8 (DYNAMIC ARMOR)      ";
   lines[2] = "------------------------------------------";
   lines[3] = " Magic Number   : " + IntegerToString(MagicNumber);
   lines[4] = " Symbol / Period: " + _Symbol + " (" + EnumToString(_Period) + ")";
   lines[5] = " Spread          : " + IntegerToString(currentSpread) + " pts (Max " + IntegerToString(MaxSpreadPoints) + ")";
   lines[6] = " Balance / Equity: $" + DoubleToString(balance, 2) + " / $" + DoubleToString(equity, 2);
   lines[7] = " Target Basket TP: $" + DoubleToString(targetDisplay, 2) + (UseDynamicGridTP ? " (Dynamic)" : " (Fixed)");
   lines[8] = " Active Grid Step: " + DoubleToString(currentGridStepPts, 1) + " pts " + (UseDynamicATRStep ? "(Dynamic ATR)" : "(Fixed)");
   lines[9] = " Open Positions  : " + IntegerToString(openCount) + " (P/L: $" + DoubleToString(openProfit, 2) + ")";
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
