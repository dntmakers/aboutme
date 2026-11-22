import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  mockNuxtImport,
  mountSuspended,
  registerEndpoint,
} from '@nuxt/test-utils/runtime';
import { flushPromises } from '@vue/test-utils';
import { readRawBody, setResponseStatus } from 'h3';
import ResetPasswordPage from '../app/pages/reset-password.vue';
import { setSiteLocale } from './support/locale';

beforeEach(() => setSiteLocale('en'));

mockNuxtImport('useHead', () => vi.fn());

const TOKEN = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg';
const NEW_PASSWORD = 'correct horse battery staple';

describe('reset-password.vue (fragment handling)', () => {
  it('composes the auth page and shared error banner', async () => {
    window.location.hash = '';
    const wrapper = await mountSuspended(ResetPasswordPage, { route: '' });

    const main = wrapper.get('[data-testid="reset-password-page"]');
    expect(main.find('[data-slot="card"]').exists()).toBe(false);
    expect(main.get('[data-page-title]').text()).toBe('Reset password');
    expect(wrapper.get('[data-testid="reset-error"]').attributes('role')).toBe(
      'alert',
    );
    expect(
      wrapper.get('[data-testid="reset-error"]').attributes('tabindex'),
    ).toBe(
      '-1',
    );
  });

  beforeEach(async () => {
    vi.mocked(useHead).mockClear();
    await useRouter().replace('/reset-password');
  });

  it('strips a single token before submit and posts token + new password',
    async () => {
      await useRouter().replace('/reset-password#token=' + TOKEN);
      window.location.hash = `#token=${TOKEN}`;
      const replaceSpy = vi.spyOn(useRouter(), 'replace');
      let hashAtRequest = 'unset';
      let body: string | null = null;
      let calls = 0;
      registerEndpoint('/api/v1/auth/password/reset', {
        method: 'POST',
        handler: async (event) => {
          calls += 1;
          hashAtRequest = window.location.hash;
          body = await readRawBody(event);
          setResponseStatus(event, 204);
          return null;
        },
      });
      const wrapper = await mountSuspended(ResetPasswordPage, { route: '' });
      expect(wrapper.get('[aria-label="Show new password"]').exists()).toBe(
        true,
      );
      await wrapper.get('#reset-password').setValue(NEW_PASSWORD);
      await wrapper.get('#reset-password-confirm').setValue(NEW_PASSWORD);
      await wrapper.get('[data-testid="reset-form"]').trigger('submit');
      await flushPromises();

      await vi.waitFor(() => expect(calls).toBe(1));
      expect(hashAtRequest).toBe('');
      expect(JSON.parse(body ?? '{}')).toEqual({
        token: TOKEN,
        password: NEW_PASSWORD,
      });
      expect(replaceSpy).toHaveBeenCalledWith(
        expect.objectContaining({ hash: '' }),
      );
      expect(useRouter().currentRoute.value.hash).toBe('');
      expect(wrapper.get('[data-testid="reset-success"]').text()).toContain(
        'Password reset. Sign in.',
      );
      expect(wrapper.html()).not.toContain(TOKEN);
    });

  it('renders a local error and no form when the fragment token is malformed',
    async () => {
      await useRouter().replace('/reset-password#token=a&token=b');
      window.location.hash = '#token=a&token=b';
      let calls = 0;
      registerEndpoint('/api/v1/auth/password/reset', {
        method: 'POST',
        handler: (event) => {
          calls += 1;
          setResponseStatus(event, 204);
          return null;
        },
      });
      const wrapper = await mountSuspended(ResetPasswordPage, { route: '' });
      await flushPromises();
      expect(calls).toBe(0);
      expect(wrapper.find('[data-testid="reset-form"]').exists()).toBe(false);
      expect(wrapper.get('[data-testid="reset-error"]').text()).toBe(
        'This reset link is invalid or incomplete.',
      );
    });

  it('shows a local mismatch error and does not submit', async () => {
    await useRouter().replace('/reset-password#token=' + TOKEN);
    window.location.hash = `#token=${TOKEN}`;
    let calls = 0;
    registerEndpoint('/api/v1/auth/password/reset', {
      method: 'POST',
      handler: (event) => {
        calls += 1;
        setResponseStatus(event, 204);
        return null;
      },
    });
    const wrapper = await mountSuspended(ResetPasswordPage, { route: '' });
    await wrapper.get('#reset-password').setValue(NEW_PASSWORD);
    await wrapper.get('#reset-password-confirm').setValue('different');
    await wrapper.get('[data-testid="reset-form"]').trigger('submit');
    await flushPromises();
    expect(calls).toBe(0);
    expect(wrapper.get('[data-testid="reset-error"]').text()).toContain(
      'Passwords do not match',
    );
  });

  it('shows closed copy for a password policy rejection', async () => {
    await useRouter().replace('/reset-password#token=' + TOKEN);
    window.location.hash = `#token=${TOKEN}`;
    registerEndpoint('/api/v1/auth/password/reset', {
      method: 'POST',
      handler: (event) => {
        setResponseStatus(event, 422);
        return {
          error: {
            code: 'password_invalid',
            message: 'x',
            details: { issue: 'breached' },
          },
        };
      },
    });
    const wrapper = await mountSuspended(ResetPasswordPage, { route: '' });
    await wrapper.get('#reset-password').setValue(NEW_PASSWORD);
    await wrapper.get('#reset-password-confirm').setValue(NEW_PASSWORD);
    await wrapper.get('[data-testid="reset-form"]').trigger('submit');
    await flushPromises();
    await vi.waitFor(() => {
      expect(wrapper.get('[data-testid="reset-error"]').text()).toContain(
        'data breach',
      );
    });
  });

  it('renders a no-referrer meta', async () => {
    await useRouter().replace('/reset-password#token=' + TOKEN);
    window.location.hash = `#token=${TOKEN}`;
    registerEndpoint('/api/v1/auth/password/reset', {
      method: 'POST',
      handler: (event) => {
        setResponseStatus(event, 204);
        return null;
      },
    });
    await mountSuspended(ResetPasswordPage, { route: '' });
    await flushPromises();
    expect(vi.mocked(useHead)).toHaveBeenCalledWith(
      expect.objectContaining({
        meta: expect.arrayContaining([
          expect.objectContaining({
            name: 'referrer',
            content: 'no-referrer',
          }),
        ]),
      }),
    );
  });
});
