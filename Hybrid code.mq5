//+------------------------------------------------------------------+
//|                               EMA_Scalper_Ultimate_v4.1.mq5      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "4.10"

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

// --- News Filter Inputs ---
input bool     UseNewsFilter     = true;   // Enable Native MT5 Calendar Filter
input int      NewsMinsBefore    = 15;     // Pause mins before high impact news
input int      NewsMinsAfter     = 15;     // Pause mins after high impact news

// --- Global Handles & Variables ---
int      fastEMA_handle, slowEMA_handle, atr_handle;
string   currentStatus  = "Initializing...";
datetime lastTradeBarTime;
double   dailyLossTotal = 0.0;
datetime lastDailyReset;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set Magic Number for Trade Object
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
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(fastEMA_handle);
   IndicatorRelease(slowEMA_handle);
   IndicatorRelease(atr_handle);
   Comment(""); 
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   ResetDailyLossIfNeeded();
   ManagePositionsAndBasket();

   // Max Daily Loss Guard
   if(dailyLossTotal >= MaxDailyLoss)
   {
      currentStatus = "STOPPED: Max Daily Loss Hit (-$" + DoubleToString(dailyLossTotal, 2) + ")";
      DrawDashboard();
      return;
   }

   // Native News Calendar Guard
   if(UseNewsFilter && IsNativeHighImpactNewsNear())
   {
      currentStatus = "PAUSED: Native Calendar High Impact News";
      DrawDashboard();
      return;
   }

   // Spread Guard
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > MaxSpreadPoints)
   {
      currentStatus = "PAUSED: High Spread (" + IntegerToString(currentSpread) + " pts)";
      DrawDashboard();
      return;
   }

   // ATR Volatility Guard
   if(UseATRFilter)
   {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(atr_handle, 0, 0, 1, atr) > 0)
      {
         if(atr[0] < MinATRValue)
         {
            currentStatus = "IDLE: Low Volatility (ATR)";
            DrawDashboard();
            return;
         }
      }
   }

   int currentPositions = GetCurrentSymbolPositions();

   // Entry & Grid Logic
   if(currentPositions == 0)
   {
      datetime currentBarTime = iTime(_Symbol, _Period, 0);
      if(currentBarTime == lastTradeBarTime)
      {
         currentStatus = "IDLE: Trade executed on current bar";
         DrawDashboard();
         return;
      }

      currentStatus = "STUDYING MARKET (Scanning 5/13 EMA Crossover)...";

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
         if(trade.Buy(LotSize, _Symbol, ask, 0, 0, "Hybrid EMA Buy"))
         {
            lastTradeBarTime = currentBarTime;
            SendAlert("BUY Trade Opened on " + _Symbol);
         }
      }
      else if(sellSignal)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(trade.Sell(LotSize, _Symbol, bid, 0, 0, "Hybrid EMA Sell"))
         {
            lastTradeBarTime = currentBarTime;
            SendAlert("SELL Trade Opened on " + _Symbol);
         }
      }
   }
   else if(UseSmartGrid && currentPositions < MaxGridOrders)
   {
      currentStatus = "GRID ACTIVE (" + IntegerToString(currentPositions) + "/" + IntegerToString(MaxGridOrders) + " Trades)";
      CheckAndExecuteGrid();
   }

   DrawDashboard();
}

//+------------------------------------------------------------------+
//| Fixed Basket Profit Target & Hard Loss Management (Magic Filter) |
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
      // Target Profit Exit
      if(basketProfit >= TakeProfitTarget)
      {
         CloseAllSymbolPositions();
         currentStatus = "CLOSED: Target Hit (+$" + DoubleToString(basketProfit, 2) + ")";
         SendAlert("Basket Profit Secured: $" + DoubleToString(basketProfit, 2));
      }
      // Hard Stop Loss Exit
      else if(basketProfit <= -(MaxAllowedLoss * openCount))
      {
         double lossVal = MathAbs(basketProfit);
         CloseAllSymbolPositions();
         dailyLossTotal += lossVal;
         currentStatus = "CLOSED: Hard Loss Guard Hit (-$" + DoubleToString(lossVal, 2) + ")";
         SendAlert("Basket Closed with Loss: -$" + DoubleToString(lossVal, 2));
      }
   }
}

//+------------------------------------------------------------------+
//| Smart Grid Management Logic (Magic Filter)                       |
//+------------------------------------------------------------------+
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
         {
            trade.Buy(LotSize, _Symbol, currentAsk, 0, 0, "Hybrid Grid Buy");
            SendAlert("Grid Level Added (BUY)");
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(currentBid - openPrice >= GridStepPoints * _Point)
         {
            trade.Sell(LotSize, _Symbol, currentBid, 0, 0, "Hybrid Grid Sell");
            SendAlert("Grid Level Added (SELL)");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close All Positions with Magic Number Filter                     |
//+------------------------------------------------------------------+
void CloseAllSymbolPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Native MT5 Calendar Filter                                       |
//+------------------------------------------------------------------+
bool IsNativeHighImpactNewsNear()
{
   MqlCalendarEvent events[];
   datetime fromTime = TimeCurrent() - (NewsMinsBefore * 60);
   datetime toTime   = TimeCurrent() + (NewsMinsAfter * 60);

   string baseCurrency  = StringSubstr(_Symbol, 0, 3);
   string quoteCurrency = StringSubstr(_Symbol, 3, 3);

   if(CalendarValueHistory(events, fromTime, toTime, NULL, NULL))
   {
      for(int i = 0; i < ArraySize(events); i++)
      {
         if(events[i].importance == CALENDAR_IMPORTANCE_HIGH)
         {
            MqlCalendarCountry country;
            if(CalendarCountryById(events[i].country_id, country))
            {
               if(country.currency == baseCurrency || country.currency == quoteCurrency)
                  return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helper Functions & Dashboard                                     |
//+------------------------------------------------------------------+
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
   if(SendPhoneAlerts) SendNotification("EMA Hybrid Alert: " + message);
}

void DrawDashboard()
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

   string dash = "====================================================\n";
   dash += "         EMA HYBRID v4.1 (MAGIC NUMBER SUPPORT)     \n";
   dash += "====================================================\n";
   dash += " Magic Number   : " + IntegerToString(MagicNumber) + "\n";
   dash += " Symbol / Period : " + _Symbol + " (" + EnumToString(_Period) + ")\n";
   dash += " Spread          : " + IntegerToString(currentSpread) + " pts (Max: " + IntegerToString(MaxSpreadPoints) + ")\n";
   dash += " Balance / Equity: $" + DoubleToString(balance, 2) + " / $" + DoubleToString(equity, 2) + "\n";
   dash += " Daily Loss Used : $" + DoubleToString(dailyLossTotal, 2) + " / Max $" + DoubleToString(MaxDailyLoss, 2) + "\n";
   dash += " Open Positions  : " + IntegerToString(GetCurrentSymbolPositions()) + " (Profit: $" + DoubleToString(openProfit, 2) + ")\n";
   dash += "----------------------------------------------------\n";
   dash += " CANDLE TIMER    : " + GetCandleTimeRemaining() + " remaining\n";
   dash += " BOT STATUS      : " + currentStatus + "\n";
   dash += "----------------------------------------------------\n";
   dash += " News Guard      : Native MT5 Calendar\n";
   dash += " Target Basket   : Close all at $" + DoubleToString(TakeProfitTarget, 2) + "\n";
   dash += "====================================================\n";

   Comment(dash);
}
