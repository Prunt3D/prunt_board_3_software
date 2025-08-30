with Server_Communication;
with STM32.USARTs;           use STM32.USARTs;
with Hardware_Configuration; use Hardware_Configuration;
with STM32.GPIO;             use STM32.GPIO;
with STM32.Device;           use STM32.Device;
with STM32.DMA;              use STM32.DMA;
with TMC2240;                use TMC2240;

package body Steppers is

   procedure Init is
   begin
      Init_Checker.Report_Init_Started;

      Enable_Clock (TMC_UART);
      Enable_Clock (TMC_UART_DMA_RX_Controller);

      Set_Word_Length (TMC_UART, Word_Length_8);
      Set_Parity (TMC_UART, No_Parity);
      Set_Mode (TMC_UART, Tx_Rx_Mode);
      Set_Oversampling_Mode (TMC_UART, Oversampling_By_16);
      Set_Stop_Bits (TMC_UART, Stopbits_1);
      Set_Flow_Control (TMC_UART, No_Flow_Control);
      Set_Baud_Rate (TMC_UART, 19_200);
      TMC_UART_Internal.CR1.FIFOEN := True;
      TMC_UART_Internal.CR3.HDSEL := True;

      Enable (TMC_UART);

      delay until Clock + Milliseconds (10);

      Configure_IO
        (TMC_UART_Pin,
         (Mode           => Mode_AF,
          Resistors      => Floating,
          AF_Output_Type => Push_Pull,
          AF_Speed       => Speed_25MHz,
          AF             => TMC_UART_Pin_AF));

      delay until Clock + Milliseconds (10);

      Configure
        (TMC_UART_DMA_RX_Controller,
         TMC_UART_DMA_RX_Stream,
         (Channel                      => TMC_UART_DMA_RX_Channel,
          Direction                    => Peripheral_To_Memory,
          Increment_Peripheral_Address => False,
          Increment_Memory_Address     => True,
          Peripheral_Data_Format       => Bytes,
          Memory_Data_Format           => Bytes,
          Operation_Mode               => Normal_Mode,
          Priority                     => TMC_UART_DMA_RX_Priority,
          Memory_Burst_Size            => Memory_Burst_Single,
          Peripheral_Burst_Size        => Peripheral_Burst_Single));

      Enable_DMA_Receive_Requests (TMC_UART);

      --  For some reason the UART says that it receives a byte when we first enable it and reading out that byte does
      --  not stop the UART from reading it out again.
      --
      --  TODO: Investigate this more.
      Start_Transfer
        (This        => TMC_UART_DMA_RX_Controller,
         Stream      => TMC_UART_DMA_RX_Stream,
         Source      => Read_Data_Register_Address (TMC_UART),
         Destination => RX_Buffer'Address,
         Data_Count  => 1);

      declare
         Error : DMA_Error_Code;
      begin
         delay until Clock + Milliseconds (10);
         Abort_Transfer (This => TMC_UART_DMA_RX_Controller, Stream => TMC_UART_DMA_RX_Stream, Result => Error);
         Clear_All_Status (TMC_UART_DMA_RX_Controller, TMC_UART_DMA_RX_Stream);
      end;

      Init_Checker.Report_Init_Done;

      Send_To_All_Steppers
        ((Bytes_Mode => False,
          Content    =>
            (Node          => 1,
             Register      => TMC2240.NODECONF_Address,
             NODECONF_Data => (Node_Addr => 0, Send_Delay => TMC2240.Delay_3x8, Reserved => 0),
             others        => <>)));
      Send_To_All_Steppers
        ((Bytes_Mode => False,
          Content    =>
            (Node          => 1,
             Register      => TMC2240.CHOPCONF_Address,
             CHOPCONF_Data =>
               (TOFF                 => TMC2240.Disable_Driver,
                HSTRT_TFD210         => 5,
                HEND_OFFSET          => 2,
                FD3                  => 0,
                DISFDCC              => TMC2240.False,
                Reserved_1           => 0,
                CHM                  => TMC2240.SpreadCycle_Mode,
                TBL                  => TMC2240.Blank_36,
                Reserved_2           => 0,
                VHIGHFS              => TMC2240.False,
                VHIGHCHM             => TMC2240.False,
                TPFD                 => 4,
                Microstep_Resolution => TMC2240.MS_256,
                Interpolate          => TMC2240.False,
                Double_Edge          => TMC2240.True,
                Disable_S2G          => TMC2240.False,
                Disable_S2Vs         => TMC2240.False),
             others        => <>)));
   end Init;

   procedure Send_To_All_Steppers (Message : TMC2240.UART_Data_Message) is
      Data_Message  : TMC2240.UART_Data_Message := Message;
      Query_Message : TMC2240.UART_Query_Message :=
        (Bytes_Mode => False, Content => (Node => 1, Register => Message.Content.Register, others => <>));
   begin
      for I in TMC2240.UART_Node_Address range 1 .. 6 loop
         loop
            declare
               Retry : Positive := 1;
            begin
               delay until Clock + Milliseconds (10);
               Data_Message.Content.Node := I;
               Data_Message.Content.CRC := TMC2240.Compute_CRC (Data_Message);
               UART_IO.Write ((for I in 1 .. 8 => TMC2240_UART_Byte (Data_Message.Bytes (9 - I))));

               delay until Clock + Milliseconds (10);
               Query_Message.Content.Node := I;
               Query_Message.Content.CRC := TMC2240.Compute_CRC (Query_Message);
               UART_IO.Start_Read ((for I in 1 .. 4 => TMC2240_UART_Byte (Query_Message.Bytes (5 - I))));

               declare
                  Result         : TMC2240_UART_Data_Byte_Array;
                  Result_Message : TMC2240.UART_Data_Message;
               begin
                  UART_IO.Get_Read_Result (Result);
                  Result_Message.Bytes := (for I in 1 .. 8 => TMC2240.UART_Byte (Result (9 - I)));

                  if Result_Message.Content.Node = 255
                    and then Result_Message.Content.CRC = TMC2240.Compute_CRC (Result_Message)
                    and then (Result_Message.Content with delta CRC => 0, Node => 0)
                             = (Data_Message.Content with delta CRC => 0, Node => 0, Is_Write => TMC2240.False)
                  then
                     exit;
                  else
                     Retry := @ + 1;
                  end if;
               end;

               if Retry = 10 then
                  raise TMC_UART_Error with "Failed to write register for node " & I'Image;
               end if;
            end;
         end loop;
      end loop;
   end Send_To_All_Steppers;

   protected body UART_IO is
      procedure Start_Read (Input : TMC2240_UART_Query_Byte_Array) is
      begin
         Init_Checker.Raise_If_Init_Not_Done;

         if Read_Started then
            raise Constraint_Error with "Read already started.";
         end if;

         Read_Started := True;

         --  Keep the receiver off until the transmission is done in case a write just happened.
         loop
            exit when TMC_UART_Internal.ISR.TXFE and TMC_UART_Internal.ISR.TC;
         end loop;
         TMC_UART_Internal.CR1.RE := True;

         while Rx_Ready (TMC_UART) or TMC_UART_Internal.ISR.BUSY loop
            declare
               Junk : UInt9 := TMC_UART_Internal.RDR.RDR;
            begin
               --  Server_Communication.Transmit_String_Line
               --    ("Unexpected data on TMC UART before read (" & Junk'Image & ").");
               null;
            end;
         end loop;

         --  STM32G474 has a 8 byte FIFO (Table 345, RM0440 Rev 8), so no need for DMA here.
         TMC_UART_Internal.CR1.TE := False;
         for Byte of Input loop
            Transmit (TMC_UART, UInt9 (Byte));
         end loop;

         Start_Transfer
           (This        => TMC_UART_DMA_RX_Controller,
            Stream      => TMC_UART_DMA_RX_Stream,
            Source      => Read_Data_Register_Address (TMC_UART),
            Destination => RX_Buffer'Address,
            Data_Count  => RX_Buffer'Length);
         TMC_UART_Internal.CR1.TE := True;

         Read_Start_Time := Clock;
      end Start_Read;

      function Read_Result_Ready return Boolean is
      begin
         return
           Read_Started
           and then (Status (TMC_UART_DMA_RX_Controller, TMC_UART_DMA_RX_Stream, Transfer_Complete_Indicated)
                     or else Clock > Read_Start_Time + Milliseconds (100));
      end Read_Result_Ready;

      procedure Get_Read_Result (Output : out TMC2240_UART_Data_Byte_Array) is
      begin
         Init_Checker.Raise_If_Init_Not_Done;

         if not Read_Started then
            raise Constraint_Error with "No read started.";
         end if;

         Read_Started := False;

         declare
            Error : DMA_Error_Code;
         begin
            Poll_For_Completion
              (This           => TMC_UART_DMA_RX_Controller,
               Stream         => TMC_UART_DMA_RX_Stream,
               Expected_Level => Full_Transfer,
               Timeout        => Read_Start_Time + Milliseconds (100) - Clock,
               Result         => Error);

            if Error /= DMA_No_Error then
               Output := (others => 255);
            --  Put a known bad message on the output to indicate an error.

            end if;
         end;

         for I in 1 .. 8 loop
            Output (I) := TMC2240_UART_Byte (RX_Buffer (I + 4));
         end loop;
      end Get_Read_Result;

      procedure Write (Input : TMC2240_UART_Data_Byte_Array) is
      begin
         Init_Checker.Raise_If_Init_Not_Done;

         if Read_Started then
            raise Constraint_Error with "Can not write with pending read.";
         end if;

         while Rx_Ready (TMC_UART) or TMC_UART_Internal.ISR.BUSY loop
            declare
               Junk : UInt9 := TMC_UART_Internal.RDR.RDR;
            begin
               --  Server_Communication.Transmit_String_Line
               --    ("Unexpected data on TMC UART before write (" & Junk'Image & ").");
               null;
            end;
         end loop;

         --  STM32G474 has a 8 byte FIFO (Table 345, RM0440 Rev 8), so no need for DMA here.
         TMC_UART_Internal.CR1.TE := False;
         TMC_UART_Internal.CR1.RE := False;
         for Byte of Input loop
            Transmit (TMC_UART, UInt9 (Byte));
         end loop;
         TMC_UART_Internal.CR1.TE := True;
      end Write;
   end UART_IO;

end Steppers;
