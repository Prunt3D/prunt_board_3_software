-----------------------------------------------------------------------------
--                                                                         --
--                   Part of the Prunt Motion Controller                   --
--                                                                         --
--            Copyright (C) 2024 Liam Powell (liam@prunt3d.com)            --
--                                                                         --
--  This program is free software: you can redistribute it and/or modify   --
--  it under the terms of the GNU General Public License as published by   --
--  the Free Software Foundation, either version 3 of the License, or      --
--  (at your option) any later version.                                    --
--                                                                         --
--  This program is distributed in the hope that it will be useful,        --
--  but WITHOUT ANY WARRANTY; without even the implied warranty of         --
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the          --
--  GNU General Public License for more details.                           --
--                                                                         --
--  You should have received a copy of the GNU General Public License      --
--  along with this program.  If not, see <http://www.gnu.org/licenses/>.  --
--                                                                         --
-----------------------------------------------------------------------------

with Prunt;                use Prunt;
with Messages;             use Messages;
with Ada.Command_Line;     use Ada.Command_Line;
with Prunt.Thermistors;    use Prunt.Thermistors;
with Prunt.Controller;
with Ada.Text_IO;
with Ada.Exceptions;
with GNAT.OS_Lib;
with Prunt.Controller_Generic_Types;
with Communications;
with GNAT.Serial_Communications;
with Prunt.TMC_Types.TMC2240;
with Ada.Containers.Generic_Constrained_Array_Sort;
with System.Multiprocessors;
with Ada.Strings.Unbounded;
with Embedded_Resources;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with Interfaces.C;         use Interfaces.C;
with Udev;                 use Udev;

use type Prunt.TMC_Types.TMC2240.UART_Node_Address;

