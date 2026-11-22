// @vitest-environment happy-dom
import { afterEach, describe, expect, it, vi } from 'vitest';

const storageKey = 'vue-router:scroll';

afterEach(() => {
  sessionStorage.clear();
  vi.restoreAllMocks();
});

describe('router scroll storage', () => {
  it.each([
    '/reset-password#token=synthetic-reset',
    '/VERIFY-EMAIL/?code=synthetic-verify',
    '/%72eset-password#token=synthetic-encoded',
    '/verify%2Demail/#token=synthetic-encoded',
  ])('excludes %s and a prior auth entry', async (path) => {
    sessionStorage.setItem(storageKey, JSON.stringify({
      '1/verify-email#token=synthetic-old': { left: 1, top: 2 },
      '2/showcase?role=backend#work': { left: 12, top: 34 },
    }));
    history.replaceState({ position: 3 }, '', path);
    vi.resetModules();
    const { createWebHistory } = await import('vue-router');
    const routerHistory = createWebHistory();
    history.scrollRestoration = 'manual';
    window.dispatchEvent(new Event('pagehide'));
    const stored = sessionStorage.getItem(storageKey);
    expect(stored).not.toBeNull();
    expect(JSON.parse(stored!)).toEqual({
      '2/showcase?role=backend#work': { left: 12, top: 34 },
    });
    routerHistory.destroy();
  });

  it('restores ordinary query and hash positions on Back', async () => {
    history.replaceState({ position: 10 }, '', '/');
    const { createRouter, createWebHistory } = await import('vue-router');
    const routerHistory = createWebHistory();
    const scrollBehavior = vi.fn(() => false as const);
    const router = createRouter({
      history: routerHistory,
      routes: [
        { path: '/', component: {} },
        { path: '/showcase', component: {} },
        { path: '/other', component: {} },
      ],
      scrollBehavior,
    });
    try {
      await router.push('/showcase?role=backend#work');
      vi.spyOn(window, 'scrollX', 'get').mockReturnValue(12);
      vi.spyOn(window, 'scrollY', 'get').mockReturnValue(34);
      await router.push('/other');
      const stored = sessionStorage.getItem(storageKey);
      expect(stored).not.toBeNull();
      expect(Object.entries(JSON.parse(stored!))).toContainEqual([
        `${history.state.position - 1}/showcase?role=backend#work`,
        { left: 12, top: 34 },
      ]);
      scrollBehavior.mockClear();
      router.back();
      await vi.waitFor(() => {
        expect(scrollBehavior).toHaveBeenCalledWith(
          expect.objectContaining({ fullPath: '/showcase?role=backend#work' }),
          expect.objectContaining({ fullPath: '/other' }),
          { left: 12, top: 34 },
        );
      });
    } finally {
      routerHistory.destroy();
    }
  });
});
