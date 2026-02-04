import SyncProfiles from "../components/SyncProfiles";

export default function Sync() {
  return (
    <SyncProfiles
      onSelectProfile={(profile) => {
        // Navigate to sync preview page
        // For now, just show a toast
        console.log("Selected profile:", profile);
      }}
    />
  );
}
