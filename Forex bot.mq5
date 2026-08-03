//+------------------------------------------------------------------+
//| Team1_PRO_V3.4_DIPRIP_Martingale_Forex.mq5                       |
//| Strategy: EMA + RSI + DIP/RIP + MARTINGALE + AntiSideways        |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>
CTrade trade;

//--- STRATEGY INPUTS
input bool UseFixedLot = false;     // Set to TRUE to force a fixed lot
input double FixedLotSize = 0.01;   // Manual Lot size if UseFixedLot = true
input double RiskPercent = 1.0;     // Risk per trade in %
input int FastMA = 10;
input int SlowMA = 50;
input int RSIPeriod = 14;
input double StopLossPips = 20.0;   // SL in Pips
input double TakeProfitPips = 40.0;  // TP in Pips
input double TrailStart = 15.0;      // Trailing Stop start in Pips
input double TrailStep = 5.0;        // Trailing Stop step in Pips
input double BreakEven = 20.0;       // Break Even trigger in Pips
input int MaxSpreadPoints = 30;      // Adjusted for Forex (3.0 pips)

//--- DIP/RIP INPUTS
input bool UseDipRip = true;
input double DipMultiplier = 1.5;
input double RipMultiplier = 1.5;
input int RSIDip = 30;
input int RSIRip = 70;

//--- MARTINGALE INPUTS
input bool UseMartingale = true;
input double MartingaleMultiplier = 1.5; // Lowered to 1.5 for safer FX trading
input int MaxMartingaleSteps = 3;

//--- SIDEWAYS FILTER
input bool UseSidewaysFilter = true;
input int ADXPeriod = 14;
input double ADXThreshold = 20.0;
input int ATRPeriod = 14;
input double MinATR = 0.00005;      // Adjusted for Forex 5-digit movement

//--- PRO INPUTS
input int MagicNumber = 12347; 
input bool TradeOnlyOne = true;
input double MaxDailyLossPercent = 8.0;
input double MaxTotalDrawdownPercent = 10.0;
input bool CloseAllOnHalt = true;
input bool UseTradingHours = true;   // Turned ON for Forex Sessions
input int StartHour = 7;             // London Open (adjust to broker time)
input int EndHour = 20;              // NY Session end
input bool UseNewsFilter = false;    
input int MinutesBeforeNews = 30;
input int MinutesAfterNews = 30;
input int CooldownMinutes = 15;

int news_hours[] = {14, 16};
int news_mins[] = {30, 30};

// GLOBAL VARIABLES
double pip_size;
double equity_peak = 0;
double start_balance = 0;
datetime last_trade_time = 0;
int last_day = -1;
int martingale_step = 0; 

// INDICATOR HANDLES
int handleFastMA = INVALID_HANDLE;
int handleSlowMA = INVALID_HANDLE;
int handleRSI    = INVALID_HANDLE;
int handleATR    = INVALID_HANDLE;
int handleADX    = INVALID_HANDLE;

int OnInit()
{
   // Properly calculate Pip Size for Forex (5/3 digits vs 4/2 digits)
   if(_Digits == 3 || _Digits == 5)
      pip_size = _Point * 10;
   else
      pip_size = _Point;

   equity_peak = AccountInfoDouble(ACCOUNT_EQUITY);
   start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   last_day = dt.day;
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);

   // Initialize Indicator Handles ONCE to avoid lag
   handleFastMA = iMA(_Symbol, PERIOD_CURRENT, FastMA, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowMA = iMA(_Symbol, PERIOD_CURRENT, SlowMA, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI    = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
   handleATR    = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
   handleADX    = iADX(_Symbol, PERIOD_CURRENT, ADXPeriod);

   if(handleFastMA == INVALID_HANDLE || handleSlowMA == INVALID_HANDLE || 
      handleRSI == INVALID_HANDLE || handleATR == INVALID_HANDLE || handleADX == INVALID_HANDLE)
   {
      Print("Error creating indicator handles.");
      return(INIT_FAILED);
   }

   Print("PRO BOT V3.4 FOREX READY - Magic: ", MagicNumber);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Clean up indicator handles from memory
   IndicatorRelease(handleFastMA);
   IndicatorRelease(handleSlowMA);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleATR);
   IndicatorRelease(handleADX);
}

