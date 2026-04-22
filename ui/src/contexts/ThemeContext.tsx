import { createContext, useContext, useEffect, useState, type ReactNode } from "react";

export type ThemeName = "solar" | "midnight" | "solarized-dark" | "solarized-light";

interface ThemeContextValue {
  theme: ThemeName;
  setTheme: (t: ThemeName) => void;
  isDark: boolean;
}

const ThemeContext = createContext<ThemeContextValue>({
  theme: "solar",
  setTheme: () => {},
  isDark: false,
});

const STORAGE_KEY = "mlm-theme";
const LIGHT_THEMES: ThemeName[] = ["solar", "solarized-light"];

function getInitialTheme(): ThemeName {
  const stored = localStorage.getItem(STORAGE_KEY);
  if (
    stored === "solar" ||
    stored === "midnight" ||
    stored === "solarized-dark" ||
    stored === "solarized-light"
  ) {
    return stored;
  }
  return "solar";
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

  const isDark = !LIGHT_THEMES.includes(theme);

  return (
    <ThemeContext.Provider value={{ theme, setTheme, isDark }}>
      {children}
    </ThemeContext.Provider>
  );
}

export function useTheme() {
  return useContext(ThemeContext);
}
