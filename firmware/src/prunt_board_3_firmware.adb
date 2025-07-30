with STM32.Device;  use STM32.Device;
with STM32.GPIO;    use STM32.GPIO;
with Server_Communication;
with Step_Generator;
with Steppers;
with Input_Switches;
with Thermistors;
with Heaters;
with Fans;
with Ada.Real_Time; use Ada.Real_Time;
with System;
with Self_Check;
with MCU_Temperature;
with Current_Sense;
with System.Machine_Reset;
with Kalico_Reboot;
with STM32.Flash;

with Last_Chance_Handler;
pragma Unreferenced (Last_Chance_Handler);
--  The "last chance handler" is the user-defined routine that is called when an exception is propagated. We need it in
--  the executable, therefore it must be somewhere in the closure of the context clauses.

procedure Prunt_Board_3_Firmware is
   pragma Priority (System.Priority'First);
   --  DMA uses polling, so this task has to have a low priority. Even without polling it still makes sense to use a
   --  low priority here so communication will time out in the case that the MCU is overloaded.
   --
   --  TODO: Use interrupts instead of polling.
begin
   Enable_Clock (GPIO_A);
   Enable_Clock (GPIO_B);
   Enable_Clock (GPIO_C);
   Enable_Clock (GPIO_D);
   Enable_Clock (GPIO_F);
   Enable_Clock (GPIO_G);

   Heaters.Make_Safe;

   --  Always start server communication first so exceptions can be reported.
   Server_Communication.Init;

   if not STM32.Flash.Is_PG10_GPIO (Flash) then
      STM32.Flash.Unlock (Flash);
      STM32.Flash.Set_PG10_GPIO_And_Reset (Flash);
   end if;

   --  BOOT0.
   Configure_IO (PB8, (Mode => Mode_In, Resistors => Pull_Down));

   --  Kalico reboot.
   Configure_IO (PG10, (Mode => Mode_In, Resistors => Pull_Up));
   delay until Clock + Milliseconds (300);
   if not Set (PG10) then
      if not Self_Check.Current_Bank_Is_Valid then
         --  We do not have a way to warn the user that the integrity check has failed since they are expecting Kalico
         --  to start. The best we can do here is to keep resetting until the user removes the jumper and runs Prunt.
         System.Machine_Reset.Stop;
      end if;

      --  This persists even after the jumper is removed as long as the board is still powered.
      Kalico_Reboot.Reboot_To_Kalico;
   end if;

   if not Self_Check.Current_Bank_Is_Valid then
      raise Constraint_Error with "Integrity check failed. Manual flashing is required.";
   end if;

   Heaters.Make_Safe;
   Fans.Init;
   Input_Switches.Init;
   Steppers.Init;
   Step_Generator.Init;

   delay until Clock + Seconds (1); --  Ensure voltages have time to come up before ADC calibration.

   Thermistors.Init;
   MCU_Temperature.Init;

   Server_Communication.Run;

end Prunt_Board_3_Firmware;