bool IsMarketTrending()
{
   if(!UseSidewaysFilter) return true;
   
   double adx[];
   double atr[];
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(atr, true);
   
   if(CopyBuffer(handleADX, 0, 0, 1, adx) <= 0 || CopyBuffer(handleATR, 0, 0, 1, atr) <= 0)
      return false;
   
   if(adx[0] < ADXThreshold || atr[0] < MinATR)
   {
      Comment("PAUSED: SIDEWAYS MARKET | ADX: ", DoubleToString(adx[0], 1), " ATR: ", DoubleToString(atr[0], 5));
      return false;
   }
   return true;
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(trade.PositionClose(ticket))
         {
            if(profit < 0 && UseMartingale && martingale_step < MaxMartingaleSteps)
               martingale_step++;
            else if(profit > 0)
               martingale_step = 0; 

            Print("Closed #", ticket, " Profit:", profit, " Next Step:", martingale_step);
            last_trade_time = TimeCurrent();
         }
      }
   }
}

bool EquityProtector()
{
   MqlDateTime dt; 
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != last_day)
   {
      start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      equity_peak = AccountInfoDouble(ACCOUNT_EQUITY);
      last_day = dt.day;
      martingale_step = 0; 
      Print("New Day Reset. Balance: ", start_balance);
   }
   
   double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double current_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(current_equity > equity_peak) equity_peak = current_equity;
   
   double daily_loss = (start_balance > 0) ? (start_balance - current_balance) / start_balance * 100.0 : 0;
   double drawdown = (equity_peak > 0) ? (equity_peak - current_equity) / equity_peak * 100.0 : 0;
   
   if(daily_loss >= MaxDailyLossPercent || drawdown >= MaxTotalDrawdownPercent)
   {
      Comment("HALTED: Daily Loss:", DoubleToString(daily_loss, 2), "% DD:", DoubleToString(drawdown, 2), "%");
      Print("HALTED: DailyLoss=", daily_loss, "% DD=", drawdown, "%");
      if(CloseAllOnHalt) CloseAllPositions();
      return false;
   }
   Comment("Running | Step: ", martingale_step, " | Daily Loss: ", DoubleToString(daily_loss, 2), "%");
   return true;
}

bool CheckTradingHours()
{ 
   if(!UseTradingHours) return true; 
   MqlDateTime dt; 
   TimeToStruct(TimeCurrent(), dt); 
   return (dt.hour >= StartHour && dt.hour < EndHour); 
}

bool IsNewsTime()
{ 
   if(!UseNewsFilter) return false; 
   datetime server_time = TimeCurrent(); 
   MqlDateTime dt; 
   for(int i = 0; i < ArraySize(news_hours); i++)
   { 
      TimeToStruct(server_time, dt); 
      dt.hour = news_hours[i]; 
      dt.min = news_mins[i]; 
      dt.sec = 0; 
      datetime news_time = StructToTime(dt); 
      double diff_minutes = MathAbs((double)(server_time - news_time) / 60.0); 
      if(diff_minutes <= MinutesBeforeNews || diff_minutes <= MinutesAfterNews) return true;
   } 
   return false; 
}

bool CheckSpread()
{ 
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread_points = (ask - bid) / _Point; 
   if(spread_points > MaxSpreadPoints)
   { 
      Comment("PAUSED: High Spread: ", DoubleToString(spread_points / 10.0, 1), " pips"); 
      return false;
   } 
   return true; 
}

double CalculateLotSize(double sl_pips)
{
   double lot = FixedLotSize;
   
   if(!UseFixedLot)
   {
      double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      
      if(tick_size > 0 && tick_value > 0)
      {
         double sl_in_price = sl_pips * pip_size;
         lot = risk_amount / (sl_in_price / tick_size * tick_value);
      }
   }

   if(UseMartingale && martingale_step > 0)
      lot = lot * MathPow(MartingaleMultiplier, martingale_step);

   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(lot_step > 0)
      lot = MathFloor(lot / lot_step) * lot_step;
      
   int digits = 2;
   if(lot_step == 0.1) digits = 1;
   else if(lot_step == 1.0) digits = 0;
   
   lot = NormalizeDouble(lot, digits);

   return MathMax(MathMin(lot, max_lot), min_lot);
}