procedure Prunt_Board_3_Server is
   C_String_usb          : chars_ptr := New_String ("usb");
   C_String_usb_device   : chars_ptr := New_String ("usb_device");
   C_String_tty          : chars_ptr := New_String ("tty");
   C_String_idVendor     : chars_ptr := New_String ("idVendor");
   C_String_idProduct    : chars_ptr := New_String ("idProduct");
   C_String_manufacturer : chars_ptr := New_String ("manufacturer");
   C_String_product      : chars_ptr := New_String ("product");
   C_String_serial       : chars_ptr := New_String ("serial");

   procedure Log (Message : String);

   function Find_Port_Name return String is
      My_Udev : access Udev.Udev := Udev_New;
   begin
      if My_Udev = null then
         raise Constraint_Error;
      end if;

      declare
         My_Enumerate : access Udev_Enumerate := Udev_Enumerate_New (My_Udev);
      begin
         if My_Enumerate = null then
            raise Constraint_Error;
         end if;

         if Udev_Enumerate_Add_Match_Subsystem (My_Enumerate, C_String_tty) < 0 then
            raise Constraint_Error;
         end if;
         if Udev_Enumerate_Scan_Devices (My_Enumerate) < 0 then
            raise Constraint_Error;
         end if;

         declare
            Device_Entry : access Udev_List_Entry := Udev_Enumerate_Get_List_Entry (My_Enumerate);
         begin
            while Device_Entry /= null loop
               declare
                  Path : chars_ptr := Udev_List_Entry_Get_Name (Device_Entry);
               begin
                  if Path = Null_Ptr then
                     raise Constraint_Error;
                  end if;
                  declare
                     TTY_Device : access Udev_Device := Udev_Device_New_From_Syspath (My_Udev, Path);
                  begin
                     if TTY_Device = null then
                        raise Constraint_Error;
                     end if;
                     declare
                        USB_Device : constant access Udev_Device :=
                          Udev_Device_Get_Parent_With_Subsystem_Devtype
                            (TTY_Device, C_String_usb, C_String_usb_device);
                     begin
                        if USB_Device /= null then
                           declare
                              VID          : constant chars_ptr :=
                                Udev_Device_Get_Sysattr_Value (USB_Device, C_String_idVendor);
                              PID          : constant chars_ptr :=
                                Udev_Device_Get_Sysattr_Value (USB_Device, C_String_idProduct);
                              Manufacturer : constant chars_ptr :=
                                Udev_Device_Get_Sysattr_Value (USB_Device, C_String_manufacturer);
                              Product      : constant chars_ptr :=
                                Udev_Device_Get_Sysattr_Value (USB_Device, C_String_product);
                              Serial       : constant chars_ptr :=
                                Udev_Device_Get_Sysattr_Value (USB_Device, C_String_serial);
                           begin
                              if String'(Value (VID)) = "0483"
                                and then String'(Value (PID)) in "a4f6" | "a53b"
                                and then String'(Value (Manufacturer)) = "Prunt 3D"
                                and then String'(Value (Product)) = "Prunt Board 3"
                              then
                                 if Serial = Null_Ptr then
                                    raise Constraint_Error with "Board serial number is missing.";
                                 end if;

                                 Log ("Board serial number: " & Value (Serial));

                                 declare
                                    Return_Value : constant String := Value (Path);
                                    Split_Point  : Positive := Return_Value'First;
                                 begin
                                    for I in Return_Value'Range loop
                                       if Return_Value (I) = '/' then
                                          Split_Point := I + 1;
                                       end if;
                                    end loop;

                                    TTY_Device := Udev_Device_Unref (TTY_Device);
                                    My_Enumerate := Udev_Enumerate_Unref (My_Enumerate);
                                    My_Udev := Udev_Unref (My_Udev);

                                    return "/dev/" & Return_Value (Split_Point .. Return_Value'Last);
                                 end;
                              end if;
                           end;
                        end if;
                     end;
                     TTY_Device := Udev_Device_Unref (TTY_Device);
                  end;
               end;

               Device_Entry := Udev_List_Entry_Get_Next (Device_Entry);
            end loop;
            My_Enumerate := Udev_Enumerate_Unref (My_Enumerate);
         end;
         My_Udev := Udev_Unref (My_Udev);
         return "";
      end;

   end Find_Port_Name;

   Loop_Move_Multiplier : constant := 1024;

   function Argument_Value (Switch, Default : String) return String is
   begin
      --  The last argument takes priority in case of duplicates.
      for Arg in reverse 1 .. Argument_Count loop
         if Argument (Arg)'Length > Switch'Length
           and then Argument (Arg) (Argument (Arg)'First .. Argument (Arg)'First + Switch'Length - 1) = Switch
         then
            return Argument (Arg) (Argument (Arg)'First + Switch'Length .. Argument (Arg)'Last);
         end if;
      end loop;
      return Default;
   end Argument_Value;

   type Board_Temperature_Probe_Name is (Main_MCU);

   type Empty_Enum is new Boolean range True .. False;

   package My_Controller_Generic_Types is new
     Prunt.Controller_Generic_Types
       (Stepper_Name                 => Stepper_Name,
        Heater_Name                  => Heater_Name,
        Thermistor_Name              => Thermistor_Name,
        Board_Temperature_Probe_Name => Board_Temperature_Probe_Name,
        Fan_Name                     => Fan_Name,
        Input_Switch_Name            => Input_Switch_Name,
        Laser_Name                   => Empty_Enum);

   use My_Controller_Generic_Types;

   function "-" (Left, Right : Stepper_Position) return Stepper_Position is
   begin
      return (for I in Stepper_Name => Left (I) - Right (I));
   end "-";

   function "+" (Left, Right : Stepper_Position) return Stepper_Position is
   begin
      return (for I in Stepper_Name => Left (I) + Right (I));
   end "+";

   function "*" (Left : Stepper_Position; Right : Dimensionless) return Stepper_Position is
   begin
      return (for I in Stepper_Name => Left (I) * Right);
   end "*";

   function Rounding (Left : Stepper_Position) return Stepper_Position is
   begin
      return (for I in Stepper_Name => Dimensionless'Rounding (Left (I)));
   end Rounding;

   procedure Report_Error (Occurrence : Ada.Exceptions.Exception_Occurrence; Is_Fatal : Boolean := True);

   procedure Report_Temperature (Thermistor : Thermistor_Name; Temp : Fixed_Point_Celsius);

   procedure Report_MCU_Temperature (Temp : Fixed_Point_Celsius);

   procedure Report_Heater_Power (Heater : Heater_Name; Power : Fixed_Point_PWM_Scale);

   procedure Report_Heater_Current (Heater : Messages.Heater_Name; Curr : Fixed_Point_Internal_Heater_Current);

   procedure Report_Input_Switch_State (Switch : Messages.Input_Switch_Name; State : Messages.Input_Switch_State);

   procedure Report_Tachometer_Frequency (Fan : Messages.Fan_Name; Freq : Prunt.Frequency);

   procedure Prompt_For_Update;

   pragma Warnings (Off, "cannot call * before body seen");
   package My_Communications is new
     Communications
       (Report_Error                => Report_Error,
        Report_Temperature          => Report_Temperature,
        Report_MCU_Temperature      => Report_MCU_Temperature,
        Report_Heater_Power         => Report_Heater_Power,
        Report_Heater_Current       => Report_Heater_Current,
        Report_Input_Switch_State   => Report_Input_Switch_State,
        Report_Tachometer_Frequency => Report_Tachometer_Frequency,
        Prompt_For_Update           => Prompt_For_Update,
        Log                         => Log,
        Runner_CPU                  =>
          System.Multiprocessors.CPU_Range'Value (Argument_Value ("--communications-cpu=", "0")));
   pragma Warnings (On, "cannot call * before body seen");

   function Sort_Curve_By_Resistance_Comparator (Left, Right : Thermistor_Point) return Boolean is
   begin
      return Left.Value < Right.Value;
   end Sort_Curve_By_Resistance_Comparator;

   procedure Sort_Curve_By_Resistance is new
     Ada.Containers.Generic_Constrained_Array_Sort
       (Thermistor_Curve_Index,
        Thermistor_Point,
        Thermistor_Curve,
        Sort_Curve_By_Resistance_Comparator);

   procedure Setup
     (Heater_Thermistors : My_Controller_Generic_Types.Heater_Thermistor_Map;
      Thermistors        : Thermistor_Parameters_Array_Type)
   is
      Message : Message_From_Server_Content :=
        (Kind               => Setup_Kind,
         Index              => <>,
         TMC_Write_Data     => (others => 0),
         TMC_Read_Data      => (others => 0),
         Heater_Thermistors => <>,
         Thermistor_Curves  => <>);
   begin
      for H in Heater_Name loop
         Message.Heater_Thermistors (H) := Heater_Thermistors (H);
      end loop;

      for T in Thermistor_Name loop
         for I in Thermistor_Curve_Index loop
            if Thermistors (T).Kind = Disabled_Kind then
               if I = Thermistor_Curve_Index'First then
                  Message.Thermistor_Curves (T) (I).Value := Fixed_Point_Resistance'First;
               else
                  Message.Thermistor_Curves (T) (I).Value := Fixed_Point_Resistance'Last;
               end if;
               Message.Thermistor_Curves (T) (I).Temp := 0.0;
            else
               declare
                  Temp : constant Temperature :=
                    Thermistors (T).Minimum_Temperature
                    + (Thermistors (T).Maximum_Temperature - Thermistors (T).Minimum_Temperature)
                      / (Dimensionless (Thermistor_Curve_Index'Last) - Dimensionless (Thermistor_Curve_Index'First))
                      * (Dimensionless (I) - Dimensionless (Thermistor_Curve_Index'First));
               begin
                  Message.Thermistor_Curves (T) (I).Value :=
                    Fixed_Point_Resistance (Temperature_To_Resistance (Thermistors (T), Temp) / ohm);
                  Message.Thermistor_Curves (T) (I).Temp := Fixed_Point_Celsius (Temp);
               end;
            end if;
         end loop;

         Sort_Curve_By_Resistance (Message.Thermistor_Curves (T));
      end loop;

      My_Communications.Runner.Send_Message (Message);

      for H in Heater_Name loop
         Message :=
           (Kind           => Heater_Reconfigure_Kind,
            Index          => <>,
            TMC_Write_Data => (others => 0),
            TMC_Read_Data  => (others => 0),
            Heater         => H,
            Heater_Params  =>
              (Kind                       => Disabled_Kind,
               Check_Max_Cumulative_Error => 0.0,
               Check_Gain_Time            => 0.0,
               Check_Minimum_Gain         => 0.0,
               Check_Hysteresis           => 0.0));
         My_Communications.Runner.Send_Message (Message);
      end loop;
   end Setup;

   procedure Reconfigure_Heater (Heater : Heater_Name; Params : Prunt.Heater_Parameters) is
      Message : Message_From_Server_Content :=
        (Kind           => Heater_Reconfigure_Kind,
         Index          => <>,
         TMC_Write_Data => (others => 0),
         TMC_Read_Data  => (others => 0),
         Heater         => Heater,
         Heater_Params  => <>);
   begin
      case Params.Kind is
         when Disabled_Kind =>
            Message.Heater_Params :=
              (Kind                       => Disabled_Kind,
               Check_Max_Cumulative_Error => Fixed_Point_Celsius (Params.Check_Max_Cumulative_Error),
               Check_Gain_Time            => Fixed_Point_Seconds (Params.Check_Gain_Time),
               Check_Minimum_Gain         => Fixed_Point_Celsius (Params.Check_Minimum_Gain),
               Check_Hysteresis           => Fixed_Point_Celsius (Params.Check_Hysteresis));

         when PID_Kind =>
            Message.Heater_Params :=
              (Kind                       => PID_Kind,
               Check_Max_Cumulative_Error => Fixed_Point_Celsius (Params.Check_Max_Cumulative_Error),
               Check_Gain_Time            => Fixed_Point_Seconds (Params.Check_Gain_Time),
               Check_Minimum_Gain         => Fixed_Point_Celsius (Params.Check_Minimum_Gain),
               Check_Hysteresis           => Fixed_Point_Celsius (Params.Check_Hysteresis),
               Proportional_Scale         => Fixed_Point_PID_Parameter (Params.Proportional_Scale),
               Integral_Scale             => Fixed_Point_PID_Parameter (Params.Integral_Scale),
               Derivative_Scale           => Fixed_Point_PID_Parameter (Params.Derivative_Scale));

         when Bang_Bang_Kind =>
            Message.Heater_Params :=
              (Kind                       => Bang_Bang_Kind,
               Check_Max_Cumulative_Error => Fixed_Point_Celsius (Params.Check_Max_Cumulative_Error),
               Check_Gain_Time            => Fixed_Point_Seconds (Params.Check_Gain_Time),
               Check_Minimum_Gain         => Fixed_Point_Celsius (Params.Check_Minimum_Gain),
               Check_Hysteresis           => Fixed_Point_Celsius (Params.Check_Hysteresis),
               Bang_Bang_Hysteresis       => Fixed_Point_Celsius (Params.Bang_Bang_Hysteresis));

         when PID_Autotune_Kind =>
            Message.Heater_Params :=
              (Kind                       => PID_Autotune_Kind,
               Check_Max_Cumulative_Error => Fixed_Point_Celsius (Params.Check_Max_Cumulative_Error),
               Check_Gain_Time            => Fixed_Point_Seconds (Params.Check_Gain_Time),
               Check_Minimum_Gain         => Fixed_Point_Celsius (Params.Check_Minimum_Gain),
               Check_Hysteresis           => Fixed_Point_Celsius (Params.Check_Hysteresis),
               Max_Cycles                 => Messages.PID_Autotune_Cycle_Count (Params.Max_Cycles),
               Proportional_Tuning_Factor => Fixed_Point_PID_Parameter (Params.Proportional_Tuning_Factor),
               Derivative_Tuning_Factor   => Fixed_Point_PID_Parameter (Params.Derivative_Tuning_Factor / hertz),
               PID_Tuning_Temperature     => Fixed_Point_Celsius (Params.PID_Tuning_Temperature));
      end case;

      My_Communications.Runner.Send_Message (Message);
   end Reconfigure_Heater;

   procedure Reconfigure_Fan (Fan : Fan_Name; PWM_Freq : Fan_PWM_Frequency; Use_High_Side_Switching : Boolean) is
   begin
      My_Communications.Runner.Send_Message
        ((Kind                    => Fan_Reconfigure_Kind,
          Index                   => <>,
          TMC_Write_Data          => (others => 0),
          TMC_Read_Data           => (others => 0),
          Fan                     => Fan,
          Fan_PWM_Frequency       => Fixed_Point_Fan_PWM_Frequency (PWM_Freq),
          Use_High_Side_Switching => Byte_Boolean (Use_High_Side_Switching)));
   end Reconfigure_Fan;

   procedure Setup_For_Loop_Move (Switch : Input_Switch_Name; Hit_State : Pin_State) is
   begin
      My_Communications.Runner.Send_Message
        ((Kind              => Loop_Setup_Kind,
          Index             => <>,
          TMC_Write_Data    => (others => 0),
          TMC_Read_Data     => (others => 0),
          Loop_Input_Switch => Switch,
          Loop_Until_State  => (if Hit_State = Low_State then Low else High)));
   end Setup_For_Loop_Move;

   procedure Setup_For_Conditional_Move (Switch : Input_Switch_Name; Hit_State : Pin_State) is
   begin
      My_Communications.Runner.Send_Message
        ((Kind                  => Condition_Check_Kind,
          Index                 => <>,
          TMC_Write_Data        => (others => 0),
          TMC_Read_Data         => (others => 0),
          Conditon_Input_Switch => Switch,
          Skip_If_Hit_State     => (if Hit_State = Low_State then Low else High)));
   end Setup_For_Conditional_Move;

   Last_Enqueued_Command_Index : Command_Index := Command_Index'First
   with Atomic, Volatile;

   Last_Stepper_Position   : Stepper_Position := (others => 0.0);
   Last_Commanded_Position : Stepper_Position := (others => 0.0);

   Step_Delta_Message : aliased Message_From_Server_Content :=
     (Kind            => Regular_Step_Delta_List_Kind,
      Index           => <>,
      TMC_Write_Data  => (others => 0),
      TMC_Read_Data   => (others => 0),
      Last_Index      => Step_Delta_List_Index'First,
      Fan_Targets     => (others => 0.0),
      Heater_Targets  => (others => Fixed_Point_Celsius'First),
      Safe_Stop_After => False,
      Steps           => (others => (Steps => (others => 0), Dirs => (others => Forward))));

   procedure Enqueue_Command (Command : Queued_Command) is
      procedure Send_Message_And_Reset is
      begin
         My_Communications.Runner.Send_Message (Step_Delta_Message);

         Step_Delta_Message :=
           (Kind            => Regular_Step_Delta_List_Kind,
            Index           => <>,
            TMC_Write_Data  => (others => 0),
            TMC_Read_Data   => (others => 0),
            Last_Index      => Step_Delta_List_Index'First,
            Fan_Targets     => (others => 0.0),
            Heater_Targets  => (others => Fixed_Point_Celsius'First),
            Safe_Stop_After => False,
            Steps           => (others => (Steps => (others => 0), Dirs => (others => Forward))));
      end Send_Message_And_Reset;
   begin
      if Command.Loop_Until_Hit then
         if Step_Delta_Message.Last_Index /= Step_Delta_List_Index'First then
            Step_Delta_Message.Last_Index := @ - 1;
            Send_Message_And_Reset;
         end if;

         declare
            Total_Offset : constant Stepper_Position :=
              (Command.Pos - Last_Commanded_Position) * Dimensionless (Loop_Move_Multiplier);
         begin
            for S in Stepper_Name loop
               if abs (Total_Offset (S)) > 0.0 and abs (Total_Offset (S)) < 20.0 then
                  raise Constraint_Error with "Loop move direction vector error potentially greater than 5%.";
               end if;
            end loop;
         end;

         Step_Delta_Message :=
           (Kind            => Looping_Step_Delta_List_Kind,
            Index           => <>,
            TMC_Write_Data  => (others => 0),
            TMC_Read_Data   => (others => 0),
            Last_Index      => Step_Delta_List_Index'First + Loop_Move_Multiplier - 1,
            Fan_Targets     => (others => 0.0),
            Heater_Targets  => (others => Fixed_Point_Celsius'First),
            Safe_Stop_After => False,
            Steps           => (others => (Steps => (others => 0), Dirs => (others => Forward))));

         Step_Delta_Message.Heater_Targets := (for H in Heater_Name => Fixed_Point_Celsius (Command.Heaters (H)));
         Step_Delta_Message.Fan_Targets := (for F in Fan_Name => Fixed_Point_PWM_Scale (Command.Fans (F)));

         declare
            Last_Rounded_Offset : Stepper_Position := (others => 0.0);
         begin
            for I in Step_Delta_List_Index range 1 .. Loop_Move_Multiplier loop
               declare
                  Unrounded_Offset : constant Stepper_Position :=
                    (Command.Pos - Last_Commanded_Position) * Dimensionless (I);
                  Delta_Offset     : constant Stepper_Position := Rounding (Unrounded_Offset - Last_Rounded_Offset);
               begin
                  Last_Rounded_Offset := Rounding (Unrounded_Offset);
                  for X of Delta_Offset loop
                     if abs X > Dimensionless (Step_Count'Last) then
                        raise Constraint_Error with "Step rate too high. Delta_Offset = " & Delta_Offset'Image;
                     end if;
                  end loop;

                  Step_Delta_Message.Steps (Step_Delta_List_Index'First + I - 1).Steps :=
                    (for J in Stepper_Name => Step_Count (abs Delta_Offset (J)));
                  Step_Delta_Message.Steps (Step_Delta_List_Index'First + I - 1).Dirs :=
                    (for J in Stepper_Name => (if Delta_Offset (J) >= 0.0 then Forward else Backward));
               end;
            end loop;
         end;

         Send_Message_And_Reset;

         Last_Stepper_Position := Rounding (Command.Pos);
      --  TODO: Take error between stepper position and commanded position in to account. It is unlikely that this
      --  will ever matter in practice, but it would be nice to have.

      else
         declare
            Offset : constant Stepper_Position := Rounding (Command.Pos - Last_Stepper_Position);
         begin
            for X of Offset loop
               if abs X > Dimensionless (Step_Count'Last) then
                  raise Constraint_Error with "Step rate too high. Offset = " & Offset'Image;
               --  TODO: Add a way to ensure that this will never occur based on the configuration.

               end if;
            end loop;

            Step_Delta_Message.Steps (Step_Delta_Message.Last_Index).Steps :=
              (for I in Stepper_Name => Step_Count (abs Offset (I)));
            Step_Delta_Message.Steps (Step_Delta_Message.Last_Index).Dirs :=
              (for I in Stepper_Name => (if Offset (I) >= 0.0 then Forward else Backward));

            Step_Delta_Message.Heater_Targets := (for H in Heater_Name => Fixed_Point_Celsius (Command.Heaters (H)));
            Step_Delta_Message.Fan_Targets := (for F in Fan_Name => Fixed_Point_PWM_Scale (Command.Fans (F)));

            if Command.Safe_Stop_After then
               Step_Delta_Message.Safe_Stop_After := True;
               Send_Message_And_Reset;
            elsif Step_Delta_Message.Last_Index = Step_Delta_List_Index'Last then
               Send_Message_And_Reset;
            else
               Step_Delta_Message.Last_Index := @ + 1;
            end if;

            Last_Stepper_Position := @ + Offset;
         end;
      end if;

      Last_Commanded_Position := Command.Pos;
      Last_Enqueued_Command_Index := Command.Index;
   end Enqueue_Command;

   procedure Reset_Position (Pos : Stepper_Position) is
   begin
      Last_Commanded_Position := Pos;
      Last_Stepper_Position := Rounding (Pos);
   --  TODO: Take error between stepper position and commanded position in to account. It is unlikely that this will
   --  ever matter in practice, but it would be nice to have.
   end Reset_Position;

   procedure Wait_Until_Idle (Last_Command : Command_Index) is
      Reply : Message_From_Client_Content;
   begin
      loop
         exit when Last_Enqueued_Command_Index >= Last_Command;
      end loop;

      loop
         My_Communications.Runner.Send_Message_And_Wait_For_Reply
           ((Kind => Check_If_Idle_Kind, Index => <>, TMC_Write_Data => (others => 0), TMC_Read_Data => (others => 0)),
            Reply);
         exit when Reply.Condition_Met;
      end loop;
   end Wait_Until_Idle;

   procedure TMC_Write (Message : Prunt.TMC_Types.TMC2240.UART_Data_Byte_Array) is
   begin
      My_Communications.TMC_IO.Write
        ((for I in Messages.TMC2240_UART_Data_Byte_Array'Range => Messages.TMC2240_UART_Byte (Message (9 - I))));
   end TMC_Write;

   procedure TMC_Read
     (Message        : Prunt.TMC_Types.TMC2240.UART_Query_Byte_Array;
      Receive_Failed : out Boolean;
      Reply          : out Prunt.TMC_Types.TMC2240.UART_Data_Byte_Array)
   is
      TMC_Reply : TMC2240_UART_Data_Byte_Array;
   begin
      My_Communications.TMC_IO.Read
        ((for I in Messages.TMC2240_UART_Query_Byte_Array'Range => Messages.TMC2240_UART_Byte (Message (5 - I))),
         TMC_Reply);

      Receive_Failed := TMC_Reply (1) /= 2#00000101#;

      Reply := (for I in Reply'Range => Prunt.TMC_Types.TMC2240.UART_Byte (TMC_Reply (9 - I)));
   end TMC_Read;

   procedure Autotune_Heater (Heater : Heater_Name; Params : Prunt.Heater_Parameters) is
      Reply : Message_From_Client_Content;
   begin
      Reconfigure_Heater (Heater, Params);

      loop
         My_Communications.Runner.Send_Message_And_Wait_For_Reply
           ((Kind            => Check_If_Heater_Autotune_Done_Kind,
             Index           => <>,
             TMC_Write_Data  => (others => 0),
             TMC_Read_Data   => (others => 0),
             Heater_To_Check => Heater),
            Reply);
         exit when Reply.Condition_Met;
      end loop;
   end Autotune_Heater;

   procedure Reset is
   begin
      My_Communications.Runner.Restart;
      My_Communications.Runner.Init (False);
   end Reset;

   function Get_Board_Specific_Documentation (Key : String) return String is
      Stepper_Text    : constant String :=
        "<p>Note that the pinout of this connector does not match the pinout of the connector on many other "
        & "boards, refer to the below image. No damage will occur to the board or motor if the motor is not "
        & "connected correctly, but the motor will not function. Switch off power to the board before plugging "
        & "in or unplugging the motor.</p>";
      Endstop_Text    : constant String :=
        "<p>There is a 1A shared current limit between the 4 endstop inputs. Input pins are connected to the power "
        & "pins via 6.6kohm resistors. Voltages above 5V should not be applied to the input or 5V pins as this "
        & "will increase the voltage to all other endstop pins, the board will not be damaged by this but other "
        & "endstops may be if they are not designed to handle this.</p><p>Note that the pinout of endstop connectors "
        & "varies between different board vendors, refer to the below image and check that your endstops are "
        & "correctly wired for this pinout.</p>";
      Heater_Text     : constant String :=
        "<p>This heater uses low-side switching at 1kHz and has fast over-current protection which triggers at 15A. "
        & "If the over-current protection is triggered then the heater output will not turn back on until power to "
        & "the board has been switched off for 30 seconds.</p>";
      Thermistor_Text : constant String :=
        "<p>This thermistor uses a 2000 ohm pull-up to 3.3V. Most common thermistors, including PT-1000s, may be "
        & "connected directly as this board contains extra circuitry to allow for lower noise readings than other "
        & "boards.</p>";
      Fan_Text        : constant String :=
        "<p>The high side switch on this fan is capable of driving a 2A load at up to 100Hz. The high side switch is "
        & "on by default before the board setup runs or when low side switching is selected, this allows it to be "
        & "used as the power pin when using low side switching.<p></p>The low side switch is capable of driving a "
        & "500mA load at up to 25kHz. This switch may be used for fans that require a high PWM frequency or it "
        & "may be used to drive the PWM pin of a 4 wire fan.<p></p>The tachometer has a 4700 ohm pull-up resistor to "
        & "5V and can tolerate higher voltages so it can be directly connected to the tachometer output of most "
        & "fans. The maximum tachometer input rate is limited by hardware to approximately 1kHz. The tachometer "
        & "should not be used if the low side switch is being used to drive the ground pin of a fan rather than "
        & "the PWM pin as this may cause damage to the fan.</p>";

      function Image (Path : String) return String is
      begin
         return "<p><image src=""extras/images/" & Path & """ style=""max-width: 600px; width:100%;""></p>";
      end Image;
   begin
      if Key = "Steppers$STEPPER_1" then
         return Stepper_Text & Image ("stepper_1.png");
      elsif Key = "Steppers$STEPPER_2" then
         return Stepper_Text & Image ("stepper_2.png");
      elsif Key = "Steppers$STEPPER_3" then
         return Stepper_Text & Image ("stepper_3.png");
      elsif Key = "Steppers$STEPPER_4" then
         return Stepper_Text & Image ("stepper_4.png");
      elsif Key = "Steppers$STEPPER_5" then
         return Stepper_Text & Image ("stepper_5.png");
      elsif Key = "Steppers$STEPPER_6" then
         return Stepper_Text & Image ("stepper_6.png");
      elsif Key = "Input switches$ENDSTOP_1" then
         return Endstop_Text & Image ("endstop_1.png");
      elsif Key = "Input switches$ENDSTOP_2" then
         return Endstop_Text & Image ("endstop_2.png");
      elsif Key = "Input switches$ENDSTOP_3" then
         return Endstop_Text & Image ("endstop_3.png");
      elsif Key = "Input switches$ENDSTOP_4" then
         return Endstop_Text & Image ("endstop_4.png");
      elsif Key = "Heaters$HEATER_1" then
         return Heater_Text & Image ("heater_1.png");
      elsif Key = "Heaters$HEATER_2" then
         return Heater_Text & Image ("heater_2.png");
      elsif Key = "Heaters$HEATER_3" then
         return
           "<p>This heater is designed for controlling an external solid state relay. It outputs a 0V to 5V 1kHz PWM "
           & "signal through a 500 ohm resistor.</p>"
           & Image ("heater_3.png");
      elsif Key = "Thermistors$THERMISTOR_1" then
         return Thermistor_Text & Image ("thermistor_1.png");
      elsif Key = "Thermistors$THERMISTOR_2" then
         return Thermistor_Text & Image ("thermistor_2.png");
      elsif Key = "Thermistors$THERMISTOR_3" then
         return Thermistor_Text & Image ("thermistor_3.png");
      elsif Key = "Thermistors$THERMISTOR_4" then
         return Thermistor_Text & Image ("thermistor_4.png");
      elsif Key = "Fans" then
         return
           "<p>A 1000 ohm pull-up resistor to 5V may be enabled for the low side driver of each fan by installing a "
           & "1.27mm in the vertical position on the header. This is useful for fans with a PWM pin which do not "
           & "contain an internal pull-up, but it should not be used otherwise to avoid damage to fans.<p></p>The "
           & "jumpers have no effect when in the horizontal position and may be stored in this position when they "
           & "are not in use.<p></p>The order of the 4 pairs of vertical pins is the same as the order of the fan "
           & "connectors, with fan 1 being on the left and fan 4 being on the right.</p>"
           & Image ("fan_pull_ups.png");
      elsif Key = "Fans$FAN_1" then
         return Fan_Text & Image ("fan_1.png");
      elsif Key = "Fans$FAN_2" then
         return Fan_Text & Image ("fan_2.png");
      elsif Key = "Fans$FAN_3" then
         return Fan_Text & Image ("fan_3.png");
      elsif Key = "Fans$FAN_4" then
         return Fan_Text & Image ("fan_4.png");
      else
         return "";
      end if;
   end Get_Board_Specific_Documentation;

   Stepper_UART_Address : constant array (Stepper_Name) of Prunt.TMC_Types.TMC2240.UART_Node_Address :=
     (Stepper_1 => 6, Stepper_2 => 4, Stepper_3 => 3, Stepper_4 => 2, Stepper_5 => 5, Stepper_6 => 1);

   Fan_Maximum_Low_Side_Frequency  : constant Frequency := 25_000.0 * hertz;
   Fan_Maximum_High_Side_Frequency : constant Frequency := 100.0 * hertz;

   package My_Controller is new
     Prunt.Controller
       (Generic_Types                    => My_Controller_Generic_Types,
        Stepper_Hardware                 =>
          (for S in Messages.Stepper_Name =>
             (Kind                      => TMC2240_UART_Kind,
              Maximum_Delta_Per_Command => Dimensionless (Step_Count'Last),
              Double_Edge_Stepping      => True,
              TMC2240_Diag_0            => Messages.Stepper_Diag_0,
              TMC2240_UART_Address      => Stepper_UART_Address (S),
              TMC2240_UART_Write        => TMC_Write'Access,
              TMC2240_UART_Read         => TMC_Read'Access)),
        Fan_Hardware                     =>
          (for F in Messages.Fan_Name =>
             (Kind                                       => Low_Or_High_Side_Switching_Kind,
              Reconfigure_Low_Or_High_Side_Switching_Fan => Reconfigure_Fan'Access,
              Maximum_Low_Side_PWM_Frequency             => Fan_Maximum_Low_Side_Frequency,
              Maximum_High_Side_PWM_Frequency            => Fan_Maximum_High_Side_Frequency)),
        Interpolation_Time               => 60_000.0 / 600_000_000.0 * s,
        Loop_Interpolation_Time          => 60_000.0 / 600_000_000.0 * s,
        Setup                            => Setup,
        Reconfigure_Heater               => Reconfigure_Heater,
        Autotune_Heater                  => Autotune_Heater,
        Setup_For_Loop_Move              => Setup_For_Loop_Move,
        Setup_For_Conditional_Move       => Setup_For_Conditional_Move,
        Enqueue_Command                  => Enqueue_Command,
        Reset_Position                   => Reset_Position,
        Wait_Until_Idle                  => Wait_Until_Idle,
        Reset                            => Reset,
        Config_Path                      => "./prunt_board_3.json",
        Get_Extra_HTTP_Content           => Embedded_Resources.Get_Content,
        Get_Board_Specific_Documentation => Get_Board_Specific_Documentation,
        Update_Check                     =>
          (Method       => Github,
           Repository   => Ada.Strings.Unbounded.To_Unbounded_String ("prunt3d/prunt_board_3_software"),
           Expected_Tag => Ada.Strings.Unbounded.To_Unbounded_String ("v1.7.1")),
        Input_Switch_Visible_To_User     => (Stepper_Diag_0 => False, others => True));

   procedure Report_Error (Occurrence : Ada.Exceptions.Exception_Occurrence; Is_Fatal : Boolean := True) is
   begin
      My_Controller.Report_External_Error (Occurrence, Is_Fatal);
   end Report_Error;

   procedure Report_Temperature (Thermistor : Messages.Thermistor_Name; Temp : Fixed_Point_Celsius) is
   begin
      My_Controller.Report_Temperature (Thermistor, Temperature (Temp));
   end Report_Temperature;

   procedure Report_MCU_Temperature (Temp : Fixed_Point_Celsius) is
   begin
      My_Controller.Report_Temperature (Main_MCU, Temperature (Temp));
   end Report_MCU_Temperature;

   procedure Report_Heater_Power (Heater : Messages.Heater_Name; Power : Fixed_Point_PWM_Scale) is
   begin
      My_Controller.Report_Heater_Power (Heater, PWM_Scale (Power));
   end Report_Heater_Power;

   procedure Report_Heater_Current (Heater : Messages.Heater_Name; Curr : Fixed_Point_Internal_Heater_Current) is
   begin
      My_Controller.Report_Heater_Current (Heater, Current (Curr));
   end Report_Heater_Current;

   procedure Report_Input_Switch_State (Switch : Messages.Input_Switch_Name; State : Messages.Input_Switch_State) is
   begin
      My_Controller.Report_Input_Switch_State (Switch, (if State = High then High_State else Low_State));
   end Report_Input_Switch_State;

   procedure Report_Tachometer_Frequency (Fan : Messages.Fan_Name; Freq : Prunt.Frequency) is
   begin
      My_Controller.Report_Tachometer_Frequency (Fan, Freq);
   end Report_Tachometer_Frequency;

   procedure Prompt_For_Update is
   begin
      My_Controller.Prompt_For_Update;
   end Prompt_For_Update;

   procedure Log (Message : String) is
   begin
      My_Controller.Log (Message);
   end Log;
begin
   loop
      declare
         Port_Name : constant String := Find_Port_Name;
      begin
         if Port_Name /= "" then
            Log ("Prunt Board 3 found at " & Port_Name);
            My_Communications.Runner.Open_Port (GNAT.Serial_Communications.Port_Name (Port_Name));
            exit;
         else
            Log ("Prunt Board 3 not found. Retrying in 3 seconds.");
            delay 3.0;
         end if;
      end;
   end loop;

   My_Communications.Runner.Init (Argument_Value ("--force-firmware-update=", "") = "do-not-use-this-argument");

   for Arg in 1 .. Argument_Count loop
      if Argument (Arg) = "--reboot-to-kalico" then
         My_Communications.Runner.Send_Message
           ((Kind           => Kalico_Reboot_Kind,
             Index          => <>,
             TMC_Write_Data => (others => 0),
             TMC_Read_Data  => (others => 0)));
         My_Communications.Runner.Restart;
         GNAT.OS_Lib.OS_Abort;
      end if;
   end loop;

   My_Controller.Run;

   My_Communications.Runner.Restart;
   GNAT.OS_Lib.OS_Abort;
exception
   when E : others =>
      Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Information (E));
      My_Controller.Report_External_Error (E);
      GNAT.OS_Lib.OS_Abort;
end Prunt_Board_3_Server;
