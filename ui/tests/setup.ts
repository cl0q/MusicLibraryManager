import { beforeAll, afterEach } from 'vitest';
import { mockWindows, clearMocks } from '@tauri-apps/api/mocks';
import '@testing-library/jest-dom';

// Initialize Tauri window mock before all tests.
// Required by @tauri-apps/api — prevents "window.__TAURI_INTERNALS__ is undefined" errors.
beforeAll(() => {
  mockWindows('main');
});

// Clean up Tauri mocks after each test to prevent state leakage.
afterEach(() => {
  clearMocks();
});
