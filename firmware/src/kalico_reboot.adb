with System.Machine_Reset;
with Heaters;

package body Kalico_Reboot is

   procedure Reboot_To_Kalico is
   begin
      Heaters.Make_Safe;
      Kalico_Persistent_Boot_Flag := 16#0B1C_93F0#;
      System.Machine_Reset.Stop;
   end Reboot_To_Kalico;

end Kalico_Reboot;
