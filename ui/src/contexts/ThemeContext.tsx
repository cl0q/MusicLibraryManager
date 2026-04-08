import { createContext, useContext, useEffect, useState, type ReactNode } from "react";

export type ThemeName = "midnight" | "solarized-dark" | "solarized-light";

interface ThemeContextValue {
  theme: ThemeName;
  setTheme: (t: ThemeName) => void;
  isDark: boolean;
}

const ThemeContext = createContext<ThemeContextValue>({
  theme: "midnight",
  setTheme: () => {},
  isDark: true,
});

const STORAGE_KEY = "mlm-theme";

function getInitialTheme(): ThemeName {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored === "midnight" || stored === "solarized-dark" || stored === "solarized-light") {
    return stored;
  }
  return "midnight";
}

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setThemeState] = useState<ThemeName>(getInitialTheme);

  const setTheme = (t: ThemeName) => {
    setThemeState(t);
    localStorage.setItem(STORAGE_KEY, t);
  };

  useEffect(() => {
    document.documentElement.setAttribute("data-theme", theme);
  }, [theme]);

  const isDark = theme !== "solarized-light";

  return (
    <ThemeContext.Provider value={{ theme, setTheme, isDark }}>
      {children}
    </ThemeContext.Provider>
  );
}

export function useTheme() {
  return useContext(ThemeContext);
}
