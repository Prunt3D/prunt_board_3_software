private with Ada.Interrupts.Names;
private with HAL;
with STM32.HRTimers;         use STM32.HRTimers;
with STM32.Device;           use STM32.Device;
with Messages;               use Messages;
with Hardware_Configuration; use Hardware_Configuration;
with Init_Checkers;

package Step_Generator is

   procedure Init;

   procedure Enqueue (Steps : Step_Delta);
   procedure Setup_Loop (Input_Switch : Input_Switch_Name; Until_State : Input_Switch_State);
   procedure Enqueue_Start_Loop;
   procedure Enqueue_Stop_Loop;
   function Check_If_Idle return Boolean;
   procedure Force_Start;
   function Loop_Enqueued return Boolean;
   function Enqueue_Would_Block (Number_Of_Steps : Step_Delta_List_Index) return Boolean;

   function Get_And_Reset_Loop_Counter return Loop_Iteration_Count;
   --  Returns the number of iterations taken to complete the last loop move. This is the number of timer reloads, not
   --  the number of complete loops. Zero is a sentinel value to indicate that the loop move is still running as a loop
   --  move always runs for at least one timer reload.
   --
   --  This function must be called and a valid value must be read for each loop before another loop start can be
   --  enqueued. After this function is called and a valid value is read it may not be called again until another loop
   --  stop is enqueued.
   --
   --  Will raise a Constraint_Error if there is no loop running or enqueued.

   Empty_Buffer_Error : exception;

private

   Init_Checker : Init_Checkers.Init_Checker;

   use HAL;

   type Step_Delta_Buffer_Index is mod 2**13;

   type Step_Delta_Buffer_Type is array (Step_Delta_Buffer_Index) of Step_Delta with
     Volatile_Components, Pack;

   Step_Delta_Buffer : Step_Delta_Buffer_Type with
     Volatile;

   Step_Delta_Buffer_Writer_Index : Step_Delta_Buffer_Index := 0 with
     Volatile, Atomic;
   Step_Delta_Buffer_Reader_Index : Step_Delta_Buffer_Index := 0 with
     Volatile, Atomic;

   Step_Delta_Buffer_Loop_Start_Index : Step_Delta_Buffer_Index := 0 with
     Volatile, Atomic;
   Step_Delta_Buffer_Loop_End_Index   : Step_Delta_Buffer_Index := 0 with
     Volatile, Atomic;

   Step_Delta_Buffer_Loop_Enabled : Boolean := False with
     Volatile, Atomic;

   Loop_Until_State  : Input_Switch_State with
     Volatile;
   Loop_Input_Switch : Input_Switch_Name with
     Volatile;

   Is_Idle : Boolean := True with
     Volatile, Atomic;

   Buffer_Ran_Dry : Boolean := False with
     Volatile, Atomic;

   Loop_Iterations : Loop_Iteration_Count := 0 with
     Volatile, Atomic;

   type Step_Period_Parameters is record
      Period : UInt16;
      Toggle : UInt16;
   end record;

   protected Timer_Reload_Handler is
      pragma Interrupt_Priority (Step_Generator_Interrupt_Priority);
   private
      procedure Master_Update_Handler with
        Attach_Handler => Ada.Interrupts.Names.HRTIM_Master_IRQn_Interrupt;
   end Timer_Reload_Handler;

   HRTim_Map : constant array (Stepper_Name) of access HRTimer_Channel :=
     (Stepper_1 => STM32.Device.HRTimer_B'Access,
      Stepper_2 => STM32.Device.HRTimer_A'Access,
      Stepper_3 => STM32.Device.HRTimer_E'Access,
      Stepper_4 => STM32.Device.HRTimer_C'Access,
      Stepper_5 => STM32.Device.HRTimer_F'Access,
      Stepper_6 => STM32.Device.HRTimer_D'Access);

   Step_Count_To_Period : constant array (Step_Count) of UInt16 :=
     (0 => 0, for I in 1 .. Step_Count'Last => 60_000 / UInt16 (I));

end Step_Generator;
