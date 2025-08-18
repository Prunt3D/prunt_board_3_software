with HAL.GPIO;
with STM32.GPIO;     use STM32.GPIO;
with HAL;            use HAL;
with STM32.Device;   use STM32.Device;
with STM32.Timers;   use STM32.Timers;
with STM32.LPTimers; use STM32.LPTimers;
with STM32.SYSCFG;

package body Fans is

   procedure Init is
   begin
      Init_Checker.Report_Init_Started;
      Fan_Handlers.Init;
      Init_Checker.Report_Init_Done;
   end Init;

   procedure Reconfigure (Fan : Fan_Name; PWM_Frequency : Fixed_Point_Fan_PWM_Frequency; Use_High_Side : Boolean) is
   begin
      Init_Checker.Raise_If_Init_Not_Done;
      Fan_Handlers.Reconfigure (Fan, PWM_Frequency, Use_High_Side);
   end Reconfigure;

   procedure Set_PWM (Fan : Fan_Name; Scale : Fixed_Point_PWM_Scale) is
   begin
      Init_Checker.Raise_If_Init_Not_Done;
      Fan_Handlers.Set_PWM (Fan, Scale);
   end Set_PWM;

   function Get_PWM (Fan : Fan_Name) return PWM_Scale is
   begin
      Init_Checker.Raise_If_Init_Not_Done;
      return Fan_Handlers.Get_PWM (Fan);
   end Get_PWM;

   function Get_Tach_Counter (Fan : Fan_Name) return Tach_Counter is
   begin
      Init_Checker.Raise_If_Init_Not_Done;
      return Fan_Handlers.Get_Tach_Counter (Fan);
   end Get_Tach_Counter;

   procedure Update_Software_Fan_Counters is
   begin
      for F in Fan_Name loop
         if Tach_Configs (F).Kind = In_Step_Generator_Loop_Kind then
            --  declare
            --     State : constant Comparator_Output := Get_Comparator_Output (Tach_Configs (F).Comp.all);
            --  begin
            --     if Software_Fan_Counters_Last_States (F) /= State then
            --        if State = High then
            --           Software_Fan_Counters (F) := @ + 1;
            --        end if;
            --     end if;
            --     Software_Fan_Counters_Last_States (F) := State;
            --  end;
            declare
               State : constant Boolean := Set (Tach_Configs (F).Point);
            begin
               if Software_Fan_Counters_Last_States (F) /= State then
                  if State = True then
                     Software_Fan_Counters (F) := @ + 1;
                  end if;
               end if;
               Software_Fan_Counters_Last_States (F) := State;
            end;
         end if;
      end loop;
   end Update_Software_Fan_Counters;

   protected body Fan_Handlers is
      procedure Init is
         procedure Init_PWM_Timer
           (Tim : in out Timer; Channel : Timer_Channel; Polarity : Timer_Output_Compare_Polarity) is
         begin
            Enable_Clock (Tim);
            Disable (Tim); --  The same timer may be used for multiple channels.
            if Advanced_Timer (Tim) then
               Enable_Main_Output (Tim);
            end if;
            Configure (This => Tim, Prescaler => 74, Period => 60_000); --  33.33 Hz
            Configure_Channel_Output
              (This => Tim, Channel => Channel, Mode => PWM1, State => Enable, Pulse => 0, Polarity => Polarity);
            Set_Autoreload_Preload (Tim, True);
            Set_Output_Preload_Enable (This => Tim, Channel => Channel, Enabled => True);
            Enable (Tim);
         end Init_PWM_Timer;

         function GPIO_To_NonInverting_Input_Port (Point : GPIO_Point) return NonInverting_Input_Port is
         begin
            if Point = PA1
              or else Point = PA7
              or else Point = PA0
              or else Point = PB0
              or else Point = PB13
              or else Point = PB11
              or else Point = PB14
            then
               return Option_1;
            elsif Point = PB1
              or else Point = PA3
              or else Point = PC1
              or else Point = PE7
              or else Point = PD12
              or else Point = PD11
              or else Point = PD14
            then
               return Option_2;
            else
               raise Constraint_Error with "GPIO point not connected to non-inverting comparator input.";
            end if;
         end GPIO_To_NonInverting_Input_Port;

         procedure Init_Tach (Config : Tach_Config) is
         begin
            Configure_IO (Config.Point, (Mode_In, Floating));
            --  TODO: Remove when we get comparators working.
            return;

            Configure_IO (Config.Point, (Mode_Analog, Floating));
            Configure_Comparator
              (Config.Comp.all,
               (Input_Minus     => Vrefint,
                Input_Plus      => GPIO_To_NonInverting_Input_Port (Config.Point),
                Hysteresis      => Fifty_mV,
                Blanking_Source => No_Blanking,
                Output_Pol      => Not_Inverted));
            Enable (Config.Comp.all);

            case Config.Kind is
               when Timer_Kind =>
                  Enable_Clock (Config.Tim.all);
                  Set_External_Trigger_Source (Config.Tim.all, Config.Trigger);
                  Configure_External_Clock_Mode1 (Config.Tim.all, NonInverted, Off, No_Filter);
                  Enable (Config.Tim.all);

               when LPTimer_Kind =>
                  Enable_Clock (Config.LPTim.all);
                  Select_Clock_Source (Config.LPTim.all, Internal);
                  Configure_Input_Clock (Config.LPTim.all, Input_2, (Internal => True, Value => Config.Clock));
                  Set_Counter_Clock_Source (Config.LPTim.all, External);
                  Configure_External_Clock (Config.LPTim.all, Rising_Edge, Any_Level_Change);
                  Enable (Config.LPTim.all);
                  Set_Autoreload_Value (Config.LPTim.all, UInt16'Last);
                  Select_Pulse_Mode (Config.LPTim.all, Repetitive);

               when In_Step_Generator_Loop_Kind =>
                  null;
            end case;
         end Init_Tach;
      begin
         STM32.SYSCFG.Enable_SYSCFG_Clock;
         --  For comparators.

         for Fan in Fan_Name loop
            Init_PWM_Timer (Fan_Timers (Fan).all, Fan_Timer_LS_Channels (Fan), Low);
            Init_PWM_Timer (Fan_Timers (Fan).all, Fan_Timer_HS_Channels (Fan), High);

            declare
               Points : GPIO_Points := (Fan_LS_GPIO_Points (Fan), Fan_HS_GPIO_Points (Fan));
            begin
               Set (Points);
            end;

            Configure_IO
              (Fan_LS_GPIO_Points (Fan),
               (Mode => Mode_Out, Resistors => Floating, Output_Type => Push_Pull, Speed => Speed_25MHz));
            Configure_IO
              (Fan_HS_GPIO_Points (Fan),
               (Mode => Mode_Out, Resistors => Floating, Output_Type => Push_Pull, Speed => Speed_25MHz));

            Init_Tach (Tach_Configs (Fan));
         end loop;
      end Init;

      procedure Reconfigure (Fan : Fan_Name; PWM_Frequency : Fixed_Point_Fan_PWM_Frequency; Use_High_Side : Boolean) is
         Prescaler : UInt32;
         Period    : UInt32;
      begin
         declare
            Points : GPIO_Points := (Fan_LS_GPIO_Points (Fan), Fan_HS_GPIO_Points (Fan));
         begin
            Set (Points);
         end;

         Configure_IO
           (Fan_LS_GPIO_Points (Fan),
            (Mode => Mode_Out, Resistors => Floating, Output_Type => Push_Pull, Speed => Speed_25MHz));
         Configure_IO
           (Fan_HS_GPIO_Points (Fan),
            (Mode => Mode_Out, Resistors => Floating, Output_Type => Push_Pull, Speed => Speed_25MHz));

         Compute_Prescaler_And_Period
           (This                => Fan_Timers (Fan),
            Requested_Frequency => UInt32 (PWM_Frequency),
            Prescaler           => Prescaler,
            Period              => Period);
         Disable_Channel (Fan_Timers (Fan).all, Fan_Timer_LS_Channels (Fan));
         Disable_Channel (Fan_Timers (Fan).all, Fan_Timer_HS_Channels (Fan));
         Disable (Fan_Timers (Fan).all);
         Configure (This => Fan_Timers (Fan).all, Prescaler => UInt16 (Prescaler), Period => Period);
         Enable (Fan_Timers (Fan).all);
         Set_PWM (Fan, Last_PWMs (Fan));

         if Use_High_Side then
            Enable_Channel (Fan_Timers (Fan).all, Fan_Timer_HS_Channels (Fan));
            Configure_IO
              (Fan_HS_GPIO_Points (Fan),
               (Mode           => Mode_AF,
                Resistors      => Floating,
                AF_Output_Type => Push_Pull,
                AF_Speed       => Speed_25MHz,
                AF             => Fan_HS_GPIO_AFs (Fan)));
         else
            Enable_Channel (Fan_Timers (Fan).all, Fan_Timer_LS_Channels (Fan));
            Configure_IO
              (Fan_LS_GPIO_Points (Fan),
               (Mode           => Mode_AF,
                Resistors      => Floating,
                AF_Output_Type => Push_Pull,
                AF_Speed       => Speed_25MHz,
                AF             => Fan_LS_GPIO_AFs (Fan)));

            declare
               Point : GPIO_Point := Fan_HS_GPIO_Points (Fan);
            begin
               Set (Point);
            end;
         end if;
      end Reconfigure;

      procedure Set_PWM (Fan : Fan_Name; Scale : Fixed_Point_PWM_Scale) is
      begin
         if Has_32bit_CC_Values ((Fan_Timers (Fan).all)) then
            Set_Compare_Value
              (Fan_Timers (Fan).all,
               Fan_Timer_LS_Channels (Fan),
               UInt32 (Float (Scale) * Float (Current_Autoreload (Fan_Timers (Fan).all))));
            Set_Compare_Value
              (Fan_Timers (Fan).all,
               Fan_Timer_HS_Channels (Fan),
               UInt32 (Float (Scale) * Float (Current_Autoreload (Fan_Timers (Fan).all))));
         else
            Set_Compare_Value
              (Fan_Timers (Fan).all,
               Fan_Timer_LS_Channels (Fan),
               UInt16 (Float (Scale) * Float (Current_Autoreload (Fan_Timers (Fan).all))));
            Set_Compare_Value
              (Fan_Timers (Fan).all,
               Fan_Timer_HS_Channels (Fan),
               UInt16 (Float (Scale) * Float (Current_Autoreload (Fan_Timers (Fan).all))));
         end if;

         Last_PWMs (Fan) := Scale;
      end Set_PWM;

      function Get_PWM (Fan : Fan_Name) return PWM_Scale is
      begin
         return PWM_Scale (Last_PWMs (Fan));
      end Get_PWM;

      function Get_Tach_Counter (Fan : Fan_Name) return Tach_Counter is
      begin
         case Tach_Configs (Fan).Kind is
            when Timer_Kind =>
               return Tach_Counter (Current_Counter (Tach_Configs (Fan).Tim.all) mod 2**16);

            when LPTimer_Kind =>
               return Tach_Counter (Current_Counter (Tach_Configs (Fan).LPTim.all));

            when In_Step_Generator_Loop_Kind =>
               return Tach_Counter (Software_Fan_Counters (Fan) mod 2**16);
         end case;
      end Get_Tach_Counter;
   end Fan_Handlers;

end Fans;
