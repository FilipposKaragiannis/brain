import { useLayoutEffect, useState } from 'react';
import type { KeyboardEvent, PointerEvent as ReactPointerEvent } from 'react';

/** The accessible name of the dock's top edge, which the owner drags, or moves with the arrow keys, to resize the dock. */
export const PANE_DOCK_RESIZE = 'Resize terminal panes';

/** Where this browser keeps the dock's height, in pixels. */
export const PANE_HEIGHT_STORAGE_KEY = 'console.paneDock.height';

/** The terminal's height bounds: at least a few rows, at most a share of the window so the page above stays reachable. */
export const PANE_HEIGHT = {
  defaultPixels: 360,
  defaultWindowShare: 0.45,
  minimumPixels: 120,
  maximumWindowShare: 0.75,
  keyStepPixels: 24,
} as const;

const HEIGHT_PROPERTY = '--pane-body-height';
const PERCENT = 100;
const PRIMARY_BUTTON = 0;

/** The dock's height in pixels and a way to change it, kept in bounds. */
export type DockHeight = { pixels: number; resizeTo: (pixels: number) => void };

/**
 * The height of the dock's terminal, the browser's last pick or a default that fits the window.
 * It goes on the page as `--pane-body-height`, which the dock and the page's bottom padding both
 * read, before the panes refit to it.
 */
export function useDockHeight(): DockHeight {
  const [pixels, setPixels] = useState(storedHeight);
  useLayoutEffect(() => {
    const root = document.documentElement.style;
    root.setProperty(HEIGHT_PROPERTY, `min(${pixels}px, ${PANE_HEIGHT.maximumWindowShare * PERCENT}vh)`);
    storeHeight(pixels);
    return () => { root.removeProperty(HEIGHT_PROPERTY); };
  }, [pixels]);
  return { pixels, resizeTo: (wanted) => setPixels(heightInBounds(wanted)) };
}

/**
 * The dock's top edge: drag it, or focus it and press the up and down arrows, to make the
 * terminal taller or shorter.
 */
export function PaneResizeHandle({ height }: { height: DockHeight }) {
  const startDrag = (event: ReactPointerEvent<HTMLDivElement>): void => {
    if (event.button !== PRIMARY_BUTTON) return;
    event.preventDefault();
    const startY = event.clientY;
    const startPixels = height.pixels;
    const follow = (move: PointerEvent): void => height.resizeTo(startPixels + startY - move.clientY);
    const stop = (): void => {
      window.removeEventListener('pointermove', follow);
      window.removeEventListener('pointerup', stop);
      window.removeEventListener('pointercancel', stop);
    };
    window.addEventListener('pointermove', follow);
    window.addEventListener('pointerup', stop);
    window.addEventListener('pointercancel', stop);
  };
  const step = (event: KeyboardEvent<HTMLDivElement>): void => {
    const change = KEY_STEPS[event.key];
    if (change === undefined) return;
    event.preventDefault();
    height.resizeTo(height.pixels + change);
  };
  return (
    <div
      className="pane-resize"
      role="separator"
      aria-orientation="horizontal"
      aria-label={PANE_DOCK_RESIZE}
      aria-valuemin={PANE_HEIGHT.minimumPixels}
      aria-valuemax={maximumHeight()}
      aria-valuenow={height.pixels}
      tabIndex={0}
      onPointerDown={startDrag}
      onKeyDown={step}
    />
  );
}

const KEY_STEPS: Readonly<Record<string, number>> = { ArrowUp: PANE_HEIGHT.keyStepPixels, ArrowDown: -PANE_HEIGHT.keyStepPixels };

function maximumHeight(): number {
  return Math.round(window.innerHeight * PANE_HEIGHT.maximumWindowShare);
}

function heightInBounds(pixels: number): number {
  return Math.max(PANE_HEIGHT.minimumPixels, Math.min(Math.round(pixels), maximumHeight()));
}

/** The height this browser kept last, in bounds; the default when none is kept, it is not a number or storage is blocked. */
function storedHeight(): number {
  const fallback = Math.min(PANE_HEIGHT.defaultPixels, window.innerHeight * PANE_HEIGHT.defaultWindowShare);
  try {
    const kept = window.localStorage.getItem(PANE_HEIGHT_STORAGE_KEY);
    const keptPixels = kept === null || kept.trim() === '' ? Number.NaN : Number(kept);
    return heightInBounds(Number.isFinite(keptPixels) ? keptPixels : fallback);
  } catch {
    return heightInBounds(fallback);
  }
}

function storeHeight(pixels: number): void {
  try {
    window.localStorage.setItem(PANE_HEIGHT_STORAGE_KEY, String(pixels));
  } catch {
    // The dock still resizes; its height is only not remembered.
  }
}
