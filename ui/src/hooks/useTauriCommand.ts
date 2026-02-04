import { invoke } from "@tauri-apps/api/core";

interface TauriCommandResult<T> {
  ok: boolean;
  data?: T;
  error?: string;
}

/**
 * Generic hook for invoking Tauri commands with error handling
 * @param cmd - The Tauri command name to invoke
 * @param payload - Optional payload to pass to the command
 * @returns Result object with ok flag, data on success, or error message on failure
 */
export async function invokeTauriCommand<T>(
  cmd: string,
  payload?: Record<string, unknown>
): Promise<TauriCommandResult<T>> {
  try {
    const data = await invoke<T>(cmd, payload);
    return { ok: true, data };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error)
    };
  }
}
