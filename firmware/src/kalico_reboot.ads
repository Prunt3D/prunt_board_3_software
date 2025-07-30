private with HAL;

package Kalico_Reboot is

   procedure Reboot_To_Kalico;

private

   Kalico_Persistent_Boot_Flag : HAL.UInt32
   with Volatile => True, Linker_Section => ".data_persistent.kalico_boot_flag";

end Kalico_Reboot;
