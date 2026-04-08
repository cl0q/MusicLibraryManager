import { Toaster } from "sonner";
import { useTheme } from "../../contexts/ThemeContext";

export default function ToastProvider() {
  const { isDark } = useTheme();

  return (
    <Toaster
      position="bottom-right"
      theme={isDark ? "dark" : "light"}
      toastOptions={{
        style: {
          background: 'var(--color-raised)',
          border: '1px solid var(--color-edge)',
          color: 'var(--color-ink)',
        },
      }}
    />
  );
}