bool CheckSignals(int &signal)
{
   signal = 0;

   double fastMA[], slowMA[], rsi[], atr[];
   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(handleFastMA, 0, 0, 2, fastMA) <= 0 ||
      CopyBuffer(handleSlowMA, 0, 0, 2, slowMA) <= 0 ||
      CopyBuffer(handleRSI, 0, 0, 1, rsi) <= 0 ||
      CopyBuffer(handleATR, 0, 0, 1, atr) <= 0) return false;

   double close_price = iClose(_Symbol, PERIOD_CURRENT, 0);

   if(fastMA[1] <= slowMA[1] && fastMA[0] > slowMA[0] && rsi[0] > 50) signal = 1;
   if(fastMA[1] >= slowMA[1] && fastMA[0] < slowMA[0] && rsi[0] < 50) signal = -1;

   if(UseDipRip)
   {
      double dip_level = slowMA[0] - atr[0] * DipMultiplier;
      double rip_level = slowMA[0] + atr[0] * RipMultiplier;
      if(close_price <= dip_level && rsi[0] < RSIDip) signal = 1;
      if(close_price >= rip_level && rsi[0] > RSIRip) signal = -1;
   }
   return (signal != 0);
}

void OpenTrade(int signal)
{
   if(TradeOnlyOne && PositionsTotal() > 0) return;
   if(TimeCurrent() - last_trade_time < CooldownMinutes * 60)
   {
      int minutes_left = (int)((CooldownMinutes * 60 - (TimeCurrent() - last_trade_time)) / 60);
      Comment("COOLDOWN: ", IntegerToString(minutes_left), " min left | Step: ", martingale_step);
      return;
   }
   
   double lot = CalculateLotSize(StopLossPips);
   if(lot < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) return;
   
   double sl_distance = StopLossPips * pip_size;
   double tp_distance = TakeProfitPips * pip_size;
   
   if(signal == 1)
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(trade.Buy(lot, _Symbol, price, price - sl_distance, price + tp_distance, "FX_MART_Buy_S" + IntegerToString(martingale_step)))
      {
         last_trade_time = TimeCurrent();
         Print("BUY OPENED - Lot: ", lot, " Step: ", martingale_step);
      }
   }
   else if(signal == -1)
   {
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(trade.Sell(lot, _Symbol, price, price + sl_distance, price - tp_distance, "FX_MART_Sell_S" + IntegerToString(martingale_step)))
      {
         last_trade_time = TimeCurrent();
         Print("SELL OPENED - Lot: ", lot, " Step: ", martingale_step);
      }
   }
}

void ManageTrades()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         
         double current_price = (type == POSITION_TYPE_BUY)? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         
         // Calculate profit distance in pips properly for Forex
         double profit_pips = 0;
         if(type == POSITION_TYPE_BUY) profit_pips = (current_price - open_price) / pip_size;
         else if(type == POSITION_TYPE_SELL) profit_pips = (open_price - current_price) / pip_size;

         // BreakEven Logic
         if(profit_pips >= BreakEven)
         {
            if(type == POSITION_TYPE_BUY && sl < open_price) 
               trade.PositionModify(ticket, open_price, tp);
            else if(type == POSITION_TYPE_SELL && (sl > open_price || sl == 0)) 
               trade.PositionModify(ticket, open_price, tp);
         }

         // Trailing Stop Logic
         if(profit_pips >= TrailStart)
         {
            double new_sl;
            if(type == POSITION_TYPE_BUY)
            { 
               new_sl = current_price - TrailStep * pip_size; 
               if(sl == 0 || new_sl > sl + pip_size) trade.PositionModify(ticket, new_sl, tp);
            }
            else
            { 
               new_sl = current_price + TrailStep * pip_size; 
               if(sl == 0 || new_sl < sl - pip_size) trade.PositionModify(ticket, new_sl, tp);
            }
         }
      }
   }
}

void OnTick()
{
   if(!EquityProtector()) { Comment("BOT HALTED BY PROTECTION"); return; }
   if(!CheckTradingHours()) { Comment("Outside Trading Hours"); return; }
   if(IsNewsTime()) { Comment("News Time - Trading Paused"); return; }
   if(!CheckSpread()) return;
   if(!IsMarketTrending()) return;
   
   ManageTrades();
   
   int signal;
   if(CheckSignals(signal)) OpenTrade(signal);
}
//+------------------------------------------------------------------+
