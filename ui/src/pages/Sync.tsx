import { toast } from "sonner";
import SyncProfiles, { type SyncProfileDto } from "../components/SyncProfiles";
import { execute_sync_cmd } from "../utils/tauri-commands";

export default function Sync() {
  const handleSelectProfile = async (profile: SyncProfileDto) => {
    try {
      toast.info(`Starting sync for ${profile.name}...`);
      const result = await execute_sync_cmd(String(profile.id));
      toast.success(
        `Sync complete! Added: ${result.files_added}, Updated: ${result.files_updated}`
      );
    } catch (error) {
      console.error("Sync failed:", error);
      toast.error(`Sync failed: ${error}`);
    }
  };

  return <SyncProfiles onSelectProfile={handleSelectProfile} />;
}
